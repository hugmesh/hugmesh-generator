#!/usr/bin/env bash
# test-tube-media-signed-gate.sh — the tube-media Nginx sidecar must not serve
# /tube/content/** without a VALIDATED signature.
#
# THE DEFECT THIS PINS DOWN. The sidecar's config used to be:
#
#     location /tube/content/ {
#       if ($arg_sig = "") { return 403 "missing sig"; }
#       alias /var/tube-content/;
#     }
#
# That is not a signature check. It accepts ANY non-empty value, so `?sig=x` served
# any user's bytes. The real HMAC verifier already existed and was already permitAll
# for exactly this purpose (tube-bff-api TubeMediaController#verify, GET
# /bff/tube/media/verify) — nginx simply never called it.
#
# So the assertion that matters here is NOT "an empty sig is refused" — the buggy
# config passes that. It is "a NON-EMPTY BUT INVALID sig is refused", which can only
# be true if the serve decision is delegated to something that actually verifies.
#
# TWO LEGS:
#   1) STATIC (always runs) — parse the shipped ConfigMap and assert the delegation
#      chain on the RENDERED nginx config: the location that serves the bytes is
#      gated by auth_request; the auth_request target is internal and proxies to the
#      verify endpoint; all five signed fields reach it; and no $arg_sig-shaped
#      self-decision survives anywhere.
#   2) BEHAVIOURAL (needs docker + a local nginx image; LOUDLY SKIPPED otherwise) —
#      boot real nginx on the real config with a stub verifier standing in for the
#      BFF, and measure the status codes. This is the leg that proves ?sig=x is 403.
#
# WHAT THIS DOES NOT PROVE: that TubeMediaTokenService's HMAC is itself correct. That
# is tube-bff-api's own TubeMediaTokenServiceTest. This suite proves nginx ASKS.
#
# Offline; no cluster, no stack, no build.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEPLOY="${REPO}/specs/cluster/manifests/tube/deployment.yaml"
COMPOSE="${REPO}/tests/stack/compose.local.yaml"

P=0; F=0; S=0
ok(){   echo "  PASS $*"; P=$((P+1)); }
bad(){  echo "  FAIL $*"; F=$((F+1)); }
skip(){ echo "  SKIP $*"; S=$((S+1)); }

echo "== tube-media signed-URL gate =="

command -v python3 >/dev/null 2>&1 || { echo "::error:: python3 required"; exit 1; }
python3 -c 'import yaml' 2>/dev/null || { echo "::error:: pyyaml required (this suite would otherwise assert nothing)"; exit 1; }
[ -f "${DEPLOY}" ] || { echo "::error:: missing ${DEPLOY}"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# ── extract the rendered nginx config out of the shipped ConfigMap ─────────────
if ! python3 - "${DEPLOY}" "${WORK}/default.conf" <<'PY'
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")) if d]
cm = [d for d in docs
      if d.get("kind") == "ConfigMap" and d["metadata"]["name"] == "tube-media-nginx-conf"]
if len(cm) != 1:
    sys.exit("expected exactly 1 tube-media-nginx-conf ConfigMap, found %d" % len(cm))
conf = cm[0]["data"]["default.conf"]
open(sys.argv[2], "w", encoding="utf-8").write(conf)
PY
then
  bad "could not extract tube-media-nginx-conf/default.conf from the deployment"
  echo "── PASS=${P} FAIL=${F} SKIP=${S} ──"; exit 1
fi
ok "tube-media-nginx-conf ConfigMap renders a default.conf"

# ── 1) STATIC: the delegation chain on the rendered config ────────────────────
echo "-- 1) rendered nginx config: the bytes are behind a validating gate --"
STATIC_OUT="${WORK}/static.txt"
python3 - "${WORK}/default.conf" >"${STATIC_OUT}" 2>&1 <<'PY'
import re, sys

src = open(sys.argv[1], encoding="utf-8").read()
# Strip comments BEFORE any assertion — a commented-out auth_request must not
# read as wiring (and the shipped file explains itself at length in comments).
bare = re.sub(r'(?m)#.*$', '', src)

def blocks(text):
    """Yield (header, body) for every brace block, innermost-aware."""
    out, i = [], 0
    while True:
        b = text.find('{', i)
        if b < 0:
            return out
        # header = from the previous ; } or { up to this {
        h0 = max(text.rfind(';', 0, b), text.rfind('}', 0, b), text.rfind('{', 0, b)) + 1
        header = text[h0:b].strip()
        depth, j = 1, b + 1
        while j < len(text) and depth:
            if text[j] == '{': depth += 1
            elif text[j] == '}': depth -= 1
            j += 1
        out.append((header, text[b + 1:j - 1]))
        i = b + 1

all_blocks = blocks(bare)
locs = [(h, b) for h, b in all_blocks if h.split()[:1] == ['location']]

res = []
def chk(cond, msg): res.append(("PASS" if cond else "FAIL", msg))

# (a) find the location(s) that actually hand out the content bytes
servers = [(h, b) for h, b in locs
           if re.search(r'(?m)^\s*(alias|root)\s+\S*/var/tube-content', b)]
chk(len(servers) == 1,
    "exactly one location serves /var/tube-content (found %d)" % len(servers))
if len(servers) != 1:
    for st, m in res: print(st, m)
    sys.exit(0)
shdr, sbody = servers[0]

# (b) it is gated by auth_request
m = re.search(r'(?m)^\s*auth_request\s+(\S+?)\s*;', sbody)
chk(bool(m), "the serving location carries an auth_request gate")
if not m:
    for st, mm in res: print(st, mm)
    sys.exit(0)
target = m.group(1)
chk(target != 'off', "auth_request is not 'off'")

# (c) THE BUG SHAPE: no $arg_sig-based self-decision anywhere in the config.
#     nginx has no key; any verdict it reaches on its own is by definition
#     "the parameter is present", which is what shipped and what was exploitable.
chk('$arg_sig' not in re.sub(r'\$arg_sig(?=[^\w])', lambda m: m.group(0),
                             re.sub(r'(?m)^\s*set\s+\$\w+\s+\$arg_sig\s*;', '', bare)),
    "no $arg_sig is consulted for a serve/deny decision (only copied for the subrequest)")
chk(not re.search(r'if\s*\(\s*\$arg_\w+', bare),
    "no `if ($arg_...)` gate — presence of a parameter is not authorisation")

# (d) the auth_request target resolves to a location that really verifies
tl = [(h, b) for h, b in locs
      if h.split()[-1] == target or h.split()[-1].rstrip('/') == target.rstrip('/')]
chk(len(tl) == 1, "auth_request target %s resolves to exactly one location (found %d)"
    % (target, len(tl)))
if len(tl) != 1:
    for st, mm in res: print(st, mm)
    sys.exit(0)
thdr, tbody = tl[0]
chk(re.search(r'(?m)^\s*internal\s*;', tbody) is not None,
    "the auth_request target is `internal` (not probeable from outside)")
pp = re.search(r'(?m)^\s*proxy_pass\s+([^;]+);', tbody)
chk(bool(pp), "the auth_request target proxies somewhere")
if pp:
    url = pp.group(1)
    chk('/bff/tube/media/verify' in url,
        "it proxies to the real verifier /bff/tube/media/verify (not some other path)")
    # (e) every field the MAC is minted over must reach the verifier, or it
    #     fail-closes on a blank param and NOTHING is ever servable — a fix that
    #     "passes" by breaking the feature.
    for f in ('path', 'sig', 'exp', 'sub', 'domain'):
        chk(re.search(r'[?&]%s=\$' % f, url) is not None,
            "the subrequest forwards the signed field `%s`" % f)

# (f) the subrequest-variable pitfall. auth_request creates the subrequest with an
#     EMPTY argument string, so $arg_* read for the first time inside the target
#     yields "" and the verifier fail-closes on every request. The parent must copy
#     them into plain variables during ITS rewrite phase.
if pp:
    for v in re.findall(r'[?&](?:path|sig|exp|sub|domain)=\$(\w+)', pp.group(1)):
        if v.startswith('arg_'):
            chk(False, "subrequest reads $%s directly — auth_request subrequests have "
                       "EMPTY args, so this is always blank" % v)
        else:
            chk(re.search(r'(?m)^\s*set\s+\$%s\s+\$\w+\s*;' % re.escape(v), sbody) is not None
                or v == 'media_path'
                or re.search(r'\(\?<%s>' % re.escape(v), shdr) is not None,
                "$%s is resolved in the PARENT request (set/named capture), not the subrequest" % v)

for st, mm in res:
    print(st, mm)
PY
while read -r st msg; do
  [ -z "${st}" ] && continue
  if [ "${st}" = "PASS" ]; then ok "${msg}"; else bad "${msg}"; fi
done <"${STATIC_OUT}"

# ── the sidecar must not hold the HMAC key ────────────────────────────────────
echo "-- 2) the sidecar holds no key and makes no decision of its own --"
python3 - "${DEPLOY}" <<'PY' && ok "tube-media container has no TUBE_MEDIA_KEY in its env" || echo "  FAIL tube-media container was handed the HMAC key"
import sys, yaml
for d in yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")):
    if d and d.get("kind") == "Deployment":
        for c in d["spec"]["template"]["spec"]["containers"]:
            if c["name"] == "tube-media":
                names = [e["name"] for e in c.get("env", [])]
                sys.exit(1 if "TUBE_MEDIA_KEY" in names else 0)
sys.exit(1)
PY
grep -c 'FAIL tube-media container was handed' /dev/null >/dev/null 2>&1 || true

# ── 3) COMPOSE-LANE DRIFT ─────────────────────────────────────────────────────
# The compose lane must not grow a SECOND, weaker copy of this gate. Today it ships
# no tube-media service at all (a documented limitation) — that is fine. What is not
# fine is a tube-media there whose nginx config re-introduces the $arg_sig stub.
echo "-- 3) compose lane carries no weaker second copy of the gate --"
if [ -f "${COMPOSE}" ]; then
  if grep -qE '^\s{2}tube-media:' "${COMPOSE}"; then
    if grep -q 'arg_sig' "${COMPOSE}"; then
      bad "compose lane defines tube-media AND gates on \$arg_sig — the stub drifted back in"
    else
      ok "compose lane defines tube-media without an \$arg_sig stub gate"
    fi
  else
    grep -q 'arg_sig' "${COMPOSE}" \
      && bad "compose lane has no tube-media service but mentions \$arg_sig" \
      || ok "compose lane ships no tube-media service (documented limitation), no stub gate to drift"
  fi
else
  bad "compose.local.yaml missing"
fi

# ── 4) BEHAVIOURAL: run the real config under real nginx ──────────────────────
echo "-- 4) behavioural: real nginx on the real config, stub verifier for the BFF --"
NGINX_IMG=""
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  # LOCAL images only — never pull. A pull here would make the suite depend on the
  # network and on Docker Hub.
  NGINX_IMG="$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
               | grep -E '^(docker\.io/)?(library/)?nginx:' | head -n1)"
fi
if [ -z "${NGINX_IMG}" ]; then
  skip "no docker + local nginx image — the behavioural leg did NOT run."
  skip "  Legs 1-3 still assert the delegation chain statically, but the status codes"
  skip "  (?sig=x -> 403, valid tuple -> 200) were NOT measured in this environment."
else
  CD="${WORK}/conf.d"; mkdir -p "${CD}"
  cp "${WORK}/default.conf" "${CD}/default.conf"
  # Stub standing in for tube-bff-api's verifier: allows ONLY the exact tuple, so a
  # wrong OR MISSING field denies. It deliberately has no HMAC — the point is what
  # nginx delegates and forwards, not how the BFF computes its answer.
  cat >"${CD}/zz-stub-verifier.conf" <<'STUB'
server {
  listen 127.0.0.1:8080;
  server_name _;
  location = /bff/tube/media/verify {
    set $v "${arg_path}|${arg_sig}|${arg_exp}|${arg_sub}|${arg_domain}";
    if ($v != "/acme/alice/v.mp4|GOODSIG|99999999999999|alice|acme") { return 403; }
    return 200 "";
  }
  location / { return 403; }
}
STUB
  cat >"${WORK}/probe.sh" <<'PROBE'
set -u
mkdir -p /var/tube-content/acme/alice
echo "SECRET-BYTES" > /var/tube-content/acme/alice/v.mp4
nginx -g 'daemon on;' 2>/dev/null
i=0; while [ $i -lt 50 ]; do wget -q -O /dev/null http://127.0.0.1:8081/ 2>/dev/null; [ $? -ne 4 ] && break; i=$((i+1)); done
q() {
  rm -f /tmp/hdr /tmp/body
  wget -q -S -O /tmp/body "$1" 2>/tmp/hdr
  code="$(awk '/^ *HTTP\//{c=$2} END{print c+0}' /tmp/hdr)"
  body="$(tr -d '\n' </tmp/body 2>/dev/null)"
  echo "$2 $code $body"
}
B='http://127.0.0.1:8081/tube/content/acme/alice/v.mp4'
G='sig=GOODSIG&exp=99999999999999&sub=alice&domain=acme'
q "$B"                                                   no-query
q "$B?sig="                                              empty-sig
q "$B?sig=x"                                             nonempty-invalid-sig
q "$B?sig=x&exp=99999999999999&sub=alice&domain=acme"    invalid-sig-full-tuple
q "$B?$G"                                                valid-tuple
q "$B?sig=GOODSIG&exp=1&sub=alice&domain=acme"           good-sig-rewritten-exp
q "$B?sig=GOODSIG&exp=99999999999999&sub=mallory&domain=acme" good-sig-other-user
q "http://127.0.0.1:8081/__tube_media_verify?$G"         direct-internal-probe
PROBE
  RES="${WORK}/probe.out"
  if docker run --rm --network none \
        -v "${CD}":/etc/nginx/conf.d:ro \
        -v "${WORK}/probe.sh":/probe.sh:ro \
        "${NGINX_IMG}" sh /probe.sh >"${RES}" 2>/dev/null; then
    :
  fi
  got(){ awk -v k="$1" '$1==k{print $2}' "${RES}"; }
  body(){ awk -v k="$1" '$1==k{print $3}' "${RES}"; }
  if [ ! -s "${RES}" ]; then
    bad "behavioural probe produced no output (nginx did not come up on the shipped config)"
  else
    ok "real nginx ${NGINX_IMG} accepted the shipped config and served the probe"
    # THE DEFECT. A non-empty but invalid signature must NOT get the bytes.
    [ "$(got nonempty-invalid-sig)" = "403" ] \
      && ok "?sig=x (non-empty, INVALID) -> 403 — the exploit is closed" \
      || bad "?sig=x (non-empty, INVALID) -> $(got nonempty-invalid-sig) — ANY value still serves the bytes"
    [ "$(body nonempty-invalid-sig)" != "SECRET-BYTES" ] \
      && ok "?sig=x returns no content bytes" \
      || bad "?sig=x returned the content"
    [ "$(got invalid-sig-full-tuple)" = "403" ] \
      && ok "a forged sig with an otherwise well-formed tuple -> 403" \
      || bad "forged sig with a well-formed tuple -> $(got invalid-sig-full-tuple)"
    [ "$(got no-query)" = "403" ]   && ok "no query string -> 403"   || bad "no query string -> $(got no-query)"
    [ "$(got empty-sig)" = "403" ]  && ok "?sig= (empty) -> 403"     || bad "?sig= -> $(got empty-sig)"
    # ...and the gate must not be a brick: the genuine tuple still streams.
    [ "$(got valid-tuple)" = "200" ] \
      && ok "the verifier-approved tuple -> 200 (the gate is not a brick)" \
      || bad "the verifier-approved tuple -> $(got valid-tuple) — this fix broke playback"
    [ "$(body valid-tuple)" = "SECRET-BYTES" ] \
      && ok "the approved request receives the content bytes" \
      || bad "the approved request got no content"
    # exp lives INSIDE the signed tuple, so rewriting it fails the MAC, not a
    # separate expiry branch. Same for sub. Both must deny.
    [ "$(got good-sig-rewritten-exp)" = "403" ] \
      && ok "rewriting exp under a good sig -> 403 (exp is inside the signed tuple)" \
      || bad "rewriting exp -> $(got good-sig-rewritten-exp)"
    [ "$(got good-sig-other-user)" = "403" ] \
      && ok "replaying a good sig under another sub -> 403" \
      || bad "cross-user replay -> $(got good-sig-other-user)"
    [ "$(got direct-internal-probe)" = "404" ] \
      && ok "the auth_request target is not reachable from outside (404)" \
      || bad "the auth_request target answered an external probe with $(got direct-internal-probe)"
  fi
fi

echo "── PASS=${P} FAIL=${F} SKIP=${S} ──"
[ "${F}" -eq 0 ] || exit 1
