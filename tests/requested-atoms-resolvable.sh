#!/usr/bin/env bash
# requested-atoms-resolvable.sh — a GLOBAL USE mask in a platform spec must never
# silently make a REQUESTED atom unresolvable.
#
# The incident this pins: the 2026-07-30 21:04 mesh build died on all three rpi5
# roles at hour N of a real build —
#   emerge: there are no ebuilds built with USE flags to satisfy
#   ">=dev-libs/glib-2.82.0:2[introspection]" for /out/wl-pki.rpi5/sysroot/.
# because specs-rpi5/portage/make.conf.tmpl's global USE="-introspection"
# (added for a real cross-compile failure, see that file) contradicted a hard
# dependency chain of a REQUESTED atom:
#   net-firewall/firewalld -> dev-python/pygobject:3
#     -> dev-libs/gobject-introspection -> dev-libs/glib[introspection]
# The requested-atom completeness gate then (correctly) refused the images —
# but only AFTER hours of compile. This gate moves that discovery to gate time.
# The fix is the scoped specs-rpi5/portage/package.use/firewalld-introspection
# override; this test fails the moment the override is dropped while the wall
# stands, on ANY platform that requests the atom (the table is walked against
# all ten specs, so a future platform adding firewalld under -introspection
# fails here too).
#
# WHY STATIC, not host-side resolution (the design call, made explicitly): a
# REAL resolution proof needs app-portage tooling on the gate host, the same
# /var/db/repos/gentoo snapshot the builders bind-mount, and minutes of
# fresh-root depgraph CPU per platform — the CI verify jobs run in python:3
# containers with none of those, and this gate must be cheap enough to run on
# every branch. So gate time proves a CURATED chain table statically (packages
# lists x known hard USE-dep chains x package.use overrides), and the deep
# proof — real `emerge --pretend` closure on the actual failed sysroots,
# baseline error verbatim + fixed rc=0 with zero new walls — is recorded in the
# fix branch's FINDINGS.md (fix/arm-firewalld-installable). The price of
# static: only KNOWN chains are caught. Grow CHAINS below with each incident;
# the completeness gate (scripts/_payload-gate-lib.sh) remains the runtime
# backstop for the unknown ones.
#
# Pure static text checks. No emerge, no chroot, no network, no root.
#
#   bash tests/requested-atoms-resolvable.sh   # or via: make matrix-check
#   (wired as the RAR bucket of tests/build-matrix/check.sh)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

# Every platform spec dir (specs/ itself is the shared rootfs overlay, not a
# platform). Keep in lockstep with the builder set in tests/build-arm-payload-gates.sh.
PLATFORMS=(rpi5 frite jetson orangepi-zero2 orangepi-zero2w orangepi-zero3
           orangepi3-lts orangepi4-lts orangepi5 x86)

# The curated hard-chain table: requested-atom|prerequisite-pkg|prerequisite-flag|chain.
# An entry means: "REQUESTED-ATOM is unresolvable unless PREREQUISITE-PKG has
# PREREQUISITE-FLAG enabled" — an unconditional USE dep somewhere in the atom's
# dependency chain, verified against the real tree when the entry was added.
CHAINS=(
  "net-firewall/firewalld|dev-libs/glib|introspection|firewalld -> pygobject:3 -> gobject-introspection -> glib[introspection] (unconditional at EVERY firewalld version in the tree — it is a python daemon)"
)

# Final state of <flag> across a spec's accumulated global USE= lines
# (make.conf.tmpl appends via USE="${USE} ...", last token wins; @@TOKENS@@ are
# build-time role extras and never carry the flags in CHAINS). Echoes +, - or "".
global_flag_state() { # <specdir> <flag>
  local mk="$1/portage/make.conf.tmpl" state="" tok
  [ -f "${mk}" ] || { echo "MISSING"; return 0; }
  while read -r tok; do
    case "${tok}" in
      "$2")  state="+" ;;
      "-$2") state="-" ;;
    esac
  done < <(grep -E '^[[:space:]]*USE=' "${mk}" | tr '"' ' ' | tr ' ' '\n')
  echo "${state}"
}

# Is <atom> requested by any of the spec's packages*.list?
is_requested() { # <specdir> <atom>
  local f
  for f in "$1"/portage/packages*.list; do
    [ -f "${f}" ] || continue
    grep -qE "^[[:space:]]*$2[[:space:]]*$" "${f}" && return 0
  done
  return 1
}

# Final state of <flag> for <pkg> across the spec's package.use (portage reads
# the dir's files in sorted order; later files and later tokens win). Echoes
# "+ <file>", "- <file>" or "".
pkguse_flag_state() { # <specdir> <pkg> <flag>
  local pu="$1/portage/package.use" state="" statefile="" f line tok first
  local files=()
  if [ -d "${pu}" ]; then
    while IFS= read -r f; do files+=("${f}"); done < <(find "${pu}" -maxdepth 1 -type f | sort)
  elif [ -f "${pu}" ]; then
    files=("${pu}")
  fi
  for f in "${files[@]}"; do
    while IFS= read -r line; do
      line="${line%%#*}"
      [ -z "${line//[[:space:]]/}" ] && continue
      read -r first _ <<<"${line}"
      # normalize the atom: strip version operators, any -<version> tail, any :slot
      first="${first#"${first%%[!<>=~]*}"}"   # leading < > = ~
      first="${first%%:*}"
      first="$(echo "${first}" | sed -E 's/-[0-9][0-9a-z._-]*(\*)?$//')"
      [ "${first}" = "$2" ] || continue
      for tok in ${line#* }; do
        case "${tok}" in
          "$3")  state="+"; statefile="${f##*/}" ;;
          "-$3") state="-"; statefile="${f##*/}" ;;
        esac
      done
    done < "${f}"
  done
  [ -n "${state}" ] && echo "${state} ${statefile}" || echo ""
}

echo "== requested-atoms-resolvable (global USE mask vs requested-atom hard chains) =="

echo "-- A) chain table x every platform --"
for plat in "${PLATFORMS[@]}"; do
  sd="${REPO}/specs-${plat}"
  for entry in "${CHAINS[@]}"; do
    IFS='|' read -r atom pkg flag chain <<<"${entry}"
    gstate="$(global_flag_state "${sd}" "${flag}")"
    if [ "${gstate}" = "MISSING" ]; then
      bad "[${plat}] specs-${plat}/portage/make.conf.tmpl MISSING — cannot prove ${atom} resolvable"
      continue
    fi
    if ! is_requested "${sd}" "${atom}"; then
      ok "[${plat}] ${atom} not requested — chain N/A"
      continue
    fi
    if [ "${gstate}" != "-" ]; then
      ok "[${plat}] ${atom} requested; no global -${flag} wall in make.conf.tmpl"
      continue
    fi
    pstate="$(pkguse_flag_state "${sd}" "${pkg}" "${flag}")"
    case "${pstate}" in
      "+ "*)
        ok "[${plat}] ${atom} requested + global -${flag} wall + scoped '${pkg} ${flag}' override present (package.use/${pstate#+ })" ;;
      *)
        bad "[${plat}] requested atom ${atom} is UNRESOLVABLE: global USE=-${flag} (make.conf.tmpl) with no scoped package.use '${pkg} ${flag}' override — chain: ${chain}. Either restore the scoped override or make a LOUD per-platform exclusion (drop the atom from the list AND update this gate — paper trail required, never a silent skip)." ;;
    esac
  done
done

echo "-- B) the live instance is pinned (rpi5 firewalld: DELIBERATE EXCLUSION) --"
# HISTORY: candidate A (scoped glib[introspection] override) resolved the graph
# but the 2026-08-05 real resume build died in glib-2.88.2 src_configure's
# in-source gobject-introspection bootstrap (ninja) — the bc87d1e cross failure,
# still live. The honest state is a LOUD per-platform exclusion. This section
# pins BOTH halves of that state plus its paper trail, so neither a silent
# re-add (hour-N build death) nor a silent un-documenting can pass a gate run.
RPI5="${REPO}/specs-rpi5"
if is_requested "${RPI5}" "net-firewall/firewalld"; then
  bad "specs-rpi5 requests net-firewall/firewalld again — its glib[introspection] chain does NOT cross-compile (glib-2.88.2 g-i bootstrap dies in src_configure, proven 2026-08-05); re-adding it requires a working cross story AND updating this gate, or the build dies at hour N"
else
  ok "specs-rpi5 does not request net-firewall/firewalld (deliberate exclusion; cross g-i bootstrap is broken)"
fi
if grep -q 'DELIBERATELY EXCLUDED' "${RPI5}/portage/packages.list" \
   && grep -A3 'DELIBERATELY EXCLUDED' "${RPI5}/portage/packages.list" | grep -q 'firewalld'; then
  ok "packages.list carries the exclusion paper trail (DELIBERATELY EXCLUDED block naming firewalld)"
else
  bad "the firewalld exclusion lost its paper trail in packages.list — a bare deletion is indistinguishable from the silently-shipped-firewalld-less-image hole this gate exists to prevent"
fi
OVR="${RPI5}/portage/package.use/firewalld-introspection"
if [ -f "${OVR}" ]; then
  bad "package.use/firewalld-introspection still exists — with firewalld excluded it only makes every --newuse build retry the BROKEN glib[introspection] cross rebuild (glib-2.88.2 bootstrap dies in src_configure)"
else
  ok "the retired glib[introspection] override is gone (nothing re-triggers the broken glib rebuild)"
fi
if grep -q '^net-firewall/nftables' "${RPI5}/portage/packages.list"; then
  ok "nftables is still requested (the remaining host-firewall story: nftables + hugmesh-firewall-reconcile)"
else
  bad "nftables vanished from specs-rpi5 packages.list — the exclusion rationale claims it carries the host-firewall story"
fi
if grep -q 'DELIBERATELY EXCLUDED' "${RPI5}/portage/make.conf.tmpl" || grep -q 'DELIBERATE EXCLUSION' "${RPI5}/portage/make.conf.tmpl"; then
  ok "make.conf.tmpl's -introspection block records the exclusion history (a reader of the wall learns why there is no door)"
else
  bad "make.conf.tmpl's -introspection block lost the exclusion history — the retired override becomes rediscoverable folklore"
fi

echo "-- C) the runtime backstop this gate's compile-side bet relies on --"
# The completeness gate is the runtime backstop that made the original silent
# firewalld hole loud, and it is what refuses any FUTURE silently-degraded
# image — so its arming stays part of THIS gate's contract.
if grep -q 'source "${SCRIPT_DIR}/scripts/_payload-gate-lib.sh"' "${REPO}/build-rpi5-stage4.sh"; then
  ok "build-rpi5-stage4.sh sources scripts/_payload-gate-lib.sh (completeness gate armed)"
else
  bad "build-rpi5-stage4.sh no longer sources _payload-gate-lib.sh — the compile-side bet has no runtime backstop"
fi
if grep -q '^ALLOW_MISSING_PACKAGES=false' "${REPO}/build-rpi5-stage4.sh"; then
  ok "completeness gate defaults to FAILING on a degraded image (ALLOW_MISSING_PACKAGES=false)"
else
  bad "ALLOW_MISSING_PACKAGES no longer defaults to false — a firewalld-less image could ship again"
fi

echo "-- D) atoms upstream REMOVED from the tree must never be requested again --"
# The 2026-08-15 mesh incident: net-dns/bind-tools reached its announced removal
# date while still listed in specs-x86/portage/packages.list. A package.mask'd
# atom does not merely skip itself — it fails the resolution of the WHOLE emerge
# group, so the entire x86 `image` payload merged NOTHING and the build died at
# the completeness gate with grub-install/dracut/parted/jq/nmcli/kubelet/kubeadm/
# containerd "missing", naming none of the actual cause. Every x86 role was dead;
# rpi5 survived only because it had dropped the atom earlier for its own reasons.
#
# Section C's completeness gate is the runtime backstop, but it fires an hour
# into a real build. This table moves the KNOWN removals to gate time. Unlike a
# mask check, it needs no portage tree — it is a literal-text refusal, which is
# what keeps this gate runnable in the CI python:3 containers (see the header).
#
# Add a row when upstream removes something we shipped: atom|replacement-or-empty|bug
REMOVED_ATOMS=(
  "net-dns/bind-tools||#977172 (stub since Bind 9.18; prefer net-dns/ldns[drill] or net-dns/doggo)"
  "app-arch/p7zip|app-arch/7zip|#942397 (outdated, unfixed severe vulnerabilities)"
)
for row in "${REMOVED_ATOMS[@]}"; do
  IFS='|' read -r atom repl bug <<<"${row}"
  # A REQUEST is an uncommented list line naming the atom; the paper-trail
  # comments that explain each drop are deliberately not matched.
  hits="$(grep -rlE "^[[:space:]]*${atom}([[:space:]]|$)" "${REPO}"/specs*/portage/packages*.list 2>/dev/null || true)"
  if [ -z "${hits}" ]; then
    ok "${atom} is not requested by any platform (removed upstream — ${bug})"
  else
    bad "${atom} is REQUESTED but was REMOVED upstream (${bug}) — a masked atom fails its WHOLE emerge group, merging nothing:"
    printf '       %s\n' ${hits}
    [ -n "${repl}" ] && printf '       use %s instead\n' "${repl}"
  fi
done

echo "-- E) the spec's declared profile must actually BIND in every builder --"
# The 2026-08-19 finding: specs-x86 declared hardened/selinux in
# portage/profile/parent, but build-x86-host-stage4.sh only COPIED that file
# into the chroot's /etc/portage/profile/ — where portage silently ignores a
# `parent` file (the user-override node takes use.mask etc., never a profile
# selector). Every x86 image built under the stage3's plain `hardened` profile:
# USE=selinux stayed masked, all 24 IUSE=selinux payload packages built
# `(-selinux)`, while the sec-policy store merged fine and the summary banner
# (cat of the copied file) claimed hardened/selinux. Policy on disk, userland
# unable to use it — invisible in every log line except the plan preview's
# parenthesized USE column. The ARM builder had the correct mechanism (an
# ABSOLUTE make.profile symlink derived from the same spec file) the whole time.
#
# The binding is what this section pins: each builder must DERIVE make.profile
# from the spec's profile/parent. A bare copy of the file is not a binding.
for b in build-x86-host-stage4.sh build-rpi5-stage4.sh; do
  if grep -qE 'ln -sfn .*profiles/\$\{PROFILE_PATH\}.*make\.profile' "${REPO}/${b}" \
     && grep -qE 'PROFILE_PATH=.*profile/parent' "${REPO}/${b}"; then
    ok "${b} derives make.profile from the spec's profile/parent (ln -sfn, absolute)"
  else
    bad "${b} no longer derives make.profile from profile/parent — the spec's declared profile (hardened/selinux) silently stops binding"
  fi
  if grep -qE '^cp .*profile/parent.*etc/portage/profile/parent' "${REPO}/${b}"; then
    bad "${b} copies profile/parent into /etc/portage/profile/ — portage ignores a parent file there; this is the exact no-op that shipped selinux-less x86 images"
  else
    ok "${b} does not resurrect the profile/parent copy no-op"
  fi
done
# And the declarations themselves must still be selinux profiles — a quiet edit
# of a spec's parent away from hardened/selinux would pass the binding check
# while shipping unconfined images.
for spec in specs-x86 specs-rpi5; do
  if grep -q 'hardened/selinux' "${REPO}/${spec}/portage/profile/parent"; then
    ok "${spec} declares a hardened/selinux profile"
  else
    bad "${spec}/portage/profile/parent no longer declares hardened/selinux: $(cat "${REPO}/${spec}/portage/profile/parent")"
  fi
done

echo
echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
