-- pg_timers function signature tests
BEGIN;
SELECT plan(9);

-- Functions exist with correct argument types
SELECT has_function('timers', 'schedule_at', ARRAY['timestamp with time zone', 'text', 'bigint', 'integer']);
SELECT has_function('timers', 'schedule_in', ARRAY['interval', 'text', 'bigint', 'integer']);
SELECT has_function('timers', 'cancel', ARRAY['bigint', 'bigint']);

-- Return types
SELECT function_returns('timers', 'schedule_at', ARRAY['timestamp with time zone', 'text', 'bigint', 'integer'], 'bigint');
SELECT function_returns('timers', 'schedule_in', ARRAY['interval', 'text', 'bigint', 'integer'], 'bigint');
SELECT function_returns('timers', 'cancel', ARRAY['bigint', 'bigint'], 'boolean');

-- All implemented in C
SELECT function_lang_is('timers', 'schedule_at', ARRAY['timestamp with time zone', 'text', 'bigint', 'integer'], 'c');
SELECT function_lang_is('timers', 'schedule_in', ARRAY['interval', 'text', 'bigint', 'integer'], 'c');
SELECT function_lang_is('timers', 'cancel', ARRAY['bigint', 'bigint'], 'c');

SELECT * FROM finish();
ROLLBACK;
