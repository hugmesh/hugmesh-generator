# SPDX-License-Identifier: Apache-2.0
"""hugmesh-media-poisoner — FastAPI service stub.

The OPTIONAL x86/GPU heavy-tier worker that applies an AI-cloak/poison perturbation
to image bytes BEFORE the homeserver ingests them. The hugmesh-user-bff-api
media-proxy is the ONLY caller:

  POST /poison   multipart/form-data: image=<file>, mode=<none|light|glaze|nightshade>,
                 sizes=<comma-separated ints, optional>
                 -> 200 image/jpeg  (perturbed bytes)         on success
                 -> 200 image/<orig> (unchanged) when mode=none / non-image
                 -> 415 when the upload is not a decodable image and mode != none
  GET  /health   -> 200 {"status","backend","modes","available"}   liveness + capability
                    The BFF proxies "backend" into /bff/user/media/capability so the
                    UI renders an honest, hardware-derived expectation (cuda ~1 min,
                    cpu reduced-strength, none -> warn-before-post).

On a Pi5-only cluster this Deployment stays Pending (nodeSelector requires the
amd64+gpu node), its Service has no Ready endpoints, and the BFF's capability probe
reports the heavy tier absent -> lean fallback (warn-before-post). When the worker
IS scheduled on a CPU-only test node it still runs the lean perturbation and honestly
reports backend=cpu.

SECURITY: this is a ClusterIP-only service reached over in-cluster DNS. If the
proxies/BFF require mTLS to it, either terminate that at the manifest layer
(sidecar / mesh) or have THIS worker terminate it: app/serve.py (the container
entrypoint) reads POISON_TLS_CERT / POISON_TLS_KEY / POISON_TLS_CLIENT_CA and runs
uvicorn with TLS + REQUIRED client-cert verification (ssl.CERT_REQUIRED) when set —
unset, it serves plain HTTP exactly as before (backward-compatible default). A
partial TLS config FAILS startup (never a silent plaintext fallback), and /health
discloses the active transport ("mtls" | "tls" | "plaintext"). It mints no
credentials and holds no durable copy of any image (in-memory, ephemeral).
"""

from __future__ import annotations

import logging

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import JSONResponse, Response

from .poison import KNOWN_MODES, MODE_NONE, detect_backend, perturb
from .serve import transport_mode

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("media-poisoner")

# Resolve the compute backend ONCE at startup (cuda|rocm|cpu|none) so /health is a
# cheap, allocation-free probe the BFF can poll frequently.
BACKEND = detect_backend()

# Honest transport disclosure (mtls | tls | plaintext), resolved ONCE at startup
# from the same env the entrypoint (app/serve.py) serves with.
TRANSPORT = transport_mode()

# Bounded request body so a hostile/huge upload cannot OOM the worker. The BFF also
# enforces its own multipart limit; this is defense-in-depth. 25 MiB default.
MAX_IMAGE_BYTES = 25 * 1024 * 1024

app = FastAPI(
    title="hugmesh-media-poisoner",
    description="Optional x86/GPU AI-cloak/poison worker. Best-effort, not a guarantee.",
    version="0.1.0",
)


@app.get("/health")
def health() -> JSONResponse:
    """Liveness + capability. The BFF reads ``backend`` to set UI expectations."""
    return JSONResponse(
        {
            "status": "ok",
            "backend": BACKEND.kind,  # cuda | rocm | cpu | none
            "available": BACKEND.available,
            "modes": list(KNOWN_MODES),
            "transport": TRANSPORT,  # mtls | tls | plaintext (honest disclosure)
        }
    )


def _parse_sizes(raw: str | None) -> list[int] | None:
    if not raw:
        return None
    out: list[int] = []
    for part in raw.split(","):
        part = part.strip()
        if not part:
            continue
        try:
            out.append(int(part))
        except ValueError:
            continue  # ignore garbage; the worker has safe defaults.
    return out or None


@app.post("/poison")
async def poison(
    image: UploadFile = File(...),
    mode: str = Form("glaze"),
    sizes: str | None = Form(None),
) -> Response:
    """Apply the perturbation for ``mode`` and return the re-encoded bytes.

    The BFF holds the plaintext bytes only transiently; this worker does the same
    (read into memory, perturb, return — no disk write). ``mode=none`` and
    non-image uploads are returned unchanged so the BFF can use one code path.
    """

    mode = (mode or "glaze").strip().lower()
    if mode not in KNOWN_MODES:
        # Unknown mode is coerced to a safe default inside perturb(); log it.
        log.warning("unknown mode %r coerced to default", mode)

    data = await image.read()
    if len(data) > MAX_IMAGE_BYTES:
        raise HTTPException(status_code=413, detail="image too large")

    if mode == MODE_NONE:
        # Opt-out: forward verbatim with the original content type.
        return Response(content=data, media_type=image.content_type or "application/octet-stream")

    out = perturb(data, mode=mode, sizes=_parse_sizes(sizes))

    # perturb() returns the ORIGINAL bytes unchanged when the upload is not a
    # decodable image (or Pillow/numpy are missing). Signal that to the BFF as 415
    # so its round-trip gate doesn't mark un-perturbed bytes "protected".
    if out is data and mode != MODE_NONE:
        raise HTTPException(status_code=415, detail="not a decodable image; nothing perturbed")

    return Response(content=out, media_type="image/jpeg")
