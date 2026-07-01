"""snapdragon-edge-ai-tts — CPU-default Piper text-to-speech for the VN voice feature
(B3). Stateless FastAPI wrapper around rhasspy/piper that synthesizes a short line of
speech AND returns an even-split viseme timeline the matrix-ui VN client uses to drive
2D mouth-shape lipsync (B3-PR2). ON-PREM: all synthesis is local CPU work; nothing
leaves the mesh and no model is fetched at request time (the default voice is baked in).

Auth/tenancy is enforced at the be-gateway (route-access /v1/synthesize/** = ROLE_USER);
this service trusts the gateway-validated X-Tenant-ID / X-User-ID headers and stamps
every response with them. FAIL-CLOSED: a synthesis call that errors returns HTTP 5xx and
never a partial/empty "ok" body — the client must get audio or an explicit error.

VISEME timeline v1 = EVEN-SPLIT (deterministic, fork-free):
  1. Piper hands back the espeak-ng phoneme sequence per sentence (AudioChunk.phonemes),
  2. collapse each phoneme to one of 7 viseme keys via visemes.to_viseme,
  3. spread those keys EVENLY across the MEASURED audio duration.
True per-phoneme durations are a documented later spike (see README): piper-tts 1.4.x
already exposes AudioChunk.phoneme_alignments (sample counts per phoneme) when the voice
model supports it, so the spike is a config flag — NOT a fork — but v1 stays even-split
for determinism and to keep parity with voices that don't carry alignment metadata.
"""
from __future__ import annotations

import base64
import io
import os
import wave
from datetime import datetime, timezone
from functools import lru_cache
from typing import TYPE_CHECKING, Any

from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel, Field

import visemes

if TYPE_CHECKING:  # import only for type hints; the native wheel is loaded lazily
    from piper import PiperVoice

# ── config ───────────────────────────────────────────────────────────────────
# The default voice (.onnx + .onnx.json) is baked into the image under MODEL_DIR.
# Additional voices are pulled to a PVC and selected by `voice` (see README).
MODEL_DIR = os.environ.get("TTS_MODEL_DIR", "/models")
DEFAULT_VOICE = os.environ.get("TTS_DEFAULT_VOICE", "en_US-amy-medium")
# length_scale: Piper "speed" — >1 slower, <1 faster; None = the voice's natural rate.
LENGTH_SCALE = float(os.environ.get("TTS_LENGTH_SCALE", "1.0"))
NOISE_SCALE = float(os.environ.get("TTS_NOISE_SCALE", "0.667"))
NOISE_W = float(os.environ.get("TTS_NOISE_W", "0.8"))
MAX_CHARS = int(os.environ.get("TTS_MAX_CHARS", "800"))  # short VN lines only

app = FastAPI(title="snapdragon-edge-ai-tts", version="1.0")


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _voice_paths(voice: str) -> tuple[str, str]:
    """Resolve (onnx, onnx.json) for a voice id; fail-closed on traversal / missing files.

    `voice` is an untrusted client field. We allow only a simple id and refuse any path
    separator or dot-dot so a caller cannot escape MODEL_DIR.
    """
    if not voice or "/" in voice or "\\" in voice or ".." in voice:
        raise HTTPException(status_code=400, detail="invalid voice id")
    onnx = os.path.join(MODEL_DIR, f"{voice}.onnx")
    cfg = f"{onnx}.json"
    if not (os.path.isfile(onnx) and os.path.isfile(cfg)):
        # fail-closed: an unknown voice is a client error, never a silent fallback
        raise HTTPException(status_code=404, detail=f"voice not installed: {voice}")
    return onnx, cfg


@lru_cache(maxsize=8)
def _load_voice(voice: str) -> "PiperVoice":
    """Load + cache a PiperVoice (CPU). Imported lazily so module import (and py_compile /
    OpenAPI generation) does not require the piper-tts native wheel to be present."""
    from piper import PiperVoice  # type: ignore[import-not-found]

    onnx, cfg = _voice_paths(voice)
    # use_cuda=False is the default and the whole point of this CPU image.
    return PiperVoice.load(onnx, config_path=cfg, use_cuda=False)


def _syn_config(voice: str):
    """Build the per-request SynthesisConfig (CPU; deterministic-ish for short lines)."""
    from piper import SynthesisConfig  # type: ignore[import-not-found]

    return SynthesisConfig(
        length_scale=LENGTH_SCALE,
        noise_scale=NOISE_SCALE,
        noise_w_scale=NOISE_W,
    )


def _synthesize(voice: str, text: str) -> tuple[bytes, int, list[str]]:
    """Run Piper -> (pcm16_mono bytes, sample_rate, phonemes).

    piper.synthesize() yields one AudioChunk per sentence; we concatenate the int16 PCM
    and flatten the espeak phoneme lists (the phonemes that PRODUCED the audio, so they
    line up 1:1 with what was spoken). Raises on synthesis failure (caller fails closed).
    """
    voice_obj = _load_voice(voice)
    syn = _syn_config(voice)
    pcm = bytearray()
    phonemes: list[str] = []
    sample_rate = 0
    for chunk in voice_obj.synthesize(text, syn_config=syn):
        sample_rate = chunk.sample_rate
        pcm.extend(chunk.audio_int16_bytes)
        phonemes.extend(chunk.phonemes)
    return bytes(pcm), sample_rate, phonemes


def _duration_ms(pcm16_mono: bytes, sample_rate: int) -> int:
    """Measured audio duration in ms from raw 16-bit mono PCM byte length."""
    if sample_rate <= 0:
        return 0
    n_samples = len(pcm16_mono) // 2  # 16-bit -> 2 bytes/sample, mono
    return int(round(n_samples * 1000 / sample_rate))


def _even_split_visemes(phonemes: list[str], total_ms: int) -> list[dict[str, Any]]:
    """Spread collapsed visemes EVENLY across the measured duration (v1).

    Deterministic and fork-free: we don't use each phoneme's true duration, so every
    viseme gets an equal slice of `total_ms`. Runs of the same viseme are collapsed
    first so on-screen the mouth holds a shape instead of flickering identically.
    Integer ms are distributed so the slices sum EXACTLY to total_ms (no gap/overrun).
    """
    keys = visemes.collapse_runs([visemes.to_viseme(p) for p in phonemes])
    if not keys or total_ms <= 0:
        return [{"key": visemes.REST, "startMs": 0, "durMs": max(total_ms, 0)}]
    n = len(keys)
    base, extra = divmod(total_ms, n)  # spread the remainder onto the first `extra` slices
    timeline: list[dict[str, Any]] = []
    cursor = 0
    for i, key in enumerate(keys):
        dur = base + (1 if i < extra else 0)
        timeline.append({"key": key, "startMs": cursor, "durMs": dur})
        cursor += dur
    return timeline


def _wrap_wav(pcm16_mono: bytes, sample_rate: int) -> bytes:
    """Wrap raw 16-bit mono PCM into a RIFF/WAV container for browser <audio>."""
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(sample_rate)
        wav.writeframes(pcm16_mono)
    return buf.getvalue()


# ── models ───────────────────────────────────────────────────────────────────
class SynthReq(BaseModel):
    text: str = Field(..., min_length=1)
    voice: str | None = None       # voice id installed under MODEL_DIR (default below)
    character: str | None = None   # VN character id — reserved for per-character voices
    format: str = "wav"            # 'wav' (RIFF base64) | 'pcm16' (raw little-endian)


# ── health ───────────────────────────────────────────────────────────────────
@app.get("/healthz")
async def healthz() -> dict[str, str]:
    """Liveness — process is up. Does NOT touch the model (cheap, always answers)."""
    return {"status": "ok"}


@app.get("/readyz")
async def readyz() -> dict[str, str]:
    """Ready only when the default voice files are present on disk (we can synthesize)."""
    try:
        _voice_paths(DEFAULT_VOICE)
    except HTTPException:
        raise HTTPException(status_code=503, detail=f"default voice not installed: {DEFAULT_VOICE}")
    return {"status": "ready"}


# ── synthesis ────────────────────────────────────────────────────────────────
@app.post("/v1/synthesize")
async def synthesize(
    req: SynthReq,
    x_tenant_id: str = Header("unknown"),
    x_user_id: str = Header("unknown"),
):
    """Synthesize one short line -> { audioBase64, sampleRate, format, visemes[] }.

    FAIL-CLOSED: synthesis errors raise HTTP 5xx; we never return an empty/partial
    "ok" body. The viseme timeline is best-effort (no phonemes yields a single `rest`
    span) but audio is mandatory.
    """
    text = req.text.strip()
    if not text:
        raise HTTPException(status_code=400, detail="text is empty")
    if len(text) > MAX_CHARS:
        raise HTTPException(status_code=413, detail=f"text exceeds {MAX_CHARS} chars")
    fmt = (req.format or "wav").lower()
    if fmt not in ("wav", "pcm16"):
        raise HTTPException(status_code=400, detail="format must be 'wav' or 'pcm16'")
    voice = req.voice or DEFAULT_VOICE
    # validate voice id / existence up front (fail-closed) before doing any work
    _voice_paths(voice)

    try:
        pcm, sample_rate, phonemes = _synthesize(voice, text)
    except HTTPException:
        raise
    except Exception as e:  # noqa: BLE001 — fail-closed: surface as a server error
        raise HTTPException(status_code=500, detail=f"synthesis failed: {e}") from e

    if not pcm or sample_rate <= 0:
        # Piper produced nothing (e.g. text was all punctuation) — fail closed.
        raise HTTPException(status_code=422, detail="no audio produced for the given text")

    total_ms = _duration_ms(pcm, sample_rate)
    timeline = _even_split_visemes(phonemes, total_ms)
    audio_bytes = pcm if fmt == "pcm16" else _wrap_wav(pcm, sample_rate)

    return {
        "audioBase64": base64.b64encode(audio_bytes).decode("ascii"),
        "sampleRate": sample_rate,
        "format": fmt,
        "durationMs": total_ms,
        "voice": voice,
        "visemes": timeline,
        "tenant_id": x_tenant_id,
        "user_id": x_user_id,
        "timestamp": _now(),
    }


# NOTE (follow-up): a streaming variant — WS or chunked `POST /v1/synthesize/stream`
# that emits audio chunks + interleaved viseme frames as Piper produces each sentence
# AudioChunk — is an OPTIONAL later PR. The even-split timeline already lets the client
# start lipsync the moment it has the (small) JSON body, so streaming is a latency
# optimisation, not a correctness requirement, for short VN lines.
