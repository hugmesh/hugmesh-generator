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
# Sections F and G (defect L6, the 2026-11-10 La Frite build) pin two more ways a
# requested atom silently never merges: the board's own profile/package.provided
# declaring it (F, with in-suite negative controls in F'), and net-fs/cifs-utils
# dragging the non-cross-buildable net-fs/samba into a cross build (G, with G').
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
   && grep -A3 'DELIBERATELY EXCLUDED' "${RPI5}/portage/packages.list" | grep 'firewalld' >/dev/null; then
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

echo "-- F) a REQUESTED atom must never also be declared in the board's package.provided --"
# The 2026-11-10 La Frite light-desktop build (defect L6): the frite, jetson,
# orangepi4-lts and orangepi5 desktop lists all requested www-client/netsurf
# while the SAME board's profile/package.provided declared it (netsurf cannot be
# cross-built; see that file). Portage's answer is only a warning:
#   WARNING: A requested package will not be merged because it is listed in
#   package.provided:   www-client/netsurf pulled in by 'args'
# so the emerge carries on, and hours later the requested-atom completeness gate
# (scripts/_payload-gate-lib.sh) fails the build on an atom that was never going
# to merge. That gate is right NOT to exempt package.provided: a requested
# package that is absent from the image IS a degraded image. The contradiction
# is in the spec, so it is caught here, at gate time.
#
# Compared by cat/pn. package.provided entries are full CPVs (cat/pn-ver); list
# atoms may carry an operator+version, a :slot, [use] deps or ::repo. ANY overlap
# fails, including a version-bounded request the provided version would not
# satisfy: that spec would then build netsurf on some trees and silently skip it
# on others, which nobody reading the list can predict.

# PMS version tail: -<n>(.<n>)*<letter>?(_suffix<n>?)*(-r<n>)?. Strict on
# purpose, so a package NAME that only contains "-<digit>" (font-bh-100dpi) is
# never mistaken for a version.
PMS_VER_RE='^(.+)-([0-9]+(\.[0-9]+)*[a-z]?((_alpha|_beta|_pre|_rc|_p)[0-9]*)*(-r[0-9]+)?)$'

# Sets ATOM_CP to the cat/pn of a list atom ("" when the token has no category).
# A global, not stdout: this runs once per list line (thousands), and a command
# substitution per line would fork for each one.
atom_cp() { # <atom>
  local a="$1" op=""
  a="${a%%::*}"; a="${a%%\[*}"; a="${a%%:*}"
  case "${a}" in [\<\>=~!]*) op=1 ;; esac
  a="${a#"${a%%[!<>=~!]*}"}"
  if [ -n "${op}" ]; then
    a="${a%\*}"
    [[ "${a}" =~ ${PMS_VER_RE} ]] && a="${BASH_REMATCH[1]}"
  fi
  case "${a}" in */*) ATOM_CP="${a}" ;; *) ATOM_CP="" ;; esac
}

# Prints one line per finding, nothing when the spec is clean:
#   OVERLAP|<list>:<lineno>|<requested atom>|<provided entry>
#   BADCPV|<entry>   a package.provided token that is not cat/pn-version
#   EMPTY|<file>     package.provided exists but no entry parsed (a pass would be vacuous)
# A list line is requested exactly when the builders' own filter keeps it
# (grep -v '^\s*#'), so an inline "# ..." tail is dropped and comment lines never count.
provided_overlaps() { # <specdir>
  local sd="$1" line tok list n
  local pp="${sd}/portage/profile/package.provided"
  local -A prov=()
  [ -f "${pp}" ] || return 0
  while IFS= read -r line || [ -n "${line}" ]; do
    line="${line%%#*}"
    tok=""; read -r tok _ <<<"${line}"
    [ -n "${tok}" ] || continue
    if [[ "${tok}" =~ ${PMS_VER_RE} ]] && [[ "${BASH_REMATCH[1]}" == [a-z0-9]*/* ]]; then
      prov["${BASH_REMATCH[1]}"]="${tok}"
    else
      echo "BADCPV|${tok}"
    fi
  done < "${pp}"
  if [ "${#prov[@]}" -eq 0 ]; then echo "EMPTY|${pp#"${sd}"/}"; return 0; fi
  for list in "${sd}"/portage/packages*.list; do
    [ -f "${list}" ] || continue
    n=0
    while IFS= read -r line || [ -n "${line}" ]; do
      n=$((n+1))
      line="${line%%#*}"
      tok=""; read -r tok _ <<<"${line}"
      [ -n "${tok}" ] || continue
      atom_cp "${tok}"
      if [ -n "${ATOM_CP}" ] && [ -n "${prov[${ATOM_CP}]+x}" ]; then
        echo "OVERLAP|${list#"${sd}"/}:${n}|${tok}|${prov[${ATOM_CP}]}"
      fi
    done < "${list}"
  done
  return 0
}

report_provided_overlaps() { # <label> <findings>
  local kind where atom entry
  while IFS='|' read -r kind where atom entry; do
    case "${kind}" in
      OVERLAP) bad "[$1] ${where} requests ${atom}, but profile/package.provided declares ${entry}. Portage will NEVER merge it ('A requested package will not be merged because it is listed in package.provided'), so the completeness gate fails every build that requests it. Drop the request and leave a comment pointing at package.provided, or remove the provided entry together with a build that proves the package now merges." ;;
      BADCPV)  bad "[$1] profile/package.provided entry '${where}' is not a cat/pn-version CPV. Portage rejects such entries, and this gate cannot compare it." ;;
      EMPTY)   bad "[$1] ${where} exists but no entry parsed, so the overlap check would pass vacuously." ;;
      *)       bad "[$1] unexpected overlap-check output: ${kind}|${where}|${atom}|${entry}" ;;
    esac
  done <<<"$2"
}

for plat in "${PLATFORMS[@]}"; do
  sd="${REPO}/specs-${plat}"
  if [ ! -f "${sd}/portage/profile/package.provided" ]; then
    ok "[${plat}] no profile/package.provided, so nothing can shadow a requested atom"
    continue
  fi
  found="$(provided_overlaps "${sd}")"
  if [ -z "${found}" ]; then
    ok "[${plat}] no atom requested by packages*.list is also in profile/package.provided"
  else
    report_provided_overlaps "${plat}" "${found}"
  fi
done
# The loop above walks PLATFORMS. A board whose package.provided is not in that
# array would never be checked, so every package.provided on disk must belong to it.
for pp in "${REPO}"/specs-*/portage/profile/package.provided; do
  [ -f "${pp}" ] || continue
  plat="${pp#"${REPO}"/specs-}"; plat="${plat%%/*}"
  case " ${PLATFORMS[*]} " in
    *" ${plat} "*) ok "specs-${plat}/portage/profile/package.provided is covered by the PLATFORMS walk" ;;
    *)             bad "specs-${plat}/portage/profile/package.provided exists but '${plat}' is not in PLATFORMS, so section F never checks it" ;;
  esac
done

echo "-- F') negative controls: the overlap check sees every spelling (synthesised specs) --"
NC_ROOT="$(mktemp -d)"
trap 'rm -rf "${NC_ROOT}"' EXIT
NCN=0
# <want: OVERLAP|BADCPV|EMPTY|clean> <label> <list-file> <list-body> <provided-body>
nc_expect() {
  local d out
  NCN=$((NCN+1)); d="${NC_ROOT}/specs-nc${NCN}"
  mkdir -p "${d}/portage/profile"
  printf '%s\n' "$5" > "${d}/portage/profile/package.provided"
  printf 'app-editors/nano\n%s\nmedia-fonts/dejavu\n' "$4" > "${d}/portage/$3"
  out="$(provided_overlaps "${d}")"
  if [ "$1" = "clean" ]; then
    [ -z "${out}" ] && ok "negative control stays clean: $2" \
                    || bad "negative control false positive ($2): ${out}"
  else
    case "${out}" in
      "$1|"*) ok "negative control caught ($1): $2" ;;
      *)      bad "negative control MISSED ($1 expected): $2 -> '${out}'" ;;
    esac
  fi
}
NP='www-client/netsurf-3.11-r1'
nc_expect OVERLAP "plain atom (the L6 line itself)"        packages-light-desktop.list 'www-client/netsurf' "${NP}"
nc_expect OVERLAP "in the BASE list, not only a desktop list" packages.list            'www-client/netsurf' "${NP}"
nc_expect OVERLAP "=cat/pn-ver"                             packages-desktop.list      '=www-client/netsurf-3.11-r1' "${NP}"
nc_expect OVERLAP ">=cat/pn-ver the provided one cannot meet" packages-desktop.list    '>=www-client/netsurf-4' "${NP}"
nc_expect OVERLAP "=cat/pn-ver* glob"                       packages-desktop.list      '=www-client/netsurf-3.11*' "${NP}"
nc_expect OVERLAP "slot atom"                               packages-desktop.list      'www-client/netsurf:0' "${NP}"
nc_expect OVERLAP "USE-dep + repo atom"                     packages-desktop.list      'www-client/netsurf[svg]::gentoo' "${NP}"
nc_expect OVERLAP "indented, with an inline comment"        packages-live.list         '   www-client/netsurf   # browser' "${NP}"
nc_expect OVERLAP "provided at a different version"         packages-desktop.list      'www-client/netsurf' 'www-client/netsurf-9.9_rc2-r3'
nc_expect OVERLAP "name containing -<digit> (strict version regex)" packages.list       'media-fonts/font-bh-100dpi' 'media-fonts/font-bh-100dpi-1.0.4-r1'
nc_expect clean   "comment-only mention"                    packages-light-desktop.list '# www-client/netsurf used to be listed here' "${NP}"
nc_expect clean   "name that only shares a prefix"          packages-desktop.list      'www-client/netsurf-extras' "${NP}"
nc_expect clean   "same pn, other category"                 packages-desktop.list      'dev-libs/netsurf' "${NP}"
nc_expect BADCPV  "versionless provided entry"              packages.list              'app-misc/jq' 'www-client/netsurf'
nc_expect BADCPV  "operator in a provided entry"            packages.list              'app-misc/jq' '>=www-client/netsurf-3.11'
nc_expect EMPTY   "provided file with only comments"        packages.list              'app-misc/jq' '# nothing provided'
# The real-tree walk only reaches report_provided_overlaps when a spec is broken,
# so a green run never exercises it. Prove here that each finding kind counts as
# a FAIL (in a subshell, so these probes leave the suite's own counters alone).
for probe in "OVERLAP|portage/packages.list:1|www-client/netsurf|${NP}" "BADCPV|www-client/netsurf" "EMPTY|package.provided"; do
  probe_fails="$(F=0; report_provided_overlaps nc "${probe}" >/dev/null; echo "${F}")"
  if [ "${probe_fails}" = 1 ]; then
    ok "report_provided_overlaps counts a ${probe%%|*} finding as a FAIL"
  else
    bad "report_provided_overlaps did NOT count '${probe}' as exactly one FAIL (got ${probe_fails})"
  fi
done

echo "-- G) net-fs/cifs-utils must not drag net-fs/samba into a CROSS build --"
# cifs-utils' default +acl hard-RDEPENDs >=net-fs/samba, and these cross
# builders cannot build samba: its waf configure runs the BUILD host's perl and
# needs Parse::Yapp::Driver, which samba lists in DEPEND (not BDEPEND), so it
# only ever lands in the sysroot. Measured twice: jetson samba-4.24.6 (2026-08-15
# fleet run) and frite samba-4.24.7 (2026-11-10), both "failed (configure phase)",
# both followed by "cifs-utils ... dropped because it requires
# >=net-fs/samba-4.0.0_alpha1" and a completeness-gate failure. mount.cifs needs
# no acl: the flag only adds the cifsacl/cifsidmap helpers.
#
# A cross-built board that requests cifs-utils must therefore pin
# "net-fs/cifs-utils -acl" in package.use. x86 builds natively in a chroot and
# is not covered. CIFS_UNMEASURED lists the boards that request cifs-utils with
# acl still on and that no build has measured yet. Each one prints a NOTE (an
# open finding, not a silent pass). A board in it that gains the pin must be
# moved out (FAIL until it is), and a board NOT in it that requests cifs-utils
# with acl on FAILS, so the exposure can shrink but never grow.
CIFS_UNMEASURED=(orangepi-zero2 orangepi-zero2w orangepi-zero3 orangepi3-lts orangepi4-lts orangepi5)

# Is <cat/pn> requested by any of the spec's packages*.list, in ANY spelling
# (operator+version, :slot, [use], ::repo, indentation, an inline comment)? Uses
# section F's atom_cp, so a request cannot dodge G with a spelling F would catch.
# (is_requested above matches the bare atom only; the sections that use it keep it.)
requests_cp() { # <specdir> <cat/pn>
  local list line tok
  for list in "$1"/portage/packages*.list; do
    [ -f "${list}" ] || continue
    while IFS= read -r line || [ -n "${line}" ]; do
      line="${line%%#*}"
      tok=""; read -r tok _ <<<"${line}"
      [ -n "${tok}" ] || continue
      atom_cp "${tok}"
      [ "${ATOM_CP}" = "$2" ] && return 0
    done < "${list}"
  done
  return 1
}

# One board's verdict, on stdout:
#   NA               net-fs/cifs-utils is not requested
#   PINNED|<file>    requested, and package.use/<file> leaves acl off
#   UNMEASURED       requested with acl on; the board is in CIFS_UNMEASURED (NOTE)
#   STALE|<file>     pinned, but the board is still in CIFS_UNMEASURED
#   ACLON            requested with acl on; the board is not in CIFS_UNMEASURED
cifs_verdict() { # <specdir> <plat>
  local acl unmeasured=""
  if ! requests_cp "$1" "net-fs/cifs-utils"; then echo "NA"; return 0; fi
  acl="$(pkguse_flag_state "$1" "net-fs/cifs-utils" "acl")"
  case " ${CIFS_UNMEASURED[*]} " in *" $2 "*) unmeasured=1 ;; esac
  if [ "${acl%% *}" = "-" ]; then
    if [ -n "${unmeasured}" ]; then echo "STALE|${acl#- }"; else echo "PINNED|${acl#- }"; fi
  elif [ -n "${unmeasured}" ]; then
    echo "UNMEASURED"
  else
    echo "ACLON"
  fi
}

report_cifs_verdict() { # <plat> <verdict>
  case "$2" in
    NA)         ok "[$1] net-fs/cifs-utils not requested; samba chain N/A" ;;
    PINNED\|*)  ok "[$1] cifs-utils requested; package.use/${2#PINNED|} pins -acl, so samba stays out of the cross build" ;;
    STALE\|*)   bad "[$1] now pins net-fs/cifs-utils -acl (package.use/${2#STALE|}) but is still in CIFS_UNMEASURED. Move it out so the pin is enforced." ;;
    UNMEASURED) echo "  NOTE [$1] requests net-fs/cifs-utils with acl ON (pulls net-fs/samba); unmeasured on this board, open finding" ;;
    ACLON)      bad "[$1] requests net-fs/cifs-utils with acl ON, so net-fs/samba joins the cross build, fails configure, and the completeness gate fails on cifs-utils. Pin 'net-fs/cifs-utils -acl -ads' in specs-$1/portage/package.use/cifs (see specs-jetson's)." ;;
    *)          bad "[$1] unexpected cifs-utils verdict: '$2'" ;;
  esac
}

for plat in "${PLATFORMS[@]}"; do
  [ "${plat}" = "x86" ] && continue
  report_cifs_verdict "${plat}" "$(cifs_verdict "${REPO}/specs-${plat}" "${plat}")"
done

echo "-- G') negative controls: the cifs-utils/samba verdict (synthesised specs) --"
# A green real tree only exercises the verdicts the boards happen to produce
# today, so each verdict and each request spelling is proven on a synthesised
# spec. 'ncboard' is not in CIFS_UNMEASURED; orangepi5 is.
# <want> <label> <plat> <list-file> <list-body> [<package.use file> <body>]...
gc_expect() {
  local want="$1" label="$2" plat="$3" d out
  NCN=$((NCN+1)); d="${NC_ROOT}/specs-gc${NCN}"
  mkdir -p "${d}/portage/package.use"
  printf 'app-editors/nano\n%s\n' "$5" > "${d}/portage/$4"
  shift 5
  while [ "$#" -ge 2 ]; do printf '%s\n' "$2" > "${d}/portage/package.use/$1"; shift 2; done
  out="$(cifs_verdict "${d}" "${plat}")"
  case "${out}" in
    "${want}"|"${want}|"*) ok "G negative control: ${label} -> ${out}" ;;
    *)                     bad "G negative control MISSED (${want} expected): ${label} -> '${out}'" ;;
  esac
}
gc_expect ACLON      "requested in the BASE list, no package.use"            ncboard   packages.list         'net-fs/cifs-utils'
gc_expect ACLON      "versioned, slotted, USE-dep, inline-comment request"   ncboard   packages-desktop.list '  >=net-fs/cifs-utils-7.0:0[caps]::gentoo  # mount.cifs'
gc_expect ACLON      "-ads only: acl stays on"                               ncboard   packages.list         'net-fs/cifs-utils' cifs 'net-fs/cifs-utils -ads'
gc_expect ACLON      "a LATER package.use file turns acl back on"            ncboard   packages.list         'net-fs/cifs-utils' cifs 'net-fs/cifs-utils -acl -ads' zz-local 'net-fs/cifs-utils acl'
gc_expect PINNED     "plain pin"                                             ncboard   packages.list         'net-fs/cifs-utils' cifs 'net-fs/cifs-utils -acl -ads'
gc_expect PINNED     "versioned pin"                                         ncboard   packages-desktop.list '=net-fs/cifs-utils-7.7' cifs '>=net-fs/cifs-utils-7 -acl'
gc_expect NA         "comment-only mention"                                  ncboard   packages.list         '# net-fs/cifs-utils used to be listed here'
gc_expect NA         "a name that only shares a prefix"                      ncboard   packages.list         'net-fs/cifs-utils-extras'
gc_expect UNMEASURED "acl on, board in CIFS_UNMEASURED"                      orangepi5 packages.list         'net-fs/cifs-utils'
gc_expect STALE      "pinned, board still in CIFS_UNMEASURED"                orangepi5 packages.list         'net-fs/cifs-utils' cifs 'net-fs/cifs-utils -acl -ads'
# Each verdict must land in the right bucket: a FAIL, a PASS, or a NOTE that is
# neither (subshells, so these probes leave the suite's own counters alone).
for probe in "ACLON:0 1" "STALE|cifs:0 1" "UNMEASURED:0 0" "PINNED|cifs:1 0" "NA:1 0" "bogus:0 1"; do
  got="$(P=0; F=0; report_cifs_verdict nc "${probe%%:*}" >/dev/null; echo "${P} ${F}")"
  if [ "${got}" = "${probe#*:}" ]; then
    ok "report_cifs_verdict counts '${probe%%:*}' as PASS/FAIL ${probe#*:}"
  else
    bad "report_cifs_verdict counts '${probe%%:*}' as PASS/FAIL ${got}, expected ${probe#*:}"
  fi
done

echo
echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
