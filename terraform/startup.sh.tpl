#!/bin/bash
set -euxo pipefail
apt-get update && apt-get install -y python3-venv curl

# Ops Agent (ships logs + memory/CPU metrics to Cloud Logging / Monitoring)
if ! systemctl list-unit-files | grep -q google-cloud-ops-agent; then
  curl -sSO https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh
  bash add-google-cloud-ops-agent-repo.sh --also-install
fi

mkdir -p /opt/sample-app /var/log/sample-app
gcloud storage cp gs://${build_bucket}/app/app.py /opt/sample-app/app.py
python3 -m venv /opt/sample-app/venv
/opt/sample-app/venv/bin/pip install flask gunicorn

# Tail the JSON log file; the log name in Cloud Logging will be "sample_app"
cat > /etc/google-cloud-ops-agent/config.yaml <<'CFG'
logging:
  receivers:
    sample_app:
      type: files
      include_paths: [/var/log/sample-app/app.log]
  processors:
    parse_json:
      type: parse_json
  service:
    pipelines:
      sample_app:
        receivers: [sample_app]
        processors: [parse_json]
CFG
systemctl restart google-cloud-ops-agent

cat > /etc/systemd/system/sample-app.service <<'UNIT'
[Unit]
Description=Sample app
After=network.target

[Service]
WorkingDirectory=/opt/sample-app
ExecStart=/opt/sample-app/venv/bin/gunicorn -w 2 -b 0.0.0.0:8080 app:app
StandardOutput=append:/var/log/sample-app/app.log
StandardError=append:/var/log/sample-app/app.log
Restart=always

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now sample-app
