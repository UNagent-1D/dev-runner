# Custom Postgres image for the `tenant-postgres` Railway service.
# Build context is the umbrella repo root (set by the bootstrap script
# when it creates the Railway service); paths are relative to that.
#
# Postgres runs every *.sql file under /docker-entrypoint-initdb.d/ exactly
# once, on the first boot of an empty data volume. Subsequent restarts
# reuse the existing volume and skip the init step.
FROM postgres:16-alpine

COPY Tenant/sql/init_schema.sql /docker-entrypoint-initdb.d/01_init_schema.sql
