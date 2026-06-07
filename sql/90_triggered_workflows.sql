\set ON_ERROR_STOP on
\pset pager off

SET SESSION AUTHORIZATION poc_runner;

DROP TABLE IF EXISTS poc.trigger_workflow_log;
DROP TABLE IF EXISTS poc.trigger_items CASCADE;

CREATE TABLE poc.trigger_items (
    id bigserial PRIMARY KEY,
    status text NOT NULL DEFAULT 'staged',
    payload jsonb NOT NULL DEFAULT '{}'::jsonb,
    workflow_instance_id text,
    workflow_started_at timestamptz,
    processed_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE poc.trigger_workflow_log (
    id bigserial PRIMARY KEY,
    item_id bigint NOT NULL,
    instance_id text NOT NULL,
    event text NOT NULL,
    detail jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION poc.process_trigger_item(p_item_id bigint, p_instance_id text)
RETURNS TABLE(item_id bigint, final_status text)
LANGUAGE plpgsql
AS $$
DECLARE
    affected int;
BEGIN
    UPDATE poc.trigger_items
    SET status = 'processed',
        processed_at = now(),
        updated_at = now()
    WHERE id = p_item_id
      AND status = 'ready';

    GET DIAGNOSTICS affected = ROW_COUNT;

    INSERT INTO poc.trigger_workflow_log(item_id, instance_id, event, detail)
    VALUES (
        p_item_id,
        p_instance_id,
        'processed',
        jsonb_build_object('updated_rows', affected)
    );

    RETURN QUERY
    SELECT t.id, t.status
    FROM poc.trigger_items t
    WHERE t.id = p_item_id;
END;
$$;

CREATE OR REPLACE FUNCTION poc.trigger_item_start_workflow()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    inst_id text;
BEGIN
    NEW.updated_at := now();

    IF NEW.status = 'ready'
       AND NEW.workflow_instance_id IS NULL
       AND (TG_OP = 'INSERT' OR OLD.status IS DISTINCT FROM NEW.status) THEN
        inst_id := df.start(
            format($q$SELECT * FROM poc.process_trigger_item(%s, '{sys_instance_id}')$q$, NEW.id),
            format('poc-trigger-item-%s', NEW.id)
        );

        NEW.workflow_instance_id := inst_id;
        NEW.workflow_started_at := now();
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trigger_items_start_workflow
BEFORE INSERT OR UPDATE OF status ON poc.trigger_items
FOR EACH ROW
EXECUTE FUNCTION poc.trigger_item_start_workflow();

CREATE TEMP TABLE _trigger_expected (
    scenario text NOT NULL,
    item_id bigint NOT NULL,
    instance_id text NOT NULL
);

CREATE TEMP TABLE _trigger_stage_ids (
    item_id bigint PRIMARY KEY
);

WITH inserted AS (
    INSERT INTO poc.trigger_items(status, payload)
    VALUES ('ready', '{"scenario": "insert"}')
    RETURNING id, workflow_instance_id
)
INSERT INTO _trigger_expected(scenario, item_id, instance_id)
SELECT 'insert-ready', id, workflow_instance_id
FROM inserted;

TRUNCATE _trigger_stage_ids;

WITH inserted AS (
    INSERT INTO poc.trigger_items(status, payload)
    VALUES ('staged', '{"scenario": "update"}')
    RETURNING id
)
INSERT INTO _trigger_stage_ids(item_id)
SELECT id
FROM inserted;

WITH updated AS (
    UPDATE poc.trigger_items t
    SET status = 'ready'
    FROM _trigger_stage_ids i
    WHERE t.id = i.item_id
    RETURNING t.id, t.workflow_instance_id
)
INSERT INTO _trigger_expected(scenario, item_id, instance_id)
SELECT 'update-to-ready', id, workflow_instance_id
FROM updated;

DO $$
DECLARE
    before_instances int;
    after_instances int;
BEGIN
    SELECT count(*) INTO before_instances
    FROM df.instances
    WHERE label LIKE 'poc-trigger-item-%';

    BEGIN
        INSERT INTO poc.trigger_items(status, payload)
        VALUES ('ready', '{"scenario": "rollback"}');

        RAISE EXCEPTION 'simulate rollback after trigger-started workflow';
    EXCEPTION WHEN OTHERS THEN
        NULL;
    END;

    PERFORM pg_sleep(1);

    SELECT count(*) INTO after_instances
    FROM df.instances
    WHERE label LIKE 'poc-trigger-item-%';

    IF after_instances != before_instances THEN
        RAISE EXCEPTION 'TEST FAILED: rolled-back trigger start changed instance count before=% after=%',
            before_instances, after_instances;
    END IF;

    IF EXISTS (SELECT 1 FROM poc.trigger_items WHERE payload->>'scenario' = 'rollback') THEN
        RAISE EXCEPTION 'TEST FAILED: rollback trigger item persisted';
    END IF;
END $$;

TRUNCATE _trigger_stage_ids;

WITH inserted AS (
    INSERT INTO poc.trigger_items(status, payload)
    SELECT 'staged', jsonb_build_object('scenario', 'bulk', 'seq', g)
    FROM generate_series(1, 20) AS g
    RETURNING id
)
INSERT INTO _trigger_stage_ids(item_id)
SELECT id
FROM inserted;

WITH updated AS (
    UPDATE poc.trigger_items t
    SET status = 'ready'
    FROM _trigger_stage_ids i
    WHERE t.id = i.item_id
    RETURNING t.id, t.workflow_instance_id
)
INSERT INTO _trigger_expected(scenario, item_id, instance_id)
SELECT 'bulk-update-to-ready', id, workflow_instance_id
FROM updated;

DO $$
DECLARE
    rec record;
    final_status text;
BEGIN
    FOR rec IN SELECT * FROM _trigger_expected LOOP
        IF rec.instance_id IS NULL THEN
            RAISE EXCEPTION 'TEST FAILED: trigger did not attach instance id for item %', rec.item_id;
        END IF;

        SELECT df.wait_for_completion(rec.instance_id, 60) INTO final_status;

        IF final_status != 'completed' THEN
            RAISE EXCEPTION 'TEST FAILED: trigger workflow % for item % status = %',
                rec.instance_id, rec.item_id, final_status;
        END IF;
    END LOOP;
END $$;

UPDATE poc.trigger_items
SET status = 'processed'
WHERE payload->>'scenario' = 'insert';

DO $$
DECLARE
    expected_count int;
    processed_count int;
    log_count int;
    duplicate_count int;
BEGIN
    SELECT count(*) INTO expected_count FROM _trigger_expected;
    SELECT count(*) INTO processed_count FROM poc.trigger_items WHERE status = 'processed';
    SELECT count(*) INTO log_count FROM poc.trigger_workflow_log WHERE event = 'processed';

    SELECT count(*) INTO duplicate_count
    FROM (
        SELECT item_id
        FROM poc.trigger_workflow_log
        GROUP BY item_id
        HAVING count(*) > 1
    ) d;

    IF expected_count != 22 THEN
        RAISE EXCEPTION 'TEST FAILED: expected 22 triggered workflows, got %', expected_count;
    END IF;

    IF processed_count != expected_count THEN
        RAISE EXCEPTION 'TEST FAILED: processed item count % != expected %', processed_count, expected_count;
    END IF;

    IF log_count != expected_count THEN
        RAISE EXCEPTION 'TEST FAILED: workflow log count % != expected %', log_count, expected_count;
    END IF;

    IF duplicate_count != 0 THEN
        RAISE EXCEPTION 'TEST FAILED: found duplicate workflow logs for % item(s)', duplicate_count;
    END IF;

    INSERT INTO poc.experiment_results(experiment, status, assertion)
    VALUES (
        '100_triggered_workflows',
        'passed',
        jsonb_build_object(
            'triggered_workflows', expected_count,
            'processed_items', processed_count,
            'workflow_logs', log_count,
            'rollback_start_persisted', false,
            'duplicate_item_logs', duplicate_count
        )
    );

    RAISE NOTICE 'TEST PASSED: triggered workflows expected=% processed=% logs=%',
        expected_count, processed_count, log_count;
END $$;

DROP TABLE _trigger_expected;
DROP TABLE _trigger_stage_ids;

RESET SESSION AUTHORIZATION;
