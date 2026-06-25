# edge-ai-analysis image

The container source for the `edge-ai-analysis` optional service — a stateless FastAPI
wrapper that turns the edge-AI Ollama model server into task-oriented **analysis
verdicts** for the mesh. See [../../../../docs/EDGE-AI.md](../../../../docs/EDGE-AI.md)
("Analysis API") and `../configmap.yaml` for the verdict schema.

## Endpoints
- `POST /v1/analyze/image/classify` — NSFW/abuse/policy classification (llava vision)
- `POST /v1/analyze/image/hash` — perceptual hashes (pHash/aHash/dHash; CPU only)
- `POST /v1/analyze/content/moderate` — classify + hash → `allow|flag|reject` (**fail-closed**)
- `POST /v1/analyze/log/summarize` — log/anomaly triage (llama reasoning)
- `GET /healthz` (liveness) · `GET /readyz` (ready iff the edge-AI upstream answers)

Tenancy is enforced at the be-gateway (`/v1/analyze/** = ROLE_USER`); this service
trusts and stamps the gateway-validated `X-Tenant-ID` / `X-User-ID` headers.

## Build
```sh
docker build -t registry.snapdragon.systems/snapdragon/edge-ai-analysis:main .
docker push  registry.snapdragon.systems/snapdragon/edge-ai-analysis:main
```
Then select the slug (`--with-edge-ai-analysis` / `--optional-services edge-ai-analysis`)
and ArgoCD deploys it alongside the edge-ai node. Until the image is pushed, keep the
slug **deselected** (its DEFAULT-OFF state) so no node tries to pull it.

## Run locally
```sh
pip install -r requirements.txt
EDGE_AI_UPSTREAM=http://localhost:11434 uvicorn app:app --port 8080
```
