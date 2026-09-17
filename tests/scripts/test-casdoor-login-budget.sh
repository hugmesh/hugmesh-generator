#!/usr/bin/env bash
# =============================================================================
# test-casdoor-login-budget.sh — the Casdoor bootstrap Jobs share ONE account,
# and nothing may spend its sign-in budget out from under the Job that owns it.
#
# WHAT HAPPENED (hugmesh-generator#396, measured on the kind cluster 2026-09-16).
# `make kind-up` exited 1 with casdoor-init reporting
#     FAIL admin login failed with BOTH the provisioned password and the casdoor
#     bootstrap default — reconcile secret/hugmesh/casdoor with the account's
#     real password (nothing below can run)
# The Vault secret was byte-for-byte correct. The account was BANNED: casdoor
# throttles sign-ins, and while the ban holds it refuses the CORRECT password
# too, with HTTP 200 + {"status":"error"} — the same shape a wrong password gets.
#
# Who spent the budget: manifests/casdoor ships FOUR ArgoCD PostSync hook Jobs
# that all log in as built-in/admin, and there was no sync-wave between them. The
# three derived-role syncs know ONLY the Vault-provisioned password, which cannot
# be right until casdoor-init has taken the account over from casdoor's bootstrap
# default — so ArgoCD started all four together and the three guaranteed-wrong
# logins tripped the throttle 2.3 seconds in. casdoor-init's correct "123" login
# was refused inside the ban; the cluster then converged BY ITSELF 7m37s after
# make had already declared failure.
#
# reconcile_admin_password()'s docstring asserted the invariant this broke — "at
# most two wrong-password attempts are ever made, well under casdoor's 5-attempt
# sign-in lockout". True of the FILE; false of the DEPLOYMENT, where the budget
# is spent against one shared account by every Job here and by the pod backoff.
# The measured spend on that run was 104 attempts across 111 logins.
#
# WHAT IS CHECKED, in four layers:
#
#   1. THE DEPLOYMENT. Over every manifests/casdoor*/ directory: the Jobs that
#      open a session with the SAME admin Secret are ordered by
#      argocd.argoproj.io/sync-wave, with the one that owns the takeover strictly
#      first; and that owner exits with a DISTINCT status for "the throttle is
#      refusing every login" which a podFailurePolicy FailJob rule turns into a
#      stop, not into backoffLimit+1 replays of the same ban. Every rule is
#      mutation-tested: the annotation removed, the waves equalised, the sibling
#      moved AHEAD of the owner, the policy deleted, its exit code desynchronised
#      from the script's, restartPolicy put back — each must be CAUGHT.
#   2. THE BOOTSTRAP. `kubectl apply -k` honours no sync-wave, so re-applying the
#      whole directory to restart one Job re-creates the other three alongside it
#      — the same four-way race, by hand. And a wait shorter than casdoor's own
#      lockout window can expire while the cluster is merely serving out a ban it
#      will recover from (600s did, by 7m37s). And ttlSecondsAfterFinished: 600
#      means `kubectl logs job/casdoor-init`, the command the old failure message
#      told the operator to run, prints "No resources found" minutes later — so
#      the failure path must dump the evidence itself, while it exists.
#   3. THE BEHAVIOUR, by RUNNING the real extracted reconcile.py against a stub
#      Casdoor in its new `lockout` mode, which answers with casdoor's own
#      throttle text verbatim. The run must name the throttle, must NOT tell the
#      operator to rotate a correct secret, must exit the non-retryable status,
#      and must STOP attempting: a budget nobody spends is the only one that
#      cannot be overspent. The happy paths pin the spend too — zero wrong
#      attempts on a converged cluster, two on a fresh one.
#   4. NEGATIVE CONTROLS. The pre-fix try_login() is restored into a staged copy
#      and layer 3 must catch it; the marker is blinded and layer 3 must catch
#      that too. A guard whose failure cases are never exercised is a guard that
#      has already stopped biting.
#
# No cluster, no kubectl, no docker, no network egress: the stub binds 127.0.0.1
# on an ephemeral port. PyYAML + python3 stdlib only.
# =============================================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLUSTER="${REPO}/specs/cluster"
CONTRACT="${REPO}/tests/scripts/casdoor_reconcile_contract.py"
STUB="${REPO}/tests/scripts/casdoor_stub.py"
BOOTSTRAP="${CLUSTER}/bootstrap/kind-local/bootstrap-kind.sh"

# casdoor's sign-in lockout window. NOT guessed: on 2026-09-16 the fifth wrong
# attempt landed at 17:13:49.374Z, every attempt up to 17:28:40.720Z was refused,
# and the next attempt — 17:29:18.675Z — succeeded, so the ban expired inside that
# 38s gap and 17:13:49.374 + 900s = 17:28:49.374 falls in it. Any bring-up wait
# shorter than this can expire on a cluster that is merely serving out a ban.
CASDOOR_LOCKOUT_SECONDS=900

command -v python3 >/dev/null 2>&1 || { echo "  FAIL python3 is required"; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "  FAIL PyYAML is required (pip install pyyaml)"; exit 2; }
for f in "${CONTRACT}" "${STUB}" "${BOOTSTRAP}"; do
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

# Deliberately unlike casdoor's default (so the takeover path is exercised) and
# deliberately distinctive (so the secret sweep at the end can look for it).
PROVISIONED_PW="fixture-provisioned-admin-pw-6b21"
CASDOOR_DEFAULT_PW="123"

# ── staging ──────────────────────────────────────────────────────────────────
# A cluster tree holding only the casdoor* manifest directories: `discover()`
# globs manifests/casdoor*/*.yaml, so this is a complete input as far as the
# contract is concerned, and copying 8.6M of specs/cluster per mutation is not.
stage_tree() { # <dest>
    rm -rf "$1"
    mkdir -p "$1/manifests"
    cp -r "${CLUSTER}/manifests/casdoor" "${CLUSTER}/manifests/casdoor-games" "$1/manifests/"
}

# Runs the deployment contract over a tree. Output -> ${WORK}/hooks.out.
hooks_on() { # <tree>
    python3 "${CONTRACT}" hooks "$1" >"${WORK}/hooks.out" 2>&1
    return $?
}

# A mutation that did not change the file proves nothing, and reads exactly like a
# guard that caught it. Every mutation below goes through this.
mutate() { # <label> <file> <python-snippet-on-stdin>
    local label="$1"
    local file="$2"
    local before
    before="$(md5sum "${file}" | cut -d' ' -f1)"
    python3 - "${file}" || { bad "mutation '${label}': the patch script itself failed"; return 1; }
    if [ "$(md5sum "${file}" | cut -d' ' -f1)" = "${before}" ]; then
        bad "mutation '${label}': changed nothing — the control is vacuous"
        return 1
    fi
    return 0
}

echo "== 1. the deployment: who may log in, and in what order =="

if hooks_on "${CLUSTER}"; then
    ok "(1a) the shipped manifests satisfy the hook-ordering / login-budget contract"
    sed 's/^/        /' "${WORK}/hooks.out"
else
    bad "(1a) the shipped manifests FAIL their own hook-ordering contract:"
    sed 's/^/        /' "${WORK}/hooks.out"
fi

# Each control: mutate a staged copy, then require the contract to FAIL.
control() { # <label> <relative-file> ; patch python on stdin
    local label="$1"
    local rel="$2"
    local tree="${WORK}/ctl"
    stage_tree "${tree}"
    mutate "${label}" "${tree}/${rel}" || return 0
    if hooks_on "${tree}"; then
        bad "(1) control [${label}]: SURVIVED — the contract passed a tree with this defect"
    else
        ok "(1) control [${label}]: caught — $(grep -m1 '  FAIL' "${WORK}/hooks.out" | sed 's/^ *FAIL //' | cut -c1-140)"
    fi
}

control "casdoor-init loses its sync-wave" manifests/casdoor/init-job.yaml <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
s = s.replace('    argocd.argoproj.io/sync-wave: "0"\n', '', 1)
open(p, 'w').write(s)
PY

control "a derived-role sync loses its sync-wave" manifests/casdoor/games-admin-sync-job.yaml <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace('    argocd.argoproj.io/sync-wave: "1"\n', '', 1)
open(p, 'w').write(s)
PY

control "a derived-role sync is put in the SAME wave as the takeover" \
        manifests/casdoor/games-services-admin-sync-job.yaml <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace('argocd.argoproj.io/sync-wave: "1"', 'argocd.argoproj.io/sync-wave: "0"', 1)
open(p, 'w').write(s)
PY

control "a derived-role sync is put AHEAD of the takeover" \
        manifests/casdoor/games-services-runner-sync-job.yaml <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace('argocd.argoproj.io/sync-wave: "1"', 'argocd.argoproj.io/sync-wave: "-1"', 1)
open(p, 'w').write(s)
PY

control "the podFailurePolicy is deleted (the pod backoff replays the ban)" \
        manifests/casdoor/init-job.yaml <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
s = re.sub(r"\n  podFailurePolicy:\n(?:    .*\n|      .*\n|        .*\n)+", "\n", s, count=1)
open(p, 'w').write(s)
PY

control "the FailJob exit code drifts away from the script's" \
        manifests/casdoor/init-job.yaml <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("values: [75]", "values: [42]", 1)
open(p, 'w').write(s)
PY

control "restartPolicy goes back to OnFailure (the apiserver would reject the policy)" \
        manifests/casdoor/init-job.yaml <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("      restartPolicy: Never\n", "      restartPolicy: OnFailure\n", 1)
open(p, 'w').write(s)
PY

control "the script stops defining a lockout exit status" manifests/casdoor/init-job.yaml <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("    LOCKOUT_EXIT = 75\n", "", 1)
open(p, 'w').write(s)
PY

echo
echo "== 2. the bring-up: one Job, a wait longer than the ban, evidence on failure =="

bootstrap_check() { # <file>
    python3 - "$1" "${CASDOOR_LOCKOUT_SECONDS}" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
floor = int(sys.argv[2])
fails = []

# Comments are stripped first. Every rule below is about what the script DOES;
# the file explains all three defects in prose, so a textual check that kept the
# comments would pass on a tree where the code had been reverted.
code = "\n".join(re.sub(r"(^|\s)#.*$", "", ln) for ln in src.splitlines())

m = re.search(r"^\s*recreate_job\s+hugmesh-pki\s+casdoor-init\s+(\S+)\s*(\S*)\s*$",
              code, re.M)
if not m:
    fails.append("no `recreate_job hugmesh-pki casdoor-init ...` line at all — "
                 "this guard cannot see what the bring-up restarts")
elif not m.group(2):
    fails.append("recreate_job re-applies the WHOLE casdoor kustomization "
                 f"({m.group(1)}); kubectl honours no sync-wave, so once "
                 "ttlSecondsAfterFinished has reaped the three derived-role hook "
                 "Jobs this re-creates them alongside casdoor-init — the four-way "
                 "login race of #396, by hand. Name init-job.yaml as the 4th arg.")

w = re.search(r"^\s*wait_job\s+hugmesh-pki\s+casdoor-init\s+(\d+)", code, re.M)
k = re.search(r"wait\s+--for=condition=complete\s+job/casdoor-init\s+--timeout=(\d+)s",
              code)
if w:
    if int(w.group(1)) < floor:
        fails.append(f"the casdoor-init wait is {w.group(1)}s, under casdoor's own "
                     f"{floor}s sign-in lockout — it can expire while the cluster is "
                     "serving out a ban it recovers from unaided (600s did, by 7m37s)")
elif k:
    fails.append("the casdoor-init wait is `kubectl wait --for=condition=complete`, "
                 "which cannot see a FAILED Job: it blocks the whole timeout and then "
                 "reports 'timed out waiting for the condition', which reads as slow "
                 "and can mean dead")
else:
    fails.append("no wait on casdoor-init found at all")

body = re.search(r"^wait_job\(\)\s*\{(.*?)^\}", code, re.M | re.S)
if not body:
    fails.append("no wait_job() helper — nothing dumps the Job before "
                 "ttlSecondsAfterFinished reaps it and its pods")
elif not re.search(r"kubectl[^\n]*\blogs\b", body.group(1)):
    fails.append("wait_job() never reads the Job's logs; ttlSecondsAfterFinished: 600 "
                 "means `kubectl logs job/casdoor-init` is empty a few minutes after "
                 "the failure, so the evidence has to be captured here or not at all")

for f in fails:
    print(f"FAIL {f}")
sys.exit(1 if fails else 0)
PY
}

if bootstrap_check "${BOOTSTRAP}" >"${WORK}/boot.out" 2>&1; then
    ok "(2a) bootstrap-kind.sh restarts casdoor-init ALONE, waits past casdoor's ${CASDOOR_LOCKOUT_SECONDS}s lockout, and dumps the Job before its TTL reaps it"
else
    bad "(2a) bootstrap-kind.sh:"
    sed 's/^/        /' "${WORK}/boot.out"
fi

boot_control() { # <label> ; patch python on stdin
    local label="$1"
    cp "${BOOTSTRAP}" "${WORK}/boot.sh"
    mutate "${label}" "${WORK}/boot.sh" || return 0
    if bootstrap_check "${WORK}/boot.sh" >"${WORK}/boot.out" 2>&1; then
        bad "(2) control [${label}]: SURVIVED — the bring-up contract passed with this defect"
    else
        ok "(2) control [${label}]: caught — $(head -1 "${WORK}/boot.out" | sed 's/^FAIL //' | cut -c1-120)"
    fi
}

boot_control "the whole casdoor directory is re-applied again" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace('recreate_job hugmesh-pki casdoor-init "${CLUSTER_DIR}/manifests/casdoor" init-job.yaml',
              'recreate_job hugmesh-pki casdoor-init "${CLUSTER_DIR}/manifests/casdoor"', 1)
open(p, 'w').write(s)
PY

boot_control "the wait drops back under casdoor's lockout window" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("wait_job hugmesh-pki casdoor-init 1200", "wait_job hugmesh-pki casdoor-init 600", 1)
open(p, 'w').write(s)
PY

boot_control "the wait goes back to kubectl wait --for=condition=complete" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace("  wait_job hugmesh-pki casdoor-init 1200 \\\n",
              "  kubectl -n hugmesh-pki wait --for=condition=complete job/casdoor-init --timeout=600s \\\n", 1)
open(p, 'w').write(s)
PY

boot_control "wait_job stops dumping the Job's logs" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace('    kubectl -n "${ns}" logs "${pod}" --all-containers --tail=80 >&2 2>/dev/null || true\n',
              '    true\n', 1)
open(p, 'w').write(s)
PY

echo
echo "== 3. the behaviour: the real reconcile.py against casdoor's own throttle =="

stub_up() { # <mode> <initial-admin-password> <lockout-after>
    stub_down
    rm -f "${WORK}/port" "${WORK}/journal"
    STUB_MODE="$1" STUB_ADMIN_PASSWORD="$2" STUB_ADMIN_USER=admin \
        STUB_LOCKOUT_AFTER="$3" \
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

SCRIPT=""; SECRETS=""; SEED=""
stage_fixture() { # <cluster-root> <workdir>
    SCRIPT=""; SECRETS=""; SEED=""
    eval "$(python3 "${CONTRACT}" fixture "$1" "$2" casdoor-init-script "${PROVISIONED_PW}" \
            2>"${WORK}/fixture.err")"
    [ -n "${SCRIPT}" ] && [ -f "${SCRIPT}" ] && return 0
    bad "casdoor-init-script could not be staged for execution: $(tail -1 "${WORK}/fixture.err")"
    return 1
}

run_script() { # (uses SCRIPT/SECRETS/SEED); output -> ${WORK}/out, status -> ${RC}
    CASDOOR_URL="http://127.0.0.1:$(cat "${WORK}/port")" \
    CASDOOR_SECRETS_DIR="${SECRETS}" CASDOOR_INIT_DATA="${SEED}" \
        timeout 120 python3 "${SCRIPT}" >"${WORK}/out" 2>&1
    RC=$?
    cat "${WORK}/out" >>"${WORK}/sweep"
    return 0
}

# The outcome of the LAST login of the run. casdoor clears signin_wrong_times on
# a successful sign-in, so a run that ends on a success leaves the shared budget
# where it found it and a run that ends on a wrong attempt leaves it one notch
# closer to a ban — which, across ArgoCD's re-syncs of a CONVERGED cluster, is
# how a healthy deployment would drift into the lockout all by itself.
last_login() {
    grep -a '"path": "/api/login"' "${WORK}/journal" 2>/dev/null \
        | tail -1 | sed -n 's/.*"result": "\([a-z]*\)".*/\1/p'
}

# Login attempts by OUTCOME, straight out of the stub's journal.
logins() { # <ok|wrong|locked|any>
    local want="$1"
    local n
    if [ "${want}" = "any" ]; then
        n="$(grep -ac '"path": "/api/login"' "${WORK}/journal" 2>/dev/null)" || n=0
    else
        n="$(grep -ac "\"result\": \"${want}\"" "${WORK}/journal" 2>/dev/null)" || n=0
    fi
    echo "${n:-0}"
}

# The line the failure used to print, and the thing it must never print about an
# account that is merely banned: it sends the operator to rotate a correct secret.
MISDIRECTION="reconcile secret/"

stage_fixture "${CLUSTER}" "${WORK}/fx" || true

# (3a) The live shape: a SIBLING Job banned the account before this one got a turn.
if [ -n "${SCRIPT}" ] && stub_up lockout "${CASDOOR_DEFAULT_PW}" 0; then
    run_script
    [ "${RC}" -eq 75 ] \
        && ok "(3a) an account a sibling already banned -> exit 75, the status the Job's podFailurePolicy stops on (not a retry)" \
        || bad "(3a) exit ${RC}, expected 75 — the pod backoff will replay this login into the ban"
    grep -aq "too many times" "${WORK}/out" \
        && ok "(3a) the failure quotes casdoor's own throttle text instead of guessing at the cause" \
        || bad "(3a) the output never mentions the throttle: $(grep -am1 FAIL "${WORK}/out")"
    grep -aq "${MISDIRECTION}" "${WORK}/out" \
        && bad "(3a) still tells the operator to rotate the Vault secret for an account that is merely banned" \
        || ok "(3a) does NOT tell the operator to rotate a secret that is correct"
    [ "$(logins any)" -eq 1 ] \
        && ok "(3a) made exactly ONE login attempt — the latch stops the second, so a banned account is not kept hot" \
        || bad "(3a) made $(logins any) login attempts against a banned account; one is all that can be learned"
fi

# (3b) The fresh-cluster shape, exactly as it played out: the provisioned password
#      is wrong (the admin still holds casdoor's default) and THAT attempt trips a
#      throttle a sibling had already loaded, so the CORRECT "123" is refused.
if [ -n "${SCRIPT}" ] && stub_up lockout "${CASDOOR_DEFAULT_PW}" 1; then
    run_script
    [ "${RC}" -eq 75 ] \
        && ok "(3b) the live failure replayed: wrong-then-banned -> exit 75" \
        || bad "(3b) exit ${RC}, expected 75"
    [ "$(logins locked)" -ge 1 ] \
        && ok "(3b) the ban was actually reached (the scenario is not vacuous)" \
        || bad "(3b) no login was refused by the throttle — the scenario never exercised it"
    [ "$(logins any)" -eq 2 ] \
        && ok "(3b) spent exactly two attempts: the wrong one, then the one that discovered the ban" \
        || bad "(3b) spent $(logins any) attempts, expected 2 — the per-run budget is not being held"
    grep -aq "${MISDIRECTION}" "${WORK}/out" \
        && bad "(3b) blames the Vault secret for a lockout, which is the #396 misdiagnosis verbatim" \
        || ok "(3b) does not blame the Vault secret"
fi

# (3c) A fresh cluster with NO throttle: the takeover must still work, and the
#      wrong-attempt spend is pinned. Two is the whole budget this script has.
if [ -n "${SCRIPT}" ] && stub_up ok "${CASDOOR_DEFAULT_PW}" 99; then
    run_script
    [ "${RC}" -eq 0 ] \
        && ok "(3c) a fresh cluster still converges — the lockout handling did not break the takeover" \
        || bad "(3c) exit ${RC} on a healthy fresh cluster: $(grep -am1 FAIL "${WORK}/out")"
    [ "$(logins wrong)" -le 2 ] \
        && ok "(3c) fresh-cluster spend is $(logins wrong) wrong attempt(s), within the 2 the docstring claims" \
        || bad "(3c) fresh-cluster spend is $(logins wrong) wrong attempts — more than one Job's share of casdoor's budget"
    [ "$(last_login)" = "ok" ] \
        && ok "(3c) the run ends on a SUCCESSFUL login, so casdoor's wrong-attempt counter is left reset" \
        || bad "(3c) the run ends on a '$(last_login)' login — it leaves casdoor's counter loaded for the next Job"
fi

# (3d) The converged cluster — the path EVERY ArgoCD re-sync takes, for as long as
#      the cluster lives. It is not free and must not be asserted to be: the run
#      deliberately spends one wrong attempt proving casdoor's public default no
#      longer logs in, which is the check that caught a live IdP still answering
#      {"status":"ok"} to admin/123. What must hold is that the run does not LEAVE
#      the counter loaded — it ends on a success, which clears it. Without that,
#      re-syncs alone would walk a healthy cluster into a ban.
if [ -n "${SCRIPT}" ] && stub_up ok "${PROVISIONED_PW}" 99; then
    run_script
    [ "${RC}" -eq 0 ] \
        && ok "(3d) a converged cluster re-runs clean" \
        || bad "(3d) exit ${RC} on a converged cluster: $(grep -am1 FAIL "${WORK}/out")"
    [ "$(logins wrong)" -eq 1 ] \
        && ok "(3d) a converged re-sync spends exactly one wrong attempt — the deliberate proof that casdoor's public default no longer logs in" \
        || bad "(3d) a converged re-sync spends $(logins wrong) wrong attempt(s), expected exactly 1 (0 would mean the default-password proof stopped running; more would accumulate across re-syncs)"
    [ "$(last_login)" = "ok" ] \
        && ok "(3d) and it ends on a SUCCESSFUL login, which clears casdoor's counter — re-syncs cannot accumulate a ban" \
        || bad "(3d) the run ends on a '$(last_login)' login, leaving casdoor's wrong-attempt counter loaded on every re-sync"
fi

echo
echo "== 4. negative controls — layer 3 must catch the bug it exists for =="

# (4a) The pre-fix try_login(): the envelope message is discarded, so the throttle
#      is indistinguishable from a wrong password and the run reports the wrong
#      cause. This is the exact code that shipped before #396.
CTL="${WORK}/nc-prefix"
stage_tree "${CTL}"
if mutate "pre-fix try_login discards casdoor's message" "${CTL}/manifests/casdoor/init-job.yaml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace('''        if LOCKED_OUT:
            return False
        cj.clear()''', '''        cj.clear()''', 1)
s = s.replace('''        except CasdoorError as e:
            if LOCKOUT_MARKER in getattr(e, "msg", ""):
                LOCKED_OUT.append(e.msg)
            return False
        return require_admin_session()''', '''        except CasdoorError:
            return False
        return require_admin_session()''', 1)
open(p, 'w').write(s)
PY
then
    if stage_fixture "${CTL}" "${WORK}/fx-prefix" && stub_up lockout "${CASDOOR_DEFAULT_PW}" 1; then
        run_script
        if [ "${RC}" -ne 75 ] && grep -aq "${MISDIRECTION}" "${WORK}/out"; then
            ok "(4a) control [pre-fix try_login]: caught — the regressed copy exits ${RC} telling the operator to rotate a correct secret, which is exactly what (3b) scores as a FAIL"
        else
            bad "(4a) control [pre-fix try_login]: SURVIVED — exit ${RC}, misdirection=$(grep -acq "${MISDIRECTION}" "${WORK}/out" && echo yes || echo no); (3b) would not have caught #396"
        fi
    fi
fi

# (4b) The marker blinded. Proves the classification is matched against casdoor's
#      REAL text (the stub answers verbatim) and not against a convenient string.
CTL2="${WORK}/nc-marker"
stage_tree "${CTL2}"
if mutate "LOCKOUT_MARKER no longer matches casdoor's text" "${CTL2}/manifests/casdoor/init-job.yaml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s = s.replace('    LOCKOUT_MARKER = "too many times"',
              '    LOCKOUT_MARKER = "a phrase casdoor never sends"', 1)
open(p, 'w').write(s)
PY
then
    if stage_fixture "${CTL2}" "${WORK}/fx-marker" && stub_up lockout "${CASDOOR_DEFAULT_PW}" 1; then
        run_script
        if [ "${RC}" -ne 75 ]; then
            ok "(4b) control [blinded marker]: caught — exit ${RC}, so the marker really is matched against the text casdoor sends"
        else
            bad "(4b) control [blinded marker]: SURVIVED — still exited 75 with a marker casdoor never sends, so (3a)/(3b) pass on nothing"
        fi
    fi
fi
stub_down

echo
echo "== 5. secret sweep — no password may reach stdout/stderr on any path =="
if [ -s "${WORK}/sweep" ]; then
    LEAK=0
    grep -aq "${PROVISIONED_PW}" "${WORK}/sweep" && LEAK=1
    if [ "${LEAK}" -eq 0 ]; then
        ok "(5) $(wc -l <"${WORK}/sweep") captured output line(s) across every scenario, no password among them"
    else
        bad "(5) the provisioned password reached the output"
    fi
else
    bad "(5) nothing was captured — no scenario ran, so the sweep is vacuous"
fi

echo
echo "== casdoor login budget: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ] || exit 1
