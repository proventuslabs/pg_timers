-- schedule_at: fire at exact time
CREATE FUNCTION timers.schedule_at(
    fire_at     timestamptz,
    action      text,
    shard_key   bigint DEFAULT 0,
    timeout_ms  integer DEFAULT 0
) RETURNS bigint
AS 'MODULE_PATHNAME', 'pg_timers_schedule_at'
LANGUAGE C VOLATILE STRICT;

-- schedule_in: fire after interval
CREATE FUNCTION timers.schedule_in(
    fire_in     interval,
    action      text,
    shard_key   bigint DEFAULT 0,
    timeout_ms  integer DEFAULT 0
) RETURNS bigint
AS 'MODULE_PATHNAME', 'pg_timers_schedule_in'
LANGUAGE C VOLATILE STRICT;

-- cancel: cancel a pending timer
CREATE FUNCTION timers.cancel(
    timer_id    bigint,
    shard_key   bigint DEFAULT 0
) RETURNS boolean
AS 'MODULE_PATHNAME', 'pg_timers_cancel'
LANGUAGE C VOLATILE STRICT;

-- fire: synchronously execute a pending timer NOW, ignoring fire_at.
-- Intended for pgTAP / unit tests — lets tests assert on a timer's side effects
-- without waiting for the background worker.  Returns true iff the action
-- succeeded; false if the timer is not pending or the action raised.
CREATE FUNCTION timers.fire(
    timer_id    bigint,
    shard_key   bigint DEFAULT 0
) RETURNS boolean
AS 'MODULE_PATHNAME', 'pg_timers_fire'
LANGUAGE C VOLATILE STRICT;

-- fire_all_pending: synchronously execute every pending timer NOW, ignoring
-- fire_at.  Returns the number of timers processed.  Intended for tests that
-- schedule timers indirectly and need to drain them without knowing ids.
CREATE FUNCTION timers.fire_all_pending()
RETURNS integer
AS 'MODULE_PATHNAME', 'pg_timers_fire_all_pending'
LANGUAGE C VOLATILE;
