#!/usr/bin/env bash
# test-cloud-package.sh — hermetic unit test for scripts/cloud-package.sh, the
# operator-facing raw->cloud-format packager (qcow2 / vhd-fixed / raw).
#
# NOTHING here needs qemu, root, network or a real image: inputs are tiny
# truncate-made sparse files named like real builder artifacts, and qemu-img is
# a RECORDING STUB on the SNAP_QEMU_IMG seam that logs its argv PLUS the byte
# size of the convert source AT CALL TIME — which is how the Azure whole-MiB
# round-UP math is proven (the stub sees the padded size, the input must stay
# untouched). Covered:
#   • raw passthrough: byte-identical copy, sha256/BYTES in the manifest match
#     reality, qemu-img never invoked,
#   • qcow2: exact `convert -f raw -O qcow2` argv,
#   • vhd-fixed: `-O vpc -o subformat=fixed,force_size`; the compact-image shape
#     (1+512+ROOT+1 MiB, already whole-MiB) converts UNPADDED from the original,
#     an odd-size input is padded UP (never down) on a working copy that is
#     cleaned afterwards,
#   • refusal paths: ARM/-arm64- names, unrecognizable names, .iso/.xz, qcow2
#     magic, empty/missing inputs, bad --format, overwrite, missing qemu-img,
#   • manifest shape + append behaviour.
#
# Run: bash tests/scripts/test-cloud-package.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CP="${REPO}/scripts/cloud-package.sh"
[ -f "${CP}" ] || { echo "  FAIL script missing: ${CP}"; exit 1; }

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
MIB=1048576

echo "== cloud-package.sh unit test =="

# ── Fixtures: builder-named sparse inputs + the recording qemu-img stub ───────
# X86: the real x86 naming shape <brand>-x86-amd64-<role>-<env>-<stamp>.img.
# A few real bytes up front so raw-copy sha256 equality is non-vacuous.
X86_IMG="${WORK}/acme-x86-amd64-pki-test-20260719-120000.img"
printf 'pretend-x86-gpt-esp-root-bytes' > "${X86_IMG}"
truncate -s $(( 3 * MIB + 4096 )) "${X86_IMG}"   # odd-size on purpose (see vhd cases)

# The compact-image shape the x86 builder actually emits: 1 gap + 512 ESP +
# ROOT + 1 slack MiB — a whole-MiB (but not GiB-round) size. ROOT stand-in 2 MiB
# keeps the fixture tiny; the MATH is size-relative, not size-dependent.
WHOLE_IMG="${WORK}/acme-x86-amd64-be-prod-20260719-130000.img"
truncate -s $(( (1 + 512 + 2 + 1) * MIB )) "${WHOLE_IMG}"

STUB_BIN="${WORK}/bin"; mkdir -p "${STUB_BIN}"
QIMG_LOG="${WORK}/qemu-img.log"; export QIMG_LOG
cat > "${STUB_BIN}/qemu-img" <<'EOF'
#!/usr/bin/env bash
# Recording qemu-img stub: one line per call —
#   ARGV <argv> | SRCSIZE <bytes of the convert SOURCE at call time>
# and writes deterministic content to the destination so the caller's manifest
# sha256/BYTES can be verified against a real file.
set -u
argv="$*"
src=""; dst=""
if [ "${1:-}" = "convert" ]; then
    shift
    pos=()
    while [ $# -gt 0 ]; do
        case "$1" in
            -f|-O|-o) shift 2 ;;
            -*)       shift ;;
            *)        pos+=("$1"); shift ;;
        esac
    done
    src="${pos[0]:-}"; dst="${pos[1]:-}"
fi
srcsize="-"
[ -n "${src}" ] && [ -e "${src}" ] && srcsize="$(stat -c %s "${src}")"
printf 'ARGV %s | SRCSIZE %s\n' "${argv}" "${srcsize}" >> "${QIMG_LOG:?}"
[ -n "${dst}" ] && printf 'stub-converted %s\n' "$(basename "${src}")" > "${dst}"
exit 0
EOF
chmod +x "${STUB_BIN}/qemu-img"

run_cp() {  # run_cp <out-dir> <args...> — stubbed qemu-img, captured output
    SNAP_QEMU_IMG="${STUB_BIN}/qemu-img" bash "${CP}" --out-dir "$@"
}
SHAPE='^FORMAT (qcow2|vhd-fixed|raw) FILE [^ ]+ BYTES [0-9]+ SHA256 [0-9a-f]{64}$'

# ── 0. static ────────────────────────────────────────────────────────────────
bash -n "${CP}" && ok "bash -n: parses" || bad "bash -n: syntax error"
bash "${CP}" --help >/dev/null 2>&1 && ok "--help exits 0" || bad "--help should exit 0"

# ── 1. raw passthrough: byte-identical, manifest true, no qemu-img ───────────
OUT1="${WORK}/out-raw"
o1="$(run_cp "${OUT1}" --img "${X86_IMG}" --format raw 2>&1)"; rc=$?
[ "${rc}" -eq 0 ] && ok "raw: exits 0" || bad "raw: expected exit 0, got ${rc}: ${o1}"
R_OUT="${OUT1}/$(basename "${X86_IMG}")"
[ -f "${R_OUT}" ] && ok "raw: <base>.img landed in --out-dir" || bad "raw: missing ${R_OUT}"
[ "$(stat -c %s "${R_OUT}")" -eq "$(stat -c %s "${X86_IMG}")" ] \
    && ok "raw: byte count preserved" || bad "raw: size differs from input"
[ "$(sha256sum "${R_OUT}" | awk '{print $1}')" = "$(sha256sum "${X86_IMG}" | awk '{print $1}')" ] \
    && ok "raw: sha256 identical to input (byte-identical copy)" || bad "raw: copy is not byte-identical"
[ ! -e "${QIMG_LOG}" ] && ok "raw: qemu-img never invoked" || bad "raw: qemu-img was invoked for a raw copy"

M1="${OUT1}/cloud-package.manifest"
[ -f "${M1}" ] && ok "raw: manifest file created" || bad "raw: manifest missing"
line1="$(tail -n1 "${M1}" 2>/dev/null)"
echo "${line1}" | grep -Eq "${SHAPE}" && ok "raw: manifest line matches the pinned shape" || bad "raw: bad manifest line: '${line1}'"
echo "${o1}" | grep -qF "${line1}" && ok "raw: manifest line echoed to stdout" || bad "raw: manifest line not echoed"
[ "$(echo "${line1}" | awk '{print $6}')" = "$(stat -c %s "${R_OUT}")" ] \
    && ok "raw: manifest BYTES is the real artifact size" || bad "raw: manifest BYTES wrong"
[ "$(echo "${line1}" | awk '{print $8}')" = "$(sha256sum "${R_OUT}" | awk '{print $1}')" ] \
    && ok "raw: manifest SHA256 is the real artifact hash" || bad "raw: manifest SHA256 wrong"

# ── 2. qcow2: exact convert argv + true manifest over the stub's output ──────
OUT2="${WORK}/out-qcow2"
o2="$(run_cp "${OUT2}" --img "${X86_IMG}" --format qcow2 2>&1)"; rc=$?
[ "${rc}" -eq 0 ] && ok "qcow2: exits 0" || bad "qcow2: expected exit 0, got ${rc}: ${o2}"
Q_OUT="${OUT2}/$(basename "${X86_IMG%.img}").qcow2"
[ -f "${Q_OUT}" ] && ok "qcow2: <base>.qcow2 landed" || bad "qcow2: missing ${Q_OUT}"
grep -Eq "^ARGV convert -f raw -O qcow2 ${X86_IMG} ${Q_OUT} \|" "${QIMG_LOG}" \
    && ok "qcow2: exact 'convert -f raw -O qcow2 <in> <out>' argv" || bad "qcow2: wrong argv: $(cat "${QIMG_LOG}" 2>/dev/null)"
line2="$(tail -n1 "${OUT2}/cloud-package.manifest")"
[ "$(echo "${line2}" | awk '{print $2}')" = "qcow2" ] && ok "qcow2: manifest FORMAT token" || bad "qcow2: FORMAT token wrong"
[ "$(echo "${line2}" | awk '{print $8}')" = "$(sha256sum "${Q_OUT}" | awk '{print $1}')" ] \
    && ok "qcow2: manifest SHA256 hashes the PRODUCED artifact" || bad "qcow2: manifest SHA256 wrong"
# BYTES must be the PRODUCED artifact's size, not the input's — the stub's output
# is deliberately tiny, so stamping the input size here would fail loudly.
[ "$(echo "${line2}" | awk '{print $6}')" = "$(stat -c %s "${Q_OUT}")" ] \
    && ok "qcow2: manifest BYTES is the PRODUCED artifact size" || bad "qcow2: manifest BYTES wrong (input size leaked?)"

# ── 3. vhd-fixed, compact-image shape (1+512+ROOT+1 MiB): NO padding ─────────
# The builder's own size is already whole-MiB — the round-up must be a no-op:
# converted straight from the ORIGINAL file at its EXACT size (an over-round
# here would silently grow every Azure disk).
: > "${QIMG_LOG}"
OUT3="${WORK}/out-vhd-whole"
o3="$(run_cp "${OUT3}" --img "${WHOLE_IMG}" --format vhd-fixed 2>&1)"; rc=$?
[ "${rc}" -eq 0 ] && ok "vhd whole-MiB: exits 0" || bad "vhd whole-MiB: expected exit 0, got ${rc}: ${o3}"
V_OUT="${OUT3}/$(basename "${WHOLE_IMG%.img}").vhd"
[ -f "${V_OUT}" ] && ok "vhd whole-MiB: <base>.vhd landed" || bad "vhd whole-MiB: missing ${V_OUT}"
vline="$(grep '^ARGV convert' "${QIMG_LOG}")"
echo "${vline}" | grep -q -- '-O vpc' && ok "vhd whole-MiB: -O vpc" || bad "vhd whole-MiB: missing -O vpc"
echo "${vline}" | grep -q -- '-o subformat=fixed,force_size' \
    && ok "vhd whole-MiB: subformat=fixed,force_size" || bad "vhd whole-MiB: missing fixed/force_size opts"
echo "${vline}" | grep -qF " ${WHOLE_IMG} " \
    && ok "vhd whole-MiB: converts the ORIGINAL (no pad copy)" || bad "vhd whole-MiB: did not convert the original"
[ "$(echo "${vline}" | awk -F'SRCSIZE ' '{print $2}')" = "$(( 516 * MIB ))" ] \
    && ok "vhd whole-MiB: source size at convert time is EXACTLY 516 MiB (no over-round)" \
    || bad "vhd whole-MiB: source size wrong: ${vline}"
[ "$(stat -c %s "${WHOLE_IMG}")" -eq "$(( 516 * MIB ))" ] \
    && ok "vhd whole-MiB: input .img untouched" || bad "vhd whole-MiB: input was mutated"
vmline="$(tail -n1 "${OUT3}/cloud-package.manifest")"
[ "$(echo "${vmline}" | awk '{print $6}')" = "$(stat -c %s "${V_OUT}")" ] \
    && ok "vhd whole-MiB: manifest BYTES is the PRODUCED artifact size" || bad "vhd whole-MiB: manifest BYTES wrong (input size leaked?)"

# ── 4. vhd-fixed, odd-size input: padded UP on a working copy ────────────────
# 3 MiB + 4096 B must become EXACTLY 4 MiB (round UP — rounding DOWN would
# truncate the root partition), via a temp copy, with the input never grown and
# the temp cleaned up afterwards.
: > "${QIMG_LOG}"
OUT4="${WORK}/out-vhd-odd"
o4="$(run_cp "${OUT4}" --img "${X86_IMG}" --format vhd-fixed 2>&1)"; rc=$?
[ "${rc}" -eq 0 ] && ok "vhd odd-size: exits 0" || bad "vhd odd-size: expected exit 0, got ${rc}: ${o4}"
vline="$(grep '^ARGV convert' "${QIMG_LOG}")"
srcsize="$(echo "${vline}" | awk -F'SRCSIZE ' '{print $2}')"
[ "${srcsize}" = "$(( 4 * MIB ))" ] \
    && ok "vhd odd-size: 3MiB+4096B rounds UP to exactly 4 MiB at convert time" \
    || bad "vhd odd-size: expected $(( 4 * MIB )), qemu-img saw '${srcsize}'"
echo "${vline}" | grep -qF " ${X86_IMG} " \
    && bad "vhd odd-size: converted the INPUT in place (must use a padded working copy)" \
    || ok "vhd odd-size: converted a padded working copy, not the input"
[ "$(stat -c %s "${X86_IMG}")" -eq "$(( 3 * MIB + 4096 ))" ] \
    && ok "vhd odd-size: input .img never mutated" || bad "vhd odd-size: input size changed"
if ls "${OUT4}"/*.pad.raw >/dev/null 2>&1; then
    bad "vhd odd-size: pad temp left behind in --out-dir"
else
    ok "vhd odd-size: pad temp cleaned up"
fi
line4="$(tail -n1 "${OUT4}/cloud-package.manifest")"
echo "${line4}" | grep -Eq "${SHAPE}" && ok "vhd odd-size: manifest line shape" || bad "vhd odd-size: bad manifest line: '${line4}'"

# ── 5. manifest APPENDS across runs in one out-dir ───────────────────────────
o5="$(run_cp "${OUT2}" --img "${WHOLE_IMG}" --format qcow2 2>&1)" \
    && ok "second run into the same out-dir succeeds" || bad "second run failed: ${o5}"
[ "$(wc -l < "${OUT2}/cloud-package.manifest")" -eq 2 ] \
    && ok "manifest appends (2 lines after 2 runs)" || bad "manifest did not append"
[ "$(grep -cE "${SHAPE}" "${OUT2}/cloud-package.manifest")" -eq 2 ] \
    && ok "every manifest line matches the pinned shape" || bad "a manifest line broke the shape"

# ── 6. refusal paths — all must exit non-zero, create NO artifact ────────────
refuse() {  # refuse <label> <stderr-regex> <args...>
    local label="$1" want="$2"; shift 2
    local out rc outdir="${WORK}/out-refuse"
    rm -rf "${outdir}"
    out="$(SNAP_QEMU_IMG="${STUB_BIN}/qemu-img" bash "${CP}" --out-dir "${outdir}" "$@" 2>&1)"; rc=$?
    if [ "${rc}" -eq 0 ]; then bad "${label}: should refuse (exit non-zero)"; return; fi
    echo "${out}" | grep -Eqi "${want}" && ok "${label}" || bad "${label}: refusal reason missing /${want}/: ${out}"
    if [ -d "${outdir}" ] && [ -n "$(find "${outdir}" -type f ! -name '*.manifest' 2>/dev/null)" ]; then
        bad "${label}: refusal still left an artifact behind"
    fi
}

# ARM builder names — every ARM platform stamps -arm64-; all must die with the
# u-boot/L4T explanation, for ALL three formats (the refusal is format-independent).
ARM_RPI="${WORK}/acme-rpi5-arm64-pki-test-20260719.img";                    truncate -s "${MIB}" "${ARM_RPI}"
ARM_JET="${WORK}/acme-jetson-orin-nano-arm64-edge_ai-prod-20260719.img";   truncate -s "${MIB}" "${ARM_JET}"
# Match on phrases unique to the ARM refusal die — NOT 'ARM', which the fixture
# filename itself contains and every die message echoes (any die would match).
refuse "refusal: rpi5 -arm64- image (qcow2)"    'u-boot/L4T|cloud-viable'    --img "${ARM_RPI}" --format qcow2
refuse "refusal: jetson -arm64- image (vhd)"    'u-boot/L4T|cloud-viable'    --img "${ARM_JET}" --format vhd-fixed
refuse "refusal: rpi5 -arm64- image (raw too)"  'u-boot/L4T|cloud-viable'    --img "${ARM_RPI}" --format raw
# Unrecognizable name: fail closed rather than package an unknown platform.
NONAME="${WORK}/backup-of-something.img"; truncate -s "${MIB}" "${NONAME}"
refuse "refusal: name without -x86-amd64- marker" 'x86-amd64|provenance' --img "${NONAME}" --format qcow2
# Wrong artifact kinds by extension.
ISO="${WORK}/acme-frite-la-frite-arm64-live-test.iso"; truncate -s "${MIB}" "${ISO}"
XZ="${WORK}/acme-x86-amd64-pki-test-20260719.img.xz";  truncate -s "${MIB}" "${XZ}"
refuse "refusal: .iso artifact"                 'ISO|optical'   --img "${ISO}" --format qcow2
refuse "refusal: compressed .img.xz"            'unxz|decompress' --img "${XZ}" --format qcow2
# A qcow2 wearing a .img name: caught by magic, not name.
QCOW_LIE="${WORK}/acme-x86-amd64-pki-test-lie.img"
printf 'QFI\xfb\x00\x00\x00\x03' > "${QCOW_LIE}"; truncate -s "${MIB}" "${QCOW_LIE}"
refuse "refusal: qcow2 magic behind a .img name" 'QFI|already'  --img "${QCOW_LIE}" --format vhd-fixed
# Missing / empty inputs.
refuse "refusal: missing input file"            'not found'     --img "${WORK}/nope-x86-amd64-x.img" --format raw
EMPTY="${WORK}/acme-x86-amd64-pki-test-empty.img"; : > "${EMPTY}"
refuse "refusal: empty (0-byte) input"          'EMPTY|hollow'  --img "${EMPTY}" --format raw
# Bad flags.
refuse "refusal: unknown --format"              'qcow2 \| vhd-fixed \| raw' --img "${X86_IMG}" --format vmdk
out="$(bash "${CP}" --img "${X86_IMG}" --format raw 2>&1)"; rc=$?
[ "${rc}" -ne 0 ] && echo "${out}" | grep -q 'Missing --out-dir' \
    && ok "refusal: missing --out-dir shows usage" || bad "refusal: missing --out-dir accepted (rc=${rc})"
out="$(bash "${CP}" --bogus 2>&1)"; rc=$?
[ "${rc}" -ne 0 ] && echo "${out}" | grep -q 'Unknown option' \
    && ok "refusal: unknown option shows usage" || bad "refusal: unknown option accepted (rc=${rc})"

# ── 7. overwrite refusal: a second run must not clobber the first artifact ───
sha_before="$(sha256sum "${R_OUT}" | awk '{print $1}')"
o7="$(run_cp "${OUT1}" --img "${X86_IMG}" --format raw 2>&1)"; rc=$?
[ "${rc}" -ne 0 ] && ok "overwrite: second raw run into the same out-dir refuses" \
    || bad "overwrite: clobbered an existing artifact"
echo "${o7}" | grep -q 'already exists' && ok "overwrite: names the existing file" || bad "overwrite: unexplained refusal: ${o7}"
[ "$(sha256sum "${R_OUT}" | awk '{print $1}')" = "${sha_before}" ] \
    && ok "overwrite: prior artifact bytes untouched" || bad "overwrite: prior artifact changed"

# ── 8. qemu-img seam fails LOUD when the tool is absent (conversions only) ───
out="$(SNAP_QEMU_IMG="${WORK}/no-such-qemu-img" bash "${CP}" --out-dir "${WORK}/out-noq" --img "${WHOLE_IMG}" --format qcow2 2>&1)"; rc=$?
[ "${rc}" -ne 0 ] && echo "${out}" | grep -q 'qemu-img not found' \
    && ok "missing qemu-img: qcow2 dies with the install hint" || bad "missing qemu-img: qcow2 should die (rc=${rc}): ${out}"
[ ! -e "${WORK}/out-noq/$(basename "${WHOLE_IMG%.img}").qcow2" ] \
    && ok "missing qemu-img: no artifact emitted" || bad "missing qemu-img: artifact appeared without a converter"
out="$(SNAP_QEMU_IMG="${WORK}/no-such-qemu-img" bash "${CP}" --out-dir "${WORK}/out-noq" --img "${WHOLE_IMG}" --format raw 2>&1)"; rc=$?
[ "${rc}" -eq 0 ] && ok "missing qemu-img: raw copy still works (no converter needed)" \
    || bad "missing qemu-img: raw should not need qemu-img (rc=${rc}): ${out}"

echo "== done: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
