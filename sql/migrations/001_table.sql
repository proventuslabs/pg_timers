-- Schema "timers" is created automatically via the control file.

CREATE TABLE timers.timers (
    id              bigint GENERATED ALWAYS AS IDENTITY,
    shard_key       bigint NOT NULL DEFAULT 0,
    fire_at         timestamptz NOT NULL,
    action          text NOT NULL CHECK (action <> ''),
    scheduled_by    name NOT NULL DEFAULT session_user,
    timeout_ms      integer NOT NULL DEFAULT 0,   -- statement timeout for this action (0=no limit)
    status          smallint NOT NULL DEFAULT 0,  -- 0=pending, 1=fired, 2=failed, 3=cancelled
    created_at      timestamptz NOT NULL DEFAULT clock_timestamp(),
    fired_at        timestamptz,
    error           text,
    PRIMARY KEY (shard_key, id)
);

CREATE INDEX timers_pending_idx
    ON timers.timers (fire_at)
    WHERE status = 0;
