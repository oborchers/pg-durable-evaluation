\set ON_ERROR_STOP on
\pset pager off

SET SESSION AUTHORIZATION poc_runner;

DROP TABLE IF EXISTS poc.deployment_log;
DROP FUNCTION IF EXISTS poc.versioned_worker(text, text);

CREATE TABLE poc.deployment_log (
    id bigserial PRIMARY KEY,
    scenario text NOT NULL,
    instance_id text NOT NULL,
    event text NOT NULL,
    observed_version text,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION poc.versioned_worker(p_scenario text, p_instance_id text)
RETURNS text
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO poc.deployment_log(scenario, instance_id, event, observed_version)
    VALUES (p_scenario, p_instance_id, 'versioned_worker', 'v1');

    RETURN 'v1';
END;
$$;

CREATE TEMP TABLE _deploy_state (
    scenario text PRIMARY KEY,
    instance_id text NOT NULL,
    final_status text
);

INSERT INTO _deploy_state(scenario, instance_id)
SELECT
    'replace_inflight_function',
    df.start(
        'INSERT INTO poc.deployment_log(scenario, instance_id, event)
         VALUES (''replace_inflight_function'', ''{sys_instance_id}'', ''before_versioned_call'')'
        ~> df.sleep(3)
        ~> 'SELECT poc.versioned_worker(''replace_inflight_function'', ''{sys_instance_id}'') AS observed_version',
        'poc-deploy-replace-inflight-function'
    );

DO $$
DECLARE
    inst_id text;
    attempts int := 0;
BEGIN
    SELECT instance_id INTO inst_id
    FROM _deploy_state
    WHERE scenario = 'replace_inflight_function';

    LOOP
        EXIT WHEN EXISTS (
            SELECT 1
            FROM poc.deployment_log
            WHERE scenario = 'replace_inflight_function'
              AND instance_id = inst_id
              AND event = 'before_versioned_call'
        ) OR attempts > 100;

        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF attempts > 100 THEN
        RAISE EXCEPTION 'TEST FAILED: replacement workflow did not reach sleep marker';
    END IF;
END $$;

CREATE OR REPLACE FUNCTION poc.versioned_worker(p_scenario text, p_instance_id text)
RETURNS text
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO poc.deployment_log(scenario, instance_id, event, observed_version)
    VALUES (p_scenario, p_instance_id, 'versioned_worker', 'v2');

    RETURN 'v2';
END;
$$;

DO $$
DECLARE
    inst_id text;
    v_final_status text;
    v_observed_version text;
BEGIN
    SELECT instance_id INTO inst_id
    FROM _deploy_state
    WHERE scenario = 'replace_inflight_function';

    SELECT df.wait_for_completion(inst_id, 45) INTO v_final_status;

    UPDATE _deploy_state
    SET final_status = v_final_status
    WHERE scenario = 'replace_inflight_function';

    SELECT observed_version INTO v_observed_version
    FROM poc.deployment_log
    WHERE scenario = 'replace_inflight_function'
      AND event = 'versioned_worker'
    ORDER BY id DESC
    LIMIT 1;

    IF v_final_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: replacement workflow status = %', v_final_status;
    END IF;

    IF v_observed_version != 'v2' THEN
        RAISE EXCEPTION 'TEST FAILED: expected in-flight workflow to observe v2 after replacement, got %',
            v_observed_version;
    END IF;
END $$;

INSERT INTO _deploy_state(scenario, instance_id)
SELECT
    'drop_inflight_function',
    df.start(
        'INSERT INTO poc.deployment_log(scenario, instance_id, event)
         VALUES (''drop_inflight_function'', ''{sys_instance_id}'', ''before_versioned_call'')'
        ~> df.sleep(3)
        ~> 'SELECT poc.versioned_worker(''drop_inflight_function'', ''{sys_instance_id}'') AS observed_version',
        'poc-deploy-drop-inflight-function'
    );

DO $$
DECLARE
    inst_id text;
    attempts int := 0;
BEGIN
    SELECT instance_id INTO inst_id
    FROM _deploy_state
    WHERE scenario = 'drop_inflight_function';

    LOOP
        EXIT WHEN EXISTS (
            SELECT 1
            FROM poc.deployment_log
            WHERE scenario = 'drop_inflight_function'
              AND instance_id = inst_id
              AND event = 'before_versioned_call'
        ) OR attempts > 100;

        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF attempts > 100 THEN
        RAISE EXCEPTION 'TEST FAILED: drop workflow did not reach sleep marker';
    END IF;
END $$;

DROP FUNCTION poc.versioned_worker(text, text);

DO $$
DECLARE
    inst_id text;
    v_final_status text;
BEGIN
    SELECT instance_id INTO inst_id
    FROM _deploy_state
    WHERE scenario = 'drop_inflight_function';

    SELECT df.wait_for_completion(inst_id, 45) INTO v_final_status;

    UPDATE _deploy_state
    SET final_status = v_final_status
    WHERE scenario = 'drop_inflight_function';

    IF v_final_status NOT IN ('failed', 'completed') THEN
        RAISE EXCEPTION 'TEST FAILED: drop workflow ended with unexpected status %', v_final_status;
    END IF;
END $$;

CREATE OR REPLACE FUNCTION poc.versioned_worker(p_scenario text, p_instance_id text)
RETURNS text
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO poc.deployment_log(scenario, instance_id, event, observed_version)
    VALUES (p_scenario, p_instance_id, 'versioned_worker', 'v1');

    RETURN 'v1';
END;
$$;

INSERT INTO _deploy_state(scenario, instance_id)
SELECT
    'rollback_migration',
    df.start(
        'INSERT INTO poc.deployment_log(scenario, instance_id, event)
         VALUES (''rollback_migration'', ''{sys_instance_id}'', ''before_versioned_call'')'
        ~> df.sleep(3)
        ~> 'SELECT poc.versioned_worker(''rollback_migration'', ''{sys_instance_id}'') AS observed_version',
        'poc-deploy-rollback-migration'
    );

DO $$
DECLARE
    inst_id text;
    attempts int := 0;
BEGIN
    SELECT instance_id INTO inst_id
    FROM _deploy_state
    WHERE scenario = 'rollback_migration';

    LOOP
        EXIT WHEN EXISTS (
            SELECT 1
            FROM poc.deployment_log
            WHERE scenario = 'rollback_migration'
              AND instance_id = inst_id
              AND event = 'before_versioned_call'
        ) OR attempts > 100;

        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF attempts > 100 THEN
        RAISE EXCEPTION 'TEST FAILED: rollback migration workflow did not reach sleep marker';
    END IF;
END $$;

BEGIN;
CREATE OR REPLACE FUNCTION poc.versioned_worker(p_scenario text, p_instance_id text)
RETURNS text
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO poc.deployment_log(scenario, instance_id, event, observed_version)
    VALUES (p_scenario, p_instance_id, 'versioned_worker', 'v3_rolled_back');

    RETURN 'v3_rolled_back';
END;
$$;
ROLLBACK;

SET SESSION AUTHORIZATION poc_runner;

DO $$
DECLARE
    inst_id text;
    v_final_status text;
    v_observed_version text;
BEGIN
    SELECT instance_id INTO inst_id
    FROM _deploy_state
    WHERE scenario = 'rollback_migration';

    SELECT df.wait_for_completion(inst_id, 45) INTO v_final_status;

    UPDATE _deploy_state
    SET final_status = v_final_status
    WHERE scenario = 'rollback_migration';

    SELECT observed_version INTO v_observed_version
    FROM poc.deployment_log
    WHERE scenario = 'rollback_migration'
      AND event = 'versioned_worker'
    ORDER BY id DESC
    LIMIT 1;

    IF v_final_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: rollback migration workflow status = %', v_final_status;
    END IF;

    IF v_observed_version != 'v1' THEN
        RAISE EXCEPTION 'TEST FAILED: expected rollback migration to observe v1, got %',
            v_observed_version;
    END IF;
END $$;

DO $$
DECLARE
    replace_status text;
    drop_status text;
    rollback_status text;
    replace_version text;
    rollback_version text;
BEGIN
    SELECT final_status INTO replace_status
    FROM _deploy_state
    WHERE scenario = 'replace_inflight_function';

    SELECT final_status INTO drop_status
    FROM _deploy_state
    WHERE scenario = 'drop_inflight_function';

    SELECT final_status INTO rollback_status
    FROM _deploy_state
    WHERE scenario = 'rollback_migration';

    SELECT observed_version INTO replace_version
    FROM poc.deployment_log
    WHERE scenario = 'replace_inflight_function'
      AND event = 'versioned_worker'
    ORDER BY id DESC
    LIMIT 1;

    SELECT observed_version INTO rollback_version
    FROM poc.deployment_log
    WHERE scenario = 'rollback_migration'
      AND event = 'versioned_worker'
    ORDER BY id DESC
    LIMIT 1;

    INSERT INTO poc.experiment_results(experiment, status, assertion)
    VALUES (
        '150_migration_deployment',
        CASE WHEN drop_status = 'failed' THEN 'passed_with_caveat' ELSE 'observed' END,
        jsonb_build_object(
            'replace_inflight_status', replace_status,
            'replace_inflight_observed_version', replace_version,
            'drop_inflight_status', drop_status,
            'drop_inflight_failed', drop_status = 'failed',
            'rollback_migration_status', rollback_status,
            'rollback_migration_observed_version', rollback_version
        )
    );

    RAISE NOTICE 'TEST PASSED: migration/deployment replace_version=% drop_status=% rollback_version=%',
        replace_version, drop_status, rollback_version;
END $$;

DROP TABLE _deploy_state;

RESET SESSION AUTHORIZATION;
