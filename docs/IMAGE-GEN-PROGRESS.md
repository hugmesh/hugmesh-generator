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

A sibling session owns admin-bff-api; apply there:

1. **Job env** (`jobs/image-gen-job.yaml`, `ImageBuildOrchestrator`) — add ONE var,
   templated per-build the same way `INGEST_URL`/`IMAGE_SPEC_JSON` already are:

   ```yaml
   - name: PROGRESS_URL
     value: "<same scheme+host as INGEST_URL>/bff/internal/image-builds/{BUILD_ID}/progress"
   ```

   Built from the identical internal base the orchestrator renders `INGEST_URL`
   from, with `image_build.id` substituted into the path. Reuse the SAME optional
   `INTERNAL_TOKEN` secretKeyRef (`optional: true`) already mounted for ingest — no
   new secret. Setting `PROGRESS_URL` is what turns the producer on; omit it and the
   worker is byte-identical to today.

2. **Endpoint** `POST /bff/internal/image-builds/{id}/progress` (the non-terminal
   endpoint added in admin-bff-api #206). Accept the `ImageBuildProgressRequest`
   above; header `X-Internal-Token` when present (mTLS is the primary boundary, token
   absence is not fatal — mirrors ingest). Validate `buildId == {id}`; treat as
   **non-terminal** (never mutate `image_build.status` — `COMPLETED`/`FAILED`/`ERROR`
   remain owned by the terminal ingest); store latest and, as defense-in-depth,
   ignore any backwards/non-monotonic percent; then re-emit on the SSE stream the
   admin UI already consumes (`GET /bff/admin/image-builds/{id}/events`) so the web
   progress bar advances through the real phase percents. 2xx quickly and cheaply —
   worker-side it is best-effort and bounded by `curl --max-time`, so a slow or
   erroring endpoint degrades only the progress bar, never the build.
