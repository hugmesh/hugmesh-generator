"""The Studio release is built on GitHub-hosted runners and signed there.

Operator rule (2026-10-21): every published download is BUILT ON GITHUB RUNNERS BY
GITHUB ACTIONS AND SIGNED THERE. For ``.github/workflows/studio-release.yml`` that means:

* no job can be moved onto the self-hosted runner (no ``RUNS_ON*`` variable, no label);
* only the ``publish`` job may write, and it alone gets ``id-token`` and
  ``attestations``;
* SHA256SUMS is cosign-signed keyless, every published file gets a build-provenance
  attestation, and both happen BEFORE the release exists, so a signing failure leaves
  no unsigned release;
* Authenticode signing of the MSI is optional and runs only when its secret is set;
* the release notes carry verify commands whose identity is the one cosign signs with;
* the site is told with a ``releases-updated`` repository_dispatch, skipped (green) when
  ``SITE_DISPATCH_TOKEN`` is not set, and a ``::warning::`` carrying GitHub's message,
  never a red run, when GitHub answers anything but 204 or cannot be reached (the
  release is already published by then).

Several tests run the workflow's own ``run:`` scripts with fake tools, so they test what
GitHub would execute, not a copy of it.

The version in every fixture is ``__version__``, read from the tree, never a literal.
"Cut a Studio release" runs this file AFTER ``release_version.py bump``, so the fixtures
name the tag that is about to be published. A literal here was hand-edited repeatedly
in November 2026 (0.3.0-beta.1 -> 0.4.0-beta.2, and the forged-identity case with it);
test_studio_beta_version.py's ``test_guards_hold_after_a_bump`` runs this file after a
simulated bump to the next MINOR and MAJOR, so a literal that only works on today's
version (as ``replace("0.4.0", "0x4x0")`` did) is red there before it is red in a cut.
"""
from __future__ import annotations

import http.server
import json
import os
import re
import shutil
import socket
import subprocess
import threading

import pytest
import yaml

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
WORKFLOW = os.path.join(GENERATOR_DIR, ".github", "workflows", "studio-release.yml")
WIN_LOCK = os.path.join(STUDIO_ROOT, "packaging", "wix", "windows-build-requirements.txt")
LINUX_REQS = os.path.join(STUDIO_ROOT, "packaging", "linux-build-requirements.txt")
MACOS_SCRIPT = os.path.join(STUDIO_ROOT, "packaging", "build-macos-app.sh")

REPO = "hugmesh/hugmesh-generator"


def _current_version() -> str:
    with open(os.path.join(STUDIO_ROOT, "hugmesh_studio", "__init__.py"), encoding="utf-8") as handle:
        return re.search(r'(?m)^__version__ = "([^"]+)"', handle.read()).group(1)


VERSION = _current_version()
TAG = f"studio-v{VERSION}"
IDENTITY = f"https://github.com/{REPO}/.github/workflows/studio-release.yml@refs/tags/{TAG}"
ISSUER = "https://token.actions.githubusercontent.com"
HOSTED = {"ubuntu-latest", "ubuntu-24.04", "ubuntu-24.04-arm", "windows-latest",
          "macos-15", "macos-15-intel"}
FLATPAK_ARCHES = ("x86_64", "aarch64")
#: The two macOS build jobs: job name -> (hosted runner, the arch its .dmg is built for).
#: macos-15 is Apple silicon and macos-15-intel is Intel, the same two images the
#: `macos` job of studio-tests.yml proves build-macos-app.sh on.
MACOS_JOBS = {"macos": ("macos-15", "arm64"), "macos-intel": ("macos-15-intel", "x86_64")}
DMGS = [f"hugmesh-studio-{VERSION}-macos-{arch}.dmg" for _runner, arch in MACOS_JOBS.values()]
BUILD_JOBS = {"msi", "linux", "flatpak", "flatpak-aarch64", *MACOS_JOBS}


def _text() -> str:
    with open(WORKFLOW, encoding="utf-8") as handle:
        return handle.read()


def _jobs() -> dict:
    return yaml.safe_load(_text())["jobs"]


def _step(job: str, name: str) -> dict:
    steps = _jobs()[job]["steps"]
    hits = [s for s in steps if s.get("name") == name]
    assert len(hits) == 1, f"{job}: expected one step named {name!r}, found {len(hits)}"
    return hits[0]


def _index(job: str, predicate) -> int:
    steps = _jobs()[job]["steps"]
    hits = [i for i, s in enumerate(steps) if predicate(s)]
    assert len(hits) == 1, hits
    return hits[0]


def _run_bash(script: str, env: dict, cwd) -> subprocess.CompletedProcess:
    # GitHub runs a `run:` block as `bash -e {0}` (plus pipefail when shell: bash is set).
    return subprocess.run(["bash", "-e", "-c", script], env=env, cwd=cwd,
                          capture_output=True, text=True)


# ── runners and permissions ────────────────────────────────────────────────────────
def test_every_job_runs_on_a_github_hosted_runner():
    for name, job in _jobs().items():
        assert job["runs-on"] in HOSTED, f"job {name} runs on {job['runs-on']!r}"
    text = _text()
    assert "self-hosted" not in re.sub(r"(?m)#.*$", "", text).replace(
        "--deny-self-hosted-runners", ""), "a job can reach the self-hosted runner"
    assert not re.search(r"vars\.RUNS_ON", text), (
        "a RUNS_ON* variable can move a build or the signing onto the self-hosted runner")


def test_only_publish_writes_and_only_publish_can_sign():
    workflow = yaml.safe_load(_text())
    assert workflow["permissions"] == {"contents": "read"}
    jobs = workflow["jobs"]
    assert jobs["publish"]["permissions"] == {
        "contents": "write", "id-token": "write", "attestations": "write"}
    for name, job in jobs.items():
        if name != "publish":
            assert "permissions" not in job, f"build job {name} must stay read-only"


def test_no_other_workflow_can_sign():
    """Over EVERY workflow file: a job that can mint a signing identity (id-token) or
    store attestations is one of the three release workflows' publish jobs and nothing
    else (Studio, the mesh-node image, and the hugmesh-akkoma image, whose
    akkoma-release.yml is mesh-node-release.yml with the names swapped). The cut workflow in particular writes contents and actions only: it creates
    the tag and starts the publishing run, it never signs."""
    workflows = os.path.join(GENERATOR_DIR, ".github", "workflows")
    allowed = {("studio-release.yml", "publish"), ("mesh-node-release.yml", "image"),
               ("akkoma-release.yml", "image")}
    seen = set()
    for name in sorted(os.listdir(workflows)):
        if not name.endswith((".yml", ".yaml")):
            continue
        with open(os.path.join(workflows, name), encoding="utf-8") as handle:
            doc = yaml.safe_load(handle)
        top = doc.get("permissions") or {}
        assert not isinstance(top, dict) or not ({"id-token", "attestations"} & set(top)), (
            f"{name}: workflow-level id-token/attestations")
        assert top != "write-all", name
        for job, spec in (doc.get("jobs") or {}).items():
            perms = spec.get("permissions") or {}
            if perms == "write-all" or (isinstance(perms, dict) and {"id-token", "attestations"} & set(perms)):
                seen.add((name, job))
    assert seen == allowed, seen
    cut = os.path.join(workflows, "studio-release-cut.yml")
    with open(cut, encoding="utf-8") as handle:
        cut_doc = yaml.safe_load(handle)
    assert cut_doc["permissions"] == {"contents": "read"}
    assert "permissions" not in cut_doc["jobs"]["preflight"]
    assert cut_doc["jobs"]["cut"]["permissions"] == {"contents": "write", "actions": "write"}


# ── signing order and coverage ─────────────────────────────────────────────────────
def test_sums_are_signed_and_every_file_attested_before_the_release_exists():
    steps = _jobs()["publish"]["steps"]
    sums = _index("publish", lambda s: s.get("name") == "Write SHA256SUMS")
    cosign = _index("publish", lambda s: "cosign sign-blob" in s.get("run", ""))
    attest = _index("publish", lambda s: s.get("uses", "").startswith("actions/attest-build-provenance@"))
    meta = _index("publish", lambda s: s.get("name") == "Generate releases.json for the documentation site")
    release = _index("publish", lambda s: s.get("uses", "").startswith("softprops/action-gh-release@"))
    assert sums < cosign < attest < release, (sums, cosign, attest, release)
    assert meta < attest, "releases.json is published, so it must be attested too"
    assert steps[attest]["with"]["subject-path"] == "release/*"
    run = steps[cosign]["run"]
    assert "cosign sign-blob --yes --bundle SHA256SUMS.sigstore.json SHA256SUMS" in run
    # The job checks its own signature against the identity the notes publish.
    assert "cosign verify-blob --bundle SHA256SUMS.sigstore.json" in run
    assert '--certificate-identity "$IDENTITY"' in run
    assert steps[cosign]["env"]["IDENTITY"] == (
        "https://github.com/${{ github.repository }}/.github/workflows/studio-release.yml@${{ github.ref }}")
    assert f"--certificate-oidc-issuer {ISSUER}" in run
    installer = next(s for s in steps if s.get("uses", "").startswith("sigstore/cosign-installer@"))
    assert installer["with"]["cosign-release"].startswith("v2."), "the notes promise cosign 2.x syntax"


def test_signing_actions_are_pinned_to_a_commit():
    # A moved tag on a signing action would change what signs the release.
    text = _text()
    for action in ("actions/attest-build-provenance", "sigstore/cosign-installer", "anchore/sbom-action"):
        uses = re.findall(r"uses: %s@(\S+)" % re.escape(action), text)
        assert uses, action
        for ref in uses:
            assert re.fullmatch(r"[0-9a-f]{40}", ref), f"{action}@{ref} is not a commit SHA"


def test_every_action_is_pinned_to_a_commit_with_its_tag_as_a_comment():
    # The publish job holds contents/id-token/attestations write and signs what the
    # build jobs uploaded, so a moved tag on ANY action in this file (the release
    # action, checkout, the artifact up/download pair) could change what is signed or
    # published. Each pin carries the tag it was resolved from, for the next bump.
    uses = re.findall(r"(?m)^\s*(?:-\s+)?uses:\s*(\S+)(.*)$", _text())
    assert len(uses) >= 10, uses
    for ref, rest in uses:
        action, _, sha = ref.partition("@")
        assert re.fullmatch(r"[0-9a-f]{40}", sha), f"{ref} is not pinned to a commit SHA"
        assert re.fullmatch(r"\s+#\s+v\d+(\.\d+)*\s*", rest), (
            f"{action} pin has no '# vX.Y.Z' comment naming its tag: {rest!r}")
    publish = [s["uses"] for s in _jobs()["publish"]["steps"] if "uses" in s]
    assert any(u.startswith("softprops/action-gh-release@") for u in publish)


def test_publish_checkout_does_not_keep_the_write_token_on_disk():
    checkout = next(s for s in _jobs()["publish"]["steps"]
                    if s.get("uses", "").startswith("actions/checkout@"))
    assert checkout.get("with", {}).get("persist-credentials") is False


def test_release_uploads_every_signed_file_and_stays_a_prerelease():
    release = next(s for s in _jobs()["publish"]["steps"]
                   if s.get("uses", "").startswith("softprops/action-gh-release@"))
    files = release["with"]["files"].split()
    for want in ("release/*.msi", "release/*.flatpak", "release/*.tar.gz", "release/*.dmg",
                 "release/*.spdx.json", "release/SHA256SUMS", "release/SHA256SUMS.sigstore.json", "release/releases.json"):
        assert want in files, want
    assert release["with"]["body_path"] == "release-notes.md"
    assert release["with"]["prerelease"] == "${{ contains(env.VERSION, '-') }}"
    assert release["with"]["make_latest"] == "${{ contains(env.VERSION, '-') && 'false' || 'true' }}"


def test_publish_needs_every_build_and_collect_requires_every_installer(tmp_path):
    assert set(_jobs()["publish"]["needs"]) == {"version", *BUILD_JOBS}
    script = _step("publish", "Collect the installers")["run"]
    art = tmp_path / "artifacts"
    (art / "msi").mkdir(parents=True)
    (art / "flatpak").mkdir()
    (art / "msi" / f"hugmesh-studio-{VERSION}-x64.msi").write_bytes(b"msi")
    (art / "flatpak" / f"hugmesh-studio-{VERSION}-x86_64.flatpak").write_bytes(b"fp")
    env = {"PATH": "/usr/bin:/bin", "VERSION": VERSION}
    proc = _run_bash(script, env, tmp_path)
    assert proc.returncode != 0 and f"hugmesh-studio-{VERSION}-aarch64.flatpak is missing" in proc.stdout, proc
    # The aarch64 bundle arrives in its own artifact directory (upload name flatpak-aarch64).
    (art / "flatpak-aarch64").mkdir()
    (art / "flatpak-aarch64" / f"hugmesh-studio-{VERSION}-aarch64.flatpak").write_bytes(b"fp-arm")
    proc = _run_bash(script, env, tmp_path)
    assert proc.returncode != 0 and "linux-x86_64.tar.gz is missing" in proc.stdout, proc
    (art / "linux").mkdir()
    (art / "linux" / f"hugmesh-studio-{VERSION}-linux-x86_64.tar.gz").write_bytes(b"tgz")
    # Each .dmg arrives in its own artifact directory; one missing stops the publish,
    # and so does the other.
    for (_runner, arch), dmg in zip(MACOS_JOBS.values(), DMGS):
        proc = _run_bash(script, env, tmp_path)
        assert proc.returncode != 0 and f"release/{dmg} is missing" in proc.stdout, (dmg, proc)
        (art / f"macos-{arch}").mkdir()
        (art / f"macos-{arch}" / dmg).write_bytes(b"dmg")
        # The checksum file next to it is not an installer and is not collected.
        (art / f"macos-{arch}" / f"{dmg}.sha256").write_text("x  " + dmg)
    proc = _run_bash(script, env, tmp_path)
    assert proc.returncode == 0, (proc.stdout, proc.stderr)
    collected = sorted(f.name for f in (tmp_path / "release").iterdir())
    assert collected == sorted([f"hugmesh-studio-{VERSION}-x64.msi",
                                f"hugmesh-studio-{VERSION}-x86_64.flatpak",
                                f"hugmesh-studio-{VERSION}-aarch64.flatpak",
                                f"hugmesh-studio-{VERSION}-linux-x86_64.tar.gz", *DMGS]), collected


def test_sha256sums_lists_installers_and_sboms_and_tolerates_a_missing_sbom(tmp_path):
    script = _step("publish", "Write SHA256SUMS")["run"]
    rel = tmp_path / "release"
    rel.mkdir()
    for name in (f"hugmesh-studio-{VERSION}-x64.msi", f"hugmesh-studio-{VERSION}-x86_64.flatpak",
                 f"hugmesh-studio-{VERSION}-aarch64.flatpak",
                 f"hugmesh-studio-{VERSION}-linux-x86_64.tar.gz", *DMGS):
        (rel / name).write_bytes(name.encode())
    proc = _run_bash(script, {"PATH": "/usr/bin:/bin"}, rel)
    assert proc.returncode == 0, (proc.stdout, proc.stderr)
    lines = (rel / "SHA256SUMS").read_text().splitlines()
    assert len(lines) == 6, lines
    # Both Flatpaks are in the signed list: the aarch64 bundle is verified like the rest.
    for arch in FLATPAK_ARCHES:
        assert any(l.endswith(f"  hugmesh-studio-{VERSION}-{arch}.flatpak") for l in lines), (arch, lines)
    # And both .dmg files: cosign signs this list, so a .dmg missing from it is unsigned.
    for dmg in DMGS:
        assert any(l.endswith(f"  {dmg}") for l in lines), (dmg, lines)
    (rel / f"hugmesh-studio-{VERSION}-linux-x86_64.spdx.json").write_text("{}")
    proc = _run_bash(script, {"PATH": "/usr/bin:/bin"}, rel)
    lines = (rel / "SHA256SUMS").read_text().splitlines()
    assert len(lines) == 7 and any(l.endswith(".spdx.json") for l in lines), lines


# ── Linux tarball ──────────────────────────────────────────────────────────────────
def test_linux_job_freezes_smoke_tests_and_packs_a_tarball():
    job = _jobs()["linux"]
    runs = "\n".join(s.get("run", "") for s in job["steps"])
    assert "pyinstaller --noconfirm --clean packaging/hugmesh-studio.spec" in runs
    assert "./dist/hugmesh-studio/hugmesh-studio --print-specs" in runs
    assert 'name="hugmesh-studio-${VERSION}-linux-x86_64"' in runs
    assert "gzip -n" in runs and "--sort=name" in runs
    assert "HUGMESH_STUDIO_ICON" not in json.dumps(job)
    upload = next(s for s in job["steps"] if s.get("uses", "").startswith("actions/upload-artifact@"))
    assert upload["with"]["name"] == "linux"
    assert "studio/hugmesh-studio-*-linux-x86_64.tar.gz" in upload["with"]["path"]


def _pins(path: str) -> dict:
    out = {}
    for line in open(path, encoding="utf-8"):
        m = re.match(r"^([A-Za-z0-9._-]+)==([^\s\\]+)", line)
        if m:
            out[m.group(1).lower()] = m.group(2)
    return out


def test_linux_pins_are_the_windows_lock_minus_windows_only_packages():
    win, linux = _pins(WIN_LOCK), _pins(LINUX_REQS)
    assert linux, "linux-build-requirements.txt pins nothing"
    assert set(win) - set(linux) == {"pefile", "pywin32-ctypes", "pillow"}, set(win) - set(linux)
    for name, version in linux.items():
        assert win[name] == version, f"{name}: linux {version} != windows {win[name]}"


def test_msi_job_installs_the_hash_locked_file():
    run = _step("msi", "Install the hash-locked build dependencies")["run"]
    assert "--require-hashes --only-binary=:all: -r studio/packaging/wix/windows-build-requirements.txt" in run
    assert "pyinstaller pillow" not in _text(), "the unpinned install is back"


# ── Authenticode (optional) ────────────────────────────────────────────────────────
def test_authenticode_is_gated_on_its_secret_and_signs_before_the_checksum():
    job = _jobs()["msi"]
    names = [s.get("name") for s in job["steps"]]
    detect = _step("msi", "Authenticode — is a signing certificate configured?")
    assert detect["env"]["PFX_B64"] == "${{ secrets.STUDIO_AUTHENTICODE_PFX_BASE64 }}"
    assert job["outputs"]["authenticode"] == "${{ steps.authenticode.outputs.enabled }}"
    for name in ("Authenticode — sign the executable", "Authenticode — sign the MSI"):
        step = _step("msi", name)
        assert step["if"] == "steps.authenticode.outputs.enabled == 'true'", name
        assert "signtool" in step["run"] and "/tr $env:TIMESTAMP_URL" in step["run"]
    assert (names.index("Freeze with PyInstaller") < names.index("Authenticode — sign the executable")
            < names.index("Build the MSI") < names.index("Authenticode — sign the MSI")
            < names.index("Checksum"))
    assert _step("msi", "Authenticode — sign the MSI")["env"]["TARGET"] == "hugmesh-studio-${{ env.VERSION }}-x64.msi"
    # Both executables the spec freezes on Windows: the console twin ships in the MSI too.
    assert _step("msi", "Authenticode — sign the executable")["env"]["TARGETS"].split(";") == [
        r"dist\hugmesh-studio\hugmesh-studio.exe", r"dist\hugmesh-studio\hugmesh-studio-cli.exe"]


# ── release notes and releases.json, by running the workflow's own scripts ────────
@pytest.mark.parametrize("signed", ["true", "false"])
def test_release_notes_carry_verify_commands_with_the_signing_identity(tmp_path, signed):
    script = _step("publish", "Write the release notes")["run"]
    env = {"PATH": "/usr/bin:/bin", "VERSION": VERSION, "GITHUB_REPOSITORY": REPO,
           "AUTHENTICODE": signed}
    proc = _run_bash(script, env, tmp_path)
    assert proc.returncode == 0, proc.stderr
    notes = (tmp_path / "release-notes.md").read_text()
    assert f"--certificate-identity {IDENTITY} \\" in notes
    assert f"--certificate-oidc-issuer {ISSUER}" in notes
    assert f"--signer-workflow {REPO}/.github/workflows/studio-release.yml \\" in notes
    assert f"--source-ref refs/tags/{TAG} \\" in notes
    assert "--deny-self-hosted-runners" in notes
    assert ("not code-signed" in notes) == (signed == "false")
    # Both Flatpaks are named, each with its install line; the aarch64 one is not a
    # footnote to the x86_64 paragraph.
    for arch in FLATPAK_ARCHES:
        assert f"`hugmesh-studio-{VERSION}-{arch}.flatpak`" in notes, arch
        assert f"flatpak install --user ./hugmesh-studio-{VERSION}-{arch}.flatpak" in notes, arch
    assert "**Linux aarch64**" in notes and "**Linux x86_64**" in notes
    # Both .dmg files, each named once for its kind of Mac, and the two things a Mac user
    # must know before downloading: the app is signed ad hoc and not notarized (Gatekeeper
    # refuses its first start), and building images on a Mac is EXPERIMENTAL.
    mac = next((p for p in notes.split("\n\n") if p.startswith("**macOS**")), "")
    assert mac, notes
    for dmg in DMGS:
        assert f"`{dmg}`" in mac, dmg
    assert "Apple silicon" in mac and "Intel" in mac
    assert "signed ad hoc" in mac and "not notarized" in mac and "Open Anyway" in mac
    assert "EXPERIMENTAL" in mac
    assert "macos-15" in mac and "macos-15-intel" in mac
    assert f"shasum -a 256 {DMGS[0]}" in notes, "no checksum line a Mac can run"
    assert ("(beta, pre-release)" in notes) == ("-" in VERSION)
    regexp = re.search(r"--certificate-identity-regexp '([^']+)'", notes).group(1)
    assert re.fullmatch(regexp, IDENTITY), regexp
    # Forgeries derived from the identity, never from a spelt version: a literal such as
    # replace("0.4.0", ...) silently stops forging anything once __version__ moves.
    for other in (IDENTITY + "0",  # a longer tag: X.Y.Z-beta.1 -> X.Y.Z-beta.10
                  IDENTITY.replace("studio-release.yml", "evil.yml"),
                  IDENTITY.replace("hugmesh-generator", "hugmesh-generatorX"),
                  IDENTITY.replace(VERSION, VERSION.replace(".", "x"))):  # "." must be literal
        assert other != IDENTITY, "a forgery that equals the identity proves nothing"
        assert not re.search(regexp, other), f"{regexp} also matches {other}"


@pytest.mark.parametrize("signed", ["true", "false"])
def test_releases_json_lists_every_package_and_the_signature_material(tmp_path, signed):
    script = _step("publish", "Generate releases.json for the documentation site")["run"]
    rel = tmp_path / "release"
    rel.mkdir()
    for name in (f"hugmesh-studio-{VERSION}-x64.msi", f"hugmesh-studio-{VERSION}-x86_64.flatpak",
                 f"hugmesh-studio-{VERSION}-aarch64.flatpak",
                 f"hugmesh-studio-{VERSION}-linux-x86_64.tar.gz", *DMGS,
                 f"hugmesh-studio-{VERSION}-linux-x86_64.spdx.json", "SHA256SUMS"):
        (rel / name).write_bytes(b"x" * 2048)
    env = {"PATH": "/usr/bin:/bin", "VERSION": VERSION, "GITHUB_REPOSITORY": REPO,
           "AUTHENTICODE": signed}
    proc = _run_bash(script, env, tmp_path)
    assert proc.returncode == 0, proc.stderr
    data = json.loads((rel / "releases.json").read_text())
    # The fields the site's page reads today are all still there.
    assert data["version"] == VERSION and data["notesUrl"].endswith(f"/releases/tag/{TAG}")
    kinds = {(i["platform"], i["kind"]) for i in data["installers"]}
    assert kinds == {("windows", "msi"), ("linux", "flatpak"), ("linux", "tarball"),
                     ("macos", "dmg")}
    assert len(data["installers"]) == 6, [i["file"] for i in data["installers"]]
    # One Flatpak per architecture, told apart by file, label and the "arch" field.
    flatpaks = {i["arch"]: i for i in data["installers"] if i["kind"] == "flatpak"}
    assert set(flatpaks) == set(FLATPAK_ARCHES), flatpaks
    for arch, item in flatpaks.items():
        assert item["file"] == f"hugmesh-studio-{VERSION}-{arch}.flatpak"
        assert item["label"] == f"Flatpak bundle ({arch})"
        assert arch in item["notes"]
    # One .dmg per kind of Mac, told apart the same way.
    dmgs = {i["arch"]: i for i in data["installers"] if i["kind"] == "dmg"}
    assert set(dmgs) == {arch for _runner, arch in MACOS_JOBS.values()}, dmgs
    assert dmgs["arm64"]["label"] == "macOS disk image (Apple silicon)"
    assert dmgs["x86_64"]["label"] == "macOS disk image (Intel)"
    for arch, item in dmgs.items():
        assert item["file"] == f"hugmesh-studio-{VERSION}-macos-{arch}.dmg"
        for words in ("signed ad hoc", "not notarized", "Open Anyway", "EXPERIMENTAL",
                      "brew install bash coreutils gnu-sed findutils grep make"):
            assert words in item["notes"], (arch, words, item["notes"])
        assert "sbom" not in item, "no macOS SBOM is written, so none may be linked"
    assert len({i["label"] for i in data["installers"]}) == 6, "two installers share a label"
    assert all("arch" not in i for i in data["installers"] if i["kind"] not in ("flatpak", "dmg"))
    for item in data["installers"]:
        assert set(item) >= {"platform", "kind", "label", "file", "url", "size", "sha256", "notes"}
        assert item["url"] == f"https://github.com/{REPO}/releases/download/{TAG}/{item['file']}"
    tarball = next(i for i in data["installers"] if i["kind"] == "tarball")
    assert tarball["sbom"].endswith("-linux-x86_64.spdx.json")
    msi = next(i for i in data["installers"] if i["kind"] == "msi")
    assert "sbom" not in msi, "the Windows SBOM was not written, so it must not be linked"
    assert ("SmartScreen will warn" in msi["notes"]) == (signed == "false")
    assert data["authenticode"] is (signed == "true")
    assert data["signature"]["identity"] == IDENTITY
    assert data["signature"]["issuer"] == ISSUER
    assert data["signature"]["bundle"].endswith("/SHA256SUMS.sigstore.json")
    assert data["checksums"].endswith("/SHA256SUMS")


def test_releases_json_refuses_a_flatpak_of_an_unknown_architecture(tmp_path):
    # The label is derived from the file name, so a bundle named for an architecture
    # nobody builds (a typo in a job, a stray file in an artifact) stops the publish
    # instead of being listed under an invented label.
    script = _step("publish", "Generate releases.json for the documentation site")["run"]
    rel = tmp_path / "release"
    rel.mkdir()
    (rel / f"hugmesh-studio-{VERSION}-riscv64.flatpak").write_bytes(b"x" * 2048)
    env = {"PATH": "/usr/bin:/bin", "VERSION": VERSION, "GITHUB_REPOSITORY": REPO,
           "AUTHENTICODE": "false"}
    proc = _run_bash(script, env, tmp_path)
    assert proc.returncode != 0 and "riscv64.flatpak: not a bundle of a known architecture" in proc.stderr, proc
    assert not (rel / "releases.json").exists()


@pytest.mark.parametrize("name", ["macos-universal2.dmg", "macos-aarch64.dmg", "x86_64.dmg"])
def test_releases_json_refuses_a_dmg_of_an_unknown_architecture(tmp_path, name):
    # The same rule for the .dmg: its label (Apple silicon or Intel) comes from the file
    # name, so a name neither macOS job writes is a stop, not an invented label.
    script = _step("publish", "Generate releases.json for the documentation site")["run"]
    rel = tmp_path / "release"
    rel.mkdir()
    (rel / f"hugmesh-studio-{VERSION}-{name}").write_bytes(b"x" * 2048)
    env = {"PATH": "/usr/bin:/bin", "VERSION": VERSION, "GITHUB_REPOSITORY": REPO,
           "AUTHENTICODE": "false"}
    proc = _run_bash(script, env, tmp_path)
    assert proc.returncode != 0 and f"{name}: not a disk image of a known architecture" in proc.stderr, proc
    assert not (rel / "releases.json").exists()


# ── the two macOS jobs ─────────────────────────────────────────────────────────────
def _upload(job: str) -> dict:
    return next(s for s in _jobs()[job]["steps"]
                if s.get("uses", "").startswith("actions/upload-artifact@"))


def test_macos_jobs_run_the_script_the_pull_request_job_proves():
    """Each .dmg is built by studio/packaging/build-macos-app.sh, the SAME script (and the
    same arguments) the `macos` job of studio-tests.yml runs on every Studio pull
    request, on the same two hosted images. Read-only like every build job, the
    version from the version job, the arch named literally so check_macos_bundle.py
    holds the frozen executable to it."""
    jobs = _jobs()
    tests = yaml.safe_load(open(os.path.join(GENERATOR_DIR, ".github", "workflows",
                                             "studio-tests.yml"), encoding="utf-8"))
    proven = {(i["runner"], i["arch"]) for i in tests["jobs"]["macos"]["strategy"]["matrix"]["include"]}
    assert set(MACOS_JOBS.values()) == proven, (MACOS_JOBS, proven)
    for job, (runner, arch) in MACOS_JOBS.items():
        spec = jobs[job]
        assert spec["runs-on"] == runner, job
        assert spec["needs"] == "version", job
        assert "permissions" not in spec, f"build job {job} must stay read-only"
        assert spec["env"] == {"VERSION": "${{ needs.version.outputs.version }}", "ARCH": arch}, job
        runs = "\n".join(s.get("run", "") for s in spec["steps"])
        assert "--only-binary=:all: -r studio/packaging/macos-build-requirements.txt" in runs
        assert "brew install bash coreutils gnu-sed findutils grep make" in runs
        build = _step(job, "Build, check and smoke-test the app, then pack the .dmg")["run"]
        for arg in ("bash studio/packaging/build-macos-app.sh", '--python "$RUNNER_TEMP/venv/bin/python"',
                    '--version "$VERSION"', '--arch "$ARCH"', '--dist "$RUNNER_TEMP/dist"',
                    "--gui-smoke", "--require-gnu"):
            assert arg in build, (job, arg)
        assert "--no-dmg" not in build
        names = [s.get("name") for s in spec["steps"]]
        assert names.index("The runner must really be the job's arch") < names.index(
            "Build, check and smoke-test the app, then pack the .dmg")
        # The artifact (macos-arm64, macos-x86_64) and the file are named from ARCH, so
        # the twins share every step and still upload under two names.
        upload = _upload(job)
        assert upload["with"]["name"] == "macos-${{ env.ARCH }}", job
        assert upload["with"]["if-no-files-found"] == "error"
        paths = upload["with"]["path"].splitlines()
        assert "${{ runner.temp }}/dist/hugmesh-studio-*-macos-${{ env.ARCH }}.dmg" in paths, paths
        assert not any(p.endswith(".png") for p in paths), "the GUI screenshot is not a release file"


def test_the_two_macos_jobs_are_twins():
    # Only the runner and ARCH differ: one job's steps are the other's, so a fix to one
    # cannot silently miss the other.
    a, b = _jobs()["macos"], _jobs()["macos-intel"]
    assert a["steps"] == b["steps"]
    assert {k: v for k, v in a.items() if k not in ("runs-on", "env")} == \
        {k: v for k, v in b.items() if k not in ("runs-on", "env")}
    # Two artifacts of one name would make the second upload fail: ARCH tells them apart.
    assert a["env"]["ARCH"] != b["env"]["ARCH"]


def test_the_dmg_names_are_the_ones_the_build_script_writes():
    # build-macos-app.sh's dmg_name is the one source of the file name; the publish job's
    # list must be what it writes, or "Collect the installers" stops every release.
    proc = subprocess.run(["bash", "-c", 'source "$1"; for a in arm64 x86_64; do dmg_name "$2" "$a"; done',
                           "_", MACOS_SCRIPT, VERSION], capture_output=True, text=True)
    assert proc.returncode == 0, proc.stderr
    assert proc.stdout.split() == DMGS, proc.stdout
    collect = _step("publish", "Collect the installers")["run"]
    for arch in ("arm64", "x86_64"):
        assert f'"hugmesh-studio-$VERSION-macos-{arch}.dmg"' in collect, arch


def test_the_macos_arch_check_refuses_the_other_mac(tmp_path):
    """A mislabelled runner would build the other arch under this arch's name. The
    check runs `uname -m` (arm64 or x86_64 on a Mac) before anything is built."""
    bindir = tmp_path / "bin"
    bindir.mkdir()
    for job, (_runner, arch) in MACOS_JOBS.items():
        other = "x86_64" if arch == "arm64" else "arm64"
        script = _step(job, "The runner must really be the job's arch")["run"]
        env = {"PATH": f"{bindir}:/usr/bin:/bin", "ARCH": arch}
        (bindir / "uname").write_text(f"#!/bin/sh\necho {other}\n")
        (bindir / "uname").chmod(0o755)
        proc = _run_bash(script, env, tmp_path)
        assert proc.returncode != 0 and f"builds the {arch} .dmg but this runner is {other}" in proc.stdout, proc
        (bindir / "uname").write_text(f"#!/bin/sh\necho {arch}\n")
        proc = _run_bash(script, env, tmp_path)
        assert proc.returncode == 0, proc


# ── the aarch64 Flatpak job ────────────────────────────────────────────────────────
def test_flatpak_aarch64_job_is_the_x86_64_job_on_the_arm_runner():
    """The aarch64 bundle comes from a twin of the proven x86_64 job: the same manifest,
    the same flatpak-builder and build-bundle commands and the same runtime branch, on
    GitHub's hosted arm64 runner, read-only like every build job, and uploaded under
    its own artifact name so the publish job can collect both bundles."""
    jobs = _jobs()
    x86, arm = jobs["flatpak"], jobs["flatpak-aarch64"]
    assert arm["runs-on"] == "ubuntu-24.04-arm"
    assert "permissions" not in arm
    assert arm["env"]["ARCH"] == "aarch64"
    assert arm["needs"] == x86["needs"] == "version"

    def runs(job):
        return "\n".join(s.get("run", "") for s in job["steps"])
    for command in ("flatpak-builder --user --disable-rofiles-fuse --force-clean",
                    "--repo=repo build-dir org.hugmesh.ImageStudio.yml",
                    "flatpak install --user -y flathub org.kde.Platform//6.11 org.kde.Sdk//6.11",
                    "flatpak build-bundle --runtime-repo=https://dl.flathub.org/repo/flathub.flatpakrepo repo",
                    "desktop-file-validate org.hugmesh.ImageStudio.desktop",
                    "appstreamcli validate --no-net org.hugmesh.ImageStudio.metainfo.xml",
                    "--print-specs > specs.json"):
        assert command in runs(x86), command
        assert command in runs(arm), command
    # The bundle's name says aarch64, derived from the one ARCH variable.
    assert 'build-bundle --runtime-repo=https://dl.flathub.org/repo/flathub.flatpakrepo repo "hugmesh-studio-${VERSION}-${ARCH}.flatpak"' in runs(arm)
    assert "x86_64" not in runs(arm), "the aarch64 job names the other architecture somewhere"
    # The runner's architecture is checked before anything is built.
    names = [s.get("name") for s in arm["steps"]]
    assert names.index("The runner must really be aarch64") < names.index("Build the Flatpak")
    assert "flatpak --default-arch" in _step("flatpak-aarch64", "The runner must really be aarch64")["run"]
    # Qt is started inside the installed bundle: --print-specs never imports PySide6.
    qt = _step("flatpak-aarch64", "Smoke-test the bundle (Qt starts offscreen on the aarch64 wheels)")["run"]
    assert "QT_QPA_PLATFORM=offscreen" in qt and "--nofilesystem=host" in qt
    assert 'BINDING != "PySide6"' in qt and "platform.machine()" in qt
    assert names.index("Smoke-test the bundle (--print-specs, the Qt-free path)") < names.index(
        "Smoke-test the bundle (Qt starts offscreen on the aarch64 wheels)")
    upload = next(s for s in arm["steps"] if s.get("uses", "").startswith("actions/upload-artifact@"))
    assert upload["with"]["name"] == "flatpak-aarch64"
    assert "studio/packaging/flatpak/hugmesh-studio-*-aarch64.flatpak" in upload["with"]["path"]
    assert upload["with"]["if-no-files-found"] == "error"
    x86_upload = next(s for s in x86["steps"] if s.get("uses", "").startswith("actions/upload-artifact@"))
    assert x86_upload["with"]["name"] != upload["with"]["name"], "two artifacts of one name: the second upload fails"


def test_the_arch_check_and_the_qt_smoke_test_refuse_what_they_must(tmp_path):
    """Run the two aarch64-only steps with fake tools: the arch check stops on an x86_64
    runner, and the Qt step fails on a sandbox whose Python did not report qt-ok for
    aarch64 (a PyQt6 fallback, an x86_64 wheel, Qt not starting at all)."""
    bindir = tmp_path / "bin"
    bindir.mkdir()
    env = {"PATH": f"{bindir}:/usr/bin:/bin", "ARCH": "aarch64", "VERSION": VERSION}
    arch = _step("flatpak-aarch64", "The runner must really be aarch64")["run"]
    (bindir / "flatpak").write_text("#!/bin/sh\necho x86_64\n")
    (bindir / "flatpak").chmod(0o755)
    proc = _run_bash(arch, env, tmp_path)
    assert proc.returncode != 0 and "default arch on this runner is x86_64" in proc.stdout, proc
    (bindir / "flatpak").write_text("#!/bin/sh\necho aarch64\n")
    proc = _run_bash(arch, env, tmp_path)
    assert proc.returncode == 0, proc

    qt = _step("flatpak-aarch64", "Smoke-test the bundle (Qt starts offscreen on the aarch64 wheels)")["run"]
    for answer in ("", "qt-ok binding=PyQt6 qt=6.11.2 platform=offscreen machine=aarch64",
                   "qt-ok binding=PySide6 qt=6.11.2 platform=offscreen machine=x86_64",
                   "Traceback: ImportError: libQt6Core.so.6: wrong ELF class"):
        (bindir / "flatpak").write_text(f"#!/bin/sh\ncat >/dev/null\nprintf '%s\\n' '{answer}'\n")
        proc = _run_bash(qt, env, tmp_path)
        assert proc.returncode != 0, (answer, proc.stdout)
        assert "did not report qt-ok on aarch64" in proc.stdout, (answer, proc.stdout)
    good = "qt-ok binding=PySide6 qt=6.11.2 platform=offscreen machine=aarch64 grab=120x40"
    (bindir / "flatpak").write_text(f"#!/bin/sh\ncat >/dev/null\nprintf '%s\\n' '{good}'\n")
    proc = _run_bash(qt, env, tmp_path)
    assert proc.returncode == 0, proc


# ── site notification ──────────────────────────────────────────────────────────────
# The step runs AFTER the release is published, so nothing it hears back may turn the
# run red. On 2026-11-10 it did: `curl -fsS` turned GitHub's 403 for SITE_DISPATCH_TOKEN
# into exit 22, the published studio-v0.4.4-beta.1 run (42882326209) went red, and
# GitHub's reason was thrown away. These tests run the step's own script with the REAL
# curl against a loopback stand-in for api.github.com, so what is under test is curl's
# actual --fail / -o / -w behaviour, not a stub's idea of it.
DISPATCH_STEP = "Tell hugmesh.github.io to rebuild its downloads data"
SITE_REPO = "hugmesh/hugmesh.github.io"
SITE_TOKEN = "site-dispatch-test-token-0d1f"
REAL_CURL = shutil.which("curl")
GITHUB_403 = json.dumps({
    "message": "Resource not accessible by personal access token",
    "documentation_url": "https://docs.github.com/rest/repos/repos#create-a-repository-dispatch-event",
    "status": "403"})


@pytest.fixture
def fake_github():
    """start(status, body) -> (port, seen): a loopback server answering every POST."""
    servers = []

    def start(status: int, body: str = ""):
        seen = []
        payload = body.encode()

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                length = int(self.headers.get("Content-Length") or 0)
                seen.append({"path": self.path, "auth": self.headers.get("Authorization"),
                             "body": self.rfile.read(length)})
                self.send_response(status)
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, *args):
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        servers.append(server)
        return server.server_address[1], seen

    yield start
    for server in servers:
        server.shutdown()
        server.server_close()


def _closed_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def _dispatch_env(tmp_path, token: str, port: int = 0) -> dict:
    # `curl` on PATH logs its argv, rewrites https://api.github.com/ to the loopback port
    # and execs the real curl. Any other URL is refused, so no test can reach a network.
    assert REAL_CURL, "these tests need curl: they exercise its real --fail/-w behaviour"
    bindir = tmp_path / "bin"
    bindir.mkdir(exist_ok=True)
    curl = bindir / "curl"
    curl.write_text(
        "#!/bin/sh\n"
        'printf "%s\\n" "$@" > "$CURL_LOG"\n'
        "for a do\n"
        "  shift\n"
        '  case "$a" in\n'
        '    https://api.github.com/*) a="http://127.0.0.1:$SITE_PORT/${a#https://api.github.com/}" ;;\n'
        '    http://*|https://*) echo "test curl: refusing $a" >&2; exit 99 ;;\n'
        "  esac\n"
        '  set -- "$@" "$a"\n'
        "done\n"
        'exec "$REAL_CURL" "$@"\n')
    curl.chmod(0o755)
    return {"PATH": f"{bindir}:/usr/bin:/bin", "VERSION": VERSION, "GITHUB_REPOSITORY": REPO,
            "SITE_DISPATCH_TOKEN": token, "SITE_REPO": SITE_REPO,
            "CURL_LOG": str(tmp_path / "curl.log"), "REAL_CURL": REAL_CURL,
            "SITE_PORT": str(port)}


def _dispatch(tmp_path, token: str, port: int = 0) -> subprocess.CompletedProcess:
    step = _step("publish", DISPATCH_STEP)
    return _run_bash(step["run"], _dispatch_env(tmp_path, token, port), tmp_path)


def _one_warning(proc) -> str:
    warnings = [line for line in proc.stdout.splitlines() if line.startswith("::warning::")]
    assert len(warnings) == 1, proc.stdout
    return warnings[0]


def test_site_dispatch_is_skipped_green_without_its_secret(tmp_path):
    step = _step("publish", DISPATCH_STEP)
    assert step["env"]["SITE_DISPATCH_TOKEN"] == "${{ secrets.SITE_DISPATCH_TOKEN }}"
    proc = _dispatch(tmp_path, "")
    assert proc.returncode == 0, proc.stderr
    assert "::notice::SITE_DISPATCH_TOKEN is not set" in proc.stdout
    assert not (tmp_path / "curl.log").exists(), "curl ran without a token"


def test_site_dispatch_sends_releases_updated(tmp_path, fake_github):
    port, seen = fake_github(204)
    proc = _dispatch(tmp_path, SITE_TOKEN, port)
    assert proc.returncode == 0, proc.stderr
    assert f"sent releases-updated to {SITE_REPO}" in proc.stdout
    assert "::warning::" not in proc.stdout
    args = (tmp_path / "curl.log").read_text().splitlines()
    assert f"https://api.github.com/repos/{SITE_REPO}/dispatches" in args
    assert len(seen) == 1, seen
    assert seen[0]["path"] == f"/repos/{SITE_REPO}/dispatches"
    assert seen[0]["auth"] == f"Bearer {SITE_TOKEN}"
    body = json.loads(seen[0]["body"])
    assert body["event_type"] == "releases-updated"
    assert body["client_payload"] == {
        "source": REPO, "kind": "studio", "version": VERSION, "tag": TAG,
        "releases_json": f"https://github.com/{REPO}/releases/download/{TAG}/releases.json"}
    # Runs after the release, and also on a re-run whose release already exists.
    step = _step("publish", DISPATCH_STEP)
    steps = _jobs()["publish"]["steps"]
    assert steps[-1] is step or steps[-1] == step
    assert "if" not in step
    assert "continue-on-error" not in step, "green must come from the script, not be painted on"


@pytest.mark.parametrize("status, body, reason", [
    # The answer run 42882326209 got: a token GitHub will not let write to the site.
    (403, GITHUB_403, "Resource not accessible by personal access token"),
    (401, json.dumps({"message": "Bad credentials", "status": "401"}), "Bad credentials"),
    (404, json.dumps({"message": "Not Found", "status": "404"}), "Not Found"),
    # GitHub's text is folded onto one line: a newline would end the ::warning:: early.
    (422, json.dumps({"message": "Invalid request.\n\nFor 'links/0/schema', nil is not an object.",
                      "status": "422"}),
     "Invalid request. For 'links/0/schema', nil is not an object."),
    # Not JSON, and a % that a workflow command would otherwise read as an escape.
    (500, "<html>upstream\r\n50% unavailable</html>", "<html>upstream 50%25 unavailable</html>"),
    (502, "", "no response body"),
    # Only 204 counts as sent; dispatches never answers 200, so a 200 is not trusted.
    (200, "{}", "{}"),
], ids=["403-token-refused", "401-bad-credentials", "404-not-visible", "422-multiline",
        "500-not-json", "502-empty", "200-not-204"])
def test_a_refused_dispatch_is_a_warning_and_the_published_release_stays_green(
        tmp_path, fake_github, status, body, reason):
    port, seen = fake_github(status, body)
    proc = _dispatch(tmp_path, SITE_TOKEN, port)
    assert len(seen) == 1, "the dispatch never reached the stand-in for api.github.com"
    assert proc.returncode == 0, f"HTTP {status} turned a published release red: {proc.stderr}"
    warning = _one_warning(proc)
    assert f"was not accepted (HTTP {status}): {reason}. " in warning, warning
    assert "The release is published and unaffected." in warning
    assert f"gh workflow run pages.yml --repo {SITE_REPO}" in warning
    assert "sent releases-updated" not in proc.stdout
    assert SITE_TOKEN not in proc.stdout + proc.stderr, "the token was printed"


def test_an_unreachable_api_is_a_warning_and_the_published_release_stays_green(tmp_path):
    proc = _dispatch(tmp_path, SITE_TOKEN, _closed_port())
    assert proc.returncode == 0, f"no connection turned a published release red: {proc.stderr}"
    warning = _one_warning(proc)
    # curl exit 7 is "failed to connect"; it reports http_code 000.
    assert "was not accepted (HTTP 000): curl exit 7" in warning, warning
    assert f"gh workflow run pages.yml --repo {SITE_REPO}" in warning
    assert "sent releases-updated" not in proc.stdout


# ── which packages carry the generator tree (the "nothing to clone" claim) ──────────
SEED_STEP = "Record whether the bundle carries the generator it placed"
FLATPAK_JOBS = {"flatpak": "x86_64", "flatpak-aarch64": "aarch64"}


def _all_installers(rel):
    names = [f"hugmesh-studio-{VERSION}-x64.msi", f"hugmesh-studio-{VERSION}-x86_64.flatpak",
             f"hugmesh-studio-{VERSION}-aarch64.flatpak",
             f"hugmesh-studio-{VERSION}-linux-x86_64.tar.gz", *DMGS]
    for name in names:
        (rel / name).write_bytes(b"x" * 2048)
    return names


def _self_check(placed_path="/home/runner/.local/share/hugmesh-studio/generator", **change):
    report = {"generator_dir": placed_path, "in_flatpak": True, "problems": [],
              "seed": {"dir": "/app/share/hugmesh-studio", "version": VERSION,
                       "commit": "0" * 40, "files": 3302},
              "placed": {"path": placed_path, "action": "seeded", "error": ""}}
    report.update(change)
    return report


def _seed_fact(job, tmp_path, report):
    """Run the job's own seed-fact step against a self-check report; return what it wrote
    to GITHUB_OUTPUT and the process."""
    step = _step(job, SEED_STEP)
    work = tmp_path / job
    work.mkdir(exist_ok=True)
    if report is not None:
        (work / "self-check.json").write_text(
            report if isinstance(report, str) else json.dumps(report))
    elif (work / "self-check.json").exists():
        (work / "self-check.json").unlink()
    out = work / "github_output"
    out.write_text("")
    env = {"PATH": "/usr/bin:/bin", "VERSION": VERSION, "GITHUB_OUTPUT": str(out),
           **({"ARCH": _jobs()[job]["env"]["ARCH"]} if "ARCH" in _jobs()[job].get("env", {}) else {})}
    proc = _run_bash(step["run"], env, work)
    return out.read_text(), proc


@pytest.mark.parametrize("job", sorted(FLATPAK_JOBS))
def test_each_flatpak_job_records_the_seed_only_from_its_own_self_check(tmp_path, job):
    """The site and the notes stop telling a user to clone only for a file whose OWN
    installed self-check placed the bundled tree and checked that tree. Never from the
    kind: a Flatpak whose report says anything less is recorded as not carrying it."""
    arch = FLATPAK_JOBS[job]
    name = f"hugmesh-studio-{VERSION}-{arch}.flatpak"
    steps = [s.get("name") for s in _jobs()[job]["steps"]]
    assert steps.index(SEED_STEP) == steps.index(
        "Smoke-test the bundle (--self-check, the generator tree it carries)") + 1
    step = _step(job, SEED_STEP)
    assert step["id"] == "seed" and step["working-directory"] == "studio/packaging/flatpak"
    assert _jobs()[job]["outputs"]["generator_seed"] == "${{ steps.seed.outputs.generator_seed }}"

    written, proc = _seed_fact(job, tmp_path, _self_check())
    assert proc.returncode == 0, proc.stderr
    assert written == f"generator_seed={name}\n", written

    refused = {
        "no seed in the bundle": _self_check(seed=None),
        "placing failed": _self_check(placed={"path": "", "action": "", "error": "disk full"}),
        # The same path as the tree checked, so only the error itself can refuse it.
        "placed with an error": _self_check(placed={
            "path": _self_check()["generator_dir"], "action": "seeded", "error": "sha256 mismatch"}),
        "checked another tree": _self_check(generator_dir="/home/runner/work/hugmesh-generator"),
        "problems reported": _self_check(problems=["make foo is not defined"]),
        "not an object": "[1, 2]",
        "not JSON": "garbage",
        "no report at all": None,
    }
    for why, report in refused.items():
        written, proc = _seed_fact(job, tmp_path, report)
        assert proc.returncode == 0, (why, proc.stderr)
        assert written == "generator_seed=\n", (why, written)
        assert f"::warning::{name} is NOT recorded as carrying the generator" in proc.stdout, why


def test_the_two_seed_fact_steps_are_twins():
    x86 = _step("flatpak", SEED_STEP)["run"]
    arm = _step("flatpak-aarch64", SEED_STEP)["run"]
    assert x86.replace('"hugmesh-studio-${VERSION}-x86_64.flatpak"',
                       '"hugmesh-studio-${VERSION}-${ARCH}.flatpak"') == arm


def test_publish_reads_the_seed_facts_of_both_flatpak_jobs_only():
    seed = _jobs()["publish"]["env"]["GENERATOR_SEED"]
    assert seed.split() == ["${{", "needs.flatpak.outputs.generator_seed", "}}",
                            "${{", "needs.flatpak-aarch64.outputs.generator_seed", "}}"], seed
    # The MSI, the tarball and the .dmg carry no seed yet; their jobs must not claim one.
    for job in ("msi", "linux", *MACOS_JOBS):
        assert "generator_seed" not in (_jobs()[job].get("outputs") or {}), job


@pytest.mark.parametrize("seeded", ["both-flatpaks", "none"])
def test_releases_json_says_per_file_whether_it_carries_the_generator(tmp_path, seeded):
    script = _step("publish", "Generate releases.json for the documentation site")["run"]
    rel = tmp_path / "release"
    rel.mkdir()
    names = _all_installers(rel)
    flatpaks = [n for n in names if n.endswith(".flatpak")]
    env = {"PATH": "/usr/bin:/bin", "VERSION": VERSION, "GITHUB_REPOSITORY": REPO,
           "AUTHENTICODE": "false",
           # As the publish job's env renders it: an empty output leaves a lone space.
           "GENERATOR_SEED": " ".join(flatpaks) if seeded == "both-flatpaks" else " "}
    proc = _run_bash(script, env, tmp_path)
    assert proc.returncode == 0, proc.stderr
    data = json.loads((rel / "releases.json").read_text())
    for item in data["installers"]:
        carries = seeded == "both-flatpaks" and item["kind"] == "flatpak"
        assert item["generatorSeed"] is carries, item
        assert "Point it at a hugmesh-generator checkout" not in item["notes"]
        if carries:
            assert "nothing to clone" in item["notes"], item["notes"]
            assert "clone" not in item["notes"].replace("nothing to clone", ""), item["notes"]
        else:
            assert "does not include the hugmesh-generator build scripts yet" in item["notes"].lower(), item
            assert "folder you cloned hugmesh-generator into" in item["notes"], item["notes"]


def test_releases_json_without_seed_facts_claims_nothing(tmp_path):
    # An older caller (or a hand run) with no GENERATOR_SEED at all: every file says false.
    script = _step("publish", "Generate releases.json for the documentation site")["run"]
    rel = tmp_path / "release"
    rel.mkdir()
    _all_installers(rel)
    env = {"PATH": "/usr/bin:/bin", "VERSION": VERSION, "GITHUB_REPOSITORY": REPO,
           "AUTHENTICODE": "false"}
    proc = _run_bash(script, env, tmp_path)
    assert proc.returncode == 0, proc.stderr
    data = json.loads((rel / "releases.json").read_text())
    assert [i["generatorSeed"] for i in data["installers"]] == [False] * 6


@pytest.mark.parametrize("seeded", ["both-flatpaks", "none"])
def test_release_notes_say_per_file_whether_a_clone_is_needed(tmp_path, seeded):
    script = _step("publish", "Write the release notes")["run"]
    flatpaks = [f"hugmesh-studio-{VERSION}-{arch}.flatpak" for arch in FLATPAK_ARCHES]
    env = {"PATH": "/usr/bin:/bin", "VERSION": VERSION, "GITHUB_REPOSITORY": REPO,
           "AUTHENTICODE": "false",
           "GENERATOR_SEED": " ".join(flatpaks) if seeded == "both-flatpaks" else " "}
    proc = _run_bash(script, env, tmp_path)
    assert proc.returncode == 0, proc.stderr
    notes = (tmp_path / "release-notes.md").read_text()
    assert "point it at one on first run" not in notes
    with_line = next((l for l in notes.splitlines() if "nothing to clone" in l), "")
    without_line = next((l for l in notes.splitlines() if "do not include" in l), "")
    others = [f"hugmesh-studio-{VERSION}-x64.msi", f"hugmesh-studio-{VERSION}-linux-x86_64.tar.gz",
              *DMGS]
    if seeded == "both-flatpaks":
        for name in flatpaks:
            assert f"`{name}`" in with_line and f"`{name}`" not in without_line, name
        for name in others:
            assert f"`{name}`" in without_line and f"`{name}`" not in with_line, name
    else:
        assert with_line == "", with_line
        for name in flatpaks + others:
            assert f"`{name}`" in without_line, name
    assert "git clone https://github.com/hugmesh/hugmesh-generator" in without_line
