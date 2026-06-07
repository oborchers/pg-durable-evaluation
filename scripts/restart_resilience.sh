#!/usr/bin/env bash
set -euo pipefail

CONTAINER_NAME="${1:-pg_durable_poc}"
RUN_DIR="${2:-runs/manual}"

mkdir -p "$RUN_DIR"

psql_exec() {
    docker exec -i "$CONTAINER_NAME" psql -U postgres -v ON_ERROR_STOP=1 "$@"
}

psql_scalar() {
    docker exec -i "$CONTAINER_NAME" psql -U postgres -Atq -v ON_ERROR_STOP=1 "$@"
}

echo "Starting restart resilience workflow"

INSTANCE_ID="$(
    psql_scalar <<'SQL'
SET SESSION AUTHORIZATION poc_runner;
TRUNCATE poc.restart_probe;
SELECT df.start(
    'INSERT INTO poc.restart_probe(marker) VALUES (''before_sleep'')'
    ~> df.sleep(8)
    ~> 'INSERT INTO poc.restart_probe(marker) VALUES (''after_sleep'')',
    'poc-restart-resilience'
);
RESET SESSION AUTHORIZATION;
SQL
)"

echo "Instance: $INSTANCE_ID"

echo "Waiting for first checkpoint"
for _ in $(seq 1 80); do
    BEFORE_COUNT="$(psql_scalar -c "SELECT count(*) FROM poc.restart_probe WHERE marker = 'before_sleep';")"
    if [[ "$BEFORE_COUNT" -ge 1 ]]; then
        break
    fi
    sleep 0.25
done

if [[ "${BEFORE_COUNT:-0}" -lt 1 ]]; then
    echo "TEST FAILED: before_sleep checkpoint did not appear before restart" >&2
    exit 1
fi

echo "Restarting PostgreSQL container while workflow is sleeping"
docker restart "$CONTAINER_NAME" >/dev/null

printf 'Waiting for PostgreSQL after restart'
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

psql_exec -c "SELECT public.poc_wait_for_worker_ready(60);"

FINAL_STATUS="$(
    psql_scalar <<SQL
SET SESSION AUTHORIZATION poc_runner;
SELECT df.wait_for_completion('$INSTANCE_ID', 90);
RESET SESSION AUTHORIZATION;
SQL
)"

BEFORE_COUNT="$(psql_scalar -c "SELECT count(*) FROM poc.restart_probe WHERE marker = 'before_sleep';")"
AFTER_COUNT="$(psql_scalar -c "SELECT count(*) FROM poc.restart_probe WHERE marker = 'after_sleep';")"

if [[ "$FINAL_STATUS" != "completed" ]]; then
    echo "TEST FAILED: restart workflow status = $FINAL_STATUS" >&2
    exit 1
fi

if [[ "$BEFORE_COUNT" -ne 1 || "$AFTER_COUNT" -ne 1 ]]; then
    echo "TEST FAILED: expected one before and one after marker, got before=$BEFORE_COUNT after=$AFTER_COUNT" >&2
    exit 1
fi

psql_exec <<SQL
INSERT INTO poc.experiment_results(experiment, instance_id, status, assertion)
VALUES (
    '60_restart_resilience',
    '$INSTANCE_ID',
    'passed',
    jsonb_build_object(
        'final_status', '$FINAL_STATUS',
        'before_sleep_markers', $BEFORE_COUNT,
        'after_sleep_markers', $AFTER_COUNT
    )
);
SQL

echo "TEST PASSED: restart resilience instance=$INSTANCE_ID before=$BEFORE_COUNT after=$AFTER_COUNT"
