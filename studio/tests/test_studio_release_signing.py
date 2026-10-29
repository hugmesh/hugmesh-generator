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
  ``SITE_DISPATCH_TOKEN`` is not set.

Several tests run the workflow's own ``run:`` scripts with fake tools, so they test what
GitHub would execute, not a copy of it.
"""
from __future__ import annotations

import json
import os
import re
import subprocess

import pytest
import yaml

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
WORKFLOW = os.path.join(GENERATOR_DIR, ".github", "workflows", "studio-release.yml")
WIN_LOCK = os.path.join(STUDIO_ROOT, "packaging", "wix", "windows-build-requirements.txt")
LINUX_REQS = os.path.join(STUDIO_ROOT, "packaging", "linux-build-requirements.txt")

REPO = "hugmesh/hugmesh-generator"
VERSION = "0.3.0-beta.1"
TAG = f"studio-v{VERSION}"
IDENTITY = f"https://github.com/{REPO}/.github/workflows/studio-release.yml@refs/tags/{TAG}"
ISSUER = "https://token.actions.githubusercontent.com"
HOSTED = {"ubuntu-latest", "ubuntu-24.04", "ubuntu-24.04-arm", "windows-latest"}
FLATPAK_ARCHES = ("x86_64", "aarch64")


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
    store attestations is one of the two release workflows' publish jobs and nothing
    else. The cut workflow in particular writes contents and actions only: it creates
    the tag and starts the publishing run, it never signs."""
    workflows = os.path.join(GENERATOR_DIR, ".github", "workflows")
    allowed = {("studio-release.yml", "publish"), ("mesh-node-release.yml", "image")}
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
    for want in ("release/*.msi", "release/*.flatpak", "release/*.tar.gz", "release/*.spdx.json",
                 "release/SHA256SUMS", "release/SHA256SUMS.sigstore.json", "release/releases.json"):
        assert want in files, want
    assert release["with"]["body_path"] == "release-notes.md"
    assert release["with"]["prerelease"] == "${{ contains(env.VERSION, '-') }}"
    assert release["with"]["make_latest"] == "${{ contains(env.VERSION, '-') && 'false' || 'true' }}"


def test_publish_needs_all_four_builds_and_collect_requires_all_four_files(tmp_path):
    assert set(_jobs()["publish"]["needs"]) == {"version", "msi", "linux", "flatpak", "flatpak-aarch64"}
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
    proc = _run_bash(script, env, tmp_path)
    assert proc.returncode == 0, (proc.stdout, proc.stderr)
    collected = sorted(f.name for f in (tmp_path / "release").iterdir())
    assert collected == sorted([f"hugmesh-studio-{VERSION}-x64.msi",
                                f"hugmesh-studio-{VERSION}-x86_64.flatpak",
                                f"hugmesh-studio-{VERSION}-aarch64.flatpak",
                                f"hugmesh-studio-{VERSION}-linux-x86_64.tar.gz"]), collected


def test_sha256sums_lists_installers_and_sboms_and_tolerates_a_missing_sbom(tmp_path):
    script = _step("publish", "Write SHA256SUMS")["run"]
    rel = tmp_path / "release"
    rel.mkdir()
    for name in (f"hugmesh-studio-{VERSION}-x64.msi", f"hugmesh-studio-{VERSION}-x86_64.flatpak",
                 f"hugmesh-studio-{VERSION}-aarch64.flatpak",
                 f"hugmesh-studio-{VERSION}-linux-x86_64.tar.gz"):
        (rel / name).write_bytes(name.encode())
    proc = _run_bash(script, {"PATH": "/usr/bin:/bin"}, rel)
    assert proc.returncode == 0, (proc.stdout, proc.stderr)
    lines = (rel / "SHA256SUMS").read_text().splitlines()
    assert len(lines) == 4, lines
    # Both Flatpaks are in the signed list: the aarch64 bundle is verified like the rest.
    for arch in FLATPAK_ARCHES:
        assert any(l.endswith(f"  hugmesh-studio-{VERSION}-{arch}.flatpak") for l in lines), (arch, lines)
    (rel / f"hugmesh-studio-{VERSION}-linux-x86_64.spdx.json").write_text("{}")
    proc = _run_bash(script, {"PATH": "/usr/bin:/bin"}, rel)
    lines = (rel / "SHA256SUMS").read_text().splitlines()
    assert len(lines) == 5 and any(l.endswith(".spdx.json") for l in lines), lines


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
    assert "(beta, pre-release)" in notes
    regexp = re.search(r"--certificate-identity-regexp '([^']+)'", notes).group(1)
    assert re.fullmatch(regexp, IDENTITY), regexp
    for other in (IDENTITY + "0",  # studio-v0.3.0-beta.10
                  IDENTITY.replace("studio-release.yml", "evil.yml"),
                  IDENTITY.replace("hugmesh-generator", "hugmesh-generatorX"),
                  IDENTITY.replace("0.3.0", "0x3x0")):
        assert not re.search(regexp, other), f"{regexp} also matches {other}"


@pytest.mark.parametrize("signed", ["true", "false"])
def test_releases_json_lists_all_four_packages_and_the_signature_material(tmp_path, signed):
    script = _step("publish", "Generate releases.json for the documentation site")["run"]
    rel = tmp_path / "release"
    rel.mkdir()
    for name in (f"hugmesh-studio-{VERSION}-x64.msi", f"hugmesh-studio-{VERSION}-x86_64.flatpak",
                 f"hugmesh-studio-{VERSION}-aarch64.flatpak",
                 f"hugmesh-studio-{VERSION}-linux-x86_64.tar.gz",
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
    assert kinds == {("windows", "msi"), ("linux", "flatpak"), ("linux", "tarball")}
    assert len(data["installers"]) == 4, [i["file"] for i in data["installers"]]
    # One Flatpak per architecture, told apart by file, label and the "arch" field.
    flatpaks = {i["arch"]: i for i in data["installers"] if i["kind"] == "flatpak"}
    assert set(flatpaks) == set(FLATPAK_ARCHES), flatpaks
    for arch, item in flatpaks.items():
        assert item["file"] == f"hugmesh-studio-{VERSION}-{arch}.flatpak"
        assert item["label"] == f"Flatpak bundle ({arch})"
        assert arch in item["notes"]
    assert len({i["label"] for i in data["installers"]}) == 4, "two installers share a label"
    assert all("arch" not in i for i in data["installers"] if i["kind"] != "flatpak")
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
def _dispatch_env(tmp_path, token: str) -> dict:
    bindir = tmp_path / "bin"
    bindir.mkdir(exist_ok=True)
    log = tmp_path / "curl.log"
    curl = bindir / "curl"
    curl.write_text('#!/bin/sh\nfor a in "$@"; do printf "%s\\n" "$a"; done > "$CURL_LOG"\n')
    curl.chmod(0o755)
    return {"PATH": f"{bindir}:/usr/bin:/bin", "VERSION": VERSION, "GITHUB_REPOSITORY": REPO,
            "SITE_DISPATCH_TOKEN": token, "SITE_REPO": "hugmesh/hugmesh.github.io",
            "CURL_LOG": str(log)}


def test_site_dispatch_is_skipped_green_without_its_secret(tmp_path):
    step = _step("publish", "Tell hugmesh.github.io to rebuild its downloads data")
    assert step["env"]["SITE_DISPATCH_TOKEN"] == "${{ secrets.SITE_DISPATCH_TOKEN }}"
    proc = _run_bash(step["run"], _dispatch_env(tmp_path, ""), tmp_path)
    assert proc.returncode == 0, proc.stderr
    assert "::notice::SITE_DISPATCH_TOKEN is not set" in proc.stdout
    assert not (tmp_path / "curl.log").exists(), "curl ran without a token"


def test_site_dispatch_sends_releases_updated(tmp_path):
    step = _step("publish", "Tell hugmesh.github.io to rebuild its downloads data")
    proc = _run_bash(step["run"], _dispatch_env(tmp_path, "tok"), tmp_path)
    assert proc.returncode == 0, proc.stderr
    args = (tmp_path / "curl.log").read_text().splitlines()
    assert "https://api.github.com/repos/hugmesh/hugmesh.github.io/dispatches" in args
    assert "Authorization: Bearer tok" in args
    body = json.loads(args[args.index("-d") + 1])
    assert body["event_type"] == "releases-updated"
    assert body["client_payload"] == {
        "source": REPO, "kind": "studio", "version": VERSION, "tag": TAG,
        "releases_json": f"https://github.com/{REPO}/releases/download/{TAG}/releases.json"}
    # Runs after the release, and also on a re-run whose release already exists.
    steps = _jobs()["publish"]["steps"]
    assert steps[-1] is step or steps[-1] == step
    assert "if" not in step
