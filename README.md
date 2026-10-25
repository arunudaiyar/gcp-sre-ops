# AI Ops Assistant on GCP

```
Browser -> Cloud Storage (web UI) -> Cloud Run function -> Cloud Logging + Cloud Monitoring
                                                        -> GCS knowledge bucket (runbooks, architecture, incidents)
                                                        -> Gemini on Vertex AI -> root cause + steps
Compute Engine VM (sample-app + Ops Agent) -> Cloud Logging / Monitoring
```

## Deploy
```bash
gcloud auth application-default login
cd terraform
terraform init
terraform apply -var project_id=YOUR_PROJECT -var allowed_cidr="YOUR_IP/32"
```
Wait 3-4 minutes after apply for the VM startup script and Ops Agent.

## Try it
```bash
APP=$(terraform output -raw app_url)
for i in $(seq 1 30); do curl -s $APP/api/orders >/dev/null; curl -s $APP/api/checkout >/dev/null; done   # healthy baseline
curl $APP/fault/on                                                                                          # inject the problem
for i in $(seq 1 15); do curl -s $APP/api/checkout >/dev/null & done; wait                                  # generate slow/failing traffic
```
Open `terraform output web_url` and ask: "Why is checkout slow and returning errors?"
Turn it off with `curl $APP/fault/off`.

## Demo shortcuts to replace before real use
- Function is public (`allow_unauthenticated=true`). Put API Gateway + Identity Platform JWT validation in front and set it to false.
- Web bucket is public. Use a load balancer + Cloud CDN, Firebase Hosting, or IAP.
- Knowledge retrieval is keyword matching. Move to Vertex AI RAG Engine / Vertex AI Search.
- If the function build fails with a permissions error, grant the default compute service account
  `roles/cloudbuild.builds.builder` (and `roles/logging.logWriter`, `roles/artifactregistry.writer`).
