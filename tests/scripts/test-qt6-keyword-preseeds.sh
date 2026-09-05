#!/usr/bin/env bash
# ── Qt 6 ~amd64 keyword pre-seed + payload plan fail-fast guard (issue #223) ──
# The 2026-08-31 standalone-unaffiliated x86 build (session 20260831-183101-a9dc56)
# died stage4-incomplete because the tree moved the whole dev-qt/* set to
# ~amd64-only 6.11.2: the capable payload (neochat/kdeconnect/khelpcenter) and
# the calamares chain (kpmcore-26.08+ -> >=qtbase-6.11.2) both demanded it, the
# payload emerge runs --autounmask-keep-keywords=y, and NOTHING pre-seeded the
# keywords into the target config — so the ENTIRE image resolution bailed and
# grub/dracut/parted/jq/nmcli/Xorg/lightdm/openbox never merged. The build also
# continued ~15 minutes past "Emerge plan: image unavailable" to that certain
# failure.
#
# This guard bites on every way to revert the fix:
#   * the qt6 accept_keywords file disappearing, losing an atom, or growing a
#     version pin (pins rot on the next tree bump — unversioned is the contract),
#   * the copy-loop qt6 gate losing either the CAPABLE or the WANT_CALAMARES leg,
#   * package.use/capable losing the avahi mdnsresponder-compat seed (kdnssd),
#   * the plan lib no longer KEEPING failed resolver output (the gate's input),
#   * the builder losing the gate definition or its call site,
#   * the gate's LOGIC regressing — the executed leg extracts the function from
#     the heredoc and proves: keyword/mask wall => exit 1, USE-only => continue,
#     no keep-file => continue,
#   * and the gate's DISCRIMINATOR widening back onto portage's informational
#     text. Every token in the wall grep is pinned by its OWN fixture, and two
#     negative fixtures pin the other side: portage prints "- cpv (masked by:
#     ...)" for the real wall AND for the routine "installed packages are
#     masked" / "updates are masked by LICENSE changes" blocks, which
#     display_problems() emits from the SAME dump as the USE-changes block. So
#     "masked by:" was never a wall token, and keying on it turned every
#     USE-only failure on a sysroot with a masked installed package (this repo
#     masks >=sys-devel/gettext-0.23 into every role) into a hard exit 1 — the
#     exact case the USE-only assertion below claims to protect.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$(cd "${HERE}/../.." && pwd)"
P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

QT6="${GEN}/specs-x86/portage/package.accept_keywords/qt6"
CAPUSE="${GEN}/specs-x86/portage/package.use/capable"
X86="${GEN}/build-x86-host-stage4.sh"
LIB="${GEN}/scripts/_emerge-plan-lib.sh"

echo "== qt6 keyword pre-seed + payload plan gate guard =="

# 1. the qt6 file: every atom of the incident's AUTOUNMASK-PRETEND set, ~amd64,
#    UNVERSIONED (a =...-6.11.2 pin silently rots on the next tree bump).
QT6_ATOMS="qtbase qtdeclarative qtmultimedia qtwebengine qtwebview qtspeech
qtlocation qtpositioning qtwebchannel qt5compat qtsvg qttools qttranslations
qtshadertools qtquicktimeline qtquick3d"
if [ -f "${QT6}" ]; then
    ok "package.accept_keywords/qt6 present"
    missing=""
    for a in ${QT6_ATOMS}; do
        grep -qE "^dev-qt/${a} ~amd64\$" "${QT6}" || missing="${missing} ${a}"
    done
    if [ -z "${missing}" ]; then
        ok "qt6 carries all 16 dev-qt atoms, unversioned, ~amd64"
    else
        bad "qt6 missing/mis-shaped atoms (unversioned 'dev-qt/<pn> ~amd64' required):${missing}"
    fi
    if grep -qE '^\s*[=<>]' "${QT6}"; then
        bad "qt6 grew a version-pinned line — pins rot on tree bumps, keep atoms unversioned"
    else
        ok "qt6 has no version-pinned lines"
    fi
    if grep -q '223' "${QT6}"; then
        ok "qt6 carries the issue #223 rationale"
    else
        bad "qt6 lost its incident rationale comment"
    fi
else
    bad "specs-x86/portage/package.accept_keywords/qt6 is MISSING"
fi

# 2. the accept_keywords copy loop must gate qt6 on CAPABLE *OR* WANT_CALAMARES
#    (capable apps AND the calamares/kpmcore chain both need the set; losing
#    either leg silently re-strands one of the two consumers).
if grep -qE '^\s*qt6\)\s*\$\{CAPABLE\} \|\| \$\{WANT_CALAMARES\} \|\| continue ;;' "${X86}"; then
    ok "x86 copy loop gates qt6 on CAPABLE || WANT_CALAMARES"
else
    bad "x86 copy loop lost (or reshaped) the qt6 CAPABLE||WANT_CALAMARES gate"
fi

# 3. the avahi USE seed for the kdeconnect -> kdnssd chain stays in 'capable'.
if [ -f "${CAPUSE}" ] && grep -qE '^\s*net-dns/avahi\s+mdnsresponder-compat\b' "${CAPUSE}"; then
    ok "package.use/capable seeds net-dns/avahi mdnsresponder-compat"
else
    bad "package.use/capable lost the net-dns/avahi mdnsresponder-compat seed"
fi

# 4. the plan lib must KEEP failed resolver output (the gate's only input) and
#    clear stale keep-files up front (resumed sysroots persist /tmp).
if grep -q 'pretend-failed\.log' "${LIB}" \
   && grep -qE 'mv -f "\$\{tmp\}" "\$\{keep\}"' "${LIB}" \
   && grep -qE 'rm -f "\$\{keep\}"' "${LIB}"; then
    ok "plan lib keeps failed resolver output and clears stale keep-files"
else
    bad "plan lib no longer keeps/clears the pretend-failed resolver output"
fi

# 5. the builder must define the gate and CALL it between the image plan emit
#    and the image merge (a defined-but-uncalled gate is inert).
if grep -q 'hugmesh_payload_plan_gate() {' "${X86}"; then
    ok "builder defines hugmesh_payload_plan_gate"
else
    bad "builder lost the hugmesh_payload_plan_gate definition"
fi
if awk '/emerge_plan_emit image /{seen=1} seen && /^hugmesh_payload_plan_gate$/{print "CALLED"; exit} seen && /==> Emerge group: image/{exit}' "${X86}" | grep CALLED >/dev/null; then
    ok "builder calls the gate between the image plan emit and the image merge"
else
    bad "the gate call between the image plan emit and the image merge is gone"
fi
# path parity: the builder reads exactly the file the lib writes for group=image.
if grep -q 'kept=/tmp/hugmesh-emerge-plan-image-pretend-failed.log' "${X86}" \
   && grep -q 'hugmesh-emerge-plan-\${group}-pretend-failed\.log' "${LIB}"; then
    ok "gate/lib keep-file path parity (image group)"
else
    bad "gate and lib disagree on the keep-file path — the gate would read nothing"
fi

# 6. EXECUTED: extract the gate function from the unquoted heredoc (unescape \$),
#    point it at a sandbox keep-file, and prove the discrimination logic.
sed -n '/^hugmesh_payload_plan_gate() {/,/^}/p' "${X86}" \
    | sed -e 's/\\\$/$/g' \
          -e "s|/tmp/hugmesh-emerge-plan-image-pretend-failed.log|${TMP}/kept.log|" \
    > "${TMP}/gate.sh"
if [ -s "${TMP}/gate.sh" ] && grep -q '^}' "${TMP}/gate.sh"; then
    ok "gate function extracted from the heredoc"
else
    bad "could not extract the gate function body (anchors moved?)"
fi

# 6a. keyword wall (verbatim shape from build.log:19708-19713) => exit 1, loud.
cat > "${TMP}/kept.log" <<'FIXTURE'
Calculating dependencies  ... done!

!!! All ebuilds that could satisfy ">=dev-qt/qtbase-6.11.2:6[dbus,gui,widgets]" have been masked.
!!! One of the following masked packages is required to complete your request:
- dev-qt/qtbase-6.11.2::gentoo (masked by: ~amd64 keyword)

(dependency required by "sys-libs/kpmcore-26.08.0::gentoo" [ebuild])
FIXTURE
out="$(bash -c "set -eo pipefail; source '${TMP}/gate.sh'; hugmesh_payload_plan_gate" 2>&1)"
rc=$?
if [ "${rc}" -eq 1 ] && printf '%s' "${out}" | grep 'KEYWORD/MASK wall' >/dev/null; then
    ok "keyword wall => exit 1 with the loud banner"
else
    bad "keyword wall not failed fast (rc=${rc})"
fi
if printf '%s' "${out}" | grep 'masked by: ~amd64 keyword' >/dev/null; then
    ok "banner surfaces the needed change lines"
else
    bad "banner did not surface the resolver's needed-change lines"
fi

# 6a-2 / 6a-3. The other two wall tokens, pinned SEPARATELY (one fixture each —
#       a single fixture carrying both would let either one be deleted silently).
#       These are portage's autounmask PROPOSAL headers, emitted by
#       _display_autounmask() only when the resolver was allowed to consider the
#       change; the payload's own vector passes --autounmask-keep-keywords=y
#       --autounmask-keep-masks=y, so it never sees them today and they are
#       defensive: if that option vector is ever relaxed they become the wall
#       text, and the merge still cannot apply them.
cat > "${TMP}/kept.log" <<'FIXTURE'
Calculating dependencies  ... done!

The following keyword changes are necessary to proceed:
 (see "package.accept_keywords" in the portage(5) man page for more details)
# required by sys-libs/kpmcore-26.08.0::gentoo
>=dev-qt/qtbase-6.11.2 ~amd64
FIXTURE
out="$(bash -c "set -eo pipefail; source '${TMP}/gate.sh'; hugmesh_payload_plan_gate" 2>&1)"
rc=$?
if [ "${rc}" -eq 1 ] && printf '%s' "${out}" | grep 'KEYWORD/MASK wall' >/dev/null; then
    ok "'keyword changes are necessary' => exit 1"
else
    bad "'keyword changes are necessary' no longer fails fast (rc=${rc})"
fi

cat > "${TMP}/kept.log" <<'FIXTURE'
Calculating dependencies  ... done!

The following mask changes are necessary to proceed:
 (see "package.unmask" in the portage(5) man page for more details)
# required by sys-libs/kpmcore-26.08.0::gentoo
# /usr/portage/profiles/package.mask:
=sys-kernel/gentoo-sources-6.12.31
FIXTURE
out="$(bash -c "set -eo pipefail; source '${TMP}/gate.sh'; hugmesh_payload_plan_gate" 2>&1)"
rc=$?
if [ "${rc}" -eq 1 ] && printf '%s' "${out}" | grep 'KEYWORD/MASK wall' >/dev/null; then
    ok "'mask changes are necessary' => exit 1"
else
    bad "'mask changes are necessary' no longer fails fast (rc=${rc})"
fi

# 6b. USE-only failure => continue (autounmask-continue applies USE mid-merge).
cat > "${TMP}/kept.log" <<'FIXTURE'
The following USE changes are necessary to proceed:
# required by kde-misc/kdeconnect-26.04.3-r3::gentoo
net-dns/avahi mdnsresponder-compat
FIXTURE
if bash -c "set -eo pipefail; source '${TMP}/gate.sh'; hugmesh_payload_plan_gate" >/dev/null 2>&1; then
    ok "USE-only failure => gate continues (merge can still self-heal)"
else
    bad "USE-only failure wrongly failed fast — regressions of the old green path"
fi

# 6b-2. REAL portage shape: a USE-ONLY failure that ALSO carries portage's
#       routine informational "installed packages are masked" block. Both are
#       printed by the SAME depgraph.display_problems() call (the USE block via
#       _display_autounmask, the mask block from _masked_installed), so they land
#       in ONE --pretend dump whenever the sysroot holds any masked installed
#       package. That is routine here, not exotic: this repo ships its own
#       package.mask for >=sys-devel/gettext-0.23 into every role, and the
#       pre-image gettext downgrade is a TOLERATED failure ("|| echo WARN"), so
#       the image plan pass can legitimately see a package-masked installed
#       gettext-0.23.2. The gate must still CONTINUE — the real merge runs
#       --autounmask-continue=y and applies the USE change.
#       This is the invariant 6b claims to protect; 6b's bare-USE fixture cannot
#       see it, because the regression is triggered by the mask text 6b omits.
cat > "${TMP}/kept.log" <<'FIXTURE'
Calculating dependencies  ... done!

The following USE changes are necessary to proceed:
 (see "package.use" in the portage(5) man page for more details)
# required by kde-misc/kdeconnect-26.04.3-r3::gentoo
# required by @selected
>=net-dns/avahi-0.9 mdnsresponder-compat

!!! The following installed packages are masked:
- sys-devel/gettext-0.23.2::gentoo (masked by: package.mask)

For more information, see the MASKED PACKAGES section in the emerge
man page or refer to the Gentoo Handbook.
FIXTURE
out="$(bash -c "set -eo pipefail; source '${TMP}/gate.sh'; hugmesh_payload_plan_gate" 2>&1)"
rc=$?
if [ "${rc}" -eq 0 ]; then
    ok "USE-only failure + informational installed-masked block => gate continues"
else
    bad "informational 'masked by:' block wrongly triggered the wall abort (rc=${rc})"
fi

# 6b-3. The discriminator must key on the WALL text, not on any 'masked by:'
#       line: show_masked_packages() renders that same "- cpv (masked by: ...)"
#       shape for the real wall AND for both informational blocks
#       (_masked_installed, _masked_license_updates). A dump carrying ONLY the
#       informational block is not a wall and must not abort the build.
cat > "${TMP}/kept.log" <<'FIXTURE'
Calculating dependencies  ... done!

!!! The following updates are masked by LICENSE changes:
- sys-kernel/linux-firmware-20260826::gentoo (masked by: linux-fw-redistributable license(s))

For more information, see the MASKED PACKAGES section in the emerge
man page or refer to the Gentoo Handbook.
FIXTURE
out="$(bash -c "set -eo pipefail; source '${TMP}/gate.sh'; hugmesh_payload_plan_gate" 2>&1)"
rc=$?
if [ "${rc}" -eq 0 ]; then
    ok "informational-only 'masked by:' dump => gate continues (no wall text)"
else
    bad "a 'masked by:'-only dump was misread as a KEYWORD/MASK wall (rc=${rc})"
fi

# 6c. no keep-file (plan resolved / opt-out / timeout) => no-op.
rm -f "${TMP}/kept.log"
if bash -c "set -eo pipefail; source '${TMP}/gate.sh'; hugmesh_payload_plan_gate" >/dev/null 2>&1; then
    ok "no keep-file => gate is a no-op"
else
    bad "gate failed with no keep-file present"
fi

echo "== qt6-keyword-preseeds: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
