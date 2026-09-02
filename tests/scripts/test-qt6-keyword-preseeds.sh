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
#     no keep-file => continue.
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

# 6c. no keep-file (plan resolved / opt-out / timeout) => no-op.
rm -f "${TMP}/kept.log"
if bash -c "set -eo pipefail; source '${TMP}/gate.sh'; hugmesh_payload_plan_gate" >/dev/null 2>&1; then
    ok "no keep-file => gate is a no-op"
else
    bad "gate failed with no keep-file present"
fi

echo "== qt6-keyword-preseeds: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
