# SPDX-License-Identifier: Apache-2.0
"""hugmesh-media-poisoner — FastAPI service stub.

The OPTIONAL x86/GPU heavy-tier worker that applies an AI-cloak/poison perturbation
to image bytes BEFORE the homeserver ingests them. The hugmesh-user-bff-api
media-proxy is the ONLY caller:

  POST /poison   TWO accepted encodings, because the BFF and this worker were written
                 against DIFFERENT contracts and neither side was ever exercised against
                 the other (see "the seam" below):

                 (a) application/octet-stream + X-Cloak-* headers — WHAT THE BFF SENDS.
                     body = the original bytes; X-Cloak-Mode / X-Cloak-Filename /
                     X-Cloak-Content-Type / X-Cloak-Thumbnail-Sizes.
                     -> 200 application/json {ok, backend, poisonedOriginal(base64),
                                              thumbnails[], detail}
                     This is PoisonModels.PoisonResult on the Java side; Jackson decodes
                     the byte[] field from base64, which is why the bytes travel as a
                     base64 string rather than a second body.
                 (b) multipart/form-data: image=<file>, mode=, sizes= — the previously
                     documented shape, kept working so nothing that already speaks it
                     breaks.
                     -> 200 image/jpeg (perturbed bytes)
                 Both: -> 200 unchanged when mode=none
                       -> 415 when the upload is not a decodable image and mode != none
  POST /survival application/octet-stream + X-Cloak-Mode / X-Cloak-Size. Body = the
                 bytes the homeserver actually SERVES after its own re-encode/downscale.
                 -> 200 {"present","score","detail"}  (PoisonModels.SurvivalVerdict)
                 The BFF's round-trip gate calls this per served artifact; it is what
                 separates "a cloak was applied" from "a cloak is still there".
  GET  /health   -> 200 {"status","backend","modes","available"}   liveness + capability
                    The BFF proxies "backend" into /bff/user/media/capability so the
                    UI renders an honest, hardware-derived expectation (cuda ~1 min,
                    cpu reduced-strength, none -> warn-before-post).

THE SEAM (2026-08-14). This worker previously served ONLY (b) and had no /survival at
all, while hugmesh-user-bff-api's PoisonWorkerClient only ever sent (a) and called
/survival. Every real cloak attempt therefore died on a bare 422 and the gate 404'd —
proven live against the running mesh, where the BFF logged
"poison job failed (mode=glaze): 422 Unprocessable Content". /health was the ONLY
endpoint both sides agreed on, which is exactly why the feature looked healthy: the
BFF's capability probe went green while nothing downstream of it worked. The two
halves are integration-tested against each other now (tests/test_bff_contract.py)
rather than each against its own idea of the other.

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

import base64
import logging

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse, Response

from .poison import KNOWN_MODES, MODE_NONE, detect_backend, detect_perturbation, perturb
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


# The BFF enumerates the homeserver's SERVED sizes as LABELS ("small" for akkoma,
# "240x240" for Matrix — app.media.poisoning.thumbnail-sizes), not as integers. The
# original int-only parser dropped every one of those on a ValueError and silently fell
# through to the defaults, so the pinned sizes never reached the backend at all.
_NAMED_SIZES = {"small": 400, "thumbnail": 400, "preview": 400, "medium": 640, "original": 0}


def _parse_sizes(raw: str | None) -> list[int] | None:
    """Parse the served-size list, accepting ints, ``WxH`` and the BFF's named sizes."""

    if not raw:
        return None
    out: list[int] = []
    for part in raw.split(","):
        part = part.strip().lower()
        if not part:
            continue
        if part in _NAMED_SIZES:
            if _NAMED_SIZES[part]:
                out.append(_NAMED_SIZES[part])
            continue
        if "x" in part:  # "240x240" -> the larger edge
            dims = [d for d in part.split("x") if d.strip().isdigit()]
            if dims:
                out.append(max(int(d) for d in dims))
                continue
        try:
            out.append(int(part))
        except ValueError:
            log.warning("unparseable served size %r ignored", part)
    return out or None


def _normalize_mode(mode: str | None) -> str:
    mode = (mode or "glaze").strip().lower()
    if mode not in KNOWN_MODES:
        # Unknown mode is coerced to a safe default inside perturb(); log it.
        log.warning("unknown mode %r coerced to default", mode)
    return mode


def _apply(data: bytes, mode: str, sizes: str | None) -> bytes:
    """Shared body of both /poison encodings: bounds-check, apply, fail honestly."""

    if len(data) > MAX_IMAGE_BYTES:
        raise HTTPException(status_code=413, detail="image too large")
    if mode == MODE_NONE:
        return data  # opt-out: caller forwards verbatim.
    out = perturb(data, mode=mode, sizes=_parse_sizes(sizes))
    # perturb() returns the ORIGINAL bytes unchanged when the upload is not a
    # decodable image (or Pillow/numpy are missing). Signal that to the BFF as 415
    # so its round-trip gate doesn't mark un-perturbed bytes "protected".
    if out is data:
        raise HTTPException(status_code=415, detail="not a decodable image; nothing perturbed")
    return out


@app.post("/poison")
async def poison(request: Request) -> Response:
    """Apply the perturbation for ``mode``; see the module docstring for both encodings.

    The BFF holds the plaintext bytes only transiently; this worker does the same
    (read into memory, perturb, return — no disk write).
    """

    ctype = (request.headers.get("content-type") or "").lower()

    if ctype.startswith("multipart/form-data"):
        form = await request.form()
        upload = form.get("image")
        if not hasattr(upload, "read"):
            raise HTTPException(status_code=422, detail="multipart field 'image' is required")
        data = await upload.read()
        mode = _normalize_mode(str(form.get("mode") or "glaze"))
        out = _apply(data, mode, _form_str(form.get("sizes")))
        if mode == MODE_NONE:
            return Response(content=out,
                            media_type=upload.content_type or "application/octet-stream")
        return Response(content=out, media_type="image/jpeg")

    # The BFF's encoding: raw body + X-Cloak-* headers -> the JSON PoisonResult it decodes.
    data = await request.body()
    mode = _normalize_mode(request.headers.get("X-Cloak-Mode"))
    out = _apply(data, mode, request.headers.get("X-Cloak-Thumbnail-Sizes"))
    unchanged = mode == MODE_NONE
    return JSONResponse(
        {
            "ok": True,
            "backend": BACKEND.kind,
            "poisonedOriginal": base64.b64encode(out).decode("ascii"),
            # The BFF declares a per-size derivative list but consumes ONLY
            # poisonedOriginal (nothing reads PoisonResult.thumbnails), and the
            # homeserver regenerates its own thumbnails from the original anyway — so
            # the "no clean derivative" property comes from the perturbation surviving
            # the downscale, not from shipping derivatives. Empty, not fabricated.
            "thumbnails": [],
            "detail": ("mode=none: forwarded unchanged" if unchanged
                       else f"perturbed with mode={mode} on backend={BACKEND.kind}"),
        }
    )


def _form_str(v) -> str | None:
    return None if v is None else str(v)


@app.post("/survival")
async def survival(request: Request) -> JSONResponse:
    """Is the cloak still present in these SERVED bytes? -> SurvivalVerdict.

    Fail-honest by construction (see detect_perturbation): anything unmeasurable answers
    present=false with the reason. A verdict we could not compute is NOT a survival —
    over-claiming here would tell a user their work is protected when it is not.
    """

    data = await request.body()
    mode = _normalize_mode(request.headers.get("X-Cloak-Mode"))
    size = (request.headers.get("X-Cloak-Size") or "original").strip()
    present, score, detail = detect_perturbation(data, mode)
    log.info("[survival] size=%s mode=%s present=%s score=%s", size, mode, present, score)
    return JSONResponse({"present": present, "score": score, "detail": f"[{size}] {detail}"})
