\set ON_ERROR_STOP on
\pset pager off

SET SESSION AUTHORIZATION poc_runner;

DROP TABLE IF EXISTS poc.load_workflow_events;
DROP TABLE IF EXISTS poc.load_workflows;
DROP TABLE IF EXISTS poc.load_batches;

CREATE TABLE poc.load_batches (
    batch text PRIMARY KEY,
    mode text NOT NULL,
    planned_count int NOT NULL,
    started_at timestamptz NOT NULL DEFAULT now(),
    submitted_at timestamptz,
    completed_at timestamptz,
    elapsed_ms numeric(12, 3),
    detail jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE poc.load_workflows (
    id bigserial PRIMARY KEY,
    batch text NOT NULL REFERENCES poc.load_batches(batch),
    worker_id int NOT NULL,
    seq int NOT NULL,
    instance_id text NOT NULL UNIQUE,
    submitted_at timestamptz NOT NULL DEFAULT now(),
    completed_status text,
    completed_at timestamptz,
    UNIQUE(batch, worker_id, seq)
);

CREATE TABLE poc.load_workflow_events (
    id bigserial PRIMARY KEY,
    batch text NOT NULL,
    worker_id int NOT NULL,
    seq int NOT NULL,
    instance_id text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION poc.record_load_workflow(
    p_batch text,
    p_worker_id int,
    p_seq int,
    p_instance_id text,
    p_sleep_ms int DEFAULT 0
)
RETURNS TABLE(batch text, worker_id int, seq int, instance_id text)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_sleep_ms > 0 THEN
        PERFORM pg_sleep(p_sleep_ms::numeric / 1000.0);
    END IF;

    INSERT INTO poc.load_workflow_events(batch, worker_id, seq, instance_id)
    VALUES (p_batch, p_worker_id, p_seq, p_instance_id);

    RETURN QUERY SELECT p_batch, p_worker_id, p_seq, p_instance_id;
END;
$$;

CREATE OR REPLACE FUNCTION poc.submit_load_workflows(
    p_batch text,
    p_worker_id int,
    p_count int,
    p_sleep_ms int DEFAULT 0
)
RETURNS int
LANGUAGE plpgsql
AS $$
DECLARE
    i int;
    workflow_seq int;
    inst_id text;
BEGIN
    INSERT INTO poc.load_batches(batch, mode, planned_count, started_at)
    VALUES (p_batch, 'concurrent_sessions', 0, now())
    ON CONFLICT (batch) DO NOTHING;

    FOR i IN 1..p_count LOOP
        workflow_seq := (p_worker_id * 100000) + i;

        inst_id := df.start(
            format(
                $q$SELECT * FROM poc.record_load_workflow(%L, %s, %s, '{sys_instance_id}', %s)$q$,
                p_batch,
                p_worker_id,
                workflow_seq,
                p_sleep_ms
            ),
            format('poc-load-%s-w%s-%s', p_batch, p_worker_id, i)
        );

        INSERT INTO poc.load_workflows(batch, worker_id, seq, instance_id)
        VALUES (p_batch, p_worker_id, workflow_seq, inst_id);
    END LOOP;

    UPDATE poc.load_batches
    SET planned_count = (
            SELECT count(*)
            FROM poc.load_workflows
            WHERE batch = p_batch
        ),
        submitted_at = now()
    WHERE batch = p_batch;

    RETURN p_count;
END;
$$;

INSERT INTO poc.load_batches(batch, mode, planned_count, started_at)
VALUES ('single_session_burst', 'single_session_burst', 200, clock_timestamp());

SELECT poc.submit_load_workflows('single_session_burst', 0, 200, 0) AS submitted_single_session_workflows;

UPDATE poc.load_batches
SET submitted_at = clock_timestamp()
WHERE batch = 'single_session_burst';

DO $$
DECLARE
    start_ts timestamptz;
    end_ts timestamptz;
    rec record;
    final_status text;
    expected_count int;
    event_count int;
    failed_count int := 0;
BEGIN
    SELECT started_at INTO start_ts
    FROM poc.load_batches
    WHERE batch = 'single_session_burst';

    FOR rec IN
        SELECT instance_id
        FROM poc.load_workflows
        WHERE batch = 'single_session_burst'
        ORDER BY id
    LOOP
        SELECT df.wait_for_completion(rec.instance_id, 120) INTO final_status;

        UPDATE poc.load_workflows
        SET completed_status = final_status,
            completed_at = clock_timestamp()
        WHERE instance_id = rec.instance_id;

        IF final_status != 'completed' THEN
            failed_count := failed_count + 1;
        END IF;
    END LOOP;

    end_ts := clock_timestamp();

    SELECT count(*) INTO expected_count
    FROM poc.load_workflows
    WHERE batch = 'single_session_burst';

    SELECT count(*) INTO event_count
    FROM poc.load_workflow_events
    WHERE batch = 'single_session_burst';

    IF expected_count != 200 THEN
        RAISE EXCEPTION 'TEST FAILED: expected 200 single-session workflows, got %', expected_count;
    END IF;

    IF failed_count != 0 THEN
        RAISE EXCEPTION 'TEST FAILED: % single-session workflows failed', failed_count;
    END IF;

    IF event_count != expected_count THEN
        RAISE EXCEPTION 'TEST FAILED: event count % != workflow count %', event_count, expected_count;
    END IF;

    UPDATE poc.load_batches
    SET completed_at = end_ts,
        elapsed_ms = extract(epoch FROM end_ts - start_ts) * 1000,
        detail = jsonb_build_object(
            'submitted_workflows', expected_count,
            'completed_workflows', expected_count - failed_count,
            'events_written', event_count
        )
    WHERE batch = 'single_session_burst';

    INSERT INTO poc.experiment_results(experiment, status, assertion)
    SELECT
        '110_load_single_session_burst',
        'passed',
        jsonb_build_object(
            'batch', batch,
            'planned_count', planned_count,
            'elapsed_ms', elapsed_ms,
            'events_written', event_count
        )
    FROM poc.load_batches
    WHERE batch = 'single_session_burst';

    RAISE NOTICE 'TEST PASSED: single-session load workflows=% elapsed_ms=%',
        expected_count,
        (SELECT elapsed_ms FROM poc.load_batches WHERE batch = 'single_session_burst');
END $$;

RESET SESSION AUTHORIZATION;
