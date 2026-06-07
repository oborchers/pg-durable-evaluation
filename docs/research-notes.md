# Research Notes

Source revision studied: `microsoft/pg_durable@11ac64e3adb64c14386be5c737b3a3806d873fc4`.

Primary sources:

- Website: https://microsoft.github.io/pg_durable/
- Repository: https://github.com/microsoft/pg_durable
- User guide: `vendor/pg_durable/USER_GUIDE.md`
- API reference: `vendor/pg_durable/docs/api-reference.md`
- Scenarios guide: `vendor/pg_durable/docs/SCENARIOS.md`
- Architecture guide: `vendor/pg_durable/docs/ARCHITECTURE.md`
- HTTP security guide: `vendor/pg_durable/docs/http-security.md`
- Agent skill: `vendor/pg_durable/.agents/skills/pg-durable-sql/SKILL.md`
- postgres-http repository: https://github.com/pramsey/pgsql-http

## What pg_durable Is

`pg_durable` is a PostgreSQL extension for durable, long-running SQL workflows. A user session builds a function graph with the `df.*` SQL DSL and starts it with `df.start()`. A PostgreSQL background worker then executes the graph asynchronously and persists orchestration state in ordinary database tables.

The extension is in preview. The upstream `Cargo.toml` currently reports version `0.2.2`, with PostgreSQL 17 as the default build target and PostgreSQL 17/18 called out in the README.

## Core Model

- DSL expressions are text values until `df.start()` persists and enqueues the graph.
- Plain SQL strings auto-wrap into SQL nodes; explicit `df.sql()` is usually unnecessary.
- `~>` runs steps sequentially.
- `&` joins branches in parallel and waits for all branches.
- `|` races branches and returns the first winner.
- `?>` and `!>` express conditionals.
- `@>` creates an infinite loop; `df.loop(body, condition)` supports conditional loops.
- `|=>` captures a result for later substitution via `$name`, `$name.column`, `$name?`, or `$name.*`.
- `df.setvar()` variables are set before `df.start()` and referenced as `{name}`.

## Architecture Notes

- No external orchestrator is required. The worker is loaded through `shared_preload_libraries`.
- User sessions perform graph construction and write `df.instances`, `df.nodes`, and `df.vars`.
- The background worker uses Duroxide/Duroxide-PG and stores runtime state in `duroxide.*`.
- Workflows execute with the submitting PostgreSQL role, not the worker role.
- The worker role must be superuser or otherwise able to bypass RLS so it can process all users' instances.
- Observability is SQL-native through `df.list_instances()`, `df.instance_info()`, `df.instance_nodes()`, `df.instance_executions()`, `df.metrics()`, and `df.result()`.

## Practical Semantics Notes

`df.start()` is transactional. Instances started inside a transaction are not visible to the worker until commit, and rolled-back starts do not persist. This was confirmed both with explicit rollback and with trigger-started workflows.

Do not submit workflows and call `df.wait_for_completion()` inside the same uncommitted transaction. The practical load harness initially did that and the worker could not see the uncommitted instances. The stable pattern is: submit, commit, then wait or poll.

Row triggers can call `df.start()`. The practical trigger test used a `BEFORE INSERT OR UPDATE OF status` trigger to start workflows, store the instance ID on the row, and process insert/update/bulk-update transitions after commit.

No automatic retry was observed for a SQL node that raised an exception. The sequence-backed flaky function failed once and left the workflow failed; manual resubmission completed on the next sequence attempt. A fresh verification repro was posted to upstream issue https://github.com/microsoft/pg_durable/issues/155.

SQL function references are resolved when a SQL node executes, not snapshotted at workflow start. A sleeping workflow observed a replacement function body (`v2`) when its later node ran. Dropping the referenced function before that later node caused the workflow to fail.

The practical run exposed an aggregate observability discrepancy that held up under follow-up verification. `df.metrics()` counts failed rows from `duroxide.executions`, including orphan rows created when `df.start()` is rolled back and the worker later records `Instance ... not found after 5s (transaction may have been rolled back)`. Those rows have no matching `df.instances` entry, so aggregate failed counts can diverge from `df.instances` / `df.list_instances('failed')`. This was reported upstream as https://github.com/microsoft/pg_durable/issues/213.

## HTTP Notes

`df.http()` is compiled behind feature flags:

- no HTTP feature: `df.http()` is disabled
- `http-allow-azure-domains`: Azure service domains only
- `http-allow-test-domains`: Azure domains plus `api.github.com` and `httpbingo.org`
- `http-allow-all`: disables the domain/IP guards and is local-development only

The upstream Dockerfile builds with `http-allow-test-domains`, which is useful for this evaluation because `httpbingo.org` can stand in for an OpenAI/Azure Function transformer endpoint without requiring secrets.

HTTP access also requires PostgreSQL execute privileges on `df.http()`. This PoC creates a non-superuser `poc_runner` role and grants `df.grant_usage('poc_runner', include_http => true)`.

## postgres-http Follow-Up Notes

The follow-up installed the separate PostgreSQL `http` extension from package `postgresql-17-http` in a derived Docker image. Inside the database, `pg_available_extensions` reported installed version `1.7`.

The extension exposes ordinary SQL functions and types, including `http_get()`, `http_post()`, `http((...)::http_request)`, `http_request`, `http_response`, `http_header`, and `http_method`.

Those functions work from inside pg_durable SQL nodes because pg_durable runs ordinary SQL with the submitting role. In the follow-up, postgres-http called both `https://api.github.com/rate_limit` and `https://example.com/` from workflow SQL nodes.

This is separate from pg_durable's `df.http()` security model. The `df.http()` build-time allowlist and `df.http` execute privilege do not govern postgres-http functions. Any production evaluation needs a database-wide policy for which workflow roles can execute other outbound-network-capable extensions. A docs-boundary clarification was reported upstream as https://github.com/microsoft/pg_durable/issues/214.

## Skill-Specific Gotchas

The upstream `pg-durable-sql` skill emphasizes:

- `df.start()` is the only call that executes work.
- Use doubled single quotes inside SQL string nodes.
- Use parentheses to control custom operator grouping.
- Call `df.setvar()` before `df.start()`.
- Do not mix `{var}` pre-start variables with `$result` captures.
- `df.http()` parameters are literal configuration values, although URL/body strings support workflow substitution.
