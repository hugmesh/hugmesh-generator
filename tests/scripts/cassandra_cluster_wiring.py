#!/usr/bin/env python3
"""cassandra_cluster_wiring.py — static contract gate for every Cassandra
consumer in the GitOps cluster payload.

Usage: cassandra_cluster_wiring.py <repo-root>

WHAT IT ASSERTS, and why each line of it was earned on a real cluster
(docs/KIND-SSO-E2E-FINDINGS.md #5/#6):

  [creds]        every workload that dials Cassandra is emitted WITH a username
                 and a password, the password from a secretKeyRef and never a
                 literal.  The whole payload shipped with zero credentials while
                 the server ran PasswordAuthenticator, so every gateway
                 CrashLoopBackOff'd at bean creation.
  [creds-secret] that Secret+key is actually produced by an ExternalSecret IN THE
                 WORKLOAD'S OWN NAMESPACE.  A Secret that exists only in
                 hugmesh-pki is not mountable from hugmesh-frontend.
  [seed]         every Vault property those ExternalSecrets reference is minted by
                 scripts/gen-cluster-secrets.sh on BOTH delivery paths (the online
                 `vault kv put` and the offline USB secrets.json).  ESO fails a
                 WHOLE Secret when one property is missing, so a half-seeded
                 document takes the custody key down with it.
  [keyspace]     every keyspace any consumer names is CREATEd by a bootstrap that
                 the cluster actually runs.  Spring's schema-action creates
                 TABLES, never keyspaces; nothing cluster-side created them, and
                 the gateways died on `Invalid keyspace snapdragon_gateway`.
  [role]         every role a consumer authenticates as is CREATEd by that
                 bootstrap and holds EXACTLY the permissions its declared access
                 class calls for on EXACTLY the keyspace it dials — set equality,
                 per role, per keyspace. Not "some grant names the keyspace": the
                 defect this branch fixes was a grant matrix that named every
                 keyspace and was BACKWARDS (the four gateways, which carry the
                 CQL migration runner, declared SELECT-only readers; admin-bff,
                 which issues no DDL, the writer). A presence check scores that
                 green. The class is declared next to the credential it governs —
                 `cassandra.access` in the gateway Applications, the
                 snapdragon.systems/cassandra-access pod annotation elsewhere —
                 and the bootstrap's GRANTs are checked against it, so landing
                 either half alone fails. Roles are never shared between
                 consumers, never SUPERUSER, never granted on a keyspace they do
                 not use, and never granted to nobody.
  [role]         …and the grant GRAMMAR is an allowlist: only
                 `GRANT <perm> ON KEYSPACE <ks> TO <role>` (and its REVOKE) is
                 scoreable. ALL PERMISSIONS, ON ALL KEYSPACES, table/function/
                 mbean resources and role-to-role inheritance are rejected
                 outright — each of them widens a role past anything a permission
                 matrix can express, and the old parser simply could not see them,
                 so a superuser-equivalent grant sitting beside the correct ones
                 was invisible.
  [order]        every CREATE KEYSPACE precedes every GRANT in the bootstrap
                 script.  A GRANT names a keyspace and fails if it is absent.
  [bootstrap]    the bootstrap is wired into the AUTO-SYNCED Argo tree, its
                 overlay really includes both objects, and it is admitted by the
                 Cassandra NetworkPolicy — that policy is default-deny-except, so
                 an unlisted bootstrap pod cannot reach the database it seeds.
  [local-dc]     every consumer's local-datacenter equals the name the server
                 really advertises.  With the chart-default SimpleSnitch that is
                 always `datacenter1` regardless of `cluster.datacenter`, and a
                 mismatch is NoNodeAvailableException on every dial.
  [chart]        the gateway chart template renders the credentials from its
                 values, and refuses to render a half-wired instance.
  [brand]        a templates/apps/*.hbs gateway may omit Cassandra values (brand
                 meshes have no Cassandra payload of their own — see the gate's
                 README note), but it may not declare HALF of them.

No cluster, no kubectl, no network.  PyYAML + stdlib only.
"""
from __future__ import annotations

import os
import re
import sys
import yaml

FAILURES: list[str] = []
NOTES: list[str] = []


def fail(check: str, msg: str) -> None:
    FAILURES.append(f"  FAIL {check} {msg}")


def note(msg: str) -> None:
    NOTES.append(f"  note {msg}")


# ── loading ──────────────────────────────────────────────────────────────────
def load_all(path: str):
    """Every YAML document in a file, or [] with a recorded failure."""
    try:
        with open(path, encoding="utf-8") as fh:
            return [d for d in yaml.safe_load_all(fh) if isinstance(d, dict)]
    except Exception as exc:  # noqa: BLE001 - the message is the value here
        fail("[yaml-parse]", f"{path}: {exc}")
        return []


def walk_yaml(root: str):
    for dirpath, _dirs, files in os.walk(root):
        for name in sorted(files):
            if name.endswith((".yaml", ".yml")):
                yield os.path.join(dirpath, name)


def deep_merge(base, over):
    if isinstance(base, dict) and isinstance(over, dict):
        out = dict(base)
        for k, v in over.items():
            out[k] = deep_merge(base.get(k), v) if k in base else v
        return out
    return over


# ── what counts as "dialing Cassandra" ───────────────────────────────────────
# Behavioural, not name-based: a value that IS a cassandra host (optionally with a
# port). Renaming the env var does not let a consumer slip past this gate.
CONTACT_VALUE = re.compile(r"^cassandra[a-z0-9.\-]*(:\d+)?$")


def is_contact_point(value) -> bool:
    return isinstance(value, str) and bool(CONTACT_VALUE.match(value.strip()))


class Consumer:
    """A workload that opens a CQL session, however it is spelled."""

    def __init__(self, kind, name, namespace, where, envs):
        self.kind = kind
        self.name = name
        self.namespace = namespace
        self.where = where
        self.envs = envs  # {NAME: {"value": str} | {"secret": (name, key)}}
        self.access = None  # declared CQL permission class; see ACCESS_ANNOTATION
        self.keyspace = None
        self.local_dc = None

    def __str__(self):
        return f"{self.kind} {self.namespace}/{self.name} ({self.where})"

    def env_ending(self, suffix):
        return {n: v for n, v in self.envs.items() if n.endswith(suffix)}


def container_envs(container) -> dict:
    out = {}
    for e in container.get("env") or []:
        if not isinstance(e, dict) or "name" not in e:
            continue
        vf = e.get("valueFrom") or {}
        skr = vf.get("secretKeyRef") if isinstance(vf, dict) else None
        if isinstance(skr, dict):
            out[e["name"]] = {"secret": (skr.get("name"), skr.get("key"))}
        else:
            out[e["name"]] = {"value": e.get("value")}
    return out


WORKLOAD_KINDS = {"Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob"}

# The CQL permission class a workload claims for its role. Declared on the POD
# (so it is readable on the live object next to the role it is claimed for), and
# the thing manifests/cassandra-init's GRANTs are checked against.
ACCESS_ANNOTATION = "snapdragon.systems/cassandra-access"


def pod_template(doc):
    if doc.get("kind") == "CronJob":
        return (((doc.get("spec") or {}).get("jobTemplate") or {}).get("spec") or {}).get("template") or {}
    return ((doc.get("spec") or {}).get("template") or {}) or {}


def pod_spec(doc):
    return pod_template(doc).get("spec") or {}


def declared_access(doc):
    """The access class, from the pod template, else the object itself."""
    for meta in (pod_template(doc).get("metadata") or {}, doc.get("metadata") or {}):
        ann = (meta.get("annotations") or {}).get(ACCESS_ANNOTATION)
        if ann:
            return str(ann).strip()
    return None


# ── 1. collect consumers from plain manifests ────────────────────────────────
def collect_manifest_consumers(cluster_root):
    consumers, bootstraps = [], []
    for path in walk_yaml(os.path.join(cluster_root, "manifests")):
        for doc in load_all(path):
            if doc.get("kind") not in WORKLOAD_KINDS:
                continue
            meta = doc.get("metadata") or {}
            spec = pod_spec(doc)
            for c in (spec.get("containers") or []) + (spec.get("initContainers") or []):
                envs = container_envs(c)
                if not any(is_contact_point(v.get("value")) for v in envs.values()):
                    continue
                obj = Consumer(doc["kind"], meta.get("name"), meta.get("namespace"),
                               os.path.relpath(path, cluster_root), envs)
                obj.access = declared_access(doc)
                # The bootstrap is not an application consumer: it authenticates
                # as the superuser to CREATE what the applications then use.
                if any(n.endswith("ADMIN_USER") for n in envs):
                    bootstraps.append((obj, doc, path))
                else:
                    consumers.append(obj)
    return consumers, bootstraps


# ── 2. collect gateway consumers from Argo Applications + the chart ──────────
GATEWAY_CHART = "specs/cluster/charts/hugmesh-gateway"


def canon_path(p):
    return os.path.normpath((p or "").strip().strip("/")) if p else ""


def helm_values(app, where):
    src = (app.get("spec") or {}).get("source") or {}
    helm = src.get("helm") or {}
    for unreadable in ("valueFiles", "fileParameters"):
        if helm.get(unreadable):
            fail("[chart]", f"{where}: helm.{unreadable} is not readable by this gate — "
                            "its Cassandra wiring cannot be checked, so it fails rather than passing quietly")
    vals = {}
    if isinstance(helm.get("values"), str):
        try:
            vals = deep_merge(vals, yaml.safe_load(helm["values"]) or {})
        except Exception as exc:  # noqa: BLE001
            fail("[chart]", f"{where}: helm.values is not parseable YAML: {exc}")
    if isinstance(helm.get("valuesObject"), dict):
        vals = deep_merge(vals, helm["valuesObject"])
    for p in helm.get("parameters") or []:
        if isinstance(p, dict) and p.get("name", "").startswith("cassandra."):
            leaf = p["name"].split(".", 1)[1]
            vals = deep_merge(vals, {"cassandra": {leaf: p.get("value")}})
    return vals


def collect_gateway_consumers(repo, cluster_root):
    chart_defaults = {}
    cv = os.path.join(repo, GATEWAY_CHART, "values.yaml")
    docs = load_all(cv)
    if docs:
        chart_defaults = docs[0]
    out = []
    for path in walk_yaml(os.path.join(cluster_root, "apps")):
        for app in load_all(path):
            if app.get("kind") != "Application":
                continue
            src = (app.get("spec") or {}).get("source") or {}
            if canon_path(src.get("path")) != GATEWAY_CHART:
                continue
            where = os.path.relpath(path, cluster_root)
            merged = deep_merge(chart_defaults, helm_values(app, where))
            cas = merged.get("cassandra") or {}
            ns = ((app.get("spec") or {}).get("destination") or {}).get("namespace")
            envs = {}
            if cas.get("contactPoints"):
                envs["CASSANDRA_CONTACT_POINTS"] = {"value": cas["contactPoints"]}
            if cas.get("username"):
                envs["SPRING_CASSANDRA_USERNAME"] = {"value": cas["username"]}
            if cas.get("passwordSecret") and cas.get("passwordSecretKey"):
                envs["SPRING_CASSANDRA_PASSWORD"] = {
                    "secret": (cas["passwordSecret"], cas["passwordSecretKey"])}
            elif cas.get("passwordSecret") or cas.get("passwordSecretKey"):
                fail("[creds]", f"{where}: cassandra.passwordSecret/passwordSecretKey are half set "
                                f"({cas.get('passwordSecret')!r}/{cas.get('passwordSecretKey')!r}) — "
                                "a username without a resolvable password fails auth at bean creation")
            c = Consumer("Application(gateway)", (app.get("metadata") or {}).get("name"), ns, where, envs)
            c.keyspace = cas.get("keyspace")
            c.local_dc = cas.get("localDc")
            c.access = (str(cas["access"]).strip() if cas.get("access") else None)
            out.append(c)
    return out


# ── 3. the credential contract ───────────────────────────────────────────────
def check_credentials(consumers):
    roles = {}  # consumer -> role name
    for c in consumers:
        users = c.env_ending("CASSANDRA_USERNAME")
        pwds = c.env_ending("CASSANDRA_PASSWORD")
        if not users:
            fail("[creds]", f"{c} dials Cassandra but sets no *CASSANDRA_USERNAME. "
                            "The server runs PasswordAuthenticator by image default; this pod "
                            "cannot open a session at all.")
            continue
        if not pwds:
            fail("[creds]", f"{c} sets a username but no *CASSANDRA_PASSWORD.")
            continue
        for n, v in users.items():
            if not (v.get("value") or "").strip():
                fail("[creds]", f"{c}: {n} is empty.")
        for n, v in pwds.items():
            if "secret" not in v:
                fail("[creds]", f"{c}: {n} is a literal value, not a secretKeyRef — "
                                "Cassandra passwords are never committed.")
        # An app that gates its CQL auth behind a flag must have the flag ON, or
        # the credentials above are decoration.
        for n, v in c.env_ending("CASSANDRA_AUTH_ENABLED").items():
            if str(v.get("value")).lower() != "true":
                fail("[creds]", f"{c}: {n}={v.get('value')!r} — credentials are wired but "
                                "the driver will not send them.")
        role = next(iter(users.values())).get("value", "").strip()
        roles[c] = role
    return roles


def collect_external_secrets(cluster_root):
    """(namespace, secretName) -> {key: (vault-doc, property)}"""
    out = {}
    for path in walk_yaml(os.path.join(cluster_root, "manifests")):
        for doc in load_all(path):
            if doc.get("kind") != "ExternalSecret":
                continue
            meta = doc.get("metadata") or {}
            spec = doc.get("spec") or {}
            target = (spec.get("target") or {}).get("name") or meta.get("name")
            keys = {}
            for d in spec.get("data") or []:
                rr = d.get("remoteRef") or {}
                keys[d.get("secretKey")] = (rr.get("key"), rr.get("property"))
            out[(meta.get("namespace"), target)] = keys
    return out


def check_credential_secrets(consumers, ext):
    wanted = {}
    for c in consumers:
        for n, v in c.env_ending("CASSANDRA_PASSWORD").items():
            if "secret" not in v:
                continue
            sname, skey = v["secret"]
            keys = ext.get((c.namespace, sname))
            if keys is None:
                fail("[creds-secret]", f"{c}: {n} mounts Secret {sname!r} in namespace "
                                       f"{c.namespace!r}, which no ExternalSecret materializes there.")
                continue
            if skey not in keys:
                fail("[creds-secret]", f"{c}: {n} wants key {skey!r} of {sname!r} in {c.namespace!r}; "
                                       f"that ExternalSecret only supplies {sorted(keys)}.")
                continue
            wanted[(c.namespace, sname, skey)] = keys[skey]
    return wanted


# ── 4. both seeding paths ────────────────────────────────────────────────────
def seeded_properties(repo):
    """What scripts/gen-cluster-secrets.sh actually mints, per delivery path."""
    path = os.path.join(repo, "scripts", "gen-cluster-secrets.sh")
    try:
        text = open(path, encoding="utf-8").read()
    except OSError as exc:
        fail("[seed]", f"cannot read {path}: {exc}")
        return {}, {}

    # online: vault kv put "${VAULT_KV_MOUNT}/${BASE}/<doc>" \ prop="..." \ ...
    vault = {}
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        m = re.search(r'vault kv put "\$\{VAULT_KV_MOUNT\}/\$\{BASE\}/([A-Za-z0-9._-]+)"', lines[i])
        if m:
            doc, props = m.group(1), set()
            j = i
            while lines[j].rstrip().endswith("\\"):
                j += 1
                pm = re.match(r'\s*([A-Za-z0-9._-]+)=', lines[j])
                if pm:
                    props.add(pm.group(1))
            vault.setdefault(doc, set()).update(props)
            i = j
        i += 1

    # offline USB bundle: the python heredoc's {ns: {secretName: {key: ...}}}
    usb = {}
    ns_re = re.compile(r'f"\{brand\}-([a-z0-9-]+)": \{')
    sec_re = re.compile(r'"([A-Za-z0-9._-]+)": \{')
    key_re = re.compile(r'"([A-Za-z0-9._-]+)":\s')
    ns = None
    for line in lines:
        nm = ns_re.search(line)
        if nm:
            ns, sec = nm.group(1), None
            continue
        indent = len(line) - len(line.lstrip())
        sm = sec_re.search(line)
        if ns and sm and indent == 8:
            sec = sm.group(1)
            continue
        km = key_re.search(line)
        if ns and km and indent == 12:
            usb.setdefault((ns, sec), set()).add(km.group(1))
    return vault, usb


def check_seeding(wanted, ext, vault, usb):
    # every property the consumers' ExternalSecrets pull must exist in Vault …
    for (ns, sname, skey), (vdoc, vprop) in sorted(wanted.items()):
        doc = (vdoc or "").split("/")[-1]
        if doc not in vault:
            fail("[seed]", f"ExternalSecret {ns}/{sname} key {skey!r} reads Vault document "
                           f"{vdoc!r}, which gen-cluster-secrets.sh never writes.")
        elif vprop not in vault[doc]:
            fail("[seed]", f"ExternalSecret {ns}/{sname} key {skey!r} reads property {vprop!r} of "
                           f"{vdoc!r}; gen-cluster-secrets.sh seeds only {sorted(vault[doc])}. "
                           "ESO fails the WHOLE Secret on one missing property.")
        # … and in the offline USB bundle, which is a co-equal delivery path.
        short_ns = ns.split("-", 1)[1] if ns and "-" in ns else ns
        have = usb.get((short_ns, sname), set())
        if skey not in have:
            fail("[seed]", f"offline USB bundle has no {ns}/{sname} key {skey!r} "
                           f"(gen-cluster-secrets.sh secrets.json supplies {sorted(have)}). "
                           "A Vault-less provisioning run would come up credential-less.")


# ── 5. the bootstrap: keyspaces, roles, grants, ordering, reachability ───────
CREATE_KS = re.compile(r"CREATE\s+KEYSPACE\s+IF\s+NOT\s+EXISTS\s+([A-Za-z0-9_]+)", re.I)
CREATE_TBL = re.compile(r"CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?([A-Za-z0-9_]+)\.", re.I)
# `create_role <role> <PASSWORD_ENV_VAR>` — the helper the bootstrap uses.
CREATE_ROLE_CALL = re.compile(r"^\s*create_role\s+([A-Za-z0-9_]+)\s+([A-Za-z0-9_]+)\s*$", re.M)
# A role created by literal CQL rather than the helper. The (?!IF\b) stops the
# optional IF-NOT-EXISTS from being skipped so that "IF" itself is read as a name
# when the role is a shell expansion (`CREATE ROLE IF NOT EXISTS ${role}`).
LITERAL_CREATE_ROLE = re.compile(r"CREATE\s+ROLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(?!IF\b)([A-Za-z0-9_]+)", re.I)
ROLE_STMT = re.compile(r"\b(?:CREATE|ALTER)\s+ROLE\b[^;]*", re.I)
REQUIRE_CALL = re.compile(r"^\s*require\s+([A-Za-z0-9_]+)\s", re.M)

# ── the grant grammar, as an ALLOWLIST ───────────────────────────────────────
# Apache Cassandra CQL (developing/cql/security.html):
#   grant_permission_statement ::= GRANT permissions ON resource TO role_name
#   permissions ::= ALL [ PERMISSIONS ] | permission [ PERMISSION ]
#   permission  ::= CREATE | ALTER | DROP | SELECT | MODIFY | AUTHORIZE
#                 | DESCRIBE | EXECUTE | UNMASK | SELECT_MASKED
#   grant_role_statement ::= GRANT role_name TO role_name        (inheritance)
# and `resource` may be ALL KEYSPACES / KEYSPACE ks / TABLE t / ALL FUNCTIONS /
# FUNCTION f / ALL ROLES / ROLE r / ALL MBEANS / MBEAN m.
#
# This gate scores exactly ONE of those shapes — a single named permission on a
# single named KEYSPACE — and REFUSES the rest instead of ignoring them. That is
# the whole point: the previous parser matched `GRANT <WORD> ON KEYSPACE`, so
# `GRANT ALL PERMISSIONS ON ALL KEYSPACES TO admin_bff_cass` sitting next to the
# correct grants was not "rejected", it was INVISIBLE, and the role came out
# superuser-equivalent with the gate still green.
CQL_PERMISSIONS = {"CREATE", "ALTER", "DROP", "SELECT", "MODIFY", "AUTHORIZE",
                   "DESCRIBE", "EXECUTE", "UNMASK", "SELECT_MASKED"}
# …and of those, the ones a KEYSPACE resource actually accepts. Per the same
# table, DESCRIBE applies only to ALL ROLES / MBEANS and EXECUTE only to
# FUNCTIONS / MBEANS, so `GRANT DESCRIBE ON KEYSPACE …` is not a wide grant, it
# is a statement cqlsh rejects — which fails the Job, which fails the sync, which
# leaves the cluster with no keyspaces at all.
KEYSPACE_PERMISSIONS = CQL_PERMISSIONS - {"DESCRIBE", "EXECUTE"}
GRANT_KEYWORD = re.compile(r"\b(?:GRANT|REVOKE)\b", re.I)
KEYSPACE_PERM = re.compile(
    r"^(?P<verb>GRANT|REVOKE)\s+(?P<perm>[A-Za-z_]+)(?:\s+PERMISSIONS?)?\s+ON\s+KEYSPACE\s+"
    r"(?P<ks>[A-Za-z0-9_]+)\s+(?P<dir>TO|FROM)\s+(?P<role>[A-Za-z0-9_${}]+)\s*;?$", re.I)

# What each declared access class is allowed to hold — exactly, no more, no less.
# No class contains DROP or AUTHORIZE: no application role in this platform may
# drop a table or hand its own privileges to another role.
ACCESS_CLASSES = {
    # carries a CQL schema-migration runner (CREATE TABLE / ALTER TABLE ... ADD)
    "schema-owner": frozenset({"SELECT", "MODIFY", "CREATE", "ALTER"}),
    # reads and writes rows; depends on someone else's DDL
    "dml": frozenset({"SELECT", "MODIFY"}),
    "read-only": frozenset({"SELECT"}),
}


def strip_comments(script):
    return "\n".join(l for l in script.splitlines() if not l.lstrip().startswith("#"))


def unroll_loops(text):
    """`for r in a b c; do … ${r} … done` -> the three concrete iterations.

    A grant issued inside a shell loop is still a grant; leaving the loop folded
    made every role in the word list invisible to the matrix.
    """
    def rep(m):
        var, words, body = m.group(1), m.group(2).split(), m.group(3)
        if not all(w.isidentifier() for w in words):
            return m.group(0)  # not a literal word list — leave it to fail parsing
        pat = re.compile(r"\$\{%s\}|\$%s\b" % (re.escape(var), re.escape(var)))
        return "".join(pat.sub(w, body) for w in words)
    return re.sub(r"for\s+(\w+)\s+in\s+([^;]+);\s*do(.*?)done", rep, text, flags=re.S)


def parse_grant_statements(script):
    """Every GRANT/REVOKE in source order as (verb, perm, keyspace, role).

    Anything that is a GRANT/REVOKE but not the one scoreable shape is a FAILURE,
    never a silent skip.
    """
    text = unroll_loops(strip_comments(script))
    out = []
    for m in GRANT_KEYWORD.finditer(text):
        end = text.find(";", m.start())
        raw = text[m.start(): end + 1] if end != -1 else text[m.start():]
        raw = " ".join(raw.split())
        km = KEYSPACE_PERM.match(raw)
        if not km:
            fail("[role]", f"unscoreable grant statement in the bootstrap: {raw!r}. This gate "
                           "understands exactly `GRANT <PERMISSION> ON KEYSPACE <ks> TO <role>` "
                           "(and REVOKE … FROM …). ON ALL KEYSPACES, table/function/mbean/role "
                           "resources and role-to-role inheritance (`GRANT <role> TO <role>`) all "
                           "widen a role beyond anything a per-keyspace matrix can express, so they "
                           "fail here rather than being parsed away.")
            continue
        perm, verb = km.group("perm").upper(), km.group("verb").upper()
        if (verb == "GRANT") != (km.group("dir").upper() == "TO"):
            fail("[role]", f"malformed statement {raw!r}: GRANT takes TO, REVOKE takes FROM.")
            continue
        if perm == "ALL":
            fail("[role]", f"{raw!r} grants ALL PERMISSIONS. That is DROP and AUTHORIZE too — the "
                           "role could drop the gateway's tables and re-grant itself anywhere. "
                           "Name the permissions the workload actually needs.")
            continue
        if perm not in CQL_PERMISSIONS:
            fail("[role]", f"{raw!r} names {perm!r}, which is not a CQL permission "
                           f"({sorted(CQL_PERMISSIONS)}) — cqlsh would reject this statement and the "
                           "bootstrap Job would fail the sync.")
            continue
        if perm not in KEYSPACE_PERMISSIONS:
            fail("[role]", f"{raw!r} names {perm!r}, which CQL does not accept on a KEYSPACE "
                           "resource (it applies to roles/functions/mbeans). cqlsh rejects the "
                           "statement, the bootstrap Job fails, and the cluster comes up with no "
                           "keyspaces at all.")
            continue
        out.append((verb, perm, km.group("ks"), km.group("role").strip("${}")))
    return out


def effective_matrix(statements):
    """role -> {keyspace: {perms}} after replaying GRANTs and REVOKEs in order."""
    grants = {}
    for verb, perm, ks, role in statements:
        cell = grants.setdefault(role, {}).setdefault(ks, set())
        cell.add(perm) if verb == "GRANT" else cell.discard(perm)
    return {r: {k: v for k, v in m.items() if v} for r, m in grants.items() if any(m.values())}


def read_bootstrap(cluster_root):
    """The CQL script the cluster runs, plus the objects around it."""
    overlay = os.path.join(cluster_root, "manifests", "cassandra-init")
    if not os.path.isdir(overlay):
        fail("[bootstrap]", "specs/cluster/manifests/cassandra-init does not exist — "
                            "nothing cluster-side creates the keyspaces or the application roles.")
        return None, None, None
    script, job = None, None
    for path in walk_yaml(overlay):
        for doc in load_all(path):
            if doc.get("kind") == "ConfigMap":
                for v in (doc.get("data") or {}).values():
                    if "CREATE KEYSPACE" in v:
                        script = v
            if doc.get("kind") == "Job":
                job = doc
    if script is None:
        fail("[keyspace]", "manifests/cassandra-init has no ConfigMap containing CREATE KEYSPACE.")
    if job is None:
        fail("[bootstrap]", "manifests/cassandra-init has no Job to run the bootstrap.")
    kust = os.path.join(overlay, "kustomization.yaml")
    listed = set()
    if os.path.isfile(kust):
        docs = load_all(kust)
        if docs:
            listed = set(docs[0].get("resources") or [])
    for need in ("bootstrap-configmap.yaml", "bootstrap-job.yaml"):
        if need not in listed:
            fail("[bootstrap]", f"manifests/cassandra-init/kustomization.yaml does not list {need} — "
                                "ArgoCD would render an incomplete overlay.")
    return script, job, overlay


def bootstrap_capabilities(script):
    """(keyspaces created, {role: password-env-var}, {role: {keyspace: perms}})."""
    keyspaces = set(CREATE_KS.findall(script))
    roles = {r: pw for r, pw in CREATE_ROLE_CALL.findall(script)}
    for r in LITERAL_CREATE_ROLE.findall(strip_comments(script)):
        roles.setdefault(r, None)
    # Every role statement must pin the two properties that decide how much a
    # stolen application password is worth. The helper sets them; a hand-written
    # CREATE ROLE that forgets SUPERUSER=false creates a cluster superuser.
    for stmt in ROLE_STMT.findall(strip_comments(script)):
        flat = " ".join(stmt.split())
        if not re.search(r"SUPERUSER\s*=\s*false", flat, re.I):
            fail("[role]", f"role statement {flat!r} does not pin SUPERUSER = false. A CQL role "
                           "defaults to non-superuser only if nothing says otherwise — say it, so "
                           "that flipping it is a visible diff and not an omission.")
        if not re.search(r"LOGIN\s*=\s*true", flat, re.I):
            fail("[role]", f"role statement {flat!r} does not pin LOGIN = true; a role without "
                           "LOGIN cannot authenticate and every consumer using it fails at bean "
                           "creation.")
    return keyspaces, roles, effective_matrix(parse_grant_statements(script))


def check_ordering(script):
    """Everything a GRANT or a CREATE TABLE names must already exist."""
    text = strip_comments(script)
    first_grant = None
    last_ks = None
    ks_line = {}
    for i, line in enumerate(text.splitlines()):
        m = CREATE_KS.search(line)
        if m:
            last_ks = i
            ks_line.setdefault(m.group(1), i)
        if GRANT_KEYWORD.search(line) and first_grant is None:
            first_grant = i
    if first_grant is not None and last_ks is not None and last_ks > first_grant:
        fail("[order]", f"a CREATE KEYSPACE (line {last_ks + 1}) comes after the first GRANT "
                        f"(line {first_grant + 1}); a GRANT on a keyspace that does not exist yet fails.")
    if first_grant is not None and last_ks is None:
        fail("[order]", "the bootstrap GRANTs on keyspaces it never creates.")
    # A CREATE TABLE is qualified by a keyspace too, and fails the same way.
    for i, line in enumerate(text.splitlines()):
        m = CREATE_TBL.search(line)
        if not m:
            continue
        ks = m.group(1)
        if ks not in ks_line:
            fail("[order]", f"line {i + 1} creates a table in keyspace {ks!r}, which this bootstrap "
                            "never creates.")
        elif ks_line[ks] > i:
            fail("[order]", f"line {i + 1} creates a table in keyspace {ks!r} before line "
                            f"{ks_line[ks] + 1} creates that keyspace.")


def check_bootstrap_is_synced(cluster_root, overlay):
    want = "specs/cluster/manifests/cassandra-init"
    for path in walk_yaml(os.path.join(cluster_root, "apps")):
        for app in load_all(path):
            if app.get("kind") != "Application":
                continue
            src = (app.get("spec") or {}).get("source") or {}
            if canon_path(src.get("path")) != want:
                continue
            if not (((app.get("spec") or {}).get("syncPolicy") or {}).get("automated")):
                fail("[bootstrap]", f"{os.path.relpath(path, cluster_root)}: the cassandra-init "
                                    "Application has no syncPolicy.automated — the bootstrap would "
                                    "only ever run if a human remembered to sync it.")
            return
    fail("[bootstrap]", "no Application under specs/cluster/apps sources "
                        f"{want} — the bootstrap is not part of the cluster payload.")


def check_bootstrap_networkpolicy(cluster_root, job):
    if job is None:
        return
    labels = (((job.get("spec") or {}).get("template") or {}).get("metadata") or {}).get("labels") or {}
    ns = (job.get("metadata") or {}).get("namespace")
    for path in walk_yaml(os.path.join(cluster_root, "manifests", "networkpolicy")):
        for doc in load_all(path):
            if doc.get("kind") != "NetworkPolicy":
                continue
            spec = doc.get("spec") or {}
            sel = ((spec.get("podSelector") or {}).get("matchLabels") or {})
            if sel.get("app.kubernetes.io/name") != "cassandra":
                continue
            for rule in spec.get("ingress") or []:
                for frm in rule.get("from") or []:
                    if frm.get("namespaceSelector"):
                        continue  # cross-namespace peers, not this same-ns Job
                    want = ((frm.get("podSelector") or {}).get("matchLabels") or {})
                    if want and all(labels.get(k) == v for k, v in want.items()):
                        return
            fail("[bootstrap]", f"the cassandra-init Job (ns {ns}, labels {labels}) matches no `from` "
                                f"entry of {doc['metadata'].get('name')} — that policy is "
                                "default-deny-except, so the bootstrap cannot reach :9042.")
            return
    note("no db-ingress-cassandra NetworkPolicy found; bootstrap reachability unchecked")


# ── 6. server-advertised datacenter ──────────────────────────────────────────
def server_datacenter(cluster_root):
    path = os.path.join(cluster_root, "apps", "00-cassandra.yaml")
    for app in load_all(path):
        if app.get("kind") != "Application":
            continue
        vals = helm_values(app, "apps/00-cassandra.yaml")
        cluster = vals.get("cluster") or {}
        snitch = cluster.get("endpointSnitch", "SimpleSnitch")
        if str(snitch) == "SimpleSnitch":
            # SimpleSnitch never reads cassandra-rackdc.properties; it always
            # advertises datacenter1, so cluster.datacenter is cosmetic.
            if cluster.get("datacenter") not in (None, "datacenter1"):
                fail("[local-dc]", f"apps/00-cassandra.yaml sets cluster.datacenter="
                                   f"{cluster['datacenter']!r} under SimpleSnitch, which advertises "
                                   "'datacenter1' regardless — the manifest names the datacenter "
                                   "something no client can use.")
            return "datacenter1"
        return cluster.get("datacenter", "dc1")
    fail("[local-dc]", "apps/00-cassandra.yaml has no Application to read the datacenter from")
    return None


def check_local_dc(consumers, dc):
    if not dc:
        return
    for c in consumers:
        vals = [v.get("value") for n, v in c.envs.items()
                if n.endswith("LOCAL_DC") or n.endswith("LOCAL_DATACENTER")]
        if getattr(c, "local_dc", None):
            vals.append(c.local_dc)
        for v in vals:
            if v and v != dc:
                fail("[local-dc]", f"{c} uses local-datacenter {v!r}; the server advertises {dc!r}. "
                                   "The driver rejects every node and throws NoNodeAvailableException.")


# ── 7. keyspaces + roles line up with the bootstrap ──────────────────────────
def consumer_keyspace(c):
    if getattr(c, "keyspace", None):
        return c.keyspace
    for n, v in c.envs.items():
        if n.endswith("KEYSPACE") and isinstance(v.get("value"), str):
            return v["value"]
    return None


def check_keyspaces_and_roles(consumers, roles, keyspaces, made_roles, grants):
    """The permission MATRIX, not the presence of grants.

    Every finding below was scored green by a presence check, and every one of
    them is a live outage or a live privilege escalation:

      * declared schema-owner, granted SELECT+MODIFY  -> the gateway's migration
        runner dies on its first CREATE TABLE. This is the exact matrix the dark
        overlay shipped, and it "had a grant on the keyspace".
      * declared dml, granted CREATE+ALTER (or DROP)  -> a BFF that never issues
        DDL can drop or reshape the gateway's tables.
      * granted on the OTHER keyspace as well        -> federation's cache role
        reading the gateway's revocation list.
      * two consumers sharing one role               -> rotating one password
        locks the other out, and neither can be revoked independently.
      * a role nobody authenticates as               -> a live login credential
        with no owner and no rotation story.
    """
    owner = {}          # role -> first consumer seen using it
    for c in consumers:
        role = roles.get(c)
        if not role:
            continue
        if role in owner:
            fail("[role]", f"{c} and {owner[role]} both authenticate as role {role!r}. Each "
                           "consumer gets its OWN role: a shared role cannot be rotated, revoked "
                           "or audited for one workload without hitting the other.")
        else:
            owner[role] = c

    for c in consumers:
        ks = consumer_keyspace(c)
        if not ks:
            fail("[keyspace]", f"{c} dials Cassandra but names no keyspace, so which keyspace must "
                               "exist cannot be checked.")
            continue
        if ks not in keyspaces:
            fail("[keyspace]", f"{c} uses keyspace {ks!r}, which the cluster bootstrap never creates. "
                               "Spring's schema-action creates TABLES, never keyspaces.")
        role = roles.get(c)
        if not role:
            continue
        if role not in made_roles:
            fail("[role]", f"{c} authenticates as role {role!r}, which the cluster bootstrap "
                           "never creates.")
            continue

        got = dict(grants.get(role, {}))
        held = set(got.get(ks, set()))
        access = c.access
        if not access:
            fail("[role]", f"{c} authenticates as {role!r} but declares no CQL permission class "
                           f"({ACCESS_ANNOTATION} on the pod, or cassandra.access in the gateway "
                           "Application), so WHICH permissions that role must hold cannot be "
                           "checked — and a grant that merely names the keyspace proves nothing. "
                           "The defect this gate exists for was a grant matrix that named every "
                           "keyspace and was backwards.")
        elif access not in ACCESS_CLASSES:
            fail("[role]", f"{c} declares CQL permission class {access!r}; the known classes are "
                           f"{sorted(ACCESS_CLASSES)} (see the gateway chart values.yaml).")
        else:
            want = set(ACCESS_CLASSES[access])
            if held != want:
                missing = sorted(want - held)
                excess = sorted(held - want)
                why = []
                if missing:
                    why.append(f"MISSING {missing} — the workload's declared class needs them and "
                               "CassandraAuthorizer is deny-by-default, so it will authenticate and "
                               "then be refused mid-flight")
                if excess:
                    why.append(f"EXCESS {excess} — privilege its declared class does not ask for")
                fail("[role]", f"role {role!r} ({c}) is declared {access!r} = {sorted(want)} on "
                               f"{ks!r}, but the bootstrap leaves it holding "
                               f"{sorted(held) if held else 'nothing'}: " + "; ".join(why))
        for other, perms in sorted(got.items()):
            if other != ks and perms:
                fail("[role]", f"role {role!r} ({c}) is GRANTed {sorted(perms)} on keyspace "
                               f"{other!r}, which that consumer never dials (it uses {ks!r}). A role "
                               "reaches exactly one keyspace in this payload.")

    for role in sorted(set(grants) | set(made_roles)):
        if role in owner:
            continue
        held = grants.get(role, {})
        if held:
            fail("[role]", f"the bootstrap GRANTs {role!r} { {k: sorted(v) for k, v in held.items()} } "
                           "but no Cassandra consumer in the payload authenticates as it — an "
                           "unowned privileged login nobody rotates.")
        else:
            fail("[role]", f"the bootstrap creates login role {role!r} that no Cassandra consumer "
                           "authenticates as. A LOGIN role with a password and no owner is a "
                           "credential with no rotation story; drop it or wire its consumer.")


def check_role_password_coordinates(consumers, roles, made_roles, bootstrap, ext, script):
    """The password a consumer SENDS must be the one the bootstrap SET.

    A role and a password are two halves of one credential, and they are wired in
    two different files: the bootstrap Job hands `create_role <role> <PW_ENV>` a
    Secret key, and the consumer's own manifest mounts a Secret key of its own.
    Nothing before this made the two agree, so swapping two keys — the same shape
    of mistake as swapping two GRANT rows — produced six roles, six passwords, and
    an AuthenticationException per pod that no static check could see.

    Both sides are resolved all the way to the Vault document+property, because
    equal key NAMES in two namespaces are not evidence: the ExternalSecrets that
    materialize them could still be reading different properties.
    """
    if bootstrap is None:
        fail("[creds]", "no bootstrap workload was recognised, so no role's password could be "
                        "traced to the Secret its consumer sends.")
        return

    def resolve(ns, sname, skey):
        keys = ext.get((ns, sname))
        return None if keys is None else keys.get(skey)

    # 1. every password the script insists on must actually be handed to the Job.
    required_vars = set(REQUIRE_CALL.findall(strip_comments(script)))
    for var in sorted(required_vars):
        if var not in bootstrap.envs:
            fail("[creds]", f"the bootstrap script requires {var} but {bootstrap} never sets it — "
                            "the Job exits 1 and no keyspace, role or grant is ever created.")

    # 2. …and every role's password must be one of those (an unrequired password
    #    can be empty, and an empty password creates a role nobody can use).
    for role, pw_var in sorted((r, p) for r, p in made_roles.items() if p):
        if pw_var not in required_vars:
            fail("[creds]", f"role {role!r} takes its password from {pw_var}, which the bootstrap "
                            "never `require`s — an unset value would create the role with an empty "
                            "password rather than failing.")
        env = bootstrap.envs.get(pw_var)
        if env is None:
            fail("[creds]", f"role {role!r} takes its password from {pw_var}, which {bootstrap} "
                            "never sets.")
        elif "secret" not in env:
            fail("[creds]", f"role {role!r}'s password ({pw_var}) is a literal in {bootstrap}, not a "
                            "secretKeyRef.")

    # 3. the two halves must resolve to the SAME Vault property.
    for c in consumers:
        role = roles.get(c)
        pw_var = made_roles.get(role) if role else None
        if not pw_var:
            continue
        b_env = bootstrap.envs.get(pw_var) or {}
        if "secret" not in b_env:
            continue
        b_coord = resolve(bootstrap.namespace, *b_env["secret"])
        for n, v in c.env_ending("CASSANDRA_PASSWORD").items():
            if "secret" not in v:
                continue
            c_coord = resolve(c.namespace, *v["secret"])
            if b_coord is None or c_coord is None:
                continue  # already reported by [creds-secret]
            if b_coord != c_coord:
                fail("[creds-secret]",
                     f"{c} authenticates as {role!r} and sends {n} from "
                     f"{c.namespace}/{v['secret'][0]}[{v['secret'][1]}] = Vault {c_coord}, but the "
                     f"bootstrap SET that role's password from "
                     f"{bootstrap.namespace}/{b_env['secret'][0]}[{b_env['secret'][1]}] = Vault "
                     f"{b_coord}. Two different secrets for one credential: the role exists, the "
                     "password is right for a different role, and every dial is an "
                     "AuthenticationException.")


# ── 8. the chart template really renders what the values promise ────────────
def check_chart_template(repo):
    path = os.path.join(repo, GATEWAY_CHART, "templates", "deployment.yaml")
    try:
        text = open(path, encoding="utf-8").read()
    except OSError as exc:
        fail("[chart]", f"cannot read {path}: {exc}")
        return
    for needed in ("SPRING_CASSANDRA_USERNAME", "SPRING_CASSANDRA_PASSWORD"):
        if needed not in text:
            fail("[chart]", f"{GATEWAY_CHART}/templates/deployment.yaml never emits {needed}; the "
                            "gateway image declares no username/password under spring.cassandra, so "
                            "this relaxed-binding env is the only way credentials reach the driver.")
    if ".Values.cassandra.passwordSecretKey" not in text:
        fail("[chart]", "the chart hardcodes or omits the password Secret key instead of reading "
                        ".Values.cassandra.passwordSecretKey — per-instance roles cannot differ.")
    if "required" not in text.split("SPRING_CASSANDRA_PASSWORD", 1)[-1][:600]:
        fail("[chart]", "a gateway with cassandra.username set but no Secret coordinate still renders. "
                        "Half-wiring must be a template error, not a running pod that fails auth.")
    # The declared permission class must reach the LIVE object, and an unknown or
    # absent class must be a render error rather than an unaudited role.
    if ACCESS_ANNOTATION not in text or ".Values.cassandra.access" not in text:
        fail("[chart]", f"the chart never renders {ACCESS_ANNOTATION} from .Values.cassandra.access. "
                        "The permission class a role is granted against then exists only in git, "
                        "where nothing on the cluster can be audited against it.")
    elif "fail" not in text.split(ACCESS_ANNOTATION, 1)[0][-800:]:
        fail("[chart]", "a gateway with cassandra.username set but no valid cassandra.access class "
                        "still renders. An unclassified role cannot be checked against the "
                        "bootstrap's GRANTs, so it must be a template error.")


# ── 9. brand templates may abstain, but not half-declare ─────────────────────
def check_brand_templates(repo):
    tdir = os.path.join(repo, "templates", "apps")
    if not os.path.isdir(tdir):
        return
    for name in sorted(os.listdir(tdir)):
        if not (name.endswith(".hbs") and "gateway" in name):
            continue
        text = open(os.path.join(tdir, name), encoding="utf-8").read()
        if "cassandra:" not in text:
            note(f"templates/apps/{name} declares no Cassandra values — brand meshes ship no "
                 "Cassandra payload of their own; see the gate header")
            continue
        parts = {"username:": "username:" in text,
                 "passwordSecretKey:": "passwordSecretKey:" in text,
                 "access:": "access:" in text}
        if len(set(parts.values())) != 1:
            fail("[brand]", f"templates/apps/{name} declares part of a Cassandra credential and not "
                            f"the rest ({parts}). A brand gateway either brings a complete role — "
                            "username, Secret coordinate AND the permission class its grants are "
                            "checked against — or none of it; anything between renders a pod that "
                            "fails auth, or a role nobody can audit.")


# ── main ─────────────────────────────────────────────────────────────────────
def main(argv):
    if len(argv) != 2:
        print(__doc__)
        return 2
    repo = os.path.abspath(argv[1])
    cluster_root = os.path.join(repo, "specs", "cluster")
    if not os.path.isdir(cluster_root):
        print(f"  FAIL [input] no specs/cluster under {repo}")
        return 1

    manifest_consumers, bootstraps = collect_manifest_consumers(cluster_root)
    gateway_consumers = collect_gateway_consumers(repo, cluster_root)
    consumers = manifest_consumers + gateway_consumers
    # Refuse to score a PASS off an EMPTY reading. Both halves of the scan have a
    # known non-zero population (the gateway Applications that deploy the chart,
    # and the BFF manifests that dial Cassandra directly); if either comes back
    # empty the scan is broken — e.g. a consumer's contact point was respelled
    # into something the value-shaped detector no longer recognises — and that is
    # a failure, not a clean sheet.
    if not gateway_consumers:
        fail("[input]", "no Application under specs/cluster/apps was recognised as deploying "
                        f"{GATEWAY_CHART} — the gateway scan found nothing, so its credential "
                        "checks proved nothing.")
    if not manifest_consumers:
        fail("[input]", "no workload manifest under specs/cluster/manifests was recognised as "
                        "dialing Cassandra — the manifest scan found nothing, so its credential "
                        "checks proved nothing.")

    roles = check_credentials(consumers)
    ext = collect_external_secrets(cluster_root)
    wanted = check_credential_secrets(consumers, ext)

    # The bootstrap authenticates as the superuser; that too must come from a Secret.
    for obj, _doc, _path in bootstraps:
        for n, v in obj.envs.items():
            if n.endswith(("ADMIN_USER", "ADMIN_PASSWORD")) and "secret" not in v:
                fail("[creds]", f"{obj}: {n} is a literal, not a secretKeyRef.")
            if "secret" in v:
                sname, skey = v["secret"]
                if (obj.namespace, sname) not in ext:
                    fail("[creds-secret]", f"{obj}: {n} mounts Secret {sname!r} in {obj.namespace!r}, "
                                           "which no ExternalSecret materializes there.")
                else:
                    wanted[(obj.namespace, sname, skey)] = ext[(obj.namespace, sname)].get(skey, (None, None))
                    if skey not in ext[(obj.namespace, sname)]:
                        fail("[creds-secret]", f"{obj}: {n} wants key {skey!r} of {sname!r}, "
                                               "which that ExternalSecret does not supply.")

    vault, usb = seeded_properties(repo)
    check_seeding(wanted, ext, vault, usb)

    script, job, overlay = read_bootstrap(cluster_root)
    if script:
        keyspaces, made_roles, grants = bootstrap_capabilities(script)
        check_ordering(script)
        check_keyspaces_and_roles(consumers, roles, keyspaces, made_roles, grants)
        check_role_password_coordinates(
            consumers, roles, made_roles,
            bootstraps[0][0] if bootstraps else None, ext, script)
        check_bootstrap_is_synced(cluster_root, overlay)
        check_bootstrap_networkpolicy(cluster_root, job)

    check_local_dc(consumers, server_datacenter(cluster_root))
    check_chart_template(repo)
    check_brand_templates(repo)

    for n in NOTES:
        print(n)
    if FAILURES:
        for f in FAILURES:
            print(f)
        print(f"  -- {len(FAILURES)} failure(s) across {len(consumers)} Cassandra consumer(s)")
        return 1
    print(f"  PASS all {len(consumers)} Cassandra consumer(s) credentialed, "
          "keyspaces + roles bootstrapped, both seeding paths complete")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
