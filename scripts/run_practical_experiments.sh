#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM_DIR="$ROOT_DIR/vendor/pg_durable"
IMAGE_NAME="${PGD_POC_IMAGE:-pg_durable_poc:latest}"
CONTAINER_NAME="${PGD_PRACTICAL_CONTAINER:-pg_durable_poc_practical}"
HOST_PORT="${PGD_PRACTICAL_PORT:-55434}"
RUN_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$ROOT_DIR/runs/$RUN_STAMP-practical"

FORCE_REBUILD=false
KEEP_RUNNING=true
CONCURRENCY_WORKERS="${PGD_POC_CONCURRENCY_WORKERS:-8}"
CONCURRENCY_PER_WORKER="${PGD_POC_CONCURRENCY_PER_WORKER:-20}"
CONCURRENCY_SLEEP_MS="${PGD_POC_CONCURRENCY_SLEEP_MS:-50}"

usage() {
    cat <<'USAGE'
Usage: ./scripts/run_practical_experiments.sh [--rebuild] [--stop-after]

Options:
  --rebuild     Force a Docker rebuild from vendor/pg_durable.
  --stop-after  Stop and remove the PostgreSQL container after the run.

Environment:
  PGD_POC_CONCURRENCY_WORKERS      Concurrent psql submitter sessions (default: 8)
  PGD_POC_CONCURRENCY_PER_WORKER   Workflows submitted by each session (default: 20)
  PGD_POC_CONCURRENCY_SLEEP_MS     Sleep inside each concurrent workflow SQL node (default: 50)
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rebuild)
            FORCE_REBUILD=true
            shift
            ;;
        --stop-after)
            KEEP_RUNNING=false
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage
            exit 2
            ;;
    esac
done

mkdir -p "$RUN_DIR"

log() {
    printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"
}

require_upstream() {
    if [[ ! -d "$UPSTREAM_DIR/.git" ]]; then
        log "Cloning upstream pg_durable into vendor/pg_durable"
        mkdir -p "$ROOT_DIR/vendor"
        git clone --depth 1 https://github.com/microsoft/pg_durable.git "$UPSTREAM_DIR"
    fi
}

build_image() {
    if [[ "$FORCE_REBUILD" == true ]] || ! docker image inspect "$IMAGE_NAME" >/dev/null 2>&1; then
        log "Building Docker image $IMAGE_NAME from pinned upstream checkout"
        docker build --platform linux/amd64 -t "$IMAGE_NAME" -f "$UPSTREAM_DIR/Dockerfile" "$UPSTREAM_DIR" | tee "$RUN_DIR/docker-build.log"
    else
        log "Using existing Docker image $IMAGE_NAME"
    fi
}

start_container() {
    log "Starting PostgreSQL container $CONTAINER_NAME on localhost:$HOST_PORT"
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker run -d \
        --platform linux/amd64 \
        --name "$CONTAINER_NAME" \
        -e POSTGRES_HOST_AUTH_METHOD=trust \
        -p "$HOST_PORT:5432" \
        "$IMAGE_NAME" >/dev/null

    printf 'Waiting for PostgreSQL'
    local ready_count=0
    for _ in $(seq 1 90); do
        if docker exec "$CONTAINER_NAME" pg_isready -U postgres >/dev/null 2>&1; then
            ready_count=$((ready_count + 1))
            if [[ "$ready_count" -ge 3 ]]; then
                printf ' ready\n'
                return
            fi
        else
            ready_count=0
        fi
        printf '.'
        sleep 1
    done

    printf '\n'
    docker logs "$CONTAINER_NAME" > "$RUN_DIR/docker-timeout.log" 2>&1 || true
    echo "PostgreSQL did not become ready" >&2
    exit 1
}

copy_sql() {
    docker exec "$CONTAINER_NAME" mkdir -p /poc/sql
    for file in "$ROOT_DIR"/sql/*.sql; do
        docker cp "$file" "$CONTAINER_NAME:/poc/sql/$(basename "$file")"
    done
}

run_sql_file() {
    local file="$1"
    local name
    name="$(basename "$file")"
    log "Running $name"
    docker exec "$CONTAINER_NAME" psql -U postgres -v ON_ERROR_STOP=1 -f "/poc/sql/$name" 2>&1 | tee "$RUN_DIR/$name.out"
}

run_concurrency_phase() {
    log "Submitting concurrent load: workers=$CONCURRENCY_WORKERS per_worker=$CONCURRENCY_PER_WORKER sleep_ms=$CONCURRENCY_SLEEP_MS"

    local pids=()
    local worker
    for worker in $(seq 1 "$CONCURRENCY_WORKERS"); do
        (
            docker exec -i "$CONTAINER_NAME" psql -U postgres -v ON_ERROR_STOP=1 2>&1 <<SQL
\pset pager off
SET SESSION AUTHORIZATION poc_runner;
SELECT poc.submit_load_workflows(
    'concurrent_sessions',
    $worker,
    $CONCURRENCY_PER_WORKER,
    $CONCURRENCY_SLEEP_MS
) AS submitted;
RESET SESSION AUTHORIZATION;
SQL
        ) > "$RUN_DIR/load-worker-$worker.out" &
        pids+=("$!")
    done

    local failed=0
    local pid
    for pid in "${pids[@]}"; do
        if ! wait "$pid"; then
            failed=1
        fi
    done

    if [[ "$failed" -ne 0 ]]; then
        echo "One or more concurrent load submitters failed; see $RUN_DIR/load-worker-*.out" >&2
        exit 1
    fi
}

collect_snapshot() {
    log "Collecting practical experiment snapshot"
    docker exec -i "$CONTAINER_NAME" psql -U postgres -v ON_ERROR_STOP=1 2>&1 <<'SQL' | tee "$RUN_DIR/final-snapshot.out"
\pset pager off
\x on
SELECT df.version() AS pg_durable_version;
SELECT * FROM df.metrics();
SELECT instance_id, label, status, execution_count
FROM df.list_instances(NULL, 80)
WHERE label LIKE 'poc-%'
ORDER BY instance_id;
SELECT experiment, status, assertion
FROM poc.experiment_results
ORDER BY id;
SELECT batch, mode, planned_count, elapsed_ms, detail
FROM poc.load_batches
ORDER BY batch;
SELECT scenario, final_status, attempts_after, failed_node_count
FROM poc.retry_observations
ORDER BY id;
SELECT scenario, event, observed_version, count(*) AS rows
FROM poc.deployment_log
GROUP BY scenario, event, observed_version
ORDER BY scenario, event, observed_version;
SQL
}

cleanup() {
    local exit_code=$?
    docker logs "$CONTAINER_NAME" > "$RUN_DIR/docker.log" 2>&1 || true
    if [[ "$KEEP_RUNNING" == false ]]; then
        docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi
    exit "$exit_code"
}
trap cleanup EXIT

require_upstream
git -C "$UPSTREAM_DIR" rev-parse HEAD > "$RUN_DIR/upstream-head.txt"
build_image
start_container
copy_sql

run_sql_file "$ROOT_DIR/sql/00_setup.sql"
run_sql_file "$ROOT_DIR/sql/01_readiness.sql"
run_sql_file "$ROOT_DIR/sql/90_triggered_workflows.sql"
run_sql_file "$ROOT_DIR/sql/100_load_concurrency.sql"
run_concurrency_phase
run_sql_file "$ROOT_DIR/sql/101_load_concurrency_verify.sql"
run_sql_file "$ROOT_DIR/sql/110_retry_semantics.sql"
run_sql_file "$ROOT_DIR/sql/120_transaction_semantics.sql"
run_sql_file "$ROOT_DIR/sql/130_dsl_testing_strategy.sql"
run_sql_file "$ROOT_DIR/sql/140_migration_deployment.sql"

collect_snapshot

log "Practical run artifacts written to $RUN_DIR"
log "Container: docker exec -it $CONTAINER_NAME psql -U postgres"
