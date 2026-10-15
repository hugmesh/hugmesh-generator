"""The cloud_deploy CLI face (``python3 -m hugmesh_studio.core.cloud_deploy VERB
[flags]``) through its REAL argparse — no Qt needed, so it runs on a bare host
(test_cloud_deploy.py skips whole without a Qt binding).

The menu's _deploy_run, the Makefile deploy-* delegates and
CloudDeployOptions.to_cli_args() all hand this entrypoint the --idp* flags; before
they were declared here every external-IdP deploy died in argparse with rc=2
("unrecognized arguments") before the driver was ever reached. The driver is a STUB
(SNAP_CLOUD_DEPLOY_CMD) except in the one end-to-end test that runs the real bash
driver offline through its CD_* seams.
"""
import os
import subprocess
import sys

import pytest

from hugmesh_studio.core.cloud_deploy import CloudDeployOptions, main

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

_STUB = """#!/usr/bin/env bash
printf '%s\\n' "$@" >"${CD_STUB_OUT:?}/argv"
echo "stub ran verb=$1"
"""

ENTRA = ["--idp", "entra",
         "--idp-issuer", "https://login.microsoftonline.com/tid/v2.0",
         "--idp-client-id", "app-mesh",
         "--idp-jwks", "https://login.microsoftonline.com/tid/discovery/v2.0/keys"]


@pytest.fixture
def stub(tmp_path, monkeypatch):
    """A recording stub driver behind SNAP_CLOUD_DEPLOY_CMD; returns the argv file."""
    drv = tmp_path / "stub-cloud-deploy.sh"
    drv.write_text(_STUB)
    drv.chmod(0o755)
    out = tmp_path / "stub-out"
    out.mkdir()
    monkeypatch.setenv("SNAP_CLOUD_DEPLOY_CMD", str(drv))
    monkeypatch.setenv("CD_STUB_OUT", str(out))
    return out / "argv"


def test_cli_accepts_the_idp_flags_and_forwards_them_to_the_driver(stub, capsys):
    # the menu _deploy_run / Makefile shape: pinned flags, then --idp*, then
    # --generator-dir (consumed by the entrypoint, never forwarded)
    rc = main(["plan", "--provider", "azure-image", "--image", "/tmp/node.vhd",
               "--domain", "acme.example", "--region", "westeurope",
               "--out-dir", "/tmp/cd-out", "--keys-dir", "/tmp/keys",
               *ENTRA, "--generator-dir", GENERATOR_DIR])
    assert rc == 0, capsys.readouterr().out
    assert stub.read_text().split("\n")[:-1] == [
        "plan", "--provider", "azure-image", "--image", "/tmp/node.vhd",
        "--domain", "acme.example", "--region", "westeurope",
        "--out-dir", "/tmp/cd-out", "--keys-dir", "/tmp/keys", *ENTRA]


def test_cli_idp_subflags_are_optional_but_each_one_is_forwarded(stub):
    assert main(["plan", "--provider", "aws-ec2", "--idp", "oidc",
                 "--idp-issuer", "https://idp.example/realm"]) == 0
    assert stub.read_text().split("\n")[:-1] == [
        "plan", "--provider", "aws-ec2", "--idp", "oidc",
        "--idp-issuer", "https://idp.example/realm"]


@pytest.mark.parametrize("idp_args", [[], ["--idp", "casdoor"], ["--idp", ""]])
def test_cli_casdoor_default_adds_nothing_to_the_driver_argv(stub, idp_args):
    assert main(["plan", "--provider", "aws-ec2", *idp_args]) == 0
    assert stub.read_text().split("\n")[:-1] == ["plan", "--provider", "aws-ec2"]


@pytest.mark.parametrize("verb", ["list", "plan", "apply", "status", "destroy"])
def test_cli_every_verb_takes_the_idp_flags(stub, verb):
    assert main([verb, "--provider", "aws-ec2", *ENTRA[:4]]) == 0
    assert stub.read_text().split("\n")[:-1][-4:] == ENTRA[:4]


def test_cli_preview_shows_the_idp_flags_in_the_plan_command(capsys):
    assert main(["preview", "--provider", "aws-ec2", *ENTRA[:4]]) == 0
    out = capsys.readouterr().out
    assert "--idp entra --idp-issuer https://login.microsoftonline.com/tid/v2.0" in out


def test_cli_parses_everything_to_cli_args_emits(stub):
    """Every flag CloudDeployOptions.to_cli_args() can emit must parse through the
    entrypoint's argparse and come out the far side unchanged — the two halves of
    the same contract (the GUI/phone/menu faces marshal with the former)."""
    opts = CloudDeployOptions(
        provider="azure-image", image="/tmp/node.vhd", domain="acme.example",
        region="westeurope", creds_file="/tmp/op-creds", out_dir="/tmp/cd-out",
        keys_dir="/tmp/keys", idp="entra",
        idp_issuer="https://login.microsoftonline.com/tid/v2.0",
        idp_client_id="app-mesh",
        idp_jwks="https://login.microsoftonline.com/tid/discovery/v2.0/keys")
    assert main(["plan", *opts.to_cli_args()]) == 0
    assert stub.read_text().split("\n")[:-1] == ["plan", *opts.to_cli_args()]


def test_cli_external_idp_plan_emits_idp_conf_through_the_real_driver(tmp_path):
    """End to end, offline: the REAL bash driver behind the REAL argparse, through
    the driver's own CD_* seams. The plan artifacts carry the operator's IdP."""
    image = tmp_path / "node.qcow2"
    image.write_bytes(b"qcow2-stand-in")
    out = tmp_path / "out"
    env = dict(os.environ,
               CD_PROVIDERS_LIB=os.path.join(
                   GENERATOR_DIR, "specs/usr/lib/hugmesh/cloud-deploy-providers.sh"),
               CD_ETC_HUGMESH=str(tmp_path / "etc"),
               PYTHONPATH=STUDIO_ROOT)
    env.pop("SNAP_CLOUD_DEPLOY_CMD", None)
    r = subprocess.run(
        [sys.executable, "-m", "hugmesh_studio.core.cloud_deploy", "plan",
         "--provider", "generic-qcow2", "--image", str(image),
         "--out-dir", str(out), "--keys-dir", str(tmp_path), *ENTRA[:6],
         "--generator-dir", GENERATOR_DIR],
        env=env, cwd=GENERATOR_DIR, stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=60)
    assert r.returncode == 0, r.stdout
    conf = (out / "idp" / "idp.conf").read_text()
    assert "provider=entra" in conf
    assert "issuer=https://login.microsoftonline.com/tid/v2.0" in conf
    assert "client_id=app-mesh" in conf


def test_cli_driver_still_owns_idp_validation(tmp_path, monkeypatch):
    """The entrypoint only passes the flags through: a value the driver refuses
    (external IdP with no issuer) is the DRIVER's rejection (rc 1, its own
    message), not an argparse usage error."""
    env = dict(os.environ,
               CD_PROVIDERS_LIB=os.path.join(
                   GENERATOR_DIR, "specs/usr/lib/hugmesh/cloud-deploy-providers.sh"),
               CD_ETC_HUGMESH=str(tmp_path / "etc"),
               PYTHONPATH=STUDIO_ROOT)
    env.pop("SNAP_CLOUD_DEPLOY_CMD", None)
    r = subprocess.run(
        [sys.executable, "-m", "hugmesh_studio.core.cloud_deploy", "plan",
         "--provider", "generic-qcow2", "--out-dir", str(tmp_path / "out"),
         "--idp", "entra", "--generator-dir", GENERATOR_DIR],
        env=env, cwd=GENERATOR_DIR, stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=60)
    assert r.returncode == 1, r.stdout
    assert "requires --idp-issuer" in r.stdout
    assert "usage:" not in r.stdout

