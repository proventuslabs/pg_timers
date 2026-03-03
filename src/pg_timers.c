/*
 * pg_timers.c — _PG_init, GUCs, shared memory hooks, bgworker registration
 */

#include "postgres.h"

#include "miscadmin.h"
#include "postmaster/bgworker.h"
#include "storage/ipc.h"
#include "storage/latch.h"
#include "storage/lwlock.h"
#include "storage/shmem.h"
#include "utils/guc.h"

#include "pg_timers.h"

PG_MODULE_MAGIC;

/* GUC variables */
char	   *pg_timers_database = NULL;
int			pg_timers_max_per_tick = 64;
int			pg_timers_check_interval_ms = 0;

/* Shared state */
PgTimersSharedState *pg_timers_shared = NULL;

/* Shmem hooks — previous values in chain */
static shmem_request_hook_type prev_shmem_request_hook = NULL;
static shmem_startup_hook_type prev_shmem_startup_hook = NULL;

/*
 * How much shared memory we need.
 */
static Size
pg_timers_shmem_size(void)
{
	return MAXALIGN(sizeof(PgTimersSharedState));
}

/*
 * Request shared memory (PG 15+ hook).
 */
static void
pg_timers_shmem_request(void)
{
	if (prev_shmem_request_hook)
		prev_shmem_request_hook();

	RequestAddinShmemSpace(pg_timers_shmem_size());
	RequestNamedLWLockTranche("pg_timers", 1);
}

/*
 * Initialize shared memory segment.
 */
static void
pg_timers_shmem_startup(void)
{
	bool		found;

	if (prev_shmem_startup_hook)
		prev_shmem_startup_hook();

	LWLockAcquire(AddinShmemInitLock, LW_EXCLUSIVE);

	pg_timers_shared = (PgTimersSharedState *)
		ShmemInitStruct("pg_timers",
						pg_timers_shmem_size(),
						&found);

	if (!found)
	{
		memset(pg_timers_shared, 0, sizeof(PgTimersSharedState));
		pg_timers_shared->lock = &(GetNamedLWLockTranche("pg_timers"))->lock;
		pg_timers_shared->bgworker_latch = NULL;
		pg_timers_shared->next_fire_at = 0;
		pg_timers_shared->worker_attached = false;
		pg_timers_shared->worker_pid = 0;
	}

	LWLockRelease(AddinShmemInitLock);
}

/*
 * Attach to shared memory if not already attached.
 * Called lazily from backend SQL functions that need shared state.
 * During shared_preload_libraries loading, pg_timers_shared is set by the
 * shmem_startup hook. But when the .so is loaded later via CREATE EXTENSION
 * in a backend, the global is NULL and we need to look it up.
 */
static void
pg_timers_attach_shmem(void)
{
	bool		found;

	if (pg_timers_shared)
		return;

	pg_timers_shared = (PgTimersSharedState *)
		ShmemInitStruct("pg_timers",
						pg_timers_shmem_size(),
						&found);

	if (!found)
		elog(ERROR, "pg_timers: shared memory not initialized (not in shared_preload_libraries?)");
}

/*
 * Signal the bgworker if new_fire_at is sooner than the current next_fire_at.
 * Called from backend SQL functions after inserting a timer.
 */
void
pg_timers_signal_worker(TimestampTz new_fire_at)
{
	Latch	   *latch = NULL;
	pid_t		pid = 0;

	pg_timers_attach_shmem();

	LWLockAcquire(pg_timers_shared->lock, LW_EXCLUSIVE);

	if (pg_timers_shared->worker_attached &&
		(pg_timers_shared->next_fire_at == 0 ||
		 new_fire_at < pg_timers_shared->next_fire_at))
	{
		pg_timers_shared->next_fire_at = new_fire_at;
		latch = pg_timers_shared->bgworker_latch;
		pid = pg_timers_shared->worker_pid;
	}

	LWLockRelease(pg_timers_shared->lock);

	/* Signal outside the lock */
	if (latch && pid > 0)
	{
		/* Verify the process is still alive before touching its latch */
		if (kill(pid, 0) == 0)
			SetLatch(latch);
	}
}

/*
 * Module initialization — called when shared_preload_libraries loads us.
 */
void
_PG_init(void)
{
	BackgroundWorker worker;

	if (!process_shared_preload_libraries_in_progress)
		return;

	/* Define GUCs */
	DefineCustomStringVariable(
		"pg_timers.database",
		"Database the pg_timers background worker connects to.",
		NULL,
		&pg_timers_database,
		"postgres",
		PGC_POSTMASTER,
		0,
		NULL, NULL, NULL);

	DefineCustomIntVariable(
		"pg_timers.max_timers_per_tick",
		"Maximum number of timers to process per wake cycle.",
		NULL,
		&pg_timers_max_per_tick,
		64,
		1, 10000,
		PGC_SIGHUP,
		0,
		NULL, NULL, NULL);

	DefineCustomIntVariable(
		"pg_timers.check_interval_ms",
		"Maximum sleep time in milliseconds between checks (0 = no cap).",
		NULL,
		&pg_timers_check_interval_ms,
		0,
		0, INT_MAX,
		PGC_SIGHUP,
		0,
		NULL, NULL, NULL);

	MarkGUCPrefixReserved("pg_timers");

	/* Install shmem hooks */
	prev_shmem_request_hook = shmem_request_hook;
	shmem_request_hook = pg_timers_shmem_request;

	prev_shmem_startup_hook = shmem_startup_hook;
	shmem_startup_hook = pg_timers_shmem_startup;

	/* Register background worker */
	memset(&worker, 0, sizeof(BackgroundWorker));
	snprintf(worker.bgw_name, BGW_MAXLEN, "pg_timers worker");
	snprintf(worker.bgw_type, BGW_MAXLEN, "pg_timers worker");
	snprintf(worker.bgw_library_name, BGW_MAXLEN, "pg_timers");
	snprintf(worker.bgw_function_name, BGW_MAXLEN, "pg_timers_bgworker_main");

	worker.bgw_flags = BGWORKER_SHMEM_ACCESS | BGWORKER_BACKEND_DATABASE_CONNECTION;
	worker.bgw_start_time = BgWorkerStart_RecoveryFinished;
	worker.bgw_restart_time = 5;		/* restart after 5s on crash */
	worker.bgw_main_arg = (Datum) 0;
	worker.bgw_notify_pid = 0;

	RegisterBackgroundWorker(&worker);
}
