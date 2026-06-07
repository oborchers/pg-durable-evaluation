\set ON_ERROR_STOP on
\pset pager off

-- Secret-handling probe.
--
-- Goal: characterize how an API key actually flows through pg_durable when a
-- workflow calls an authenticated endpoint, and where the secret comes to rest.
-- Uses a unique sentinel token (never a real key) against httpbingo.org/bearer
-- (allowlisted in the http-allow-test-domains build), then scans pg_durable's
-- own schemas for the resolved secret and for the {agent_key} placeholder.
--
-- The substitution proof does NOT depend on the endpoint's response code (the
-- public httpbingo instance is occasionally flaky): it is proven by the resolved
-- key appearing in duroxide runtime history, which records the materialized
-- request input the worker sent.
--
-- Note: df.secrets / df.setsecret do NOT exist in this build (specced as T11 in
-- the security model, not implemented), so df.setvar is the only persistent
-- in-DB mechanism available. This probe records that fact too.

SET SESSION AUTHORIZATION poc_runner;

DROP TABLE IF EXISTS poc.secret_probe;
DROP TABLE IF EXISTS poc.secret_leak_findings;

CREATE TABLE poc.secret_probe (
    id bigserial PRIMARY KEY,
    http_status int,
    ok boolean
);

CREATE TABLE poc.secret_leak_findings (
    id bigserial PRIMARY KEY,
    marker text NOT NULL,      -- 'resolved_secret' or 'placeholder'
    surface text NOT NULL,     -- schema.table.column where the value was found
    sample text
);

SELECT df.clearvars();
SELECT df.setvar('agent_key', 'PGD-SECRET-PROBE-7Q2X');

CREATE TEMP TABLE _state(instance_id text);

-- The secret is referenced as {agent_key} in the header config and resolved by
-- the worker at execution time. The recording node only stores the status and
-- ok flag, so an empty or non-JSON body cannot fail the workflow.
INSERT INTO _state
SELECT df.start(
    df.http(
        'https://httpbingo.org/bearer',
        'GET',
        NULL,
        '{"Authorization": "Bearer {agent_key}"}'::jsonb,
        30
    ) |=> 'resp'
    ~> $$INSERT INTO poc.secret_probe(http_status, ok)
        SELECT ($resp::jsonb->>'status')::int,
               ($resp::jsonb->>'ok')::boolean$$,
    'poc-secret-handling'
);

DO $$
DECLARE
    inst_id text;
    final_status text;
    probe poc.secret_probe%ROWTYPE;
BEGIN
    SELECT instance_id INTO inst_id FROM _state;
    SELECT df.wait_for_completion(inst_id, 60) INTO final_status;
    SELECT * INTO probe FROM poc.secret_probe ORDER BY id DESC LIMIT 1;

    IF final_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: secret-handling workflow status = %', final_status;
    END IF;

    RAISE NOTICE 'workflow completed: http_status=% ok=%', probe.http_status, probe.ok;
END $$;

DROP TABLE _state;

RESET SESSION AUTHORIZATION;

-- Leak scan as superuser: bypasses RLS on df.vars and can see duroxide.* runtime
-- state. Scan every text/json column in the df and duroxide schemas for the
-- resolved sentinel and, separately, for the {agent_key} placeholder.
DO $scan$
DECLARE
    rec record;
    pattern text;
    sample_text text;
    marker text;
    patterns text[] := ARRAY['PGD-SECRET-PROBE-7Q2X', '{agent_key}'];
    markers text[]  := ARRAY['resolved_secret', 'placeholder'];
    i int;
BEGIN
    FOR i IN 1..array_length(patterns, 1) LOOP
        pattern := '%' || patterns[i] || '%';
        marker  := markers[i];

        FOR rec IN
            SELECT c.table_schema AS sch, c.table_name AS tab, c.column_name AS col
            FROM information_schema.columns c
            JOIN information_schema.tables t
              ON t.table_schema = c.table_schema
             AND t.table_name = c.table_name
            WHERE c.table_schema IN ('df', 'duroxide')
              AND t.table_type = 'BASE TABLE'
              AND c.data_type IN ('text', 'character varying', 'character', 'name', 'json', 'jsonb')
        LOOP
            BEGIN
                EXECUTE format(
                    'SELECT (%1$I)::text FROM %2$I.%3$I WHERE (%1$I)::text LIKE %4$L LIMIT 1',
                    rec.col, rec.sch, rec.tab, pattern
                ) INTO sample_text;

                IF sample_text IS NOT NULL THEN
                    INSERT INTO poc.secret_leak_findings(marker, surface, sample)
                    VALUES (marker, format('%s.%s.%s', rec.sch, rec.tab, rec.col), left(sample_text, 160));
                END IF;
            EXCEPTION WHEN OTHERS THEN
                NULL;  -- skip any column that cannot be cast/queried
            END;
        END LOOP;
    END LOOP;
END $scan$;

-- Record the experiment result as poc_runner, consistent with the other tests.
SET SESSION AUTHORIZATION poc_runner;

DO $$
DECLARE
    probe poc.secret_probe%ROWTYPE;
    resolved_surfaces text[];
    placeholder_surfaces text[];
    vars_plaintext boolean;
    history_has_resolved boolean;
    graph_has_resolved boolean;
    df_secrets_present boolean;
BEGIN
    SELECT * INTO probe FROM poc.secret_probe ORDER BY id DESC LIMIT 1;

    SELECT array_agg(surface ORDER BY surface) INTO resolved_surfaces
    FROM poc.secret_leak_findings WHERE marker = 'resolved_secret';

    SELECT array_agg(surface ORDER BY surface) INTO placeholder_surfaces
    FROM poc.secret_leak_findings WHERE marker = 'placeholder';

    SELECT EXISTS (SELECT 1 FROM poc.secret_leak_findings
                   WHERE marker = 'resolved_secret' AND surface LIKE 'df.vars.%') INTO vars_plaintext;

    SELECT EXISTS (SELECT 1 FROM poc.secret_leak_findings
                   WHERE marker = 'resolved_secret' AND surface LIKE 'duroxide.%') INTO history_has_resolved;

    -- Does the durable graph definition itself bake in the resolved secret?
    SELECT EXISTS (SELECT 1 FROM poc.secret_leak_findings
                   WHERE marker = 'resolved_secret' AND surface LIKE 'df.nodes.%') INTO graph_has_resolved;

    SELECT EXISTS (SELECT 1 FROM pg_proc p
                   JOIN pg_namespace n ON n.oid = p.pronamespace
                   WHERE n.nspname = 'df' AND p.proname = 'setsecret') INTO df_secrets_present;

    -- Headline assertions:
    --   1. the resolved key sits in df.vars in plain text;
    --   2. the resolved key is persisted in duroxide runtime history (proves the
    --      worker materialized the secret into the request and stored it durably).
    IF NOT vars_plaintext THEN
        RAISE EXCEPTION 'TEST FAILED: expected the resolved secret in df.vars (plaintext at rest)';
    END IF;

    IF NOT history_has_resolved THEN
        RAISE EXCEPTION 'TEST FAILED: expected the resolved secret in duroxide runtime history';
    END IF;

    INSERT INTO poc.experiment_results(experiment, status, assertion)
    VALUES (
        '45_secret_handling',
        'passed',
        jsonb_build_object(
            'http_status', probe.http_status,
            'http_ok', probe.ok,
            'df_secrets_feature_present', df_secrets_present,
            'secret_plaintext_in_df_vars', vars_plaintext,
            'secret_persisted_in_runtime_history', history_has_resolved,
            'secret_baked_into_graph_definition', graph_has_resolved,
            'resolved_secret_surfaces', to_jsonb(coalesce(resolved_surfaces, ARRAY[]::text[])),
            'placeholder_surfaces', to_jsonb(coalesce(placeholder_surfaces, ARRAY[]::text[]))
        )
    );

    RAISE NOTICE 'TEST PASSED: secret handling. df.secrets present=% graph_has_resolved=% resolved=% placeholder=%',
        df_secrets_present, graph_has_resolved, resolved_surfaces, placeholder_surfaces;
END $$;

SELECT df.clearvars();

RESET SESSION AUTHORIZATION;
