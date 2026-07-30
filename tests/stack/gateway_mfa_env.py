#!/usr/bin/env python3
"""Extractor for the gateway MFA enforcement env wiring (APP_MFA_* trio).

Driven by tests/stack/test-gateway-mfa-env.sh, which owns the assertions and the
negative controls. Deliberately dependency-light (PyYAML only) so it runs in the
`python:3-slim` CI image with no cluster, no helm and no network — the same
constraint tests/scripts/cluster_manifest_integrity.py works under.

Two modes:

  chart <chart-dir> <app.yaml> [<app.yaml> ...]
      For EACH ArgoCD Application given, deep-merge EVERY helm value input it
      declares (see helm_inputs: values / valuesObject / parameters / ...) over
      the chart's values.yaml (Helm's map-coalesce semantics) and evaluate the
      container `env:` list of templates/deployment.yaml against the result.
      Emits one TSV row per resolved env var:
          <release>  <ENV_NAME>  <effective-value>  <quoted|bare>
      plus a `#CHART-PATH` row per app recording the chart path that app points
      at (so the shared-chart premise is asserted, not assumed).

      WHY A MODEL AND NOT `helm template`: helm is not installable in the CI lint
      images (or this sandbox). The model is NARROW ON PURPOSE — it understands
      only `{{ .Values.<dotted.path> [| quote] }}` and literal scalars, and it
      FAILS LOUD (exit 2) on a values path that does not resolve, which is what
      makes it a real check of the values<->template contract rather than a
      string match. Rows whose expression it does not understand are reported as
      `#UNMODELLED` and never silently treated as absent. When helm IS on PATH,
      the driver script cross-checks this model against real `helm template`
      output.

  compose <compose-file> <service> [<service> ...]
      Emits one TSV row per APP_MFA_* env entry of each named compose service:
          <service>  <ENV_NAME>  <raw-value>  <resolved-with-var-unset>
      `resolved` applies compose's documented `${VAR:-default}` semantics for an
      UNSET variable, i.e. what `make stack-up` actually gives the container when
      the operator sets nothing. A var whose raw form is not `${NAME:-default}`
      resolves to the literal text, so an off-house-style entry is visible.

  apps [--root <dir>] <app.yaml> [<app.yaml> ...]
      Audits EVERY ArgoCD Application AND ApplicationSet template in the given
      files (typically every file the root app-of-apps syncs, not just the four
      gateway ones) for the cluster-side posture. `--root` makes the <file> column
      a path RELATIVE to that directory instead of a bare basename, so a rogue
      `extra/20-gateway-be.yaml` cannot masquerade as the declared root-level file
      of the same name. Six-column TSV:
          APP    <file> <release> MFA_ENABLED  UNSET|ON|OFF  <python repr>
          APP    <file> <release> APP_MFA_ENV  NONE|SET      <csv of names>
          APP    <file> <release> HELM_FORMS   <csv of value inputs used>  -
          APP    <file> <release> HELM_OPAQUE  NONE|OPAQUE   <csv of inputs>
          APP    <file> <release> SOURCE_FORM  SINGLE|MULTI|NONE  <n sources>
          APP    <file> <release> CHART_PATH   <canonical source.path>  <raw>
          APPSET <file> <name>[template] ...  (same rows, from spec.template.spec)
          NOAPP  <file> -         -            -             -
      MFA_ENABLED reads `mfa.enabled` out of the Application's EFFECTIVE helm
      values — every input form coalesced in helm's own precedence order, NOT just
      the `values` string (reading only that string is how a `valuesObject:` block
      turned MFA on while this gate stayed green; see helm_inputs) — and
      classifies it with the container's truthiness, NOT python's: the bare
      boolean true AND the strings "true"/"1"/"yes"/"on" all reach the JVM as an
      enabling value once the template's `| quote` has run, so all of them are ON.
      APP_MFA_ENV scans the RE-SERIALISED values tree (again comment-proof) plus
      every `--set` parameter NAME for any APP_MFA_* token, which catches a
      hand-set var smuggled in through the raw `extraEnv` escape hatch or any
      other env-ish sub-map.
      HELM_OPAQUE names the value inputs whose CONTENT is not in the file (a
      valueFiles entry, a fileParameters path). Those cannot be audited from here,
      so they are REPORTED and the driver script fails on them for a gateway
      Application: an un-auditable input must never read as a pass.
      This mode exists because the single regression this whole gate is guarding
      against is an Application flipping MFA on for a cluster instance.

  compose-gateways <compose-file>
      Discovers which compose services ARE gateway instances, from the compose
      file itself rather than from a list hard-coded in the driver (a hard-coded
      list means a NEW gateway service with no APP_MFA_* trio passes silently).
          GWSVC  <service>  <csv of why it was recognised>  <csv of APP_MFA_* it declares>

  normpath <path> [<path> ...]
      Prints norm_chart_path() of each argument, one per line. Exists so the
      DRIVER can canonicalise its own expected chart path with the exact code the
      audit rows went through: a gate whose expectation is spelled differently
      from its data compares two strings that were never comparable, which is the
      defect this mode was added alongside.
"""
import os
import posixpath
import re
import sys

import yaml

TRIO = ("APP_MFA_ENABLED", "APP_MFA_FRESHNESS_WINDOW", "APP_MFA_ENFORCE_PRIVILEGED_FLOOR")


def die(msg):
    print(f"gateway_mfa_env.py: FATAL: {msg}", file=sys.stderr)
    sys.exit(2)


# ── Helm-ish helpers ─────────────────────────────────────────────────────────
def coalesce(base, over):
    """Helm's values merge: maps merge recursively, any other type overrides."""
    out = dict(base or {})
    for k, v in (over or {}).items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = coalesce(out[k], v)
        else:
            out[k] = v
    return out


def norm_chart_path(p):
    """The CANONICAL form of an ArgoCD `spec.source.path`.

    Argo joins source.path to the cloned repo root, so `./x`, `x/`, `.//x`,
    `x/./y` and `/x` all address the SAME chart directory — but a raw string
    compare says they are five different charts. That gap was a real escape:
    a fifth gateway Application spelled `./specs/cluster/charts/hugmesh-gateway`
    was not recognised as a gateway-chart consumer at all, so the undeclared
    -consumer, undeclared-release and opaque-input assertions never looked at it
    and it shipped GREEN carrying an unreadable (valueFiles) MFA value.

    Canonicalising HERE rather than in the driver means one normalisation serves
    every consumer of these rows (assertion 1's shared-chart premise, the
    consumer-set/release-set checks and the opaque-gateway check all key on it).

    A leading `/` is stripped: the path is repo-relative by definition, so a
    leading slash is at worst a typo for the same directory. Collapsing it is the
    FAIL-CLOSED reading — it makes such an Application count as a gateway
    consumer (a loud failure to triage) instead of an invisible one.

    "" stays "" — an Application that declares no path at all is a different
    thing from one pointing at the repo root, and posixpath.normpath("") == "."
    would erase that distinction.
    """
    s = "" if p is None else str(p).strip()
    if not s:
        return ""
    return posixpath.normpath(s).lstrip("/") or "."


def source_form(spec):
    """('SINGLE'|'MULTI'|'NONE', n_sources) for one Application spec.

    An Application declares EITHER `spec.source` or the multi-source
    `spec.sources` list. MULTI-SOURCE IS NOT MODELLED BY THIS GATE (see
    mode_chart) and the driver fails on it with that stated plainly, rather than
    letting the emission assertions report a confusing "NOT emitted" for releases
    the model simply never resolved.
    """
    spec = spec or {}
    single = bool(spec.get("source")) and isinstance(spec.get("source"), dict)
    multi = [s for s in (spec.get("sources") or []) if isinstance(s, dict) and s]
    if multi:
        return "MULTI", len(multi) + (1 if single else 0)
    return ("SINGLE", 1) if single else ("NONE", 0)


def lookup(values, dotted):
    cur = values
    for part in dotted.split("."):
        if not isinstance(cur, dict) or part not in cur:
            raise KeyError(dotted)
        cur = cur[part]
    return cur


# The two forms whose CONTENT lives outside the Application manifest (a file in the
# source repo, read by the repo-server at render time). This model cannot resolve
# them; it reports them so the driver can FAIL, because an input the gate cannot
# read must never be indistinguishable from an input that says "off".
OPAQUE_HELM_FORMS = ("fileParameters", "valueFiles")
DOT_SPLIT = re.compile(r"(?<!\\)\.")


def set_dotted(tree, dotted, value):
    """`helm --set <dotted>=<value>` into an existing values tree, in place.

    ArgoCD's spec.source.helm.parameters IS --set, and --set is applied AFTER every
    -f / inline values block, so it wins over both. Honours helm's `\\.` escape for
    a literal dot in a key.
    """
    parts = [p.replace("\\.", ".") for p in DOT_SPLIT.split(dotted) if p]
    if not parts:
        return
    cur = tree
    for p in parts[:-1]:
        nxt = cur.get(p)
        if not isinstance(nxt, dict):
            nxt = {}
            cur[p] = nxt
        cur = nxt
    cur[parts[-1]] = value


class HelmInputs:
    """The coalesced result of every helm value input an ArgoCD source declares."""

    __slots__ = ("values", "forms", "opaque", "param_names")

    def __init__(self):
        self.values = {}
        self.forms = []
        self.opaque = []
        self.param_names = []


def helm_inputs(helm, where, strict=True, into=None):
    """Fold ONE `source.helm` block into a HelmInputs.

    An ArgoCD Application can inject a helm value FIVE ways and a gate that reads
    only one of them is decoration — this is not hypothetical: assertion (4b) used
    to read `helm.values` alone, and a `valuesObject:` block that switched MFA on
    for a gateway left the whole suite green.

      values         inline YAML as a STRING
      valuesObject   the same thing as structured YAML. ArgoCD documents it as
                     taking precedence over `values` (the CRD makes the two
                     mutually exclusive); coalesced last of the two here so a tree
                     that somehow carries both is fully audited, not half-read.
      parameters     [{name: dotted.path, value: "x"}] — literally `--set`, so it
                     is applied LAST and beats everything above.
      fileParameters [{name, path}] — value read from a file at render time. OPAQUE.
      valueFiles     extra `-f` files resolved from the source repo. OPAQUE.

    `strict` dies (exit 2) on a malformed input, which is right for a real
    Application. ApplicationSet TEMPLATES are parsed with strict=False because
    their fields may carry go-template placeholders; there an unreadable input
    becomes an OPAQUE entry instead of a crash — still never a silent pass.
    """
    hi = into if into is not None else HelmInputs()
    if not isinstance(helm, dict):
        return hi

    def fail(msg, tag):
        if strict:
            die(f"{where}: {msg}")
        hi.opaque.append(tag)

    # `forms` is appended AT THE POINT OF USE, never from a separate presence scan:
    # it has to mean "this input was READ", so that if the reader stops finding an
    # input the driver's reader-non-vacuity check goes off instead of every posture
    # row quietly reading UNSET. A second scan of the same keys would keep saying
    # "values" while the parse below looked at the wrong key.
    raw = helm.get("values")
    if raw:
        hi.forms.append("values")
        parsed = None
        try:
            parsed = yaml.safe_load(raw)
        except yaml.YAMLError as e:
            fail(f"unparseable spec.source.helm.values: {e}", "values:unparseable")
        if parsed is not None:
            if isinstance(parsed, dict):
                hi.values = coalesce(hi.values, parsed)
            else:
                fail("spec.source.helm.values is not a mapping", "values:non-mapping")

    vo = helm.get("valuesObject")
    if vo is not None:
        hi.forms.append("valuesObject")
        if isinstance(vo, dict):
            hi.values = coalesce(hi.values, vo)
        else:
            fail("spec.source.helm.valuesObject is not a mapping", "valuesObject:non-mapping")

    params = helm.get("parameters")
    if params:
        hi.forms.append("parameters")
    if params is not None and not isinstance(params, list):
        fail("spec.source.helm.parameters is not a list", "parameters:malformed")
        params = None
    for p in params or []:
        if not isinstance(p, dict) or not p.get("name"):
            fail(f"spec.source.helm.parameters entry has no name: {p!r}", "parameters:malformed")
            continue
        name = str(p["name"])
        hi.param_names.append(name)
        # Argo types `value` as a string, which is exactly what --set hands helm;
        # env_truthy() already treats "true"/"1"/"yes"/"on" as ON.
        set_dotted(hi.values, name, p.get("value"))

    fparams = helm.get("fileParameters")
    if fparams:
        hi.forms.append("fileParameters")
    if fparams is not None and not isinstance(fparams, list):
        fail("spec.source.helm.fileParameters is not a list", "fileParameters:malformed")
        fparams = None
    for p in fparams or []:
        if isinstance(p, dict):
            name, path = str(p.get("name", "?")), str(p.get("path", "?"))
        else:
            name, path = "?", str(p)
        hi.param_names.append(name)
        hi.opaque.append(f"fileParameters:{name}<-{path}")

    vfiles = helm.get("valueFiles")
    if vfiles:
        hi.forms.append("valueFiles")
    if vfiles is not None and not isinstance(vfiles, list):
        fail("spec.source.helm.valueFiles is not a list", "valueFiles:malformed")
        vfiles = None
    for f in vfiles or []:
        hi.opaque.append(f"valueFiles:{f}")
    return hi


def app_sources(spec):
    """[spec.source] + spec.sources.

    An Application declares EITHER `source` or the multi-source `sources` list; a
    multi-source app can hide a chart path + its helm values inside the list form,
    which reading `spec.source` alone would see as an empty source.
    """
    out = []
    s = (spec or {}).get("source")
    if isinstance(s, dict) and s:
        out.append(s)
    for s in (spec or {}).get("sources") or []:
        if isinstance(s, dict) and s:
            out.append(s)
    return out


def source_helm_inputs(srcs, where, strict=True):
    hi = HelmInputs()
    for s in srcs:
        helm_inputs(s.get("helm") or {}, where, strict=strict, into=hi)
    return hi


def as_env_string(v):
    """The string a container actually receives for a `value:` of v.

    Mirrors Go/Helm scalar printing for the types this chart uses: bool ->
    true/false lowercase, int -> decimal, nil -> empty.
    """
    if v is True:
        return "true"
    if v is False:
        return "false"
    if v is None:
        return ""
    return str(v)


# ── deployment.yaml container env extraction ─────────────────────────────────
ENV_HEADER = re.compile(r"^(\s*)env:\s*$")
NAME_ROW = re.compile(r"^\s*-\s+name:\s+(\S+)\s*$")
VALUE_ROW = re.compile(r"^\s*value:\s+(.*?)\s*$")
TPL_VALUES = re.compile(r"^\{\{-?\s*\.Values\.([A-Za-z0-9_.]+)\s*(\|\s*quote\s*)?-?\}\}$")


def env_block_lines(path):
    """The lines of the FIRST `env:` list in the file, at deeper indent."""
    lines = open(path, encoding="utf-8").read().splitlines()
    start = None
    indent = None
    for i, ln in enumerate(lines):
        m = ENV_HEADER.match(ln)
        if m:
            start = i + 1
            indent = len(m.group(1))
            break
    if start is None:
        die(f"no `env:` list found in {path}")
    out = []
    for ln in lines[start:]:
        if not ln.strip():
            out.append(ln)
            continue
        cur = len(ln) - len(ln.lstrip())
        if cur <= indent:
            break
        out.append(ln)
    return out


def render_env(chart_dir, extra_values, release):
    """Evaluate the chart's container env list against merged values."""
    vpath = os.path.join(chart_dir, "values.yaml")
    dpath = os.path.join(chart_dir, "templates", "deployment.yaml")
    for p in (vpath, dpath):
        if not os.path.isfile(p):
            die(f"missing {p}")
    values = coalesce(yaml.safe_load(open(vpath, encoding="utf-8")) or {}, extra_values)

    rows = []
    pending = None
    for ln in env_block_lines(dpath):
        s = ln.strip()
        if s.startswith("#"):
            continue
        m = NAME_ROW.match(ln)
        if m:
            pending = m.group(1).strip('"').strip("'")
            continue
        m = VALUE_ROW.match(ln)
        if m and pending:
            expr = m.group(1)
            name = pending
            pending = None
            t = TPL_VALUES.match(expr)
            if t:
                dotted, quoted = t.group(1), bool(t.group(2))
                try:
                    val = lookup(values, dotted)
                except KeyError:
                    die(
                        f"{release}: template references .Values.{dotted} for env {name} "
                        f"but that path does not resolve in the merged values"
                    )
                rows.append((release, name, as_env_string(val), "quoted" if quoted else "bare"))
            elif "{{" in expr:
                rows.append((release, name, "#UNMODELLED", "#UNMODELLED"))
            else:
                rows.append((release, name, expr.strip('"').strip("'"), "literal"))
    return rows


def app_docs(path):
    docs = [d for d in yaml.safe_load_all(open(path, encoding="utf-8")) if isinstance(d, dict)]
    apps = [d for d in docs if d.get("kind") == "Application"]
    if not apps:
        die(f"{path}: no kind:Application document")
    return apps


def mode_chart(argv):
    if len(argv) < 2:
        die("usage: chart <chart-dir> <app.yaml>...")
    chart_dir, app_paths = argv[0], argv[1:]
    out = []
    for ap in app_paths:
        for app in app_docs(ap):
            spec = app.get("spec") or {}
            # MULTI-SOURCE IS OUT OF SCOPE, AND SAYS SO. Rendering `sources[0]`
            # and hoping picks an arbitrary source: the release name, the chart
            # path and the helm values can each live in a different entry, so the
            # emission rows come out attached to the wrong release and the driver
            # reports "NOT emitted / NOT quoted" for releases that were never
            # resolved at all. That message sends the reader hunting for a missing
            # env var that is not missing. Fail on the real reason instead.
            form, n_src = source_form(spec)
            if form == "MULTI":
                die(
                    f"{os.path.basename(ap)}: Application "
                    f"'{(app.get('metadata') or {}).get('name', '?')}' uses the MULTI-SOURCE "
                    f"form (spec.sources, {n_src} sources). MULTI-SOURCE APPLICATIONS ARE NOT "
                    f"MODELLED by this gate — it cannot say which source carries the gateway "
                    f"chart or which carries the helm values, so it will not guess. Give this "
                    f"Application a single spec.source, or extend gateway_mfa_env.py to model "
                    f"spec.sources. This is NOT a missing env var."
                )
            srcs = app_sources(spec)
            src = srcs[0] if srcs else {}
            helm = src.get("helm", {}) or {}
            release = helm.get("releaseName") or app["metadata"]["name"]
            # CANONICAL path: the shared-chart premise in (1) is about which
            # DIRECTORY each release renders, and `./x` is that same directory.
            out.append(("#CHART-PATH", release, norm_chart_path(src.get("path", "")),
                        os.path.basename(ap)))
            # EVERY value input, not just the `values` string — otherwise a
            # valuesObject/--set override of mfa.enabled renders as the chart
            # default and assertion (4) reports the posture it wishes were true.
            hi = source_helm_inputs(srcs, f"{os.path.basename(ap)}/{release}")
            out.extend(render_env(chart_dir, hi.values, release))
    # Also render the bare chart (no per-instance overrides) so the chart's own
    # shipped default is asserted independently of any Application.
    out.append(("#CHART-PATH", "CHART-DEFAULTS", chart_dir, "-"))
    out.extend(render_env(chart_dir, {}, "CHART-DEFAULTS"))
    for r in out:
        print("\t".join(str(x) for x in r))


# ── compose ${VAR:-default} ──────────────────────────────────────────────────
INTERP = re.compile(r"^\$\{([A-Za-z_][A-Za-z0-9_]*):-(.*)\}$")


def mode_compose(argv):
    if len(argv) < 2:
        die("usage: compose <compose-file> <service>...")
    path, services = argv[0], argv[1:]
    doc = yaml.safe_load(open(path, encoding="utf-8")) or {}
    svcs = doc.get("services") or {}
    for name in services:
        if name not in svcs:
            die(f"{path}: no service {name}")
        env = svcs[name].get("environment")
        if env is None:
            continue
        if isinstance(env, list):  # `- KEY=value` form
            env = dict(e.split("=", 1) for e in env if "=" in e)
        for k in TRIO:
            if k not in env:
                continue
            raw = "" if env[k] is None else str(env[k])
            m = INTERP.match(raw)
            resolved = m.group(2) if m else raw
            print("\t".join([name, k, raw, resolved]))


# ── cluster-app posture audit ────────────────────────────────────────────────
APP_MFA_TOKEN = re.compile(r"APP_MFA_[A-Z0-9_]+")


def env_truthy(v):
    """Is this values entry ON as far as the CONTAINER is concerned?

    Deliberately NOT python truthiness. The chart renders `{{ .Values.mfa.enabled
    | quote }}`, so YAML `true` and YAML `"true"` both arrive at the JVM as the
    string "true" and both enable app.mfa.enabled; Spring's relaxed binding also
    accepts yes/on/1. Anything else (including the string "false", 0 and null) is
    OFF. Classifying only the bare boolean would let `enabled: "true"` slip past
    the gate, which is exactly the kind of near-miss this audit is for.
    """
    if isinstance(v, bool):
        return v
    if v is None:
        return False
    return str(v).strip().strip("\"'").lower() in ("true", "1", "yes", "on", "y")


def emit_app_audit(tag, base, spec, fallback_name, strict=True):
    """The five audit rows for one Application (or ApplicationSet template) spec."""
    srcs = app_sources(spec)
    release = fallback_name
    for s in srcs:
        rn = (s.get("helm") or {}).get("releaseName")
        if rn:
            release = str(rn)
            break
    hi = source_helm_inputs(srcs, f"{base}/{release}", strict=strict)

    mfa = hi.values.get("mfa")
    if not isinstance(mfa, dict) or "enabled" not in mfa:
        state, detail = "UNSET", "-"
    else:
        state = "ON" if env_truthy(mfa["enabled"]) else "OFF"
        detail = repr(mfa["enabled"])
    print("\t".join([tag, base, release, "MFA_ENABLED", state, detail]))

    # Re-serialise so COMMENTS cannot create a hit and so the scan reaches every
    # nesting level (extraEnv rows, ad-hoc env maps, ...); the `--set` parameter
    # NAMES are appended because `--set extraEnv[0].name=APP_MFA_ENABLED` puts the
    # interesting token in the path rather than in the tree.
    scan = yaml.safe_dump(hi.values, default_flow_style=False) + "\n" + "\n".join(hi.param_names)
    names = sorted(set(APP_MFA_TOKEN.findall(scan)))
    print("\t".join([tag, base, release, "APP_MFA_ENV",
                     "SET" if names else "NONE", ",".join(names) or "-"]))
    print("\t".join([tag, base, release, "HELM_FORMS", ",".join(hi.forms) or "-", "-"]))
    print("\t".join([tag, base, release, "HELM_OPAQUE",
                     "OPAQUE" if hi.opaque else "NONE", ",".join(hi.opaque) or "-"]))
    # WHICH source form. Multi-source is deliberately NOT modelled; reporting it
    # lets the driver say so in as many words instead of emitting a posture the
    # model did not actually resolve (see mode_chart).
    form, n_src = source_form(spec)
    print("\t".join([tag, base, release, "SOURCE_FORM", form, str(n_src)]))

    # One row PER SOURCE: a multi-source Application can point one of its sources
    # at the gateway chart while `spec.source` is absent entirely.
    # Column 5 is the CANONICAL path and column 6 the raw spelling. Consumers key
    # on column 5 because ArgoCD resolves `./x`, `x/` and `x` to one directory —
    # keying on the raw string let a fifth gateway spelled `./…` pass unseen.
    if not srcs:
        print("\t".join([tag, base, release, "CHART_PATH", "", "-"]))
    for s in srcs:
        raw = str(s.get("path", ""))
        print("\t".join([tag, base, release, "CHART_PATH", norm_chart_path(raw), raw or "-"]))


def mode_apps(argv):
    root = None
    if argv and argv[0] == "--root":
        if len(argv) < 2:
            die("usage: apps [--root <dir>] <app.yaml>...")
        root, argv = argv[1], argv[2:]
    if not argv:
        die("usage: apps [--root <dir>] <app.yaml>...")
    for ap in argv:
        # The LABEL is the path relative to the audited root when one is given.
        # A bare basename lets `extra/20-gateway-be.yaml` report as the declared
        # `20-gateway-be.yaml`, i.e. a rogue instance wearing a legitimate name.
        base = os.path.relpath(ap, root) if root else os.path.basename(ap)
        try:
            docs = list(yaml.safe_load_all(open(ap, encoding="utf-8")))
        except yaml.YAMLError as e:
            die(f"{base}: unparseable YAML: {e}")
        audited = 0
        for d in docs:
            if not isinstance(d, dict):
                continue
            kind = d.get("kind")
            name = (d.get("metadata") or {}).get("name", "?")
            if kind == "Application":
                emit_app_audit("APP", base, d.get("spec") or {}, name)
                audited += 1
            elif kind == "ApplicationSet":
                # An ApplicationSet's spec.template.spec IS an Application spec, so
                # the same posture question applies to it — a gateway deployed by an
                # ApplicationSet would otherwise be invisible to this audit. Its
                # fields may hold go-template placeholders, hence strict=False.
                tpl = (d.get("spec") or {}).get("template") or {}
                emit_app_audit("APPSET", base, tpl.get("spec") or {},
                               f"{name}[template]", strict=False)
                audited += 1
        if not audited:
            print("\t".join(["NOAPP", base, "-", "-", "-", "-"]))


# ── compose gateway-service discovery ────────────────────────────────────────
# The gateway repo/image slug. All gateway instances are ONE image run N times.
GW_IMAGE_SLUG = "hugmesh-gateway"
# Name shape, so a gateway pulled from the registry by tag (no build context) or
# named off-pattern is still recognised: <something>-gateway / gateway-<something>.
GW_NAME_RE = re.compile(r"(?:^|[-_])gateway(?:[-_]|$)")


def mode_compose_gateways(argv):
    if len(argv) != 1:
        die("usage: compose-gateways <compose-file>")
    path = argv[0]
    doc = yaml.safe_load(open(path, encoding="utf-8")) or {}
    for name, svc in sorted((doc.get("services") or {}).items()):
        svc = svc or {}
        why = []
        build = svc.get("build")
        ctx = build.get("context") if isinstance(build, dict) else build
        if ctx and os.path.basename(str(ctx).rstrip("/")) == GW_IMAGE_SLUG:
            why.append("build-context")
        if svc.get("image") and GW_IMAGE_SLUG in str(svc["image"]):
            why.append("image")
        if GW_NAME_RE.search(name):
            why.append("name")
        if not why:
            continue
        env = svc.get("environment")
        if isinstance(env, list):
            env = dict(e.split("=", 1) for e in env if "=" in e)
        env = env or {}
        declared = [k for k in TRIO if k in env]
        print("\t".join(["GWSVC", name, ",".join(why), ",".join(declared) or "-"]))


def mode_normpath(argv):
    if not argv:
        die("usage: normpath <path>...")
    for p in argv:
        print(norm_chart_path(p))


def main():
    if len(sys.argv) < 2:
        die("usage: gateway_mfa_env.py {chart|compose|compose-gateways|apps|normpath} ...")
    mode, rest = sys.argv[1], sys.argv[2:]
    if mode == "chart":
        mode_chart(rest)
    elif mode == "compose":
        mode_compose(rest)
    elif mode == "compose-gateways":
        mode_compose_gateways(rest)
    elif mode == "apps":
        mode_apps(rest)
    elif mode == "normpath":
        mode_normpath(rest)
    else:
        die(f"unknown mode {mode}")


if __name__ == "__main__":
    main()
