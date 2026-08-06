#!/usr/bin/env bash
# test-bake-coverage.sh — the NODE-STORAGE agent must actually be BAKED into every
# image and actually be ENABLED at first boot. Unprivileged, no builds, no root,
# no docker, no cluster: bash + jq + python3 + coreutils.
#
# WHAT THIS REPLACES, AND WHY.
# The agent (PR6) first shipped in specs/ only and was baked into ZERO images: an
# operator could register a storage pool in the UI and no node would ever reconcile it.
# #525 pasted the bake into all ten builders and added a guard — but that guard was a
# TEXT-PRESENCE GREP, and four different instances of the exact regression it exists to
# catch all left it 21/21 green:
#
#   (a) BAKE DISABLED   — comment the cp lines out. `grep -q '…/hugmesh-node-storage-
#       reconcile"'` matches a commented line exactly as well as a live one.
#   (b) BAKE UNREACHABLE— wrap the block in a branch that never runs for a mesh node.
#       Text is unmoved; the image ships without the agent.
#   (c) BAKE MIS-TARGETED — change the DESTINATION. Every grep pattern also matches the
#       SOURCE argument of the same cp, so `cp "${SPECS}/usr/sbin/X" "${SYSROOT}/opt/X"`
#       stays green while /usr/sbin/X never exists in the image.
#   (d) ENABLE DEAD     — the rc-update / cron-install never reached. `grep -Eq
#       '^[[:space:]]+provision_node_storage'` is satisfied by ANY indented occurrence,
#       including one inside a function nothing calls or a branch nothing takes.
#
# So this guard asserts REACHABILITY and EFFECT instead of presence:
#
#   [bake-effect]      source scripts/_node-storage-bake-lib.sh and RUN bake_node_storage
#                      against a sandbox sysroot; the four files must exist AT THOSE PATHS
#                      with those modes and byte-identical content. (a) and (c) die here.
#   [bake-reachable]   every build-*-stage4.sh must source the lib and call it, and the
#                      call's enclosing branch chain — taken from BASH'S OWN PARSER via
#                      `declare -f`, so comments cannot lie and indentation cannot lie —
#                      must EVALUATE TRUE for a mesh node. (b) dies here. Fail-closed: a
#                      gate this guard does not recognise is a FAILURE, not a pass.
#   [enable-effect]    run the REAL provision.sh first-boot flow against that sandbox
#                      sysroot and require the boot oneshot to have been rc-update'd and
#                      the cron drop-in to have LANDED in /etc/cron.d. (d) dies here, and
#                      so does any rename on either side of the staged-cron contract —
#                      the bake writes it and provision.sh reads it back in one run.
#   [degrade]          the same flow against an UNBAKED sysroot must warn and complete:
#                      a stale image never reconciles pools, but it must never brick.
#
# Every check carries NEGATIVE CONTROLS: the whole checker is re-run against staged
# copies carrying one injected defect of each class, and each MUST go red. A guard that
# cannot be shown failing is not a guard.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/node-storage/provision-sandbox.sh
source "${HERE}/provision-sandbox.sh"

for t in bash jq python3; do
    command -v "${t}" >/dev/null 2>&1 || {
        echo "FATAL: ${t} required (refusing to skip — a skipping gate never guards)" >&2; exit 2; }
done

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}" 2>/dev/null' EXIT

# ── The MESH-NODE profile ──────────────────────────────────────────────────────
# The role toggles a builder may legitimately gate the bake on, with the value they
# take on an image that JOINS THE MESH — i.e. every image that can host a pool. The
# only one in the tree today is build-x86-host-stage4.sh's UNAFFILIATED (a standalone
# personal workstation has no mesh at all, so it correctly gets no agent), plus
# provision.sh main()'s STANDALONE_IMG twin. Any OTHER gate is unrecognised and fails:
# adding one must be a deliberate edit here, not a silent narrowing of the fleet.
declare -A MESH_PROFILE=( [UNAFFILIATED]=false [STANDALONE_IMG]=false )

# ── Structural helpers: let BASH parse the shell, never a regex ────────────────
# pp_dump <script> <out> — pretty-print a whole script through bash's own parser by
# defining it as a function body and dumping it with `declare -f`. Comments are gone
# (a commented-out call cannot masquerade as a call), string literals are canonical,
# and indentation is bash's, so nesting depth is the REAL nesting depth.
pp_dump() {
    local src="$1" out="$2" wrap="${WORK}/wrap.$$.sh"
    { printf '__pp_subject() {\n'; cat "${src}"; printf '\n}\n'; } > "${wrap}" || return 1
    bash -c 'source "$1" >/dev/null 2>&1; declare -f __pp_subject' _ "${wrap}" > "${out}" 2>/dev/null
    [ -s "${out}" ]
}

# pp_lineno <pp-file> <needle> — line number of the single line containing <needle>.
# Fails unless there is EXACTLY one.
pp_lineno() {
    local hits; hits="$(grep -n -- "$2" "$1" | cut -d: -f1)"
    [ "$(printf '%s\n' "${hits}" | grep -c .)" = "1" ] || return 1
    printf '%s' "${hits}"
}

# pp_gate_chain <pp-file> <lineno> — the chain of enclosing block headers, innermost
# first, one per line. Stops at the enclosing function definition, reported as
# `FUNCTION:<name>`; the outermost is always the __pp_subject wrapper = file top level.
#
# Three kinds of line are NOT structure and are skipped: blank lines (no indentation to
# read), HERE-DOCUMENT BODIES (bash reproduces them verbatim, so a column-0 line of YAML
# or python inside one would read as a top-level block header), and CONTINUATION LINES
# OF MULTI-LINE STRING LITERALS — `case "$v" in *'<newline>'*)` really does print its
# pattern across two lines, the second starting at column 0.
pp_gate_chain() {
    awk -v T="$2" '
        # quote state after scanning s, starting in state q (0 none, 1 \047, 2 ")
        function scanq(s, q,   i, c, n) {
            n = length(s)
            for (i = 1; i <= n; i++) {
                c = substr(s, i, 1)
                if (q == 0)      { if (c == "\\") i++; else if (c == "\047") q = 1; else if (c == "\"") q = 2 }
                else if (q == 1) { if (c == "\047") q = 0 }
                else             { if (c == "\\") i++; else if (c == "\"") q = 0 }
            }
            return q
        }
        {
            line[NR] = $0
            if (inhd) {
                hd[NR] = 1
                l = $0; gsub(/^[ \t]+|[ \t]+$/, "", l)
                if (l == term) inhd = 0
                next
            }
            if (q != 0) { hd[NR] = 1; q = scanq($0, q); next }
            if (match($0, /<<-?[ \t]*[\047"]?[A-Za-z_][A-Za-z0-9_]*[\047"]?/)) {
                s = substr($0, RSTART, RLENGTH)
                sub(/^<<-?[ \t]*/, "", s); gsub(/[\047"]/, "", s)
                term = s; inhd = 1
                next
            }
            q = scanq($0, 0)
        }
        END {
            cur = match(line[T], /[^ ]/) - 1
            for (i = T - 1; i >= 1; i--) {
                if (hd[i]) continue
                if (line[i] ~ /^[ \t]*$/) continue
                ind = match(line[i], /[^ ]/) - 1
                if (ind >= cur) continue
                l = line[i]; sub(/^ +/, "", l); sub(/ +$/, "", l)
                if (l == "{") {                       # a function body opener
                    d = line[i-1]; sub(/^ +/, "", d); sub(/ +$/, "", d)
                    sub(/^function +/, "", d); sub(/ *\(\).*$/, "", d)
                    print "FUNCTION:" d
                    exit
                }
                print l
                cur = ind
                if (cur <= 0) exit
            }
        }' "$1"
}

# gate_reached <header line> — is this enclosing header taken on a mesh node?
# ONLY a pure boolean role-variable test is accepted (`if ${V}; then`, `if ! ${V}; then`
# and &&/|| combinations of those). Anything else — an else/elif arm, a loop, a `case`,
# a file test, a command — is UNRECOGNISED and returns 2, which the caller treats as a
# failure. That is the fail-closed half: a novel gate turns this red until someone
# teaches MESH_PROFILE about it deliberately.
gate_reached() {
    local h="$1" cond v tok scan assigns="" k
    case "${h}" in
        "if "*"; then") cond="${h#if }"; cond="${cond%; then}" ;;
        *) return 2 ;;
    esac
    scan="${cond}"
    scan="${scan//\!/ }"; scan="${scan//&&/ }"; scan="${scan//||/ }"
    for tok in ${scan}; do
        case "${tok}" in
            '${'*'}') v="${tok#\$\{}"; v="${v%\}}" ;;
            *) return 2 ;;
        esac
        [ -n "${MESH_PROFILE[${v}]+set}" ] || return 2
    done
    for k in "${!MESH_PROFILE[@]}"; do assigns="${assigns}${k}=${MESH_PROFILE[$k]}; "; done
    ( set -u; eval "${assigns}"; eval "if ${cond}; then exit 0; else exit 1; fi" ) 2>/dev/null
}

# ── The checker ───────────────────────────────────────────────────────────────
# The bake contract, as (spec-source | sysroot-destination | mode) triples. This list is
# the ONE place the expected layout is written down; the lib is asserted against it by
# running it, never by reading it.
SPEC_SRC=(
    "usr/sbin/hugmesh-node-storage-reconcile|usr/sbin/hugmesh-node-storage-reconcile|755"
    "usr/lib/hugmesh/storage-verify.sh|usr/lib/hugmesh/storage-verify.sh|644"
    "etc/init.d/hugmesh-node-storage-reconcile|etc/init.d/hugmesh-node-storage-reconcile|755"
    "etc/cron.d/hugmesh-node-storage-reconcile|etc/hugmesh/registry/cron-node-storage-reconcile|644"
)

# check_tree <tree-root>: prints "  PASS [tag] …" / "  FAIL [tag] …"; returns 1 if any
# FAIL. Reads ONLY <tree>/build-*-stage4.sh, <tree>/scripts/_node-storage-bake-lib.sh,
# <tree>/specs/etc/keys-provision/provision.sh and the four spec sources — which is
# exactly what stage_tree() copies for the negative controls.
check_tree() {
    local T="$1" fails=0
    ok()  { echo "  PASS $*"; }
    bad() { echo "  FAIL $*"; fails=$((fails+1)); }

    local LIB="${T}/scripts/_node-storage-bake-lib.sh"
    local PROV="${T}/specs/etc/keys-provision/provision.sh"

    # ── [bake-effect] run the real bake against a sandbox sysroot ─────────────
    local SR="${WORK}/sysroot"; rm -rf "${SR}"; mkdir -p "${SR}"
    if [ ! -r "${LIB}" ]; then
        bad "[bake-effect] no bake helper at scripts/_node-storage-bake-lib.sh"
    elif ! ( set -uo pipefail; source "${LIB}"; bake_node_storage "${SR}" "${T}/specs" ) \
              > "${WORK}/bake.out" 2>&1; then
        bad "[bake-effect] bake_node_storage returned non-zero: $(tail -3 "${WORK}/bake.out" | tr '\n' ' ')"
    else
        ok "[bake-effect] bake_node_storage ran clean against a sandbox sysroot"
    fi
    local e src dst mode got
    for e in "${SPEC_SRC[@]}"; do
        src="${T}/specs/${e%%|*}"; dst="${e#*|}"; mode="${dst#*|}"; dst="${dst%%|*}"
        if [ ! -f "${SR}/${dst}" ]; then
            bad "[bake-effect] NOT baked: ${dst} (a comment, a wrong destination and a deleted cp all look like this)"
            continue
        fi
        if ! cmp -s "${src}" "${SR}/${dst}"; then
            bad "[bake-effect] baked ${dst} differs from its spec source ${e%%|*}"; continue
        fi
        got="$(stat -c '%a' "${SR}/${dst}" 2>/dev/null)"
        if [ "${got}" != "${mode}" ]; then
            bad "[bake-effect] ${dst} mode ${got}, expected ${mode} (the agent + oneshot are EXECUTED)"; continue
        fi
        ok "[bake-effect] ${dst} baked, identical, mode ${mode}"
    done
    [ -d "${SR}/var/lib/hugmesh/node-storage" ] \
        && ok "[bake-effect] agent cache dir /var/lib/hugmesh/node-storage created" \
        || bad "[bake-effect] agent cache dir /var/lib/hugmesh/node-storage NOT created"

    # ── [bake-reachable] every builder sources the lib AND reaches the call ───
    local -a BUILDERS
    mapfile -t BUILDERS < <(ls "${T}"/build-*-stage4.sh 2>/dev/null)
    if [ "${#BUILDERS[@]}" -lt 10 ]; then
        bad "[bake-reachable] expected >= 10 build-*-stage4.sh, found ${#BUILDERS[@]}"
    else
        ok "[bake-reachable] ${#BUILDERS[@]} device builders under test"
    fi
    local b name pp ln h rc bad_chain
    for b in "${BUILDERS[@]}"; do
        name="$(basename "${b}")"
        pp="${WORK}/pp.${name}.txt"
        if ! pp_dump "${b}" "${pp}"; then
            bad "[bake-reachable] ${name}: bash could not parse it (declare -f produced nothing)"; continue
        fi
        if ! grep -q '_node-storage-bake-lib.sh' "${pp}"; then
            bad "[bake-reachable] ${name} never SOURCES scripts/_node-storage-bake-lib.sh — the call below it would be a 127"
            continue
        fi
        if ! ln="$(pp_lineno "${pp}" 'bake_node_storage')"; then
            bad "[bake-reachable] ${name}: expected exactly one LIVE bake_node_storage call (a commented-out one is invisible to bash)"
            continue
        fi
        bad_chain=""
        while IFS= read -r h; do
            case "${h}" in
                FUNCTION:__pp_subject) : ;;                      # file top level: reached
                FUNCTION:*) bad_chain="the bake sits inside function ${h#FUNCTION:}() — nothing here proves that function runs" ;;
                *)
                    gate_reached "${h}"; rc=$?
                    [ "${rc}" -eq 0 ] && continue
                    if [ "${rc}" -eq 2 ]; then
                        bad_chain="unrecognised gate: '${h}' (teach MESH_PROFILE, or ungate the bake)"
                    else
                        bad_chain="gate '${h}' is FALSE on a mesh node — the bake never runs there"
                    fi
                    ;;
            esac
            [ -n "${bad_chain}" ] && break
        done < <(pp_gate_chain "${pp}" "${ln}")
        if [ -n "${bad_chain}" ]; then
            bad "[bake-reachable] ${name}: ${bad_chain}"
        else
            ok "[bake-reachable] ${name} calls bake_node_storage on a path a mesh node takes"
        fi
    done

    # ── [enable-effect] run the REAL first-boot flow against the baked sysroot ─
    local SB="${WORK}/sb-enable" SB2="${WORK}/sb-stale"
    if [ ! -r "${PROV}" ]; then
        bad "[enable-effect] cannot read ${PROV}"
    elif ! ps_stage "${SB}" "${PROV}" 2>"${WORK}/stage.err"; then
        bad "[enable-effect] sandbox staging failed: $(tail -2 "${WORK}/stage.err" | tr '\n' ' ')"
    else
        # Bake into the SAME fake root the provisioner will run against, so the
        # staged-cron basename contract is proven by effect: the bake writes it and
        # provision.sh reads it back. A rename on either side leaves cron.d empty.
        ( set -uo pipefail; source "${LIB}"; bake_node_storage "${SB}" "${T}/specs" ) >/dev/null 2>&1
        printf '{"hostname":"sandbox-node"}\n' > "${SB}/run/keys/provision.json"
        KEYS_PREMOUNTED=1 ps_run "${SB}"
        if ps_log "${SB}" rc-update | grep -q '^add hugmesh-node-storage-reconcile default$'; then
            ok "[enable-effect] provision.sh rc-update'd the boot oneshot into the default runlevel"
        else
            bad "[enable-effect] rc-update was NEVER CALLED for hugmesh-node-storage-reconcile (dead enable; recorded: $(ps_log "${SB}" rc-update | tr '\n' ',')) "
        fi
        if [ -f "${SB}/etc/cron.d/hugmesh-node-storage-reconcile" ] \
           && cmp -s "${T}/specs/etc/cron.d/hugmesh-node-storage-reconcile" \
                     "${SB}/etc/cron.d/hugmesh-node-storage-reconcile"; then
            ok "[enable-effect] the 60s cron drop-in LANDED in /etc/cron.d (staged-cron contract holds end to end)"
        else
            bad "[enable-effect] /etc/cron.d/hugmesh-node-storage-reconcile absent or not the spec file — no 60s convergence poll"
        fi
        if grep -q '=== keys-provision complete ===' "${SB}/log/run.out"; then
            ok "[enable-effect] the first-boot flow ran to completion"
        else
            bad "[enable-effect] first-boot flow did not complete: $(tail -3 "${SB}/log/run.out" | tr '\n' ' ')"
        fi

        # ── [degrade] a STALE image (agent not baked) warns, never bricks ──────
        if ps_stage "${SB2}" "${PROV}" 2>/dev/null; then
            printf '{"hostname":"stale-node"}\n' > "${SB2}/run/keys/provision.json"
            KEYS_PREMOUNTED=1 ps_run "${SB2}"
            if grep -q 'hugmesh-node-storage-reconcile missing from image' "${SB2}/log/run.out" \
               && grep -q '=== keys-provision complete ===' "${SB2}/log/run.out"; then
                ok "[degrade] an unbaked image WARNS about the missing agent and still completes provisioning"
            else
                bad "[degrade] an unbaked image must warn AND complete: $(tail -3 "${SB2}/log/run.out" | tr '\n' ' ')"
            fi
            if [ -f "${SB2}/etc/cron.d/hugmesh-node-storage-reconcile" ]; then
                bad "[degrade] an unbaked image installed a cron for an agent that is not there"
            else
                ok "[degrade] no cron installed when nothing was baked"
            fi
        fi
    fi

    return $(( fails > 0 ))
}

# ── stage_tree <dst> — a minimal writable copy of everything check_tree reads ──
stage_tree() {
    local d="$1" e
    rm -rf "${d}"
    mkdir -p "${d}/scripts" "${d}/specs/etc/keys-provision" "${d}/specs/etc/init.d" \
             "${d}/specs/etc/cron.d" "${d}/specs/usr/sbin" "${d}/specs/usr/lib/hugmesh" || return 1
    cp "${REPO}"/build-*-stage4.sh "${d}/" || return 1
    cp "${REPO}/scripts/_node-storage-bake-lib.sh" "${d}/scripts/" || return 1
    cp "${REPO}/specs/etc/keys-provision/provision.sh" "${d}/specs/etc/keys-provision/" || return 1
    for e in "${SPEC_SRC[@]}"; do
        cp "${REPO}/specs/${e%%|*}" "${d}/specs/${e%%|*}" || return 1
    done
}

echo "== node-storage bake + enable: reachability and effect =="
echo "-- positive: the repo's own tree must pass every check --"
check_tree "${REPO}"
POS=$?
if [ "${POS}" -ne 0 ]; then
    echo
    echo "== node-storage bake-coverage: FAIL (see above) =="
    exit 1
fi

# ── NEGATIVE CONTROLS ─────────────────────────────────────────────────────────
echo
echo "-- negative controls: one injected defect of each class, each must be caught --"
NEG_P=0; NEG_F=0
neg_ok()  { echo "  PASS negative control: $*"; NEG_P=$((NEG_P+1)); }
neg_bad() { echo "  FAIL negative control: $*"; NEG_F=$((NEG_F+1)); }

# <label> <expected [tag]> <injection snippet, run with $T = the staged tree>
expect_catch() {
    local label="$1" want="$2" inject="$3" T="${WORK}/tree" out rc
    stage_tree "${T}" || { neg_bad "${label} (staging failed)"; return; }
    ( T="${T}"; eval "${inject}" ) || { neg_bad "${label} (injection itself failed)"; return; }
    out="$(check_tree "${T}" 2>&1)"; rc=$?
    if [ "${rc}" -ne 0 ] && grep -qF "  FAIL ${want}" <<<"${out}"; then
        neg_ok "${label} -> caught by ${want}"
    else
        neg_bad "${label} NOT caught (rc=${rc}); wanted ${want}. FAILs seen:"
        grep -F '  FAIL ' <<<"${out}" | sed 's/^/        /' | head -6
    fi
}

# (a) BAKE DISABLED — the install line is commented out. The old grep-based guard was
#     green on exactly this shape.
expect_catch "bake disabled (the install line commented out)" "[bake-effect]" '
  python3 - "$T/scripts/_node-storage-bake-lib.sh" <<"PY"
import sys
p = sys.argv[1]; t = open(p, encoding="utf-8").read()
old = "        install -m \"${mode}\" \"${src}\" \"${dst}\" || { rc=1; continue; }"
assert old in t, "install line not found"
t = t.replace(old, "        : # " + old.strip(), 1)
open(p, "w", encoding="utf-8").write(t)
PY
'
# (c) BAKE MIS-TARGETED — only the DESTINATION moves. Every source-path string a grep
#     could look for is untouched, which is precisely why a grep never saw this class.
expect_catch "bake mis-targeted (oneshot copied to the wrong path)" "[bake-effect]" '
  sed -i "s#|etc/init.d/hugmesh-node-storage-reconcile|0755#|etc/init.d.disabled/hugmesh-node-storage-reconcile|0755#" \
      "$T/scripts/_node-storage-bake-lib.sh"
'
# (b) BAKE UNREACHABLE — the call is wrapped in a role gate that is FALSE for a mesh node.
expect_catch "bake unreachable (wrapped in a gate false on a mesh node)" "[bake-reachable]" '
  python3 - "$T/build-rpi5-stage4.sh" <<"PY"
import sys
p = sys.argv[1]; t = open(p, encoding="utf-8").read()
call = "bake_node_storage \"${SYSROOT}\" \"${SHARED_SPECS}\""
assert call in t, "call not found"
t = t.replace(call, "if ${UNAFFILIATED}; then\n" + call, 1)
t = t.replace("|| { err \"node-storage bake failed (see above)\"; exit 1; }",
              "|| { err \"node-storage bake failed (see above)\"; exit 1; }\nfi", 1)
open(p, "w", encoding="utf-8").write(t)
PY
'
# (b2) BAKE GATED ON SOMETHING THIS GUARD DOES NOT KNOW — must fail CLOSED, not pass.
expect_catch "bake behind an unrecognised gate (fail-closed)" "[bake-reachable]" '
  python3 - "$T/build-frite-stage4.sh" <<"PY"
import sys
p = sys.argv[1]; t = open(p, encoding="utf-8").read()
call = "bake_node_storage \"${SYSROOT}\" \"${SHARED_SPECS}\""
assert call in t, "call not found"
t = t.replace(call, "if [ \"${BOARD}\" = \"no-such-board\" ]; then\n" + call, 1)
t = t.replace("|| { err \"node-storage bake failed (see above)\"; exit 1; }",
              "|| { err \"node-storage bake failed (see above)\"; exit 1; }\nfi", 1)
open(p, "w", encoding="utf-8").write(t)
PY
'
# (d) ENABLE DEAD — provision_node_storage is still defined AND still textually called,
#     but the call moved into a helper nothing invokes. The old guard matched it happily.
expect_catch "enable dead (the call moved into a function nobody invokes)" "[enable-effect]" '
  python3 - "$T/specs/etc/keys-provision/provision.sh" <<PY
import sys
p=sys.argv[1]; t=open(p,encoding="utf-8").read()
old = "        provision_node_storage      # NODE-STORAGE reconcile enable"
assert old in t, "main() call site not found"
t = t.replace(old, "        : # dead", 1)
t = t.replace("# ── Main ───",
              "__never_called() {\n    provision_node_storage\n}\n\n# ── Main ───", 1)
open(p,"w",encoding="utf-8").write(t)
PY
'
# (d2) ENABLE DEAD, other half — rc-update present, but inside a branch that cannot run.
expect_catch "enable dead (rc-update inside a branch that never runs)" "[enable-effect]" '
  python3 - "$T/specs/etc/keys-provision/provision.sh" <<PY
import sys
p=sys.argv[1]; t=open(p,encoding="utf-8").read()
old = "    if [ -f /etc/init.d/hugmesh-node-storage-reconcile ]; then"
assert old in t, "enable branch not found"
t = t.replace(old, "    if false && [ -f /etc/init.d/hugmesh-node-storage-reconcile ]; then", 1)
open(p,"w",encoding="utf-8").write(t)
PY
'
# CROSS-FILE CONTRACT — the bake stages the cron under a basename provision.sh does not
# read back. Neither file is wrong on its own; the pair is.
expect_catch "staged-cron basename drift (bake side renamed)" "[enable-effect]" '
  sed -i "s#etc/hugmesh/registry/cron-node-storage-reconcile#etc/hugmesh/registry/cron-node-storage#" \
      "$T/scripts/_node-storage-bake-lib.sh"
'

echo
echo "node-storage bake-coverage: positive PASS, negative controls ${NEG_P} passed, ${NEG_F} failed"
[ "${NEG_F}" -eq 0 ]
