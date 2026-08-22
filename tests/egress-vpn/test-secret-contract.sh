#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════════════
# test-secret-contract.sh — the CROSS-REPO gate for the egress-VPN config-Secret
# contract. It reads BOTH halves and fails when they disagree.
#
# WHY IT EXISTS. generator #526 (the reader: the secret-projector DaemonSet) and
# admin-bff #255 (the writer: Fabric8VpnConfigSecretWriter) both merged green
# while disagreeing about where the Secrets live and what the data key is called:
#
#     reader   ns=hugmesh-egress-vpn  key="config"
#     writer   ns=hugmesh-backend     key=<the Secret's own name>
#
# Two of three values wrong, in a delivery path that therefore could not deliver
# a single byte. Nothing caught it, because each repo's tests asserted only its
# OWN constants — a closed loop is not a contract. This test breaks the loop: the
# values are declared once in specs/cluster/egress-vpn-secret-contract.env, and
# every copy — in THIS repo's manifests AND in the admin-bff source itself — is
# asserted against that file.
#
# THE ADMIN-BFF SIDE IS NOT OPTIONAL. Without a sibling checkout this test exits
# 3 (INCOMPLETE) and takes the CI job red. It never prints a green SKIP: an
# assertion that can silently not run is the disease, not the cure. (Same posture
# scripts/validate-reserved-prefixes.sh was forced into after its silent
# code-copy SKIP let a five-label drift sit on a "green" main.)
#
# Offline, read-only, no cluster, no docker, no python — grep + sed only.
#
# EXIT: 0 agreed · 1 disagreement · 3 INCOMPLETE (admin-bff side unavailable)
# ════════════════════════════════════════════════════════════════════════════════
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/contract.sh
. "${REPO}/tests/egress-vpn/lib/contract.sh"
CONTRACT="$(contract_path "${REPO}")"

DS="${REPO}/specs/cluster/manifests/egress-vpn/secret-projector-daemonset.yaml"
NS_YAML="${REPO}/specs/cluster/manifests/egress-vpn/namespace.yaml"
READER_RBAC="${REPO}/specs/cluster/manifests/egress-vpn/secret-projector-rbac.yaml"
WRITER_RBAC="${REPO}/specs/cluster/manifests/egress-vpn/writer-rbac.yaml"
KUST="${REPO}/specs/cluster/manifests/egress-vpn/kustomization.yaml"
APP13E="${REPO}/specs/cluster/apps/13e-egress-vpn.yaml"
BFF_DEPLOY="${REPO}/specs/cluster/manifests/admin-bff-api/deployment.yaml"
REGISTRY="${REPO}/specs/cluster/optional-services.yaml"
DOC="${REPO}/docs/EGRESS-VPN.md"

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }
eq(){ # eq <label> <got> <want>
    if [ "$2" = "$3" ]; then ok "$1 == ${3}"; else bad "$1 is '${2}', contract says '${3}'"; fi
}

# ── THE VERIFIED SET (feeds the COPY CENSUS in §2.5) ──────────────────────────
# Every file whose contract copy is actually COMPARED against the contract by
# this run records itself here, and it records itself from INSIDE the comparison
# — `eqf` / `okf` — never from a standalone declaration. That is the point: a
# hand-maintained "files we assert" list rots into a list of files we USED to
# assert, and a rotted list is indistinguishable from coverage. Delete an
# assertion and its file drops out of this set, the census stops recognising it,
# and the job goes red.
V=""
verified(){ local f="${1#"${REPO}"/}"; case " ${V} " in *" ${f} "*) ;; *) V="${V} ${f}" ;; esac; }
eqf(){ # eqf <file> <label> <got> <want>   — eq, and record <file> as verified
    local f="$1"; shift; verified "${f}"; eq "$@"
}
okf(){ # okf <file> <cond-rc> <pass-msg> <fail-msg> — record + report a non-eq check
    local f="$1" rc="$2"; verified "${f}"
    [ "${rc}" -eq 0 ] && ok "$3" || bad "$4"
}

echo "== egress-vpn config-Secret CROSS-REPO contract gate =="

# ── 0. the contract itself ────────────────────────────────────────────────────
C_NS="$(contract_get "${CONTRACT}" EGRESS_VPN_SECRET_NAMESPACE)"   || C_NS=""
C_SEL="$(contract_get "${CONTRACT}" EGRESS_VPN_SECRET_SELECTOR)"   || C_SEL=""
C_KEY="$(contract_get "${CONTRACT}" EGRESS_VPN_SECRET_KEY)"        || C_KEY=""
C_NAME="$(contract_get "${CONTRACT}" EGRESS_VPN_SECRET_NAME_EQUALS)" || C_NAME=""
C_NODE="$(contract_get "${CONTRACT}" EGRESS_VPN_NODE_LABEL)"       || C_NODE=""
if [ -n "${C_NS}" ] && [ -n "${C_SEL}" ] && [ -n "${C_KEY}" ] && [ -n "${C_NAME}" ] && [ -n "${C_NODE}" ]; then
    ok "contract declares all five values (${CONTRACT#"${REPO}"/})"
else
    bad "contract file unreadable or incomplete: ${CONTRACT}"
    echo "== RESULT: ${P} passed, ${F} failed =="; exit 1
fi
C_SEL_KEY="${C_SEL%%=*}"; C_SEL_VAL="${C_SEL#*=}"

# ══════════════════════════════════════════════════════════════════════════════
# 1. THE READER HALF — this repo
# ══════════════════════════════════════════════════════════════════════════════
echo "-- reader (hugmesh-generator)"

eqf "${DS}" "projector SECRET_NS"  "$(manifest_env "${DS}" SECRET_NS  || echo '<unreadable>')" "${C_NS}"
eqf "${DS}" "projector SECRET_SEL" "$(manifest_env "${DS}" SECRET_SEL || echo '<unreadable>')" "${C_SEL}"
eqf "${DS}" "projector SECRET_KEY" "$(manifest_env "${DS}" SECRET_KEY || echo '<unreadable>')" "${C_KEY}"

# The DaemonSet's own metadata.namespace (first `namespace:` in the object).
eqf "${DS}" "projector DaemonSet namespace" \
   "$(sed -n -E 's/^[[:space:]]{2}namespace:[[:space:]]*([^[:space:]]+).*/\1/p' "${DS}" | head -1)" \
   "${C_NS}"

# The Namespace object that IS the RBAC boundary.
eqf "${NS_YAML}" "namespace.yaml name" \
   "$(sed -n -E 's/^[[:space:]]{2}name:[[:space:]]*([^[:space:]]+).*/\1/p' "${NS_YAML}" | head -1)" \
   "${C_NS}"

# Every namespaced RBAC object on BOTH sides must sit in the contract namespace,
# or the grant does not cover the Secrets it is supposed to cover.
for f in "${READER_RBAC}" "${WRITER_RBAC}"; do
    if [ ! -f "${f}" ]; then bad "missing RBAC file ${f#"${REPO}"/}"; continue; fi
    wrong="$(grep -E '^[[:space:]]{2}namespace:' "${f}" | grep -cvE "^[[:space:]]{2}namespace:[[:space:]]*${C_NS}[[:space:]]*$" || true)"
    okf "${f}" "$( [ "${wrong}" = "0" ] && echo 0 || echo 1 )" \
        "${f##*/}: every object namespace is ${C_NS}" \
        "${f##*/}: ${wrong} object namespace(s) are not ${C_NS}"
done

# The projector's Role must stay READ-ONLY; the write grant belongs to the
# writer file alone. (Keeps the two files' headers true.)
grep -qE '^[[:space:]]*verbs:[[:space:]]*\["get",[[:space:]]*"list"\][[:space:]]*$' "${READER_RBAC}" \
    && ok "reader Role is exactly get+list" || bad "reader Role verbs changed shape — re-read secret-projector-rbac.yaml"
grep -qE '\b(create|patch|update|delete)\b' "${READER_RBAC}" \
    && bad "reader Role gained a WRITE verb" || ok "reader Role has no write verb"

# The writer grant must name the identity the admin-bff pod really runs as.
BFF_SA="$(sed -n -E 's/^[[:space:]]*serviceAccountName:[[:space:]]*([^[:space:]]+).*/\1/p' "${BFF_DEPLOY}" | head -1)"
BFF_NS="$(sed -n -E 's/^[[:space:]]{2}namespace:[[:space:]]*([^[:space:]]+).*/\1/p' "${BFF_DEPLOY}" | head -1)"
if [ ! -f "${WRITER_RBAC}" ]; then
    bad "no write grant exists — admin-bff's serverSideApply is RBAC-denied, and the writer swallows that to a silent 'pending'"
else
    if [ -n "${BFF_SA}" ] && grep -qE "^[[:space:]]*-[[:space:]]*kind:[[:space:]]*ServiceAccount" "${WRITER_RBAC}" \
       && grep -qE "^[[:space:]]*name:[[:space:]]*${BFF_SA}[[:space:]]*$" "${WRITER_RBAC}" \
       && grep -qE "^[[:space:]]*namespace:[[:space:]]*${BFF_NS}[[:space:]]*$" "${WRITER_RBAC}"; then
        ok "writer RoleBinding names the admin-bff pod identity (${BFF_SA} in ${BFF_NS})"
    else
        bad "writer RoleBinding does not bind the admin-bff Deployment's ServiceAccount (${BFF_SA:-?} in ${BFF_NS:-?})"
    fi
    # Read the VERBS LINE ONLY — a prose mention of "list" in the header is not a
    # grant, and a check that cannot tell the two apart is not a check.
    W_VERBS="$(grep -E '^[[:space:]]*verbs:' "${WRITER_RBAC}" | head -1)"
    case "${W_VERBS}" in
        *'"create"'*) case "${W_VERBS}" in *'"patch"'*) ok "writer Role grants create+patch (serverSideApply)" ;;
                                           *) bad "writer Role lacks 'patch' — serverSideApply is a patch" ;; esac ;;
        *)            bad "writer Role lacks 'create' — the first apply of a new config would be denied" ;;
    esac
    case "${W_VERBS}" in
        *'"list"'*|*'"watch"'*) bad "writer Role verbs grant list/watch — it addresses Secrets by name only" ;;
        *) ok "writer Role verbs grant no list/watch (cannot enumerate every VPN config)" ;;
    esac
fi

# Both RBAC files must be enable-able: present in the (commented) resource list.
for r in namespace.yaml secret-projector-rbac.yaml writer-rbac.yaml secret-projector-daemonset.yaml; do
    grep -qE "^[[:space:]]*#[[:space:]]*-[[:space:]]*${r}\b" "${KUST}"
    okf "${KUST}" "$?" \
        "kustomization carries the ${r} enable line" \
        "kustomization has no enable line for ${r} — it can never be applied"
done

# The kustomization header is an OPERATOR RUNBOOK, and step 1 spells the selector
# out in prose. A runbook is a copy: the operator confirming "the control-plane
# half is live" types what this comment says, not what the contract file says. It
# already tells the reader to go read the contract instead — but a pointer beside
# a stale literal is how you get a confidently wrong operator, so the literal is
# asserted too.
K_SEL="$(grep -oE 'hugmesh\.net/optional-service=[A-Za-z0-9._-]+' "${KUST}" | head -1)"
eqf "${KUST}" "kustomization runbook selector (step 1)" "${K_SEL:-<absent>}" "${C_SEL}"

# ── THE NODE-ARMING LABEL — gate 2, and the one that fails SILENTLY ───────────
# The operator opens gate 2 by putting a label on a node; the DaemonSet's
# `nodeSelector` decides which label that is. Drift between the two does not
# error. Upstream is explicit that "the DaemonSet controller will create Pods on
# nodes which match that node selector" — so an unsatisfiable nodeSelector
# yields no Pods AT ALL, not even Pending ones, which means no scheduling event
# and nothing in any log. It is indistinguishable from a delivery leg that has
# simply not converged yet.
#
# ── THE EXPECTED VALUE COMES FROM THE SCHEDULER'S SIDE, NOT FROM THE RUNBOOK ──
# Every carrier below is graded against DS_NODE: the key parsed out of the
# DaemonSet's `nodeSelector:` MAPPING — the key the kube-scheduler actually
# evaluates. That, and not the contract literal, is what a wrongly-labelled node
# fails to match.
#
# THE FIRST CUT OF THIS CONTROL WAS VACUOUS AND THIS IS THE POST-MORTEM. It
# compared, per file, `grep -c` of `hugmesh.net/*egress-vpn*` against
# `grep -c` of the contract key — two counts off the SAME FILE. Both counts move
# together for every edit that leaves the pattern behind, so it passed on:
#   * a renamed prefix   (`renamed.example/egress-vpn=true`) 0 == 0
#   * the transposition  (`hugmesh.net/vpn-egress=true`) 0 == 0 — and that
#     is not a hypothetical typo, it is the POD opt-in label this feature already
#     uses, spelled out 111 lines above the node label in docs/EGRESS-VPN.md
#   * deleting the instruction outright                         0 == 0
# and printed "every node-label mention spells <key>" in all three cases,
# including the one where there was no mention left to spell. A control whose
# expected value is derived from the file under test cannot detect drift in that
# file. It can only detect self-inconsistency, and a stale copy is perfectly
# self-consistent.
DS_NODE="$(awk '/^[[:space:]]*nodeSelector:/{n=1;next} n&&/^[[:space:]]*[^[:space:]#]/{ \
    sub(/^[[:space:]]*/,""); sub(/:.*$/,""); print; exit}' "${DS}")"
eqf "${DS}" "projector nodeSelector key (what the scheduler evaluates)" "${DS_NODE:-<absent>}" "${C_NODE}"
[ -n "${DS_NODE}" ] || bad "the DaemonSet's nodeSelector key is unreadable — every node-label check below is grading against nothing"

# node_label_scan <file> -> one record per Kubernetes-label-shaped token:
#     <NODE|OTHER><TAB><key><TAB><line-no><TAB><token>
#
# The token pattern is the LABEL GRAMMAR, not this feature's label: an optional
# DNS-subdomain prefix, `/`, a name segment, then `=`/`:` and a value — the shape
# upstream defines for a label key ("an optional prefix and name, separated by a
# slash (/) … the prefix must be a DNS subdomain"). It therefore matches a label
# key nobody here has thought of yet, which is the entire point. Deliberately NOT
# anchored on `hugmesh.net` or on `egress-vpn`: a scanner that finds node
# labels by grepping for the node label can only ever re-find the one it was
# built around. (Filesystem paths do not match — the grammar requires the `=`/`:`
# and an alphanumeric value right after the name segment.)
#
# NODE means the token sits in a passage that tells a reader to put a label ON A
# NODE. That is decided by the ACTION described in a two-line window — the field
# name `nodeSelector`, or the word `label` together with the word `node`/`nodes`
# — never by the label's spelling. Two lines because these runbooks wrap prose
# mid-sentence ("…then label the assigned\n# nodes `<key>=true`"), and no wider
# because the DaemonSet header cites ANOTHER service's node label three lines
# under its own `nodeSelector` mention as a shape analogy.
node_label_scan() {
    awk '
    BEGIN { TOK = "[a-z0-9][-a-z0-9.]*/[A-Za-z0-9][-A-Za-z0-9._]*[ \t]*[=:][ \t]*\"?[A-Za-z0-9]" }
    { prev = cur; cur = tolower($0); win = prev " " cur
      arming = (index(win, "nodeselector") > 0) || \
               (win ~ /label/ && win ~ /(^|[^a-z])nodes?([^a-z]|$)/)
      line = $0
      # An `image:` value is `repo/name:tag`, which collides with the label
      # grammar by pure coincidence and can never BE a label. It was carried as a
      # named exemption ("bitnami/kubectl") until the vendor moved the image to
      # docker.io/bitnamilegacy and the stale entry stopped matching — a rot the
      # allowlist could not detect. Excluding the line structurally cannot rot.
      if (cur ~ /^[ \t]*-?[ \t]*image[ \t]*:/) next
      while (match(line, TOK)) {
          tok  = substr(line, RSTART, RLENGTH)
          line = substr(line, RSTART + RLENGTH)
          key  = tok; sub("[ \t]*[=:].*$", "", key)
          printf "%s\t%s\t%d\t%s\n", (arming ? "NODE" : "OTHER"), key, NR, tok
      }
    }' "$1"
}

# node_label_other_ok <key> <file-basename> -> the reason it is not a node label,
# or empty. Each entry needs a written reason, exactly like census_exempt(): the
# point of naming them is that anything NOT named goes red, so a node label the
# window classifier missed cannot sit quietly in the OTHER bucket.
#
# This list governs the OTHER bucket ONLY. It is not an escape hatch from the
# NODE comparison — `hugmesh.net/vpn-egress` is listed here as a POD
# label, and if it ever appears in a node-arming passage it is still graded
# against DS_NODE and still fails. That ordering is the first defence against
# the transposition.
#
# THE CONFUSABLE ENTRIES ARE SCOPED TO THE ONE FILE THEY BELONG IN, and that is
# the second defence. The window classifier reads two lines; a node-arming
# instruction whose verb sits THREE lines above its label token reaches the OTHER
# bucket, and if its key were globally allow-listed it would then pass. So the
# keys that could plausibly be mistaken for this node label are legal in exactly
# the file that legitimately mentions them: `vpn-egress` in the doc that
# documents the pod leg, `compute` in the DaemonSet header that cites it as a
# shape. The same key anywhere else is unclassified, and unclassified is red.
# Only the two upstream-reserved namespaces and the slug selector — none of them
# confusable with a node key, all graded elsewhere — are allowed file-wide.
node_label_other_ok() {
    case "$2:$1" in
      *:app.kubernetes.io/*)
        echo "upstream's recommended object labels — they select Pods for the DaemonSet's own matchLabels, never Nodes" ;;
      *:argocd.argoproj.io/*)
        echo "ArgoCD's own annotation namespace (sync-wave) — ordering metadata on the Application, not a node label" ;;
      *:hugmesh.net/optional-service)
        echo "the SLUG selector: the label on the config Secrets (and the tag on every optional-service object). Graded against the contract by the kustomization/registry/writer assertions in this file — a Secret selector, not a node selector" ;;
      EGRESS-VPN.md:hugmesh.net/vpn-egress)
        echo "the POD opt-in label: hugmesh-vpn-mark sets it on marked pods and manifests/networkpolicy/egress-vpn-interaction.yaml's podSelector matches it. A different carrier with a different consumer, and ONE TRANSPOSITION away from the node key — so it is legal HERE, in the doc that explains the pod leg, and nowhere else" ;;
      secret-projector-daemonset.yaml:hugmesh.net/compute)
        echo "the GPU plugin's node label, cited in this DaemonSet's header as the shape this one copies — another service's key, legal in this header and nowhere else" ;;
      *) echo "" ;;
    esac
}

# The DaemonSet is in this list too: its header carries a PROSE copy of the
# nodeSelector three dozen lines above the mapping, and nothing graded it.
for f in "${DS}" "${KUST}" "${APP13E}" "${DOC}"; do
    rl="${f#"${REPO}"/}"; base="${rl##*/}"
    armed=0; wrong=0; unclassified=0; det=""
    while IFS="$(printf '\t')" read -r cls key ln tok; do
        [ -n "${cls}" ] || continue
        if [ "${cls}" = "NODE" ]; then
            armed=$((armed+1))
            [ "${key}" = "${DS_NODE}" ] && continue
            wrong=$((wrong+1))
            det="${det}         ${base}:${ln} arms a node with '${key}' — the scheduler selects '${DS_NODE}'  [${tok}…]
"
        elif [ -z "$(node_label_other_ok "${key}" "${base}")" ]; then
            unclassified=$((unclassified+1))
            det="${det}         ${base}:${ln} carries label '${key}', neither node-arming nor a non-node label known IN THIS FILE  [${tok}…]
"
        fi
    done <<SCAN_EOF
$(node_label_scan "${f}")
SCAN_EOF
    okf "${f}" "$( [ "${wrong}" -eq 0 ] && echo 0 || echo 1 )" \
        "${base}: all ${armed} node-arming mention(s) spell the scheduler's key ${DS_NODE}" \
        "${base}: ${wrong} node-arming mention(s) do not spell ${DS_NODE} — a reader following this file labels a node the projector does not select, and nothing errors"
    okf "${f}" "$( [ "${armed}" -ge 1 ] && echo 0 || echo 1 )" \
        "${base}: names the node-arming label at least once" \
        "${base}: names NO node-arming label at all — either the instruction was dropped (nobody can open gate 2 from this file) or it was reworded past the scanner. Both are red on purpose: a scan that finds nothing agrees with everything, which is how the previous version of this control passed"
    okf "${f}" "$( [ "${unclassified}" -eq 0 ] && echo 0 || echo 1 )" \
        "${base}: every other label it names is a known non-node label" \
        "${base}: ${unclassified} label(s) are neither node-arming nor known non-node — give each a reason in node_label_other_ok(), or it is a node label this scanner cannot see"
    [ -n "${det}" ] && printf '%s' "${det}"
done

# Read the namespace out of the `destination:` BLOCK, not `| tail -1` of every
# `namespace:` in the file. 13e legitimately carries two (metadata.namespace is
# `devops`), and "the last one wins" is a parser that silently starts grading a
# different field the moment somebody appends a key.
eqf "${APP13E}" "apps/13e destination namespace" \
   "$(awk '/^[[:space:]]*destination:/{d=1;next} d&&/^[[:space:]]*[a-zA-Z]/{if($1!~/^(server|namespace):$/&&$1!~/^(server|namespace):/){d=0}} d&&/^[[:space:]]*namespace:/{sub(/^[[:space:]]*namespace:[[:space:]]*/,"");sub(/[[:space:]]*$/,"");print;exit}' "${APP13E}")" \
   "${C_NS}"

# ── 1b. THE REGISTRY COPY — specs/cluster/optional-services.yaml ──────────────
# The FOURTH copy, and the one nothing read. optional-services.yaml is the
# repo's source of truth for WHICH optional services exist; it is NOT the source
# of truth for this contract, but it carried its own secretNamespace/secretLabel/
# secretKey triple anyway — and `secretKey` sat at `config`, the exact value this
# whole change declared broken, for as long as the entry existed. Two "single
# sources of truth" is not redundancy, it is a drift engine with a spare.
echo "-- registry copy (optional-services.yaml)"
eqf "${REGISTRY}" "registry secretNamespace" \
    "$(registry_field "${REGISTRY}" egress-vpn secretNamespace || echo '<unreadable>')" "${C_NS}"
eqf "${REGISTRY}" "registry secretLabel" \
    "$(registry_field "${REGISTRY}" egress-vpn secretLabel || echo '<unreadable>')" "${C_SEL}"
eqf "${REGISTRY}" "registry secretKey" \
    "$(registry_field "${REGISTRY}" egress-vpn secretKey || echo '<unreadable>')" "${C_KEY}"
eqf "${REGISTRY}" "registry nodeDeliveryLabel" \
    "$(registry_field "${REGISTRY}" egress-vpn nodeDeliveryLabel || echo '<unreadable>')" "${C_NODE}"
# …and it must point at the file that wins, so the next reader of the registry
# knows these three are copies before they trust one.
eqf "${REGISTRY}" "registry secretContract pointer" \
    "$(registry_field "${REGISTRY}" egress-vpn secretContract || echo '<absent>')" \
    "${CONTRACT#"${REPO}"/}"

# The census is per-FILE, so a SECOND slug growing its own delivery contract
# inside this same file would ride egress-vpn's verification and be graded by
# nothing — the fourth-copy defect reproduced one indentation level down. Every
# secret{Namespace,Label,Key} line in the registry must therefore live in the
# block this test actually reads.
REG_TOTAL="$(grep -cE '^[[:space:]]*secret(Namespace|Label|Key):' "${REGISTRY}" || true)"
okf "${REGISTRY}" "$( [ "${REG_TOTAL}" = "3" ] && echo 0 || echo 1 )" \
    "registry declares the delivery contract in exactly one slug block (${REG_TOTAL} field lines, all egress-vpn's)" \
    "registry has ${REG_TOTAL} secret{Namespace,Label,Key} lines but only egress-vpn's 3 are graded — a second slug's delivery contract is being asserted by nothing; give it a secretContract: pointer and assert it here"

# ── 1c. THE DOC COPY — docs/EGRESS-VPN.md's contract table ────────────────────
# The doc's `| what | contract | the reader shipped | the writer shipped |` table
# is the human-facing copy. Its 2nd column MUST track the contract; its 3rd and
# 4th columns MUST NOT — they are the historical record of what each half
# actually shipped (`hugmesh-backend` ✘, `config` ✘) and rewriting them to match
# would erase the evidence. So the contract column is asserted and the shipped
# columns are deliberately left alone; see the census exemption note below.
echo "-- doc copy (docs/EGRESS-VPN.md contract table)"
doc_row(){ # doc_row <row-label> -> the 2nd column, backticks stripped
    sed -n -E "s/^\|[[:space:]]*$1[[:space:]]*\|([^|]*)\|.*/\1/p" "${DOC}" \
        | head -1 | tr -d '`' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}
eqf "${DOC}" "doc table namespace (contract column)" "$(doc_row namespace)" "${C_NS}"
eqf "${DOC}" "doc table label (contract column)"     "$(doc_row label)"     "${C_SEL}"
D_KEY_CELL="$(doc_row 'data key')"
case "${D_KEY_CELL}" in
    *"(${C_KEY})"*|"${C_KEY}") ok "doc table data key (contract column) names ${C_KEY}" ;;
    *) bad "doc table data key column is '${D_KEY_CELL}' — it does not name the contract key '${C_KEY}'" ;;
esac

# ══════════════════════════════════════════════════════════════════════════════
# 2. THE DEPLOY LEVER — this repo tells admin-bff where to write
# ══════════════════════════════════════════════════════════════════════════════
echo "-- deploy lever (admin-bff Deployment, this repo)"
D_NS="$(manifest_env "${BFF_DEPLOY}" EGRESS_VPN_SECRET_NAMESPACE || echo '<absent>')"
eqf "${BFF_DEPLOY}" "admin-bff EGRESS_VPN_SECRET_NAMESPACE" "${D_NS}" "${C_NS}"
D_EN="$(manifest_env "${BFF_DEPLOY}" EGRESS_VPN_SECRET_DELIVERY_ENABLED || echo '<absent>')"
[ "${D_EN}" = "false" ] \
    && ok "admin-bff EGRESS_VPN_SECRET_DELIVERY_ENABLED is false (ships dark)" \
    || bad "admin-bff EGRESS_VPN_SECRET_DELIVERY_ENABLED is '${D_EN}' — this leg must ship dark"

# ══════════════════════════════════════════════════════════════════════════════
# 2.5. THE COPY CENSUS — "every place the contract is written" as an ASSERTION
# ══════════════════════════════════════════════════════════════════════════════
# WHY THIS EXISTS AND NOT JUST FOUR MORE eq LINES. The first cut of this gate
# asserted the three copies its author happened to know about and declared ONE
# SOURCE OF TRUTH. A fourth — optional-services.yaml — was sitting in the tree
# the whole time carrying `secretKey: config`, and no test read it. Adding a
# fifth assertion fixes the fourth copy; it does nothing about the fifth copy.
# The defect is not "we missed a file", it is "nothing in this repo can tell us
# when we miss a file".
#
# So: SEARCH for the contract rather than enumerate it. Every machine-read
# carrier of a contract value in the tree must be either
#   * VERIFIED — a comparison in this run actually read a value out of it
#     (the ${V} set, populated from inside eqf/okf, never by hand), or
#   * EXEMPT   — listed below WITH A WRITTEN REASON.
# A new file that carries a copy is in neither, so it goes red until somebody
# decides which it is. That is the whole point: the census fails on copies that
# did not exist when it was written.
#
# SCOPE, stated plainly. Detector A is repo-wide over tokens that can only mean
# this contract (`EGRESS_VPN_SECRET_*`, the projector's `SECRET_NS/SEL/KEY`, the
# selector literal, the `@name` sentinel, and the namespace in a YAML
# name:/namespace:/secretNamespace: value or a `-n`/`--namespace` argument).
# Detector B adds the generic-elsewhere field names `secretNamespace:` /
# `secretLabel:` / `secretKey:` but ONLY in files that also mention egress-vpn —
# because `secretKey:` is a core ExternalSecret field appearing ~120 times in
# this repo with nothing to do with VPNs, and a census that cries wolf gets
# muted. Detector B is what catches a copy that has DRIFTED (a
# `secretNamespace: hugmesh-backend` no longer matches any value-keyed pattern).
#
# NOT censused, deliberately: bare prose mentions of the namespace string in the
# node-image tree (specs/usr, specs/etc, specs/selinux, specs-*/, build-*.sh),
# where `hugmesh-egress-vpn` is the name of an OpenRC SERVICE, not a Kubernetes
# namespace — a homonym, ~40 hits, none of which can misconfigure delivery.
echo "-- copy census (every machine-read carrier of a contract value)"

# The two operator runbooks are prose, but they are also the thing a human
# retypes into a cluster, so they are VERIFIED above (§1c, and the kustomization
# selector in §1), not exempted.
census_exempt(){ # census_exempt <path> -> prints the reason, or nothing
    case "$1" in
      specs/cluster/manifests/networkpolicy/egress-vpn-interaction.yaml)
        echo "slug TAG on a NetworkPolicy object (every optional-service object carries hugmesh.net/optional-service), NOT a copy of the Secret SELECTOR — nothing here selects a Secret, and coupling the two would turn a legitimate slug-tag change into a false contract break" ;;
      tests/egress-vpn/*)
        echo "the guards themselves + lib: they READ the contract, and their fixtures deliberately carry the OLD wrong values (ns=hugmesh-backend, key=config) to prove the guard fails on them — asserting fixtures against the contract would delete the negative cases" ;;
      *) echo "" ;;
    esac
}

RE_A='EGRESS_VPN_SECRET_[A-Z_]+|SECRET_(NS|SEL|KEY)([^A-Z_]|$)'
RE_A="${RE_A}|hugmesh\\.net/optional-service[[:space:]]*[=:][[:space:]]*egress-vpn|@name"
RE_A="${RE_A}|^[[:space:]]*(namespace|name|secretNamespace):[[:space:]]*\"?${C_NS}\"?[[:space:]]*\$"
RE_A="${RE_A}|(-n|--namespace[= ])[[:space:]]*\"?${C_NS}"
RE_A="${RE_A}|${C_NODE}[=:]|nodeDeliveryLabel[[:space:]]*:"
RE_B='(^|[^A-Za-z_])secret(Namespace|Label|Key)[[:space:]]*:'

# A path inside a checkout that is NOT this repo. The egress-vpn-node-agents job
# clones the admin-bff sibling to ${CI_PROJECT_DIR}/.egress-vpn-siblings — i.e.
# INSIDE the tree being censused — so without this the census reads the WRITER's
# own EGRESS_VPN_SECRET_* declarations as un-asserted copies of this repo's
# contract and the job is red on every run. (It was. This test caught it before
# it shipped, against a real clone.) Keyed on the nested `.git` rather than on
# the directory NAME so any vendored/sibling checkout is handled.
census_nested() {
    local d="${1%/*}"
    while [ -n "${d}" ] && [ "${d}" != "$1" ] && [ "${d}" != "." ]; do
        [ -e "${REPO}/${d}/.git" ] && return 0
        [ "${d}" = "${d%/*}" ] && break
        d="${d%/*}"
    done
    return 1
}

# PORTABILITY, and why it mattered. busybox grep -- what the alpine CI image
# ships -- has NO --exclude-dir: it exits 2 with a usage dump, which the
# `2>/dev/null` below swallowed whole. The census therefore came back EMPTY on
# alpine and every asserted file reported as a "census blind spot": nine
# confident, entirely wrong messages pointing at the manifests instead of at
# grep. find-based pruning is understood by both greps.
_census_textfiles() { # <ere> -> repo-relative text files matching it
    find . -name .git -prune -o -type f -print0 2>/dev/null \
      | xargs -0 grep -lIE "$1" 2>/dev/null | sed 's|^\./||'
}
census_files() {
    ( cd "${REPO}" || exit 0
      # -I: skip binary files. A sibling checkout with build output carries
      # .class files whose constant pool contains these very strings, and a
      # census that reports compiled bytecode as a contract copy gets muted.
      _census_textfiles "${RE_A}"
      # Detector B: only where the file also talks about egress-vpn.
      _census_textfiles 'egress-vpn' | while read -r f; do
          grep -qE "${RE_B}" "${f}" 2>/dev/null && printf '%s\n' "${f}"
      done
    ) | sort -u | while read -r f; do
          census_nested "${f}" || printf '%s\n' "${f}"
      done
}

CENSUS="$(census_files)"
# NON-VACUITY. A blind census is a TOOLING failure, and it has to say so in one
# true sentence rather than as N false "blind spot" reports about the manifests.
CENSUS_N="$(printf '%s\n' "${CENSUS}" | grep -c . 2>/dev/null)"
[ "${CENSUS_N:-0}" -gt 0 ] \
    && ok "census detectors resolved ${CENSUS_N} file(s) — the sweep below is not vacuous" \
    || bad "census_files() resolved NOTHING — the detectors are blind, so every 'blind spot' below would be a false positive. This is a tooling failure, not a contract failure (busybox grep has no --exclude-dir)."
CONTRACT_REL="${CONTRACT#"${REPO}"/}"
unknown=0; exempted=0; checked=0
while IFS= read -r rel; do
    [ -n "${rel}" ] || continue
    # The contract file itself is the DECLARATION, not a copy of one.
    [ "${rel}" = "${CONTRACT_REL}" ] && continue
    case " ${V} " in
        *" ${rel} "*) checked=$((checked+1)); continue ;;
    esac
    reason="$(census_exempt "${rel}")"
    if [ -n "${reason}" ]; then
        exempted=$((exempted+1))
        echo "  note EXEMPT ${rel}"
        echo "         because ${reason}"
        continue
    fi
    unknown=$((unknown+1))
    bad "UN-ASSERTED contract copy: ${rel}"
    ( cd "${REPO}" && grep -nE "${RE_A}|${RE_B}" "${rel}" 2>/dev/null | head -6 | sed 's/^/         /' )
    echo "         -> assert it against ${CONTRACT_REL} in this file, or add it to census_exempt() WITH a reason."
done <<CENSUS_EOF
${CENSUS}
CENSUS_EOF

if [ "${unknown}" -eq 0 ]; then
    ok "census: ${checked} carrier(s) verified against the contract, ${exempted} exempt, 0 un-asserted"
fi

# THE VACUITY CONTROL. Read in the other direction: every file the assertions
# above actually read a value out of must ALSO be visible to the detectors. A
# census whose regexes stop matching would otherwise report "0 carriers, 0
# un-asserted" and go green — a guard that grades an empty set is worse than no
# guard, because it looks like coverage. With this, detectors that go blind take
# every verified file red at once instead.
for rel in ${V}; do
    printf '%s\n' "${CENSUS}" | grep -xF "${rel}" >/dev/null \
        || bad "census blind spot: ${rel} is asserted above but matches no census detector — the detectors no longer see the file they are supposed to police"
done

# ══════════════════════════════════════════════════════════════════════════════
# 3. THE WRITER HALF — hugmesh-admin-bff-api. MANDATORY.
# ══════════════════════════════════════════════════════════════════════════════
echo "-- writer (hugmesh-admin-bff-api)"

SIB=""
# An EXPLICIT root that does not exist is an error, never a quiet fall-through to
# some other checkout — "I pointed it at X and it silently graded Y" is the same
# family of lie this whole file exists to stop.
if [ -n "${EGRESS_VPN_ADMIN_BFF_ROOT:-}" ] && [ ! -d "${EGRESS_VPN_ADMIN_BFF_ROOT}" ]; then
    echo "  FAIL EGRESS_VPN_ADMIN_BFF_ROOT=${EGRESS_VPN_ADMIN_BFF_ROOT} is not a directory" >&2
    echo "== RESULT: ${P} passed, ${F} failed, WRITER HALF UNCHECKED =="
    exit 3
fi
for cand in \
    "${EGRESS_VPN_ADMIN_BFF_ROOT:-}" \
    "${CI_PROJECT_DIR:-${REPO}}/.egress-vpn-siblings/hugmesh-admin-bff-api" \
    "${REPO}/../hugmesh-admin-bff-api" \
    "${REPO}/../../hugmesh-admin-bff-api" \
    "${REPO}/../../../hugmesh-admin-bff-api" \
    "${REPO}/../../../../hugmesh-admin-bff-api"
do
    [ -n "${cand}" ] || continue
    if [ -d "${cand}" ]; then SIB="$(cd "${cand}" && pwd)"; break; fi
done

if [ -z "${SIB}" ]; then
    cat >&2 <<MSG

  ══════════════════════════════════════════════════════════════════════════
  INCOMPLETE — the hugmesh-admin-bff-api checkout is absent, so the WRITER
  half of the contract was not checked. This is a FAILURE, not a skip: the
  defect this gate exists for lives entirely in the disagreement between the
  two repos, and half a comparison catches none of it.

  Provide the sibling with EGRESS_VPN_ADMIN_BFF_ROOT=<path>, or clone it to
  \${CI_PROJECT_DIR}/.egress-vpn-siblings/hugmesh-admin-bff-api (the
  .gitlab-ci.yml egress-vpn-node-agents job does exactly that, the same way
  lint:reserved-prefixes clones its ReservedNames.java copies).
  ══════════════════════════════════════════════════════════════════════════
MSG
    echo "== RESULT: ${P} passed, ${F} failed, WRITER HALF UNCHECKED =="
    exit 3
fi

# Read from origin/main when the sibling is a git checkout — never from a working
# tree another session may be mid-edit in. Falls back to the file on disk.
W_REL="src/main/java/net/hugmesh/adminbff/egressvpn/Fabric8VpnConfigSecretWriter.java"
Y_REL="src/main/resources/application.yml"
SIB_REF=""
for ref in origin/main origin/HEAD; do
    if git -C "${SIB}" rev-parse --verify -q "${ref}" >/dev/null 2>&1; then SIB_REF="${ref}"; break; fi
done
read_sib() {
    if [ -n "${SIB_REF}" ]; then git -C "${SIB}" show "${SIB_REF}:$1" 2>/dev/null
    else cat "${SIB}/$1" 2>/dev/null; fi
}
WRITER_SRC="$(read_sib "${W_REL}")"
APP_YML="$(read_sib "${Y_REL}")"

if [ -z "${WRITER_SRC}" ] || [ -z "${APP_YML}" ]; then
    echo "  FAIL sibling found at ${SIB} but ${W_REL} / ${Y_REL} unreadable" >&2
    echo "== RESULT: ${P} passed, ${F} failed, WRITER HALF UNCHECKED =="
    exit 3
fi
ok "reading the writer half from ${SIB} @ ${SIB_REF:-working tree}"

# 3a. DATA KEY. `.addToStringData(<arg>, configBody)`: `secretRef` means the key
# IS the Secret's own name, which the contract spells `@name`; a quoted literal
# means the contract must carry that literal instead.
SD_ARG="$(printf '%s\n' "${WRITER_SRC}" | sed -n -E 's/.*\.addToStringData\(([^,]+),.*/\1/p' | head -1 | tr -d ' ')"
case "${SD_ARG}" in
    "")          bad "could not find .addToStringData(...) in ${W_REL} — the writer changed shape" ;;
    secretRef)   eq "writer data key (derived: == secretRef)" "@name" "${C_KEY}" ;;
    \"*\")       eq "writer data key (literal)" "$(printf '%s' "${SD_ARG}" | tr -d '"')" "${C_KEY}" ;;
    *)           bad "writer data key comes from an unrecognised expression '${SD_ARG}' — re-read ${W_REL}" ;;
esac

# 3b. Secret NAME == secretRef (this is what makes the projected FILENAME right).
printf '%s\n' "${WRITER_SRC}" | grep -E '\.withName\(secretRef\)' >/dev/null \
    && eq "writer Secret name" "secretRef" "${C_NAME}" \
    || bad "writer no longer sets metadata.name from secretRef — the projected filename contract breaks"

# 3c. LABEL — the selector the projector lists by.
W_LK="$(printf '%s\n' "${WRITER_SRC}" | sed -n -E 's/.*\.addToLabels\("([^"]*optional-service)",[[:space:]]*"([^"]*)"\).*/\1/p' | head -1)"
W_LV="$(printf '%s\n' "${WRITER_SRC}" | sed -n -E 's/.*\.addToLabels\("([^"]*optional-service)",[[:space:]]*"([^"]*)"\).*/\2/p' | head -1)"
if [ -n "${W_LK}" ]; then
    eq "writer label key"   "${W_LK}" "${C_SEL_KEY}"
    eq "writer label value" "${W_LV}" "${C_SEL_VAL}"
else
    bad "writer does not stamp an optional-service label — the projector's selector would match nothing"
fi

# 3d. NAMESPACE. The writer's namespace is a DEPLOY LEVER; assert the env name we
# set in the Deployment is the one it actually binds, and that when the app's own
# default differs from the contract the Deployment is what closes the gap.
NS_HITS="$(printf '%s\n' "${APP_YML}" | grep -cE '\$\{EGRESS_VPN_SECRET_NAMESPACE:' || true)"
if [ "${NS_HITS}" = "1" ]; then
    ok "writer binds the namespace to \${EGRESS_VPN_SECRET_NAMESPACE:…} (the env the Deployment sets)"
    W_NS_DEFAULT="$(printf '%s\n' "${APP_YML}" | sed -n -E 's/.*\$\{EGRESS_VPN_SECRET_NAMESPACE:([^}]*)\}.*/\1/p' | head -1)"
    if [ "${W_NS_DEFAULT}" = "${C_NS}" ]; then
        ok "writer's own default namespace already equals the contract (${C_NS})"
    elif [ "${D_NS}" = "${C_NS}" ]; then
        ok "writer defaults to '${W_NS_DEFAULT}' but the Deployment overrides it to the contract ${C_NS}"
    else
        bad "writer defaults to '${W_NS_DEFAULT}', contract is '${C_NS}', and the Deployment does not override it — the halves write and read different namespaces"
    fi
else
    bad "\${EGRESS_VPN_SECRET_NAMESPACE:…} appears ${NS_HITS} times in ${Y_REL} — the env name this repo sets is not the one the writer binds"
fi

# 3e. The enabled lever: same env name, and dark by default on the writer side.
W_EN_DEFAULT="$(printf '%s\n' "${APP_YML}" | sed -n -E 's/.*\$\{EGRESS_VPN_SECRET_DELIVERY_ENABLED:([^}]*)\}.*/\1/p' | head -1)"
[ "${W_EN_DEFAULT}" = "false" ] \
    && ok "writer's EGRESS_VPN_SECRET_DELIVERY_ENABLED defaults false (ships dark on both sides)" \
    || bad "writer's EGRESS_VPN_SECRET_DELIVERY_ENABLED default is '${W_EN_DEFAULT:-<absent>}', not false"

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
