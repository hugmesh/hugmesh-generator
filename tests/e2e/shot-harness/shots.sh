#!/usr/bin/env bash
# shots.sh — ONE command that produces every screenshot a manual test plan cites.
#
#   npm run shots -- --persona member --door https://localhost:8488
#
# Writes tests/e2e/shots/<persona>-<NN>-<slug>.png, one file per row of
# shot-harness/shots.json. The 17 plans reference those paths; no image is ever
# pasted into a GitHub issue body (a 65,536-character cap does not survive one).
#
# WHAT THIS SCRIPT IS FOR, beyond invoking playwright:
#
#   1. IT REFUSES WHEN THE STACK IS DOWN, before a browser starts. A directory
#      of 1280x900 browser error pages under believable filenames is worse than
#      an empty directory, because it is indistinguishable from evidence to
#      everyone who did not run the harness.
#   2. IT READS THE CREDENTIAL, NEVER MINTS ONE. tests/stack/e2e-password.sh
#      GENERATES a password when EXECUTED directly; SOURCING it only defines
#      functions. This script sources it and calls the read-only
#      e2e_password_read. Minting here would produce a password the running
#      stack was never seeded with, and every sign-in would fail for a reason
#      nothing names.
#   3. IT REFUSES OFFLINE when the persona has no rows, so a plan author finds
#      out without bringing a mesh up.
#
# EXIT CODES
#   0  every selected shot captured
#   2  refused before starting a browser (bad args, stack down, no credential,
#      no rows for that persona) — nothing was written
#   *  playwright's own exit code
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E="$(cd "${HERE}/.." && pwd)"
REPO="$(cd "${E2E}/../.." && pwd)"

PERSONA=""
DOOR=""
OUT=""
MODE="capture"

die() { printf '%s\n' "$@" >&2; exit 2; }

usage() {
  cat >&2 <<'USAGE'
usage: npm run shots -- --persona <persona> --door <url> [--out <dir>]
       npm run shots -- --list                 # personas, issue numbers, shot counts
       npm run shots -- --paths --persona <p>  # the shots/… lines a plan quotes
       npm run shots -- --validate             # gate shots.json (offline)

  --persona <slug>  which plan's shots to capture; omit with --all for every persona
  --all             capture every persona in the table
  --door <url>      the mesh front door, e.g. https://localhost:8488
                    (default: $SNAP_BASE_URL, else https://localhost:${PUBLIC_HTTPS_PORT:-8488})
  --out <dir>       output directory (default: tests/e2e/shots)

Everything except --list/--paths/--validate needs a RUNNING, SEEDED stack:
  make stack-up && make stack-seed
USAGE
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --persona)   PERSONA="${2:-}"; shift 2 ;;
    --persona=*) PERSONA="${1#*=}"; shift ;;
    --door)      DOOR="${2:-}"; shift 2 ;;
    --door=*)    DOOR="${1#*=}"; shift ;;
    --out)       OUT="${2:-}"; shift 2 ;;
    --out=*)     OUT="${1#*=}"; shift ;;
    --all)       PERSONA=""; MODE="capture-all"; shift ;;
    --list)      MODE="list"; shift ;;
    --paths)     MODE="paths"; shift ;;
    --validate)  MODE="validate"; shift ;;
    -h|--help)   usage ;;
    *)           printf "shots.sh: unknown argument '%s'\n\n" "$1" >&2; usage ;;
  esac
done

# ── offline modes: no stack, no credential, no browser ───────────────────────
case "${MODE}" in
  list)     exec node "${HERE}/shot-table.mjs" list ;;
  validate) exec node "${HERE}/shot-table.mjs" validate ;;
  paths)
    [ -n "${PERSONA}" ] || die "shots.sh: --paths needs --persona <slug>. Try: npm run shots -- --list"
    exec node "${HERE}/shot-table.mjs" paths "${PERSONA}"
    ;;
esac

# The table is the contract between a plan author and this harness. Gate it
# before anything expensive: a malformed row is a screenshot of the wrong screen.
node "${HERE}/shot-table.mjs" validate >/dev/null || die "shots.sh: shots.json is invalid (run: npm run shots -- --validate)"

if [ "${MODE}" = "capture" ] && [ -z "${PERSONA}" ]; then
  die "shots.sh: --persona is required (or pass --all)." \
      "  npm run shots -- --list       to see the 17 persona slugs"
fi

# REFUSE OFFLINE when there is nothing to capture, rather than starting a
# browser to discover it.
ROWS="$(node "${HERE}/shot-table.mjs" count "${PERSONA}")"
if [ "${ROWS:-0}" -eq 0 ]; then
  die "shots.sh: shot-harness/shots.json has no rows for persona '${PERSONA}'." \
      "  Add a row (it is DATA, not code), then: npm run shots -- --validate" \
      "  Known personas: npm run shots -- --list"
fi

# ── the door ─────────────────────────────────────────────────────────────────
if [ -z "${DOOR}" ]; then DOOR="${SNAP_BASE_URL:-}"; fi
if [ -z "${DOOR}" ]; then DOOR="https://localhost:${PUBLIC_HTTPS_PORT:-8488}"; fi
DOOR="${DOOR%/}"

OUT="${OUT:-${E2E}/shots}"
case "${OUT}" in /*) ;; *) OUT="$(pwd)/${OUT}" ;; esac

command -v node >/dev/null 2>&1 || die "shots.sh: node is not on PATH."
[ -d "${E2E}/node_modules/@playwright/test" ] || \
  die "shots.sh: Playwright is not installed in tests/e2e." "  Install it: (cd tests/e2e && npm ci)"

# ── preflight: is that door actually this platform's front door? ─────────────
# Two questions, because they fail differently and a tester needs to know which.
#   (a) is ANYTHING listening?           curl exits non-zero / code 000 if not
#   (b) is it THIS platform?             GET /bff/session answers 200|401|403
# (b) is not pedantry: a bare nginx default backend answers 404 to everything,
# which is exactly what the kind node on the neighbouring port does (measured
# 2026-08-27). Screenshotting a 404 for twelve steps is the failure this catches.
PREFLIGHT_TIMEOUT="${SHOTS_PREFLIGHT_TIMEOUT:-10}"
code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time "${PREFLIGHT_TIMEOUT}" "${DOOR}/" 2>/dev/null)"
if [ -z "${code}" ] || [ "${code}" = "000" ]; then
  die "shots.sh: nothing answered ${DOOR}/ within ${PREFLIGHT_TIMEOUT}s." \
      "" \
      "  This harness refuses to start a browser against a door that is not there." \
      "  A folder of browser error pages under believable filenames is worse than" \
      "  no screenshots at all." \
      "" \
      "  Bring the stack up, then re-run:" \
      "    make stack-up && make stack-seed" \
      "  Or point at the door you meant:  --door https://<host>:<port>"
fi
session_code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time "${PREFLIGHT_TIMEOUT}" "${DOOR}/bff/session" 2>/dev/null)"
case "${session_code}" in
  200|401|403) ;;
  *)
    die "shots.sh: ${DOOR}/ answered ${code}, but GET ${DOOR}/bff/session answered ${session_code}." \
        "" \
        "  Something is listening on that port, but it is not this platform's front door" \
        "  (a bare nginx default backend answers 404 to everything). Screenshots taken" \
        "  through it would be pictures of the wrong server." \
        "" \
        "  Check the port:  make stack-up publishes 8488 by default (PUBLIC_HTTPS_PORT)." \
        "  On kind, also export SNAP_HOST_RESOLVER as the e2e lane does."
    ;;
esac

# ── the credential: READ, never mint ─────────────────────────────────────────
NEEDS_AUTH="$(node "${HERE}/shot-table.mjs" needs-auth "${PERSONA}")"
if [ "${NEEDS_AUTH}" = "yes" ] && [ -z "${E2E_PASSWORD:-}" ]; then
  # SOURCING defines functions only — it does NOT generate. Executing that file
  # directly DOES generate, which is why this line is a `.` and never a `bash`.
  # shellcheck source=../../stack/e2e-password.sh
  . "${REPO}/tests/stack/e2e-password.sh"
  set -uo pipefail   # e2e-password.sh sets its own shell options on the way in
  found="$(e2e_password_read E2E_PASSWORD)" || exit 2
  if [ -z "${found}" ]; then
    die "shots.sh: no seeded e2e password found." \
        "  Looked at: \$E2E_PASSWORD and ${E2E_CREDENTIALS_FILE:-${REPO}/.e2e-credentials}" \
        "" \
        "  This harness drives an ALREADY-SEEDED stack, so it will not mint one:" \
        "  a fresh password would not match the accounts that stack was seeded with," \
        "  and every sign-in would fail for a reason nothing names." \
        "" \
        "  Seed the stack first:  make stack-seed"
  fi
  E2E_PASSWORD="${found}"
  export E2E_PASSWORD
fi

mkdir -p "${OUT}" || die "shots.sh: could not create ${OUT}"

printf '==> persona : %s\n' "${PERSONA:-(all)}"
printf '==> door    : %s  (/ %s, /bff/session %s)\n' "${DOOR}" "${code}" "${session_code}"
printf '==> shots   : %s\n' "${OUT}"
printf '==> rows    : %s\n\n' "${ROWS}"

cd "${E2E}" || die "shots.sh: could not enter ${E2E}"
SNAP_BASE_URL="${DOOR}" \
SNAP_SHOTS="${OUT}" \
SHOTS_PERSONA="${PERSONA}" \
  npx playwright test -c shot-harness/shots.config.ts --reporter=list
rc=$?

if [ "${rc}" -eq 0 ]; then
  printf '\n==> wrote %s PNG(s) to %s\n' "$(ls -1 "${OUT}"/*.png 2>/dev/null | wc -l)" "${OUT}"
  printf '    A plan cites these as:\n'
  node "${HERE}/shot-table.mjs" paths "${PERSONA}" 2>/dev/null | sed 's/^/      /'
fi
exit "${rc}"
