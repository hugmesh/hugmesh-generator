#!/usr/bin/env bash
# test-web-locales-wiring.sh — the INERT-KNOB gate for the web-login LOCALE SET,
# and the regression gate for rename phase 3c (SNAP_WEB_LOCALES -> HUG_WEB_LOCALES
# on the producer side).
#
# WHY THIS GATE EXISTS. The locale set crosses four links by NAME ALONE, with no
# schema, no version and no handshake:
#
#   Studio  LocalMeshBootstrapConfig.web_locales
#     -> LocalStackNode._build_env()                       (env for `make stack-up`)
#     -> Makefile  HUG_WEB_LOCALES/SNAP_WEB_LOCALES -> STACK_WEB_LOCALES -> STACK_ENV
#     -> tests/stack/compose.local.yaml  build.args        (${…:-} interpolation)
#     -> hugmesh-login-ui  Dockerfile ARG  -> tools/i18n/emit-shipped-locales.mjs
#
# Break ANY link on ONE side and nothing fails. The chain still builds, the stack
# still boots, `make stack-up` still exits 0 — the image just ships zero catalogs
# and the UI serves untranslated. There is no error, no warning and no log line,
# because "no locales requested" is also the legitimate default. That is exactly
# the shape of failure this repo has shipped before (the gateway MFA trio wired to
# zero consumers; the AI-cloak lane needing BOTH halves), which is why the locale
# knob gets a gate that proves the value ARRIVES rather than that a name exists.
#
# It is also why the phase-3c rename is guarded rather than trusted. Both ends of
# the rename ladder are asymmetric and both directions of version skew are real:
#
#   * the Studio is INSTALLED SEPARATELY from the generator tree it drives
#     (LocalStackNode.generator_dir is a constructor argument), so a new Studio can
#     call an OLD Makefile that reads only SNAP_WEB_LOCALES;
#   * the login-ui build context is ${STACK_SRC}/hugmesh-login-ui, a checkout at a
#     pinned branch, so a new compose file can build an OLD Dockerfile that
#     declares only ARG SNAP_WEB_LOCALES.
#
# So phase 3c is a DUAL WRITE with the new name primary: every producer emits both
# spellings carrying the SAME value, and the Makefile ACCEPTS either on input with
# NON-EMPTY-wins precedence (not `?=` defined-wins — the Studio and the Makefile
# both materialise the new name unconditionally, so "defined" carries no
# information; only emptiness does, and that is the same rule the consumer's
# webLocalesEnv() applies). Lane A proves that precedence by EXECUTION, not by
# reading the Makefile.
#
# LANES
#   A  Makefile precedence      — real `make` evaluation of STACK_ENV, 5 cases
#   B  compose artifact shape   — re-derived from the YAML: both names, each
#                                 interpolated from its OWN name, under build.args
#                                 and NOT environment
#   C  Studio env producer      — LocalStackNode._build_env() executed
#   D  end-to-end interpolation — make's STACK_ENV fed to `docker compose config`
#
# WHAT THIS GATE DOES NOT OWN: the consumer half. Whether the login-ui image turns
# the ARG into catalog files is hugmesh-login-ui's own tools/i18n/web-locales.test.mjs
# (which pins webLocalesEnv()'s non-empty-wins rule, including the trap that the
# Dockerfile materialises `ENV HUG_WEB_LOCALES=` for an unpassed build arg, so a
# `??` fallback would read the new name's empty string and never consult the old).
# This gate stops at the build arg because that is where this repo's authority stops.
#
# No cluster, no kubectl, no daemon, no image build. Lane D needs the `docker
# compose` CLI for interpolation only (no daemon call) and reports INCOMPLETE — not
# PASS — when it is missing: an unrun assertion is not a pass.
#
# EXIT CODES
#   0  PASS        — every lane ran and every assertion held
#   1  FAIL        — a link is broken (offenders printed)
#   2  FATAL       — environment problem (missing make/python3/PyYAML/repo file)
#   3  INCOMPLETE  — no violation found, but a lane could not run. Non-zero on
#                   purpose: an unrun assertion is not a pass. Set
#                   WEB_LOCALES_ALLOW_INCOMPLETE=1 to opt out DELIBERATELY (exit 0,
#                   but the verdict line still says PASS (INCOMPLETE …), never a
#                   clean PASS) — the same honesty contract
#                   scripts/validate-catalog-discovery.sh's stage 5 carries. The
#                   lint lane uses it for lane D only, because `docker compose` is
#                   not in a python:3-slim image; lanes A and B already prove each
#                   half of that link separately, D proves them composed.
set -uo pipefail

ALLOW_INCOMPLETE="${WEB_LOCALES_ALLOW_INCOMPLETE:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
COMPOSE_FILE="${REPO_ROOT}/tests/stack/compose.local.yaml"
MAKEFILE="${REPO_ROOT}/Makefile"
STUDIO_DIR="${REPO_ROOT}/studio"
SERVICE="hugmesh-login-ui"

FAILED=0
INCOMPLETE=0
ok()   { printf '  ok   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; FAILED=1; }
skip() { printf '  SKIP %s\n' "$*"; INCOMPLETE=1; }

for f in "$MAKEFILE" "$COMPOSE_FILE"; do
  [ -f "$f" ] || { echo "FATAL: missing required file: $f" >&2; exit 2; }
done
command -v make    >/dev/null 2>&1 || { echo "FATAL: make not available" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 not available" >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "FATAL: PyYAML not available" >&2; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# A throwaway makefile fragment that prints one variable. Appended with a second
# -f so the real Makefile is parsed EXACTLY as `make stack-up` parses it — the
# point is to read the value make itself computes, never to re-implement the `if`.
printf 'print-%%:\n\t@printf "%%s\\n" "$(%s)"\n' '$*' > "${WORK}/print.mk"

stack_env() {
  # Echo the WEB_LOCALES assignments make puts into STACK_ENV, one per line, for
  # the given input environment. Input is passed as ENV (not as a make command-line
  # override) because that is how the Studio hands it over: subprocess env.
  env "$@" make --no-print-directory -C "${REPO_ROOT}" \
      -f "${MAKEFILE}" -f "${WORK}/print.mk" print-STACK_ENV 2>/dev/null \
    | tr ' ' '\n' | grep -E "^(HUG|SNAP)_WEB_LOCALES=" || true
}

expect_pair() {
  # $1 label, $2 expected value (may be empty), rest: input env assignments
  local label="$1" want="$2"; shift 2
  local got hug snap
  got="$(stack_env "$@")"
  hug="$(printf '%s\n' "$got"  | sed -n "s/^HUG_WEB_LOCALES='\(.*\)'$/\1/p")"
  snap="$(printf '%s\n' "$got" | sed -n "s/^SNAP_WEB_LOCALES='\(.*\)'$/\1/p")"
  if ! printf '%s\n' "$got" | grep -q "^HUG_WEB_LOCALES="; then
    bad "${label}: STACK_ENV carries no HUG_WEB_LOCALES at all"; return
  fi
  if ! printf '%s\n' "$got" | grep -q "^SNAP_WEB_LOCALES="; then
    bad "${label}: STACK_ENV dropped the SNAP_WEB_LOCALES skew mirror"; return
  fi
  if [ "$hug" = "$want" ] && [ "$snap" = "$want" ]; then
    ok "${label} -> both names carry '${want}'"
  else
    bad "${label}: expected both='${want}', got HUG='${hug}' SNAP='${snap}'"
  fi
}

echo "== lane A: Makefile precedence (real make evaluation of STACK_ENV) =="
# The live name alone — the phase-3c path every current producer takes.
expect_pair "A1 new name only"        "de,fr" HUG_WEB_LOCALES=de,fr
# The retired name alone. This is an OLDER STUDIO, or an operator typing the
# spelling that has been in the docs and their shell history all along. If this
# case ever regresses, those callers ship English-only and exit 0.
expect_pair "A2 legacy name only"     "nl,pt" SNAP_WEB_LOCALES=nl,pt
# Both set and disagreeing: the live name must win, or the rename never happened.
expect_pair "A3 both set, new wins"   "de,fr" HUG_WEB_LOCALES=de,fr SNAP_WEB_LOCALES=nl,pt
# NON-EMPTY-wins, the assertion that separates this from a `?=`/defined-wins
# reading. A producer that materialises HUG_WEB_LOCALES='' (the Studio's default
# path, the Dockerfile's unpassed ARG) must NOT thereby veto the legacy value.
expect_pair "A4 new set EMPTY, legacy honoured" "nl,pt" HUG_WEB_LOCALES= SNAP_WEB_LOCALES=nl,pt
# The default has to stay the smallest artifact: empty, English-only, no catalogs.
expect_pair "A5 neither set"          ""

echo
echo "== lane B: compose build args (re-derived from the artifact) =="
python3 - "$COMPOSE_FILE" "$SERVICE" <<'PY'
import sys, yaml
path, service = sys.argv[1], sys.argv[2]
doc = yaml.safe_load(open(path, encoding="utf-8"))
svc = (doc.get("services") or {}).get(service)
rc = 0
def ok(m):  print(f"  ok   {m}")
def bad(m):
    global rc; rc = 1; print(f"  FAIL {m}")

if svc is None:
    bad(f"service {service} not found in {path}"); sys.exit(1)

args = (svc.get("build") or {}).get("args") or {}
if isinstance(args, list):  # compose also allows KEY=VALUE strings
    args = dict(a.split("=", 1) for a in args if "=" in a)

for name in ("HUG_WEB_LOCALES", "SNAP_WEB_LOCALES"):
    if name not in args:
        bad(f"B: {service} build.args is missing {name}")
        continue
    val = str(args[name])
    # Self-interpolated, not literal and not cross-wired. A hardcoded value here
    # would leave the Studio -> make -> compose chain looking wired and doing
    # nothing; interpolating the OTHER name would make the two build args carry
    # the same env var and lose one whole input path.
    if val.strip() == "${%s:-}" % name:
        ok(f"B: build.args {name} interpolates ${{{name}:-}}")
    else:
        bad(f"B: build.args {name} is {val!r} — must be '${{{name}:-}}' "
            "(a literal disconnects the chain; the other name loses an input)")

# BUILD arg, not runtime env: which catalogs SHIP is decided at build time. As an
# `environment:` entry every image would be byte-identical and the knob would
# change nothing — the dead-knob shape this gate exists to refuse.
env = svc.get("environment") or {}
if isinstance(env, list):
    env = dict((e.split("=", 1) + [""])[:2] for e in env)
leaked = [k for k in env if k.endswith("WEB_LOCALES")]
if leaked:
    bad(f"B: {leaked} appears under environment: — it must be a BUILD ARG only "
        "(a runtime var cannot change which catalogs the image contains)")
else:
    ok("B: no *_WEB_LOCALES under environment: (build-time only, as designed)")
sys.exit(rc)
PY
[ $? -ne 0 ] && FAILED=1

echo
echo "== lane C: Studio env producer (LocalStackNode._build_env executed) =="
if PYTHONPATH="${STUDIO_DIR}" python3 - "$REPO_ROOT" <<'PY'
import sys
try:
    from hugmesh_studio.core.local_stack_node import LocalStackNode
except Exception as exc:                      # noqa: BLE001 - reported, never swallowed
    print(f"  IMPORT-FAILED {exc}")
    sys.exit(2)
rc = 0
def ok(m):  print(f"  ok   {m}")
def bad(m):
    global rc; rc = 1; print(f"  FAIL {m}")

gen = sys.argv[1]
env = LocalStackNode(gen, web_locales=("de", "fr"))._build_env()
if env.get("HUG_WEB_LOCALES") == "de,fr":
    ok("C: selected locales reach the stack-up env as HUG_WEB_LOCALES")
else:
    bad(f"C: HUG_WEB_LOCALES={env.get('HUG_WEB_LOCALES')!r}, expected 'de,fr'")
# The skew mirror: an installed Studio can drive an older generator checkout.
if env.get("SNAP_WEB_LOCALES") == "de,fr":
    ok("C: legacy SNAP_WEB_LOCALES mirrored with the same value")
else:
    bad(f"C: SNAP_WEB_LOCALES={env.get('SNAP_WEB_LOCALES')!r}, expected 'de,fr' — "
        "an older Makefile would read this as unset and ship English-only")
# The default must add ZERO bytes: neither spelling, or the no-op default is not one.
d = LocalStackNode(gen)._build_env()
stray = [k for k in d if k.endswith("WEB_LOCALES")]
if stray:
    bad(f"C: the English-only default emitted {stray} — it must emit neither name")
else:
    ok("C: default emits neither spelling (byte-identical to a plain stack-up)")
sys.exit(rc)
PY
then :; else
  case $? in
    2) skip "C: hugmesh_studio not importable here (PYTHONPATH=${STUDIO_DIR})" ;;
    *) FAILED=1 ;;
  esac
fi

echo
echo "== lane D: end-to-end interpolation (make STACK_ENV -> docker compose config) =="
if docker compose version >/dev/null 2>&1; then
  for pair in "HUG_WEB_LOCALES=de,fr:de,fr" "SNAP_WEB_LOCALES=nl,pt:nl,pt"; do
    input="${pair%%:*}"; want="${pair##*:}"
    assigns="$(stack_env "$input" | tr '\n' ' ' | sed "s/'//g")"
    [ -n "$assigns" ] || { bad "D: make produced no WEB_LOCALES env for ${input}"; continue; }
    resolved="$(eval "env ${assigns} docker compose -f '${COMPOSE_FILE}' config" 2>/dev/null \
      | python3 -c '
import sys, yaml
doc = yaml.safe_load(sys.stdin) or {}
svc = (doc.get("services") or {}).get("'"${SERVICE}"'") or {}
args = (svc.get("build") or {}).get("args") or {}
print(args.get("HUG_WEB_LOCALES", "<absent>"))
print(args.get("SNAP_WEB_LOCALES", "<absent>"))')"
    hug="$(printf '%s\n' "$resolved" | sed -n 1p)"
    snap="$(printf '%s\n' "$resolved" | sed -n 2p)"
    if [ "$hug" = "$want" ] && [ "$snap" = "$want" ]; then
      ok "D: ${input} survives make + compose interpolation as both names = '${want}'"
    else
      bad "D: ${input} resolved to HUG='${hug}' SNAP='${snap}', expected both '${want}'"
    fi
  done
else
  skip "D: the \`docker compose\` CLI is unavailable — interpolation not proven"
fi

echo
if [ "$FAILED" -ne 0 ]; then
  echo "RESULT: FAIL — a link in the web-locales chain is broken"
  exit 1
fi
if [ "$INCOMPLETE" -ne 0 ]; then
  echo "RESULT: PASS (INCOMPLETE — a lane above could not run; see SKIP lines)"
  [ "$ALLOW_INCOMPLETE" = "1" ] && exit 0
  exit 3
fi
echo "RESULT: PASS — the locale set reaches the login-ui build arg under both spellings"
exit 0
