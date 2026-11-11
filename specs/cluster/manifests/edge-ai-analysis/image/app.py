"""hugmesh-edge-ai-analysis — task-oriented analysis API over the edge-AI model
server. Stateless FastAPI wrapper that turns Ollama's OpenAI-compatible model API into
structured verdicts the mesh consumes (image NSFW/abuse classify + perceptual-hash, log
triage). ON-PREM: it only calls the in-cluster Ollama upstream; nothing leaves the mesh.

Auth/tenancy is enforced at the be-gateway (route-access /v1/analyze/** = ROLE_USER);
this service trusts the gateway-validated X-Tenant-ID / X-User-ID headers and stamps
every verdict with them. FAIL-CLOSED: a moderation call that errors returns action
"reject" (never "allow" on uncertainty).
"""
from __future__ import annotations

import base64
import binascii
import io
import ipaddress
import json
import os
import re
import socket
from datetime import datetime, timezone
from typing import Any

import httpx
import imagehash
from fastapi import FastAPI, Header, HTTPException
from PIL import Image
from pydantic import BaseModel

UPSTREAM = os.environ.get("EDGE_AI_UPSTREAM", "http://hugmesh-edge-ai.hugmesh-inference.svc.cluster.local:11434").rstrip("/")
VISION_MODEL = os.environ.get("ANALYSIS_VISION_MODEL", "llava:7b")
REASON_MODEL = os.environ.get("ANALYSIS_REASON_MODEL", "llama3.2:3b")
NSFW_THRESHOLD = float(os.environ.get("ANALYSIS_NSFW_THRESHOLD", "0.7"))
ABUSE_THRESHOLD = float(os.environ.get("ANALYSIS_ABUSE_THRESHOLD", "0.7"))
MODERATE_ACTION = os.environ.get("ANALYSIS_MODERATE_ACTION", "reject")  # reject (fail-closed) | flag

app = FastAPI(title="hugmesh-edge-ai-analysis", version="1.0")


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _verdict(task: str, tenant: str, user: str, model: str, result: dict[str, Any]) -> dict[str, Any]:
    return {"task": task, "tenant_id": tenant, "user_id": user, "model_used": model,
            "timestamp": _now(), "result": result}


# One detail for every image_url the guard refuses, whatever the reason. Separate
# "does not resolve" and "non-public address" answers would let a caller learn which
# internal names exist.
_IMAGE_URL_REFUSED = "image_url must be a public http(s) URL"
# One detail for every failed fetch. The underlying httpx error names the address,
# port and failure mode (refused, timed out, reset), so echoing it would turn this
# endpoint into a reachability probe.
_IMAGE_URL_FETCH_FAILED = "could not fetch image_url"

# TLS trust for image_url fetches. Built once. httpx.create_ssl_context() reads
# SSL_CERT_FILE / SSL_CERT_DIR as before; the fetch client itself runs with
# trust_env=False, so no proxy variable can route the request around the pinned
# address.
_TLS_CONTEXT = httpx.create_ssl_context()


def _is_public_address(ip: ipaddress.IPv4Address | ipaddress.IPv6Address) -> bool:
    """True only for a globally routable unicast address.

    is_global is the primary test. It refuses everything is_private does and also
    100.64.0.0/10 (CGNAT, which is the mesh's own headscale tailnet, MagicDNS
    100.100.100.100 included), which is_private does not cover. The explicit
    predicates stay as well, because is_global alone accepts multicast. IPv6 forms that carry an IPv4
    address are covered by the same predicates: an IPv4-mapped address is judged by
    its IPv4 address, 6to4 (2002::/16) counts as private and NAT64 (64:ff9b::/96) as
    reserved."""
    if not ip.is_global:
        return False
    return not (ip.is_private or ip.is_loopback or ip.is_link_local
                or ip.is_reserved or ip.is_multicast or ip.is_unspecified)


def _resolve_public_image_url(url: str) -> tuple[httpx.URL, str]:
    """SSRF guard. image_url is user-supplied (behind the ROLE_USER be-gateway) and must
    only reference a PUBLIC http(s) endpoint. The URL is parsed ONCE, by the same parser
    that builds the request, so the guard and the fetch cannot disagree about the host.
    Every address the host resolves to must be public (see _is_public_address);
    one non-public answer refuses the whole URL.

    Returns the parsed URL and the vetted address the fetch must connect to. The caller
    connects to that address and does not resolve the name again, which closes the
    DNS-rebinding window between this check and the fetch."""
    try:
        parsed = httpx.URL(url)
    except (httpx.InvalidURL, TypeError, ValueError):
        raise HTTPException(status_code=400, detail=_IMAGE_URL_REFUSED) from None
    if parsed.scheme not in ("http", "https") or not parsed.raw_host:
        raise HTTPException(status_code=400, detail=_IMAGE_URL_REFUSED)
    try:
        host = parsed.raw_host.decode("ascii")
    except UnicodeDecodeError:
        raise HTTPException(status_code=400, detail=_IMAGE_URL_REFUSED) from None
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    try:
        addrinfos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM, proto=socket.IPPROTO_TCP)
    except (OSError, UnicodeError):
        raise HTTPException(status_code=400, detail=_IMAGE_URL_REFUSED) from None
    vetted: list[str] = []
    for info in addrinfos:
        try:
            ip = ipaddress.ip_address(info[4][0])
        except ValueError:
            raise HTTPException(status_code=400, detail=_IMAGE_URL_REFUSED) from None
        if not _is_public_address(ip):
            raise HTTPException(status_code=400, detail=_IMAGE_URL_REFUSED)
        vetted.append(str(ip))
    if not vetted:
        raise HTTPException(status_code=400, detail=_IMAGE_URL_REFUSED)
    return parsed, vetted[0]


def _fetch_image_url(image_url: str) -> bytes:
    """GET image_url from the address the guard vetted.

    The request goes to the IP literal, so httpx never looks the name up itself. The
    Host header and the TLS SNI / certificate check still use the original name
    (httpx's documented sni_hostname request extension). Redirects are not followed,
    and every failure returns the same generic detail."""
    parsed, address = _resolve_public_image_url(image_url)
    pinned = parsed.copy_with(host=address)
    host_header = parsed.netloc.decode("ascii")
    server_name = parsed.raw_host.decode("ascii")
    try:
        with httpx.Client(timeout=10.0, follow_redirects=False, trust_env=False,
                          verify=_TLS_CONTEXT) as client:
            r = client.get(pinned, headers={"Host": host_header},
                           extensions={"sni_hostname": server_name})
            r.raise_for_status()
            return r.content
    except httpx.HTTPError:
        raise HTTPException(status_code=400, detail=_IMAGE_URL_FETCH_FAILED) from None


def _decode_image(image_b64: str | None, image_url: str | None) -> bytes:
    if image_b64:
        try:
            return base64.b64decode(image_b64, validate=True)
        except (binascii.Error, ValueError):
            raise HTTPException(status_code=400, detail="image_b64 is not valid base64")
    if image_url:
        return _fetch_image_url(image_url)
    raise HTTPException(status_code=400, detail="provide image_b64 or image_url")


def _phash(data: bytes) -> str:
    try:
        with Image.open(io.BytesIO(data)) as im:
            return str(imagehash.phash(im.convert("RGB")))
    except Exception as e:  # noqa: BLE001 — any decode failure is a client error
        raise HTTPException(status_code=400, detail=f"not a decodable image: {e}")


def _extract_json(text: str) -> dict[str, Any]:
    """Best-effort: pull the first {...} block out of a model's free-text answer."""
    m = re.search(r"\{.*\}", text, re.DOTALL)
    if not m:
        return {}
    try:
        return json.loads(m.group(0))
    except json.JSONDecodeError:
        return {}


async def _ollama_chat(model: str, prompt: str, images_b64: list[str] | None = None) -> str:
    msg: dict[str, Any] = {"role": "user", "content": prompt}
    if images_b64:
        msg["images"] = images_b64
    body = {"model": model, "messages": [msg], "stream": False, "options": {"temperature": 0}}
    async with httpx.AsyncClient(timeout=120.0) as client:
        r = await client.post(f"{UPSTREAM}/api/chat", json=body)
        r.raise_for_status()
        return (r.json().get("message") or {}).get("content", "")


_CLASSIFY_PROMPT = (
    "You are a strict content-safety classifier. Look at the image and respond with ONLY a "
    "JSON object: {\"classification\": one of \"safe\",\"nsfw\",\"abuse\", "
    "\"confidence\": a number 0..1, \"tags\": [short strings]}. "
    "nsfw = sexual/explicit nudity; abuse = violence, gore, hate symbols, or CSAM indicators. "
    "Be conservative: if unsure between safe and unsafe, prefer the unsafe label."
)


def _classify_result(raw: str, data: bytes) -> dict[str, Any]:
    parsed = _extract_json(raw)
    classification = str(parsed.get("classification", "unknown")).lower()
    if classification not in ("safe", "nsfw", "abuse", "unknown"):
        classification = "unknown"
    try:
        confidence = float(parsed.get("confidence", 0.0))
    except (TypeError, ValueError):
        confidence = 0.0
    tags = [str(t) for t in parsed.get("tags", []) if isinstance(t, (str, int, float))][:12]
    threshold = ABUSE_THRESHOLD if classification == "abuse" else NSFW_THRESHOLD
    policy_hit = classification in ("nsfw", "abuse") and confidence >= threshold
    return {"classification": classification, "confidence": round(confidence, 4),
            "tags": tags, "policy_hit": policy_hit, "perceptual_hash": _phash(data),
            "raw_output": raw[:2000]}


# ── models ──────────────────────────────────────────────────────────────────
class ImageReq(BaseModel):
    image_b64: str | None = None
    image_url: str | None = None


class LogReq(BaseModel):
    logs: list[str] = []
    source: str = "unknown"


# ── health ──────────────────────────────────────────────────────────────────
@app.get("/healthz")
async def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/readyz")
async def readyz() -> dict[str, str]:
    """Ready only when the edge-AI upstream is reachable (we delegate inference to it)."""
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            r = await client.get(f"{UPSTREAM}/api/tags")
            r.raise_for_status()
    except httpx.HTTPError as e:
        raise HTTPException(status_code=503, detail=f"edge-ai upstream not ready: {e}")
    return {"status": "ready"}


# ── analysis endpoints ──────────────────────────────────────────────────────
@app.post("/v1/analyze/image/classify")
async def classify(req: ImageReq, x_tenant_id: str = Header("unknown"), x_user_id: str = Header("unknown")):
    data = _decode_image(req.image_b64, req.image_url)
    raw = await _ollama_chat(VISION_MODEL, _CLASSIFY_PROMPT, images_b64=[base64.b64encode(data).decode()])
    return _verdict("image.classify", x_tenant_id, x_user_id, VISION_MODEL, _classify_result(raw, data))


@app.post("/v1/analyze/image/hash")
async def image_hash(req: ImageReq, x_tenant_id: str = Header("unknown"), x_user_id: str = Header("unknown")):
    data = _decode_image(req.image_b64, req.image_url)
    with Image.open(io.BytesIO(data)) as im:
        rgb = im.convert("RGB")
        result = {"perceptual_hash": str(imagehash.phash(rgb)),
                  "average_hash": str(imagehash.average_hash(rgb)),
                  "difference_hash": str(imagehash.dhash(rgb))}
    return _verdict("image.hash", x_tenant_id, x_user_id, "imagehash", result)


@app.post("/v1/analyze/content/moderate")
async def moderate(req: ImageReq, x_tenant_id: str = Header("unknown"), x_user_id: str = Header("unknown")):
    """Pre-publish moderation. FAIL-CLOSED: on a policy hit OR any inference error the
    action is the configured fail-closed action (default "reject")."""
    data = _decode_image(req.image_b64, req.image_url)
    try:
        raw = await _ollama_chat(VISION_MODEL, _CLASSIFY_PROMPT, images_b64=[base64.b64encode(data).decode()])
        result = _classify_result(raw, data)
        result["action"] = MODERATE_ACTION if result["policy_hit"] else "allow"
    except httpx.HTTPError:
        # fail-closed: never "allow" when the classifier could not run
        result = {"classification": "unknown", "confidence": 0.0, "tags": ["classifier-error"],
                  "policy_hit": True, "perceptual_hash": _phash(data), "action": "reject",
                  "raw_output": "edge-ai upstream error — failing closed"}
    return _verdict("content.moderate", x_tenant_id, x_user_id, VISION_MODEL, result)


_LOG_PROMPT = (
    "You are an SRE triage assistant. Summarize these infrastructure/security log lines and "
    "respond with ONLY a JSON object: {\"summary\": short string, "
    "\"severity\": one of \"info\",\"warning\",\"critical\", \"anomalies\": [short strings]}. "
    "Flag intrusion attempts, file-integrity changes, repeated failures, and policy violations."
)


@app.post("/v1/analyze/log/summarize")
async def summarize(req: LogReq, x_tenant_id: str = Header("unknown"), x_user_id: str = Header("unknown")):
    if not req.logs:
        raise HTTPException(status_code=400, detail="logs[] is empty")
    prompt = f"{_LOG_PROMPT}\n\nsource={req.source}\n---\n" + "\n".join(req.logs[:500])
    raw = await _ollama_chat(REASON_MODEL, prompt)
    parsed = _extract_json(raw)
    severity = str(parsed.get("severity", "info")).lower()
    if severity not in ("info", "warning", "critical"):
        severity = "info"
    result = {"summary": str(parsed.get("summary", raw[:500])), "severity": severity,
              "anomalies": [str(a) for a in parsed.get("anomalies", [])][:20], "raw_output": raw[:2000]}
    return _verdict("log.summarize", x_tenant_id, x_user_id, REASON_MODEL, result)
