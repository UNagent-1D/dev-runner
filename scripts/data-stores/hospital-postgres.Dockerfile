# Custom Postgres image for the `hospital-postgres` Railway service.
# Build context is the umbrella repo root (set by the bootstrap script
# when it creates the Railway service); paths are relative to that.
#
# Mirrors the compose mount in docker-compose.yml:32-33 so behavior is
# identical between local and Railway: schema applied first, seed second.
FROM postgres:16-alpine

COPY Hospital-MP/schema.sql /docker-entrypoint-initdb.d/01_schema.sql
COPY Hospital-MP/seed.sql   /docker-entrypoint-initdb.d/02_seed.sql
