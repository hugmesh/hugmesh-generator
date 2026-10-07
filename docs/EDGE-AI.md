# Edge-AI — GPU inference node serving a model API to the mesh

The **edge-AI** capability adds a GPU **inference node** to the HugMesh mesh: a
node that runs an [Ollama](https://ollama.com)-based inference server and exposes an
**OpenAI-compatible model API** (`/v1/chat/completions`, `/v1/embeddings`,
`/v1/models`) to every other node and device — over **Kubernetes** (in-cluster
ClusterIP) **and** the **tailnet** (a gateway host route). It also installs the GPU
device plugin that makes the node's NVIDIA GPU **schedulable for the existing
GPU-hungry services** (owncast video transcode, coturn/Matrix A/V, LocalTube
yt-dlp transcode, and future voice STT/TTS).

It ships as two cooperating pieces:

| Piece | What it is | Where |
|---|---|---|
| `edge-ai` **node role** | a `backend-gpu`-class worker whose purpose is inference: NVIDIA proprietary + CUDA + the containerd `nvidia` runtime + `app-containers/nvidia-container-toolkit`, labelled `hugmesh.net/edge-ai=true`, and it **auto-selects** the `edge-ai` service | `build-x86-host-stage4.sh --role edge-ai` |
| `edge-ai` **optional service** | the cluster workload: an Ollama Deployment + Service + the model-library ConfigMap, GPU-scheduled, fronted by the `ai.<domain>` gateway route. DEFAULT-OFF, GPU-gated | `specs/cluster/{apps/54-edge-ai.yaml, manifests/edge-ai/}` |

Both run unchanged on **x86_64** (e.g. the RTX-4060 host) and on the **NVIDIA
Jetson Orin Nano** (arm64 — see *Jetson* below). The role/service is the shared
core; the Jetson platform bring-up is additive.

> Running Ollama on your own desktop for a coding assistant, rather than serving the
> mesh, is covered in [LOCAL-AI-ASSISTANT.md](LOCAL-AI-ASSISTANT.md).

---

## 1. Build an edge-AI node

```bash
# Dedicated inference node (NVIDIA + CUDA + edge-ai service auto-selected):
./build-x86-host-stage4.sh --role edge-ai

# Tune the model library at build time:
./build-x86-host-stage4.sh --role edge-ai \
    --edge-ai-runtime ollama \
    --edge-ai-models 'llama3.2:3b,nomic-embed-text,llava:7b' \
    --edge-ai-model-default llama3.2:3b

# OR add the inference service onto an existing GPU cluster role:
./build-x86-host-stage4.sh --role backend-gpu  --with-edge-ai
./build-x86-host-stage4.sh --role omnibus --with-edge-ai --edge-ai-models 'llama3.1:8b'
```

All three front-ends expose the same knobs (**all-menus parity**):

- **CLI:** `--role edge-ai`, `--with-edge-ai` / `--no-edge-ai`, `--edge-ai-runtime`,
  `--edge-ai-models`, `--edge-ai-model-default`.
- **`scripts/build-menu.sh`:** the `edge-ai` row in the x86 role menu, and
  **Options → Edge-AI service** (toggle for backend-gpu/omnibus + runtime/preload/default).
- **Studio wizard:** *Domain, Mesh, and Services → the AI & Inference group of the
  services table* (cloud/mesh modes); `ImageConfig.edge_ai_service / edge_ai_runtime / edge_ai_models
  / edge_ai_model_default` → `to_cli_args()`.

The `edge-ai` role defaults `--gpu-driver nvidia` and turns CUDA on; pass an explicit
`--gpu-driver` to override (an AMD/Intel ROCm edge node is a future path).

**CUDA host compiler = clang, on purpose.** `dev-util/nvidia-cuda-toolkit` caps its
host compiler below the toolchain the amd64 hardened stage3 seed ships (12.9.2 caps
at gcc 14; the seed carries gcc 15), and the x86 builder keeps the seed toolchain
(`--exclude sys-devel/gcc`) — with the toolkit's default gcc leg that combination made
`edge_ai.x86` structurally unbuildable (session `20260719-103006-a775c2`: resolution
aborted, zero artifacts). The image therefore builds the toolkit with `USE=clang`
(`specs-x86/portage/package.use/nvidia`, which documents the full evidence), pulling
the stable, slotted `llvm-core/clang-19`. Compile CUDA code on the node with
`nvcc -ccbin clang++-19 …`. The invariant is guarded by
`scripts/preflight-cuda-host-compiler.sh` (static repo mode runs in CI; a `--sysroot`
mode is ready for the builder to call right before the payload emerge).

---

## 2. How the mesh consumes it

**In-cluster (k8s).** Any pod calls the ClusterIP Service directly:

```
http://hugmesh-edge-ai.hugmesh-inference.svc.cluster.local:11434/v1/chat/completions
```

**Tailnet / external.** The `be-gateway` carries a host route `ai.<CLUSTER_DOMAIN>`
to the same Service, so any tailnet node or device reaches the model API at:

```
https://ai.<domain>/v1/chat/completions      # role-gated: /v1/** = ROLE_USER floor
```

The route-access DB (`manifests/route-access/initdb/20-schema.sql`) gates `/v1/**`
to the authenticated floor (`ROLE_USER`); add a finer `ROLE_EDGE_AI` row (cf.
`ROLE_OWNCAST`) for per-domain restriction. The `edge-ai-analysis` and `edge-ai-tts`
services each carry a NetworkPolicy; the Ollama service itself has none. No API key is
baked (secrets never live in the image — auth is at the gateway).

---

### Runtime version

The inference runtime is the `ollama/ollama` container image, **pinned** to `0.40.0` in
`specs/cluster/manifests/edge-ai/deployment.yaml` (`image:`) and
`specs/cluster/manifests/edge-ai/kustomization.yaml` (`newTag`, which rewrites the
image at render time). The pin is deliberate: a pod restart must not change the runtime
under a running mesh, and an older Ollama refuses newer models at pull time (HTTP 412,
"requires a newer version of Ollama"). The tag is multi-arch (amd64 and arm64), so the
Jetson nodes run the same version. To upgrade:

1. pick the release (<https://github.com/ollama/ollama/releases>) and confirm the tag
   exists: `curl -s https://hub.docker.com/v2/repositories/ollama/ollama/tags/<version>`;
2. change **both** files to the new version: `bash tests/scripts/test-edge-ai-ollama-pin.sh`
   fails when they differ or when either goes back to `latest`, and
   `bash tests/scripts/test-container-image-tags.sh` fails when the tag does not exist;
3. let the Application sync, then
   `kubectl -n hugmesh-inference rollout status deploy/hugmesh-edge-ai` and
   `curl http://<svc>:11434/api/version`.

A developer desktop is separate: see [LOCAL-AI-ASSISTANT.md](LOCAL-AI-ASSISTANT.md).

## 3. The model library (config exposed to the mesh)

`manifests/edge-ai/models-configmap.yaml` (ConfigMap `edge-ai-models`) is the single
knob surface — **admin/superadmin editable, per-domain** (it fits the Service-Catalog
model):

| Key | Meaning |
|---|---|
| `runtime` | `ollama` (default) or `vllm`. Only Ollama is deployed: the Deployment has no vLLM path, so `vllm` changes the value and nothing else |
| `preload` | comma list of model tags pulled on first boot (background) |
| `default-model` | model used when an OpenAI request omits `model` |
| `context-length` / `keep-alive` / `max-loaded-models` / `num-parallel` / `flash-attention` | serving knobs (env-mapped into the container) |
| `catalog.json` | the model CATALOG offered to the mesh (tag, kind chat/embedding/vision/asr, params, quant, VRAM) — the admin console renders this. It lists `whisper` (asr), but the Deployment has no whisper sidecar, so speech-to-text is not built |

Build-time, the `--edge-ai-*` flags patch `runtime` / `preload` / `default-model`.
At runtime, edit the ConfigMap (admin task / GitOps commit) and restart the
Deployment to retune. Curate `preload` to the node's VRAM — an 8 GB Jetson Orin
Nano wants a lean set (`llama3.2:3b` + an embedder); an x86 RTX host can hold more.

---

## 4. GPU for the existing services (voice / video)

The `edge-ai` role and any `--gpu-driver nvidia` k8s node bake
`app-containers/nvidia-container-toolkit` and add the containerd **`nvidia` runtime**;
the always-on `nvidia-device-plugin` DaemonSet (`apps/01d-nvidia-device-plugin.yaml`,
nodeSelector `compute=gpu`) advertises `nvidia.com/gpu` and installs the `nvidia`
RuntimeClass. Once that is up, **any** workload can request the GPU — not just edge-AI:

```yaml
spec:
  runtimeClassName: nvidia
  containers:
    - name: transcoder
      resources:
        limits:
          nvidia.com/gpu: "1"
  nodeSelector:
    hugmesh.net/compute: gpu
```

This is how owncast (video transcode), coturn/Matrix A/V (media), LocalTube
(yt-dlp transcode), and future STT/TTS voice services schedule onto the GPU/edge
node. The device plugin is **harmless without a GPU node** (its DaemonSet schedules
zero pods), so it is not optional-service-gated — it deploys like calico/metrics.

> Wiring a specific service to the GPU is a per-service manifest change (add the
> `nvidia.com/gpu` request + `runtimeClassName: nvidia`); this doc + the device
> plugin provide the schedulable resource. Tracked per service in their manifests.

---

## 4b. Analysis API — task verdicts for the mesh (`edge-ai-analysis`)

The raw `/v1` model API is general-purpose; mesh consumers want **task-oriented
verdicts**. The `edge-ai-analysis` optional service is a thin stateless wrapper
(FastAPI) in front of the Ollama upstream that exposes:

| Endpoint | Verdict |
|---|---|
| `POST /v1/analyze/image/classify` | `{classification: safe\|nsfw\|abuse, confidence, tags, policy_hit, perceptual_hash}` (llava vision) |
| `POST /v1/analyze/image/hash` | `{perceptual_hash, average_hash, difference_hash}` (CPU, no GPU) |
| `POST /v1/analyze/content/moderate` | `{action: allow\|flag\|reject, ...}` — **fail-closed** (a policy hit OR an inference error ⇒ `reject`) |
| `POST /v1/analyze/log/summarize` | `{summary, severity, anomalies[]}` (llama triage) |

It is reached at `https://ai.<domain>/v1/analyze/**` (be-gateway, `ROLE_USER` floor)
and in-cluster at `http://hugmesh-edge-ai-analysis.hugmesh-inference.svc:8080`.
Tenancy: the gateway-validated `X-Tenant-ID`/`X-User-ID` headers stamp every verdict.
Config (task→model map, NSFW/abuse thresholds, `moderate-action`) is the
`edge-ai-analysis` ConfigMap; the stable verdict schema is documented there.

```bash
# add the analysis API onto an edge-AI cluster (needs the edge-ai model server):
./build-x86-host-stage4.sh --role edge-ai --with-edge-ai-analysis
```

**This is the Phase-A foundation:**
the on-prem hinge that the AIOps consumer (infra logs → `@system` Matrix DM) and the
avatar vision-moderation hook (→ federation moderation queue) call. Those consumers
live in the BFF/federation Java repos and land separately.

**Slug:** `edge-ai-analysis`, **DEFAULT-OFF**, `dependsOn: edge-ai` (greyed in the
console when edge-ai is off). The container is a **separate build artifact** — its
source is `specs/cluster/manifests/edge-ai-analysis/image/` (FastAPI + Pillow +
imagehash); build + push `registry.hugmesh.net/hugmesh/edge-ai-analysis:main`
then select the slug. Keep it deselected until the image is pushed (so no node
ImagePull-fails). Everything stays on-prem — the wrapper only calls the in-cluster
Ollama upstream.

## 4c. Voice synthesis — TTS API for the mesh (`edge-ai-tts`)

The **VN voice feature** (matrix-ui) needs short-line text-to-speech plus a mouth-shape
timeline for 2D lipsync. The `edge-ai-tts` optional service is a stateless FastAPI
wrapper around [Piper](https://github.com/OHF-Voice/piper1-gpl) that exposes:

| Endpoint | Response |
|---|---|
| `POST /v1/synthesize` | `{audioBase64, sampleRate, format, durationMs, voice, visemes[]}` |

**UNLIKE `edge-ai-analysis`, this service has NO `edge-ai` dependency.** It is
CPU-only and self-contained: the default voice (`.onnx` + `.onnx.json`) is baked
into the image at build time, no model is fetched and no upstream is called at
request time — it schedules **anywhere in the mesh**, GPU node or not, and is wired
on **both** `build-x86-host-stage4.sh` **and** `build-rpi5-stage4.sh` (unlike
`edge-ai`, which needs a GPU node, and `edge-ai-analysis`, which is x86-only and needs `edge-ai`).

It is reached at `https://ai.<domain>/v1/synthesize/**` (be-gateway, `ROLE_USER`
floor) and in-cluster at `http://hugmesh-edge-ai-tts.hugmesh-inference.svc:8080`.
Tenancy: the gateway-validated `X-Tenant-ID`/`X-User-ID` headers stamp every response.
Config (model dir, default voice, Piper `length_scale`/`noise_scale`/`noise_w`,
`max_chars`) is the `edge-ai-tts` ConfigMap.

The **7-key viseme vocabulary** (`rest · AI · E · O · U · L · MBP`) is a CONTRACT with
matrix-ui's `viseme.ts` mouth-shape map — keep the two in sync (see
`specs/cluster/manifests/edge-ai-tts/image/README.md`).

```bash
# add the TTS API to any cluster role (CPU-only — no --with-edge-ai needed):
./build-x86-host-stage4.sh --role backend --with-edge-ai-tts
./build-rpi5-stage4.sh     --role backend --with-edge-ai-tts
```

**CLI:** `--with-edge-ai-tts` / `--no-edge-ai-tts` (both builders), or list
`edge-ai-tts` in `--optional-services`. **`scripts/build-menu.sh`:** the *Voice
synthesis (TTS)* row in **Options → Edge-AI inference** (grouped there for UX only —
its flag is emitted unconditionally, not gated to a GPU target). **Studio wizard:**
*Domain, Mesh, and Services* — the `edge-ai-tts` row in the services table's
Characters & Avatars group (platform-gated like Character Studio, not mode-gated like
the GPU Edge-AI group);
`ImageConfig.edge_ai_tts` → `to_cli_args()`.

**Slug:** `edge-ai-tts`, **DEFAULT-OFF**, **NO `dependsOn`**. The container is a
**separate build artifact** — its source is
`specs/cluster/manifests/edge-ai-tts/image/` (FastAPI + piper-tts + onnxruntime,
CPU); build + push `registry.hugmesh.net/hugmesh/edge-ai-tts:main` then
select the slug. Keep it deselected until the image is pushed (so no node
ImagePull-fails). Everything stays on-prem — synthesis is local CPU work.

## 5. Jetson Orin Nano (arm64 platform — EXPERIMENTAL, buildable)

The NVIDIA **Jetson Orin Nano** (aarch64 + Ampere, 67 TOPS) runs the same `edge-ai`
role + `edge-ai` service; the difference is the **platform**: the `specs-jetson`
tree (Tegra234 kernel fragments + boot/portage specs) rather than `specs-x86`. The
kustomize image tags and the GPU request are identical (Ollama has arm64 + Jetson
CUDA images).

The platform now has a **buildable EXPERIMENTAL path** — `build-jetson-stage4.sh`:

```bash
./build-jetson-stage4.sh --role edge-ai              # the headline (DEFAULT)
./build-jetson-stage4.sh --role edge-ai --print-plan # dry-run plan (no root)
make jetson JETSON_ROLE=edge-ai                      # the make front door
```

Roles: `edge-ai` (default) | `backend-gpu` | `omnibus` | `desktop` (the old spelling `full` is still accepted for `omnibus`); boards
`orin-nano` (default) / `orin-nano-4gb` / `orin-nx-8gb` / `orin-nx-16gb`. The
default `--kernel-flavor mainline` is the buildable route (gentoo-sources arm64
+ the Tegra234 fragments) and carries **NO CUDA** — the GA10B iGPU needs
NVIDIA's nvgpu, so the edge-ai service runs **CPU-only** until the node moves to
the L4T stack; `--kernel-flavor l4t` (NVIDIA BSP kernel + CUDA userspace) is a
**documented stub** (EULA-gated downloads, hard error pointing at
`specs-jetson/installer/TEGRAFLASH.md`). All four channels expose the platform
(CLI / `make jetson` / ncurses menu / Studio — all-menus parity), and the full
role×env matrix is dry-run-verified by `make matrix-check`.

**Status: EXPERIMENTAL — hardware validation pending.** No physical Orin has
booted an image from this builder yet; every real build prints a LOUD
EXPERIMENTAL banner until first boot is confirmed on hardware. See
[`specs-jetson/README.md`](../specs-jetson/README.md) for the validation
checklist. Until then, the edge-AI service itself stays validated on the x86
GPU host.

---

## 6. GPU-cluster bring-up checklist (first time on real GPU hardware)

The k8s manifests are validated by `kustomize build`; the runtime path needs a GPU
node and could not be exercised in CI. On first GPU-cluster bring-up, verify:

1. **containerd nvidia runtime** present: `/etc/containerd/config.toml` has the
   `runtimes.nvidia` block (baked when `--gpu-driver nvidia` on a k8s role) and
   `/usr/bin/nvidia-container-runtime` exists (from `nvidia-container-toolkit`).
2. **Device plugin schedules**: `kubectl -n kube-system get ds nvidia-device-plugin-daemonset`
   has a ready pod on the GPU node; `kubectl get node <gpu> -o jsonpath='{.status.allocatable.nvidia\.com/gpu}'` ≥ 1.
3. **SELinux** (nodes boot ENFORCING): the device plugin requests `spc_t`. If it is
   denied, scan AVCs (`ausearch -m avc -ts recent`) and add a
   `nvidia_device_plugin` policy module under `specs/selinux/` — keep SELinux in
   sync with the new role (see [SECURITY.md](SECURITY.md)).
4. **edge-ai pod**: `kubectl -n hugmesh-inference get deploy hugmesh-edge-ai`
   becomes Ready; `curl http://<svc>:11434/v1/models` lists the preloaded models;
   `curl https://ai.<domain>/v1/chat/completions` (with a mesh token) returns a
   completion.
5. **Model cache PVC** binds (local-path) so weights survive a pod restart.

---

## 7. Files

```
specs/cluster/apps/01d-nvidia-device-plugin.yaml      # GPU device plugin + nvidia RuntimeClass (always-on)
specs/cluster/manifests/nvidia-device-plugin/         #   daemonset + runtimeclass + kustomization
specs/cluster/apps/54-edge-ai.yaml                    # edge-ai ArgoCD Application (DEFAULT-OFF, gated)
specs/cluster/manifests/edge-ai/                      #   namespace + ollama deployment+service + models ConfigMap + PVC
specs/cluster/apps/55-edge-ai-analysis.yaml           # edge-ai-analysis ArgoCD Application (DEFAULT-OFF, dependsOn edge-ai)
specs/cluster/manifests/edge-ai-analysis/             #   FastAPI analysis wrapper (deployment+service+configmap+netpol) + image/ source
specs/cluster/apps/55b-edge-ai-tts.yaml                # edge-ai-tts ArgoCD Application (DEFAULT-OFF, NO dependsOn)
specs/cluster/manifests/edge-ai-tts/                  #   FastAPI Piper TTS wrapper (deployment+service+configmap+netpol) + image/ source
specs/cluster/optional-services.yaml                  # edge-ai slug entry (registry)
specs/cluster/apps/13a-optional-services.yaml         # edge-ai runtime ApplicationSet element
specs/cluster/apps/20-gateway-be.yaml                 # ai.<domain> host route
specs/cluster/manifests/route-access/initdb/20-schema.sql   # /v1/** ROLE_USER row
specs/cluster/manifests/policy/installed-services-configmap.yaml  # edge-ai install-state
build-x86-host-stage4.sh / build-rpi5-stage4.sh       # edge-ai role, flags, gate, PKGS, containerd runtime
scripts/build-menu.sh                                 # role row + Edge-AI options
studio/hugmesh_studio/{core/config.py,gui/wizard.py}   # ImageConfig fields + wizard group
```
