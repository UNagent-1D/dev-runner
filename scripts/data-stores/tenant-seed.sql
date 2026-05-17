-- Seed the default demo admin so the SPA's "demo user" works out of the box.
-- Runs as /docker-entrypoint-initdb.d/02_seed_demo.sql on a fresh tenant-postgres
-- volume; also safe to re-run manually (every statement is idempotent).
--
-- Password is `demo1234`, hashed with bcrypt via pgcrypto. Go's
-- bcrypt.CompareHashAndPassword accepts the $2a$ output of crypt(... 'bf').

CREATE EXTENSION IF NOT EXISTS pgcrypto;

INSERT INTO users (email, password_hash, first_name, last_name)
VALUES
  ('admin@demo.com',   crypt('demo1234', gen_salt('bf', 10)), 'Demo', 'Admin'),
  ('admin@demo.local', crypt('demo1234', gen_salt('bf', 10)), 'Demo', 'Admin')
ON CONFLICT (email) DO NOTHING;

INSERT INTO user_tenants (user_id, tenant_id, role)
SELECT id, NULL, 'app_admin'
FROM users
WHERE email IN ('admin@demo.com', 'admin@demo.local')
ON CONFLICT (user_id, tenant_id) DO NOTHING;
