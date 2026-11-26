"""core/config_check: a config checked the way the wizard's Review step checks it, with
no GUI (the engine behind ``--check``).

Pure core, no Qt. Each test names the gate it holds: the parts are the wizard's own
(``scope_violations``, ``domain_services.gate_reason``, ``validate_identity``,
``root_size_floor``, ``WorklistDriver.preflight``), and what is new, and pinned here, is
that a hand-written config meets every one of them, that a key the loader would drop and
a name that is no service are reported instead of vanishing, and that each finding says
which gate it came from.
"""
import json
import os
import re

import pytest

from hugmesh_studio.core import config_check as cc
from hugmesh_studio.core import root_size_floor
from hugmesh_studio.core.desktop_spec import DesktopSpec
from hugmesh_studio.core.config import (
    BUILDER_DESELECTABLE_SERVICES,
    BUILDER_SELECTABLE_SERVICES,
    MIGRATED_CONFIG_KEYS,
    MIGRATED_DOMAIN_KEYS,
    REGISTRY_SERVICES,
    Domain,
    ImageConfig,
    User,
)
from hugmesh_studio.core.platform_info import HostInfo
from hugmesh_studio.core.worklist import WorklistConfig, WorklistEntry, synthesize

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)


def _read(rel: str) -> str:
    with open(os.path.join(GENERATOR_DIR, rel), encoding="utf-8") as fh:
        return fh.read()


def _clean() -> dict:
    """A config nothing is wrong with: what a saved cloud laptop on x86 looks like."""
    return ImageConfig(mode="cloud", role="laptop", platform="x86").to_dict()


def _mesh(cfg: ImageConfig, *entries: WorklistEntry) -> dict:
    return WorklistConfig(base=cfg, entries=list(entries)
                          or [WorklistEntry(role="omnibus", platform="x86")]).to_dict()


def _mesh_cfg(**kw) -> ImageConfig:
    """A mesh base the gates have nothing to say about (a private LAN address for the pki
    node, the main domain's services already walked); ``kw`` lays a defect on it."""
    cfg = ImageConfig(mode="mesh", role="omnibus", platform="x86", tailscale=True,
                      pki_lan_ip="192.168.1.10", pki_lan_ip_fixed=True)
    cfg.domain_services_reviewed = [cfg.cluster_domain]
    for k, v in kw.items():
        setattr(cfg, k, v)
    return cfg


def checks(findings):
    return [f.check for f in findings]


def say(findings) -> str:
    return "\n".join(f"{f.check}|{f.image}|{f.message}" for f in findings)


def run(data, **kw) -> "cc.CheckReport":
    kw.setdefault("preflight", False)
    return cc.check_data(data, **kw)


def host(*, docker=False, root=True) -> HostInfo:
    return HostInfo(os="linux", is_gentoo=True, has_docker=docker, has_bash=True,
                    has_kvm=False, is_root=root, builder_image="hugmesh-builder")


# ── a clean config is clean (the guard against a checker that cries wolf) ───────────────
def test_a_clean_config_has_nothing_to_say():
    r = run(_clean())
    assert (r.ok, r.problems, r.warnings) == (True, [], [])
    assert r.kind == "config" and r.images == ["laptop.x86"]


def test_what_the_studio_itself_saves_is_never_reported(tmp_path):
    """Every key a saved config or envelope carries is a key the loader keeps: a rich
    config round-trips through save() with no unknown-key finding, flat and enveloped."""
    cfg = _mesh_cfg(
        domains=[Domain(name="acme.example", title="Acme",
                        optional_services=["akkoma"], tor=True)],
        users=[User(username="ann", domain="acme.example", email="ann@acme.example")],
        desktop_spec={"sessions": ["i3"],
                      "apps": [{"id": "x", "label": "X", "delivery": "native",
                                "atom": "app-misc/x", "flatpak": "", "remote": "flathub"}],
                      "extra_users": [{"name": "kid", "admin": False}]},
        optional_services=["akkoma", "tuwunel"], anubis="on")
    assert cc.unknown_keys(cfg.to_dict()) == []
    entry = WorklistEntry(role="omnibus", platform="x86", desktop_spec={"sessions": ["i3"]})
    env = _mesh(cfg, entry)
    assert cc.unknown_keys(env) == []
    path = tmp_path / "saved.json"
    cfg.save(str(path))
    assert cc.unknown_keys(json.loads(path.read_text())) == []


# ── G44/G59: a key the loader drops is reported, not dropped ───────────────────────────
def test_an_unknown_key_is_reported_with_the_name_it_probably_meant():
    d = _clean()
    d["bundle_sourc"] = False
    r = run(d)
    assert not r.ok
    [f] = r.problems
    assert f.check == cc.CHECK_UNKNOWN_KEY
    assert "'bundle_sourc'" in f.message and "did you mean 'bundle_source'" in f.message
    # ...and the loader really does drop it, which is why it must be said
    assert ImageConfig.from_dict(d).bundle_source is True


def test_unknown_keys_are_found_in_every_shape_the_loader_filters():
    d = _mesh(_mesh_cfg(domains=[Domain(name="acme.example")],
                        users=[User(username="ann", domain="acme.example")],
                        desktop_spec={"sessions": ["i3"]}))
    d["extra"] = 1
    d["base"]["bogus"] = 1
    d["base"]["domains"][0]["titel"] = "x"
    d["base"]["users"][0]["usernam"] = "x"
    d["base"]["desktop_spec"]["sesions"] = []
    d["entries"][0]["colour"] = "x"
    d["entries"][0]["desktop_spec"] = {"sesions": []}
    # rows nested a level deeper inside the Desktop spec are filtered by its loader too
    d["base"]["desktop_spec"]["apps"] = [{"id": "x", "label": "X", "delivry": "flatpak"}]
    d["base"]["desktop_spec"]["extra_users"] = [{"name": "kid", "adming": True}]
    said = "\n".join(f.message for f in cc.unknown_keys(d))
    for where in ("'extra'", "'base.bogus'", "'base.domains[0].titel'",
                  "'base.users[0].usernam'", "'base.desktop_spec.sesions'",
                  "'entries[0].colour'", "'entries[0].desktop_spec.sesions'",
                  "'base.desktop_spec.apps[0].delivry'",
                  "'base.desktop_spec.extra_users[0].adming'"):
        assert where in said, f"{where} not reported:\n{said}"
    # ...and the loader really drops them (which is why they must be said)
    spec = DesktopSpec.from_dict(d["base"]["desktop_spec"])
    assert spec.apps[0].delivery == "native" and spec.extra_users[0].admin is False


def test_a_spelling_the_loader_migrates_is_not_an_unknown_key():
    """``qemu_e2e`` and a domain's ``games`` are not fields, but from_dict moves them onto
    one that is: reporting them would call a config that loads fine malformed."""
    d = _clean()
    del d["qemu_device_tests"]                  # the old spelling alone: what an old save holds
    d["qemu_e2e"] = True
    d["domains"] = [{"name": "acme.example", "games": True}]
    assert cc.unknown_keys(d) == []
    cfg = ImageConfig.from_dict(d)
    assert cfg.qemu_device_tests is True
    assert cfg.domains[0].optional_services == ["games"]
    assert MIGRATED_CONFIG_KEYS == {"qemu_e2e"} and MIGRATED_DOMAIN_KEYS == {"games"}
    assert not MIGRATED_CONFIG_KEYS & set(ImageConfig.__dataclass_fields__)
    assert not MIGRATED_DOMAIN_KEYS & set(Domain.__dataclass_fields__)


def test_a_foreign_worklist_schema_is_a_load_problem():
    d = _mesh(_mesh_cfg())
    assert run(d).ok
    d["schema"] = "hugmesh-worklist/v9"
    r = run(d)
    assert [f.check for f in r.problems] == [cc.CHECK_LOAD]
    assert "hugmesh-worklist/v9" in r.problems[0].message


def test_a_value_the_loader_refuses_is_a_load_problem_not_a_traceback():
    d = _clean()
    d["tailscale"] = "maybe"
    d["not_a_key"] = 1
    r = run(d)
    assert not r.ok
    assert cc.CHECK_LOAD in checks(r.problems)
    assert cc.CHECK_UNKNOWN_KEY in checks(r.problems)      # still said alongside


def test_json_that_is_not_an_object_is_refused_as_input():
    with pytest.raises(ValueError, match="JSON object"):
        cc.check_data([1, 2])


# ── G44/G59: a name that is no service is not accepted ─────────────────────────────────
@pytest.mark.parametrize("field", ["optional_services", "exclude_services"])
def test_an_unknown_service_name_blocks(field):
    d = _clean()
    d[field] = ["akkoma", "akoma"]
    r = run(d)
    [f] = r.problems
    assert f.check == cc.CHECK_SERVICE
    assert f"{field}: unknown service 'akoma'" in f.message
    assert "did you mean 'akkoma'" in f.message


def test_every_list_a_service_name_can_sit_in_is_checked():
    cfg = _mesh_cfg(domains=[Domain(name="acme.example", optional_services=["matrix"])],
                    cluster_domain_services=["wiki"])
    cfg.domain_services_reviewed = [cfg.cluster_domain, "acme.example"]
    entry = WorklistEntry(role="omnibus", platform="x86", infra_services=("tor", "vpn"))
    said = say(run(_mesh(cfg, entry)).problems)
    assert "domains[acme.example].optional_services: unknown service 'matrix'" in said
    assert "cluster_domain_services: unknown service 'wiki'" in said
    assert "infra_services: 'vpn' is not a per-image service" in said
    assert "omnibus.x86" in said                     # named by its image


def test_what_the_builder_accepts_is_not_refused():
    """The sentinels, the one deselect spelling, a space-separated element (the builder
    word-splits it) and a registry name only a domain row can use all pass."""
    d = _clean()
    d["optional_services"] = ["none"]
    assert run(d).ok
    d["optional_services"] = ["all", "-anubis"]
    assert run(d).ok
    d["optional_services"] = ["no-anubis", "akkoma tuwunel"]
    assert run(d).ok
    d["optional_services"] = ["tor", "egress-vpn", "edge-ai", "headwind"]
    assert run(d).ok
    d["optional_services"] = []
    d["domains"] = [{"name": "acme.example", "optional_services": ["coturn", "anubis"]}]
    assert [f for f in run(d).problems if f.check == cc.CHECK_SERVICE] == []


@pytest.mark.parametrize("field,value,fragment", [
    ("optional_services", ["-games"], "only for anubis"),
    ("exclude_services", ["-anubis"], "write its plain name ('anubis')"),
    ("optional_services", "akkoma tuwunel", "must be a list of service names"),
    ("optional_services", [5], "is not a service name"),
    ("cluster_domain_services", ["all"], "unknown service 'all'"),
])
def test_a_spelling_or_shape_the_builder_refuses_blocks(field, value, fragment):
    d = _clean()
    d[field] = value
    r = run(d)
    assert fragment in say(r.problems), say(r.problems)


def test_a_service_no_builder_bakes_blocks_on_x86_and_warns_elsewhere():
    """coturn is switched on in the running cluster. The x86 builder dies on it after
    dispatch (a problem); the rpi5 one accepts and ignores it (a warning: never invent a
    constraint the builder does not have)."""
    x86 = _clean()
    x86["optional_services"] = ["coturn"]
    assert "no builder bakes" in say(run(x86).problems)
    rpi = ImageConfig(mode="cloud", role="pki", platform="rpi5").to_dict()
    rpi["optional_services"] = ["coturn"]
    r = run(rpi)
    assert not [f for f in r.problems if f.check == cc.CHECK_SERVICE]
    assert "no builder bakes" in say(r.warnings)


def test_the_service_sets_are_the_builders_and_the_registrys():
    """REGISTRY_SERVICES / BUILDER_SELECTABLE_SERVICES / BUILDER_DESELECTABLE_SERVICES
    are mirrored, not derived: they are equal to the x86 builder's own lines (which
    tests/stack/test-optional-services-exclude.sh holds equal to the registry), and the
    registry is read here too, so a service added in one place and not here is red."""
    script = _read("build-x86-host-stage4.sh")

    def line(name):
        m = re.search(rf'^{name}="([^"]*)"', script, re.M)
        assert m, f"build-x86-host-stage4.sh no longer declares {name}"
        return set(m.group(1).split())

    assert set(REGISTRY_SERVICES) == line("KNOWN_OPTIONAL_SERVICES")
    assert set(BUILDER_SELECTABLE_SERVICES) == line("SELECTABLE_OPTIONAL_SERVICES")
    assert set(BUILDER_DESELECTABLE_SERVICES) == line("DESELECTABLE_OPTIONAL_SERVICES")
    registry = set(re.findall(r"^\s+- slug: (\S+)\s*$",
                              _read("specs/cluster/optional-services.yaml"), re.M))
    assert set(REGISTRY_SERVICES) == registry
    assert set(BUILDER_SELECTABLE_SERVICES) <= set(REGISTRY_SERVICES)
    assert len(set(REGISTRY_SERVICES)) == len(REGISTRY_SERVICES)


# ── the gates the wizard puts between a config and a build ─────────────────────────────
def test_the_domain_services_gate_blocks_a_domain_nobody_configured():
    cfg = _mesh_cfg(domains=[Domain(name="acme.example")])
    r = run(_mesh(cfg))
    assert r.images == ["omnibus.x86"]
    [f] = [f for f in r.problems if f.check == cc.CHECK_DOMAIN_SERVICES]
    assert "acme.example" in f.message and "domain_services_reviewed" in f.message
    # the words are the CLI's: the GUI's remedy ("this screen") would be a dead end here
    assert "this screen" not in f.message
    cfg.domain_services_reviewed = ["acme.example", cfg.cluster_domain]
    assert run(_mesh(cfg)).ok


def test_the_identity_allowlist_blocks():
    d = _clean()
    d["brand"] = "not a brand!"
    [f] = run(d).problems
    assert f.check == cc.CHECK_IDENTITY and "brand" in f.message.lower()


def test_assembly_rules_are_reported_not_raised():
    """Two entries with one id (the loader refuses the envelope), an envelope with no
    images, a bad per-image hostname and two images that would bake one hostname (what
    materialize refuses) are the wizard's 'cannot assemble the build'."""
    cfg = _mesh_cfg()
    twice = _mesh(cfg, WorklistEntry(role="omnibus", platform="x86"),
                  WorklistEntry(role="omnibus", platform="x86"))
    assert "share id 'omnibus.x86'" in say(run(twice).problems)
    empty = _mesh(cfg)
    empty["entries"] = []
    assert "no images" in say(run(empty).problems)
    bad = _mesh(cfg, WorklistEntry(role="omnibus", platform="x86", hostname="bad host!"))
    assert [f.check for f in run(bad).problems] == [cc.CHECK_IDENTITY]
    same = _mesh(cfg, WorklistEntry(role="omnibus", platform="x86", hostname="node1"),
                 WorklistEntry(role="backend", platform="x86", hostname="node1"))
    [f] = run(same).problems
    assert f.check == cc.CHECK_IDENTITY and "same hostname" in f.message


def test_a_command_that_cannot_be_assembled_blocks():
    d = _clean()
    d["extra_flags"] = "--x 'unbalanced"
    [f] = run(d).problems
    assert f.check == cc.CHECK_COMMAND and "laptop.x86" == f.image
    assert "No closing quotation" in f.message


def test_scope_splits_blocking_from_advisory_the_way_the_review_does():
    """rpi5 + --standalone on a node role is a hard builder error (a problem); on x86 the
    builder accepts it and builds the wrong image (a warning)."""
    rpi = _mesh_cfg(role="backend", platform="rpi5", standalone=True)
    r = run(rpi.to_dict())
    assert any(f.check == cc.CHECK_SCOPE and "hard-errors" in f.message for f in r.problems)
    x86 = _mesh(_mesh_cfg(standalone=True), WorklistEntry(role="backend", platform="x86"))
    r = run(x86)
    assert not [f for f in r.problems if f.check == cc.CHECK_SCOPE]
    assert any(f.check == cc.CHECK_SCOPE and "silently wrong" in f.message
               for f in r.warnings)


def test_scope_reads_the_value_as_written_not_as_materialize_leaves_it():
    """materialize() resets ``standalone`` on a node, so the assembled image carries none
    and says nothing: the value the operator wrote is what the flat --print-command and
    worker channels hand a builder, and what the rule is for."""
    cfg = _mesh_cfg(role="backend", platform="rpi5", standalone=True)
    [(_entry, assembled)] = synthesize(cfg).materialize()
    assert assembled.standalone is False
    assert any("hard-errors" in f.message for f in run(cfg.to_dict()).problems)


def test_scope_names_the_image_only_when_the_images_differ():
    cfg = _mesh_cfg(nvidia_cuda=True, gpu_driver="amd-free")
    both = _mesh(cfg, WorklistEntry(role="backend-gpu", platform="x86"),
                 WorklistEntry(role="omnibus", platform="x86"))
    [f] = [f for f in run(both).problems if f.check == cc.CHECK_SCOPE]
    assert f.image == ""                              # every image has it: said once
    mixed = _mesh(cfg, WorklistEntry(role="backend-gpu", platform="x86"),
                  WorklistEntry(role="pki", platform="rpi5"))
    [f] = [f for f in run(mixed).problems if f.check == cc.CHECK_SCOPE]
    assert f.image == "backend-gpu.x86"               # the rpi5 builder has no such flag


def test_the_root_size_floor_blocks_what_the_gui_refuses():
    """G50: the floor was GUI-only. Same function, same words as the Build page."""
    d = ImageConfig(mode="cloud", role="laptop", platform="x86", img_size=1000).to_dict()
    [f] = run(d).problems
    assert f.check == cc.CHECK_ROOT_SIZE and f.image == "laptop.x86"
    cfg = ImageConfig.from_dict(d)
    [(eid, gui_words)] = root_size_floor.entry_errors(synthesize(cfg).entries, cfg)
    assert (eid, gui_words) == (f.image, f.message)
    d["img_size"] = 16384
    assert run(d).ok
    d["img_size"] = 0
    assert run(d).ok                                    # 0 = the role default


def test_the_floor_is_per_image_and_follows_the_images_own_axes():
    cfg = _mesh_cfg(img_size=12000)
    both = _mesh(cfg, WorklistEntry(role="omnibus", platform="x86"),      # floor 20480
                 WorklistEntry(role="backend", platform="x86"))           # floor 14336
    r = run(both)
    assert sorted(f.image for f in r.problems if f.check == cc.CHECK_ROOT_SIZE) == \
        ["backend.x86", "omnibus.x86"]
    ok = _mesh(_mesh_cfg(img_size=15000), WorklistEntry(role="backend", platform="x86"))
    assert not [f for f in run(ok).problems if f.check == cc.CHECK_ROOT_SIZE]


def test_the_floor_reads_the_entrys_own_desktop_and_the_configs_capable_flag():
    """The same axes the Build page feeds the floor: an entry's own desktop beats the
    config's (full 24576, thin 16384) and the config's capable (Plasma) flag lifts it."""
    cfg = ImageConfig(mode="mesh", role="desktop", platform="x86", img_size=20000)
    assert root_size_floor.entry_errors(
        [WorklistEntry(role="desktop", platform="x86", desktop="full")], cfg)
    assert not root_size_floor.entry_errors(
        [WorklistEntry(role="desktop", platform="x86")], cfg)
    cfg.capable = True
    assert root_size_floor.entry_errors(
        [WorklistEntry(role="desktop", platform="x86")], cfg)


# ── the preflight, with this host's facts ──────────────────────────────────────────────
def test_the_preflight_runs_the_wizards_and_names_its_findings(tmp_path):
    d = _clean()
    d["output_dir"] = str(tmp_path / "out")
    r = cc.check_data(d, generator_dir=GENERATOR_DIR, host=host(docker=False),
                      backend="docker")
    assert any(f.check == cc.CHECK_PREFLIGHT and "Docker daemon is not reachable" in f.message
               for f in r.problems), say(r.problems)
    # the same config, probes left out: nothing to say
    assert cc.check_data(d, generator_dir=GENERATOR_DIR, host=host(docker=False),
                         backend="docker", preflight=False).ok


def test_a_native_build_on_a_root_host_passes_the_preflight(tmp_path):
    d = _clean()
    d["output_dir"] = str(tmp_path / "out")
    r = cc.check_data(d, generator_dir=GENERATOR_DIR, host=host(root=True),
                      backend="native")
    assert r.ok, say(r.problems)


def test_a_missing_builder_script_is_a_preflight_problem(tmp_path):
    r = cc.check_data(_clean(), generator_dir=str(tmp_path), host=host(), backend="native")
    assert any(f.check == cc.CHECK_PREFLIGHT and "builder script" in f.message
               for f in r.problems)


def test_a_finding_both_gates_make_is_said_once(tmp_path):
    """scope_violations is a check of its own AND part of BuildDriver.preflight: a CUDA
    bake with a non-nvidia driver (which survives assembly, so both see it) is one line."""
    cfg = ImageConfig(mode="cloud", role="laptop", platform="x86", nvidia_cuda=True,
                      gpu_driver="amd-free", output_dir=str(tmp_path / "out"))
    r = cc.check_data(cfg.to_dict(), generator_dir=GENERATOR_DIR, host=host(),
                      backend="native")
    assert len([f for f in r.problems if "CUDA needs" in f.message]) == 1
    assert len([f for f in cc.check_data(cfg.to_dict(), preflight=False).problems
                if "CUDA needs" in f.message]) == 1


def test_an_image_specific_preflight_line_names_its_image(tmp_path, monkeypatch):
    from hugmesh_studio.core.build_driver import BuildDriver
    real = BuildDriver.preflight

    def fussy(self, cfg, backend=None):
        out = real(self, cfg, backend)
        return out + (["only this one"] if cfg.platform == "rpi5" else [])
    monkeypatch.setattr(BuildDriver, "preflight", fussy)
    cfg = _mesh_cfg(output_dir=str(tmp_path / "out"))
    env = _mesh(cfg, WorklistEntry(role="omnibus", platform="x86"),
                WorklistEntry(role="pki", platform="rpi5"))
    r = cc.check_data(env, generator_dir=GENERATOR_DIR, host=host(), backend="native")
    [f] = [f for f in r.problems if f.message == "only this one"]
    assert (f.check, f.image) == (cc.CHECK_PREFLIGHT, "pki.rpi5")


# ── secrets: a hand-written config may carry them; the report never repeats one ────────
@pytest.mark.parametrize("mode,role,platform", [
    ("standalone", "standalone-thick", "x86"), ("cloud", "laptop", "x86"),
    ("mesh", "omnibus", "x86"), ("mesh", "pki", "rpi5")])
def test_no_secret_or_value_of_the_config_reaches_the_report(tmp_path, mode, role, platform):
    """The loader accepts plaintext secrets from a hand-written file (``save()`` is what
    blanks them), so every gate has a chance to quote one. The findings name keys and the
    operator's own typo'd service names, and nothing else out of the file: not a secret
    field, not the value of an unknown key, not the text of a flag that cannot be parsed."""
    from hugmesh_studio.core.config import SECRET_FIELDS
    secrets = {
        "local_pass": "CANARY-local'\"$(x)\nline2", "luks_pass": "CANARY-luks\tTAB:colon",
        "user_password": "CANARY-user pass", "root_password": "CANARY-root;rm",
        "extra_local_passes": "kid:CANARY-extra\nbad line CANARY-extra2"}
    assert set(secrets) == set(SECRET_FIELDS), "a new secret field needs a canary here"
    d = ImageConfig(mode=mode, role=role, platform=platform).to_dict()
    d.update(secrets)
    d.update({"bogus": "CANARY-unknown-value", "optional_services": ["akoma", "CANARY-svc"],
              "img_size": 1000, "local_user": "ann", "extra_flags": "--x 'CANARY-quote",
              "output_dir": str(tmp_path / "out")})
    r = cc.check_data(d, generator_dir=GENERATOR_DIR, host=host(), backend="native")
    said = "\n".join(cc.format_report(r)) + json.dumps(r.to_dict())
    # the control: the report is not empty, and what IS the operator's to fix is quoted
    assert not r.ok and "'CANARY-svc'" in said and "'bogus'" in said
    # ...and the one name quoted from the file is the only canary that gets out
    assert said.replace("'CANARY-svc'", "").count("CANARY") == 0, said


# ── the report ─────────────────────────────────────────────────────────────────────────
def test_the_report_text_and_json_shape():
    d = _clean()
    d["bogus"] = 1
    r = run(d)
    assert r.to_dict() == {
        "ok": False, "kind": "config", "images": ["laptop.x86"],
        "problems": [{"check": "unknown-key", "image": "", "message": r.problems[0].message}],
        "warnings": []}
    lines = cc.format_report(r)
    assert lines[0] == "config: 1 image(s): laptop.x86"
    assert lines[1].startswith("problem  [unknown-key] unknown key 'bogus'")
    assert lines[-1] == "FAILED: 1 problem(s), 0 warning(s)"
    assert cc.format_report(run(_clean()))[-1] == "ok"


def test_run_cli_exit_status(tmp_path, capsys):
    good = tmp_path / "good.json"
    good.write_text(json.dumps(_clean()))
    bad = tmp_path / "bad.json"
    bad.write_text(json.dumps({**_clean(), "optional_services": ["akoma"]}))
    kw = dict(generator_dir=GENERATOR_DIR, host=host(), backend="native")
    # a clean config's preflight depends on the output dir: the default is the checkout's
    out = tmp_path / "out"
    cfg = json.loads(good.read_text())
    cfg["output_dir"] = str(out)
    good.write_text(json.dumps(cfg))
    assert cc.run_cli(str(good), **kw) == cc.EXIT_OK
    assert cc.run_cli(str(bad), **kw) == cc.EXIT_PROBLEMS
    assert cc.run_cli(str(tmp_path / "missing.json"), **kw) == cc.EXIT_BAD_INPUT
    notjson = tmp_path / "notjson.json"
    notjson.write_text("{nope")
    assert cc.run_cli(str(notjson), **kw) == cc.EXIT_BAD_INPUT
    arr = tmp_path / "arr.json"
    arr.write_text("[1]")
    assert cc.run_cli(str(arr), **kw) == cc.EXIT_BAD_INPUT
    err = capsys.readouterr().err
    assert err.count("error:") == 3 and "JSON object" in err
