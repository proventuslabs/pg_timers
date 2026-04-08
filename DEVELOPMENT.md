# Development Guide

## Overview

pg_timers is a PostgreSQL C extension. The development setup uses two tools with distinct roles:

- **Nix** — provides a reproducible native toolchain (compiler, pg_config, make) for editor integration and local compilation. Activated automatically via direnv.
- **Docker** — runs everything at runtime: dev postgres, tests, and all container image builds.

---

## For Humans

### Prerequisites

- [Nix](https://nixos.org/download) with flakes enabled
- [direnv](https://direnv.net/) hooked into your shell
- Docker

### First time

```bash
git clone https://github.com/proventuslabs/pg_timers
cd pg_timers       # direnv activates the Nix dev shell automatically
```

direnv will ask you to `direnv allow` on first entry. After that, every `cd` into the project gives you `gcc`, `pg_config`, `make`, and the correct PostgreSQL headers in your environment — no Docker needed for editing.

### Daily workflow

**Start a dev postgres:**
```bash
make dev           # builds and starts postgres on port 5433
make psql          # open a psql session
make down          # stop and remove containers + volumes
```

The dev container has pg_timers and pgTAP pre-installed. Any source change requires a rebuild:
```bash
make down && make dev
```

**Run the test suite:**
```bash
make test          # runs all pgTAP tests via docker compose
```

Tests run against the same Debian-based postgres image as the release build — so a failure here is a real failure, not an environment mismatch.

**Test against a specific PostgreSQL version:**
```bash
PG_MAJOR=15 make test
PG_MAJOR=16 make test
PG_MAJOR=17 make test
PG_MAJOR=18 make test   # default
```

**Local compilation (without Docker):**

Useful for fast feedback while editing C code. The Nix shell provides everything needed:
```bash
make USE_PGXS=1 all      # compile
make USE_PGXS=1 clean    # clean build artifacts
```

This does not install anything — it just confirms the code compiles. Tests still run via Docker.

**Switch PostgreSQL version in the dev shell:**
```bash
nix develop .#pg15   # or pg16, pg17, pg18
```

### Editor / LSP setup

The Nix dev shell puts the correct `pg_config` and PostgreSQL headers in your environment. clangd picks this up automatically for C language server support (go-to-definition, diagnostics, autocomplete on PostgreSQL internals).

No additional configuration needed for Neovim, Emacs, or any editor that uses clangd.

### Writing migrations

Migrations are append-only SQL files under `sql/migrations/`. They are concatenated in filename order to produce the versioned install file at build time.

```
sql/migrations/001_table.sql
sql/migrations/002_functions.sql
sql/migrations/003_permissions.sql
004_your_change.sql   ← add here
```

Never edit existing migration files. Never edit `sql/pg_timers--*.sql` directly — it is generated.

### Releasing

Releases are fully automated via release-please. Merge commits with conventional commit messages (`feat:`, `fix:`, etc.) accumulate into a release PR. Merging that PR:

1. Bumps the version in `pg_timers.control` and `META.json`
2. Creates a GitHub release and tag
3. Triggers the release workflow: builds and pushes multi-arch Docker images to GHCR, publishes to PGXN

---

## For Agents

### Environment

You are operating in a repository with a Nix flake and Docker-based runtime. Do not install tools locally. Do not use `nix run`. The flake is for human tooling only.

### How to run things

| Task | Command |
|---|---|
| Run tests | `make test` or `PG_MAJOR=<ver> docker compose --profile test run --rm test` |
| Start dev postgres | `make dev` |
| Connect to dev postgres | `make psql` |
| Stop everything | `make down` |
| Compile locally (check only) | `make USE_PGXS=1 all` (requires `nix develop` shell) |

### Making changes

**C source** — edit files in `src/`. Rebuild the dev container to test: `make down && make test`.

**SQL** — add a new migration file in `sql/migrations/` with the next number prefix. Never edit existing migrations or the generated `sql/pg_timers--*.sql`.

**Init scripts** — scripts in `docker-entrypoint-initdb.d/` run once when the dev postgres container is first initialised. Add numbered files (`02_*.sh`, `03_*.sh`) for additional setup. These are dev-only — they are not included in the release image.

**Tests** — add or edit `.sql` files in `t/`. Run with `make test`.

**Extension metadata** — `pg_timers.control` is the source of truth for the version. Do not edit `default_version` manually — release-please owns it.

### Checks before finishing

```bash
make test          # all 5 test files must pass
make down          # clean up
```

If tests fail, check container logs:
```bash
docker compose --profile dev logs
```
