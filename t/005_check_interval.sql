-- pg_timers check_interval_ms GUC tests
BEGIN;
SELECT plan(3);

-- Default is 0 (no cap)
SELECT is(
    current_setting('pg_timers.check_interval_ms')::integer,
    0,
    'check_interval_ms defaults to 0 (no cap)'
);

-- GUC is sighup context (cannot SET in session)
SELECT throws_ok(
    $$SET pg_timers.check_interval_ms = 30000$$,
    '55P02',
    NULL,
    'check_interval_ms requires sighup (cannot SET in session)'
);

-- Minimum is 0 (rejects negative)
SELECT throws_ok(
    $$SET pg_timers.check_interval_ms = -1$$,
    '55P02',
    NULL,
    'check_interval_ms rejects SET with negative value'
);

SELECT * FROM finish();
ROLLBACK;
