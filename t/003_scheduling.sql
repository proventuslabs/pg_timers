-- pg_timers scheduling unit tests
BEGIN;
SELECT plan(12);

-- schedule_in works
SELECT lives_ok(
    $$SELECT timers.schedule_in('60 seconds', 'SELECT 1')$$,
    'schedule_in accepts interval and SQL'
);

-- schedule_at works
SELECT lives_ok(
    $$SELECT timers.schedule_at(clock_timestamp() + interval '60 seconds', 'SELECT 1')$$,
    'schedule_at accepts timestamp and SQL'
);

-- schedule_in with shard_key
SELECT lives_ok(
    $$SELECT timers.schedule_in('60 seconds', 'SELECT 1', 42)$$,
    'schedule_in accepts shard_key'
);

-- Verify row inserted correctly
SELECT is(
    (SELECT action FROM timers.timers WHERE shard_key = 42 ORDER BY id DESC LIMIT 1),
    'SELECT 1',
    'timer row has correct action'
);

SELECT ok(
    (SELECT fire_at > clock_timestamp() FROM timers.timers WHERE shard_key = 42 ORDER BY id DESC LIMIT 1),
    'fire_at is in the future'
);

SELECT is(
    (SELECT shard_key FROM timers.timers WHERE shard_key = 42 ORDER BY id DESC LIMIT 1),
    42::bigint,
    'shard_key stored correctly'
);

SELECT is(
    (SELECT status FROM timers.timers WHERE shard_key = 42 ORDER BY id DESC LIMIT 1),
    0::smallint,
    'new timer has status=0 (pending)'
);

-- Cancel returns true for existing timer
SELECT ok(
    (SELECT timers.cancel(id, shard_key) FROM timers.timers WHERE shard_key = 42 ORDER BY id DESC LIMIT 1),
    'cancel returns true for pending timer'
);

SELECT is(
    (SELECT status FROM timers.timers WHERE shard_key = 42 ORDER BY id DESC LIMIT 1),
    3::smallint,
    'cancelled timer has status=3'
);

-- Far-future timers are valid (timestamptz max is year 294276)
SELECT lives_ok(
    $$SELECT timers.schedule_at('9999-12-31 23:59:59+00', 'SELECT 1')$$,
    'schedule_at accepts far-future timestamp'
);

SELECT ok(
    (SELECT fire_at = '9999-12-31 23:59:59+00'::timestamptz FROM timers.timers WHERE action = 'SELECT 1' AND fire_at > '9999-01-01'::timestamptz LIMIT 1),
    'far-future fire_at stored correctly'
);

-- Cancel non-existent returns false
SELECT ok(
    NOT timers.cancel(999999999, 0),
    'cancel returns false for non-existent timer'
);

SELECT * FROM finish();
ROLLBACK;
