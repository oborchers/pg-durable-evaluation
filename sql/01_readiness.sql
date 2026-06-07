\set ON_ERROR_STOP on
\pset pager off

SET SESSION AUTHORIZATION poc_runner;

CREATE TEMP TABLE _state(instance_id text);

INSERT INTO _state
SELECT df.start(
    'SELECT ''hello pg_durable'' AS message',
    'poc-readiness'
);

DO $$
DECLARE
    inst_id text;
    final_status text;
    result_json jsonb;
BEGIN
    SELECT instance_id INTO inst_id FROM _state;
    SELECT df.wait_for_completion(inst_id, 30) INTO final_status;
    SELECT df.result(inst_id)::jsonb INTO result_json;

    IF final_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: readiness status = %', final_status;
    END IF;

    IF result_json->'rows'->0->>'message' != 'hello pg_durable' THEN
        RAISE EXCEPTION 'TEST FAILED: unexpected readiness result %', result_json;
    END IF;

    INSERT INTO poc.experiment_results(experiment, instance_id, status, assertion)
    VALUES (
        '01_readiness',
        inst_id,
        'passed',
        jsonb_build_object('message', result_json->'rows'->0->>'message')
    );

    RAISE NOTICE 'TEST PASSED: readiness instance=%', inst_id;
END $$;

DROP TABLE _state;

RESET SESSION AUTHORIZATION;

