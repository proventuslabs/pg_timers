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
