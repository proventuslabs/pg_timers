-- pg_timers 0.1.0: precise timer scheduling
-- Schema "timers" is created automatically via the control file.

/*
 * Security model
 * --------------
 * Timer actions execute as the user who scheduled them (the session_user at
 * the time of the schedule_at/schedule_in call), NOT as the superuser that
 * owns the background worker.  The scheduled_by column records this user.
 *
 * All objects are REVOKEd from PUBLIC by default.  Grant access carefully —
 * any user who can call schedule_at/schedule_in can cause arbitrary SQL to
 * run under their own identity via the background worker.
 */

CREATE TABLE timers.timers (
    id              bigint GENERATED ALWAYS AS IDENTITY,
    shard_key       bigint NOT NULL DEFAULT 0,
    fire_at         timestamptz NOT NULL,
    action          text NOT NULL CHECK (action <> ''),
    scheduled_by    name NOT NULL DEFAULT session_user,
    status          smallint NOT NULL DEFAULT 0,  -- 0=pending, 1=fired, 2=failed, 3=cancelled
    created_at      timestamptz NOT NULL DEFAULT clock_timestamp(),
    fired_at        timestamptz,
    error           text,
    PRIMARY KEY (shard_key, id)
);

CREATE INDEX timers_pending_idx
    ON timers.timers (fire_at)
    WHERE status = 0;

-- schedule_at: fire at exact time
CREATE FUNCTION timers.schedule_at(
    fire_at     timestamptz,
    action      text,
    shard_key   bigint DEFAULT 0
) RETURNS bigint
AS 'MODULE_PATHNAME', 'pg_timers_schedule_at'
LANGUAGE C VOLATILE STRICT;

-- schedule_in: fire after interval
CREATE FUNCTION timers.schedule_in(
    fire_in     interval,
    action      text,
    shard_key   bigint DEFAULT 0
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

-- Security: restrict access to prevent privilege escalation.
REVOKE ALL ON TABLE timers.timers FROM PUBLIC;
REVOKE ALL ON FUNCTION timers.schedule_at(timestamptz, text, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION timers.schedule_in(interval, text, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION timers.cancel(bigint, bigint) FROM PUBLIC;
