#!/usr/bin/env bash
# Mutation battery for loop_preflight_test.sh. BREAKS PRODUCTION, runs the
# suite, and demands RED. A guard nobody has broken on purpose is a guard nobody
# has tested. Every mutation is verified to have ACTUALLY changed the file — a
# sed that silently matched nothing would otherwise "survive" and look like
# coverage. Not wired into CI: it edits tracked files and restores them.
#
#   bash tests/qemu/loop_preflight_mutations.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="${HERE}/run-qemu-docker.sh"
SUITE="${HERE}/loop_preflight_test.sh"
BAK="$(mktemp)"; cp "${RUNNER}" "${BAK}"
restore() { cp "${BAK}" "${RUNNER}"; }
trap 'restore; rm -f "${BAK}"' EXIT

SURVIVED=0; CAUGHT=0
mutate() { # mutate NAME PYTHON_OLD PYTHON_NEW
    local name old new
    name="$1"; old="$2"; new="$3"
    restore
    OLD="${old}" NEW="${new}" python3 - "${RUNNER}" <<'PY' || { printf '  ERROR %s: mutation did not apply\n' "${name}"; SURVIVED=$((SURVIVED+1)); return; }
import os, sys
p = sys.argv[1]; s = open(p, encoding='utf-8').read()
old, new = os.environ['OLD'], os.environ['NEW']
if s.count(old) != 1:
    sys.exit(1)
open(p, 'w', encoding='utf-8').write(s.replace(old, new))
PY
    # The file must actually differ, or "survived" would mean "never broken".
    if cmp -s "${RUNNER}" "${BAK}"; then
        printf '  ERROR %s: file unchanged after mutation\n' "${name}"; SURVIVED=$((SURVIVED+1)); return
    fi
    if bash "${SUITE}" >/dev/null 2>&1; then
        printf '  SURVIVED %s  <-- the suite passed on broken production\n' "${name}"
        SURVIVED=$((SURVIVED+1))
    else
        printf '  caught   %s\n' "${name}"
        CAUGHT=$((CAUGHT+1))
    fi
}

echo "mutation battery — break production, demand RED"

# ── the reviewer's two mutations, the reason this file grew ──────────────────
mutate 'R1 partition nodes counted as devices (revert the case-filter)' \
  '        case "${f##*/}" in loop*[!0-9]*) continue ;; esac' \
  '        :'
mutate 'R2 -v /dev:/dev -> -v /dev:/dev-host (nodes land where the container cannot open them)' \
  '--rm --privileged -v /dev:/dev --entrypoint' \
  '--rm --privileged -v /dev:/dev-host --entrypoint'
mutate 'R3 --privileged -> --privileged=false-not-really (substring grep sails past it)' \
  'docker run --rm --privileged -v /dev:/dev' \
  'docker run --rm --privileged=false-not-really -v /dev:/dev'
mutate 'R4 preflight container loses --rm (a leaked container per short-count run)' \
  'docker run --rm --privileged -v /dev:/dev' \
  'docker run --privileged -v /dev:/dev'
mutate 'R5 the case-filter over-rejects, dropping loop10' \
  'in loop*[!0-9]*) continue' \
  'in loop*[!0-9]*|loop[0-9][0-9]*) continue'

# ── the original battery, re-run against the rewritten assertions ────────────
mutate 'M1 -v /dev:/dev deleted outright' \
  '--rm --privileged -v /dev:/dev --entrypoint' \
  '--rm --privileged --entrypoint'
mutate 'M2 attach/detach interleaved (one node, not N)' \
  '                held="${held} ${d}"' \
  '                losetup -d "${d}" 2>/dev/null || true'
mutate 'M3 believe docker rc over the host node count' \
  '    have="$(loop_node_count)"
    if [ "${have}" -ge "${want}" ]; then
        info "loop preflight: ${have} loop node(s) now visible on the host devtmpfs"' \
  '    have="$(loop_node_count)"
    if [ "${rc}" -eq 0 ]; then
        info "loop preflight: ${have} loop node(s) now visible on the host devtmpfs"'
mutate 'M4 --jobs 0 re-serialized (the bare running>=JOBS gate)' \
  '        if [ "${JOBS}" -gt 0 ] && [ "${running}" -ge "${JOBS}" ]; then' \
  '        if [ "${running}" -ge "${JOBS}" ]; then'
mutate 'M5 the preflight call site removed from the top level' \
  '
ensure_loop_devices "${#ROWS[@]}"' \
  '
: ensure_loop_devices_disabled'
mutate 'M6 run_row loses --privileged (losetup -P dies inside the row)' \
  '    docker run --rm --privileged "${KVM_ARGS[@]}"' \
  '    docker run --rm "${KVM_ARGS[@]}"'
mutate 'M7 run_row loses --rm (a stopped container leaked per row)' \
  '    docker run --rm --privileged "${KVM_ARGS[@]}"' \
  '    docker run --privileged "${KVM_ARGS[@]}"'

restore
printf 'battery: %d caught, %d survived\n' "${CAUGHT}" "${SURVIVED}"
# A clean tree must still be GREEN, or "caught" would just mean "always red".
bash "${SUITE}" >/dev/null 2>&1 \
    && echo 'positive control: the restored tree is GREEN' \
    || { echo 'positive control FAILED: restored tree is red'; exit 1; }
[ "${SURVIVED}" -eq 0 ] || exit 1
