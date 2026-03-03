#ifndef PG_TIMERS_H
#define PG_TIMERS_H

#include "postgres.h"
#include "storage/latch.h"
#include "storage/lwlock.h"
#include "utils/timestamp.h"

/* Timer status values */
#define TIMER_STATUS_PENDING   0
#define TIMER_STATUS_FIRED     1
#define TIMER_STATUS_FAILED    2
#define TIMER_STATUS_CANCELLED 3

/* Shared memory state for coordinating backends with the bgworker */
typedef struct PgTimersSharedState
{
	LWLock	   *lock;
	Latch	   *bgworker_latch;
	TimestampTz next_fire_at;		/* earliest pending timer, 0 = none */
	bool		worker_attached;
	pid_t		worker_pid;
} PgTimersSharedState;

/* GUC variables — defined in pg_timers.c */
extern char *pg_timers_database;
extern int	pg_timers_max_per_tick;
extern int	pg_timers_check_interval_ms;

/* Shared state — set up in pg_timers.c shmem hooks */
extern PgTimersSharedState *pg_timers_shared;

/* Utility: signal the bgworker if a new timer is sooner than next_fire_at */
extern void pg_timers_signal_worker(TimestampTz new_fire_at);

/* Background worker entry point — defined in bgworker.c */
extern PGDLLEXPORT void pg_timers_bgworker_main(Datum main_arg);

#endif /* PG_TIMERS_H */
