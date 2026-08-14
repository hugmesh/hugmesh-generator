# edge-ai-tts image — CPU-default Piper TTS + viseme timeline (VN voice, B3)

The container source for the `edge-ai-tts` optional service — a stateless FastAPI
wrapper around [rhasspy/piper](https://github.com/OHF-Voice/piper1-gpl) that synthesizes a
short line of speech **and** returns an even-split **viseme timeline** the matrix-ui VN
client uses to drive 2D mouth-shape lipsync. It is the greenfield backend core of the VN
voice feature (B3). Mirrors the structure of the only built FastAPI precedent,
[`../../edge-ai-analysis/image`](../../edge-ai-analysis/image).

ON-PREM: all synthesis is local CPU work; nothing leaves the mesh and **no model is
fetched at request time** — the default voice is baked into the image.

## API contract
`POST /v1/synthesize`
```jsonc
// request
{
  "text": "Hello, traveler.",   // required, <= TTS_MAX_CHARS (default 800)
  "voice": "en_US-amy-medium",  // optional; a voice id installed under /models
  "character": "mira",          // optional; reserved for per-character voices (future)
  "format": "wav"               // "wav" (RIFF base64) | "pcm16" (raw LE base64)
}
// 200 response
{
  "audioBase64": "<base64>",    // WAV or raw 16-bit mono PCM, per `format`
  "sampleRate": 22050,
  "format": "wav",
  "durationMs": 1234,           // MEASURED from the produced PCM
  "voice": "en_US-amy-medium",
  "visemes": [                  // even-split timeline (see below)
    { "key": "MBP", "startMs": 0,   "durMs": 90 },
    { "key": "E",   "startMs": 90,  "durMs": 90 },
    { "key": "L",   "startMs": 180, "durMs": 90 }
  ],
  "tenant_id": "...", "user_id": "...", "timestamp": "..."
}
```
- `GET /healthz` (liveness — never touches the model) · `GET /readyz` (ready iff the
  default voice files are present on disk).
- **FAIL-CLOSED**: synthesis errors return HTTP 5xx and never a partial/empty "ok" body;
  an unknown/uninstalled `voice` is a 404; text past `TTS_MAX_CHARS` is a 413; text that
  produces no audio (e.g. all punctuation) is a 422. Audio is mandatory; the viseme
  timeline is best-effort (no phonemes → a single `rest` span).
- Tenancy is enforced at the be-gateway (`/v1/synthesize/** = ROLE_USER`, a follow-up
  route PR); this service trusts and stamps the gateway-validated `X-Tenant-ID` /
  `X-User-ID` headers.

### Streaming (follow-up)
A `POST /v1/synthesize/stream` (WS or chunked) that emits audio chunks + interleaved
viseme frames as Piper produces each sentence is an OPTIONAL later PR. The even-split
timeline already lets the client start lipsync the moment it has the (small) JSON body,
so streaming is a latency optimisation, not a correctness requirement, for short lines.

## Viseme timeline — even-split v1 (deterministic, fork-free)
1. Piper hands back the espeak-ng phoneme sequence per sentence
   (`AudioChunk.phonemes`, which line up 1:1 with the audio it produced).
2. Each phoneme is collapsed to one of **7 viseme keys** via `visemes.to_viseme`
   (longest-prefix IPA match; unknown → `rest`, never an error). Adjacent identical
   visemes are merged (`collapse_runs`) so the mouth holds a shape instead of flickering.
3. Those keys are spread **EVENLY** across the **measured** audio duration; integer ms
   are distributed so the slices sum to `durationMs` exactly (no gap/overrun).

### 7-key viseme vocabulary — CONTRACT, keep in sync with matrix-ui `viseme.ts` (B3-PR2)
`rest · AI · E · O · U · L · MBP`. The collapse table lives in
[`visemes.py`](./visemes.py); the matrix-ui PR2 `viseme.ts` maps each key → a mouth
shape. **Add/rename a key here ⇒ mirror it in `viseme.ts`**, or the client falls back to
`rest` for the unknown key (lipsync degrades to a closed mouth — safe, but silent there).

### True per-phoneme durations — documented later spike (NOT done here)
v1 is even-split so it stays deterministic and works for every voice. piper-tts 1.4.x
already exposes `AudioChunk.phoneme_alignments` (audio sample counts per phoneme) when
the voice model carries alignment metadata — so the true-duration upgrade is a **config
flag** that consumes those alignments, **not a fork of Piper**. Deferred because (a) not
all voices expose alignments and (b) even-split is the simplest correct v1; the upgrade
lands once the client lipsync is tuned against real timelines.

## CPU-default rationale
The image is `python:3.12-slim` + `onnxruntime` (CPU). **No nvidia base, no CUDA.** Piper
is real-time on CPU for the short lines a VN speaks, so a CPU pod is the right default and
schedules anywhere in the mesh. A GPU variant (`use_cuda=True` + an onnxruntime-gpu base)
is a later optional flag, not the default.

## Voices
- The default `en_US-amy-medium` voice (`.onnx` + `.onnx.json`) is downloaded into
  `/models` at **build time** (stage 1) and baked in — the runtime image is offline.
- Pull additional voices to a **PVC** mounted at `/models` and select them with the
  `voice` field, e.g.:
  ```sh
  python -m piper.download_voices --download-dir /models en_US-lessac-medium
  ```
  `app.py` resolves `<voice>.onnx` + `<voice>.onnx.json` under `TTS_MODEL_DIR` and
  refuses any path separator / `..` in the id (no MODEL_DIR escape).

## Config (env)
| var | default | meaning |
|-----|---------|---------|
| `TTS_MODEL_DIR` | `/models` | where voice files live (baked + PVC) |
| `TTS_DEFAULT_VOICE` | `en_US-amy-medium` | voice used when the request omits `voice` |
| `TTS_LENGTH_SCALE` | `1.0` | Piper speed (>1 slower, <1 faster) |
| `TTS_NOISE_SCALE` | `0.667` | generator noise |
| `TTS_NOISE_W` | `0.8` | phoneme-width noise |
| `TTS_MAX_CHARS` | `800` | reject longer text (VN lines are short) |

## Build
```sh
docker build -t registry.hugmesh.net/hugmesh/edge-ai-tts:main .
docker push  registry.hugmesh.net/hugmesh/edge-ai-tts:main
```
Runs as non-root (uid 65532) with a read-only rootfs (pod mounts an emptyDir at `/tmp`).

> **NOTE — runtime synthesis was NOT executed in this PR.** This change adds the image
> source only; a container-build spike (which resolves the heavy `piper-tts` /
> `onnxruntime` wheels and runs a real `POST /v1/synthesize`) validates synthesis +
> viseme output before merge. The generator repo is **ASK-to-merge**, so this lands as a
> DRAFT pending that spike and user review.

## Follow-up PRs (not in this one)
The k8s wiring is intentionally separate (PR8–11):
- **k8s manifests** — `deployment.yaml` / `service.yaml` / `configmap.yaml` /
  `network-policy.yaml` / `kustomization.yaml` (mirror `../../edge-ai-analysis/`).
- **generator slug** — `--with-edge-ai-tts` / `--optional-services edge-ai-tts`,
  DEFAULT-OFF until the image is pushed.
- **gateway route** — `/v1/synthesize/** = ROLE_USER` route-access on the be-gateway.
- **matrix-ui PR2** — `viseme.ts` mouth-shape map consuming this 7-key vocabulary.

## Run locally (needs the heavy wheels + a voice)
```sh
pip install -r requirements.txt
python -m piper.download_voices --download-dir ./models en_US-amy-medium
TTS_MODEL_DIR=./models uvicorn app:app --port 8080
```
