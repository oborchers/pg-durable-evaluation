# pg_durable Evaluation Summary

`pg_durable` is promising. The PoC ran locally, exercised real workflow patterns, survived a PostgreSQL container restart, and exposed useful SQL-native observability.

It is not friction-free. The first Docker source build was slow, Docker Hub auth mattered, the DSL is quote-sensitive, HTTP has build-time allowlist constraints, and signal timing needs care.

The postgres-http follow-up adds one more important caveat: pg_durable's native HTTP controls apply to `df.http()`, not to every SQL function a workflow role can execute.

The practical follow-up made the tradeoffs sharper: trigger-started workflows worked, modest local load completed, and SQL-level tests are viable. But SQL exceptions did not auto-retry, in-flight workflows picked up replaced SQL function bodies, and waiting for workflows before the submitting transaction commits is a real harness footgun.

After follow-up verification, we also reported two upstream docs/behavior issues and added retry evidence to an existing upstream retry issue.

## Final Verdict

This is worth deeper evaluation, especially for workflows where Postgres already owns the data and where local reproducibility matters.

I would not yet treat it as a universal replacement for Airflow, Temporal, Trigger.dev, ECS Batch, or similar systems. It currently feels strongest for Postgres-centered workflows: async aggregation, queue draining, report generation, database operations, and tightly scoped external API calls.

## Evidence

Final run: `runs/20260607T114327Z`

postgres-http follow-up: `runs/20260607T122843Z-postgres-http`

practical follow-up: `runs/20260607T125709Z-practical`

- version: `0.2.2`
- final instances: 11 completed, 2 intentionally failed security tests, 0 running
- async aggregation: passed
- job dispatch loop: passed
- SQL function calls: passed
- external API simulation: passed
- postgres-http inside pg_durable SQL nodes: passed
- trigger-started workflows: passed
- load/concurrency: 200 single-session workflows in about 8.8s; 160 workflows from 8 concurrent sessions in about 10.1s
- retry semantics: SQL exception did not auto-retry; manual resubmission completed
- transaction semantics: committed starts ran, rolled-back starts did not persist
- DSL testing strategy: SQL assertion helpers worked
- migration/deployment: replacing a function affected an in-flight workflow; dropping a referenced function caused failure
- signal approval: passed with a simplified wait-first pattern
- restart resilience: passed
- HTTP allowlist, bare IP, no-HTTP-grant, and malformed quoting checks: passed
- upstream reports: metrics mismatch issue #213, retry evidence on #155, `df.http()` docs-boundary issue #214

## Most Important Findings

- Local-first scheduling is the standout advantage.
- Durability across restart worked in this PoC.
- SQL-native monitoring is practical and useful.
- HTTP security is intentionally restrictive.
- postgres-http works inside SQL nodes, but bypasses pg_durable's native `df.http()` allowlist.
- Row triggers can start workflows, which makes Postgres-native pub-sub plausible.
- SQL node failures need explicit recovery strategy; the flaky SQL test did not auto-retry, and the verified repro was added to upstream issue #155.
- Workflow code is live database code: in-flight workflows resolve later SQL function calls against the deployed definition at execution time.
- `df.metrics()` disagreed with `df.instances`/`df.list_instances()` because rolled-back starts can leave failed orphan `duroxide.executions` rows; reported upstream as #213.
- Non-2xx HTTP responses require explicit workflow logic.
- DSL quoting is the biggest authoring footgun.
- Signal workflows need more focused testing before relying on complex approval flows.
- No secret store exists in this build (`df.secrets` is specced as T11 but not implemented). `df.setvar` substitution into an Authorization header works, but the resolved key is persisted in plain text in both `df.vars` and `duroxide.history.event_data`; only the placeholder is stored in the graph (`df.nodes`). Verified by `sql/45_secret_handling.sql`.

## Blog Thesis

`pg_durable` is compelling because it makes Postgres itself a durable workflow substrate. That is powerful for database-native jobs, but the cost is that you are now operating a real Postgres extension with background-worker, build-feature, SQL-authoring, and security-policy consequences.

This matters for teams already uneasy about pure-Postgres development workflows. You still need migrations for database code, and extension-level capabilities such as HTTP must be controlled with the same seriousness as application deployments. pg_durable can restrict its own `df.http()` path, but it cannot make a broad outbound-network policy for every other extension installed in the database; we reported that docs-boundary clarification as #214.
