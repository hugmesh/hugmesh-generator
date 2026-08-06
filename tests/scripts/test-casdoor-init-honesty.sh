#!/usr/bin/env bash
# =============================================================================
# test-casdoor-init-honesty.sh — the Casdoor bootstrap must not be able to lie.
#
# WHY THIS EXISTS. The first time the GitOps payload was stood up on a real
# cluster, `casdoor-init` printed all thirteen of its "added app-<name>" lines
# while its admin login had FAILED. Every call went out anonymous, Casdoor logged
# "result = deny", and the database ended the run with one application. A totally
# failed run was byte-for-byte indistinguishable from a successful one — which is
# why two much worse things sat underneath it unnoticed:
#
#   * the mounted init_data.json was NEVER imported (app.conf omitted
#     `initDataFile`, and object/init_data.go's InitFromFile() returns
#     immediately when that key is empty), so no organization, no roles and no
#     service users existed on a completely fresh database; and
#   * because nothing ever applied the Vault/ESO password, the identity provider
#     kept casdoor's public default — POST /api/login with admin/123 returned
#     {"status":"ok"} on the live cluster.
#
# The mechanism behind all three: Casdoor answers denials, bad logins and
# validation errors alike with **HTTP 200** and {"status":"error","msg":…} in the
# body (routers/authz_filter.go denyRequest -> responseError). urllib raises
# nothing. A script that only watches for exceptions sees success every time.
#
# WHAT IS CHECKED, in three layers:
#
#   1. THE SOURCE CONTRACT, over EVERY Casdoor reconcile script embedded in
#      specs/cluster (discovered, not listed — a sixth Job is covered the day it
#      lands): one HTTP egress point; no path through that helper may return a
#      response whose status was not proved to be "ok" (CONTROL-FLOW analysed —
#      a helper that logs a bad status and carries on mentions every word a
#      grep would look for and enforces nothing); every write is re-read; the
#      login is verified by reading the session back; nothing is swallowed; and
#      the script can exit non-zero. Init scripts must also apply the admin
#      password through /api/set-password (update-user cannot change one) and
#      know casdoor's bootstrap default.
#   2. THE WIRING CONTRACT: initDataFile must be set, must equal the path the
#      Deployment mounts the seed at, initDataNewOnly must be true (false DELETEs
#      and re-adds every declared object on every restart, resetting role
#      membership to the seed's empty lists), and the init Job must mount the
#      same seed ConfigMap its verification pass reads.
#   2b. THE OBJECT-GRAPH CONTRACT: a seed that IS imported must be able to import
#      ITSELF. Wiring the import up is what exposed this: the very first boot that
#      really read init_data.json died on
#          panic: The organization: admin should have one application at least
#      because casdoor refuses to create a user in an organization with no
#      application (object/user.go:1000-1007, panicked at init_data.go:368) and
#      the systems seed declared six service users, twenty-seven roles and NO
#      application — the applications are created later, over the API, by the very
#      Job that cannot run until casdoor is up. A wiring-only gate cannot see that:
#      every path matched, every key was set, and the IdP still could not boot. So
#      `seed` reproduces casdoor's own preconditions statically over every seed in
#      the tree: organization viability, the owner the application count actually
#      filters on, InitFromFile()'s hardcoded kind order, and the dangling
#      role/permission members that casdoor stores without complaint.
#      Those preconditions are PINNED to the literals upstream hardcodes, not
#      derived from the seed, because two of them cannot be recovered from a
#      self-consistent file: an organization owned by anything but "admin" is
#      never found at all (GetOrganizationByUser is
#      getOrganization("admin", user.Owner), object/organization.go:305-311), and
#      the built-in organization's exemption at object/user.go:999 covers the
#      application count and nothing else — object/user.go:1010-1011 still refuses
#      every built-in user but "admin". Both panic at object/init_data.go:366-368
#      exactly like the missing application did, and both are controlled in
#      section 3 in BOTH directions, so neither rule can pass by banning the shape
#      casdoor actually accepts.
#   3. THE BEHAVIOUR, by RUNNING the real scripts against a stub Casdoor
#      (tests/scripts/casdoor_stub.py) that reproduces the live failure shapes:
#      a denied session, denied writes, writes that answer {"status":"ok"} while
#      storing nothing, and a write whose VERIFICATION READ is denied. Each must
#      exit non-zero and must NOT announce anything as changed. This runs over
#      EVERY discovered script, INCLUDING the three derived-role sync Jobs —
#      whose write (update-role on an authorization source) is the one that most
#      needs it. Those Jobs only write when they find roles to reconcile, so the
#      stub is seeded from their OWN role names first; a scenario that never
#      reached the write would satisfy every "announced nothing" assertion while
#      proving nothing, so the journal is asserted to contain the write. A
#      happy-path run must still succeed, announce, and be idempotent on a second
#      pass — and the announcement detector itself is asserted to FIRE there, so
#      "announced nothing" can never be a property of a blind detector.
#      The credential legs get the same treatment TWICE OVER, because there are
#      two accounts provisioned from Vault and only one of them is the session:
#      the admin is proved by re-login, and every OTHER account (today, the
#      superadmin) is proved by set-password's own refusal to re-set a password
#      that already matches (object/check_password_complexity.go:104-124), which
#      is the only read-back a password has — /api/get-user masks it as "***".
#      Scenario (4g) starts from a cluster holding the PREVIOUS password, so a
#      rotation that never left Vault is a failure rather than an invisible
#      no-op; (4h) makes the write vanish and requires the run to fail rather
#      than announce it. Finally a secret sweep: no password — neither account's
#      — may reach stdout or stderr on ANY path.
#
# Every layer-1/2 check is also re-run against a deliberately corrupted staged
# copy, so a check that silently stopped biting is reported, not passed over —
# and layer 3 gets the same treatment: the staged sync script is regressed to the
# error-swallowing readback this gate was written to make un-reshippable, and the
# harness asserts the scenario catches it.
#
# No cluster, no kubectl, no docker, no network egress: the stub binds 127.0.0.1
# on an ephemeral port. PyYAML + python3 stdlib only.
# =============================================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLUSTER="${REPO}/specs/cluster"
CONTRACT="${REPO}/tests/scripts/casdoor_reconcile_contract.py"
STUB="${REPO}/tests/scripts/casdoor_stub.py"

command -v python3 >/dev/null 2>&1 || { echo "  FAIL python3 is required"; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "  FAIL PyYAML is required (pip install pyyaml)"; exit 2; }
for f in "${CONTRACT}" "${STUB}"; do
    [ -f "${f}" ] || { echo "  FAIL missing: ${f}"; exit 2; }
done

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

WORK="$(mktemp -d)"
STUB_PID=""
cleanup() {
    [ -n "${STUB_PID}" ] && kill "${STUB_PID}" 2>/dev/null
    rm -rf "${WORK}"
}
trap cleanup EXIT

# The fixture admin password. Deliberately unlike casdoor's default so the
# takeover path is exercised, and deliberately distinctive so the secret sweep
# below can look for it verbatim.
PROVISIONED_PW="fixture-provisioned-admin-pw-8f13"
CASDOOR_DEFAULT_PW="123"

# ── stub lifecycle ───────────────────────────────────────────────────────────
stub_up() { # <mode> <initial-admin-password> [store-seed.json]
    stub_down
    rm -f "${WORK}/port" "${WORK}/journal"
    STUB_MODE="$1" STUB_ADMIN_PASSWORD="$2" STUB_ADMIN_USER=admin \
        STUB_SEED="${3:-}" \
        STUB_PORT_FILE="${WORK}/port" STUB_JOURNAL="${WORK}/journal" \
        python3 "${STUB}" >"${WORK}/stub.log" 2>&1 &
    STUB_PID=$!
    local i
    for i in $(seq 1 100); do
        [ -s "${WORK}/port" ] && return 0
        kill -0 "${STUB_PID}" 2>/dev/null || break
        sleep 0.1
    done
    bad "stub Casdoor (mode $1) did not come up: $(cat "${WORK}/stub.log" 2>/dev/null)"
    return 1
}
stub_down() {
    [ -n "${STUB_PID}" ] && { kill "${STUB_PID}" 2>/dev/null; wait "${STUB_PID}" 2>/dev/null; }
    STUB_PID=""
}

# Runs one extracted script against the running stub. Output -> ${WORK}/out,
# exit status -> ${RC}. Adds every output to the sweep corpus.
run_script() { # <script> <secrets-dir> <seed-file>
    CASDOOR_URL="http://127.0.0.1:$(cat "${WORK}/port")" \
    CASDOOR_SECRETS_DIR="$2" CASDOOR_INIT_DATA="$3" \
        timeout 120 python3 "$1" >"${WORK}/out" 2>&1
    RC=$?
    cat "${WORK}/out" >>"${WORK}/sweep"
    return 0
}

# A line that tells the operator something CHANGED in Casdoor. Any of these on a
# run that did not persist its write is the lie this whole gate exists to stop.
# Zero-counts are deliberately excluded: "0 created by this Job" is a true report
# of nothing happening, and scoring it as an announcement would make the failure
# scenarios pass for the wrong reason. Every scenario that asserts "announced
# nothing" is paired with a happy-path run that asserts this DOES fire, so the
# detector can never go blind unnoticed.
announces_success() {
    grep -Eq '^[[:space:]]*(added|updated|created)[[:space:]]|: done$|\+[1-9][0-9]* added|-[1-9][0-9]* removed|[1-9][0-9]* (qualified )?member\(s\)|already ==|: assigned |set user\.groups|password rotated' "${WORK}/out"
}

# Stages one script and the files it opens; sets SCRIPT / SECRETS / SEED and, for
# a derived-role sync Job, the two stub stores that take it to its write path. A
# fixture that could not be built must not read as "the script behaved".
SCRIPT=""; SECRETS=""; SEED=""; STUB_SEED_ADD=""; STUB_SEED_PRUNE=""
STUB_SEED_STALE_SUPERADMIN=""; SUPERADMIN_PW=""
stage_fixture() { # <cluster-root> <workdir> <configmap> <admin-password>
    SCRIPT=""; SECRETS=""; SEED=""; STUB_SEED_ADD=""; STUB_SEED_PRUNE=""
    STUB_SEED_STALE_SUPERADMIN=""; SUPERADMIN_PW=""
    eval "$(python3 "${CONTRACT}" fixture "$1" "$2" "$3" "$4" 2>"${WORK}/fixture.err")"
    [ -n "${SCRIPT}" ] && [ -f "${SCRIPT}" ] && return 0
    bad "(4) $3: could not be staged for execution: $(tail -1 "${WORK}/fixture.err")"
    return 1
}

# How many times the script has POSTed a write to the stub so far. A scenario
# that asserts "a write that did not persist was not announced" proves nothing if
# the script never issued the write, so every such scenario checks this moved.
writes_seen() {
    local n
    n="$(grep -c '"path": "/api/\(add\|update\|delete\)-' "${WORK}/journal" 2>/dev/null)" || n=0
    echo "${n:-0}"
}

echo "== 1. source contract (every embedded Casdoor reconcile script) =="
if python3 "${CONTRACT}" static "${CLUSTER}"; then
    ok "(1) every discovered script satisfies the source contract"
else
    bad "(1) at least one script can ignore a Casdoor response (details above)"
fi

echo
echo "== 2. init_data.json wiring contract =="
if python3 "${CONTRACT}" conf "${CLUSTER}"; then
    ok "(2) both Casdoor deployments actually import the seed they mount"
else
    bad "(2) the declarative seed is not wired to be imported (details above)"
fi

echo
echo "== 2b. init_data.json object-graph contract =="
if python3 "${CONTRACT}" seed "${CLUSTER}"; then
    ok "(2b) every declarative seed can satisfy its own import preconditions"
else
    bad "(2b) a seed cannot be imported by the casdoor it is mounted into (details above)"
fi

echo
echo "== 3. negative controls — each check re-run against a corrupted copy =="
STAGE="${WORK}/stage"
mkdir -p "${STAGE}/manifests"
cp -r "${CLUSTER}/manifests/casdoor" "${CLUSTER}/manifests/casdoor-games" "${STAGE}/manifests/"
CONF_CM="${STAGE}/manifests/casdoor/app-conf-configmap.yaml"
INIT_JOB="${STAGE}/manifests/casdoor/init-job.yaml"
DEPLOY="${STAGE}/manifests/casdoor/deployment.yaml"

control() { # <label> <subcommand> — the staged tree must already be corrupted
    if python3 "${CONTRACT}" "$2" "${STAGE}" >/dev/null 2>&1; then
        bad "(3) control [$1]: the corrupted tree still PASSED — $2 is not biting"
    else
        ok "(3) control [$1]: caught by \`$2\`"
    fi
}

# (nc1) call() stops checking the envelope -> the whole class comes back.
python3 - "${INIT_JOB}" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
needle = '        if resp.get("status") != "ok":\n'
assert s.count(needle) == 1, "control precondition: status check not found exactly once"
p.write_text(s.replace(needle, '        if False:\n'))
PY
if [ $? -eq 0 ]; then control "call() ignores the response envelope" static
else bad "(3) control [call() ignores the response envelope] could not be staged"; fi
cp "${CLUSTER}/manifests/casdoor/init-job.yaml" "${INIT_JOB}"

# (nc2) the initDataFile key goes missing -> the seed silently stops importing.
python3 - "${CONF_CM}" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
lines = [l for l in s.splitlines(True) if not l.strip().startswith("initDataFile")]
assert len(lines) == len(s.splitlines(True)) - 1, "control precondition: no initDataFile line"
p.write_text("".join(lines))
PY
if [ $? -eq 0 ]; then control "app.conf drops initDataFile" conf
else bad "(3) control [app.conf drops initDataFile] could not be staged"; fi
cp "${CLUSTER}/manifests/casdoor/app-conf-configmap.yaml" "${CONF_CM}"

# (nc3) initDataNewOnly flips back to the upstream default -> every restart
# deletes and re-adds the org, roles and service users.
python3 - "${CONF_CM}" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
assert s.count("initDataNewOnly = true") == 1, "control precondition: initDataNewOnly"
p.write_text(s.replace("initDataNewOnly = true", "initDataNewOnly = false"))
PY
if [ $? -eq 0 ]; then control "initDataNewOnly reverts to false" conf
else bad "(3) control [initDataNewOnly reverts to false] could not be staged"; fi
cp "${CLUSTER}/manifests/casdoor/app-conf-configmap.yaml" "${CONF_CM}"

# (nc4) the seed is mounted somewhere the conf does not name -> inert again.
python3 - "${DEPLOY}" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
needle = "mountPath: /init_data.json, subPath: init_data.json"
assert s.count(needle) == 1, "control precondition: seed mountPath"
p.write_text(s.replace(needle, "mountPath: /elsewhere/init_data.json, subPath: init_data.json"))
PY
if [ $? -eq 0 ]; then control "seed mounted at a path initDataFile does not name" conf
else bad "(3) control [seed mount path drift] could not be staged"; fi
cp "${CLUSTER}/manifests/casdoor/deployment.yaml" "${DEPLOY}"

# (nc5) THE SHAPE A WORD-SEARCH CANNOT TELL FROM A CHECK. call() still reads the
# envelope, still names "status", still names "ok", still contains a `raise` (in
# its HTTPError handler) — and now LOGS the bad status and returns the response
# anyway. Every substring a grep would look for is present; the enforcement is
# gone. `static` must fail on control flow, not vocabulary.
SYNC_JOB="${STAGE}/manifests/casdoor/games-admin-sync-job.yaml"
python3 - "${SYNC_JOB}" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
needle = ('            raise CasdoorError(f"{method} {path}: {msg or resp}") from None\n')
assert s.count(needle) == 1, "control precondition: call() envelope raise"
p.write_text(s.replace(needle,
    '            print(f"{method} {path}: status is not ok: {msg or resp}")\n'))
PY
if [ $? -eq 0 ]; then control "call() logs a non-ok status and returns it anyway" static
else bad "(3) control [call() logs instead of raising] could not be staged"; fi
cp "${CLUSTER}/manifests/casdoor/games-admin-sync-job.yaml" "${SYNC_JOB}"

# (nc6) the post-write verification is deleted, so the Job announces a membership
# change off the write's envelope alone. casdoor answers status ok for a write
# that stored nothing, so that envelope is not evidence — `static`'s write/re-read
# rule must say so without needing the script to be run.
python3 - "${SYNC_JOB}" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
m = re.search(r'( *call\(f"/api/update-role\?id=\{ORG\}/\{[A-Z_]+\}", target, "POST"\)\n)'
              r'(?:.*\n)*?( *added *= sorted\()', s)
assert m, "control precondition: the write and its verification block"
p.write_text(s[:m.end(1)] + s[m.start(2):])
PY
if [ $? -eq 0 ]; then control "a sync Job announces its write with no read-back" static
else bad "(3) control [write with no read-back] could not be staged"; fi
cp "${CLUSTER}/manifests/casdoor/games-admin-sync-job.yaml" "${SYNC_JOB}"

# ── controls for the object-graph contract (2b) ──────────────────────────────
# Each one edits the STAGED seed's embedded init_data.json and asserts `seed`
# fails on it. The mutation is applied to the parsed JSON rather than by patching
# text, so a reformatting of the ConfigMap cannot quietly stop these staging.
SEED_CM="${STAGE}/manifests/casdoor/init-data-configmap.yaml"
mutate_seed() { # <configmap-file> <python statement over `j`, asserting its own precondition>
    python3 - "$1" "$2" <<'PY'
import json, pathlib, sys, yaml
p = pathlib.Path(sys.argv[1])
doc = yaml.safe_load(p.read_text())
j = json.loads(doc["data"]["init_data.json"])
exec(sys.argv[2])
doc["data"]["init_data.json"] = json.dumps(j, indent=2)
p.write_text(yaml.safe_dump(doc))
PY
}

# (nc7) THE SHIPPED BUG, restored: the applications block goes away and the seed
# is byte-for-byte the shape that CrashLoopBackOff'd a live cluster.
mutate_seed "${SEED_CM}" '
assert j.get("applications"), "control precondition: no applications block to remove"
assert j.get("users"), "control precondition: no users to be blocked by it"
del j["applications"]'
if [ $? -eq 0 ]; then control "the seed declares users for an org with no application" seed
else bad "(3) control [users with no application] could not be staged"; fi
cp "${CLUSTER}/manifests/casdoor/init-data-configmap.yaml" "${SEED_CM}"

# (nc8) THE SUBTLE ONE. The application is there, but owned by the organization
# instead of by "admin" — which reads perfectly naturally and makes the count
# (owner = <organization.Owner>) return 0 just the same, so the panic comes back
# with an applications block sitting right there in the file.
mutate_seed "${SEED_CM}" '
assert j["applications"] and j["applications"][0]["owner"] == "admin", \
    "control precondition: application is not admin-owned to begin with"
j["applications"][0]["owner"] = j["organizations"][0]["name"]'
if [ $? -eq 0 ]; then control "the application is owned by the org, not by admin" seed
else bad "(3) control [application owner drift] could not be staged"; fi
cp "${CLUSTER}/manifests/casdoor/init-data-configmap.yaml" "${SEED_CM}"

# (nc9) a role names a member the seed never creates. Casdoor stores it without a
# murmur (bare insert, no FK), so nothing but a static check can ever see it.
mutate_seed "${SEED_CM}" '
r = [x for x in j["roles"] if x["name"] == "ROLE_ADMIN"]
assert r, "control precondition: ROLE_ADMIN not found"
r[0]["users"] = ["hugmesh/svc-does-not-exist"]'
if [ $? -eq 0 ]; then control "a role names a user the seed never creates" seed
else bad "(3) control [phantom role membership] could not be staged"; fi
cp "${CLUSTER}/manifests/casdoor/init-data-configmap.yaml" "${SEED_CM}"

# (nc10) the ordering rule, which nothing in the shipped tree exercises today: an
# application naming a cert the SAME file declares. InitFromFile() creates certs
# after applications, so the reference is written against nothing.
mutate_seed "${SEED_CM}" '
assert j.get("applications"), "control precondition: no application to give a cert"
j["applications"][0]["cert"] = "cert-hugmesh"
j["certs"] = [{"owner": "admin", "name": "cert-hugmesh", "type": "x509"}]'
if [ $? -eq 0 ]; then control "an application names a cert declared later in the same file" seed
else bad "(3) control [cert ordering] could not be staged"; fi
cp "${CLUSTER}/manifests/casdoor/init-data-configmap.yaml" "${SEED_CM}"

# (nc11) THE CONSISTENT LIE. A whole second tenant is added — organization,
# its user and its own application — under an owner that is not "admin". Nothing
# inside the file disagrees with anything else, so a rule that DERIVES the
# required owner from the seed's own organization block passes it; casdoor still
# never finds the organization, because GetOrganizationByUser hardcodes
# getOrganization("admin", user.Owner) (object/organization.go:305-311), and
# initDefinedUser panics on "the organization: acme is not found"
# (object/user.go:992-998 -> object/init_data.go:366-368).
mutate_seed "${SEED_CM}" '
assert all(o["owner"] == "admin" for o in j["organizations"]), \
    "control precondition: an organization is already non-admin-owned"
j["organizations"].append({"owner": "acme", "name": "acme", "displayName": "Acme"})
j["users"].append({"owner": "acme", "name": "svc-acme", "type": "normal-user"})
j["applications"].append({"owner": "acme", "name": "app-acme",
                          "organization": "acme", "clientId": "a" * 20})'
if [ $? -eq 0 ]; then control "a self-consistent tenant owned by something other than admin" seed
else bad "(3) control [non-admin organization owner] could not be staged"; fi
cp "${CLUSTER}/manifests/casdoor/init-data-configmap.yaml" "${SEED_CM}"

# (nc12) a service account is put in the built-in organization. AddUser exempts
# built-in from the APPLICATION-COUNT check (object/user.go:999) and from nothing
# else — object/user.go:1010-1011 rejects any built-in user not named "admin"
# while HasPrivilegeConsent is false, and initDefinedUser panics on that too. A
# guard that reads the first exemption as "built-in is exempt" skips the object
# entirely and reports a pass.
mutate_seed "${SEED_CM}" '
assert not [u for u in j["users"] if u["owner"] == "built-in"], \
    "control precondition: a built-in user already exists"
j["users"].append({"owner": "built-in", "name": "svc-ops", "type": "normal-user"})'
if [ $? -eq 0 ]; then control "a service account in the built-in organization" seed
else bad "(3) control [built-in service account] could not be staged"; fi
cp "${CLUSTER}/manifests/casdoor/init-data-configmap.yaml" "${SEED_CM}"

# ── and the other direction, so nc12 is not passing off a blanket ban ─────────
# The rule is "no built-in user but admin", not "no built-in user". If `seed`
# rejected the built-in organization outright it would satisfy nc12 while
# forbidding the one thing casdoor allows, so the legal shape is asserted to
# still PASS. Same for an admin-owned second tenant against nc11.
permits() { # <label> — the staged tree is legal and must still pass
    if python3 "${CONTRACT}" seed "${STAGE}" >/dev/null 2>&1; then
        ok "(3) control [$1]: still accepted, so the rule above is not a blanket ban"
    else
        bad "(3) control [$1]: \`seed\` rejects a shape casdoor accepts — over-broad"
    fi
}
mutate_seed "${SEED_CM}" '
j["users"].append({"owner": "built-in", "name": "admin", "type": "normal-user"})'
if [ $? -eq 0 ]; then permits "the built-in user IS named admin"
else bad "(3) control [built-in admin allowed] could not be staged"; fi
cp "${CLUSTER}/manifests/casdoor/init-data-configmap.yaml" "${SEED_CM}"

mutate_seed "${SEED_CM}" '
j["organizations"].append({"owner": "admin", "name": "acme", "displayName": "Acme"})
j["users"].append({"owner": "acme", "name": "svc-acme", "type": "normal-user"})
j["applications"].append({"owner": "admin", "name": "app-acme",
                          "organization": "acme", "clientId": "a" * 20})'
if [ $? -eq 0 ]; then permits "a second tenant declared the way casdoor requires"
else bad "(3) control [admin-owned second tenant allowed] could not be staged"; fi
cp "${CLUSTER}/manifests/casdoor/init-data-configmap.yaml" "${SEED_CM}"

echo
echo "== 4. behaviour — the real scripts against the live failure shapes =="
: >"${WORK}/sweep"
INIT_SCRIPTS="$(python3 "${CONTRACT}" discover "${CLUSTER}" | awk -F'\t' '$2=="init"{print $1}' | cut -d/ -f1)"
SYNC_SCRIPTS="$(python3 "${CONTRACT}" discover "${CLUSTER}" | awk -F'\t' '$2=="sync"{print $1}' | cut -d/ -f1)"
ALL_SCRIPTS="$(python3 "${CONTRACT}" discover "${CLUSTER}" | cut -f1 | cut -d/ -f1)"
[ -n "${ALL_SCRIPTS}" ] || bad "(4) discovery returned no scripts to run"
[ -n "${SYNC_SCRIPTS}" ] || bad "(4) no derived-role sync Job was discovered — the \
Jobs whose write is an authorization source would go unexercised"

# A script that hardcodes /secrets cannot be run anywhere but inside its own Pod,
# so its behaviour is unprovable here. Say that, rather than letting a
# FileNotFoundError stand in for a verdict about honesty.
exercisable() { # <script>
    if grep -q CASDOOR_SECRETS_DIR "$1"; then return 0; fi
    bad "(4) ${cm}: hardcodes its secret paths — its behaviour cannot be exercised "\
"offline, so none of the scenarios below can be run against it"
    return 1
}

for cm in ${ALL_SCRIPTS}; do
    stage_fixture "${CLUSTER}" "${WORK}/fx" "${cm}" "${PROVISIONED_PW}" || continue
    exercisable "${SCRIPT}" || continue
    # (4a) A DENIED SESSION — the exact live shape. Must exit non-zero, must not
    # announce anything, and must name the login/session failure rather than
    # confidently misdiagnosing the empty reads it gets back.
    stub_up deny-login "${CASDOOR_DEFAULT_PW}" || continue
    run_script "${SCRIPT}" "${SECRETS}" "${SEED}"
    if [ "${RC}" -eq 0 ]; then
        bad "(4a) ${cm}: exited 0 against a Casdoor that denied every call"
    elif announces_success; then
        bad "(4a) ${cm}: announced work it never did while every call was denied"
    elif grep -qiE 'login (failed|did not)|admin session' "${WORK}/out"; then
        ok "(4a) ${cm}: a denied session exits non-zero and is reported AS a login failure"
    else
        bad "(4a) ${cm}: exits non-zero but never names the login failure: $(tail -1 "${WORK}/out")"
    fi
    stub_down
done

# ── the derived-role sync Jobs ───────────────────────────────────────────────
# These three materialize ROLE_GAMES_ADMIN / ROLE_GAMES_SERVICES_ADMIN /
# ROLE_GAMES_SERVICES_RUNNER, and those roles are the ONLY thing on the
# corresponding route-access rows — so what they write IS the authorization
# decision. casdoor's wrapActionResponse() answers {"status":"ok","data":
# "Affected"|"Unaffected"} for every write that reached the handler whether or
# not it stored anything (and /api/update-group is LIVE-VERIFIED to answer
# "Affected" while persisting no membership at all), so an ok envelope is not
# evidence and these Jobs must not announce off one.
#
# The stub is seeded from each script's OWN role names first, in two directions:
#   ADD   — the derived role gains a member.
#   PRUNE — it loses its last one, so the expected set is EMPTY. That is the
#           direction where a readback which FAILED and was quietly turned into
#           "no members" compares equal to the expected set and the run reports a
#           removal that never happened. Add-only testing cannot see it.
sync_write_scenarios() { # <cluster-root> <configmap>
    local root="$1" cm="$2" before after
    stage_fixture "${root}" "${WORK}/fx-sync" "${cm}" "${PROVISIONED_PW}" || return 1
    exercisable "${SCRIPT}" || return 1
    if [ -z "${STUB_SEED_ADD}" ] || [ -z "${STUB_SEED_PRUNE}" ]; then
        bad "(4s) ${cm}: no stub store could be derived from the script's own role \
names, so every scenario below would run against an empty Casdoor, exit early and \
prove nothing"
        return 1
    fi

    # (4s1) reads work, the write is DENIED — "result = deny" behind a good login.
    stub_up deny-writes "${PROVISIONED_PW}" "${STUB_SEED_ADD}" || return 1
    run_script "${SCRIPT}" "${SECRETS}" "${SEED}"
    if [ "$(writes_seen)" -lt 1 ]; then
        bad "(4s1) ${cm}: never issued its write, so 'announced nothing' proves nothing"
    elif [ "${RC}" -ne 0 ] && ! announces_success; then
        ok "(4s1) ${cm}: a denied update-role -> exits non-zero, announces no membership change"
    else
        bad "(4s1) ${cm}: rc=${RC} with the write denied$(announces_success && echo ' and it announced the change anyway')"
    fi
    stub_down

    # (4s2) the write answers {"status":"ok","data":"Affected"} and stores NOTHING
    # — the update-group shape, generalised. Only a read-back can see this.
    stub_up writes-vanish "${PROVISIONED_PW}" "${STUB_SEED_ADD}" || return 1
    run_script "${SCRIPT}" "${SECRETS}" "${SEED}"
    if [ "$(writes_seen)" -lt 1 ]; then
        bad "(4s2) ${cm}: never issued its write, so 'announced nothing' proves nothing"
    elif [ "${RC}" -ne 0 ] && ! announces_success; then
        ok "(4s2) ${cm}: a write that reports ok and persists nothing -> exits non-zero, announces nothing"
    else
        bad "(4s2) ${cm}: rc=${RC} when the write persisted nothing$(announces_success && echo ' and it announced it anyway')"
    fi
    stub_down

    # (4s3) THE ONE THE ADD DIRECTION CANNOT SEE. The write reports ok, stores
    # nothing, and the verification read is DENIED. casdoor's GetRole answers
    # ResponseOk(role) — data null — for a role that does not exist, so a status
    # "error" here is a DENIAL and never an absence: a script that lets an
    # error-swallowing helper turn it into an empty role compares that invention
    # against an expected set that is ALSO empty, matches, and announces the prune.
    stub_up readback-denied "${PROVISIONED_PW}" "${STUB_SEED_PRUNE}" || return 1
    run_script "${SCRIPT}" "${SECRETS}" "${SEED}"
    if [ "$(writes_seen)" -lt 1 ]; then
        bad "(4s3) ${cm}: never issued its write, so this scenario proves nothing"
    elif [ "${RC}" -ne 0 ] && ! announces_success; then
        ok "(4s3) ${cm}: a write whose verification read was denied -> exits non-zero, \
announces no removal"
    else
        bad "(4s3) ${cm}: rc=${RC} — the verification read was DENIED and the run \
$(announces_success && echo 'announced the membership change anyway' || echo 'still succeeded')"
    fi
    stub_down

    # (4s4) THE HAPPY PATH, and the proof none of the above is vacuous: against a
    # Casdoor that really stores, the same script must succeed, must issue the
    # write, and the announcement detector used by (4s1)-(4s3) must FIRE. A second
    # run must then converge without writing again.
    stub_up ok "${PROVISIONED_PW}" "${STUB_SEED_ADD}" || return 1
    run_script "${SCRIPT}" "${SECRETS}" "${SEED}"
    before="$(writes_seen)"
    if [ "${RC}" -ne 0 ]; then
        bad "(4s4) ${cm}: the happy path FAILED (rc=${RC}): $(tail -2 "${WORK}/out" | tr '\n' ' ')"
    elif [ "${before}" -lt 1 ]; then
        bad "(4s4) ${cm}: happy path exited 0 without ever writing the derived role"
    elif ! announces_success; then
        bad "(4s4) ${cm}: happy path announced nothing the detector recognises — every \
'announces nothing' PASS above would be a property of the detector, not the script"
    else
        ok "(4s4) ${cm}: against a Casdoor that stores, it writes the derived role, \
verifies it and announces the change (so the scenarios above are not vacuous)"
    fi
    run_script "${SCRIPT}" "${SECRETS}" "${SEED}"
    after="$(writes_seen)"
    if [ "${RC}" -eq 0 ] && [ "${after}" -eq "${before}" ] && grep -q 'no change' "${WORK}/out"; then
        ok "(4s4) ${cm}: a second run is idempotent — converged with no further write"
    else
        bad "(4s4) ${cm}: re-run was not idempotent (rc=${RC}, writes ${before}->${after}): \
$(tail -1 "${WORK}/out")"
    fi
    stub_down
}

for cm in ${SYNC_SCRIPTS}; do
    sync_write_scenarios "${CLUSTER}" "${cm}"
done

for cm in ${INIT_SCRIPTS}; do
    stage_fixture "${CLUSTER}" "${WORK}/fx" "${cm}" "${PROVISIONED_PW}" || continue
    grep -q CASDOOR_SECRETS_DIR "${SCRIPT}" || continue   # already reported above

    # (4b) Reads work, every WRITE is denied — "result = deny" with a good login.
    stub_up deny-writes "${PROVISIONED_PW}" || continue
    run_script "${SCRIPT}" "${SECRETS}" "${SEED}"
    if [ "${RC}" -ne 0 ] && ! announces_success; then
        ok "(4b) ${cm}: every write denied -> exits non-zero, announces nothing"
    else
        bad "(4b) ${cm}: rc=${RC} with denied writes$(announces_success && echo ' and it printed added/updated/done')"
    fi
    stub_down

    # (4c) Writes answer {"status":"ok"} and store NOTHING — the update-group
    # shape, generalised. This is the one a status check alone cannot catch.
    stub_up writes-vanish "${PROVISIONED_PW}" || continue
    run_script "${SCRIPT}" "${SECRETS}" "${SEED}"
    if [ "${RC}" -ne 0 ] && ! announces_success; then
        ok "(4c) ${cm}: writes that report ok but persist nothing -> exits non-zero, announces nothing"
    else
        bad "(4c) ${cm}: rc=${RC} when no write persisted$(announces_success && echo ' and it announced them anyway')"
    fi
    stub_down

    # (4d) set-password reports success without changing the password. The Job
    # must not go on believing the credential was rotated.
    stub_up setpw-noop "${CASDOOR_DEFAULT_PW}" || continue
    run_script "${SCRIPT}" "${SECRETS}" "${SEED}"
    if [ "${RC}" -ne 0 ] && ! grep -q ': done$' "${WORK}/out"; then
        ok "(4d) ${cm}: a set-password that did not take -> exits non-zero, no 'done'"
    else
        bad "(4d) ${cm}: rc=${RC} after set-password silently failed to change the password"
    fi
    stub_down

    # (4e) THE HAPPY PATH, from a fresh cluster whose admin still has casdoor's
    # default. Must succeed, must take the account over, and the default must
    # stop working. Then a SECOND run against the same stub must converge with no
    # password change at all (idempotence) — and both together prove this gate is
    # not passing merely because the script always fails.
    stub_up ok "${CASDOOR_DEFAULT_PW}" || continue
    run_script "${SCRIPT}" "${SECRETS}" "${SEED}"
    if [ "${RC}" -ne 0 ]; then
        bad "(4e) ${cm}: the happy path FAILED (rc=${RC}): $(tail -3 "${WORK}/out" | tr '\n' ' ')"
    elif ! grep -q ': done$' "${WORK}/out"; then
        bad "(4e) ${cm}: happy path exited 0 without printing its done line"
    elif ! grep -q '"path": "/api/set-password"' "${WORK}/journal"; then
        bad "(4e) ${cm}: happy path never called /api/set-password — the provisioned "\
"password was never applied and the account keeps casdoor's default"
    else
        ok "(4e) ${cm}: fresh cluster -> succeeds, and takes the admin account over "\
"from casdoor's default via /api/set-password"
    fi
    # the form fields casdoor's SetPassword() reads, all four present. An ABSENT
    # call is reported as proving nothing about the shape, never scored either way.
    if ! grep -q '"path": "/api/set-password"' "${WORK}/journal"; then
        bad "(4e) ${cm}: no /api/set-password call to inspect — the payload shape is unproven"
    elif grep -q '"fields": \["newPassword", "oldPassword", "userName", "userOwner"\]' "${WORK}/journal"; then
        ok "(4e) ${cm}: set-password is sent with userOwner/userName/oldPassword/newPassword"
    else
        bad "(4e) ${cm}: set-password payload is not the shape casdoor reads: "\
"$(grep set-password "${WORK}/journal" | head -1)"
    fi
    run_script "${SCRIPT}" "${SECRETS}" "${SEED}"
    if [ "${RC}" -eq 0 ] && grep -q 'already the provisioned value' "${WORK}/out"; then
        ok "(4e) ${cm}: a second run is idempotent — no password change attempted"
    else
        bad "(4e) ${cm}: re-run was not idempotent (rc=${RC}): $(tail -2 "${WORK}/out" | tr '\n' ' ')"
    fi
    stub_down

    # (4f) The Vault value IS casdoor's default. Provisioning the well-known
    # password is the exposure, not a fix, so it must be refused.
    stage_fixture "${CLUSTER}" "${WORK}/fx-default" "${cm}" "${CASDOOR_DEFAULT_PW}" || continue
    stub_up ok "${CASDOOR_DEFAULT_PW}" || continue
    run_script "${SCRIPT}" "${SECRETS}" "${SEED}"
    if [ "${RC}" -ne 0 ] && grep -q 'bootstrap default' "${WORK}/out"; then
        ok "(4f) ${cm}: refuses to leave the IdP on casdoor's publicly known password"
    else
        bad "(4f) ${cm}: accepted casdoor's default as the provisioned password (rc=${RC})"
    fi
    stub_down

    # (4g) THE ROTATION. The admin account has its own leg above; this is every
    # OTHER account the Job provisions from Vault, of which the superadmin is the
    # one that exists. The cluster already holds the account with the PREVIOUS
    # password — the state a rotation in Vault produces — and the run must move it,
    # because /api/update-user cannot carry a password at all: for as long as this
    # leg only re-sent the user object, a rotated Vault secret never reached the
    # IdP and the divergence surfaced as a superadmin who could not log in.
    stage_fixture "${CLUSTER}" "${WORK}/fx-rot" "${cm}" "${PROVISIONED_PW}" || continue
    if [ -z "${STUB_SEED_STALE_SUPERADMIN}" ]; then
        echo "  --   (4g) ${cm}: no Vault-provisioned non-admin account — nothing to rotate"
    else
        stub_up ok "${PROVISIONED_PW}" "${STUB_SEED_STALE_SUPERADMIN}" || continue
        run_script "${SCRIPT}" "${SECRETS}" "${SEED}"
        if [ "${RC}" -eq 0 ] && grep -q 'superadmin: password rotated' "${WORK}/out"; then
            ok "(4g) ${cm}: an account already holding the PREVIOUS password is rotated to the Vault value"
        else
            bad "(4g) ${cm}: a rotated Vault password did not reach the IdP (rc=${RC}): $(grep -i 'superadmin: password' "${WORK}/out" | head -1)"
        fi
        # ...and the very next run must find it converged, off casdoor's own
        # refusal to re-set an identical password — not off a remembered result.
        run_script "${SCRIPT}" "${SECRETS}" "${SEED}"
        if [ "${RC}" -eq 0 ] && grep -q 'superadmin: password already the provisioned value' "${WORK}/out"; then
            ok "(4g) ${cm}: the re-run reads the rotation back out of casdoor and rotates nothing"
        else
            bad "(4g) ${cm}: the re-run did not confirm the rotation (rc=${RC}): $(grep -i 'superadmin: password' "${WORK}/out" | head -1)"
        fi
        stub_down

        # (4h) and the lie this must not be able to tell: set-password answers ok
        # and stores nothing (casdoor's wrapActionResponse shape). The admin
        # password is already converged here, so the admin leg never touches
        # set-password and the scenario lands squarely on the account leg.
        stub_up setpw-noop "${PROVISIONED_PW}" "${STUB_SEED_STALE_SUPERADMIN}" || continue
        run_script "${SCRIPT}" "${SECRETS}" "${SEED}"
        if [ "${RC}" -ne 0 ] && ! grep -q 'superadmin: password rotated' "${WORK}/out"; then
            ok "(4h) ${cm}: a set-password that reported ok and stored nothing -> exits non-zero, announces no rotation"
        else
            bad "(4h) ${cm}: announced a rotation the store never took (rc=${RC})"
        fi
        stub_down
    fi
done

echo
echo "== 4z. behavioural negative control — (4s3) must catch the bug it exists for =="
# Layer 1 and 2 get their checks re-run against a corrupted copy; layer 3 gets the
# same treatment. The regression staged here is the exact one the shipped sync
# Jobs carried: role_obj() catches CasdoorError and answers {} — so a DENIED
# verification read becomes "the role has no members", which on a PRUNE is
# precisely the expected value, and the Job announces a removal it never made.
# If (4s3) ever stops failing on this, it has stopped guarding.
sync_control_scenario() { # <cluster-root> <configmap> <what>
    stage_fixture "$1" "${WORK}/fx-nc" "$2" "${PROVISIONED_PW}" || return 1
    if [ -z "${STUB_SEED_PRUNE}" ]; then
        bad "(4z) control [$3]: no stub store could be derived, so nothing was exercised"
        return 1
    fi
    stub_up readback-denied "${PROVISIONED_PW}" "${STUB_SEED_PRUNE}" || return 1
    run_script "${SCRIPT}" "${SECRETS}" "${SEED}"
    if [ "$(writes_seen)" -lt 1 ]; then
        bad "(4z) control [$3]: the regressed script never reached its write, so the \
scenario was never exercised and this control proves nothing"
    elif [ "${RC}" -eq 0 ] && announces_success; then
        ok "(4z) control [$3]: caught — the regressed copy exits 0 announcing \
\"$(grep -Eo '\-[0-9]+ removed' "${WORK}/out" | head -1)\" against a store it never \
wrote, which is exactly what (4s3) reports as a FAIL"
    else
        bad "(4z) control [$3]: the regressed copy was NOT caught (rc=${RC}, \
announced=$(announces_success && echo yes || echo no)) — scenario (4s3) is not biting"
    fi
    stub_down
}

NCTREE="${WORK}/nc-tree"
rm -rf "${NCTREE}"; mkdir -p "${NCTREE}/manifests"
cp -r "${CLUSTER}/manifests/casdoor" "${CLUSTER}/manifests/casdoor-games" "${NCTREE}/manifests/"
python3 - "${NCTREE}/manifests/casdoor/games-admin-sync-job.yaml" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
# (a) role_obj answers {} on a denial instead of letting it raise
needle = '        return call(f"/api/get-role?id={ORG}/{role}").get("data") or {}\n'
assert s.count(needle) == 1, "control precondition: role_obj reads through call()"
s = s.replace(needle,
              '        try:\n'
              '            return call(f"/api/get-role?id={ORG}/{role}").get("data") or {}\n'
              '        except CasdoorError:\n'
              '            return {}\n')
# (b) and the verification compares straight through it, with no "did the read
#     even answer?" step in between — together, the shipped shape this gate was
#     written to make un-reshippable.
m = re.search(r'( *)verified = role_obj\((\w+)\)\n(?:.*\n)*?'
              r' *if members\(verified\) != set\(qualified\):\n', s)
assert m, "control precondition: the verification block"
s = s[:m.start()] + f"{m.group(1)}if members(role_obj({m.group(2)})) != set(qualified):\n" \
    + s[m.end():]
p.write_text(s)
PY
if [ $? -eq 0 ]; then
    sync_control_scenario "${NCTREE}" games-admin-sync-script \
        "role_obj() turns a denied read back into an empty role"
else
    bad "(4z) control [role_obj swallows a denial] could not be staged"
fi

# The SECOND behavioural control: an init script that rebuilds an update-user
# payload from scratch. It is invisible on a fresh cluster — the object does not
# exist yet, so the ADD path runs and everything succeeds — and fails on every
# run after that, which for a Job ArgoCD re-runs on each sync means it is broken
# nearly all of the time. So the scenario must run the script TWICE and judge the
# second run; a single-run harness cannot see this class at all.
init_rerun_scenario() { # <cluster-root> <configmap> <what> <expect: catch|clean>
    local rc1
    stage_fixture "$1" "${WORK}/fx-nci" "$2" "${PROVISIONED_PW}" || return 1
    stub_up ok "${CASDOOR_DEFAULT_PW}" || return 1
    run_script "${SCRIPT}" "${SECRETS}" "${SEED}"
    rc1=${RC}
    run_script "${SCRIPT}" "${SECRETS}" "${SEED}"
    if [ "${rc1}" -ne 0 ]; then
        bad "(4z) [$3]: failed on its FIRST run (rc=${rc1}), so the re-run property \
was never exercised: $(tail -2 "${WORK}/out" | tr '\n' ' ')"
    elif [ "$4" = "catch" ]; then
        if [ "${RC}" -ne 0 ] && grep -q 'ID is immutable' "${WORK}/out"; then
            ok "(4z) control [$3]: caught — the first run passes and the re-run fails \
with \"The ID is immutable.\", exactly what (4e)'s idempotence check scores as a FAIL"
        else
            bad "(4z) control [$3]: NOT caught (rc=${RC}) — the stub's immutable-ID \
rule has stopped biting, so a reconciler that is broken on every re-sync would ship"
        fi
    elif [ "${RC}" -eq 0 ] && grep -q ': done$' "${WORK}/out"; then
        ok "(4z) [$3]: the shipped script survives a second run against a casdoor that \
enforces the immutable ID (so the control above is not passing on a script that \
always fails)"
    else
        bad "(4z) [$3]: the shipped script does not survive a re-run (rc=${RC}): \
$(tail -2 "${WORK}/out" | tr '\n' ' ')"
    fi
    stub_down
}

python3 - "${NCTREE}/manifests/casdoor/init-job.yaml" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
# The regression: the update payload stops being the object read back from
# casdoor and becomes one built from scratch — no "id", so casdoor rejects it.
needle = "            user = dict(existing)\n"
assert s.count(needle) == 1, "control precondition: the re-fetched update payload"
p.write_text(s.replace(needle, '            user = {"owner": ORG, "name": username}\n'))
PY
if [ $? -eq 0 ]; then
    init_rerun_scenario "${NCTREE}" casdoor-init-script \
        "update-user payload rebuilt from scratch instead of re-read" catch
    init_rerun_scenario "${CLUSTER}" casdoor-init-script \
        "casdoor-init re-run" clean
else
    bad "(4z) control [update-user payload rebuilt from scratch] could not be staged"
fi

# THE THIRD behavioural control, for (4h): apply_password() stops confirming and
# reports the rotation off set-password's response envelope alone. That envelope
# is not evidence — casdoor answers ok for a write that changed nothing — and a
# password is the one object with no read endpoint at all (/api/get-user masks it
# as "***", object/user.go:678), so the confirming refusal is the ONLY read-back
# there is. If (4h) ever stops failing on this, the rotation leg is announcing an
# unverified credential change, which is the same class of lie as the original
# thirteen "added" lines.
NCROT="${WORK}/nc-rot"
rm -rf "${NCROT}"; mkdir -p "${NCROT}/manifests"
cp -r "${CLUSTER}/manifests/casdoor" "${CLUSTER}/manifests/casdoor-games" "${NCROT}/manifests/"
python3 - "${NCROT}/manifests/casdoor/init-job.yaml" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
m = re.search(r'( *)confirm = attempt\(\)\n(?:.*\n)*?'
              r'.*credential is NOT what Vault holds"\)\n', s)
assert m, "control precondition: apply_password's confirming second call"
assert s.count("confirm = attempt()") == 1, "control precondition: one confirmation"
p.write_text(s[:m.start()] + s[m.end():])
PY
if [ $? -eq 0 ]; then
    stage_fixture "${NCROT}" "${WORK}/fx-ncrot" casdoor-init-script "${PROVISIONED_PW}" \
        && [ -n "${STUB_SEED_STALE_SUPERADMIN}" ] \
        && stub_up setpw-noop "${PROVISIONED_PW}" "${STUB_SEED_STALE_SUPERADMIN}" \
        && run_script "${SCRIPT}" "${SECRETS}" "${SEED}"
    if [ "${RC}" -eq 0 ] && grep -q 'superadmin: password rotated' "${WORK}/out"; then
        ok "(4z) control [apply_password reports a rotation off the write envelope]: \
caught — the regressed copy exits 0 announcing \"password rotated\" against a store \
that kept the old password, which is exactly what (4h) reports as a FAIL"
    else
        bad "(4z) control [apply_password reports a rotation off the write envelope]: \
NOT caught (rc=${RC}) — scenario (4h) is not biting"
    fi
    stub_down
else
    bad "(4z) control [apply_password drops its confirmation] could not be staged"
fi

echo
echo "== 5. secret sweep — no password may reach stdout/stderr on any path =="
if [ ! -s "${WORK}/sweep" ]; then
    bad "(5) no output was captured, so the sweep proves nothing"
elif [ -z "${SUPERADMIN_PW}" ]; then
    bad "(5) the fixture never reported a superadmin password, so the sweep below \
would have been searching for an empty string and could not fail"
elif grep -qF "${PROVISIONED_PW}" "${WORK}/sweep"; then
    bad "(5) the provisioned admin password was printed: $(grep -nF "${PROVISIONED_PW}" "${WORK}/sweep" | head -1)"
elif grep -qF "${SUPERADMIN_PW}" "${WORK}/sweep"; then
    bad "(5) the superadmin password was printed: $(grep -nF "${SUPERADMIN_PW}" "${WORK}/sweep" | head -1)"
elif grep -qE '(password|Password)["=: ]+123\b' "${WORK}/sweep"; then
    bad "(5) a password value was printed alongside its name"
else
    ok "(5) $(wc -l <"${WORK}/sweep") captured output line(s) across every scenario, no password among them"
fi

echo
echo "== casdoor bootstrap honesty: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
