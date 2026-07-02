# snapdragon-media-poisoner (worker)

The **optional x86/GPU heavy-tier** worker that applies an AI-cloak / poison
perturbation to image bytes **before** the homeserver ingests them. It is the
server-side compute half of the *poison-before-ingest* design; the policy decision,
the round-trip survival gate, and all honest UI copy live in
`snapdragon-user-bff-api` (the only caller).

> **Honesty contract.** This is **best-effort training-set hygiene, not a
> guarantee.** Cloaks/poisons are removable by determined adversaries and by
> ordinary JPEG re-encode / downscale. The UI says *"AI-cloak applied"*, never
> *"protected"*, and the BFF only marks a result protected if its post-ingest
> round-trip check confirms the signal survived. Already-federated copies and
> personal-client (Element/Tusky/Ivory) uploads are **uncloseable** and must be
> disclosed as such.

## Interface (the BFF calls this — keep stable)

| Method | Path      | Body                                                                 | Response |
|--------|-----------|----------------------------------------------------------------------|----------|
| `POST` | `/poison` | multipart: `image=<file>`, `mode=<none\|light\|glaze\|nightshade>`, `sizes=<csv ints, optional>` | `200 image/jpeg` perturbed bytes; `200` unchanged for `mode=none`/non-image; `413` too large; `415` undecodable image |
| `GET`  | `/health` | —                                                                    | `200 {"status","backend","available","modes"}` |

`backend` is one of `cuda \| rocm \| cpu \| none`. The BFF proxies it into
`/bff/user/media/capability` so the UI renders an honest, **hardware-derived**
expectation (cuda ~1 min Glaze, cpu reduced-strength, none → warn-before-post).

## Backends and the lean fallback

* **Default (shipped):** a tiny, CPU-portable, L-inf-bounded sinusoidal-grid
  perturbation (`app/poison.py::_lean_perturb`, Pillow + numpy only). Intentionally
  **weak** — surfaced to the user as *"light"* — and exists so the worker is
  runnable and the BFF round-trip gate is exercisable end-to-end **without a GPU**.
* **GPU / production (follow-up):** PGD against the same Stable-Diffusion VAE/encoder
  the published technique targets, via the **open PyTorch reference** (see roadmap).
  Selected when `detect_backend()` finds CUDA or ROCm torch.
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

CI = **GitLab only** (no GitHub Actions). The kustomization rewrites the image ref
to the in-cluster GitLab registry like every other first-party app.

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
   "small" + Matrix 240×240) so no clean derivative can be regenerated.
4. Keep the BFF's round-trip survival gate authoritative: the worker only applies
   bytes; the BFF re-fetches the homeserver-served original + each thumbnail and
   decides `protected` vs `protection-degraded`.
5. Roadmap-only (not shippable today): faster/more-robust methods (FastProtect /
   BlurGuard). Track removability research (LightShed, JPEG-bypass) honestly.

## Security / privacy

ClusterIP-only, in-cluster DNS, mints no credentials, keeps **no durable copy** of
any image (read → perturb → return, in-memory). Server-side poisoning necessarily
exposes plaintext to this one extra component — acceptable because posted media is
public-by-design, but it is disclosed in ToS.

**mTLS (worker-terminated, optional).** If the BFF/proxies require **mTLS** to the
worker, either terminate it at the manifest layer (sidecar/mesh) or let the worker
terminate it itself: the container entrypoint (`app/serve.py`, `python -m app.serve`)
reads

| env | meaning |
|---|---|
| `POISON_TLS_CERT` | server certificate PEM path (leaf [+ chain]) |
| `POISON_TLS_KEY`  | server private key PEM path |
| `POISON_TLS_CLIENT_CA` | CA bundle used to **verify client certs** — setting it enforces `ssl.CERT_REQUIRED` (true mTLS) |

and runs uvicorn accordingly. All three unset (the default) serves plain HTTP on
`:8080` exactly as before — fully backward compatible. A **partial** config (cert
without key, client CA without server cert, missing PEM file) **aborts startup**
(fail-closed; never a silent plaintext fallback), and `/health` discloses the live
transport as `"transport": "mtls" | "tls" | "plaintext"`. The PEMs arrive via an
ESO-projected Secret volume (mirrors the BFF/gateway `build-keystore` + ESO pattern
used elsewhere in this repo); when enabling, swap the Deployment's `httpGet` probes
for `tcpSocket` (the kubelet has no client cert). Unit + live-handshake tests:
`tests/test_serve_tls.py` (the live test self-signs a throwaway CA and proves a
certless client is REJECTED and a cert-bearing one accepted).
