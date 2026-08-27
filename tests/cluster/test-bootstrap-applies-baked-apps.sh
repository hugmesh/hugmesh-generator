#!/usr/bin/env bash
# test-bootstrap-applies-baked-apps.sh — does a DEVICE actually run only the
# services its image was built with?
#
# THE BUG THIS EXISTS FOR (observed 2026-08-26, on the tree as committed):
#   specs/cluster/bootstrap/bootstrap.sh applied exactly ONE Application —
#   ${CLUSTER_DIR}/app-of-apps.yaml — whose source is
#       repoURL: https://github.com/hugmesh/hugmesh-generator.git
#       targetRevision: main
#       path: specs/cluster/apps
#       directory: {recurse: true}
#   Nothing in bootstrap.sh, and nothing in specs/etc/keys-provision/provision.sh,
#   ever read the BAKED /var/lib/hugmesh/cluster/apps tree. So ArgoCD instantiated
#   specs/cluster/apps AS IT EXISTS ON GITHUB MAIN, and every `rm -f` that
#   gate_optional_services() performs in build-rpi5-stage4.sh /
#   build-x86-host-stage4.sh edited a directory ArgoCD never read. A device built
#   with `--optional-services akkoma` still received tuwunel, phpbb, games,
#   owncast and tube. The build-time prune was not incomplete — it was INERT.
#
# THE VACUITY HAZARD THIS TEST IS SHAPED AROUND:
#   A test asserting "the pruned sysroot does not contain apps/30-tuwunel.yaml"
#   PROVES NOTHING about what ArgoCD syncs. That exact assertion was GREEN
#   throughout the entire lifetime of the bug above — tests/stack/
#   test-optional-services-exclude.sh makes it, correctly, and it could not have
#   caught this. So this test does NOT look at the sysroot at all. It DRIVES
#   bootstrap.sh with a stub `kubectl` on PATH that captures every manifest
#   actually applied, and asserts on THE RESOLVED SOURCE of what was applied:
#     * no applied Application re-imports specs/cluster/apps from a git repo
#       (that is the recursing root, in any spelling of repoURL/targetRevision);
#     * the applied Application NAME set matches the SELECTION, not the repo;
#     * the applied Application CONTENT is the baked, gate-edited content — the
#       gateway routes gate_optional_services() deleted from apps/20-gateway-be.yaml
#       are absent from what reaches the cluster. That last one can only pass if
#       the bytes came from the baked tree, so it also pins the provenance.
#
# WHAT IT DOES NOT PROVE:
#   * Nothing about a real ArgoCD. The stub records `kubectl apply` payloads; it
#     does not reconcile them. "ArgoCD would create Application X" is inferred
#     from "Application X was applied", which is exactly the step that was
#     missing, but a live-cluster assertion this is not.
#   * Nothing about the MANIFEST content each surviving Application pulls: the
#     child Applications still source specs/cluster/manifests/<dir> from the git
#     repo, so a baked edit UNDER manifests/ (installed-services ConfigMap,
#     seed-optionalservices.yaml, route-access SQL) still does not reach the
#     cluster. Fixing that needs a pruned SOURCE (an in-cluster repo server, the
#     kind-local shape), which this change does not attempt. See
#     specs/cluster/README.md "What the device syncs".
#   * Nothing about arm64/amd64 differences: it drives the shared
#     specs/cluster/bootstrap/bootstrap.sh with the rpi5 builder's gate. That is
#     now a WEAKER caveat than it reads: this branch was written while each builder
#     carried its own copy of the gate, and its commit message said "the 13a guard
#     is rpi5-only by construction" because x86 had no _opt_render_appset_flag at
#     all. Both halves have since changed — the gate is ONE shared
#     scripts/_optional-services-lib.sh, and x86's missing renderer was defect #1
#     of the x86 builder drift — so the guard this suite exercises is the SAME code
#     x86 runs. tests/stack/test-optional-services-exclude.sh asserts, per builder,
#     that neither carries a local override, which is what makes "the rpi5 gate" a
#     legitimate stand-in here rather than a blind spot.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILDER="${REPO_ROOT}/build-rpi5-stage4.sh"
SRC="${REPO_ROOT}/specs/cluster"
BOOTSTRAP_SRC="${SRC}/bootstrap/bootstrap.sh"
[ -f "${BUILDER}" ]       || { echo "  FAIL builder missing: ${BUILDER}"; exit 1; }
[ -f "${BOOTSTRAP_SRC}" ] || { echo "  FAIL bootstrap missing: ${BOOTSTRAP_SRC}"; exit 1; }

P=0; F=0
ok(){  echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
info(){ :; }; warn(){ :; }; err(){ echo "    ERR $*" >&2; }   # silence the builder logger

echo "== bootstrap applies the BAKED, GATED Application set (not the repo) =="

# ── Load the REAL gate + helpers AS THE BUILDER RESOLVES THEM ─────────────────
# NOT `awk` over build-rpi5-stage4.sh. The gate was EXTRACTED into one shared
# scripts/_optional-services-lib.sh that both builders source (three defects
# shipped on x86 only while each builder carried its own copy), so awk-ing the
# builder finds nothing and this suite died "could not extract _opt_selected".
# tests/lib/opt-gate-source.sh reproduces BASH'S OWN resolution order — every
# sourced scripts/*-lib.sh in source order, the builder LAST — so a builder-local
# override still wins and is still what this suite runs. That matters here more
# than anywhere: this suite's whole point is that what the DEVICE applies must be
# what the BUILDER actually produced.
source "${REPO_ROOT}/tests/lib/opt-gate-source.sh"
opt_gate_load "${BUILDER}" _opt_selected _opt_explicitly_deselected _opt_anubis_installed \
          _opt_drop_kustomize_line _opt_drop_route _opt_drop_extrahost _opt_drop_rows \
          _opt_fix_trailing_comma _opt_wire_anubis_ingress \
          _opt_appset_element_path _opt_appset_cutover_done \
          _opt_set_cr_enabled _opt_render_optionalservice_cr \
          _opt_federation_module _opt_gate_sql_value _opt_render_federation_modules \
          _opt_render_appset_flag _opt_render_installed_services gate_optional_services || exit 1
ok "loaded the real gate + helpers as build-rpi5-stage4.sh resolves them"

# ── The stub PATH: kubectl captures every applied manifest; curl fakes the ─────
#    upstream ArgoCD install fetch (no network in this test).
STUB="${WORK}/bin"; mkdir -p "${STUB}"
cat > "${STUB}/kubectl" <<'STUBEOF'
#!/usr/bin/env bash
# Stub kubectl. Records every `apply` payload into ${KUBECTL_CAPTURE}/ as one
# file per invocation, and answers the handful of reads bootstrap.sh performs.
set -u
CAP="${KUBECTL_CAPTURE}"
mkdir -p "${CAP}"
printf '%s\n' "$*" >> "${CAP}/calls.log"
# The -f target, if any (bootstrap always pipes, i.e. `-f -`).
fpath=""; prev=""
for a in "$@"; do
  case "${prev}" in -f|--filename) fpath="${a}" ;; esac
  prev="${a}"
done
kustomize=0
for a in "$@"; do case "${a}" in -k|--kustomize) kustomize=1 ;; esac; done
verb=""
for a in "$@"; do
  case "${a}" in
    apply|get|patch|delete|create|label|rollout|version|wait) verb="${a}"; break ;;
  esac
done
# ── SCRIPTABLE hugmesh-root retirement fixture ───────────────────────────────
# The retirement path in bootstrap.sh is the single most destructive step in the
# script (a delete of the root Application with ArgoCD's resources-finalizer
# still attached CASCADE-DELETES the whole platform), so the stub can be told to
# simulate a cluster that HAS a pre-existing root and to fail each safety step:
#   STUB_ROOT_PATH        — what `get application hugmesh-root -o
#                           jsonpath={.spec.source.path}` returns. Empty (default)
#                           => no pre-existing root, the retirement is skipped.
#   STUB_PATCH_RC         — rc of `patch application hugmesh-root` (default 0).
#   STUB_ROOT_FINALIZERS  — what `get application hugmesh-root -o
#                           jsonpath={.metadata.finalizers}` returns AFTER the
#                           patch. Empty (default) => the strip took effect.
#   STUB_GET_FIN_RC       — rc of that finalizers read (default 0); non-zero
#                           simulates an RBAC denial on the VERIFY step.
# ── SCRIPTABLE partial-failure fixture ───────────────────────────────────────
#   STUB_CRD_FAIL         — non-empty => `get crd/<x>` and `wait crd/<x>` fail,
#                           i.e. the argoproj CRDs never become Established.
#   STUB_FLAKY_TOKEN      — an apply whose STDIN payload contains this token
#   STUB_FLAKY_TIMES        fails (transient API error) the first N times, then
#                           succeeds. Drives the bounded-retry path.
case "${verb}" in
  version) exit 0 ;;
  apply)
    # `apply -k <dir>` carries no stdin payload; capturing it would block on a tty.
    [ "${kustomize}" -eq 1 ] && exit 0
    n=$(find "${CAP}" -maxdepth 1 -name 'manifest-*.yaml' | wc -l)
    out="${CAP}/manifest-$(printf '%04d' "${n}").yaml"
    if [ -z "${fpath}" ] || [ "${fpath}" = "-" ]; then cat > "${out}"; else cat "${fpath}" > "${out}"; fi
    if [ -n "${STUB_FLAKY_TOKEN:-}" ] && grep -F -- "${STUB_FLAKY_TOKEN}" "${out}" >/dev/null 2>&1; then
      c=0; [ -f "${CAP}/.flaky" ] && c=$(cat "${CAP}/.flaky")
      if [ "${c}" -lt "${STUB_FLAKY_TIMES:-0}" ]; then
        echo "$((c + 1))" > "${CAP}/.flaky"
        rm -f "${out}"          # a failed apply reached nothing; do not record it
        echo "Error from server: etcdserver: request timed out" >&2
        exit 1
      fi
    fi
    exit 0 ;;
  get)
    # lan-dns ConfigMap must be ABSENT so bootstrap takes its documented
    # "app pruned / not deployed" branch instead of trying to patch a Corefile.
    case " $* " in *" lan-dns-corefile "*) exit 1 ;; esac
    case " $* " in *" crd/"*) [ -z "${STUB_CRD_FAIL:-}" ] || exit 1 ;; esac
    case " $* " in
      *" application hugmesh-root "*)
        case " $* " in
          *".spec.source.path"*)
            printf '%s' "${STUB_ROOT_PATH:-}" ; exit 0 ;;
          *".metadata.finalizers"*)
            [ "${STUB_GET_FIN_RC:-0}" -eq 0 ] || {
                echo "Error from server (Forbidden): applications.argoproj.io \"hugmesh-root\" is forbidden" >&2; exit 1; }
            printf '%s' "${STUB_ROOT_FINALIZERS:-}" ; exit 0 ;;
        esac ;;
    esac
    exit 0 ;;
  patch)
    case " $* " in
      *" application hugmesh-root "*)
        [ "${STUB_PATCH_RC:-0}" -eq 0 ] || {
            echo "Error from server (Forbidden): applications.argoproj.io \"hugmesh-root\" is forbidden" >&2
            exit "${STUB_PATCH_RC}"; } ;;
    esac
    exit 0 ;;
  wait)
    case " $* " in *" crd/"*) [ -z "${STUB_CRD_FAIL:-}" ] || exit 1 ;; esac
    exit 0 ;;
  rollout|delete|label|create) exit 0 ;;
  *) exit 0 ;;
esac
STUBEOF
cat > "${STUB}/curl" <<'STUBEOF'
#!/usr/bin/env bash
# Stub curl: stand in for the upstream ArgoCD install.yaml fetch. Emits a single
# NON-Application object so it can never be mistaken for one of the app manifests
# the assertions below count.
cat <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: stub-argocd-install
  namespace: argocd
YAML
STUBEOF
chmod +x "${STUB}/kubectl" "${STUB}/curl"

# ── Seed a FULL baked tree (the whole specs/cluster payload, as an image bakes ──
#    it), gate it to a SELECTION, then drive the REAL bootstrap.sh against it.
#    bootstrap.sh derives CLUSTER_DIR from its own BASH_SOURCE, so placing it at
#    <tree>/bootstrap/bootstrap.sh reproduces the on-device layout exactly.
SELECTED="akkoma"
DESELECTED="tuwunel phpbb games owncast tube"

# Stub scripting knobs — exported so the stub kubectl (a separate process) sees
# them. reset_stub() restores the DEFAULT fixture: no pre-existing hugmesh-root,
# every safety step succeeds.
export STUB_ROOT_PATH="" STUB_PATCH_RC=0 STUB_ROOT_FINALIZERS="" STUB_GET_FIN_RC=0
export STUB_CRD_FAIL="" STUB_FLAKY_TOKEN="" STUB_FLAKY_TIMES=0
reset_stub() {
  export STUB_ROOT_PATH="" STUB_PATCH_RC=0 STUB_ROOT_FINALIZERS="" STUB_GET_FIN_RC=0
  export STUB_CRD_FAIL="" STUB_FLAKY_TOKEN="" STUB_FLAKY_TIMES=0
}

run_bootstrap() {           # $1 = run label, $2 = "gate"|"nogate"; extra env via $3.. as NAME=VALUE
  local label="$1" gate="$2"
  shift 2
  SYSROOT="${WORK}/sysroot-${label}"; rm -rf "${SYSROOT}"
  TREE="${SYSROOT}/var/lib/hugmesh/cluster"
  mkdir -p "$(dirname "${TREE}")"
  cp -r "${SRC}" "${TREE}"
  export SYSROOT
  if [ "${gate}" = "gate" ]; then
    OPTIONAL_SERVICES="${SELECTED}" ENV="test" gate_optional_services
  fi
  CAP="${WORK}/cap-${label}"; rm -rf "${CAP}"; mkdir -p "${CAP}"
  BOOT_LOG="${WORK}/boot-${label}.log"
  # HUGMESH_CRD_TIMEOUT/HUGMESH_APPLY_BACKOFF are pinned small so a stub that
  # ever starts answering "not ready" cannot hang this suite for two minutes.
  env PATH="${STUB}:${PATH}" KUBECTL_CAPTURE="${CAP}" \
      ARGOCD_REPO_PUBLIC=1 KUBECONFIG="${WORK}/kubeconfig" \
      HUGMESH_CRD_TIMEOUT=5 HUGMESH_APPLY_BACKOFF=0 "$@" \
      bash "${TREE}/bootstrap/bootstrap.sh" > "${BOOT_LOG}" 2>&1
  BOOT_RC=$?
}

# Every Application/ApplicationSet NAME in the captured payloads.
applied_names() {
  local f
  for f in "${CAP}"/manifest-*.yaml; do
    [ -e "${f}" ] || continue
    awk '
      /^kind:[[:space:]]*(Application|ApplicationSet)[[:space:]]*$/ { k=1; m=0; next }
      k && /^metadata:[[:space:]]*$/ { m=1; next }
      m && /^  name:[[:space:]]/ { sub(/^  name:[[:space:]]*/,""); print; k=0; m=0 }
    ' "${f}"
  done | sort -u
}
# Every `path:` an applied Application declares (its resolved source directory).
applied_source_paths() {
  local f
  for f in "${CAP}"/manifest-*.yaml; do
    [ -e "${f}" ] || continue
    sed -e 's/#.*$//' "${f}" | sed -n -E 's#^[[:space:]]*path:[[:space:]]*([^[:space:]]+).*#\1#p'
  done | sort -u
}
has_name() { applied_names | grep -x -- "$1" >/dev/null; }

# ─────────────────────────────────────────────────────────────────────────────
# 1) A GATED image: drive bootstrap against a pruned tree.
# ─────────────────────────────────────────────────────────────────────────────
run_bootstrap gated gate
if [ "${BOOT_RC}" -eq 0 ]; then
  ok "bootstrap.sh exited 0 against a gated baked tree"
else
  bad "bootstrap.sh exited ${BOOT_RC} against a gated baked tree; log:"; sed 's/^/      /' "${BOOT_LOG}"
fi

NAPPLIED=$(applied_names | wc -l)
if [ "${NAPPLIED}" -gt 10 ]; then
  ok "bootstrap applied ${NAPPLIED} distinct Applications/ApplicationSets (the baked set, not one root)"
else
  bad "bootstrap applied only ${NAPPLIED} Application object(s) — the baked apps/ tree was not applied"
  applied_names | sed 's/^/      applied: /'
fi

# ── 1a) THE KEYSTONE ASSERTION: nothing re-imports specs/cluster/apps ─────────
# The recursing root is defined by its RESOLVED SOURCE, not by its name: any
# applied Application whose source `path` is specs/cluster/apps pulls the WHOLE
# repo apps directory and re-creates every pruned service. This is the assertion
# that goes red on the real bug, and it is spelled in terms of the source rather
# than the filename precisely so a renamed/re-spelled root cannot slip past.
if applied_source_paths | grep -x 'specs/cluster/apps' >/dev/null; then
  bad "an applied Application resolves its source to path=specs/cluster/apps — the repo-recursing root is back; every build-time prune is inert"
else
  ok "no applied Application resolves its source to specs/cluster/apps (nothing re-imports the repo apps tree)"
fi
# Belt and braces, by name, for both roots that carry that source.
for root in hugmesh-root hugmesh-root-waved; do
  if has_name "${root}"; then
    bad "the repo-recursing root Application '${root}' was applied"
  else
    ok "the repo-recursing root Application '${root}' was NOT applied"
  fi
done

# ── 1b) The applied set matches the SELECTION ────────────────────────────────
if has_name "akkoma"; then
  ok "SELECTED slug 'akkoma' — its Application WAS applied"
else
  bad "SELECTED slug 'akkoma' — its Application was NOT applied"
fi
# ── DESELECTION, by RESOLVED Application NAME, with a vacuity guard ──────────
# REVIEW FIX 2026-08-26. This loop used to read
#     for n in tuwunel phpbb games owncast tube; do ... has_name "${n}" ...
# and THREE of those five assertions COULD NEVER FAIL: apps/50-games.yaml,
# 52-owncast.yaml and 53-tube.yaml declare `hugmesh-games`, `hugmesh-owncast` and
# `hugmesh-tube`, while has_name is an exact `grep -x` on the slug. Proven by
# mutating gate_optional_services() to a no-op: every app file was applied
# unpruned and only tuwunel/phpbb went red. So resolve the slug to the NAME(S)
# its own baked file declares, and refuse to conclude anything from a slug that
# resolves to no name at all.
#
# The resolution is derived from what the gate ACTUALLY DELETED (repo copy minus
# gated copy) rather than from a hand-written slug->name map, so it stays true if
# a file is renamed, and it cannot be satisfied by a file the gate never touches
# (e.g. apps/06-casdoor-games.yaml also matches *-games.yaml but is NOT pruned).
names_in_repo_file() {   # $1 = basename under ${SRC}/apps
  awk '
    /^kind:[[:space:]]*(Application|ApplicationSet)[[:space:]]*$/ { k=1; m=0; next }
    k && /^metadata:[[:space:]]*$/ { m=1; next }
    m && /^  name:[[:space:]]/ { sub(/^  name:[[:space:]]*/,""); print; k=0; m=0 }
  ' "${SRC}/apps/$1"
}
PRUNED_FILES=""
for _f in "${SRC}"/apps/*.yaml; do
  _b="$(basename "${_f}")"
  [ -e "${TREE}/apps/${_b}" ] || PRUNED_FILES="${PRUNED_FILES} ${_b}"
done
if [ -z "${PRUNED_FILES// /}" ]; then
  bad "fixture is VACUOUS: gate_optional_services() deleted NO apps/*.yaml at all, so every deselection assertion below is unfalsifiable"
else
  ok "the gate pruned $(echo ${PRUNED_FILES} | wc -w) apps/*.yaml file(s) from the baked tree"
fi
for slug in ${DESELECTED}; do
  _names=""; _files=""
  for _b in ${PRUNED_FILES}; do
    case "${_b}" in
      *-"${slug}".yaml)
        _files="${_files} ${_b}"
        _names="${_names} $(names_in_repo_file "${_b}" | tr '\n' ' ')" ;;
    esac
  done
  _names="$(printf '%s\n' ${_names} | sort -u | tr '\n' ' ')"
  if [ -z "${_names// /}" ]; then
    bad "VACUITY GUARD: deselected slug '${slug}' resolves to NO Application name from any pruned apps file — its apps file was not pruned at all, so this assertion could not fail"
    # ...and say what DID reach the cluster, resolved from the UNPRUNED repo copy,
    # so the failure names the service instead of only complaining about vacuity.
    for _b in $(cd "${SRC}/apps" && ls -1 -- *-"${slug}".yaml 2>/dev/null); do
      for n in $(names_in_repo_file "${_b}"); do
        if has_name "${n}"; then
          bad "DESELECTED slug '${slug}' — its Application '${n}' (from the UNPRUNED ${_b}) reached the cluster anyway"
        fi
      done
    done
    continue
  fi
  for n in ${_names}; do
    if has_name "${n}"; then
      bad "DESELECTED slug '${slug}' — its Application '${n}' reached the cluster anyway"
    else
      ok "DESELECTED slug '${slug}' — its Application '${n}' (declared by the pruned${_files}) was NOT applied"
    fi
  done
done

# ── 1c) PROVENANCE: the applied bytes are the GATE-EDITED bytes ──────────────
# gate_optional_services() does more than delete files: it edits surviving app
# YAML in place, deleting the HTTP routes that pointed at each pruned upstream
# (_opt_drop_route on apps/20-gateway-be.yaml). Those routes exist verbatim in
# the repo copy. If they are absent from what was applied, the payload can only
# have come from the baked tree — which is the whole claim under test.
# Sanity-check the token first, so a route rename cannot make this vacuous.
if sed -e 's/#.*$//' "${SRC}/apps/20-gateway-be.yaml" | grep -E 'id:[[:space:]]*matrix-api' >/dev/null; then
  ok "provenance probe token 'matrix-api' exists in the REPO copy of apps/20-gateway-be.yaml"
  if grep -R -E 'id:[[:space:]]*matrix-api' "${CAP}" >/dev/null 2>&1; then
    bad "the tuwunel gateway route 'matrix-api' was applied — the payload came from the repo, not the gate-edited baked file"
  else
    ok "the tuwunel gateway route 'matrix-api' is absent from every applied manifest (baked, gate-edited bytes reached the cluster)"
  fi
else
  bad "provenance probe is VACUOUS: 'matrix-api' no longer appears in ${SRC}/apps/20-gateway-be.yaml — repoint this probe at a route _opt_drop_route still deletes"
fi

# ── 1d) The applied set is EXACTLY the baked set — no more, no less ──────────
# A count is not enough (some app files declare more than one Application). Compare
# the NAME SETS: every Application the baked tree declares must have been applied,
# and nothing may have been applied that the baked tree does not declare. The
# second half is what fails if any repo-sourced root sneaks extras back in.
names_in() {   # every Application/ApplicationSet name declared by the files in $1
  local d="$1" f
  for f in "${d}"/*.yaml; do
    [ -e "${f}" ] || continue
    case "$(basename "${f}")" in 00-app-of-apps-waved.yaml) continue ;; esac
    awk '
      /^kind:[[:space:]]*(Application|ApplicationSet)[[:space:]]*$/ { k=1; m=0; next }
      k && /^metadata:[[:space:]]*$/ { m=1; next }
      m && /^  name:[[:space:]]/ { sub(/^  name:[[:space:]]*/,""); print; k=0; m=0 }
    ' "${f}"
  done | sort -u
}
names_in "${TREE}/apps" > "${WORK}/baked-names.txt"
applied_names > "${WORK}/applied-names.txt"
# POST-CONDITION on the fixture itself: a comparison of two empty sets would be
# green and meaningless, so refuse to draw a conclusion from one.
if [ ! -s "${WORK}/baked-names.txt" ]; then
  bad "fixture is VACUOUS: the baked apps/ tree declares no Application at all"
else
  MISSING="$(comm -23 "${WORK}/baked-names.txt" "${WORK}/applied-names.txt")"
  EXTRA="$(comm -13 "${WORK}/baked-names.txt" "${WORK}/applied-names.txt")"
  if [ -z "${MISSING}" ]; then
    ok "every Application the baked tree declares ($(wc -l < "${WORK}/baked-names.txt")) was applied"
  else
    bad "baked Applications that were NOT applied: $(echo ${MISSING})"
  fi
  if [ -z "${EXTRA}" ]; then
    ok "no Application was applied that the baked tree does not declare"
  else
    bad "applied but NOT in the baked tree: $(echo ${EXTRA})"
  fi
fi

# ── 1e) The FORK/MIRROR override actually reaches all 74 manifests ───────────
# REVIEW FIX 2026-08-26 (surviving mutation MX4). apply_baked_app()'s whole body
# could be replaced with `cat "$1" | kubectl apply -f -` — deleting the
# repoURL/targetRevision substitution outright — and this suite stayed 21/21
# green, while the code comment and the commit message both claim the override
# still works and the change multiplies that substitution from ONE apply to ~74.
# If it regresses, a device built against a fork/mirror (HUGMESH_GITOPS_REPO /
# HUGMESH_GITOPS_REV, patched onto the device via /etc/hugmesh/gitops.env)
# applies 74 Applications all pointing at the upstream PRIVATE
# github.com/hugmesh/hugmesh-generator; every one fails to sync with
# "authentication required: Repository not found" and bootstrap.sh exits 0
# reporting "applied 74 baked Application manifest(s), 0 failed".
FORK_URL="https://example.invalid/fork.git"
FORK_REV="my-branch"
reset_stub
run_bootstrap fork gate \
  HUGMESH_GITOPS_REPO="${FORK_URL}" HUGMESH_GITOPS_REV="${FORK_REV}"
if [ "${BOOT_RC}" -eq 0 ]; then
  ok "bootstrap.sh exited 0 with HUGMESH_GITOPS_REPO/REV overridden to a fork"
else
  bad "bootstrap.sh exited ${BOOT_RC} with a fork override; log:"; sed 's/^/      /' "${BOOT_LOG}"
fi
# NON-VACUITY FIRST: the capture must contain manifests at all, and the upstream
# literal must exist in the REPO copy — otherwise "no upstream URL survived"
# would be trivially true.
NCAP=$(find "${CAP}" -maxdepth 1 -name 'manifest-*.yaml' | wc -l)
UPSTREAM_IN_REPO=$(grep -R -l -F 'repoURL: https://github.com/hugmesh/hugmesh-generator.git' "${SRC}/apps" 2>/dev/null | wc -l)
if [ "${NCAP}" -gt 10 ] && [ "${UPSTREAM_IN_REPO}" -gt 10 ]; then
  ok "fork-override probe is non-vacuous: ${NCAP} manifests captured, ${UPSTREAM_IN_REPO} repo apps files carry the upstream repoURL literal"
else
  bad "fork-override probe is VACUOUS: ${NCAP} manifests captured / ${UPSTREAM_IN_REPO} repo apps files carry the upstream repoURL — cannot conclude anything"
fi
# (a) no applied manifest still points at the upstream private repo
LEFT_UPSTREAM=$(grep -R -l -F 'repoURL: https://github.com/hugmesh/hugmesh-generator.git' "${CAP}" 2>/dev/null | wc -l)
if [ "${LEFT_UPSTREAM}" -eq 0 ]; then
  ok "fork override: NO applied manifest still carries repoURL github.com/hugmesh/hugmesh-generator.git"
else
  bad "fork override: ${LEFT_UPSTREAM} applied manifest(s) still point at the upstream PRIVATE repo — the repoURL substitution did not run; every one of them would fail to sync with 'authentication required'"
fi
# (b) the fork URL actually reached a non-trivial number of them
GOT_FORK=$(grep -R -l -F "repoURL: ${FORK_URL}" "${CAP}" 2>/dev/null | wc -l)
if [ "${GOT_FORK}" -gt 10 ]; then
  ok "fork override: ${GOT_FORK} applied manifest(s) carry repoURL ${FORK_URL}"
else
  bad "fork override: only ${GOT_FORK} applied manifest(s) carry the fork repoURL — the substitution reached (almost) nothing"
fi
# (c) targetRevision was rewritten too
LEFT_MAIN=$(grep -R -l -E '^[[:space:]]*targetRevision:[[:space:]]*main[[:space:]]*$' "${CAP}" 2>/dev/null | wc -l)
GOT_REV=$(grep -R -l -F "targetRevision: ${FORK_REV}" "${CAP}" 2>/dev/null | wc -l)
if [ "${LEFT_MAIN}" -eq 0 ] && [ "${GOT_REV}" -gt 10 ]; then
  ok "fork override: no applied manifest still says targetRevision: main; ${GOT_REV} carry ${FORK_REV}"
else
  bad "fork override: ${LEFT_MAIN} applied manifest(s) still say 'targetRevision: main' and only ${GOT_REV} carry '${FORK_REV}' — the targetRevision substitution did not run"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2) The escape hatch is loud and is NOT the default.
# ─────────────────────────────────────────────────────────────────────────────
SYSROOT="${WORK}/sysroot-hatch"; rm -rf "${SYSROOT}"
TREE="${SYSROOT}/var/lib/hugmesh/cluster"; mkdir -p "$(dirname "${TREE}")"; cp -r "${SRC}" "${TREE}"
export SYSROOT
OPTIONAL_SERVICES="${SELECTED}" ENV="test" gate_optional_services
CAP="${WORK}/cap-hatch"; rm -rf "${CAP}"; mkdir -p "${CAP}"
PATH="${STUB}:${PATH}" KUBECTL_CAPTURE="${CAP}" ARGOCD_REPO_PUBLIC=1 \
  KUBECONFIG="${WORK}/kubeconfig" HUGMESH_GITOPS_ROOT_RECURSE=1 \
  bash "${TREE}/bootstrap/bootstrap.sh" > "${WORK}/boot-hatch.log" 2>&1
if has_name "hugmesh-root"; then
  ok "HUGMESH_GITOPS_ROOT_RECURSE=1 restores the repo-recursing root (documented opt-out)"
else
  bad "HUGMESH_GITOPS_ROOT_RECURSE=1 did not apply the root app-of-apps"
fi
if grep -E 'WARNING: this root syncs specs/cluster/apps FROM' "${WORK}/boot-hatch.log" >/dev/null; then
  ok "the escape hatch warns, out loud, that every build-time prune is ignored"
else
  bad "the escape hatch is SILENT about ignoring the build-time prune"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3) The DOUBLE-MANAGEMENT guard on the 13a ApplicationSet element.
#    docs/OPTIONAL-SERVICES.md forbids two owners of one manifest directory. A
#    selected slug whose hardcoded apps/30-<slug>.yaml still exists must NOT also
#    be flipped installed:"true" in apps/13a-optional-services.yaml — that would
#    put two prune/selfHeal Applications on specs/cluster/manifests/<dir>. This
#    only became reachable when bootstrap started applying the baked tree.
# ─────────────────────────────────────────────────────────────────────────────
SYSROOT="${WORK}/sysroot-appset"; rm -rf "${SYSROOT}"
TREE="${SYSROOT}/var/lib/hugmesh/cluster"; mkdir -p "$(dirname "${TREE}")"; cp -r "${SRC}" "${TREE}"
export SYSROOT
OPTIONAL_SERVICES="akkoma tuwunel" ENV="test" gate_optional_services
APPSET="${TREE}/apps/13a-optional-services.yaml"
appset_flag() { sed -n -E "s#^[[:space:]]*-[[:space:]]*\{[[:space:]]*slug:[[:space:]]*$1[[:space:]]*,.*installed:[[:space:]]*\"(true|false)\".*#\1#p" "${APPSET}" | sed -n '1p'; }
for slug in akkoma tuwunel; do
  [ -f "${TREE}/apps/30-${slug}.yaml" ] || { bad "fixture broken: apps/30-${slug}.yaml missing for a SELECTED slug"; continue; }
  if [ "$(appset_flag "${slug}")" = "false" ]; then
    ok "SELECTED '${slug}' keeps its 13a element installed:\"false\" while apps/30-${slug}.yaml still owns the manifest dir (no double management)"
  else
    bad "SELECTED '${slug}' has 13a installed:\"$(appset_flag "${slug}")\" while apps/30-${slug}.yaml still exists — DOUBLE MANAGEMENT of specs/cluster/manifests/${slug}"
  fi
done
# The guard must not become a blanket "always false": a slug with NO hardcoded
# Application (anubis is wired ONLY through 13a) must still be flippable, or the
# fix would have silently disabled the runtime-only services.
SYSROOT="${WORK}/sysroot-anubis"; rm -rf "${SYSROOT}"
TREE="${SYSROOT}/var/lib/hugmesh/cluster"; mkdir -p "$(dirname "${TREE}")"; cp -r "${SRC}" "${TREE}"
export SYSROOT
APPSET="${TREE}/apps/13a-optional-services.yaml"
OPTIONAL_SERVICES="anubis" ENV="test" gate_optional_services
if [ "$(appset_flag anubis)" = "true" ]; then
  ok "runtime-only slug 'anubis' (no hardcoded Application) still flips to installed:\"true\" — the guard is targeted, not blanket"
else
  bad "runtime-only slug 'anubis' was forced to installed:\"$(appset_flag anubis)\" — the double-management guard is over-broad and disabled a 13a-only service"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 4) THE RETIREMENT OF A PRE-EXISTING RECURSING ROOT — the most destructive step
#    in bootstrap.sh, and until 2026-08-26 the only UNTESTED one.
#
#    A `kubectl delete application hugmesh-root` while ArgoCD's
#    `resources-finalizer.argocd.argoproj.io` is still attached CASCADE-DELETES
#    every resource the root manages — the ENTIRE PLATFORM. The strip that
#    prevents that used to be `>/dev/null 2>&1 || true`, so an RBAC denial, a
#    conflict or an API hiccup was swallowed and control fell straight through to
#    the delete. The reviewer demonstrated it: with a stub kubectl returning
#    Forbidden on `patch application hugmesh-root`, bootstrap.sh still emitted
#    `delete application hugmesh-root --cascade=orphan` and exited 0.
#
#    These runs pin the fail-CLOSED behaviour: the delete is issued ONLY after
#    the strip is VERIFIED by re-reading .metadata.finalizers from a get that
#    itself succeeded, and every failure aborts BEFORE the delete.
# ─────────────────────────────────────────────────────────────────────────────
root_calls() {   # $1 = verb ; count of `<verb> application hugmesh-root` calls
  grep -c -E "(^| )$1 application hugmesh-root( |$)" "${CAP}/calls.log" 2>/dev/null || true
}
call_index() {   # $1 = extended regex ; 1-based line number of its FIRST hit in calls.log
  grep -n -E "$1" "${CAP}/calls.log" 2>/dev/null | sed -n '1p' | cut -d: -f1
}

# ── 4a) HAPPY PATH: the root exists, the strip takes, the delete is issued ────
reset_stub
export STUB_ROOT_PATH="specs/cluster/apps"
run_bootstrap retire-ok gate
if [ "${BOOT_RC}" -eq 0 ]; then
  ok "retirement (happy path): bootstrap.sh exited 0 with a pre-existing recursing hugmesh-root"
else
  bad "retirement (happy path): bootstrap.sh exited ${BOOT_RC}; log:"; sed 's/^/      /' "${BOOT_LOG}"
fi
if [ "$(root_calls delete)" -ge 1 ]; then
  ok "retirement (happy path): the recursing root WAS deleted"
else
  bad "retirement (happy path): hugmesh-root was never deleted — the recursing root survives and will selfHeal the whole repo apps/ tree back"
fi
PIDX="$(call_index 'patch application hugmesh-root')"
DIDX="$(call_index 'delete application hugmesh-root')"
if [ -n "${PIDX}" ] && [ -n "${DIDX}" ] && [ "${PIDX}" -lt "${DIDX}" ]; then
  ok "retirement (happy path): the finalizer strip (call ${PIDX}) PRECEDES the delete (call ${DIDX})"
else
  bad "retirement (happy path): finalizer strip index='${PIDX}' delete index='${DIDX}' — the strip does not provably precede the delete"
fi
if grep -E 'delete application hugmesh-root.*--cascade=orphan' "${CAP}/calls.log" >/dev/null 2>&1; then
  ok "retirement (happy path): the delete carries --cascade=orphan (children ORPHANED, not deleted)"
else
  bad "retirement (happy path): the delete does NOT carry --cascade=orphan — ArgoCD would delete every child Application too"
fi
if [ "$(applied_names | wc -l)" -gt 10 ]; then
  ok "retirement (happy path): the baked set was still applied after the retirement ($(applied_names | wc -l) Applications)"
else
  bad "retirement (happy path): only $(applied_names | wc -l) Application(s) applied — retiring the root aborted the real work"
fi

# ── 4b) NEGATIVE CONTROL: the strip is DENIED -> abort, and NO delete ─────────
reset_stub
export STUB_ROOT_PATH="specs/cluster/apps" STUB_PATCH_RC=1
run_bootstrap retire-patchfail gate
if [ "${BOOT_RC}" -ne 0 ]; then
  ok "retirement FAILS CLOSED: a Forbidden on the finalizer strip aborts bootstrap.sh (rc=${BOOT_RC})"
else
  bad "retirement FAILS OPEN: the finalizer strip was DENIED and bootstrap.sh still exited 0"
fi
if [ "$(root_calls delete)" -eq 0 ]; then
  ok "retirement FAILS CLOSED: NO 'delete application hugmesh-root' was issued after the strip was denied (no platform-wide cascade delete)"
else
  bad "CATASTROPHIC: the finalizer strip was DENIED and bootstrap.sh deleted hugmesh-root anyway — ArgoCD's resources-finalizer would CASCADE-DELETE the entire platform"
fi
if grep -E 'FATAL: could not strip the resources-finalizer' "${BOOT_LOG}" >/dev/null; then
  ok "retirement FAILS CLOSED: the abort says WHY, out loud, on stderr"
else
  bad "retirement aborted without naming the finalizer strip as the reason; log:"; sed 's/^/      /' "${BOOT_LOG}"
fi

# ── 4c) NEGATIVE CONTROL: the patch 'succeeds' but the finalizer SURVIVES ─────
# The exit code is not the post-condition. A server-side admission webhook, a
# stale merge, or a re-adding controller can leave the finalizer attached with
# rc=0 — so the finalizer list is RE-READ and must come back empty.
reset_stub
export STUB_ROOT_PATH="specs/cluster/apps" STUB_ROOT_FINALIZERS='["resources-finalizer.argocd.argoproj.io"]'
run_bootstrap retire-finalizer-survives gate
if [ "${BOOT_RC}" -ne 0 ]; then
  ok "retirement FAILS CLOSED: a finalizer that SURVIVES an rc=0 patch aborts bootstrap.sh (rc=${BOOT_RC}) — post-condition, not exit code"
else
  bad "retirement FAILS OPEN: the resources-finalizer was still attached after the patch and bootstrap.sh exited 0"
fi
if [ "$(root_calls delete)" -eq 0 ]; then
  ok "retirement FAILS CLOSED: NO delete was issued while the resources-finalizer was still attached"
else
  bad "CATASTROPHIC: hugmesh-root was deleted with resources-finalizer.argocd.argoproj.io still attached — that CASCADE-DELETES the entire platform"
fi

# ── 4d) NEGATIVE CONTROL: the VERIFY read itself is denied ───────────────────
# A get that fails must NOT be read as "no finalizers". Fail closed on unknown.
reset_stub
export STUB_ROOT_PATH="specs/cluster/apps" STUB_GET_FIN_RC=1
run_bootstrap retire-verify-denied gate
if [ "${BOOT_RC}" -ne 0 ] && [ "$(root_calls delete)" -eq 0 ]; then
  ok "retirement FAILS CLOSED: a DENIED verify read aborts (rc=${BOOT_RC}) and issues no delete — an unverified strip is treated as a live cascade finalizer"
else
  bad "retirement FAILS OPEN on an unverifiable strip: rc=${BOOT_RC}, delete calls=$(root_calls delete)"
fi

# ── 4e) The retirement is GUARDED ON THE SOURCE PATH ─────────────────────────
# An operator's own differently-scoped Application that merely happens to be
# named hugmesh-root must never be patched or deleted.
reset_stub
export STUB_ROOT_PATH="specs/other/apps"
run_bootstrap retire-guard gate
if [ "${BOOT_RC}" -eq 0 ] && [ "$(root_calls delete)" -eq 0 ] && [ "$(root_calls patch)" -eq 0 ]; then
  ok "retirement is guarded on .spec.source.path: an unrelated Application named hugmesh-root is neither patched nor deleted"
else
  bad "retirement touched an Application named hugmesh-root whose source path is NOT specs/cluster/apps (rc=${BOOT_RC}, patch=$(root_calls patch), delete=$(root_calls delete))"
fi
reset_stub

# ─────────────────────────────────────────────────────────────────────────────
# 5) THE NEW PARTIAL-FAILURE SURFACE this change created.
#    This step went from ONE `kubectl apply` (all-or-nothing) to ~74 sequential
#    ones, immediately after an ArgoCD install whose readiness wait is
#    best-effort (`rollout status ... || true`). A CRD that is not yet
#    Established, or one transient API error, used to be a whole-step failure;
#    now it aborts after an ARBITRARY PREFIX of the set is already live, and
#    provision.sh only `|| warn`s about it. Two guards, both exercised here:
#    a CRD-establishment gate BEFORE the loop, and a bounded retry INSIDE it.
# ─────────────────────────────────────────────────────────────────────────────
# ── 5a) CRDs never Established -> abort BEFORE applying anything ─────────────
reset_stub
export STUB_CRD_FAIL=1
run_bootstrap crd-fail gate
if [ "${BOOT_RC}" -ne 0 ]; then
  ok "CRD gate: bootstrap.sh aborts (rc=${BOOT_RC}) when applications.argoproj.io never becomes Established"
else
  bad "CRD gate: the argoproj CRDs never became Established and bootstrap.sh still exited 0"
fi
CRD_APPLIED=$(applied_names | wc -l)
if [ "${CRD_APPLIED}" -eq 0 ]; then
  ok "CRD gate: ZERO Applications were applied — no half-deployed cluster left behind"
else
  bad "CRD gate: ${CRD_APPLIED} Application(s) were applied before/despite the CRD gate — that is the partial-set failure this gate exists to prevent"
fi
if grep -E 'FATAL: CRD applications.argoproj.io was not Established' "${BOOT_LOG}" >/dev/null; then
  ok "CRD gate: the abort names the CRD and says nothing was applied"
else
  bad "CRD gate: aborted without naming the un-Established CRD; log:"; sed 's/^/      /' "${BOOT_LOG}"
fi

# ── 5b) A TRANSIENT apply failure is RETRIED, not fatal ─────────────────────
reset_stub
export STUB_FLAKY_TOKEN="name: akkoma" STUB_FLAKY_TIMES=1
run_bootstrap flaky-once gate
if [ "${BOOT_RC}" -eq 0 ]; then
  ok "bounded retry: one transient API error on a manifest does NOT abort a device bootstrap (rc=0)"
else
  bad "bounded retry: a single transient failure aborted the whole bootstrap (rc=${BOOT_RC}); log:"; sed 's/^/      /' "${BOOT_LOG}"
fi
if has_name "akkoma"; then
  ok "bounded retry: the manifest that failed once WAS applied on retry"
else
  bad "bounded retry: the transiently-failed Application 'akkoma' never reached the cluster"
fi
if grep -E 'transient failure applying .*retry 2/3' "${BOOT_LOG}" >/dev/null; then
  ok "bounded retry: the retry is announced, so a flapping API is visible in the provisioning log"
else
  bad "bounded retry: nothing in the log says a manifest was retried; log tail:"; tail -20 "${BOOT_LOG}" | sed 's/^/      /'
fi

# ── 5c) A manifest that fails EVERY attempt is still FATAL, and NAMED ────────
reset_stub
export STUB_FLAKY_TOKEN="name: akkoma" STUB_FLAKY_TIMES=99
run_bootstrap flaky-always gate
if [ "${BOOT_RC}" -ne 0 ]; then
  ok "exhausted retry: a manifest failing every attempt is still FATAL (rc=${BOOT_RC}) — the deployed set must not silently differ from the image"
else
  bad "exhausted retry: a manifest that failed every attempt still let bootstrap.sh exit 0"
fi
if grep -E 'FATAL: .* baked Application manifest\(s\) failed to apply .*30-akkoma\.yaml' "${BOOT_LOG}" >/dev/null; then
  ok "exhausted retry: the FATAL NAMES the failed file (30-akkoma.yaml), so the operator knows what the partial set is"
else
  bad "exhausted retry: the FATAL does not name the failed file; log tail:"; tail -5 "${BOOT_LOG}" | sed 's/^/      /'
fi
reset_stub

echo
echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
