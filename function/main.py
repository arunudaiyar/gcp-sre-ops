"""AI Ops Assistant - Cloud Run function (HTTP).
Flow: question -> logs/metrics -> runbooks/docs/incidents -> Gemini on Vertex AI -> root cause + steps."""
import os, re, time, datetime as dt
from collections import Counter, defaultdict

import functions_framework
from flask import jsonify
from google import genai
from google.genai import types
from google.cloud import logging as cloud_logging
from google.cloud import monitoring_v3, storage

PROJECT = os.environ["PROJECT_ID"]
REGION = os.environ.get("REGION", "us-central1")
VERTEX_LOCATION = os.environ.get("VERTEX_LOCATION", "global")
MODEL = os.environ.get("GEMINI_MODEL", "gemini-3.5-flash-lite")   # set to any model available in your region
KB_BUCKET = os.environ["KNOWLEDGE_BUCKET"]
APP_LOG = os.environ.get("APP_LOG_NAME", "sample_app")

log_client = cloud_logging.Client(project=PROJECT)
mon_client = monitoring_v3.MetricServiceClient()
gcs = storage.Client(project=PROJECT)
llm = genai.Client(vertexai=True, project=PROJECT, location=VERTEX_LOCATION)

CORS = {"Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Headers": "Content-Type, Authorization",
        "Access-Control-Allow-Methods": "POST, OPTIONS"}


# ---------- 1. Logs + latency ----------
def collect_logs(minutes):
    since = (dt.datetime.now(dt.timezone.utc) - dt.timedelta(minutes=minutes)).isoformat()
    flt = f'logName="projects/{PROJECT}/logs/{APP_LOG}" AND timestamp>="{since}"'
    entries = list(log_client.list_entries(filter_=flt, order_by=cloud_logging.DESCENDING, max_results=1000))

    lat, errs, status = defaultdict(list), Counter(), Counter()
    samples = []
    for e in entries:
        p = e.payload if isinstance(e.payload, dict) else {"message": str(e.payload)}
        if "latency_ms" in p:
            lat[p.get("path", "?")].append(p["latency_ms"])
            status[(p.get("path"), p.get("status"))] += 1
        if e.severity in ("ERROR", "CRITICAL", "WARNING"):
            errs[(e.severity, p.get("message", "")[:160])] += 1
            if len(samples) < 8:
                samples.append(f'{e.timestamp:%H:%M:%S} {e.severity} {p.get("message", "")[:200]}')

    def pct(v, q):
        v = sorted(v)
        return v[min(len(v) - 1, int(len(v) * q))]

    latency = {path: {"count": len(v), "p50_ms": pct(v, .5), "p95_ms": pct(v, .95), "max_ms": max(v)}
               for path, v in lat.items()}
    return {
        "entries_scanned": len(entries),
        "latency_by_path": latency,
        "status_counts": {f"{p} {s}": n for (p, s), n in status.most_common(10)},
        "top_warnings_errors": [{"severity": s, "message": m, "count": n} for (s, m), n in errs.most_common(8)],
        "recent_samples": samples,
    }


# ---------- 2. Metrics ----------
def metric_summary(metric_type, minutes, extra_filter=""):
    now = int(time.time())
    interval = monitoring_v3.TimeInterval({"end_time": {"seconds": now}, "start_time": {"seconds": now - minutes * 60}})
    agg = monitoring_v3.Aggregation({"alignment_period": {"seconds": 60},
                                     "per_series_aligner": monitoring_v3.Aggregation.Aligner.ALIGN_MEAN})
    series = mon_client.list_time_series(request={
        "name": f"projects/{PROJECT}",
        "filter": f'metric.type="{metric_type}" {extra_filter}',
        "interval": interval, "aggregation": agg,
        "view": monitoring_v3.ListTimeSeriesRequest.TimeSeriesView.FULL})
    vals = [p.value.double_value for ts in series for p in ts.points]
    if not vals:
        return None
    return {"avg": round(sum(vals) / len(vals), 3), "max": round(max(vals), 3), "points": len(vals)}


def collect_metrics(minutes):
    return {
        "vm_cpu_utilization (0-1)": metric_summary("compute.googleapis.com/instance/cpu/utilization", minutes),
        "vm_memory_used_percent": metric_summary("agent.googleapis.com/memory/percent_used", minutes,
                                                 'AND metric.labels.state="used"'),
    }


# ---------- 3. Knowledge (runbooks, architecture, past incidents) ----------
def load_knowledge(question, evidence_text, top_k=4):
    """Naive keyword retrieval from GCS. Swap for Vertex AI RAG Engine / Vertex AI Search in production."""
    terms = set(re.findall(r"[a-z]{4,}", (question + " " + evidence_text).lower()))
    scored = []
    for blob in gcs.bucket(KB_BUCKET).list_blobs():
        if not blob.name.endswith((".md", ".txt")):
            continue
        text = blob.download_as_text()
        words = set(re.findall(r"[a-z]{4,}", text.lower()))
        scored.append((len(terms & words), blob.name, text[:4000]))
    scored.sort(reverse=True)
    return [(name, text) for score, name, text in scored[:top_k] if score > 0]


# ---------- 4. Reasoning ----------
SYSTEM = ("You are an SRE assistant. Use ONLY the evidence provided (logs, metrics, latency, runbooks, "
          "architecture, past incidents). Give: 1) Most likely root cause, 2) Evidence that supports it, "
          "3) Numbered diagnostic steps, 4) Suggested fix / mitigation, 5) Confidence and what is unknown. "
          "If the evidence does not show a problem, say so. Never invent data.")


def diagnose(question, minutes):
    logs = collect_logs(minutes)
    metrics = collect_metrics(minutes)
    evidence = f"LOGS & LATENCY:\n{logs}\n\nMETRICS:\n{metrics}"
    docs = load_knowledge(question, evidence)
    kb = "\n\n".join(f"--- {n} ---\n{t}" for n, t in docs) or "(no matching documents)"
    prompt = f"Question: {question}\nWindow: last {minutes} minutes\n\n{evidence}\n\nKNOWLEDGE BASE:\n{kb}"
    resp = llm.models.generate_content(
        model=MODEL, contents=prompt,
        config=types.GenerateContentConfig(system_instruction=SYSTEM, temperature=0.2))
    return {"answer": resp.text, "evidence": {"logs": logs, "metrics": metrics, "docs_used": [n for n, _ in docs]}}


@functions_framework.http
def ask(request):
    if request.method == "OPTIONS":
        return ("", 204, CORS)
    body = request.get_json(silent=True) or {}
    question = (body.get("question") or "").strip()
    if not question:
        return (jsonify(error="question is required"), 400, CORS)
    minutes = max(5, min(int(body.get("window_minutes", 30)), 180))
    try:
        return (jsonify(diagnose(question, minutes)), 200, CORS)
    except Exception as exc:                      # surface cause to the UI while you are developing
        return (jsonify(error=f"{type(exc).__name__}: {exc}"), 500, CORS)
