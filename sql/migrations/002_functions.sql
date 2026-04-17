-- schedule_at: fire at exact time
CREATE FUNCTION timers.schedule_at(
    fire_at     timestamptz,
    action      text,
    shard_key   bigint DEFAULT 0,
    timeout_ms  integer DEFAULT 0
) RETURNS bigint
AS 'MODULE_PATHNAME', 'pg_timers_schedule_at'
LANGUAGE C VOLATILE STRICT;

COMMENT ON FUNCTION timers.schedule_at(timestamptz, text, bigint, integer) IS
'Schedule a SQL action to run once at an exact wall-clock time.

Inserts a row into timers.timers with status=0 (pending), records session_user
in scheduled_by, and signals the background worker after commit so the new
fire_at is visible when the worker wakes. The worker executes the action at
clock_timestamp() >= fire_at, as scheduled_by, inside a subtransaction, with
SET LOCAL statement_timeout = timeout_ms (0 = no limit). On success the row
moves to status=1 (fired); on error to status=2 (failed) with the message in
the error column. If the transaction that called schedule_at rolls back, the
timer is never inserted. Returns the new timer id.';

-- schedule_in: fire after interval
CREATE FUNCTION timers.schedule_in(
    fire_in     interval,
    action      text,
    shard_key   bigint DEFAULT 0,
    timeout_ms  integer DEFAULT 0
) RETURNS bigint
AS 'MODULE_PATHNAME', 'pg_timers_schedule_in'
LANGUAGE C VOLATILE STRICT;

COMMENT ON FUNCTION timers.schedule_in(interval, text, bigint, integer) IS
'Schedule a SQL action to run once after the given interval has elapsed.

Equivalent to schedule_at(clock_timestamp() + fire_in, action, ...): the
interval is resolved to an absolute timestamptz at call time, not re-evaluated
later, so subsequent clock skew or server restarts do not shift the fire time.
All other behavior (subtransaction isolation, role switch to scheduled_by,
per-timer statement_timeout, status transitions, rollback safety) is identical
to schedule_at. Returns the new timer id.';

-- cancel: cancel a pending timer
CREATE FUNCTION timers.cancel(
    timer_id    bigint,
    shard_key   bigint DEFAULT 0
) RETURNS boolean
AS 'MODULE_PATHNAME', 'pg_timers_cancel'
LANGUAGE C VOLATILE STRICT;

COMMENT ON FUNCTION timers.cancel(bigint, bigint) IS
'Cancel a pending timer so the background worker will not execute it.

Moves the row from status=0 (pending) to status=3 (cancelled), but only if it
is still pending — a timer that has already fired, failed, or been cancelled
is left untouched. Safe against races with the worker: the UPDATE contends for
the same row lock the worker takes while firing, and whichever side wins, the
status=0 guard ensures no double-transition. Returns true iff this call is the
one that actually cancelled the timer; false if it was already non-pending or
the id/shard_key does not exist.';

-- fire: synchronously execute a pending timer NOW, ignoring fire_at.
CREATE FUNCTION timers.fire(
    timer_id    bigint,
    shard_key   bigint DEFAULT 0
) RETURNS boolean
AS 'MODULE_PATHNAME', 'pg_timers_fire'
LANGUAGE C VOLATILE STRICT;

COMMENT ON FUNCTION timers.fire(bigint, bigint) IS
'Execute a pending timer synchronously in the calling backend, ignoring fire_at.

Intended for pgTAP / unit tests that need to assert on a timer''s side effects
without waiting for the scheduled time. Locks the row with FOR UPDATE SKIP
LOCKED, then runs the action with the same semantics as the background worker:
as scheduled_by, inside a subtransaction, with SET LOCAL statement_timeout =
timeout_ms. On success the row moves to status=1 (fired); on error to
status=2 (failed) with the message recorded. Runs in the caller''s transaction,
so wrapping the test in BEGIN; ...; ROLLBACK; rolls back both the action''s
side effects and the status transition. Returns true iff the action succeeded;
false if the timer is not pending (cancelled / already fired / does not exist)
or the action raised an error. Note: no scheduled_by check — a role with
EXECUTE on this function and SELECT on timers.timers can fire any user''s
pending timer out of order.';

-- fire_all_pending: synchronously execute every pending timer NOW, ignoring fire_at.
CREATE FUNCTION timers.fire_all_pending()
RETURNS integer
AS 'MODULE_PATHNAME', 'pg_timers_fire_all_pending'
LANGUAGE C VOLATILE;

COMMENT ON FUNCTION timers.fire_all_pending() IS
'Execute every pending timer synchronously in the calling backend, ignoring fire_at.

Intended for tests that invoke a function which schedules timers internally
and want to drain the queue without knowing the individual timer ids. Locks
all status=0 rows with FOR UPDATE SKIP LOCKED (rows held by the background
worker or another session are skipped), then runs each action with full
bgworker parity — as scheduled_by, inside its own subtransaction so one
action''s failure does not affect the others, with per-timer statement_timeout.
Successful actions move their row to status=1, failures to status=2 with the
error message recorded. Runs in the caller''s transaction, so BEGIN; ...;
ROLLBACK; undoes every side effect together. Returns the number of timers
processed (both successes and failures). Same cross-user caveat as fire():
any row visible via SELECT on timers.timers can be fired here.';