#!/usr/bin/env bash
# boot_stall_test.sh — HERMETIC guard for the runner's boot-stall fail-fast
# (docker-entrypoint.sh boot_stall_check + the ssh-wait loop that calls it).
# Boots nothing and starts no container: the function and the REAL wait loop are
# extracted from the entrypoint and driven with a fake ssh and a fake clock, over
# console logs captured from real guests.
#
#   bash tests/qemu/boot_stall_test.sh
#
# WHY. On 2026-11-10 one of two x86 laptop display-door boots lost its udev
# coldplug: no seat tags, so no X; no initialised NIC, so NetworkManager stayed
# inactive and ssh never answered. The console showed a login prompt at 12:20 and
# the runner still waited out the full 2400s ssh timeout, with the device record
# stuck at "booting". Fixtures (sanitised: ANSI, non-ASCII and host-key lines
# stripped, from the console after OpenRC starts):
#   fixtures/boot-stall/door1-lost-coldplug.console  that boot (NM inactive,
#                                                    login prompt, no ssh)
#   fixtures/boot-stall/door2-healthy.console        the next boot of the same
#                                                    image, which came up fine
#
# WHAT IT PINS:
#   1. door-1 FAILS FAST: "boot stalled" within the grace (300s) after the login
#      prompt, not at the 2400s timeout, and the verdict says NM was inactive.
#   2. door-2 PASSES: ssh answering ends the wait before any stall verdict, even
#      a slow ssh that answers just inside the grace.
#   3. The guest's own verdict ("udev-coldplug-guard: FAIL", printed by
#      specs/usr/libexec/udev-coldplug-guard) fails the row on the FIRST iteration,
#      and the row's verdict quotes that line: seat0 is named only when the guest
#      named it (a node row has no seat manager).
#   4. --boot-stall-grace 0 restores the old behaviour (wait the full --timeout),
#      and a console with no login prompt yet never trips the grace.
#   5. Only a getty prompt counts: "Local login: user X ready" does not; a CR
#      before the newline (serial consoles) does.
#   6. The flag is parsed and validated by the entrypoint and forwarded by
#      run-qemu-docker.sh on BOTH of its docker run lines.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTRYPOINT="${HERE}/docker-entrypoint.sh"
RUNNER="${HERE}/run-qemu-docker.sh"
FIX="${HERE}/fixtures/boot-stall"
for f in "${ENTRYPOINT}" "${RUNNER}" "${FIX}/door1-lost-coldplug.console" "${FIX}/door2-healthy.console"; do
    [ -f "${f}" ] || { echo "cannot find ${f}" >&2; exit 2; }
done

PASS=0; FAIL=0
_ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
_bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1" >&2; }
eq()   { if [ "$1" = "$2" ]; then _ok "$3"; else _bad "$3 (got '$1', want '$2')"; fi; }
has()   { case "$1" in *"$2"*) _ok "$3" ;; *) _bad "$3 (missing: $2)" ;; esac; }
lacks() { case "$1" in *"$2"*) _bad "$3 (found: $2)" ;; *) _ok "$3" ;; esac; }

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT

# ── extraction ──────────────────────────────────────────────────────────────
FN="${TMP}/fn.sh"
sed -n '/^boot_stall_check() {/,/^}/p' "${ENTRYPOINT}" > "${FN}"
grep -q '^boot_stall_check() {' "${FN}" || { echo "could not extract boot_stall_check from ${ENTRYPOINT}" >&2; exit 2; }
# The REAL wait loop, verbatim, from its step line to the trap reset after it.
LOOP="${TMP}/loop.sh"
awk '/^step "Waiting up to \$\{TIMEOUT\}s for guest SSH/{p=1} p{print} /^trap - TERM INT$/{exit}' "${ENTRYPOINT}" > "${LOOP}"
grep -q '^trap - TERM INT$' "${LOOP}" || { echo "could not extract the ssh-wait loop from ${ENTRYPOINT}" >&2; exit 2; }
echo 'emit_result UP ""' >> "${LOOP}"

# drive CONSOLE SSH_UP_AFTER TIMEOUT GRACE — runs the extracted loop in its own
# bash with a fake clock (each 5s sleep advances SECONDS by 5) and a fake ssh
# that answers on call SSH_UP_AFTER (0 = never). Prints "STATUS<TAB>DETAIL<TAB>T".
drive() {
    local out="${TMP}/out.$$.${RANDOM}"
    CONSOLE="$1" SSH_UP_AFTER="$2" TIMEOUT="$3" BOOT_STALL_GRACE="$4" OUT="${out}" \
    FN="${FN}" LOOP="${LOOP}" bash -c '
        set -u
        SSH_OPTS=(-p 2222); SSH_USER=tester; SSH_PORT=2222; PIDFILE=""
        SSH_CALLS=0
        step() { :; }
        warn() { :; }
        ssh() { SSH_CALLS=$((SSH_CALLS + 1)); [ "${SSH_UP_AFTER}" -gt 0 ] && [ "${SSH_CALLS}" -ge "${SSH_UP_AFTER}" ]; }
        sleep() { :; }
        wait() { SECONDS=$((SECONDS + 5)); }
        emit_result() { printf "%s\t%s\t%s\n" "$1" "$2" "${SECONDS}" > "${OUT}"; }
        source "${FN}"
        BOOT_STALL_REASON=""; BOOT_STALL_LOGIN_AT=""
        SECONDS=0
        source "${LOOP}"
    ' >/dev/null 2>&1
    cat "${out}" 2>/dev/null || printf 'NONE\t\t0\n'
    rm -f "${out}"
}
field() { printf '%s' "$1" | cut -f"$2"; }

D1="${FIX}/door1-lost-coldplug.console"
D2="${FIX}/door2-healthy.console"

echo "1. the door-1 console (lost coldplug) fails fast"
r="$(drive "${D1}" 0 2400 300)"
eq "$(field "${r}" 1)" FAIL "door-1: the row FAILS"
has "$(field "${r}" 2)" "boot stalled" "door-1: the verdict names a stalled boot"
has "$(field "${r}" 2)" "NetworkManager inactive: yes" "door-1: the verdict reports NetworkManager inactive"
has "$(field "${r}" 2)" "udev coldplug lost: no" "door-1: no guard line on a pre-guard image, and it says so"
t="$(field "${r}" 3)"
if [ "${t}" -ge 300 ] && [ "${t}" -lt 310 ]; then _ok "door-1: failed at ${t}s, inside one poll of the 300s grace (not 2400s)"
else _bad "door-1: failed at ${t}s, want 300..309"; fi

echo "2. the door-2 console (healthy) passes"
r="$(drive "${D2}" 4 2400 300)"
eq "$(field "${r}" 1)" UP "door-2: ssh answers, the wait ends UP"
r="$(drive "${D2}" 59 2400 300)"
eq "$(field "${r}" 1)" UP "door-2: a slow ssh answering at ~290s, inside the grace, is still UP"

echo "3. the guest's own FAIL verdict ends the wait at once"
cp "${D1}" "${TMP}/guard-fail.console"
printf '%s\n' "udev-coldplug-guard: FAIL: still uninitialised after the re-trigger: net/eth0 drm/card0 (seat0 will have no devices and NetworkManager will not manage the NIC)" >> "${TMP}/guard-fail.console"
r="$(drive "${TMP}/guard-fail.console" 0 2400 300)"
eq "$(field "${r}" 1)" FAIL "guard FAIL: the row FAILS"
has "$(field "${r}" 2)" "(console: 'udev-coldplug-guard: FAIL: still uninitialised after the re-trigger: net/eth0 drm/card0 (seat0 will have no devices and NetworkManager will not manage the NIC)')" "guard FAIL (desktop): the verdict quotes the guest's line, seat0 included"
has "$(field "${r}" 2)" "udev-coldplug-guard: FAIL" "guard FAIL: the verdict quotes the console line"
# A node row has no seat manager: the guest's line says so, and the runner must
# not add a seat0 claim of its own (PR #972 refuter, round 2).
cp "${D1}" "${TMP}/guard-fail-node.console"
printf '%s\n' "udev-coldplug-guard: FAIL: still uninitialised after the re-trigger: pci/0000:00:03.0 net/eth0 (udev never applied its rules to them: no driver autoload, no NIC naming, no device permissions)" >> "${TMP}/guard-fail-node.console"
r="$(drive "${TMP}/guard-fail-node.console" 0 2400 300)"
eq "$(field "${r}" 1)" FAIL "guard FAIL (node): the row FAILS"
lacks "$(field "${r}" 2)" "seat0" "guard FAIL (node): no seat0 claim on a row without a seat manager"
lacks "$(field "${r}" 2)" "no X, no greeter" "guard FAIL (node): no X/greeter claim either"
has "$(field "${r}" 2)" "udev never applied its rules to them" "guard FAIL (node): the verdict carries the guest's own cost"
# Only the guest's line says what was lost; a stuck card or PCI device alone
# does not stop ssh, so the runner must not claim it never answers.
lacks "$(field "${r}" 2)" "ssh will never answer" "guard FAIL (node): no 'ssh will never answer' claim of the runner's own"
# A serial console can glue colour codes and a half line in front, and a CR after.
printf '\033[0;32m * \033[0mChecking that the udev coldplug reached udevd ...udev-coldplug-guard: FAIL: still uninitialised after the re-trigger: net/eth0 (udev never applied its rules to them: no driver autoload, no NIC naming, no device permissions)\r\n' > "${TMP}/guard-fail-crlf.console"
r="$(drive "${TMP}/guard-fail-crlf.console" 0 2400 300)"
has "$(field "${r}" 2)" "(console: 'udev-coldplug-guard: FAIL: still uninitialised" "guard FAIL (serial): the quote starts at the marker"
lacks "$(field "${r}" 2)" $'\r' "guard FAIL (serial): no CR in the verdict"
lacks "$(field "${r}" 2)" "Checking that" "guard FAIL (serial): the glued half line is not quoted"
t="$(field "${r}" 3)"
if [ "${t}" -lt 10 ]; then _ok "guard FAIL: failed at ${t}s, on the first poll"; else _bad "guard FAIL: failed at ${t}s, want < 10"; fi
r="$(drive "${TMP}/guard-fail.console" 0 2400 0)"
has "$(field "${r}" 2)" "udev-coldplug-guard: FAIL" "guard FAIL: still fails fast with --boot-stall-grace 0"

echo "4. a recovered coldplug is not a failure; a lost one is reported"
cp "${D2}" "${TMP}/recovered.console"
printf '%s\n' "udev-coldplug-guard: LOST coldplug: 2 canary device(s) never reached udevd: net/eth0 drm/card0 ; re-triggering" \
              "udev-coldplug-guard: RECOVERED: the re-trigger initialised every canary" >> "${TMP}/recovered.console"
r="$(drive "${TMP}/recovered.console" 3 2400 300)"
eq "$(field "${r}" 1)" UP "LOST then RECOVERED + ssh up: the wait ends UP"
cp "${D1}" "${TMP}/lost.console"
printf '%s\n' "udev-coldplug-guard: LOST coldplug: 1 canary device(s) never reached udevd: net/eth0 ; re-triggering" >> "${TMP}/lost.console"
r="$(drive "${TMP}/lost.console" 0 2400 300)"
has "$(field "${r}" 2)" "udev coldplug lost: yes" "LOST + no ssh: the stall verdict reports the lost coldplug"

echo "5. the old behaviour is still there when asked for, and before a login prompt"
r="$(drive "${D1}" 0 2400 0)"
eq "$(field "${r}" 1)" FAIL "grace 0: still FAILS"
has "$(field "${r}" 2)" "guest did not reach SSH within 2400s" "grace 0: waits the full --timeout (old verdict)"
t="$(field "${r}" 3)"
if [ "${t}" -ge 2400 ]; then _ok "grace 0: failed at ${t}s"; else _bad "grace 0: failed at ${t}s, want >= 2400"; fi
head -n 120 "${D1}" > "${TMP}/midboot.console"
r="$(drive "${TMP}/midboot.console" 0 600 300)"
has "$(field "${r}" 2)" "guest did not reach SSH within 600s" "no login prompt yet: the grace never starts"
r="$(drive "${TMP}/does-not-exist.console" 0 300 300)"
has "$(field "${r}" 2)" "guest did not reach SSH within 300s" "no console file at all: plain timeout"

echo "6. only a getty prompt starts the grace"
printf '%s\n' " * Starting local ..." "Local login: user proofuser ready (password set at build time)." > "${TMP}/local-only.console"
r="$(drive "${TMP}/local-only.console" 0 600 300)"
has "$(field "${r}" 2)" "guest did not reach SSH within 600s" "'Local login: user X ready' is not a login prompt"
printf '%s\r\n' "This is node (Linux aarch64)" "node-1 login: " > "${TMP}/crlf.console"
r="$(drive "${TMP}/crlf.console" 0 2400 300)"
has "$(field "${r}" 2)" "boot stalled" "a CRLF serial prompt counts"

echo "7. the knob is parsed, validated and forwarded"
ep="$(cat "${ENTRYPOINT}")"; rn="$(cat "${RUNNER}")"
has "${ep}" '--boot-stall-grace) BOOT_STALL_GRACE="$2"; shift 2 ;;' "entrypoint parses --boot-stall-grace"
has "${ep}" 'die "--boot-stall-grace must be a whole number of seconds' "entrypoint validates it"
has "${rn}" '--boot-stall-grace) BOOT_STALL_GRACE="$2"; shift 2 ;;' "runner parses --boot-stall-grace"
n="$(grep -c -F -- '${BOOT_STALL_GRACE:+--boot-stall-grace "${BOOT_STALL_GRACE}"}' "${RUNNER}")"
eq "${n}" 2 "runner forwards it on both docker run lines"

echo
echo "boot_stall_test: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
