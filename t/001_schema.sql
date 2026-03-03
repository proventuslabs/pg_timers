-- pg_timers schema structure tests
BEGIN;
SELECT plan(17);

-- Extension installed
SELECT has_extension('pg_timers');

-- Schema exists
SELECT has_schema('timers');

-- Table exists
SELECT has_table('timers', 'timers', 'timers.timers table exists');

-- All columns present
SELECT has_column('timers', 'timers', 'id', 'has id column');
SELECT has_column('timers', 'timers', 'shard_key', 'has shard_key column');
SELECT has_column('timers', 'timers', 'fire_at', 'has fire_at column');
SELECT has_column('timers', 'timers', 'action', 'has action column');
SELECT has_column('timers', 'timers', 'scheduled_by', 'has scheduled_by column');
SELECT has_column('timers', 'timers', 'status', 'has status column');
SELECT has_column('timers', 'timers', 'created_at', 'has created_at column');
SELECT has_column('timers', 'timers', 'fired_at', 'has fired_at column');
SELECT has_column('timers', 'timers', 'error', 'has error column');

-- Key column types
SELECT col_type_is('timers', 'timers', 'id', 'bigint', 'id is bigint');
SELECT col_type_is('timers', 'timers', 'fire_at', 'timestamp with time zone', 'fire_at is timestamptz');

-- Partial index on pending timers
SELECT has_index('timers', 'timers', 'timers_pending_idx', 'has pending index');

-- CHECK constraint rejects empty actions
SELECT throws_ok(
    $$INSERT INTO timers.timers (fire_at, action) VALUES (clock_timestamp() + interval '1 hour', '')$$,
    '23514',
    NULL,
    'empty action rejected by CHECK constraint'
);

-- shard_key is bigint
SELECT col_type_is('timers', 'timers', 'shard_key', 'bigint', 'shard_key is bigint');

SELECT * FROM finish();
ROLLBACK;
