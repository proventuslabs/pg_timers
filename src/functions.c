/*
 * functions.c — SQL-callable C functions: schedule_at, schedule_in, cancel
 */

#include "postgres.h"

#include "executor/spi.h"
#include "funcapi.h"
#include "utils/builtins.h"
#include "utils/timestamp.h"

#include "pg_timers.h"

PG_FUNCTION_INFO_V1(pg_timers_schedule_at);
PG_FUNCTION_INFO_V1(pg_timers_schedule_in);
PG_FUNCTION_INFO_V1(pg_timers_cancel);

/*
 * Insert a timer and return its id. Signals the bgworker if needed.
 */
static int64
insert_timer(TimestampTz fire_at, const char *action, int64 shard_key)
{
	int			ret;
	int64		timer_id;
	Oid			argtypes[3] = {TIMESTAMPTZOID, TEXTOID, INT8OID};
	Datum		values[3];
	bool		isnull = false;

	static const char *INSERT_SQL =
		"INSERT INTO timers.timers (fire_at, action, shard_key) "
		"VALUES ($1, $2, $3) "
		"RETURNING id";

	values[0] = TimestampTzGetDatum(fire_at);
	values[1] = CStringGetTextDatum(action);
	values[2] = Int64GetDatum(shard_key);

	SPI_connect();

	ret = SPI_execute_with_args(INSERT_SQL, 3, argtypes, values, NULL, false, 0);
	if (ret != SPI_OK_INSERT_RETURNING || SPI_processed != 1)
		elog(ERROR, "pg_timers: failed to insert timer");

	timer_id = DatumGetInt64(SPI_getbinval(SPI_tuptable->vals[0],
										   SPI_tuptable->tupdesc,
										   1, &isnull));

	SPI_finish();

	/* Wake the bgworker if this timer is sooner */
	pg_timers_signal_worker(fire_at);

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
	const char *action = text_to_cstring(action_text);

	PG_RETURN_INT64(insert_timer(fire_at, action, shard_key));
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
	const char *action = text_to_cstring(action_text);
	TimestampTz fire_at;

	/* clock_timestamp() + interval */
	fire_at = DatumGetTimestampTz(
		DirectFunctionCall2(timestamptz_pl_interval,
							TimestampTzGetDatum(GetCurrentTimestamp()),
							IntervalPGetDatum(fire_in)));

	PG_RETURN_INT64(insert_timer(fire_at, action, shard_key));
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
