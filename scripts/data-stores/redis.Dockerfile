# Thin wrapper so the `redis` Railway service builds via Dockerfile path
# (uniform with hospital-postgres / tenant-postgres / rabbitmq), instead of
# needing the dashboard's Source-Image dance.
#
# The `redis:7-alpine` default config has `bind 127.0.0.1 ::1` AND
# `protected-mode yes` — so the daemon refuses connections from other
# containers on Railway's private network. Override both via CMD so
# conversation-chat can actually reach it. No auth is needed because the
# service has no public domain — only `*.railway.internal` reaches it.
FROM redis:7-alpine

EXPOSE 6379
CMD ["redis-server", "--bind", "0.0.0.0", "--protected-mode", "no"]
