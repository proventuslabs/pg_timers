/*
 * bgworker.c — background worker main loop, timer execution
 */

#include "postgres.h"

#include "access/xact.h"
#include "executor/spi.h"
#include "utils/acl.h"
#include "utils/builtins.h"
#include "utils/guc.h"
#include "miscadmin.h"
#include "pgstat.h"
#include "postmaster/bgworker.h"
#include "storage/ipc.h"
#include "storage/latch.h"
#include "storage/lwlock.h"
#include "tcop/utility.h"
#include "utils/memutils.h"
#include "utils/snapmgr.h"
#include "utils/timestamp.h"

#include "pg_timers.h"

/* Signal handling */
static volatile sig_atomic_t got_sigterm = false;
static volatile sig_atomic_t got_sighup = false;

static void
pg_timers_sigterm(SIGNAL_ARGS)
{
	int save_errno = errno;
	got_sigterm = true;
	SetLatch(MyLatch);
	errno = save_errno;
}

static void
pg_timers_sighup(SIGNAL_ARGS)
{
	int save_errno = errno;
	got_sighup = true;
	SetLatch(MyLatch);
	errno = save_errno;
}

/* SQL templates */
static const char *FETCH_EXPIRED_SQL =
	"SELECT id, shard_key, action, scheduled_by, timeout_ms FROM timers.timers "
	"WHERE status = 0 AND fire_at <= clock_timestamp() "
	"ORDER BY fire_at LIMIT $1 "
	"FOR UPDATE SKIP LOCKED";

static const char *MARK_FIRED_SQL =
	"UPDATE timers.timers "
	"SET status = 1, fired_at = clock_timestamp() "
	"WHERE id = $1 AND shard_key = $2 AND status = 0";

static const char *MARK_FAILED_SQL =
	"UPDATE timers.timers "
	"SET status = 2, fired_at = clock_timestamp(), error = $3 "
	"WHERE id = $1 AND shard_key = $2 AND status = 0";

static const char *NEXT_FIRE_SQL =
	"SELECT min(fire_at) FROM timers.timers WHERE status = 0";

/* Prepared statement handles (survive across SPI sessions via SPI_keepplan) */
static SPIPlanPtr fetch_plan = NULL;
static SPIPlanPtr mark_fired_plan = NULL;
static SPIPlanPtr mark_failed_plan = NULL;
static SPIPlanPtr next_fire_plan = NULL;

/*
 * on_shmem_exit callback: clear shared state when bgworker exits.
 */
static void
pg_timers_worker_exit(int code, Datum arg)
{
	if (!pg_timers_shared)
		return;

	LWLockAcquire(pg_timers_shared->lock, LW_EXCLUSIVE);
	pg_timers_shared->worker_attached = false;
	pg_timers_shared->bgworker_latch = NULL;
	pg_timers_shared->worker_pid = 0;
	LWLockRelease(pg_timers_shared->lock);
}

/*
 * Execute a single timer action inside a subtransaction as the scheduling user.
 * Returns true on success, false on failure (with error_msg set).
 */
static bool
execute_timer_action(const char *action, const char *scheduled_by,
					 int timeout_ms, char **error_msg)
{
	MemoryContext oldctx;
	bool		success = true;
	Oid			saved_userid;
	int			saved_sec_context;
	Oid			target_userid;

	/* Resolve the scheduling user */
	target_userid = get_role_oid(scheduled_by, true);
	if (!OidIsValid(target_userid))
	{
		oldctx = MemoryContextSwitchTo(TopTransactionContext);
		*error_msg = psprintf("scheduled_by role \"%s\" does not exist", scheduled_by);
		MemoryContextSwitchTo(oldctx);
		return false;
	}

	/* Switch to the scheduling user */
	GetUserIdAndSecContext(&saved_userid, &saved_sec_context);
	SetUserIdAndSecContext(target_userid,
						   saved_sec_context | SECURITY_LOCAL_USERID_CHANGE);

	BeginInternalSubTransaction(NULL);

	PG_TRY();
	{
		int ret;

		/* Apply per-timer statement timeout */
		if (timeout_ms > 0)
		{
			char timeout_sql[64];
			snprintf(timeout_sql, sizeof(timeout_sql),
					 "SET LOCAL statement_timeout = %d",
					 timeout_ms);
			SPI_execute(timeout_sql, false, 0);
		}

		ret = SPI_execute(action, false, 0);
		if (ret < 0)
			elog(ERROR, "SPI_execute failed with code %d", ret);

		ReleaseCurrentSubTransaction();
	}
	PG_CATCH();
	{
		ErrorData  *edata;

		MemoryContextSwitchTo(CurrentMemoryContext);
		edata = CopyErrorData();
		FlushErrorState();

		RollbackAndReleaseCurrentSubTransaction();

		oldctx = MemoryContextSwitchTo(TopTransactionContext);
		*error_msg = pstrdup(edata->message);
		MemoryContextSwitchTo(oldctx);

		FreeErrorData(edata);
		success = false;
	}
	PG_END_TRY();

	/* Always restore the original user */
	SetUserIdAndSecContext(saved_userid, saved_sec_context);

	return success;
}

/*
 * Prepare a statement on first use and keep it across SPI sessions.
 */
static SPIPlanPtr
prepare_once(SPIPlanPtr *plan, const char *sql, int nargs, Oid *argtypes)
{
	if (*plan == NULL)
	{
		*plan = SPI_prepare(sql, nargs, argtypes);
		if (*plan == NULL)
			elog(ERROR, "pg_timers: SPI_prepare failed for: %s", sql);
		SPI_keepplan(*plan);
	}
	return *plan;
}

/*
 * Single tick: process expired timers, then query next fire time.
 * Returns the timeout in milliseconds for WaitLatch.
 */
static long
tick(void)
{
	int			ret;
	int			i;
	Oid			fetch_argtypes[1] = {INT4OID};
	Datum		fetch_values[1];
	int			nprocessed;
	TimestampTz next_fire = 0;
	long		timeout_ms;

	fetch_values[0] = Int32GetDatum(pg_timers_max_per_tick);

	SetCurrentStatementStartTimestamp();
	StartTransactionCommand();

	PG_TRY();
	{
		SPI_connect();
		PushActiveSnapshot(GetTransactionSnapshot());

		/* --- Phase 1: fetch and process expired timers --- */
		prepare_once(&fetch_plan, FETCH_EXPIRED_SQL, 1, fetch_argtypes);
		ret = SPI_execute_plan(fetch_plan, fetch_values, NULL, false, 0);

		if (ret != SPI_OK_SELECT)
		{
			elog(WARNING, "pg_timers: failed to fetch expired timers");
			goto finish;
		}

		nprocessed = (int) SPI_processed;

		if (nprocessed > 0)
		{
			/*
			 * Copy the result set into TopTransactionContext so it survives
			 * subtransactions.
			 */
			MemoryContext oldctx = MemoryContextSwitchTo(TopTransactionContext);
			int64	   *ids = palloc(sizeof(int64) * nprocessed);
			int64	   *shard_keys = palloc(sizeof(int64) * nprocessed);
			char	  **actions = palloc(sizeof(char *) * nprocessed);
			char	  **scheduled_bys = palloc(sizeof(char *) * nprocessed);
			int		   *timeout_mss = palloc(sizeof(int) * nprocessed);
			bool		isnull;

			for (i = 0; i < nprocessed; i++)
			{
				char   *action_str;
				char   *scheduled_by_str;

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

				scheduled_by_str = SPI_getvalue(SPI_tuptable->vals[i],
												SPI_tuptable->tupdesc, 4);
				if (scheduled_by_str == NULL)
					elog(ERROR, "pg_timers: timer scheduled_by is NULL");

				scheduled_bys[i] = pstrdup(scheduled_by_str);

				timeout_mss[i] = DatumGetInt32(SPI_getbinval(SPI_tuptable->vals[i],
															 SPI_tuptable->tupdesc,
															 5, &isnull));
				if (isnull)
					timeout_mss[i] = 0;
			}

			MemoryContextSwitchTo(oldctx);

			/* Execute each timer and mark result */
			for (i = 0; i < nprocessed; i++)
			{
				char	   *error_msg = NULL;
				Datum		mark_values[3];

				bool		ok = execute_timer_action(actions[i],
													  scheduled_bys[i],
													  timeout_mss[i],
													  &error_msg);

				mark_values[0] = Int64GetDatum(ids[i]);
				mark_values[1] = Int64GetDatum(shard_keys[i]);

				if (ok)
				{
					Oid		fired_argtypes[2] = {INT8OID, INT8OID};

					prepare_once(&mark_fired_plan, MARK_FIRED_SQL, 2, fired_argtypes);
					ret = SPI_execute_plan(mark_fired_plan, mark_values, NULL, false, 0);
					if (ret != SPI_OK_UPDATE)
						elog(WARNING, "pg_timers: failed to mark timer %lld as fired (SPI code %d)",
							 (long long) ids[i], ret);
				}
				else
				{
					Oid		failed_argtypes[3] = {INT8OID, INT8OID, TEXTOID};

					mark_values[2] = CStringGetTextDatum(error_msg ? error_msg : "unknown error");

					prepare_once(&mark_failed_plan, MARK_FAILED_SQL, 3, failed_argtypes);
					ret = SPI_execute_plan(mark_failed_plan, mark_values, NULL, false, 0);
					if (ret != SPI_OK_UPDATE)
						elog(WARNING, "pg_timers: failed to mark timer %lld as failed (SPI code %d)",
								 (long long) ids[i], ret);

					elog(LOG, "pg_timers: timer %lld failed: %s",
						 (long long) ids[i], error_msg ? error_msg : "unknown");
				}
			}

			pfree(ids);
			pfree(shard_keys);
			/* actions and scheduled_bys freed with memory context */
		}

		/* --- Phase 2: query next fire time --- */
		prepare_once(&next_fire_plan, NEXT_FIRE_SQL, 0, NULL);
		ret = SPI_execute_plan(next_fire_plan, NULL, NULL, true, 0);
		if (ret == SPI_OK_SELECT && SPI_processed == 1)
		{
			bool	isnull;
			Datum	val = SPI_getbinval(SPI_tuptable->vals[0],
										SPI_tuptable->tupdesc,
										1, &isnull);
			if (!isnull)
				next_fire = DatumGetTimestampTz(val);
		}

finish:
		SPI_finish();
		PopActiveSnapshot();
		CommitTransactionCommand();
	}
	PG_CATCH();
	{
		ErrorData  *edata = CopyErrorData();

		FlushErrorState();
		elog(WARNING, "pg_timers: tick failed: %s", edata->message);
		FreeErrorData(edata);
		AbortCurrentTransaction();

		/* Reset shared state so next signal_worker() always wakes us */
		LWLockAcquire(pg_timers_shared->lock, LW_EXCLUSIVE);
		pg_timers_shared->next_fire_at = 0;
		LWLockRelease(pg_timers_shared->lock);

		return pg_timers_check_interval_ms > 0 ? pg_timers_check_interval_ms : INT_MAX;
	}
	PG_END_TRY();

	/* Update shared state */
	LWLockAcquire(pg_timers_shared->lock, LW_EXCLUSIVE);
	pg_timers_shared->next_fire_at = next_fire;
	LWLockRelease(pg_timers_shared->lock);

	if (next_fire == 0)
	{
		/* No pending timers — sleep until woken */
		timeout_ms = pg_timers_check_interval_ms > 0 ? pg_timers_check_interval_ms : INT_MAX;
	}
	else
	{
		long		secs;
		int			microsecs;

		TimestampDifference(GetCurrentTimestamp(), next_fire, &secs, &microsecs);

		/* Cap to INT_MAX to avoid overflow in secs * 1000 */
		if (secs > (long) INT_MAX / 1000)
			timeout_ms = INT_MAX;
		else
			timeout_ms = secs * 1000 + microsecs / 1000;

		if (timeout_ms < 0)
			timeout_ms = 0; /* already overdue */
		if (pg_timers_check_interval_ms > 0 && timeout_ms > pg_timers_check_interval_ms)
			timeout_ms = pg_timers_check_interval_ms;
	}

	return timeout_ms;
}

/*
 * Background worker entry point.
 */
void
pg_timers_bgworker_main(Datum main_arg)
{
	/* Set up signal handlers */
	pqsignal(SIGTERM, pg_timers_sigterm);
	pqsignal(SIGHUP, pg_timers_sighup);
	BackgroundWorkerUnblockSignals();

	/* Connect to the configured database */
	BackgroundWorkerInitializeConnection(pg_timers_database, NULL, 0);

	/* Register the exit callback */
	on_shmem_exit(pg_timers_worker_exit, (Datum) 0);

	/* Register our latch in shared memory */
	LWLockAcquire(pg_timers_shared->lock, LW_EXCLUSIVE);
	pg_timers_shared->bgworker_latch = MyLatch;
	pg_timers_shared->worker_attached = true;
	pg_timers_shared->worker_pid = MyProcPid;
	LWLockRelease(pg_timers_shared->lock);

	elog(LOG, "pg_timers: background worker started (pid %d)", MyProcPid);

	/* Main loop */
	while (!got_sigterm)
	{
		long		timeout_ms;
		int			rc;

		CHECK_FOR_INTERRUPTS();

		if (got_sighup)
		{
			got_sighup = false;
			ProcessConfigFile(PGC_SIGHUP);
		}

		timeout_ms = tick();

		rc = WaitLatch(MyLatch,
					   WL_LATCH_SET | WL_TIMEOUT | WL_POSTMASTER_DEATH,
					   timeout_ms,
					   PG_WAIT_EXTENSION);

		ResetLatch(MyLatch);

		if (rc & WL_POSTMASTER_DEATH)
			proc_exit(1);
	}

	elog(LOG, "pg_timers: background worker shutting down");
	proc_exit(0);
}
