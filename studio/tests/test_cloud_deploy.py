"""Cloud deploy — the ModePage's sixth first-screen choice (DeployPage) and the
Qt-free core it fronts (core/cloud_deploy.py).

Everything here is HERMETIC: the driver is a STUB shell script pointed at through
the SNAP_CLOUD_DEPLOY_CMD env seam (the exact pattern test_phone_wizard.py uses for
SNAP_PHONE_WIZARD) — no real cloud CLI, driver, or terminal emulator ever runs. The
core assertions prove the contract that matters most: pasted creds NEVER land on
argv, ride a 0600 --creds-file tempfile, and are shredded after the run; a
creds-FILE knob forwards the operator's path only; and preview() is PURE (no
subprocess, no files).

Runs the REAL page on Qt's offscreen platform; skipped whole when no Qt binding is
installed (mirrors test_phone_wizard.py — the pure-core assertions still need only
the core import, which does not require Qt, but live here beside the GUI ones for
locality).
"""
import os
import stat

import pytest

# must be set BEFORE the first QApplication is created
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import cloud_deploy as cloud_deploy_mod  # noqa: E402
from hugmesh_studio.core.cloud_deploy import (  # noqa: E402
    CloudDeploy, CloudDeployOptions,
)
from hugmesh_studio.gui import wizard as wizard_mod  # noqa: E402
from hugmesh_studio.gui.pages import deploy as deploy_mod  # noqa: E402
from hugmesh_studio.gui.pages import ModePage  # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets  # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

# A stub driver that records its argv and — at CHILD runtime — the --creds-file's
# content + octal mode + path, proving the secret travels by 0600 file only. Its
# `list` verb emits the REAL driver's space-padded printf table (header + rows +
# trailing prose) so the provider-picker parse is proven against the go-live
# house shape, never a tab-dependent one.
_STUB = """#!/usr/bin/env bash
printf '%s\\n' "$@" >"${CD_STUB_OUT:?}/argv"
prev=""
for a in "$@"; do
    if [ "${prev}" = "--creds-file" ]; then
        cat -- "${a}" >"${CD_STUB_OUT}/creds-content" 2>/dev/null
        stat -c '%a' -- "${a}" >"${CD_STUB_OUT}/creds-mode" 2>/dev/null
        printf '%s' "${a}" >"${CD_STUB_OUT}/creds-path"
    fi
    prev="${a}"
done
if [ "$1" = "list" ]; then
    # The REAL driver's table shape: space-padded printf columns (go-live house
    # pattern), NEVER tabs — the parser must whitespace-split, not tab-split.
    printf '%-16s %-10s %-6s %s\n' 'ID' 'FORMAT' 'STATE' 'DESCRIPTION'
    printf '%-16s %-10s %-6s %s\n' 'aws-ec2' 'raw' 'full' 'AWS EC2 AMI via import-snapshot'
    printf '%-16s %-10s %-6s %s\n' 'azure-image' 'vhd-fixed' 'full' 'Azure managed image (Gen2 fixed VHD)'
    printf '%-16s %-10s %-6s %s\n' 'openshift-cnv' 'qcow2' 'full' 'OpenShift Virtualization (KubeVirt qcow2)'
    printf '%-16s %-10s %-6s %s\n' 'generic-qcow2' 'qcow2' 'full' 'Any libvirt/qcow2 host or PaaS'
    printf '\n'
    printf 'All providers are fully implemented. plan --provider ID emits artifacts.\n'
fi
echo "stub ran verb=$1"
exit "${CD_STUB_RC:-0}"
"""


def _install_stub(tmp_path, monkeypatch):
    """Write the stub driver + wire the SNAP_CLOUD_DEPLOY_CMD / CD_STUB_OUT seams.
    Returns the out-dir the stub writes its captures into."""
    stub = tmp_path / "stub-cloud-deploy.sh"
    stub.write_text(_STUB)
    stub.chmod(0o755)
    out = tmp_path / "stub-out"
    out.mkdir()
    monkeypatch.setenv("SNAP_CLOUD_DEPLOY_CMD", str(stub))
    monkeypatch.setenv("CD_STUB_OUT", str(out))
    return out


def _image(tmp_path, name="node.qcow2"):
    """A tiny stand-in packaged artifact (validate() only checks presence)."""
    p = tmp_path / name
    p.write_bytes(b"qcow2-stand-in")
    return str(p)


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


def _drain_worker(qapp, host, timeout_ms=5000):
    """Join the _MeshWorker (verbs run OFF the GUI thread) and pump the loop so its
    queued line/done signals land before the test asserts."""
    w = getattr(host, "worker", None)
    if w is not None:
        w.wait(timeout_ms)
    for _ in range(200):
        qapp.processEvents()


# ---- pure-core: argv marshalling + off-argv 0600 secret -------------------------

def test_run_argv_is_verb_first_flags_in_pinned_order_and_creds_off_argv(tmp_path, monkeypatch):
    out = _install_stub(tmp_path, monkeypatch)
    secret = "AWS_SECRET_ACCESS_KEY=Sup3r Secret!"
    img = _image(tmp_path)
    cd = CloudDeploy(str(tmp_path), CloudDeployOptions(
        provider="aws-ec2", image=img, domain="acme.example", region="eu-central-1",
        out_dir="/tmp/cd-out", keys_dir=str(tmp_path), creds=secret))
    lines = []
    rc = cd.run("plan", on_line=lines.append)

    assert rc == 0
    argv = (out / "argv").read_text().splitlines()
    # verb first, flags in the driver's pinned order (--provider --image --domain
    # --region --out-dir --keys-dir); the staged creds file rides at the tail
    assert argv[:13] == ["plan", "--provider", "aws-ec2", "--image", img,
                         "--domain", "acme.example", "--region", "eu-central-1",
                         "--out-dir", "/tmp/cd-out", "--keys-dir", str(tmp_path)]
    assert argv[13] == "--creds-file"
    # the secret NEVER appears anywhere on argv
    assert secret not in (out / "argv").read_text()
    # it rode a 0600 file whose content is exactly the secret (no trailing newline) …
    assert (out / "creds-content").read_text() == secret
    assert (out / "creds-mode").read_text().strip() == "600"
    # … and the file was shredded after the run
    assert not os.path.exists((out / "creds-path").read_text())
    assert any("stub ran verb=plan" in ln for ln in lines)


def test_run_bare_verb_emits_no_empty_flags_and_no_credsfile(tmp_path, monkeypatch):
    out = _install_stub(tmp_path, monkeypatch)
    cd = CloudDeploy(str(tmp_path), CloudDeployOptions())
    assert cd.run("status") == 0
    assert (out / "argv").read_text().splitlines() == ["status"]
    assert not (out / "creds-path").exists()   # no creds -> no --creds-file at all


def test_creds_file_knob_forwards_the_path_between_region_and_out_dir(tmp_path, monkeypatch):
    out = _install_stub(tmp_path, monkeypatch)
    cf = tmp_path / "creds"
    cf.write_text("aws_access_key_id=AKIA...")
    cf.chmod(0o600)
    cd = CloudDeploy(str(tmp_path), CloudDeployOptions(
        provider="aws-ec2", region="eu-central-1", creds_file=str(cf),
        out_dir="/tmp/cd-out"))
    assert cd.run("status") == 0
    assert (out / "argv").read_text().splitlines() == [
        "status", "--provider", "aws-ec2", "--region", "eu-central-1",
        "--creds-file", str(cf), "--out-dir", "/tmp/cd-out"]
    # the operator's OWN file is never staged, never shredded — custody stays theirs
    assert cf.exists()


def test_run_nonzero_driver_rc_is_returned(tmp_path, monkeypatch):
    _install_stub(tmp_path, monkeypatch)
    monkeypatch.setenv("CD_STUB_RC", "7")
    assert CloudDeploy(str(tmp_path), CloudDeployOptions()).run("status") == 7


def test_to_cli_args_never_contains_pasted_creds():
    opts = CloudDeployOptions(provider="aws-ec2", creds="SECRETVALUE")
    assert "SECRETVALUE" not in opts.to_cli_args()
    assert opts.to_cli_args() == ["--provider", "aws-ec2"]


def test_to_cli_args_idp_default_emits_nothing():
    # The built-in default keeps argv byte-identical to pre-IdP flows — both the
    # blank and the explicit "casdoor" spelling.
    for default in ("", "casdoor"):
        opts = CloudDeployOptions(provider="aws-ec2", idp=default,
                                  idp_issuer="https://x.example")
        assert opts.to_cli_args() == ["--provider", "aws-ec2"]


def test_to_cli_args_idp_external_appends_after_pinned_flags():
    opts = CloudDeployOptions(
        provider="azure-image", idp="entra",
        idp_issuer="https://login.microsoftonline.com/tid/v2.0",
        idp_client_id="app-mesh")
    assert opts.to_cli_args() == [
        "--provider", "azure-image",
        "--idp", "entra",
        "--idp-issuer", "https://login.microsoftonline.com/tid/v2.0",
        "--idp-client-id", "app-mesh",
    ]


# ---- pure-core: provider registry parse + availability --------------------------

def test_providers_parses_the_space_padded_table_and_skips_header_and_prose(tmp_path, monkeypatch):
    _install_stub(tmp_path, monkeypatch)
    rows = CloudDeploy(str(tmp_path)).providers()
    assert [r[0] for r in rows] == ["aws-ec2", "azure-image", "openshift-cnv",
                                    "generic-qcow2"]
    assert all(status == "full" for _pid, status, _d in rows)
    assert rows[0][2] == "AWS EC2 AMI via import-snapshot"


def test_available_false_when_driver_missing_and_providers_empty(tmp_path, monkeypatch):
    monkeypatch.setenv("SNAP_CLOUD_DEPLOY_CMD", str(tmp_path / "nope"))
    cd = CloudDeploy(str(tmp_path))
    ok, why = cd.available()
    assert ok is False and "not found" in why.lower()
    assert cd.providers() == []


def test_available_false_when_driver_not_executable(tmp_path, monkeypatch):
    f = tmp_path / "ne.sh"
    f.write_text("#!/usr/bin/env bash\n")
    f.chmod(0o644)
    monkeypatch.setenv("SNAP_CLOUD_DEPLOY_CMD", str(f))
    assert CloudDeploy(str(tmp_path)).available()[0] is False


def test_driver_path_defaults_to_the_canonical_sysroot_location(monkeypatch):
    # The driver lands from the parallel deploy-driver lane; until then the wrapper
    # must still RESOLVE to the one canonical path (and available() stays honest).
    monkeypatch.delenv("SNAP_CLOUD_DEPLOY_CMD", raising=False)
    cd = CloudDeploy(GENERATOR_DIR)
    assert cd.driver_path == os.path.join(
        GENERATOR_DIR, "specs", "usr", "sbin", "hugmesh-cloud-deploy")


# ---- pure-core: preview purity + validate blockers ------------------------------

def test_preview_is_pure_no_subprocess_no_files(tmp_path, monkeypatch):
    out = _install_stub(tmp_path, monkeypatch)
    cd = CloudDeploy(str(tmp_path), CloudDeployOptions(provider="aws-ec2"))
    text = cd.preview()
    assert "CLOUD DEPLOY" in text and "plan command:" in text
    # PURE: the stub never ran and nothing was written anywhere
    assert not (out / "argv").exists()
    assert sorted(p.name for p in tmp_path.iterdir()) == \
        ["stub-cloud-deploy.sh", "stub-out"]


def test_preview_carries_a_blockers_tail_and_clears_when_valid(tmp_path, monkeypatch):
    _install_stub(tmp_path, monkeypatch)
    bad = CloudDeploy(str(tmp_path), CloudDeployOptions())
    assert "BLOCKERS" in bad.preview()
    good = CloudDeploy(str(tmp_path), CloudDeployOptions(
        provider="generic-qcow2", image=_image(tmp_path)))
    assert "BLOCKERS" not in good.preview()


def test_validate_blockers_cover_the_rejection_table(tmp_path):
    img = _image(tmp_path)
    # no provider + no image
    probs = CloudDeploy(str(tmp_path), CloudDeployOptions()).validate()
    assert any("provider" in p for p in probs)
    assert any("image" in p for p in probs)
    # image path missing
    probs = CloudDeploy(str(tmp_path), CloudDeployOptions(
        provider="aws-ec2", image=str(tmp_path / "gone.qcow2"))).validate()
    assert any("not found" in p for p in probs)
    # both creds channels set
    cf = tmp_path / "creds"; cf.write_text("k=v"); cf.chmod(0o600)
    probs = CloudDeploy(str(tmp_path), CloudDeployOptions(
        provider="aws-ec2", image=img, creds="x", creds_file=str(cf))).validate()
    assert any("one channel" in p for p in probs)
    # group/world-readable creds file (custody bar) — fail-closed
    cf.chmod(0o644)
    probs = CloudDeploy(str(tmp_path), CloudDeployOptions(
        provider="aws-ec2", image=img, creds_file=str(cf))).validate()
    assert any("chmod 600" in p for p in probs)
    # nonsense domain + keys_dir that is not a dir
    probs = CloudDeploy(str(tmp_path), CloudDeployOptions(
        provider="aws-ec2", image=img, domain="not a domain",
        keys_dir=img)).validate()
    assert any("domain" in p for p in probs)
    assert any("keys dir" in p for p in probs)
    # all-good clears every blocker
    cf.chmod(0o600)
    assert CloudDeploy(str(tmp_path), CloudDeployOptions(
        provider="aws-ec2", image=img, domain="acme.example",
        region="eu-central-1", creds_file=str(cf),
        keys_dir=str(tmp_path))).validate() == []


def test_preflight_names_a_missing_driver(tmp_path, monkeypatch):
    monkeypatch.setenv("SNAP_CLOUD_DEPLOY_CMD", str(tmp_path / "nope"))
    probs = CloudDeploy(str(tmp_path), CloudDeployOptions(
        provider="aws-ec2", image=_image(tmp_path))).preflight()
    assert any("cloud-deploy driver not found" in p for p in probs)


# ---- pure-core: the mutating verbs defer to a terminal (no bypass) --------------

def test_destroy_without_emulator_hands_back_the_exact_command(tmp_path, monkeypatch):
    _install_stub(tmp_path, monkeypatch)
    monkeypatch.setattr(cloud_deploy_mod.shutil, "which", lambda *_: None)
    cd = CloudDeploy(str(tmp_path), CloudDeployOptions(provider="generic-qcow2"))
    ok, msg = cd.run_verb_in_terminal("destroy")
    assert ok is False and "no terminal emulator" in msg.lower()
    assert "destroy" in msg and "--provider" in msg and "generic-qcow2" in msg
    # no CD_ASSUME_YES / --yes anywhere near the hand-off — the driver's gate stands
    assert "CD_ASSUME_YES" not in msg and "--yes" not in msg


def test_terminal_launch_keeps_pasted_creds_off_the_terminal_argv(tmp_path, monkeypatch):
    _install_stub(tmp_path, monkeypatch)
    monkeypatch.setattr(cloud_deploy_mod.shutil, "which", lambda name: "/usr/bin/" + name)
    launched = {}
    monkeypatch.setattr(cloud_deploy_mod.subprocess, "Popen",
                        lambda cmd, **kw: launched.update(cmd=cmd) or object())
    staged = {}
    _orig = CloudDeploy._stage_creds
    monkeypatch.setattr(CloudDeploy, "_stage_creds",
                        staticmethod(lambda s: staged.setdefault("path", _orig(s))))
    cd = CloudDeploy(str(tmp_path), CloudDeployOptions(
        provider="aws-ec2", creds="SECRETVALUE"))
    ok, _msg = cd.run_verb_in_terminal("apply")
    assert ok is True
    script = launched["cmd"][-1]
    # the creds ride a --creds-file, so the SECRET VALUE is never on the terminal's
    # argv, and the wrapper shreds the file when the session ends.
    assert "--creds-file" in script
    assert "SECRETVALUE" not in script
    assert "shred" in script
    p = staged["path"]
    assert stat.S_IMODE(os.stat(p).st_mode) == 0o600
    with open(p) as fh:
        assert fh.read() == "SECRETVALUE"
    os.unlink(p)   # the fake terminal never ran, so remove the staged creds ourselves


# ---- GUI: the DeployPage surface (offscreen) ------------------------------------

def test_deploy_page_populates_provider_combo_and_masks_creds(qapp, tmp_path, monkeypatch):
    _install_stub(tmp_path, monkeypatch)
    dlg = deploy_mod.DeployDialog(str(tmp_path))
    ids = [dlg.provider.itemData(i) for i in range(dlg.provider.count())]
    assert ids == ["aws-ec2", "azure-image", "openshift-cnv", "generic-qcow2"]
    assert dlg.creds.echoMode() == QtWidgets.QLineEdit.EchoMode.Password
    assert dlg.page.isComplete() is True
    # the pure preview pane is live from construction
    assert "CLOUD DEPLOY" in dlg.plan_view.toPlainText()


def test_deploy_page_without_driver_shows_placeholder_and_why(qapp, tmp_path, monkeypatch):
    monkeypatch.setenv("SNAP_CLOUD_DEPLOY_CMD", str(tmp_path / "nope"))
    dlg = deploy_mod.DeployDialog(str(tmp_path))
    assert dlg.provider.count() == 1 and dlg.provider.itemData(0) == ""
    assert "not found" in dlg.status.text().lower()


def test_deploy_page_collect_maps_widgets_and_keeps_creds_off_argv(qapp, tmp_path, monkeypatch):
    _install_stub(tmp_path, monkeypatch)
    dlg = deploy_mod.DeployDialog(str(tmp_path))
    i = dlg.provider.findData("azure-image")
    assert i >= 0
    dlg.provider.setCurrentIndex(i)
    dlg.image.setText("/tmp/node.vhd")
    dlg.domain.setText("acme.example")
    dlg.region.setText("westeurope")
    dlg.out_dir.setText("/tmp/cd-out")
    dlg.creds.setText("SECRETVALUE")
    opts = dlg.collect()
    assert (opts.provider, opts.image, opts.domain, opts.region, opts.out_dir) == \
        ("azure-image", "/tmp/node.vhd", "acme.example", "westeurope", "/tmp/cd-out")
    assert opts.creds == "SECRETVALUE"
    assert "SECRETVALUE" not in opts.to_cli_args()


def test_deploy_page_apply_is_gated_on_the_ack_and_on_validate(qapp, tmp_path, monkeypatch):
    out = _install_stub(tmp_path, monkeypatch)
    dlg = deploy_mod.DeployDialog(str(tmp_path))
    (out / "argv").unlink()      # drop the ctor's provider-list capture
    # unacknowledged: the button is disabled AND the handler refuses
    assert dlg.apply_btn.isEnabled() is False
    dlg._apply_clicked()
    assert "acknowledge" in dlg.status.text().lower()
    assert not (out / "argv").exists()          # nothing ran
    # acknowledged but invalid (no provider/image): blockers stop it before the driver
    dlg.ack.setChecked(True)
    assert dlg.apply_btn.isEnabled() is True    # ack arms the button …
    dlg._apply_clicked()
    assert dlg.status.text().startswith("Cannot apply:")
    assert not (out / "argv").exists()          # … but validate still refuses
    # valid: apply streams through the worker (the localmesh _MeshWorker pattern)
    dlg.provider.setCurrentIndex(dlg.provider.findData("generic-qcow2"))
    dlg.image.setText(_image(tmp_path))
    dlg._apply_clicked()
    _drain_worker(qapp, dlg.page)
    argv = (out / "argv").read_text().splitlines()
    assert argv[0] == "apply" and "--provider" in argv and "generic-qcow2" in argv
    assert dlg.page.isComplete() is True        # Finish re-armed after done
    assert "stub ran verb=apply" in dlg.log.toPlainText()


def test_deploy_page_plan_streams_off_thread_and_preview_live_refreshes(qapp, tmp_path, monkeypatch):
    out = _install_stub(tmp_path, monkeypatch)
    dlg = deploy_mod.DeployDialog(str(tmp_path))
    dlg.provider.setCurrentIndex(dlg.provider.findData("aws-ec2"))
    img = _image(tmp_path)
    dlg.image.setText(img)                       # textChanged -> live preview refresh
    assert img in dlg.plan_view.toPlainText()
    dlg._run_stream("plan", "Planning")
    _drain_worker(qapp, dlg.page)
    argv = (out / "argv").read_text().splitlines()
    assert argv[0] == "plan"
    assert "--provider" in argv and "aws-ec2" in argv
    assert "stub ran verb=plan" in dlg.log.toPlainText()


def test_deploy_module_imports_no_qtwebengine():
    """QtWebEngine is absent under PyQt6 in this env and is never needed here — the
    page must not import it (directly or transitively)."""
    import sys

    import hugmesh_studio.gui.pages.deploy as m
    with open(m.__file__, encoding="utf-8") as fh:
        assert "QtWebEngine" not in fh.read()
    assert not any("QtWebEngine" in name for name in sys.modules)


def test_mode_page_deploy_radio_flows_into_the_terminal_page(qapp):
    """Selecting the Cloud deploy radio raises wiz.deploy_selected, leaves cfg.mode
    an image mode, and routes into the terminal DeployPage (mirrors the localmesh/
    phone side-flow contract)."""
    wiz = wizard_mod.StudioWizard(GENERATOR_DIR)
    try:
        mp = next(p for p in wiz._pages if isinstance(p, ModePage))
        before = wiz.cfg.mode
        for b in mp.group.buttons():
            if b.property("mode") == "deploy":
                b.setChecked(True)
        assert mp.isComplete() is True
        assert mp.validatePage() is True
        assert wiz.deploy_selected is True
        assert wiz.phone_selected is False
        assert wiz.localmesh_selected is False
        assert wiz.cfg.mode == before                # cfg.mode untouched (not an image mode)
        dp = wiz.page(wiz._page_ids["deploy"])
        assert dp.applies_to(wiz.cfg) is True
        assert dp.nextId() == -1 and dp.isFinalPage()
    finally:
        wiz.deleteLater()
