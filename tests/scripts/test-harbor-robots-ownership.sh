#!/usr/bin/env bash
# test-harbor-robots-ownership.sh — `secret/<brand>/harbor-robots` has ONE owner,
# and it is not this generator.
#
# THE BUG THIS EXISTS TO KILL
# ---------------------------
# Two writers, no agreement about who owns the path.
#
#   THE OWNER. specs/cluster/manifests/harbor/harbor-provision-job.yaml mints
#   Harbor's pull-only and push-only robot accounts and writes their secrets to
#   secret/<brand>/harbor-robots. It is the ONLY thing that can: "a Harbor robot
#   account's secret is returned EXACTLY ONCE at creation time and can never be
#   re-read from Harbor afterwards ... this Job must capture the secret the
#   moment Harbor mints it and WRITE it INTO Vault itself". Its write is a
#   read-merge-write (vault_put_merge), so the pull robot never disturbs the
#   push robot's keys.
#
#   THE INTRUDER. scripts/gen-cluster-secrets.sh did an UNCONDITIONAL
#       vault kv put "${VAULT_KV_MOUNT}/${BASE}/harbor-robots" \
#           pull_name="${GITLAB_REGISTRY_USER}" \
#           pull_secret="${GITLAB_REGISTRY_TOKEN}" \
#           push_name="${IMAGE_BUILDER_REGISTRY_USER}" \
#           push_secret="${IMAGE_BUILDER_REGISTRY_TOKEN}"
#   of two literal placeholder defaults (REPLACE_WITH_GITLAB_DEPLOY_TOKEN,
#   REPLACE_WITH_GITLAB_WRITE_REGISTRY_DEPLOY_TOKEN). KV v2 `put` REPLACES the
#   whole document.
#
# The seeder's own comment conceded the conflict and got the direction backwards
# — it said a later Job run would overwrite the seeder. It cannot: the Job's
# idempotency is keyed on HARBOR ("if a robot with the expected name already
# exists, SKIP creating it"), not on Vault. So the LAST writer wins, the last
# writer is whoever ran the seeder most recently, and the damage is permanent:
# four real robot credentials replaced by placeholder strings, the `project` key
# the seeder does not know about deleted outright, and no repair path short of
# deleting the robots in Harbor by hand.
#
# The failure mode is silent all the way down. ESO resolves the placeholder
# happily, renders a syntactically perfect kubernetes.io/dockerconfigjson into
# all five namespaces (four `harbor-registry`, one `hugmesh-registry-pull`, plus
# `image-builder-registry`), and reports SecretSynced. Nothing is wrong until a
# pull 401s — and in the kind lane nothing ever pulls, because
# scripts/kind-load-images.sh side-loads every first-party image (see
# docs/KIND-SSO-E2E-FINDINGS.md #17). That is how a dead credential survived.
#
# THE INVARIANT
# -------------
# A writer that CANNOT REPAIR must be the ONLY writer; every other writer merges
# or stays out. Asserted of BOTH sides here — the seeder must not replace the
# Job's document, and the Job must not replace anybody else's keys either.
#
# HOW IT IS ASSERTED: BEHAVIOUR, NOT TEXT
# ---------------------------------------
# Nothing here greps for `kv put`. This suite builds a FAKE VAULT that implements
# KV v2 for real — `put` replaces the document, `patch` merges into it, `patch`
# on a path with no document fails exactly as the CLI does — pre-loads it with
# the document harbor-provision leaves behind, EXECUTES the real
# gen-cluster-secrets.sh against it, and compares the document afterwards. The
# Job's own reconcile.py is extracted from its ConfigMap and EXECUTED against an
# in-process fake Harbor + fake Vault HTTP API.
#
# HOW IT CANNOT GO VACUOUSLY GREEN
#   * [harness] runs FIRST and proves the fake `put` really does destroy keys —
#     otherwise "the document survived" is a property of the harness;
#   * [ran] fails a run that never reached the seeder's ONLINE branch, because a
#     seeder that writes nothing cannot clobber anything;
#   * [override-live] fails a seeder whose escape hatch silently does nothing —
#     the same "writes nothing" hole from the other side;
#   * [path-live] fails if no ExternalSecret reads the document any more, so the
#     gate cannot end up guarding something nothing consumes;
#   * [patch-denied] closes the fallback door: `kv patch || kv put` reads as
#     "merge, or create if absent" and is not — a patch is also refused when the
#     token lacks the `patch` capability, and the fallback would then replace a
#     document that was there all along. Same clobber, error path. [probe-denied]
#     closes the twin: "the existence read failed" is not "there is nothing
#     there";
#   * the whole analysis is re-run against TEN deliberately-broken staged
#     copies — including the EXACT pre-fix seeder and a sabotaged fake Vault —
#     and every one must bite, naming its check.
#
# A MISSING TOOL IS A HARD FAILURE, never a skip — see tests/lib/guard-preflight.sh.
# Needs: bash, python3 + PyYAML, openssl (the seeder mints with it). No cluster,
# no vault binary, no Harbor, no docker, no network.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
# shellcheck source=../lib/guard-preflight.sh
. "${HERE}/../lib/guard-preflight.sh"

SEEDER="${REPO}/scripts/gen-cluster-secrets.sh"
JOB="${REPO}/specs/cluster/manifests/harbor/harbor-provision-job.yaml"
CLUSTER="${REPO}/specs/cluster"
ANALYSER="${HERE}/harbor_robots_ownership.py"

echo "== harbor-robots ownership: the seeder may not overwrite a path the provision Job owns =="

guard_require_tools python3 openssl
python3 -c 'import yaml' >/dev/null 2>&1 \
  || guard_require_capability "python3 has no PyYAML (the provision Job's ConfigMap cannot be parsed)"

for f in "${SEEDER}" "${JOB}" "${ANALYSER}"; do
    [ -f "${f}" ] || { echo "  FAIL missing input: ${f}"; exit 1; }
done
[ -d "${CLUSTER}" ] || { echo "  FAIL missing specs/cluster: ${CLUSTER}"; exit 1; }

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# ─────────────────────────────────────────────────────────────────────────────
# THE FAKE VAULT. A real KV v2, not a recorder: `put` REPLACES the document,
# `patch` MERGES into it and fails when there is nothing to merge into. The
# seeder finds it through PATH exactly as it would find the real CLI (it takes
# its online branch on `command -v vault` + VAULT_ADDR/VAULT_TOKEN), so what is
# measured is what the script really invokes — including anything built up in an
# array or emitted from a conditional branch, which no static read could tell.
# ─────────────────────────────────────────────────────────────────────────────
mkdir -p "${WORK}/bin"
cat > "${WORK}/bin/vault" <<'STUB'
#!/usr/bin/env python3
import json, os, sys

argv = sys.argv[1:]
store = os.environ["FAKE_VAULT_STORE"]
with open(os.environ["FAKE_VAULT_LOG"], "a", encoding="utf-8") as fh:
    fh.write(json.dumps(argv) + "\n")


def docfile(path):
    return os.path.join(store, path.replace("/", "%2F") + ".json")


if len(argv) >= 3 and argv[0] == "kv" and argv[1] in ("put", "patch"):
    path = argv[2]
    kvs = dict(a.split("=", 1) for a in argv[3:] if "=" in a)
    f = docfile(path)
    # A Vault token without the `patch` capability on the path: the CLI refuses
    # the HTTP PATCH even though the document is perfectly present. Modelled
    # because a `patch || put` fallback turns exactly this into a clobber.
    if argv[1] == "patch" and os.environ.get("FAKE_VAULT_DENY_PATCH") == "1":
        sys.stderr.write("Error patching %s: permission denied\n" % path)
        sys.exit(2)
    if argv[1] == "put":
        doc = kvs                      # KV v2 put: the new document IS the args
    else:
        if not os.path.exists(f):      # the real CLI cannot patch a missing doc
            sys.stderr.write("No value found at %s\n" % path)
            sys.exit(2)
        with open(f, encoding="utf-8") as fh:
            doc = json.load(fh)
        doc.update(kvs)                # KV v2 patch: merge
    os.makedirs(store, exist_ok=True)
    with open(f, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, sort_keys=True)
    sys.exit(0)

if len(argv) >= 3 and argv[0] == "kv" and argv[1] == "get":
    f = docfile(argv[-1])
    # A token with update but no READ on the path — an ordinary Vault policy.
    # "The read failed" must never be mistaken for "there is nothing there".
    if os.environ.get("FAKE_VAULT_DENY_GET") == "1":
        sys.stderr.write("Error reading %s: permission denied\n" % argv[-1])
        sys.exit(2)
    if not os.path.exists(f):
        sys.stderr.write("No value found at %s\n" % argv[-1])
        sys.exit(2)
    with open(f, encoding="utf-8") as fh:
        print(json.dumps({"data": {"data": json.load(fh)}}))
    sys.exit(0)

sys.exit(0)
STUB
chmod +x "${WORK}/bin/vault"

# A SABOTAGED copy of that stub, used by control (n7): its `put` merges instead
# of replacing. Every "the document survived" assertion would then hold no
# matter what the seeder does — which is precisely what [harness] must catch.
mkdir -p "${WORK}/bin-lying"
sed 's|^        doc = kvs  |        doc = dict(json.load(open(f, encoding="utf-8"))) if os.path.exists(f) else {}; doc.update(kvs)  |' \
    "${WORK}/bin/vault" > "${WORK}/bin-lying/vault"
chmod +x "${WORK}/bin-lying/vault"
if ! grep -q 'doc.update(kvs)  ' "${WORK}/bin-lying/vault"; then
    bad "(setup) could not build the sabotaged stub for control (n7) — the anchor moved"
fi

run_analyser() { # run_analyser <seeder> <job> <specs/cluster> <stubdir> <workdir>
    python3 "${ANALYSER}" "$1" "$2" "$3" "$4" "$5" 2>&1
}

# ── POSITIVE: the repo's own tree ────────────────────────────────────────────
echo
echo "-- positive: both writers respect the document --"
OUT="$(run_analyser "${SEEDER}" "${JOB}" "${CLUSTER}" "${WORK}/bin" "${WORK}/pos")"; RC=$?
sed 's/^/    /' <<<"${OUT}"
if [ "${RC}" -eq 0 ]; then
    ok "(a) the tree satisfies the ownership invariant"
else
    bad "(a) the tree does NOT satisfy the ownership invariant (see above)"
fi

# ── NEGATIVE CONTROLS ────────────────────────────────────────────────────────
# Each stages a copy of one input, injects ONE defect, and requires the matching
# check to bite. An injection that cannot find its anchor is itself a FAILURE,
# so a control can never quietly stop testing anything.
echo
echo "-- negative controls: each injected defect must be caught, by check --"

# The injectors live in FILES, written through QUOTED heredocs. Every anchor
# below is a literal shell-variable reference (`${VAULT_KV_MOUNT}`,
# `${#HARBOR_ROBOT_OVERRIDE[@]}`); an inline snippet would have those expanded by
# THIS shell before python ever saw them, and under `set -u` the control would
# die on an unbound variable instead of testing anything.
INJ="${WORK}/inject"; mkdir -p "${INJ}"

# (n1) THE SHIPPED DEFECT, exactly: restore the placeholder defaults and the
# unconditional `vault kv put` of all four keys that origin/main carried.
cat > "${INJ}/n1-prefix-seeder.py" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
before = s
s = s.replace('GITLAB_REGISTRY_TOKEN="${GITLAB_REGISTRY_TOKEN:-}"',
              'GITLAB_REGISTRY_TOKEN="${GITLAB_REGISTRY_TOKEN:-REPLACE_WITH_GITLAB_DEPLOY_TOKEN}"', 1)
s = s.replace('IMAGE_BUILDER_REGISTRY_TOKEN="${IMAGE_BUILDER_REGISTRY_TOKEN:-}"',
              'IMAGE_BUILDER_REGISTRY_TOKEN="${IMAGE_BUILDER_REGISTRY_TOKEN:-REPLACE_WITH_GITLAB_WRITE_REGISTRY_DEPLOY_TOKEN}"', 1)
assert s != before, "the empty-default anchors are gone"
m = re.search(r"\n        HARBOR_ROBOT_OVERRIDE=\(\).*?\n        fi\n", s, re.S)
assert m, "the guarded harbor-robots block is gone"
s = s[:m.start()] + (
    '\n        vault kv put "${VAULT_KV_MOUNT}/${BASE}/harbor-robots" \\\n'
    '            pull_name="${GITLAB_REGISTRY_USER}" \\\n'
    '            pull_secret="${GITLAB_REGISTRY_TOKEN}" \\\n'
    '            push_name="${IMAGE_BUILDER_REGISTRY_USER}" \\\n'
    '            push_secret="${IMAGE_BUILDER_REGISTRY_TOKEN}"\n') + s[m.end():]
open(p, "w", encoding="utf-8").write(s)
PY

# (n2) The same defect wearing the CURRENT shape: the path is left alone by
# default, but the escape hatch still uses the destructive verb.
cat > "${INJ}/n2-hatch-puts.py" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
old = '            vault kv patch "${VAULT_KV_MOUNT}/${BASE}/harbor-robots" \\'
assert old in s, "the `kv patch` call is gone"
s = s.replace(old, '            vault kv put "${VAULT_KV_MOUNT}/${BASE}/harbor-robots" \\', 1)
open(p, "w", encoding="utf-8").write(s)
PY

# (n3) THE VACUITY HOLE from the other side: a seeder that never writes the path
# at all trivially satisfies every no-clobber assertion.
cat > "${INJ}/n3-hatch-dead.py" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
old = '        if [ "${#HARBOR_ROBOT_OVERRIDE[@]}" -gt 0 ]; then'
assert old in s, "the override branch is gone"
s = s.replace(old, "        if false; then", 1)
open(p, "w", encoding="utf-8").write(s)
PY

# (n4) THE OTHER VACUITY HOLE: a run that never reaches the online branch writes
# nothing anywhere, so nothing can be clobbered.
cat > "${INJ}/n4-offline.py" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
old = "    if command -v vault >/dev/null; then"
assert old in s, "the online-branch guard is gone"
s = s.replace(old, "    if command -v vault-that-does-not-exist >/dev/null; then", 1)
open(p, "w", encoding="utf-8").write(s)
PY

# (n5) THE OWNER TURNING INTO A CLOBBERER: harbor-provision writes through
# vault_put_merge() precisely so minting one robot does not delete the other.
cat > "${INJ}/n5-job-replaces.py" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
old = "        current = vault_get(path)"
assert old in s, "vault_put_merge no longer reads before writing"
s = s.replace(old, "        current = {}", 1)
open(p, "w", encoding="utf-8").write(s)
PY

# (n6) A Job that re-mints on every sync. Harbor cannot re-reveal an existing
# robot's secret, so a re-run that writes ANYTHING writes a value no registry
# will accept — over the one that worked.
cat > "${INJ}/n6-job-rewrites.py" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
old = "        if full_name in existing_robot_names():"
assert old in s, "the already-exists skip is gone"
s = s.replace(old, "        if False:", 1)
open(p, "w", encoding="utf-8").write(s)
PY

# (n9) THE FALLBACK CLOBBER: `kv patch || kv put` reads as "merge, or create if
# absent" and is not — a patch is also refused when the token lacks the `patch`
# capability, and the fallback then REPLACES a document that was there all along.
cat > "${INJ}/n9-patch-or-put.py" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
m = re.search(r"\n            if _hr_probe=.*?\n            fi\n", s, re.S)
assert m, "the exists-then-choose-verb block is gone"
s = s[:m.start()] + (
    '\n            vault kv patch "${VAULT_KV_MOUNT}/${BASE}/harbor-robots" \\\n'
    '                "${HARBOR_ROBOT_OVERRIDE[@]}" \\\n'
    '              || vault kv put "${VAULT_KV_MOUNT}/${BASE}/harbor-robots" \\\n'
    '                "${HARBOR_ROBOT_OVERRIDE[@]}"\n') + s[m.end():]
open(p, "w", encoding="utf-8").write(s)
PY

# (n10) THE PROBE HOLE: treating ANY failed existence probe as "absent". A
# token with update but no read on the path is an ordinary Vault policy, and a
# blind `put` on that reading destroys the document.
cat > "${INJ}/n10-probe-blind.py" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
m = re.search(r"\n            elif printf '%s' \"\$\{_hr_probe\}\".*?\n            fi\n", s, re.S)
assert m, "the explicit not-found branch is gone"
s = s[:m.start()] + (
    '\n            else\n'
    '                vault kv put "${VAULT_KV_MOUNT}/${BASE}/harbor-robots" \\\n'
    '                    "${HARBOR_ROBOT_OVERRIDE[@]}"\n'
    '            fi\n') + s[m.end():]
open(p, "w", encoding="utf-8").write(s)
PY

# (n8) The gate must not end up guarding a document nothing reads.
cat > "${INJ}/n8-path-dead.py" <<'PY'
import os, sys
root = sys.argv[1]
n = 0
for dirpath, _d, files in os.walk(root):
    for fn in files:
        if not fn.endswith((".yaml", ".yml")):
            continue
        p = os.path.join(dirpath, fn)
        s = open(p, encoding="utf-8").read()
        if "kind: ExternalSecret" not in s or "harbor-robots" not in s:
            continue
        open(p, "w", encoding="utf-8").write(s.replace("harbor-robots", "harbor-robots-renamed"))
        n += 1
assert n, "no ExternalSecret file referenced harbor-robots to rename"
PY

N=0
expect_catch() { # <label> <check> <target: seeder|job|specs|stub> <injector|->
    local label="$1" want="$2" which="$3" inject="$4"
    N=$((N+1))
    local dir="${WORK}/neg-${N}"
    rm -rf "${dir}"; mkdir -p "${dir}"
    local S="${dir}/gen-cluster-secrets.sh" J="${dir}/harbor-provision-job.yaml"
    local T="${CLUSTER}" B="${WORK}/bin" target=""
    cp "${SEEDER}" "${S}"; cp "${JOB}" "${J}"
    case "${which}" in
        seeder) target="${S}" ;;
        job)    target="${J}" ;;
        specs)  T="${dir}/cluster"; cp -r "${CLUSTER}" "${T}"; target="${T}" ;;
        stub)   B="${WORK}/bin-lying" ;;
        *)      bad "negative control: ${label} (unknown target '${which}')"; return ;;
    esac
    if [ "${inject}" != "-" ]; then
        if ! python3 "${INJ}/${inject}" "${target}"; then
            bad "negative control: ${label} (the injection itself failed — its anchor moved)"
            return
        fi
    fi
    local out rc
    out="$(run_analyser "${S}" "${J}" "${T}" "${B}" "${dir}/work")"; rc=$?
    if [ "${rc}" -ne 0 ] && grep -qF "FAIL ${want}" <<<"${out}"; then
        ok "negative control: ${label} -> caught by ${want}"
    else
        bad "negative control: ${label} NOT caught (rc=${rc}); wanted ${want}. Output:"
        sed 's/^/        /' <<<"${out}" | tail -25
    fi
}

# (n1) THE SHIPPED DEFECT, exactly: restore the unconditional `vault kv put` of
# the two placeholder defaults that origin/main carried.
expect_catch "the shipped defect: an unconditional \`kv put\` of the placeholder defaults" \
    "[no-clobber]" "seeder" "n1-prefix-seeder.py"

expect_catch "an escape hatch that \`kv put\`s instead of merging" \
    "[override-merge]" "seeder" "n2-hatch-puts.py"

expect_catch "an escape hatch that silently does nothing" \
    "[override-live]" "seeder" "n3-hatch-dead.py"

expect_catch "a seeder run that never reaches its ONLINE branch" \
    "[ran]" "seeder" "n4-offline.py"

expect_catch "a provision Job whose Vault write replaces instead of merging" \
    "[job-merge]" "job" "n5-job-replaces.py"

expect_catch "a provision Job that rewrites the credential on every sync" \
    "[job-no-rewrite]" "job" "n6-job-rewrites.py"

# (n7) THE CONTROL ON THE CONTROLS: a fake Vault whose `put` merges. Every
# document-survived assertion above would hold regardless of what the seeder
# does, so [harness] must refuse the run. No injector — the sabotage IS the stub.
expect_catch "a fake Vault whose \`put\` does not replace the document" \
    "[harness]" "stub" "-"

expect_catch "an escape hatch that falls back to \`kv put\` when the merge is refused" \
    "[patch-denied]" "seeder" "n9-patch-or-put.py"

expect_catch "an existence probe that reads any failure as \`absent\`" \
    "[probe-denied]" "seeder" "n10-probe-blind.py"

expect_catch "a tree where no ExternalSecret reads the document any more" \
    "[path-live]" "specs" "n8-path-dead.py"

# ── TOOLING PREFLIGHT: absent tooling is a hard failure, and CI cannot opt out ─
echo
echo "-- tooling preflight: absent tooling is a hard failure, not a silent skip --"
mkdir -p "${WORK}/notools"
for b in bash dirname mktemp sed grep; do
    src="$(command -v "${b}" 2>/dev/null)" && ln -sf "${src}" "${WORK}/notools/${b}"
done
T1_OUT="$(env -u GUARD_TOOLING_ALLOW_SKIP PATH="${WORK}/notools" \
    bash "${BASH_SOURCE[0]}" 2>&1)"; T1_RC=$?
if [ "${T1_RC}" -ne 0 ] && grep -qF "FAIL missing required tool(s)" <<<"${T1_OUT}"; then
    ok "(t1) with python3 absent and no opt-out the guard FAILS (rc=${T1_RC}) instead of exiting 0"
else
    bad "(t1) with python3 absent the guard did not hard-fail (rc=${T1_RC}): ${T1_OUT}"
fi
T2_OUT="$(env GUARD_TOOLING_ALLOW_SKIP=1 PATH="${WORK}/notools" \
    bash "${BASH_SOURCE[0]}" 2>&1)"; T2_RC=$?
if [ "${T2_RC}" -eq 0 ] && grep -qF "GUARD_TOOLING_ALLOW_SKIP=1 was set" <<<"${T2_OUT}"; then
    ok "(t2) GUARD_TOOLING_ALLOW_SKIP=1 is honored as a DELIBERATE local opt-out (rc=0)"
else
    bad "(t2) the explicit opt-out did not work (rc=${T2_RC}): ${T2_OUT}"
fi
# tests/scripts/test-guard-integrity.sh already fails the build if
# GUARD_TOOLING_ALLOW_SKIP appears anywhere in .gitlab-ci.yml; assert the other
# half here — that a CI job really runs THIS file, so the fail-closed preflight
# is on a path CI takes.
CI_FILE="${REPO}/.gitlab-ci.yml"
if [ ! -f "${CI_FILE}" ]; then
    bad "(t3) ${CI_FILE} not found — cannot prove this guard is wired"
elif ! grep -qF "tests/scripts/test-harbor-robots-ownership.sh" "${CI_FILE}"; then
    bad "(t3) no .gitlab-ci.yml job runs tests/scripts/test-harbor-robots-ownership.sh — the guard is not wired in"
elif grep -qF "GUARD_TOOLING_ALLOW_SKIP" "${CI_FILE}"; then
    bad "(t3) .gitlab-ci.yml mentions GUARD_TOOLING_ALLOW_SKIP — CI could skip this guard silently"
else
    ok "(t3) .gitlab-ci.yml runs this guard and never sets GUARD_TOOLING_ALLOW_SKIP"
fi

echo
echo "== harbor-robots ownership: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
