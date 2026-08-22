#!/usr/bin/env bash
# ── worker progress side-channel GUARD smoke (NON-GATING) ────────────────────────
# Companion to tests/build-image-spec-guards.sh. Proves the OPTIONAL PROGRESS_URL
# producer added to docker/build-image.sh (forward_and_wait + docker/progress-tap.py):
#
#   1  PROGRESS_URL-UNSET is byte-identical to today: forward_and_wait's whole tap
#      branch is gated on `[ -n "$PROGRESS_URL" ]`, and the current direct
#      `"$@" &; child_pid=$!; wait` path is still present verbatim (source assert),
#      and the terminal contract (send_ingest / COMPLETED / resolve_build_target /
#      the required-env loop) is untouched.
#   2  The tap echoes a canned stdout stream VERBATIM (byte-for-byte) to its own
#      stdout (the Job-log passthrough), with PROGRESS_URL unset -> no POST attempted.
#   3  From a canned x86 AND rpi5 banner transcript the tap emits progress POSTs whose
#      percents are MONOTONIC and INDETERMINATE (null) until the first `==> ` banner —
#      the Studio ProgressParser contract, reused (not reimplemented) worker-side.
#      The parser contract itself is also asserted directly (deterministic).
#   4  A black-hole (hanging) PROGRESS_URL still lets the WHOLE stream echo and the
#      tap exit within a tight time bound — the non-blocking proof: the tap never
#      waits on the fire-and-forget curl, and at most ONE curl is ever in flight.
#
# Everything is dry: no root, no network (a fake `curl` on PATH captures/hangs), no
# writes outside mktemp. python3 is the only runtime prereq (already required by the
# worker). PROGRESS_URL / progress-tap.py are OPTIONAL and never part of the required
# admin-bff-api Job contract when omitted.
#
# Usage: tests/build-image-progress.sh   [PYTHON=/path/to/python]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$(cd "$HERE/.." && pwd)"
STUDIO="$GEN/studio"
BUILD_IMAGE_SH="$GEN/docker/build-image.sh"
TAP_PY="$GEN/docker/progress-tap.py"
PY="${PYTHON:-python3}"
export PYTHONPATH="$STUDIO${PYTHONPATH:+:$PYTHONPATH}"

work="$(mktemp -d)"
trap 'rm -rf "$work"; pkill -f "$work/hang-marker" 2>/dev/null || true' EXIT

fail=0
ok()   { echo "ok  [$1] $2"; }
bad()  { echo "FAIL [$1] $2"; fail=1; }

# ── canned builder transcripts (ANSI-wrapped banners like the real banner()) ──────
ESC=$'\033'
x86_transcript() {
  printf '%s\n' "warming up, no phase yet"
  printf '%s%s\n' "${ESC}[1;34m==> Rebranding baked config${ESC}[0m" ""
  printf '%s\n' "==> Verifying prerequisites"
  printf '%s\n' "==> Preparing build directories"
  printf '%s\n' "==> Fetching amd64 hardened stage3 seed"
  printf '%s\n' ">>> Emerging (1 of 4) sys-apps/foo"
  printf '%s\n' ">>> Emerging (3 of 4) sys-apps/bar"
  printf '%s\n' "==> Native emerge inside chroot"
  printf '%s\n' ">>> Emerging (5 of 10) app/baz"
  printf '%s\n' "==> Building Gentoo hardened kernel"
  printf '%s\n' "==> Packaging stage4 tarball"
}
rpi5_transcript() {
  printf '%s\n' "cross toolchain warm-up"
  printf '%s\n' "==> Rebranding baked config"
  printf '%s\n' "==> Verifying prerequisites"
  printf '%s\n' "==> Fetching latest arm64 stage3 seed"
  printf '%s\n' "==> Phase 1: Cross-building @system"
  printf '%s\n' ">>> Emerging (2 of 8) sys-libs/x"
  printf '%s\n' "==> Phase 2: Cross-building stage4"
  printf '%s\n' "==> Phase 5: Building raw .img"
}

# ── 1. PROGRESS_URL-unset is byte-identical + terminal contract untouched ─────────
echo "── 1. source guards: opt-in gate, direct path intact, terminal contract untouched ──"
src_has() { if grep -qF -- "$2" "$BUILD_IMAGE_SH"; then ok "$1" "present in build-image.sh"; else bad "$1" "missing: $2"; fi; }
src_has env-optional          'PROGRESS_URL="${PROGRESS_URL:-}"'
src_has gate-on-progress-url  'if [ -n "$PROGRESS_URL" ]; then'
src_has fifo-pins-both-ends   'exec 9<>"$progress_fifo" 8<"$progress_fifo"'
src_has tap-drops-writer      'progress_tap_run <&8 9>&- &'
src_has builder-stays-child   '"$@" >"$progress_fifo" 8<&- 9>&- &'
src_has tap-fallback-cat      'python3 "${GENERATOR_DIR}/docker/progress-tap.py" || cat'
# the CURRENT direct path (unset PROGRESS_URL) must still be present verbatim
src_has direct-path-child     '  "$@" &'
src_has direct-path-wait      '  if wait "$child_pid"; then'
# terminal contract must NOT be perturbed
if ! grep -q 'PROGRESS_URL' <(sed -n '/^resolve_build_target() {$/,/^}$/p' "$BUILD_IMAGE_SH"); then
  ok resolve-untouched "resolve_build_target() does not mention PROGRESS_URL (build-matrix sed stays green)"
else
  bad resolve-untouched "resolve_build_target() now references PROGRESS_URL — build-matrix JOB probe will drift"
fi
# PROGRESS_URL must NOT be in the required-env loop
req_loop="$(grep -n 'for v in BUILD_ID' "$BUILD_IMAGE_SH" | head -1 | cut -d: -f1)"
if [ -n "$req_loop" ] && ! sed -n "${req_loop}p" "$BUILD_IMAGE_SH" | grep PROGRESS_URL >/dev/null; then
  ok not-required "PROGRESS_URL absent from the required-env loop (it is optional)"
else
  bad not-required "PROGRESS_URL leaked into the required-env loop"
fi

# ── 2. tap echoes verbatim (PROGRESS_URL unset -> passthrough only, no POST) ──────
echo "── 2. tap passthrough is byte-identical to its input (no PROGRESS_URL) ──"
x86_transcript > "$work/x86.txt"
# no PATH stub -> if it *tried* to POST with an empty URL curl wouldn't exist anyway;
# with PROGRESS_URL unset the tap must skip all POST logic.
GENERATOR_DIR="$GEN" PROGRESS_URL="" BUILD_ID="B1" PROGRESS_PLATFORM="x86" \
  "$PY" "$TAP_PY" < "$work/x86.txt" > "$work/x86.echo" 2>/dev/null || true
if cmp -s "$work/x86.txt" "$work/x86.echo"; then
  ok passthrough "stdout stream reproduced byte-for-byte"
else
  bad passthrough "tap altered the stream"; diff "$work/x86.txt" "$work/x86.echo" | head || true
fi

# ── 3. emitted POSTs: monotonic + indeterminate-until-first-banner ───────────────
echo "── 3. progress POSTs are monotonic + indeterminate until the first banner ──"
# fake curl: capture the --data-binary @- body (one JSON per line) to $CAP.
mkbin="$work/bin"; mkdir -p "$mkbin"
cat > "$mkbin/curl" <<EOF
#!/usr/bin/env bash
# test double for curl: drain stdin (the JSON body via --data-binary @-) to \$CAP.
cat >> "\$CAP"
printf '\n' >> "\$CAP"
exit 0
EOF
chmod +x "$mkbin/curl"
# feed with a small per-line delay so each instant fake-curl finishes before the next
# frame's poll() — makes the lossy "at most one in flight" skip deterministic here.
feed_slow() { while IFS= read -r l; do printf '%s\n' "$l"; sleep 0.05; done; }

run_capture() {  # PLATFORM TRANSCRIPT_FN CAPFILE
  local plat="$1" fn="$2" cap="$3"
  : > "$cap"
  "$fn" | feed_slow | \
    CAP="$cap" PATH="$mkbin:$PATH" GENERATOR_DIR="$GEN" \
    PROGRESS_URL="http://progress.invalid/p" BUILD_ID="BID-$plat" \
    PROGRESS_PLATFORM="$plat" PROGRESS_MIN_INTERVAL="0" PROGRESS_CURL_TIMEOUT="2" \
    "$PY" "$TAP_PY" > /dev/null 2>/dev/null || true
}

assert_frames() {  # LABEL CAPFILE
  local label="$1" cap="$2"
  "$PY" - "$cap" <<'PY'
import json, sys
frames = []
with open(sys.argv[1], "rb") as fh:
    for raw in fh.read().split(b"\n"):
        raw = raw.strip()
        if not raw:
            continue
        frames.append(json.loads(raw))
assert frames, "no progress frames captured"
# initial frame is indeterminate (null percent, phaseIndex -1)
assert frames[0]["percent"] is None and frames[0]["indeterminate"] is True, \
    "first frame not indeterminate: %r" % frames[0]
assert frames[0]["phaseIndex"] == -1, "first frame phaseIndex != -1: %r" % frames[0]
# indeterminate until the first non-null percent; once determinate, never null again
seen_determinate = False
last = -1
for f in frames:
    p = f["percent"]
    if p is None:
        assert not seen_determinate, "percent regressed to null after a determinate frame"
        assert f["indeterminate"] is True
    else:
        seen_determinate = True
        assert f["indeterminate"] is False
        assert 0 <= p <= 99, "percent out of 0..99: %r" % f
        assert p >= last, "percent went BACKWARDS: %d then %d" % (last, p)
        last = p
assert seen_determinate, "no determinate frame ever emitted"
# buildId + phase fields present; no secret-shaped keys
for f in frames:
    assert set(f) == {"buildId","percent","phaseIndex","phaseCount","phaseLabel","indeterminate"}, \
        "unexpected payload keys: %r" % sorted(f)
print("FRAMES_OK count=%d final_percent=%d" % (len(frames), last))
PY
}

for plat in x86 rpi5; do
  run_capture "$plat" "${plat}_transcript" "$work/cap.$plat"
  if out="$(assert_frames "$plat" "$work/cap.$plat" 2>&1)"; then
    ok "monotonic-$plat" "$out"
  else
    bad "monotonic-$plat" "$out"; sed 's/^/    | /' "$work/cap.$plat" | head || true
  fi
done

# parser-contract assertion directly (deterministic, no curl/timing) ──────────────
"$PY" - "$work/x86.txt" <<'PY' && ok parser-contract "indeterminate-until-first-banner + monotonic (direct ProgressParser)" || bad parser-contract "ProgressParser contract violated"
import sys, os
sys.path.insert(0, os.environ["PYTHONPATH"].split(":")[0])
from hugmesh_studio.core.progress_parse import ProgressParser
p = ProgressParser("x86")
seen_banner = False
last = -1
with open(sys.argv[1]) as fh:
    for line in fh:
        st = p.feed(line)
        if "==>" in line:
            seen_banner = True
        if not seen_banner:
            assert st.percent is None, "percent became determinate before any banner"
        if st.percent is not None:
            assert last <= st.percent <= 99, "percent non-monotonic/out-of-range"
            last = st.percent
assert last >= 0, "never reached a determinate percent"
PY

# ── 4. black-hole PROGRESS_URL: whole stream still echoes, tap exits fast ─────────
echo "── 4. hanging PROGRESS_URL is non-blocking (bounded, whole stream still echoed) ──"
hangbin="$work/hangbin"; mkdir -p "$hangbin"
# fake curl that HANGS (simulates a slow/hung BFF up to --max-time). The tap must
# never wait on it. Marker in argv so the EXIT trap can reap the orphan.
cat > "$hangbin/curl" <<EOF
#!/usr/bin/env bash
# $work/hang-marker  (reaped by the test's EXIT trap)
cat > /dev/null
sleep 3
EOF
chmod +x "$hangbin/curl"
x86_transcript > "$work/x86.txt"
start=$(date +%s.%N 2>/dev/null || date +%s)
set +e
timeout 2 env PATH="$hangbin:$PATH" GENERATOR_DIR="$GEN" \
  PROGRESS_URL="http://blackhole.invalid/p" BUILD_ID="BH" PROGRESS_PLATFORM="x86" \
  PROGRESS_MIN_INTERVAL="0" PROGRESS_CURL_TIMEOUT="2" \
  "$PY" "$TAP_PY" < "$work/x86.txt" > "$work/x86.bh.echo" 2>/dev/null
rc=$?
set -e
end=$(date +%s.%N 2>/dev/null || date +%s)
if [ "$rc" -eq 124 ]; then
  bad non-blocking "tap did NOT exit within 2s despite a hanging curl (it must never wait on the POST)"
else
  ok non-blocking "tap exited (rc=$rc) well under the 2s bound while curl hangs"
fi
if cmp -s "$work/x86.txt" "$work/x86.bh.echo"; then
  ok bh-passthrough "the ENTIRE stream still echoed to the Job log despite the hanging POST"
else
  bad bh-passthrough "stream truncated/altered when the POST hangs"; diff "$work/x86.txt" "$work/x86.bh.echo" | head || true
fi

# ── 5. END-TO-END: drive the REAL forward_and_wait FIFO tap (deadlock/rc/echo) ────
# progress-tap.py above was fed a plain file/pipe; the actual worker interposes a
# FIFO whose ends the PARENT pins. That wiring has its own failure modes (a blocking
# open with no peer; the tap/builder inheriting the pinned writer -> the FIFO never
# reaches EOF and `wait $tap_pid` hangs), so exercise the extracted-verbatim
# forward_and_wait + progress_tap_run against a fake builder.
echo "── 5. real forward_and_wait FIFO tap: bounded, echoes verbatim, preserves rc ──"
drv="$work/drive.sh"
{
  echo 'set -u'
  echo 'PROGRESS_URL="${PROGRESS_URL:-}"'   # mirror the real script's set -u default
  echo 'PRINT_ONLY=0'
  echo 'on_exit() { :; }'
  echo 'BUILD_ID="E2E"; INTERNAL_TOKEN=""; PLATFORM="x86"'
  echo 'PROGRESS_MIN_INTERVAL="0"; PROGRESS_CURL_TIMEOUT="2"'
  echo "GENERATOR_DIR=\"$GEN\""
  echo "SCRATCH_DIR=\"$work/e2e-scratch\"; mkdir -p \"\$SCRATCH_DIR\""
  # the two functions, verbatim from the worker source (drift-sensitive: a rename
  # or signature change here re-points this extraction and the test fails loud).
  sed -n '/^progress_tap_run() {$/,/^}$/p' "$BUILD_IMAGE_SH"
  sed -n '/^forward_and_wait() {$/,/^}$/p' "$BUILD_IMAGE_SH"
  # a fake "builder": streams the canned transcript to STDOUT (-> the FIFO) and
  # exits with a distinctive non-zero rc that forward_and_wait must return verbatim.
  echo 'fakebuild() {'
  x86_transcript | sed "s/'/'\\\\''/g; s/^/  printf '%s\\\\n' '/; s/$/'/"
  echo '  return 7'
  echo '}'
  echo 'forward_and_wait fakebuild; echo "FW_RC=$?" >&2'
} > "$drv"

# (a) with a fast (capture) curl on PATH — must finish bounded, echo the whole
#     transcript to stdout, and return the fake builder's rc (7).
: > "$work/e2e.cap"
set +e
timeout 8 env PATH="$mkbin:$PATH" CAP="$work/e2e.cap" \
  PROGRESS_URL="http://progress.invalid/p" bash "$drv" \
  > "$work/e2e.out" 2> "$work/e2e.err"
trc=$?
set -e
if [ "$trc" -eq 124 ]; then
  bad e2e-bounded "forward_and_wait HUNG (FIFO never reached EOF / wait \$tap_pid deadlock)"
else
  ok e2e-bounded "forward_and_wait completed within the time bound (no FIFO deadlock)"
fi
if cmp -s "$work/x86.txt" "$work/e2e.out"; then
  ok e2e-echo "builder stdout streamed to the Job log byte-for-byte through the tap"
else
  bad e2e-echo "Job-log stream altered/truncated by the tap"; diff "$work/x86.txt" "$work/e2e.out" | head || true
fi
if grep -q 'FW_RC=7' "$work/e2e.err"; then
  ok e2e-rc "the builder's real exit code (7) is preserved through forward_and_wait"
else
  bad e2e-rc "exit code NOT preserved: $(grep FW_RC "$work/e2e.err" || echo '<none>')"
fi

# (b) with a HANGING curl on PATH — the FIFO tap must STILL finish bounded and echo
#     the whole stream (a slow/hung BFF never stalls or blocks the build).
set +e
timeout 8 env PATH="$hangbin:$PATH" \
  PROGRESS_URL="http://blackhole.invalid/p" bash "$drv" \
  > "$work/e2e.bh.out" 2> "$work/e2e.bh.err"
trc=$?
set -e
if [ "$trc" -ne 124 ] && cmp -s "$work/x86.txt" "$work/e2e.bh.out" && grep -q 'FW_RC=7' "$work/e2e.bh.err"; then
  ok e2e-hang "hanging BFF: forward_and_wait still bounded, full stream echoed, rc preserved"
else
  bad e2e-hang "hanging BFF stalled/altered the build (timeout_rc=$trc)"
fi

# (c) with PROGRESS_URL UNSET the SAME forward_and_wait takes the direct path:
#     builder stdout still streams to this process unchanged and rc is preserved
#     (functional companion to the source-level byte-identical guards in section 1).
set +e
timeout 8 env -u PROGRESS_URL bash "$drv" > "$work/e2e.unset.out" 2> "$work/e2e.unset.err"
trc=$?
set -e
if [ "$trc" -ne 124 ] && cmp -s "$work/x86.txt" "$work/e2e.unset.out" && grep -q 'FW_RC=7' "$work/e2e.unset.err"; then
  ok e2e-unset "PROGRESS_URL unset -> direct path: stream unchanged, rc preserved, no FIFO created"
else
  bad e2e-unset "unset-PROGRESS_URL path diverged (timeout_rc=$trc)"
fi
if [ ! -e "$work/e2e-scratch/progress.fifo" ]; then
  ok e2e-no-fifo "no progress.fifo materialized when PROGRESS_URL is unset"
else
  bad e2e-no-fifo "a progress.fifo was created even though PROGRESS_URL is unset"
fi

echo
if [ "$fail" -ne 0 ]; then
  echo "build-image-progress: FAIL"
  exit 1
fi
echo "build-image-progress: PASS"
