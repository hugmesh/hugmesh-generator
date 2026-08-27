#!/usr/bin/env bash
# test-fragment-route-target.sh — the /_fragments/** route must point at something
# that can actually SERVE fragment bundles, in BOTH lanes.
#
# THE BUG THIS EXISTS TO KILL
# ---------------------------
# The compose lane's fe-gateway routed
#
#     - id: remote-fragment
#       uri: http://hugmesh-remote-fragment:8081     # the Spring SYNC app
#       predicates: [ Path=/_fragments/** ]
#
# The cluster is a two-container pod (specs/cluster/manifests/remote-fragment/
# deployment.yaml): `web` (nginxinc/nginx-unprivileged, :8080) SERVES the bundles
# and `sync` (the first-party image, actuator on :8081) only WRITES them into the
# shared docroot. The compose lane ran the SYNC HALF ONLY — so two faults stacked:
#
#   1. :8081 is the actuator port; it serves no bundle bytes, and
#   2. there was NO fragment web server in compose at all, so the sync service's
#      SYNC_TARGET_DIR=/usr/share/nginx/html was a docroot NOTHING SERVED.
#
# Fixing (1) alone would still have been broken, which is why this test does not
# assert "the port is 8080". The failure mode is the dangerous one: the host's
# loadRemoteModule fails at the NETWORK layer, and a federated remote that cannot
# load renders a BLANK PAGE rather than an error page or a 404.
#
# WHAT IS ASSERTED (invariants, nothing hardcoded)
# ------------------------------------------------
#   [route-target-exists]  the compose route that WINS /_fragments/** (real SCG
#                          first-match-wins simulation) names a service that is
#                          actually DEFINED in the compose project (compose.local
#                          plus everything it `include:`s).
#   [route-target-port]    the route's port is a port that service actually
#                          LISTENS on, DERIVED from the service definition —
#                          a bind-mounted nginx conf's `listen` directives are
#                          authoritative when present, else SERVER_PORT, else
#                          expose/ports. A HARDCODED expectation is exactly how
#                          this drifted, so the expected value is computed.
#   [healthcheck-agrees]   the target's healthcheck probes that same derived port
#                          (otherwise the healthcheck goes green on a port the
#                          gateway never uses).
#   [docroot-is-served]    the nginx `root` from that conf is a shared volume the
#                          web service mounts, AND some other service mounts the
#                          SAME volume, writable, at its own SYNC_TARGET_DIR.
#                          This is the original defect stated directly: a writer
#                          with no reader.
#   [lane-parity]          compose and cluster agree about WHICH COMPONENT serves
#                          /_fragments/**: the compose route target's image and
#                          the cluster route target's container image are the
#                          same image. Repointing either lane at the first-party
#                          sync image breaks this.
#   [cluster-route-port]   the cluster route's port exists on the target Service
#                          and its targetPort resolves to a real container port.
#   [m2-override-services] every service in compose.m2-local.yaml exists in
#                          compose.local.yaml (it is a build-args-only override;
#                          a rename on one side alone silently stops applying).
#
# Offline: reads committed files only. No docker, no cluster, no network.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${FRAGMENT_ROUTE_ROOT:-$(cd "${HERE}/../.." && pwd)}"

python3 - "$ROOT" <<'PY'
import os
import re
import sys

root = sys.argv[1]

try:
    import yaml
except Exception as e:  # pragma: no cover - preflight in CI catches this
    print(f"FATAL: PyYAML is required ({e}).", file=sys.stderr)
    sys.exit(2)

COMPOSE      = os.path.join(root, "tests", "stack", "compose.local.yaml")
COMPOSE_M2   = os.path.join(root, "tests", "stack", "compose.m2-local.yaml")
COMPOSE_FE   = os.path.join(root, "tests", "stack", "gateway-routes", "fe",
                            "application-routes.yml")
CLUSTER_FE   = os.path.join(root, "specs", "cluster", "apps", "20-gateway-fe.yaml")
CLUSTER_MANI = os.path.join(root, "specs", "cluster", "manifests")

FRAGMENT_PATH = "/_fragments/example-slug/0123456789abcdef/remoteEntry.json"

passed = failed = 0


def ok(msg):
    global passed
    passed += 1
    print(f"  PASS {msg}")


def bad(msg):
    global failed
    failed += 1
    print(f"  FAIL {msg}")


# ---------------------------------------------------------------- matching ---
def ant_to_re(pattern):
    """Spring's Ant path matching: ** crosses /, * does not."""
    out, i = [], 0
    while i < len(pattern):
        if pattern.startswith("**", i):
            out.append(".*")
            i += 2
        elif pattern[i] == "*":
            out.append("[^/]*")
            i += 1
        else:
            out.append(re.escape(pattern[i]))
            i += 1
    return re.compile("^" + "".join(out) + "$")


def path_matches(patterns, path):
    return any(ant_to_re(p.strip()).search(path) for p in patterns if p.strip())


def host_matches(pattern, host):
    return ant_to_re(pattern.strip().replace(".", "\x00")
                     ).search(host.replace(".", "\x00")) is not None


def load_compose_routes(path):
    doc = yaml.safe_load(open(path))
    raw = doc["spring"]["cloud"]["gateway"]["server"]["webflux"]["routes"]
    routes = []
    for r in raw:
        entry = {"id": r["id"], "uri": r["uri"], "paths": [], "host": None,
                 "header": None}
        for p in r.get("predicates", []):
            if p.startswith("Path="):
                entry["paths"] = p[len("Path="):].split(",")
            elif p.startswith("Host="):
                entry["host"] = p[len("Host="):]
            elif p.startswith("Header="):
                entry["header"] = p[len("Header="):]
        routes.append(entry)
    return routes


def load_cluster_routes(path):
    doc = yaml.safe_load(open(path))
    values = yaml.safe_load(doc["spec"]["source"]["helm"]["values"])
    return [{
        "id": r["id"],
        "uri": r["uri"],
        "paths": str(r["path"]).split(",") if r.get("path") else [],
        "host": r.get("host"),
        "header": r.get("header"),
    } for r in values["routes"]]


def first_match(routes, path, host="localhost", accept="*/*"):
    """SCG semantics: first route in DECLARED ORDER whose predicates all hold."""
    for r in routes:
        if r["host"] and not host_matches(r["host"], host):
            continue
        if r["paths"] and not path_matches(r["paths"], path):
            continue
        if r["header"]:
            name, _, value_re = r["header"].partition(",")
            if name.strip().lower() != "accept":
                continue
            if not re.search(value_re.strip(), accept):
                continue
        return r
    return None


URI = re.compile(r"^\w+://(?P<host>[^/:]+)(?::(?P<port>\d+))?")


def uri_parts(uri):
    m = URI.match(uri)
    if not m:
        return None, None
    return m.group("host"), int(m.group("port") or 0)


# ----------------------------------------------------------------- compose ---
def load_compose_project(path, seen=None):
    """compose.local.yaml plus every file it `include:`s (recursively).

    The route target may legitimately live in an included profile file (the
    games wasm-fragment does), so "is this service defined?" must be asked of
    the whole PROJECT, not of one file.
    """
    seen = seen if seen is not None else set()
    real = os.path.realpath(path)
    if real in seen or not os.path.exists(real):
        return {}, {}, set()
    seen.add(real)
    doc = yaml.safe_load(open(real)) or {}
    services = {}
    origins = {}
    volumes = set()
    here = os.path.dirname(real)
    for inc in doc.get("include", []) or []:
        p = inc.get("path") if isinstance(inc, dict) else inc
        if not p:
            continue
        sub, sub_org, sub_vol = load_compose_project(os.path.join(here, p), seen)
        services.update(sub)
        origins.update(sub_org)
        volumes |= sub_vol
    for name, svc in (doc.get("services") or {}).items():
        services[name] = svc
        origins[name] = real
    volumes |= set((doc.get("volumes") or {}).keys())
    return services, origins, volumes


def split_mount(entry):
    """'src:dst[:mode]' -> (src, dst, mode). Long syntax dicts too."""
    if isinstance(entry, dict):
        return entry.get("source"), entry.get("target"), (
            "ro" if entry.get("read_only") else "")
    bits = str(entry).split(":")
    if len(bits) == 1:
        return None, bits[0], ""
    if len(bits) == 2:
        return bits[0], bits[1], ""
    return bits[0], bits[1], bits[2]


# Negative controls re-run the same checks over DELIBERATELY BROKEN inputs. A
# mutation that changes an nginx conf has to be visible to the readers without
# touching the real file, so every conf read goes through here.
CONF_OVERRIDE = {}


def read_conf(path):
    return CONF_OVERRIDE.get(path, None) or open(path).read()


def env_of(svc):
    """Compose accepts both mapping and KEY=VALUE list forms for `environment:`."""
    env = svc.get("environment") or {}
    if isinstance(env, list):
        return dict(e.split("=", 1) for e in env if "=" in e)
    return {k: v for k, v in env.items()}


LISTEN = re.compile(r"^\s*listen\s+(?P<addr>\S+)\s*;", re.M)
NGINX_ROOT = re.compile(r"^\s*root\s+(?P<dir>\S+?)\s*;", re.M)


def nginx_conf_of(svc, origin):
    """The on-disk nginx config a service bind-mounts, if any."""
    base = os.path.dirname(origin)
    for entry in svc.get("volumes", []) or []:
        src, dst, _mode = split_mount(entry)
        if not src or not dst or not str(dst).startswith("/etc/nginx"):
            continue
        p = src if os.path.isabs(src) else os.path.join(base, src)
        if os.path.isfile(p):
            return os.path.realpath(p)
    return None


def listen_ports(conf_text):
    ports = set()
    for m in LISTEN.finditer(conf_text):
        addr = m.group("addr")
        tail = addr.rsplit("]", 1)[-1] if "]" in addr else addr
        num = tail.rsplit(":", 1)[-1]
        if num.isdigit():
            ports.add(int(num))
    return ports


def derived_ports(name, svc, origin):
    """Ports a compose service actually listens on, and where that was learned.

    Precedence is deliberate: a bind-mounted nginx conf is the FILE THAT DECIDES
    the port at runtime, so when one is present it is authoritative and nothing
    else may widen the set. That is what makes 'change the listen port and not
    the route' a failing mutation instead of a silent pass.
    """
    conf = nginx_conf_of(svc, origin)
    if conf:
        ports = listen_ports(read_conf(conf))
        if ports:
            return ports, f"nginx conf {os.path.relpath(conf, root)}"
    env = env_of(svc)
    if env.get("SERVER_PORT"):
        return {int(str(env["SERVER_PORT"]))}, "SERVER_PORT"
    ports = set()
    for e in svc.get("expose", []) or []:
        if str(e).isdigit():
            ports.add(int(e))
    for p in svc.get("ports", []) or []:
        if isinstance(p, dict):
            if p.get("target"):
                ports.add(int(p["target"]))
        else:
            bits = str(p).split(":")
            if bits[-1].split("/")[0].isdigit():
                ports.add(int(bits[-1].split("/")[0]))
    if ports:
        return ports, "expose/ports"
    return set(), "nothing in the service definition"


HC_URL = re.compile(r"https?://[^/\s]*?:(?P<port>\d+)/")


def healthcheck_ports(svc):
    hc = svc.get("healthcheck") or {}
    test = hc.get("test")
    if not test:
        return set()
    text = " ".join(test) if isinstance(test, list) else str(test)
    return {int(m.group("port")) for m in HC_URL.finditer(text)}


def compose_image(name, svc):
    if svc.get("image"):
        return svc["image"]
    build = svc.get("build")
    if isinstance(build, dict) and build.get("context"):
        return "build:" + os.path.basename(str(build["context"]).rstrip("/"))
    if isinstance(build, str):
        return "build:" + os.path.basename(build.rstrip("/"))
    return None


# ----------------------------------------------------------------- cluster ---
def cluster_docs(dirname):
    for dirpath, _dirs, files in os.walk(dirname):
        for f in sorted(files):
            if not f.endswith((".yaml", ".yml")):
                continue
            full = os.path.join(dirpath, f)
            try:
                for d in yaml.safe_load_all(open(full)):
                    if isinstance(d, dict) and d.get("kind"):
                        yield full, d
            except yaml.YAMLError:
                continue


WORKLOADS = ("Deployment", "StatefulSet", "DaemonSet")


def cluster_target_container(svc_name, namespace, port, docs):
    """Resolve a Service name+port to the CONTAINER that answers it."""
    service = None
    for _f, d in docs:
        if (d.get("kind") == "Service"
                and d.get("metadata", {}).get("name") == svc_name
                and d.get("metadata", {}).get("namespace") == namespace):
            service = d
            break
    if service is None:
        return None, f"no Service {namespace}/{svc_name} in specs/cluster/manifests"
    sport = None
    for p in service.get("spec", {}).get("ports", []) or []:
        if int(p.get("port", 0)) == port:
            sport = p
            break
    if sport is None:
        have = [p.get("port") for p in service.get("spec", {}).get("ports", []) or []]
        return None, (f"Service {namespace}/{svc_name} exposes {have}, "
                      f"not the routed port {port}")
    target = sport.get("targetPort", sport.get("port"))
    selector = service.get("spec", {}).get("selector") or {}
    for _f, d in docs:
        if d.get("kind") not in WORKLOADS:
            continue
        md = d.get("metadata", {})
        if md.get("namespace") != namespace:
            continue
        labels = (d.get("spec", {}).get("template", {})
                   .get("metadata", {}).get("labels") or {})
        if not selector or any(labels.get(k) != v for k, v in selector.items()):
            continue
        for c in d.get("spec", {}).get("template", {}).get("spec", {}).get(
                "containers", []) or []:
            for cp in c.get("ports", []) or []:
                if cp.get("name") == target or cp.get("containerPort") == target:
                    return (d, c), None
        return None, (f"workload {md.get('name')} has no container port "
                      f"matching targetPort {target!r}")
    return None, f"no workload in {namespace} matches selector {selector}"


# =============================================================== the checks ===
def run_checks(compose_routes, cluster_routes, services, origins, docs,
               volumes):
    """Every invariant, over whatever inputs it is handed.

    Parameterised on purpose: the negative controls at the bottom re-run it over
    deliberately broken copies, so a green run cannot be vacuous.
    """
    croute = first_match(compose_routes, FRAGMENT_PATH)
    kroute = first_match(cluster_routes, FRAGMENT_PATH)

    compose_target = compose_ports = compose_origin = None

    # -- [route-target-exists] ------------------------------------------------
    if croute is None:
        bad(f"[route-target-exists] no compose fe route matches {FRAGMENT_PATH}")
    else:
        host, port = uri_parts(croute["uri"])
        if host in services:
            compose_target = services[host]
            compose_origin = origins[host]
            ok(f"[route-target-exists] compose route '{croute['id']}' -> service "
               f"'{host}', which is defined in "
               f"{os.path.relpath(compose_origin, root)}")
        else:
            bad(f"[route-target-exists] compose route '{croute['id']}' targets "
                f"'{host}', which NO service in the compose project defines — "
                f"/_fragments/** cannot be served locally at all")

    # -- [route-target-port] --------------------------------------------------
    if compose_target is not None:
        host, port = uri_parts(croute["uri"])
        compose_ports, source = derived_ports(host, compose_target, compose_origin)
        if not compose_ports:
            bad(f"[route-target-port] cannot derive any listen port for '{host}' "
                f"from its service definition ({source}) — the routed port "
                f"{port} is unverifiable")
        elif port in compose_ports:
            ok(f"[route-target-port] routed port {port} is a port '{host}' "
               f"listens on (derived from {source}: {sorted(compose_ports)})")
        else:
            bad(f"[route-target-port] route sends /_fragments/** to "
                f"'{host}:{port}' but that service listens on "
                f"{sorted(compose_ports)} (derived from {source})")

    # -- [healthcheck-agrees] -------------------------------------------------
    if compose_target is not None and compose_ports:
        host, _port = uri_parts(croute["uri"])
        hcp = healthcheck_ports(compose_target)
        if not hcp:
            bad(f"[healthcheck-agrees] '{host}' has no http healthcheck — "
                f"nothing local proves the fragment server ever came up")
        elif hcp <= compose_ports:
            ok(f"[healthcheck-agrees] '{host}' healthchecks {sorted(hcp)}, a "
               f"port it listens on")
        else:
            bad(f"[healthcheck-agrees] '{host}' healthchecks {sorted(hcp)} but "
                f"listens on {sorted(compose_ports)} — the probe would go green "
                f"on a port the gateway never uses (or never at all)")

    # -- [docroot-is-served] --------------------------------------------------
    if compose_target is not None:
        host, _port = uri_parts(croute["uri"])
        conf = nginx_conf_of(compose_target, compose_origin)
        if conf is None:
            bad(f"[docroot-is-served] '{host}' bind-mounts no nginx config, so "
                f"nothing here shows it serves the fragment docroot at all")
        else:
            m = NGINX_ROOT.search(read_conf(conf))
            if not m:
                bad(f"[docroot-is-served] {os.path.relpath(conf, root)} declares "
                    f"no `root` — cannot tell which directory is served")
            else:
                docroot = m.group("dir")
                served_from = None
                for entry in compose_target.get("volumes", []) or []:
                    src, dst, _mode = split_mount(entry)
                    if dst == docroot and src and "/" not in src:
                        served_from = src
                if served_from is None:
                    bad(f"[docroot-is-served] '{host}' serves {docroot} but "
                        f"mounts no shared volume there — it would serve "
                        f"whatever the image happens to ship")
                else:
                    writers = []
                    for other, svc in services.items():
                        if other == host:
                            continue
                        env = env_of(svc)
                        want = env.get("SYNC_TARGET_DIR")
                        for entry in svc.get("volumes", []) or []:
                            src, dst, mode = split_mount(entry)
                            if (src == served_from and dst == want
                                    and "ro" not in mode):
                                writers.append(other)
                    if served_from not in volumes:
                        bad(f"[docroot-is-served] '{host}' mounts named volume "
                            f"'{served_from}' at its nginx root but no compose "
                            f"file DECLARES it under top-level `volumes:` — "
                            f"`docker compose up` refuses the project outright")
                    if writers:
                        ok(f"[docroot-is-served] volume '{served_from}' is "
                           f"written by {sorted(writers)} at its SYNC_TARGET_DIR "
                           f"and read by '{host}' at its nginx root {docroot}")
                    else:
                        bad(f"[docroot-is-served] '{host}' serves volume "
                            f"'{served_from}' but NO compose service writes its "
                            f"SYNC_TARGET_DIR there — the docroot stays empty "
                            f"forever. This is the original defect's twin: the "
                            f"lane shipped a writer with no reader.")

    # -- [cluster-route-port] + [lane-parity] ---------------------------------
    cluster_container = None
    if kroute is None:
        bad(f"[cluster-route-port] no cluster fe route matches {FRAGMENT_PATH}")
    else:
        khost, kport = uri_parts(kroute["uri"])
        svc_name, _, rest = khost.partition(".")
        namespace = rest.split(".")[0] if rest else ""
        found, why = cluster_target_container(svc_name, namespace, kport, docs)
        if found is None:
            bad(f"[cluster-route-port] cluster route '{kroute['id']}' -> "
                f"{khost}:{kport}: {why}")
        else:
            workload, container = found
            cluster_container = container
            ok(f"[cluster-route-port] cluster route '{kroute['id']}' -> Service "
               f"{namespace}/{svc_name}:{kport} -> container "
               f"'{container.get('name')}' of {workload['metadata']['name']}")

    if compose_target is not None and cluster_container is not None:
        host, _port = uri_parts(croute["uri"])
        cimg = compose_image(host, compose_target)
        kimg = cluster_container.get("image")
        if cimg == kimg:
            ok(f"[lane-parity] both lanes serve /_fragments/** from the same "
               f"component: {kimg}")
        else:
            bad(f"[lane-parity] compose serves /_fragments/** from {cimg} but "
                f"the cluster serves it from {kimg} — the two lanes disagree "
                f"about which component is the fragment web server")

    # -- [route-paths-agree] --------------------------------------------------
    if croute is not None and kroute is not None:
        cp = sorted(p.strip() for p in croute["paths"])
        kp = sorted(p.strip() for p in kroute["paths"])
        if cp == kp:
            ok(f"[route-paths-agree] both lanes route {cp} to the fragment fleet")
        else:
            bad(f"[route-paths-agree] compose routes {cp} but the cluster routes "
                f"{kp} to the fragment fleet")


def check_m2():
    """[m2-override-services] the private-registry override is a pure overlay."""
    m2 = yaml.safe_load(open(COMPOSE_M2)) or {}
    local_only = yaml.safe_load(open(COMPOSE)) or {}
    local_names = set((local_only.get("services") or {}).keys())
    m2_names = set((m2.get("services") or {}).keys())
    orphans = sorted(m2_names - local_names)
    if orphans:
        bad(f"[m2-override-services] compose.m2-local.yaml overrides service(s) "
            f"absent from compose.local.yaml: {orphans} — a build-args-only "
            f"override for a name that no longer exists applies to nothing, so "
            f"the private-registry build args silently stop being passed")
    else:
        ok(f"[m2-override-services] all {len(m2_names)} m2 overrides name a real "
           f"compose.local.yaml service")


print("== /_fragments/** route target ==")

compose_routes = load_compose_routes(COMPOSE_FE)
cluster_routes = load_cluster_routes(CLUSTER_FE)
services, origins, volumes = load_compose_project(COMPOSE)
docs = list(cluster_docs(CLUSTER_MANI))

run_checks(compose_routes, cluster_routes, services, origins, docs, volumes)
check_m2()

# ------------------------------------------------------- negative controls ---
print()
print("== negative controls (the test must FAIL when the bug returns) ==")


def expect_caught(label, mutate):
    """Re-run every invariant against DELIBERATELY BROKEN inputs and require it
    to trip. The probe run's output is suppressed — its FAIL lines are the
    expected detections, not real failures — so only the verdict is reported."""
    import contextlib
    import copy
    import io

    inputs = {
        "compose_routes": copy.deepcopy(compose_routes),
        "cluster_routes": copy.deepcopy(cluster_routes),
        "services": copy.deepcopy(services),
        "origins": dict(origins),
        "docs": copy.deepcopy(docs),
        "volumes": set(volumes),
    }
    saved_override = dict(CONF_OVERRIDE)
    mutate(inputs)

    global passed, failed
    p0, f0 = passed, failed
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            run_checks(**inputs)
        n = failed - f0
    finally:
        passed, failed = p0, f0
        CONF_OVERRIDE.clear()
        CONF_OVERRIDE.update(saved_override)

    if n:
        ok(f"negative control: {label} -> caught ({n} invariant(s) tripped)")
    else:
        bad(f"negative control: {label} -> NOT caught (the test is vacuous)")


def route_of(routes, rid):
    return next(r for r in routes if r["id"] == rid)


def fragment_route(routes):
    """The route that WINS /_fragments/**, whatever it is called."""
    return first_match(routes, FRAGMENT_PATH)


def m_restore_sync_target(inp):
    """The original defect, verbatim: point the route back at the sync app."""
    fragment_route(inp["compose_routes"])["uri"] = \
        "http://hugmesh-remote-fragment:8081"


def m_delete_web_service(inp):
    """The web half is dropped from compose (the state this lane shipped in)."""
    host, _ = uri_parts(fragment_route(inp["compose_routes"])["uri"])
    inp["services"].pop(host, None)
    inp["origins"].pop(host, None)


def m_move_listen_port(inp):
    """The nginx conf starts listening elsewhere and NOBODY updates the route.

    This is the mutation a hardcoded `assert port == 8080` would sail past, and
    the reason the expected port is derived from the conf instead.
    """
    host, _ = uri_parts(fragment_route(inp["compose_routes"])["uri"])
    conf = nginx_conf_of(inp["services"][host], inp["origins"][host])
    assert conf, "fixture: the web service must bind-mount an nginx conf"
    text = read_conf(conf)
    CONF_OVERRIDE[conf] = re.sub(r"(listen[^;]*:)8080\s*;", r"\g<1>8099;", text)
    assert CONF_OVERRIDE[conf] != text, "fixture: the conf mutation did nothing"


def m_route_wrong_port(inp):
    """The route's port drifts off the conf's listen port."""
    r = fragment_route(inp["compose_routes"])
    host, port = uri_parts(r["uri"])
    r["uri"] = f"http://{host}:{port + 1}"


def m_unshare_docroot(inp):
    """The sync service stops writing into the served volume.

    nginx is still there, still on the right port — and serves an empty docroot
    forever. Ports and service names alone cannot see this.
    """
    for name, svc in inp["services"].items():
        env = env_of(svc)
        if env.get("SYNC_TARGET_DIR"):
            svc["volumes"] = []


def m_undeclare_volume(inp):
    """The shared volume loses its top-level `volumes:` declaration."""
    inp["volumes"] = set()


def m_cluster_route_port(inp):
    """The cluster route names a port its Service does not expose."""
    fragment_route(inp["cluster_routes"])["uri"] = (
        "http://hugmesh-remote-fragment.hugmesh-frontend.svc.cluster.local:8081")


def m_cluster_targets_sync(inp):
    """The cluster Service is repointed at the SYNC container's port.

    Same class of defect as the compose one, on the other lane: the two lanes
    would then disagree about which component serves the bundles.
    """
    for _f, d in inp["docs"]:
        if (d.get("kind") == "Service"
                and d.get("metadata", {}).get("name") == "hugmesh-remote-fragment"):
            for prt in d["spec"]["ports"]:
                prt["targetPort"] = "actuator"


expect_caught("the compose route is pointed back at the sync app on :8081 "
              "(the original defect)", m_restore_sync_target)
expect_caught("the fragment web service is deleted from compose",
              m_delete_web_service)
expect_caught("the nginx conf's listen port moves and the route is not updated",
              m_move_listen_port)
expect_caught("the compose route's port drifts off the conf's listen port",
              m_route_wrong_port)
expect_caught("the sync service stops sharing the docroot volume "
              "(nginx serves an empty root forever)", m_unshare_docroot)
expect_caught("the shared docroot volume loses its top-level declaration",
              m_undeclare_volume)
expect_caught("the cluster route names a port its Service does not expose",
              m_cluster_route_port)
expect_caught("the cluster Service is repointed at the sync container",
              m_cluster_targets_sync)

print()
print(f"== fragment route target: {passed} passed, {failed} failed ==")
sys.exit(1 if failed else 0)
PY
