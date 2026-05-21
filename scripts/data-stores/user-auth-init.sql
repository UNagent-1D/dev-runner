-- Runs as the LAST file under /docker-entrypoint-initdb.d on a fresh
-- tenant-postgres volume. Creates a separate `user_auth` database that
-- the User-Auth microservice owns, plus its single `users_info` table.
--
-- Kept inside tenant-postgres (instead of spinning up a third Postgres
-- container) because User-Auth is a small read-mostly catalog of
-- (email, document, tenant_slug) tuples — no operational reason for a
-- dedicated instance in local dev.

CREATE DATABASE user_auth;

\c user_auth

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

CREATE TABLE IF NOT EXISTS users_info (
    user_id        UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    tenant_id      UUID NOT NULL,
    tenant_slug    VARCHAR(64) NOT NULL,
    user_name      VARCHAR(64) NOT NULL,
    user_last_name VARCHAR(64) NOT NULL,
    user_document  VARCHAR(64) UNIQUE NOT NULL,
    user_email     VARCHAR(64) UNIQUE NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_users_info_tenant_id ON users_info(tenant_id);
CREATE INDEX IF NOT EXISTS idx_users_info_document  ON users_info(user_document);
CREATE INDEX IF NOT EXISTS idx_users_info_email     ON users_info(user_email);
