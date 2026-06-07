\set ON_ERROR_STOP on
\pset pager off

SET SESSION AUTHORIZATION poc_runner;

TRUNCATE poc.metric_snapshots;

CREATE TEMP TABLE _state(instance_id text, started_at timestamptz);

INSERT INTO _state
SELECT
    df.start(
        (
            ($$SELECT pg_sleep(2), count(*)::int AS user_count FROM poc.events WHERE kind = 'signup'$$ |=> 'users')
            &
            ($$SELECT pg_sleep(2), count(*)::int AS paid_order_count FROM poc.events WHERE kind = 'paid_order'$$ |=> 'orders')
            &
            ($$SELECT pg_sleep(2), coalesce(sum(amount), 0)::numeric(12,2) AS revenue FROM poc.events WHERE kind = 'paid_order'$$ |=> 'revenue')
        )
        ~> $$INSERT INTO poc.metric_snapshots(user_count, paid_order_count, revenue, source)
            VALUES ($users.user_count, $orders.paid_order_count, $revenue.revenue, 'parallel-fanout')
            RETURNING id, user_count, paid_order_count, revenue$$,
        'poc-async-aggregation'
    ),
    clock_timestamp();

DO $$
DECLARE
    inst_id text;
    final_status text;
    elapsed_ms numeric;
    snap poc.metric_snapshots%ROWTYPE;
BEGIN
    SELECT instance_id INTO inst_id FROM _state;
    SELECT df.wait_for_completion(inst_id, 60) INTO final_status;
    SELECT extract(epoch FROM (clock_timestamp() - started_at)) * 1000 INTO elapsed_ms FROM _state;
    SELECT * INTO snap FROM poc.metric_snapshots ORDER BY id DESC LIMIT 1;

    IF final_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: aggregation status = %', final_status;
    END IF;

    IF snap.user_count != 3 OR snap.paid_order_count != 3 OR snap.revenue != 227.50 THEN
        RAISE EXCEPTION 'TEST FAILED: unexpected snapshot users=% orders=% revenue=%',
            snap.user_count, snap.paid_order_count, snap.revenue;
    END IF;

    IF elapsed_ms > 7000 THEN
        RAISE EXCEPTION 'TEST FAILED: fan-out took too long (% ms), expected roughly one sleep window', elapsed_ms;
    END IF;

    INSERT INTO poc.experiment_results(experiment, instance_id, status, assertion)
    VALUES (
        '10_async_aggregation',
        inst_id,
        'passed',
        jsonb_build_object(
            'elapsed_ms', round(elapsed_ms, 1),
            'user_count', snap.user_count,
            'paid_order_count', snap.paid_order_count,
            'revenue', snap.revenue
        )
    );

    RAISE NOTICE 'TEST PASSED: async aggregation instance=% elapsed_ms=%', inst_id, round(elapsed_ms, 1);
END $$;

DROP TABLE _state;

RESET SESSION AUTHORIZATION;

