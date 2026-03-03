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
REVOKE ALL ON TABLE timers.timers FROM PUBLIC;
REVOKE ALL ON FUNCTION timers.schedule_at(timestamptz, text, bigint, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION timers.schedule_in(interval, text, bigint, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION timers.cancel(bigint, bigint) FROM PUBLIC;
