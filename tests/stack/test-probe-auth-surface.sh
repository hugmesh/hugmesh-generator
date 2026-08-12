#!/usr/bin/env bash
# test-probe-auth-surface.sh — a kubelet probe may not target a path the service
# itself role-gates unless the probe tolerates the 401 that gating produces.
#
# WHY THIS EXISTS. THE most severe defect the first real kind run found
# (KIND_PROFILE=sso, 2026-08-05, blocker #7): NO gateway could ever become Ready
# on Kubernetes. specs/cluster/charts/hugmesh-gateway gave it httpGet probes on
# /actuator/health/{liveness,readiness}; the gateway image's OWN SecurityConfig
# role-gates /actuator/** (INFRA_PATHS -> GAME-MASTER/ADMIN/SUPERADMIN), and a
# kubelet carries no token, so every probe got 401. A kubelet scores httpGet
# success as 200 <= code < 400, so readiness NEVER passed and liveness then
# killed a perfectly healthy pod -> CrashLoopBackOff forever, on all four
# instances (pki/be/fe/superadmin) that share that one chart. Live:
#
#   Warning  Unhealthy  ...  Readiness probe failed: HTTP probe failed with statuscode: 401   (x17)
#   (same pod, same minute)  Started HugMeshGatewayApplication in 10.496 seconds
#                            Netty started on port 8080
#
# It fails SILENTLY in the only way that matters: the app logs a clean start and
# serves traffic, and only the Ready column says otherwise.
#
# AND IT WAS ALREADY SOLVED, IN THE OTHER HALF OF THE REPO. compose.local.yaml's
# three gateway healthchecks have accepted 401 for exactly this reason, with a
# comment saying so ("A 401 proves both that the app is up and that its security
# chain is wired; 000/5xx do not"). Compose green was read as proof the platform
# works; it proved the SERVICES work, never the cluster PAYLOAD. So this gate is
# built around that asymmetry rather than around a hard-coded expectation:
#
#   [gateway-probe-401]          REAL `helm template` of the chart, THE WAY
#                                ARGOCD RENDERS IT (parameters > valuesObject >
#                                values > valueFiles, across spec.source AND
#                                spec.sources[]), for the chart default AND every
#                                gateway Application source:
#                                exec (not httpGet), on the right actuator path,
#                                accepting exactly {200,401} — not `curl -f`
#                                (which aborts on 401 just like on 500), not a
#                                wider set (000/5xx must still fail), through an
#                                explicit shell (a k8s ExecAction is "not
#                                executed through a shell"), with an explicit
#                                timeoutSeconds (forking sh+curl does not
#                                reliably finish inside the kubelet's 1s
#                                default).
#   [compose-gateway-401]        the compose oracle itself stays 401-tolerant, so
#                                nobody can neuter the comparison and the local
#                                stack in one "simplification".
#   [compose-cluster-401-parity] THE CLASS, not the instance: for ANY service
#                                whose compose healthcheck had to tolerate 401 —
#                                i.e. compose discovered its actuator is gated —
#                                the cluster probe must tolerate it too. This is
#                                the "fixed in compose, never fixed in the
#                                cluster manifests" theme, mechanised.
#   [actuator-probe-coverage]    every /actuator probe in specs/cluster is either
#                                judged by a compose healthcheck or listed, with
#                                a reason, as having no compose twin — so the
#                                parity check cannot quietly stop covering things
#                                as the tree grows.
#
# RENDER FIDELITY is half the gate. The first cut rendered each Application's
# helm.values and nothing else, which meant a gateway could ship with its probes
# switched off through helm.parameters — the input ArgoCD applies LAST and which
# therefore beats everything — or as a multi-source (spec.sources[]) Application,
# and be reported green with no probe coverage at all. Controls (12)-(16) below
# pin the reader to what ArgoCD actually does: the documented precedence
# (parameters > valuesObject > values > valueFiles > the chart's values.yaml,
# argo-cd user-guide/helm/), both source forms, forceString -> --set-string, and
# fail-closed on any input the gate cannot resolve — including an ApplicationSet,
# whose values come from a generator rather than from the file.
#
# helm is a HARD requirement (no model-only SKIP): four instances share one
# chart, so rendering it is the only honest way to say what they deploy.
# Otherwise cheap — python3 + PyYAML + bash + helm; no cluster, no kubectl.
#
# Every check carries a NEGATIVE CONTROL below: the assertion is re-run against a
# deliberately corrupted staged copy of the tree and MUST fail there. The repo
# tree is never mutated. Control (11) is the important one of the first group —
# it neuters the compose oracle AND reverts the chart together, and the gate must
# STILL go red, proving [gateway-probe-401] does not lean on the thing it is
# comparing to.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO

command -v python3 >/dev/null 2>&1 || { echo "  FAIL python3 not available"; exit 1; }
python3 -c 'import yaml' 2>/dev/null || { echo "  FAIL PyYAML not available (pip install pyyaml)"; exit 1; }
command -v helm >/dev/null 2>&1 || {
  echo "  FAIL helm not on PATH — this gate RENDERS the shared gateway chart and"
  echo "       has no model-only fallback (a silent SKIP is the hole this class of"
  echo "       bug hides in). The CI job installs a sha256-pinned helm."
  exit 1
}

CHECKER="$(dirname "${BASH_SOURCE[0]}")/probe_auth_surface.py"
[ -f "${CHECKER}" ] || { echo "  FAIL missing checker: ${CHECKER}"; exit 1; }

echo "== probe auth-surface gate =="
echo "-- positive: the repo's own tree must pass every check --"
python3 "${CHECKER}" "${REPO}"
RC=$?
if [ "${RC}" -ne 0 ]; then
  echo
  echo "== probe auth-surface: FAIL (see above) =="
  exit 1
fi

# ── NEGATIVE CONTROLS ────────────────────────────────────────────────────────
echo
echo "-- negative controls: each injected defect must be caught --"
NEG_P=0; NEG_F=0
neg_ok(){ echo "  PASS negative control: $*"; NEG_P=$((NEG_P+1)); }
neg_bad(){ echo "  FAIL negative control: $*"; NEG_F=$((NEG_F+1)); }

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT

CHART_TPL='specs/cluster/charts/hugmesh-gateway/templates/deployment.yaml'
COMPOSE='tests/stack/compose.local.yaml'

# Shared injector preamble, prepended to every injector below. It carries the
# two multi-line rewrites used by more than one control plus the compose
# healthcheck strings VERBATIM — reproducing `$code`, `$$` and the nested escaped
# quotes is the whole difficulty here, and no layer of shell quoting survives
# them, which is why every injection is python fed through a quoted heredoc.
INJECT_LIB="${WORK}/inject_lib.py"
cat > "${INJECT_LIB}" <<'LIB'
import re
import sys

import yaml

COMPOSE_REL = "tests/stack/compose.local.yaml"

# compose.local.yaml's gateway healthcheck (401-tolerant) and the plain
# fail-on-4xx form every non-gateway service uses, byte-for-byte.
TOLERANT_HC = ('      test: ["CMD-SHELL", "code=$$(curl -s -o /dev/null -w '
               "'%{http_code}'"
               ' http://localhost:8080/actuator/health/readiness); '
               '[ \\"$$code\\" = 200 ] || [ \\"$$code\\" = 401 ]"]')
PLAIN_HC = ('      test: ["CMD-SHELL", "curl -sf '
            'http://localhost:8080/actuator/health/readiness || exit 1"]')

# The probe block exactly as it shipped on main — the defect, not a paraphrase.
SHIPPED_HTTPGET = """          {{- if .Values.probes.enabled }}
          readinessProbe:
            httpGet: { path: /actuator/health/readiness, port: http }
            initialDelaySeconds: 20
            periodSeconds: 10
          livenessProbe:
            httpGet: { path: /actuator/health/liveness, port: http }
            initialDelaySeconds: 45
            periodSeconds: 15
          {{- end }}
"""


def revert_chart_to_httpget(tree, chart_tpl):
    p = tree + "/" + chart_tpl
    s = open(p, encoding="utf-8").read()
    a = s.index("          {{- if .Values.probes.enabled }}")
    b = s.index("          resources: {{- toYaml .Values.resources")
    open(p, "w", encoding="utf-8").write(s[:a] + SHIPPED_HTTPGET + s[b:])


def neuter_compose_gateways(tree):
    p = tree + "/" + COMPOSE_REL
    s = open(p, encoding="utf-8").read()
    n = s.count(TOLERANT_HC)
    assert n == 3, "compose gateway healthcheck anchor matched %d times, not 3" % n
    open(p, "w", encoding="utf-8").write(s.replace(TOLERANT_HC, PLAIN_HC))


def add_helm_block(tree, app_rel, block):
    """Splice extra keys into an Application's spec.source.helm, textually, so
    the file's comments and formatting survive (these controls are about what
    ArgoCD READS, not about YAML round-tripping)."""
    p = tree + "/specs/cluster/apps/" + app_rel
    s = open(p, encoding="utf-8").read()
    anchor = "    helm:\n"
    assert s.count(anchor) == 1, "%s: helm anchor matched %d times" % (
        app_rel, s.count(anchor))
    open(p, "w", encoding="utf-8").write(s.replace(anchor, anchor + block, 1))


def to_multi_source(tree, app_rel, extra_helm=None, chart_index=1):
    """Convert an Application from spec.source to ArgoCD's multi-source form.

    spec.sources[] entries have the same shape as spec.source (argo-cd
    user-guide/multiple_sources/), and a `ref`-only entry that supplies value
    files is the canonical companion — so the chart is NOT at index 0, which is
    the whole point: a reader that only knows spec.source sees nothing here.
    """
    p = tree + "/specs/cluster/apps/" + app_rel
    doc = yaml.safe_load(open(p, encoding="utf-8"))
    src = doc["spec"].pop("source")
    src.setdefault("helm", {}).update(extra_helm or {})
    sources = [{"repoURL": src["repoURL"],
                "targetRevision": src.get("targetRevision", "main"),
                "ref": "values"}]
    sources.insert(chart_index, src)
    doc["spec"]["sources"] = sources
    with open(p, "w", encoding="utf-8") as fh:
        yaml.safe_dump(doc, fh, sort_keys=False)
LIB

# $1 = human label, $2 = expected check-id substring in the failure output.
# STDIN = a python injector, run as `injector <staged-tree> <chart-template-rel>`
# on top of the preamble above.
expect_catch() {
  local label="$1" want="$2"
  local T="${WORK}/tree" SRC="${WORK}/inject.py"
  { cat "${INJECT_LIB}"; cat; } > "${SRC}"
  rm -rf "${T}"; mkdir -p "${T}/specs" "${T}/tests/stack"
  cp -r "${REPO}/specs/cluster" "${T}/specs/"
  cp "${REPO}/${COMPOSE}" "${T}/tests/stack/"
  local ierr
  ierr="$(python3 "${SRC}" "${T}" "${CHART_TPL}" 2>&1)" || {
    neg_bad "${label} (injection itself failed): $(tail -1 <<<"${ierr}")"; return; }
  local out rc
  out="$(python3 "${CHECKER}" "${T}" 2>&1)"; rc=$?
  # -F: the check ids contain [] and -, which grep would read as a bracket range.
  if [ "${rc}" -ne 0 ] && grep -qF "  FAIL ${want}" <<<"${out}"; then
    neg_ok "${label} -> caught by ${want}"
  else
    neg_bad "${label} NOT caught (rc=${rc}); wanted ${want}. Output:"
    sed 's/^/        /' <<<"${out}" | tail -20
  fi
}

# (1) THE SHIPPED DEFECT, re-injected verbatim: the httpGet probes that could
#     never pass. This is the exact text that was on main.
expect_catch "gateway probes back to httpGet on the role-gated actuator" "[gateway-probe-401]" <<'PY'
revert_chart_to_httpget(sys.argv[1], sys.argv[2])
PY

# (2) an exec probe that LOOKS like the fix but uses `curl -sf`, which aborts on
#     401 exactly as it does on 500 — the wrapper is then pure decoration.
expect_catch "exec probe reverts to curl -sf (fails on 401 like on 500)" "[gateway-probe-401]" <<'PY'
p = sys.argv[1] + "/" + sys.argv[2]
s = open(p, encoding="utf-8").read()
s, n = re.subn(r"                - >-\n(?:                  .*\n)+",
               "                - curl -sf http://127.0.0.1:8080/actuator/health/readiness\n", s)
assert n == 2, "folded exec command anchor matched %d times, not 2" % n
open(p, "w", encoding="utf-8").write(s)
PY

# (3) the acceptance quietly narrowed back to 200 on READINESS only — the pod
#     still never becomes Ready, and the liveness probe still looks fixed.
expect_catch "401 dropped from the readiness acceptance (200 only)" "[gateway-probe-401]" <<'PY'
p = sys.argv[1] + "/" + sys.argv[2]
s = open(p, encoding="utf-8").read()
old = 'readiness);\n                  [ "$code" = 200 ] || [ "$code" = 401 ]'
assert s.count(old) == 1, "readiness anchor matched %d times" % s.count(old)
open(p, "w", encoding="utf-8").write(
    s.replace(old, 'readiness);\n                  [ "$code" = 200 ]', 1))
PY

# (4) the OTHER direction: acceptance widened until the probe stops proving
#     anything. A 503 means the app answered "I am not healthy" and must fail.
expect_catch "acceptance widened to swallow 503 (probe stops proving anything)" "[gateway-probe-401]" <<'PY'
p = sys.argv[1] + "/" + sys.argv[2]
s = open(p, encoding="utf-8").read()
old = '[ "$code" = 200 ] || [ "$code" = 401 ]'
assert s.count(old) == 2, "acceptance anchor matched %d times" % s.count(old)
open(p, "w", encoding="utf-8").write(s.replace(old, old + ' || [ "$code" = 503 ]'))
PY

# (5) timeoutSeconds dropped back to the kubelet default of 1s. An exec probe
#     forks sh+curl; on an SBC node that is a coin flip, and a timed-out liveness
#     probe restarts the pod.
expect_catch "exec probe left on the kubelet 1s default timeout" "[gateway-probe-401]" <<'PY'
p = sys.argv[1] + "/" + sys.argv[2]
lines = open(p, encoding="utf-8").read().splitlines(True)
kept = [l for l in lines if l != "            timeoutSeconds: 5\n"]
assert len(lines) - len(kept) == 2, "timeoutSeconds anchor matched %d lines" % (len(lines) - len(kept))
open(p, "w", encoding="utf-8").write("".join(kept))
PY

# (6) the liveness probe deleted outright — an unprobed gateway hides exactly the
#     failure this gate pins, so "no probe" must not read as "probe is fine".
expect_catch "gateway livenessProbe deleted (absence must not pass)" "[gateway-probe-401]" <<'PY'
p = sys.argv[1] + "/" + sys.argv[2]
s = open(p, encoding="utf-8").read()
a = s.index("          livenessProbe:")
b = s.index("          {{- end }}\n          resources:")
open(p, "w", encoding="utf-8").write(s[:a] + s[b:])
PY

# (7) the ORACLE neutered: compose gateway healthchecks "simplified" back to
#     curl -sf. That breaks the local stack AND would hollow out (8) in the same
#     commit, so it has to be a finding in its own right.
expect_catch "compose gateway healthcheck simplified back to curl -sf" "[compose-gateway-401]" <<'PY'
neuter_compose_gateways(sys.argv[1])
PY

# (8) THE CLASS, not the instance. A DIFFERENT service (user-bff) discovers in
#     compose that its actuator is gated and its healthcheck learns to accept
#     401; the cluster probe stays `curl -sf`. Nothing about this check is keyed
#     to the gateway — the parity is derived from compose at run time.
expect_catch "a NON-gateway service learns 401 in compose, cluster probe left behind" "[compose-cluster-401-parity]" <<'PY'
p = sys.argv[1] + "/" + COMPOSE_REL
s = open(p, encoding="utf-8").read()
i = s.index("  hugmesh-user-bff-api:")
j = s.index(PLAIN_HC, i)
open(p, "w", encoding="utf-8").write(s[:j] + TOLERANT_HC + s[j + len(PLAIN_HC):])
PY

# (9) a NEW workload probing /actuator with neither a compose twin nor a recorded
#     reason — the state every one of these bugs started in.
expect_catch "new actuator probe on a workload nothing in this repo can judge" "[actuator-probe-coverage]" <<'PY'
p = sys.argv[1] + "/specs/cluster/manifests/signup-gate/deployment.yaml"
s = open(p, encoding="utf-8").read()
old = "            httpGet: { path: /healthz, port: http }"
assert old in s, "signup-gate probe anchor missing"
open(p, "w", encoding="utf-8").write(
    s.replace(old, "            httpGet: { path: /actuator/health/readiness, port: http }", 1))
PY

# (10) the opposite rot: an exemption outliving the probe it excused. A stale
#      NO_COMPOSE_TWIN entry silently shrinks the covered set.
expect_catch "NO_COMPOSE_TWIN entry outlives the probe it excused" "[actuator-probe-coverage]" <<'PY'
p = sys.argv[1] + "/specs/cluster/manifests/mesh-bff-api/deployment.yaml"
s = open(p, encoding="utf-8").read()
s, n = re.subn(r"          (?:readiness|liveness)Probe:\n            exec:\n"
               r"(?:              .*\n)+?            initialDelaySeconds: \d+\n"
               r"(?:            \w+: \d+\n)*", "", s)
assert n == 2, "mesh-bff probe anchor matched %d times, not 2" % n
open(p, "w", encoding="utf-8").write(s)
PY

# (11) ANTI-VACUITY. Neuter the compose oracle AND revert the chart together —
#      the pairing a "harmonise the healthchecks" commit would produce. Parity
#      can no longer bite; the gate must STILL go red on [gateway-probe-401],
#      which is why that check is an absolute pin and not a comparison.
expect_catch "oracle neutered AND chart reverted in one commit" "[gateway-probe-401]" <<'PY'
neuter_compose_gateways(sys.argv[1])
revert_chart_to_httpget(sys.argv[1], sys.argv[2])
PY

# ── controls (12)-(15): the ARGOCD INPUT SURFACE ─────────────────────────────
# The chart is never deployed by `helm install` here — ArgoCD deploys it, and
# ArgoCD's own precedence is
#     parameters > valuesObject > values > valueFiles > the chart's values.yaml
# (argo-cd user-guide/helm/, "Helm Value Precedence") across spec.source AND
# every spec.sources[] entry. A gate that renders only helm.values models a
# deployment nobody performs: a gateway can then ship with its probes switched
# off, or as a multi-source Application, and be reported green. These four
# controls pin the reader to the real thing — visibility, precedence, the
# multi-source form, and fail-closed on an input the gate cannot resolve.

# (12) probes killed ONLY through helm.parameters. helm.values is untouched and
#      perfectly correct, so a reader that stops at values renders a probed
#      gateway that the cluster never gets.
expect_catch "gateway probes disabled via helm.parameters alone" "[gateway-probe-401]" <<'PY'
add_helm_block(sys.argv[1], "20-gateway-be.yaml",
               '      parameters:\n'
               '        - name: probes.enabled\n'
               '          value: "false"\n')
PY

# (13) PRECEDENCE, not just visibility. helm.values says probes.enabled: true —
#      loudly, explicitly — and helm.parameters says false. ArgoCD's --set is
#      applied after every --values, so false wins and the gateway deploys
#      unprobed. A reader that merges parameters UNDER values (or dict-merges
#      them in the wrong order) renders probes and reports green.
expect_catch "helm.parameters override an explicit helm.values (parameters win)" "[gateway-probe-401]" <<'PY'
p = sys.argv[1] + "/specs/cluster/apps/20-gateway-pki.yaml"
s = open(p, encoding="utf-8").read()
anchor = "      values: |\n"
assert s.count(anchor) == 1, "values anchor matched %d times" % s.count(anchor)
s = s.replace(anchor, anchor + "        probes:\n          enabled: true\n", 1)
open(p, "w", encoding="utf-8").write(s)
add_helm_block(sys.argv[1], "20-gateway-pki.yaml",
               '      parameters:\n'
               '        - name: probes.enabled\n'
               '          value: "false"\n')
PY

# (14) the MULTI-SOURCE form. The same Application, rewritten to spec.sources[]
#      with a ref-source first and the chart second, and its probes turned off
#      through helm.valuesObject (the middle rung of the precedence ladder).
#      A reader that only looks at spec.source sees no gateway here at all.
expect_catch "multi-source Application (spec.sources[]) with probes off via valuesObject" "[gateway-probe-401]" <<'PY'
to_multi_source(sys.argv[1], "20-gateway-fe.yaml",
                {"valuesObject": {"probes": {"enabled": False}}})
PY

# (15) FAIL-CLOSED on an input this gate cannot resolve, on a sources[] entry.
#      helm.valueFiles pointing into a $values ref-source is unreadable from this
#      repo alone; rendering without it produces a DIFFERENT deployment than the
#      cluster gets, so "it rendered fine" must not read as a pass.
expect_catch "unreadable helm.valueFiles on a spec.sources[] gateway entry" "[gateway-probe-401]" <<'PY'
to_multi_source(sys.argv[1], "22-gateway-superadmin.yaml",
                {"valueFiles": ["$values/overrides/superadmin.yaml"]})
PY

# (16) the THIRD deployment mechanism. specs/cluster already runs five
#      ApplicationSets; one of them starting to template the gateway chart would
#      produce gateway instances whose helm inputs come from a generator, not
#      from the file — unrenderable from this repo alone. "Cannot render it" must
#      not degrade into "there is nothing there".
expect_catch "an ApplicationSet templating the gateway chart" "[gateway-probe-401]" <<'PY'
doc = {
    "apiVersion": "argoproj.io/v1alpha1",
    "kind": "ApplicationSet",
    "metadata": {"name": "hugmesh-gateway-regions", "namespace": "devops"},
    "spec": {
        "generators": [{"list": {"elements": [{"region": "eu"}, {"region": "us"}]}}],
        "template": {
            "metadata": {"name": "hugmesh-{{ .region }}-gateway"},
            "spec": {
                "project": "default",
                "source": {
                    "repoURL": "https://github.com/hugmesh/hugmesh-generator.git",
                    "targetRevision": "main",
                    "path": "specs/cluster/charts/hugmesh-gateway",
                    "helm": {"values": "instance:\n  name: hugmesh-{{ .region }}-gateway\n"},
                },
                "destination": {"server": "https://kubernetes.default.svc",
                                "namespace": "hugmesh-backend"},
            },
        },
    },
}
with open(sys.argv[1] + "/specs/cluster/apps/25-gateway-regions.yaml", "w",
          encoding="utf-8") as fh:
    yaml.safe_dump(doc, fh, sort_keys=False)
PY

echo
echo "== negative controls: ${NEG_P} passed, ${NEG_F} failed =="
[ "${NEG_F}" -eq 0 ] || exit 1
echo "== probe auth-surface: PASS =="
exit 0
