# pg_durable Evaluation

Independent local evaluation of Microsoft's `pg_durable` PostgreSQL extension as a Postgres-native durable workflow/job engine.

This is a public companion repo for a technical blog post. It records what worked, what failed, and what needs more scrutiny before production use.

The harness builds the upstream extension from a pinned source checkout, runs it in Docker, and executes SQL scenarios that cover:

- asynchronous fan-out aggregation
- job dispatch and SQL function calls
- durable variables and result substitution
- HTTP/API calls that simulate an AI transformer step
- signal-driven human approval
- restart resilience across a PostgreSQL container restart
- trigger-started workflows, transaction semantics, load/concurrency, retry behavior, DSL test strategy, and migration/deployment hazards
- observability and developer-experience notes for a future technical blog post

## Headline Findings

- `pg_durable` is promising for Postgres-centered workflows where the database already owns the state.
- Local Docker execution worked, including a restart-resilience probe.
- Triggers can start workflows, which makes Postgres-native row-state orchestration plausible.
- The SQL DSL is powerful but quote-sensitive, so SQL-level tests matter.
- SQL node failures did not auto-retry in the tested flaky-function scenario.
- In-flight workflows call the SQL function body that exists when the node executes, not the body that existed when the workflow started.
- `df.http()` has a restrictive native HTTP security model, but it does not govern arbitrary HTTP-capable SQL extensions such as `postgres-http`.
- `df.metrics()` can overcount failed instances after rolled-back starts because lower-level orphan execution rows are counted.
- There is no built-in secret store (`df.secrets` is specced but not implemented in this build). `df.setvar` substitutes a key into request headers, but the resolved key is persisted in plain text in `df.vars` and in `duroxide.history.event_data` (runtime history). The graph definition (`df.nodes`) stores only the placeholder.

## Quick Start

```bash
./scripts/run_experiments.sh --rebuild
```

After the first build, rerun without `--rebuild`:

```bash
./scripts/run_experiments.sh
```

The runner leaves a PostgreSQL container running as `pg_durable_poc` and writes run artifacts to `runs/<timestamp>/`.

Run the production-adjacent follow-up suite:

```bash
./scripts/run_practical_experiments.sh
```

Connect manually:

```bash
docker exec -it pg_durable_poc psql -U postgres
```

## Current Result

Latest complete run: `runs/20260607T114327Z`.

All planned happy-path experiments passed, and the negative-path tests intentionally produced two failed pg_durable instances for blocked HTTP destinations. Raw run artifacts are local-only and ignored by Git; the distilled evidence is in `summary.md`, `findings.md`, and `EXPERIMENT.md`.

Follow-up postgres-http comparison run: `runs/20260607T122843Z-postgres-http`.

That follow-up installed the separate PostgreSQL `http` extension in a derived image and called it from inside pg_durable SQL nodes. It worked, but it also showed an important security boundary: pg_durable's native `df.http()` allowlist does not govern arbitrary HTTP-capable SQL extensions.

Practical follow-up run: `runs/20260607T125709Z-practical`.

That run tested trigger-started workflows, load/concurrency, retry behavior, transaction semantics, SQL-level DSL tests, and migration/deployment behavior. The most important caveats: SQL exceptions did not auto-retry in this test, workflows started in an uncommitted transaction must not be waited on before commit, and in-flight workflows used the replaced version of a SQL function when the later node executed.

Verified follow-up reports filed upstream:

- metrics mismatch from rolled-back starts: https://github.com/microsoft/pg_durable/issues/213
- retry/backoff evidence added to existing issue: https://github.com/microsoft/pg_durable/issues/155#issuecomment-4642853550
- `df.http()` allowlist scope clarification: https://github.com/microsoft/pg_durable/issues/214

## Repository Contents

- `sql/` contains the individual experiment scenarios.
- `scripts/` contains the Docker-backed runners.
- `docker/postgres-http.Dockerfile` builds the derived image used for the `postgres-http` comparison.
- `summary.md` is the high-level blog-oriented summary.
- `findings.md` is the detailed technical evaluation.
- `EXPERIMENT.md` describes the experiment matrix.
- `docs/research-notes.md` captures source-documentation notes and gotchas.

## Upstream Pin

See `upstream.lock` for the exact source revision used by this PoC. The upstream source is cloned under `vendor/pg_durable/` for local builds and intentionally ignored by Git.

## Notes For Readers

The harness builds from source, so the first run can take several minutes. Docker Hub authentication may matter for base-image pulls. The local image uses pg_durable's test-domain HTTP feature so the scenarios can call public test endpoints without secrets.
