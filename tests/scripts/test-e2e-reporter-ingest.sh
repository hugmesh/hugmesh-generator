#!/usr/bin/env bash
# =============================================================================
# test-e2e-reporter-ingest.sh — the e2e reporter's LIVE events must reach admin-bff's
# test-report ingest, and a failure to reach it must not be silent.
#
# WHAT WAS WRONG (hugmesh-generator#507, finding 25; measured 2026-11-18). The Jobs POSTed to
# `.../bff/admin/test-reports/ingest` and it could never have worked, in four ways at once:
#   1. PATH      the controller maps POST /{id}/ingest; there is no POST /ingest;
#   2. CONTRACT  the reporter sent {event:'run-begin'|...}; the endpoint takes
#                TestRunIngestRequest {kind SUITE|RUN, state, passed, failed, skipped, percent...};
#   3. AUTH      no Authorization header, on a @PreAuthorize endpoint;
#   4. TLS       admin-bff serves client-auth=need and nothing presented a certificate.
# The POST swallowed every failure, so "results silently never ingested" and nobody noticed.
#
# HOW IT TESTS. It replays the RECORDED run through the REAL reporter (the same replay
# tests/scripts/test-e2e-reporter-shape.sh uses: bare node, no stack, no browser) against
# tests/scripts/e2e-ingest-stub.mjs, a server that ENFORCES the endpoint's real contract: the
# route, a bearer, the DTO's constraints, and (when asked) a TLS listener that REQUIRES a client
# certificate. So what is asserted is what the endpoint would accept, not what the reporter
# believes it sends.
#
#   1. happy path     mTLS + a client-credentials token: every event accepted, on the right
#                     path, run id in it, bearer present, our certificate seen, nothing printed
#   2. no client cert the TLS peer refuses it, and the reporter SAYS SO (stderr), summary.json intact
#   3. no credential  401s, and the reporter says so
#   4. token expiry   the first token is rejected, the reporter mints another and succeeds
#   5. the retired SNAP_INGEST_URL alone warns and sends nothing
#   6. no run id      reported, not silently posted to a path with a hole in it
#   7. NEGATIVE CONTROLS: each of the mutations below is applied to a COPY of the reporter's
#      ingest client and must turn case 1 red.
#
# OFFLINE: bash + node (type stripping, as the reporter runs) + openssl + python3.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E="${HERE}/../e2e"
REPLAY="${HERE}/e2e-reporter-replay.mjs"
STUB="${HERE}/e2e-ingest-stub.mjs"
FIXTURE="${E2E}/reporters/fixtures/recorded-run.json"

for t in node openssl python3; do
  command -v "$t" >/dev/null 2>&1 || { echo "  FAIL ${t} is required (refusing to skip: a skipping gate never guards)"; exit 2; }
done
WORK="$(mktemp -d)"; STUB_PID=""
cleanup() { [ -n "${STUB_PID}" ] && kill "${STUB_PID}" 2>/dev/null; rm -rf "${WORK}"; }
trap cleanup EXIT

P=0; F=0
ok()  { P=$((P+1)); echo "  PASS $*"; }
bad() { F=$((F+1)); echo "  FAIL $*"; }

# one self-signed identity, used as the server certificate, the client certificate and the CA
openssl req -x509 -newkey rsa:2048 -nodes -keyout "${WORK}/key.pem" -out "${WORK}/cert.pem" -days 1 \
  -subj "/CN=ingest-test-client" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" >/dev/null 2>&1 \
  || { echo "  FAIL could not mint the test certificate"; exit 2; }

# start_stub <tag> <stub args...> : sets PORT_INGEST, PORT_TOKEN, LOG
start_stub() {
  local tag="$1"; shift
  LOG="${WORK}/${tag}.log"; : > "${LOG}"; rm -f "${WORK}/${tag}.ready"
  node "${STUB}" "${LOG}" "${WORK}/${tag}.ready" "$@" >"${WORK}/${tag}.stub.out" 2>&1 &
  STUB_PID=$!
  local i; for i in $(seq 1 50); do [ -s "${WORK}/${tag}.ready" ] && break; sleep 0.1; done
  [ -s "${WORK}/${tag}.ready" ] || { echo "  FAIL the stub did not start: $(cat "${WORK}/${tag}.stub.out")"; exit 2; }
  PORT_INGEST="$(python3 -c "import json;print(json.load(open('${WORK}/${tag}.ready'))['ingest'])")"
  PORT_TOKEN="$(python3 -c "import json;print(json.load(open('${WORK}/${tag}.ready'))['token'])")"
}
stop_stub() { [ -n "${STUB_PID}" ] && kill "${STUB_PID}" 2>/dev/null; wait "${STUB_PID}" 2>/dev/null; STUB_PID=""; }

# replay <out-dir> <reporter.ts> [VAR=value ...]  -> RC, ERR (stderr text)
replay() {
  local out="$1" reporter="$2"; shift 2
  ERR="${WORK}/replay.err"
  ( env "$@" node "${REPLAY}" "${RFIXTURE:-${FIXTURE}}" "${out}" "${reporter}" >"${WORK}/replay.out" 2>"${ERR}" ); RC=$?
}
REPORTER="${E2E}/reporters/hugmesh-reporter.ts"

# log helpers (python, so no jq dependency)
logq() { python3 - "${LOG}" "$@" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
what = sys.argv[2]
ing = [r for r in rows if r.get("t") == "ingest"]
if what == "accepted": print(sum(1 for r in ing if r.get("status") == 200))
elif what == "rejected": print(sum(1 for r in ing if r.get("status") != 200))
elif what == "total": print(len(ing))
elif what == "tokens": print(sum(1 for r in rows if r.get("t") == "token"))
elif what == "tlserr": print(sum(1 for r in rows if r.get("t") == "tls-client-error"))
elif what == "kinds": print(",".join(sorted({r["body"]["kind"] for r in ing if r.get("status") == 200 and "body" in r})))
elif what == "firstkind": print(next((r["body"]["kind"] + ":" + r["body"]["state"] for r in ing if "body" in r), ""))
elif what == "runids": print(",".join(sorted({r.get("runId", "") for r in ing})))
elif what == "peer": print(",".join(sorted({str(r.get("peerCN")) for r in ing})))
elif what == "auth": print(",".join(sorted({r.get("authorization", "") for r in ing})))
elif what == "urls": print(",".join(sorted({r.get("url", "") for r in ing})))
PY
}

BASE_TLS() { echo "SNAP_INGEST_BASE_URL=https://127.0.0.1:${PORT_INGEST}/bff/admin/test-reports"; }
CRED()     { echo "SNAP_INGEST_TOKEN_URL=http://127.0.0.1:${PORT_TOKEN}/api/login/oauth/access_token"; }

# ── the happy path, reused by the controls ──────────────────────────────────────────────
happy() { # <reporter.ts> <out-dir> -> sets RC, ERR; stub already started with --tls
  replay "$2" "$1" "$(BASE_TLS)" SNAP_RUN_ID=run-42 "$(CRED)" SNAP_INGEST_CLIENT_ID=app-test-ingest \
    SNAP_INGEST_CLIENT_SECRET=s3cret SNAP_INGEST_TLS_CERT="${WORK}/cert.pem" SNAP_INGEST_TLS_KEY="${WORK}/key.pem" \
    SNAP_INGEST_TLS_CA="${WORK}/cert.pem"
}

echo "== e2e reporter live ingest =="

echo "-- 1. happy path: mTLS + a client-credentials token --"
start_stub case1 --tls "${WORK}/cert.pem" "${WORK}/key.pem" "${WORK}/cert.pem"
happy "${REPORTER}" "${WORK}/out1"
total="$(logq total)"; acc="$(logq accepted)"
[ "${RC}" -eq 0 ] && ok "the replay ran (rc 0)" || bad "the replay crashed (rc=${RC}): $(tail -3 "${ERR}" | tr '\n' ' ')"
[ "${total}" -ge 3 ] && ok "the reporter sent ${total} live events (run-begin, tests, run-end)" || bad "too few live events reached the endpoint: ${total}"
[ "${acc}" = "${total}" ] && [ "${total}" -gt 0 ] && ok "EVERY event was accepted by the endpoint's real contract (route, bearer, DTO constraints)" \
  || bad "the endpoint rejected $(logq rejected) of ${total} events: $(grep -m2 '"status":[^2]' "${LOG}" | cut -c1-260)"
[ "$(logq kinds)" = "RUN,SUITE" ] && ok "both kinds arrive: RUN and SUITE" || bad "kinds seen: $(logq kinds)"
[ "$(logq firstkind)" = "RUN:running" ] && ok "the first event is the run starting (RUN running)" || bad "first event was $(logq firstkind)"
[ "$(logq runids)" = "run-42" ] && ok "the run id is in the path: /{id}/ingest" || bad "run ids seen: $(logq runids)"
[ "$(logq urls)" = "/bff/admin/test-reports/run-42/ingest" ] && ok "one path, the controller's mapping" || bad "paths seen: $(logq urls)"
case "$(logq auth)" in "Bearer <redacted>") ok "every event carries a bearer";; *) bad "authorization seen: $(logq auth)";; esac
[ "$(logq peer)" = "ingest-test-client" ] && ok "the TLS peer saw OUR client certificate" || bad "peer CN seen: $(logq peer)"
[ "$(logq tokens)" = "1" ] && ok "one token minted, then reused" || bad "tokens minted: $(logq tokens)"
grep -q "NOT accepted" "${ERR}" && bad "the reporter complained on a clean run" || ok "a clean run prints no ingest warning"
[ -s "${WORK}/out1/summary.json" ] && ok "summary.json is written" || bad "no summary.json"
stop_stub

echo "-- 2. no client certificate: the TLS peer refuses, and the reporter SAYS SO --"
start_stub case2 --tls "${WORK}/cert.pem" "${WORK}/key.pem" "${WORK}/cert.pem"
replay "${WORK}/out2" "${REPORTER}" "$(BASE_TLS)" SNAP_RUN_ID=run-42 "$(CRED)" SNAP_INGEST_CLIENT_ID=app-test-ingest \
  SNAP_INGEST_CLIENT_SECRET=s3cret SNAP_INGEST_TLS_CA="${WORK}/cert.pem"
[ "$(logq accepted)" = "0" ] && ok "nothing was accepted" || bad "events got through without a client certificate"
grep -q "ingest: .* live events were NOT accepted" "${ERR}" && ok "the reporter reports it on stderr (it used to be silent)" || bad "silent failure: $(tail -2 "${ERR}")"
[ -s "${WORK}/out2/summary.json" ] && ok "summary.json is still complete (the report on disk is authoritative)" || bad "no summary.json after an ingest failure"
stop_stub

echo "-- 3. no credential: 401, and the reporter says so --"
start_stub case3 --tls "${WORK}/cert.pem" "${WORK}/key.pem" "${WORK}/cert.pem"
replay "${WORK}/out3" "${REPORTER}" "$(BASE_TLS)" SNAP_RUN_ID=run-42 SNAP_INGEST_TLS_CERT="${WORK}/cert.pem" \
  SNAP_INGEST_TLS_KEY="${WORK}/key.pem" SNAP_INGEST_TLS_CA="${WORK}/cert.pem"
[ "$(logq accepted)" = "0" ] && ok "nothing was accepted without a bearer" || bad "events were accepted with no credential"
grep -q "answered 401" "${ERR}" && ok "the reporter names the 401" || bad "no 401 in the report: $(tail -2 "${ERR}")"
stop_stub

echo "-- 4. token expiry: the first token is rejected, the reporter mints another --"
start_stub case4 --tls "${WORK}/cert.pem" "${WORK}/key.pem" "${WORK}/cert.pem" --expire-first-token
happy "${REPORTER}" "${WORK}/out4"
[ "$(logq rejected)" -ge 1 ] && ok "the endpoint rejected the expired token (a 401)" || bad "the stub never rejected a token: the case proves nothing"
[ "$(logq tokens)" -ge 2 ] && ok "the reporter minted a second token" || bad "tokens minted: $(logq tokens)"
grep -q "NOT accepted" "${ERR}" && bad "the retry did not recover: $(grep 'NOT accepted' "${ERR}" | cut -c1-200)" || ok "after the refresh every later event was accepted"
stop_stub

echo "-- 5. the retired SNAP_INGEST_URL alone: a warning, and no client at all --"
# the replay harness deletes SNAP_INGEST_URL and defaults SNAP_RUN_ID, so these two go straight
# to the client (scripts/e2e-ingest-unit.mjs)
U="$(node "${HERE}/e2e-ingest-unit.mjs" legacy-url 2>/dev/null)"
python3 - "${U}" <<'PY' && ok "the retired variable warns, names its replacement, and sends nothing (no client is built)" || bad "legacy variable handling: ${U}"
import json, sys
d = json.loads(sys.argv[1])
assert d["client"] is True and len(d["warnings"]) == 1
assert "retired" in d["warnings"][0] and "SNAP_INGEST_BASE_URL" in d["warnings"][0]
PY
U="$(node "${HERE}/e2e-ingest-unit.mjs" no-env 2>/dev/null)"
python3 - "${U}" <<'PY' && ok "with nothing configured there is no client and no noise (as before)" || bad "unconfigured handling: ${U}"
import json, sys
d = json.loads(sys.argv[1]); assert d["client"] is True and d["warnings"] == []
PY

echo "-- 6. no run id: counted and said, never posted to a path with a hole in it --"
U="$(node "${HERE}/e2e-ingest-unit.mjs" no-run-id 2>/dev/null)"
python3 - "${U}" <<'PY' && ok "no request is made without a run id, and the reason is recorded" || bad "no-run-id handling: ${U}"
import json, sys
st = json.loads(sys.argv[1])["stats"]
assert st["attempted"] == 1 and st["failed"] == 1 and "SNAP_RUN_ID" in st["firstFailure"]
PY

echo "-- 6b. a TLS file that cannot be read: counted and said, never a crash of the run --"
# the client is built while Playwright builds its reporters: a throw there failed the whole run
U="$(node "${HERE}/e2e-ingest-unit.mjs" missing-tls 2>/dev/null)"
python3 - "${U}" <<'PY' && ok "a missing client certificate is recorded as the reason, and nothing throws" || bad "missing-tls handling: ${U}"
import json, sys
st = json.loads(sys.argv[1])["stats"]
assert st["attempted"] == 1 and st["failed"] == 1 and "SNAP_INGEST_TLS" in st["firstFailure"], st
PY

echo "-- 6c. a failing test whose error quotes a password: scrubbed, sent, and the run survives --"
# The reporter used to scrub the serialised JSON text: `password=\"x\"` lost its backslash, the
# text stopped being JSON, and JSON.parse threw inside onTestEnd.
python3 - "${FIXTURE}" "${WORK}/quoted.json" <<'PY' || { echo "  FAIL could not build the quoted-password fixture"; exit 2; }
import json, sys
d = json.load(open(sys.argv[1]))
n = 0
for ev in d["events"]:
    err = ((ev.get("result") or {}).get("error")) if isinstance(ev, dict) else None
    if isinstance(err, dict) and "message" in err:
        err["message"] = 'locator.fill: password="hunter2-quoted" was refused'
        n += 1
assert n > 0, "the fixture has no failed test to quote a password in"
json.dump(d, open(sys.argv[2], "w"))
PY
start_stub case6c --tls "${WORK}/cert.pem" "${WORK}/key.pem" "${WORK}/cert.pem"
RFIXTURE="${WORK}/quoted.json" happy "${REPORTER}" "${WORK}/out6c"
total="$(logq total)"; acc="$(logq accepted)"
[ "${RC}" -eq 0 ] && ok "the replay ran (rc 0)" || bad "the replay crashed (rc=${RC}): $(tail -3 "${ERR}" | tr '\n' ' ')"
[ "${total}" -ge 3 ] && [ "${acc}" = "${total}" ] && ok "every event (${total}) still reached the endpoint and was accepted" \
  || bad "accepted ${acc} of ${total} events: $(tail -3 "${ERR}" | tr '\n' ' ')"
grep -q "hunter2-quoted" "${LOG}" && bad "the quoted password reached the endpoint" || ok "the quoted password was scrubbed from what was sent"
stop_stub

# ── 7. NEGATIVE CONTROLS ────────────────────────────────────────────────────────────────
echo "-- 7. negative controls: each mutation of the ingest client must turn the happy path red --"
SRC_ING="${E2E}/reporters/ingest.ts"
mutate() { # <label> <python snippet over s> [happy|failing] -> runs a scenario on a mutated COPY, expects it RED
  local label="$1" snippet="$2" mode="${3:-happy}" c="${WORK}/ctl"
  rm -rf "${c}"; mkdir -p "${c}/reporters" "${c}/specs"
  cp "${REPORTER}" "${c}/reporters/hugmesh-reporter.ts"; cp "${E2E}/specs/report-tags.ts" "${c}/specs/report-tags.ts"
  python3 - "${SRC_ING}" "${c}/reporters/ingest.ts" "${snippet}" <<'PY' || { bad "CONTROL ${label}: the mutation anchor was not found (the control proves nothing)"; return; }
import sys
src, dst, snip = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(src, encoding="utf-8").read(); t = s
exec(snip)
if t == s: sys.exit(1)
open(dst, "w", encoding="utf-8").write(t)
PY
  start_stub ctl --tls "${WORK}/cert.pem" "${WORK}/key.pem" "${WORK}/cert.pem"
  if [ "${mode}" = failing ]; then
    # a scenario that MUST fail at the endpoint (no credential): the reporter has to SAY so
    replay "${WORK}/outctl" "${c}/reporters/hugmesh-reporter.ts" "$(BASE_TLS)" SNAP_RUN_ID=run-42 \
      SNAP_INGEST_TLS_CERT="${WORK}/cert.pem" SNAP_INGEST_TLS_KEY="${WORK}/key.pem" SNAP_INGEST_TLS_CA="${WORK}/cert.pem"
    stop_stub
    # the property under test is "a failing run SAYS SO": under the mutation the message must be GONE
    if grep -q "NOT accepted" "${ERR}"; then bad "CONTROL ${label}: SURVIVED (the failing run still announced the failure)"; else ok "CONTROL ${label}: caught (the failing run printed nothing)"; fi
    return
  fi
  if [ "${mode}" = expiry ]; then
    # the first token the stub mints is never valid: only a client that re-mints recovers
    stop_stub; start_stub ctl --tls "${WORK}/cert.pem" "${WORK}/key.pem" "${WORK}/cert.pem" --expire-first-token
    happy "${c}/reporters/hugmesh-reporter.ts" "${WORK}/outctl"
    stop_stub
    if grep -q "NOT accepted" "${ERR}"; then ok "CONTROL ${label}: caught (the run did not recover from an expired token)"; else bad "CONTROL ${label}: SURVIVED (it recovered without the retry)"; fi
    return
  fi
  happy "${c}/reporters/hugmesh-reporter.ts" "${WORK}/outctl"
  local tot acc; tot="$(logq total)"; acc="$(logq accepted)"
  stop_stub
  if [ "${tot}" -gt 0 ] && [ "${acc}" = "${tot}" ] && ! grep -q "NOT accepted" "${ERR}" && [ "${RC}" -eq 0 ]; then
    bad "CONTROL ${label}: SURVIVED (the happy path stayed green)"
  else
    ok "CONTROL ${label}: caught (accepted ${acc}/${tot}, rc ${RC})"
  fi
}
mutate "the run id is dropped from the path" \
  't = s.replace("`${this.cfg.baseUrl}/${encodeURIComponent(this.cfg.runId)}/ingest`", "`${this.cfg.baseUrl}/ingest`")'
mutate "the old event shape is sent instead of the endpoint's contract" \
  't = s.replace("const body = toIngestBody(event, payload);\n    if (!body) return;", "const body = { event, ...payload } as never;")'
mutate "no Authorization header" \
  't = s.replace("if (token) headers[\x27authorization\x27] = `Bearer ${token}`;", "")'
mutate "the client certificate is never presented" \
  't = s.replace("this.tls.cert = fs.readFileSync(cfg.tlsCert);", "").replace("this.tls.key = fs.readFileSync(cfg.tlsKey);", "")'
mutate "an expired token is not re-minted (the 401 retry is gone)" \
  't = s.replace("if (r.status === 401 && attempt === 0 && !this.cfg.staticToken) { failedToken = token; continue; }", "")' expiry
mutate "a failure is swallowed again (counted as nothing)" \
  't = s.replace("this.failed++;", "")' failing
mutate "the state mapping sends an unknown state" \
  't = s.replace("const state = status === \x27passed\x27 ? \x27passed\x27", "const state = status === \x27passed\x27 ? \x27ok\x27")'

echo
echo "${P} passed, ${F} failed"
[ "${F}" -eq 0 ] || exit 1
exit 0
