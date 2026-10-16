# edge-ai-tts image — CPU-default Piper TTS + viseme timeline (VN voice, B3)

The container source for the `edge-ai-tts` optional service. It is a stateless
FastAPI wrapper around [Piper](https://github.com/OHF-Voice/piper1-gpl). It
synthesizes a short line of speech **and** returns an even-split **viseme timeline**
meant to drive 2D mouth-shape lipsync. It is the backend core of the VN voice feature
(B3), and it follows the structure of
[`../../edge-ai-analysis/image`](../../edge-ai-analysis/image).

> **The matrix-ui client does not use the timeline today.** It drives the VN mouth from
> audio loudness (amplitude only, "by product decision": matrix-ui `README.md`,
> `voice-synth.service.ts`), ignores `visemes`, and keeps its TTS call off by default
> (`VOICE_TTS_ENABLED`, default false).

Everything runs on-prem. All synthesis is local CPU work, nothing leaves the mesh, and
**no model is fetched at request time**: the default voice is baked into the image.

## API contract
`POST /v1/synthesize`
```jsonc
// request
{
  "text": "Hello, traveler.",   // required, <= TTS_MAX_CHARS (default 800); also <= 8000 at validation
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
- **FAIL-CLOSED**: a synthesis error returns HTTP 5xx, never a partial or empty "ok"
  body. Other errors:
  - 404: an unknown or uninstalled `voice`.
  - 400: an empty `text`, a `voice` id with a path separator or `..`, or a `format`
    other than `wav`/`pcm16`.
  - 413: text past `TTS_MAX_CHARS`.
  - 422: text past 8000 characters (request validation), or text that produces no
    audio (e.g. all punctuation).

  Audio is mandatory. The viseme timeline is best-effort: no phonemes gives a single
  `rest` span.
- Tenancy is enforced at the be-gateway (`/v1/synthesize/** = ROLE_USER`: row in
  `specs/cluster/manifests/route-access/initdb/20-schema.sql`, route in
  `specs/cluster/apps/20-gateway-be.yaml`). This service trusts and stamps the
  gateway-validated `X-Tenant-ID` / `X-User-ID` headers.

### Streaming (follow-up)
A `POST /v1/synthesize/stream` (WS or chunked) would emit audio chunks and interleaved
viseme frames as Piper finishes each sentence. It is an OPTIONAL later PR. For short
lines it only saves latency: the client can already start lipsync once it has the small
JSON body.

## Viseme timeline — even-split v1 (deterministic, fork-free)
1. Piper hands back the espeak-ng phoneme sequence per sentence
   (`AudioChunk.phonemes`, which line up 1:1 with the audio it produced).
2. Each phoneme is collapsed to one of **7 viseme keys** via `visemes.to_viseme`
   (longest-prefix IPA match; unknown → `rest`, never an error). Adjacent identical
   visemes are merged (`collapse_runs`) so the mouth holds a shape instead of flickering.
3. Those keys are spread **EVENLY** across the **measured** audio duration. Integer ms
   are distributed so the slices sum to `durationMs` exactly (no gap, no overrun).

### 7-key viseme vocabulary — CONTRACT, keep in sync with matrix-ui `viseme.ts` (B3-PR2)
`rest · AI · E · O · U · L · MBP`. The collapse table lives in
[`visemes.py`](./visemes.py). No `viseme.ts` exists in matrix-ui today (see the note at
the top), so no client reads these keys yet. A client that maps keys to mouth shapes must
mirror this vocabulary. **Add or rename a key here ⇒ mirror it there**, or the client
falls back to `rest` for the unknown key. Lipsync then degrades to a closed mouth, which
is safe but silent.

### True per-phoneme durations — documented later spike (NOT done here)
v1 is even-split, so it is deterministic and works for every voice. piper-tts 1.4.2
exposes `AudioChunk.phoneme_alignments` (audio sample counts per phoneme). It fills
them when the voice model carries alignment metadata and
`synthesize(..., include_alignments=True)` is passed (`piper/voice.py` in the 1.4.2
wheel). So the true-duration upgrade is a **call flag** that reads those alignments,
**not a fork of Piper**. It waits because (a) not all voices expose alignments and
(b) even-split is the simplest correct v1. It lands once client lipsync is tuned
against real timelines.

## CPU-default rationale
The image is `python:3.12-slim` + `onnxruntime` (CPU). **No nvidia base, no CUDA.** Piper
is real-time on CPU for the short lines a VN speaks, so a CPU pod is the default and
schedules anywhere in the mesh. A GPU variant (`use_cuda=True` + an onnxruntime-gpu
base) is a later optional flag.

## Voices
- The default `en_US-amy-medium` voice (`.onnx` + `.onnx.json`) is downloaded into
  `/models` at **build time** (stage 1) and baked in. The runtime image is offline.
- Add voices under `/models` and select them with the `voice` field. The shipped
  Deployment mounts no volume there, and a volume mounted at `/models` hides the baked
  voice, so it must hold the default voice too. Fetch a voice with:
  ```sh
  python -m piper.download_voices --download-dir /models en_US-lessac-medium
  ```
  `app.py` resolves `<voice>.onnx` + `<voice>.onnx.json` under `TTS_MODEL_DIR`. It
  refuses any path separator or `..` in the id (no MODEL_DIR escape).

## Config (env)
| var | default | meaning |
|-----|---------|---------|
| `TTS_MODEL_DIR` | `/models` | where voice files live (baked in, plus any volume you mount) |
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
Runs as non-root (uid 65532) with a read-only rootfs (the pod mounts an emptyDir at `/tmp`).

> **NOTE — runtime synthesis has NOT been executed.** No one has built this image and
> run a real `POST /v1/synthesize` against it in this repo. The container-build spike
> is still open: resolve the heavy `piper-tts` / `onnxruntime` wheels, then check
> synthesis and viseme output. The first `make stack-up TTS=1` run is that spike
> (`tests/stack/compose.edge-ai-tts.yaml` builds this directory).

## Follow-up PRs (not in this one)
The k8s wiring was kept apart from the image source (PR8–11). Status today:
- **k8s manifests** — landed: `deployment.yaml` / `service.yaml` / `configmap.yaml` /
  `network-policy.yaml` / `kustomization.yaml` in `specs/cluster/manifests/edge-ai-tts/`.
- **generator slug** — landed: `--with-edge-ai-tts` / `--optional-services edge-ai-tts`
  (x86 and rpi5 builders), DEFAULT-OFF until the image is pushed.
- **gateway route** — landed: `/v1/synthesize/** = ROLE_USER` (see above).
- **matrix-ui PR2** — not built: there is no `viseme.ts`, and matrix-ui is amplitude-only.

## Run locally (needs the heavy wheels + a voice)
```sh
pip install -r requirements.txt
python -m piper.download_voices --download-dir ./models en_US-amy-medium
TTS_MODEL_DIR=./models uvicorn app:app --port 8080
```
