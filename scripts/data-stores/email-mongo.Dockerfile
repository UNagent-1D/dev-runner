# Thin wrapper — uniform Dockerfile-based deploy for the `email-mongo`
# Railway service. Used by UN_email_send_ms (audit log) AND Compliance
# (audit_logs collection), mirroring the local compose topology.
FROM mongo:7
