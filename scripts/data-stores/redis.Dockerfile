# Thin wrapper so the `redis` Railway service builds via Dockerfile path
# (uniform with hospital-postgres / tenant-postgres / rabbitmq), instead of
# needing the dashboard's Source-Image dance.
FROM redis:7-alpine
