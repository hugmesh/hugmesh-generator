"""Windows sweep, cluster c9: sentences and bytes the native Windows Studio got wrong.

  * the fleet preflight told a Windows user with a stopped Docker Desktop to install
    Docker (installed) or use a Gentoo host (impossible for the MSI);
  * a key-zip whose domain.conf / vault/secrets.json was written by Notepad or Windows
    PowerShell 5.1 (UTF-8 BOM, UTF-16) lost BRAND or the whole file, silently;
  * the superbrand profile refusal said "letters" for a rule that is ASCII-only;
  * a path pasted with Explorer's "Copy as path" quotes was refused as relative /
    "moved, or a directory";
  * a second --login-agent bound the port beside the first (SO_REUSEADDR on Windows);
  * a CA row told the MSI user to install a package the frozen build cannot load;
  * --e2e-plan said "runnable: yes" for a `make` run the Windows build cannot do.

Every Windows rule is reached through an ``osname`` parameter (never by patching
os.name), so the Linux half of each test runs on Linux CI too.
"""
from __future__ import annotations

import codecs
import functools
import importlib.util
import json
import os
import socket
import sys

import pytest

sys.path.insert(0, os.path.dirname(__file__))

from hugmesh_studio.core import brand_model, build_driver, config, domain_reach  # noqa: E402
from hugmesh_studio.core import platform_info  # noqa: E402
from hugmesh_studio.core import e2e_environments, keyzip, local_login_agent  # noqa: E402
from hugmesh_studio.core.config import ImageConfig  # noqa: E402
from hugmesh_studio.core.fleet import FleetConfig, FleetDriver  # noqa: E402
from hugmesh_studio.core.keyzip import KeyZipContents  # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo  # noqa: E402

_REAL_REMEDY = build_driver.windows_docker_remedy

windows_only = pytest.mark.skipif(os.name != "nt", reason="Windows socket/PATH rules")


# ── fleet preflight: the Windows Docker remedy ──────────────────────────────────

def _host(os_name: str, has_docker: bool = False) -> HostInfo:
    return HostInfo(os=os_name, is_gentoo=False, has_docker=has_docker, has_bash=True,
                    has_kvm=False, is_root=False, builder_image="hugmesh-builder")


def test_fleet_none_backend_on_windows_says_the_windows_remedy(tmp_path, monkeypatch):
    monkeypatch.setattr(build_driver, "windows_docker_remedy",
                        lambda *a, **k: "Start Docker Desktop, then check again.")
    d = FleetDriver(str(tmp_path), host=_host("windows"))
    text = " ".join(d.preflight(FleetConfig()))
    assert "No build backend: Start Docker Desktop, then check again." in text
    assert "Gentoo" not in text
    assert "install Docker (any OS)" not in text


def test_fleet_docker_unreachable_on_windows_names_the_remedy(tmp_path, monkeypatch):
    monkeypatch.setattr(build_driver, "windows_docker_remedy",
                        lambda *a, **k: "Start Docker Desktop, then check again.")
    d = FleetDriver(str(tmp_path), host=_host("windows"))
    text = " ".join(d.preflight(FleetConfig(), backend="docker"))
    assert ("Docker selected but the Docker daemon is not reachable. Start Docker "
            "Desktop, then check again.") in text


def test_fleet_none_backend_on_linux_keeps_the_generic_sentence(tmp_path):
    d = FleetDriver(str(tmp_path), host=_host("linux"))
    problems = d.preflight(FleetConfig())
    assert "No build backend: install Docker (any OS) or run on a Gentoo host." in problems
    assert "Docker selected but the Docker daemon is not reachable." not in " ".join(
        d.preflight(FleetConfig(), backend="none"))
    assert ("Docker selected but the Docker daemon is not reachable." in
            d.preflight(FleetConfig(), backend="docker"))


@pytest.mark.parametrize("state", [platform_info.DOCKER_TIMEOUT, platform_info.DOCKER_DOWN])
def test_fleet_windows_remedy_uses_the_hosts_probe_state(tmp_path, monkeypatch, state):
    # the real remedy, pinned to nt so it runs on Linux CI too: a busy engine (timeout)
    # must get the "did not answer" wording, as the build preflight gives, not "start it"
    monkeypatch.setattr(build_driver, "windows_docker_remedy",
                        functools.partial(_REAL_REMEDY, osname="nt"))
    host = _host("windows")
    host.docker_state = state
    d = FleetDriver(str(tmp_path), host=host)
    for backend in (None, "docker"):
        text = " ".join(d.preflight(FleetConfig(), backend=backend))
        assert host.docker_remedy() in text
        assert "Gentoo" not in text
        # a timeout is "slow", not "unreachable" (BuildDriver.preflight's rule)
        assert ("not reachable" in text) == (
            backend == "docker" and state != platform_info.DOCKER_TIMEOUT)


@windows_only
def test_fleet_none_backend_real_windows_remedy_names_docker_desktop(tmp_path):
    d = FleetDriver(str(tmp_path), host=_host("windows"))
    text = " ".join(d.preflight(FleetConfig()))
    assert "Docker Desktop" in text and "Gentoo" not in text


# ── key-zip: BOM / UTF-16 text from Notepad and Windows PowerShell 5.1 ─────────

DOMAIN_CONF = "BRAND=acme\r\nORG=Acme\r\nCLUSTER_DOMAIN=acme.example\r\n"
SECRETS = {"acme-pki": {"casdoor-superadmin": {"username": "superadmin",
                                                "password": "S3cret"}}}


@pytest.mark.parametrize("encoding", ["utf-8-sig", "utf-16"])
def test_keyzip_domain_conf_bom_and_utf16_apply_every_field(tmp_path, encoding):
    p = tmp_path / "domain.conf"
    p.write_bytes(DOMAIN_CONF.encode(encoding))
    cfg, warnings = ImageConfig(), []
    keyzip._apply_domain_conf(str(p), cfg, warnings)
    assert (cfg.brand, cfg.org, cfg.cluster_domain) == ("acme", "Acme", "acme.example")
    assert warnings == []


@pytest.mark.parametrize("encoding", ["utf-8-sig", "utf-16"])
def test_keyzip_domain_json_bom_and_utf16_apply(tmp_path, encoding):
    p = tmp_path / "domain.json"
    p.write_bytes(json.dumps({"BRAND": "acme"}).encode(encoding))
    cfg = ImageConfig()
    keyzip._apply_domain_conf(str(p), cfg, [])
    assert cfg.brand == "acme"


def test_keyzip_unreadable_domain_conf_is_a_warning_not_silence(tmp_path):
    p = tmp_path / "domain.conf"
    p.write_bytes(b"BRAND=\xff\xc0acme\n")          # not UTF-8, no UTF-16 BOM
    cfg, warnings = ImageConfig(), []
    keyzip._apply_domain_conf(str(p), cfg, warnings)
    assert cfg.brand == ImageConfig().brand
    assert any("domain.conf could not be read" in w for w in warnings)


def _staging_with_secrets(tmp_path, raw: bytes) -> KeyZipContents:
    staging = tmp_path / "staging"
    (staging / "vault").mkdir(parents=True)
    (staging / "vault" / "secrets.json").write_bytes(raw)
    return KeyZipContents(staging_dir=str(staging), has_keys=True)


@pytest.mark.parametrize("encoding", ["utf-8-sig", "utf-16"])
def test_keyzip_secrets_json_bom_and_utf16_remember_roles(tmp_path, encoding):
    contents = _staging_with_secrets(tmp_path, json.dumps(SECRETS).encode(encoding))
    manifest = tmp_path / "roles.json"
    roles = keyzip.emit_passwordless_login_roles(contents, enabled=True,
                                                 manifest_path=str(manifest))
    assert roles == ["superadmin"]
    assert manifest.exists()
    assert contents.warnings == []


def test_keyzip_unreadable_secrets_json_is_a_warning(tmp_path):
    contents = _staging_with_secrets(tmp_path, b"{not valid json")
    manifest = tmp_path / "roles.json"
    assert keyzip.emit_passwordless_login_roles(
        contents, enabled=True, manifest_path=str(manifest)) == []
    assert not manifest.exists()
    assert any("secrets.json could not be read" in w for w in contents.warnings)


def test_keyzip_utf16_bom_is_what_the_test_writes():
    # The fixture above must really carry the bytes PowerShell 5.1 writes, or the
    # utf-16 case would pass vacuously.
    assert DOMAIN_CONF.encode("utf-16").startswith((codecs.BOM_UTF16_LE,
                                                    codecs.BOM_UTF16_BE))
    assert DOMAIN_CONF.encode("utf-8-sig").startswith(codecs.BOM_UTF8)


# ── superbrand profile refusal names the ASCII rule ─────────────────────────────

def test_profile_refusal_says_ascii_letters_for_a_non_ascii_title():
    record = brand_model.BrandRecord(
        brand_model.Superbrand(id="joerg", title="Jörg Mesh"))
    problems = [p for p in brand_model.record_problems(record) if "BRAND_TITLE" in p]
    assert problems, "Jörg Mesh must still be refused (the profile rule is ASCII)"
    assert "ASCII letters A-Z a-z" in problems[0]
    assert "(letters, digits" not in problems[0]


# ── quoted paths (Explorer's "Copy as path") ────────────────────────────────────

QUOTED = '"C:\\Users\\J\u00f6rg\\certs J\u00f6rg\\my vpn.conf"'


def test_egress_quoted_path_on_windows_names_the_quotes():
    out = domain_reach.egress_problems({"mode": "vpn", "conf": QUOTED}, "the mesh",
                                       osname="nt")
    assert len(out) == 1
    assert "quote marks" in out[0]
    assert "must be an absolute path" not in out[0]


def test_egress_quoted_path_off_windows_keeps_its_sentence():
    out = domain_reach.egress_problems({"mode": "vpn", "conf": QUOTED}, "the mesh",
                                       osname="posix")
    assert out == [f"the mesh: egress conf must be an absolute path, got {QUOTED!r}"]


def test_ca_cert_quoted_path_on_windows_names_the_quotes(tmp_path):
    pem = tmp_path / "ca \u00fc.pem"
    pem.write_text("-----BEGIN CERTIFICATE-----\naGVsbG8=\n-----END CERTIFICATE-----\n",
                   encoding="utf-8")
    quoted = f'"{pem}"'
    err = config.ca_cert_error(quoted, osname="nt")
    assert err.startswith("ca \u00fc.pem: ")
    assert "quote marks" in err
    assert "moved, or a directory" not in err
    # what the TUI's `c` command hands over: abspath() of the quoted text
    joined = os.path.join(str(tmp_path), quoted)
    assert "quote marks" in config.ca_cert_error(joined, osname="nt")


def test_ca_cert_quoted_path_off_windows_keeps_its_sentence(tmp_path):
    err = config.ca_cert_error(f'"{tmp_path / "missing.pem"}"', osname="posix")
    assert "not a readable file (moved, or a directory)" in err


# ── CA row in the frozen Windows build ──────────────────────────────────────────

no_cryptography = pytest.mark.skipif(
    importlib.util.find_spec("cryptography") is not None,
    reason="python-cryptography is installed, so the stand-in line is not shown")


@no_cryptography
def test_ca_row_in_the_frozen_windows_build_gives_no_install_advice():
    from ca_fixtures import CA_ROOT
    line = config.describe_ca_cert(CA_ROOT, osname="nt", frozen=True)
    assert "install python-cryptography" not in line
    assert "this Windows build of the Studio does not include python-cryptography" in line


@no_cryptography
@pytest.mark.parametrize("osname,frozen", [("posix", True), ("posix", False), ("nt", False)])
def test_ca_row_elsewhere_keeps_the_install_advice(osname, frozen):
    from ca_fixtures import CA_ROOT
    line = config.describe_ca_cert(CA_ROOT, osname=osname, frozen=frozen)
    assert "(install python-cryptography to show subject and expiry)" in line


# ── login agent: one listener per port ──────────────────────────────────────────

def _manifest(tmp_path) -> str:
    path = str(tmp_path / "roles.json")
    local_login_agent.RolesManifest(roles=[], origins=frozenset()).write(path)
    return path


def _agent(tmp_path):
    return local_login_agent.LocalLoginAgent(_manifest(tmp_path))


def test_second_login_agent_on_a_bound_port_fails_to_bind(tmp_path):
    agent = _agent(tmp_path)
    first = local_login_agent.make_server(agent, host="127.0.0.1", port=0)
    try:
        port = first.server_address[1]
        with pytest.raises(OSError):
            second = local_login_agent.make_server(agent, host="127.0.0.1", port=port)
            second.server_close()
    finally:
        first.server_close()


def test_run_exits_1_when_another_agent_holds_the_port(tmp_path, monkeypatch):
    # Should the bind wrongly succeed, run() must return rather than serve forever.
    monkeypatch.setattr(local_login_agent._LoopbackAuthServer, "serve_forever",
                        lambda self, *a, **k: None)
    monkeypatch.setattr(local_login_agent._LoopbackAuthServer, "shutdown",
                        lambda self: None)
    agent = _agent(tmp_path)
    first = local_login_agent.make_server(agent, host="127.0.0.1", port=0)
    try:
        rc = local_login_agent.run(_manifest(tmp_path), host="127.0.0.1",
                                   port=first.server_address[1])
        assert rc == 1
    finally:
        first.server_close()


@windows_only
def test_no_reuseaddr_socket_can_sit_beside_the_agent(tmp_path):
    first = local_login_agent.make_server(_agent(tmp_path), host="127.0.0.1", port=0)
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            with pytest.raises(OSError):
                s.bind(("127.0.0.1", first.server_address[1]))
        finally:
            s.close()
    finally:
        first.server_close()


# ── e2e plan on native Windows ──────────────────────────────────────────────────

@pytest.mark.parametrize("env_id", ["docker", "kind", "qemu"])
def test_e2e_plan_on_native_windows_is_refused_with_the_wsl2_sentence(env_id):
    p = e2e_environments.plan(env_id, ambient={}, osname="nt")
    assert not p.runnable
    assert "WSL2" in p.refusals[0]
    assert p.to_dict()["runnable"] is False


@pytest.mark.parametrize("env_id", ["docker", "kind", "qemu"])
def test_e2e_plan_off_windows_is_unchanged(env_id):
    p = e2e_environments.plan(env_id, ambient={}, osname="posix")
    assert p.runnable and p.refusals == ()
    assert p.argv == ("make", e2e_environments.RUN_TARGET)


# ── quoted paths: the quotes come off at input, on native Windows only ─────────────

_REAL_UNQUOTE = platform_info.unquote_pasted_path


def _unquote_as(monkeypatch, osname):
    monkeypatch.setattr(platform_info, "unquote_pasted_path",
                        functools.partial(_REAL_UNQUOTE, osname=osname))


def test_unquote_pasted_path_drops_explorer_quotes_on_windows_only():
    assert platform_info.unquote_pasted_path(QUOTED, osname="nt") == QUOTED[1:-1]
    assert platform_info.unquote_pasted_path(f"  {QUOTED} ", osname="nt") == QUOTED[1:-1]
    assert platform_info.unquote_pasted_path(QUOTED, osname="posix") == QUOTED
    # not ONE quoted path: left for the check to name
    for text in (r'"C:\a" "C:\b"', r'"C:\a', r'C:\a"', '"', r'C:\plain'):
        assert platform_info.unquote_pasted_path(text, osname="nt") == text


def test_a_quoted_egress_conf_is_stored_without_its_quotes_on_windows(monkeypatch):
    from hugmesh_studio.tui.brand_step import BrandView

    class _View:
        own = False

        def _set_ways(self, **kw):
            self.ways = kw
            return []

    _unquote_as(monkeypatch, "nt")
    view = _View()
    assert BrandView.set_egress(view, "vpn", QUOTED) == []
    assert view.ways == {"egress": {"mode": "vpn", "conf": QUOTED[1:-1]}}
    _unquote_as(monkeypatch, "posix")
    BrandView.set_egress(view, "vpn", QUOTED)
    assert view.ways["egress"]["conf"] == QUOTED          # Linux: as typed, as before


def test_a_quoted_ca_path_in_the_text_screen_is_added_on_windows(tmp_path, monkeypatch):
    from types import SimpleNamespace
    from hugmesh_studio.tui.journey import VaultScreen
    pem = tmp_path / "ca.pem"
    pem.write_text("-----BEGIN CERTIFICATE-----\naGVsbG8=\n-----END CERTIFICATE-----\n",
                   encoding="utf-8")
    _unquote_as(monkeypatch, "nt")
    j = SimpleNamespace(cfg=ImageConfig(), status="")
    VaultScreen._feed_certificate(j, "c", f'"{pem}"')
    assert j.cfg.base_ca_certs == [str(pem)], j.status
    assert j.status.startswith("added ca.pem")


def test_a_quoted_picture_path_loads_on_windows(tmp_path, monkeypatch):
    from hugmesh_studio.core import brand_look
    from test_look_model import png_bytes
    pic = tmp_path / "logo J\u00f6rg.png"
    pic.write_bytes(png_bytes(16, 16))
    _unquote_as(monkeypatch, "nt")
    out = brand_look.Look().load_picture("logo_image", f'"{pic}"')
    assert out.ok and out.text.startswith("Accepted:"), out.text
    look = brand_look.Look()
    assert look.try_set("desktop_logo", f'"{pic}"').ok
    assert look.get("desktop_logo") == str(pic)


def test_a_quoted_picture_path_is_left_alone_off_windows(tmp_path, monkeypatch):
    from hugmesh_studio.core import brand_look
    _unquote_as(monkeypatch, "posix")
    look = brand_look.Look()
    assert look.try_set("desktop_logo", '"/srv/logo.png"').ok
    assert look.get("desktop_logo") == '"/srv/logo.png"'


# ── the superbrand title is refused AS IT IS TYPED, in the ASCII words ──────────────

def test_a_non_ascii_title_is_refused_when_typed_on_the_image_route():
    import types
    from hugmesh_studio.tui.superbrand_step import session_for
    gen = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    s = session_for(types.SimpleNamespace(), "image", ImageConfig(), os.path.dirname(gen))
    said = s.set_identity("title", "J\u00f6rg Mesh")
    assert "ASCII letters A-Z a-z" in said and said.startswith("title: ")
    assert s.sb.title == ""                               # a refused value changes nothing
    assert s.set_identity("title", "Joerg Mesh") == "" and s.sb.title == "Joerg Mesh"


def test_the_docker_route_still_takes_a_non_ascii_title():
    import types
    from hugmesh_studio.core.config import Domain
    from hugmesh_studio.core.local_mesh_bootstrap import LocalMeshBootstrapConfig
    from hugmesh_studio.core.local_mesh_domains import LocalMeshDomains
    from hugmesh_studio.tui.superbrand_step import session_for
    gen = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    boot = LocalMeshBootstrapConfig(env="test")
    state = LocalMeshDomains(domains=[Domain(name="hugmesh.net")], own_name="hugmesh.net")
    s = session_for(types.SimpleNamespace(), "docker", (boot, state), gen)
    assert s.set_identity("title", "J\u00f6rg Mesh") == ""  # its start takes any title
