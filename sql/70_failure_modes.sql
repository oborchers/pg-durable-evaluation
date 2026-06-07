\set ON_ERROR_STOP on
\pset pager off

SET SESSION AUTHORIZATION poc_runner;

-- Non-allowlisted external domains should fail under the http-allow-test-domains build.
CREATE TEMP TABLE _bad_domain(instance_id text);

INSERT INTO _bad_domain
SELECT df.start(
    df.http('https://example.com/path', 'GET'),
    'poc-negative-http-domain'
);

DO $$
DECLARE
    inst_id text;
    final_status text;
    node_result text;
BEGIN
    SELECT instance_id INTO inst_id FROM _bad_domain;
    SELECT df.wait_for_completion(inst_id, 30) INTO final_status;

    SELECT result::text INTO node_result
    FROM df.nodes
    WHERE instance_id = inst_id
      AND node_type = 'HTTP';

    IF final_status != 'failed' THEN
        RAISE EXCEPTION 'TEST FAILED: non-allowlisted HTTP domain should fail, got %', final_status;
    END IF;

    IF node_result IS NULL OR node_result NOT ILIKE '%not in the allowed%' THEN
        RAISE EXCEPTION 'TEST FAILED: expected allowlist error, got %', node_result;
    END IF;

    INSERT INTO poc.experiment_results(experiment, instance_id, status, assertion)
    VALUES (
        '70_failure_modes_http_allowlist',
        inst_id,
        'passed',
        jsonb_build_object('status', final_status, 'error_contains', 'not in the allowed')
    );

    RAISE NOTICE 'TEST PASSED: HTTP allowlist rejected example.com instance=%', inst_id;
END $$;

DROP TABLE _bad_domain;

-- Bare IPs should be rejected even when they are public addresses.
CREATE TEMP TABLE _bare_ip(instance_id text);

INSERT INTO _bare_ip
SELECT df.start(
    df.http('https://8.8.8.8/path', 'GET'),
    'poc-negative-bare-ip'
);

DO $$
DECLARE
    inst_id text;
    final_status text;
    node_result text;
BEGIN
    SELECT instance_id INTO inst_id FROM _bare_ip;
    SELECT df.wait_for_completion(inst_id, 30) INTO final_status;

    SELECT result::text INTO node_result
    FROM df.nodes
    WHERE instance_id = inst_id
      AND node_type = 'HTTP';

    IF final_status != 'failed' THEN
        RAISE EXCEPTION 'TEST FAILED: bare IP HTTP destination should fail, got %', final_status;
    END IF;

    IF node_result IS NULL OR node_result NOT ILIKE '%bare IP%' THEN
        RAISE EXCEPTION 'TEST FAILED: expected bare IP error, got %', node_result;
    END IF;

    INSERT INTO poc.experiment_results(experiment, instance_id, status, assertion)
    VALUES (
        '70_failure_modes_bare_ip',
        inst_id,
        'passed',
        jsonb_build_object('status', final_status, 'error_contains', 'bare IP')
    );

    RAISE NOTICE 'TEST PASSED: HTTP bare IP rejected instance=%', inst_id;
END $$;

DROP TABLE _bare_ip;

RESET SESSION AUTHORIZATION;

-- A role with normal pg_durable usage but no HTTP grant should not be able to call df.http().
SET SESSION AUTHORIZATION poc_no_http;

DO $$
DECLARE
    caught boolean := false;
BEGIN
    BEGIN
        PERFORM df.http('https://httpbingo.org/get', 'GET');
    EXCEPTION WHEN insufficient_privilege THEN
        caught := true;
    END;

    IF NOT caught THEN
        RAISE EXCEPTION 'TEST FAILED: poc_no_http unexpectedly called df.http()';
    END IF;

    RAISE NOTICE 'TEST PASSED: no-http role cannot call df.http()';
END $$;

RESET SESSION AUTHORIZATION;

SET SESSION AUTHORIZATION poc_runner;

INSERT INTO poc.experiment_results(experiment, status, assertion)
VALUES (
    '70_failure_modes_http_privilege',
    'passed',
    jsonb_build_object('role', 'poc_no_http', 'blocked_at', 'df.http execute privilege')
);

-- DSL quoting mistakes can fail before pg_durable gets a chance to help.
DO $$
DECLARE
    caught boolean := false;
    message text;
BEGIN
    BEGIN
        EXECUTE $sql$SELECT df.start('SELECT 'pending' AS status', 'poc-negative-bad-quoting')$sql$;
    EXCEPTION WHEN syntax_error THEN
        caught := true;
        message := SQLERRM;
    END;

    IF NOT caught THEN
        RAISE EXCEPTION 'TEST FAILED: malformed nested SQL quote did not raise syntax_error';
    END IF;

    INSERT INTO poc.experiment_results(experiment, status, assertion)
    VALUES (
        '70_failure_modes_dsl_quoting',
        'passed',
        jsonb_build_object('blocked_at', 'SQL parser before df.start', 'message', message)
    );

    RAISE NOTICE 'TEST PASSED: malformed DSL quoting fails before pg_durable can run';
END $$;

RESET SESSION AUTHORIZATION;
