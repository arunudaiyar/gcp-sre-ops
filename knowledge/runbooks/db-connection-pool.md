# Runbook: Checkout slow or failing (DB connection pool exhausted)
Symptoms: /api/checkout p95 latency above 2s, HTTP 503, log "db connection pool exhausted".
Diagnose:
1. Compare checkout latency with /api/orders. If only checkout is slow, the DB path is the suspect.
2. Check database connections in use vs pool size; look for long-running queries or locks.
3. Check whether a recent deploy changed pool size or query patterns.
Mitigate: restart the app service (sudo systemctl restart sample-app), kill long-running queries, raise pool size temporarily.
Escalate to the database on-call if connections stay saturated after restart.
