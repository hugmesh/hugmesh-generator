# hugmesh-media-poisoner (worker)

The **optional x86/GPU heavy-tier** worker. It applies an AI-cloak / poison
perturbation to image bytes **before** the homeserver ingests them. It is the
server-side compute half of the *poison-before-ingest* design. The policy decision,
the round-trip survival gate, and all honest UI copy live in `hugmesh-user-bff-api`,
the only caller.

> **Honesty contract.** This is **best-effort training-set hygiene, not a
> guarantee.** Determined adversaries can remove cloaks and poisons, and so can an
> ordinary JPEG re-encode or downscale. The UI says *"AI-cloak applied"*, never
> *"protected"*. The BFF marks a result protected only if its post-ingest round-trip
> check confirms the signal survived. Already-federated copies and uploads from
> personal clients (Element/Tusky/Ivory) are **uncloseable** and must be disclosed
> as such.

## Interface (the BFF calls this — keep stable)

| Method | Path        | Body                                                                 | Response |
|--------|-------------|----------------------------------------------------------------------|----------|
| `POST` | `/poison`   | **What the BFF sends:** `application/octet-stream` body (the original bytes) + headers `X-Cloak-Mode`, `X-Cloak-Filename`, `X-Cloak-Content-Type`, `X-Cloak-Thumbnail-Sizes` | `200 application/json` `{ok, backend, poisonedOriginal (base64), thumbnails: [], detail}`; with `mode=none` the original bytes come back unchanged |
| `POST` | `/poison`   | **Older shape, still accepted:** multipart `image=<file>`, `mode=<none\|light\|glaze\|nightshade>`, `sizes=<csv, optional>` | `200 image/jpeg` perturbed bytes (`mode=none`: the upload unchanged); `422` if `image` is missing |
| `POST` | `/survival` | `application/octet-stream` body (the bytes the homeserver serves) + headers `X-Cloak-Mode`, `X-Cloak-Size` | `200 {"present","score","detail"}` |
| `GET`  | `/health`   | —                                                                    | `200 {"status","backend","available","modes","transport"}` |

Both `/poison` shapes return `413` for a body over 25 MiB. They return `415` for a
body that is not a decodable image when `mode` is not `none`. The mode defaults to
`glaze`. `sizes` takes integers, `WxH` (`240x240`) and the names `small`,
`thumbnail`, `preview`, `medium`, `original`. The BFF's round-trip gate calls
`/survival` once per served artifact. It answers `present=false` for anything it
cannot measure.

`backend` is one of `cuda \| rocm \| cpu \| none`. The BFF proxies it into
`/bff/user/media/capability`, so the UI shows an honest, **hardware-derived**
expectation (cuda ~1 min Glaze, cpu reduced-strength, none → warn-before-post).

## Backends and the lean fallback

* **Default (shipped):** a tiny, CPU-portable, L-inf-bounded sinusoidal-grid
  perturbation (`app/poison.py::_lean_perturb`, Pillow + numpy only). It is
  intentionally **weak** and surfaced to the user as *"light"*. It exists so the
  worker runs and the BFF round-trip gate works end to end **without a GPU**.
* **GPU / production (follow-up, NOT built):** PGD against the same Stable-Diffusion
  VAE/encoder the published technique targets, via the **open PyTorch reference** (see
  roadmap). Today every mode, `glaze` and `nightshade` included, runs the same
  `_lean_perturb` with a larger budget (`light` 2, `glaze` 6, `nightshade` 10 on a
  0..255 scale). `detect_backend()` only *reports* `cuda` or `rocm` when it finds a
  matching torch build; it does not switch the algorithm. The lean backend accepts
  `sizes` and ignores it.
* **Pi5-only cluster:** the Deployment's `nodeSelector` requires the `amd64` + GPU
  node, so the pod stays **Pending** and its Service has **no Ready endpoints**. The
  BFF capability probe then reports the heavy tier **absent** and falls back to the
  lean path (warn-before-post). The worker needs no code for this.

`POISON_BACKEND=cuda|rocm|cpu|none` overrides the probe (testing, or forcing the lean
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
PyTorch reference**: an L-inf-bounded PGD adversarial perturbation against the SD
VAE/encoder, implemented from public descriptions under a permissive license.
`torch` and `diffusers` are permissive (BSD/Apache). The SD VAE weights are
CreativeML OpenRAIL-M, so **verify they are acceptable for the deployment** before
enabling.

## Integration roadmap (full Glaze/Nightshade — follow-up)

1. Add the `requirements-gpu.txt` deps (torch + diffusers) in a GPU image variant.
2. Implement the strong backends in `poison.py`. Load the SD VAE/encoder once. Run a
   bounded PGD that maximizes the latent/feature distance from the clean image
   (Glaze = style-cloak budget; Nightshade = stronger poison budget). Target the SD
   VAE/encoder itself, **not** a generic CLIP surrogate (this avoids the
   surrogate-mismatch failure mode).
3. Poison **every served size** in one call, so no clean derivative can be
   regenerated. The `sizes` arg already carries akkoma "small" and Matrix 240×240,
   but the lean backend ignores it.
4. Keep the BFF's round-trip survival gate authoritative. The worker only applies
   bytes. The BFF re-fetches the homeserver-served original and each thumbnail, and
   decides `protected` vs `degraded`.
5. Roadmap-only (not shippable today): faster, more robust methods (FastProtect /
   BlurGuard). Track the removability research (LightShed, JPEG-bypass) honestly.

## Security / privacy

The worker is ClusterIP-only, reached by in-cluster DNS. It mints no credentials and
keeps **no durable copy** of any image (read → perturb → return, in memory).
Server-side poisoning necessarily exposes plaintext to this one extra component. That
is acceptable because posted media is public by design, and the ToS disclose it.

**mTLS (worker-terminated) — LIVE.** The worker terminates mTLS itself. The
container entrypoint (`app/serve.py`, `python -m app.serve`) reads

| env | meaning |
|---|---|
| `POISON_TLS_CERT` | server certificate PEM path (leaf [+ chain]) |
| `POISON_TLS_KEY`  | server private key PEM path |
| `POISON_TLS_CLIENT_CA` | CA bundle used to **verify client certs** — setting it enforces `ssl.CERT_REQUIRED` (true mTLS) |

and runs uvicorn accordingly.

- With all three unset, it serves plain HTTP on `:8080` exactly as before. This is
  backward compatible and useful for local/dev runs outside the cluster.
- A **partial** config (cert without key, client CA without server cert, missing PEM
  file) **aborts startup**. It is fail-closed and never falls back to plaintext.
- `/health` discloses the live transport as `"transport": "mtls" | "tls" |
  "plaintext"`. It says `"invalid"` if the process was started around `app/serve.py`
  with a partial config.
- In the cluster, the three variables point at the PEM files projected from the ESO
  Secret `media-poisoner-mtls`
  (`manifests/external-secrets/media-poisoner-externalsecrets.yaml`). It uses the same
  Vault-PKI -> ESO -> `kubernetes.io/tls` pattern as the akkoma-proxy / tuwunel-proxy
  homeserver mTLS certs, but it is mounted straight into this container instead of a
  sidecar.
- The Deployment's readiness and liveness probes are `tcpSocket`, not `httpGet`. The
  mTLS handshake rejects the kubelet's certless probe.
- Tests: unit and live-handshake tests in `tests/test_serve_tls.py`. The live test
  self-signs a throwaway CA and proves that a certless client is REJECTED and a
  cert-bearing one accepted.
