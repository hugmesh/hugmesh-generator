#!/usr/bin/env bash
# ── worklist parity smoke (NON-GATING) ───────────────────────────────────────────
# The redesign's core invariant, exercised end-to-end through the REAL headless CLI:
#
#   `--print-commands` over a worklist ENVELOPE must print, for each materialized
#   image, exactly the command `--print-command` prints for the equivalent flat
#   single-image config (the config materialize() produced, saved back out).
#
# Deliberately NOT wired into tests/build-matrix/check.sh — it is a developer smoke,
# promoted into the gating matrix only once stable (design 6). WS-BUILDER owns check.sh.
#
# Usage: tests/build-matrix/worklist-smoke.sh
#   PYTHON=... to override the interpreter (default: python3).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$(cd "$HERE/../.." && pwd)"
STUDIO="$GEN/studio"
PY="${PYTHON:-python3}"
export PYTHONPATH="$STUDIO${PYTHONPATH:+:$PYTHONPATH}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# 1. Build a multi-image envelope and, alongside it, save each MATERIALIZED image as a
#    flat config — the exact single-image configs a user could build by hand.
"$PY" - "$work" <<'PYEOF'
import sys
from hugmesh_studio.core.config import Domain, ImageConfig, User
from hugmesh_studio.core.worklist import WorklistConfig, WorklistEntry

work = sys.argv[1]
base = ImageConfig(mode="mesh", role="omnibus", platform="x86", brand="acme",
                   brand_title="Acme", org="Acme-Inc", cluster_domain="acme.example",
                   superdomain="core.acme.internal", encrypt_root=True)
base.domains = [Domain(name="acme.example", title="Acme"),
                Domain(name="team.acme.example", title="Team", images=["be.rpi5"])]
base.users = [User(username="root-admin", domain="core.acme.internal", role="superadmin")]
wl = WorklistConfig(base=base, entries=[
    WorklistEntry(role="omnibus", platform="x86"),
    WorklistEntry(role="be", platform="rpi5", board="rpi5", packages_add="app-misc/tmux"),
    WorklistEntry(role="edge_ai", platform="jetson", encrypt_root="on"),
])
wl.save(f"{work}/envelope.json")
for i, (_entry, cfg) in enumerate(wl.materialize()):
    cfg.save(f"{work}/flat-{i}.json")
print(len(wl.entries))
PYEOF

# 2. Collect the envelope's per-image commands and diff each against the flat config's.
mapfile -t multi < <("$PY" -m hugmesh_studio --print-commands \
    --config "$work/envelope.json" --generator-dir "$GEN" --backend native)

fail=0
i=0
for flat in "$work"/flat-*.json; do
    one="$("$PY" -m hugmesh_studio --print-command \
        --config "$flat" --generator-dir "$GEN" --backend native)"
    if [[ "${multi[$i]:-<missing>}" != "$one" ]]; then
        echo "MISMATCH image $i"
        echo "  envelope: ${multi[$i]:-<missing>}"
        echo "  flat:     $one"
        fail=1
    else
        echo "ok image $i: ${multi[$i]}"
    fi
    i=$((i + 1))
done

if [[ "${#multi[@]}" -ne "$i" ]]; then
    echo "COUNT MISMATCH: --print-commands emitted ${#multi[@]} line(s), expected $i"
    fail=1
fi

# 3. --image <n> must isolate a single materialized image.
single="$("$PY" -m hugmesh_studio --print-commands --image 1 \
    --config "$work/envelope.json" --generator-dir "$GEN" --backend native)"
if [[ "$single" != "${multi[1]}" ]]; then
    echo "MISMATCH --image 1"
    echo "  --image 1: $single"
    echo "  expected:  ${multi[1]}"
    fail=1
fi

if [[ "$fail" -ne 0 ]]; then
    echo "worklist-smoke: FAIL"
    exit 1
fi
echo "worklist-smoke: PASS ($i image(s))"
