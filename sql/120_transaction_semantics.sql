\set ON_ERROR_STOP on
\pset pager off

SET SESSION AUTHORIZATION poc_runner;

DROP TABLE IF EXISTS poc.txn_trigger_items CASCADE;
DROP TABLE IF EXISTS poc.txn_semantics_log;

CREATE TABLE poc.txn_semantics_log (
    id bigserial PRIMARY KEY,
    msg text NOT NULL,
    instance_id text,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TEMP TABLE _txn_expected (
    scenario text PRIMARY KEY,
    instance_id text NOT NULL
);

DO $$
DECLARE
    inst_id text;
BEGIN
    inst_id := df.start(
        'INSERT INTO poc.txn_semantics_log(msg, instance_id)
         VALUES (''same_transaction_committed'', ''{sys_instance_id}'')',
        'poc-txn-same-transaction-commit'
    );

    INSERT INTO poc.txn_semantics_log(msg, instance_id)
    VALUES ('same_transaction_instance_id', inst_id);
END $$;

INSERT INTO _txn_expected(scenario, instance_id)
SELECT 'same_transaction_commit', instance_id
FROM poc.txn_semantics_log
WHERE msg = 'same_transaction_instance_id';

DO $$
DECLARE
    inst_id text;
    final_status text;
BEGIN
    SELECT instance_id INTO inst_id
    FROM _txn_expected
    WHERE scenario = 'same_transaction_commit';

    SELECT df.wait_for_completion(inst_id, 30) INTO final_status;

    IF final_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: same-transaction workflow status = %', final_status;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM poc.txn_semantics_log WHERE msg = 'same_transaction_committed') THEN
        RAISE EXCEPTION 'TEST FAILED: same-transaction workflow did not execute after commit';
    END IF;
END $$;

BEGIN;
SELECT df.start(
    'INSERT INTO poc.txn_semantics_log(msg, instance_id)
     VALUES (''explicit_rollback_should_not_run'', ''{sys_instance_id}'')',
    'poc-txn-explicit-rollback'
);
ROLLBACK;

SET SESSION AUTHORIZATION poc_runner;

SELECT pg_sleep(2);

DO $$
DECLARE
    instance_count int;
BEGIN
    SELECT count(*) INTO instance_count
    FROM df.instances
    WHERE label = 'poc-txn-explicit-rollback';

    IF instance_count != 0 THEN
        RAISE EXCEPTION 'TEST FAILED: rolled-back df.start persisted % instance(s)', instance_count;
    END IF;

    IF EXISTS (SELECT 1 FROM poc.txn_semantics_log WHERE msg = 'explicit_rollback_should_not_run') THEN
        RAISE EXCEPTION 'TEST FAILED: rolled-back workflow executed';
    END IF;
END $$;

CREATE TABLE poc.txn_trigger_items (
    id bigserial PRIMARY KEY,
    status text NOT NULL DEFAULT 'ready',
    workflow_instance_id text,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION poc.txn_trigger_start_workflow()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    inst_id text;
BEGIN
    inst_id := df.start(
        'INSERT INTO poc.txn_semantics_log(msg, instance_id)
         VALUES (''trigger_transaction_committed'', ''{sys_instance_id}'')',
        format('poc-txn-trigger-%s', NEW.id)
    );

    NEW.workflow_instance_id := inst_id;
    RETURN NEW;
END;
$$;

CREATE TRIGGER txn_trigger_items_start_workflow
BEFORE INSERT ON poc.txn_trigger_items
FOR EACH ROW
EXECUTE FUNCTION poc.txn_trigger_start_workflow();

WITH inserted AS (
    INSERT INTO poc.txn_trigger_items(status)
    VALUES ('ready')
    RETURNING id, workflow_instance_id
)
INSERT INTO _txn_expected(scenario, instance_id)
SELECT 'trigger_transaction_commit', workflow_instance_id
FROM inserted;

DO $$
DECLARE
    inst_id text;
    final_status text;
BEGIN
    SELECT instance_id INTO inst_id
    FROM _txn_expected
    WHERE scenario = 'trigger_transaction_commit';

    SELECT df.wait_for_completion(inst_id, 30) INTO final_status;

    IF final_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: trigger transaction workflow status = %', final_status;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM poc.txn_semantics_log WHERE msg = 'trigger_transaction_committed') THEN
        RAISE EXCEPTION 'TEST FAILED: trigger transaction workflow did not execute after commit';
    END IF;
END $$;

DO $$
DECLARE
    before_instances int;
    after_instances int;
BEGIN
    SELECT count(*) INTO before_instances
    FROM df.instances
    WHERE label LIKE 'poc-txn-trigger-%';

    BEGIN
        INSERT INTO poc.txn_trigger_items(status)
        VALUES ('ready');

        RAISE EXCEPTION 'simulate rollback of trigger transaction';
    EXCEPTION WHEN OTHERS THEN
        NULL;
    END;

    PERFORM pg_sleep(2);

    SELECT count(*) INTO after_instances
    FROM df.instances
    WHERE label LIKE 'poc-txn-trigger-%';

    IF after_instances != before_instances THEN
        RAISE EXCEPTION 'TEST FAILED: rolled-back trigger transaction changed instance count before=% after=%',
            before_instances, after_instances;
    END IF;
END $$;

DO $$
DECLARE
    expected_count int;
BEGIN
    SELECT count(*) INTO expected_count FROM _txn_expected;

    IF expected_count != 2 THEN
        RAISE EXCEPTION 'TEST FAILED: expected two committed transaction workflows, got %', expected_count;
    END IF;

    INSERT INTO poc.experiment_results(experiment, status, assertion)
    VALUES (
        '130_transaction_semantics',
        'passed',
        jsonb_build_object(
            'same_transaction_commit', true,
            'explicit_rollback_persisted_instance', false,
            'trigger_transaction_commit', true,
            'trigger_transaction_rollback_persisted_instance', false,
            'committed_workflows', expected_count
        )
    );

    RAISE NOTICE 'TEST PASSED: transaction semantics committed_workflows=%', expected_count;
END $$;

DROP TABLE _txn_expected;

RESET SESSION AUTHORIZATION;
