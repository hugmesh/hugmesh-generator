#!/usr/bin/env bash
# test-front-door-client-surface.sh — regression gate for three defects that all
# share one shape: a config knob that LOOKS set, silently is not honoured, and
# fails in a way no status-code check notices.
#
# All three were measured on the live local mesh on 2026-08-14 and are pinned
# here STATICALLY (files only — no docker, no network), so CI catches a
# re-regression without a running stack.
#
# ── (A) THE FRONT DOOR MUST DECLARE ITS TLS TERMINATOR ────────────────────────
# Spring Cloud Gateway >= 4.1 only honours X-Forwarded-* when the IMMEDIATE peer
# is a trusted proxy. With no `trusted-proxies`, NOTHING is trusted, so
# XForwardedHeadersFilter throws away the terminator's X-Forwarded-Proto AND any
# value a route's own SetRequestHeader filter set, then rewrites both from the raw
# connection. The fe table had the Mastodon route's
# `SetRequestHeader=X-Forwarded-Proto, https` but not the key that lets it survive:
#   GET https://localhost:8488/api/v1/instance
#   -> 301 https://mastodon-web:3000/api/v1/instance
# Mastodon's force_ssl decided the request was not TLS and 301'd to its own
# https URL, built from the proxied authority — a COMPOSE-INTERNAL host no
# external client can resolve, so a Mastodon client handshake died at step one on
# a DNS failure. HTTP 301 is a "successful" response to anything that only checks
# for 5xx, which is why it survived.
#
# ── (B) TUWUNEL'S WELL-KNOWN KEYS ARE NESTED, NOT FLAT ────────────────────────
# The discovery documents come from tuwunel's `[global.well_known]` TABLE
# (struct WellKnownConfig: client / server / support_* / rtc_transports). The flat
# `well_known_client` / `well_known_server` spelling is a Conduit-era name tuwunel
# has REMOVED, and removal is SILENT — a warning in the log, then the setting is
# dropped. Both lanes had the flat spelling, so both served 404 M_NOT_FOUND with
# the config apparently present:
#   docker logs hugmesh-local-tuwunel-1
#   WARN tuwunel_core::config::check: Config parameter "well_known_client" is
#        deprecated, ignoring. ... is unknown to tuwunel, ignoring.
# In env form the nesting separator is figment's `__`, so the compose lane must
# spell it TUWUNEL_WELL_KNOWN__CLIENT (double underscore). Verified by running the
# ghcr.io/matrix-construct/tuwunel:v1.7.0 binary under each spelling: the nested
# form serves 200 application/json with zero config warnings, the flat form 404s.
#
# ── (C) THE AI-CLOAK NEEDS ITS EGRESS LEG, NOT JUST ITS FEATURE FLAG ──────────
# app.media.poisoning.* decides whether the cloak is OFFERED. The homeserver
# upload of the cloaked bytes is a SEPARATE, separately gated client
# (app.media.proxy.<platform>.enabled). Offered-but-not-wired does not degrade:
#   GET  /bff/user/media/capability -> 200 {"available":true,...}
#   POST /bff/user/media/upload     -> 500  IllegalStateException: homeserver
#        media proxy for 'mastodon' is not wired (app.media.proxy.mastodon.enabled=false)
# and the composer only falls back to the working uncloaked path when the
# CAPABILITY reports unavailable, never when the upload fails — so every
# attachment 500s. That is the operator's "file uploads on mastodon stopped
# working". The fix DERIVES the egress flags from the cloak flag so the broken
# combination is unrepresentable; this gate pins that derivation.
#
# Every assertion below carries a NEGATIVE CONTROL: the check is re-run against a
# mutated copy that re-introduces the bug, and the gate fails if the check still
# passes. A green run therefore cannot be vacuous.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FE_ROUTES="$REPO/tests/stack/gateway-routes/fe/application-routes.yml"
BE_ROUTES="$REPO/tests/stack/gateway-routes/be/application-routes.yml"
COMPOSE_REAL="$REPO/tests/stack/compose.real.yaml"
COMPOSE_LOCAL="$REPO/tests/stack/compose.local.yaml"
CLUSTER_TUWUNEL="$REPO/specs/cluster/manifests/tuwunel/tuwunel.yaml"
CLUSTER_FE="$REPO/specs/cluster/apps/20-gateway-fe.yaml"
CHART_CM="$REPO/specs/cluster/charts/hugmesh-gateway/templates/configmap.yaml"

pass=0; fail=0
ok()   { printf '  PASS %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
check(){ if [ "$1" = "0" ]; then ok "$2"; else bad "$2"; fi; }

for f in "$FE_ROUTES" "$BE_ROUTES" "$COMPOSE_REAL" "$COMPOSE_LOCAL" \
         "$CLUSTER_TUWUNEL" "$CLUSTER_FE" "$CHART_CM"; do
  [ -f "$f" ] || { echo "FAIL-CLOSED: missing $f"; exit 1; }
done

# ── (A) trusted-proxies on the TLS-terminated front door ─────────────────────
echo "== (A) the front door declares its TLS terminator =="

# Read it out of the PARSED yaml, not with grep: a key that is present but nested
# in the wrong place (the SCG 5.0 trap this very file's header warns about — the
# legacy spring.cloud.gateway.* prefix binds NOTHING) would satisfy a grep and
# bind nothing at runtime.
tp_at() {  # $1=file  -> prints the value bound at spring.cloud.gateway.server.webflux.trusted-proxies
  python3 - "$1" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
w = (((d.get('spring') or {}).get('cloud') or {}).get('gateway') or {}).get('server') or {}
print((w.get('webflux') or {}).get('trusted-proxies') or '')
PY
}

FE_TP="$(tp_at "$FE_ROUTES")"
[ -n "$FE_TP" ]; check $? "fe route table binds server.webflux.trusted-proxies (got: '${FE_TP:-<empty>}')"

# The be tier has carried this key since its own live debug; the fe tier is the
# one that is ACTUALLY behind the TLS terminator, so it must not be the laggard.
BE_TP="$(tp_at "$BE_ROUTES")"
[ -n "$BE_TP" ]; check $? "be route table still binds it too (the precedent this mirrors)"

# The peer set must actually cover the compose bridge network, or the key is
# decoration: hugmesh-https-front reaches the gateway from a 172.x address.
python3 - "$FE_TP" <<'PY'
import re, sys
pat = sys.argv[1]
sys.exit(0 if re.fullmatch(pat, "172.18.0.7") and re.fullmatch(pat, "127.0.0.1") else 1)
PY
check $? "the regex admits the compose bridge (172.x) and loopback — the real peers"

# ...and must NOT be a blanket match-anything.
python3 - "$FE_TP" <<'PY'
import re, sys
pat = sys.argv[1]
# A public address must NOT be trusted.
sys.exit(1 if re.fullmatch(pat, "8.8.8.8") else 0)
PY
check $? "the regex does NOT trust arbitrary/public peers"

# The Mastodon routes still assert the scheme (trusted-proxies is what makes the
# assertion survive; deleting either half re-opens the defect).
grep -q 'SetRequestHeader=X-Forwarded-Proto, https' "$FE_ROUTES"
check $? "the fe Mastodon routes still set X-Forwarded-Proto: https"

# NEGATIVE CONTROL: strip the key and the first assertion must go red.
NEG="$(mktemp)"; grep -v 'trusted-proxies:' "$FE_ROUTES" > "$NEG"
[ -z "$(tp_at "$NEG")" ]; check $? "negative control: trusted-proxies deleted -> the bound value goes empty (gate would fail)"
rm -f "$NEG"

# ── (A2) cluster parity: the chart must be ABLE to render it, and fe must set it ─
echo "== (A2) the cluster lane can express the same key =="
grep -q 'trusted-proxies: {{' "$CHART_CM"
check $? "the shared gateway chart renders trusted-proxies"
grep -q 'with .Values.trustedProxies' "$CHART_CM"
check $? "...guarded by \`with\`, so instances that do not set it render byte-identically"

python3 - "$CLUSTER_FE" <<'PY'
import sys, yaml
app = yaml.safe_load(open(sys.argv[1]))
vals = yaml.safe_load(app['spec']['source']['helm']['values'])
tp = vals.get('trustedProxies') or ''
if not tp:
    sys.exit("fe Application sets no trustedProxies")
import re
# The cluster pod CIDR (specs/etc/kubernetes/kubeadm-config.yaml podSubnet).
if not re.fullmatch(tp, "10.244.3.9"):
    sys.exit("trustedProxies does not admit the pod CIDR 10.244.0.0/16: %r" % tp)
if re.fullmatch(tp, "8.8.8.8"):
    sys.exit("trustedProxies trusts a public address: %r" % tp)
PY
check $? "the fe Application sets trustedProxies to the pod CIDR + loopback, and no wider"

# ── (B) tuwunel well-known: nested spelling on BOTH lanes ────────────────────
echo "== (B) tuwunel autodiscovery uses the NESTED well_known keys =="

# compose: env form, figment '__' nesting split.
tuw_env() {  # $1=file -> prints the tuwunel service's env keys, one per line
  python3 - "$1" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
env = (d.get('services') or {}).get('tuwunel', {}).get('environment') or {}
print('\n'.join(env if isinstance(env, list) else env.keys()))
PY
}
ENVKEYS="$(tuw_env "$COMPOSE_REAL")"

grep -qx 'TUWUNEL_WELL_KNOWN__CLIENT' <<<"$ENVKEYS"
check $? "compose tuwunel sets TUWUNEL_WELL_KNOWN__CLIENT (DOUBLE underscore)"
grep -qx 'TUWUNEL_WELL_KNOWN__SERVER' <<<"$ENVKEYS"
check $? "compose tuwunel sets TUWUNEL_WELL_KNOWN__SERVER (DOUBLE underscore)"

# The removed flat spelling must be GONE, not merely accompanied — tuwunel logs
# "unknown to tuwunel, ignoring" for it, which is noise that reads like config.
! grep -qx 'TUWUNEL_WELL_KNOWN_CLIENT' <<<"$ENVKEYS" && ! grep -qx 'TUWUNEL_WELL_KNOWN_SERVER' <<<"$ENVKEYS"
check $? "the removed FLAT spelling (single underscore) is gone from compose"

# The advertised base must be a PUBLIC address, never an in-network container.
python3 - "$COMPOSE_REAL" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
env = d['services']['tuwunel']['environment']
v = str(env.get('TUWUNEL_WELL_KNOWN__CLIENT', ''))
for internal in ('tuwunel:8008', 'tuwunel-proxy', 'mastodon-web', 'hugmesh-fe-gateway'):
    if internal in v:
        sys.exit("well-known advertises an in-network host: %r" % v)
if not v.startswith('${') and not v.startswith('http'):
    sys.exit("well-known client base is not a URL: %r" % v)
PY
check $? "the advertised client base is the PUBLIC door, not an in-network container name"

# cluster: TOML table form.
python3 - "$CLUSTER_TUWUNEL" <<'PY'
import sys, yaml
try:
    import tomllib
except ModuleNotFoundError:
    sys.exit(0)  # py<3.11: the yaml-level checks below still gate this file
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
cm = [d for d in docs if d.get('kind') == 'ConfigMap' and d['metadata']['name'] == 'tuwunel-config'][0]
g = tomllib.loads(cm['data']['tuwunel.toml'])['global']
wk = g.get('well_known')
if not isinstance(wk, dict):
    sys.exit("[global.well_known] is not a table: %r" % (wk,))
for k in ('client', 'server'):
    if not wk.get(k):
        sys.exit("[global.well_known].%s is unset" % k)
for dead in ('well_known_client', 'well_known_server'):
    if dead in g:
        sys.exit("the removed flat key %s is still in [global]" % dead)
# A sub-table swallows every bare key written after it — nothing may have fallen in.
for leaked in ('turn_ttl', 'server_name', 'trusted_servers'):
    if leaked in wk:
        sys.exit("%s leaked into [global.well_known] — the table is not last" % leaked)
PY
check $? "cluster tuwunel.toml uses [global.well_known] client/server, flat keys gone, no bare key swallowed"

# NEGATIVE CONTROL: put the flat spelling back and the compose check must go red.
NEG="$(mktemp)"; sed 's/TUWUNEL_WELL_KNOWN__CLIENT/TUWUNEL_WELL_KNOWN_CLIENT/' "$COMPOSE_REAL" > "$NEG"
! grep -qx 'TUWUNEL_WELL_KNOWN__CLIENT' <<<"$(tuw_env "$NEG")"
check $? "negative control: flat spelling restored -> the nested-key check goes red"
rm -f "$NEG"

# ── (C) the AI-cloak egress leg is bound to the cloak flag ───────────────────
echo "== (C) the AI-cloak's homeserver egress cannot be left dark while the cloak is offered =="

ubff_env() {  # $1=file -> prints "KEY=VALUE" for the user-bff service env
  python3 - "$1" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
env = d['services']['hugmesh-user-bff-api']['environment']
items = (e.split('=', 1) for e in env) if isinstance(env, list) else env.items()
for k, v in items:
    print("%s=%s" % (k, v))
PY
}
UB="$(ubff_env "$COMPOSE_LOCAL")"

for k in MEDIA_PROXY_MASTODON_ENABLED MEDIA_PROXY_MATRIX_ENABLED \
         MEDIA_PROXY_MASTODON_BASE_URL MEDIA_PROXY_MATRIX_BASE_URL; do
  grep -q "^$k=" <<<"$UB"; check $? "compose user-bff sets $k"
done

# The enablement must DERIVE from the cloak flag. A hardcoded `true` would make
# the cloak-off lane dial homeservers it should not, and a hardcoded `false`
# re-creates the 500.
# (Deliberately not a `grep -c` pipeline: `grep -c` exits 1 on a count of 0, which
# under `set -o pipefail` reports the ALL-GOOD case as a failure.)
derives_from_cloak() {  # $1=file -> 0 when every egress flag references the cloak flag
  python3 - "$1" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
env = d['services']['hugmesh-user-bff-api']['environment']
items = dict(e.split('=', 1) for e in env) if isinstance(env, list) else env
flags = {k: v for k, v in items.items()
         if k.startswith('MEDIA_PROXY_') and k.endswith('_ENABLED')}
missing = {'MEDIA_PROXY_MASTODON_ENABLED', 'MEDIA_PROXY_MATRIX_ENABLED'} - set(flags)
if missing:  # absent is not "derived" — it inherits the image's dark default
    sys.exit("egress flags absent entirely: %s" % ', '.join(sorted(missing)))
bad = [k for k, v in flags.items() if 'MEDIA_POISONING_ENABLED' not in str(v)]
if bad:
    sys.exit("hardcoded, not derived from the cloak flag: %s" % ', '.join(sorted(bad)))
PY
}
derives_from_cloak "$COMPOSE_LOCAL"
check $? "both MEDIA_PROXY_*_ENABLED derive from MEDIA_POISONING_ENABLED (not hardcoded)"

# The base URLs must be the COMPOSE homeservers. The image defaults are the
# cluster's akkoma-proxy/tuwunel-proxy, which are NXDOMAIN here — inheriting them
# turns the 500 into a DNS failure rather than fixing anything.
grep -q '^MEDIA_PROXY_MASTODON_BASE_URL=.*mastodon-web:3000' <<<"$UB"
check $? "the mastodon media-proxy base URL is the compose homeserver"
grep -q '^MEDIA_PROXY_MATRIX_BASE_URL=.*tuwunel:8008' <<<"$UB"
check $? "the matrix media-proxy base URL is the compose homeserver"
! grep -E '^MEDIA_PROXY_.*BASE_URL=' <<<"$UB" | grep -q 'svc.cluster.local'
check $? "neither base URL inherited a cluster-only host"

# NEGATIVE CONTROL: hardcode the egress flag off — exactly the state that produced
# the live 500 — and the derivation check must go red.
NEG="$(mktemp)"
sed 's|MEDIA_PROXY_MASTODON_ENABLED: .*|MEDIA_PROXY_MASTODON_ENABLED: "false"|' "$COMPOSE_LOCAL" > "$NEG"
if derives_from_cloak "$NEG" >/dev/null 2>&1; then neg=0; else neg=1; fi
[ "$neg" -eq 1 ]; check $? "negative control: egress flag hardcoded false -> the derivation check goes red"
rm -f "$NEG"

echo
echo "== front-door client surface: $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
