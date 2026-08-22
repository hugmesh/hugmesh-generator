#!/usr/bin/env bash
# test-no-store-posture.sh — static regression gate for the compose lane's
# STALE-AFTER-LOGOUT header posture (wave-5 fix of the 2026-08-19 operator
# report "need to clear cache every time after log out").
#
# WHY THIS GATE EXISTS. The browser HTTP cache is keyed by URL alone, is blind to
# the session cookie, and is NOT emptied by sign-out. Any /bff/** response that a
# BFF lets a browser store is therefore replayable to the NEXT user of the same
# machine after logout — which is exactly what happened: user-bff's owner-scoped
# avatar/sticker byte serves sent `private, max-age=300` on user-independent URLs
# and the previous user's media survived sign-out until the cache was cleared by
# hand. The fix landed as UNCONDITIONAL CODE in two upstream repos:
#   • hugmesh-gateway#11    — BffJsonNoStoreWebFilter: a commit-time hook that
#     forces the Spring-Security cache-bust trio (`no-cache, no-store, max-age=0,
#     must-revalidate` + Pragma + Expires) on every /bff/** JSON response, even
#     when the upstream BFF set a weaker policy of its own.
#   • hugmesh-user-bff-api#8 — the two offending byte serves (ProfileController
#     avatar, StickerController sticker) now send CacheControl.noStore().
# Neither fix has an env knob, so nothing in compose.local.yaml can dark them
# TODAY — but this repo still owns every layer that could quietly regress the
# posture, and no test pinned any of them. This gate pins each one statically:
#
# THE REGRESSION SURFACES THIS REPO OWNS
#   (front door)  tests/stack/tls-front/*.conf terminates HTTPS ahead of the
#     fe-gateway and proxies byte-transparently. One `proxy_hide_header
#     Cache-Control` (the HSTS strip next door is exactly that shape), one
#     `add_header Cache-Control`, one `expires`, or any `proxy_cache*` /
#     `proxy_store` and the door strips or overrides the trio the gateway just
#     forced — or starts serving one user's response to another itself.
#   (compose env) the gateway/user-bff fixes are knob-less today. The day either
#     repo grows a cache knob, a `SOMETHING_CACHE_*: "..."` line in
#     compose.local.yaml is how the posture goes dark on the local mesh with
#     every unit test in both repos still green (the POISONER-lane inert-toggle
#     class). A name-pattern tripwire makes that a conscious edit HERE.
#   (build-time patcher) scripts/patch-stack-src.sh rewrites the cloned sources
#     immediately before `docker compose build`. A patch that touches the filter
#     or the trio is invisible to both repos' own test suites.
#   (the built sources) the stack builds from ${STACK_SRC}/<repo> clones, on
#     whatever branch scripts/clone-all-repos.sh checked out (GIT_REF). A clone
#     from a ref that predates the fixes rebuilds the bug with this repo
#     byte-identical — so when a clone tree is PRESENT, pin the code in it.
#
# ASSERTS
#   (1) FRONT DOOR CACHE-TRANSPARENCY, every tls-front/*.conf, non-comment lines
#       only: no proxy_hide_header / add_header of Cache-Control|Pragma|Expires
#       (the ONLY hide the door makes is the deliberate per-host HSTS strip —
#       see the comment block in default.conf), no `expires` directive, no
#       proxy_cache* / proxy_store. Non-vacuity: discovery must find
#       default.conf, and every conf must really be a proxy front (>=1
#       non-comment proxy_pass) — a gate greping the wrong file passes nothing.
#   (2) COMPOSE CACHE-KNOB TRIPWIRE: the services that OWN the posture — every
#       gateway service (re-derived: build context basename hugmesh-gateway or a
#       *-gateway service name) and every user-bff service (context basename
#       hugmesh-user-bff-api) — set NO env var whose NAME matches
#       CACHE|NO(_)STORE, case-insensitive. Both consumer sets are re-derived
#       from compose.local.yaml itself and must include the known services, so
#       the tripwire cannot go vacuous by a rename (the (6b) lesson from
#       test-gateway-mfa-env.sh). Tripping this is not forbidden forever: it
#       means the knob's author must extend THIS gate with the deliberate
#       posture (the way the MFA trio is pinned) instead of shipping a dark or
#       weak default.
#   (3) PATCHER TRIPWIRE: scripts/patch-stack-src.sh carries no non-comment
#       reference to NoStore / no-store / Cache-Control — a build-time rewrite
#       of the posture must be made HERE, visibly, or not at all.
#   (4) SOURCE PINS, for each of ${STACK_SRC:-<repo>/.stack-src}/hugmesh-gateway
#       and .../hugmesh-user-bff-api that is PRESENT:
#         gateway  — filter/BffJsonNoStoreWebFilter.java exists, is a live
#                    @Component, still forces the exact Spring-Security trio,
#                    and still keys on the "/bff/" prefix;
#         user-bff — ProfileController.java and StickerController.java still
#                    serve their owner-scoped bytes with CacheControl.noStore().
#       An absent tree is a loud SKIP (the CI lint image has no clones);
#       REQUIRE_STACK_SRC=1 turns each SKIP into a FAIL for machines that just
#       ran scripts/clone-all-repos.sh (e.g. right before an image build).
#   (5) NEGATIVE CONTROLS on staged copies (the repo tree is NEVER mutated), one
#       per assertion family: a conf with `proxy_hide_header Cache-Control`,
#       with `add_header Cache-Control "public, max-age=300"`, with
#       `expires 5m`, and with `proxy_cache`; a compose file whose fe-gateway
#       grows a BFF_RESPONSE_CACHE_SECONDS env; a patcher that seds the trio; a
#       synthetic gateway tree with the trio weakened to max-age=300 and one
#       with the filter file deleted; a synthetic user-bff tree with one
#       noStore() dropped. Each mutator PROVES IT LANDED (exits non-zero when
#       its target text is absent) — a silently no-op'd mutator turns its
#       control into a fake pass. The synthetic source trees also serve as the
#       POSITIVE control for (4)'s predicates, so those are exercised on every
#       run even where no real clone tree exists.
#
# THE TALLY IS GUARDED: tools are preflighted (this runs under `set -uo
# pipefail` WITHOUT `-e`, so a missing binary would distort the count, not stop
# it), and MIN_CHECKS pins how many assertions must have run.
#
# Cheap: bash + python3 + PyYAML + coreutils. No docker, no network, no cluster.
set -uo pipefail

_self="${BASH_SOURCE[0]}"; _selfdir="${_self%/*}"
[ "${_selfdir}" != "${_self}" ] || _selfdir="."
HERE="$(cd "${_selfdir}" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
COMPOSE="${HERE}/compose.local.yaml"
TLS_FRONT_DIR="${HERE}/tls-front"
PATCHER="${REPO}/scripts/patch-stack-src.sh"
# Same default the compose file itself carries (${STACK_SRC:-../../.stack-src},
# relative to tests/stack) — i.e. .stack-src at the repo root.
STACK_SRC="${STACK_SRC:-${REPO}/.stack-src}"
GW_FILTER_REL="src/main/java/net/hugmesh/gateway/filter/BffJsonNoStoreWebFilter.java"
UBFF_SRC_REL="src/main/java/net/hugmesh/userbff"
# The exact Spring-Security trio the gateway filter forces. Byte-identical to
# CacheControlServerHttpHeadersWriter's, which is the point: a hardened response
# is indistinguishable from the platform default.
TRIO='no-cache, no-store, max-age=0, must-revalidate'
# The compose services that OWN the posture (assertion (2) re-derives both sets
# from the compose file and fails if these are not contained in what it finds).
KNOWN_GW=(hugmesh-pki-gateway hugmesh-be-gateway hugmesh-fe-gateway)
KNOWN_UBFF=(hugmesh-user-bff-api)

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

# ── preflight ─────────────────────────────────────────────────────────────────
command -v python3 >/dev/null 2>&1 || { echo "  FAIL python3 missing"; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "  FAIL PyYAML missing (pip install pyyaml)"; exit 2; }
missing=""
for t in grep sed find sort tr wc mktemp cp rm mkdir; do
  command -v "${t}" >/dev/null 2>&1 || missing="${missing} ${t}"
done
[ -z "${missing}" ] || {
  echo "  FAIL required tool(s) not on PATH:${missing} — running without them would"
  echo "       distort the tally (this script deliberately does not use set -e)"; exit 2; }
for f in "${COMPOSE}" "${TLS_FRONT_DIR}/default.conf" "${PATCHER}"; do
  [ -f "${f}" ] || { echo "  FAIL missing input ${f}"; exit 2; }
done
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}" 2>/dev/null' EXIT

echo "== stale-after-logout header posture: front door + compose + source pins =="

# ── shared predicates (used by the positive assertions AND the controls) ──────
# Violating directives in one nginx conf, non-comment lines only. Matches:
#   proxy_hide_header / add_header of Cache-Control | Pragma | Expires
#   the `expires` directive
#   anything proxy_cache* (proxy_cache, _path, _valid, _bypass, ...) or proxy_store
# and deliberately does NOT match the door's one legitimate hide
# (proxy_hide_header Strict-Transport-Security).
conf_cache_violations() { # <conf> -> one matched line per violation
  grep -viE '^[[:space:]]*#' "$1" \
    | grep -iE '(proxy_hide_header|add_header)[[:space:]]+"?(cache-control|pragma|expires)([^a-z-]|$)|^[[:space:]]*expires([[:space:]]|;)|proxy_cache|proxy_store'
}
conf_is_proxy_front() { # <conf> — non-vacuity: the file really proxies
  grep -viE '^[[:space:]]*#' "$1" | grep -E '^[[:space:]]*proxy_pass[[:space:]]' >/dev/null
}
# Evidence for when the line above goes red. Issue #151 burned a day because a
# staged-conf FAIL carried no way to tell "the write was truncated" from "the
# pipeline reported a failure it did not have": the direct, pipeline-free hit
# count separates them on sight, and the per-stage statuses name the stage.
conf_diag() { # <conf>
  local n hits st
  n="$(wc -l < "$1" 2>/dev/null)"
  hits="$(grep -c '^[[:space:]]*proxy_pass[[:space:]]' "$1" 2>/dev/null)"
  grep -viE '^[[:space:]]*#' "$1" | grep -E '^[[:space:]]*proxy_pass[[:space:]]' >/dev/null
  st="${PIPESTATUS[*]}"
  echo "         [diag] $1: ${n:-?} line(s); proxy_pass hits read WITHOUT a pipeline:" \
       "${hits:-?}; pipeline stage statuses: ${st}"
}
# Compose audit: TSV of GW/UBFF membership rows and HIT rows for env names
# matching the cache tripwire, over an arbitrary compose file.
compose_cache_audit() { # <compose-file> -> TSV (GW\tname | UBFF\tname | HIT\tsvc\tENV)
  python3 - "$1" <<'PY'
import re, sys, yaml
doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
svcs = doc.get("services") or {}
gw, ubff = set(), set()
for name, s in sorted(svcs.items()):
    s = s or {}
    b = s.get("build")
    ctx = (b.get("context") if isinstance(b, dict) else b) or ""
    base = str(ctx).rstrip("/").rsplit("/", 1)[-1]
    if base == "hugmesh-gateway" or name.endswith("-gateway"):
        gw.add(name)
    if base == "hugmesh-user-bff-api":
        ubff.add(name)
pat = re.compile(r"CACHE|NO_?STORE", re.I)
for name in sorted(gw | ubff):
    env = (svcs.get(name) or {}).get("environment") or {}
    keys = [str(e).split("=", 1)[0] for e in env] if isinstance(env, list) else list(env)
    for k in sorted(keys):
        if pat.search(k):
            print("HIT\t%s\t%s" % (name, k))
for name in sorted(gw):
    print("GW\t%s" % name)
for name in sorted(ubff):
    print("UBFF\t%s" % name)
PY
}
audit_hits() { grep -E '^HIT' "$1" || true; }
audit_set() { # <tsv> <GW|UBFF> -> space-joined names
  grep -E "^$2	" "$1" | cut -f2 | sort -u | tr '\n' ' ' | sed 's/ $//'
}
contains_all() { # <haystack (space-joined)> <needle>...
  local hay=" $1 "; shift
  local n; for n in "$@"; do case "${hay}" in *" ${n} "*) ;; *) return 1;; esac; done
}
patcher_posture_refs() { # <patch-script> -> non-comment lines touching the posture
  grep -viE '^[[:space:]]*#' "$1" | grep -iE 'NoStore|no-store|Cache-Control'
}
gateway_src_problems() { # <gateway-src-dir> -> one line per problem
  local f="$1/${GW_FILTER_REL}"
  if [ ! -f "${f}" ]; then
    echo "MISSING ${GW_FILTER_REL} — the /bff JSON no-store filter is gone from the built source"
    return
  fi
  grep -qF "${TRIO}" "${f}" \
    || echo "the forced Cache-Control trio is no longer '${TRIO}' — weakened or renamed"
  grep -qF '"/bff/"' "${f}" \
    || echo 'the "/bff/" prefix key is gone — the filter no longer scopes the BFF namespace'
  grep -q '@Component' "${f}" \
    || echo "not a live @Component — the filter exists but Spring never registers it"
}
userbff_src_problems() { # <user-bff-src-dir>
  local rel
  for rel in profile/ProfileController.java character/StickerController.java; do
    local f="$1/${UBFF_SRC_REL}/${rel}"
    if [ ! -f "${f}" ]; then
      echo "MISSING ${rel} — if the controller moved, update this pin to its new home"
    elif ! grep -q 'CacheControl\.noStore()' "${f}"; then
      echo "${rel} no longer serves its owner-scoped bytes with CacheControl.noStore()"
    fi
  done
}

# ── 1) the HTTPS front door stays cache-transparent ───────────────────────────
echo "-- 1) tls-front: the door neither strips, overrides, nor caches --"
mapfile -t CONFS < <(find "${TLS_FRONT_DIR}" -maxdepth 1 -type f -name '*.conf' | sort)
case " ${CONFS[*]} " in
  *"/default.conf "*) ok "(1) conf discovery found ${#CONFS[@]} file(s) incl. default.conf" ;;
  *) bad "(1) conf discovery under tls-front/ did not find default.conf — the door check is vacuous" ;;
esac
for c in "${CONFS[@]}"; do
  conf_is_proxy_front "${c}" \
    && ok "(1) ${c##*/}: really a proxy front (has a live proxy_pass)" \
    || bad "(1) ${c##*/}: no non-comment proxy_pass — is this still the front door? The cache pins below would be checking a dead file"
  v="$(conf_cache_violations "${c}")"
  [ -z "${v}" ] \
    && ok "(1) ${c##*/}: cache-transparent (no cache hide/add/expires/proxy_cache directive)" \
    || bad "(1) ${c##*/}: CACHE DIRECTIVE AT THE DOOR: $(printf '%s' "${v}" | tr '\n' ';' | cut -c1-200) — the door must pass the gateway's no-store trio through untouched (only the HSTS hide is deliberate)"
done

# ── 2) compose: no cache knob on the services that own the posture ───────────
echo "-- 2) compose.local.yaml: cache-knob tripwire on gateway + user-bff --"
if compose_cache_audit "${COMPOSE}" > "${WORK}/audit.tsv" 2>"${WORK}/audit.err"; then
  ok "(2) compose parsed (anchors + merge keys resolved)"
else
  bad "(2) compose audit FAILED: $(tr -d '\n' <"${WORK}/audit.err" | cut -c1-300)"
fi
gw_got="$(audit_set "${WORK}/audit.tsv" GW)"
ubff_got="$(audit_set "${WORK}/audit.tsv" UBFF)"
contains_all "${gw_got}" "${KNOWN_GW[@]}" \
  && ok "(2) gateway consumers re-derived: ${gw_got}" \
  || bad "(2) gateway discovery lost a known service (got '${gw_got}', need at least: ${KNOWN_GW[*]}) — the tripwire would not be watching the real gateways"
contains_all "${ubff_got}" "${KNOWN_UBFF[@]}" \
  && ok "(2) user-bff consumer re-derived: ${ubff_got}" \
  || bad "(2) user-bff discovery lost '${KNOWN_UBFF[*]}' (got '${ubff_got}') — the tripwire would not be watching the identity-media owner"
hits="$(audit_hits "${WORK}/audit.tsv")"
[ -z "${hits}" ] \
  && ok "(2) no CACHE/NO_STORE-named env var on any gateway or user-bff service (the wave-5 fixes are knob-less; nothing here can dark them)" \
  || bad "(2) CACHE KNOB APPEARED: $(printf '%s' "${hits}" | tr '\n\t' ' :' | cut -c1-200) — a cache knob on a posture-owning service must be pinned DELIBERATELY: extend this gate with the knob's required value (the way test-gateway-mfa-env.sh pins the MFA trio), do not just delete this assertion"

# ── 3) the build-time patcher keeps its hands off the posture ─────────────────
echo "-- 3) scripts/patch-stack-src.sh: no posture rewrite at build time --"
prefs="$(patcher_posture_refs "${PATCHER}")"
[ -z "${prefs}" ] \
  && ok "(3) patch-stack-src.sh does not touch NoStore/no-store/Cache-Control" \
  || bad "(3) the stack-src patcher REWRITES the cache posture: $(printf '%s' "${prefs}" | tr '\n' ';' | cut -c1-200) — a build-time patch is invisible to both repos' test suites; make the change upstream or pin it here deliberately"

# ── 4) source pins, where the built tree exists ───────────────────────────────
echo "-- 4) built sources under ${STACK_SRC} (SKIP when absent; REQUIRE_STACK_SRC=1 to force) --"
src_pin() { # <label> <dir> <problems-fn>
  local label="$1" dir="$2" fn="$3" probs
  if [ -d "${dir}" ]; then
    probs="$("${fn}" "${dir}")"
    [ -z "${probs}" ] \
      && ok "(4) ${label}: the built source still carries the no-store fix" \
      || bad "(4) ${label}: $(printf '%s' "${probs}" | tr '\n' ';') — the compose lane would REBUILD the stale-after-logout bug (cloned ref predates the fix, or it was patched out)"
  elif [ "${REQUIRE_STACK_SRC:-0}" = "1" ]; then
    bad "(4) ${label}: ${dir} ABSENT with REQUIRE_STACK_SRC=1 — this run declared the source pin load-bearing (run scripts/clone-all-repos.sh first)"
  else
    echo "  SKIP (4) ${label}: ${dir} not present — the source pin only runs where the"
    echo "        clone tree exists (set REQUIRE_STACK_SRC=1 after clone-all-repos.sh"
    echo "        to make this a FAIL instead)."
  fi
}
src_pin "hugmesh-gateway"      "${STACK_SRC}/hugmesh-gateway"      gateway_src_problems
src_pin "hugmesh-user-bff-api" "${STACK_SRC}/hugmesh-user-bff-api" userbff_src_problems

# ── 5) negative controls (staged copies; the repo tree is never mutated) ──────
echo "-- 5) negative controls: every assertion must bite --"
mut_ok() { # <rc> <label>
  [ "$1" -eq 0 ] && return 0
  bad "($2) MUTATOR DID NOT LAND (target text absent) — control NOT exercised, so the assertion it guards is unproven"
  return 1
}
# The insertion anchor every conf mutant uses. Server-block scope, present today;
# the mutators fail loudly if it ever moves.
CONF_ANCHOR='    client_max_body_size 100m;'

stage_conf_with() { # <name> <directive> -> echoes staged conf path, rc from mutator
  local d="${WORK}/conf-$1"; mkdir -p "${d}"
  cp "${TLS_FRONT_DIR}/default.conf" "${d}/default.conf"
  python3 - "${d}/default.conf" "${CONF_ANCHOR}" "$2" <<'PY'
import sys
p, anchor, directive = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p, encoding="utf-8").read()
if anchor + "\n" not in s:
    raise SystemExit("conf mutator: anchor line not found: %r" % anchor)
open(p, "w", encoding="utf-8").write(
    s.replace(anchor + "\n", anchor + "\n    " + directive + "\n", 1))
PY
  local rc=$?
  echo "${d}/default.conf"
  return "${rc}"
}
for ctl in \
  '5a|proxy_hide_header Cache-Control;|hide of Cache-Control' \
  '5b|add_header Cache-Control "public, max-age=300";|added weak Cache-Control' \
  '5c|expires 5m;|expires directive' \
  '5d|proxy_cache STATIC;|proxy_cache at the door' ; do
  IFS='|' read -r tag directive what <<< "${ctl}"
  mconf="$(stage_conf_with "${tag}" "${directive}")"; MRC=$?
  if mut_ok "${MRC}" "${tag}"; then
    if [ -n "$(conf_cache_violations "${mconf}")" ]; then
      ok "(${tag}) conf check bites: ${what} FAILS it"
    else
      bad "(${tag}) CONF CHECK VACUOUS: it passed a conf carrying '${directive}'"
    fi
    # ...and the mutant must still look like the front door, so the violation
    # (not a broken stage) is what the predicate saw.
    conf_is_proxy_front "${mconf}" \
      && ok "(${tag}) staged conf still a proxy front — the mutation is isolated" \
      || { bad "(${tag}) staged conf lost its proxy_pass — control did not isolate the cache directive"
           conf_diag "${mconf}"; }
  fi
done

# 5e) a cache knob appearing on the fe-gateway service must trip (2)
python3 - "${COMPOSE}" "${WORK}/compose-knob.yaml" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src, encoding="utf-8").read()
anchor = "  hugmesh-fe-gateway:\n"
i = s.find(anchor)
if i < 0:
    raise SystemExit("compose mutator: no hugmesh-fe-gateway service block")
j = s.find("    environment:\n", i)
if j < 0:
    raise SystemExit("compose mutator: fe-gateway has no environment: block")
k = j + len("    environment:\n")
open(dst, "w", encoding="utf-8").write(
    s[:k] + '      BFF_RESPONSE_CACHE_SECONDS: "300"\n' + s[k:])
PY
MRC=$?
if mut_ok "${MRC}" 5e; then
  if compose_cache_audit "${WORK}/compose-knob.yaml" > "${WORK}/audit-knob.tsv" 2>/dev/null; then
    knob_hits="$(audit_hits "${WORK}/audit-knob.tsv")"
    printf '%s' "${knob_hits}" | grep 'BFF_RESPONSE_CACHE_SECONDS' >/dev/null \
      && ok "(5e) compose tripwire bites: a *_CACHE_* env on the fe-gateway FAILS it" \
      || bad "(5e) COMPOSE TRIPWIRE VACUOUS: BFF_RESPONSE_CACHE_SECONDS on the fe-gateway was not flagged (hits: '${knob_hits:-none}')"
    # the mutant must not have broken discovery, or the miss above means nothing
    contains_all "$(audit_set "${WORK}/audit-knob.tsv" GW)" "${KNOWN_GW[@]}" \
      || bad "(5e) staged compose lost the gateway set — control did not isolate the env knob"
  else
    bad "(5e) staged compose failed to parse (control not exercised)"
  fi
fi

# 5f) a patcher that rewrites the trio must trip (3)
cp "${PATCHER}" "${WORK}/patcher.sh"
printf '\nsed -i "s/no-store/max-age=300/" "${STACK_SRC}/hugmesh-gateway/%s"\n' "${GW_FILTER_REL}" >> "${WORK}/patcher.sh"
[ -n "$(patcher_posture_refs "${WORK}/patcher.sh")" ] \
  && ok "(5f) patcher tripwire bites: a build-time no-store rewrite FAILS it" \
  || bad "(5f) PATCHER TRIPWIRE VACUOUS: a sed over no-store in patch-stack-src.sh was not flagged"

# 5g) synthetic source trees: POSITIVE control for (4)'s predicates, then each
#     regression shape must be caught. This runs on every machine, clone or not.
GOOD_GW="${WORK}/src-good/hugmesh-gateway"
mkdir -p "${GOOD_GW}/$(dirname "${GW_FILTER_REL}")"
cat > "${GOOD_GW}/${GW_FILTER_REL}" <<EOF
@Component
public class BffJsonNoStoreWebFilter implements WebFilter, Ordered {
    private static final String BFF_PREFIX = "/bff/";
    static final String CACHE_CONTROL_VALUE = "${TRIO}";
}
EOF
[ -z "$(gateway_src_problems "${GOOD_GW}")" ] \
  && ok "(5g) gateway source pin passes a tree carrying the filter (positive control)" \
  || bad "(5g) gateway source pin FAILS a correct tree: $(gateway_src_problems "${GOOD_GW}" | tr '\n' ';') — the predicate is broken, (4) would go red on a good clone"
WEAK_GW="${WORK}/src-weak/hugmesh-gateway"
mkdir -p "${WEAK_GW}/$(dirname "${GW_FILTER_REL}")"
sed 's/no-cache, no-store, max-age=0, must-revalidate/private, max-age=300/' \
  "${GOOD_GW}/${GW_FILTER_REL}" > "${WEAK_GW}/${GW_FILTER_REL}"
grep -q 'private, max-age=300' "${WEAK_GW}/${GW_FILTER_REL}" \
  || bad "(5g) MUTATOR DID NOT LAND (trio not weakened) — control NOT exercised"
[ -n "$(gateway_src_problems "${WEAK_GW}")" ] \
  && ok "(5g) gateway source pin bites: a weakened trio FAILS it" \
  || bad "(5g) GATEWAY SOURCE PIN VACUOUS: it passed a filter forcing private, max-age=300"
GONE_GW="${WORK}/src-gone/hugmesh-gateway"
mkdir -p "${GONE_GW}/src/main/java"
[ -n "$(gateway_src_problems "${GONE_GW}")" ] \
  && ok "(5g) gateway source pin bites: a tree WITHOUT the filter FAILS it" \
  || bad "(5g) GATEWAY SOURCE PIN VACUOUS: it passed a tree with no BffJsonNoStoreWebFilter at all"

GOOD_UB="${WORK}/src-good/hugmesh-user-bff-api"
mkdir -p "${GOOD_UB}/${UBFF_SRC_REL}/profile" "${GOOD_UB}/${UBFF_SRC_REL}/character"
printf 'class ProfileController { x.cacheControl(CacheControl.noStore()); }\n' \
  > "${GOOD_UB}/${UBFF_SRC_REL}/profile/ProfileController.java"
printf 'class StickerController { x.cacheControl(CacheControl.noStore()); }\n' \
  > "${GOOD_UB}/${UBFF_SRC_REL}/character/StickerController.java"
[ -z "$(userbff_src_problems "${GOOD_UB}")" ] \
  && ok "(5g) user-bff source pin passes a tree with both noStore() serves (positive control)" \
  || bad "(5g) user-bff source pin FAILS a correct tree: $(userbff_src_problems "${GOOD_UB}" | tr '\n' ';')"
BAD_UB="${WORK}/src-bad/hugmesh-user-bff-api"
mkdir -p "${BAD_UB}/${UBFF_SRC_REL}/profile" "${BAD_UB}/${UBFF_SRC_REL}/character"
cp "${GOOD_UB}/${UBFF_SRC_REL}/character/StickerController.java" "${BAD_UB}/${UBFF_SRC_REL}/character/"
sed 's/CacheControl\.noStore()/CacheControl.maxAge(300, java.util.concurrent.TimeUnit.SECONDS)/' \
  "${GOOD_UB}/${UBFF_SRC_REL}/profile/ProfileController.java" \
  > "${BAD_UB}/${UBFF_SRC_REL}/profile/ProfileController.java"
grep -q 'maxAge(300' "${BAD_UB}/${UBFF_SRC_REL}/profile/ProfileController.java" \
  || bad "(5g) MUTATOR DID NOT LAND (noStore not replaced) — control NOT exercised"
[ -n "$(userbff_src_problems "${BAD_UB}")" ] \
  && ok "(5g) user-bff source pin bites: an avatar serve back on maxAge FAILS it" \
  || bad "(5g) USER-BFF SOURCE PIN VACUOUS: it passed a ProfileController serving max-age again"

# ── the tally itself has to be trustworthy ────────────────────────────────────
# `set -uo pipefail` WITHOUT `-e` is deliberate (one red assertion must not hide
# the rest), so a section that stops RUNNING stops being COUNTED. State the floor
# and enforce it. MIN_CHECKS is the count with NO ${STACK_SRC} clone tree present
# (the CI lint image); each present tree adds one assertion in (4), hence a floor
# and not an equality. Adding assertions? Raise it. Removing one? Lower it ON
# PURPOSE, in the same commit.
MIN_CHECKS=23
total=$(( P + F ))
if [ "${total}" -lt "${MIN_CHECKS}" ]; then
  bad "only ${total} assertions ran, but this file declares a floor of ${MIN_CHECKS} — checks stopped running rather than failing, so the count above means nothing. Find what exited early (or lower MIN_CHECKS deliberately if the removal was intended)."
fi

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
