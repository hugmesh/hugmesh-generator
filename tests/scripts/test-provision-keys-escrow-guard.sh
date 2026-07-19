#!/usr/bin/env bash
# test-provision-keys-escrow-guard.sh — offline test for gen-provision-keys.sh's
# escrow-clobber guard (the queued MDM defense-in-depth follow-up).
#
# gen-provision-keys.sh starts with `rm -rf ${OUT_DIR}`. Everything the script
# itself mints regenerates, but OTHER tools escrow NON-regenerable secrets under
# <out>/vault-seed/device/<id>/ — the phone-wizard's enterprise-profile.pass is
# the only copy of a passphrase that unlocks an already-created on-device work
# profile. The guard must REFUSE the delete when such foreign files exist, and
# must NOT block on the files gen-provision-keys itself creates
# (ssh/dial_private_key{,.pub} + ingest.json).
#
# Offline: never runs the full key generation — the guard fires (or is passed)
# before any tool checks beyond openssl/ssh-keygen/python3, so we stub a fast
# exit by letting the real script run only far enough in the refusal case, and
# in the pass-through cases assert it got PAST the guard (the "==> Building"
# banner) before we kill it via a missing-template early exit.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GPK="${REPO}/scripts/gen-provision-keys.sh"
[ -f "${GPK}" ] || { echo "  FAIL gen-provision-keys.sh missing: ${GPK}"; exit 1; }
for t in openssl ssh-keygen python3; do
    command -v "${t}" >/dev/null || { echo "SKIP: need ${t}"; exit 0; }
done

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

echo "== gen-provision-keys.sh escrow-clobber guard =="

# The guard runs BEFORE the template-dir check?  No — argument/tool/template
# checks come first, then the guard, then rm -rf.  Use the REAL keys-template so
# the run reaches the guard; abort the (slow) rest of a would-be successful run
# by pointing --out at a tree whose guard verdict we assert on, then killing via
# timeout.  In the refusal case the script exits 1 on its own, fast.

# ── (a) foreign escrow file (phone-wizard enterprise-profile.pass) → REFUSE ──
OUT_A="${WORK}/keys-out-a"
mkdir -p "${OUT_A}/vault-seed/device/pixel-1"
echo "irreplaceable-passphrase" > "${OUT_A}/vault-seed/device/pixel-1/enterprise-profile.pass"
set +e
LOG_A="$(cd "${REPO}" && "${GPK}" -o "${OUT_A}" 2>&1)"
RC_A=$?
set -e
if [ "${RC_A}" -eq 1 ] && printf '%s' "${LOG_A}" | grep -q "refusing to delete"; then
    ok "(a) foreign escrow → exit 1 with a refusing-to-delete error"
else
    bad "(a) expected exit 1 + refusal, got rc=${RC_A}: $(printf '%s' "${LOG_A}" | head -3)"
fi
if [ -f "${OUT_A}/vault-seed/device/pixel-1/enterprise-profile.pass" ] \
   && [ "$(cat "${OUT_A}/vault-seed/device/pixel-1/enterprise-profile.pass")" = "irreplaceable-passphrase" ]; then
    ok "(a2) the escrowed file survives byte-for-byte"
else
    bad "(a2) the escrowed file was destroyed or altered"
fi
if printf '%s' "${LOG_A}" | grep -q "enterprise-profile.pass"; then
    ok "(a3) the refusal names the offending file"
else
    bad "(a3) refusal does not name the offending file"
fi

# ── (b) ONLY the script's own vault-seed files → guard passes (reaches rm -rf) ──
# A prior legit gen-provision-keys tree must remain clobber-able, or every rerun
# breaks. Seed exactly the recognized set and assert the run gets PAST the guard
# (prints the "==> Building" banner). Give it a short timeout: reaching the
# banner is the assertion; whether the full (slow) generation then completes is
# out of scope here and covered by the existing staging e2e test.
OUT_B="${WORK}/keys-out-b"
mkdir -p "${OUT_B}/vault-seed/device/dev-cafe/ssh"
echo k > "${OUT_B}/vault-seed/device/dev-cafe/ssh/dial_private_key"
echo p > "${OUT_B}/vault-seed/device/dev-cafe/ssh/dial_private_key.pub"
echo '{}' > "${OUT_B}/vault-seed/device/dev-cafe/ingest.json"
set +e
LOG_B="$(cd "${REPO}" && timeout 60 "${GPK}" -o "${OUT_B}" 2>&1)"
RC_B=$?
set -e
if printf '%s' "${LOG_B}" | grep -q "==> Building"; then
    ok "(b) own regenerable files only → guard passes (rebuild proceeds)"
else
    bad "(b) guard blocked a legitimate rerun (rc=${RC_B}): $(printf '%s' "${LOG_B}" | head -3)"
fi

# ── (c) no pre-existing OUT_DIR at all → guard passes ──
OUT_C="${WORK}/keys-out-c"
set +e
LOG_C="$(cd "${REPO}" && timeout 60 "${GPK}" -o "${OUT_C}" 2>&1)"
RC_C=$?
set -e
if printf '%s' "${LOG_C}" | grep -q "==> Building"; then
    ok "(c) fresh OUT_DIR → guard passes"
else
    bad "(c) guard misfired on a fresh OUT_DIR (rc=${RC_C}): $(printf '%s' "${LOG_C}" | head -3)"
fi

# ── (d) mixed tree: recognized files AND one foreign file → still REFUSES ──
OUT_D="${WORK}/keys-out-d"
mkdir -p "${OUT_D}/vault-seed/device/dev-beef/ssh"
echo k > "${OUT_D}/vault-seed/device/dev-beef/ssh/dial_private_key"
echo '{}' > "${OUT_D}/vault-seed/device/dev-beef/ingest.json"
mkdir -p "${OUT_D}/vault-seed/device/pixel-2"
echo secret > "${OUT_D}/vault-seed/device/pixel-2/enterprise-profile.pass"
set +e
LOG_D="$(cd "${REPO}" && "${GPK}" -o "${OUT_D}" 2>&1)"
RC_D=$?
set -e
if [ "${RC_D}" -eq 1 ] && [ -f "${OUT_D}/vault-seed/device/pixel-2/enterprise-profile.pass" ]; then
    ok "(d) mixed tree → refused, foreign escrow intact"
else
    bad "(d) mixed tree not refused (rc=${RC_D}) or escrow lost: $(printf '%s' "${LOG_D}" | head -3)"
fi

echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
