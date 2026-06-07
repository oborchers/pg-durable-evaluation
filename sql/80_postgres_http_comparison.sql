\set ON_ERROR_STOP on
\pset pager off

CREATE EXTENSION IF NOT EXISTS http;

GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO poc_runner;
GRANT USAGE ON TYPE http_request TO poc_runner;
GRANT USAGE ON TYPE http_response TO poc_runner;
GRANT USAGE ON TYPE http_header TO poc_runner;
GRANT USAGE ON TYPE http_method TO poc_runner;

SET SESSION AUTHORIZATION poc_runner;

DROP TABLE IF EXISTS poc.http_comparison_results;
CREATE TABLE poc.http_comparison_results (
    id bigserial PRIMARY KEY,
    client text NOT NULL,
    endpoint text NOT NULL,
    instance_id text,
    status_code int,
    ok boolean,
    body_has_resources boolean,
    raw jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TEMP TABLE _state(label text, instance_id text);

-- Baseline: pg_durable's native HTTP node. This is governed by pg_durable's
-- build-time HTTP allowlist and by EXECUTE privilege on df.http().
INSERT INTO _state(label, instance_id)
SELECT
    'df-http-rate-limit',
    df.start(
        (
            df.http(
                'https://api.github.com/rate_limit',
                'GET',
                NULL,
                '{"Accept": "application/vnd.github+json", "User-Agent": "pg-durable-poc"}'::jsonb,
                30
            ) |=> 'response'
        )
        ~> 'INSERT INTO poc.http_comparison_results(client, endpoint, status_code, ok, body_has_resources, raw)
            SELECT
                ''df.http'',
                ''https://api.github.com/rate_limit'',
                ($response::jsonb->>''status'')::int,
                ($response::jsonb->>''ok'')::boolean,
                (($response::jsonb->>''body'')::jsonb ? ''resources''),
                $response::jsonb
            RETURNING status_code',
        'poc-compare-df-http'
    );

-- Follow-up: postgres-http called from inside a pg_durable SQL node. This is
-- just SQL from pg_durable's point of view; pg_durable's df.http allowlist is
-- not involved.
INSERT INTO _state(label, instance_id)
SELECT
    'postgres-http-rate-limit',
    df.start(
        'INSERT INTO poc.http_comparison_results(client, endpoint, status_code, ok, body_has_resources, raw)
         SELECT
             ''postgres-http'',
             ''https://api.github.com/rate_limit'',
             response.status,
             response.status BETWEEN 200 AND 299,
             response.content::jsonb ? ''resources'',
             jsonb_build_object(
                 ''status'', response.status,
                 ''content_type'', response.content_type,
                 ''body'', response.content::jsonb,
                 ''headers'', to_jsonb(response.headers)
             )
         FROM http((
             ''GET'',
             ''https://api.github.com/rate_limit'',
             ARRAY[
                 http_header(''Accept'', ''application/vnd.github+json''),
                 http_header(''User-Agent'', ''pg-durable-poc'')
             ]::http_header[],
             NULL,
             NULL
         )::http_request) AS response
         RETURNING status_code',
        'poc-compare-postgres-http'
    );

-- Security comparison: native df.http blocks example.com in the test build,
-- but postgres-http can still be invoked from an ordinary SQL node if the
-- extension is installed and executable.
INSERT INTO _state(label, instance_id)
SELECT
    'postgres-http-example-dot-com',
    df.start(
        'INSERT INTO poc.http_comparison_results(client, endpoint, status_code, ok, body_has_resources, raw)
         SELECT
             ''postgres-http'',
             ''https://example.com/'',
             response.status,
             response.status BETWEEN 200 AND 299,
             false,
             jsonb_build_object(
                 ''status'', response.status,
                 ''content_type'', response.content_type,
                 ''content_prefix'', left(response.content, 80)
             )
         FROM http_get(''https://example.com/'') AS response
         RETURNING status_code',
        'poc-compare-postgres-http-example'
    );

DO $$
DECLARE
    rec record;
    final_status text;
BEGIN
    FOR rec IN SELECT * FROM _state LOOP
        SELECT df.wait_for_completion(rec.instance_id, 90) INTO final_status;

        IF final_status != 'completed' THEN
            RAISE EXCEPTION 'TEST FAILED: % status = %', rec.label, final_status;
        END IF;
    END LOOP;
END $$;

DO $$
DECLARE
    df_row poc.http_comparison_results%ROWTYPE;
    pg_row poc.http_comparison_results%ROWTYPE;
    example_row poc.http_comparison_results%ROWTYPE;
BEGIN
    SELECT * INTO df_row
    FROM poc.http_comparison_results
    WHERE client = 'df.http'
      AND endpoint = 'https://api.github.com/rate_limit';

    SELECT * INTO pg_row
    FROM poc.http_comparison_results
    WHERE client = 'postgres-http'
      AND endpoint = 'https://api.github.com/rate_limit';

    SELECT * INTO example_row
    FROM poc.http_comparison_results
    WHERE client = 'postgres-http'
      AND endpoint = 'https://example.com/';

    IF df_row.status_code != 200 OR df_row.ok IS NOT TRUE OR df_row.body_has_resources IS NOT TRUE THEN
        RAISE EXCEPTION 'TEST FAILED: unexpected df.http row %', row_to_json(df_row);
    END IF;

    IF pg_row.status_code != 200 OR pg_row.ok IS NOT TRUE OR pg_row.body_has_resources IS NOT TRUE THEN
        RAISE EXCEPTION 'TEST FAILED: unexpected postgres-http GitHub row %', row_to_json(pg_row);
    END IF;

    IF example_row.status_code NOT BETWEEN 200 AND 299 THEN
        RAISE EXCEPTION 'TEST FAILED: expected postgres-http example.com success, got %', row_to_json(example_row);
    END IF;

    INSERT INTO poc.experiment_results(experiment, status, assertion)
    VALUES (
        '80_postgres_http_comparison',
        'passed',
        jsonb_build_object(
            'df_http_status', df_row.status_code,
            'postgres_http_status', pg_row.status_code,
            'postgres_http_example_status', example_row.status_code,
            'security_note', 'postgres-http SQL nodes are not governed by df.http allowlist'
        )
    );

    RAISE NOTICE 'TEST PASSED: postgres-http comparison df.status=% postgres_http.status=% example.status=%',
        df_row.status_code, pg_row.status_code, example_row.status_code;
END $$;

DROP TABLE _state;

RESET SESSION AUTHORIZATION;

