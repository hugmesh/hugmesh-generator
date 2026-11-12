#!/usr/bin/env bash
# test-rpi5-img-preflight.sh — the rpi5 raw-.img pre-flight in build-rpi5-stage4.sh
# (build_img) must measure what the stage4 CARRIES and must GROW a root that is too
# small, not abort the build.
#
# THE DEFECT (2026-11-11, out/sessions/20261111-003330-5d3d2f/build-pki.rpi5.log):
#   ERROR: Payload 15450 MiB exceeds the 9216 MiB root partition (usable ~8570 MiB).
# after the whole emerge. Two faults, both on main:
#   1. The pre-flight ran `du` over the WHOLE sysroot. The build used --skip-clean, so
#      the kernel build tree in usr/src (12142 MiB) was still there, and the stage4 pack
#      never carries usr/src, var/cache or tmp/*. The stage4 held 2786 MiB (xz --list)
#      and would have fit 9216 three times over: the abort was false.
#   2. A payload that really does not fit was a fatal error; the x86 builder grows the
#      root to fit instead (growroot resizes it on first boot anyway).
#
# Pure extract + execute: the pack commands and the pre-flight are cut out of the
# builder by their own text and run against a small fixture sysroot. No root, no loop
# devices, no network. Each part ends with a negative control that plants the old
# defect into the extracted text and requires this suite to see it.
#
# RPI5_BUILDER=<file> runs the suite against another copy of the builder (mutation
# testing); the default is the builder in this checkout.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
BUILDER="${RPI5_BUILDER:-${REPO}/build-rpi5-stage4.sh}"

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

for t in awk du tar xz head; do
  command -v "$t" >/dev/null 2>&1 || { echo "FAIL: $t is required (the suite would assert nothing without it)"; exit 1; }
done
# GNU du only: busybox du has no --exclude, and the pre-flight relies on it.
du --exclude=x -s . >/dev/null 2>&1 || { echo "FAIL: this du has no --exclude (busybox?) — run under GNU coreutils"; exit 1; }

# Fastest xz preset: the fixture is random bytes, so a higher preset only costs time.
export XZ_OPT=-0

TMPD="$(mktemp -d)"
trap 'rm -rf "${TMPD}"' EXIT

echo "== rpi5 .img pre-flight (${BUILDER#"${REPO}"/}) =="

# ─────────────────────────────────────────────────────────────────────────────
echo "-- 1) extraction --"
# The pack: from the exclude-list assignment through the fallback tar's last line
# (the only line that ends in `-cJf "${STAGE4_TARBALL}" .` with nothing after it).
awk '/^STAGE4_PACK_EXCLUDES=/{f=1} f{print} f&&/-cJf "\$\{STAGE4_TARBALL\}" \.$/{exit}' \
    "${BUILDER}" > "${TMPD}/pack"
# The pre-flight: build_img's size formula through its "Pre-flight:" report line.
awk '/^build_img\(\) \{/{f=1} f&&/img_size_mib=\$\(\( 1 \+ 512 \+ ROOT_MiB \+ 1 \)\)/{s=1}
     s{print} s&&/info "Pre-flight: payload/{exit}' "${BUILDER}" > "${TMPD}/preflight"
grep -q 'tar -C' "${TMPD}/pack" \
  && ok "extracted the stage4 pack ($(wc -l < "${TMPD}/pack") lines)" \
  || bad "could not extract the stage4 pack (no STAGE4_PACK_EXCLUDES= assignment before it?)"
grep -q 'Pre-flight: payload' "${TMPD}/preflight" \
  && ok "extracted the build_img pre-flight ($(wc -l < "${TMPD}/preflight") lines)" \
  || bad "could not extract the build_img pre-flight"

# ─────────────────────────────────────────────────────────────────────────────
echo "-- 2) one exclude list, read by both pack commands and the pre-flight --"
n_tar=$(grep -c '^tar -C "\${SYSROOT}"' "${TMPD}/pack")
n_ref=$(grep -c '"\${STAGE4_PACK_EXCLUDES\[@\]}"' "${TMPD}/pack")
n_lit=$(grep -v '^STAGE4_PACK_EXCLUDES=' "${TMPD}/pack" | grep -c -- '--exclude')
if [ "${n_tar}" -eq 2 ] && [ "${n_ref}" -eq 2 ] && [ "${n_lit}" -eq 0 ]; then
  ok "both tar commands (the xattr one and its fallback) take STAGE4_PACK_EXCLUDES and nothing else"
else
  bad "pack drifted from the shared list: ${n_tar} tar command(s), ${n_ref} reference(s), ${n_lit} literal --exclude"
fi
grep -q 'du -sxBM "\${STAGE4_PACK_EXCLUDES\[@\]}" \.' "${TMPD}/preflight" \
  && ok "the pre-flight du takes the same list, from inside the sysroot" \
  || bad "the pre-flight du does not measure with STAGE4_PACK_EXCLUDES (it would count what is never packed)"
excl_ln=$(grep -n '^STAGE4_PACK_EXCLUDES=' "${BUILDER}" | head -1 | cut -d: -f1)
call_ln=$(grep -n '^    build_img$' "${BUILDER}" | head -1 | cut -d: -f1)
if [ -n "${excl_ln}" ] && [ -n "${call_ln}" ] && [ "${excl_ln}" -lt "${call_ln}" ]; then
  ok "the list is set (line ${excl_ln}) before build_img runs (line ${call_ln})"
else
  bad "the list is not set before the build_img call (list=${excl_ln:-missing} call=${call_ln:-missing})"
fi

# ─────────────────────────────────────────────────────────────────────────────
# run_case <pack> <preflight> <ROOT_MiB> <sysroot> <tarball> — pack the sysroot, then run
# the pre-flight under the builder's own shell options. Prints the log and a RESULT line.
run_case() {
  {
    echo 'set -euo pipefail'
    echo 'err(){ echo "ERROR: $*"; }; warn(){ echo "WARNING: $*"; }; info(){ echo "INFO: $*"; }'
    echo 'hmr_pack_owner_args(){ HMR_PACK_OWNER_ARGS=(--owner=0 --group=0); }'
    echo 'ROOT_MiB=$1; SYSROOT=$2; STAGE4_TARBALL=$3'
    cat "$1"
    echo 'pf() {'
    echo '    local img_size_mib'
    cat "$2"
    echo '    echo "RESULT ROOT_MiB=${ROOT_MiB} img_size_mib=${img_size_mib} cap_mib=${cap_mib} payload_mib=${payload_mib}"'
    echo '}'
    echo 'pf'
  } > "${TMPD}/run"
  bash "${TMPD}/run" "$3" "$4" "$5" 2>&1
}
# field <log> <name> — the number after " <name>=" on the RESULT line (no \b: busybox sed).
field(){ printf '%s\n' "$1" | sed -n "s/^RESULT.* $2=\\([0-9]*\\).*/\\1/p"; }
mib(){ head -c "$(( $2 * 1024 * 1024 ))" /dev/urandom > "$1"; }   # random: no sparse/compress shortcut

# The 11-11 shape, scaled down: a root of 8 MiB (usable 7), a 3 MiB payload and
# 32 MiB the pack never carries (a kernel build tree, a cache, tmp).
SR1="${TMPD}/sysroot-skipclean"
mkdir -p "${SR1}/usr/bin" "${SR1}/usr/src/linux" "${SR1}/var/cache/distfiles" "${SR1}/tmp" "${SR1}/etc"
mib "${SR1}/usr/bin/payload" 3
mib "${SR1}/usr/src/linux/vmlinux.o" 24
mib "${SR1}/var/cache/distfiles/src.tar" 4
mib "${SR1}/tmp/leftover" 4
echo 'hostname=pki' > "${SR1}/etc/hostname"

# check_unpacked_fits <log> — exit 0 when the 11-11 shape fit WITHOUT a grow.
check_unpacked_fits() {
  case "$1" in *auto-growing*|*ERROR*) return 1 ;; esac
  [ "$(field "$1" ROOT_MiB)" = 8 ] && [ "$(field "$1" img_size_mib)" = 522 ] \
    && [ -n "$(field "$1" payload_mib)" ] && [ "$(field "$1" payload_mib)" -le 7 ]
}

echo "-- 3) the 11-11 shape: what is never packed is never counted (EXECUTED) --"
out1="$(run_case "${TMPD}/pack" "${TMPD}/preflight" 8 "${SR1}" "${TMPD}/s1.stage4.tar.xz")"; rc1=$?
if [ "${rc1}" -eq 0 ] && check_unpacked_fits "${out1}"; then
  ok "a 3 MiB payload beside 32 MiB of usr/src + var/cache + tmp fits an 8 MiB root with no grow (measured $(field "${out1}" payload_mib) MiB)"
else
  bad "the 11-11 shape did not fit cleanly (rc=${rc1}): $(printf '%s' "${out1}" | tr '\n' ' ')"
fi
# Measure what shipped: unpack the stage4 the extracted pack wrote and du it the same way.
if [ -s "${TMPD}/s1.stage4.tar.xz" ]; then
  members="$(tar -tJf "${TMPD}/s1.stage4.tar.xz")"
  if printf '%s\n' "${members}" | grep -E '^\./(usr/src/.|var/cache|tmp/.)' >/dev/null; then
    bad "the stage4 carries what the list excludes: $(printf '%s\n' "${members}" | grep -E '^\./(usr/src/.|var/cache|tmp/.)' | head -3 | tr '\n' ' ')"
  else
    ok "the stage4 carries no usr/src, var/cache or tmp/ contents"
  fi
  mkdir -p "${TMPD}/unpacked"
  tar -C "${TMPD}/unpacked" -xJf "${TMPD}/s1.stage4.tar.xz"
  shipped=$(cd "${TMPD}/unpacked" && du -sxBM . | cut -f1 | tr -dc '0-9')
  measured=$(field "${out1}" payload_mib)
  if [ -n "${measured}" ] && [ "${measured}" -ge "${shipped}" ] && [ "${measured}" -le $(( shipped + 1 )) ]; then
    ok "the pre-flight measured what the stage4 ships (${measured} MiB measured, ${shipped} MiB unpacked)"
  else
    bad "the pre-flight measured ${measured:-nothing} MiB but the stage4 unpacks to ${shipped} MiB"
  fi
else
  bad "the extracted pack wrote no stage4 tarball"
fi
# Negative control: the main-branch measurement (du over the whole sysroot).
sed 's/du -sxBM "\${STAGE4_PACK_EXCLUDES\[@\]}" \./du -sxBM ./' "${TMPD}/preflight" > "${TMPD}/nc-whole"
if cmp -s "${TMPD}/preflight" "${TMPD}/nc-whole"; then
  bad "negative control (whole-sysroot du) did not change the extracted text"
else
  nc="$(run_case "${TMPD}/pack" "${TMPD}/nc-whole" 8 "${SR1}" "${TMPD}/nc1.stage4.tar.xz")"
  check_unpacked_fits "${nc}" \
    && bad "negative control: a whole-sysroot du still read as fitting — section 3 cannot see the 11-11 defect" \
    || ok "negative control: a whole-sysroot du (the 11-11 measurement) is caught"
fi

# ─────────────────────────────────────────────────────────────────────────────
# A payload that really does not fit: 12 MiB into the 8 MiB root.
SR2="${TMPD}/sysroot-big"
mkdir -p "${SR2}/usr/lib" "${SR2}/etc"
mib "${SR2}/usr/lib/payload" 12
echo 'hostname=pki' > "${SR2}/etc/hostname"

# check_grown <log> <rc> — exit 0 when the root was grown to the x86 formula and every
# derived size was recomputed from the grown root.
check_grown() {
  [ "$2" -eq 0 ] || return 1
  case "$1" in *auto-growing*) ;; *) return 1 ;; esac
  local p r i c
  p=$(field "$1" payload_mib); r=$(field "$1" ROOT_MiB); i=$(field "$1" img_size_mib); c=$(field "$1" cap_mib)
  [ -n "${p}" ] && [ -n "${r}" ] && [ -n "${i}" ] && [ -n "${c}" ] || return 1
  [ "${r}" -eq $(( (p * 115 / 100 / 1024 + 1) * 1024 )) ] \
    && [ "${i}" -eq $(( 1 + 512 + r + 1 )) ] \
    && [ "${c}" -eq $(( r * 93 / 100 )) ] \
    && [ "${c}" -ge "${p}" ]
}

echo "-- 4) a payload that does not fit GROWS the root (EXECUTED) --"
out2="$(run_case "${TMPD}/pack" "${TMPD}/preflight" 8 "${SR2}" "${TMPD}/s2.stage4.tar.xz")"; rc2=$?
if check_grown "${out2}" "${rc2}"; then
  ok "12 MiB into an 8 MiB root: grown to $(field "${out2}" ROOT_MiB) MiB, image $(field "${out2}" img_size_mib) MiB, usable $(field "${out2}" cap_mib) MiB, exit 0"
else
  bad "an oversized payload was not grown cleanly (rc=${rc2}): $(printf '%s' "${out2}" | tr '\n' ' ')"
fi
case "${out2}" in
  *"fits the $(field "${out2}" ROOT_MiB) MiB root"*) ok "the Pre-flight line reports the grown root" ;;
  *) bad "the Pre-flight line does not report the grown root: $(printf '%s' "${out2}" | grep 'Pre-flight' || true)" ;;
esac
# At the real scale: a du that reports the 11-11 number (stubbed, so no 15 GiB fixture).
mkdir -p "${TMPD}/bin"
cat > "${TMPD}/bin/du" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$PWD $*" > "${DU_ARGV_LOG}"
printf '15450M\t.\n'
STUB
chmod +x "${TMPD}/bin/du"
out3="$(DU_ARGV_LOG="${TMPD}/du-argv" PATH="${TMPD}/bin:${PATH}" \
        run_case "${TMPD}/pack" "${TMPD}/preflight" 9216 "${SR2}" "${TMPD}/s3.stage4.tar.xz")"; rc3=$?
if check_grown "${out3}" "${rc3}" && [ "$(field "${out3}" ROOT_MiB)" = 18432 ] && [ "$(field "${out3}" img_size_mib)" = 18946 ]; then
  ok "15450 MiB into the 9216 MiB node root: grown to 18432 MiB (the size main's error told you to pass), image 18946 MiB"
else
  bad "the 15450 MiB case did not grow to 18432 (rc=${rc3}): $(printf '%s' "${out3}" | tr '\n' ' ')"
fi
argv="$(cat "${TMPD}/du-argv" 2>/dev/null || true)"
case "${argv}" in
  "${SR2} -sxBM --exclude=./usr/src --exclude=./var/cache --exclude=./tmp/* .") ok "du runs inside the sysroot with the pack's three excludes" ;;
  *) bad "du ran as '${argv:-<not run>}'" ;;
esac
# Negative controls: main's fatal branch, and each recompute dropped.
awk '
  /AUTO-GROW \(was a fatal error/ { skip = 1 }
  skip && /^    fi$/ { print "        err \"Payload ${payload_mib} MiB exceeds the ${ROOT_MiB} MiB root partition (usable ~${cap_mib} MiB).\""; print "        exit 1"; skip = 0 }
  !skip { print }' "${TMPD}/preflight" > "${TMPD}/nc-fatal"
# Drop the first line matching $1 inside the grow branch (and only that line).
drop_in_grow() {
  awk -v re="$1" '/AUTO-GROW \(was a fatal error/{g=1} g && !d && $0 ~ re {d=1; next} {print}' "${TMPD}/preflight"
}
drop_in_grow 'img_size_mib=[$][(][(] 1 [+] 512 [+] ROOT_MiB [+] 1 [)][)]' > "${TMPD}/nc-noimg"
drop_in_grow 'cap_mib=[$][(][(] ROOT_MiB [*] 93 / 100 [)][)]' > "${TMPD}/nc-nocap"
pf_lines=$(wc -l < "${TMPD}/preflight")
for nc_name in fatal noimg nocap; do
  f="${TMPD}/nc-${nc_name}"
  if cmp -s "${TMPD}/preflight" "${f}"; then
    bad "negative control (${nc_name}) did not change the extracted text"; continue
  fi
  if [ "${nc_name}" != fatal ] && [ "$(wc -l < "${f}")" -ne $(( pf_lines - 1 )) ]; then
    bad "negative control (${nc_name}) removed $(( pf_lines - $(wc -l < "${f}") )) lines, not exactly the one recompute"; continue
  fi
  nco="$(run_case "${TMPD}/pack" "${f}" 8 "${SR2}" "${TMPD}/nc.stage4.tar.xz")"; ncrc=$?
  check_grown "${nco}" "${ncrc}" \
    && bad "negative control (${nc_name}) still read as a clean grow — section 4 cannot see it" \
    || ok "negative control (${nc_name}) is caught"
done

echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
