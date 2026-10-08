# hugmesh-media-poisoner (worker)

The **optional x86/GPU heavy-tier** worker that applies an AI-cloak / poison
perturbation to image bytes **before** the homeserver ingests them. It is the
server-side compute half of the *poison-before-ingest* design; the policy decision,
the round-trip survival gate, and all honest UI copy live in
`hugmesh-user-bff-api` (the only caller).

> **Honesty contract.** This is **best-effort training-set hygiene, not a
> guarantee.** Cloaks/poisons are removable by determined adversaries and by
> ordinary JPEG re-encode / downscale. The UI says *"AI-cloak applied"*, never
> *"protected"*, and the BFF only marks a result protected if its post-ingest
> round-trip check confirms the signal survived. Already-federated copies and
> personal-client (Element/Tusky/Ivory) uploads are **uncloseable** and must be
> disclosed as such.

## Interface (the BFF calls this — keep stable)

| Method | Path        | Body                                                                 | Response |
|--------|-------------|----------------------------------------------------------------------|----------|
| `POST` | `/poison`   | **What the BFF sends:** `application/octet-stream` body (the original bytes) + headers `X-Cloak-Mode`, `X-Cloak-Filename`, `X-Cloak-Content-Type`, `X-Cloak-Thumbnail-Sizes` | `200 application/json` `{ok, backend, poisonedOriginal (base64), thumbnails: [], detail}`; with `mode=none` the original bytes come back unchanged |
| `POST` | `/poison`   | **Older shape, still accepted:** multipart `image=<file>`, `mode=<none\|light\|glaze\|nightshade>`, `sizes=<csv, optional>` | `200 image/jpeg` perturbed bytes (`mode=none`: the upload unchanged); `422` if `image` is missing |
| `POST` | `/survival` | `application/octet-stream` body (the bytes the homeserver serves) + headers `X-Cloak-Mode`, `X-Cloak-Size` | `200 {"present","score","detail"}` |
| `GET`  | `/health`   | —                                                                    | `200 {"status","backend","available","modes","transport"}` |

Both `/poison` shapes also return `413` for a body over 25 MiB, and `415` for a body
that is not a decodable image when `mode` is not `none`. The mode defaults to `glaze`
when none is sent. `sizes` takes integers, `WxH` (`240x240`) and the names `small`,
`thumbnail`, `preview`, `medium`, `original`. `/survival` is the call the BFF's
round-trip gate makes for each served artifact; it answers `present=false` for
anything it cannot measure.

`backend` is one of `cuda \| rocm \| cpu \| none`. The BFF proxies it into
`/bff/user/media/capability` so the UI renders an honest, **hardware-derived**
expectation (cuda ~1 min Glaze, cpu reduced-strength, none → warn-before-post).

## Backends and the lean fallback

* **Default (shipped):** a tiny, CPU-portable, L-inf-bounded sinusoidal-grid
  perturbation (`app/poison.py::_lean_perturb`, Pillow + numpy only). Intentionally
  **weak** — surfaced to the user as *"light"* — and exists so the worker is
  runnable and the BFF round-trip gate is exercisable end-to-end **without a GPU**.
* **GPU / production (follow-up, NOT built):** PGD against the same Stable-Diffusion
  VAE/encoder the published technique targets, via the **open PyTorch reference** (see
  roadmap). Today every mode, `glaze` and `nightshade` included, runs the same
  `_lean_perturb` with a larger budget (`light` 2, `glaze` 6, `nightshade` 10 on a
  0..255 scale). `detect_backend()` only *reports* `cuda` or `rocm` when it finds a
  matching torch build; it does not switch the algorithm. `sizes` is accepted and
  ignored by the lean backend.
* **Pi5-only cluster:** the Deployment's `nodeSelector` requires the `amd64` + GPU
  node, so the pod stays **Pending**, its Service has **no Ready endpoints**, and the
  BFF capability probe reports the heavy tier **absent** → lean fallback
  (warn-before-post). Nothing here needs to know about that — it is pure k8s
  protocol-probe availability (no Eureka/Config/Task).

`POISON_BACKEND=cuda|rocm|cpu|none` overrides the probe (testing / forcing the lean
path).

## Build

```sh
# lean default (CPU-portable, what ships):
docker build -t media-poisoner:dev .

# GPU variant (NOT built by default): add a torch wheel from the CUDA or ROCm
# pytorch index on top of requirements.txt — see requirements-gpu.txt:
#   CUDA: --index-url https://download.pytorch.org/whl/cu124
#   ROCm: --index-url https://download.pytorch.org/whl/rocm6.2
```

The only CI job in this repo that touches the worker is `lint:media-poisoner-tls` in
`.gitlab-ci.yml`, which runs the unit tests in `tests/`. No job here builds or pushes
the image. The kustomization rewrites the image ref to
`registry.hugmesh.net/hugmesh/hugmesh-media-poisoner:main`, the in-cluster Harbor
registry, like every other first-party app. For a local run, `make stack-up POISONER=1`
builds the worker from this directory (`tests/stack/compose.media-poisoner.yaml`).

## License (read before swapping a real backend in)

Glaze and Nightshade are distributed by the **University of Chicago SAND Lab** as
**non-commercial research binaries**. A default-on, federated, possibly-branded
deployment **must not** ship those binaries. The production path here is the **open
PyTorch reference** (an L-inf-bounded PGD adversarial perturbation against the SD
VAE/encoder, implemented from public descriptions under a permissive license).
`torch`/`diffusers` are permissive (BSD/Apache); the SD VAE weights are
CreativeML OpenRAIL-M — **verify acceptability for the deployment** before enabling.

## Integration roadmap (full Glaze/Nightshade — follow-up)

1. Add `requirements-gpu.txt` deps (torch + diffusers) in a GPU image variant.
2. Implement `poison.py` strong backends: load the SD VAE/encoder once; run a
   bounded PGD that maximizes the latent/feature distance from the clean image
   (Glaze = style-cloak budget; Nightshade = stronger poison budget). Target the SD
   VAE/encoder specifically — **not** a generic CLIP surrogate (avoids the
   surrogate-mismatch failure mode).
3. Poison **every served size** in one call (the `sizes` arg already carries akkoma
   "small" + Matrix 240×240, but the lean backend ignores it) so no clean derivative
   can be regenerated.
4. Keep the BFF's round-trip survival gate authoritative: the worker only applies
   bytes; the BFF re-fetches the homeserver-served original + each thumbnail and
   decides `protected` vs `degraded`.
5. Roadmap-only (not shippable today): faster/more-robust methods (FastProtect /
   BlurGuard). Track removability research (LightShed, JPEG-bypass) honestly.

## Security / privacy

ClusterIP-only, in-cluster DNS, mints no credentials, keeps **no durable copy** of
any image (read → perturb → return, in-memory). Server-side poisoning necessarily
exposes plaintext to this one extra component — acceptable because posted media is
public-by-design, but it is disclosed in ToS.

**mTLS (worker-terminated) — LIVE.** The worker terminates mTLS itself: the
container entrypoint (`app/serve.py`, `python -m app.serve`) reads

| env | meaning |
|---|---|
| `POISON_TLS_CERT` | server certificate PEM path (leaf [+ chain]) |
| `POISON_TLS_KEY`  | server private key PEM path |
| `POISON_TLS_CLIENT_CA` | CA bundle used to **verify client certs** — setting it enforces `ssl.CERT_REQUIRED` (true mTLS) |

and runs uvicorn accordingly. All three unset serves plain HTTP on `:8080` exactly
as before — fully backward compatible (useful for local/dev runs outside the
cluster). A **partial** config (cert without key, client CA without server cert,
missing PEM file) **aborts startup** (fail-closed; never a silent plaintext
fallback), and `/health` discloses the live transport as `"transport": "mtls" |
"tls" | "plaintext"` (`"invalid"` if the process was started around `app/serve.py`
with a partial config). In the cluster, `POISON_TLS_CERT`/`POISON_TLS_KEY`/
`POISON_TLS_CLIENT_CA` point at the PEM files projected from the ESO Secret
`media-poisoner-mtls` (`manifests/external-secrets/media-poisoner-externalsecrets.yaml`
— the same Vault-PKI -> ESO -> `kubernetes.io/tls` pattern as the akkoma-proxy /
tuwunel-proxy homeserver mTLS certs, mounted straight into this container instead
of a sidecar), and the Deployment's readiness/liveness probes are `tcpSocket` (not
`httpGet`), since the mTLS handshake rejects the kubelet's certless probe. Unit +
live-handshake tests: `tests/test_serve_tls.py` (the live test self-signs a
throwaway CA and proves a certless client is REJECTED and a cert-bearing one
accepted).
