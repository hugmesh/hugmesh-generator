#!/usr/bin/env bash
# test-attestation-dockerfile-patches.sh — OFFLINE test of the source-patch
# sed+grep gates in the two MDM image Dockerfiles. NO docker build, NO network,
# NO clone: the RUN commands are EXTRACTED from the REAL Dockerfile text (the
# Dockerfile is the SUT — hand-copying the seds into this test would make it
# vacuous) and executed against committed fixtures replicating the EXACT
# upstream declaration shapes at the pinned commit 98b6c130
# (tests/stack/fixtures/attestation-98b6c130/), plus the real committed
# headwind docker/build.properties.
#
# specs/cluster/manifests/attestation-server/Dockerfile carries 3 patches, each
# with a fail-loud grep gate:
#   Patch 1  DOMAIN  ("attestation.app" -> ${ATTESTATION_DOMAIN})
#   Patch 2  bind    (InetSocketAddress("::1", 8080) -> InetSocketAddress(8080))
#   Patch 3  fork identity (AUDITOR_APP_PACKAGE_NAME_RELEASE + the LINE-WRAPPED
#            AUDITOR_APP_SIGNATURE_DIGEST_RELEASE — the sed targets the unique
#            stock digest LITERAL "990E04...", not the declaration)
# specs/cluster/manifests/headwind/Dockerfile carries the build.properties
# randomize step (jwt.secretkey/hash.secret RANDOMIZE-AT-IMAGE-BUILD -> fresh
# 48-hex per image) gated by `! grep -q RANDOMIZE-AT-IMAGE-BUILD`.
#
# Proves:
#   (1) extraction: each RUN block is found in the real Dockerfile text and
#       still carries BOTH its sed and its fail-loud grep gate; ARG defaults
#       are read from the Dockerfile (never hardcoded here);
#   (2) fixtures replicate the upstream shapes (incl. the line-wrap: the digest
#       declaration line ends with `=`, the literal sits alone on the next);
#   (3) with default ARGs each patch LANDS, each grep gate PASSES, the patched
#       fixture carries the new value and NOT the old; only the RELEASE pin is
#       repointed (_PLAY/_DEBUG sentinels untouched);
#   (4) PLACEHOLDER POSTURE: with default ARGs the patched fixture contains
#       SET-FROM-FORK-RELEASE-CERT — a green run does NOT mean a real digest
#       was pinned (mirrors the Dockerfile's own NOTE); a --build-arg-style
#       override with a real 64-hex digest also lands;
#   (5) MUTATION PROOFS (staged fixture copies only — the repo tree is never
#       mutated): a rewrapped-to-one-line digest still patches (the gate is
#       robust to REWRAP), but a CHANGED digest literal / reshaped package or
#       DOMAIN declaration makes the extracted gate FAIL LOUD nonzero;
#   (6) headwind randomize: run against the REAL committed build.properties,
#       both secrets become 48-hex, two runs differ (really random), the
#       placeholder is gone; a RESHAPED placeholder line trips the
#       `! grep -q` gate, and a fully DELETED placeholder line — invisible to
#       that in-Dockerfile gate by construction — is caught by THIS suite's
#       48-hex assertion (the layer beneath the gate).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ATT_DF="${REPO}/specs/cluster/manifests/attestation-server/Dockerfile"
HW_DF="${REPO}/specs/cluster/manifests/headwind/Dockerfile"
FIX="${REPO}/tests/stack/fixtures/attestation-98b6c130"
HW_PROPS="${REPO}/specs/cluster/manifests/headwind/docker/build.properties"

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

echo "== MDM Dockerfile sed/grep patch gates (offline, extracted from the real text) =="

for t in sed grep od tr head; do
  command -v "${t}" >/dev/null 2>&1 || { echo "SKIP: need ${t}"; exit 0; }
done
[ -f "${ATT_DF}" ] && [ -f "${HW_DF}" ] || { echo "SKIP: MDM Dockerfiles not present"; exit 0; }

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}" 2>/dev/null' EXIT

# ── RUN-block extraction from the real Dockerfile text ────────────────────────
parse_run_blocks() { # <dockerfile> <outprefix> — one shell command per file
  local n=0 in=0 line cmd=""
  while IFS= read -r line; do
    if [ "${in}" -eq 0 ]; then
      case "${line}" in
        "RUN "*) in=1; cmd="${line#RUN }" ;;
        *) continue ;;
      esac
    else
      cmd="${cmd}"$'\n'"${line}"
    fi
    case "${line}" in
      *"\\") ;;  # backslash continuation — keep accumulating
      *) printf '%s\n' "${cmd}" > "$2-${n}"; n=$((n+1)); in=0; cmd="" ;;
    esac
  done < "$1"
}
pick_block() { # <outprefix> <needle1> [needle2] — echoes the ONE matching block
  local f hit="" needle
  for f in "$1"-*; do
    [ -f "${f}" ] || continue
    for needle in "${@:2}"; do
      grep -qF -- "${needle}" "${f}" || continue 2
    done
    [ -n "${hit}" ] && return 2   # ambiguous
    hit="${f}"
  done
  [ -n "${hit}" ] && echo "${hit}"
}
arg_default() { # <dockerfile> <NAME> — the committed ARG default
  sed -n "s/^ARG $2=//p" "$1" | head -1
}
run_block() { # <blockfile> <cwd> — execute with the Dockerfile's ARG env
  ( cd "$2" && env \
      ATTESTATION_DOMAIN="${ATTESTATION_DOMAIN}" \
      AUDITOR_PACKAGE="${AUDITOR_PACKAGE}" \
      AUDITOR_SIGNER_DIGEST="${AUDITOR_SIGNER_DIGEST}" \
      bash -c "$(cat "$1")" ) >/dev/null 2>&1
}
stage_att() { # <dst> [src-fixture-dir] — lay fixtures out at the Dockerfile's paths
  local dst="$1" src="${2:-${FIX}}"
  mkdir -p "${dst}/src/main/java/app/attestation/server"
  cp "${src}/AttestationServer.java" "${src}/AttestationProtocol.java" \
     "${dst}/src/main/java/app/attestation/server/"
}
ASJ="src/main/java/app/attestation/server/AttestationServer.java"
APJ="src/main/java/app/attestation/server/AttestationProtocol.java"
STOCK_DIGEST="990E04F0864B19F14F84E0E432F7A393F297AB105A22C1E1B10B442A4A62C42C"

# ── 1) extraction sanity: blocks + gates + ARG defaults from the REAL text ────
echo "-- 1) extraction from the real Dockerfiles --"
parse_run_blocks "${ATT_DF}" "${WORK}/att-run"
parse_run_blocks "${HW_DF}"  "${WORK}/hw-run"
P1="$(pick_block "${WORK}/att-run" 'AttestationServer.java' 'DOMAIN')" \
  && ok "(1) Patch 1 (DOMAIN) RUN block extracted" || { bad "(1) Patch 1 block not found/ambiguous"; P1=/dev/null; }
P2="$(pick_block "${WORK}/att-run" 'AttestationServer.java' 'InetSocketAddress')" \
  && ok "(1) Patch 2 (bind address) RUN block extracted" || { bad "(1) Patch 2 block not found/ambiguous"; P2=/dev/null; }
P3="$(pick_block "${WORK}/att-run" 'AttestationProtocol.java')" \
  && ok "(1) Patch 3 (fork identity) RUN block extracted" || { bad "(1) Patch 3 block not found/ambiguous"; P3=/dev/null; }
HR="$(pick_block "${WORK}/hw-run" 'RANDOMIZE-AT-IMAGE-BUILD')" \
  && ok "(1) headwind randomize RUN block extracted" || { bad "(1) headwind randomize block not found/ambiguous"; HR=/dev/null; }
GATES_OK=1
for b in "${P1}" "${P2}" "${P3}"; do
  grep -q 'sed -i' "${b}" && grep -q 'grep -q' "${b}" || GATES_OK=0
done
[ "${GATES_OK}" -eq 1 ] \
  && ok "(1) all 3 patch blocks still carry sed -i AND a fail-loud grep gate" \
  || bad "(1) a patch block lost its sed or its fail-loud grep gate"
grep -q '! grep -q RANDOMIZE-AT-IMAGE-BUILD' "${HR}" \
  && ok "(1) headwind block still carries the '! grep -q RANDOMIZE-AT-IMAGE-BUILD' gate" \
  || bad "(1) headwind randomize gate missing from the extracted block"
ATTESTATION_DOMAIN="$(arg_default "${ATT_DF}" ATTESTATION_DOMAIN)"
AUDITOR_PACKAGE="$(arg_default "${ATT_DF}" AUDITOR_PACKAGE)"
AUDITOR_SIGNER_DIGEST="$(arg_default "${ATT_DF}" AUDITOR_SIGNER_DIGEST)"
[ -n "${ATTESTATION_DOMAIN}" ] && [ -n "${AUDITOR_PACKAGE}" ] && [ -n "${AUDITOR_SIGNER_DIGEST}" ] \
  && ok "(1) ARG defaults read from the Dockerfile (${ATTESTATION_DOMAIN} / ${AUDITOR_PACKAGE} / ${AUDITOR_SIGNER_DIGEST})" \
  || { bad "(1) could not read the ARG defaults from the Dockerfile"; echo "== RESULT: ${P} passed, ${F} failed =="; exit 1; }

# ── 2) fixture pre-flight: the committed fixtures replicate the shapes ────────
echo "-- 2) fixture shape pre-flight (98b6c130 declaration shapes) --"
grep -qF 'static final String DOMAIN = "attestation.app";' "${FIX}/AttestationServer.java" \
  && ok "(2) fixture: stock DOMAIN declaration shape present" || bad "(2) fixture DOMAIN shape wrong"
grep -qF 'new InetSocketAddress("::1", 8080)' "${FIX}/AttestationServer.java" \
  && ok "(2) fixture: stock ::1 bind shape present" || bad "(2) fixture bind shape wrong"
grep -qF 'AUDITOR_APP_PACKAGE_NAME_RELEASE = "app.attestation.auditor";' "${FIX}/AttestationProtocol.java" \
  && ok "(2) fixture: ONE-LINE package release declaration present" || bad "(2) fixture package shape wrong"
grep -q 'AUDITOR_APP_SIGNATURE_DIGEST_RELEASE =$' "${FIX}/AttestationProtocol.java" \
  && grep -q "^[[:space:]]*\"${STOCK_DIGEST}\";$" "${FIX}/AttestationProtocol.java" \
  && ok "(2) fixture: digest declaration is LINE-WRAPPED (decl line ends '=', literal alone on the next)" \
  || bad "(2) fixture digest declaration is not line-wrapped as at 98b6c130"

# ── 3) patches land + gates pass on the faithful fixture ──────────────────────
echo "-- 3) extracted patches against the faithful fixture (default ARGs) --"
stage_att "${WORK}/good"
run_block "${P1}" "${WORK}/good" \
  && ok "(3) Patch 1 executes: sed lands + grep gate passes" || bad "(3) Patch 1 FAILED on the faithful fixture"
grep -qF "static final String DOMAIN = \"${ATTESTATION_DOMAIN}\";" "${WORK}/good/${ASJ}" \
  && ! grep -qF '"attestation.app"' "${WORK}/good/${ASJ}" \
  && ok "(3) Patch 1 result: DOMAIN=${ATTESTATION_DOMAIN}, stock attestation.app GONE" \
  || bad "(3) Patch 1 result wrong"
run_block "${P2}" "${WORK}/good" \
  && ok "(3) Patch 2 executes: sed lands + grep gate passes" || bad "(3) Patch 2 FAILED on the faithful fixture"
grep -qF 'new InetSocketAddress(8080)' "${WORK}/good/${ASJ}" \
  && ! grep -qF '"::1", 8080' "${WORK}/good/${ASJ}" \
  && ok "(3) Patch 2 result: all-interfaces bind, loopback-only bind GONE" \
  || bad "(3) Patch 2 result wrong"
run_block "${P3}" "${WORK}/good" \
  && ok "(3) Patch 3 executes: both seds land + both grep gates pass" || bad "(3) Patch 3 FAILED on the faithful fixture"
grep -qF "AUDITOR_APP_PACKAGE_NAME_RELEASE = \"${AUDITOR_PACKAGE}\"" "${WORK}/good/${APJ}" \
  && ! grep -qF '"app.attestation.auditor"' "${WORK}/good/${APJ}" \
  && ok "(3) Patch 3 result: RELEASE package repointed to ${AUDITOR_PACKAGE}" \
  || bad "(3) Patch 3 package result wrong"
! grep -qF "${STOCK_DIGEST}" "${WORK}/good/${APJ}" \
  && ok "(3) Patch 3 result: stock RELEASE digest literal GONE" \
  || bad "(3) stock digest survived Patch 3"
grep -qF '"app.attestation.auditor.play"' "${WORK}/good/${APJ}" \
  && grep -qF 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA0001' "${WORK}/good/${APJ}" \
  && grep -qF 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA0002' "${WORK}/good/${APJ}" \
  && ok "(3) ONLY the RELEASE pin repointed — _PLAY/_DEBUG sentinels untouched" \
  || bad "(3) a non-RELEASE pin was modified"

# ── 4) placeholder posture + real-digest override path ────────────────────────
echo "-- 4) placeholder posture (green != real digest pinned) --"
[ "${AUDITOR_SIGNER_DIGEST}" = "SET-FROM-FORK-RELEASE-CERT" ] \
  && ok "(4) committed ARG default IS the placeholder (Track 2 custody gate still open — see Dockerfile NOTE)" \
  || bad "(4) ARG default changed from the placeholder — if Track 2 delivered a real digest, update this suite CONSCIOUSLY"
grep -qF 'SET-FROM-FORK-RELEASE-CERT' "${WORK}/good/${APJ}" \
  && ok "(4) default-ARG patched fixture carries SET-FROM-FORK-RELEASE-CERT: a green run does NOT prove a real digest" \
  || bad "(4) placeholder not present in the default-ARG result"
REAL_DIGEST="1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF1234567890ABCDEF"
stage_att "${WORK}/real"
( AUDITOR_SIGNER_DIGEST="${REAL_DIGEST}"; run_block "${P3}" "${WORK}/real"; ) \
  && grep -qF "${REAL_DIGEST}" "${WORK}/real/${APJ}" \
  && ok "(4) --build-arg-style override: a real 64-hex digest lands + passes the gate" \
  || bad "(4) real-digest override path broken"

# ── 5) mutation proofs: the gates FAIL LOUD on reshaped upstream ──────────────
echo "-- 5) mutation proofs (staged fixture copies) --"
# 5a) digest REWRAPPED onto one line (different spacing) — sed targets the
#     literal, so the patch must STILL land (robust to a benign rewrap).
mkdir -p "${WORK}/mut-rewrap-src"
sed -e '/AUDITOR_APP_SIGNATURE_DIGEST_RELEASE =$/{N;s/ =\n[[:space:]]*"/  =  "/;}' \
  "${FIX}/AttestationProtocol.java" > "${WORK}/mut-rewrap-src/AttestationProtocol.java"
cp "${FIX}/AttestationServer.java" "${WORK}/mut-rewrap-src/"
grep -q "DIGEST_RELEASE  =  \"${STOCK_DIGEST}\";" "${WORK}/mut-rewrap-src/AttestationProtocol.java" \
  || bad "(5a) rewrap staging failed (control not exercised)"
stage_att "${WORK}/mut-rewrap" "${WORK}/mut-rewrap-src"
run_block "${P3}" "${WORK}/mut-rewrap" \
  && ! grep -qF "${STOCK_DIGEST}" "${WORK}/mut-rewrap/${APJ}" \
  && ok "(5a) one-line rewrap of the digest declaration: patch still lands (sed pins the LITERAL, not the shape)" \
  || bad "(5a) benign rewrap broke Patch 3 — the literal-targeting promise regressed"
# 5b) digest LITERAL changed (upstream rotated the stock pin) -> gate FIRES.
mkdir -p "${WORK}/mut-digest-src"
sed "s/${STOCK_DIGEST}/${STOCK_DIGEST%?}D/" "${FIX}/AttestationProtocol.java" \
  > "${WORK}/mut-digest-src/AttestationProtocol.java"
cp "${FIX}/AttestationServer.java" "${WORK}/mut-digest-src/"
stage_att "${WORK}/mut-digest" "${WORK}/mut-digest-src"
if run_block "${P3}" "${WORK}/mut-digest"; then
  bad "(5b) VACUOUS GATE: changed digest literal and Patch 3 still went green"
else
  ok "(5b) changed digest literal -> extracted Patch 3 grep gate FAILS LOUD (nonzero)"
fi
# 5c) package declaration reshaped (extra spaces) -> gate FIRES.
mkdir -p "${WORK}/mut-pkg-src"
sed 's/AUDITOR_APP_PACKAGE_NAME_RELEASE = "app.attestation.auditor"/AUDITOR_APP_PACKAGE_NAME_RELEASE  =  "app.attestation.auditor"/' \
  "${FIX}/AttestationProtocol.java" > "${WORK}/mut-pkg-src/AttestationProtocol.java"
cp "${FIX}/AttestationServer.java" "${WORK}/mut-pkg-src/"
stage_att "${WORK}/mut-pkg" "${WORK}/mut-pkg-src"
if run_block "${P3}" "${WORK}/mut-pkg"; then
  bad "(5c) VACUOUS GATE: reshaped package declaration and Patch 3 still went green"
else
  ok "(5c) reshaped package declaration -> extracted Patch 3 gate FAILS LOUD"
fi
# 5d) DOMAIN declaration reshaped -> Patch 1 gate FIRES.
mkdir -p "${WORK}/mut-dom-src"
sed 's/String DOMAIN = "attestation.app";/String DOMAIN="attestation.app";/' \
  "${FIX}/AttestationServer.java" > "${WORK}/mut-dom-src/AttestationServer.java"
cp "${FIX}/AttestationProtocol.java" "${WORK}/mut-dom-src/"
stage_att "${WORK}/mut-dom" "${WORK}/mut-dom-src"
if run_block "${P1}" "${WORK}/mut-dom"; then
  bad "(5d) VACUOUS GATE: reshaped DOMAIN declaration and Patch 1 still went green"
else
  ok "(5d) reshaped DOMAIN declaration -> extracted Patch 1 gate FAILS LOUD"
fi

# ── 6) headwind build.properties randomize step ───────────────────────────────
echo "-- 6) headwind randomize step against the REAL committed build.properties --"
hex48_ok() { # <dir> — both secrets are fresh 48-hex, placeholder gone
  grep -qE '^jwt\.secretkey=[0-9a-f]{48}$' "$1/server/build.properties" \
    && grep -qE '^hash\.secret=[0-9a-f]{48}$' "$1/server/build.properties" \
    && ! grep -q 'RANDOMIZE-AT-IMAGE-BUILD' "$1/server/build.properties"
}
for d in hw1 hw2; do
  mkdir -p "${WORK}/${d}/server"
  cp "${HW_PROPS}" "${WORK}/${d}/server/build.properties"
done
run_block "${HR}" "${WORK}/hw1" \
  && ok "(6) randomize RUN executes green on the real committed build.properties" \
  || bad "(6) randomize RUN failed on the committed build.properties"
hex48_ok "${WORK}/hw1" \
  && ok "(6) jwt.secretkey + hash.secret are 48-hex and the placeholder is GONE" \
  || bad "(6) randomized secrets wrong shape / placeholder survived"
run_block "${HR}" "${WORK}/hw2" || bad "(6) second randomize run failed"
[ "$(grep '^jwt\.secretkey=' "${WORK}/hw1/server/build.properties")" != "$(grep '^jwt\.secretkey=' "${WORK}/hw2/server/build.properties")" ] \
  && ok "(6) two runs mint DIFFERENT jwt keys (really random, not a constant)" \
  || bad "(6) two runs produced the SAME jwt key — randomization is fake"
# 6a) RESHAPED placeholder line (leading space) -> the in-Dockerfile gate FIRES.
mkdir -p "${WORK}/hw-reshape/server"
sed 's/^jwt.secretkey=RANDOMIZE-AT-IMAGE-BUILD/ jwt.secretkey=RANDOMIZE-AT-IMAGE-BUILD/' \
  "${HW_PROPS}" > "${WORK}/hw-reshape/server/build.properties"
if run_block "${HR}" "${WORK}/hw-reshape"; then
  bad "(6a) VACUOUS GATE: unsubstitutable placeholder line and the randomize RUN still went green"
else
  ok "(6a) reshaped placeholder line -> '! grep -q RANDOMIZE-AT-IMAGE-BUILD' gate FAILS LOUD"
fi
# 6b) placeholder line DELETED — invisible to the in-Dockerfile gate by
#     construction (nothing left to grep), so THIS SUITE's 48-hex check is the
#     layer that catches it. Prove that layer bites.
mkdir -p "${WORK}/hw-missing/server"
grep -v '^jwt\.secretkey=RANDOMIZE-AT-IMAGE-BUILD' "${HW_PROPS}" > "${WORK}/hw-missing/server/build.properties"
run_block "${HR}" "${WORK}/hw-missing" \
  || bad "(6b) control not exercised: randomize RUN failed on the deleted-line mutant"
if hex48_ok "${WORK}/hw-missing"; then
  bad "(6b) VACUOUS SUITE CHECK: hex48_ok passed with jwt.secretkey deleted"
else
  ok "(6b) deleted placeholder line: in-Dockerfile gate is blind (documented), but the suite's 48-hex check FIRES"
fi

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
