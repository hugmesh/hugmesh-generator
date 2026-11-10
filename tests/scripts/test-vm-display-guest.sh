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
#      is `~` (warn-only), so emerge goes green and the daemon ships inert. Those
#      fragments are guarded by tests/scripts/test-virtual-display-kernel.sh,
#      not here.
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

# The guest KERNEL side (virtio-gpu, virtio-input, uinput under INPUT_MISC, and
# VIRTIO_CONSOLE for the vdagent port) is owned and guarded by
# tests/scripts/test-virtual-display-kernel.sh across all five boards; only the
# one x86 line this suite's resize claim leans on is restated here.
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

# Fixture, shaped like the real tree (class/drm entries are SYMLINKS into
# devices/): <root>/devices/<bus>/DEV is the card's parent device, bound to
# $parent; when $child is not "-", DEV/virtio0 is a virtio child bound to $child;
# DEV/drm/card0/card0-<conn>/{status,modes}; class/drm/card0 and
# class/drm/card0-<conn> link into it, and card0/device links back to DEV.
#
# MEASURED on a built x86 image (kernel 6.18, -vga virtio; desktop-proof-20261109
# serial log): card0/device -> /sys/devices/pci0000:00/0000:00:03.0, whose driver
# is virtio-pci — the virtio_gpu-bound device is that function's virtioN child.
# This suite's earlier fixture put virtio_gpu on card0/device itself, a tree no
# measured guest has, so the hermetic test stayed green while the applier exited
# on every virtio-vga guest. Layouts used below:
#   virtio-pci + virtio_gpu   x86 virtio-vga / virtio-gpu-pci (the measured one)
#   virtio-mmio + virtio_gpu  an ARM `virt` board's virtio-gpu-device
#   virtio_gpu + -            the parent IS the virtio device (legacy layout)
#   qxl / i915 / bochs-drm + -  a PCI GPU driven directly
mk_sysfs(){ # root parent child conn status modes...
  local root="$1" parent="$2" child="$3" conn="$4" st="$5"; shift 5
  local bus="pci0000:00" dev="0000:00:03.0" pbus="pci"
  case "${parent}" in virtio-mmio) bus="platform"; dev="a003e00.virtio_mmio"; pbus="platform" ;; esac
  local D="${root}/devices/${bus}/${dev}"
  rm -rf "${root}"
  mkdir -p "${D}/drm/card0/card0-${conn}" "${root}/class/drm" "${root}/bus/${pbus}/drivers/${parent}"
  ln -s "../../../bus/${pbus}/drivers/${parent}" "${D}/driver"
  if [ "${child}" != "-" ]; then
    mkdir -p "${D}/virtio0" "${root}/bus/virtio/drivers/${child}"
    ln -s "../../../../bus/virtio/drivers/${child}" "${D}/virtio0/driver"
  fi
  ln -s "../../../${dev}" "${D}/drm/card0/device"
  ln -s "../../devices/${bus}/${dev}/drm/card0" "${root}/class/drm/card0"
  ln -s "../../devices/${bus}/${dev}/drm/card0/card0-${conn}" "${root}/class/drm/card0-${conn}"
  printf '%s\n' "${st}" > "${D}/drm/card0/card0-${conn}/status"
  printf '%s\n' "$@" > "${D}/drm/card0/card0-${conn}/modes"
}
modes_file(){ echo "$1/class/drm/card0-Virtual-1/modes"; }
# Stub xrandr, STATEFUL like the X server: logs every argv line; --query prints
# one connected output whose active (*) mode is the content of $STUB_CUR;
# `--output Virtual-1 --auto` switches $STUB_CUR to the first line of
# $STUB_MODES (the connector's preferred mode), unless $STUB_FAILS holds a
# positive count, which it decrements instead (a mode-set that did not take).
mk_xrandr(){ # path
  cat > "$1" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "${STUB_LOG}"
if [ "$1" = "--query" ]; then
  printf 'Screen 0: minimum 16 x 16, current 1280 x 720, maximum 8192 x 8192\n'
  printf 'Virtual-1 connected primary 1280x720+0+0 0mm x 0mm\n'
  printf '   %s      60.00*+\n' "$(cat "${STUB_CUR}")"
  printf '   640x480       60.00  \n'
  printf 'Virtual-2 disconnected\n'
elif [ "$*" = "--output Virtual-1 --auto" ]; then
  n="$(cat "${STUB_FAILS}" 2>/dev/null || echo 0)"
  if [ "${n:-0}" -gt 0 ]; then echo $((n-1)) > "${STUB_FAILS}"; else head -n 1 "${STUB_MODES}" > "${STUB_CUR}"; fi
fi
exit 0
STUB
  chmod +x "$1"
}

# run_autofit SUT parent child status current preferred [more modes...] -> prints log
run_autofit(){
  local sut="$1" parent="$2" child="$3" st="$4" cur="$5"; shift 5
  local root="${T}/sysfs" log="${T}/xr.log"
  mk_sysfs "${root}" "${parent}" "${child}" Virtual-1 "${st}" "$@"
  : > "${log}"; mk_xrandr "${T}/xrandr"; echo "${cur}" > "${T}/cur"; echo 0 > "${T}/fails"
  STUB_LOG="${log}" STUB_CUR="${T}/cur" STUB_FAILS="${T}/fails" STUB_MODES="$(modes_file "${root}")" \
  VM_AUTOFIT_SYSFS="${root}" VM_AUTOFIT_XRANDR="${T}/xrandr" VM_AUTOFIT_ONCE=1 \
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
  log="$(run_autofit "$sut" virtio-pci virtio_gpu connected 1280x720 1280x720 1024x768)"
  [ "$(last_rc)" -eq 0 ] && [ "$(printf '%s\n' "$log" | count_apply)" -eq 0 ] || { echo "    case1: preferred==current must not call xrandr --auto (rc=$(last_rc) log=[$log])"; fails=$((fails+1)); }
  log="$(run_autofit "$sut" virtio-pci virtio_gpu connected 1280x720 1920x1080 1280x720)"
  [ "$(last_rc)" -eq 0 ] && [ "$(printf '%s\n' "$log" | count_apply)" -eq 1 ] || { echo "    case2: virtio-vga as MEASURED on 6.18 (card0/device = PCI fn bound to virtio-pci, its virtio0 child bound to virtio_gpu): a new preferred mode must call xrandr --output Virtual-1 --auto exactly once (rc=$(last_rc) log=[$log])"; fails=$((fails+1)); }
  log="$(run_autofit "$sut" qxl - connected 800x600 1600x900 800x600)"
  [ "$(last_rc)" -eq 0 ] && [ "$(printf '%s\n' "$log" | count_apply)" -eq 1 ] || { echo "    case3: qxl is a resize-capable driver too (rc=$(last_rc) log=[$log])"; fails=$((fails+1)); }
  log="$(run_autofit "$sut" i915 - connected 1280x720 1920x1080 1280x720)"
  [ "$(last_rc)" -eq 0 ] && [ -z "$log" ] || { echo "    case4: real hardware (i915) must exit 0 before touching xrandr at all (rc=$(last_rc) log=[$log])"; fails=$((fails+1)); }
  log="$(run_autofit "$sut" virtio-pci virtio_gpu disconnected 1280x720 1920x1080 1280x720)"
  [ "$(last_rc)" -eq 0 ] && [ "$(printf '%s\n' "$log" | count_apply)" -eq 0 ] || { echo "    case5: a disconnected connector is never applied (rc=$(last_rc) log=[$log])"; fails=$((fails+1)); }
  log="$(run_autofit "$sut" virtio_gpu - connected 1280x720 1920x1080 1280x720)"
  [ "$(last_rc)" -eq 0 ] && [ "$(printf '%s\n' "$log" | count_apply)" -eq 1 ] || { echo "    case6: legacy layout (card0/device itself bound to virtio_gpu) still matches (rc=$(last_rc) log=[$log])"; fails=$((fails+1)); }
  log="$(run_autofit "$sut" virtio-mmio virtio_gpu connected 1280x720 1920x1080 1280x720)"
  [ "$(last_rc)" -eq 0 ] && [ "$(printf '%s\n' "$log" | count_apply)" -eq 1 ] || { echo "    case7: virtio-gpu-device on virtio-mmio (ARM virt) matches through its virtio child (rc=$(last_rc) log=[$log])"; fails=$((fails+1)); }
  log="$(run_autofit "$sut" bochs-drm - connected 1280x720 1920x1080 1280x720)"
  [ "$(last_rc)" -eq 0 ] && [ -z "$log" ] || { echo "    case8: bochs (-vga std) exposes Virtual-1 but cannot resize: must exit before xrandr (rc=$(last_rc) log=[$log])"; fails=$((fails+1)); }
  log="$(run_autofit "$sut" virtio-pci virtio_net connected 1280x720 1920x1080 1280x720)"
  [ "$(last_rc)" -eq 0 ] && [ -z "$log" ] || { echo "    case9: a virtio child bound to anything but virtio_gpu is not a GPU (rc=$(last_rc) log=[$log])"; fails=$((fails+1)); }
  return $fails
}

if battery "${AUTOFIT}"; then ok "vm-autofit: all nine one-pass cases hold (measured 6.18 virtio-vga layout, mmio, legacy, qxl; i915/bochs/non-gpu virtio refused)"; else bad "vm-autofit: one-pass battery broken (see above)"; fi

# loop_run SUT fails-before-success seconds-after-change -> number of --auto calls
# after the preferred mode changes in a RUNNING applier (measured 6.18 layout).
# Also leaves the stub's final current mode in ${T}/cur.
loop_run(){
  local sut="$1" nfail="$2" wait_after="$3" root="${T}/sysfs-loop" log="${T}/xr-loop.log" pid
  mk_sysfs "${root}" virtio-pci virtio_gpu Virtual-1 connected 1280x720 1024x768
  : > "${log}"; mk_xrandr "${T}/xrandr"; echo 1280x720 > "${T}/cur"; echo "${nfail}" > "${T}/fails"
  STUB_LOG="${log}" STUB_CUR="${T}/cur" STUB_FAILS="${T}/fails" STUB_MODES="$(modes_file "${root}")" \
  VM_AUTOFIT_SYSFS="${root}" VM_AUTOFIT_XRANDR="${T}/xrandr" VM_AUTOFIT_INTERVAL=0.2 DISPLAY=:9 \
    sh "${sut}" >/dev/null 2>&1 &
  pid=$!
  sleep 1
  printf '%s\n' 1920x1080 1280x720 > "$(modes_file "${root}")"
  sleep "${wait_after}"
  kill "${pid}" 2>/dev/null; wait "${pid}" 2>/dev/null
  count_apply < "${log}"
}
# The loop battery, replayed against mutants in section D.
loop_battery(){ # SUT
  local sut="$1" fails=0 n
  n="$(loop_run "$sut" 0 2)"
  [ "$n" -eq 1 ] && [ "$(cat "${T}/cur")" = 1920x1080 ] || { echo "    loop1: a later preferred-mode change must be applied exactly once (applies=$n current=$(cat "${T}/cur"))"; fails=$((fails+1)); }
  n="$(loop_run "$sut" 1 2)"
  [ "$n" -eq 2 ] && [ "$(cat "${T}/cur")" = 1920x1080 ] || { echo "    loop2: a mode-set that did not take must be retried on the next poll (applies=$n, want 2; current=$(cat "${T}/cur"))"; fails=$((fails+1)); }
  n="$(loop_run "$sut" 99 3)"
  [ "$n" -eq 3 ] || { echo "    loop3: a mode the server never takes is tried at most 3 times per change, not every poll (applies=$n)"; fails=$((fails+1)); }
  return $fails
}
if loop_battery "${AUTOFIT}"; then ok "vm-autofit loop: a later change is applied once, a failed mode-set is retried, retries are bounded at 3"; else bad "vm-autofit loop battery broken (see above)"; fi

# No DISPLAY and not ONCE: must exit at once even on a virtual GPU (nothing to drive).
# Exit is observed through a marker the SUT's own parent writes after `wait`,
# NOT `kill -0 <pid>`: in a CI job container PID 1 is `tail -f /dev/null`, which
# never reaps, so an orphaned SUT that exited stays a zombie and `kill -0` on it
# SUCCEEDS (measured in alpine:3 — this check read "keeps running" for a script
# that had exited). Polls up to 5 s, then kills the loop it started. The fixture
# is the MEASURED layout, so the DISPLAY guard is what stops it — not a card
# detection that never matched (which is how this check stayed green before).
no_display_exits(){ # SUT -> 0 when it exits by itself with rc 0
  local sut="$1" i=0 root="${T}/sysfs-nd"
  mk_sysfs "${root}" virtio-pci virtio_gpu Virtual-1 connected 1280x720
  rm -f "${T}/nd.exited" "${T}/nd.pid"
  ( env -u DISPLAY VM_AUTOFIT_SYSFS="${root}" VM_AUTOFIT_XRANDR="${T}/xrandr" VM_AUTOFIT_INTERVAL=1 STUB_LOG="${T}/nd.log" \
      STUB_CUR="${T}/nd.cur" STUB_FAILS="${T}/nd.fails" STUB_MODES="$(modes_file "${root}")" \
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
try_mut "DISPLAY guard removed (loops with no X server)"  "$AUTOFIT" '/^\[ -n "${DISPLAY:-}" \] ||/d'                  no_display_exits
try_mut "virtio child walk removed (the pre-fix detection: exits on 6.18 virtio-vga)" "$AUTOFIT" 's/\[ "${vdrv##\*\/}" = "virtio_gpu" \] \&\& return 0/:/' battery
try_mut "any virtio child accepted as a GPU"               "$AUTOFIT" 's/\[ "${vdrv##\*\/}" = "virtio_gpu" \] \&\& return 0/return 0/' battery
try_mut "post-apply re-check removed (no retry)"           "$AUTOFIT" '/^    \[ "$(current_mode "${out}")" = "${mode}" \]$/d'           loop_battery
try_mut "retry bound removed (xrandr every poll)"          "$AUTOFIT" 's/ || \[ "${tries}" -ge "${MAX_TRIES}" \]//'                 loop_battery
try_mut "starter: char-device gate removed"                "$STARTER" 's/^\[ -c "${PORT}" \] ||/true ||/'                        starter_battery
try_mut "starter: starts nothing"                          "$STARTER" 's/^rc-service --ifnotstarted spice-vdagent start$/:/'    starter_battery
echo "  mutations: ${caught} caught / ${survived} survived"

echo
echo "${P} passed, ${F} failed"
[ "${F}" -eq 0 ]
