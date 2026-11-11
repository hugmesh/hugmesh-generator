#!/usr/bin/env python3
"""akkoma_image_pin.py ROOT — the hugmesh-akkoma pin, default and release-wiring checks.

Run by tests/scripts/test-akkoma-image-pin.sh (on the real tree, then on mutated
copies that must fail). Stdlib only. Prints one PASS/FAIL line per check, tagged, and
exits 1 if any check failed, 2 if the tree could not be read at all.

Why it exists. Upstream Akkoma publishes no container image and git.akkoma.dev does
not resolve, so every Akkoma ref in specs/cluster pointed at an image nobody could
pull. hugmesh-akkoma (images/akkoma/) is built from upstream source and published by
.github/workflows/akkoma-release.yml. Until its first release the refs carry a
placeholder digest, and Akkoma must stay out of every DEFAULT selection, or a default
mesh deploys a pod that cannot pull. These checks hold that line:

  [dead-host]  no git.akkoma.dev and no teslamint/akkoma (the local compose lane's
               unofficial image) anywhere under specs/cluster or images/akkoma.
  [refs]       every image ref under specs/cluster whose repository name contains
               "akkoma" is ghcr.io/hugmesh/hugmesh-akkoma[:tag]@sha256:<64 hex>.
  [sites]      the six known refs exist (akkoma.yaml x2, admin-sync-job.yaml,
               domainlock-sync-job.yaml, test-runner/akkoma-peer.yaml x2): a guard that
               finds no refs must not pass.
  [lockstep]   every ref carries the same digest.
  [placeholder] a repeated-character digest is the placeholder. It must be marked on
               its line ("PLACEHOLDER digest"), and while it is in place Akkoma must be
               OFF in every default source: the shared builder lib, both builders'
               OPTIONAL_SERVICES default, Studio's BUILTIN_DEFAULT_SERVICES, the
               registry's `default:`, the installed-services ConfigMap baseline, the
               seed OptionalService CR and the federation gate.sql baseline. A real
               digest must not carry the marker.
  [dockerfile] images/akkoma/Dockerfile pins both base images by digest, builds one
               40-hex upstream commit in every stage, ships no Erlang cookie and runs
               as a non-root user.
  [version]    images/akkoma/VERSION is MAJOR.MINOR.PATCH[-beta.N] and shares X.Y with
               clients/docker-mesh-node/VERSION (one release/X.Y per repository).
  [release-wf] akkoma-release.yml has no pull_request trigger, publishes only
               akkoma-v* tags with TAG_PREFIX=akkoma-v, boot-tests before it decides
               the tags, decides them in the step right before the push, and every
               security-relevant step body equals mesh-node-release.yml's after the
               artifact's names are swapped in.
  [pr-wf]      akkoma-image-ci.yml runs on pull_request only, with a read-only token,
               no registry login and no push.
"""
import os
import re
import sys

ROOT = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else ".")
FAILED = []


def ok(tag, msg):
    print("  PASS [%s] %s" % (tag, msg))


def fail(tag, msg):
    print("  FAIL [%s] %s" % (tag, msg))
    FAILED.append(tag)


def read(rel):
    path = os.path.join(ROOT, rel)
    with open(path, "rb") as fh:
        return fh.read().decode("utf-8", errors="replace")


def exists(rel):
    return os.path.isfile(os.path.join(ROOT, rel))


IMAGE = "ghcr.io/hugmesh/hugmesh-akkoma"
REF_RE = re.compile(r"^ghcr\.io/hugmesh/hugmesh-akkoma(:[A-Za-z0-9._-]+)?@(sha256:[0-9a-f]{64})$")
MARKER = "PLACEHOLDER digest"
SITES = {
    "specs/cluster/manifests/akkoma/akkoma.yaml": 2,
    "specs/cluster/manifests/akkoma/admin-sync-job.yaml": 1,
    "specs/cluster/manifests/akkoma/domainlock-sync-job.yaml": 1,
    "specs/cluster/manifests/test-runner/akkoma-peer.yaml": 2,
}
# `image: x`, `- image: x`, `newName: x` (kustomize), `--image=x` / `--image x`.
IMG_LINE = re.compile(r"""(?:\b(?:image|newName)\s*:\s*|--image[=\s]+)["']?([^\s"'#,}\]]+)""")


def is_placeholder(digest):
    return len(set(digest[len("sha256:"):])) < 2


def scan_files(top):
    for dirpath, dirnames, filenames in os.walk(os.path.join(ROOT, top)):
        dirnames.sort()
        for name in sorted(filenames):
            full = os.path.join(dirpath, name)
            if os.path.islink(full):
                continue
            with open(full, "rb") as fh:
                data = fh.read()
            # A NUL byte must not make a file invisible (GNU grep skips it as binary).
            yield os.path.relpath(full, ROOT), data.decode("utf-8", errors="replace")


# ── [dead-host] ──────────────────────────────────────────────────────────────
def check_dead_host():
    hits = []
    for top in ("specs/cluster", "images/akkoma"):
        if not os.path.isdir(os.path.join(ROOT, top)):
            fail("dead-host", "%s is missing; nothing to scan" % top)
            return
        for rel, text in scan_files(top):
            for n, line in enumerate(text.splitlines(), 1):
                low = line.lower()
                if "git.akkoma.dev" in low or "teslamint/akkoma" in low:
                    hits.append("%s:%d: %s" % (rel, n, line.strip()[:120]))
    if hits:
        fail("dead-host", "git.akkoma.dev (does not resolve) or teslamint/akkoma (unofficial; "
             "the local compose lane only) is named here: " + "; ".join(hits[:6]))
    else:
        ok("dead-host", "no git.akkoma.dev and no teslamint/akkoma under specs/cluster or images/akkoma")


# ── [refs] [sites] [lockstep] [placeholder] ──────────────────────────────────
def collect_refs():
    refs = []  # (rel, lineno, ref, line)
    for rel, text in scan_files("specs/cluster"):
        for n, line in enumerate(text.splitlines(), 1):
            if line.lstrip().startswith("#"):
                continue
            for m in IMG_LINE.finditer(line):
                ref = m.group(1)
                name = ref.split("@", 1)[0]
                last = name.rsplit("/", 1)[-1].split(":", 1)[0]
                if "akkoma" in last.lower():
                    refs.append((rel, n, ref, line))
    return refs


def default_sources():
    """(source, says_on: bool|None, detail). None = could not be read."""
    out = []

    def literal(rel, pattern, label):
        if not exists(rel):
            out.append((label, None, "%s is missing" % rel))
            return
        m = re.search(pattern, read(rel), re.M)
        if not m:
            out.append((label, None, "no match for %r in %s" % (pattern, rel)))
            return
        words = m.group(1).replace(",", " ").replace('"', " ").replace("'", " ").split()
        out.append((label, "akkoma" in words, "%s: %s" % (rel, m.group(0).strip())))

    literal("scripts/_optional-services-lib.sh", r'^_OPT_BUILTIN_DEFAULT_SERVICES="([^"]*)"',
            "builder lib _OPT_BUILTIN_DEFAULT_SERVICES")
    for b in ("build-x86-host-stage4.sh", "build-rpi5-stage4.sh"):
        literal(b, r'^OPTIONAL_SERVICES="\$\{OPTIONAL_SERVICES:-([^}"]*)\}"', "%s default" % b)
    literal("studio/hugmesh_studio/core/config.py", r"^BUILTIN_DEFAULT_SERVICES\s*=\s*\(([^)]*)\)",
            "Studio BUILTIN_DEFAULT_SERVICES")

    rel = "specs/cluster/optional-services.yaml"
    if exists(rel):
        lines = read(rel).splitlines()
        start = next((i for i, l in enumerate(lines) if re.match(r"^\s*- slug:\s*akkoma\s*$", l)), None)
        val = None
        if start is not None:
            for l in lines[start + 1:]:
                if re.match(r"^\s*- slug:", l):
                    break
                m = re.match(r"^\s*default:\s*(\S+)", l)
                if m:
                    val = m.group(1).strip("\"'").lower()
                    break
        if val is None:
            out.append(("registry default:", None, "no `default:` in the akkoma entry of %s" % rel))
        else:
            out.append(("registry default:", val in ("on", "true", "yes"), "%s: akkoma default: %s" % (rel, val)))
    else:
        out.append(("registry default:", None, "%s is missing" % rel))

    rel = "specs/cluster/manifests/policy/installed-services-configmap.yaml"
    literal(rel, r'^\s*akkoma:\s*"(true|false)"', "installed-services baseline")
    if out[-1][1] is not None:
        out[-1] = (out[-1][0], 'akkoma: "true"' in out[-1][2], out[-1][2])

    rel = "specs/cluster/manifests/optional-services-operator/seed-optionalservices.yaml"
    if exists(rel):
        docs = read(rel).split("\n---")
        val = None
        for d in docs:
            if re.search(r"^\s*slug:\s*akkoma\s*$", d, re.M):
                m = re.search(r"^\s*enabled:\s*(\S+)", d, re.M)
                val = m.group(1).lower() if m else None
        if val is None:
            out.append(("seed OptionalService", None, "no akkoma CR with `enabled:` in %s" % rel))
        else:
            out.append(("seed OptionalService", val == "true", "%s: akkoma enabled: %s" % (rel, val)))
    else:
        out.append(("seed OptionalService", None, "%s is missing" % rel))

    rel = "specs/cluster/manifests/federation-modules-gate/sql/gate.sql"
    if exists(rel):
        m = re.search(r"^UPDATE federation_modules SET enabled = (true|false) WHERE slug = 'mastodon';",
                      read(rel), re.M)
        if not m:
            out.append(("federation gate.sql", None, "no mastodon row in %s" % rel))
        else:
            out.append(("federation gate.sql", m.group(1) == "true", "%s: %s" % (rel, m.group(0))))
    else:
        out.append(("federation gate.sql", None, "%s is missing" % rel))
    return out


def check_refs_and_defaults():
    refs = collect_refs()
    bad = [r for r in refs if not REF_RE.match(r[2])]
    if not refs:
        fail("refs", "found NO Akkoma image ref under specs/cluster; this guard cannot be vacuous")
    elif bad:
        fail("refs", "Akkoma image ref(s) that are not %s[:tag]@sha256:<64 hex>: %s" % (
            IMAGE, "; ".join("%s:%d %s" % (r[0], r[1], r[2]) for r in bad)))
    else:
        ok("refs", "%d Akkoma image ref(s), each %s@sha256:<64 hex>" % (len(refs), IMAGE))

    counts = {}
    for r in refs:
        counts[r[0]] = counts.get(r[0], 0) + 1
    short = ["%s (%d of %d)" % (f, counts.get(f, 0), n) for f, n in SITES.items() if counts.get(f, 0) < n]
    if short:
        fail("sites", "known Akkoma ref sites are missing refs: " + "; ".join(short))
    else:
        ok("sites", "all %d known sites carry their refs" % sum(SITES.values()))

    digests = sorted({REF_RE.match(r[2]).group(2) for r in refs if REF_RE.match(r[2])})
    if len(digests) > 1:
        fail("lockstep", "Akkoma refs carry %d different digests: %s" % (len(digests), ", ".join(digests)))
        return
    if not digests:
        fail("lockstep", "no well-formed Akkoma digest to compare")
        return
    ok("lockstep", "every Akkoma ref carries %s" % digests[0])

    placeholder = is_placeholder(digests[0])
    unmarked = [r for r in refs if placeholder and MARKER not in r[3]]
    stale = [r for r in refs if not placeholder and MARKER in r[3]]
    if unmarked:
        fail("placeholder", "the placeholder digest is not marked %r on: %s" % (
            MARKER, "; ".join("%s:%d" % (r[0], r[1]) for r in unmarked)))
    elif stale:
        fail("placeholder", "a real digest still carries the %r marker on: %s" % (
            MARKER, "; ".join("%s:%d" % (r[0], r[1]) for r in stale)))
    else:
        ok("placeholder", "the digest is %s and its marking agrees" % ("the PLACEHOLDER" if placeholder else "real"))

    sources = default_sources()
    unreadable = [s for s in sources if s[1] is None]
    for s in unreadable:
        fail("defaults", "cannot read %s: %s" % (s[0], s[2]))
    on = [s for s in sources if s[1]]
    if placeholder and on:
        fail("defaults", "Akkoma is DEFAULT-ON while its digest is the placeholder (the image is not "
             "yet published; a default mesh would sit in ImagePullBackOff): " + "; ".join(s[2] for s in on))
    elif not unreadable:
        if placeholder:
            ok("defaults", "Akkoma is OFF in all %d default sources while the digest is the placeholder" % len(sources))
        else:
            ok("defaults", "the digest is real, so Akkoma may be default-on (%d of %d sources say on)" % (len(on), len(sources)))


# ── [dockerfile] ─────────────────────────────────────────────────────────────
def check_dockerfile():
    rel = "images/akkoma/Dockerfile"
    if not exists(rel):
        fail("dockerfile", "%s is missing" % rel)
        return
    text = read(rel)
    lines = text.splitlines()
    problems = []
    args = {}
    for l in lines:
        m = re.match(r"^ARG\s+([A-Z_]+)=(.*)$", l.strip())
        if m:
            args.setdefault(m.group(1), set()).add(m.group(2).strip())
    for base in ("ELIXIR_IMAGE", "RUNTIME_IMAGE"):
        vals = args.get(base, set())
        if len(vals) != 1:
            problems.append("ARG %s has %d defaults" % (base, len(vals)))
            continue
        v = next(iter(vals))
        m = re.search(r"@(sha256:[0-9a-f]{64})$", v)
        if not m or is_placeholder(m.group(1)):
            problems.append("ARG %s=%s is not pinned by a real digest" % (base, v))
    froms = [l.split()[1] for l in lines if re.match(r"^FROM\s", l)]
    stages = {l.split()[-1] for l in lines if re.match(r"^FROM\s+\S+\s+AS\s+\S+", l, re.I)}
    for f in froms:
        if f not in ("${ELIXIR_IMAGE}", "${RUNTIME_IMAGE}") and f not in stages:
            problems.append("FROM %s is neither a pinned base ARG nor a stage" % f)
    commits = args.get("AKKOMA_COMMIT", set())
    if len(commits) != 1 or not re.fullmatch(r"[0-9a-f]{40}", next(iter(commits), "")):
        problems.append("AKKOMA_COMMIT is not one 40-hex commit id in every stage: %s" % sorted(commits))
    if len(args.get("AKKOMA_VERSION", set())) != 1:
        problems.append("AKKOMA_VERSION differs between stages: %s" % sorted(args.get("AKKOMA_VERSION", set())))
    if 'test "$(git rev-parse HEAD)" = "$AKKOMA_COMMIT"' not in text:
        problems.append("the fetched upstream commit is not checked against AKKOMA_COMMIT")
    if "rm -f /opt/akkoma/releases/COOKIE" not in text:
        problems.append("the build no longer deletes the baked Erlang cookie (releases/COOKIE)")
    users = [l.split(None, 1)[1].strip() for l in lines if re.match(r"^USER\s", l)]
    if not users or users[-1].split(":")[0] in ("0", "root"):
        problems.append("the final USER is %r, not a non-root user" % (users[-1] if users else None))
    if problems:
        fail("dockerfile", "; ".join(problems))
    else:
        ok("dockerfile", "bases pinned by digest, one upstream commit checked after fetch, no baked cookie, non-root USER %s" % users[-1])


# ── [version] ────────────────────────────────────────────────────────────────
def check_version():
    try:
        mine = read("images/akkoma/VERSION").strip()
        node = read("clients/docker-mesh-node/VERSION").strip()
    except OSError as e:
        fail("version", "cannot read a VERSION file: %s" % e)
        return
    vre = re.compile(r"^(\d+)\.(\d+)\.(\d+)(-beta\.[1-9]\d*)?$")
    a, b = vre.match(mine), vre.match(node)
    if not a:
        fail("version", "images/akkoma/VERSION %r is not MAJOR.MINOR.PATCH[-beta.N]" % mine)
    elif not b:
        fail("version", "clients/docker-mesh-node/VERSION %r is not MAJOR.MINOR.PATCH[-beta.N]" % node)
    elif a.group(1, 2) != b.group(1, 2):
        fail("version", "images/akkoma/VERSION %s is on line %s.%s but the mesh-node image is on %s.%s: "
             "hugmesh-generator has ONE release/X.Y branch, and a push there refuses a version on "
             "another line" % (mine, a.group(1), a.group(2), b.group(1), b.group(2)))
    else:
        ok("version", "images/akkoma/VERSION %s shares release line %s.%s with the mesh-node image" % (
            mine, a.group(1), a.group(2)))


# ── workflows ────────────────────────────────────────────────────────────────
def steps(text):
    """{step name: block text} for every `- name:` step in the file."""
    lines = text.split("\n")
    out = {}
    idx = [i for i, l in enumerate(lines) if re.match(r"^\s+- name:\s", l)]
    for k, i in enumerate(idx):
        indent = len(lines[i]) - len(lines[i].lstrip())
        end = len(lines)
        for j in range(i + 1, len(lines)):
            l = lines[j]
            if l.strip() and (len(l) - len(l.lstrip())) <= indent and not l.lstrip().startswith("#"):
                end = j
                break
        # drop trailing comment/blank lines: they describe the NEXT step
        while end > i + 1 and (not lines[end - 1].strip() or lines[end - 1].lstrip().startswith("#")):
            end -= 1
        name = lines[i].split("- name:", 1)[1].strip()
        out[name] = "\n".join(lines[i:end])
    return out


SWAP = [
    ("clients/docker-mesh-node/VERSION", "images/akkoma/VERSION"),
    ("mesh-node-release.yml", "akkoma-release.yml"),
    ("hugmesh-mesh-node", "hugmesh-akkoma"),
    ("mesh-node-v", "akkoma-v"),
]
PARITY_STEPS = [
    "Refuse to overwrite a published version",
    "Compute tags and labels",
    "Resolve the pushed image name and digest",
    "Install cosign",
    "Sign the image digest (cosign keyless, GitHub OIDC)",
    "Attest build provenance (pushed to the registry)",
    "Generate an SPDX SBOM of the pushed digest",
    "Attest the SBOM (pushed to the registry)",
    "Check every pushed tag resolves to the signed digest",
    "Write the verify commands to the job summary",
    "Self-test the release channel rules",
    "Read and check the version",
    "Log in to GHCR",
]


def on_block(text):
    lines = text.split("\n")
    start = next((i for i, l in enumerate(lines) if re.match(r"^['\"]?on['\"]?\s*:", l)), None)
    if start is None:
        return ""
    end = next((j for j in range(start + 1, len(lines)) if lines[j] and not lines[j][0].isspace()
                and not lines[j].startswith("#")), len(lines))
    return "\n".join(l for l in lines[start:end] if not l.lstrip().startswith("#"))


def check_release_workflow():
    rel, tpl = ".github/workflows/akkoma-release.yml", ".github/workflows/mesh-node-release.yml"
    if not exists(rel) or not exists(tpl):
        fail("release-wf", "%s or %s is missing" % (rel, tpl))
        return
    text, ttext = read(rel), read(tpl)
    problems = []
    on = on_block(text)
    if "pull_request" in on:
        problems.append("it has a pull_request trigger (a publishing workflow must never run on one)")
    if "tags: ['akkoma-v*']" not in on:
        problems.append("its tag trigger is not tags: ['akkoma-v*']")
    code = "\n".join(l for l in text.split("\n") if not l.lstrip().startswith("#"))
    if "mesh-node-v" in code or "hugmesh-mesh-node" in code:
        problems.append("it still names the mesh-node image or tag prefix outside comments")
    if code.count("TAG_PREFIX=akkoma-v") < 3:
        problems.append("fewer than 3 channel-script calls pass TAG_PREFIX=akkoma-v")
    if "hugmesh-release-channels: beta+stable" not in text:
        problems.append("the channel marker scripts/release.sh requires is missing")
    s, ts = steps(text), steps(ttext)
    order = list(s)
    need = ["Build the image (no push)", "Boot-test the image before pushing it",
            "Compute tags and labels", "Build and push image"]
    missing = [n for n in need if n not in s]
    if missing:
        problems.append("missing step(s): %s" % ", ".join(missing))
    else:
        pos = [order.index(n) for n in need]
        if pos != sorted(pos):
            problems.append("steps out of order: build -> boot-test -> compute tags -> push is required")
        if pos[3] != pos[2] + 1:
            problems.append("the tags are not decided in the step right before the push")
        if "push: false" not in s["Build the image (no push)"]:
            problems.append("the first build is not push: false")
        if "smoke-test.sh" not in s["Boot-test the image before pushing it"]:
            problems.append("the boot test does not run images/akkoma/smoke-test.sh")
    if "Check the upstream tag still names the pinned commit" not in s:
        problems.append("the version job does not check the upstream tag against the pinned commit")
    for name in PARITY_STEPS:
        if name not in ts:
            problems.append("template step %r vanished from mesh-node-release.yml" % name)
            continue
        want = ts[name]
        for a, b in SWAP:
            want = want.replace(a, b)
        if s.get(name) != want:
            problems.append("step %r differs from mesh-node-release.yml's (after the name swap)" % name)
    if problems:
        fail("release-wf", "; ".join(problems))
    else:
        ok("release-wf", "no PR trigger, akkoma-v* only, boot-test before tags, tags right before push, "
           "%d security steps equal to mesh-node-release.yml's" % len(PARITY_STEPS))


def check_pr_workflow():
    rel = ".github/workflows/akkoma-image-ci.yml"
    if not exists(rel):
        fail("pr-wf", "%s is missing" % rel)
        return
    text = read(rel)
    code = "\n".join(l for l in text.split("\n") if not l.lstrip().startswith("#"))
    on = on_block(text)
    problems = []
    if "pull_request:" not in on:
        problems.append("it does not run on pull_request")
    for word in ("push:", "pull_request_target", "workflow_dispatch", "schedule"):
        if word in on.replace("pull_request:", ""):
            problems.append("it has a %s trigger (PR build only)" % word.rstrip(":"))
    if not re.search(r"^permissions:\s*\n\s+contents:\s*read\s*$", code, re.M):
        problems.append("top-level permissions are not exactly contents: read")
    for bad in ("packages: write", "id-token: write", "docker/login-action", "push: true", "cosign"):
        if bad in code:
            problems.append("it contains %r" % bad)
    if "smoke-test.sh" not in code:
        problems.append("it does not boot-test the image")
    if problems:
        fail("pr-wf", "; ".join(problems))
    else:
        ok("pr-wf", "pull_request only, contents: read, no login, no push, boot-tested")


def main():
    if not os.path.isdir(os.path.join(ROOT, "specs/cluster")):
        print("FATAL: %s has no specs/cluster" % ROOT)
        return 2
    check_dead_host()
    check_refs_and_defaults()
    check_dockerfile()
    check_version()
    check_release_workflow()
    check_pr_workflow()
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
