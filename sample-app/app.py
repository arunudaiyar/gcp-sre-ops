"""Tiny demo service for the GCP VM. Emits JSON logs that the Ops Agent ships to Cloud Logging.
Toggle a fault with GET /fault/on and GET /fault/off to produce slow requests + errors."""
import json, os, random, time
from flask import Flask, request, jsonify

app = Flask(__name__)
FAULT_FLAG = "/tmp/sample-app-fault"   # file flag so all gunicorn workers agree


def log(severity, message, **fields):
    print(json.dumps({"severity": severity, "message": message, **fields}), flush=True)


@app.before_request
def _start():
    request._t0 = time.time()


@app.after_request
def _log_request(resp):
    ms = round((time.time() - request._t0) * 1000)
    sev = "ERROR" if resp.status_code >= 500 else "INFO"
    log(sev, f"{request.method} {request.path} -> {resp.status_code}",
        path=request.path, status=resp.status_code, latency_ms=ms)
    return resp


@app.route("/")
def index():
    return jsonify(service="sample-app", fault=os.path.exists(FAULT_FLAG))


@app.route("/health")
def health():
    return "ok"


@app.route("/api/orders")
def orders():
    time.sleep(random.uniform(0.03, 0.15))
    return jsonify(orders=[1, 2, 3])


@app.route("/api/checkout")
def checkout():
    if os.path.exists(FAULT_FLAG):
        time.sleep(random.uniform(2.5, 5))              # simulated slow DB
        if random.random() < 0.6:
            log("ERROR", "db connection pool exhausted: timeout acquiring connection (pool_size=10, in_use=10)",
                component="db", path="/api/checkout")
            return jsonify(error="upstream timeout"), 503
    else:
        time.sleep(random.uniform(0.05, 0.2))
    return jsonify(status="paid")


@app.route("/fault/<state>")
def fault(state):
    if state == "on":
        open(FAULT_FLAG, "w").close()
    elif os.path.exists(FAULT_FLAG):
        os.remove(FAULT_FLAG)
    log("WARNING", f"fault mode set to {state}")
    return jsonify(fault=state)
