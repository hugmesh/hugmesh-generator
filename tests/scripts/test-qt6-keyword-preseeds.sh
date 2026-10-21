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

# 1. the qt6 file: WHOLE-CATEGORY ~amd64 coverage, UNVERSIONED (a =...-6.11.2 pin
#    silently rots on the next tree bump).
#    This assertion used to demand a 16-atom ENUMERATION — the set the #223
#    build's AUTOUNMASK-PRETEND dump happened to name. That was the wrong
#    contract and it cost a second incident (session 20260907-190340-70b501,
#    standalone-thick): dev-qt members depend on each other with EXACT-VERSION
#    atoms, so unmasking a SUBSET splits the set — the listed packages float to
#    the newest keyworded release, the unlisted ones stay stable, and their
#    exact-version deps collide. That build died on
#    "dev-qt/qtbase:6 ... resulting in a slot conflict" because qtsensors and
#    qtimageformats were not on the list. The contract is now CATEGORY coverage.
if [ -f "${QT6}" ]; then
    ok "package.accept_keywords/qt6 present"
    if grep -qE '^dev-qt/\* ~amd64$' "${QT6}"; then
        ok "qt6 grants ~amd64 to the whole dev-qt category (dev-qt/* ~amd64)"
    else
        bad "qt6 lost the whole-category 'dev-qt/* ~amd64' rule"
    fi
    # The regression shape is an ENUMERATION creeping back: any per-package
    # dev-qt line means somebody re-listed members, and a list is a subset the
    # moment the tree grows a new one.
    enum="$(grep -E '^dev-qt/[a-z0-9]' "${QT6}" | grep -vE '^dev-qt/\* ' || true)"
    if [ -z "${enum}" ]; then
        ok "qt6 enumerates no individual dev-qt packages (a list is always a subset)"
    else
        bad "qt6 re-grew per-package dev-qt lines — widen to dev-qt/*: ${enum}"
    fi
    # Executed coverage check, keyed on the three members the two incidents
    # actually named: qtsensors + qtimageformats (the 20260907 slot conflict)
    # and qtlanguageserver (the wall the 16-atom list ALSO hits on the
    # 2026-09-03 tree). None of them were in the old list, so this control
    # fails against the pre-fix file and passes against the fixed one.
    uncovered=""
    for a in qtsensors qtimageformats qtlanguageserver qtwayland; do
        grep -qE "^dev-qt/(\*|${a}) ~amd64$" "${QT6}" || uncovered="${uncovered} ${a}"
    done
    if [ -z "${uncovered}" ]; then
        ok "qt6 covers the members both incidents named (qtsensors/qtimageformats/qtlanguageserver/qtwayland)"
    else
        bad "qt6 does not cover:${uncovered} — these are the atoms the slot conflict came from"
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
#    point it at a sandbox keep-file AND a sandbox probe file, and prove the
#    discrimination logic.
sed -n '/^hugmesh_payload_plan_gate() {/,/^}/p' "${X86}" \
    | sed -e 's/\\\$/$/g' \
          -e "s|/tmp/hugmesh-emerge-plan-image-pretend-failed.log|${TMP}/kept.log|" \
          -e "s|/tmp/hugmesh-payload-autounmask-probe.log|${TMP}/probe.log|" \
    > "${TMP}/gate.sh"
if [ -s "${TMP}/gate.sh" ] && grep -q '^}' "${TMP}/gate.sh"; then
    ok "gate function extracted from the heredoc"
else
    bad "could not extract the gate function body (anchors moved?)"
fi
# The gate now ASKS the resolver (one --pretend --autounmask pass) whenever the
# kept dump carries no wall text, so the executed legs need a stubbed emerge.
# This is not optional politeness: the test host IS Gentoo, so an unstubbed
# 'emerge' would run a real resolution against the developer's own world file.
# The stub prints whatever fixture the leg points HUGMESH_TEST_EMERGE_OUT at.
mkdir -p "${TMP}/bin"
cat > "${TMP}/bin/emerge" <<'STUB'
#!/usr/bin/env bash
cat "${HUGMESH_TEST_EMERGE_OUT:-/dev/null}"
exit "${HUGMESH_TEST_EMERGE_RC:-1}"
STUB
chmod +x "${TMP}/bin/emerge"
export PATH="${TMP}/bin:${PATH}"
# The extracted body keeps the two HOST-expanded words (they are literal package
# text by the time the real chroot sees them); give them defined values here.
export EMERGE_EXCLUDE="" PKGS="virtual/test-payload"
export HUGMESH_TEST_EMERGE_OUT=/dev/null
if command -v emerge >/dev/null && [ "$(command -v emerge)" = "${TMP}/bin/emerge" ]; then
    ok "stubbed emerge shadows the host resolver for the executed legs"
else
    bad "emerge is NOT stubbed — an executed leg would run a real host resolution"
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

# 6b. USE text in the KEPT dump only, and a probe that returns no verdict
#     (stub prints nothing) => continue. Only a probe verdict may stop a build;
#     the USE verdict itself is pinned by 6e and 6h.
cat > "${TMP}/kept.log" <<'FIXTURE'
The following USE changes are necessary to proceed:
# required by kde-misc/kdeconnect-26.04.3-r3::gentoo
net-dns/avahi mdnsresponder-compat
FIXTURE
if bash -c "set -eo pipefail; source '${TMP}/gate.sh'; hugmesh_payload_plan_gate" >/dev/null 2>&1; then
    ok "USE text in the kept dump + no probe verdict => gate continues"
else
    bad "the gate failed fast on kept-dump text alone, with no probe verdict"
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
#       gettext-0.23.2. The mask block must not be read as a KEYWORD/MASK wall:
#       with no probe verdict the gate CONTINUES (6e/6h pin the USE verdict).
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

# ── 6d/6e/6f: the SLOT-CONFLICT path (session 20260907-190340-70b501) ─────────
# The 20260907 standalone-thick build proved the text discriminator alone is a
# fail-OPEN. Its kept dump carried a slot conflict and NONE of the three wall
# tokens — "have been masked" appears exactly 0 times in that 3696-line log — so
# the gate waved it through and ~11 minutes later the real merge died on the
# same conflict, followed by an AUTOUNMASK-PRETEND dump naming the two keyword
# lines that would have fixed it. The gate now ASKS the resolver instead of
# pattern-matching portage's error prose, and these legs pin that behaviour.
# The fixture below is the VERBATIM head of that build's conflict
# (build-standalone-thick.x86.log:3611-3625), trimmed to the two colliding
# parents; keep it wall-token-free — that is the whole point of the fixture.
cat > "${TMP}/kept.log" <<'FIXTURE'
Calculating dependencies  ..... done!

[blocks B      ] <dev-qt/qtimageformats-6.11.2:6 ("<dev-qt/qtimageformats-6.11.2:6" is soft blocking dev-qt/qtbase-6.11.2)

!!! Multiple package instances within a single package slot have been pulled
!!! into the dependency graph, resulting in a slot conflict:

dev-qt/qtbase:6

  (dev-qt/qtbase-6.11.2:6/6.11.2::gentoo, ebuild scheduled for merge) pulled in by
    ~dev-qt/qtbase-6.11.2:6[concurrent,network,sql,sqlite] required by (dev-qt/qttools-6.11.2:6/6.11.2::gentoo, ebuild scheduled for merge)

  (dev-qt/qtbase-6.11.1:6/6.11.1::gentoo, ebuild scheduled for merge) pulled in by
    ~dev-qt/qtbase-6.11.1:6[dbus] required by (dev-qt/qtsensors-6.11.1:6/6.11.1::gentoo, ebuild scheduled for merge)

 * Error: The above package list contains packages which cannot be
 * installed at the same time on the same system.
FIXTURE
# Anti-vacuity: if this fixture ever grows a wall token the OLD discriminator
# would fire and 6d/6e would stop testing the new code path at all.
if grep -Eq 'have been masked|keyword changes are necessary|mask changes are necessary' "${TMP}/kept.log"; then
    bad "the slot-conflict fixture carries a wall token — 6d/6e would exit on the OLD path"
else
    ok "slot-conflict fixture is wall-token-free (it must reach the resolver probe)"
fi

# 6d. slot conflict + resolver says KEYWORD changes => exit 1 before the merge.
#     This is the 20260907 build, replayed: the two keyword lines below are
#     verbatim from its own post-mortem AUTOUNMASK-PRETEND dump.
cat > "${TMP}/probe-keyword.txt" <<'PROBE'
Calculating dependencies  ... done!
The following keyword changes are necessary to proceed:
 (see "package.accept_keywords" in the portage(5) man page for more details)
# required by kde-plasma/kwin-x11-6.6.6::gentoo
=dev-qt/qtsensors-6.11.2 ~amd64
# required by kde-apps/gwenview-26.04.3::gentoo
=dev-qt/qtimageformats-6.11.2 ~amd64
PROBE
out="$(HUGMESH_TEST_EMERGE_OUT="${TMP}/probe-keyword.txt" \
       bash -c "set -eo pipefail; source '${TMP}/gate.sh'; hugmesh_payload_plan_gate" 2>&1)"
rc=$?
if [ "${rc}" -eq 1 ]; then
    ok "slot conflict + keyword-needing resolution => exit 1 (no 11-minute dead end)"
else
    bad "slot conflict + keyword-needing resolution did NOT fail fast (rc=${rc}) — the 20260907 fail-open is back"
fi
if printf '%s' "${out}" | grep '=dev-qt/qtsensors-6.11.2 ~amd64' >/dev/null; then
    ok "the abort surfaces the resolver's actual keyword lines (pre-seed them and rebuild)"
else
    bad "the abort did not print the keyword lines the operator has to pre-seed"
fi
# A keyword line naming ONE member of a lockstep set is the tell that the whole
# set is split; the banner must say so, or the operator adds that one atom and
# the next member breaks the next build (exactly how #223 became this incident).
if printf '%s' "${out}" | grep 'lockstep' >/dev/null; then
    ok "the abort warns that a single-member keyword line means a split set"
else
    bad "the abort lost the lockstep-set guidance — the fix becomes whack-a-mole"
fi

# 6e. slot conflict + resolver needs USE changes => exit 1. This leg used to
#     pin "continue", on the belief that --autounmask-continue=y applies USE
#     changes mid-merge. It does not: EMERGE_DEFAULT_OPTS carries
#     --binpkg-respect-use=y, and portage then leaves automatic USE changes off
#     unless --autounmask=y is passed (create_depgraph_params.py). Measured
#     2026-10-21 by replaying the failed desktop build's sysroot: the merge's
#     exact options print the wall; adding --autounmask=y prints the USE change.
#     That build passed this gate on the old belief and died on the same wall.
cat > "${TMP}/probe-use.txt" <<'PROBE'
Calculating dependencies  ... done!
The following USE changes are necessary to proceed:
 (see "package.use" in the portage(5) man page for more details)
# required by kde-misc/kdeconnect-26.04.3-r3::gentoo
>=net-dns/avahi-0.9 mdnsresponder-compat
PROBE
out="$(HUGMESH_TEST_EMERGE_OUT="${TMP}/probe-use.txt" \
       bash -c "set -eo pipefail; source '${TMP}/gate.sh'; hugmesh_payload_plan_gate" 2>&1)"
rc=$?
if [ "${rc}" -eq 1 ] && printf '%s' "${out}" | grep 'needs USE changes' >/dev/null; then
    ok "slot conflict + USE-needing resolution => exit 1 (the merge cannot apply USE changes)"
else
    bad "slot conflict + USE-needing resolution did NOT fail fast (rc=${rc}) — the merge would die on the same wall after the gate"
fi
if printf '%s' "${out}" | grep '>=net-dns/avahi-0.9 mdnsresponder-compat' >/dev/null; then
    ok "the USE abort surfaces the package.use line to pre-seed"
else
    bad "the USE abort did not print the line the operator has to pre-seed"
fi

# 6h. the 2026-10-21 desktop build, replayed: its kept dump carried the missing-
#     USE wall (no keyword/mask token), and the probe (the gate's own options,
#     run in that build's sysroot) printed exactly this. Verbatim.
cat > "${TMP}/kept.log" <<'FIXTURE'
Calculating dependencies ... done!
emerge: there are no ebuilds built with USE flags to satisfy "~dev-qt/qtbase-6.11.2:6[accessibility=,gui,network=,opengl=,sql?,ssl?,vulkan=,wayland=,widgets=]".
!!! One of the following packages is required to complete your request:
- dev-qt/qtbase-6.11.2-r2::gentoo (Change USE: -wayland)
- dev-qt/qtdeclarative-6.11.2-r1::gentoo (Change USE: +wayland)
(dependency required by "dev-qt/qtdeclarative-6.11.2-r1::gentoo" [ebuild])
FIXTURE
cat > "${TMP}/probe-20261021.txt" <<'PROBE'
Calculating dependencies ... done!
Dependency resolution took 1.95 s (backtrack: 0/20).
The following USE changes are necessary to proceed:
 (see "package.use" in the portage(5) man page for more details)
# required by dev-qt/qtquicktimeline-6.11.2::gentoo
# required by dev-qt/qtquick3d-6.11.2::gentoo
# required by dev-qt/qtmultimedia-6.11.2::gentoo[qml]
# required by dev-qt/qtspeech-6.11.2::gentoo
# required by net-im/neochat-26.08.1::gentoo
# required by net-im/neochat (argument)
>=dev-qt/qtdeclarative-6.11.2-r1 wayland
PROBE
if grep -Eq 'have been masked|keyword changes are necessary|mask changes are necessary' "${TMP}/kept.log"; then
    bad "the 2026-10-21 kept fixture carries a wall token — 6h would exit on the text path, not the probe"
else
    ok "2026-10-21 kept fixture is wall-token-free (it must reach the resolver probe)"
fi
out="$(HUGMESH_TEST_EMERGE_OUT="${TMP}/probe-20261021.txt" \
       bash -c "set -eo pipefail; source '${TMP}/gate.sh'; hugmesh_payload_plan_gate" 2>&1)"
rc=$?
if [ "${rc}" -eq 1 ] && printf '%s' "${out}" | grep '>=dev-qt/qtdeclarative-6.11.2-r1 wayland' >/dev/null; then
    ok "2026-10-21 shape => exit 1 naming '>=dev-qt/qtdeclarative-6.11.2-r1 wayland' (not two more hours to the same wall)"
else
    bad "2026-10-21 shape did NOT fail fast with the qtdeclarative line (rc=${rc}) — the gate would again wave a certain failure through"
fi
# grep -a on the probe: one NUL byte anywhere in an emerge log makes GNU grep
# treat it as binary and print "binary file matches" INSTEAD of the lines, so
# the abort would tell the operator nothing about what to pre-seed.
printf 'binary noise \000 here\n' >> "${TMP}/probe-20261021.txt"
out="$(HUGMESH_TEST_EMERGE_OUT="${TMP}/probe-20261021.txt" \
       bash -c "set -eo pipefail; source '${TMP}/gate.sh'; hugmesh_payload_plan_gate" 2>&1)"
rc=$?
if [ "${rc}" -eq 1 ] && printf '%s' "${out}" | grep -a '>=dev-qt/qtdeclarative-6.11.2-r1 wayland' >/dev/null; then
    ok "a NUL byte in the probe output neither hides the USE verdict nor the line to pre-seed"
else
    bad "a NUL byte in the probe output hid the USE verdict or its pre-seed line (rc=${rc}) — a grep without -a"
fi

# 6f. a STALE probe file from an earlier build must not decide this one. The
#     x86 builder resumes sysroots, so /tmp survives across runs. Seed a
#     keyword-flavoured probe, then have the resolver report NO needed change:
#     the gate must CONTINUE, which it can only do if it read back just what THIS
#     resolution wrote. Mutating the gate's truncating ">" to ">>" flips this
#     leg red, which is what makes it a control and not decoration.
cat > "${TMP}/probe-none.txt" <<'PROBE'
Calculating dependencies  ... done!
Dependency resolution took 2.10 s (backtrack: 1/20).
PROBE
cp "${TMP}/probe-keyword.txt" "${TMP}/probe.log"
if HUGMESH_TEST_EMERGE_OUT="${TMP}/probe-none.txt" \
   bash -c "set -eo pipefail; source '${TMP}/gate.sh'; hugmesh_payload_plan_gate" >/dev/null 2>&1; then
    ok "a stale probe file from an earlier build does not abort this one"
else
    bad "the gate read a STALE probe file — a resumed sysroot would fail a healthy build"
fi
rm -f "${TMP}/probe.log"

# 6g. a probe that could NOT answer (resolver timed out, chroot without
#     coreutils, resolver died early) leaves no keyword text and must CONTINUE.
#     The gate is allowed to hard-stop a build only on a verdict it actually
#     got — "I could not tell" is not a verdict. The stub prints nothing and
#     exits non-zero, which is what all three of those look like on disk.
if HUGMESH_TEST_EMERGE_OUT=/dev/null HUGMESH_TEST_EMERGE_RC=124 \
   bash -c "set -eo pipefail; source '${TMP}/gate.sh'; hugmesh_payload_plan_gate" >/dev/null 2>&1; then
    ok "an unanswerable probe (timeout/rc!=0/empty) => gate continues"
else
    bad "the gate aborted on a probe that returned no verdict"
fi
# The watchdog itself: an unbounded probe would hang the build it is meant to
# save. Pinned as text because the executed leg above runs a stub, not timeout(1).
if grep -q 'probe_timeout="timeout ' "${X86}"; then
    ok "the resolver probe is bounded by a timeout"
else
    bad "the resolver probe lost its watchdog — a hung resolution would hang the build"
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
