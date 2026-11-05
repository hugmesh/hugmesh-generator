#!/usr/bin/env bash
# =============================================================================
# test-bff-jwks-in-cluster.sh — a pod that validates a Casdoor JWT must fetch the
# signing keys from the IN-CLUSTER Casdoor Service, never from the public issuer
# host, and the wired NetworkPolicies must let that pod reach it.
#
# WHAT HAPPENED (hugmesh-generator#693; measured on a freshly bootstrapped kind
# cluster, 2026-10-07). POST /bff/login minted the cookie, then GET /bff/session,
# POST /bff/provision/matrix and POST /bff/provision/mastodon answered 500.
# hugmesh-user-bff-api logged
#     java.lang.IllegalStateException: Could not obtain the keys
#     caused by WebClientRequestException: Failed to resolve 'id.hugmesh.net'
#     on GET https://id.hugmesh.net/.well-known/jwks
# From inside that pod https://id.hugmesh.net/.well-known/jwks was unreachable (no
# DNS entry in the cluster; CoreDNS forwards to the host resolver) while
# http://casdoor.hugmesh-pki.svc.cluster.local:8000/.well-known/jwks answered 200.
# Every first-party BFF's application.yml reads
#     jwk-set-uri: ${CASDOOR_JWKS_URI:${CASDOOR_ISSUER_URI:https://id.hugmesh.net}/.well-known/jwks}
# so with only CASDOOR_ISSUER_URI set, the key fetch goes to the public name. The
# gateway chart had set CASDOOR_JWKS_URI to the in-cluster Service from the start
# (charts/hugmesh-gateway/values.yaml casdoor.jwksUri: "so the public URL need not
# resolve in-cluster"); the ten kustomize-managed BFF manifests had not. Not a Tor
# defect: any signed-in call on the kind lane that validates a JWT failed the same
# way. The onion door only met it first.
#
# WHAT THIS PINS, offline, over specs/cluster (no cluster, no network):
#   For every container (init containers included) of every Deployment /
#   StatefulSet / DaemonSet under specs/cluster/manifests that sets
#   CASDOOR_ISSUER_URI:
#     (1) it also sets CASDOOR_JWKS_URI as a LITERAL value (a valueFrom cannot be
#         read offline and is FAIL);
#     (2) that value is an in-cluster URL, http(s)://<svc>.<ns>.svc.cluster.local
#         [:port]/.well-known/jwks — the public issuer host is exactly the defect;
#     (3) the Service <svc> in <ns> exists under manifests, serves that port, and
#         selects a workload the tree defines (closure: a URL into a namespace that
#         never existed — the `casdoor.hugmesh-casdoor` shape this tree carried for
#         months — is FAIL), and the URL's scheme is the one that port speaks
#         (https against Casdoor's plain-http port 8000 is FAIL);
#     (3b) that Service is the IdP that SIGNED the token. Every first-party pod
#         validates systems-realm tokens, so it must name casdoor.hugmesh-pki; the
#         games realm's casdoor-games.hugmesh-games is a Service that exists, is
#         reachable and answers 200 with the WRONG keys, so (3) alone would wave it
#         through and every token would fail its signature check;
#     (4) the NetworkPolicies the networkpolicy kustomization ACTUALLY lists admit
#         that pod to the Service's pod port on BOTH axes: Ingress policies in the
#         Casdoor namespace that select the Casdoor pod, and Egress policies in the
#         pod's own namespace that select the pod. A pod no policy selects is open
#         and passes with that said; a selected pod needs a rule naming its
#         namespace (and its labels, when the peer carries a podSelector) on that
#         port. k8s NetworkPolicy is additive with no deny, so the union of every
#         selecting policy is what counts.
#   ... or it is on the EXEMPTION list in the analyser, with a reason and a
#   predicate that must still hold. Two anti-rot rules, like kind_route_closure.py:
#   an entry dies when NOTHING references it (no container under that key sets
#   CASDOOR_ISSUER_URI any more) and when the gap it describes is CLOSED (that
#   container now sets CASDOOR_JWKS_URI itself).
#   The gateway Helm chart (specs/cluster/charts/*) is Go-templated, so it is read
#   as text: a template that sets CASDOOR_ISSUER_URI must set CASDOOR_JWKS_URI from
#   a values key; that key's value (values.yaml, overridden by each Application's
#   helm.parameters) must pass (2) and (3), and each Application that installs the
#   chart (apps/*.yaml, destination namespace + helm.releaseName) must pass (4).
#   Fewer than MIN_CANDIDATES containers is FAIL: a census that finds nothing has
#   lost the tree, not proved it clean. So is a manifest file whose non-comment text
#   names CASDOOR_ISSUER_URI more often than the census found containers in it (a
#   CronJob, a Pod, a ConfigMap: a kind this gate does not walk). And so is a
#   container that lists CASDOOR_JWKS_URI or CASDOOR_ISSUER_URI twice: Kubernetes
#   runs the LAST entry, this gate would read the first, and a merge of two branches
#   that each added the line produces exactly that.
#
# KNOWN GAPS, said plainly: a service that reads its keys under another variable
# name is not a candidate. phpbb's extension reads HUGMESH_JWKS_URI, public and
# https-only by that extension's own rule (printed as INFO, not judged), and
# akkoma's Ueberauth OIDC strategy names the public issuer host: both still fail
# on a cluster where id.hugmesh.net does not resolve, and neither is fixed by this
# gate or the change it pins. Whether an IMAGE honours CASDOOR_JWKS_URI is a
# property of the service repository's application.yml, which this tree does not
# contain — the ten first-party BFFs' sources were read on 2026-10-07 and all carry
# the expression above (a source read, not a look inside a running image); an
# env supplied by a kustomize patch outside specs/cluster/manifests/<service>/ is
# not read; namespace labels other than kubernetes.io/metadata.name are known only
# when a Namespace manifest in the tree declares them; and kind applies NONE of
# manifests/networkpolicy (apps/08-networkpolicy.yaml is in none of
# bootstrap-kind.sh's lists; a live `kubectl get networkpolicy -A` on 2026-10-07
# showed only ArgoCD's own policies and Cassandra's), so (4) describes a device
# cluster, not kind.
#
# NEGATIVE CONTROLS: each planted defect is applied to a scratch copy of
# specs/cluster, the copy must actually differ (a no-op mutation reads exactly like
# an uncaught one), and the analyser must go RED naming that defect. One control
# plants nothing and must stay GREEN, so the staging itself is proven.
#
# Needs bash + python3 + PyYAML (the debian shell-suites job installs and
# preflights PyYAML; the alpine job has py3-yaml).
#
#   bash tests/scripts/test-bff-jwks-in-cluster.sh
#   JWKS_ROOT=<other checkout> bash tests/scripts/test-bff-jwks-in-cluster.sh
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${JWKS_ROOT:-$(cd "${HERE}/../.." && pwd)}"

command -v python3 >/dev/null 2>&1 || { echo "  FAIL python3 not available"; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "  FAIL PyYAML is required (pip install pyyaml / apk add py3-yaml)"; exit 2; }
[ -d "${REPO}/specs/cluster/manifests" ] || { echo "  FAIL ${REPO}/specs/cluster/manifests is not a directory"; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/bff-jwks.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
ANALYSER="${WORK}/analyser.py"

cat > "${ANALYSER}" <<'PY'
import glob, os, re, sys
import yaml

CLUSTER = os.path.abspath(sys.argv[1])
MAN = os.path.join(CLUSTER, "manifests")
CHARTS = os.path.join(CLUSTER, "charts")
APPS = os.path.join(CLUSTER, "apps")
MIN_CANDIDATES = 8      # 12 on 2026-10-07: 11 workload containers (games among them) + the gateway chart template; well above
IN_CLUSTER = re.compile(
    r"^(https?)://([a-z0-9][a-z0-9-]*)\.([a-z0-9][a-z0-9-]*)\.svc\.cluster\.local(?::(\d+))?(/.*)?$")
WORKLOADS = ("Deployment", "StatefulSet", "DaemonSet")
JWKS_PATH = "/.well-known/jwks"
# The IdP that signs every systems-realm token. A first-party pod's key URL must name
# THIS Service (rule 3b); the games BFF also trusts its own realm's Casdoor, see EXEMPT.
SYSTEMS_CASDOOR = ("casdoor", "hugmesh-pki")

# ── EXEMPTIONS ───────────────────────────────────────────────────────────────
# "<namespace>/<kind>/<workload>/<container>" -> why that container may set
# CASDOOR_ISSUER_URI without CASDOOR_JWKS_URI, plus `jwks_from`: the variable whose
# value + /.well-known/jwks IS its key URL, which is then held to rules (2)-(4) in
# CASDOOR_JWKS_URI's place, and `expect`: the (Service, namespace) that URL must
# resolve to, because the reason names a specific IdP. An entry is deleted the day its container sets
# CASDOOR_JWKS_URI (gap closed) or stops setting CASDOOR_ISSUER_URI (nothing
# references it); either state FAILS below.
EXEMPT = {
    "hugmesh-games/Deployment/hugmesh-games/games": {
        "reason": "GAMES-realm BFF (casdoor-games, org threewizards), not the systems "
                  "Casdoor. The games backend's application.yml builds jwk-set-uri as "
                  "${CASDOOR_ENDPOINT}/.well-known/jwks and never reads CASDOOR_JWKS_URI; "
                  "CASDOOR_ISSUER_URI (https://id.hugmesh.games) is the iss string only.",
        "jwks_from": "CASDOOR_ENDPOINT",
        "expect": ("casdoor-games", "hugmesh-games"),
        # The two-realm BFF: tokens from BOTH issuers are accepted, each decoded with
        # its own in-cluster JWKS. Every entry of the map is judged under rules (2)-(4)
        # against the IdP that signs that issuer, so the netpol path to the SYSTEMS
        # Casdoor (networkpolicy/casdoor-jwks-ingress.yaml) is load-bearing here too.
        "issuer_map": {
            "env": "APP_TENANCY_JWKS_URIS",
            "issuers_env": "APP_TENANCY_ISSUERS",
            "expect": {
                "https://id.hugmesh.games": ("casdoor-games", "hugmesh-games"),
                "https://id.hugmesh.net": SYSTEMS_CASDOOR,
            },
        },
    },
}

P = F = 0
def ok(m):
    global P; P += 1; print("  PASS " + m)
def bad(m):
    global F; F += 1; print("  FAIL " + m)
def info(m):
    print("  INFO " + m)
def rel(p):
    return os.path.relpath(p, CLUSTER)

# The C parser is ~10x faster over 6 MB of manifests and reads the same documents; fall
# back to the pure-Python one where a PyYAML build ships without libyaml.
YAML_LOADER = getattr(yaml, "CSafeLoader", yaml.SafeLoader)

def load_all(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return [d for d in yaml.load_all(fh, Loader=YAML_LOADER) if isinstance(d, dict)]
    except (yaml.YAMLError, OSError) as e:
        bad("%s: not parseable YAML: %s" % (rel(path), e)); return []

def kustomization_resources(dirpath):
    kz = os.path.join(dirpath, "kustomization.yaml")
    if not os.path.isfile(kz):
        return False, None, None
    docs = load_all(kz)
    d = docs[0] if docs else {}
    return True, set(d.get("resources") or []), d.get("namespace")

# ── census ───────────────────────────────────────────────────────────────────
workloads = []      # (path, doc, ns)
services = {}       # (name, ns) -> (path, doc)
ns_labels = {}      # namespace -> labels declared by a Namespace manifest
netpols = []        # (path, ns, doc) — WIRED ONLY (listed by its kustomization)
for dirpath, _dn, filenames in os.walk(MAN):
    has_kz, resources, defns = kustomization_resources(dirpath)
    for name in sorted(filenames):
        if not name.endswith((".yaml", ".yml")) or name == "kustomization.yaml":
            continue
        path = os.path.join(dirpath, name)
        wired = (not has_kz) or (name in resources)
        for doc in load_all(path):
            kind = doc.get("kind"); meta = doc.get("metadata") or {}
            ns = meta.get("namespace") or defns
            if kind in WORKLOADS:
                workloads.append((path, doc, ns))
            elif kind == "Service":
                services[(meta.get("name"), ns)] = (path, doc)
            elif kind == "Namespace":
                ns_labels[meta.get("name")] = dict(meta.get("labels") or {})
            elif kind == "NetworkPolicy" and wired:
                netpols.append((path, ns, doc))

def labels_of_ns(ns):
    out = dict(ns_labels.get(ns, {}))
    out["kubernetes.io/metadata.name"] = ns
    return out

def sel_matches(sel, labels):
    """Kubernetes label-selector semantics; an empty selector matches everything."""
    sel = sel or {}
    for k, v in (sel.get("matchLabels") or {}).items():
        if labels.get(k) != str(v):
            return False
    for e in sel.get("matchExpressions") or []:
        k, op = e.get("key"), e.get("operator")
        vals = [str(x) for x in (e.get("values") or [])]
        if op == "In" and labels.get(k) not in vals: return False
        if op == "NotIn" and labels.get(k) in vals: return False
        if op == "Exists" and k not in labels: return False
        if op == "DoesNotExist" and k in labels: return False
    return True

def policy_types(spec):
    t = spec.get("policyTypes")
    if t is None:   # k8s defaulting: Ingress always, Egress only when egress rules exist
        return ["Ingress", "Egress"] if spec.get("egress") is not None else ["Ingress"]
    return t

def port_ok(rports, pod_port, pod_port_name):
    if not rports:
        return True
    for rp in rports:
        rp = rp or {}
        if (rp.get("protocol") or "TCP") != "TCP":
            continue
        p = rp.get("port")
        if p is None:
            return True
        if isinstance(p, int):
            end = rp.get("endPort")
            if p == pod_port or (isinstance(end, int) and p <= pod_port <= end):
                return True
        elif pod_port_name and str(p) == pod_port_name:
            return True
    return False

def peer_matches(peer, policy_ns, other_ns, other_labels):
    peer = peer or {}
    if "ipBlock" in peer:
        return False
    nsel, psel = peer.get("namespaceSelector"), peer.get("podSelector")
    if nsel is None and psel is None:
        return False
    if nsel is not None:
        if not sel_matches(nsel, labels_of_ns(other_ns)):
            return False
    elif other_ns != policy_ns:
        return False          # podSelector-only peers are same-namespace only
    if psel is not None and not sel_matches(psel, other_labels):
        return False
    return True

def axis(policies, ns, labels, direction, other_ns, other_labels, pod_port, pod_port_name):
    """-> (admitted_or_open, text) for one axis over the wired policies."""
    key_rules, key_peer = ("ingress", "from") if direction == "Ingress" else ("egress", "to")
    selecting = [(p, d) for (p, pns, d) in policies
                 if pns == ns and direction in policy_types(d.get("spec") or {})
                 and sel_matches((d.get("spec") or {}).get("podSelector"), labels)]
    if not selecting:
        return True, "%s: no wired policy selects the pod (open)" % direction.lower()
    for path, d in selecting:
        for rule in ((d.get("spec") or {}).get(key_rules) or []):
            rule = rule or {}
            peers = rule.get(key_peer)
            if peers and not any(peer_matches(pe, ns, other_ns, other_labels) for pe in peers):
                continue
            if port_ok(rule.get("ports"), pod_port, pod_port_name):
                return True, "%s: admitted by %s (%s)" % (
                    direction.lower(), rel(path), (d.get("metadata") or {}).get("name"))
    return False, "%s: NOT admitted — %d policy/policies select the pod (%s) and none names %s%s on port %s" % (
        direction.lower(), len(selecting),
        ", ".join(sorted(set("%s (%s)" % (rel(p), (d.get("metadata") or {}).get("name")) for p, d in selecting))),
        other_ns, " pod " + ",".join("%s=%s" % kv for kv in sorted(other_labels.items())) if other_labels else "",
        pod_port)

def resolve_target(url):
    """In-cluster JWKS URL -> dict(svc, ns, path, pod_labels, pod_port, pod_port_name) or (None, why)."""
    m = IN_CLUSTER.match(url or "")
    if not m:
        return None, "%r is not an in-cluster URL (want http(s)://<svc>.<ns>.svc.cluster.local[:port]/.well-known/jwks); the public issuer host does not resolve on kind and the key fetch answers 500" % url
    scheme, svc, ns, port, path = m.groups()
    port = int(port) if port else (443 if scheme == "https" else 80)
    if path != JWKS_PATH:
        return None, "%r: path is %r, not %s" % (url, path, JWKS_PATH)
    if (svc, ns) not in services:
        return None, "%r: no Service %s in namespace %s under specs/cluster/manifests (the URL names something this tree never creates)" % (url, svc, ns)
    spath, sdoc = services[(svc, ns)]
    sports = (sdoc.get("spec") or {}).get("ports") or []
    chosen = next((p for p in sports if (p or {}).get("port") == port), None)
    if chosen is None:
        return None, "%r: Service %s (%s) does not serve port %d (it serves %s)" % (
            url, svc, rel(spath), port, [p.get("port") for p in sports])
    # The scheme must be the one the Service port speaks: Casdoor's port 8000 is named
    # `http`, so https://casdoor...:8000 passes every other rule and dies in the TLS
    # handshake. Only a port named (or appProtocol'd) http/https is judged.
    speaks = str(chosen.get("appProtocol") or chosen.get("name") or "").lower()
    if speaks in ("http", "https") and speaks != scheme:
        return None, "%r: Service %s (%s) port %d speaks %s, the URL says %s — the handshake fails" % (
            url, svc, rel(spath), port, speaks, scheme)
    selector = (sdoc.get("spec") or {}).get("selector") or {}
    backing = [(wp, wd) for (wp, wd, wns) in workloads if wns == ns and selector
               and sel_matches({"matchLabels": selector},
                               (((wd.get("spec") or {}).get("template") or {}).get("metadata") or {}).get("labels") or {})]
    if not backing:
        return None, "%r: Service %s (%s) selects %s but no Deployment/StatefulSet/DaemonSet in %s carries those labels" % (
            url, svc, rel(spath), selector, ns)
    wpath, wdoc = backing[0]
    pod_labels = (((wdoc.get("spec") or {}).get("template") or {}).get("metadata") or {}).get("labels") or {}
    tgt = chosen.get("targetPort", chosen.get("port"))
    pod_port, pod_port_name = None, None
    cports = [cp for c in (((wdoc.get("spec") or {}).get("template") or {}).get("spec") or {}).get("containers") or []
              for cp in (c.get("ports") or [])]
    if isinstance(tgt, int):
        pod_port = tgt
        pod_port_name = next((cp.get("name") for cp in cports if cp.get("containerPort") == tgt), None)
    else:
        hit = next((cp for cp in cports if cp.get("name") == tgt), None)
        if hit is None:
            return None, "%r: Service %s targets port %r by name but %s declares no container port with that name" % (
                url, svc, tgt, rel(wpath))
        pod_port, pod_port_name = hit.get("containerPort"), tgt
    return dict(svc=svc, ns=ns, spath=rel(spath), pod_labels=pod_labels,
                pod_port=pod_port, pod_port_name=pod_port_name), None

def judge(label, url, src_ns, src_labels, want=SYSTEMS_CASDOOR):
    """Rules (2)-(4) for one pod/URL pair; `want` is the (Service, namespace) it must be."""
    tgt, why = resolve_target(url)
    if tgt is None:
        bad("%s: %s" % (label, why)); return
    if (tgt["svc"], tgt["ns"]) != want:
        bad("%s: keys come from Service %s.%s, but this pod validates tokens signed by %s.%s — a Service that exists and answers 200 with the wrong keys fails every signature check" % (
            label, tgt["svc"], tgt["ns"], want[0], want[1])); return
    lines = []
    good = True
    for direction, pns, plabels, ons, olabels in (
            ("Ingress", tgt["ns"], tgt["pod_labels"], src_ns, src_labels),
            ("Egress", src_ns, src_labels, tgt["ns"], tgt["pod_labels"])):
        ok_, text = axis(netpols, pns, plabels, direction, ons, olabels, tgt["pod_port"], tgt["pod_port_name"])
        good = good and ok_
        lines.append(text)
    msg = "%s: keys from %s.%s:%d%s (Service %s, pod port %s); %s" % (
        label, tgt["svc"], tgt["ns"], tgt["pod_port"], JWKS_PATH, tgt["spath"], tgt["pod_port"], "; ".join(lines))
    (ok if good else bad)(msg)

def env_all(container, name):
    return [e for e in (container.get("env") or []) if (e or {}).get("name") == name]

def env_entry(container, name):
    """The entry for `name`; callers have already refused a container that lists it twice."""
    hits = env_all(container, name)
    return hits[0] if hits else None

# ── (A) kustomize-managed workloads ──────────────────────────────────────────
print("-- manifests: every container that sets CASDOOR_ISSUER_URI --")
candidates = 0
used_exempt = set()
seen_in_file = {}     # manifest path -> containers the census judged (for the blind-spot count)

for path, doc, ns in workloads:
    meta = doc.get("metadata") or {}
    kind, wname = doc.get("kind"), meta.get("name")
    tspec = ((doc.get("spec") or {}).get("template") or {}).get("spec") or {}
    pod_labels = (((doc.get("spec") or {}).get("template") or {}).get("metadata") or {}).get("labels") or {}
    for c in (tspec.get("initContainers") or []) + (tspec.get("containers") or []):
        key = "%s/%s/%s/%s" % (ns, kind, wname, c.get("name"))
        label = "%s/%s[%s] (%s)" % (ns, wname, c.get("name"), rel(path))
        n_issuer = len(env_all(c, "CASDOOR_ISSUER_URI"))
        if n_issuer == 0:
            for e in c.get("env") or []:
                n = (e or {}).get("name") or ""
                if n.endswith("JWKS_URI") and not IN_CLUSTER.match(str((e or {}).get("value") or "")):
                    info("%s: %s=%r is not in-cluster; it is read under another contract than CASDOOR_ISSUER_URI, so this gate does not judge it" % (label, n, e.get("value")))
            continue
        candidates += 1
        seen_in_file[path] = seen_in_file.get(path, 0) + n_issuer
        if key in EXEMPT:
            used_exempt.add(key)
        twice = [nm for nm in ("CASDOOR_ISSUER_URI", "CASDOOR_JWKS_URI") + ((EXEMPT[key]["jwks_from"],) if key in EXEMPT else ())
                 if len(env_all(c, nm)) > 1]
        if twice:
            bad("%s: %s listed more than once — Kubernetes runs the LAST entry and this gate would read the first; keep one" % (label, ", ".join(twice)))
            continue
        jwks = env_entry(c, "CASDOOR_JWKS_URI")
        if key in EXEMPT:
            ex = EXEMPT[key]
            if jwks is not None:
                bad("%s: EXEMPT, but the container now sets CASDOOR_JWKS_URI — the gap the entry describes is closed; delete the exemption" % label)
                continue
            src = env_entry(c, ex["jwks_from"])
            base = (src or {}).get("value")
            if src is None or base is None:
                bad("%s: EXEMPT because its keys come from %s, but the container sets no literal %s — the exemption's reason no longer holds" % (label, ex["jwks_from"], ex["jwks_from"]))
                continue
            print("     exempt: %s" % key)
            print("             %s" % ex["reason"])
            judge(label + " via " + ex["jwks_from"], str(base).rstrip("/") + JWKS_PATH, ns, pod_labels, ex["expect"])
            im = ex.get("issuer_map")
            if im:
                twice_m = [nm for nm in (im["env"], im["issuers_env"]) if len(env_all(c, nm)) > 1]
                mp = env_entry(c, im["env"])
                tr = env_entry(c, im["issuers_env"])
                if twice_m:
                    bad("%s: %s listed more than once — Kubernetes runs the LAST entry and this gate would read the first; keep one" % (label, ", ".join(twice_m)))
                elif mp is None or mp.get("value") is None or tr is None or tr.get("value") is None:
                    bad("%s: the two-realm BFF needs literal %s and %s; without them only one realm's tokens validate" % (label, im["env"], im["issuers_env"]))
                else:
                    uris = dict(p.split("=", 1) for p in str(mp["value"]).split(",") if "=" in p)
                    issuers = [p.split("=", 1)[0] for p in str(tr["value"]).split(",") if "=" in p]
                    domains = {p.split("=", 1)[1] for p in str(tr["value"]).split(",") if "=" in p}
                    if len(domains) != 1:
                        bad("%s: %s maps the issuers to %d domains %s — uploads get stamped per realm and each realm's admins lose the other's games; map every issuer to ONE domain" % (label, im["issuers_env"], len(domains), sorted(domains)))
                    if set(issuers) != set(uris):
                        bad("%s: %s names %s but %s names %s — a trusted issuer without a JWKS entry has no in-cluster key path" % (label, im["issuers_env"], sorted(issuers), im["env"], sorted(uris)))
                    if set(uris) != set(im["expect"]):
                        bad("%s: %s covers %s, the gate expects exactly %s" % (label, im["env"], sorted(uris), sorted(im["expect"])))
                    for iss, want in sorted(im["expect"].items()):
                        if iss in uris:
                            judge("%s %s[%s]" % (label, im["env"], iss), uris[iss], ns, pod_labels, want)
            continue
        if jwks is None:
            bad("%s: sets CASDOOR_ISSUER_URI but no CASDOOR_JWKS_URI — the key fetch goes to the public issuer host, which need not resolve in-cluster (and on kind does not)" % label)
            continue
        if "value" not in jwks or jwks.get("value") is None:
            bad("%s: CASDOOR_JWKS_URI has no literal value (valueFrom cannot be read offline)" % label)
            continue
        judge(label, str(jwks["value"]), ns, pod_labels)

# ── census blind spot: a file that names the variable more often than we judged ──
# Only Deployment / StatefulSet / DaemonSet containers are walked above. A CronJob, a
# bare Pod or a ConfigMap that carries CASDOOR_ISSUER_URI would otherwise be invisible
# and a green run would mean nothing about it. Comment-only mentions are not counted.
for dirpath, _dn, filenames in os.walk(MAN):
    for name in sorted(filenames):
        if not name.endswith((".yaml", ".yml")):
            continue
        path = os.path.join(dirpath, name)
        try:
            lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
        except OSError:
            continue
        named = sum(1 for ln in lines if "CASDOOR_ISSUER_URI" in ln and not ln.lstrip().startswith("#"))
        if named > seen_in_file.get(path, 0):
            bad("%s: %d non-comment line(s) name CASDOOR_ISSUER_URI but only %d workload container(s) there were judged — a kind this gate does not walk (CronJob, Pod, ConfigMap) or a second spelling; extend the gate" % (rel(path), named, seen_in_file.get(path, 0)))

# ── anti-rot: every exemption must still be referenced ──────────────────────
for key in sorted(set(EXEMPT) - used_exempt):
    bad("exemption %s: nothing references it (no container under that key sets CASDOOR_ISSUER_URI any more) — delete the entry" % key)
if EXEMPT and not (set(EXEMPT) - used_exempt):
    ok("anti-rot: every exemption still matches a CASDOOR_ISSUER_URI container (%d declared)" % len(EXEMPT))

# ── (B) Helm charts: text, plus each Application that installs them ─────────
print("-- charts: a template that sets CASDOOR_ISSUER_URI, per installing Application --")

def walk_values(values, dotted):
    cur = values
    for part in dotted.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return None
        cur = cur[part]
    return cur

def deep_merge(a, b):
    out = dict(a)
    for k, v in (b or {}).items():
        out[k] = deep_merge(out[k], v) if isinstance(out.get(k), dict) and isinstance(v, dict) else v
    return out

def set_dotted(values, dotted, v):
    cur = values
    parts = dotted.split(".")
    for part in parts[:-1]:
        cur = cur.setdefault(part, {})
    cur[parts[-1]] = v

applications = []   # (app path, chart rel path, namespace, release, helm block)
for apath in sorted(glob.glob(os.path.join(APPS, "*.yaml"))):
    for doc in load_all(apath):
        if doc.get("kind") != "Application":
            continue
        src = (doc.get("spec") or {}).get("source") or {}
        cpath = src.get("path") or ""
        if "/charts/" not in cpath:
            continue
        helm = src.get("helm") or {}
        applications.append((apath, cpath, ((doc.get("spec") or {}).get("destination") or {}).get("namespace"),
                             helm.get("releaseName") or (doc.get("metadata") or {}).get("name"), helm))

for cdir in sorted(glob.glob(os.path.join(CHARTS, "*"))):
    texts = []
    for t in sorted(glob.glob(os.path.join(cdir, "templates", "*.yaml"))):
        txt = open(t, encoding="utf-8", errors="replace").read()
        if re.search(r"name:\s*CASDOOR_ISSUER_URI\b", txt):
            texts.append((t, txt))
    if not texts:
        continue
    chart_base = os.path.basename(cdir.rstrip("/"))
    try:
        chart_name = (yaml.safe_load(open(os.path.join(cdir, "Chart.yaml"), encoding="utf-8")) or {}).get("name") or os.path.basename(cdir)
    except (OSError, yaml.YAMLError):
        chart_name = os.path.basename(cdir)
    try:
        base_values = yaml.safe_load(open(os.path.join(cdir, "values.yaml"), encoding="utf-8")) or {}
    except (OSError, yaml.YAMLError) as e:
        bad("%s: cannot read values.yaml: %s" % (rel(cdir), e)); continue
    for t, txt in texts:
        candidates += 1
        m = re.search(r"name:\s*CASDOOR_JWKS_URI\s*\n\s*value:\s*(.+)", txt)
        if not m:
            bad("%s: the template sets CASDOOR_ISSUER_URI but no CASDOOR_JWKS_URI env" % rel(t)); continue
        vm = re.search(r"\.Values\.([A-Za-z0-9_.]+)", m.group(1))
        if not vm:
            bad("%s: CASDOOR_JWKS_URI value %r does not come from a .Values key this gate can resolve" % (rel(t), m.group(1).strip())); continue
        # Applications spell the chart as specs/cluster/charts/<name>; the scratch copies
        # the negative controls stage live elsewhere, so match on the name after /charts/.
        installs = [a for a in applications if a[1].rstrip("/").split("/charts/")[-1] == chart_base]
        if not installs:
            bad("%s: no Application under specs/cluster/apps installs chart charts/%s, so its pods' namespace and policy admission cannot be judged" % (rel(t), chart_base)); continue
        for apath, _cp, ns, release, helm in installs:
            values = deep_merge(base_values, helm.get("valuesObject") or {})
            if isinstance(helm.get("values"), str):
                try:
                    values = deep_merge(values, yaml.safe_load(helm["values"]) or {})
                except yaml.YAMLError:
                    pass
            for prm in helm.get("parameters") or []:
                if (prm or {}).get("name"):
                    set_dotted(values, prm["name"], prm.get("value"))
            val = walk_values(values, vm.group(1))
            label = "%s/%s (chart %s via %s)" % (ns, release, chart_name, rel(apath))
            if not isinstance(val, str) or not val:
                bad("%s: values key %s resolves to %r, not a URL" % (label, vm.group(1), val)); continue
            judge(label, val, ns, {"app.kubernetes.io/name": chart_name, "app.kubernetes.io/instance": release})

# ── vacuity ──────────────────────────────────────────────────────────────────
if candidates < MIN_CANDIDATES:
    bad("the census found only %d CASDOOR_ISSUER_URI container(s)/template(s) (floor %d): the tree moved, or the scan went blind" % (candidates, MIN_CANDIDATES))
else:
    ok("vacuity: %d CASDOOR_ISSUER_URI container(s)/template(s) really inspected, %d wired NetworkPolicy document(s), %d Service(s)" % (candidates, len(netpols), len(services)))

print("\n%d passed / %d failed" % (P, F))
sys.exit(1 if F else 0)
PY

echo "== BFF JWKS in-cluster gate =="
echo "-- positive: the repo's own specs/cluster --"
python3 "${ANALYSER}" "${REPO}/specs/cluster"
RC=$?
[ "${RC}" -eq 0 ] || { echo; echo "== bff-jwks-in-cluster: FAIL (rc ${RC}) =="; exit 1; }

echo
echo "-- negative controls: each planted defect must be caught --"
NEG_P=0; NEG_F=0
neg_ok(){ echo "  PASS negative control: $*"; NEG_P=$((NEG_P+1)); }
neg_bad(){ echo "  FAIL negative control: $*"; NEG_F=$((NEG_F+1)); }

# $1 = label, $2 = substring the analyser's FAIL output must contain ("" = any red),
# $3 = a shell snippet run with $T = the staged copy of specs/cluster, which plants
# the defect. The copy MUST differ afterwards: a mutation that matched nothing would
# run, find no defect, and blame the gate for a hole the control never opened.
expect_red() {
  local label="$1" want="$2" inject="$3"
  local T="${WORK}/tree"
  rm -rf "${T}"; cp -r "${REPO}/specs/cluster" "${T}"
  local before after out rc
  before="$(find "${T}" -type f -exec md5sum {} + | sort | md5sum)"
  ( T="${T}"; eval "${inject}" ) || { neg_bad "${label} (injection itself failed)"; return; }
  after="$(find "${T}" -type f -exec md5sum {} + | sort | md5sum)"
  if [ "${before}" = "${after}" ]; then
    neg_bad "${label} (INJECTION CHANGED NOTHING — the anchor has drifted; this control proves nothing)"; return
  fi
  out="$(python3 "${ANALYSER}" "${T}" 2>&1)"; rc=$?
  if [ "${rc}" -eq 0 ]; then
    neg_bad "${label} — the analyser stayed GREEN"; return
  fi
  if [ -n "${want}" ] && ! printf '%s\n' "${out}" | grep -aF -- "${want}" >/dev/null; then
    neg_bad "${label} — RED, but not for the planted reason (wanted ${want}); got: $(printf '%s\n' "${out}" | grep -a 'FAIL' | head -3 | tr '\n' ' ')"; return
  fi
  neg_ok "${label}"
}

UB='manifests/user-bff-api/deployment.yaml'
WB='manifests/wiki-bff-api/deployment.yaml'
GM='manifests/games/deployment.yaml'
NP='manifests/networkpolicy'
CH='charts/hugmesh-gateway'
PUB='https://id.hugmesh.net/.well-known/jwks'
INC='http://casdoor.hugmesh-pki.svc.cluster.local:8000/.well-known/jwks'

# (0) the staging itself: an untouched copy must be GREEN, or every red below is noise.
rm -rf "${WORK}/tree"; cp -r "${REPO}/specs/cluster" "${WORK}/tree"
if python3 "${ANALYSER}" "${WORK}/tree" >/dev/null 2>&1; then neg_ok "control: an untouched copy is green"; else neg_bad "control: an untouched copy is RED — the staging is broken"; fi

expect_red "(1) CASDOOR_JWKS_URI removed from user-bff" "no CASDOOR_JWKS_URI" '
  sed -i "/- name: CASDOOR_JWKS_URI/,+1d" "$T/'"${UB}"'"'
expect_red "(2) user-bff keys pointed at the PUBLIC issuer host" "not an in-cluster URL" '
  sed -i "s#'"${INC}"'#'"${PUB}"'#" "$T/'"${UB}"'"'
expect_red "(3) wiki-bff keys pointed at a namespace that never existed" "no Service casdoor in namespace hugmesh-casdoor" '
  sed -i "s#casdoor.hugmesh-pki.svc#casdoor.hugmesh-casdoor.svc#" "$T/'"${WB}"'"'
expect_red "(4) CASDOOR_JWKS_URI supplied via valueFrom" "no literal value" '
  python3 - "$T/'"${UB}"'" <<EOF
import sys; p=sys.argv[1]; t=open(p).read()
old="""- name: CASDOOR_JWKS_URI
              value: "'"${INC}"'\""""
new="""- name: CASDOOR_JWKS_URI
              valueFrom: { secretKeyRef: { name: planted, key: jwks } }"""
assert old in t, "anchor missing"; open(p,"w").write(t.replace(old,new,1))
EOF'
expect_red "(5) casdoor-jwks-ingress.yaml dropped from the kustomization" "hugmesh-owncast" '
  sed -i "/casdoor-jwks-ingress.yaml/d" "$T/'"${NP}"'/kustomization.yaml"'
expect_red "(6) hugmesh-backend removed from the pki tier from-set" "hugmesh-user-bff-api" '
  sed -i "/headscale-forward -> pki-gateway/d" "$T/'"${NP}"'/tier-ingress.yaml"'
expect_red "(7) owncast admit rule on the wrong port" "hugmesh-owncast" '
  python3 - "$T/'"${NP}"'/casdoor-jwks-ingress.yaml" <<EOF
import sys; p=sys.argv[1]; t=open(p).read()
i=t.index("name: owncast-bff-to-casdoor-jwks"); j=t.index("port: 8000", i)
open(p,"w").write(t[:j]+"port: 8080"+t[j+len("port: 8000"):])
EOF'
expect_red "(8) owncast admit rule selecting the wrong pod label" "hugmesh-owncast" '
  sed -i "s#matchLabels: { app: hugmesh-owncast }#matchLabels: { app: hugmesh-owncast-planted }#" "$T/'"${NP}"'/casdoor-jwks-ingress.yaml"'
expect_red "(9) fe-gateway admit document deleted" "hugmesh-fe-gateway" '
  python3 - "$T/'"${NP}"'/casdoor-jwks-ingress.yaml" <<EOF
import sys; p=sys.argv[1]; docs=open(p).read().split("\n---\n")
keep=[d for d in docs if "name: fe-gateway-to-casdoor-jwks" not in d]
assert len(keep)==len(docs)-1; open(p,"w").write("\n---\n".join(keep))
EOF'
expect_red "(10) a default-deny EGRESS policy on user-bff with no casdoor allow" "egress: NOT admitted" '
  cat > "$T/'"${NP}"'/planted-egress.yaml" <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: planted-egress, namespace: hugmesh-backend }
spec:
  podSelector: { matchLabels: { app: hugmesh-user-bff-api } }
  policyTypes: [Egress]
  egress:
    - to: [ { namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: kube-system } } } ]
EOF
  sed -i "s#^  - tier-ingress.yaml#  - planted-egress.yaml\n  - tier-ingress.yaml#" "$T/'"${NP}"'/kustomization.yaml"'
expect_red "(11) games gains CASDOOR_JWKS_URI while still exempt" "gap the entry describes is closed" '
  sed -i "s#- { name: CASDOOR_ISSUER_URI, value: \"https://id.hugmesh.games\" }#&\n            - { name: CASDOOR_JWKS_URI, value: \"http://casdoor-games.hugmesh-games.svc.cluster.local:8000/.well-known/jwks\" }#" "$T/'"${GM}"'"'
expect_red "(12) games stops setting CASDOOR_ISSUER_URI (exemption orphaned)" "nothing references it" '
  sed -i "/name: CASDOOR_ISSUER_URI, value: \"https:\/\/id.hugmesh.games\"/d" "$T/'"${GM}"'"'
expect_red "(13) games CASDOOR_ENDPOINT moved to the public host (exemption reason false)" "not an in-cluster URL" '
  sed -i "s#http://casdoor-games.hugmesh-games.svc.cluster.local:8000#https://id.hugmesh.games#" "$T/'"${GM}"'"'
expect_red "(11a) games-bff JWKS admit rule dropped from the auto-sync netpol" "APP_TENANCY_JWKS_URIS[https://id.hugmesh.net]" '
  python3 - "$T/'"${NP}"'/casdoor-jwks-ingress.yaml" <<EOF
import sys; p=sys.argv[1]; t=open(p).read()
i=t.index("# Games BFF -> systems Casdoor :8000")
open(p,"w").write(t[:i].rstrip()[:-3].rstrip()+"\n")
EOF'
expect_red "(11b) games JWKS map loses the systems issuer" "a trusted issuer without a JWKS entry" '
  sed -i "s#,https://id.hugmesh.net=http://casdoor.hugmesh-pki.svc.cluster.local:8000/.well-known/jwks##" "$T/'"${GM}"'"'
expect_red "(11c) systems issuer keys pointed at the games Casdoor" "validates tokens signed by casdoor.hugmesh-pki" '
  sed -i "s#https://id.hugmesh.net=http://casdoor.hugmesh-pki#https://id.hugmesh.net=http://casdoor-games.hugmesh-games#" "$T/'"${GM}"'"'
expect_red "(11d) the realms stamped with two domains" "map every issuer to ONE domain" '
  sed -i "s#https://id.hugmesh.net=default#https://id.hugmesh.net=mesh#" "$T/'"${GM}"'"'
expect_red "(14) chart values jwksUri pointed at the public host" "chart hugmesh-gateway" '
  sed -i "s#jwksUri: '"${INC}"'#jwksUri: '"${PUB}"'#" "$T/'"${CH}"'/values.yaml"'
expect_red "(15) chart template loses its CASDOOR_JWKS_URI env" "no CASDOOR_JWKS_URI env" '
  sed -i "/- name: CASDOOR_JWKS_URI/,+1d" "$T/'"${CH}"'/templates/deployment.yaml"'
expect_red "(16) an Application overrides casdoor.jwksUri with the public host" "hugmesh-fe-gateway" '
  python3 - "$T/apps/20-gateway-fe.yaml" <<EOF
import sys; p=sys.argv[1]; t=open(p).read()
old="      releaseName: hugmesh-fe-gateway\n"
assert old in t, "anchor missing"
open(p,"w").write(t.replace(old, old+"      parameters:\n        - { name: casdoor.jwksUri, value: '"${PUB}"' }\n",1))
EOF'
expect_red "(17) every CASDOOR_ISSUER_URI removed (vacuous census)" "census found only" '
  python3 - "$T" <<EOF
import sys, os, re, glob
root=sys.argv[1]; n=0
for p in glob.glob(os.path.join(root,"manifests","*","*.yaml"))+glob.glob(os.path.join(root,"charts","*","templates","*.yaml")):
    t=open(p).read()
    t2=re.sub(r"\n[^\n]*- \{ name: CASDOOR_ISSUER_URI,[^\n]*", "", t)
    t2=re.sub(r"\n[^\n]*- name: CASDOOR_ISSUER_URI\n[^\n]*value:[^\n]*", "", t2)
    if t2!=t: open(p,"w").write(t2); n+=1
assert n>=8, n
EOF'

expect_red "(18) user-bff keys pointed at the GAMES realm's Casdoor (exists, answers 200, wrong keys)" "validates tokens signed by casdoor.hugmesh-pki" '
  sed -i "s#'"${INC}"'#http://casdoor-games.hugmesh-games.svc.cluster.local:8000/.well-known/jwks#" "$T/'"${UB}"'"'
expect_red "(19) user-bff lists CASDOOR_JWKS_URI twice, the last one public" "listed more than once" '
  python3 - "$T/'"${UB}"'" <<EOF
import sys; p=sys.argv[1]; t=open(p).read()
old="""- name: CASDOOR_JWKS_URI
              value: "'"${INC}"'\""""
new=old+"""
            - name: CASDOOR_JWKS_URI
              value: "'"${PUB}"'\""""
assert old in t, "anchor missing"; open(p,"w").write(t.replace(old,new,1))
EOF'
expect_red "(20) a CronJob that sets CASDOOR_ISSUER_URI (a kind the gate does not walk)" "a kind this gate does not walk" '
  cat > "$T/manifests/user-bff-api/planted-cronjob.yaml" <<EOF
apiVersion: batch/v1
kind: CronJob
metadata: { name: planted, namespace: hugmesh-backend }
spec:
  schedule: "0 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: Never
          containers:
            - name: planted
              image: planted:1
              env:
                - { name: CASDOOR_ISSUER_URI, value: "https://id.hugmesh.net" }
EOF'
expect_red "(21) a brand-new StatefulSet sets CASDOOR_ISSUER_URI and no CASDOOR_JWKS_URI" "planted-sts" '
  mkdir -p "$T/manifests/planted-sts"
  cat > "$T/manifests/planted-sts/statefulset.yaml" <<EOF
apiVersion: apps/v1
kind: StatefulSet
metadata: { name: planted-sts, namespace: hugmesh-backend }
spec:
  selector: { matchLabels: { app: planted-sts } }
  template:
    metadata: { labels: { app: planted-sts } }
    spec:
      containers:
        - name: planted-sts
          image: planted:1
          env:
            - { name: CASDOOR_ISSUER_URI, value: "https://id.hugmesh.net" }
EOF'
expect_red "(22) games CASDOOR_ENDPOINT repointed at the systems Casdoor (exemption reason false)" "validates tokens signed by casdoor-games.hugmesh-games" '
  sed -i "s#http://casdoor-games.hugmesh-games.svc.cluster.local:8000#http://casdoor.hugmesh-pki.svc.cluster.local:8000#" "$T/'"${GM}"'"'
expect_red "(23) an Application overrides casdoor.jwksUri with the games Casdoor" "validates tokens signed by casdoor.hugmesh-pki" '
  python3 - "$T/apps/20-gateway-fe.yaml" <<EOF
import sys; p=sys.argv[1]; t=open(p).read()
old="      releaseName: hugmesh-fe-gateway\n"
assert old in t, "anchor missing"
open(p,"w").write(t.replace(old, old+"      parameters:\n        - { name: casdoor.jwksUri, value: http://casdoor-games.hugmesh-games.svc.cluster.local:8000/.well-known/jwks }\n",1))
EOF'
expect_red "(24) user-bff keys over https against Casdoor's plain-http port" "speaks http, the URL says https" '
  sed -i "s#http://casdoor.hugmesh-pki.svc.cluster.local:8000#https://casdoor.hugmesh-pki.svc.cluster.local:8000#" "$T/'"${UB}"'"'

echo
echo "== negative controls: ${NEG_P} passed, ${NEG_F} failed =="
[ "${NEG_F}" -eq 0 ] || exit 1
echo "== bff-jwks-in-cluster: PASS =="
exit 0
