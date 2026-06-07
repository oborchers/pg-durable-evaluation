\set ON_ERROR_STOP on
\pset pager off

CREATE EXTENSION IF NOT EXISTS pg_durable;

CREATE OR REPLACE FUNCTION public.poc_wait_for_worker_ready(p_timeout_secs int DEFAULT 60)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
    attempts int := 0;
    max_attempts int := p_timeout_secs * 10;
    table_exists boolean;
    is_ready boolean;
BEGIN
    LOOP
        SELECT EXISTS (
            SELECT 1
            FROM information_schema.tables
            WHERE table_schema = 'duroxide'
              AND table_name = '_worker_ready'
        ) INTO table_exists;

        IF table_exists THEN
            SELECT EXISTS (
                SELECT 1
                FROM duroxide._worker_ready
                WHERE schema_version >= 1
            ) INTO is_ready;
        ELSE
            is_ready := false;
        END IF;

        EXIT WHEN is_ready OR attempts >= max_attempts;
        PERFORM pg_sleep(0.1);
        attempts := attempts + 1;
    END LOOP;

    IF NOT is_ready THEN
        RAISE EXCEPTION 'pg_durable worker did not become ready after % seconds', p_timeout_secs;
    END IF;
END;
$$;

SELECT public.poc_wait_for_worker_ready(60);

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'poc_runner') THEN
        CREATE ROLE poc_runner LOGIN;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'poc_no_http') THEN
        CREATE ROLE poc_no_http LOGIN;
    END IF;
END $$;

SELECT df.grant_usage('poc_runner', include_http => true);
SELECT df.grant_usage('poc_no_http', include_http => false);
GRANT USAGE, CREATE ON SCHEMA public TO poc_runner;
GRANT USAGE, CREATE ON SCHEMA public TO poc_no_http;

DROP SCHEMA IF EXISTS poc CASCADE;
CREATE SCHEMA poc AUTHORIZATION poc_runner;

SET SESSION AUTHORIZATION poc_runner;

CREATE TABLE poc.experiment_results (
    id bigserial PRIMARY KEY,
    experiment text NOT NULL,
    instance_id text,
    status text NOT NULL,
    assertion jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE poc.events (
    id bigserial PRIMARY KEY,
    kind text NOT NULL,
    user_id int,
    amount numeric(12, 2) NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now(),
    processed_at timestamptz
);

CREATE TABLE poc.metric_snapshots (
    id bigserial PRIMARY KEY,
    user_count int NOT NULL,
    paid_order_count int NOT NULL,
    revenue numeric(12, 2) NOT NULL,
    source text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE poc.jobs (
    id bigserial PRIMARY KEY,
    kind text NOT NULL,
    payload jsonb NOT NULL,
    priority int NOT NULL DEFAULT 0,
    status text NOT NULL DEFAULT 'pending',
    attempts int NOT NULL DEFAULT 0,
    result jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    started_at timestamptz,
    completed_at timestamptz
);

CREATE TABLE poc.job_audit (
    id bigserial PRIMARY KEY,
    job_id bigint NOT NULL REFERENCES poc.jobs(id),
    event text NOT NULL,
    detail jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE poc.report_requests (
    id bigserial PRIMARY KEY,
    report_name text NOT NULL,
    status text NOT NULL DEFAULT 'queued',
    total_amount numeric(12, 2),
    created_at timestamptz NOT NULL DEFAULT now(),
    completed_at timestamptz
);

CREATE TABLE poc.api_transforms (
    id bigserial PRIMARY KEY,
    input_text text NOT NULL,
    status text NOT NULL DEFAULT 'queued',
    response jsonb,
    transformed_text text,
    created_at timestamptz NOT NULL DEFAULT now(),
    completed_at timestamptz
);

CREATE TABLE poc.approvals (
    id bigserial PRIMARY KEY,
    amount numeric(12, 2) NOT NULL,
    status text NOT NULL DEFAULT 'needs_review',
    decision jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    decided_at timestamptz
);

CREATE TABLE poc.restart_probe (
    id bigserial PRIMARY KEY,
    marker text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO poc.events(kind, user_id, amount, created_at) VALUES
    ('signup', 1, 0, now() - interval '3 hours'),
    ('signup', 2, 0, now() - interval '2 hours'),
    ('signup', 3, 0, now() - interval '1 hour'),
    ('paid_order', 1, 49.00, now() - interval '58 minutes'),
    ('paid_order', 2, 149.00, now() - interval '50 minutes'),
    ('paid_order', 3, 29.50, now() - interval '45 minutes'),
    ('failure', 2, 0, now() - interval '30 minutes');

INSERT INTO poc.jobs(kind, payload, priority) VALUES
    ('email', '{"to": "alice@example.com", "template": "welcome"}', 10),
    ('report', '{"name": "daily-revenue"}', 5),
    ('webhook', '{"target": "crm", "entity": "customer"}', 8);

INSERT INTO poc.api_transforms(input_text) VALUES
    ('summarize: pg_durable keeps workflow state in postgres');

INSERT INTO poc.approvals(amount) VALUES
    (1250.00);

CREATE OR REPLACE FUNCTION poc.dispatch_next_job()
RETURNS TABLE(job_id bigint, kind text, outcome text)
LANGUAGE plpgsql
AS $$
DECLARE
    picked poc.jobs%ROWTYPE;
BEGIN
    SELECT *
    INTO picked
    FROM poc.jobs
    WHERE status = 'pending'
    ORDER BY priority DESC, id
    LIMIT 1
    FOR UPDATE SKIP LOCKED;

    IF picked.id IS NULL THEN
        RETURN;
    END IF;

    UPDATE poc.jobs
    SET status = 'running',
        attempts = attempts + 1,
        started_at = now()
    WHERE id = picked.id;

    INSERT INTO poc.job_audit(job_id, event, detail)
    VALUES (picked.id, 'started', jsonb_build_object('kind', picked.kind));

    UPDATE poc.jobs
    SET status = 'completed',
        completed_at = now(),
        result = jsonb_build_object('handled_by', 'pg_durable', 'kind', picked.kind)
    WHERE id = picked.id;

    INSERT INTO poc.job_audit(job_id, event, detail)
    VALUES (picked.id, 'completed', jsonb_build_object('attempt', picked.attempts + 1));

    RETURN QUERY SELECT picked.id, picked.kind, 'completed'::text;
END;
$$;

CREATE OR REPLACE FUNCTION poc.create_report_request(p_report_name text)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
    new_id bigint;
BEGIN
    INSERT INTO poc.report_requests(report_name, status)
    VALUES (p_report_name, 'running')
    RETURNING id INTO new_id;

    RETURN new_id;
END;
$$;

CREATE OR REPLACE FUNCTION poc.finish_report_request(p_report_id bigint)
RETURNS TABLE(report_id bigint, total_amount numeric, status text)
LANGUAGE plpgsql
AS $$
DECLARE
    total numeric(12, 2);
BEGIN
    SELECT COALESCE(sum(amount), 0)
    INTO total
    FROM poc.events
    WHERE kind = 'paid_order';

    UPDATE poc.report_requests
    SET status = 'completed',
        total_amount = total,
        completed_at = now()
    WHERE id = p_report_id;

    RETURN QUERY SELECT p_report_id, total, 'completed'::text;
END;
$$;

RESET SESSION AUTHORIZATION;

SELECT 'TEST PASSED: setup' AS result;
