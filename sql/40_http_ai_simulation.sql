\set ON_ERROR_STOP on
\pset pager off

SET SESSION AUTHORIZATION poc_runner;

UPDATE poc.api_transforms
SET status = 'queued',
    response = NULL,
    transformed_text = NULL,
    completed_at = NULL;

SELECT df.clearvars();
SELECT df.setvar('transform_url', 'https://api.github.com/rate_limit');

CREATE TEMP TABLE _state(instance_id text);

INSERT INTO _state
SELECT df.start(
    'SELECT id, input_text FROM poc.api_transforms WHERE status = ''queued'' ORDER BY id LIMIT 1' |=> 'item'
    ~> 'UPDATE poc.api_transforms SET status = ''processing'' WHERE id = $item.id'
    ~> (
        df.http(
            '{transform_url}',
            'GET',
            NULL,
            '{"Accept": "application/vnd.github+json", "User-Agent": "pg-durable-poc"}'::jsonb,
            30
        ) |=> 'api_response'
    )
    ~> 'UPDATE poc.api_transforms
        SET status = ''completed'',
            response = $api_response::jsonb,
            transformed_text = upper(input_text),
            completed_at = now()
        WHERE id = $item.id
        RETURNING id, status, transformed_text',
    'poc-http-ai-simulation'
);

DO $$
DECLARE
    inst_id text;
    final_status text;
    row_state poc.api_transforms%ROWTYPE;
    http_status int;
BEGIN
    SELECT instance_id INTO inst_id FROM _state;
    SELECT df.wait_for_completion(inst_id, 90) INTO final_status;
    SELECT * INTO row_state FROM poc.api_transforms ORDER BY id LIMIT 1;
    SELECT (row_state.response->>'status')::int INTO http_status;

    IF final_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: HTTP/AI simulation status = %', final_status;
    END IF;

    IF row_state.status != 'completed' OR http_status != 200 THEN
        RAISE EXCEPTION 'TEST FAILED: transform row status=% http_status=% response=%',
            row_state.status, http_status, row_state.response;
    END IF;

    INSERT INTO poc.experiment_results(experiment, instance_id, status, assertion)
    VALUES (
        '40_http_ai_simulation',
        inst_id,
        'passed',
        jsonb_build_object(
            'row_id', row_state.id,
            'http_status', http_status,
            'transformed_text', row_state.transformed_text
        )
    );

    RAISE NOTICE 'TEST PASSED: HTTP AI simulation instance=% http_status=%', inst_id, http_status;
END $$;

SELECT df.clearvars();
DROP TABLE _state;

RESET SESSION AUTHORIZATION;
