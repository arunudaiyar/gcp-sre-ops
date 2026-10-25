# Architecture: sample-app
Single Compute Engine VM running Flask under gunicorn (port 8080). Endpoints: /api/orders (reads), /api/checkout
(writes, depends on the orders database with a connection pool of 10). Logs go to Cloud Logging through the Ops Agent.
Normal latency: orders p95 under 200ms, checkout p95 under 300ms.
