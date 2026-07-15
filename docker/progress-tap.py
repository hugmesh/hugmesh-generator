#!/usr/bin/env python3
"""build-image.sh's OPTIONAL stdout progress tap — see docker/build-image.sh's
forward_and_wait / progress_tap_run.

Reads the builder's stdout on stdin, re-emits every line VERBATIM to this process's
stdout (the k8s Job log, byte-for-byte and in order) and, as a best-effort NON-TERMINAL
side channel, POSTs throttled phase->percent frames to PROGRESS_URL. It REUSES the exact
Studio parser (snapdragon_studio.core.progress_parse.ProgressParser) that already loads
progress-tables.json and drives the Studio GUI (gui/pages/progress.py) — no regex or
phase table is copied worker-side. PYTHONPATH=<generator>/studio is set by the wrapper
so the import below resolves; the sys.path insert is a belt-and-braces fallback.

THREE independent guarantees that a slow / failing / hanging progress POST can never
fail, slow, or block the build:

  1. Each POST is a fire-and-forget `curl --max-time` subprocess we NEVER wait on in the
     read loop. At most one curl is kept in flight: a still-running previous one causes
     the new frame to be skipped (lossy by design), so a hung/slow BFF (curl blocked up
     to --max-time) can neither pile up processes nor stall parsing.
  2. The read loop swallows every parse/POST exception and exits ONLY at stdin EOF (the
     builder closed stdout). It never stops draining stdin, so the builder's writes never
     back-pressure, and it never raises out.
  3. It NEVER calls parser.finalize() — the terminal COMPLETED/FAILED state stays owned
     by the BFF's send_ingest, so this channel is strictly non-terminal (matches #206).

Env (all set by the shell wrapper): PROGRESS_URL, BUILD_ID, INTERNAL_TOKEN (optional),
PROGRESS_PLATFORM (=$PLATFORM), PROGRESS_MIN_INTERVAL (sec), PROGRESS_CURL_TIMEOUT (sec).
The payload carries only buildId + phase integers/label — never a key, path, or Vault
ref; INTERNAL_TOKEN rides the X-Internal-Token header only when set (same discipline as
the ingest side channel).
"""
import json
import os
import subprocess
import sys
import time

# PYTHONPATH is normally set to <generator>/studio by the wrapper; add it here too so a
# direct `python3 progress-tap.py` (e.g. from the guard test) still resolves the import.
_GEN_DIR = os.environ.get("GENERATOR_DIR", "")
if _GEN_DIR:
    sys.path.insert(0, os.path.join(_GEN_DIR, "studio"))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "studio"))

from snapdragon_studio.core.progress_parse import ProgressParser  # noqa: E402


def _num_env(name, default):
    try:
        val = float(os.environ.get(name, "") or default)
        return val if val >= 0 else default
    except (TypeError, ValueError):
        return default


def _frame(build_id, st):
    """The ImageBuildProgressRequest body: percent is null while indeterminate."""
    return {
        "buildId": build_id,
        "percent": st.percent,               # None (null) until the first `==> ` banner
        "phaseIndex": st.phase_index,
        "phaseCount": st.phase_count,
        "phaseLabel": st.phase_label,
        "indeterminate": st.percent is None,
    }


def _post(url, token, curl_timeout, prev, body):
    """Fire-and-forget one bounded curl; return the (possibly unchanged) in-flight handle.

    Never waited on. If a previous POST is still running, skip (keep its handle) so at
    most one curl is ever in flight. Any error is swallowed — a progress POST must never
    disturb the build."""
    proc = None
    try:
        if prev is not None and prev.poll() is None:
            return prev                       # previous still running -> skip this frame
        args = ["curl", "-sS", "-o", "/dev/null", "--max-time", str(curl_timeout),
                "-X", "POST", "-H", "Content-Type: application/json"]
        if token:
            args += ["-H", "X-Internal-Token: " + token]
        args += ["--data-binary", "@-", url]
        proc = subprocess.Popen(
            args, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, start_new_session=True)
        proc.stdin.write(json.dumps(body).encode("utf-8"))
        proc.stdin.close()
        return proc
    except Exception:
        # If curl was already spawned but writing its body failed (e.g. it exited early on
        # a garbage URL and closed stdin -> BrokenPipe), return the NEW handle so the next
        # call polls/reaps it instead of leaking a defunct; otherwise keep the prior one.
        return proc if proc is not None else prev


def main():
    url = os.environ.get("PROGRESS_URL", "")
    build_id = os.environ.get("BUILD_ID", "")
    token = os.environ.get("INTERNAL_TOKEN", "")
    platform = os.environ.get("PROGRESS_PLATFORM", "") or "x86"
    min_interval = _num_env("PROGRESS_MIN_INTERVAL", 1.0)
    curl_timeout = _num_env("PROGRESS_CURL_TIMEOUT", 2.0)

    out = sys.stdout.buffer
    src = sys.stdin.buffer

    parser = ProgressParser(platform)
    inflight = None
    last_sent_phase = -2          # < the initial frame's phaseIndex (-1) so it always fires
    last_sent_percent = -1
    last_send_time = 0.0

    # ONE initial indeterminate frame (percent=None, phaseIndex=-1) so the UI leaves the
    # orchestrator's frozen initial frame immediately, before any banner arrives.
    if url:
        try:
            st0 = parser.state()
            inflight = _post(url, token, curl_timeout, inflight, _frame(build_id, st0))
            last_sent_phase = st0.phase_index
            last_send_time = time.monotonic()
        except Exception:
            pass

    while True:
        line = src.readline()
        if not line:
            break                 # stdin EOF: builder closed stdout (loop exits ONLY here)

        # 1) Job-log passthrough FIRST — raw bytes, unchanged, in order.
        try:
            out.write(line)
            out.flush()
        except Exception:
            pass

        # 2) parse + best-effort throttled POST — never raises out of the loop.
        if not url:
            continue
        try:
            text = line.decode("utf-8", errors="replace")
            st = parser.feed(text)
            now = time.monotonic()
            # Send on EITHER a phase advance OR a monotonic percent bump past the throttle.
            # The module's percent is already non-decreasing, so "percent > last_sent"
            # alone keeps the wire monotonic; equal/older frames are dropped, not resent.
            phase_advanced = st.phase_index > last_sent_phase
            percent_progressed = (
                st.percent is not None
                and st.percent > last_sent_percent
                and (now - last_send_time) >= min_interval)
            if phase_advanced or percent_progressed:
                inflight = _post(url, token, curl_timeout, inflight, _frame(build_id, st))
                last_sent_phase = st.phase_index
                if st.percent is not None:
                    last_sent_percent = st.percent
                last_send_time = now
        except Exception:
            pass


if __name__ == "__main__":
    main()
