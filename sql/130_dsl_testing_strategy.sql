\set ON_ERROR_STOP on
\pset pager off

SET SESSION AUTHORIZATION poc_runner;

DROP TABLE IF EXISTS poc.dsl_test_observations;

CREATE TABLE poc.dsl_test_observations (
    id bigserial PRIMARY KEY,
    kind text NOT NULL,
    detail jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION poc.assert_true(p_condition boolean, p_message text)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    IF coalesce(p_condition, false) IS NOT TRUE THEN
        RAISE EXCEPTION 'ASSERTION FAILED: %', p_message;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION poc.assert_eq_text(p_actual text, p_expected text, p_message text)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_actual IS DISTINCT FROM p_expected THEN
        RAISE EXCEPTION 'ASSERTION FAILED: % actual=% expected=%', p_message, p_actual, p_expected;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION poc.wait_completed(p_instance_id text, p_timeout_secs int DEFAULT 30)
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
    final_status text;
BEGIN
    SELECT df.wait_for_completion(p_instance_id, p_timeout_secs) INTO final_status;

    IF final_status != 'completed' THEN
        RAISE EXCEPTION 'instance % ended with status %', p_instance_id, final_status;
    END IF;

    RETURN final_status;
END;
$$;

DO $$
DECLARE
    graph text;
    graph_2 text;
    invalid_rejected boolean := false;
    invalid_message text;
BEGIN
    graph := 'INSERT INTO poc.dsl_test_observations(kind, detail)
              VALUES (''dry_run_executed'', ''{"source": "df.start"}''::jsonb)';

    PERFORM poc.assert_true(
        NOT EXISTS (SELECT 1 FROM poc.dsl_test_observations WHERE kind = 'dry_run_executed'),
        'constructing a SQL string graph should not execute it'
    );

    graph := 'SELECT 1' ~> 'SELECT 2';
    graph_2 := 'SELECT 1' ~> 'SELECT 2';

    PERFORM poc.assert_eq_text(
        graph::jsonb->>'node_type',
        'THEN',
        'sequence operator should produce a THEN node'
    );

    PERFORM poc.assert_eq_text(
        graph,
        graph_2,
        'identical DSL expressions should produce stable graph JSON'
    );
END $$;

CREATE TEMP TABLE _dsl_state (
    scenario text PRIMARY KEY,
    instance_id text NOT NULL
);

INSERT INTO _dsl_state(scenario, instance_id)
SELECT
    'dry_run_boundary',
    df.start(
        'INSERT INTO poc.dsl_test_observations(kind, detail)
         VALUES (''dry_run_executed'', ''{"source": "df.start"}''::jsonb)',
        'poc-dsl-test-dry-run-boundary'
    );

DO $$
DECLARE
    inst_id text;
BEGIN
    SELECT instance_id INTO inst_id
    FROM _dsl_state
    WHERE scenario = 'dry_run_boundary';

    PERFORM poc.wait_completed(inst_id, 30);

    PERFORM poc.assert_true(
        EXISTS (SELECT 1 FROM poc.dsl_test_observations WHERE kind = 'dry_run_executed'),
        'df.start should execute the previously inert graph'
    );
END $$;

INSERT INTO _dsl_state(scenario, instance_id)
SELECT
    'captured_result',
    df.start(
        ('SELECT 42 AS answer' |=> 'answer')
        ~> 'INSERT INTO poc.dsl_test_observations(kind, detail)
            VALUES (''captured_result'', jsonb_build_object(''answer'', $answer))',
        'poc-dsl-test-captured-result'
    );

DO $$
DECLARE
    inst_id text;
    invalid_rejected boolean := false;
    invalid_message text;
BEGIN
    SELECT instance_id INTO inst_id
    FROM _dsl_state
    WHERE scenario = 'captured_result';

    PERFORM poc.wait_completed(inst_id, 30);

    PERFORM poc.assert_true(
        EXISTS (
            SELECT 1
            FROM poc.dsl_test_observations
            WHERE kind = 'captured_result'
              AND detail->>'answer' = '42'
        ),
        'captured result should be available to downstream SQL'
    );

    BEGIN
        PERFORM df.start('{"node_type":"NOT_A_NODE"}', 'poc-dsl-test-invalid-node');
    EXCEPTION WHEN OTHERS THEN
        invalid_rejected := true;
        invalid_message := SQLERRM;
    END;

    PERFORM poc.assert_true(
        invalid_rejected,
        'invalid raw graph JSON should be rejected by df.start'
    );

    INSERT INTO poc.experiment_results(experiment, status, assertion)
    VALUES (
        '140_dsl_testing_strategy',
        'passed',
        jsonb_build_object(
            'sql_assert_helpers', true,
            'dry_run_graph_construction', true,
            'stable_graph_json', true,
            'captured_result_asserted', true,
            'invalid_node_rejected', invalid_rejected,
            'invalid_node_message', invalid_message
        )
    );

    RAISE NOTICE 'TEST PASSED: DSL testing strategy helpers and assertions worked';
END $$;

DROP TABLE _dsl_state;

RESET SESSION AUTHORIZATION;
