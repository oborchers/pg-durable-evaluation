#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM_DIR="$ROOT_DIR/vendor/pg_durable"
IMAGE_NAME="${PGD_POC_IMAGE:-pg_durable_poc:latest}"
CONTAINER_NAME="${PGD_POC_CONTAINER:-pg_durable_poc}"
HOST_PORT="${PGD_POC_PORT:-55432}"
RUN_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$ROOT_DIR/runs/$RUN_STAMP"

FORCE_REBUILD=false
KEEP_RUNNING=true

usage() {
    cat <<'USAGE'
Usage: ./scripts/run_experiments.sh [--rebuild] [--stop-after]

Options:
  --rebuild     Force a Docker rebuild from vendor/pg_durable.
  --stop-after  Stop and remove the PostgreSQL container after the run.
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

collect_snapshot() {
    log "Collecting final SQL observability snapshot"
    docker exec -i "$CONTAINER_NAME" psql -U postgres -v ON_ERROR_STOP=1 2>&1 <<'SQL' | tee "$RUN_DIR/final-snapshot.out"
\pset pager off
\x on
SELECT df.version() AS pg_durable_version;
SELECT * FROM df.metrics();
SELECT instance_id, label, status, execution_count
FROM df.list_instances(NULL, 50)
WHERE label LIKE 'poc-%'
ORDER BY instance_id;
SELECT experiment, status, assertion
FROM poc.experiment_results
ORDER BY id;
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
run_sql_file "$ROOT_DIR/sql/10_async_aggregation.sql"
run_sql_file "$ROOT_DIR/sql/20_dispatch_jobs.sql"
run_sql_file "$ROOT_DIR/sql/30_function_calls.sql"
run_sql_file "$ROOT_DIR/sql/40_http_ai_simulation.sql"
run_sql_file "$ROOT_DIR/sql/45_secret_handling.sql"
run_sql_file "$ROOT_DIR/sql/50_signal_approval.sql"
run_sql_file "$ROOT_DIR/sql/70_failure_modes.sql"

log "Running restart resilience probe"
"$ROOT_DIR/scripts/restart_resilience.sh" "$CONTAINER_NAME" "$RUN_DIR" 2>&1 | tee "$RUN_DIR/60_restart_resilience.out"

collect_snapshot

log "Run artifacts written to $RUN_DIR"
log "Container: docker exec -it $CONTAINER_NAME psql -U postgres"
