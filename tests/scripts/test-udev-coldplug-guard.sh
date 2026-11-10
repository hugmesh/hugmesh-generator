#!/usr/bin/env bash
# test-udev-coldplug-guard.sh — HERMETIC guard for the guest half of the udev
# coldplug fix: specs/usr/libexec/udev-coldplug-guard, its OpenRC service, and the
# x86 build lines that install it into the SYSINIT runlevel.
#
#   bash tests/scripts/test-udev-coldplug-guard.sh
#
# The helper runs under plain `sh` against a fake sysfs tree and a fake udevadm
# that keeps a tiny device database in files, so every scenario is the helper's
# real code making real decisions; nothing is grepped out of it.
#
# WHAT IT PINS:
#   1. HEALTHY BOOTS on a desktop (seat rule, tagged card), a headless node and
#      a headless GPU node (initialised card, NO seat rule: nodes have no
#      elogind) -> "ok", exit 0, and NO second coldplug (a re-trigger re-runs
#      every RUN+= rule, so it must not be routine). A masked seat rule counts
#      as no seat rule; one in /etc alone counts as one.
#   2. LOST COLDPLUGS: the 2026-11-10 door-1 boot (PCI, NIC and card never
#      reached udevd); a headless node whose NIC driver is a module (no NIC class
#      device at all, only the PCI canary sees it); an uninitialised card on a
#      GPU node -> "LOST", exactly one re-trigger (subsystems, then devices,
#      --action=add), "RECOVERED", exit 0. The ping comes FIRST.
#   3. A COLDPLUG THAT STAYS LOST -> the "udev-coldplug-guard: FAIL" line the QEMU
#      runner fails fast on, exit 1; it claims seat0 only where a seat rule is.
#   4. With a seat rule, a card that is initialised but carries no "seat" tag is
#      still a lost seat device (seat0 is built from that tag).
#   5. A ping failure is reported and the check still runs.
#   6. Virtual NICs (no device link) and DRM connectors (no dev file) are not
#      canaries; a box with no canaries at all is fine; a long list is bounded.
#   7. The OpenRC service orders itself need udev / after udev-trigger and runs
#      the helper; the x86 build installs both files and links the service into
#      runlevels/SYSINIT (executed against a scratch sysroot, not read).
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
HELPER="${ROOT}/specs/usr/libexec/udev-coldplug-guard"
INITD="${ROOT}/specs/etc/init.d/udev-coldplug-guard"
BUILD="${ROOT}/build-x86-host-stage4.sh"
for f in "${HELPER}" "${INITD}" "${BUILD}"; do
    [ -f "${f}" ] || { echo "FAIL: cannot find ${f}" >&2; exit 1; }
done

PASS=0; FAIL=0
_ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
_bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1" >&2; }
eq()   { if [ "$1" = "$2" ]; then _ok "$3"; else _bad "$3 (got '$1', want '$2')"; fi; }
has()   { case "$1" in *"$2"*) _ok "$3" ;; *) _bad "$3 (missing: $2)" ;; esac; }
lacks() { case "$1" in *"$2"*) _bad "$3 (found: $2)" ;; *) _ok "$3" ;; esac; }

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT

# ── the fake udevadm ────────────────────────────────────────────────────────
# State dir ($UCG_STATE):
#   calls        one line per invocation: its argv
#   db/<name>    a processed device ("udevd saw it"); content = its TAGS value
#                (empty = processed, no tags)
#   ping_rc      exit status of `control --ping` (default 0)
#   on_trigger   "recover" = a trigger initialises every device in recover.list
#                (each line "name TAGS"), anything else = triggers change nothing
FAKE="${TMP}/udevadm"
cat > "${FAKE}" <<'EOF'
#!/bin/sh
S="${UCG_STATE:?}"
echo "$*" >> "${S}/calls"
case "$1" in
    control) exit "$(cat "${S}/ping_rc" 2>/dev/null || echo 0)" ;;
    settle)  exit 0 ;;
    trigger)
        if [ "$(cat "${S}/on_trigger" 2>/dev/null)" = recover ]; then
            while read -r n t; do printf '%s\n' "${t}" > "${S}/db/${n}"; done < "${S}/recover.list"
        fi
        exit 0 ;;
    info)
        p=""
        for a in "$@"; do case "${a}" in --path=*) p="${a#--path=}" ;; esac; done
        n="${p##*/}"
        echo "DEVPATH=/devices/fake/${n}"
        echo "SUBSYSTEM=fake"
        if [ -f "${S}/db/${n}" ]; then
            echo "USEC_INITIALIZED=4242"
            t="$(cat "${S}/db/${n}")"
            [ -n "${t}" ] && echo "TAGS=${t}" && echo "CURRENT_TAGS=${t}"
        fi
        exit 0 ;;
esac
exit 0
EOF
chmod +x "${FAKE}"

# mk_world NAME ROLE — a fresh sysfs + rules dirs + state. ROLE is one of
#   desktop  client/desktop image: elogind's 71-seat.rules installed, card0
#   gpunode  headless GPU node (backend-gpu/omnibus/edge-ai, i915/amdgpu built
#            in): card0, but NO seat rule (nodes ship no elogind)
#   node     headless node: no card, no seat rule
# Every world has three PCI devices (host bridge, VGA, NIC), eth0 (physical),
# lo + dummy0 (virtual); card worlds add card0-Virtual-1 (a connector, no dev
# file). recover.list holds what a working coldplug writes to the db; heal
# writes it, i.e. "this boot's coldplug reached udevd".
PCI_DEVS="0000:00:00.0 0000:00:02.0 0000:00:03.0"
mk_world() {
    local w="${TMP}/$1" role="$2" d
    mkdir -p "${w}/sys/class/net/eth0/device" "${w}/sys/class/net/lo" "${w}/sys/class/net/dummy0" \
             "${w}/sys/bus/pci/devices" "${w}/rules/etc" "${w}/rules/run" "${w}/rules/usr" "${w}/state/db"
    : > "${w}/state/calls"; : > "${w}/state/recover.list"
    for d in ${PCI_DEVS}; do
        mkdir -p "${w}/sys/bus/pci/devices/${d}"
        printf '%s\n' "${d} " >> "${w}/state/recover.list"
    done
    printf '%s\n' "eth0 :systemd:" >> "${w}/state/recover.list"
    case "${role}" in
        desktop|gpunode)
            mkdir -p "${w}/sys/class/drm/card0" "${w}/sys/class/drm/card0-Virtual-1"
            echo "226:0" > "${w}/sys/class/drm/card0/dev" ;;
    esac
    case "${role}" in
        desktop)
            printf '%s\n' 'SUBSYSTEM=="drm", KERNEL=="card[0-9]*", TAG+="seat", TAG+="master-of-seat"' \
                > "${w}/rules/usr/71-seat.rules"
            printf '%s\n' "card0 :master-of-seat:uaccess:seat:" >> "${w}/state/recover.list" ;;
        gpunode)
            printf '%s\n' "card0 " >> "${w}/state/recover.list" ;;
    esac
    echo "${w}"
}
# heal WORLD — every device the coldplug would reach is in the db.
heal() { while read -r n t; do printf '%s\n' "${t}" > "$1/state/db/${n}"; done < "$1/state/recover.list"; }
# run_guard WORLD — run the real helper under sh; sets OUT and RC.
run_guard() {
    OUT="$(UCG_SYSFS="$1/sys" UCG_UDEVADM="${FAKE}" UCG_STATE="$1/state" \
           UCG_RULES_DIRS="$1/rules/etc:$1/rules/run:$1/rules/usr" \
           UCG_PING_TIMEOUT=1 UCG_SETTLE_TIMEOUT=1 sh "${HELPER}" 2>&1)"
    RC=$?
}
ntrig() { grep -c '^trigger' "$1/state/calls"; }

echo "1. healthy boots on every role: ok, no second coldplug"
W="$(mk_world healthy-desktop desktop)"; heal "${W}"
run_guard "${W}"
eq "${RC}" 0 "desktop: exit 0"
has "${OUT}" "udev-coldplug-guard: ok (5 coldplug canaries initialised: 3 pci, 1 net, 1 drm; cards seat-tagged)" "desktop: one ok line counting 3 PCI + eth0 + card0"
eq "$(ntrig "${W}")" 0 "desktop: no re-trigger"
lacks "${OUT}" "LOST" "desktop: nothing reported lost"

W="$(mk_world healthy-node node)"; heal "${W}"
run_guard "${W}"
eq "${RC}" 0 "headless node: exit 0"
has "${OUT}" "udev-coldplug-guard: ok (4 coldplug canaries initialised: 3 pci, 1 net, 0 drm; no seat rule, cards need no seat tag)" "headless node: ok line"
eq "$(ntrig "${W}")" 0 "headless node: no re-trigger"

# THE PR #972 REFUTER'S MEDIUM: an initialised card with no seat tag on a node
# with no seat rule is HEALTHY. Before the fix this printed LOST, re-ran the
# whole coldplug and printed the FAIL marker the QEMU runner kills rows on.
W="$(mk_world healthy-gpunode gpunode)"; heal "${W}"
run_guard "${W}"
eq "${RC}" 0 "headless GPU node, untagged card, no seat rule: exit 0"
has "${OUT}" "udev-coldplug-guard: ok (5 coldplug canaries initialised: 3 pci, 1 net, 1 drm; no seat rule, cards need no seat tag)" "headless GPU node: ok line"
eq "$(ntrig "${W}")" 0 "headless GPU node: no re-trigger"
lacks "${OUT}" "LOST" "headless GPU node: the untagged card is not reported lost"
lacks "${OUT}" "FAIL" "headless GPU node: no FAIL marker for the runner to kill the row on"

# A seat rule that is installed but MASKED (same name in a higher-precedence
# dir, empty or a /dev/null link) tags nothing either.
for mask in empty devnull; do
    W="$(mk_world masked-${mask} desktop)"; heal "${W}"
    printf '%s\n' "card0 :uaccess:" > "${W}/state/db/card0"
    if [ "${mask}" = empty ]; then : > "${W}/rules/etc/71-seat.rules"
    else ln -s /dev/null "${W}/rules/run/71-seat.rules"; fi
    run_guard "${W}"
    eq "${RC}" 0 "seat rule masked (${mask}): untagged card is fine, exit 0"
    eq "$(ntrig "${W}")" 0 "seat rule masked (${mask}): no re-trigger"
done
# ...while the same rule in /etc (not masked) overrides an absent /usr copy.
W="$(mk_world etc-rule gpunode)"; heal "${W}"
cp "${TMP}/healthy-desktop/rules/usr/71-seat.rules" "${W}/rules/etc/71-seat.rules"
run_guard "${W}"
has "${OUT}" "drm/card0(no seat tag)" "seat rule in /etc only: the card must be tagged"

echo "2. lost coldplugs: one re-trigger recovers them"
W="$(mk_world door1 desktop)"
echo recover > "${W}/state/on_trigger"
run_guard "${W}"
eq "${RC}" 0 "door-1: exit 0 after recovery"
has "${OUT}" "udev-coldplug-guard: LOST coldplug: 5 canary device(s) never reached udevd" "door-1: LOST line with the count"
has "${OUT}" "net/eth0" "door-1: names the NIC"
has "${OUT}" "drm/card0" "door-1: names the card"
has "${OUT}" "pci/0000:00:02.0" "door-1: names the PCI devices"
lacks "${OUT}" "lo " "door-1: lo (virtual) is not a canary"
lacks "${OUT}" "dummy0" "door-1: dummy0 (virtual) is not a canary"
lacks "${OUT}" "card0-Virtual-1" "door-1: a connector is not a canary"
has "${OUT}" "udev-coldplug-guard: RECOVERED" "door-1: RECOVERED line"
eq "$(ntrig "${W}")" 2 "door-1: exactly one coldplug (two trigger calls)"
eq "$(grep '^trigger' "${W}/state/calls" | head -1)" "trigger --type=subsystems --action=add" "door-1: subsystems first, --action=add"
eq "$(grep '^trigger' "${W}/state/calls" | tail -1)" "trigger --type=devices --action=add" "door-1: then devices, --action=add"
first="$(head -1 "${W}/state/calls")"
has "${first}" "control --ping" "the FIRST udevadm call is the ping (the barrier udev-trigger lacks)"
# settle must sit between the triggers and the re-check
seq="$(grep -n -E '^(trigger --type=devices|settle)' "${W}/state/calls" | tail -2 | cut -d: -f2- | tr '\n' '|')"
has "${seq}" "trigger --type=devices --action=add|settle" "door-1: settles after the re-trigger before re-checking"

# THE REFUTER'S LOW: a headless node whose only NIC driver is a module udev
# loads from the modalias. With the coldplug lost the module never loads, so
# there is no NIC class device and no card: before the fix the guard printed
# "ok (0 coldplug canaries initialised)". The PCI devices are still in sysfs.
W="$(mk_world module-nic node)"
rm -rf "${W}/sys/class/net/eth0"
sed -i '/^eth0 /d' "${W}/state/recover.list"
echo recover > "${W}/state/on_trigger"
run_guard "${W}"
has "${OUT}" "udev-coldplug-guard: LOST coldplug: 3 canary device(s) never reached udevd: pci/0000:00:00.0 pci/0000:00:02.0 pci/0000:00:03.0" "module NIC: the PCI canary sees the loss"
eq "$(ntrig "${W}")" 2 "module NIC: re-triggered once"
has "${OUT}" "udev-coldplug-guard: RECOVERED" "module NIC: RECOVERED"
eq "${RC}" 0 "module NIC: exit 0 after recovery"

# No seat rule does not mean no check: an UNINITIALISED card on a GPU node is
# still a lost coldplug.
W="$(mk_world gpunode-lost gpunode)"; heal "${W}"
rm -f "${W}/state/db/card0"
echo recover > "${W}/state/on_trigger"
run_guard "${W}"
has "${OUT}" "LOST coldplug: 1 canary device(s) never reached udevd: drm/card0 ;" "GPU node: an uninitialised card is still lost"
has "${OUT}" "RECOVERED" "GPU node: recovered by the re-trigger"

echo "3. a coldplug that stays lost: the FAIL line the runner keys on"
W="$(mk_world stuck desktop)"
run_guard "${W}"
eq "${RC}" 1 "stuck: exit 1"
has "${OUT}" "udev-coldplug-guard: FAIL: still uninitialised after the re-trigger" "stuck: the exact FAIL marker"
has "${OUT}" "seat0 will have no devices" "stuck desktop: says what it costs (seat0)"
eq "$(ntrig "${W}")" 2 "stuck: re-triggered once, not in a loop"
W="$(mk_world stuck-node node)"
run_guard "${W}"
eq "${RC}" 1 "stuck node: exit 1"
has "${OUT}" "udev-coldplug-guard: FAIL: still uninitialised after the re-trigger" "stuck node: the exact FAIL marker"
lacks "${OUT}" "seat0" "stuck node: no seat0 claim on a box with no seat manager"
has "${OUT}" "udev never applied its rules to them" "stuck node: says what it costs"
# the marker the runner greps must be what the helper prints, byte for byte
grep -q -F "grep -aq 'udev-coldplug-guard: FAIL'" "${ROOT}/tests/qemu/docker-entrypoint.sh" \
    && _ok "the runner greps the same 'udev-coldplug-guard: FAIL' marker" \
    || _bad "the runner does not grep 'udev-coldplug-guard: FAIL'"

echo "4. with a seat rule, an initialised card without the seat tag is a lost seat device"
W="$(mk_world untagged desktop)"; heal "${W}"
printf '%s\n' ":uaccess:" > "${W}/state/db/card0"
run_guard "${W}"
has "${OUT}" "drm/card0(no seat tag)" "untagged: card0 reported as missing its seat tag"
lacks "${OUT}" "net/eth0" "untagged: eth0 is fine and not named"
lacks "${OUT}" "pci/" "untagged: the PCI devices are fine and not named"
eq "$(ntrig "${W}")" 2 "untagged: re-triggered"
eq "${RC}" 1 "untagged: still FAIL when the re-trigger does not tag it"
# the tag must be :seat: itself, not a substring of another tag or another line
W="$(mk_world near-miss desktop)"; heal "${W}"
printf '%s\n' ":master-of-seat:uaccess:" > "${W}/state/db/card0"
run_guard "${W}"
has "${OUT}" "drm/card0(no seat tag)" "near-miss: master-of-seat alone is not the seat tag"

echo "5. ping failure is reported and the check still runs"
W="$(mk_world noping desktop)"; heal "${W}"
echo 1 > "${W}/state/ping_rc"
run_guard "${W}"
has "${OUT}" "udevd did not answer a ping" "noping: says so"
eq "${RC}" 0 "noping: canaries fine -> exit 0"

echo "6. a box with no canaries, and a lost coldplug on a big box"
W="${TMP}/bare"; mkdir -p "${W}/sys/class/net/lo" "${W}/state/db"; : > "${W}/state/calls"
run_guard "${W}"
eq "${RC}" 0 "no PCI, no NIC, no card: exit 0"
eq "$(ntrig "${W}")" 0 "no PCI, no NIC, no card: no re-trigger"
W="$(mk_world big node)"
for i in 10 11 12 13 14 15 16 17 18 19; do mkdir -p "${W}/sys/bus/pci/devices/0000:00:${i}.0"; done
run_guard "${W}"
has "${OUT}" "LOST coldplug: 14 canary device(s) never reached udevd:" "big box: counts every lost canary"
has "${OUT}" "+6 more ; re-triggering" "big box: names the first 8, then '+6 more'"
has "${OUT}" "pci/0000:00:14.0 +6 more" "big box: the 8th name is the last one printed"
lacks "${OUT}" "pci/0000:00:15.0" "big box: the 9th lost canary is counted, not named"
has "${OUT}" "+6 more (udev never applied" "big box: the FAIL line is bounded too"

echo "7. the service and the x86 build wiring"
svc="$(cat "${INITD}")"
has "${svc}" "need udev" "service: need udev"
has "${svc}" "after udev-trigger" "service: after udev-trigger"
has "${svc}" "/usr/libexec/udev-coldplug-guard" "service: runs the helper"
[ -x "${HELPER}" ] && _ok "helper is executable in the tree" || _bad "helper is not executable in the tree"
[ -x "${INITD}" ] && _ok "service is executable in the tree" || _bad "service is not executable in the tree"
sh -n "${HELPER}" && _ok "helper parses under sh" || _bad "helper does not parse under sh"
# Execute the build's own lines against a scratch sysroot.
SNIP="${TMP}/wiring.sh"
awk '/^# udev coldplug guard \(SYSINIT/{p=1} p{print} p && /^    \|\| warn /{exit}' "${BUILD}" > "${SNIP}"
if grep -q 'runlevels/sysinit/udev-coldplug-guard' "${SNIP}"; then
    SR="${TMP}/sysroot"; mkdir -p "${SR}/etc/runlevels/sysinit"
    ln -s /etc/init.d/udev-trigger "${SR}/etc/runlevels/sysinit/udev-trigger"
    WOUT="$(SYSROOT="${SR}" SHARED_SPECS="${ROOT}/specs" bash -c 'set -eu; warn(){ echo "WARN: $1"; }; source "$1"' _ "${SNIP}" 2>&1)"
    eq "$?" 0 "build wiring: runs clean"
    [ -x "${SR}/usr/libexec/udev-coldplug-guard" ] && _ok "build wiring: helper installed 0755" || _bad "build wiring: helper not installed"
    [ -x "${SR}/etc/init.d/udev-coldplug-guard" ] && _ok "build wiring: service installed 0755" || _bad "build wiring: service not installed"
    eq "$(readlink "${SR}/etc/runlevels/sysinit/udev-coldplug-guard" 2>/dev/null)" "/etc/init.d/udev-coldplug-guard" "build wiring: linked into runlevels/SYSINIT"
    [ -e "${SR}/etc/runlevels/default/udev-coldplug-guard" ] && _bad "build wiring: also linked into default" || _ok "build wiring: not in default (it must finish before NM/elogind/DM)"
    lacks "${WOUT}" "WARN" "build wiring: no warning when udev-trigger is in sysinit"
    rm -f "${SR}/etc/runlevels/sysinit/udev-trigger"
    WOUT="$(SYSROOT="${SR}" SHARED_SPECS="${ROOT}/specs" bash -c 'set -eu; warn(){ echo "WARN: $1"; }; source "$1"' _ "${SNIP}" 2>&1)"
    has "${WOUT}" "WARN: runlevels/sysinit has no udev-trigger link" "build wiring: warns when udev-trigger is not in sysinit"
else
    _bad "build wiring: the x86 build does not link udev-coldplug-guard into runlevels/sysinit"
fi

echo
echo "test-udev-coldplug-guard: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
