#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_IMAGE="${PGD_POC_BASE_IMAGE:-pg_durable_poc:latest}"
IMAGE_NAME="${PGD_POC_HTTP_IMAGE:-pg_durable_poc:http}"
CONTAINER_NAME="${PGD_POC_HTTP_CONTAINER:-pg_durable_poc_http}"
HOST_PORT="${PGD_POC_HTTP_PORT:-55433}"
RUN_STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$ROOT_DIR/runs/$RUN_STAMP-postgres-http"

mkdir -p "$RUN_DIR"

log() {
    printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"
}

if ! docker image inspect "$BASE_IMAGE" >/dev/null 2>&1; then
    log "Base image $BASE_IMAGE is missing. Build it first with ./scripts/run_experiments.sh --rebuild"
    exit 1
fi

log "Building postgres-http comparison image $IMAGE_NAME from $BASE_IMAGE"
docker build \
    --platform linux/amd64 \
    --build-arg "BASE_IMAGE=$BASE_IMAGE" \
    -t "$IMAGE_NAME" \
    -f "$ROOT_DIR/docker/postgres-http.Dockerfile" \
    "$ROOT_DIR" | tee "$RUN_DIR/docker-build.log"

cleanup() {
    local exit_code=$?
    docker logs "$CONTAINER_NAME" > "$RUN_DIR/docker.log" 2>&1 || true
    exit "$exit_code"
}
trap cleanup EXIT

log "Starting PostgreSQL container $CONTAINER_NAME on localhost:$HOST_PORT"
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
docker run -d \
    --platform linux/amd64 \
    --name "$CONTAINER_NAME" \
    -e POSTGRES_HOST_AUTH_METHOD=trust \
    -p "$HOST_PORT:5432" \
    "$IMAGE_NAME" >/dev/null

printf 'Waiting for PostgreSQL'
READY_COUNT=0
for _ in $(seq 1 90); do
    if docker exec "$CONTAINER_NAME" pg_isready -U postgres >/dev/null 2>&1; then
        READY_COUNT=$((READY_COUNT + 1))
        if [[ "$READY_COUNT" -ge 3 ]]; then
            printf ' ready\n'
            break
        fi
    else
        READY_COUNT=0
    fi
    printf '.'
    sleep 1
done

docker exec "$CONTAINER_NAME" mkdir -p /poc/sql
docker cp "$ROOT_DIR/sql/00_setup.sql" "$CONTAINER_NAME:/poc/sql/00_setup.sql"
docker cp "$ROOT_DIR/sql/80_postgres_http_comparison.sql" "$CONTAINER_NAME:/poc/sql/80_postgres_http_comparison.sql"

log "Running shared pg_durable setup"
docker exec "$CONTAINER_NAME" psql -U postgres -v ON_ERROR_STOP=1 -f /poc/sql/00_setup.sql 2>&1 | tee "$RUN_DIR/00_setup.sql.out"

log "Running postgres-http comparison"
docker exec "$CONTAINER_NAME" psql -U postgres -v ON_ERROR_STOP=1 -f /poc/sql/80_postgres_http_comparison.sql 2>&1 | tee "$RUN_DIR/80_postgres_http_comparison.sql.out"

log "Collecting comparison snapshot"
docker exec -i "$CONTAINER_NAME" psql -U postgres -v ON_ERROR_STOP=1 2>&1 <<'SQL' | tee "$RUN_DIR/final-snapshot.out"
\pset pager off
\x on
SELECT name, default_version, installed_version
FROM pg_available_extensions
WHERE name = 'http';
SELECT experiment, status, assertion
FROM poc.experiment_results
WHERE experiment LIKE '80_%'
ORDER BY id;
SELECT client, endpoint, status_code, ok, body_has_resources, raw ? 'headers' AS has_headers_object
FROM poc.http_comparison_results
ORDER BY id;
SQL

log "Run artifacts written to $RUN_DIR"
log "Container: docker exec -it $CONTAINER_NAME psql -U postgres"

