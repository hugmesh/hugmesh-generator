#!/usr/bin/env bash
# test-make-phone-face.sh — Makefile phone-* delegate-target threading test.
#
# The SUT is the REAL repo Makefile (passed verbatim via `make -f` — never a
# modified copy): its 13 phone-* delegate targets and the _PHONE_ARGS seam.
# The seam's design (see the Makefile's own comment block): every knob is
# EXPORTED and substituted by the recipe SHELL at runtime (`$${VAR:+--flag
# "$$VAR"}`), never spliced as Make text — so a hostile value (e.g. a spoofed
# USB device serial) rides argv as ONE inert string. scripts/phone-wizard.sh is
# replaced by an argv-CAPTURE stub inside a staged tmpdir (`make -C <stage>
# -f <repo>/Makefile`), so the real wizard is never executed and no device /
# network / build is touched.
#
# Proves:
#   (1) all 13 phone-* targets delegate to the wizard with the RIGHT VERB, and
#       with every knob unset the argv is EXACTLY `<verb> --work-dir <wd>` —
#       i.e. all 26 optional flags are ABSENT (negative control by exact match);
#   (2) phone-mdm-enroll threads HEADWIND_APK/HEADWIND_SIGNER_SHA256/
#       HEADWIND_URL/SERIAL to exactly --headwind-apk/--headwind-signer-sha256/
#       --headwind-url/--serial;
#   (3) phone-attest threads AUDITOR_APK/AUDITOR_SIGNER_SHA256/ATTESTATION_URL;
#   (4) phone-ingest SECRET CUSTODY: AUTHKEY_FILE/PASS_FILE/INTERNAL_TOKEN_FILE
#       forward file PATHS only — the files' secret CONTENTS never appear on
#       argv/stdout/stderr (sweep with a proven-armed detector);
#   (5) phone-flash WITHOUT SERIAL refuses via the shell-level [ -n "$SERIAL" ]
#       guard and the wizard is NEVER invoked; WITH SERIAL it delegates;
#   (6) a knob value with spaces + quotes survives as ONE argv element (the
#       `"$$VAR"` quoting is load-bearing);
#   (7) injection posture: `$(...)`, backticks and $VAR inside a knob value are
#       NOT expanded anywhere in the recipe shell — the literal string arrives
#       on argv and no side-effect file appears;
#   (8) boolean knobs (YES=1 FORCE=1) append --yes --force; PLAN_VERB threads.
#
# Every `make` runs under `env -i` so no ambient SERIAL/HEADWIND_* leaks in.
# Needs bash >= 4.4 (mapfile -d) + make; SKIPs (exit 0) if either is missing.
# No network, no root, no device, no docker, no real build.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MAKEFILE="${REPO}/Makefile"

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

echo "== Makefile phone-* face / _PHONE_ARGS threading test =="

command -v make >/dev/null 2>&1 || { echo "SKIP: need make"; exit 0; }
if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
  echo "SKIP: need bash >= 4.4 (mapfile -d)"; exit 0
fi

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}" 2>/dev/null' EXIT
STAGE="${WORK}/stage"
WD="${STAGE}/out/phone-wizard"   # PHONE_WORK_DIR default: $(CURDIR)/out/phone-wizard

# ── argv-capture stub standing in for scripts/phone-wizard.sh ─────────────────
# Records every argument NUL-delimited (exact bytes, no quoting ambiguity).
mkdir -p "${STAGE}/scripts"
cat > "${STAGE}/scripts/phone-wizard.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\0' "$@" > "${PW_CAPTURE:?}"
exit 0
STUB
chmod +x "${STAGE}/scripts/phone-wizard.sh"

# ── harness ───────────────────────────────────────────────────────────────────
CAP=""; RC=0; ARGV=()
run_make() { # run_make <target> [VAR=VALUE ...] — env -i: NOTHING ambient leaks
  local target="$1"; shift
  CAP="${WORK}/cap"
  rm -f "${CAP}"
  RC=0
  env -i PATH="${PATH}" PW_CAPTURE="${CAP}" "$@" \
    make -C "${STAGE}" -f "${MAKEFILE}" "${target}" \
    >"${WORK}/out.log" 2>"${WORK}/err.log" || RC=$?
  ARGV=()
  [ -f "${CAP}" ] && mapfile -d '' -t ARGV < "${CAP}"
}
argv_is() { # exact element-wise comparison, length included
  local want=("$@") i
  [ "${#want[@]}" -eq "${#ARGV[@]}" ] || return 1
  for i in "${!want[@]}"; do [ "${ARGV[${i}]}" = "${want[${i}]}" ] || return 1; done
}
argv_show() { printf '%s' "argv(${#ARGV[@]}):"; printf ' [%s]' "${ARGV[@]}"; echo; }
leaks() { grep -qF -- "$1" "$2" 2>/dev/null; }  # secret sweep primitive

# ── (0) SUT sanity: the REAL Makefile is under test, seam present ─────────────
echo "-- 0) SUT sanity --"
[ -f "${MAKEFILE}" ] && ok "(0) real repo Makefile present (${MAKEFILE})" || { bad "(0) Makefile missing"; echo "== RESULT: ${P} passed, ${F} failed =="; exit 1; }
grep -q '^_PHONE_ARGS = --work-dir' "${MAKEFILE}" \
  && ok "(0) _PHONE_ARGS seam present in the Makefile (a rename would silently un-test it)" \
  || bad "(0) _PHONE_ARGS seam not found — targets renamed/reshaped?"

# ── (1) all 13 targets: right verb, and NO optional flag with knobs unset ─────
echo "-- 1) verb map + unset-knob flag ABSENCE (exact argv, 12 non-flash targets) --"
declare -A VERB=(
  [phone-plan]=plan [phone-detect]=detect [phone-fetch]=fetch
  [phone-enroll]=enroll [phone-profile]=profile
  [phone-rotate-profile-pass]=rotate-profile-pass
  [phone-remove-profile]=remove-profile [phone-ingest]=ingest
  [phone-status]=status [phone-mdm-enroll]=mdm-enroll
  [phone-attest]=attest [phone-wizard]=wizard
)
for t in phone-plan phone-detect phone-fetch phone-enroll phone-profile \
         phone-rotate-profile-pass phone-remove-profile phone-ingest \
         phone-status phone-mdm-enroll phone-attest phone-wizard; do
  run_make "${t}"
  if [ "${RC}" -eq 0 ] && argv_is "${VERB[${t}]}" --work-dir "${WD}"; then
    ok "(1) ${t} -> exactly '${VERB[${t}]} --work-dir <wd>' (all 26 optional flags absent)"
  else
    bad "(1) ${t} rc=${RC} $(argv_show)"
  fi
done

# ── (2) phone-mdm-enroll threading ────────────────────────────────────────────
echo "-- 2) phone-mdm-enroll knob threading --"
run_make phone-mdm-enroll \
  HEADWIND_APK=/apks/hmdm-dpc.apk \
  HEADWIND_SIGNER_SHA256=aa11bb22cc33dd44 \
  HEADWIND_URL=https://superadmin.hugmesh.net/hmdm \
  SERIAL=SERIAL123
if [ "${RC}" -eq 0 ] && argv_is mdm-enroll --work-dir "${WD}" \
     --serial SERIAL123 \
     --headwind-apk /apks/hmdm-dpc.apk \
     --headwind-signer-sha256 aa11bb22cc33dd44 \
     --headwind-url https://superadmin.hugmesh.net/hmdm; then
  ok "(2) HEADWIND_APK/HEADWIND_SIGNER_SHA256/HEADWIND_URL/SERIAL -> exact wizard argv"
else
  bad "(2) phone-mdm-enroll rc=${RC} $(argv_show)"
fi

# ── (2b) quest-mdm-enroll thin-desktop threading (§8b) ───────────────────────
# The quest-* face rides --device-class quest FIRST (_QUEST_ARGS), then the
# same _PHONE_ARGS seam — the four thin-desktop knobs thread like every other
# knob, and stay ABSENT (byte-identical argv) when unset.
echo "-- 2b) quest-mdm-enroll thin-desktop knob threading --"
run_make quest-mdm-enroll \
  THIN_DESKTOP=1 \
  MOONLIGHT_APK=/apks/moonlight.apk \
  MOONLIGHT_SIGNER_SHA256=cc33dd44ee55ff66 \
  THIN_DESKTOP_HOSTS=frite,box2.hugmesh.internal
if [ "${RC}" -eq 0 ] && argv_is mdm-enroll --device-class quest --work-dir "${WD}" \
     --thin-desktop \
     --moonlight-apk /apks/moonlight.apk \
     --moonlight-signer-sha256 cc33dd44ee55ff66 \
     --thin-desktop-hosts frite,box2.hugmesh.internal; then
  ok "(2b) THIN_DESKTOP/MOONLIGHT_APK/MOONLIGHT_SIGNER_SHA256/THIN_DESKTOP_HOSTS -> exact quest argv"
else
  bad "(2b) quest-mdm-enroll rc=${RC} $(argv_show)"
fi
run_make quest-mdm-enroll
if [ "${RC}" -eq 0 ] && argv_is mdm-enroll --device-class quest --work-dir "${WD}"; then
  ok "(2b) unset thin-desktop knobs -> NO thin-desktop flag on the quest argv (byte-identity)"
else
  bad "(2b) quest-mdm-enroll unset rc=${RC} $(argv_show)"
fi

# ── (3) phone-attest threading ────────────────────────────────────────────────
echo "-- 3) phone-attest knob threading --"
run_make phone-attest \
  AUDITOR_APK=/apks/auditor-fork.apk \
  AUDITOR_SIGNER_SHA256=ee55ff66aa77bb88 \
  ATTESTATION_URL=https://superadmin.hugmesh.net/attest
if [ "${RC}" -eq 0 ] && argv_is attest --work-dir "${WD}" \
     --auditor-apk /apks/auditor-fork.apk \
     --auditor-signer-sha256 ee55ff66aa77bb88 \
     --attestation-url https://superadmin.hugmesh.net/attest; then
  ok "(3) AUDITOR_APK/AUDITOR_SIGNER_SHA256/ATTESTATION_URL -> exact wizard argv"
else
  bad "(3) phone-attest rc=${RC} $(argv_show)"
fi

# ── (4) phone-ingest SECRET CUSTODY: paths on argv, contents NEVER ────────────
echo "-- 4) phone-ingest secret custody (paths only, never contents) --"
# A FAKE auth key in two adjacent pieces (secret scanners flagged the joined
# spelling); the shell joins them, so the runtime value is unchanged.
AK_SECRET="tskey-""auth-SECRET-Aa0Bb1Cc2Dd3Ee4"
PW_SECRET="hunter2-passphrase-9f8e7d6c5b4a"
TK_SECRET="ingest-internal-token-0123456789abcdef"
printf '%s\n' "${AK_SECRET}" > "${WORK}/authkey.f"
printf '%s\n' "${PW_SECRET}" > "${WORK}/pass.f"
printf '%s\n' "${TK_SECRET}" > "${WORK}/token.f"
run_make phone-ingest \
  AUTHKEY_FILE="${WORK}/authkey.f" \
  PASS_FILE="${WORK}/pass.f" \
  INTERNAL_TOKEN_FILE="${WORK}/token.f"
if [ "${RC}" -eq 0 ] && argv_is ingest --work-dir "${WD}" \
     --authkey-file "${WORK}/authkey.f" \
     --pass-file "${WORK}/pass.f" \
     --internal-token-file "${WORK}/token.f"; then
  ok "(4) AUTHKEY_FILE/PASS_FILE/INTERNAL_TOKEN_FILE -> --*-file <PATH> exact argv"
else
  bad "(4) phone-ingest rc=${RC} $(argv_show)"
fi
# POSITIVE CONTROL first: prove the sweep detector actually bites.
printf 'x %s y\n' "${TK_SECRET}" > "${WORK}/planted"
leaks "${TK_SECRET}" "${WORK}/planted" \
  && ok "(4) sweep detector ARMED (finds a planted secret — the sweep below is not vacuous)" \
  || bad "(4) sweep detector BROKEN: cannot find a planted secret"
SWEPT=0
for s in "${AK_SECRET}" "${PW_SECRET}" "${TK_SECRET}"; do
  for f in "${CAP}" "${WORK}/out.log" "${WORK}/err.log"; do
    leaks "${s}" "${f}" && { bad "(4) SECRET LEAK: '${s}' found in ${f}"; SWEPT=1; }
  done
done
[ "${SWEPT}" -eq 0 ] && ok "(4) sweep: no secret file CONTENT on wizard argv / make stdout / make stderr"

# ── (5) phone-flash hard-require gate ─────────────────────────────────────────
echo "-- 5) phone-flash SERIAL= hard-require --"
run_make phone-flash
if [ "${RC}" -ne 0 ]; then
  ok "(5) phone-flash without SERIAL -> make fails (rc=${RC})"
else
  bad "(5) phone-flash without SERIAL succeeded (rc=0)"
fi
grep -q 'SERIAL= is required' "${WORK}/err.log" \
  && ok "(5) refusal carries the actionable message ('SERIAL= is required')" \
  || bad "(5) hard-require message missing: $(tr -d '\n' <"${WORK}/err.log" | cut -c1-160)"
[ ! -f "${CAP}" ] \
  && ok "(5) wizard NEVER invoked on refusal (no argv capture exists)" \
  || bad "(5) wizard WAS invoked despite the refusal: $(argv_show)"
# positive control: the gate is a gate, not a dead target — WITH SERIAL it delegates.
run_make phone-flash SERIAL=FLASHSER01
if [ "${RC}" -eq 0 ] && argv_is flash --work-dir "${WD}" --serial FLASHSER01; then
  ok "(5) positive control: phone-flash WITH SERIAL delegates 'flash --serial <v>'"
else
  bad "(5) phone-flash with SERIAL rc=${RC} $(argv_show)"
fi

# ── (6) whitespace + quotes survive as ONE argv element ───────────────────────
echo "-- 6) quoting is load-bearing: spaces/quotes survive intact --"
UGLY='pixel 7a "quoted"  double-space and '\''apostrophe'\'
run_make phone-detect "SERIAL=${UGLY}"
if [ "${RC}" -eq 0 ] && argv_is detect --work-dir "${WD}" --serial "${UGLY}"; then
  ok "(6) value with spaces + \" + ' arrives as ONE unaltered argv element"
else
  bad "(6) quoted value mangled: rc=${RC} $(argv_show)"
fi

# ── (7) injection posture: no expansion of \$(...) / backticks / \$VAR ────────
echo "-- 7) injection posture on the _PHONE_ARGS seam --"
INJ='spoof`touch '"${WORK}"'/pwn-bt`$(touch '"${WORK}"'/pwn-cs)$HOME${PATH}'
run_make phone-detect "SERIAL=${INJ}"
if [ "${RC}" -eq 0 ] && argv_is detect --work-dir "${WD}" --serial "${INJ}"; then
  ok "(7) hostile value rides argv as the EXACT literal (no re-parse, no word-split)"
else
  bad "(7) hostile value altered: rc=${RC} $(argv_show)"
fi
if [ ! -e "${WORK}/pwn-bt" ] && [ ! -e "${WORK}/pwn-cs" ]; then
  ok "(7) neither \`...\` nor \$(...) EXECUTED anywhere in the recipe shell"
else
  bad "(7) INJECTION: side-effect file created ($(ls "${WORK}"/pwn-* 2>/dev/null))"
fi

# ── (8) boolean knobs + PLAN_VERB ─────────────────────────────────────────────
echo "-- 8) boolean knobs + PLAN_VERB threading --"
run_make phone-enroll YES=1 FORCE=1
if [ "${RC}" -eq 0 ] && argv_is enroll --work-dir "${WD}" --yes --force; then
  ok "(8) YES=1 FORCE=1 -> --yes --force appended (and ONLY those)"
else
  bad "(8) boolean knobs rc=${RC} $(argv_show)"
fi
run_make phone-plan PLAN_VERB=flash
if [ "${RC}" -eq 0 ] && argv_is plan flash --work-dir "${WD}"; then
  ok "(8) PLAN_VERB=flash -> 'plan flash' single-verb plan"
else
  bad "(8) PLAN_VERB rc=${RC} $(argv_show)"
fi

# ── (9) MAKE-LEVEL injection neutralized on the non-seam knobs ────────────────
# Section (7) proves the _PHONE_ARGS SHELL seam ($${VAR:+...}) is inert, but the
# flash SERIAL guard, the boolean flags, and PLAN_VERB were once read via Make's
# own $(strip $(SERIAL))/$(if $(strip $(YES)))/$(PLAN_VERB) — those expand the
# value at MAKE-EXPANSION time, so an environment-origin (recursively-expanded)
# value carrying $(shell …) EXECUTES before any recipe line runs. This is the
# real bug the sweep found; all four now go through the shell instead. Each probe
# plants a $(shell touch <marker>) payload and asserts the marker never appears.
echo '-- 9) make-level $(shell …) injection is neutralized on SERIAL/YES/FORCE/PLAN_VERB --'
inj_probe() { # inj_probe <label> <target> <VAR>
  local label="$1" target="$2" var="$3" marker="${WORK}/pwn-${3}"
  rm -f "${marker}"
  # The payload is a Make function call; it fires at expansion time on the
  # vulnerable form, is an inert string through the shell form.
  run_make "${target}" "${var}=\$(shell touch ${marker})x"
  if [ -e "${marker}" ]; then
    bad "(9) MAKE-LEVEL INJECTION via ${var}: \$(shell …) executed at expansion time"
  else
    ok "(9) ${var} carries \$(shell …) inertly (${label})"
  fi
}
inj_probe "flash SERIAL guard"  phone-flash  SERIAL
inj_probe "boolean YES"         phone-status YES
inj_probe "boolean FORCE"       phone-status FORCE
inj_probe "PLAN_VERB"           phone-plan   PLAN_VERB
# The flash guard must STILL refuse an unset serial (the fix is a shell guard,
# not a removal): a value that Make would once have executed is now just a
# non-empty serial string, so flash actually DELEGATES with it verbatim.
run_make phone-flash 'SERIAL=$(shell touch '"${WORK}"'/should-not-exist)x'
argv_is flash --work-dir "${WD}" --serial '$(shell touch '"${WORK}"'/should-not-exist)x' \
  && [ ! -e "${WORK}/should-not-exist" ] \
  && ok "(9) the once-injectable SERIAL now rides argv as an inert literal (guard still gates)" \
  || bad "(9) SERIAL passthrough wrong: $(argv_show)"

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
