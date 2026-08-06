#!/usr/bin/env python3
"""ESO seed-contract checker: every ExternalSecret reference must be SEEDED.

Usage:
  eso_seed_contract.py <specs/cluster dir> <gen-cluster-secrets.sh> <runs dir>

<runs dir> holds ONE SUBDIRECTORY PER PROVISIONING RUN, each containing
`vault.log` (the recorded `vault` argv) and `bundle/secrets.json` (the offline
USB bundle). The required run labels are `default` (every optional feature off),
`all-features` (every optional feature on), one run per entry in
CONDITIONAL_FEATURES below, enabling ONLY that feature — those isolated runs are
what makes a "conditional" classification EVIDENCE-BASED instead of an
auto-pass: an entry may only be excused as conditional if a named feature flag,
on its own, is what makes it appear — and `rebranded`, a default run under a
NON-default CLUSTER_DOMAIN (its domain recorded in `cluster-domain`), which is
what makes the [domain-coupled] check possible.

Exit 0 = every ExternalSecret reference in specs/cluster is satisfiable by BOTH
delivery paths (or is explicitly classified out of scope, with evidence).
Exit 1 = at least one unsatisfiable reference, a classification that no longer
matches reality, or a conditional claim the manifests/seeder do not support.

Driven by tests/scripts/test-eso-seed-contract.sh, which produces the run
artifacts by executing the REAL scripts/gen-cluster-secrets.sh under a `vault`
stub that records its argv instead of talking to a server, and which also runs
the negative controls. See its header for the shipped defect this gate exists to
catch.

THE CONTRACT, in one sentence: scripts/gen-cluster-secrets.sh is the ONLY thing
that provisions cluster secrets — ONLINE via `vault kv put`, OFFLINE via the USB
secrets.json bundle — so anything an ExternalSecret asks for that it does not
write is a Secret that never materializes.

WHY A MISSING PROPERTY IS FATAL, NOT PARTIAL: ESO resolves an ExternalSecret
ALL-OR-NOTHING. One unresolvable entry in `data:` fails the WHOLE object, so the
target Secret is never created and every OTHER key in it is lost too. Real
controller log from a kind cluster (2026-08-05):

  error retrieving secret at .data[5], key: hugmesh/route-access-db,
  err: cannot find secret data for key: "superadmin_gateway_password"

...which left route-access-db in CreateContainerConfigError forever, so the
gateway_route_access table — the source of truth for ALL route authorization —
never existed and every gateway silently fell back to its baked CanonicalSeed.

SCOPE, precisely (the claim and the behaviour are the same sentence): EVERY
ExternalSecret under specs/cluster is walked — not just
manifests/external-secrets. A file is CHECKED when its own directory's
kustomization.yaml lists it in `resources:`; anything else is reported under
[not-rendered]. Whether an ArgoCD Application currently points at that directory
is reported too, but a dark/manual-sync overlay is still CHECKED: its objects
are real and an operator applies them by hand at flip time, which is exactly
when an unseeded reference would bite.

CLASSIFICATION IS PER REFERENCE, NOT PER OBJECT. An ExternalSecret that draws
its cert from a Vault-PKI generator (`dataFrom[].sourceRef`) may ALSO carry
spec.data[] KV references; those are checked, and the offline-bundle
expectations still apply to every key the template derives from them. Only the
generator-derived keys are out of scope.

WHAT IS *NOT* ASSERTED: the VALUE behind a name, except in four cases —
(a) a value must be non-empty in the all-features run, (b) a literal
template.data value must match the offline bundle byte-for-byte, (c) an
`extract`-based Secret's offline key set must equal the Vault doc's, and (d) a
literal that embeds the cluster domain must TRACK CLUSTER_DOMAIN across the
`rebranded` run (see [domain-coupled] below). This gate compares the seeder's
OUTPUT to the manifests' DEMANDS; it does not attempt to judge whether a
correctly-shaped value is the RIGHT value (e.g. that a password is strong, or
that an OAuth placeholder was replaced). Those belong to the provisioning tests,
not here.

WHY [domain-coupled] EXISTS. The manifests under specs/cluster are NOT what a
cluster runs: build-*-stage4.sh copies specs/cluster to
${SYSROOT}/var/lib/hugmesh/cluster and rebrand_sysroot() then seds
`hugmesh.systems` -> `${CLUSTER_DOMAIN}` across that tree. So a template.data
literal containing the default domain is really `<something>@${CLUSTER_DOMAIN}`
at deploy time, and the offline bundle must derive the SAME value from
CLUSTER_DOMAIN. A byte-comparison against the repo manifest cannot see this —
both sides read `hugmesh.systems` on the default brand — so the gate re-runs the
seeder under a non-default domain and requires the value to move with it.

Deliberately dependency-light: PyYAML + python3 only. No cluster, no kubectl, no
vault binary, no network. Secret VALUES are read (to prove non-emptiness and
literal equality) and are NEVER printed.
"""
import json
import os
import re
import sys

import yaml

VAR = re.compile(r"\{\{-?\s*\.([A-Za-z0-9_]+)")

# ── classification: references this gate deliberately does NOT require ───────
#
# Nothing here is a silent whitelist. Every entry is PRINTED in the report with
# its reason, and the anti-rot check fails if an entry no longer matches a live
# reference — so an exemption cannot outlive the thing it excuses.

# Vault KV paths gen-cluster-secrets.sh deliberately does not mint, because the
# value is not the generator's to mint — either an operator supplies it out of
# band, or a running service ISSUES it and nothing can know it earlier. Each
# reason is quoted from the manifest that declares it, so the two cannot drift
# apart silently.
OPERATOR_SEEDED_PATHS = {
    "hugmesh/harbor-robots":
        "manifests/harbor/harbor-provision-job.yaml: 'a Harbor robot account's "
        "secret is returned EXACTLY ONCE at creation time and can never be "
        "re-read from Harbor afterwards ... this Job must capture the secret the "
        "moment Harbor mints it and WRITE it INTO Vault itself'. The generator "
        "is not merely unable to mint it — it must not WRITE the path at all: "
        "`vault kv put` replaces the whole KV-v2 doc, and the Job skips on "
        "HARBOR state ('if a robot with the expected name already exists, SKIP "
        "creating it'), so anything this seeder wrote over the real robot "
        "credentials would be permanent. gen-cluster-secrets.sh therefore leaves "
        "the path alone by default and only `kv patch`es the half a manual "
        "GITLAB_REGISTRY_TOKEN / IMAGE_BUILDER_REGISTRY_TOKEN override supplies. "
        "Guarded end to end by tests/scripts/test-harbor-robots-ownership.sh.",
    "hugmesh/akkoma-admin":
        "akkoma-externalsecrets.yaml: a PRIVILEGED Akkoma admin bearer token, "
        "issued BY the running homeserver — 'GATED STUB-SEAM: not presented "
        "until the exact verb is confirmed'. The generator cannot mint it.",
    "hugmesh/tuwunel-admin":
        "tuwunel-externalsecrets.yaml: a privileged MATRIX access token issued "
        "by the running tuwunel homeserver — same gated stub-seam as akkoma.",
    "hugmesh/coturn-shared-secret":
        "coturn-externalsecrets.yaml: 'The admin/DevOps MUST provision that "
        "Vault path at bootstrap' — DEFAULT-OFF optional service, and the value "
        "is shared with an out-of-band coturn deployment.",
    # (meshbridge-externalsecrets.yaml also says 'PROVISIONING IS MANUAL', but it
    # is not in the kustomization at all, so it is reported under [not-rendered]
    # instead — an entry here would be stale and the anti-rot check would say so.)
    "hugmesh/mesh-bff-casdoor-client":
        "secretstore.yaml: 'Provisioned MANUALLY in Casdoor (a "
        "client-credentials application bound to ROLE_SERVICE)' — a "
        "Casdoor-assigned client_id cannot be minted ahead of the application.",
    "hugmesh/cloudflared":
        "manifests/cloudflared/externalsecret.yaml: 'keys-provision populates "
        "[it] from the keys USB at provision time (KEYS/cloudflared/"
        "credentials.json -> Vault path secret/<brand>/cloudflared)'. The tunnel "
        "token is issued by CLOUDFLARE (keys-template/cloudflared/README.md), so "
        "the generator has nothing to mint; absent creds simply leave the "
        "cloudflared Deployment down, which the manifest calls 'harmless'.",
}

# Materialized k8s Secrets the OFFLINE USB bundle structurally cannot carry.
# Keyed "<namespace>/<secretName>".
OFFLINE_UNDELIVERABLE = {
    ns_secret: reason
    for ns_secret, reason in {
        # The SAME pull-scoped robot credential in every namespace that runs a
        # first-party image. The k8s Secret NAME differs in hugmesh-pki only:
        # the Harbor Helm chart is released into that namespace and already owns
        # `harbor-registry` (its own registry credentials — see
        # manifests/external-secrets/secretstore.yaml's hugmesh-registry-pull
        # block), so the pull secret there is `hugmesh-registry-pull`.
        **{
            ns_name:
                "imagePullSecret rendered from the PULL-scoped Harbor robot "
                "account that manifests/harbor/harbor-provision-job.yaml mints "
                "IN-CLUSTER at PostSync; the robot does not exist at bundle-write "
                "time. It is also a kubernetes.io/dockerconfigjson Secret, and the "
                "USB fallback in specs/etc/keys-provision/provision.sh creates "
                "`kubectl create secret generic` only."
            for ns_name in ("hugmesh-backend/harbor-registry",
                            "hugmesh-frontend/harbor-registry",
                            "hugmesh-games/harbor-registry",
                            "hugmesh-forum/harbor-registry",
                            "hugmesh-pki/hugmesh-registry-pull")
        },
        "hugmesh-image-builds/image-builder-registry":
            "same as harbor-registry: dockerconfigjson rendered from the "
            "PUSH-scoped Harbor robot account minted in-cluster by "
            "harbor-provision-job.yaml.",
    }.items()
}

# ── conditional features: an entry may be excused ONLY with evidence ─────────
#
# A reference the DEFAULT provisioning run does not satisfy is not automatically
# fine. To be excused it must be attributable to ONE of these declared feature
# flags — proven by an isolated run that enables ONLY that feature — AND the
# feature must still be real on both sides:
#   seeder_guard    a literal line of scripts/gen-cluster-secrets.sh that gates
#                   the write. If the seeder stops gating it, the claim dies.
#   manifest_proof  (file under specs/cluster, quoted text) — the manifest's own
#                   statement that the Secret is allowed not to materialize.
#                   Without this, "conditional" is just the gate excusing itself.
# Anything conditional that matches NO feature is a FAILURE, and a feature that
# no longer explains anything is a FAILURE too.
CONDITIONAL_FEATURES = {
    "mail": {
        "why":
            "outbound SMTP is OPTIONAL and ABSENT-BY-DEFAULT. With no real "
            "MAIL_USER/MAIL_PASSWORD the seeder blanks every mail property, and "
            "the casdoor/akkoma/attestation manifests read a blank host as "
            "'mail disabled' — seeding a real value unconditionally would "
            "switch outbound mail ON.",
        "enable_env": ["MAIL_PROVIDER", "MAIL_HOST", "MAIL_USER", "MAIL_PASSWORD"],
        "seeder_guard":
            'if [ "${MAIL_PROVIDER}" = "none" ] || [ -z "${MAIL_USER}" ] '
            '|| [ -z "${MAIL_PASSWORD}" ]; then',
        "manifest_proof": [
            ("manifests/external-secrets/secretstore.yaml",
             "When the Vault path is absent ESO simply never creates"),
            ("manifests/external-secrets/attestation-server-externalsecrets.yaml",
             'When mail is globally disabled (MAIL_ENABLED != "1"), this Secret '
             'renders with blank'),
        ],
    },
    "managed-velero": {
        "why":
            "the object-store IAM credential is OPERATOR-SUPPLIED, never "
            "generator-minted. Writing a blank would CLOBBER a manually-seeded "
            "secret/<brand>/velero, and materializing an empty "
            "velero-cloud-credentials would arm a backup location with no "
            "credentials.",
        "enable_env": ["MANAGED_VELERO_ACCESS_KEY_ID",
                       "MANAGED_VELERO_SECRET_ACCESS_KEY"],
        "seeder_guard": 'if [ "${MANAGED_VELERO_ENABLED}" = "1" ]; then',
        "manifest_proof": [
            ("manifests/external-secrets/velero-externalsecrets.yaml",
             "SHIPS DARK: this ExternalSecret only materializes when the velero "
             "namespace"),
        ],
    },
}

DEFAULT_RUN = "default"
ALL_RUN = "all-features"
# A default run under a NON-default CLUSTER_DOMAIN. Used ONLY by
# [domain-coupled]; never by the name-resolution checks.
REBRAND_RUN = "rebranded"

# The seeder's own default domain, parsed from this exact line of
# gen-cluster-secrets.sh. Parsed rather than hardcoded so that renaming the
# default brand cannot leave [domain-coupled] silently comparing against a domain
# nothing uses any more — if the line moves, the check fails instead of passing.
SEEDER_DOMAIN_DEFAULT = re.compile(
    r'^CLUSTER_DOMAIN="\$\{CLUSTER_DOMAIN:-([^}"]+)\}"', re.M)


# ── loading ──────────────────────────────────────────────────────────────────

def load_docs(path):
    """Every YAML document in one file, skipping empties."""
    with open(path, encoding="utf-8") as fh:
        return [d for d in yaml.safe_load_all(fh.read()) if isinstance(d, dict)]


def read_vault_log(path):
    """{ '<mount>/<path>': {property: value} } from the recorded `vault` argv.

    Values are kept ONLY so the gate can prove a property is not blank and that
    a literal matches; they are never printed.
    """
    written = {}
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            argv = json.loads(line)
            if argv[:2] != ["kv", "put"] or len(argv) < 3:
                continue
            doc = argv[2]
            props = dict(a.split("=", 1) for a in argv[3:] if "=" in a)
            written.setdefault(doc, {}).update(props)
    return written


def load_runs(runs_dir, labels):
    """{label: {'online': ..., 'bundle': ..., 'domain': ...}} per required label.

    `domain` is the CLUSTER_DOMAIN the run was executed under, recorded by the
    driver in `<label>/cluster-domain` (None when the file is absent).
    """
    runs, missing = {}, []
    for label in labels:
        d = os.path.join(runs_dir, label)
        log, bundle = os.path.join(d, "vault.log"), os.path.join(d, "bundle", "secrets.json")
        if not (os.path.isfile(log) and os.path.isfile(bundle)):
            missing.append(label)
            continue
        domain = None
        dom_file = os.path.join(d, "cluster-domain")
        if os.path.isfile(dom_file):
            with open(dom_file, encoding="utf-8") as fh:
                domain = fh.read().strip() or None
        with open(bundle, encoding="utf-8") as fh:
            runs[label] = {"online": read_vault_log(log),
                           "bundle": json.load(fh), "domain": domain}
    return runs, missing


# ── which ExternalSecrets are in scope, and on what evidence ─────────────────

def argocd_paths(specs_cluster):
    """{'<dir under specs/cluster>': '<apps/ file that points at it>'}.

    Read from every ArgoCD Application's spec.source.path / spec.sources[].path.
    Used ONLY to report how an in-scope object reaches a cluster (auto-synced vs
    applied by hand); it never decides whether a reference is checked.
    """
    out = {}
    appdir = os.path.join(specs_cluster, "apps")
    if not os.path.isdir(appdir):
        return out
    for fname in sorted(os.listdir(appdir)):
        if not fname.endswith((".yaml", ".yml")):
            continue
        try:
            docs = load_docs(os.path.join(appdir, fname))
        except Exception:  # noqa: BLE001 - a malformed app file is another gate's problem
            continue
        for doc in docs:
            if doc.get("kind") != "Application":
                continue
            spec = doc.get("spec") or {}
            srcs = [spec.get("source") or {}] + list(spec.get("sources") or [])
            for src in srcs:
                p = src.get("path")
                if not p:
                    continue
                marker = "specs/cluster/"
                rel = p.split(marker, 1)[1] if marker in p else p
                out.setdefault(rel.rstrip("/"), fname)
    return out


def kustomization_resources(dirpath):
    """The `resources:` list of <dirpath>/kustomization.yaml (empty if absent)."""
    kust = os.path.join(dirpath, "kustomization.yaml")
    if not os.path.isfile(kust):
        return None
    docs = load_docs(kust)
    if not docs:
        return []
    return [r for r in (docs[0].get("resources") or []) if isinstance(r, str)]


def find_externalsecret_files(specs_cluster):
    """[(relpath, abspath)] of every file under specs/cluster holding an ExternalSecret."""
    out = []
    for dirpath, _dirs, files in os.walk(specs_cluster):
        for fname in sorted(files):
            if not fname.endswith((".yaml", ".yml")):
                continue
            path = os.path.join(dirpath, fname)
            try:
                with open(path, encoding="utf-8") as fh:
                    blob = fh.read()
            except OSError:
                continue
            if "kind: ExternalSecret" not in blob:
                continue
            try:
                docs = [d for d in yaml.safe_load_all(blob) if isinstance(d, dict)]
            except yaml.YAMLError:
                continue
            if any(d.get("kind") == "ExternalSecret" for d in docs):
                out.append((os.path.relpath(path, specs_cluster), path))
    return sorted(out)


# ── one ExternalSecret, decomposed PER REFERENCE ─────────────────────────────

class ES:
    """One ExternalSecret, with its KV and generator references kept APART.

    The whole point: a generator-backed `dataFrom` entry excuses ITSELF and the
    template keys derived from it — nothing more. Any spec.data[] KV remoteRef
    in the same object is still a reference the seeder must satisfy, and the
    keys the template builds from it are still expected in the offline bundle.
    """

    def __init__(self, relfile, doc):
        self.file = relfile
        md, spec = doc.get("metadata", {}) or {}, doc.get("spec", {}) or {}
        self.ns, self.name = md.get("namespace"), md.get("name")
        self.spec = spec
        target = spec.get("target") or {}
        self.target = target
        self.tname = target.get("name") or self.name
        self.template = (target.get("template") or {}).get("data") or {}
        self.store = (spec.get("secretStoreRef") or {}).get("name")
        self.kv_refs = []        # dicts: key, property, secret_key
        self.gen_refs = []       # dicts: kind, name, via
        self.kv_secret_keys = set()
        self.gen_secret_keys = set()
        self.extract_keys = []
        self.malformed = []

        for entry in spec.get("data") or []:
            sk = entry.get("secretKey")
            if "sourceRef" in entry:
                # A per-entry generator reference: out of scope, but it only
                # excuses THIS key.
                gref = (entry.get("sourceRef") or {}).get("generatorRef") or {}
                self.gen_refs.append({"kind": gref.get("kind"), "name": gref.get("name"),
                                      "via": f"data[].{sk}"})
                if sk:
                    self.gen_secret_keys.add(sk)
                continue
            rr = entry.get("remoteRef") or {}
            self.kv_refs.append({"key": rr.get("key"), "property": rr.get("property"),
                                 "secret_key": sk})
            if sk:
                self.kv_secret_keys.add(sk)

        for df in spec.get("dataFrom") or []:
            if "sourceRef" in df:
                gref = (df.get("sourceRef") or {}).get("generatorRef") or {}
                self.gen_refs.append({"kind": gref.get("kind"), "name": gref.get("name"),
                                      "via": "dataFrom[].sourceRef"})
            elif "extract" in df:
                key = (df["extract"] or {}).get("key")
                self.kv_refs.append({"key": key, "property": None, "secret_key": None})
                self.extract_keys.append(key)
            elif "find" in df:
                self.malformed.append(
                    "dataFrom[].find is not supported by this gate — a wildcard "
                    "match cannot be proved against a fixed seeder")
            else:
                self.malformed.append(f"unrecognized dataFrom entry {sorted(df)}")

    @property
    def where(self):
        return f"{self.ns}/{self.name}"

    def kv_keys(self):
        return {r["key"] for r in self.kv_refs if r["key"]}

    def materialized(self, doc_props):
        """{k8s key: origin} + mode, where origin is kv | literal | generator.

        `doc_props` is {vault key: {property: value}} for ONE run, mount-stripped,
        so an `extract` Secret's key set is the doc that run actually wrote.
        An "unexplained" origin carries the offending variable names so the
        failure can name them.
        """
        extract_props = set()
        for k in self.extract_keys:
            extract_props |= set(doc_props.get(k, {}))
        if self.template:
            out = {}
            for k, v in self.template.items():
                names = set(VAR.findall(str(v)))
                if not names:
                    out[k] = "literal"
                elif names & self.kv_secret_keys or names & extract_props:
                    out[k] = "kv"
                elif names & self.gen_secret_keys or self.gen_refs:
                    out[k] = "generator"
                else:
                    out[k] = "unexplained:" + ",".join(sorted(names))
            return out, "template"
        out = {sk: "kv" for sk in self.kv_secret_keys}
        out.update({sk: "generator" for sk in self.gen_secret_keys})
        if not out and extract_props:
            return {p: "kv" for p in extract_props}, "extract"
        return out, "data"


def main():
    if len(sys.argv) != 4:
        print(__doc__)
        return 2
    specs_cluster, seeder_path, runs_dir = sys.argv[1:]

    required = [DEFAULT_RUN, ALL_RUN, REBRAND_RUN] + sorted(CONDITIONAL_FEATURES)
    runs, missing_runs = load_runs(runs_dir, required)

    fails = []

    def bad(check, msg):
        fails.append(f"  FAIL {check} {msg}")

    def ok(check, msg):
        print(f"  PASS {check} {msg}")

    if missing_runs:
        # Never treat an absent artifact as a pass: without the isolated runs the
        # conditional bucket would silently become an auto-pass again.
        bad("[runs]",
            f"missing provisioning run artifact(s) {missing_runs} under "
            f"{runs_dir} — every required run must exist "
            f"(required: {required})")
        print("\n".join(fails))
        return 1

    online = {lbl: runs[lbl]["online"] for lbl in runs}
    bundles = {lbl: runs[lbl]["bundle"] for lbl in runs}
    domains = {lbl: runs[lbl]["domain"] for lbl in runs}

    esdir = os.path.join(specs_cluster, "manifests", "external-secrets")

    # ── the ClusterSecretStore's KV mount: remoteRef keys are RELATIVE to it ──
    stores = {}
    store_file = os.path.join(esdir, "secretstore.yaml")
    if os.path.isfile(store_file):
        for doc in load_docs(store_file):
            if doc.get("kind") in ("ClusterSecretStore", "SecretStore"):
                vault_cfg = (doc.get("spec", {}).get("provider", {}) or {}).get("vault", {})
                stores[doc["metadata"]["name"]] = vault_cfg.get("path")
    if not stores:
        bad("[store]", f"no ClusterSecretStore/SecretStore found in {store_file}")
        print("\n".join(fails))
        return 1

    # ── SCOPE: every ExternalSecret under specs/cluster, checked when its own ─
    #    directory's kustomization lists it. Renderedness is EVIDENCE, printed.
    apps = argocd_paths(specs_cluster)
    checked, not_rendered = [], []
    dark_overlays = {}
    files = find_externalsecret_files(specs_cluster)
    outside = [rel for rel, _ in files
               if os.path.dirname(rel) != os.path.join("manifests", "external-secrets")]

    for rel, path in files:
        reldir = os.path.dirname(rel)
        resources = kustomization_resources(os.path.dirname(path))
        base = os.path.basename(rel)
        if resources is None:
            not_rendered.append((rel, f"{reldir}/ has no kustomization.yaml at all"))
            continue
        if base not in resources:
            not_rendered.append(
                (rel, f"absent from {reldir}/kustomization.yaml resources:"))
            continue
        app = apps.get(reldir)
        if not app:
            dark_overlays[reldir] = (
                "in its kustomization but NO ArgoCD Application points at "
                f"{reldir} — a DARK overlay an operator applies by hand. STILL "
                "CHECKED: the objects are real and an unseeded reference bites "
                "at flip time.")
        for doc in load_docs(path):
            if doc.get("kind") != "ExternalSecret":
                continue
            checked.append(ES(rel, doc))

    print(f"== ESO seed contract: {len(checked)} ExternalSecret(s) checked across "
          f"{len(files)} file(s) under {os.path.relpath(specs_cluster)} "
          f"({len(outside)} file(s) outside manifests/external-secrets, "
          f"{len(not_rendered)} not rendered) ==")

    if not checked:
        bad("[scope]", "no ExternalSecret was checked at all — the walk found "
                       "nothing, so every assertion below would pass vacuously")
        print("\n".join(fails))
        return 1

    # ── (0) structural: a KV reference needs a known store; no unknown forms ──
    kv_backed = []
    for es in checked:
        for msg in es.malformed:
            bad("[form]", f"{es.file}: {es.where} {msg}")
        if not es.kv_refs:
            continue
        if es.store not in stores:
            bad("[store]",
                f"{es.file}: {es.where} has {len(es.kv_refs)} KV remoteRef(s) but "
                f"secretStoreRef '{es.store}' is unknown (known: {sorted(stores)}) "
                f"— nothing can resolve them.")
            continue
        kv_backed.append(es)
    if not any(f.startswith("  FAIL [store]") or f.startswith("  FAIL [form]") for f in fails):
        ok("[store]",
           f"all {sum(len(e.kv_refs) for e in kv_backed)} KV reference(s) across "
           f"{len(kv_backed)} ExternalSecret(s) name a known ClusterSecretStore")

    kv_refs = [(es, r) for es in kv_backed for r in es.kv_refs]

    # ── (1) remoteRef keys must be MOUNT-RELATIVE ────────────────────────────
    # ESO's Vault provider prepends the store's own provider.vault.path (and the
    # KV-v2 /data/ segment). A key that repeats the mount resolves to
    # <mount>/data/<mount>/... — a path nothing ever writes.
    relative = 0
    for es, r in kv_refs:
        mount = stores[es.store]
        if not r["key"]:
            bad("[remoteref-key]", f"{es.file}: {es.where} has a remoteRef with no key")
            continue
        if mount and r["key"].split("/", 1)[0] == mount:
            bad("[mount-relative]",
                f"{es.file}: {es.where} remoteRef.key '{r['key']}' repeats the "
                f"ClusterSecretStore '{es.store}' mount '{mount}'. ESO prepends the "
                f"mount itself, so this resolves to '{mount}/data/{r['key']}' — a "
                f"path gen-cluster-secrets.sh never writes. Drop the leading "
                f"'{mount}/'.")
        else:
            relative += 1
    if relative == len(kv_refs):
        ok("[mount-relative]",
           f"all {relative} remoteRef key(s) are relative to their store's KV mount")

    # ── run views, mount-stripped, per label ─────────────────────────────────
    def doc_props(label, mount):
        return {k[len(mount) + 1:] if mount else k: v
                for k, v in online[label].items()
                if not mount or k.startswith(mount + "/")}

    def online_has(label, mount, key, prop):
        full = f"{mount}/{key}" if mount else key
        doc = online[label].get(full)
        if doc is None:
            return False
        return prop is None or prop in doc

    def online_value(label, mount, key, prop):
        full = f"{mount}/{key}" if mount else key
        return (online[label].get(full) or {}).get(prop)

    # ── (2) ONLINE: gen-cluster-secrets.sh must `vault kv put` key+property ──
    # `conditional` = satisfied by the all-features run but NOT by default. Such
    # an entry is NOT waved through: check (5) demands a named feature explain it.
    conditional_online = []   # (label-text, attributed features)
    online_bad = 0
    for es, r in kv_refs:
        key, prop = r["key"], r["property"]
        if not key or key in OPERATOR_SEEDED_PATHS:
            continue
        mount = stores[es.store]
        full = f"{mount}/{key}" if mount else key
        where = es.where + (f" (Secret key {r['secret_key']})" if r["secret_key"] else "")
        if online_has(DEFAULT_RUN, mount, key, prop):
            continue
        if online_has(ALL_RUN, mount, key, prop):
            attributed = [f for f in sorted(CONDITIONAL_FEATURES)
                          if online_has(f, mount, key, prop)]
            conditional_online.append(
                (f"{full}" + (f".{prop}" if prop else "") + f"  <- {where} [{es.file}]",
                 attributed, f"{full}" + (f".{prop}" if prop else "")))
            continue
        online_bad += 1
        if not any(full in online[lbl] for lbl in runs):
            bad("[online-seed]",
                f"{where} [{es.file}] reads Vault path '{full}', which "
                f"gen-cluster-secrets.sh NEVER writes (no `vault kv put {full}`).")
        else:
            bad("[online-seed]",
                f"{where} [{es.file}] reads property '{prop}' of Vault path "
                f"'{full}', which gen-cluster-secrets.sh does NOT write. ESO "
                f"fails the ENTIRE ExternalSecret on one missing property, so "
                f"Secret {es.ns}/{es.tname} never materializes at all.")
    if online_bad == 0:
        ok("[online-seed]",
           f"every KV reference is written by a `vault kv put` "
           f"({len(conditional_online)} only with an optional feature enabled)")

    # ── (3) OFFLINE: the USB bundle must carry the materialized Secret ───────
    conditional_offline = []
    offline_by_operator = []
    generator_only = []
    offline_bad = 0
    literal_bad = 0
    unexplained = 0

    def offline_view(es, label):
        mount = stores.get(es.store)
        mat, mode = es.materialized(doc_props(label, mount))
        want = {k for k, origin in mat.items() if origin in ("kv", "literal")}
        got = dict(((bundles[label].get(es.ns) or {}).get(es.tname) or {}))
        present = es.tname in (bundles[label].get(es.ns) or {})
        return mat, mode, want, got, present

    for es in checked:
        mat, mode, want, got, present = offline_view(es, DEFAULT_RUN)
        for k, origin in mat.items():
            if origin.startswith("unexplained"):
                unexplained += 1
                names = origin.split(":", 1)[1]
                bad("[template-vars]",
                    f"{es.file}: {es.where} target.template.data['{k}'] "
                    f"interpolates {names}, which NOTHING provides — no "
                    f"spec.data[] secretKey, no extracted Vault property and no "
                    f"generator. ESO renders it EMPTY, so the consumer gets a "
                    f"blank value with no error anywhere.")
        if not want:
            # Every key this object materializes is generator-derived (a cert
            # issued at sync time). Nothing to seed, and the USB bundle cannot
            # carry a runtime-issued cert either.
            if es.gen_refs:
                generator_only.append(
                    f"{es.where} -> Secret {es.ns}/{es.tname}  [{es.file}]  "
                    f"({', '.join(sorted({g['kind'] or '?' for g in es.gen_refs}))})")
            continue
        if f"{es.ns}/{es.tname}" in OFFLINE_UNDELIVERABLE:
            continue
        # A Secret sourced ENTIRELY from operator-seeded Vault paths is equally
        # absent from the USB bundle, for the SAME reason the online path skips
        # it: the value does not exist at bundle-write time. Classified once,
        # honored on both paths — but only when EVERY source is exempt, so a
        # Secret that mixes a seeded and an operator path is still checked.
        keys = es.kv_keys()
        if keys and keys <= set(OPERATOR_SEEDED_PATHS):
            offline_by_operator.append(f"{es.ns}/{es.tname}  [{es.file}]")
            continue
        if present and not (want - set(got)):
            if mode == "extract" and (set(got) - want):
                offline_bad += 1
                bad("[offline-bundle]",
                    f"{es.ns}/{es.tname} [{es.file}] is materialized by `dataFrom: "
                    f"extract`, so ESO copies EXACTLY the Vault doc's properties, "
                    f"but the USB bundle carries extra key(s) "
                    f"{sorted(set(got) - want)} that no Vault property backs — "
                    f"online and offline disagree on the same Secret.")
            continue
        _m2, _mode2, want_opt, got_opt, present_opt = offline_view(es, ALL_RUN)
        if present_opt and not (want_opt - set(got_opt)):
            attributed = []
            for feat in sorted(CONDITIONAL_FEATURES):
                _m3, _md3, want_f, got_f, present_f = offline_view(es, feat)
                if present_f and not (want_f - set(got_f)):
                    attributed.append(feat)
            conditional_offline.append(
                (f"{es.ns}/{es.tname}  [{es.file}]", attributed, f"{es.ns}/{es.tname}"))
            continue
        offline_bad += 1
        if not present and not present_opt:
            bad("[offline-bundle]",
                f"{es.ns}/{es.tname} [{es.file}] is materialized by an "
                f"ExternalSecret but the USB secrets.json bundle has NO entry for "
                f"it — an offline/USB-provisioned cluster never gets this Secret.")
        else:
            bad("[offline-bundle]",
                f"{es.ns}/{es.tname} [{es.file}] is in the USB bundle but MISSING "
                f"key(s) {sorted(want - set(got))} (derived from the "
                f"ExternalSecret's {mode}) — an offline-provisioned cluster gets a "
                f"partial Secret.")

    if offline_bad == 0:
        ok("[offline-bundle]",
           f"every materialized Secret is in the USB bundle with all its "
           f"KV-derived keys ({len(conditional_offline)} only with an optional "
           f"feature enabled)")
    if unexplained == 0:
        ok("[template-vars]",
           "every target.template.data interpolation resolves to a KV reference, "
           "an extracted Vault property or a generator")

    # ── (4) LITERAL template values must be IDENTICAL on both paths ──────────
    # A template.data value with no {{ }} is what ESO writes verbatim online.
    # If the offline bundle computes a DIFFERENT value for the same key, the two
    # delivery paths hand the same workload two different Secrets.
    literal_checked = 0
    for es in checked:
        if f"{es.ns}/{es.tname}" in OFFLINE_UNDELIVERABLE:
            continue
        keys = es.kv_keys()
        if keys and keys <= set(OPERATOR_SEEDED_PATHS):
            continue
        got = (bundles[ALL_RUN].get(es.ns) or {}).get(es.tname)
        if got is None:
            continue
        for k, v in es.template.items():
            if VAR.search(str(v)):
                continue
            literal_checked += 1
            if k not in got:
                literal_bad += 1
                bad("[literal-value]",
                    f"{es.ns}/{es.tname} [{es.file}] template.data['{k}'] is a "
                    f"LITERAL that ESO always writes online, but the USB bundle "
                    f"has no such key.")
            elif got[k] != str(v):
                literal_bad += 1
                bad("[literal-value]",
                    f"{es.ns}/{es.tname} [{es.file}] key '{k}' is a LITERAL in "
                    f"target.template.data, so ESO writes exactly that string "
                    f"online — but gen-cluster-secrets.sh puts a DIFFERENT string "
                    f"in the USB bundle. The two delivery paths disagree on the "
                    f"same Secret key; fix whichever side is wrong (the manifest "
                    f"literal is the contract).")
    if literal_bad == 0:
        ok("[literal-value]",
           f"all {literal_checked} literal template.data value(s) are byte-identical "
           f"in the USB bundle")

    # the seeder's own text — read once, used by (4b) and (5) ─────────────────
    seeder_read_error = None
    try:
        with open(seeder_path, encoding="utf-8") as fh:
            seeder_src = fh.read()
    except OSError as exc:
        seeder_src = ""
        seeder_read_error = str(exc)

    # ── (4b) DOMAIN-COUPLED literals must TRACK CLUSTER_DOMAIN ───────────────
    # Check (4) proves the two paths agree on the DEFAULT brand — and that is all
    # it can prove, because both sides read `hugmesh.systems` there. But the
    # manifest a cluster actually runs is the BAKED copy, and rebrand_sysroot()
    # seds the default domain to ${CLUSTER_DOMAIN} across it. So a literal that
    # embeds the default domain is really `<x>@${CLUSTER_DOMAIN}` online, and the
    # offline bundle must derive it the same way. The `rebranded` run — the same
    # default provisioning run under a non-default CLUSTER_DOMAIN — is what makes
    # that visible: a hardcoded offline value does not move, and is caught here.
    # The symmetric direction is asserted too: a literal that does NOT embed the
    # domain must NOT move, or the seeder is substituting where the manifest is
    # fixed.
    domain_bad = 0
    domain_checked = 0
    probe_domain = domains.get(REBRAND_RUN)
    m = SEEDER_DOMAIN_DEFAULT.search(seeder_src)
    default_domain = m.group(1) if m else None
    if seeder_read_error:
        domain_bad += 1
        bad("[domain-coupled]",
            f"cannot read the seeder at {seeder_path}: {seeder_read_error}")
    elif not default_domain:
        domain_bad += 1
        bad("[domain-coupled]",
            f"could not find the seeder's default-domain line "
            f"(`CLUSTER_DOMAIN=\"${{CLUSTER_DOMAIN:-<domain>}}\"`) in "
            f"{os.path.relpath(seeder_path)}. This check compares against that "
            f"domain, so without it every domain-bearing literal would be "
            f"silently unchecked.")
    elif not probe_domain:
        domain_bad += 1
        bad("[domain-coupled]",
            f"run '{REBRAND_RUN}' recorded no CLUSTER_DOMAIN in its "
            f"cluster-domain file — the driver must record the non-default "
            f"domain it used, or this check cannot tell a tracking value from a "
            f"hardcoded one.")
    elif probe_domain == default_domain:
        domain_bad += 1
        bad("[domain-coupled]",
            f"run '{REBRAND_RUN}' used CLUSTER_DOMAIN='{probe_domain}', which is "
            f"the seeder's DEFAULT domain — a rebrand probe that does not rebrand "
            f"proves nothing. Point it at a different domain.")
    else:
        for es in checked:
            if f"{es.ns}/{es.tname}" in OFFLINE_UNDELIVERABLE:
                continue
            keys = es.kv_keys()
            if keys and keys <= set(OPERATOR_SEEDED_PATHS):
                continue
            got = (bundles[REBRAND_RUN].get(es.ns) or {}).get(es.tname)
            if got is None:
                continue
            for k, v in es.template.items():
                if VAR.search(str(v)) or k not in got:
                    continue
                v = str(v)
                domain_checked += 1
                want = v.replace(default_domain, probe_domain)
                if got[k] == want:
                    continue
                domain_bad += 1
                if default_domain in v:
                    bad("[domain-coupled]",
                        f"{es.ns}/{es.tname} [{es.file}] template.data['{k}'] is "
                        f"the literal '{v}', which EMBEDS the default cluster "
                        f"domain '{default_domain}'. build-*-stage4.sh bakes "
                        f"specs/cluster into /var/lib/hugmesh/cluster and "
                        f"rebrand_sysroot() seds that domain to ${{CLUSTER_DOMAIN}}, "
                        f"so ESO writes '{want}' online on a cluster whose domain "
                        f"is '{probe_domain}' — but gen-cluster-secrets.sh put a "
                        f"value that does NOT track CLUSTER_DOMAIN in the USB "
                        f"bundle. The two delivery paths hand the SAME pod two "
                        f"different values on every non-default brand. Derive it "
                        f"from CLUSTER_DOMAIN instead of hardcoding it.")
                else:
                    bad("[domain-coupled]",
                        f"{es.ns}/{es.tname} [{es.file}] template.data['{k}'] is "
                        f"the literal '{v}', which does NOT embed the cluster "
                        f"domain — rebrand_sysroot() leaves it alone, so ESO "
                        f"writes it verbatim on every brand. But "
                        f"gen-cluster-secrets.sh wrote a DIFFERENT value into the "
                        f"USB bundle when CLUSTER_DOMAIN was '{probe_domain}', so "
                        f"the offline path varies where the online path is fixed.")
    if domain_bad == 0:
        ok("[domain-coupled]",
           f"all {domain_checked} literal template.data value(s) track "
           f"CLUSTER_DOMAIN exactly as rebrand_sysroot() rewrites the baked "
           f"manifest (probe domain '{probe_domain}')")

    # ── (5) CONDITIONAL entries need EVIDENCE, not an auto-pass ──────────────
    cond_bad = 0
    if seeder_read_error:
        cond_bad += 1
        bad("[conditional]",
            f"cannot read the seeder at {seeder_path}: {seeder_read_error}")

    used_features = set()
    for text, attributed, _name in conditional_online + conditional_offline:
        if not attributed:
            cond_bad += 1
            bad("[conditional]",
                f"{text} is satisfied by the all-features run but NOT by a DEFAULT "
                f"provisioning run, and NO declared feature "
                f"({sorted(CONDITIONAL_FEATURES)}) makes it appear on its own. An "
                f"always-rendered ExternalSecret that a default run cannot satisfy "
                f"is a broken Secret, not a conditional one — either seed it "
                f"unconditionally or declare (and prove) the flag that gates it.")
            continue
        used_features.update(attributed)
    for feat, spec in sorted(CONDITIONAL_FEATURES.items()):
        if feat not in used_features:
            cond_bad += 1
            bad("[conditional]",
                f"CONDITIONAL_FEATURES declares '{feat}', but with ONLY that "
                f"feature enabled nothing becomes satisfiable that a default run "
                f"could not already satisfy — the declaration explains nothing "
                f"any more. Delete it (or the references it excused moved and are "
                f"now unguarded).")
        if seeder_src and spec["seeder_guard"] not in seeder_src:
            cond_bad += 1
            bad("[conditional]",
                f"feature '{feat}' claims gen-cluster-secrets.sh gates it with "
                f"`{spec['seeder_guard']}`, but that line is GONE from "
                f"{os.path.relpath(seeder_path)} — the conditionality claim is no "
                f"longer backed by the seeder.")
        for relpath, quote in spec["manifest_proof"]:
            full = os.path.join(specs_cluster, relpath)
            try:
                with open(full, encoding="utf-8") as fh:
                    body = fh.read()
            except OSError:
                body = ""
            if quote not in body:
                cond_bad += 1
                bad("[conditional]",
                    f"feature '{feat}' claims {relpath} declares its Secret free "
                    f"not to materialize, quoting \"{quote}\" — that text is NOT "
                    f"in the manifest. A conditional classification the manifests "
                    f"do not support is the gate excusing itself.")
    if cond_bad == 0:
        ok("[conditional]",
           f"all {len(conditional_online) + len(conditional_offline)} conditional "
           f"entr(ies) are attributed to a declared feature whose seeder guard and "
           f"manifest statement both still exist")

    # ── (6) NON-EMPTY: a name that resolves to "" is not a seeded secret ─────
    # Checked against the ALL-FEATURES run, which is the only run in which every
    # optional value is real; a property that is still blank there is blank for
    # everyone. (Blank-when-disabled is the mail feature's documented behaviour
    # and is reported under [conditional], not here.)
    empty_bad = 0
    checked_values = 0
    for es, r in kv_refs:
        key, prop = r["key"], r["property"]
        if not key or key in OPERATOR_SEEDED_PATHS or prop is None:
            continue
        mount = stores[es.store]
        val = online_value(ALL_RUN, mount, key, prop)
        if val is None:
            continue  # already reported by [online-seed]
        checked_values += 1
        if val == "":
            empty_bad += 1
            bad("[non-empty]",
                f"{es.where} [{es.file}] reads '{key}.{prop}', which "
                f"gen-cluster-secrets.sh writes as an EMPTY string even with every "
                f"optional feature ON. The name resolves, so ESO materializes the "
                f"Secret and every consumer starts with a blank credential instead "
                f"of failing loudly.")
    for es in checked:
        got = (bundles[ALL_RUN].get(es.ns) or {}).get(es.tname)
        if not got:
            continue
        _m, _mode, want, _g, _p = offline_view(es, ALL_RUN)
        for k in sorted(want & set(got)):
            checked_values += 1
            if got[k] == "":
                empty_bad += 1
                bad("[non-empty]",
                    f"{es.ns}/{es.tname} [{es.file}] key '{k}' is EMPTY in the USB "
                    f"bundle even with every optional feature ON — an "
                    f"offline-provisioned cluster gets a blank credential.")
    if empty_bad == 0:
        ok("[non-empty]",
           f"all {checked_values} seeded value(s) are non-empty with every optional "
           f"feature enabled")

    # ── (7) anti-rot: no classification entry may outlive its reference ──────
    live_paths = {r["key"] for _es, r in kv_refs if r["key"]}
    live_secrets = {f"{es.ns}/{es.tname}" for es in checked}
    stale = 0
    for path in sorted(OPERATOR_SEEDED_PATHS):
        if path not in live_paths:
            stale += 1
            bad("[stale-exemption]",
                f"OPERATOR_SEEDED_PATHS still excuses '{path}', but no checked "
                f"ExternalSecret references it any more — delete the entry (or "
                f"the reference moved and is now unguarded).")
    for sec in sorted(OFFLINE_UNDELIVERABLE):
        if sec not in live_secrets:
            stale += 1
            bad("[stale-exemption]",
                f"OFFLINE_UNDELIVERABLE still excuses '{sec}', but no checked "
                f"ExternalSecret materializes it any more — delete the entry.")
    if stale == 0:
        ok("[stale-exemption]",
           f"all {len(OPERATOR_SEEDED_PATHS) + len(OFFLINE_UNDELIVERABLE)} "
           f"classification entries still match a live reference")

    # ── the honest-scope report: say what was NOT required, and why ──────────
    print()
    print("-- deliberately OUT OF SCOPE (each is a classification, not a skip) --")
    print("   [not-rendered] holds ExternalSecrets but its own kustomization does "
          "not apply it:")
    for rel, why in not_rendered:
        print(f"     - {rel}\n         {why}")
    if not not_rendered:
        print("     (none)")
    print("   [generator] EVERY key this object materializes is issued at sync "
          "time by a Vault generator (VaultDynamicSecret / PKI), not read from KV "
          "— nothing to seed, and the USB bundle cannot carry a runtime-issued "
          "cert either. (A generator-backed object that ALSO carries spec.data[] "
          "KV references is NOT here: those references are checked above.)")
    for line in generator_only:
        print(f"     - {line}")
    print("   [operator-seeded] Vault KV paths the generator deliberately does "
          "not mint (the USB bundle omits the Secrets they back for the same "
          "reason — the value does not exist at bundle-write time):")
    for path, why in sorted(OPERATOR_SEEDED_PATHS.items()):
        print(f"     - {path}\n         {why}")
    for line in offline_by_operator:
        print(f"       offline Secret omitted: {line}")
    print("   [offline-undeliverable] Secrets the USB bundle structurally "
          "cannot carry:")
    for sec, why in sorted(OFFLINE_UNDELIVERABLE.items()):
        print(f"     - {sec}\n         {why}")
    print("   [dark-overlay] CHECKED, but reached by a deliberate operator apply "
          "rather than an ArgoCD sync:")
    for reldir, why in sorted(dark_overlays.items()):
        print(f"     - {reldir}\n         {why}")
    if not dark_overlays:
        print("     (none)")
    print("   [conditional] satisfied ONLY with a named optional feature enabled "
          "— each entry is ATTRIBUTED to the feature whose isolated run makes it "
          "appear, and that feature's seeder guard + manifest statement are both "
          "verified above:")
    for text, attributed, _n in conditional_online:
        print(f"     - online   {text}\n         via feature(s): "
              f"{', '.join(attributed) or 'UNATTRIBUTED'}")
    for text, attributed, _n in conditional_offline:
        print(f"     - offline  {text}\n         via feature(s): "
              f"{', '.join(attributed) or 'UNATTRIBUTED'}")
    if not conditional_online and not conditional_offline:
        print("     (none)")
    for feat, spec in sorted(CONDITIONAL_FEATURES.items()):
        print(f"       feature '{feat}' (enabled in the isolated run by "
              f"{'+'.join(spec['enable_env'])}): {spec['why']}")

    print()
    if fails:
        print("\n".join(fails))
        print()
        print(f"== ESO seed contract: {len(fails)} unsatisfiable reference(s) ==")
        return 1
    print("== ESO seed contract: OK — every checked ExternalSecret reference is "
          "seeded by BOTH delivery paths ==")
    return 0


if __name__ == "__main__":
    sys.exit(main())
