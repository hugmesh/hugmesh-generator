# Image-gen worker progress side channel

The image-build worker (`docker/build-image.sh`) reports exactly ONE **terminal**
result to `INGEST_URL` (`send_ingest`, the `COMPLETED`/`FAILED`/`ERROR` contract).
That leaves a real build's web progress bar frozen at the orchestrator's initial
frame until the build finishes. This adds an **optional, non-terminal** progress
producer that fills the gap without touching the terminal contract.

## Worker side (this repo)

- **`PROGRESS_URL`** (optional env). When set, `forward_and_wait` tees the builder's
  **stdout** through `docker/progress-tap.py` (a FIFO the parent pins at both ends;
  the builder stays the single tracked `$child_pid`, so its real exit code and
  SIGTERM forwarding are byte-for-byte unchanged, and its stderr streams direct).
  The tap re-emits every stdout line to the Job log verbatim AND POSTs throttled
  phase→percent frames to `PROGRESS_URL`. Tunables: `PROGRESS_MIN_INTERVAL`
  (seconds between on-percent frames, default 1) and `PROGRESS_CURL_TIMEOUT`
  (per-POST curl `--max-time`, default 2).
- **Unset (today's Job) → byte-identical to before.** The whole tap branch is gated
  on `[ -n "$PROGRESS_URL" ]`; `PROGRESS_URL` is `${PROGRESS_URL:-}` (set -u safe),
  is NOT in the required-env loop, and touches neither `send_ingest`, the terminal
  `COMPLETED` path, nor `resolve_build_target()`.
- **Parsing is reused, not reimplemented.** `progress-tap.py` imports the SAME
  `hugmesh_studio.core.progress_parse.ProgressParser` (+ `progress-tables.json`)
  that drives the Studio GUI, via `PYTHONPATH=<generator>/studio`. Percent is `null`
  (indeterminate) until the first `==> ` banner, then a monotonic, never-backwards
  `(phase_index + emerge_fraction)/phase_count` capped at 99 (100/terminal stays the
  BFF's job — the tap never calls `finalize()`).
- **Best-effort, never fatal.** Each POST is a fire-and-forget `curl --max-time`
  the read loop never waits on; at most one is in flight (a still-running one is
  skipped, lossy by design); all parse/POST errors are swallowed and the loop exits
  only at stdin EOF; if `python3`/mkfifo are unavailable the code falls back to
  today's exact `"$@" &; wait` path (and the wrapper's `|| cat` still drains+echoes
  the stream). A slow/hung/erroring endpoint degrades only the progress bar.

Payload (`ImageBuildProgressRequest`), `Content-Type: application/json`, header
`X-Internal-Token` only when the token is set (same discipline as ingest — no keys,
paths, or Vault refs, ever):

```json
{ "buildId": "…", "percent": 0, "phaseIndex": 0, "phaseCount": 17,
  "phaseLabel": "Emerge packages", "indeterminate": false }
```

`percent` is `null` and `indeterminate` is `true` before the first banner.

Guard test: `tests/build-image-progress.sh` (unset = byte-identical; verbatim
passthrough; monotonic + indeterminate-until-first-banner for x86/rpi5; hanging
endpoint stays bounded; end-to-end `forward_and_wait` FIFO drive proving no
deadlock, verbatim Job-log echo, and exit-code preservation).

## admin-bff-api companion (spec only — NOT changed here)

This repo does not change admin-bff-api. The other half has since landed on admin-bff-api `main`.

1. **Job env.** `src/main/resources/jobs/image-gen-job.yaml` sets `PROGRESS_URL` to
   `https://hugmesh-admin-bff-api.hugmesh-backend.svc.cluster.local:8443/bff/internal/image-builds/${BUILD_ID}/progress`,
   next to `INGEST_URL`. The same optional `INTERNAL_TOKEN` secretKeyRef
   (`image-gen-internal-token`, `optional: true`) serves both. Omit `PROGRESS_URL` and
   the worker is byte-identical to before.

2. **Endpoint.** `POST /bff/internal/image-builds/{id}/progress`
   (`ImageBuildIngestController.progress`). It sits
   on the same internal boundary as ingest (mTLS plus the internal token) and takes
   the `ImageBuildProgressRequest` above. `percent` must be null or 0 to 99. The
   endpoint never changes `image_build.status`. `COMPLETED`, `FAILED` and `ERROR`
   stay with the terminal ingest. It turns the frame into an SSE event with
   `done=false` on the stream the admin UI already reads
   (`GET /bff/admin/image-builds/{id}/events`). A null percent becomes `0`. The
   message reads `phase i/N: label`. An unknown or reaped build is a no-op.

Not done there, so do not rely on it: the endpoint does not compare `buildId` in
the body to `{id}`, does not store the latest frame, and does not drop a
percent that goes backwards. The worker's own monotonic parser is the only guard
against backwards percents.
