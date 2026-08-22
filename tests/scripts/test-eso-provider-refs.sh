#!/usr/bin/env bash
# test-eso-provider-refs.sh — every Secret/ConfigMap an ESO provider block names
# must actually be created, by the SAME delivery path that bootstraps the
# cluster, in the namespace ESO will look in. Pure bash + python3 + PyYAML; no
# cluster, no kubectl, no vault, no network.
#
# WHY THIS EXISTS
# ---------------
# All 29 VaultDynamicSecret generators under specs/cluster declared
#
#     provider:
#       caProvider: { type: Secret, name: vault-ca, key: ca.crt }
#       auth: { tokenSecretRef: { name: vault-token, key: token } }
#
# and on a kind cluster NOTHING created either Secret in any of the three
# generator namespaces. Real ESO controller log, kind cluster, 2026-08-06:
#
#   could not generate [0]: unable to setup Vault client: failed to get cert
#   from secret: failed to resolve secret key ref: cannot get Kubernetes secret
#   "vault-ca": secrets "vault-ca" not found
#
# 26 ExternalSecrets sat in SecretSyncedError, no *-mtls Secret was ever created,
# and every pod mounting one hung in Init:0/1 on
# `MountVolume.SetUp failed for volume "pki"`. Both gateways, every BFF, every DB
# TLS sidecar, harbor and coturn. Not one mTLS certificate had ever been issued
# in the cluster — the entire mTLS wave was dead on arrival, and had been since
# the generators were written.
#
# tests/scripts/test-eso-seed-contract.sh could not see this: it checks the KV
# `data`/`dataFrom` remoteRefs against the seeder, and contains no reference to
# caProvider, tokenSecretRef or generatorRef at all. The provider block — how ESO
# authenticates and who it trusts — was unguarded.
#
# THE INVARIANT, AND WHY IT IS PER DELIVERY PATH
# ---------------------------------------------
# The naive form of this check ("something in the repo creates vault-ca") PASSES
# on the broken tree: specs/etc/keys-provision/provision.sh created both Secrets
# in all three namespaces for the USB/real-node path. What failed is that the
# kind path never did. So coverage is computed ONCE PER PATH and a reference
# satisfied on one path but missing on another is a failure naming the path.
# That is the property that was actually violated, and the reason this gate is
# not a restatement of the bug it was written for.
#
# Namespace matching is strict, because ESO's is: generators are resolved with
# resolvers.EmptyStoreKind, whose own upstream doc comment reads "The
# EmptyStoreKind is not cluster-scoped, hence resources cannot be resolved across
# namespaces", and pkg/utils/resolvers/secret_ref.go only honours a
# cross-namespace ref.Namespace for a ClusterSecretStore. Keys are matched too:
# a Secret that exists under the wrong key is the same outage with a new message.
#
# Layout follows tests/scripts/test-pki-role-san-coverage.sh: a positive run over
# the repo's own tree, then NEGATIVE CONTROLS — each defect class planted into a
# synthesised tree, each of which MUST bite — plus a vacuity control, because a
# gate that passes when it found nothing is worse than no gate.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKER="${HERE}/eso_provider_refs.py"

# Missing tooling is a FAILURE, never a green skip.
. "${HERE}/../lib/guard-preflight.sh"
guard_require_tools python3
python3 -c 'import yaml' 2>/dev/null || \
    guard_require_capability "python3 cannot import PyYAML (pip install pyyaml)"
[ -f "${CHECKER}" ] || { echo "  FAIL missing checker: ${CHECKER}"; exit 1; }

RC=0
fail() { echo "  FAIL $*"; RC=1; }
ok()   { echo "  ok   $*"; }

echo "== ESO provider reference gate (caProvider / tokenSecretRef) =="

# ── (1) THE REPO ITSELF ──────────────────────────────────────────────────────
echo
echo "-- 1) the repo's own tree --"
if python3 "${CHECKER}" "${REPO}"; then
    ok "no dangling ESO provider references"
else
    fail "the repo has dangling ESO provider references (see above)"
fi

# ── synthetic-tree helpers ───────────────────────────────────────────────────
# Every control builds a COMPLETE miniature repo: two delivery-path scripts and
# a manifest tree. Building them from scratch (rather than mutating a copy of
# the real repo) keeps each control's defect the only thing under test.
STAGE_ROOT="$(mktemp -d)"
trap 'rm -rf "${STAGE_ROOT}"' EXIT

# mk_tree <dir> <ca-secret-name> <ca-key> <kind-ca-mode> <kind-creates-token>
#
# kind-ca-mode says HOW the kind path provisions vault-ca, which is the axis the
# reachability controls turn on:
#   yes         unconditionally, in a for-loop over a literal namespace list
#   no          not at all
#   dead        inside `if false; then … fi` — present in the file, never runs
#   cond        only inside the `else` of a runtime test
#   cond-ann    ditto, carrying an `eso-provider-refs: conditional-ok <reason>`
#   cond-bare   ditto, carrying the annotation with NO reason
#   dead-ann    `if false` AND annotated — dead code may not be annotated away
#
# and the five SHORT-CIRCUIT / EARLY-OUT modes (§4b). Each is a rewrite of the
# same seeding statement that is `bash -n` clean, leaves the statement textually
# intact, and was credited as unconditional by the keyword-only reachability
# model — i.e. each is a way the real regression would actually get written:
#   sc-and      [ "${SEED_GENERATOR_CREDS:-0}" = "1" ] && { … }   opt-in gate
#   sc-cont     [ "${OPT_IN_SEED:-0}" = "1" ] || continue         loop early-out
#   sc-false    false && { … }                                     kill switch
#   fn-return   seed() { return 0; … } + a REAL call site          early return
#   sc-ret0     seed() { [ … ] || return 0; … } + a REAL call site guard clause
#   pre-exit    exit 0 immediately above the block                 early exit
#
# Every gated block also carries `brace_noise` — a `cmd || { echo …; exit 1; }`
# and a self-contained `{ echo …; }` — because the real step 8b does, and a
# control whose gated block has no braces in it cannot see a parser that pops
# the gate on the first bare `}`.
#
# and the two ERROR-HANDLING modes, which must stay GREEN — the whole point of
# drawing the line where it is drawn:
#   err-die     kubectl … || { echo …; exit 1; }   after the seeding statement
#   err-true    x="$(kubectl … )" || true          before the seeding statement
mk_tree() {
    local d="$1" caname="$2" cakey="$3" kindca="$4" kindtok="$5"
    mkdir -p "${d}/specs/cluster/manifests" \
             "${d}/specs/cluster/bootstrap/kind-local" \
             "${d}/specs/etc/keys-provision"

    cat > "${d}/specs/cluster/manifests/gen.yaml" <<YAML
apiVersion: generators.external-secrets.io/v1alpha1
kind: VaultDynamicSecret
metadata: { name: demo-mtls, namespace: hugmesh-backend }
spec:
  path: pki_int/issue/demo
  provider:
    server: https://vault.vault.svc.cluster.local:8200
    caProvider: { type: Secret, name: ${caname}, key: ${cakey} }
    auth:
      tokenSecretRef: { name: vault-token, key: token }
YAML

    # Two lines of ORDINARY ERROR HANDLING, copied in shape from
    # bootstrap-kind.sh:604, prepended to every gated block below. They exist
    # because a `{ … }` that opens and closes on one line used to pop the frame
    # of the group it sits INSIDE: with them absent the `sc-and`/`sc-false`
    # controls passed for three rounds while the gate they claim to test was
    # cancelled by exactly this idiom in the real file. A control whose gated
    # block is simpler than production is not a control.
    local brace_noise
    brace_noise=$(cat <<'INNER'
  [ -n "${ns}" ] || { echo "empty namespace" >&2; exit 1; }
  { echo "  seeding ${ns}"; }
INNER
)

    # The vault-ca provisioning statement, reused verbatim by every mode so the
    # ONLY difference between controls is the control flow around it.
    local ca_stmt
    ca_stmt=$(cat <<'INNER'
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: vault-ca
  namespace: ${ns}
type: Opaque
data:
  ca.crt: AAAA
EOF
INNER
)

    # kind path. Opens with the same path-variable idiom the real bootstrap uses,
    # so `kubectl apply -f "${CLUSTER_DIR}/manifests"` resolves and the manifest
    # tree is genuinely attributed to THIS path.
    {
        echo '#!/usr/bin/env bash'
        echo 'SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"'
        echo 'CLUSTER_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"'
        echo 'kubectl apply -f "${CLUSTER_DIR}/manifests"'
        echo 'GEN_NAMESPACES="hugmesh-backend"'
        echo 'for ns in ${GEN_NAMESPACES}; do'
        case "${kindca}" in
          yes)       printf '%s\n' "${ca_stmt}" ;;
          no)        ;;
          dead)      echo '  if false; then'; printf '%s\n' "${ca_stmt}"; echo '  fi' ;;
          dead-ann)  echo '  if false; then'
                     echo '    # eso-provider-refs: conditional-ok this reason is long enough to pass the length check but the branch is still unreachable'
                     printf '%s\n' "${ca_stmt}"; echo '  fi' ;;
          cond)      echo '  if kubectl -n "${ns}" get secret something-else >/dev/null 2>&1; then'
                     echo '    :'
                     echo '  else'; printf '%s\n' "${ca_stmt}"; echo '  fi' ;;
          cond-ann)  echo '  if kubectl -n "${ns}" get secret something-else >/dev/null 2>&1; then'
                     echo '    :'
                     echo '  else'
                     echo '    # eso-provider-refs: conditional-ok deliberate: the offline branch materializes it from custody media instead, documented in the runbook'
                     printf '%s\n' "${ca_stmt}"; echo '  fi' ;;
          cond-bare) echo '  if kubectl -n "${ns}" get secret something-else >/dev/null 2>&1; then'
                     echo '    :'
                     echo '  else'
                     echo '    # eso-provider-refs: conditional-ok'
                     printf '%s\n' "${ca_stmt}"; echo '  fi' ;;
          # ── short-circuit / early-out rewrites (§4b) ──
          sc-and)    echo '  [ "${SEED_GENERATOR_CREDS:-0}" = "1" ] && {'
                     printf '%s\n' "${brace_noise}"
                     printf '%s\n' "${ca_stmt}"
                     echo '  }' ;;
          sc-cont)   echo '  [ "${OPT_IN_SEED:-0}" = "1" ] || continue'
                     printf '%s\n' "${brace_noise}"
                     printf '%s\n' "${ca_stmt}" ;;
          sc-false)  echo '  false && {'
                     printf '%s\n' "${brace_noise}"
                     printf '%s\n' "${ca_stmt}"
                     echo '  }' ;;
          fn-return|pre-exit|sc-ret0) : ;;  # emitted at top level, after the loop
          # ── error handling, which must NOT be read as a gate ──
          err-die)   echo '  kubectl -n "${ns}" get serviceaccount default >/dev/null 2>&1 || { echo "namespace ${ns} is not usable" >&2; exit 1; }'
                     printf '%s\n' "${ca_stmt}" ;;
          err-true)  echo '  PRIOR="$(kubectl -n "${ns}" get secret cluster-ca -o name 2>/dev/null)" || true'
                     printf '%s\n' "${ca_stmt}" ;;
          err-lhs)   echo '  kubectl -n "${ns}" create secret generic vault-ca --from-literal=ca.crt=x || echo "vault-ca already present"' ;;
        esac
        [ "${kindtok}" = "yes" ] && \
            echo '  kubectl -n "${ns}" create secret generic vault-token --from-literal=token=x'
        echo 'done'
        case "${kindca}" in
          fn-return) echo 'seed_generator_credentials() {'
                     echo '  return 0'
                     echo '  for ns in ${GEN_NAMESPACES}; do'
                     printf '%s\n' "${brace_noise}"
                     printf '%s\n' "${ca_stmt}"
                     echo '  done'
                     echo '}'
                     echo 'seed_generator_credentials' ;;
          # `[ … ] || return 0` — `|| continue` in the spelling the block takes
          # the moment it is wrapped in a function. Same idiom, same effect
          # (skip the work, report success), and it must go red for the same
          # reason. The function IS called, so this is not the uncalled-function
          # rule wearing a disguise.
          sc-ret0)   echo 'seed_generator_credentials() {'
                     echo '  [ "${SEED_GENERATOR_CREDS:-0}" = "1" ] || return 0'
                     echo '  for ns in ${GEN_NAMESPACES}; do'
                     printf '%s\n' "${brace_noise}"
                     printf '%s\n' "${ca_stmt}"
                     echo '  done'
                     echo '}'
                     echo 'seed_generator_credentials' ;;
          pre-exit)  echo 'exit 0'
                     echo 'for ns in ${GEN_NAMESPACES}; do'
                     printf '%s\n' "${brace_noise}"
                     printf '%s\n' "${ca_stmt}"
                     echo 'done' ;;
        esac
    } > "${d}/specs/cluster/bootstrap/kind-local/bootstrap-kind.sh"

    # USB path — always complete, so a one-path gap is visible as a one-path gap
    {
        echo '#!/usr/bin/env bash'
        echo 'for ca_ns in hugmesh-backend; do'
        echo '  kubectl create secret generic vault-ca -n "${ca_ns}" --from-file=ca.crt=/k/ca.crt'
        echo '  kubectl create secret generic vault-token -n "${ca_ns}" --from-literal=token=x'
        echo 'done'
    } > "${d}/specs/etc/keys-provision/provision.sh"
}

# expect_red <label> <dir> [substring the finding must contain]
expect_red() {
    local label="$1" d="$2" want="${3:-}" out rc
    out="$(python3 "${CHECKER}" "${d}" 2>&1)"; rc=$?
    if [ "${rc}" -eq 0 ]; then
        fail "${label} -> the checker PASSED; it cannot detect this defect"
        printf '%s\n' "${out}" | sed 's/^/         /'
        return
    fi
    if [ -n "${want}" ] && ! printf '%s' "${out}" | grep -F -- "${want}" >/dev/null; then
        fail "${label} -> RED, but for the wrong reason (no finding matching '${want}')"
        printf '%s\n' "${out}" | sed 's/^/         /'
        return
    fi
    ok "${label} -> RED as required"
}

# expect_red_all <label> <dir> <substring>...  — RED, and every substring
# present. Used where the finding TEXT is the assertion: "the gate survived"
# and "the frame it was nested in survived" are two different properties and a
# single `grep` for one of them would not tell them apart.
expect_red_all() {
    local label="$1" d="$2"; shift 2
    local out rc want
    out="$(python3 "${CHECKER}" "${d}" 2>&1)"; rc=$?
    if [ "${rc}" -eq 0 ]; then
        fail "${label} -> the checker PASSED; it cannot detect this defect"
        printf '%s\n' "${out}" | sed 's/^/         /'
        return
    fi
    for want in "$@"; do
        if ! printf '%s' "${out}" | grep -F -- "${want}" >/dev/null; then
            fail "${label} -> RED, but no finding matching '${want}'"
            printf '%s\n' "${out}" | sed 's/^/         /'
            return
        fi
    done
    ok "${label} -> RED as required"
}

expect_green() {
    local label="$1" d="$2" out rc
    out="$(python3 "${CHECKER}" "${d}" 2>&1)"; rc=$?
    if [ "${rc}" -eq 0 ]; then
        ok "${label} -> GREEN as required"
    else
        fail "${label} -> the checker went RED on a clean tree (false positive)"
        printf '%s\n' "${out}" | sed 's/^/         /'
    fi
}

# ── (2) POSITIVE CONTROL ─────────────────────────────────────────────────────
echo
echo "-- 2) positive control: a tree where both paths provision everything --"
mk_tree "${STAGE_ROOT}/clean" vault-ca ca.crt yes yes
expect_green "fully provisioned tree" "${STAGE_ROOT}/clean"

# ── (3) NEGATIVE CONTROLS ────────────────────────────────────────────────────
echo
echo "-- 3) negative controls: each defect class must bite --"

# (a) THE SHIPPED OUTAGE: caProvider names a Secret the kind path never creates,
#     while the USB path does. The naive "someone creates it" check passes here.
mk_tree "${STAGE_ROOT}/n1" vault-ca ca.crt no yes
expect_red "caProvider Secret missing on the kind path only" "${STAGE_ROOT}/n1" \
    "nothing creates Secret vault-ca in namespace hugmesh-backend"

# (b) the same for the auth token
mk_tree "${STAGE_ROOT}/n2" vault-ca ca.crt yes no
expect_red "tokenSecretRef Secret missing on the kind path only" "${STAGE_ROOT}/n2" \
    "nothing creates Secret vault-token in namespace hugmesh-backend"

# (c) missing on BOTH paths
mk_tree "${STAGE_ROOT}/n3" vault-ca ca.crt no no
expect_red "provider Secrets missing on every path" "${STAGE_ROOT}/n3"

# (d) THE WRONG-KEY TRAP. Repointing caProvider at the pre-existing `cluster-ca`
#     Secret looks like a fix, but cluster-ca is kubernetes.io/tls: it carries
#     tls.crt / tls.key and no ca.crt. ESO resolves the Secret and then fails on
#     the key — the same outage wearing a different error. The manifest is placed
#     where the kind script's own `kubectl apply -f` reaches it, so the Secret is
#     genuinely credited to that path and the KEY is what fails.
mkdir -p "${STAGE_ROOT}/n4"
mk_tree "${STAGE_ROOT}/n4" cluster-ca ca.crt yes yes
cat > "${STAGE_ROOT}/n4/specs/cluster/manifests/clusterca.yaml" <<'YAML'
apiVersion: v1
kind: Secret
metadata: { name: cluster-ca, namespace: hugmesh-backend }
type: kubernetes.io/tls
data:
  tls.crt: AAAA
  tls.key: BBBB
YAML
expect_red "caProvider points at a Secret lacking the requested key" "${STAGE_ROOT}/n4" \
    "carries no key 'ca.crt'"

# (e) a delivery path whose provisioner script has vanished: unverifiable, which
#     is a failure and not a pass.
mk_tree "${STAGE_ROOT}/n5" vault-ca ca.crt yes yes
rm -f "${STAGE_ROOT}/n5/specs/cluster/bootstrap/kind-local/bootstrap-kind.sh"
expect_red "a declared delivery path's script is missing" "${STAGE_ROOT}/n5" \
    "does not exist"

# (f) caProvider carrying a namespace: on a generator. ESO IGNORES it
#     (EmptyStoreKind), so it reads as cross-namespace and silently is not.
mk_tree "${STAGE_ROOT}/n6" vault-ca ca.crt yes yes
sed -i 's|caProvider: { type: Secret, name: vault-ca, key: ca.crt }|caProvider: { type: Secret, name: vault-ca, key: ca.crt, namespace: vault }|' \
    "${STAGE_ROOT}/n6/specs/cluster/manifests/gen.yaml"
expect_red "generator caProvider declares an ignored namespace" "${STAGE_ROOT}/n6" \
    "which ESO ignores"

# ── (4) REACHABILITY CONTROLS ────────────────────────────────────────────────
# A checker that models `kubectl create` line by line, with no notion of control
# flow, credits a provisioner that can never run. Wrapping the real seeding block
# in `if false; then … fi` is bash -n clean and left an earlier draft of this
# gate fully green — while the SAME blindness hid a live instance: the repo's
# external-secrets/vault-token is created only inside a not-initialized `else`
# branch, so an idempotent re-run never creates it.
echo
echo "-- 4) reachability: a statement that cannot run has provisioned nothing --"

mk_tree "${STAGE_ROOT}/r1" vault-ca ca.crt dead yes
if ! bash -n "${STAGE_ROOT}/r1/specs/cluster/bootstrap/kind-local/bootstrap-kind.sh" 2>/dev/null; then
    fail "the 'if false' control is not even syntactically valid — it would be caught by shell parsing, not by this gate"
else
    ok "the 'if false' control is bash -n clean (so only reachability analysis can catch it)"
fi
expect_red "provisioning wrapped in 'if false' (present in the file, never runs)" \
    "${STAGE_ROOT}/r1" "can NEVER run"

mk_tree "${STAGE_ROOT}/r2" vault-ca ca.crt cond yes
expect_red "provisioning reachable only through one branch of a runtime test" \
    "${STAGE_ROOT}/r2" "ONLY behind a conditional"

mk_tree "${STAGE_ROOT}/r3" vault-ca ca.crt cond-ann yes
expect_green "the same conditional, declared deliberate with a stated reason" \
    "${STAGE_ROOT}/r3"

mk_tree "${STAGE_ROOT}/r4" vault-ca ca.crt cond-bare yes
expect_red "an exemption annotation carrying no reason" "${STAGE_ROOT}/r4" \
    "with no usable reason"

# Length alone would let padding through, so the reason must also be a sentence.
mk_tree "${STAGE_ROOT}/r4b" vault-ca ca.crt cond-ann yes
sed -i 's|# eso-provider-refs: conditional-ok deliberate:.*|# eso-provider-refs: conditional-ok aaaaaaaa aaaaaaaa aaaaaaaa aaaaaaaa|' \
    "${STAGE_ROOT}/r4b/specs/cluster/bootstrap/kind-local/bootstrap-kind.sh"
expect_red "an exemption whose 'reason' is padding of the right length" \
    "${STAGE_ROOT}/r4b" "with no usable reason"

# ── THE EXEMPTION INVENTORY ──────────────────────────────────────────────────
# Shape checks (length, word count) screen gibberish; they cannot tell whether a
# reason is TRUE. The control that does the real work is that exemptions may not
# accumulate quietly: this pins the EXACT set the repo carries, so adding one —
# or moving one to a different Secret — fails here BY NAME until a human edits
# this list, which is precisely the review the annotation is claiming to have
# had. Each entry below was read at provision.sh:2448/2481/2501 and
# bootstrap-kind.sh:496 and is defensible as written; that judgement is what a
# future editor is being asked to re-make, not rubber-stamp.
echo
echo "-- 4a) the set of annotated exemptions is pinned, so none can be added quietly --"
# Keyed by SITE (kind, namespace/name, file) and not by tuple alone: the USB
# path legitimately exempts hugmesh-*/vault-ca, so a pin keyed on the tuple
# would have accepted a SECOND exemption for the very same Secret added to
# bootstrap-kind.sh — which is exactly the shape of an annotation written to
# bury a regression. Verified: with a tuple-only key that attack passed.
EXPECTED_EXEMPTIONS="$(cat <<'EOF'
Secret hugmesh-backend/vault-ca specs/etc/keys-provision/provision.sh
Secret hugmesh-backend/vault-token specs/etc/keys-provision/provision.sh
Secret hugmesh-frontend/vault-ca specs/etc/keys-provision/provision.sh
Secret hugmesh-frontend/vault-token specs/etc/keys-provision/provision.sh
Secret hugmesh-pki/vault-ca specs/etc/keys-provision/provision.sh
Secret hugmesh-pki/vault-token specs/etc/keys-provision/provision.sh
Secret vault/cluster-ca specs/etc/keys-provision/provision.sh
Secret vault/vault-bootstrap specs/cluster/bootstrap/kind-local/bootstrap-kind.sh
EOF
)"
ACTUAL_EXEMPTIONS="$(python3 "${CHECKER}" "${REPO}" --exemptions 2>/dev/null | sort -u)"
if [ "${ACTUAL_EXEMPTIONS}" = "${EXPECTED_EXEMPTIONS}" ]; then
    ok "the annotated exemptions are exactly the $(printf '%s' "${EXPECTED_EXEMPTIONS}" | grep -c .) reviewed ones"
else
    fail "the set of annotated exemptions changed — every one of these is a claim that a Secret the mesh depends on is DELIBERATELY not created on some path. Re-read each site, then update EXPECTED_EXEMPTIONS here."
    diff <(printf '%s\n' "${EXPECTED_EXEMPTIONS}") <(printf '%s\n' "${ACTUAL_EXEMPTIONS}") \
        | sed 's/^/         /'
fi

mk_tree "${STAGE_ROOT}/r5" vault-ca ca.crt dead-ann yes
expect_red "dead code may NOT be annotated away" "${STAGE_ROOT}/r5" "can NEVER run"

# A function nothing calls is the same defect wearing a different shape.
mk_tree "${STAGE_ROOT}/r6" vault-ca ca.crt no yes
cat >> "${STAGE_ROOT}/r6/specs/cluster/bootstrap/kind-local/bootstrap-kind.sh" <<'ORPHAN'
seed_the_ca() {
  kubectl -n hugmesh-backend create secret generic vault-ca --from-literal=ca.crt=x
}
ORPHAN
expect_red "a provisioner inside a function nothing calls" "${STAGE_ROOT}/r6" \
    "can NEVER run"

# ── (4b) SHORT-CIRCUIT AND EARLY-OUT REACHABILITY ────────────────────────────
# The controls above close the `if false` INSTANCE. They do not close the CLASS:
# a model that reads only KEYWORD control flow is blind to bash's other half —
# `&&`/`||` gating and early-out statements — and every one of the five rewrites
# below is `bash -n` clean, leaves the seeding statement textually intact, and
# was credited as UNCONDITIONAL (checker exit 0) by the keyword-only model.
# Verified against e1d0bd06. Two of them, the opt-in flag and the loop
# early-out, are how a real regression would most plausibly be spelled.
echo
echo "-- 4b) short-circuit gating and early-out statements --"

# syntax_clean <dir> — a control that shell parsing would reject is not testing
# reachability analysis, it is testing bash.
syntax_clean() {
    local label="$1" f="$2/specs/cluster/bootstrap/kind-local/bootstrap-kind.sh"
    if bash -n "${f}" 2>/dev/null; then
        ok "${label} is bash -n clean (so only reachability analysis can catch it)"
    else
        fail "${label} is not syntactically valid — bash would catch it, not this gate"
    fi
}

# (a) OPT-IN GATE. The seeding runs only when an env flag is set, so a default
#     run does not seed. Two lines added, nothing deleted.
mk_tree "${STAGE_ROOT}/s1" vault-ca ca.crt sc-and yes
syntax_clean "the '&& { … }' opt-in gate control" "${STAGE_ROOT}/s1"
expect_red "seeding behind an opt-in flag: '[ \"\${SEED_GENERATOR_CREDS:-0}\" = 1 ] && { … }'" \
    "${STAGE_ROOT}/s1" "ONLY behind a conditional"

# (b) LOOP EARLY-OUT. One line at the top of the loop body and every iteration
#     skips the rest of itself.
mk_tree "${STAGE_ROOT}/s2" vault-ca ca.crt sc-cont yes
syntax_clean "the '|| continue' early-out control" "${STAGE_ROOT}/s2"
expect_red "seeding after '[ \"\${OPT_IN_SEED:-0}\" = 1 ] || continue' in the loop body" \
    "${STAGE_ROOT}/s2" "ONLY behind a conditional"

# (c) KILL SWITCH. `false && { … }` is `if false; then … fi` wearing the other
#     spelling, and the keyword model caught only the spelling it knew.
mk_tree "${STAGE_ROOT}/s3" vault-ca ca.crt sc-false yes
syntax_clean "the 'false && { … }' control" "${STAGE_ROOT}/s3"
expect_red "seeding inside 'false && { … }'" "${STAGE_ROOT}/s3" "can NEVER run"

# (d) EARLY RETURN. The function IS called — the call site is real — so
#     "function nothing calls" does not catch it; the `return 0` above the block
#     does.
mk_tree "${STAGE_ROOT}/s4" vault-ca ca.crt fn-return yes
syntax_clean "the early-'return 0' control" "${STAGE_ROOT}/s4"
grep -q '^seed_generator_credentials$' \
    "${STAGE_ROOT}/s4/specs/cluster/bootstrap/kind-local/bootstrap-kind.sh" \
    && ok "the early-return control has a REAL call site (so it is not the uncalled-function control again)" \
    || fail "the early-return control has no call site — it would be caught by the wrong rule"
expect_red "seeding after an unconditional 'return 0' in a function that IS called" \
    "${STAGE_ROOT}/s4" "can NEVER run"

# (e) EARLY EXIT.
mk_tree "${STAGE_ROOT}/s5" vault-ca ca.crt pre-exit yes
syntax_clean "the 'exit 0' control" "${STAGE_ROOT}/s5"
expect_red "seeding below an unconditional top-level 'exit 0'" \
    "${STAGE_ROOT}/s5" "can NEVER run"

# (f) GUARD CLAUSE. `[ … ] || return 0` is (b) with a different keyword: skip
#     the work, report success. It went GREEN while `|| continue` went red —
#     an asymmetry, and the more natural spelling once the block lives in a
#     function, so a regression could simply be written around the gate.
#     `|| exit 1` is NOT this and must stay green: see §4c.
mk_tree "${STAGE_ROOT}/s6" vault-ca ca.crt sc-ret0 yes
syntax_clean "the '|| return 0' guard-clause control" "${STAGE_ROOT}/s6"
grep -q '^seed_generator_credentials$' \
    "${STAGE_ROOT}/s6/specs/cluster/bootstrap/kind-local/bootstrap-kind.sh" \
    && ok "the '|| return 0' control has a REAL call site (so it is not the uncalled-function control again)" \
    || fail "the '|| return 0' control has no call site — it would be caught by the wrong rule"
expect_red "seeding after '[ \"\${SEED_GENERATOR_CREDS:-0}\" = 1 ] || return 0'" \
    "${STAGE_ROOT}/s6" "ONLY behind a conditional"

# ── (4c) THE OTHER SIDE OF THE LINE ──────────────────────────────────────────
# A reachability model that reads ordinary error handling as a gate is worse
# than none: it goes red on correct code, and someone switches it off. These
# three are the shapes that must stay GREEN, and they are not hypothetical —
# `… || { echo …; exit 1; }` opens nearly every function in provision.sh and
# appears five times in bootstrap-kind.sh. An earlier cut of this model treated
# a conditional `exit`/`return` as a gate and turned SEVEN correct provisioners
# in the real repo red; these controls exist so that cannot come back.
echo
echo "-- 4c) error handling is NOT a conditional gate (false-positive controls) --"

mk_tree "${STAGE_ROOT}/e1" vault-ca ca.crt err-die yes
expect_green "a '|| { echo …; exit 1; }' precondition abort ABOVE the seeding" \
    "${STAGE_ROOT}/e1"

mk_tree "${STAGE_ROOT}/e2" vault-ca ca.crt err-true yes
expect_green "an 'x=\"\$(…)\" || true' read ABOVE the seeding" "${STAGE_ROOT}/e2"

mk_tree "${STAGE_ROOT}/e3" vault-ca ca.crt err-lhs yes
expect_green "the seeding itself on the LEFT of '|| echo …' (an operator gates only its right)" \
    "${STAGE_ROOT}/e3"

# ── (4d) THE SAME SHAPES, WRAPPED AROUND THE REAL STEP-8B BLOCK ──────────────
# WHY THIS SECTION EXISTS AND §4b IS NOT ENOUGH.
#
# The §4b controls passed for three review rounds while the property they claim
# to test was broken. Their gated block is a synthesised `kubectl apply` and
# nothing else. The REAL one is ~80 lines of bootstrap-kind.sh, and line 604 of
# it is
#
#     [ -n "${GEN_TOKEN}" ] || { echo "neither external-secrets/vault-token …" >&2; exit 1; }
#
# — a self-contained `{ … }`. The model popped the enclosing frame on ANY bare
# `}`, so that one line of perfectly ordinary error handling cancelled the gate
# above it AND the `if [ -z "${GEN_TOKEN}" ]` frame it sat inside. Wrap the real
# step 8b in `[ "${SEED_GENERATOR_CREDS:-0}" = "1" ] && { … }` and the checker
# exited 0 — the same answer it gave before any reachability model existed. The
# green §4b control was green because its block was simpler than production.
#
# So these controls stage the REAL repo and wrap the REAL text, verbatim, braces
# and all. The staging is checked before use: if the anchors move or the brace
# idiom leaves line 604, the section FAILS rather than quietly testing a block
# that no longer has the shape it exists to test.
echo
echo "-- 4d) the same shapes wrapped around the REAL step-8b block --"

BK_REL="specs/cluster/bootstrap/kind-local/bootstrap-kind.sh"
REAL_ROOT="${STAGE_ROOT}/real"
mkdir -p "${REAL_ROOT}"
cp -a "${REPO}/specs" "${REAL_ROOT}/specs"

# Boundaries come from the file's own text. Hardcoded line numbers drift with
# every edit above them and would silently wrap the wrong region — a control
# that has stopped controlling.
S8B_OPEN='log "Seeding per-namespace generator credentials (vault-ca + vault-token)"'
S8B_CLOSE='unset GEN_TOKEN'
s8b_start="$(grep -cxF "${S8B_OPEN}" "${REPO}/${BK_REL}")"
s8b_end="$(grep -cxF "${S8B_CLOSE}" "${REPO}/${BK_REL}")"
if [ "${s8b_start}" = "1" ] && [ "${s8b_end}" = "1" ]; then
    ok "step 8b's boundaries resolve to exactly one line each in the real bootstrap"
else
    fail "step 8b's boundaries are not unique in ${BK_REL} (open x${s8b_start}, close x${s8b_end}) — the §4d controls would wrap the wrong region"
fi
s8b_start="$(grep -nxF "${S8B_OPEN}" "${REPO}/${BK_REL}" | cut -d: -f1)"
s8b_end="$(grep -nxF "${S8B_CLOSE}" "${REPO}/${BK_REL}" | cut -d: -f1)"

# The shape under test must actually BE in the block being wrapped.
S8B_BRACE='|| { echo "neither external-secrets/vault-token'
if sed -n "${s8b_start},${s8b_end}p" "${REPO}/${BK_REL}" | grep -F -- "${S8B_BRACE}" >/dev/null; then
    ok "the wrapped block really contains the self-contained '|| { …; exit 1; }' of line ${s8b_start}..${s8b_end}"
else
    fail "the wrapped block no longer contains a self-contained '{ … }' — §4d would be testing a simpler shape than production, which is exactly how this defect survived three rounds"
fi

# real_wrap <open-text> <close-text> — rewrite the staged bootstrap with the
# real step-8b block wrapped. `\n` inside either argument becomes a newline.
real_wrap() {
    awk -v OPEN="$1" -v CLOSE="$2" -v S="${s8b_start}" -v E="${s8b_end}" '
        NR == S { print OPEN }
        { print }
        NR == E { print CLOSE }
    ' "${REPO}/${BK_REL}" > "${REAL_ROOT}/${BK_REL}"
    chmod +x "${REAL_ROOT}/${BK_REL}"
}

# The injection itself must be inert: wrapping with no-ops has to leave the tree
# green, or every RED below could be an artefact of the harness.
real_wrap ':' ':'
syntax_clean "the untouched real bootstrap" "${REAL_ROOT}"
expect_green "the real repo with the harness's own wrapper reduced to ':' (the injection is inert)" \
    "${REAL_ROOT}"

# (a) THE OPT-IN GATE — the shape that reported "fixed" and was not.
#     Two assertions, because two frames had to survive line 604: the gate
#     itself (the seeding scores sc/then) and the `if [ -z "${GEN_TOKEN}" ]`
#     it is nested in.
real_wrap '[ "${SEED_GENERATOR_CREDS:-0}" = "1" ] && {' '}'
syntax_clean "the real block behind '&& { … }'" "${REAL_ROOT}"
expect_red_all "the REAL step 8b behind '[ \"\${SEED_GENERATOR_CREDS:-0}\" = 1 ] && { … }'" \
    "${REAL_ROOT}" \
    "ONLY behind a conditional" "sc/then(conditional)" \
    "Secret external-secrets/vault-token is created ONLY behind a conditional"

# (a2) THE SAME GATE, WITH A MULTI-LINE BRACE GROUP INSIDE IT.
#      Round 4 closed the ONE-LINE `cmd || { …; }` and stopped there, and the
#      class survived a whole round in the half that was left: a `}` closing a
#      MULTI-LINE group the frame stack never opened still popped the gate above
#      it and every frame over it, so (a) was cancelled EXACTLY as it had been
#      before the one-line fix. The three spellings below are the ones a
#      regression would actually be written in — a helper function defined
#      inside the block, a plain `{ … }` grouping, and a definition whose body
#      starts on the `{` line — and all three were rc=0 against this very block
#      at 663eff0d while a bare `&& {` wrap was rc=1.
#
#      They are staged against the REAL block and NOT only synthetically,
#      because a fixture simpler than production is the single reason this class
#      lived through four review rounds. The assertions are (a)'s, verbatim: the
#      gate frame survived (sc/then(conditional)) AND the `if [ -z … ]` frame
#      nested inside it survived (external-secrets/vault-token is conditional).
real_wrap '[ "${SEED_GENERATOR_CREDS:-0}" = "1" ] && {\n_noop() {\n  :\n}' '}'
syntax_clean "the real block behind '&& { … }' containing a multi-line function definition" "${REAL_ROOT}"
grep -q '^_noop() {$' "${REAL_ROOT}/${BK_REL}" \
    && ok "the C1 control really contains a MULTI-LINE function definition (not a one-liner)" \
    || fail "the C1 control lost its multi-line function definition — it would be re-testing the one-line shape"
expect_red_all "the REAL step 8b behind '&& { … }' with a multi-line function definition inside it (C1)" \
    "${REAL_ROOT}" \
    "ONLY behind a conditional" "sc/then(conditional)" \
    "Secret external-secrets/vault-token is created ONLY behind a conditional"

real_wrap '[ "${SEED_GENERATOR_CREDS:-0}" = "1" ] && {\n{\n  :\n}' '}'
syntax_clean "the real block behind '&& { … }' containing a plain multi-line '{ … }'" "${REAL_ROOT}"
expect_red_all "the REAL step 8b behind '&& { … }' with a plain multi-line '{ … }' inside it (C2)" \
    "${REAL_ROOT}" \
    "ONLY behind a conditional" "sc/then(conditional)" \
    "Secret external-secrets/vault-token is created ONLY behind a conditional"

real_wrap '[ "${SEED_GENERATOR_CREDS:-0}" = "1" ] && {\nfoo() { :\n} ; echo after' '}'
syntax_clean "the real block behind '&& { … }' containing 'foo() { :' / '} ; echo after'" "${REAL_ROOT}"
expect_red_all "the REAL step 8b behind '&& { … }' with a definition whose body opens on the '{' line (C11)" \
    "${REAL_ROOT}" \
    "ONLY behind a conditional" "sc/then(conditional)" \
    "Secret external-secrets/vault-token is created ONLY behind a conditional"

# (c) THE KILL SWITCH. The guard string is the over-pop assertion in full:
#     `sc/then(dead),if/then(conditional)` says the short-circuit frame AND the
#     `if` frame nested inside it BOTH survived the `}` on line 604. With the
#     over-pop, both were gone and the checker exited 0.
real_wrap 'false && {' '}'
syntax_clean "the real block behind 'false && { … }'" "${REAL_ROOT}"
expect_red_all "the REAL step 8b inside 'false && { … }'" "${REAL_ROOT}" \
    "can NEVER run" "sc/then(dead),if/then(conditional)"

# (c2) the kill switch with a multi-line group inside it. `dead` has to survive
#      the inner `}` too, not just `conditional`: they take different branches
#      out of worse()/contribution() and a fix that only restored one of them
#      would leave the strongest signal the gate has still cancellable.
real_wrap 'false && {\n_noop() {\n  :\n}' '}'
syntax_clean "the real block behind 'false && { … }' containing a multi-line function definition" "${REAL_ROOT}"
expect_red_all "the REAL step 8b inside 'false && { … }' with a multi-line function definition inside it" \
    "${REAL_ROOT}" "can NEVER run" "sc/then(dead),if/then(conditional)"

# (b) (d) (e) — the keyword shapes, restaged against the real block so none of
# them is passing on a simplification either.
real_wrap 'if false; then' 'fi'
syntax_clean "the real block inside 'if false'" "${REAL_ROOT}"
expect_red_all "the REAL step 8b inside 'if false; then … fi'" "${REAL_ROOT}" \
    "can NEVER run" "if/then(dead),if/then(conditional)"

real_wrap 'seed_generator_credentials() {\n  return 0' '}\nseed_generator_credentials'
syntax_clean "the real block after an early 'return 0'" "${REAL_ROOT}"
grep -q '^seed_generator_credentials$' "${REAL_ROOT}/${BK_REL}" \
    && ok "the real-block early-return control has a REAL call site" \
    || fail "the real-block early-return control has no call site — it would be caught by the wrong rule"
expect_red "the REAL step 8b after an unconditional 'return 0' in a function that IS called" \
    "${REAL_ROOT}" "can NEVER run"

real_wrap 'exit 0' ':'
syntax_clean "the real block below 'exit 0'" "${REAL_ROOT}"
expect_red "the REAL step 8b below an unconditional top-level 'exit 0'" \
    "${REAL_ROOT}" "can NEVER run"

# (f) THE GUARD-CLAUSE SPELLING, against the real block.
real_wrap 'seed_generator_credentials() {\n  [ "${SEED_GENERATOR_CREDS:-0}" = "1" ] || return 0' \
          '}\nseed_generator_credentials'
syntax_clean "the real block after '[ … ] || return 0'" "${REAL_ROOT}"
expect_red "the REAL step 8b after '[ \"\${SEED_GENERATOR_CREDS:-0}\" = 1 ] || return 0'" \
    "${REAL_ROOT}" "ONLY behind a conditional"

real_wrap '[ "${SEED_GENERATOR_CREDS:-0}" = "1" ] || exit 0' ':'
syntax_clean "the real block after '[ … ] || exit 0'" "${REAL_ROOT}"
expect_red "the REAL step 8b after '[ \"\${SEED_GENERATOR_CREDS:-0}\" = 1 ] || exit 0'" \
    "${REAL_ROOT}" "ONLY behind a conditional"

# ── (4e) THE BRACE IDIOMS THEMSELVES, ON THE REAL BLOCK, UNGATED ─────────────
# The mirror of §4d(a): the same lines that used to cancel a gate must not
# CREATE one. `cmd || { echo …; exit 1; }`, a bare `{ … ; }` and a plain
# function definition are the commonest lines in this tree; if any of them
# turned the real repo red the gate would be switched off within a day. The last
# two matter more since §4d(a2): EVERY multi-line `{` now pushes a frame, so
# "over-firing" is the direction this fix could have gone wrong in, and these
# are the controls that say it did not.
echo
echo "-- 4e) the brace idioms are still not gates (false-positive controls) --"

real_wrap 'kubectl version --client >/dev/null 2>&1 || { echo "kubectl is not usable" >&2; exit 1; }' ':'
syntax_clean "the real block under an extra '|| { echo …; exit 1; }'" "${REAL_ROOT}"
expect_green "an extra 'cmd || { echo …; exit 1; }' immediately above the REAL step 8b" \
    "${REAL_ROOT}"

real_wrap '{ log "  step 8b starting"; }' ':'
syntax_clean "the real block under an extra bare '{ … ; }'" "${REAL_ROOT}"
expect_green "an extra self-contained '{ log …; }' immediately above the REAL step 8b" \
    "${REAL_ROOT}"

# The multi-line halves of the same two idioms, WRAPPING the real block rather
# than sitting above it: an ungated `{` … `}` and an ungated function definition
# are not gates, so step 8b inside either must stay GREEN. Without these, §4d(a2)
# could have been "passed" by treating every `{` as conditional.
real_wrap '{' '}'
syntax_clean "the real block inside a plain multi-line '{ … }'" "${REAL_ROOT}"
expect_green "the REAL step 8b wrapped in an ungated multi-line '{ … }'" "${REAL_ROOT}"

real_wrap 'seed_generator_credentials() {' '}\nseed_generator_credentials'
syntax_clean "the real block inside an ungated function that IS called" "${REAL_ROOT}"
expect_green "the REAL step 8b inside a function definition called unconditionally" \
    "${REAL_ROOT}"

# And a multi-line group INSIDE the real block, ungated: the exact text §4d(a2)
# wraps, minus the wrapper. If this went red, (a2) would be proving nothing
# about the gate — only that the harness dislikes braces.
real_wrap '_noop() {\n  :\n}' ':'
syntax_clean "the real block under an extra multi-line function definition" "${REAL_ROOT}"
expect_green "an extra multi-line function definition immediately above the REAL step 8b" \
    "${REAL_ROOT}"

# ── (4f) THE MODEL'S OWN BRACE BOOKKEEPING ───────────────────────────────────
# Chasing §4d(a2) turned up two MORE lines in the real tree that closed a group
# nothing had opened, and each would cancel a gate wrapped around it exactly as
# the multi-line group did:
#
#   provision.sh:1698   "mkfs.${fs}" ${label:+-L "${label}"} -F "${blkdev}" …
#   provision.sh:2351   kubectl label node … ${label//,/ } --overwrite …
#
# Both are PARAMETER EXPANSIONS. Blanking the quoted spans leaves `${label:+-L
# }` and `${label//,/ }`, whose `}` is then preceded by a blank and reads as a
# grouping brace in command position. And one line opened a group nothing ever
# closed:
#
#   provision.sh:2639   [ -d "${BASE}/keystores" ] && { cp -f …; \
#
# — a `{ … }` closed on its line-continuation, which the parser consumes whole.
#
# The lesson from four rounds is that reading harder finds one spelling at a
# time. So the model now reports its OWN unmatched braces as findings, and this
# section proves that report is real: it must be silent on the true tree, and it
# must bite on each of the three shapes. That is a property no future spelling
# of this defect can be green under, whether or not anyone thought of it.
echo
echo "-- 4f) the model reports its own unmatched braces --"

# NOTE ON `| grep` HERE: this file runs under `set -o pipefail` and the checker
# EXITS NON-ZERO whenever it has findings, so `if checker | grep -q …` reports
# the exit status of the CHECKER, not of the grep — it reads "no match" on a red
# tree and silently inverts every assertion built on it. Output is captured
# first, exactly as expect_red/expect_green already do.
brace_unmatched='closes a `{ … }` group that was never opened'
brace_dangling='opens a `{ … }` group that is never closed'

# The real tree must be silent — this is the one that says the three shapes
# above are genuinely closed and not merely re-labelled.
real_out="$(python3 "${CHECKER}" "${REPO}" 2>&1)"
if printf '%s' "${real_out}" | grep -F -e "${brace_unmatched}" -e "${brace_dangling}" >/dev/null; then
    fail "the real repo has an unmatched brace the model cannot pair — every guard below it is unreliable"
    printf '%s\n' "${real_out}" | grep -F -e "${brace_unmatched}" -e "${brace_dangling}" | sed 's/^/         /'
else
    ok "the real tree's braces all pair (the \${…} expansion and continuation-chunk shapes are closed)"
fi

# … and the report must BITE. Both probes below are `bash -n` clean — that is
# the point: they are the KNOWN LIMIT shapes _brace_scan() names, written as
# valid shell, so the model genuinely cannot pair them. It must SAY so rather
# than pop (or fail to pop) a frame and carry on scoring, because a lost frame
# is how every round of this defect ended.
brace_probe() {   # brace_probe <label> <injected-text> <want>
    local out
    real_wrap "$2" ':'
    if ! bash -n "${REAL_ROOT}/${BK_REL}" 2>/dev/null; then
        fail "the brace-bookkeeping probe '$1' is not bash -n clean — it is testing bash, not the model"
        return
    fi
    out="$(python3 "${CHECKER}" "${REAL_ROOT}" 2>&1)"
    if printf '%s' "${out}" | grep -F -- "$3" >/dev/null; then
        ok "$1 -> reported as an unmatched brace"
    else
        fail "$1 -> the model absorbed it silently; a gate wrapped around this line would be cancelled without a word"
        printf '%s\n' "${out}" | sed 's/^/         /'
    fi
}

# `true }` — a bare `}` in argument position. Valid shell, indistinguishable
# from a group close to a line-based scanner.
brace_probe "a '}' the model cannot tell from a group close" \
    'true }' "${brace_unmatched}"
# `}>/dev/null` — the redirection spelling from the KNOWN LIMIT: bash pairs it
# with the `{` above, the command-position rule does not.
brace_probe "a group closed with '}>/dev/null' (the un-modelled spelling)" \
    '{\n  true\n}>/dev/null' "${brace_dangling}"

# The mirror: the two REAL expansion lines, copied verbatim out of provision.sh
# into the kind path, must NOT be reported. If the expansion rule over-reaches
# these go red and the gate is switched off within a day.
real_wrap 'label=""\nblkdev=/dev/null\nfs=ext4\ntrue "mkfs.${fs}" ${label:+-L "${label}"} -F "${blkdev}"\ntrue "${label//,/ }"' ':'
syntax_clean "the real block under the two verbatim \${…} expansion lines" "${REAL_ROOT}"
expect_green "provision.sh's own '\${label:+-L …}' and '\${label//,/ }' lines above the REAL step 8b" \
    "${REAL_ROOT}"

# And the same two lines INSIDE the gate: an expansion must not cancel it.
real_wrap '[ "${SEED_GENERATOR_CREDS:-0}" = "1" ] && {\nlabel=""\ntrue "${label:+-L "${label}"}"\ntrue "${label//,/ }"' '}'
syntax_clean "the gated real block containing the two \${…} expansion lines" "${REAL_ROOT}"
expect_red_all "the REAL step 8b behind '&& { … }' with '\${label:+…}' / '\${label//…}' inside it" \
    "${REAL_ROOT}" \
    "ONLY behind a conditional" "sc/then(conditional)" \
    "Secret external-secrets/vault-token is created ONLY behind a conditional"

# The continuation shape, inside the gate: `&& { …; \` + `…; }` is ONE logical
# statement and must neither cancel the gate nor leave a group dangling.
real_wrap '[ "${SEED_GENERATOR_CREDS:-0}" = "1" ] && {\n[ -d /nonexistent ] && { true; \\\n  true; }' '}'
syntax_clean "the gated real block containing a '\\'-continued brace group" "${REAL_ROOT}"
expect_red_all "the REAL step 8b behind '&& { … }' with a line-continuation brace group inside it" \
    "${REAL_ROOT}" \
    "ONLY behind a conditional" "sc/then(conditional)" \
    "Secret external-secrets/vault-token is created ONLY behind a conditional"

# ── (5) DELIVERY-PATH ATTRIBUTION FOR YAML ───────────────────────────────────
# The draft seeded EVERY path with EVERY *.yaml under specs/, so a manifest no
# Application and no script applies satisfied all 58 references on the broken
# tree and turned it green. A Secret only counts for a path that applies it.
echo
echo "-- 5) YAML manifests count only for a path that actually applies them --"

# kindtok=yes keeps the kind path non-empty, so what is under test is the dead
# manifest's attribution and not the vacuity check firing first.
mk_tree "${STAGE_ROOT}/y1" vault-ca ca.crt no yes
mkdir -p "${STAGE_ROOT}/y1/specs/etc/dead-notes"
cat > "${STAGE_ROOT}/y1/specs/etc/dead-notes/example-not-applied.yaml" <<'YAML'
apiVersion: v1
kind: Secret
metadata: { name: vault-ca, namespace: hugmesh-backend }
type: Opaque
data: { ca.crt: AAAA }
---
apiVersion: v1
kind: Secret
metadata: { name: vault-token, namespace: hugmesh-backend }
type: Opaque
data: { token: AAAA }
YAML
expect_red "a broken tree plus a manifest nothing applies is still broken" \
    "${STAGE_ROOT}/y1" "nothing creates Secret vault-ca in namespace hugmesh-backend"

# and the converse: a manifest the path DOES apply is credited, so this is not
# just "YAML never counts".
mk_tree "${STAGE_ROOT}/y2" vault-ca ca.crt no yes
cat > "${STAGE_ROOT}/y2/specs/cluster/manifests/vault-ca.yaml" <<'YAML'
apiVersion: v1
kind: Secret
metadata: { name: vault-ca, namespace: hugmesh-backend }
type: Opaque
data: { ca.crt: AAAA }
YAML
sed -i 's|^for ca_ns in hugmesh-backend; do|kubectl apply -f /repo/specs/cluster/manifests/vault-ca.yaml\nfor ca_ns in hugmesh-backend; do|' \
    "${STAGE_ROOT}/y2/specs/etc/keys-provision/provision.sh"
expect_green "a manifest the kind script applies with 'kubectl apply -f <dir>' IS credited" \
    "${STAGE_ROOT}/y2"

# ── (6) UNPARSEABLE YAML ─────────────────────────────────────────────────────
# `except Exception: return []` deleted the documents AND every reference in
# them, while "generators found" did not move, so the vacuity check saw nothing.
echo
echo "-- 6) a file that cannot be parsed must be accounted for, not dropped --"

mk_tree "${STAGE_ROOT}/p1" vault-ca ca.crt yes yes
cat > "${STAGE_ROOT}/p1/specs/cluster/manifests/templated.yaml" <<'YAML'
apiVersion: generators.external-secrets.io/v1alpha1
kind: VaultDynamicSecret
metadata:
  name: {{ .Values.name }}-mtls
  namespace: hugmesh-backend
spec:
  provider:
    caProvider: { type: Secret, name: totally-absent-ca, key: ca.crt }
    auth:
      tokenSecretRef: { name: totally-absent-token, key: token }
YAML
expect_red "a generator hidden in a file PyYAML cannot parse" "${STAGE_ROOT}/p1" \
    "cannot be parsed as YAML"

# ── (7) VACUITY CONTROL ──────────────────────────────────────────────────────
# A scan that finds nothing must not report success. This is the control that
# keeps the gate honest if the manifests move, the parser breaks, or a future
# refactor renames the generator API group.
echo
echo "-- 7) vacuity control: a scan that finds nothing must NOT pass --"
mkdir -p "${STAGE_ROOT}/vac/specs/cluster/bootstrap/kind-local" \
         "${STAGE_ROOT}/vac/specs/etc/keys-provision"
echo '#!/usr/bin/env bash' > "${STAGE_ROOT}/vac/specs/cluster/bootstrap/kind-local/bootstrap-kind.sh"
echo '#!/usr/bin/env bash' > "${STAGE_ROOT}/vac/specs/etc/keys-provision/provision.sh"
expect_red "an empty tree (no generators at all)" "${STAGE_ROOT}/vac"

# and a tree with generators but a parser that extracted nothing would also be
# caught by the same assertion — verify the vacuity check keys on the real counts
python3 - "${CHECKER}" "${STAGE_ROOT}/clean" <<'PY'
import sys, os, importlib.util
spec = importlib.util.spec_from_file_location("c", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
r = m.analyse(sys.argv[2])
assert not m.vacuity_errors(r), "clean tree must not be vacuous"
r2 = dict(r); r2["generators"] = 0
assert m.vacuity_errors(r2), "zero generators must be reported vacuous"
r3 = dict(r); r3["refs"] = []
assert m.vacuity_errors(r3), "zero references must be reported vacuous"
print("  ok   vacuity assertions key on the real generator/reference counts")
PY
[ $? -eq 0 ] || fail "vacuity self-test failed"

echo
if [ "${RC}" -eq 0 ]; then
    echo "== PASS: ESO provider references are all provisioned, on every path =="
else
    echo "== FAIL: see above =="
fi
exit "${RC}"
