\set ON_ERROR_STOP on
\pset pager off

SET SESSION AUTHORIZATION poc_runner;

UPDATE poc.jobs
SET status = 'pending',
    attempts = 0,
    result = NULL,
    started_at = NULL,
    completed_at = NULL;
TRUNCATE poc.job_audit;

CREATE TEMP TABLE _state(instance_id text);

INSERT INTO _state
SELECT df.start(
    df.loop(
        $$SELECT * FROM poc.dispatch_next_job()$$,
        $$SELECT EXISTS (SELECT 1 FROM poc.jobs WHERE status = 'pending')$$
    ),
    'poc-dispatch-jobs'
);

DO $$
DECLARE
    inst_id text;
    final_status text;
    completed_jobs int;
    audit_rows int;
BEGIN
    SELECT instance_id INTO inst_id FROM _state;
    SELECT df.wait_for_completion(inst_id, 60) INTO final_status;

    SELECT count(*) INTO completed_jobs FROM poc.jobs WHERE status = 'completed';
    SELECT count(*) INTO audit_rows FROM poc.job_audit;

    IF final_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: dispatch status = %', final_status;
    END IF;

    IF completed_jobs != 3 OR audit_rows != 6 THEN
        RAISE EXCEPTION 'TEST FAILED: expected 3 completed jobs and 6 audit rows, got jobs=% audit=%',
            completed_jobs, audit_rows;
    END IF;

    INSERT INTO poc.experiment_results(experiment, instance_id, status, assertion)
    VALUES (
        '20_dispatch_jobs',
        inst_id,
        'passed',
        jsonb_build_object('completed_jobs', completed_jobs, 'audit_rows', audit_rows)
    );

    RAISE NOTICE 'TEST PASSED: dispatch jobs instance=% completed_jobs=%', inst_id, completed_jobs;
END $$;

DROP TABLE _state;

RESET SESSION AUTHORIZATION;

