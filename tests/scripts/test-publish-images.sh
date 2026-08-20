#!/usr/bin/env bash
# test-publish-images.sh — hermetic unit test for scripts/publish-images.sh,
# the LOCAL image-publishing export verb (Phase 1 of the image-publishing
# outline recorded on hugmesh-host-shell#19).
#
# NOTHING here needs qemu, root, network or a real image: the session tree is
# a synthetic out/sessions/<id>/ fixture — tiny xz-magic / CD001-stamped files
# wearing the builders' real artifact names, NEXT TO planted secret material
# (keys-*/ with an OpenSSH private key, secureboot/ signing keys, a wl-*/
# sysroot with a shadow file, logs and locks) exactly as a real session
# intermixes them. Covered:
#   • happy path: images + mesh manifest + publish-manifest.json + SHA256SUMS
#     land, `sha256sum -c` verifies, the parseable IMAGE/FILE/BYTES/SHA256
#     lines are true, rpi5's long role spelling normalizes (backend -> be.rpi5),
#   • THE SECURITY LINE: nothing from keys-*/, secureboot/, wl-*/ (sysroots),
#     *.log or *.lock can reach the export — structurally (top-level regular
#     files only) and by final sweep,
#   • poisoned-tree REFUSALS (whole export refused, staging cleaned, no dest):
#     a deny∩allow name (keys-*.img.xz), a symlink wearing an artifact name,
#     an artifact-suffixed file outside the builders' naming, a PEM wearing
#     .img.xz (no xz magic), a fake .iso (no CD001), a 0-byte artifact, a
#     secret-laced mesh manifest (secret-scan.sh gate), an existing --dest,
#     a --dest nested inside the session,
#   • --images filter (and the unknown-id fatal), --hardlink, session-id
#     lookup via HUGMESH_SESSIONS_ROOT,
#   • manifest determinism (byte-identical re-run) + detached Ed25519 signing
#     (PROVENANCE_SIGNING_KEY seam, deterministic signature, openssl-verifiable).
#
# Run: bash tests/scripts/test-publish-images.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PI="${REPO}/scripts/publish-images.sh"
[ -f "${PI}" ] || { echo "  FAIL script missing: ${PI}"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "  FAIL python3 not available (JSON validation)"; exit 2; }
command -v openssl >/dev/null 2>&1 || { echo "  FAIL openssl not available (signing legs)"; exit 2; }

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT

echo "== publish-images.sh unit test =="

# ── Fixtures: a synthetic session tree with real builder names + planted secrets ──
SID="20260807-071119-5c1ccb"

mk_xz() {  # mk_xz <path> — xz magic + unique payload (shas must be non-vacuous)
    printf '\xfd\x37\x7a\x58\x5a\x00payload:%s' "$(basename "$1")" > "$1"
    truncate -s 8192 "$1"
}
mk_iso() {  # mk_iso <path> — ISO9660 CD001 signature at byte 32769
    printf 'iso-payload:%s' "$(basename "$1")" > "$1"
    truncate -s 40000 "$1"
    printf 'CD001' | dd of="$1" bs=1 seek=32769 conv=notrunc 2>/dev/null
}

X86_STEM="hugmesh-x86-amd64-pki-test-20260807T141137Z"
RPI_STEM="hugmesh-rpi5-arm64-backend-test-20260807T185415Z"

mk_session() {  # mk_session <dir> — the full intermixed tree
    local d="$1"
    mkdir -p "${d}"
    mk_xz  "${d}/${X86_STEM}.img.xz"
    mk_iso "${d}/${X86_STEM}.installer.iso"
    mk_xz  "${d}/${X86_STEM}.fs.tar.xz"
    mk_xz  "${d}/${X86_STEM}.stage4.tar.xz"
    mk_xz  "${d}/${RPI_STEM}.img.xz"
    mk_iso "${d}/${RPI_STEM}.iso"
    cat > "${d}/hugmesh-mesh-manifest.json" <<'JSON'
{
  "format": 2,
  "brand": "hugmesh",
  "org": "Example-Org",
  "cluster_domain": "example.test",
  "images": [
    {"id": "pki.x86", "role": "pki", "platform": "x86", "flavor": ""},
    {"id": "be.rpi5", "role": "be", "platform": "rpi5", "flavor": ""}
  ]
}
JSON
    # NEVER-publishable siblings, as a real session lays them out.
    mkdir -p "${d}/keys-pki.x86" "${d}/keys-be.rpi5" "${d}/secureboot" "${d}/wl-be.rpi5/sysroot/etc"
    printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXk\n-----END OPENSSH PRIVATE KEY-----\n' \
        > "${d}/keys-pki.x86/id_ed25519"
    printf 'device-provisioning-key-material\n' > "${d}/keys-be.rpi5/device.key"
    printf -- '-----BEGIN PRIVATE KEY-----\nsecureboot-db\n-----END PRIVATE KEY-----\n' > "${d}/secureboot/db.key"
    printf 'root:$6$saltsalt$hashhashhash:19000:0:99999:7:::\n' > "${d}/wl-be.rpi5/sysroot/etc/shadow"
    printf 'emerge transcript\n' > "${d}/build.log"
    printf 'emerge transcript\n' > "${d}/build-pki.x86.log"
    printf 'lock\n' > "${d}/wl-be.rpi5.lock"
}

SESS="${WORK}/sessions/${SID}"
mk_session "${SESS}"

run_pub() { bash "${PI}" "$@" 2>&1; }
IMG_LINE='^IMAGE [a-z0-9_.-]+ FILE [^ ]+ BYTES [0-9]+ SHA256 [0-9a-f]{64}$'

# ── 0. static ────────────────────────────────────────────────────────────────
bash -n "${PI}" && ok "bash -n: parses" || bad "bash -n: syntax error"
bash "${PI}" --help >/dev/null 2>&1 && ok "--help exits 0" || bad "--help should exit 0"
out="$(run_pub "${SESS}")"; rc=$?
[ "${rc}" -ne 0 ] && echo "${out}" | grep -q 'Missing --dest' \
    && ok "missing --dest shows usage" || bad "missing --dest accepted (rc=${rc})"

# ── 1. happy path: full export ───────────────────────────────────────────────
D1="${WORK}/pub1"
o1="$(run_pub "${SESS}" --dest "${D1}")"; rc=$?
[ "${rc}" -eq 0 ] && ok "full export exits 0" || bad "full export: expected exit 0, got ${rc}: ${o1}"
[ -d "${D1}" ] && ok "dest created" || bad "dest missing"
if ls "${WORK}"/pub1.staging.* >/dev/null 2>&1; then
    bad "staging dir left behind next to dest"
else
    ok "staging dir cleaned up (moved into place)"
fi

# THE SECURITY LINE: no keys/secureboot/wl/sysroot/log/lock material anywhere.
leaks="$(find "${D1}" \( -iname 'keys-*' -o -iname 'secureboot*' -o -iname 'wl-*' \
    -o -iname '*sysroot*' -o -name '*.log' -o -name '*.lock' -o -iname '*.key' \
    -o -iname 'id_ed25519*' -o -iname 'shadow*' \) -print 2>/dev/null)"
[ -z "${leaks}" ] && ok "SECURITY: no key/secureboot/sysroot/log material in the export" \
    || bad "SECURITY: secret material leaked into the export: ${leaks}"
[ -z "$(find "${D1}" -mindepth 1 -type d)" ] && ok "export is a flat tree (no subdirectories)" \
    || bad "export grew subdirectories"
[ -z "$(find "${D1}" -type l)" ] && ok "export carries no symlinks" || bad "export carries symlinks"
if grep -rl 'BEGIN OPENSSH PRIVATE KEY\|BEGIN PRIVATE KEY' "${D1}" >/dev/null 2>&1; then
    bad "SECURITY: private-key bytes present in the export"
else
    ok "SECURITY: no private-key bytes anywhere in the export"
fi

# Exact content: 6 artifacts + mesh manifest + publish manifest + SHA256SUMS.
n_files="$(find "${D1}" -maxdepth 1 -type f | wc -l)"
[ "${n_files}" -eq 9 ] && ok "exactly 9 files ship (6 artifacts + 3 sidecars)" \
    || bad "expected 9 files, found ${n_files}: $(ls "${D1}")"
for f in "${X86_STEM}.img.xz" "${X86_STEM}.installer.iso" "${X86_STEM}.fs.tar.xz" \
         "${X86_STEM}.stage4.tar.xz" "${RPI_STEM}.img.xz" "${RPI_STEM}.iso" \
         hugmesh-mesh-manifest.json publish-manifest.json SHA256SUMS; do
    [ -f "${D1}/${f}" ] || bad "missing from export: ${f}"
done
ok "every expected file is present"
[ ! -e "${D1}/publish-manifest.json.sig" ] && ok "unsigned run emits no .sig" || bad "unsigned run emitted a .sig"
echo "${o1}" | grep -q 'UNSIGNED' && ok "unsigned run warns UNSIGNED" || bad "unsigned run did not warn"

# Verifiability + parseable lines.
( cd "${D1}" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ) \
    && ok "sha256sum -c SHA256SUMS verifies the export" || bad "SHA256SUMS does not verify"
n_lines="$(echo "${o1}" | grep -cE "${IMG_LINE}")"
[ "${n_lines}" -eq 6 ] && ok "6 parseable IMAGE lines echoed" || bad "expected 6 IMAGE lines, got ${n_lines}"
line="$(echo "${o1}" | grep "FILE ${D1}/${X86_STEM}.img.xz ")"
[ "$(echo "${line}" | awk '{print $6}')" = "$(stat -c %s "${D1}/${X86_STEM}.img.xz")" ] \
    && ok "IMAGE line BYTES is the real artifact size" || bad "IMAGE line BYTES wrong: ${line}"
[ "$(echo "${line}" | awk '{print $8}')" = "$(sha256sum "${D1}/${X86_STEM}.img.xz" | awk '{print $1}')" ] \
    && ok "IMAGE line SHA256 is the real artifact hash" || bad "IMAGE line SHA256 wrong: ${line}"
[ "$(sha256sum "${D1}/${X86_STEM}.img.xz" | awk '{print $1}')" = "$(sha256sum "${SESS}/${X86_STEM}.img.xz" | awk '{print $1}')" ] \
    && ok "exported artifact is byte-identical to the session's" || bad "exported artifact differs from source"
echo "${o1}" | grep -q "^IMAGE be.rpi5 FILE .*${RPI_STEM}.img.xz " \
    && ok "rpi5 long role spelling normalizes: backend -> be.rpi5" || bad "backend did not normalize to be.rpi5"
echo "${o1}" | grep -q "^IMAGE pki.x86 " && ok "x86 id pki.x86 stamped" || bad "pki.x86 id missing"

# Manifest: valid JSON, right schema, deterministic producedAt (newest builtAt).
python3 - "${D1}/publish-manifest.json" <<'PY' && ok "publish-manifest.json is valid JSON with the v1 contract" || bad "publish-manifest.json invalid or off-contract"
import json, sys
m = json.load(open(sys.argv[1]))
assert m["schema"] == "hugmesh.net/publish-images/v1"
assert m["session"]["id"] == "20260807-071119-5c1ccb"
assert m["producedAt"] == "2026-08-07T18:54:15Z"          # newest builtAt, never wall-clock
assert m["generator"]["producedBy"] == "hugmesh-generator"
assert len(m["images"]) == 6
ids = {e["id"] for e in m["images"]}
assert ids == {"pki.x86", "be.rpi5"}, ids
for e in m["images"]:
    assert set(e) == {"id","role","platform","flavor","kind","file","bytes","sha256","builtAt"}, e
    assert e["bytes"] > 0 and len(e["sha256"]) == 64
be = [e for e in m["images"] if e["id"] == "be.rpi5"][0]
assert be["role"] == "be" and be["platform"] == "rpi5"
assert be["builtAt"] == "2026-08-07T18:54:15Z"
PY

# ── 2. determinism: a re-run yields a byte-identical manifest ────────────────
D2="${WORK}/pub2"
run_pub "${SESS}" --dest "${D2}" >/dev/null; rc=$?
[ "${rc}" -eq 0 ] || bad "re-run failed (rc=${rc})"
[ "$(sha256sum < "${D1}/publish-manifest.json")" = "$(sha256sum < "${D2}/publish-manifest.json")" ] \
    && ok "re-run publish-manifest.json is byte-identical (deterministic)" \
    || bad "manifest is not deterministic across runs"

# ── 3. --images filter + unknown-id fatal ────────────────────────────────────
D3="${WORK}/pub3"
o3="$(run_pub "${SESS}" --dest "${D3}" --images pki.x86)"; rc=$?
[ "${rc}" -eq 0 ] && ok "--images pki.x86 exits 0" || bad "--images pki.x86 failed: ${o3}"
[ -z "$(find "${D3}" -name "${RPI_STEM}*" -print 2>/dev/null)" ] \
    && ok "--images filter excludes the other image" || bad "--images shipped a filtered-out image"
[ "$(find "${D3}" -maxdepth 1 \( -name '*.img.xz' -o -name '*.iso' -o -name '*.tar.xz' \) | wc -l)" -eq 4 ] \
    && ok "--images pki.x86 ships that image's 4 artifacts" || bad "--images artifact count wrong"
o3b="$(run_pub "${SESS}" --dest "${WORK}/pub3b" --images nope.x86)"; rc=$?
[ "${rc}" -ne 0 ] && echo "${o3b}" | grep -q 'no artifact of session' \
    && ok "--images with an unknown id is FATAL (never a silent empty publish)" \
    || bad "--images nope.x86 should refuse (rc=${rc}): ${o3b}"
[ ! -e "${WORK}/pub3b" ] && ok "unknown-id refusal creates no dest" || bad "unknown-id refusal left a dest"

# ── 4. --hardlink + session-id lookup via HUGMESH_SESSIONS_ROOT ──────────────
D4="${WORK}/pub4"
o4="$(HUGMESH_SESSIONS_ROOT="${WORK}/sessions" bash "${PI}" "${SID}" --dest "${D4}" --hardlink 2>&1)"; rc=$?
[ "${rc}" -eq 0 ] && ok "session-id lookup via HUGMESH_SESSIONS_ROOT works" \
    || bad "session-id lookup failed (rc=${rc}): ${o4}"
[ "$(stat -c %i "${D4}/${X86_STEM}.img.xz")" = "$(stat -c %i "${SESS}/${X86_STEM}.img.xz")" ] \
    && ok "--hardlink links instead of copying (same inode)" || bad "--hardlink did not hardlink"

# ── 5. poisoned session trees: the WHOLE export must refuse ──────────────────
# Each case: a fresh copy of the good tree + one poison. Expect non-zero exit,
# the poison named, NO dest, and NO staging leftovers (fail-closed cleanup).
NPOISON=0
poison() {  # poison <label> <stderr-regex> <poison-cmd...>
    local label="$1" want="$2"; shift 2
    NPOISON=$((NPOISON+1))
    local sd="${WORK}/poison-${NPOISON}/${SID}" dest="${WORK}/poison-${NPOISON}-out"
    mk_session "${sd}"
    ( cd "${sd}" && "$@" ) || { bad "${label}: fixture setup failed"; return; }
    local out rc
    out="$(run_pub "${sd}" --dest "${dest}")"; rc=$?
    if [ "${rc}" -eq 0 ]; then bad "${label}: must refuse (exit non-zero)"; return; fi
    echo "${out}" | grep -Eqi "${want}" && ok "${label}" \
        || bad "${label}: refusal reason missing /${want}/: ${out}"
    [ ! -e "${dest}" ] || bad "${label}: refusal still created the dest"
    if ls "${dest}".staging.* >/dev/null 2>&1; then
        bad "${label}: refusal left a staging dir behind"
    fi
}

# (a) deny-list ∩ allow-list name: key material wearing an artifact suffix.
poison "poison: keys-*.img.xz (deny beats allow)" 'deny-list' \
    cp "keys-pki.x86/id_ed25519" "keys-pki.x86.img.xz"
# (b) a symlink wearing a valid artifact name, pointing INTO keys-*/.
poison "poison: symlink smuggling key bytes" 'SYMLINK' \
    ln -s "keys-pki.x86/id_ed25519" "hugmesh-x86-amd64-fe-test-20260807T193343Z.img.xz"
# (c) an artifact-suffixed file outside the builders' naming shape.
poison "poison: rogue evil.img.xz (unknown provenance)" 'provenance|naming' \
    bash -c 'printf "\xfd\x37\x7a\x58\x5a\x00x" > evil.img.xz'
# (d) a PEM private key wearing a well-formed .img.xz name (magic gate).
poison "poison: PEM inside a builder-named .img.xz" 'xz magic' \
    cp "keys-pki.x86/id_ed25519" "hugmesh-x86-amd64-fe-test-20260807T193343Z.img.xz"
# (e) a fake ISO without the ISO9660 signature.
poison "poison: fake .iso (no CD001)" 'ISO9660' \
    bash -c 'head -c 40000 /dev/zero > hugmesh-x86-amd64-fe-test-20260807T193343Z.live.iso'
# (f) a 0-byte artifact.
poison "poison: empty (0-byte) artifact" 'EMPTY|hollow' \
    touch "hugmesh-x86-amd64-fe-test-20260807T193343Z.img.xz"
# (g) a secret laced into the mesh manifest (the secret-scan.sh gate).
poison "poison: secret-laced mesh manifest (scan gate)" 'secret scan' \
    bash -c 'printf "{\"brand\":\"hugmesh\",\"api_token\":\"ghp_Kx9fQp2Lm7Vb8Nz4Wt6Rd1Yh0Jc5UgAb3Cd\"}\n" > hugmesh-mesh-manifest.json'

# (h) existing --dest: never clobber.
o5="$(run_pub "${SESS}" --dest "${D1}")"; rc=$?
[ "${rc}" -ne 0 ] && echo "${o5}" | grep -q 'already exists' \
    && ok "existing --dest refused (no clobber)" || bad "existing --dest accepted (rc=${rc})"
( cd "${D1}" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ) \
    && ok "prior export untouched by the refused re-run" || bad "prior export was disturbed"
# (i) --dest nested inside the session dir.
o6="$(run_pub "${SESS}" --dest "${SESS}/pub-inside")"; rc=$?
[ "${rc}" -ne 0 ] && echo "${o6}" | grep -q 'inside the session dir' \
    && ok "--dest inside the session dir refused" || bad "nested --dest accepted (rc=${rc})"
[ ! -e "${SESS}/pub-inside" ] && ok "nested-dest refusal left nothing behind" || bad "nested-dest refusal left a dir"

# ── 6. Ed25519 signing seam (PROVENANCE_SIGNING_KEY) ─────────────────────────
KEY="${WORK}/sign.pem"; PUB="${WORK}/sign.pub"
openssl genpkey -algorithm ed25519 -out "${KEY}" 2>/dev/null \
    && openssl pkey -in "${KEY}" -pubout -out "${PUB}" 2>/dev/null \
    || bad "test keypair generation failed"
D7="${WORK}/pub7"
o7="$(PROVENANCE_SIGNING_KEY="${KEY}" bash "${PI}" "${SESS}" --dest "${D7}" 2>&1)"; rc=$?
[ "${rc}" -eq 0 ] && ok "signed export exits 0" || bad "signed export failed (rc=${rc}): ${o7}"
[ -f "${D7}/publish-manifest.json.sig" ] && ok "detached .sig lands" || bad ".sig missing"
openssl pkeyutl -verify -pubin -inkey "${PUB}" -rawin \
    -in "${D7}/publish-manifest.json" -sigfile "${D7}/publish-manifest.json.sig" >/dev/null 2>&1 \
    && ok "signature verifies against the public key" || bad "signature does not verify"
grep -q 'publish-manifest.json.sig' "${D7}/SHA256SUMS" \
    && bad "SHA256SUMS must not list the .sig (it signs the manifest that lists everything)" \
    || ok "SHA256SUMS covers the tree; the .sig covers SHA256SUMS' inputs transitively"
D8="${WORK}/pub8"
PROVENANCE_SIGNING_KEY="${KEY}" bash "${PI}" "${SESS}" --dest "${D8}" >/dev/null 2>&1
[ "$(sha256sum < "${D7}/publish-manifest.json.sig")" = "$(sha256sum < "${D8}/publish-manifest.json.sig")" ] \
    && ok "Ed25519 signature is deterministic across re-runs" || bad "signature differs across identical runs"
o9="$(PROVENANCE_SIGNING_KEY="${WORK}/no-such-key.pem" bash "${PI}" "${SESS}" --dest "${WORK}/pub9" 2>&1)"; rc=$?
[ "${rc}" -ne 0 ] && echo "${o9}" | grep -q 'PROVENANCE_SIGNING_KEY' \
    && ok "missing signing key is fail-closed (never silently unsigned)" \
    || bad "missing signing key should refuse (rc=${rc})"

echo "== done: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
