-- pg_timers synchronous fire primitive tests
-- fire(timer_id, shard_key)   — fire one pending timer synchronously, ignoring fire_at
-- fire_all_pending()          — fire every pending timer synchronously, ignoring fire_at
--
-- These run inside a BEGIN/ROLLBACK block because the point of these primitives
-- is to let pgTAP tests assert on timer side effects *without* waiting for the
-- bgworker and *without* leaking committed state across tests.
BEGIN;
SELECT plan(26);

-- ── Signature / return-type / language ─────────────────────────────────
SELECT has_function('timers', 'fire', ARRAY['bigint', 'bigint']);
SELECT function_returns('timers', 'fire', ARRAY['bigint', 'bigint'], 'boolean');
SELECT function_lang_is('timers', 'fire', ARRAY['bigint', 'bigint'], 'c');

SELECT has_function('timers', 'fire_all_pending', ARRAY[]::text[]);
SELECT function_returns('timers', 'fire_all_pending', ARRAY[]::text[], 'integer');
SELECT function_lang_is('timers', 'fire_all_pending', ARRAY[]::text[], 'c');

-- ── fire(): happy path ─────────────────────────────────────────────────
CREATE TEMP TABLE fire_side_effects (msg text);

-- Schedule a timer in the far future so the bgworker cannot possibly fire it.
SELECT timers.schedule_at(
    '2999-01-01 00:00:00+00',
    $$INSERT INTO fire_side_effects (msg) VALUES ('fired-ok')$$
) AS timer_id \gset

SELECT ok(
    timers.fire(:timer_id),
    'fire() returns true for a pending timer whose action succeeds'
);

SELECT is(
    (SELECT count(*)::integer FROM fire_side_effects WHERE msg = 'fired-ok'),
    1,
    'fire() executed the action synchronously (side effect visible in same txn)'
);

SELECT is(
    (SELECT status FROM timers.timers WHERE id = :timer_id),
    1::smallint,
    'fire() transitioned status 0 -> 1 (fired)'
);

SELECT ok(
    (SELECT fired_at IS NOT NULL FROM timers.timers WHERE id = :timer_id),
    'fire() stamped fired_at'
);

-- ── fire(): ignores fire_at ────────────────────────────────────────────
-- Same as above, but asserts explicitly: the timer was scheduled for 2999
-- and still fired. This is the core property the primitive exists for.
SELECT ok(
    (SELECT fire_at > clock_timestamp() + interval '100 years'
     FROM timers.timers WHERE id = :timer_id),
    'fire() fired a timer whose fire_at is far in the future'
);

-- ── fire(): re-firing an already-fired timer is a no-op ───────────────
SELECT ok(
    NOT timers.fire(:timer_id),
    'fire() returns false for an already-fired timer'
);

SELECT is(
    (SELECT count(*)::integer FROM fire_side_effects WHERE msg = 'fired-ok'),
    1,
    'fire() did not re-execute the action of an already-fired timer'
);

-- ── fire(): failing action ─────────────────────────────────────────────
SELECT timers.schedule_at(
    '2999-01-01 00:00:00+00',
    'SELECT * FROM no_such_table_for_fire_test'
) AS bad_id \gset

SELECT ok(
    NOT timers.fire(:bad_id),
    'fire() returns false when the action raises an error'
);

SELECT is(
    (SELECT status FROM timers.timers WHERE id = :bad_id),
    2::smallint,
    'fire() transitioned a failing timer to status 2 (failed)'
);

SELECT ok(
    (SELECT error IS NOT NULL AND error <> '' FROM timers.timers WHERE id = :bad_id),
    'fire() recorded an error message for the failing timer'
);

-- ── fire(): cancelled / non-existent timers ────────────────────────────
SELECT timers.schedule_at(
    '2999-01-01 00:00:00+00',
    $$INSERT INTO fire_side_effects (msg) VALUES ('never')$$
) AS cancel_id \gset

SELECT ok(timers.cancel(:cancel_id), 'setup: cancel the timer');

SELECT ok(
    NOT timers.fire(:cancel_id),
    'fire() returns false for a cancelled timer'
);

SELECT is(
    (SELECT status FROM timers.timers WHERE id = :cancel_id),
    3::smallint,
    'fire() did not change status of a cancelled timer'
);

SELECT is(
    (SELECT count(*)::integer FROM fire_side_effects WHERE msg = 'never'),
    0,
    'fire() did not execute the action of a cancelled timer'
);

SELECT ok(
    NOT timers.fire(999999999),
    'fire() returns false for a non-existent timer'
);

-- ── fire_all_pending() ─────────────────────────────────────────────────
-- Clean slate: drop all timer rows from earlier tests so status counts below
-- only reflect the three timers scheduled here.  Safe inside the BEGIN block
-- because the whole test rolls back.
DELETE FROM timers.timers;
TRUNCATE fire_side_effects;

SELECT timers.schedule_at('2999-01-01 00:00:00+00',
    $$INSERT INTO fire_side_effects (msg) VALUES ('a')$$);
SELECT timers.schedule_at('2999-01-01 00:00:00+00',
    $$INSERT INTO fire_side_effects (msg) VALUES ('b')$$);
SELECT timers.schedule_at('2999-01-01 00:00:00+00',
    'SELECT * FROM still_no_such_table');

SELECT is(
    timers.fire_all_pending(),
    3,
    'fire_all_pending() returns the number of pending timers processed'
);

SELECT is(
    (SELECT count(*)::integer FROM fire_side_effects),
    2,
    'fire_all_pending() executed each successful action exactly once'
);

SELECT is(
    (SELECT count(*)::integer FROM timers.timers WHERE status = 0),
    0,
    'fire_all_pending() left no pending timers behind'
);

SELECT is(
    (SELECT count(*)::integer FROM timers.timers WHERE status = 2),
    1,
    'fire_all_pending() marked the failing timer as status 2'
);

-- Subsequent call with nothing pending returns 0.
SELECT is(
    timers.fire_all_pending(),
    0,
    'fire_all_pending() returns 0 when no pending timers remain'
);

SELECT * FROM finish();
ROLLBACK;
