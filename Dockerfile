ARG PG_MAJOR=18
FROM postgres:${PG_MAJOR}

ARG PG_MAJOR=18

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    postgresql-server-dev-${PG_MAJOR} \
    postgresql-${PG_MAJOR}-pgtap \
    libtap-parser-sourcehandler-pgtap-perl \
    && rm -rf /var/lib/apt/lists/*

COPY . /build/pg_timers
WORKDIR /build/pg_timers
RUN make USE_PGXS=1 clean && make USE_PGXS=1 && make USE_PGXS=1 install

COPY docker-entrypoint-initdb.d/ /docker-entrypoint-initdb.d/

RUN mkdir -p /t && cp t/*.sql /t/

RUN apt-get purge -y --auto-remove build-essential postgresql-server-dev-${PG_MAJOR} \
    && rm -rf /build /var/lib/apt/lists/*

RUN echo "shared_preload_libraries = 'pg_timers'" >> /usr/share/postgresql/postgresql.conf.sample \
    && echo "pg_timers.database = 'postgres'" >> /usr/share/postgresql/postgresql.conf.sample
