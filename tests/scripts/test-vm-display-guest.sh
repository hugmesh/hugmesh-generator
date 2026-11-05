#!/usr/bin/env bash
# test-vm-display-guest.sh — the guest half of "open an emulated desktop image in
# a window that resizes the guest" (operator requirement 2026-11-04).
#
# The host half (tests/qemu/run-qemu-docker.sh --open-display, the SPICE door on
# 127.0.0.1 with a per-run secret) can only re-lay-out the desktop if the GUEST
# carries three things, and each of them fails SILENTLY when missing:
#
#   1. app-emulation/spice-vdagent + sec-policy/selinux-vdagent in every desktop
#      package list (five boards). The ARM boards need a ~arm64 keyword for
#      vdagent, and must NOT keyword the policy module: the stable module
#      satisfies ">=selinux-base-policy-2.20260616_p1", while a ~arm64 line would
#      pick 2.20260922_p1 and demand a base-policy that frite/orangepi do not
#      accept — a wall hours into a build. (NEGATIVE control below.)
#   2. the kernel channel: VIRTIO_CONSOLE (/dev/virtio-ports/com.redhat.spice.0)
#      and INPUT_UINPUT under INPUT_MISC (/dev/uinput). The ebuild's CONFIG_CHECK
#      is `~` (warn-only), so emerge goes green and the daemon ships inert.
#   3. the session-side applier specs/usr/libexec/hugmesh/vm-autofit and its
#      xdg autostart entry, plus the conditional spice-vdagentd starter in
#      local.d — COPIED by each desktop builder (nothing copies specs/ wholesale,
#      so an overlay file without its cp line is dead), and never enabled
#      unconditionally in a runlevel (the stock init script returns 1 on every
#      physical boot and every non-display QEMU run).
#
# Sections B and C EXECUTE the two sh scripts for real against a fixture sysfs
# and PATH stubs, and section D re-runs those cases against planted defects in
# copies of the SUT (a mutation battery) so "it passes" cannot mean "it asserts
# nothing". Pure static + fixture checks: no emerge, no QEMU, no root, no network.
#
#   bash tests/scripts/test-vm-display-guest.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
cd "${REPO}"

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

AUTOFIT="specs/usr/libexec/hugmesh/vm-autofit"
AUTOSTART="specs/etc/xdg/autostart/hugmesh-vm-autofit.desktop"
STARTER="specs/etc/local.d/20-spice-vdagent.start"
LISTS=(
  specs-x86/portage/packages-desktop.list
  specs-rpi5/portage/packages-desktop.list
  specs-frite/portage/packages-light-desktop.list
  specs-orangepi5/portage/packages-desktop.list
  specs-orangepi4-lts/portage/packages-desktop.list
)
ARM_KW=(
  specs-rpi5/portage/package.accept_keywords/rpi
  specs-frite/portage/package.accept_keywords/frite
  specs-orangepi5/portage/package.accept_keywords/orangepi5
  specs-orangepi4-lts/portage/package.accept_keywords/orangepi4-lts
)
BUILDERS=(
  build-x86-host-stage4.sh
  build-rpi5-stage4.sh
  build-frite-stage4.sh
  build-orangepi5-stage4.sh
  build-orangepi4-lts-stage4.sh
)

# Full-line comments dropped, then an anchored match. Drains the pipe so a found
# match never reports failure under pipefail (the `| grep -q` trap).
has_line(){ # file ERE
  local n
  n="$(grep -vE '^[[:space:]]*#' "$1" | grep -cE "$2")" || true
  [ "${n:-0}" -gt 0 ]
}

T="$(mktemp -d "${TMPDIR:-/tmp}/vm-display-guest.XXXXXX")"
trap 'rm -rf "${T}"' EXIT

echo "== A) static: packages, keywords, kernel, overlay wiring =="

for l in "${LISTS[@]}"; do
  has_line "$l" '^app-emulation/spice-vdagent$' && ok "$l requests app-emulation/spice-vdagent" || bad "$l lacks app-emulation/spice-vdagent"
  has_line "$l" '^sec-policy/selinux-vdagent$' && ok "$l requests sec-policy/selinux-vdagent (completeness gate sees it)" || bad "$l lacks sec-policy/selinux-vdagent"
done

for k in "${ARM_KW[@]}"; do
  has_line "$k" '^app-emulation/spice-vdagent[[:space:]]+~arm64$' && ok "$k accepts spice-vdagent ~arm64" || bad "$k does not accept spice-vdagent ~arm64"
done
# NEGATIVE: no board may keyword the policy module (see header, item 1).
kw_hits="$(grep -rlE '^[[:space:]]*sec-policy/selinux-vdagent' specs-*/portage/package.accept_keywords/ 2>/dev/null | wc -l)"
[ "${kw_hits}" -eq 0 ] && ok "no board keywords sec-policy/selinux-vdagent (stable module stays stable)" || bad "sec-policy/selinux-vdagent is keyworded in ${kw_hits} file(s) — the ~ module demands a base-policy frite/orangepi do not accept"
# The claim the negative rests on: the stable module version exists for arm64 in
# the tree this host carries (skipped, not passed, when no tree is mounted).
if ls /var/db/repos/gentoo/sec-policy/selinux-vdagent/*.ebuild >/dev/null 2>&1; then
  if grep -lE 'KEYWORDS=.*[^~]arm64' /var/db/repos/gentoo/sec-policy/selinux-vdagent/selinux-vdagent-2.*.ebuild >/dev/null 2>&1; then
    ok "tree: a stable-arm64 sec-policy/selinux-vdagent exists (the no-keyword rule holds)"
  else
    bad "tree: NO stable-arm64 sec-policy/selinux-vdagent — the ARM boards now need a keyword after all"
  fi
else
  echo "  SKIP tree check (no /var/db/repos/gentoo on this host)"
fi

KCFG=specs-x86/kernel/desktop.config
for sym in CONFIG_VIRTIO_CONSOLE CONFIG_INPUT_MISC CONFIG_INPUT_UINPUT; do
  has_line "$KCFG" "^enable ${sym}$" && ok "$KCFG enables ${sym}" || bad "$KCFG does not enable ${sym}"
done
has_line specs-x86/kernel/hardened-k8s.config '^enable CONFIG_DRM_VIRTIO_GPU$' && ok "x86 base fragment keeps CONFIG_DRM_VIRTIO_GPU (the resizable display)" || bad "x86 base fragment lost CONFIG_DRM_VIRTIO_GPU"

for f in "$AUTOFIT" "$STARTER"; do
  [ -x "$f" ] && ok "$f is executable" || bad "$f missing or not executable"
  [ "$(head -n1 "$f")" = "#!/bin/sh" ] && ok "$f is #!/bin/sh" || bad "$f is not #!/bin/sh"
  sh -n "$f" && ok "$f parses under sh" || bad "$f does not parse under sh"
done
[ -f "$AUTOSTART" ] && ok "$AUTOSTART exists" || bad "$AUTOSTART missing"
grep -qxF "Exec=/${AUTOFIT#specs/}" "$AUTOSTART" && ok "autostart Exec points at /${AUTOFIT#specs/}" || bad "autostart Exec does not point at /${AUTOFIT#specs/}"
grep -qE '^OnlyShowIn=' "$AUTOSTART" && bad "autostart carries OnlyShowIn (lxsession/xfce/plasma must all honour it)" || ok "autostart has no OnlyShowIn"
grep -qE '^NoDisplay=true$' "$AUTOSTART" && ok "autostart is NoDisplay" || bad "autostart is not NoDisplay"

for b in "${BUILDERS[@]}"; do
  has_line "$b" 'SHARED_SPECS\}/usr/libexec/hugmesh/vm-autofit"' && ok "$b copies vm-autofit" || bad "$b does not copy vm-autofit"
  has_line "$b" 'SHARED_SPECS\}/etc/xdg/autostart/hugmesh-vm-autofit\.desktop"' && ok "$b copies the autostart entry" || bad "$b does not copy the autostart entry"
  has_line "$b" 'SHARED_SPECS\}/etc/local\.d/20-spice-vdagent\.start"' && ok "$b copies the vdagentd starter" || bad "$b does not copy the vdagentd starter"
  has_line "$b" 'chmod 0755 .*vm-autofit.*20-spice-vdagent\.start' && ok "$b marks both scripts executable" || bad "$b does not chmod both scripts"
  # NEGATIVE: the stock service must never be enabled unconditionally.
  if grep -vE '^[[:space:]]*#' "$b" | grep -E 'SVCS\+?=\(.*[[:space:](]spice-vdagent[[:space:])]|rc-update add spice-vdagent|runlevels/[a-z]+/spice-vdagent' >/dev/null; then
    bad "$b enables spice-vdagent unconditionally (red failed service on every physical boot)"
  else
    ok "$b leaves spice-vdagent out of the runlevel (the local.d starter gates it)"
  fi
done

echo "== B) behaviour: vm-autofit against a fixture sysfs + stub xrandr =="

# Fixture: <root>/class/drm/card0 (driver symlink -> a dir named after the driver),
# card0-<conn>/{status,modes}. For virtio-gpu card0/device is the virtio device
# (driver virtio_gpu); for qxl it is the PCI device (driver qxl).
mk_sysfs(){ # root driver conn status modes...
  local root="$1" drv="$2" conn="$3" st="$4"; shift 4
  rm -rf "${root}"; mkdir -p "${root}/class/drm/card0/device" "${root}/bus/x/drivers/${drv}" "${root}/class/drm/card0-${conn}"
  ln -s "../../../../bus/x/drivers/${drv}" "${root}/class/drm/card0/device/driver"
  printf '%s\n' "${st}" > "${root}/class/drm/card0-${conn}/status"
  printf '%s\n' "$@" > "${root}/class/drm/card0-${conn}/modes"
}
# Stub xrandr: logs every argv line; --query prints one connected output whose
# active (*) mode is $STUB_CURRENT.
mk_xrandr(){ # path
  cat > "$1" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "${STUB_LOG}"
if [ "$1" = "--query" ]; then
  printf 'Screen 0: minimum 16 x 16, current 1280 x 720, maximum 8192 x 8192\n'
  printf 'Virtual-1 connected primary 1280x720+0+0 0mm x 0mm\n'
  printf '   %s      60.00*+\n' "${STUB_CURRENT}"
  printf '   640x480       60.00  \n'
  printf 'Virtual-2 disconnected\n'
fi
exit 0
STUB
  chmod +x "$1"
}

# run_autofit SUT driver status current preferred [more modes...] -> prints log
run_autofit(){
  local sut="$1" drv="$2" st="$3" cur="$4"; shift 4
  local root="${T}/sysfs" log="${T}/xr.log"
  mk_sysfs "${root}" "${drv}" Virtual-1 "${st}" "$@"
  : > "${log}"; mk_xrandr "${T}/xrandr"
  STUB_LOG="${log}" STUB_CURRENT="${cur}" VM_AUTOFIT_SYSFS="${root}" VM_AUTOFIT_XRANDR="${T}/xrandr" VM_AUTOFIT_ONCE=1 \
    sh "${sut}" >/dev/null 2>&1
  echo $? > "${T}/rc"
  cat "${log}"
}
# run_* run inside $(...), so the exit code travels through a file, not a variable.
last_rc(){ cat "${T}/rc"; }
count_apply(){ grep -c -- '^--output Virtual-1 --auto$' || true; }

# The battery, as a function so section D can replay it against mutants.
# Prints one FAIL line per broken case to stdout; returns the count.
battery(){ # SUT
  local sut="$1" fails=0 log
  log="$(run_autofit "$sut" virtio_gpu connected 1280x720 1280x720 1024x768)"
  [ "$(last_rc)" -eq 0 ] && [ "$(printf '%s\n' "$log" | count_apply)" -eq 0 ] || { echo "    case1: preferred==current must not call xrandr --auto (rc=$(last_rc) log=[$log])"; fails=$((fails+1)); }
  log="$(run_autofit "$sut" virtio_gpu connected 1280x720 1920x1080 1280x720)"
  [ "$(last_rc)" -eq 0 ] && [ "$(printf '%s\n' "$log" | count_apply)" -eq 1 ] || { echo "    case2: new preferred mode must call xrandr --output Virtual-1 --auto exactly once (rc=$(last_rc) log=[$log])"; fails=$((fails+1)); }
  log="$(run_autofit "$sut" qxl connected 800x600 1600x900 800x600)"
  [ "$(last_rc)" -eq 0 ] && [ "$(printf '%s\n' "$log" | count_apply)" -eq 1 ] || { echo "    case3: qxl is a resize-capable driver too (rc=$(last_rc) log=[$log])"; fails=$((fails+1)); }
  log="$(run_autofit "$sut" i915 connected 1280x720 1920x1080 1280x720)"
  [ "$(last_rc)" -eq 0 ] && [ -z "$log" ] || { echo "    case4: real hardware (i915) must exit 0 before touching xrandr at all (rc=$(last_rc) log=[$log])"; fails=$((fails+1)); }
  log="$(run_autofit "$sut" virtio_gpu disconnected 1280x720 1920x1080 1280x720)"
  [ "$(last_rc)" -eq 0 ] && [ "$(printf '%s\n' "$log" | count_apply)" -eq 0 ] || { echo "    case5: a disconnected connector is never applied (rc=$(last_rc) log=[$log])"; fails=$((fails+1)); }
  return $fails
}

if battery "${AUTOFIT}"; then ok "vm-autofit: all five one-pass cases hold"; else bad "vm-autofit: one-pass battery broken (see above)"; fi

# Loop case: a preferred-mode change AFTER start must be applied on the next poll.
root="${T}/sysfs"; log="${T}/xr.log"
mk_sysfs "${root}" virtio_gpu Virtual-1 connected 1280x720 1024x768
: > "${log}"; mk_xrandr "${T}/xrandr"
STUB_LOG="${log}" STUB_CURRENT=1280x720 VM_AUTOFIT_SYSFS="${root}" VM_AUTOFIT_XRANDR="${T}/xrandr" VM_AUTOFIT_INTERVAL=1 DISPLAY=:9 \
  sh "${AUTOFIT}" >/dev/null 2>&1 &
loop_pid=$!
sleep 2
printf '%s\n' 1920x1080 1280x720 > "${root}/class/drm/card0-Virtual-1/modes"
sleep 3
kill "${loop_pid}" 2>/dev/null; wait "${loop_pid}" 2>/dev/null
n="$(count_apply < "${log}")"
[ "${n}" -eq 1 ] && ok "vm-autofit loop: a later preferred-mode change is applied exactly once" || bad "vm-autofit loop: expected 1 apply after the change, saw ${n}"

# No DISPLAY and not ONCE: must exit at once even on a virtual GPU (nothing to drive).
# Exit is observed through a marker the SUT's own parent writes after `wait`,
# NOT `kill -0 <pid>`: in a CI job container PID 1 is `tail -f /dev/null`, which
# never reaps, so an orphaned SUT that exited stays a zombie and `kill -0` on it
# SUCCEEDS (measured in alpine:3 — this check read "keeps running" for a script
# that had exited). Polls up to 5 s, then kills the loop it started.
no_display_exits(){ # SUT -> 0 when it exits by itself with rc 0
  local sut="$1" i=0 root="${T}/sysfs-nd"
  mk_sysfs "${root}" virtio_gpu Virtual-1 connected 1280x720
  rm -f "${T}/nd.exited" "${T}/nd.pid"
  ( env -u DISPLAY VM_AUTOFIT_SYSFS="${root}" VM_AUTOFIT_XRANDR="${T}/xrandr" VM_AUTOFIT_INTERVAL=1 STUB_LOG="${T}/nd.log" \
      sh "${sut}" >/dev/null 2>&1 &
    echo $! > "${T}/nd.pid"; wait $!; echo $? > "${T}/nd.exited" ) &
  local sub=$!
  while [ ! -s "${T}/nd.exited" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i+1)); done
  if [ -s "${T}/nd.exited" ]; then
    wait "$sub" 2>/dev/null
    [ "$(cat "${T}/nd.exited")" -eq 0 ] || { echo "    no DISPLAY: exited rc=$(cat "${T}/nd.exited"), expected 0"; return 1; }
    return 0
  fi
  echo "    no DISPLAY: still running after 5 s (a polling loop with no X server to drive)"
  kill "$(cat "${T}/nd.pid")" 2>/dev/null; wait "$sub" 2>/dev/null
  return 1
}
if no_display_exits "${AUTOFIT}"; then ok "vm-autofit without DISPLAY exits 0"; else bad "vm-autofit without DISPLAY keeps running (see above)"; fi

echo "== C) behaviour: the local.d starter only inside a SPICE VM =="
mkdir -p "${T}/bin"; cat > "${T}/bin/rc-service" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "${STUB_LOG}"
STUB
chmod +x "${T}/bin/rc-service"; touch "${T}/initd"
run_starter(){ # SUT port
  : > "${T}/rc.log"
  STUB_LOG="${T}/rc.log" SPICE_VDAGENT_PORT="$2" SPICE_VDAGENT_INITD="${T}/initd" PATH="${T}/bin:${PATH}" sh "$1" >/dev/null 2>&1
  echo $? > "${T}/rc"; cat "${T}/rc.log"
}
starter_battery(){ # SUT
  local sut="$1" fails=0 out
  out="$(run_starter "$sut" "${T}/no-such-port")"
  [ "$(last_rc)" -eq 0 ] && [ -z "$out" ] || { echo "    no port: must exit 0 without calling rc-service (rc=$(last_rc) out=[$out])"; fails=$((fails+1)); }
  out="$(run_starter "$sut" "${T}/initd")"   # a regular file is not a char device
  [ "$(last_rc)" -eq 0 ] && [ -z "$out" ] || { echo "    regular file as port: must not start (rc=$(last_rc) out=[$out])"; fails=$((fails+1)); }
  out="$(run_starter "$sut" /dev/null)"      # a char device stands in for the virtio port
  [ "$(last_rc)" -eq 0 ] && [ "$out" = "--ifnotstarted spice-vdagent start" ] || { echo "    char device port: must start spice-vdagent once (rc=$(last_rc) out=[$out])"; fails=$((fails+1)); }
  return $fails
}
if starter_battery "${STARTER}"; then ok "starter: no port -> no-op, char device -> rc-service --ifnotstarted spice-vdagent start"; else bad "starter battery broken (see above)"; fi

echo "== D) mutation battery: each planted defect must be caught =="
mutate(){ # src dst sed-expr
  sed -e "$3" "$1" > "$2"; chmod +x "$2"
  if cmp -s "$1" "$2"; then echo "    mutation did not change the file: $3"; return 1; fi
}
caught=0; survived=0
try_mut(){ # label src sed-expr battery-fn
  local m="${T}/mut.sh"
  if ! mutate "$2" "$m" "$3"; then bad "mutation '$1' is a no-op (pattern drifted)"; return; fi
  if "$4" "$m" >/dev/null; then survived=$((survived+1)); bad "mutation SURVIVED: $1"; else caught=$((caught+1)); ok "mutation caught: $1"; fi
}
try_mut "driver gate removed (runs on real hardware)"      "$AUTOFIT" 's/virtio_gpu|qxl)/*)/'                                   battery
try_mut "qxl no longer matched"                            "$AUTOFIT" 's/virtio_gpu|qxl)/virtio_gpu)/'                          battery
try_mut "current-mode skip removed (racing mode-sets)"     "$AUTOFIT" 's/\[ "$(current_mode "${out}")" = "${mode}" \] \&\& return 0/:/' battery
try_mut "connected check removed"                          "$AUTOFIT" 's/= "connected" \] || continue/= "nonsense" ] || :/'      battery
try_mut "--auto dropped from the xrandr call"              "$AUTOFIT" 's/--output "${out}" --auto/--output "${out}"/'            battery
try_mut "DISPLAY guard removed (loops with no X server)"  "$AUTOFIT" 's/^\[ -n "${DISPLAY:-}" \] || \[ -n "${ONCE}" \] || exit 0$/:/' no_display_exits
try_mut "starter: char-device gate removed"                "$STARTER" 's/^\[ -c "${PORT}" \] ||/true ||/'                        starter_battery
try_mut "starter: starts nothing"                          "$STARTER" 's/^rc-service --ifnotstarted spice-vdagent start$/:/'    starter_battery
echo "  mutations: ${caught} caught / ${survived} survived"

echo
echo "${P} passed, ${F} failed"
[ "${F}" -eq 0 ]
