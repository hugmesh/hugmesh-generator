#!/usr/bin/env python3
"""Probe AUTH-SURFACE gate: no kubelet probe may target a path its own service
role-gates unless the probe tolerates the 401 that gating produces.

Usage: probe_auth_surface.py <tree-root>
  <tree-root> holds specs/cluster/ and tests/stack/compose.local.yaml.
Exit 0 = every check passed. Exit 1 = at least one check failed.

Driven by tests/stack/test-probe-auth-surface.sh, which also runs the negative
controls (each check is re-run against a deliberately corrupted staged copy of
the tree and must bite). See that script's header for the shipped defect.

`helm` is a HARD requirement: the four gateway instances share one chart, so the
only honest way to assert what they deploy is to render it. There is no
model-only fallback on purpose — a SKIP here is the hole this gate exists to
close (same lesson as lint:gateway-mfa-env assertion (9)).

And the render is ARGOCD's, not a convenient approximation of it. ArgoCD merges
    parameters > valuesObject > values > valueFiles > the chart's values.yaml
across spec.source AND every spec.sources[] entry, so this gate hands those
inputs to helm in that order (--values ... then --set/--set-string) rather than
modelling the merge itself. Anything it cannot hand over — valueFiles,
fileParameters, a non-string parameter value, a generator-driven ApplicationSet
— is a FAILURE. A gateway rendered from inputs ArgoCD would not use is a gateway
this gate is not checking, and reporting that as green is the exact failure mode
the probe bug itself had: everything looked fine except the thing that mattered.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

import yaml

# ── the oracle ───────────────────────────────────────────────────────────────
# tests/stack/compose.local.yaml is the ONLY place in this repo where a probe
# against a service's actuator has been run against the real images, so it is
# what the cluster side is held to. Its gateway healthchecks accept 401 and
# carry the comment explaining why; every other service's healthcheck is a plain
# `curl -sf`, which fails on 401 — i.e. compose asserts, per service, whether
# /actuator/health is reachable without a token. Propagating that verdict to
# specs/cluster is the whole job.
COMPOSE_REL = os.path.join("tests", "stack", "compose.local.yaml")
GATEWAY_CHART_REL = os.path.join("specs", "cluster", "charts", "hugmesh-gateway")

# Cluster workloads with an /actuator probe and NO compose service of the same
# name. Each needs a reason, because an entry here removes that workload from
# the compose-parity check — it is an admission that nothing in this repo proves
# the probe's expectation, not an approval.
NO_COMPOSE_TWIN = {
    # LoRa-mesh BFF: never added to the compose stack (the mesh track's local
    # loop is the meshbridge daemon, not a browser flow). Its SecurityConfig
    # permitAll()s /actuator/health/** like every other BFF, so `curl -sf` is
    # right — but that is upstream-repo knowledge, not evidence from this tree.
    "hugmesh-mesh-bff-api",
    # remote-fragment's `sync` sidecar is the fragment-sync service, which has
    # no Spring Security at all (only actuator is exposed, see its
    # application.yml). Nothing gates the endpoint, so httpGet is correct.
    "hugmesh-remote-fragment",
    # The tailnet-only 4th gateway instance. It deploys the SAME chart as the
    # three that DO have compose twins, so it inherits their probe shape
    # verbatim; [gateway-probe-401] renders it explicitly all the same.
    "hugmesh-superadmin-gateway",
}

WORKLOAD_KINDS = ("Deployment", "StatefulSet", "DaemonSet")
PROBE_KEYS = ("readinessProbe", "livenessProbe", "startupProbe")

failures = []
notes = []


def fail(check, msg):
    failures.append((check, msg))


def ok(check, msg):
    notes.append((check, msg))


# ── shell-probe semantics ────────────────────────────────────────────────────
# `[ "$code" = 401 ]` / `[ "${code}" = "401" ]`
_CODE_TEST = re.compile(r'\[\s*"?\$\{?\w+\}?"?\s*=\s*"?(\d{3})"?\s*\]')
# `grep -qE '^(200|401)$'`
_GREP_ALT = re.compile(r"\^\(?((?:\d{3})(?:\|\d{3})*)\)?\$")
# the actuator path a probe command actually requests
_URL_PATH = re.compile(r"https?://[^\s'\"]*?(/actuator/[A-Za-z0-9_/.-]*)")


def curl_fails_on_error(cmd):
    """True when the command's curl aborts on a >=400 response (-f/--fail).

    This is the shape that makes a 401 look like a dead container: `curl -sf`
    exits 22 on 401 exactly as it does on 500.
    """
    for tok in cmd.split():
        if tok.startswith("--") and tok.split("=")[0] in (
            "--fail",
            "--fail-early",
            "--fail-with-body",
        ):
            return True
        if re.fullmatch(r"-[a-zA-Z]*f[a-zA-Z]*", tok):
            return True
    return False


def accepted_codes(cmd):
    """HTTP status codes a shell probe command scores as success.

    Empty set means the command does not inspect the status code at all (it
    delegates to curl's own exit status).
    """
    codes = set(_CODE_TEST.findall(cmd))
    for alt in _GREP_ALT.findall(cmd):
        codes.update(alt.split("|"))
    return codes


def shell_of(command):
    """Flatten an exec command / compose `test:` into one shell string."""
    if isinstance(command, str):
        parts = [command]
    else:
        parts = [str(x) for x in command]
    if parts and parts[0] in ("CMD-SHELL", "CMD", "NONE"):
        parts = parts[1:]
    # compose escapes a literal `$` as `$$`; k8s uses the same doubling.
    return " ".join(parts).replace("$$", "$")


class ProbeFacts:
    """What one probe (k8s Probe or compose healthcheck) actually asserts."""

    def __init__(self, kind, path, codes, fails_on_error, shell, raw):
        self.kind = kind                    # httpGet | exec | tcpSocket | grpc | none
        self.path = path                    # requested URL path, or None
        self.codes = codes                  # explicitly accepted status codes
        self.fails_on_error = fails_on_error
        self.shell = shell
        self.raw = raw

    @property
    def is_actuator(self):
        return bool(self.path and self.path.startswith("/actuator"))

    @property
    def tolerates_401(self):
        if self.kind == "httpGet":
            # kubelet scores httpGet success as 200 <= code < 400. Always false.
            return False
        if self.kind != "exec":
            return False
        return "401" in self.codes and not self.fails_on_error


def facts_from_k8s_probe(probe):
    if not isinstance(probe, dict):
        return ProbeFacts("none", None, set(), False, "", probe)
    if "httpGet" in probe:
        hg = probe["httpGet"] or {}
        return ProbeFacts("httpGet", hg.get("path"), set(), False, "", probe)
    if "exec" in probe:
        sh = shell_of(((probe["exec"] or {}).get("command")) or [])
        m = _URL_PATH.search(sh)
        return ProbeFacts(
            "exec", m.group(1) if m else None,
            accepted_codes(sh), curl_fails_on_error(sh), sh, probe,
        )
    if "tcpSocket" in probe:
        return ProbeFacts("tcpSocket", None, set(), False, "", probe)
    if "grpc" in probe:
        return ProbeFacts("grpc", None, set(), False, "", probe)
    return ProbeFacts("none", None, set(), False, "", probe)


def facts_from_compose_healthcheck(hc):
    sh = shell_of((hc or {}).get("test") or [])
    m = _URL_PATH.search(sh)
    return ProbeFacts(
        "exec", m.group(1) if m else None,
        accepted_codes(sh), curl_fails_on_error(sh), sh, hc,
    )


# ── loaders ──────────────────────────────────────────────────────────────────
def load_workloads(cluster_dir):
    """(workload-name, container-name, probe-key, ProbeFacts) for every probe
    authored as plain YAML under specs/cluster/manifests."""
    out = []
    for dirpath, _dirnames, filenames in os.walk(os.path.join(cluster_dir, "manifests")):
        for fn in sorted(filenames):
            if not fn.endswith((".yaml", ".yml")):
                continue
            path = os.path.join(dirpath, fn)
            try:
                docs = list(yaml.safe_load_all(open(path, encoding="utf-8")))
            except yaml.YAMLError:
                # Structural YAML validity is lint:cluster-manifest-integrity's
                # job; skipping here keeps the two gates' failures distinct.
                continue
            for doc in docs:
                if not isinstance(doc, dict) or doc.get("kind") not in WORKLOAD_KINDS:
                    continue
                name = ((doc.get("metadata") or {}).get("name")) or "?"
                pod = ((doc.get("spec") or {}).get("template") or {}).get("spec") or {}
                for ctr in (pod.get("containers") or []):
                    for key in PROBE_KEYS:
                        if key in (ctr or {}):
                            out.append((name, ctr.get("name", "?"), key,
                                        facts_from_k8s_probe(ctr[key])))
    return out


def load_compose(tree):
    path = os.path.join(tree, COMPOSE_REL)
    doc = yaml.safe_load(open(path, encoding="utf-8"))
    return (doc or {}).get("services") or {}


# ── the ArgoCD source model ──────────────────────────────────────────────────
# ArgoCD does not "apply the values it likes". For a Helm source it shells out to
#
#   helm template <release> <chart> --values <f>... --set k=v... [--set-string k=v]
#                 [--namespace <destination.namespace>] [--include-crds]
#
# and the LAST word belongs to --set. Its documented precedence is
#
#   parameters > valuesObject > values > valueFiles > the chart's own values.yaml
#
# (argo-cd user-guide/helm/, "Helm Value Precedence"), which is just helm's own
# rule — a later --values file beats an earlier one and --set beats every
# --values (helm chart_template_guide/values_files/; re-verified empirically
# against the same pinned helm this gate runs). An Application may also carry
# spec.sources[] instead of spec.source, each entry having the same shape.
#
# So this gate does NOT re-implement the merge — that is exactly the kind of
# plausible-but-wrong model that lets a gateway ship unprobed while the gate
# stays green. It hands the same inputs to the same helm in the same order and
# reads what comes back. Anything it cannot hand over (valueFiles /
# fileParameters, a non-string parameter value) is a FAILURE, never a quiet
# render-the-defaults: a gateway rendered from the wrong inputs is a gateway
# this gate is not checking at all.


class GatewaySource:
    """One ArgoCD Application source that deploys the shared gateway chart."""

    def __init__(self, origin, app, label, release, namespace, skip_crds):
        self.origin = origin        # apps/20-gateway-be.yaml
        self.app = app              # Application metadata.name
        self.label = label          # spec.source | spec.sources[2]
        self.release = release      # helm.releaseName or the Application name
        self.namespace = namespace  # spec.destination.namespace
        self.skip_crds = skip_crds
        self.value_files = []       # --values, in ArgoCD's order (values, valuesObject)
        self.set_args = []          # --set / --set-string, applied after every --values

    @property
    def where(self):
        return "%s %s (%s)" % (self.origin, self.app, self.label)


def clean_set_parameter(val):
    """ArgoCD's cleanSetParameters (util/helm/cmd.go).

    helm's --set reads `,` as a separator, so ArgoCD escapes every not-already-
    escaped comma before handing a parameter value over; a helm list/map literal
    ({...}) is passed through untouched.
    """
    if val.startswith("{") and val.endswith("}"):
        return val
    return re.sub(r"(?<!\\),", r"\\,", val)


def _app_sources(doc):
    """(label, source-dict) for spec.source AND every spec.sources[] entry.

    A multi-source Application is the same Application to Kubernetes and to us;
    reading only spec.source is how a whole gateway instance goes unexamined.
    """
    spec = doc.get("spec") or {}
    if isinstance(spec.get("source"), dict):
        yield "spec.source", spec["source"]
    if isinstance(spec.get("sources"), list):
        for i, src in enumerate(spec["sources"]):
            if isinstance(src, dict):
                yield "spec.sources[%d]" % i, src


def gateway_sources(cluster_dir, workdir):
    """Every ArgoCD source in specs/cluster/apps that deploys the gateway chart,
    materialised as the exact helm invocation ArgoCD would make."""
    out = []
    apps_dir = os.path.join(cluster_dir, "apps")
    if not os.path.isdir(apps_dir):
        fail("[gateway-probe-401]",
             "%s does not exist — there is nothing to render, so every gateway "
             "assertion below would be vacuous" % apps_dir)
        return out
    for fn in sorted(os.listdir(apps_dir)):
        if not fn.endswith((".yaml", ".yml")):
            continue
        path = os.path.join(apps_dir, fn)
        try:
            docs = list(yaml.safe_load_all(open(path, encoding="utf-8")))
        except yaml.YAMLError:
            continue
        for doc in docs:
            if not isinstance(doc, dict) or doc.get("kind") != "Application":
                continue
            app = ((doc.get("metadata") or {}).get("name")) or "?"
            dest = ((doc.get("spec") or {}).get("destination")) or {}
            for label, src in _app_sources(doc):
                if os.path.normpath(str(src.get("path") or "")) != os.path.normpath(
                        GATEWAY_CHART_REL):
                    continue
                helm = src.get("helm")
                if helm is None:
                    helm = {}
                if not isinstance(helm, dict):
                    fail("[gateway-probe-401]",
                         "%s %s (%s) has a non-mapping helm block (%s) — "
                         "unreadable input, so the render below would not be the "
                         "one ArgoCD performs"
                         % (fn, app, label, type(helm).__name__))
                    continue
                gs = GatewaySource(
                    fn, app, label,
                    helm.get("releaseName") or app,
                    dest.get("namespace") or "",
                    bool(helm.get("skipCrds")),
                )
                _read_helm_inputs(gs, helm, workdir, len(out))
                out.append(gs)
    return out


def check_applicationset_blindspot(cluster_dir):
    """An ApplicationSet that templates the gateway chart deploys gateways this
    gate cannot render.

    Its helm inputs come out of a generator (a list, a git-directory scan, a
    cluster query) rather than out of the file, so there is no honest way to
    reproduce ArgoCD's render from the repo alone. specs/cluster already runs
    five ApplicationSets, all of them over specs/cluster/manifests — i.e. this
    is a live mechanism here, and the day one of them starts templating the
    gateway chart is the day a whole set of gateway instances would go
    unexamined. That must READ as a failure, not as an absence.
    """
    hits = []
    for dirpath, dirnames, filenames in os.walk(cluster_dir):
        if os.path.basename(dirpath) == "charts":
            dirnames[:] = []          # helm templates are not parseable YAML
            continue
        for fn in sorted(filenames):
            if not fn.endswith((".yaml", ".yml")):
                continue
            path = os.path.join(dirpath, fn)
            try:
                docs = list(yaml.safe_load_all(open(path, encoding="utf-8")))
            except yaml.YAMLError:
                continue
            for doc in docs:
                if not isinstance(doc, dict) or doc.get("kind") != "ApplicationSet":
                    continue
                # Substring over the whole object, deliberately: the chart path
                # can arrive through spec.template.spec.source.path, through a
                # sources[] entry, or through a generator's list elements.
                if GATEWAY_CHART_REL in yaml.safe_dump(doc):
                    hits.append("%s (%s)" % (
                        os.path.relpath(path, cluster_dir),
                        ((doc.get("metadata") or {}).get("name")) or "?"))
    if hits:
        fail("[gateway-probe-401]",
             "ApplicationSet(s) reference %s: %s. Their helm inputs come from a "
             "generator, so this gate cannot render what they deploy — write the "
             "gateway out as an Application, or extend this reader to expand the "
             "generator. An unrenderable gateway must not read as no gateway"
             % (GATEWAY_CHART_REL, ", ".join(sorted(hits))))


def _read_helm_inputs(gs, helm, workdir, seq):
    """Turn one helm block into --values files + --set args, IN ARGOCD'S ORDER."""
    # (1) inputs this gate cannot resolve. Fail-closed: rendering without them
    #     produces a DIFFERENT deployment than the cluster gets, and a pass on
    #     that render is worth nothing.
    for unreadable in ("valueFiles", "fileParameters"):
        if helm.get(unreadable):
            fail("[gateway-probe-401]",
                 "%s feeds helm a %s this gate cannot read (%r) — resolve it "
                 "inline or extend this reader; an un-auditable gateway input "
                 "must not pass silently" % (gs.where, unreadable, helm[unreadable]))

    def add_values(name, text):
        p = os.path.join(workdir, "vals-%d-%s.yaml" % (seq, name))
        with open(p, "w", encoding="utf-8") as fh:
            fh.write(text)
        gs.value_files.append(p)

    # (2) helm.values — a raw YAML STRING in ArgoCD. Written through verbatim
    #     rather than parsed-and-re-dumped, so duplicate keys, anchors and flow
    #     style resolve the way helm resolves them, not the way PyYAML would.
    v = helm.get("values")
    if isinstance(v, str):
        try:
            parsed = yaml.safe_load(v)
        except yaml.YAMLError as exc:
            fail("[gateway-probe-401]",
                 "%s helm.values is not valid YAML (%s)" % (gs.where, exc))
            parsed = None
        if parsed is not None and not isinstance(parsed, dict):
            fail("[gateway-probe-401]",
                 "%s helm.values does not parse to a mapping (got %s)"
                 % (gs.where, type(parsed).__name__))
        elif v.strip():
            add_values("values", v)
    elif isinstance(v, dict):
        # Not ArgoCD's schema (values is a string) but harmless to honour.
        add_values("values", yaml.safe_dump(v))
    elif v is not None:
        fail("[gateway-probe-401]",
             "%s helm.values has an unreadable shape (%s)"
             % (gs.where, type(v).__name__))

    # (3) helm.valuesObject — structured, and it BEATS helm.values.
    vo = helm.get("valuesObject")
    if isinstance(vo, dict):
        add_values("valuesObject", yaml.safe_dump(vo))
    elif vo is not None:
        fail("[gateway-probe-401]",
             "%s helm.valuesObject is not a mapping (%s)"
             % (gs.where, type(vo).__name__))

    # (4) helm.parameters — `--set`, applied last, so they beat everything above.
    #     This is the input the gate used to throw away, which is how a gateway
    #     could ship with its probes switched off and still be reported green.
    for i, param in enumerate(helm.get("parameters") or []):
        at = "%s helm.parameters[%d]" % (gs.where, i)
        if not isinstance(param, dict) or "name" not in param:
            fail("[gateway-probe-401]", "%s has no name (%r)" % (at, param))
            continue
        val = param.get("value")
        if not isinstance(val, str):
            # ArgoCD's CRD types value as a string; a bool/number here is
            # rejected by the API server, so rendering it as one would be
            # modelling a manifest that cannot exist.
            fail("[gateway-probe-401]",
                 "%s (name=%s) has a non-string value %r — ArgoCD types "
                 "parameters[].value as a string; quote it"
                 % (at, param["name"], val))
            continue
        gs.set_args += ["--set-string" if param.get("forceString") else "--set",
                        "%s=%s" % (param["name"], clean_set_parameter(val))]


def helm_render(chart_dir, gs, extra_args=()):
    """Render exactly as ArgoCD would. Returns (docs, error-string)."""
    args = ["helm", "template", gs.release, chart_dir]
    for vf in gs.value_files:
        args += ["--values", vf]
    args += list(gs.set_args)
    if gs.namespace:
        args += ["--namespace", gs.namespace]
    if not gs.skip_crds:
        args.append("--include-crds")
    args += list(extra_args)
    proc = subprocess.run(args, capture_output=True, text=True)
    if proc.returncode != 0:
        return None, (proc.stderr or proc.stdout).strip().replace("\n", " ")[:300]
    try:
        return list(yaml.safe_load_all(proc.stdout)), None
    except yaml.YAMLError as exc:
        return None, "render is not valid YAML: %s" % exc


def render_gateway_instances(tree, workdir):
    """[(where, instance-name, [container])] — rendered ONCE, here, and shared by
    every check below.

    `chart-default` leads: it is the shape a NEW gateway Application inherits
    when it overrides nothing, so it has to be safe on its own. A render that
    FAILS is a failure, never a skip — a silently-unrendered instance is an
    unchecked instance.
    """
    chart = os.path.join(tree, GATEWAY_CHART_REL)
    check_applicationset_blindspot(os.path.join(tree, "specs", "cluster"))
    sources = gateway_sources(os.path.join(tree, "specs", "cluster"), workdir)
    if not sources:
        fail("[gateway-probe-401]",
             "no ArgoCD Application source deploys %s — the render below would "
             "be vacuous (checked spec.source AND spec.sources[])"
             % GATEWAY_CHART_REL)
    default = GatewaySource("<chart>", "chart-default", "defaults",
                            "chart-default", "", False)
    out = []
    for gs in [default] + sources:
        docs, err = helm_render(chart, gs)
        if err is not None:
            fail("[gateway-probe-401]",
                 "helm template %s failed: %s" % (gs.where, err))
            continue
        deployments = [d for d in docs
                       if isinstance(d, dict) and d.get("kind") == "Deployment"]
        if not deployments:
            fail("[gateway-probe-401]",
                 "%s rendered no Deployment — nothing to assert" % gs.where)
            continue
        for dep in deployments:
            # The instance name is read off the RENDERED object, not off an
            # input dict: `--set instance.name=...` renames the workload, and a
            # gate that keys its compose parity off the values it *expected*
            # would go on checking a workload nobody deploys.
            name = ((dep.get("metadata") or {}).get("name")) or "?"
            pod = ((dep.get("spec") or {}).get("template") or {}).get("spec") or {}
            out.append((gs.where, name, list(pod.get("containers") or [])))
    return out


# ── checks ───────────────────────────────────────────────────────────────────
def check_gateway_chart(rendered):
    """[gateway-probe-401] every rendered gateway probe tolerates the 401 its own
    SecurityConfig produces — and nothing wider."""
    before = len(failures)
    seen_instances = []
    for release, instance, containers in rendered:
        if not containers:
            fail("[gateway-probe-401]",
                 "%s rendered a Deployment with no container — nothing to assert"
                 % release)
            continue
        seen_instances.append("%s [%s]" % (instance, release))
        for ctr in containers:
            missing = [k for k in ("readinessProbe", "livenessProbe") if k not in ctr]
            if missing:
                fail("[gateway-probe-401]",
                     "%s container %s has no %s — an unprobed gateway hides the "
                     "very failure this gate pins"
                     % (release, ctr.get("name"), "/".join(missing)))
            for key in PROBE_KEYS:
                if key not in ctr:
                    continue
                probe = ctr[key]
                f = facts_from_k8s_probe(probe)
                where = "%s %s/%s" % (release, ctr.get("name"), key)
                if f.kind != "exec":
                    fail("[gateway-probe-401]",
                         "%s is a %s probe. /actuator/** is role-gated by the "
                         "gateway image (INFRA_PATHS -> GAME-MASTER/ADMIN/"
                         "SUPERADMIN), so an unauthenticated kubelet always gets "
                         "401 and only 200-399 scores as httpGet success: the pod "
                         "can never become Ready. Use the 401-tolerant exec probe "
                         "(see compose.local.yaml's gateway healthcheck)."
                         % (where, f.kind))
                    continue
                if not f.is_actuator:
                    fail("[gateway-probe-401]",
                         "%s does not request an /actuator path (got %r) — the "
                         "probe must exercise the app's own health endpoint"
                         % (where, f.path))
                    continue
                want_path = "/actuator/health/%s" % (
                    "readiness" if key == "readinessProbe" else "liveness")
                if key in ("readinessProbe", "livenessProbe") and f.path != want_path:
                    fail("[gateway-probe-401]",
                         "%s requests %s, expected %s" % (where, f.path, want_path))
                if f.fails_on_error:
                    fail("[gateway-probe-401]",
                         "%s uses curl -f/--fail, which aborts on 401 exactly as "
                         "it does on 500 — the exec wrapper is then cosmetic and "
                         "the pod still never becomes Ready" % where)
                if f.codes != {"200", "401"}:
                    fail("[gateway-probe-401]",
                         "%s accepts %s; it must accept exactly {200, 401}. 401 "
                         "proves the process is up, Netty is listening and the "
                         "security chain is wired; 000 and 5xx prove none of that "
                         "and must keep failing"
                         % (where, sorted(f.codes) or "no explicit status code"))
                argv = ((probe.get("exec") or {}).get("command")) or []
                if not str(argv[0] if argv else "").endswith("sh"):
                    fail("[gateway-probe-401]",
                         "%s does not invoke a shell. A k8s ExecAction is 'not "
                         "executed through a shell', so `code=$(...)` needs an "
                         "explicit /bin/sh -c" % where)
                # A malformed timeoutSeconds must READ as a finding, not as a
                # traceback: the kubelet would reject the object, and a gate that
                # dies on it reports nothing about the other instances.
                raw_timeout = probe.get("timeoutSeconds")
                try:
                    timeout = 1 if raw_timeout is None else int(raw_timeout)
                except (TypeError, ValueError):
                    fail("[gateway-probe-401]",
                         "%s has a non-integer timeoutSeconds (%r); k8s types it "
                         "as int32" % (where, raw_timeout))
                    timeout = None
                if timeout is not None and timeout < 2:
                    fail("[gateway-probe-401]",
                         "%s leaves timeoutSeconds at the kubelet default of 1s. "
                         "This probe forks sh+curl, which does not reliably "
                         "finish inside 1s on an SBC node" % where)
    if len(failures) == before:
        ok("[gateway-probe-401]",
           "all %d gateway renders (%s) probe /actuator over exec and accept "
           "exactly 200|401"
           % (len(seen_instances), ", ".join(sorted(seen_instances))))


def check_compose_oracle(tree):
    """[compose-gateway-401] the compose gateway healthchecks stay 401-tolerant.

    They are what [compose-cluster-401-parity] compares the cluster against; a
    'simplification' back to `curl -sf` would break the local stack AND hollow
    out that check in the same commit.
    """
    services = load_compose(tree)
    gws = {
        name: facts_from_compose_healthcheck(svc.get("healthcheck"))
        for name, svc in services.items()
        if isinstance(svc, dict) and name.endswith("-gateway") and svc.get("healthcheck")
    }
    if not gws:
        fail("[compose-gateway-401]",
             "no gateway service in %s has a healthcheck — the parity oracle is "
             "gone" % COMPOSE_REL)
        return
    bad = sorted(n for n, f in gws.items() if not f.tolerates_401)
    if bad:
        fail("[compose-gateway-401]",
             "compose gateway healthcheck(s) no longer tolerate 401: %s. The "
             "gateway gates /actuator/**, so `curl -sf` reports the container "
             "unhealthy forever while it serves traffic perfectly well"
             % ", ".join(bad))
    else:
        ok("[compose-gateway-401]",
           "compose keeps 401 acceptable for %d gateway healthcheck(s)" % len(gws))


def cluster_probe_index(tree, rendered):
    """workload-name -> [(container, probe-key, ProbeFacts)] for manifests AND
    the rendered gateway chart instances.

    Keyed on the name the render PRODUCED, so an instance renamed through
    helm.parameters is indexed as the workload that actually lands — and the
    compose service it used to answer for goes visibly unmatched.
    """
    index = {}
    for name, ctr, key, f in load_workloads(os.path.join(tree, "specs", "cluster")):
        index.setdefault(name, []).append((ctr, key, f))
    for where, instance, containers in rendered:
        if where.startswith("<chart>"):
            continue        # the chart default is not a deployed workload
        for ctr in containers:
            for key in PROBE_KEYS:
                if key in (ctr or {}):
                    index.setdefault(instance, []).append(
                        (ctr.get("name", "?"), key, facts_from_k8s_probe(ctr[key])))
    return index


def check_parity(tree, index):
    """[compose-cluster-401-parity] a compose healthcheck that had to tolerate
    401 is evidence the service role-gates its actuator; the cluster probe for
    the same service must tolerate it too."""
    services = load_compose(tree)
    before = len(failures)
    checked = 0
    for name, svc in sorted(services.items()):
        if not isinstance(svc, dict) or not svc.get("healthcheck"):
            continue
        cf = facts_from_compose_healthcheck(svc["healthcheck"])
        if not cf.is_actuator or not cf.tolerates_401:
            continue
        probes = index.get(name)
        if probes is None:
            fail("[compose-cluster-401-parity]",
                 "compose service %s tolerates 401 on %s but no cluster workload "
                 "of that name has any probe — the workaround was never "
                 "propagated to specs/cluster" % (name, cf.path))
            continue
        for ctr, key, f in probes:
            if not f.is_actuator:
                continue
            checked += 1
            if not f.tolerates_401:
                fail("[compose-cluster-401-parity]",
                     "compose %s accepts 401 on %s (its actuator is role-gated) "
                     "but the cluster %s on container %s is a %s probe that does "
                     "not: the kubelet gets 401 forever and the pod never becomes "
                     "Ready" % (name, cf.path, key, ctr, f.kind))
    if not checked:
        fail("[compose-cluster-401-parity]",
             "no cluster probe was compared against a 401-tolerant compose "
             "healthcheck — the check ran vacuously")
    elif len(failures) == before:
        ok("[compose-cluster-401-parity]",
           "%d cluster probe(s) match their compose counterpart's 401 tolerance"
           % checked)


def check_coverage(tree, index):
    """[actuator-probe-coverage] every /actuator probe in the cluster payload is
    either covered by a compose healthcheck (so parity can judge it) or listed,
    with a reason, as having no compose twin."""
    services = load_compose(tree)
    with_actuator_hc = {
        name for name, svc in services.items()
        if isinstance(svc, dict) and svc.get("healthcheck")
        and facts_from_compose_healthcheck(svc["healthcheck"]).is_actuator
    }
    uncovered = []
    total = 0
    for name, probes in sorted(index.items()):
        if not any(f.is_actuator for _c, _k, f in probes):
            continue
        total += 1
        if name in with_actuator_hc or name in NO_COMPOSE_TWIN:
            continue
        uncovered.append(name)
    if uncovered:
        fail("[actuator-probe-coverage]",
             "workload(s) probe /actuator with no compose healthcheck to judge "
             "them against and no NO_COMPOSE_TWIN entry: %s. Add the compose "
             "service (preferred — it is the only thing here that runs the real "
             "image) or record why it has no twin, having CHECKED that service's "
             "SecurityConfig actually permitAll()s /actuator/health/**"
             % ", ".join(uncovered))
    else:
        ok("[actuator-probe-coverage]",
           "all %d actuator-probed workloads are judged by compose or listed as "
           "twinless" % total)
    stale = sorted(n for n in NO_COMPOSE_TWIN if n not in index)
    if stale:
        fail("[actuator-probe-coverage]",
             "NO_COMPOSE_TWIN lists workload(s) that no longer probe /actuator: "
             "%s — delete the entry rather than leave a stale exemption"
             % ", ".join(stale))


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    tree = os.path.abspath(sys.argv[1])
    if shutil.which("helm") is None:
        print("  FAIL [preflight] helm is not on PATH. The four gateway "
              "instances share one chart, so this gate RENDERS it; there is no "
              "model-only fallback, because a silent SKIP is exactly the hole "
              "this class of bug hides in.")
        return 1
    for rel in (COMPOSE_REL, os.path.join(GATEWAY_CHART_REL, "Chart.yaml")):
        if not os.path.exists(os.path.join(tree, rel)):
            print("  FAIL [preflight] missing %s under %s" % (rel, tree))
            return 1

    workdir = tempfile.mkdtemp(prefix="probe-auth-")
    try:
        rendered = render_gateway_instances(tree, workdir)
        check_gateway_chart(rendered)
        check_compose_oracle(tree)
        index = cluster_probe_index(tree, rendered)
        check_parity(tree, index)
        check_coverage(tree, index)
    finally:
        shutil.rmtree(workdir, ignore_errors=True)

    for check, msg in notes:
        print("  PASS %s %s" % (check, msg))
    for check, msg in failures:
        print("  FAIL %s %s" % (check, msg))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
