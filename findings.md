# Findings

Final evidence run: `runs/20260607T114327Z`.

postgres-http follow-up run: `runs/20260607T122843Z-postgres-http`.

Practical follow-up run: `runs/20260607T125709Z-practical`.

Upstream revision: `microsoft/pg_durable@11ac64e3adb64c14386be5c737b3a3806d873fc4`.

Upstream reports from the verified follow-up:

- metrics mismatch from rolled-back starts: https://github.com/microsoft/pg_durable/issues/213
- retry/backoff evidence added to existing issue: https://github.com/microsoft/pg_durable/issues/155#issuecomment-4642853550
- `df.http()` allowlist scope clarification: https://github.com/microsoft/pg_durable/issues/214

## What Worked

`pg_durable` did run fully locally in Docker. After the first image build, the harness started PostgreSQL, loaded the extension, created a non-superuser role, ran all workflows, restarted the container mid-workflow, and collected SQL-native metrics.

The extension handled the core workflow shapes we care about:

- sequential SQL execution
- fan-out/fan-in aggregation with `&`
- loop-based job dispatch with `df.loop(body, condition)`
- local PL/pgSQL function calls
- external JSON API calls through `df.http()`
- external JSON API calls through the separate PostgreSQL `http` extension inside SQL nodes
- row-trigger-started workflows
- burst and multi-session workflow submission
- signal-driven approval
- persisted state across PostgreSQL container restart

The final snapshot showed 13 instances: 11 completed, 2 intentionally failed negative-path HTTP security tests, and 0 running.

The postgres-http follow-up showed that `pg_durable` can run HTTP-capable SQL extension functions inside ordinary SQL nodes. That is useful, but it is not governed by pg_durable's native `df.http()` allowlist.

The practical follow-up added production-adjacent evidence: 22 trigger-started workflows completed, 360 load/concurrency workflows completed, transaction rollback behaved correctly, and SQL-level DSL tests were workable.

The post-run verification refined one important observability caveat: rolled-back starts did not persist in `df.instances`, but the worker can still leave failed orphan rows in `duroxide.executions`. `df.metrics()` counts those lower-level execution rows, which can inflate aggregate failed-instance counts.

## Experiment Results

| Experiment | Result | Evidence |
| --- | --- | --- |
| Readiness | Passed | `poc-readiness` completed and returned `hello pg_durable` |
| Async aggregation | Passed | 3 independent 2-second branches produced users=3, orders=3, revenue=227.50 in about 5.8s |
| Dispatch jobs | Passed | 3 jobs completed and 6 audit rows were written |
| Function calls | Passed | PL/pgSQL report request completed with total_amount=227.50 |
| HTTP/API simulation | Passed | `df.http()` called `api.github.com/rate_limit`, HTTP status 200, row marked completed |
| postgres-http GitHub comparison | Passed | `http(...)` from the PostgreSQL `http` extension called `api.github.com/rate_limit` inside a pg_durable SQL node with HTTP status 200 |
| postgres-http allowlist bypass check | Passed | `http_get('https://example.com/')` completed with HTTP status 200 from a SQL node, even though native `df.http()` rejects `example.com` in the tested build |
| Triggered workflows | Passed | insert, update-to-ready, and 20-row bulk update triggered 22 workflows; rolled-back trigger start did not persist |
| Load: single-session burst | Passed | 200 tiny workflows completed in about 8.8s |
| Load: concurrent sessions | Passed | 8 psql sessions submitted 160 workflows with 50ms SQL-node sleeps; all completed in about 10.1s |
| Retry semantics | Passed with caveat | flaky SQL node failed after one sequence-backed attempt; manual resubmission completed on attempt 2; repro added to upstream issue #155 |
| Transaction semantics | Passed | committed `df.start()` calls ran; explicit rollback and rolled-back trigger start did not persist instances |
| DSL testing strategy | Passed | SQL assertion helpers tested dry-run graph construction, stable graph JSON, captured results, and invalid-node rejection |
| Migration/deployment workflow | Passed with caveat | in-flight workflow observed replaced function version `v2`; dropping referenced function caused failure; rolled-back replacement preserved `v1` |
| Signal approval | Passed | Wait-first approval workflow received signal and updated approval to `approved` |
| Restart resilience | Passed | Container restart during `df.sleep(8)` produced exactly one before and one after marker |
| HTTP allowlist rejection | Passed | `example.com` failed with allowlist error |
| Bare IP rejection | Passed | `https://8.8.8.8/path` failed with bare-IP error |
| HTTP privilege rejection | Passed | role without `df.http` execute privilege could not call `df.http()` |
| DSL quote failure | Passed | malformed nested SQL failed before `df.start()` with parser error |

## Advantages

The biggest advantage is locality. This behaves like a real scheduler/workflow system while staying inside Postgres. For a developer used to ECS Batch, Airflow/Astronomer, Trigger.dev, or similar systems, that is refreshing: no separate scheduler service, queue service, dashboard service, or cloud account was needed for this PoC.

The SQL-native observability is useful. `df.list_instances`, `df.instance_nodes`, `df.result`, and `df.metrics` make it easy to inspect state without learning a separate UI. Failed HTTP nodes preserved useful JSON error details. The caveat is that aggregate metrics need validation because `df.metrics()` can include lower-level orphan executions that `df.instances` does not expose.

Normal Postgres triggers can act as an internal event source. A `BEFORE INSERT OR UPDATE OF status` trigger started workflows, attached instance IDs to rows, and rollback removed both the row and the queued workflow. That makes a Postgres-native pub-sub shape plausible for row-state transitions.

Durability worked in the restart probe. The workflow inserted a marker, slept, the container restarted, and the post-restart marker appeared once. This is the kind of local failure test that is often painful with external workflow systems.

The modest load test was encouraging for local development. It is not a throughput benchmark, but 200 tiny workflows in one burst and 160 workflows from 8 concurrent psql sessions both completed without stuck instances.

The DSL can be tested directly in SQL. The practical suite added small assertion helpers and proved useful checks: graph construction is inert until `df.start()`, identical expressions produce stable graph JSON, captured results can be asserted through table state, and invalid raw graph JSON is rejected with a clear message.

The security posture around HTTP is serious. HTTP requires both build-time allowlist support and explicit function grants. Bare IPs and non-allowlisted domains were blocked.

That security statement is specifically about pg_durable's native `df.http()` path. The postgres-http follow-up is an important qualification: if the database also installs an HTTP-capable SQL extension and the workflow role can execute it, a pg_durable SQL node can call outbound endpoints through that extension.

## Problems And Sharp Edges

First-run setup was not frictionless. Docker Hub auth failed with `401 Unauthorized` until Docker login was corrected. The clean source build also took several minutes because it compiled `cargo-pgrx`, pg_durable, and a pgrx SQL-generation binary. The cached image is much nicer, but the first experience matters.

The DSL is powerful but quote-heavy. Incorrect nested quoting can fail in the PostgreSQL parser before pg_durable can provide a workflow-specific error. This is a real developer-experience cost for anything non-trivial.

Workflow code is database code. That means changes naturally flow through migrations, extension deployment, grants, and database rollout processes rather than classic application deploys. For teams already frustrated by Supabase-style "everything important is in Postgres migrations" workflows, pg_durable will amplify that tradeoff unless paired with disciplined SQL testing and promotion tooling.

In-flight workflows resolve SQL functions at execution time. The migration follow-up started a workflow with a sleep, replaced `poc.versioned_worker()` while it was sleeping, and the later node observed `v2`. Dropping the function before the later node executed caused that workflow to fail. This is a serious deployment concern: changing database code can change or break workflows that are already running.

SQL exceptions did not auto-retry in the flaky-function test. A sequence-backed function failed on attempt 1 and the workflow ended `failed`; a manually resubmitted workflow completed on attempt 2. A fresh verification repro was added to upstream issue #155. The docs use broad language about retries and resume, but for application-level SQL exceptions, teams should assume they need explicit idempotency and recovery workflow until a first-class retry policy is demonstrated.

Transaction boundaries matter. The practical load harness initially submitted many workflows and waited inside the same `DO` transaction; the worker could not see the uncommitted instances. The fixed harness submits and commits first, then waits. Application code should follow the same rule.

HTTP semantics require explicit handling. `df.http()` did not fail a workflow merely because the remote endpoint returned a non-2xx status. During development, `httpbingo.org` returned `402`; pg_durable stored that as a completed HTTP node with `ok=false`, and the workflow had to inspect the status. That is defensible, but authors must know it.

HTTP configuration is build-time. The test image uses `http-allow-test-domains`, while production-style builds may allow only Azure domains. This means local/test/prod parity needs deliberate packaging.

The postgres-http extension creates a parallel HTTP path with a different threat model. In the follow-up, native `df.http()` and postgres-http both reached GitHub's `/rate_limit` endpoint, but postgres-http also reached `https://example.com/` from inside a SQL node. pg_durable cannot enforce its `df.http()` allowlist over arbitrary SQL functions that a workflow role is allowed to execute.

Signals were more subtle than expected. A simple wait-first approval workflow passed. A more complex shape that loaded an approval row before waiting for a signal was flaky and repeatedly timed out even after attempts to detect the signal node. For a blog post, this deserves a focused follow-up test against upstream behavior before recommending signal-heavy human workflows.

The extension requires Postgres extension installation, `shared_preload_libraries`, restart, and privileged setup. That is acceptable for owned databases, but it is not as plug-and-play as an application-level job library.

There is no implemented secret store. The security model designs a `df.secrets` admin-managed store (threat T11) whose resolved values would never enter results, errors, or the graph, but it is marked not implemented, and the build confirms it: `df.secrets` and `df.setsecret` do not exist. The shipped path is `df.setvar`, which the user guide both recommends for "credentials" and warns against ("avoid storing secrets in plain text"). The `45_secret_handling` probe made this concrete. A workflow called `https://httpbingo.org/bearer` with `Authorization: Bearer {agent_key}`, where `{agent_key}` was set via `df.setvar` to a unique sentinel. The substitution reached the wire (proven independently of the endpoint's response code, because the resolved key was recorded in the worker's request input). A sentinel scan across every text and json column in the `df` and `duroxide` schemas found the resolved key in two durable surfaces: `df.vars.value` (plain text at rest) and `duroxide.history.event_data` (runtime history, which records the materialized request). The graph definition `df.nodes.query` stored only the `{agent_key}` placeholder, so resolution does happen at execution time, but the resolved value is then persisted durably in two places, neither encrypted, both included in backups. For production, the practical conclusions are: do not put a real provider key in `df.setvar`; keep the key out of the database behind an internal endpoint, or store it encrypted (Supabase Vault, `pgcrypto`) and resolve it inside the node at execution time via a `SECURITY DEFINER` function; and treat the runtime-history persistence as a real consideration until a first-class secret store ships.

One observability inconsistency appeared in the practical run and held up under follow-up verification. `df.metrics()` counts failed `duroxide.executions` rows, including orphan rows from rolled-back starts whose output says `Instance ... not found after 5s (transaction may have been rolled back)`. Those rows have no matching `df.instances` row, so `df.metrics()` can report more failed instances than `df.instances` / `df.list_instances('failed')`. This was reported upstream as #213.

## Developer Experience

Good:

- Workflows can be written as SQL and run from `psql`.
- Results and node-level state are queryable.
- Local Docker execution works.
- Non-superuser workflow execution worked after `df.grant_usage`.
- Trigger-started workflow tests can be written entirely in SQL.
- SQL-level assertion helpers are enough for many DSL tests.
- The upstream agent skill is genuinely useful for remembering DSL rules.

Rough:

- First build latency is high.
- The DSL is hard to author without tests because operators and nested SQL strings are easy to misquote.
- Workflow changes are migration-shaped database deployments, not normal app releases.
- Running workflows are sensitive to later database-function migrations.
- `df.start()` and `df.wait_for_completion()` must be separated by a commit when testing or submitting from explicit transactions.
- No automatic retry was observed for a failing SQL node.
- Shell probes are error-prone because `$result` variables collide with shell expansion.
- Signals need careful sequencing.
- HTTP allowlists are secure but make local mock API testing harder unless using the special test build.
- postgres-http is easy to call from SQL, but it increases policy complexity because it sits outside pg_durable's native HTTP controls.
- `df.metrics()` can overcount failed workflow instances after rolled-back starts because it includes orphan failed execution rows.

## Blog Angle

The honest headline is not “Postgres replaces every scheduler.” It is closer to:

> pg_durable is compelling when your workflow state already belongs in Postgres, but it inherits the operational seriousness of a Postgres extension and the authoring sharp edges of a SQL-string DSL.

Best-fit use cases from this PoC:

- database maintenance workflows
- async aggregation/reporting
- queue draining where jobs are rows
- database-local ETL
- occasional external API calls with explicit status handling
- local-first experiments where avoiding external scheduler infrastructure matters

Poorer fits or open questions:

- high-volume external API orchestration with complex retries and rate limits
- workflows requiring rich typed SDK ergonomics
- workflows that need built-in retry/backoff semantics unless those are added or proven separately
- teams without control over Postgres extension installation
- teams that cannot safely coordinate database migrations with in-flight workflow behavior
- signal-heavy workflows until signal timing semantics are tested more deeply
- local HTTP mocks under production-like HTTP allowlists
- deployments where other HTTP-capable SQL extensions are installed without a clear outbound-network policy
- alerting based solely on `df.metrics().failed_instances` until the orphan execution mismatch is fixed or documented

## postgres-http Follow-Up

The follow-up built a derived image, `pg_durable_poc:http`, from the working `pg_durable_poc:latest` image and installed the Debian package `postgresql-17-http`. The database extension reported version `1.7`.

The comparison used three workflow instances:

- native `df.http()` to `https://api.github.com/rate_limit`: completed with HTTP 200
- postgres-http `http((...)::http_request)` inside a pg_durable SQL node to `https://api.github.com/rate_limit`: completed with HTTP 200
- postgres-http `http_get('https://example.com/')` inside a pg_durable SQL node: completed with HTTP 200

The result is technically positive but security-relevant. pg_durable SQL nodes can execute normal SQL functions, so postgres-http works as expected. But that also means pg_durable's `df.http()` allowlist and `df.http` execute grants are not a complete outbound HTTP policy for the database.

The docs-boundary clarification for this was filed as https://github.com/microsoft/pg_durable/issues/214.

## Practical Follow-Up

The practical run used `scripts/run_practical_experiments.sh` and wrote artifacts to `runs/20260607T125709Z-practical`.

What it showed:

- Triggered workflows: a row trigger can call `df.start()`, attach the instance ID to the row, and process insert/update/bulk-update transitions. Rolled-back trigger starts did not persist.
- Load/concurrency: 200 single-session workflows completed in about 8.8s; 160 workflows submitted from 8 concurrent psql sessions completed in about 10.1s.
- Retry: a failing SQL node did not auto-retry. Manual resubmission worked because the function was idempotent enough to succeed on the next sequence attempt.
- Transactions: committed starts ran; explicit rollback and rolled-back trigger starts did not persist.
- DSL tests: plain SQL assertion helpers were sufficient for graph-shape and execution assertions.
- Migration/deployment: replacing a SQL function affected an in-flight workflow; dropping a referenced function caused a later node to fail.
- Metrics: rolled-back starts can leave orphan failed `duroxide.executions` rows that inflate `df.metrics()` versus `df.instances`; reported upstream as #213.

The most practical conclusion is that pg_durable can be driven from Postgres events, but production use needs a serious database-deployment story. Workflows are durable, but the SQL they call is live database code.
