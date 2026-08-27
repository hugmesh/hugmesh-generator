#!/usr/bin/env bash
# test-url-embedded-credentials.sh
#
# A GENERATED PASSWORD THAT LANDS INSIDE A URL MUST BE URL-SAFE.
#
# `openssl rand -base64` draws from an alphabet containing + / and =. Interpolated
# into a connection URL:
#
#     r2dbc:postgresql://fe_gateway:$(ROUTE_ACCESS_DB_PASSWORD)@route-access-db...
#
# R2DBC parses that with ConnectionFactoryOptions.parse(), which URL-decodes the
# userinfo, so a literal `+` reaches Postgres as a SPACE and authentication fails.
#
# IT FAILS OPEN, AND SILENTLY. A gateway that cannot reach route-access-db has no
# route_access rows, so it enforces nothing: a plain ROLE_USER gets HTTP 200 and the
# admin UI shell. Nothing logs "RBAC is off".
#
# NOT RARE. 24 base64 bytes is 32 characters, each with a 2-in-64 chance of being
# + or /, so ~63% of bootstraps mint at least one unusable credential. MEASURED on
# the live kind cluster 2026-08-27: three of six route-access passwords contained
# `+`, two of them (fe_gateway, pki_gateway) on gateways whose URL embeds it.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
RESOLVER="${HERE}/url_embedded_credentials.py"
GEN="${REPO}/scripts/gen-cluster-secrets.sh"

P=0; F=0
ok()  { echo "  ok   $*"; P=$((P + 1)); }
bad() { echo "  FAIL $*"; F=$((F + 1)); }

echo "== credentials embedded in a URL =="

# ── 1. every URL-embedded credential traces back to a URL-safe generator ─────
# DERIVED, not listed: the sites come from the manifests themselves, so a NEW
# URL-embedded credential is checked on the day it is added rather than whenever
# someone remembers to extend a hardcoded list.
echo "-- 1. every embedding site resolves to rand_urlsafe --"
if [ ! -f "${RESOLVER}" ]; then
  bad "url_embedded_credentials.py is missing — section 1 asserted NOTHING"
elif [ ! -f "${GEN}" ]; then
  bad "scripts/gen-cluster-secrets.sh is missing — nothing to resolve against"
else
  rows="$(python3 "${RESOLVER}" "${REPO}" 2>/dev/null)"
  n="$(printf '%s' "${rows}" | grep -c . || true)"
  # VACUITY FLOOR: a resolver that silently found nothing would pass forever.
  if [ "${n:-0}" -lt 5 ]; then
    bad "only ${n:-0} URL-embedding site(s) found — expected 5+. Either the resolver
       stopped matching the manifests' shape, or the sites moved. A guard that
       found nothing must not report success."
  else
    unresolved="$(printf '%s\n' "${rows}" | awk -F'\t' '$7 != "OK"')"
    unsafe="$(printf '%s\n' "${rows}" | awk -F'\t' '$7 == "OK" && $6 != "rand_urlsafe"')"
    if [ -n "${unresolved}" ]; then
      # An unresolvable chain is a FAILURE, never a skip: a chain this guard cannot
      # follow is a chain it cannot vouch for.
      bad "chain could not be followed to the generator (this is a failure, not a skip):
$(printf '%s\n' "${unresolved}" | awk -F'\t' '{printf "      %s  env=%s  %s\n", $1, $2, $7}')"
    elif [ -n "${unsafe}" ]; then
      bad "credential embedded in a URL but minted by a NON-url-safe generator:
$(printf '%s\n' "${unsafe}" | awk -F'\t' '{printf "      %s  %s = $(%s ...)\n", $1, $5, $6}')
       => use rand_urlsafe; base64 carries + / = and cannot survive a URL."
    else
      ok "${n} URL-embedding site(s), every one traced through secretKeyRef ->
       ExternalSecret -> Vault property -> rand_urlsafe"
    fi
  fi
fi

# ── 2. the generator really is URL-safe, and the check can fail ──────────────
echo "-- 2. rand_urlsafe output, and a control that proves the check bites --"
if [ ! -f "${GEN}" ]; then
  bad "cannot source the generator"
else
  # Pull the function out rather than sourcing the whole script, which mints a
  # cluster's worth of secrets as a side effect.
  fn="$(awk '/^rand_urlsafe\(\)/,/^}/' "${GEN}")"
  if [ -z "${fn}" ]; then
    bad "rand_urlsafe() not found in gen-cluster-secrets.sh — NOT asserting a
       property of a function that does not exist"
  else
    eval "${fn}"
    draws=0; badchars=""
    for _ in $(seq 1 60); do
      v="$(rand_urlsafe 24)"
      draws=$((draws + 1))
      case "${v}" in *[!A-Za-z0-9_-]*) badchars="${badchars} ${v}";; esac
      [ -n "${v}" ] || badchars="${badchars} <empty>"
    done
    if [ "${draws}" -lt 60 ]; then
      bad "only ${draws} draws taken — too few to say anything"
    elif [ -n "${badchars}" ]; then
      bad "rand_urlsafe emitted non-url-safe output in ${draws} draws:${badchars}"
    else
      # THE CONTROL. Without it, an alphabet check would also "pass" against a
      # generator that returned the empty string, or if the loop never ran.
      hits=0
      for _ in $(seq 1 60); do
        b="$(openssl rand -base64 24)"
        case "${b}" in *[!A-Za-z0-9_-]*) hits=$((hits + 1));; esac
      done
      if [ "${hits}" -eq 0 ]; then
        bad "control failed: 60 plain base64 draws produced NO url-unsafe character,
       so this section cannot distinguish a safe generator from an unsafe one and
       its pass means nothing"
      else
        ok "60/60 rand_urlsafe draws are [A-Za-z0-9_-]; control: ${hits}/60 plain
       base64 draws carry a url-unsafe character, so the check does bite"
      fi
    fi
  fi
fi

# ── 3. the decode that makes this a security bug, executable ────────────────
echo "-- 3. what a URL parser does to a literal + in userinfo --"
python3 - <<'PY'
import sys
from urllib.parse import unquote_plus, urlsplit

fail = []

# (a) `+` SURVIVES parsing but is DECODED to a space. This is the quiet one: the URL
#     still looks well-formed, the connection is still attempted, and Postgres simply
#     rejects a password nobody ever minted.
pw = "ab+cd"
got = unquote_plus(urlsplit("postgresql://user:%s@host:5432/db" % pw).password or "")
if got == pw:
    fail.append("a '+' round-tripped UNCHANGED — the premise that it gets decoded does "
                "not hold here, so this leg is asserting nothing. Re-derive it.")
elif got != "ab cd":
    fail.append("expected '+' to decode to a space ('ab cd'), got %r" % got)
else:
    print("  ok   userinfo %r decodes to %r — the '+' becomes a SPACE, so the password" % (pw, got))
    print("       presented to Postgres is not the one that was minted")

# (b) `/` is worse, and differently wrong: it ENDS the authority, so the password is
#     truncated and the remainder is read as a path.
pw2 = "ab/cd"
parsed = urlsplit("postgresql://user:%s@host:5432/db" % pw2)
if parsed.password == pw2:
    fail.append("a '/' round-tripped unchanged — expected it to terminate the authority")
else:
    print("  ok   userinfo %r does not survive at all (password=%r host=%r) — '/' ends"
          % (pw2, parsed.password, parsed.hostname))
    print("       the authority, so the URL no longer even names the right host")

for f in fail:
    print("  FAIL " + f)
sys.exit(1 if fail else 0)
PY
if [ $? -eq 0 ]; then P=$((P + 2)); else F=$((F + 1)); fi

echo
echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ] || exit 1
exit 0
