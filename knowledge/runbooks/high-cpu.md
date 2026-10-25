# Runbook: High CPU on VM
Symptoms: cpu utilization above 0.85 for 5+ minutes. Check top processes with `top`, look for runaway gunicorn workers,
check for traffic spikes in request counts, scale up the VM or add instances if load is legitimate.
