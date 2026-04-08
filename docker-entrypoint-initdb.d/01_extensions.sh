#!/bin/bash
set -e

psql -v ON_ERROR_STOP=1 -U postgres -d "${POSTGRES_DB:-postgres}" <<-SQL
    CREATE EXTENSION IF NOT EXISTS pg_timers;
    CREATE EXTENSION IF NOT EXISTS pgtap;
SQL
