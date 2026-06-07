\set ON_ERROR_STOP on
\pset pager off

SET SESSION AUTHORIZATION poc_runner;

DO $$
DECLARE
    start_ts timestamptz := clock_timestamp();
    end_ts timestamptz;
    rec record;
    final_status text;
    workflow_count int;
    event_count int;
    failed_count int := 0;
    worker_count int;
BEGIN
    SELECT count(*) INTO workflow_count
    FROM poc.load_workflows
    WHERE batch = 'concurrent_sessions';

    IF workflow_count = 0 THEN
        RAISE EXCEPTION 'TEST FAILED: no concurrent session workflows were submitted';
    END IF;

    FOR rec IN
        SELECT instance_id
        FROM poc.load_workflows
        WHERE batch = 'concurrent_sessions'
        ORDER BY id
    LOOP
        SELECT df.wait_for_completion(rec.instance_id, 180) INTO final_status;

        UPDATE poc.load_workflows
        SET completed_status = final_status,
            completed_at = clock_timestamp()
        WHERE instance_id = rec.instance_id;

        IF final_status != 'completed' THEN
            failed_count := failed_count + 1;
        END IF;
    END LOOP;

    end_ts := clock_timestamp();

    SELECT count(*) INTO event_count
    FROM poc.load_workflow_events
    WHERE batch = 'concurrent_sessions';

    SELECT count(DISTINCT worker_id) INTO worker_count
    FROM poc.load_workflows
    WHERE batch = 'concurrent_sessions';

    IF failed_count != 0 THEN
        RAISE EXCEPTION 'TEST FAILED: % concurrent workflows failed', failed_count;
    END IF;

    IF event_count != workflow_count THEN
        RAISE EXCEPTION 'TEST FAILED: concurrent event count % != workflow count %', event_count, workflow_count;
    END IF;

    UPDATE poc.load_batches
    SET planned_count = workflow_count,
        completed_at = end_ts,
        elapsed_ms = extract(epoch FROM end_ts - start_ts) * 1000,
        detail = jsonb_build_object(
            'workers', worker_count,
            'submitted_workflows', workflow_count,
            'completed_workflows', workflow_count - failed_count,
            'events_written', event_count
        )
    WHERE batch = 'concurrent_sessions';

    INSERT INTO poc.experiment_results(experiment, status, assertion)
    SELECT
        '110_load_concurrent_sessions',
        'passed',
        jsonb_build_object(
            'batch', batch,
            'workers', worker_count,
            'planned_count', planned_count,
            'elapsed_ms', elapsed_ms,
            'events_written', event_count
        )
    FROM poc.load_batches
    WHERE batch = 'concurrent_sessions';

    RAISE NOTICE 'TEST PASSED: concurrent load workers=% workflows=% elapsed_ms=%',
        worker_count,
        workflow_count,
        (SELECT elapsed_ms FROM poc.load_batches WHERE batch = 'concurrent_sessions');
END $$;

RESET SESSION AUTHORIZATION;
