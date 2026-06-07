\set ON_ERROR_STOP on
\pset pager off

SET SESSION AUTHORIZATION poc_runner;

TRUNCATE poc.report_requests;

CREATE TEMP TABLE _state(instance_id text);

INSERT INTO _state
SELECT df.start(
    'SELECT poc.create_report_request(''daily-revenue'') AS report_id' |=> 'request'
    ~> 'SELECT * FROM poc.finish_report_request($request.report_id)' |=> 'finished'
    ~> 'SELECT $finished.report_id AS report_id, $finished.total_amount AS total_amount, $finished.status AS status',
    'poc-function-calls'
);

DO $$
DECLARE
    inst_id text;
    final_status text;
    report poc.report_requests%ROWTYPE;
    result_json jsonb;
BEGIN
    SELECT instance_id INTO inst_id FROM _state;
    SELECT df.wait_for_completion(inst_id, 30) INTO final_status;
    SELECT * INTO report FROM poc.report_requests ORDER BY id DESC LIMIT 1;
    SELECT df.result(inst_id)::jsonb INTO result_json;

    IF final_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: function-call workflow status = %', final_status;
    END IF;

    IF report.status != 'completed' OR report.total_amount != 227.50 THEN
        RAISE EXCEPTION 'TEST FAILED: unexpected report status=% total=%', report.status, report.total_amount;
    END IF;

    INSERT INTO poc.experiment_results(experiment, instance_id, status, assertion)
    VALUES (
        '30_function_calls',
        inst_id,
        'passed',
        jsonb_build_object(
            'report_id', report.id,
            'total_amount', report.total_amount,
            'result', result_json
        )
    );

    RAISE NOTICE 'TEST PASSED: function calls instance=% report_id=%', inst_id, report.id;
END $$;

DROP TABLE _state;

RESET SESSION AUTHORIZATION;

