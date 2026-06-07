\set ON_ERROR_STOP on
\pset pager off

SET SESSION AUTHORIZATION poc_runner;

DROP SEQUENCE IF EXISTS poc.retry_attempt_seq;
DROP TABLE IF EXISTS poc.retry_observations;

CREATE SEQUENCE poc.retry_attempt_seq START 1;

CREATE TABLE poc.retry_observations (
    id bigserial PRIMARY KEY,
    scenario text NOT NULL,
    instance_id text NOT NULL,
    final_status text NOT NULL,
    attempts_after int NOT NULL,
    result_text text,
    failed_node_count int,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION poc.flaky_sequence(p_success_on int)
RETURNS TABLE(attempt int, outcome text)
LANGUAGE plpgsql
AS $$
DECLARE
    current_attempt int;
BEGIN
    current_attempt := nextval('poc.retry_attempt_seq')::int;

    IF current_attempt < p_success_on THEN
        RAISE EXCEPTION 'intentional flaky failure on attempt %, succeeds on attempt %',
            current_attempt, p_success_on;
    END IF;

    RETURN QUERY SELECT current_attempt, 'succeeded'::text;
END;
$$;

CREATE TEMP TABLE _retry_state (
    scenario text PRIMARY KEY,
    instance_id text NOT NULL,
    final_status text,
    attempts_after int,
    result_text text,
    failed_node_count int
);

INSERT INTO _retry_state(scenario, instance_id)
SELECT 'native_flaky_sql_node',
       df.start('SELECT * FROM poc.flaky_sequence(2)', 'poc-retry-native-flaky-sql');

DO $$
DECLARE
    inst_id text;
    v_final_status text;
    v_attempts_after int;
    v_result_text text;
    v_failed_node_count int;
BEGIN
    SELECT instance_id INTO inst_id
    FROM _retry_state
    WHERE scenario = 'native_flaky_sql_node';

    SELECT df.wait_for_completion(inst_id, 45) INTO v_final_status;
    SELECT last_value::int INTO v_attempts_after FROM poc.retry_attempt_seq;

    BEGIN
        SELECT df.result(inst_id) INTO v_result_text;
    EXCEPTION WHEN OTHERS THEN
        v_result_text := SQLERRM;
    END;

    SELECT count(*) INTO v_failed_node_count
    FROM df.instance_nodes(inst_id, 5)
    WHERE status = 'failed';

    UPDATE _retry_state
    SET final_status = v_final_status,
        attempts_after = v_attempts_after,
        result_text = v_result_text,
        failed_node_count = v_failed_node_count
    WHERE scenario = 'native_flaky_sql_node';

    INSERT INTO poc.retry_observations(
        scenario,
        instance_id,
        final_status,
        attempts_after,
        result_text,
        failed_node_count
    )
    VALUES (
        'native_flaky_sql_node',
        inst_id,
        v_final_status,
        v_attempts_after,
        v_result_text,
        v_failed_node_count
    );

    IF v_final_status NOT IN ('completed', 'failed') THEN
        RAISE EXCEPTION 'TEST FAILED: flaky workflow ended with unexpected status %', v_final_status;
    END IF;
END $$;

INSERT INTO _retry_state(scenario, instance_id)
SELECT
    'manual_resubmission_after_failure',
    df.start(
        'SELECT * FROM poc.flaky_sequence(2)',
        'poc-retry-manual-resubmit'
    )
WHERE (
    SELECT final_status
    FROM _retry_state
    WHERE scenario = 'native_flaky_sql_node'
) = 'failed';

DO $$
DECLARE
    native_status text;
    manual_inst_id text;
    manual_status text;
    attempts_after int;
    result_text text;
    failed_node_count int;
BEGIN
    SELECT final_status INTO native_status
    FROM _retry_state
    WHERE scenario = 'native_flaky_sql_node';

    IF native_status = 'failed' THEN
        SELECT instance_id INTO manual_inst_id
        FROM _retry_state
        WHERE scenario = 'manual_resubmission_after_failure';

        SELECT df.wait_for_completion(manual_inst_id, 45) INTO manual_status;
        SELECT last_value::int INTO attempts_after FROM poc.retry_attempt_seq;

        BEGIN
            SELECT df.result(manual_inst_id) INTO result_text;
        EXCEPTION WHEN OTHERS THEN
            result_text := SQLERRM;
        END;

        SELECT count(*) INTO failed_node_count
        FROM df.instance_nodes(manual_inst_id, 5)
        WHERE status = 'failed';

        IF manual_status != 'completed' THEN
            RAISE EXCEPTION 'TEST FAILED: manual resubmission status = %', manual_status;
        END IF;
    ELSE
        manual_inst_id := (SELECT instance_id FROM _retry_state WHERE scenario = 'native_flaky_sql_node');
        manual_status := 'not_needed';
        SELECT last_value::int INTO attempts_after FROM poc.retry_attempt_seq;
        result_text := 'native workflow completed without manual resubmission';
        failed_node_count := 0;
    END IF;

    INSERT INTO poc.retry_observations(
        scenario,
        instance_id,
        final_status,
        attempts_after,
        result_text,
        failed_node_count
    )
    VALUES (
        'manual_resubmission_after_failure',
        manual_inst_id,
        manual_status,
        attempts_after,
        result_text,
        failed_node_count
    );
END $$;

DO $$
DECLARE
    native poc.retry_observations%ROWTYPE;
    manual poc.retry_observations%ROWTYPE;
BEGIN
    SELECT * INTO native
    FROM poc.retry_observations
    WHERE scenario = 'native_flaky_sql_node';

    SELECT * INTO manual
    FROM poc.retry_observations
    WHERE scenario = 'manual_resubmission_after_failure';

    IF native.final_status = 'completed' AND native.attempts_after < 2 THEN
        RAISE EXCEPTION 'TEST FAILED: completed flaky workflow without enough attempts: %', row_to_json(native);
    END IF;

    IF native.final_status = 'failed' AND manual.final_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: failed native workflow was not recoverable by manual resubmission';
    END IF;

    INSERT INTO poc.experiment_results(experiment, status, assertion)
    VALUES (
        '120_retry_semantics',
        CASE
            WHEN native.final_status = 'completed' THEN 'passed'
            ELSE 'passed_with_caveat'
        END,
        jsonb_build_object(
            'native_final_status', native.final_status,
            'attempts_after_native', native.attempts_after,
            'automatic_retry_observed', native.final_status = 'completed',
            'manual_resubmission_status', manual.final_status,
            'attempts_after_manual_phase', manual.attempts_after,
            'native_failed_node_count', native.failed_node_count
        )
    );

    RAISE NOTICE 'TEST PASSED: retry semantics native_status=% attempts=% manual_status=%',
        native.final_status, native.attempts_after, manual.final_status;
END $$;

DROP TABLE _retry_state;

RESET SESSION AUTHORIZATION;
