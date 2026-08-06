#!/usr/bin/env python3
"""Nobody but harbor-provision may REPLACE secret/<brand>/harbor-robots.

Usage:
  harbor_robots_ownership.py <gen-cluster-secrets.sh> <harbor-provision-job.yaml> \
                             <specs/cluster dir> <vault-stub dir> <work dir>

Exit 0 = every writer of that Vault path either stays out of it or MERGES into
it. Exit 1 = at least one writer replaces a document it does not own.

WHY THIS GATE EXISTS
--------------------
`secret/<brand>/harbor-robots` has two writers and they disagreed about who owns
it.

  * manifests/harbor/harbor-provision-job.yaml is the only process that CAN own
    it: "a Harbor robot account's secret is returned EXACTLY ONCE at creation
    time and can never be re-read from Harbor afterwards ... this Job must
    capture the secret the moment Harbor mints it and WRITE it INTO Vault
    itself". It writes through vault_put_merge() — a read-merge-write, so the
    pull robot's write never disturbs the push robot's keys.

  * scripts/gen-cluster-secrets.sh did an UNCONDITIONAL
        vault kv put ${VAULT_KV_MOUNT}/${BASE}/harbor-robots \
            pull_name=... pull_secret=... push_name=... push_secret=...
    of two literal placeholder defaults (`REPLACE_WITH_GITLAB_DEPLOY_TOKEN`,
    `REPLACE_WITH_GITLAB_WRITE_REGISTRY_DEPLOY_TOKEN`). KV v2 `put` REPLACES the
    whole document.

The Job's idempotency is keyed on HARBOR, not on Vault — "if a robot with the
expected name already exists, SKIP creating it and leave whatever secret is
already in Vault untouched". So the damage was PERMANENT and SILENT: any second
run of the seeder (adding a service, rotating an unrelated credential,
re-provisioning) overwrote four real robot credentials with placeholder strings
and deleted the `project` key the seeder does not even know about, and the Job
could never repair it because the robots still existed in Harbor. All five
imagePullSecrets then rendered a syntactically perfect dockerconfigjson holding a
dead token: ESO reports Synced, the Secret exists, every pull 401s, and nothing
above the kubelet logs a word. That is the state a live cluster was found in.

A writer that CANNOT REPAIR must be the ONLY writer. Everyone else merges or
stays out. That is the invariant here, and it is asserted of BOTH writers.

HOW IT IS ASSERTED — BEHAVIOUR, NOT TEXT
----------------------------------------
Nothing below greps for `kv put`. The real gen-cluster-secrets.sh is EXECUTED
against a FAKE VAULT that implements KV v2 faithfully (`put` replaces, `patch`
merges, `patch` on a missing document fails as the real CLI does), pre-loaded
with the exact document harbor-provision writes; the assertion is on the
document afterwards. The Job's own reconcile.py is EXTRACTED from its ConfigMap
and EXECUTED against an in-process fake Harbor + fake Vault HTTP API; the
assertion is on the document afterwards there too.

The fake Vault's own fidelity is check [harness], and it runs first: if `put`
did not really destroy keys in it, every "the document survived" pass below
would be meaningless.

CHECKS
  [harness]        the fake KV v2 behaves like KV v2 (put replaces, patch
                   merges, patch on a virgin path fails) — the control on the
                   controls.
  [ran]            the seeder really took its ONLINE branch (a run that wrote
                   nothing would satisfy every no-clobber assertion vacuously).
  [path-live]      the document this gate protects is the one the cluster reads
                   (at least one rendered ExternalSecret remoteRef names it).
  [no-clobber]     a DEFAULT seeder run leaves a provision-Job-owned document
                   byte-identical.
  [no-placeholder] no value under harbor-robots is a REPLACE_WITH_* literal, in
                   any run.
  [override-merge] the manual escape hatch merges ONLY the half it was given:
                   the other robot's keys and `project` survive it.
  [override-live]  ...and it still actually delivers that half — including onto
                   a virgin path, where `kv patch` cannot apply.
  [patch-denied]   a REFUSED `kv patch` (a token without the patch capability on
                   a document that IS present) aborts the run instead of falling
                   back to a `put` — the same clobber down the error path.
  [probe-denied]   its twin: a REFUSED existence probe (a token that may update
                   but not read) aborts too. "The read failed" is not "there is
                   nothing there"; only a positive not-found authorizes a `put`.
  [job-merge]      the Job's own Vault write preserves keys it does not own.
  [job-no-rewrite] a Job re-run against an already-provisioned Harbor does not
                   overwrite the stored secret (it could only overwrite it with
                   garbage: Harbor will not re-reveal the real one).

Dependency-light on purpose: python3 + PyYAML. No cluster, no vault binary, no
network, no Harbor. Secret VALUES are compared, never printed.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import textwrap
import urllib.error
import urllib.request

import yaml

# The document harbor-provision leaves behind on a healthy cluster: exactly the
# keys manifests/harbor/harbor-provision-job.yaml's ensure_robot() writes
# (project + <pull|push>_name + <pull|push>_secret). The secret values are
# deliberately distinctive so a comparison failure names the key that moved.
JOB_OWNED_DOC = {
    "project": "hugmesh",
    "pull_name": "robot$hugmesh+pull",
    "pull_secret": "REAL-PULL-SECRET-MINTED-BY-HARBOR-ONCE",
    "push_name": "robot$hugmesh+push",
    "push_secret": "REAL-PUSH-SECRET-MINTED-BY-HARBOR-ONCE",
}

OVERRIDE_PULL_TOKEN = "operator-supplied-pull-override-token"
OVERRIDE_PUSH_TOKEN = "operator-supplied-push-override-token"
PLACEHOLDER = re.compile(r"^REPLACE_WITH")


class Result:
    def __init__(self):
        self.fails = []
        self.passes = 0

    def ok(self, check, msg):
        print(f"  PASS {check} {msg}")
        self.passes += 1

    def bad(self, check, msg):
        line = f"  FAIL {check} {msg}"
        print(line)
        self.fails.append(line)


# ── the fake Vault, driven through the real seeder ───────────────────────────

def doc_file(store, path):
    return os.path.join(store, path.replace("/", "%2F") + ".json")


def read_doc(store, path):
    f = doc_file(store, path)
    if not os.path.isfile(f):
        return None
    with open(f, encoding="utf-8") as fh:
        return json.load(fh)


def write_doc(store, path, doc):
    os.makedirs(store, exist_ok=True)
    with open(doc_file(store, path), "w", encoding="utf-8") as fh:
        json.dump(doc, fh, sort_keys=True)


def run_seeder(seeder, stub_dir, work, label, seed_doc, env_extra, robots_path=None):
    """Execute the REAL seeder against a fresh fake-Vault store.

    Returns (rc, store_dir, log_path, stdout_text). `seed_doc` (when given) is
    pre-loaded at `robots_path` so the assertion afterwards is about what the
    seeder did to a document that was ALREADY there — which is the whole
    scenario: a re-run of the seeder on a cluster harbor-provision has already
    provisioned.
    """
    run = os.path.join(work, "runs", label)
    store, log = os.path.join(run, "store"), os.path.join(run, "vault.log")
    shutil.rmtree(run, ignore_errors=True)
    os.makedirs(store)
    open(log, "w", encoding="utf-8").close()
    if seed_doc is not None and robots_path:
        write_doc(store, robots_path, seed_doc)
    env = dict(os.environ)
    env.update({
        "PATH": stub_dir + os.pathsep + os.environ["PATH"],
        "FAKE_VAULT_STORE": store,
        "FAKE_VAULT_LOG": log,
        "VAULT_ADDR": "https://vault.invalid:8200",
        "VAULT_TOKEN": "fake-token-for-the-harbor-robots-ownership-gate",
        # Point KEYS_FILE at nothing so a developer's real
        # keys-out/secrets/cluster-creds.json cannot influence the result.
        "KEYS_FILE": os.path.join(work, "no-such-keys-file.json"),
    })
    env.update(env_extra)
    proc = subprocess.run(["bash", seeder, "--out", os.path.join(run, "bundle")],
                          env=env, capture_output=True, text=True, timeout=300)
    return proc.returncode, store, log, proc.stdout + proc.stderr


def read_log(log):
    out = []
    with open(log, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                out.append(json.loads(line))
    return out


def kv_writes(argvs):
    """[(verb, path, {k: v})] for every kv put/patch the seeder invoked."""
    out = []
    for a in argvs:
        if len(a) >= 3 and a[0] == "kv" and a[1] in ("put", "patch"):
            out.append((a[1], a[2], dict(x.split("=", 1) for x in a[3:] if "=" in x)))
    return out


# ── the Job's own reconcile.py, executed against fakes ───────────────────────

def load_reconcile(job_yaml, tmpdir):
    """Exec the ConfigMap's reconcile.py up to (not including) its driver block.

    The only edit is to the four mounted-file PATHS, and each rewrite must
    actually apply — a drifted path is a hard error, never a silent skip that
    would leave this half of the gate testing nothing.
    """
    src = None
    with open(job_yaml, encoding="utf-8") as fh:
        for doc in yaml.safe_load_all(fh.read()):
            if isinstance(doc, dict) and doc.get("kind") == "ConfigMap":
                data = doc.get("data") or {}
                if "reconcile.py" in data:
                    src = data["reconcile.py"]
    if src is None:
        raise RuntimeError(f"{job_yaml} has no ConfigMap carrying reconcile.py")
    src = textwrap.dedent(src)

    for real, fake in (("/secrets/admin/", os.path.join(tmpdir, "admin") + "/"),
                       ("/secrets/vault/", os.path.join(tmpdir, "vault") + "/"),
                       ("/secrets/casdoor/", os.path.join(tmpdir, "casdoor") + "/"),
                       ("/ca/tls.crt", os.path.join(tmpdir, "ca", "tls.crt"))):
        if real not in src:
            raise RuntimeError(f"reconcile.py no longer mounts {real} — this gate's "
                               f"path rewrite is stale and would test a different script")
        src = src.replace(real, fake)

    marker = "\nwait_ready()\n"
    if marker not in src:
        raise RuntimeError("reconcile.py no longer ends with its `wait_ready()` driver "
                           "block — this gate cannot tell definitions from the run")
    src = src.split(marker, 1)[0]

    os.makedirs(os.path.join(tmpdir, "admin"), exist_ok=True)
    os.makedirs(os.path.join(tmpdir, "vault"), exist_ok=True)
    with open(os.path.join(tmpdir, "admin", "username"), "w", encoding="utf-8") as fh:
        fh.write("admin\n")
    with open(os.path.join(tmpdir, "admin", "password"), "w", encoding="utf-8") as fh:
        fh.write("fake-harbor-admin-password\n")
    with open(os.path.join(tmpdir, "vault", "token"), "w", encoding="utf-8") as fh:
        fh.write("fake-vault-token\n")

    ns = {"__name__": "harbor_provision_reconcile"}
    exec(compile(src, job_yaml + "::reconcile.py", "exec"), ns)   # noqa: S102
    return ns


class FakeCluster:
    """A minimal Harbor REST API + Vault KV v2 HTTP API, in process.

    Vault's POST /v1/<mount>/data/<path> REPLACES the document — faithfully, so
    that the Job's read-merge-write is what preserves keys, not this fake.
    """

    def __init__(self, vault_doc=None):
        self.robots = {}                       # full name -> secret
        self.projects = [{"project_id": 1, "project_name": "hugmesh"}]
        self.vault = dict(vault_doc or {})
        self.vault_present = vault_doc is not None
        self.vault_writes = 0
        self._minted = 0

    # -- responses ----------------------------------------------------------
    class _Resp:
        def __init__(self, status, payload):
            self.status = status
            self._body = b"" if payload is None else json.dumps(payload).encode()

        def read(self):
            return self._body

        def __enter__(self):
            return self

        def __exit__(self, *_):
            return False

    def urlopen(self, req, timeout=None, context=None):   # noqa: ARG002
        url = req.full_url if hasattr(req, "full_url") else str(req)
        method = getattr(req, "get_method", lambda: "GET")()
        body = json.loads(req.data.decode()) if getattr(req, "data", None) else None

        if "/v1/" in url and "/data/" in url:
            return self._vault(url, method, body)
        return self._harbor(url, method, body)

    # -- Harbor -------------------------------------------------------------
    def _harbor(self, url, method, body):
        if "/api/v2.0/ping" in url:
            return self._Resp(200, None)
        if "/api/v2.0/projects?" in url and method == "GET":
            return self._Resp(200, self.projects)
        if url.endswith("/robots") and method == "GET":
            return self._Resp(200, [{"name": n} for n in self.robots])
        if url.endswith("/api/v2.0/robots") and method == "POST":
            short = body["name"]
            full = f"robot$hugmesh+{short}"
            self._minted += 1
            secret = f"harbor-minted-{short}-{self._minted}"
            self.robots[full] = secret
            return self._Resp(201, {"id": self._minted, "name": full, "secret": secret})
        if url.endswith("/api/v2.0/projects") and method == "POST":
            return self._Resp(201, {"project_id": 1})
        if url.endswith("/api/v2.0/configurations"):
            return self._Resp(200, None)
        raise urllib.error.HTTPError(url, 404, "no fake route", {}, None)

    # -- Vault KV v2 --------------------------------------------------------
    def _vault(self, url, method, body):
        if method == "GET":
            if not self.vault_present:
                raise urllib.error.HTTPError(url, 404, "not found", {}, None)
            return self._Resp(200, {"data": {"data": dict(self.vault)}})
        self.vault = dict(body["data"])        # REPLACE, exactly like KV v2
        self.vault_present = True
        self.vault_writes += 1
        return self._Resp(200, {"data": {"version": self.vault_writes}})


def with_fake_cluster(fake, fn):
    real = urllib.request.urlopen
    urllib.request.urlopen = fake.urlopen
    try:
        return fn()
    finally:
        urllib.request.urlopen = real


# ── the checks ───────────────────────────────────────────────────────────────

def check_harness(res, stub_dir, work):
    """The fake KV v2 must behave like KV v2, or nothing below means anything."""
    store = os.path.join(work, "harness-store")
    log = os.path.join(work, "harness.log")
    shutil.rmtree(store, ignore_errors=True)
    os.makedirs(store)
    open(log, "w", encoding="utf-8").close()
    env = dict(os.environ)
    env.update({"PATH": stub_dir + os.pathsep + os.environ["PATH"],
                "FAKE_VAULT_STORE": store, "FAKE_VAULT_LOG": log})

    def vault(*args):
        return subprocess.run(["vault", *args], env=env, capture_output=True,
                              text=True, timeout=60)

    fails = 0
    vault("kv", "put", "probe/doc", "a=1", "keep=yes")
    vault("kv", "put", "probe/doc", "b=2")
    got = read_doc(store, "probe/doc")
    if got != {"b": "2"}:
        fails += 1
        res.bad("[harness]", f"the fake `vault kv put` did NOT replace the whole "
                             f"document (got {sorted(got or {})}). Every "
                             f"'the document survived' assertion below would then "
                             f"pass without the seeder having to behave.")
    vault("kv", "put", "probe/doc2", "a=1")
    vault("kv", "patch", "probe/doc2", "b=2")
    got = read_doc(store, "probe/doc2")
    if got != {"a": "1", "b": "2"}:
        fails += 1
        res.bad("[harness]", f"the fake `vault kv patch` did NOT merge (got "
                             f"{sorted(got or {})}) — [override-merge] would be "
                             f"testing the harness, not the seeder.")
    rc = vault("kv", "patch", "probe/virgin", "a=1")
    if rc.returncode == 0 or read_doc(store, "probe/virgin") is not None:
        fails += 1
        res.bad("[harness]", "the fake `vault kv patch` SUCCEEDED on a path with no "
                             "document. The real CLI cannot patch what does not "
                             "exist, so the seeder's `patch || put` fallback would "
                             "never be exercised here.")
    if fails == 0:
        res.ok("[harness]", "the fake Vault is a faithful KV v2: `put` replaces the "
                            "document, `patch` merges, `patch` on a virgin path fails")
    return fails == 0


def check_path_live(res, specs_cluster, base_rel):
    """The document this gate protects must be one the cluster actually reads."""
    hits = []
    for root, _dirs, files in os.walk(specs_cluster):
        for fn in sorted(files):
            if not fn.endswith((".yaml", ".yml")):
                continue
            path = os.path.join(root, fn)
            try:
                with open(path, encoding="utf-8") as fh:
                    blob = fh.read()
            except OSError:
                continue
            if "kind: ExternalSecret" not in blob:
                continue
            # (?![\w-]) rather than \b: `harbor-robots-renamed` ends the plain
            # word `harbor-robots` at a hyphen, which IS a \b — a rename would
            # have gone on matching and this anti-vacuity check would be the
            # vacuous one.
            if re.search(r"key:\s*%s(?![\w-])" % re.escape(base_rel), blob):
                hits.append(os.path.relpath(path, specs_cluster))
    if hits:
        res.ok("[path-live]", f"{len(hits)} ExternalSecret file(s) read "
                              f"'{base_rel}' ({', '.join(hits)}) — the document this "
                              f"gate protects is the one the cluster consumes")
        return True
    res.bad("[path-live]", f"NO ExternalSecret under {os.path.relpath(specs_cluster)} "
                           f"reads '{base_rel}' any more. Either the path moved (and "
                           f"this whole gate is now guarding a document nothing "
                           f"consumes) or the consumers were deleted — either way "
                           f"every check below would be protecting nothing.")
    return False


def main():
    if len(sys.argv) != 6:
        print(__doc__)
        return 2
    seeder, job_yaml, specs_cluster, stub_dir, work = sys.argv[1:]
    res = Result()

    os.makedirs(work, exist_ok=True)
    print("== harbor-robots ownership: only harbor-provision may replace that document ==")

    # ── [harness] first: it is the control on every control ──────────────────
    check_harness(res, stub_dir, work)

    # ── R1: a DEFAULT run over a document the Job already owns ───────────────
    # The path is DERIVED from the seeder's own writes (mount + brand base), so a
    # rename of either cannot leave this gate silently watching a dead path.
    rc, store, log, out = run_seeder(seeder, stub_dir, work, "default", None, {})
    if rc != 0:
        res.bad("[ran]", f"gen-cluster-secrets.sh exited {rc} on a default run:\n"
                         + textwrap.indent("\n".join(out.splitlines()[-15:]), "         "))
        print("\n".join(res.fails))
        return 1
    writes = kv_writes(read_log(log))
    other = [w for w in writes if not w[1].endswith("/harbor-robots")]
    if len(other) < 20:
        res.bad("[ran]", f"the default run recorded only {len(other)} `vault kv` "
                         f"write(s) to other paths — the seeder did not take its "
                         f"ONLINE branch, so 'it did not clobber harbor-robots' is "
                         f"true only because it wrote nothing at all.")
        print("\n".join(res.fails))
        return 1
    res.ok("[ran]", f"the real gen-cluster-secrets.sh took its ONLINE branch "
                    f"({len(other)} `vault kv` writes to other paths)")

    prefix = other[0][1].rsplit("/", 1)[0]              # "<mount>/<brand>"
    robots_path = f"{prefix}/harbor-robots"
    base_rel = robots_path.split("/", 1)[1]            # "<brand>/harbor-robots"
    check_path_live(res, specs_cluster, base_rel)

    # Re-run it, this time over a store that ALREADY holds the Job's document.
    rc, store, log, out = run_seeder(seeder, stub_dir, work, "default-preseeded",
                                     JOB_OWNED_DOC, {}, robots_path)
    after = read_doc(store, robots_path)
    if rc != 0:
        res.bad("[no-clobber]", f"gen-cluster-secrets.sh exited {rc} on the "
                                f"pre-seeded default run")
    elif after == JOB_OWNED_DOC:
        res.ok("[no-clobber]", f"a default run left {robots_path} byte-identical "
                               f"(all {len(JOB_OWNED_DOC)} Job-owned keys intact)")
    else:
        lost = sorted(k for k in JOB_OWNED_DOC if JOB_OWNED_DOC[k] != (after or {}).get(k))
        res.bad("[no-clobber]",
                f"a DEFAULT run of gen-cluster-secrets.sh changed {robots_path}: "
                f"key(s) {lost} no longer hold the value harbor-provision wrote. "
                f"That path is the Job's — Harbor reveals a robot secret once and "
                f"the Job skips on HARBOR state, so this damage is permanent and "
                f"every imagePullSecret sourced from it silently 401s. The seeder "
                f"must leave the path alone (or `kv patch` into it), never `kv put`.")

    # ── R2/R3: the escape hatch, one half at a time ──────────────────────────
    hatch = [
        ("pull", {"GITLAB_REGISTRY_TOKEN": OVERRIDE_PULL_TOKEN},
         "pull_secret", OVERRIDE_PULL_TOKEN, ("push_name", "push_secret", "project")),
        ("push", {"IMAGE_BUILDER_REGISTRY_TOKEN": OVERRIDE_PUSH_TOKEN},
         "push_secret", OVERRIDE_PUSH_TOKEN, ("pull_name", "pull_secret", "project")),
    ]
    merge_bad = live_bad = 0
    for label, env_extra, key, want, untouched in hatch:
        rc, store, log, out = run_seeder(seeder, stub_dir, work, f"override-{label}",
                                         JOB_OWNED_DOC, env_extra, robots_path)
        after = read_doc(store, robots_path) or {}
        if rc != 0:
            merge_bad += 1
            res.bad("[override-merge]", f"the {label} override run exited {rc}")
            continue
        if after.get(key) != want:
            live_bad += 1
            res.bad("[override-live]",
                    f"{env_extra and sorted(env_extra)[0]} was set, but "
                    f"{robots_path}.{key} does not carry it. The manual-override "
                    f"escape hatch is documented as the way to feed these "
                    f"ExternalSecrets without a live Harbor; if it silently does "
                    f"nothing, the no-clobber checks above pass for the wrong "
                    f"reason (a seeder that never writes cannot clobber).")
        stomped = sorted(k for k in untouched if after.get(k) != JOB_OWNED_DOC[k])
        if stomped:
            merge_bad += 1
            res.bad("[override-merge]",
                    f"the {label}-only override destroyed key(s) {stomped}, which "
                    f"it was not given and which harbor-provision owns. The escape "
                    f"hatch must MERGE its own half (`vault kv patch`), not replace "
                    f"the document.")
    # ...and onto a VIRGIN path, where `kv patch` cannot apply: the fallback must
    # still write only the supplied half, never a placeholder for the other one.
    rc, store, log, out = run_seeder(seeder, stub_dir, work, "override-virgin",
                                     None, {"GITLAB_REGISTRY_TOKEN": OVERRIDE_PULL_TOKEN},
                                     robots_path)
    virgin = read_doc(store, robots_path) or {}
    if virgin.get("pull_secret") != OVERRIDE_PULL_TOKEN:
        live_bad += 1
        res.bad("[override-live]",
                f"on a VIRGIN {robots_path} the override did not land at all "
                f"(`kv patch` cannot create a document; the seeder needs a `put` "
                f"fallback for exactly this case).")
    elif sorted(virgin) != ["pull_name", "pull_secret"]:
        merge_bad += 1
        res.bad("[override-merge]",
                f"on a virgin path the pull-only override wrote {sorted(virgin)} — "
                f"it must write ONLY the half it was given, or it reintroduces a "
                f"fabricated push credential for harbor-provision to collide with.")
    # ── [patch-denied]: a REFUSED merge must abort, never fall back to a put ──
    # `vault kv patch || vault kv put` reads as "merge, or create if absent", and
    # it is not: a patch is also refused when the token lacks the `patch`
    # capability on the path, and the fallback then REPLACES a document that was
    # there all along. Same clobber, one layer down.
    rc, store, log, out = run_seeder(
        seeder, stub_dir, work, "patch-denied", JOB_OWNED_DOC,
        {"GITLAB_REGISTRY_TOKEN": OVERRIDE_PULL_TOKEN, "FAKE_VAULT_DENY_PATCH": "1"},
        robots_path)
    denied = read_doc(store, robots_path)
    patch_bad = 0
    if denied != JOB_OWNED_DOC:
        patch_bad += 1
        lost = sorted(k for k in JOB_OWNED_DOC if JOB_OWNED_DOC[k] != (denied or {}).get(k))
        res.bad("[patch-denied]",
                f"with `kv patch` REFUSED (a token without the patch capability — "
                f"the document itself was present), the seeder still changed "
                f"key(s) {lost}. It fell back to a `kv put`, which replaces the "
                f"document: the same clobber, reached through the error path. The "
                f"verb must be chosen by whether a document EXISTS, not by "
                f"whether a write failed.")
    elif rc == 0:
        patch_bad += 1
        res.bad("[patch-denied]",
                f"`kv patch` was REFUSED and gen-cluster-secrets.sh still exited 0. "
                f"The operator's override was silently not applied; a provisioning "
                f"run that could not write what it was told to write must fail "
                f"loudly, or the next symptom is a 401 at pull time.")
    if patch_bad == 0:
        res.ok("[patch-denied]", f"a REFUSED `kv patch` aborts the run (rc={rc}) and "
                                 f"leaves {robots_path} untouched — no `put` fallback "
                                 f"turns a permission error into a clobber")

    # ── [probe-denied]: the twin. "the read failed" is not "nothing is there" ──
    # A token with update but no `read` on the path is an ordinary Vault policy.
    # A seeder that decides "absent, therefore `put`" from a failed existence
    # probe destroys the document on exactly that policy.
    rc, store, log, out = run_seeder(
        seeder, stub_dir, work, "probe-denied", JOB_OWNED_DOC,
        {"GITLAB_REGISTRY_TOKEN": OVERRIDE_PULL_TOKEN, "FAKE_VAULT_DENY_GET": "1"},
        robots_path)
    probed = read_doc(store, robots_path)
    probe_bad = 0
    if probed != JOB_OWNED_DOC:
        probe_bad += 1
        lost = sorted(k for k in JOB_OWNED_DOC if JOB_OWNED_DOC[k] != (probed or {}).get(k))
        res.bad("[probe-denied]",
                f"with the existence probe REFUSED (a token that may update but "
                f"not read this path — the document was present the whole time), "
                f"the seeder still changed key(s) {lost}. It read 'the probe "
                f"failed' as 'the path is empty' and wrote blind. Only a "
                f"POSITIVE not-found may authorize a `put` here.")
    elif rc == 0:
        probe_bad += 1
        res.bad("[probe-denied]",
                f"the existence probe was REFUSED and gen-cluster-secrets.sh still "
                f"exited 0 without applying the override — a provisioning run that "
                f"could not do what it was told must say so.")
    if probe_bad == 0:
        res.ok("[probe-denied]", f"a REFUSED existence probe aborts the run (rc={rc}) "
                                 f"and leaves {robots_path} untouched — only a "
                                 f"positive not-found authorizes a `put`")

    if merge_bad == 0:
        res.ok("[override-merge]", "the manual override merges only its own half: "
                                   "the other robot's keys and `project` survive it, "
                                   "on an existing document and on a virgin one")
    if live_bad == 0:
        res.ok("[override-live]", "the manual override still delivers the credential "
                                  "it was given (so the no-clobber passes above are "
                                  "not 'the seeder writes nothing, ever')")

    # ── [no-placeholder]: across every run, in the stored document ───────────
    placeholders = []
    for label in ("default-preseeded", "override-pull", "override-push",
                  "override-virgin", "patch-denied", "probe-denied"):
        doc = read_doc(os.path.join(work, "runs", label, "store"), robots_path) or {}
        for k, v in sorted(doc.items()):
            if PLACEHOLDER.match(str(v)):
                placeholders.append(f"{label}: {robots_path}.{k}")
    if placeholders:
        res.bad("[no-placeholder]",
                "a REPLACE_WITH_* literal reached the Vault document that backs "
                "every imagePullSecret: " + "; ".join(placeholders) +
                ". ESO renders it into a perfectly-shaped dockerconfigjson and "
                "reports Synced; the only symptom is a 401 at pull time.")
    else:
        res.ok("[no-placeholder]", f"no REPLACE_WITH_* literal reaches {robots_path} "
                                   f"in any of the 6 provisioning runs")

    # ── the OTHER writer: harbor-provision's own reconcile.py ────────────────
    try:
        recon = load_reconcile(job_yaml, os.path.join(work, "recon"))
    except Exception as exc:                                     # noqa: BLE001
        res.bad("[job-merge]", f"could not load reconcile.py out of "
                               f"{os.path.relpath(job_yaml)}: {exc}")
        res.bad("[job-no-rewrite]", "same — the Job half of this gate did not run, "
                                    "which is a failure and not a pass")
        print()
        print(f"== harbor-robots ownership: {res.passes} passed, "
              f"{len(res.fails)} failed ==")
        return 1

    # The push robot is already provisioned; the pull one is being minted now.
    pre = {"project": "hugmesh",
           "push_name": "robot$hugmesh+push",
           "push_secret": JOB_OWNED_DOC["push_secret"]}
    fake = FakeCluster(vault_doc=dict(pre))
    with_fake_cluster(fake, lambda: recon["ensure_robot"]("pull", "pull", "pull"))
    after_first = dict(fake.vault)
    if after_first.get("pull_secret") != fake.robots.get("robot$hugmesh+pull"):
        res.bad("[job-merge]", "the Job did not store the secret Harbor just minted "
                               "for the pull robot — the one moment that value is "
                               "ever visible is gone.")
    elif any(after_first.get(k) != v for k, v in pre.items()):
        lost = sorted(k for k, v in pre.items() if after_first.get(k) != v)
        res.bad("[job-merge]",
                f"harbor-provision's write of the PULL robot destroyed key(s) "
                f"{lost}, which belong to the push robot. Vault's KV-v2 write is a "
                f"REPLACE; the Job must keep read-merge-writing (vault_put_merge) "
                f"or the two robots overwrite each other on every provision.")
    else:
        res.ok("[job-merge]", "harbor-provision's own Vault write is a merge: minting "
                              "the pull robot left the push robot's keys and `project` "
                              "untouched")

    writes_before = fake.vault_writes
    with_fake_cluster(fake, lambda: recon["ensure_robot"]("pull", "pull", "pull"))
    if fake.vault != after_first:
        changed = sorted(k for k in set(fake.vault) | set(after_first)
                         if fake.vault.get(k) != after_first.get(k))
        res.bad("[job-no-rewrite]",
                f"a second harbor-provision run against a Harbor that ALREADY has "
                f"the robot rewrote key(s) {changed}. Harbor cannot re-reveal an "
                f"existing robot's secret, so anything written on a re-run is a "
                f"value no registry will accept — and ArgoCD re-runs this PostSync "
                f"hook on every sync.")
    else:
        res.ok("[job-no-rewrite]", f"a re-run against an already-provisioned Harbor "
                                   f"left the document untouched "
                                   f"({fake.vault_writes - writes_before} Vault writes)")

    print()
    if res.fails:
        print(f"== harbor-robots ownership: {res.passes} passed, "
              f"{len(res.fails)} failed ==")
        return 1
    print(f"== harbor-robots ownership: OK — {res.passes} checks, both writers "
          f"respect the document ==")
    return 0


if __name__ == "__main__":
    sys.exit(main())
