MODULE_big = pg_timers
OBJS = src/pg_timers.o src/bgworker.o src/functions.o

EXTENSION = pg_timers
EXTVERSION = $(shell cat version.txt)
DATA = sql/$(EXTENSION)--$(EXTVERSION).sql
MIGRATIONS = $(sort $(wildcard sql/migrations/*.sql))

PG_CPPFLAGS = -I$(srcdir)/src

ifdef USE_PGXS
PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
else
subdir = contrib/pg_timers
top_builddir = ../..
-include $(top_builddir)/src/Makefile.global
-include $(top_srcdir)/contrib/contrib-global.mk
endif

# Stitch migrations into versioned install file
all: sql/$(EXTENSION)--$(EXTVERSION).sql

sql/$(EXTENSION)--$(EXTVERSION).sql: $(MIGRATIONS) version.txt
	cat $(MIGRATIONS) > $@

clean: clean-versioned-sql
.PHONY: clean-versioned-sql
clean-versioned-sql:
	rm -f sql/$(EXTENSION)--*.sql

.PHONY: dev test psql down build

dev:
	docker compose --profile dev up --build -d

test:
	docker compose --profile test run --rm test

psql:
	docker exec -it pg_timers-dev psql -U postgres -d testdb

down:
	docker compose --profile dev down -v

build:
	$(MAKE) USE_PGXS=1 all
