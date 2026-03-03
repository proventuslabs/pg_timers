-- pg_timers integration test: timer firing end-to-end
-- NOT transactional — needs committed data + pg_sleep for bgworker to process

SELECT plan(3);

-- Create results table
CREATE TABLE integration_results (msg text, created_at timestamptz DEFAULT clock_timestamp());

-- Schedule a 1-second timer that inserts into results table
SELECT timers.schedule_in('1 second', $$INSERT INTO integration_results (msg) VALUES ('good_timer')$$);

-- Schedule a 1-second timer with invalid SQL (should fail gracefully)
SELECT timers.schedule_in('1 second', 'SELECT * FROM nonexistent_table_xyz_integration');

-- Poll until bgworker processes timers (500ms intervals, 30s timeout)
DO $$
DECLARE
    _i integer;
BEGIN
    FOR _i IN 1..60 LOOP
        IF (SELECT count(*) FROM timers.timers WHERE status != 0) >= 2 THEN
            EXIT;
        END IF;
        PERFORM pg_sleep(0.5);
    END LOOP;
END;
$$;

-- Verify good timer fired
SELECT is(
    (SELECT count(*)::integer FROM integration_results WHERE msg = 'good_timer'),
    1,
    'good timer fired and inserted row'
);

-- Verify bad timer recorded as failed (status=2)
SELECT is(
    (SELECT count(*)::integer FROM timers.timers
     WHERE action LIKE '%nonexistent_table_xyz_integration%' AND status = 2),
    1,
    'bad timer recorded as failed'
);

-- Verify good timer marked as fired (status=1)
SELECT is(
    (SELECT count(*)::integer FROM timers.timers
     WHERE action LIKE '%good_timer%' AND status = 1),
    1,
    'good timer marked as fired'
);

SELECT * FROM finish();

-- Cleanup
DROP TABLE IF EXISTS integration_results;
