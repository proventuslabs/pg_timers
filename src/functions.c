/*
 * functions.c — SQL-callable C functions: schedule_at, schedule_in, cancel
 */

#include "postgres.h"

#include "access/xact.h"
#include "executor/spi.h"
#include "funcapi.h"
#include "utils/builtins.h"
#include "utils/timestamp.h"

#include "utils/memutils.h"

#include "pg_timers.h"

/* Deferred signal state — signal the bgworker only after commit */
static bool xact_callback_registered = false;
static TimestampTz pending_fire_at = 0;

PG_FUNCTION_INFO_V1(pg_timers_schedule_at);
PG_FUNCTION_INFO_V1(pg_timers_schedule_in);
PG_FUNCTION_INFO_V1(pg_timers_cancel);
PG_FUNCTION_INFO_V1(pg_timers_fire);
PG_FUNCTION_INFO_V1(pg_timers_fire_all_pending);

/*
 * Transaction callback: signal the bgworker after commit so the
 * newly-inserted timer row is visible to the worker's snapshot.
 */
static void
pg_timers_xact_callback(XactEvent event, void *arg)
{
	if (event == XACT_EVENT_COMMIT && pending_fire_at != 0)
	{
		TimestampTz fire_at = pending_fire_at;

		pending_fire_at = 0;
		pg_timers_signal_worker(fire_at);
	}
	else if (event == XACT_EVENT_ABORT)
	{
		pending_fire_at = 0;
	}
}

/*
 * Insert a timer and return its id.
 * Defers the bgworker signal until after transaction commit so the timer
 * row is visible when the worker wakes and queries.
 */
static int64
insert_timer(TimestampTz fire_at, const char *action, int64 shard_key,
			 int32 timeout_ms)
{
	int			ret;
	int64		timer_id;
	Oid			argtypes[4] = {TIMESTAMPTZOID, TEXTOID, INT8OID, INT4OID};
	Datum		values[4];
	bool		isnull = false;

	static const char *INSERT_SQL =
		"INSERT INTO timers.timers (fire_at, action, shard_key, timeout_ms) "
		"VALUES ($1, $2, $3, $4) "
		"RETURNING id";

	values[0] = TimestampTzGetDatum(fire_at);
	values[1] = CStringGetTextDatum(action);
	values[2] = Int64GetDatum(shard_key);
	values[3] = Int32GetDatum(timeout_ms);

	SPI_connect();

	ret = SPI_execute_with_args(INSERT_SQL, 4, argtypes, values, NULL, false, 0);
	if (ret != SPI_OK_INSERT_RETURNING || SPI_processed != 1)
		elog(ERROR, "pg_timers: failed to insert timer");

	timer_id = DatumGetInt64(SPI_getbinval(SPI_tuptable->vals[0],
										   SPI_tuptable->tupdesc,
										   1, &isnull));

	SPI_finish();

	/* Register the xact callback once per backend lifetime */
	if (!xact_callback_registered)
	{
		RegisterXactCallback(pg_timers_xact_callback, NULL);
		xact_callback_registered = true;
	}

	/* Track the earliest pending fire_at (handles multiple inserts per txn) */
	if (pending_fire_at == 0 || fire_at < pending_fire_at)
		pending_fire_at = fire_at;

	return timer_id;
}

/*
 * pg_timers.schedule_at(fire_at timestamptz, action text, shard_key bigint)
 * Returns the timer id.
 */
Datum
pg_timers_schedule_at(PG_FUNCTION_ARGS)
{
	TimestampTz fire_at = PG_GETARG_TIMESTAMPTZ(0);
	text	   *action_text = PG_GETARG_TEXT_PP(1);
	int64		shard_key = PG_GETARG_INT64(2);
	int32		timeout_ms = PG_GETARG_INT32(3);
	const char *action = text_to_cstring(action_text);

	PG_RETURN_INT64(insert_timer(fire_at, action, shard_key, timeout_ms));
}

/*
 * pg_timers.schedule_in(fire_in interval, action text, shard_key bigint)
 * Converts the interval to an absolute timestamp using clock_timestamp().
 */
Datum
pg_timers_schedule_in(PG_FUNCTION_ARGS)
{
	Interval   *fire_in = PG_GETARG_INTERVAL_P(0);
	text	   *action_text = PG_GETARG_TEXT_PP(1);
	int64		shard_key = PG_GETARG_INT64(2);
	int32		timeout_ms = PG_GETARG_INT32(3);
	const char *action = text_to_cstring(action_text);
	TimestampTz fire_at;

	/* clock_timestamp() + interval */
	fire_at = DatumGetTimestampTz(
		DirectFunctionCall2(timestamptz_pl_interval,
							TimestampTzGetDatum(GetCurrentTimestamp()),
							IntervalPGetDatum(fire_in)));

	PG_RETURN_INT64(insert_timer(fire_at, action, shard_key, timeout_ms));
}

/*
 * pg_timers.cancel(timer_id bigint, shard_key bigint)
 * Returns true if the timer was actually cancelled (was still pending).
 */
Datum
pg_timers_cancel(PG_FUNCTION_ARGS)
{
	int64		timer_id = PG_GETARG_INT64(0);
	int64		shard_key = PG_GETARG_INT64(1);
	int			ret;
	Oid			argtypes[2] = {INT8OID, INT8OID};
	Datum		values[2];

	static const char *CANCEL_SQL =
		"UPDATE timers.timers "
		"SET status = 3 "
		"WHERE id = $1 AND shard_key = $2 AND status = 0";

	values[0] = Int64GetDatum(timer_id);
	values[1] = Int64GetDatum(shard_key);

	SPI_connect();

	ret = SPI_execute_with_args(CANCEL_SQL, 2, argtypes, values, NULL, false, 0);
	if (ret != SPI_OK_UPDATE)
		elog(ERROR, "pg_timers: failed to cancel timer");

	ret = (SPI_processed == 1) ? 1 : 0;

	SPI_finish();

	PG_RETURN_BOOL(ret == 1);
}

/*
 * Mark a timer as fired (status=1) or failed (status=2).  The WHERE status=0
 * guard means a concurrent cancel/fire won't be clobbered.
 */
static void
mark_timer_result(int64 timer_id, int64 shard_key, bool success,
				  const char *error_msg)
{
	int ret;

	if (success)
	{
		Oid			argtypes[2] = {INT8OID, INT8OID};
		Datum		values[2];

		static const char *FIRED_SQL =
			"UPDATE timers.timers "
			"SET status = 1, fired_at = clock_timestamp() "
			"WHERE id = $1 AND shard_key = $2 AND status = 0";

		values[0] = Int64GetDatum(timer_id);
		values[1] = Int64GetDatum(shard_key);

		ret = SPI_execute_with_args(FIRED_SQL, 2, argtypes, values, NULL, false, 0);
		if (ret != SPI_OK_UPDATE)
			elog(ERROR, "pg_timers: failed to mark timer as fired");
	}
	else
	{
		Oid			argtypes[3] = {INT8OID, INT8OID, TEXTOID};
		Datum		values[3];

		static const char *FAILED_SQL =
			"UPDATE timers.timers "
			"SET status = 2, fired_at = clock_timestamp(), error = $3 "
			"WHERE id = $1 AND shard_key = $2 AND status = 0";

		values[0] = Int64GetDatum(timer_id);
		values[1] = Int64GetDatum(shard_key);
		values[2] = CStringGetTextDatum(error_msg ? error_msg : "unknown error");

		ret = SPI_execute_with_args(FAILED_SQL, 3, argtypes, values, NULL, false, 0);
		if (ret != SPI_OK_UPDATE)
			elog(ERROR, "pg_timers: failed to mark timer as failed");
	}
}

/*
 * pg_timers.fire(timer_id bigint, shard_key bigint)
 *
 * Synchronously execute a pending timer in the caller's backend, ignoring
 * fire_at.  Intended for pgTAP / unit tests: schedule a timer with a
 * far-future fire_at inside a BEGIN block, fire it, assert on side effects,
 * ROLLBACK.
 *
 * Semantics mirror the bgworker tick: the action runs as the scheduling user,
 * inside a subtransaction, with optional statement timeout.  A successful
 * action flips status to 1; a raised error flips status to 2 and records the
 * message.  Returns true iff the action succeeded; false if the timer is not
 * pending (cancelled / already fired / non-existent) or if the action raised.
 */
Datum
pg_timers_fire(PG_FUNCTION_ARGS)
{
	int64		timer_id = PG_GETARG_INT64(0);
	int64		shard_key = PG_GETARG_INT64(1);
	int			ret;
	Oid			argtypes[2] = {INT8OID, INT8OID};
	Datum		values[2];
	char	   *action = NULL;
	char	   *scheduled_by = NULL;
	int32		timeout_ms = 0;
	char	   *error_msg = NULL;
	bool		ok;
	MemoryContext oldctx;

	static const char *LOCK_SQL =
		"SELECT action, scheduled_by, timeout_ms FROM timers.timers "
		"WHERE id = $1 AND shard_key = $2 AND status = 0 "
		"FOR UPDATE SKIP LOCKED";

	values[0] = Int64GetDatum(timer_id);
	values[1] = Int64GetDatum(shard_key);

	SPI_connect();

	ret = SPI_execute_with_args(LOCK_SQL, 2, argtypes, values, NULL, false, 0);
	if (ret != SPI_OK_SELECT)
		elog(ERROR, "pg_timers: failed to lock timer row");

	if (SPI_processed != 1)
	{
		/* Not pending (cancelled, already fired, or doesn't exist). */
		SPI_finish();
		PG_RETURN_BOOL(false);
	}

	/* Copy row values into TopTransactionContext so they survive subtxns. */
	oldctx = MemoryContextSwitchTo(TopTransactionContext);
	{
		bool		isnull;
		char	   *action_str;
		char	   *by_str;

		action_str = SPI_getvalue(SPI_tuptable->vals[0],
								  SPI_tuptable->tupdesc, 1);
		if (action_str == NULL)
			elog(ERROR, "pg_timers: timer action is NULL");
		action = pstrdup(action_str);

		by_str = SPI_getvalue(SPI_tuptable->vals[0],
							  SPI_tuptable->tupdesc, 2);
		if (by_str == NULL)
			elog(ERROR, "pg_timers: timer scheduled_by is NULL");
		scheduled_by = pstrdup(by_str);

		timeout_ms = DatumGetInt32(SPI_getbinval(SPI_tuptable->vals[0],
												 SPI_tuptable->tupdesc,
												 3, &isnull));
		if (isnull)
			timeout_ms = 0;
	}
	MemoryContextSwitchTo(oldctx);

	ok = pg_timers_execute_action(action, scheduled_by, timeout_ms, &error_msg);

	mark_timer_result(timer_id, shard_key, ok, error_msg);

	SPI_finish();

	PG_RETURN_BOOL(ok);
}

/*
 * pg_timers.fire_all_pending()
 *
 * Synchronously execute every pending timer in the caller's backend,
 * regardless of fire_at.  Returns the number of timers processed (whether the
 * action succeeded or failed).  Rows already locked by the bgworker or
 * another caller are skipped (FOR UPDATE SKIP LOCKED).
 *
 * Intended for test scenarios where a call may schedule several timers
 * internally and the test wants to drain them all without knowing their ids.
 */
Datum
pg_timers_fire_all_pending(PG_FUNCTION_ARGS)
{
	int			ret;
	int			nprocessed;
	int32		fired_count = 0;
	int64	   *ids = NULL;
	int64	   *shard_keys = NULL;
	char	  **actions = NULL;
	char	  **scheduled_bys = NULL;
	int		   *timeout_mss = NULL;
	MemoryContext oldctx;
	int			i;

	static const char *FETCH_SQL =
		"SELECT id, shard_key, action, scheduled_by, timeout_ms "
		"FROM timers.timers WHERE status = 0 "
		"FOR UPDATE SKIP LOCKED";

	SPI_connect();

	ret = SPI_execute(FETCH_SQL, false, 0);
	if (ret != SPI_OK_SELECT)
		elog(ERROR, "pg_timers: failed to fetch pending timers");

	nprocessed = (int) SPI_processed;

	if (nprocessed == 0)
	{
		SPI_finish();
		PG_RETURN_INT32(0);
	}

	oldctx = MemoryContextSwitchTo(TopTransactionContext);
	ids = palloc(sizeof(int64) * nprocessed);
	shard_keys = palloc(sizeof(int64) * nprocessed);
	actions = palloc(sizeof(char *) * nprocessed);
	scheduled_bys = palloc(sizeof(char *) * nprocessed);
	timeout_mss = palloc(sizeof(int) * nprocessed);

	for (i = 0; i < nprocessed; i++)
	{
		bool		isnull;
		char	   *action_str;
		char	   *by_str;

		ids[i] = DatumGetInt64(SPI_getbinval(SPI_tuptable->vals[i],
											 SPI_tuptable->tupdesc,
											 1, &isnull));
		if (isnull)
			elog(ERROR, "pg_timers: timer id is NULL");

		shard_keys[i] = DatumGetInt64(SPI_getbinval(SPI_tuptable->vals[i],
													SPI_tuptable->tupdesc,
													2, &isnull));
		if (isnull)
			elog(ERROR, "pg_timers: timer shard_key is NULL");

		action_str = SPI_getvalue(SPI_tuptable->vals[i],
								  SPI_tuptable->tupdesc, 3);
		if (action_str == NULL)
			elog(ERROR, "pg_timers: timer action is NULL");
		actions[i] = pstrdup(action_str);

		by_str = SPI_getvalue(SPI_tuptable->vals[i],
							  SPI_tuptable->tupdesc, 4);
		if (by_str == NULL)
			elog(ERROR, "pg_timers: timer scheduled_by is NULL");
		scheduled_bys[i] = pstrdup(by_str);

		timeout_mss[i] = DatumGetInt32(SPI_getbinval(SPI_tuptable->vals[i],
													 SPI_tuptable->tupdesc,
													 5, &isnull));
		if (isnull)
			timeout_mss[i] = 0;
	}
	MemoryContextSwitchTo(oldctx);

	for (i = 0; i < nprocessed; i++)
	{
		char	   *error_msg = NULL;
		bool		ok;

		ok = pg_timers_execute_action(actions[i], scheduled_bys[i],
									  timeout_mss[i], &error_msg);

		mark_timer_result(ids[i], shard_keys[i], ok, error_msg);
		fired_count++;
	}

	SPI_finish();

	PG_RETURN_INT32(fired_count);
}
