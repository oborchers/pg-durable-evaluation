\set ON_ERROR_STOP on
\pset pager off

SET SESSION AUTHORIZATION poc_runner;

UPDATE poc.approvals
SET status = 'needs_review',
    decision = NULL,
    decided_at = NULL;

CREATE TEMP TABLE _state(instance_id text);

INSERT INTO _state
SELECT df.start(
    df.wait_for_signal('approval', 60) |=> 'decision'
    ~> df.if(
        'SELECT COALESCE(($decision::jsonb->''data''->>''approved'')::boolean, false)',
        'UPDATE poc.approvals
            SET status = ''approved'',
                decision = $decision::jsonb,
                decided_at = now()
            WHERE id = (SELECT id FROM poc.approvals WHERE status = ''needs_review'' ORDER BY id LIMIT 1)
            RETURNING id, status',
        'UPDATE poc.approvals
            SET status = ''rejected'',
                decision = $decision::jsonb,
                decided_at = now()
            WHERE id = (SELECT id FROM poc.approvals WHERE status = ''needs_review'' ORDER BY id LIMIT 1)
            RETURNING id, status'
    ),
    'poc-signal-approval'
);

SELECT pg_sleep(2);

DO $$
DECLARE
    inst_id text;
    observed_status text;
BEGIN
    SELECT instance_id INTO inst_id FROM _state;
    SELECT df.status(inst_id) INTO observed_status;

    IF lower(observed_status) = 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: approval workflow completed before signal';
    END IF;

    PERFORM df.signal(inst_id, 'approval', '{"approved": true, "approver": "local-reviewer"}');
    RAISE NOTICE 'Sent approval signal to instance=% status_before_signal=%', inst_id, observed_status;
END $$;

DO $$
DECLARE
    inst_id text;
    final_status text;
    approval poc.approvals%ROWTYPE;
BEGIN
    SELECT instance_id INTO inst_id FROM _state;
    SELECT df.wait_for_completion(inst_id, 90) INTO final_status;
    SELECT * INTO approval FROM poc.approvals ORDER BY id LIMIT 1;

    IF final_status != 'completed' THEN
        RAISE EXCEPTION 'TEST FAILED: signal approval status = %', final_status;
    END IF;

    IF approval.status != 'approved' OR approval.decision->'data'->>'approver' != 'local-reviewer' THEN
        RAISE EXCEPTION 'TEST FAILED: approval row not updated correctly: %', row_to_json(approval);
    END IF;

    INSERT INTO poc.experiment_results(experiment, instance_id, status, assertion)
    VALUES (
        '50_signal_approval',
        inst_id,
        'passed',
        jsonb_build_object(
            'approval_id', approval.id,
            'status', approval.status,
            'approver', approval.decision->'data'->>'approver'
        )
    );

    RAISE NOTICE 'TEST PASSED: signal approval instance=% approval_id=%', inst_id, approval.id;
END $$;

DROP TABLE _state;

RESET SESSION AUTHORIZATION;
