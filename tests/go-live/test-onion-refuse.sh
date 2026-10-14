#!/usr/bin/env bash
# test-onion-refuse.sh — a Tor address is never tripped as a public flip
# (hugmesh-generator#654, decision D12).
#
# WHAT WAS WRONG. `hugmesh-go-live commit --provider tor-onion -y` wrote the
# go-live marker like any other provider; the plan text warned an onion-only
# operator not to run it, and nothing enforced the warning. The marker's one
# effect is that hugmesh-firewall-reconcile opens public 80/443 — the exact thing
# a Tor-only operator chose not to have. The .onion is served outbound by the
# node's own Tor daemon and is reachable with the firewall CLOSED.
#
# WHAT IS ASSERTED, offline, against a throwaway GL_ETC_HUGMESH (never /etc):
#   (a) the DRIVER refuses `commit --provider tor-onion -y`: exits non-zero, says
#       'A Tor address needs no public flip.', writes no marker, and the posture
#       stays internal — also with --persist-public and with GL_ASSUME_YES=1;
#   (b) every OTHER provider still commits (and rolls back) exactly as before;
#   (c) `plan --provider tor-onion` still emits its artifacts and no longer tells
#       the operator to run commit for it;
#   (d) the guided CLI front-end, driven through a real pty, does NOT offer
#       'Trip GO-LIVE now' after a Tor plan — and DOES offer it after a public
#       plan (the control that proves the pty drive is not vacuous);
#   (e) the console menu (plain renderer) says the sentence inline when GO LIVE is
#       picked with tor-onion chosen and never calls the driver's commit — and
#       DOES call it for a public provider (control);
#   (f) MUTATIONS: each of the three refusals is removed from a COPY of its script
#       in turn, and the matching assertion must go red. A guard that cannot fail
#       is the disease this repo keeps relapsing into.
#
# Runs ANYWHERE with bash + python3 (pty for (d)) — NO root, NO network, NO live
# /etc, NO tor. Mirrors tests/go-live/test-go-live-driver.sh.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SBIN="${REPO}/specs/usr/sbin"
DRIVER="${SBIN}/hugmesh-go-live"
CLI="${SBIN}/hugmesh-go-live-cli"
MENU="${SBIN}/hugmesh-go-live-menu"
LIB="${REPO}/specs/usr/lib/hugmesh/go-live-providers.sh"

for f in "${DRIVER}" "${CLI}" "${MENU}" "${LIB}"; do
    [ -r "${f}" ] || { echo "  FAIL missing: ${f}"; exit 1; }
done
# Tool preflight is FAIL-CLOSED (tests/lib/guard-preflight.sh): a missing tool
# makes this guard exit 1, never 0 — a CI image without python3 must not turn
# into a green check. Deliberate local opt-out: GUARD_TOOLING_ALLOW_SKIP=1.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/guard-preflight.sh"
guard_require_tools bash python3 awk cmp
python3 -c 'import pty, select' 2>/dev/null || { echo "  FAIL python3 lacks pty/select — the CLI leg (d) cannot run"; exit 1; }

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}" 2>/dev/null' EXIT

SENTENCE="A Tor address needs no public flip."
DOMAIN="mesh.example"

# fresh_etc NAME -> a throwaway /etc/hugmesh with the baked context (internal, no marker)
fresh_etc() {
    local d="${WORK}/etc-$1"
    rm -rf "${d}"; mkdir -p "${d}"
    printf '%s\n' "${DOMAIN}" > "${d}/cluster-domain"
    printf 'internal\n'       > "${d}/release-state"
    printf '%s' "${d}"
}

# gl ETC DRIVER ARGS... -> run a driver against ETC, stdin from /dev/null (non-TTY)
gl() { local etc="$1" drv="$2"; shift 2; GL_ETC_HUGMESH="${etc}" GL_PROVIDERS_LIB="${LIB}" bash "${drv}" "$@" </dev/null 2>&1; }

posture() { gl "$1" "$2" status | awk '/^effective posture:/ {print $3}'; }

echo "== go-live: a Tor address is never tripped as a public flip (#654 D12) =="

# ── (a) the driver refuses commit for the onion ───────────────────────────────
ETC="$(fresh_etc a)"
out="$(gl "${ETC}" "${DRIVER}" commit --provider tor-onion -y)"; rc=$?
[ "${rc}" -ne 0 ] && ok "driver: commit --provider tor-onion -y exits non-zero (rc=${rc})" \
    || { bad "driver: commit --provider tor-onion -y exited 0"; echo "${out}"; }
echo "${out}" | grep -F "${SENTENCE}" >/dev/null && ok "driver: says '${SENTENCE}'" \
    || { bad "driver: the sentence is missing"; echo "${out}"; }
[ ! -e "${ETC}/go-live" ] && ok "driver: no marker written" || bad "driver: the marker WAS written"
[ "$(posture "${ETC}" "${DRIVER}")" = "internal" ] && ok "driver: posture stays internal" \
    || bad "driver: posture is $(posture "${ETC}" "${DRIVER}")"
grep -x 'internal' "${ETC}/release-state" >/dev/null && ok "driver: release-state untouched" || bad "driver: release-state changed"
# --persist-public must not slip past the refusal either
out="$(gl "${ETC}" "${DRIVER}" commit --provider tor-onion -y --persist-public)"; rc=$?
[ "${rc}" -ne 0 ] && [ ! -e "${ETC}/go-live" ] && grep -x 'internal' "${ETC}/release-state" >/dev/null \
    && ok "driver: --persist-public is refused too (no marker, release-state internal)" \
    || { bad "driver: --persist-public got past the refusal (rc=${rc})"; echo "${out}"; }
# and the test-only GL_ASSUME_YES seam is not a side door
out="$(GL_ASSUME_YES=1 gl "${ETC}" "${DRIVER}" commit --provider tor-onion)"; rc=$?
[ "${rc}" -ne 0 ] && [ ! -e "${ETC}/go-live" ] && ok "driver: GL_ASSUME_YES=1 is refused too" \
    || { bad "driver: GL_ASSUME_YES=1 got past the refusal (rc=${rc})"; echo "${out}"; }
# the refusal is the onion's and not a blanket one: the generic verbs still work
out="$(gl "${ETC}" "${DRIVER}" commit --provider tor-onion -y)"
echo "${out}" | grep -F "unknown provider" >/dev/null && bad "driver: tor-onion reads as UNKNOWN — the refusal is the wrong one" \
    || ok "driver: tor-onion is still a known provider (refused on its mechanism, not its name)"

# ── (b) every other provider still commits ────────────────────────────────────
mapfile -t OTHERS < <(gl "${ETC}" "${DRIVER}" list | awk 'NR>1 { if ($0 ~ /^[[:space:]]*$/) exit; if ($2 != "onion") print $1 }')
[ "${#OTHERS[@]}" -ge 5 ] && ok "list: ${#OTHERS[@]} non-onion providers to check (${OTHERS[*]})" \
    || bad "list: expected at least 5 non-onion providers, got ${#OTHERS[@]}"
for prov in "${OTHERS[@]}"; do
    ETCB="$(fresh_etc "b-${prov}")"
    out="$(gl "${ETCB}" "${DRIVER}" commit --provider "${prov}" -y)"; rc=$?
    [ "${rc}" -eq 0 ] && [ -e "${ETCB}/go-live" ] && [ "$(posture "${ETCB}" "${DRIVER}")" = "public" ] \
        && ok "driver: ${prov} still commits (marker written, posture public)" \
        || { bad "driver: ${prov} no longer commits (rc=${rc}, marker=$([ -e "${ETCB}/go-live" ] && echo y || echo n))"; echo "${out}"; }
    grep "^provider=${prov}$" "${ETCB}/go-live" >/dev/null 2>&1 && ok "driver: ${prov} marker names the provider" \
        || bad "driver: ${prov} marker does not name the provider"
    gl "${ETCB}" "${DRIVER}" rollback -y >/dev/null
    [ ! -e "${ETCB}/go-live" ] && ok "driver: ${prov} rollback still removes the marker" || bad "driver: ${prov} rollback failed"
done

# ── (c) plan for the onion still works and no longer points at commit ─────────
OUT="${WORK}/plan-onion"; mkdir -p "${OUT}"
out="$(gl "${ETC}" "${DRIVER}" plan --provider tor-onion --out-dir "${OUT}")"; rc=$?
[ "${rc}" -eq 0 ] && ok "plan: tor-onion still plans (rc=0)" || { bad "plan: tor-onion plan failed (rc=${rc})"; echo "${out}"; }
[ -n "$(ls -A "${OUT}" 2>/dev/null)" ] && ok "plan: tor-onion still emits artifacts" || bad "plan: tor-onion emitted nothing"
[ ! -e "${ETC}/go-live" ] && ok "plan: wrote no marker (dry-run)" || bad "plan: WROTE the marker"
echo "${out}" | grep -F "hugmesh-go-live commit --provider tor-onion" >/dev/null \
    && bad "plan: still tells the operator to run commit for tor-onion" \
    || ok "plan: no longer tells the operator to run commit for tor-onion"
# the NEXT block wraps at 80 columns, so judge it with its whitespace folded
echo "${out}" | tr -s ' \n' '  ' | grep -F "A Tor address needs no public flip" >/dev/null && ok "plan: says the onion needs no public flip" \
    || { bad "plan: the no-flip sentence is gone"; echo "${out}"; }

# ── (d) the guided CLI, through a real pty ────────────────────────────────────
# The CLI's guided mode needs a TTY (it refuses a pipe on purpose), so it is
# driven through python's pty: wait for each PROMPT substring, send the ANSWER.
# A prompt that never comes (or one that comes when it must not) ends in a
# timeout, which the assertions read from the transcript — never from a guess.
cat > "${WORK}/drive.py" <<'PY'
import os, pty, select, signal, sys, time
cmd = sys.argv[1:]
prompts = os.environ["PROMPTS"].split("|")
answers = os.environ["ANSWERS"].split("|")
pid, fd = pty.fork()
if pid == 0:
    os.execvp(cmd[0], cmd)
out = b""; pos = 0; i = 0
deadline = time.time() + float(os.environ.get("DRIVE_TIMEOUT", "20"))
exited = False; status = None
while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], 0.2)
    if r:
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            chunk = b""
        if not chunk:
            # EOF (EIO on Linux once the slave side closes): the child is done.
            _, status = os.waitpid(pid, 0); exited = True
            break
        out += chunk
    if i < len(prompts) and prompts[i].encode() in out[pos:]:
        os.write(fd, (answers[i] + "\n").encode()); pos = len(out); i += 1
    wpid, status = os.waitpid(pid, os.WNOHANG)
    if wpid == pid:
        exited = True
        # drain what is left
        while True:
            r, _, _ = select.select([fd], [], [], 0.2)
            if not r: break
            try:
                chunk = os.read(fd, 4096)
            except OSError:
                break
            if not chunk: break
            out += chunk
        break
sys.stdout.write(out.decode("utf-8", "replace"))
if not exited:
    os.kill(pid, signal.SIGKILL); os.waitpid(pid, 0)
    sys.stdout.write("\n[drive.py: TIMEOUT — the front-end did not finish]\n")
    sys.exit(124)
sys.exit(os.waitstatus_to_exitcode(status))
PY
# provider NUMBERS as the CLI lists them (its index is the driver's list order)
num_of() { gl "${ETC}" "${DRIVER}" list | awk -v id="$1" 'NR>1 { if ($0 ~ /^[[:space:]]*$/) exit; n++; if ($1==id) print n }'; }
N_ONION="$(num_of tor-onion)"; N_BYO="$(num_of byo-domain)"
[ -n "${N_ONION}" ] && [ -n "${N_BYO}" ] && ok "cli: provider numbers resolved (tor-onion=${N_ONION}, byo-domain=${N_BYO})" \
    || bad "cli: could not resolve provider numbers from the driver's list"

# drive_cli ETC CLI PROMPTS ANSWERS -> transcript on stdout, rc of the front-end
drive_cli() {
    local etc="$1" cli="$2" prompts="$3" answers="$4"
    PROMPTS="${prompts}" ANSWERS="${answers}" \
    GL_DRIVER="${DRIVER}" GL_ETC_HUGMESH="${etc}" GL_PROVIDERS_LIB="${LIB}" GL_OUT_DIR="${WORK}/cli-out" TERM=dumb \
        python3 "${WORK}/drive.py" bash "${cli}"
}
ETCD="$(fresh_etc d)"
out="$(drive_cli "${ETCD}" "${CLI}" "provider number|ingress IPv4" "${N_ONION}|")"; rc=$?
[ "${rc}" -eq 0 ] && ok "cli: guided run with a Tor plan finishes by itself (rc=0, no hanging prompt)" \
    || { bad "cli: guided Tor run rc=${rc}"; echo "${out}" | tail -15; }
echo "${out}" | grep -F "Trip GO-LIVE now" >/dev/null && bad "cli: offered 'Trip GO-LIVE now' after a Tor plan" \
    || ok "cli: does not offer 'Trip GO-LIVE now' after a Tor plan"
echo "${out}" | grep -F "${SENTENCE}" >/dev/null && ok "cli: says '${SENTENCE}'" \
    || { bad "cli: the sentence is missing"; echo "${out}" | tail -15; }
[ ! -e "${ETCD}/go-live" ] && ok "cli: no marker after the Tor run" || bad "cli: the marker WAS written"
# control: a public provider is still offered the flip (answered 'n', so no marker)
ETCC="$(fresh_etc d-control)"
out="$(drive_cli "${ETCC}" "${CLI}" "provider number|ingress IPv4|Trip GO-LIVE now" "${N_BYO}|203.0.113.10|n")"; rc=$?
echo "${out}" | grep -F "Trip GO-LIVE now" >/dev/null && ok "cli CONTROL: byo-domain is still offered 'Trip GO-LIVE now' (the pty drive sees prompts)" \
    || { bad "cli CONTROL: byo-domain was NOT offered the flip (rc=${rc}) — the pty leg proves nothing"; echo "${out}" | tail -15; }
[ "${rc}" -eq 0 ] && [ ! -e "${ETCC}/go-live" ] && ok "cli CONTROL: 'n' leaves the device internal" || bad "cli CONTROL: rc=${rc}, marker=$([ -e "${ETCC}/go-live" ] && echo y || echo n)"

# ── (e) the console menu, plain renderer, piped answers ───────────────────────
# NO_TUI=1 selects the numbered-prompt fallback, which reads stdin like any shell
# prompt. Sequence: 1 (pick provider) → N (the provider) → 4 (GO LIVE) → Enter
# (dismiss the message / answer the persist question) → q (quit).
drive_menu() {
    local etc="$1" menu="$2" n="$3"
    printf '1\n%s\n4\n\nq\n' "${n}" | NO_TUI=1 TERM=dumb GL_DRIVER="${DRIVER}" GL_ETC_HUGMESH="${etc}" GL_PROVIDERS_LIB="${LIB}" \
        timeout 30 bash "${menu}" 2>&1
}
ETCE="$(fresh_etc e)"
out="$(drive_menu "${ETCE}" "${MENU}" "${N_ONION}")"; rc=$?
[ "${rc}" -eq 0 ] && ok "menu: Tor run finishes (rc=0)" || { bad "menu: Tor run rc=${rc}"; echo "${out}" | tail -15; }
echo "${out}" | grep -F "${SENTENCE}" >/dev/null && ok "menu: says '${SENTENCE}' when GO LIVE is picked for tor-onion" \
    || { bad "menu: the sentence is missing"; echo "${out}" | tail -20; }
echo "${out}" | grep -F "running: hugmesh-go-live commit" >/dev/null && bad "menu: still handed 'commit' to the driver for tor-onion" \
    || ok "menu: never hands 'commit' to the driver for tor-onion"
echo "${out}" | grep -F "not offered: a Tor address needs no public flip" >/dev/null && ok "menu: the GO LIVE entry says why it is not offered" \
    || { bad "menu: the GO LIVE entry does not say why"; echo "${out}" | tail -20; }
[ ! -e "${ETCE}/go-live" ] && ok "menu: no marker" || bad "menu: the marker WAS written"
# control: with a public provider the menu DOES hand commit to the driver (whose
# own non-TTY gate then refuses without --yes — so still no marker, by the driver's rule)
ETCF="$(fresh_etc e-control)"
out="$(drive_menu "${ETCF}" "${MENU}" "${N_BYO}")"; rc=$?
echo "${out}" | grep -F "running: hugmesh-go-live commit --provider byo-domain" >/dev/null \
    && ok "menu CONTROL: byo-domain GO LIVE reaches the driver's commit (the menu leg proves something)" \
    || { bad "menu CONTROL: byo-domain never reached the driver (rc=${rc})"; echo "${out}" | tail -20; }
echo "${out}" | grep -F "${SENTENCE}" >/dev/null && bad "menu CONTROL: the Tor sentence showed for byo-domain" \
    || ok "menu CONTROL: no Tor sentence for byo-domain"

# ── (f) MUTATIONS: remove each refusal from a COPY; the guard must go red ─────
# mutate SRC DST NEEDLE REPLACEMENT -> a copy with ONE line changed; proven to differ
mutate() {
    local src="$1" dst="$2" needle="$3" repl="$4"
    NEEDLE="${needle}" REPL="${repl}" python3 - "${src}" "${dst}" <<'PY'
import os, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
needle, repl = os.environ["NEEDLE"], os.environ["REPL"]
if text.count(needle) != 1:
    sys.exit("mutation needle found %d times (want exactly 1): %r" % (text.count(needle), needle))
open(dst, "w", encoding="utf-8").write(text.replace(needle, repl))
PY
    local rc=$?
    [ "${rc}" -eq 0 ] || return 1
    cmp -s "${src}" "${dst}" && { echo "    !! mutation did not change the copy" >&2; return 1; }
    return 0
}
MUT="${WORK}/mut"; mkdir -p "${MUT}"
# the front-ends find the driver as a SIBLING unless GL_DRIVER is set, so the
# mutated copies live beside a copy of the real driver and are pointed at it
cp "${DRIVER}" "${MUT}/hugmesh-go-live"

# (f1) driver without the refusal: commit tor-onion -y must now WRITE the marker
if mutate "${DRIVER}" "${MUT}/driver-no-refusal" '    refuse_onion_commit "${provider}"' '    :'; then
    ETCM="$(fresh_etc f1)"
    out="$(gl "${ETCM}" "${MUT}/driver-no-refusal" commit --provider tor-onion -y)"; rc=$?
    [ "${rc}" -eq 0 ] && [ -e "${ETCM}/go-live" ] && [ "$(posture "${ETCM}" "${DRIVER}")" = "public" ] \
        && ok "MUTATION driver: with the refusal removed, commit tor-onion WRITES the marker — assertion (a) would be red" \
        || { bad "MUTATION driver: refusal removed yet commit still refused (rc=${rc}) — (a) tests nothing"; echo "${out}"; }
else
    bad "MUTATION driver: could not apply (needle moved?)"
fi

# (f2) cli without its check: after a Tor plan it must now OFFER the flip
if mutate "${CLI}" "${MUT}/cli-no-check" 'if [ "${mech}" = "onion" ]; then' 'if false; then'; then
    ETCM="$(fresh_etc f2)"
    out="$(drive_cli "${ETCM}" "${MUT}/cli-no-check" "provider number|ingress IPv4|Trip GO-LIVE now" "${N_ONION}||n")"; rc=$?
    echo "${out}" | grep -F "Trip GO-LIVE now" >/dev/null \
        && ok "MUTATION cli: with its check removed, 'Trip GO-LIVE now' IS offered after a Tor plan — assertion (d) would be red" \
        || { bad "MUTATION cli: check removed yet the flip is still not offered (rc=${rc}) — (d) tests nothing"; echo "${out}" | tail -10; }
else
    bad "MUTATION cli: could not apply (needle moved?)"
fi

# (f3) menu without its check: GO LIVE for tor-onion must now reach the driver
if mutate "${MENU}" "${MUT}/menu-no-check" 'if [ "$(provider_mechanism "${OPT_PROVIDER}")" = "onion" ]; then' 'if false; then'; then
    ETCM="$(fresh_etc f3)"
    out="$(drive_menu "${ETCM}" "${MUT}/menu-no-check" "${N_ONION}")"; rc=$?
    echo "${out}" | grep -F "running: hugmesh-go-live commit --provider tor-onion" >/dev/null \
        && ok "MUTATION menu: with its check removed, GO LIVE hands commit to the driver — assertion (e) would be red" \
        || { bad "MUTATION menu: check removed yet commit never reached the driver (rc=${rc}) — (e) tests nothing"; echo "${out}" | tail -10; }
    # and the DRIVER still refuses it: the belt holds when the braces are cut
    [ ! -e "${ETCM}/go-live" ] && ok "MUTATION menu: the real driver still refused the forwarded commit (no marker)" \
        || bad "MUTATION menu: the marker was written through a mutated menu — the driver's refusal is gone too"
else
    bad "MUTATION menu: could not apply (needle moved?)"
fi

# the real tree was never touched (every mutation went to a copy under WORK)
cmp -s "${DRIVER}" "${MUT}/hugmesh-go-live" && ok "the real driver is byte-identical to its pre-mutation copy" || bad "the real driver CHANGED during this run"

echo
echo "== onion refuse: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ] || exit 1
exit 0
