#!/usr/bin/env bash
# ── headless-node installer-UI guard (ROOT-CAUSE twin of test-calamares-boost-seed.sh) ──
# build-x86-host-stage4.sh already refuses a graphical installer on a non-standalone
# role: :1244 defaults an UNSET ${INSTALLER_UI} to `all` for --standalone and `cli`
# otherwise, and :1246 flips WANT_CALAMARES true only for `calamares`/`all`, which at
# :3532 appends app-admin/calamares to PKGS.
#
# The Studio DISABLED that rule: `installer_ui: str = "all"` is a flat dataclass default,
# so config.py's to_cli_args ALWAYS passed an explicit value and the `[ -z ... ]` guard at
# :1244 could never fire. Every headless node therefore requested calamares — whose USE
# closure (specs-x86/portage/package.use/desktop) the package.use copy loop copies ONLY
# for ROLE_CLIENT roles (:2496). On a node calamares is not merely expensive, it is
# UNSATISFIABLE: 5 x86 node images died on boost[python] (fixed by #380's seed) and 5 more
# on the NEXT atom in the same closure, libpwquality[python], ~16min each (real failures,
# sessions 20260716-160638-f8c153 and 20260716-235722-54d2f7).
#
# #380 guards the SEED (one atom rescued into a role-independent package.use file). THIS
# guards the ROOT CAUSE: a node config must never emit an installer-ui that sets
# WANT_CALAMARES. Both are needed — the seed guard alone cannot stop the next atom.
#
# Anti-rot / anti-hole rules this script follows:
#   * the trigger set is EXTRACTED from the builder's LIVE :1246 line (^-anchored), so a
#     new triggering value added upstream makes this guard BITE instead of silently rot;
#   * emitted argv is parsed with a REAL argv parser (shlex) and the flag's VALUE indexed
#     — never `grep -qF -- '--installer-ui cli'`, which would happily match a comment, a
#     longer flag, or the wrong occurrence (the exact hole found in #380's log guard).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$(cd "${HERE}/../.." && pwd)"
PYTHON="${PYTHON:-python3}"
X86="${GEN}/build-x86-host-stage4.sh"
P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

echo "== installer-ui node default guard =="

# 1. Extract the WANT_CALAMARES trigger set from the LIVE builder line. ^-anchored to the
#    real assignment, so a commented-out copy can never satisfy it.
CAL_LINE="$(grep -nE '^WANT_CALAMARES=false; \{ \[ "\$\{INSTALLER_UI\}" = ' "${X86}" || true)"
if [ -n "${CAL_LINE}" ]; then
    ok "builder WANT_CALAMARES line found live (${CAL_LINE%%:*})"
else
    bad "builder WANT_CALAMARES line not found (anchors moved? guard is blind — fix it)"
    echo "== installer-ui-node-default: ${P} passed, ${F} failed =="; exit 1
fi
# every  = <value> ]  comparison on that line == a value that pulls app-admin/calamares
TRIGGERS="$(printf '%s' "${CAL_LINE#*:}" |
            grep -oE '= [a-z]+ \]' | awk '{print $2}' | sort -u | tr '\n' ' ')"
TRIGGERS="${TRIGGERS% }"
if [ -n "${TRIGGERS}" ]; then
    ok "WANT_CALAMARES triggers extracted from the builder: ${TRIGGERS}"
else
    bad "could not extract the trigger set from the live line"
fi

# 2. The builder's own non-standalone default must still be the CLI installer (:1244) —
#    the rule this guard enforces Studio-side is the builder's, not an invention.
if grep -qE '^\[ -z "\$\{INSTALLER_UI\}" \] && \{ \$\{STANDALONE\} && INSTALLER_UI=all \|\| INSTALLER_UI=cli; \}' "${X86}"; then
    ok "builder still defaults a non-standalone role to INSTALLER_UI=cli (:1244)"
else
    bad "builder's INSTALLER_UI default line changed — re-derive the Studio rule"
fi

# 3. The desktop USE closure is still ROLE_CLIENT-gated — the reason a node CANNOT build
#    calamares. If this gate ever goes away the rule's rationale changes.
if sed -n '/^for puf in "\${SPECS_DIR}\/portage\/package\.use\/"\*/,/^done$/p' "${X86}" |
       grep -qE '^\s*desktop\) \$\{ROLE_CLIENT\} \|\| continue ;;'; then
    ok "package.use/desktop is still gated on ROLE_CLIENT (a node cannot resolve calamares)"
else
    bad "the ROLE_CLIENT gate on package.use/desktop moved — recheck the node rule"
fi

# 4. THE LOAD-BEARING LEG: every x86 node role, fed each triggering value, must emit an
#    installer-ui OUTSIDE the trigger set. Plus the client no-regression leg.
OUT="$("${PYTHON}" - "${GEN}" "${TRIGGERS}" <<'PYEOF'
import json, os, shlex, subprocess, sys, tempfile

gen, triggers = sys.argv[1], sys.argv[2].split()
studio = os.path.join(gen, "studio")
env = dict(os.environ, PYTHONPATH=studio)
NODE_ROLES = ["pki", "be", "fe", "be+gpu", "omnibus", "edge_ai"]
fails = []

def emitted(cfg, tmp, name):
    p = os.path.join(tmp, name + ".json")
    with open(p, "w") as fh:
        json.dump(cfg, fh)
    r = subprocess.run([sys.executable, "-m", "hugmesh_studio", "--print-command",
                        "--config", p, "--generator-dir", gen, "--backend", "native"],
                       capture_output=True, text=True, timeout=120, env=env, cwd=studio)
    if r.returncode != 0:
        return None, f"--print-command failed for {name}: {r.stderr.strip()[:200]}"
    # REAL argv parse — index the flag's VALUE. Never a substring grep.
    argv = shlex.split(r.stdout)
    if "--installer-ui" not in argv:
        return "", None          # no flag: WANT_CALAMARES stays false (builder default)
    return argv[argv.index("--installer-ui") + 1], None

with tempfile.TemporaryDirectory() as tmp:
    for role in NODE_ROLES:
        for bad_val in triggers:
            cfg = {"mode": "mesh", "role": role, "platform": "x86", "installer_ui": bad_val}
            val, err = emitted(cfg, tmp, f"node-{role}-{bad_val}".replace("+", "p"))
            if err:
                fails.append(err); continue
            if val in triggers:
                fails.append(f"node {role} fed installer_ui={bad_val!r} EMITTED {val!r} "
                             f"-> WANT_CALAMARES true -> unsatisfiable app-admin/calamares")
    # no-regression: a desktop-class role keeps its graphical installer
    for mode, role in (("cloud", "laptop"), ("standalone", "standalone-thick")):
        cfg = {"mode": mode, "role": role, "platform": "x86", "installer_ui": "all"}
        val, err = emitted(cfg, tmp, f"desktop-{role}")
        if err:
            fails.append(err); continue
        if val != "all":
            fails.append(f"REGRESSION: {mode}/{role} emitted installer-ui {val!r}, want 'all' "
                         f"(a desktop legitimately wants and CAN build calamares)")

print("\n".join(fails) if fails else "CLEAN")
PYEOF
)"
if [ "${OUT}" = "CLEAN" ]; then
    ok "no x86 node role can emit a WANT_CALAMARES installer-ui; desktops keep 'all'"
else
    bad "installer-ui node/desktop emission wrong:"
    printf '    %s\n' "${OUT}"
fi

# 5. Drift guard: the Studio's mirrored trigger tuple must equal the builder's live set.
DRIFT="$(cd "${GEN}/studio" && PYTHONPATH=. "${PYTHON}" - "${TRIGGERS}" <<'PYEOF'
import sys
from hugmesh_studio.core.config import _CALAMARES_INSTALLER_UI
want = set(sys.argv[1].split())
got = set(_CALAMARES_INSTALLER_UI)
print("CLEAN" if got == want else f"studio mirrors {sorted(got)} but builder says {sorted(want)}")
PYEOF
)"
if [ "${DRIFT}" = "CLEAN" ]; then
    ok "studio's _CALAMARES_INSTALLER_UI matches the builder's live trigger set"
else
    bad "${DRIFT}"
fi

echo "== installer-ui-node-default: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
