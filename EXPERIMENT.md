# pg_durable Experiment Plan

Date: 2026-06-07

Objective: evaluate `pg_durable` as a locally runnable Postgres-native durable workflow/job engine, with enough rigor and notes to support a technical blog post.

## Situation

Microsoft has released `pg_durable` as an open-source PostgreSQL extension for durable SQL workflows. The promise is attractive for scheduler-heavy use cases: keep orchestration, state, retry visibility, and workflow data in Postgres without running a separate worker fleet, queue, Temporal cluster, Airflow deployment, or cloud-only scheduler.

This PoC evaluates it from four angles:

- technical capability: can it model useful workflows?
- local reproducibility: can it run entirely on a laptop with Docker?
- operability: can we inspect, debug, and recover workflows with SQL?
- developer experience: is the DSL pleasant enough to author and test?

It also evaluates negative cases. The goal is not to rubber-stamp the extension; it is to identify where it is genuinely useful and where it has sharp edges.

## Local Harness

The PoC uses the upstream Dockerfile from `vendor/pg_durable`, which builds PostgreSQL 17 with `pg_durable` and the `http-allow-test-domains` feature. This lets the SQL scenarios call `https://api.github.com` through `df.http()` while preserving the extension's normal HTTP allowlist posture.

The runner:

1. builds `pg_durable_poc:latest` from the pinned upstream checkout
2. starts `pg_durable_poc` on local port `55432`
3. creates a non-superuser `poc_runner`
4. grants pg_durable usage plus HTTP access
5. creates the `poc` schema and sample data
6. runs each SQL experiment
7. restarts the PostgreSQL container for the durability probe
8. writes psql output and logs to `runs/<timestamp>/`

Final evidence run: `runs/20260607T114327Z`.

postgres-http follow-up run: `runs/20260607T122843Z-postgres-http`.

Practical follow-up run: `runs/20260607T125709Z-practical`.

## Experiment Matrix

| ID | Experiment | Question | Artifact | Result |
| --- | --- | --- | --- | --- |
| 00 | Setup and readiness | Can the extension load, initialize the background worker, and run as a non-superuser? | `sql/00_setup.sql`, `sql/01_readiness.sql` | Passed |
| 10 | Async aggregation | Can independent SQL aggregations fan out and fan in without app code? | `sql/10_async_aggregation.sql` | Passed |
| 20 | Dispatching jobs | Can a durable loop dispatch pending jobs until the queue is empty? | `sql/20_dispatch_jobs.sql` | Passed |
| 30 | Calling functions | Can workflows call local SQL/PLpgSQL functions and pass results between steps? | `sql/30_function_calls.sql` | Passed |
| 40 | External API / AI simulation | Can `df.http()` call an external endpoint and persist the result as an async processing step? | `sql/40_http_ai_simulation.sql` | Passed |
| 45 | Secret handling | When a workflow calls an authenticated endpoint, does `df.setvar` substitution reach the wire, and where does the secret come to rest? | `sql/45_secret_handling.sql` | Passed |
| 50 | Signals / approval | Can a workflow pause until an external signal arrives and then branch on the payload? | `sql/50_signal_approval.sql` | Passed, with timing caveat |
| 60 | Restart resilience | Does a sleeping multi-step workflow survive a container restart without re-running completed steps? | `scripts/restart_resilience.sh` | Passed |
| 70 | Failure/security modes | Are unsafe HTTP destinations, missing HTTP grants, and DSL authoring mistakes rejected clearly? | `sql/70_failure_modes.sql` | Passed |
| 80 | Observability | Are status, node history, results, and metrics easy to inspect from SQL? | final snapshot in `scripts/run_experiments.sh` | Passed |
| 90 | postgres-http comparison | Can the separate PostgreSQL `http` extension be called from inside a pg_durable SQL node, and how does that compare with native `df.http()`? | `sql/80_postgres_http_comparison.sql`, `scripts/run_postgres_http_comparison.sh` | Passed |

## Practical Follow-up Experiments

These follow-up experiments focus on production-adjacent behavior rather than feature demos.

| ID | Experiment | Question | Artifact | Result |
| --- | --- | --- | --- | --- |
| 100 | Triggered workflows | Can normal Postgres row triggers start pg_durable workflows on insert/update, and do rolled-back trigger starts disappear? | `sql/90_triggered_workflows.sql` | Passed |
| 110 | Load and concurrency | What happens when many workflows are submitted in a burst and from concurrent client sessions? | `sql/100_load_concurrency.sql`, `sql/101_load_concurrency_verify.sql`, `scripts/run_practical_experiments.sh` | Passed |
| 120 | Retry semantics | Does a failing SQL node automatically retry, and what does manual recovery look like if it does not? | `sql/110_retry_semantics.sql` | Passed with caveat |
| 130 | Transaction semantics | How does `df.start()` behave inside committed, rolled-back, and trigger-driven transactions? | `sql/120_transaction_semantics.sql` | Passed |
| 140 | DSL testing strategy | Can we write reliable SQL-level tests for the DSL without a separate application test framework? | `sql/130_dsl_testing_strategy.sql` | Passed |
| 150 | Migration/deployment workflow | What happens to in-flight workflows when referenced SQL functions are replaced or dropped during execution? | `sql/140_migration_deployment.sql` | Passed with caveat |

## Evidence Summary

The final run recorded:

- pg_durable version: `0.2.2`
- image: `pg_durable_poc:latest`, 452 MB
- total instances: 13
- completed instances: 11
- intentionally failed instances: 2 (`example.com` allowlist rejection, bare-IP rejection)
- running instances after run: 0
- async aggregation elapsed time: about 5.8 seconds for three 2-second branches
- restart probe: exactly one `before_sleep` marker and one `after_sleep` marker after container restart
- postgres-http follow-up: native `df.http()` and SQL-node `http(...)` both called `https://api.github.com/rate_limit` with HTTP 200
- postgres-http follow-up: SQL-node `http_get('https://example.com/')` completed with HTTP 200 even though native `df.http()` blocks `example.com` in the tested build
- practical follow-up: 22 trigger-started workflows completed from insert, update, and bulk update paths; rolled-back trigger starts did not persist
- practical follow-up: 200 single-session burst workflows completed in about 8.8 seconds; 160 workflows submitted from 8 concurrent psql sessions completed in about 10.1 seconds
- practical follow-up: a sequence-backed flaky SQL node failed after one attempt; manual resubmission completed on the second sequence attempt
- practical follow-up: committed `df.start()` calls ran, explicit rollback did not persist an instance, and a rolled-back trigger-started workflow did not persist
- practical follow-up: SQL-level assertion helpers successfully tested graph dry-run behavior, stable graph JSON, result capture, and invalid-node rejection
- practical follow-up: an in-flight workflow observed function version `v2` after `CREATE OR REPLACE FUNCTION`; dropping the function before a later node executed caused that workflow to fail; rolling back a function replacement preserved `v1`
- practical follow-up plus verification: `df.metrics()` counted failed orphan `duroxide.executions` rows left by rolled-back starts, so it diverged from `df.instances` / `df.list_instances('failed')`; reported upstream as https://github.com/microsoft/pg_durable/issues/213

## Known Risks And Findings

- Source-build reproducibility works, but the first Docker build was slow. It pulled large base images, compiled `cargo-pgrx`, compiled the extension in release, then rebuilt an embed binary for SQL generation.
- Docker Hub auth was a real setup issue. Docker reported existing credentials, but pulls failed until login was corrected.
- `df.http()` returns non-2xx responses as completed HTTP nodes with `ok=false`; workflow authors must explicitly branch on HTTP status.
- HTTP capability is a build-time feature, not a runtime setting. Production builds with Azure-only allowlists will not behave like the test build.
- Local/private HTTP endpoints are blocked in the tested configuration. This is good SSRF posture but awkward for local API simulation.
- Installing another HTTP-capable SQL extension changes the security model. pg_durable's `df.http()` allowlist and grants do not restrict ordinary SQL nodes that can execute functions such as `http_get()`.
- The `df.http()` security docs are mostly scoped to native HTTP nodes, but some broader wording could be read as database-wide egress protection; reported as a docs clarification in https://github.com/microsoft/pg_durable/issues/214.
- Workflow source lives in SQL, so real teams need migration, review, rollback, and environment-promotion discipline rather than classic application-only deploys.
- Workflows started inside a transaction become visible after commit. Calling `df.wait_for_completion()` before committing a large submission transaction can self-deadlock the harness because the worker cannot see uncommitted instances.
- SQL node exceptions did not auto-retry in the practical flaky-function test. Recovery required idempotent logic and manual resubmission. A fresh sequence-backed repro was added to https://github.com/microsoft/pg_durable/issues/155.
- In-flight workflows do not snapshot referenced SQL function bodies. Later SQL nodes resolved the function definition present at execution time.
- Dropping a referenced function while a workflow was sleeping caused the later node to fail.
- DSL authoring is quote-sensitive. Some malformed nested SQL fails in the SQL parser before pg_durable can give a domain-specific error.
- Signals are not safe to send before the workflow is truly waiting. A more complex approval shape (`load row -> wait for signal -> branch`) was flaky in testing; the stable path waits first, then branches.
