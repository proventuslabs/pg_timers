-- pg_timers integration test: timer firing and latch wake-up signaling
-- NOT transactional — needs committed data for bgworker to process

SELECT plan(8);

CREATE TABLE integration_results (msg text, created_at timestamptz DEFAULT clock_timestamp());

-- ── Wave 1: schedule a good timer, a bad timer, and a schedule_at timer ─
SELECT timers.schedule_in('1 second', $$INSERT INTO integration_results (msg) VALUES ('wave1')$$);
SELECT timers.schedule_in('1 second', 'SELECT * FROM nonexistent_table_xyz_integration');
SELECT timers.schedule_at(clock_timestamp() + interval '1 second',
                          $$INSERT INTO integration_results (msg) VALUES ('schedule_at')$$);

-- Poll until all wave-1 timers are processed (500ms intervals, 5s timeout)
DO $$
DECLARE _i integer;
BEGIN
    FOR _i IN 1..10 LOOP
        EXIT WHEN (SELECT count(*) FROM timers.timers WHERE status != 0) >= 3;
        PERFORM pg_sleep(0.5);
    END LOOP;
END;
$$;

-- Verify good timer fired and executed its side effect
SELECT is(
    (SELECT count(*)::integer FROM integration_results WHERE msg = 'wave1'),
    1,
    'wave-1 timer fired and executed its action'
);

-- Verify bad timer marked as failed
SELECT is(
    (SELECT count(*)::integer FROM timers.timers
     WHERE action LIKE '%nonexistent_table_xyz_integration%' AND status = 2),
    1,
    'wave-1 bad timer recorded as failed (status=2)'
);

-- Verify schedule_at timer fired
SELECT is(
    (SELECT count(*)::integer FROM integration_results WHERE msg = 'schedule_at'),
    1,
    'schedule_at timer fired and executed its action'
);

-- Verify cancel returns false for already-fired timer
SELECT is(
    timers.cancel(
        (SELECT id FROM timers.timers WHERE action LIKE '%wave1%' AND status = 1 LIMIT 1),
        0
    ),
    false,
    'cancel returns false for already-fired timer'
);

-- Verify scheduled_by records session_user
SELECT is(
    (SELECT scheduled_by FROM timers.timers WHERE action LIKE '%wave1%' AND status = 1 LIMIT 1),
    session_user::name,
    'scheduled_by records the scheduling user'
);

-- ── Wave 2: verify latch wake-up from sleep ────────────────────────────
-- The worker has no pending timers and is now sleeping on WaitLatch.
-- A newly scheduled timer must wake the worker via post-commit SetLatch.
-- Without the deferred signal fix, this timer would never fire because
-- the worker was signaled before the row was committed and visible.
SELECT timers.schedule_in('1 second', $$INSERT INTO integration_results (msg) VALUES ('wave2')$$);

-- Poll for wave-2 timer (500ms intervals, 5s timeout)
DO $$
DECLARE _i integer;
BEGIN
    FOR _i IN 1..10 LOOP
        EXIT WHEN (SELECT count(*) FROM timers.timers
                   WHERE action LIKE '%wave2%' AND status = 1) >= 1;
        PERFORM pg_sleep(0.5);
    END LOOP;
END;
$$;

SELECT is(
    (SELECT count(*)::integer FROM integration_results WHERE msg = 'wave2'),
    1,
    'wave-2 timer woke sleeping worker and fired'
);

-- ── Timing precision ───────────────────────────────────────────────────
-- All fired timers should complete within 5s of their fire_at
SELECT ok(
    (SELECT bool_and(fired_at - fire_at < interval '5 seconds')
     FROM timers.timers WHERE status = 1),
    'all fired timers completed within 5s of fire_at'
);

-- ── Final counts ───────────────────────────────────────────────────────
SELECT is(
    (SELECT count(*)::integer FROM timers.timers WHERE status = 1),
    3,
    'exactly 3 timers fired successfully'
);

SELECT * FROM finish();

-- Cleanup
DROP TABLE IF EXISTS integration_results;
