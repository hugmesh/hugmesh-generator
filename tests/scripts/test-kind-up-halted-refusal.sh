#!/usr/bin/env bash
# test-kind-up-halted-refusal.sh — `make kind-up` over a HALTED kind cluster must
# refuse and name `make kind-resume`, not walk into a bring-up that cannot converge.
#
# WHY (hugmesh-generator#529). `make kind-halt` leaves the cluster up and
# answering, so `kind get clusters` names it and bootstrap-kind.sh takes its
# "already exists — reusing it" branch. But every Application is suspended and
# every mesh workload is at 0 replicas: the vault-0 wait is `|| true`, and the
# run continues into a pki chain that needs a Vault that is not there. Nothing
# said "halted".
#
# HOW. Behaviourally: this RUNS the real specs/cluster/bootstrap/kind-local/
# bootstrap-kind.sh with kind, kubectl and docker replaced on PATH by stubs. The
# kubectl stub models the real CLI's contract for the halt-record read:
#   * record present       -> rc 0, prints `configmap/<name>`
#   * record absent        -> `Error from server (NotFound)` rc 1, UNLESS the
#                             caller passed --ignore-not-found (then rc 0, silent)
#   * read error           -> a connection-refused line, rc 1, whatever the flags
# The docker stub records that it was reached and fails, so the egress preflight
# (step 1b, the first thing after the halt check) aborts the run: reaching it is
# the proof that the reuse path was taken.
#
# CASES
#   1 record present          -> refusal, names `make kind-resume`, docker never reached
#   2 record NotFound         -> reuse path (egress preflight reached), no refusal
#   3 read error              -> refusal ("could not read"), docker never reached
#   4 read error that SAYS    -> refusal. `error: context "…" not found` is not a
#     "not found"                NotFound; a prose grep would fail open on it.
#   5 fresh cluster (created) -> no halt read at all; egress preflight reached
#   6 the read is DIRECT      -> ONE `kubectl --context kind-<cluster> -n <argocd ns>
#                                get configmap hugmesh-kind-halt`, and no other
#                                kubectl call (kind-halt.sh status would census)
#
# Offline: bash + coreutils + jq/openssl/base64/git (the script's own preflight
# requires them; none is exercised). No cluster, no kind, no docker, no network.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
BOOTSTRAP="${REPO}/specs/cluster/bootstrap/kind-local/bootstrap-kind.sh"

pass=0; fail=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }

# A missing tool is a hard failure, never a skip: a skipping gate never guards.
for t in bash git jq openssl base64 mktemp; do
  command -v "${t}" >/dev/null 2>&1 || { echo "FATAL: ${t} required (refusing to skip)" >&2; exit 1; }
done
[ -r "${BOOTSTRAP}" ] || { echo "FATAL: ${BOOTSTRAP} missing" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
BIN="${TMP}/bin"; mkdir -p "${BIN}"

cat > "${BIN}/kind" <<'STUB'
#!/usr/bin/env bash
printf 'kind %s\n' "$*" >> "${STUB_LOG}"
case "$1 ${2:-}" in
  "get clusters")      [ "${STUB_CLUSTER_EXISTS}" = "1" ] && echo "${STUB_CLUSTER}"; exit 0 ;;
  "create cluster")    exit 0 ;;
  "export kubeconfig") exit 0 ;;
esac
echo "kind stub: unexpected: $*" >&2; exit 97
STUB

cat > "${BIN}/kubectl" <<'STUB'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >> "${STUB_LOG}"
args=" $* "
case "${args}" in
  *" config use-context "*) exit 0 ;;
  *" version "*)            exit 0 ;;
  *" get configmap "*)
    case "${STUB_HALT}" in
      present) echo "configmap/${STUB_CM}"; exit 0 ;;
      notfound)
        case "${args}" in *" --ignore-not-found "*) exit 0 ;; esac
        echo "Error from server (NotFound): configmaps \"${STUB_CM}\" not found" >&2; exit 1 ;;
      error)
        echo "The connection to the server 127.0.0.1:6443 was refused - did you specify the right host or port?" >&2; exit 1 ;;
      ctxerror)
        echo "error: context \"kind-${STUB_CLUSTER}\" not found" >&2; exit 1 ;;
    esac ;;
esac
echo "kubectl stub: unexpected: $*" >&2; exit 97
STUB

# getent: the egress preflight resolves registry names on the HOST first. Make
# every name unresolvable so the suite never touches DNS; the preflight then
# falls through to its anycast literals, which the docker stub refuses.
cat > "${BIN}/getent" <<'STUB'
#!/usr/bin/env bash
exit 2
STUB

cat > "${BIN}/docker" <<'STUB'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "${STUB_LOG}"
exit 1
STUB
chmod +x "${BIN}/kind" "${BIN}/kubectl" "${BIN}/docker" "${BIN}/getent"

# run <case-name> <cluster-exists 0|1> <halt mode>
# Leaves ${OUT} (stdout+stderr), ${LOG} (stub argv log) and ${RC}.
run() {
  local name="$1"
  local exists="$2"
  local mode="$3"
  local d="${TMP}/${name}"
  mkdir -p "${d}/tmp"
  OUT="${d}/out"; LOG="${d}/calls"; : > "${LOG}"
  # An isolated HOME keeps the operator's Studio tools dir (appended to PATH by
  # _tools-path-lib.sh) out of the run; TMPDIR keeps the bring-up lock private.
  env -i PATH="${BIN}:${PATH}" HOME="${d}" TMPDIR="${d}/tmp" \
      STUB_LOG="${LOG}" STUB_CLUSTER="hugmesh-local" STUB_CLUSTER_EXISTS="${exists}" \
      STUB_HALT="${mode}" STUB_CM="hugmesh-kind-halt" \
      KIND_PROFILE=core \
      bash "${BOOTSTRAP}" > "${OUT}" 2>&1
  RC=$?
}

has()   { grep -aF -e "$2" "$1" >/dev/null 2>&1; }

reached_egress() { has "${LOG}" "docker exec hugmesh-local-control-plane"; }

echo "== 1. halt record present -> refuse, naming make kind-resume"
run present 1 present
[ "${RC}" -ne 0 ] && ok "exit ${RC} (non-zero)" || bad "exited 0 over a halted cluster"
has "${OUT}" "is HALTED" && ok "says the cluster is halted" || bad "no 'is HALTED' in output"
has "${OUT}" "make kind-resume" && ok "names 'make kind-resume' as the remedy" || bad "remedy 'make kind-resume' not named"
reached_egress && bad "bring-up continued past the halt check (egress preflight reached)" || ok "stopped before any further step"

echo "== 2. halt record NotFound -> the reuse path"
run notfound 1 notfound
reached_egress && ok "reuse path continued to the egress preflight" || bad "did not reach the egress preflight (refused a non-halted cluster?)"
has "${OUT}" "is HALTED" && bad "claimed HALTED with no record" || ok "no halted refusal"
has "${OUT}" "could not read the halt record" && bad "treated NotFound as a read error" || ok "NotFound is not a read error"
has "${OUT}" "no halt record" && ok "logs that the reused cluster is not halted" || bad "no 'no halt record' log line"

echo "== 3. halt record read ERRORS -> refuse"
run error 1 error
[ "${RC}" -ne 0 ] && ok "exit ${RC} (non-zero)" || bad "exited 0 with an unreadable record"
has "${OUT}" "could not read the halt record" && ok "says the record could not be read" || bad "no 'could not read the halt record'"
has "${OUT}" "connection to the server" && ok "surfaces kubectl's own error line" || bad "kubectl's error line not surfaced"
has "${OUT}" "make kind-resume" && ok "still names the remedy" || bad "remedy not named on a read error"
reached_egress && bad "a read error was treated as 'not halted' (egress preflight reached)" || ok "stopped before any further step"

echo "== 4. a read error whose prose says 'not found' -> still refuse"
run ctxerror 1 ctxerror
has "${OUT}" "could not read the halt record" && ok "context-not-found is a read error, not NotFound" || bad "context-not-found was not refused as a read error"
reached_egress && bad "failed OPEN on 'not found' prose" || ok "stopped before any further step"

echo "== 5. freshly created cluster -> no halt read"
run fresh 0 error
has "${LOG}" "kind create cluster" && ok "took the create path" || bad "did not take the create path"
has "${LOG}" "get configmap" && bad "read a halt record on a cluster this run created" || ok "no halt read on the create path"
reached_egress && ok "continued to the egress preflight" || bad "did not reach the egress preflight"

echo "== 6. the read is direct, pinned to the cluster's context and the ArgoCD namespace"
run direct 1 notfound
line="$(grep -a -e 'get configmap' "${LOG}" | head -n 1)"
case " ${line} " in *" --context kind-hugmesh-local "*) ok "carries --context kind-hugmesh-local" ;; *) bad "context not pinned: ${line:-<no read>}" ;; esac
case " ${line} " in *" -n devops "*) ok "reads in -n devops (ARGOCD_NS default)" ;; *) bad "namespace not devops: ${line:-<no read>}" ;; esac
case " ${line} " in *" get configmap hugmesh-kind-halt "*) ok "reads configmap hugmesh-kind-halt" ;; *) bad "wrong object: ${line:-<no read>}" ;; esac
# kind-halt.sh's `status` verb runs its own census first (`get nodes`, `get crd
# applications.argoproj.io`). The ONLY kubectl calls a bring-up may make before
# the egress preflight are the context switch, the reachability check and the
# one configmap read — anything else means the decision went through another path.
others="$(grep -a -e '^kubectl ' "${LOG}" | grep -av -e ' config use-context ' -e ' version' -e ' get configmap ' || true)"
[ -z "${others}" ] && ok "no other kubectl call before the egress preflight (not routed via kind-halt.sh status)" \
  || bad "unexpected kubectl calls: ${others}"
n_reads="$(grep -ac -e ' get configmap ' "${LOG}")"
[ "${n_reads}" = "1" ] && ok "exactly one halt-record read" || bad "${n_reads} halt-record reads"

echo
echo "${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
