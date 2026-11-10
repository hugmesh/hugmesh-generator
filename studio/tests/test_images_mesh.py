"""The node-image flow's mesh: save it before the build, start it locally while the
images build (core/images_mesh.py + the projection in core/local_mesh_domains.py).

Operator ask (2026-11-09): "when someone makes a mesh in the mesh node images studio
path, they should have the option to save that mesh before proceeding to the build as
well as starting that mesh locally as the build proceeds".

Pure core — no Qt. Every docker/proc probe the gate makes is passed in as a fake, so
the verdicts here are the same on any host; the one real-host check (the gate on
whatever this machine runs) only asserts it never raises.
"""
from __future__ import annotations

import copy
import json
import os
import subprocess

import pytest

from hugmesh_studio.core import images_mesh, local_stack_node, saved_meshes
from hugmesh_studio.core import host_resources as hr
from hugmesh_studio.core import resource_limits as rl
from hugmesh_studio.core.config import DOMAIN_IDP_OWN, Domain, ImageConfig, User
from hugmesh_studio.core.local_mesh_bootstrap import (LocalMeshBootstrap,
                                                      LocalMeshBootstrapConfig,
                                                      saved_mesh_choice_text)
from hugmesh_studio.core.local_mesh_domains import (apply_imported_domains,
                                                    apply_imported_tor,
                                                    bootstrap_config_from_images,
                                                    imported_mesh_domains)
from hugmesh_studio.core.worklist import WorklistConfig, WorklistEntry

GIB = hr.GIB
GENERATOR_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(
    __file__))))


def _images_cfg() -> ImageConfig:
    """A node-image mesh as the GUI walk leaves it: an apex, two added domains (one
    with its own Tor front door, one with its own sign-in), the own domain's services
    walked, Tor on, a superadmin account."""
    c = ImageConfig(mode="mesh", brand="acme", cluster_domain="acme.org")
    c.domains = [Domain(name="chat.acme.org", title="Chat",
                        optional_services=["tuwunel"], tor=True),
                 Domain(name="forum.acme.org", title="Forum",
                        optional_services=["phpbb"])]
    c.additional_domains = True
    c.cluster_domain_services = ["owncast"]
    c.domain_services_reviewed = ["acme.org", "chat.acme.org", "forum.acme.org"]
    c.tor_onion_service = True
    c.users = [User(username="root-of-acme", roles=["superadmin"])]
    return c


def _worklist(cfg) -> WorklistConfig:
    return WorklistConfig(base=cfg, entries=[
        WorklistEntry(role="mesh", platform="x86"),
        WorklistEntry(role="pki", platform="rpi5")])


def _meminfo(total_gib: float, avail_gib: float) -> dict:
    return {"MemTotal": int(total_gib * GIB), "MemAvailable": int(avail_gib * GIB),
            "SwapTotal": 0, "SwapFree": 0}


def _all_free(_port: int) -> bool:
    return True


def _auto(mi: dict) -> rl.ResourceLimits:
    """The Docker build's limits on a host with NO saved setting: the auto formula."""
    return rl.auto_limits(nproc=8, meminfo=mi)


# ── 1. the projection: ImageConfig -> LocalMeshBootstrapConfig ─────────────────────
def test_projection_round_trips_through_the_636_import():
    """Projecting the image config and importing it back (the #636 path "Create nodes
    for local cloud" uses) gives the same domains, own-domain services, reviewed
    markers and Tor — the projection is the import's inverse."""
    cfg = _images_cfg()
    boot = bootstrap_config_from_images(cfg, _worklist(cfg))
    # through JSON, as a saved record is: the reload after a restart is the same object
    boot = LocalMeshBootstrapConfig.from_dict(json.loads(json.dumps(boot.to_dict())))
    back = ImageConfig(mode="mesh", cluster_domain=boot.cluster_domain)
    md = imported_mesh_domains(boot)
    added = apply_imported_domains(back, md)
    apply_imported_tor(back, boot.effective_with_tor(), False)
    assert added == ["chat.acme.org", "forum.acme.org"]
    assert [(d.name, d.title, d.optional_services, d.tor) for d in back.domains] == \
        [(d.name, d.title, d.optional_services, d.tor) for d in cfg.domains]
    assert back.cluster_domain_services == cfg.cluster_domain_services
    assert sorted(back.domain_services_reviewed) == sorted(cfg.domain_services_reviewed)
    assert back.tor_onion_service is True
    assert boot.brand == "acme" and boot.superadmin_username == "root-of-acme"


def test_projection_carries_own_signin_and_leaves_cfg_untouched():
    cfg = _images_cfg()
    cfg.domains.append(Domain(name="own.acme.org", idp=DOMAIN_IDP_OWN))
    before = copy.deepcopy(cfg.to_dict())
    argv = cfg.to_cli_args()
    boot = bootstrap_config_from_images(cfg)
    assert boot.own_idp_domains == ("own.acme.org",)
    assert cfg.to_dict() == before, "the projection wrote into the image config"
    assert cfg.to_cli_args() == argv, "the builder argv changed"


def test_projection_of_an_untouched_flow_records_no_domain_rows():
    """A flow that never added a domain or walked its own services records () —
    the same emission neutrality bootstrap_domain_records keeps."""
    boot = bootstrap_config_from_images(ImageConfig(mode="mesh"))
    assert boot.domains == () and boot.domain_services_reviewed == ()
    assert boot.services == () and boot.with_tor is False


def test_projection_runs_only_mesh_plane_slugs_from_the_mesh_wide_list():
    cfg = ImageConfig(mode="mesh", optional_services=["tuwunel", "wiki"], anubis="on")
    boot = bootstrap_config_from_images(cfg)
    assert boot.services == ("anubis", "wiki")      # tuwunel is a per-domain slug


# ── 2. the record: save, overwrite, reload ────────────────────────────────────────
def test_save_writes_a_draft_record_that_reloads_after_a_restart():
    cfg = _images_cfg()
    res = images_mesh.save(GENERATOR_DIR, cfg, _worklist(cfg), label="acme mesh")
    assert res.ok, res.message
    rec = res.record
    # "after a restart": nothing in memory, a fresh read of the file
    again = saved_meshes.load(rec.path())
    assert again.label == "acme mesh"
    assert again.build == {"source": "images", "session_id": "",
                           "worklist_ids": ["mesh.x86", "pki.rpi5"]}
    assert again.build_text() == "from node images (2 images)"
    assert again.run_state() == "draft", "a save before any run must be a draft"
    assert again.lanes["compose_project"] == images_mesh.project_for(again.id)
    assert again.lanes["compose_project"] != "hugmesh-local"
    assert "auth_key" in again.blanked_secrets
    boot = LocalMeshBootstrap.for_record(GENERATOR_DIR, again).cfg
    assert [d["name"] for d in boot.domains] == ["acme.org", "chat.acme.org",
                                                  "forum.acme.org"]
    assert "from node images (2 images)" in saved_mesh_choice_text(again)


def test_second_save_and_dispatch_save_overwrite_one_record():
    cfg = _images_cfg()
    first = images_mesh.save(GENERATOR_DIR, cfg, _worklist(cfg)).record
    cfg.domains[0].title = "Chat (renamed)"
    second = images_mesh.save(GENERATOR_DIR, cfg, _worklist(cfg), record_id=first.id)
    assert second.ok and second.record.id == first.id
    assert second.record.label == first.label          # an empty name keeps the name
    # dispatch: the session id joins the SAME record
    third = images_mesh.save(GENERATOR_DIR, cfg, _worklist(cfg), record_id=first.id,
                             session_id="20261110-010101-abcdef")
    assert third.record.id == first.id
    # a RESTART of that session (no record id in hand) finds it by the session
    fourth = images_mesh.save(GENERATOR_DIR, cfg, None,
                              session_id="20261110-010101-abcdef")
    assert fourth.record.id == first.id
    assert fourth.record.build["worklist_ids"] == ["mesh.x86", "pki.rpi5"]
    recs, bad = saved_meshes.scan()
    assert [r.id for r in recs] == [first.id] and not bad
    assert recs[0].config["domains"][1]["title"] == "Chat (renamed)"


def test_a_taken_name_is_refused_and_nothing_is_written():
    cfg = _images_cfg()
    images_mesh.save(GENERATOR_DIR, cfg, None, label="taken")
    res = images_mesh.save(GENERATOR_DIR, cfg, None, label="Taken ")
    assert not res.ok and "already called" in res.message
    assert len(saved_meshes.scan()[0]) == 1


def test_a_record_without_the_build_key_still_loads():
    rec = saved_meshes.SavedMesh(id=saved_meshes.new_id(), label="old")
    d = rec.to_dict()
    d.pop("build")
    loaded = saved_meshes.SavedMesh.from_dict(d)
    assert loaded.build == {} and loaded.build_text() == ""
    d["build"] = "junk"
    assert saved_meshes.SavedMesh.from_dict(d).build == {}


def test_save_never_raises(monkeypatch):
    def boom(*_a, **_k):
        raise RuntimeError("docker exploded")
    monkeypatch.setattr(saved_meshes, "capture", boom)
    res = images_mesh.save(GENERATOR_DIR, _images_cfg(), None)
    assert not res.ok and "docker exploded" in res.message


# ── 3. the gate ────────────────────────────────────────────────────────────────
def _boot(**kw):
    return bootstrap_config_from_images(ImageConfig(mode="mesh", **kw))


def test_gate_refuses_while_another_mesh_holds_casdoor_8000():
    plan = images_mesh.plan_alongside(
        _boot(), building=False, meminfo=_meminfo(64, 60), env={},
        is_free=lambda p: p != 8000, holder=lambda p: "hugmesh-local-casdoor-1")
    assert not plan.ok
    assert any("8000" in r and "hugmesh-local-casdoor-1" in r for r in plan.reasons)


def test_gate_checks_the_social_ports_only_with_the_social_tier():
    social = bootstrap_config_from_images(ImageConfig(
        mode="mesh", cluster_domain="a.org",
        domains=[Domain(name="m.a.org", optional_services=["tuwunel"])]))
    free_but_3000 = lambda p: p != 3000   # noqa: E731
    assert not images_mesh.plan_alongside(social, building=False,
                                          meminfo=_meminfo(64, 60), env={},
                                          is_free=free_but_3000,
                                          holder=lambda p: "").ok
    assert images_mesh.plan_alongside(_boot(), building=False, meminfo=_meminfo(64, 60),
                                      env={}, is_free=free_but_3000,
                                      holder=lambda p: "").ok


def test_gate_refuses_on_the_31gib_host_while_the_build_holds_its_cap():
    """The measured host: 31 GiB, the build's default cap ~23 GiB, the operator's
    mesh using ~6 GiB — no room for a second mesh while the build runs."""
    mi = _meminfo(31.1, 24.0)
    plan = images_mesh.plan_alongside(_boot(), building=True, backend="docker",
                                      limits=_auto(mi), meminfo=mi, env={},
                                      is_free=_all_free, holder=lambda p: "")
    assert not plan.ok
    assert any("not enough memory" in r for r in plan.reasons)


def test_gate_allows_a_big_host_and_names_its_ports():
    mi = _meminfo(128, 120)
    plan = images_mesh.plan_alongside(_boot(), building=True, backend="docker",
                                      limits=_auto(mi), meminfo=mi, env={},
                                      is_free=_all_free, holder=lambda p: "")
    assert plan.ok, plan.reasons
    assert set(plan.ports) == {"PUBLIC_HOST_PORT", "PUBLIC_HTTPS_PORT",
                               "TOR_SOCKS_HOST_PORT", "ANUBIS_HOST_PORT"}
    assert 8088 not in plan.ports.values() and 8488 not in plan.ports.values()


def test_gate_refuses_an_uncapped_build_and_own_casdoor_domains():
    plan = images_mesh.plan_alongside(_boot(), building=True, backend="docker",
                                      meminfo=_meminfo(128, 120),
                                      env={hr.MEMORY_ENV: "off"},
                                      is_free=_all_free, holder=lambda p: "")
    assert not plan.ok and any("no cap" in r and "starve" in r for r in plan.reasons)
    own = bootstrap_config_from_images(ImageConfig(
        mode="mesh", domains=[Domain(name="o.example.org", idp=DOMAIN_IDP_OWN)]))
    plan = images_mesh.plan_alongside(own, building=False, meminfo=_meminfo(128, 120),
                                      env={}, is_free=_all_free, holder=lambda p: "")
    assert not plan.ok and any("own Casdoor" in r for r in plan.reasons)


def test_gate_estimate_is_overridable():
    env = {images_mesh.MESH_MEMORY_ENV: "1g"}
    plan = images_mesh.plan_alongside(_boot(), building=False, meminfo=_meminfo(8, 6),
                                      env=env, is_free=_all_free, holder=lambda p: "")
    assert plan.ok and plan.need_bytes == GIB


def test_free_ports_skip_taken_ones():
    ports = images_mesh.free_ports(lambda p: p not in (18088, 18089))
    assert ports["PUBLIC_HOST_PORT"] == 18090


def test_gate_on_this_host_never_raises():
    for backend in ("docker", "native", None):
        plan = images_mesh.plan_alongside(_boot(), building=True, backend=backend)
        assert isinstance(plan.ok, bool) and plan.lines()


# ── 4. start / stop beside the build ───────────────────────────────────────────
@pytest.fixture
def saved():
    cfg = _images_cfg()
    return images_mesh.save(GENERATOR_DIR, cfg, _worklist(cfg)).record


def test_a_refused_start_starts_nothing_and_creates_no_worktree(saved, monkeypatch):
    called = []
    monkeypatch.setattr(LocalMeshBootstrap, "up",
                        lambda *a, **k: called.append("up") or (True, []))
    lane = images_mesh.AlongsideMesh(GENERATOR_DIR, saved)
    lines = []
    mi = _meminfo(31.1, 24.0)
    ok, _ = lane.start(building=True, backend="docker", limits=_auto(mi),
                       on_line=lines.append, meminfo=mi, env={}, is_free=_all_free,
                       holder=lambda p: "")
    assert not ok and not called
    assert not os.path.exists(lane.worktree)
    assert any("not enough memory" in ln for ln in lines)


def _scratch_repo(tmp_path) -> str:
    repo = tmp_path / "gen"
    repo.mkdir()
    env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t",
               GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")
    for cmd in (["git", "init", "-q"], ["git", "commit", "-q", "--allow-empty", "-m", "x"]):
        subprocess.run(cmd, cwd=repo, check=True, env=env)
    return str(repo)


def test_a_gated_start_runs_in_its_own_project_worktree_and_ports(saved, tmp_path,
                                                                    monkeypatch):
    repo = _scratch_repo(tmp_path)
    seen = {}

    def fake_up(self, on_line=None, cancel=None):
        node = self._stack_node()
        env = node._build_env(write_overlays=False)
        seen.update(gen=self.generator_dir, project=node.project, env=env,
                    cfg=self.cfg)
        return True, []
    monkeypatch.setattr(LocalMeshBootstrap, "up", fake_up)
    lane = images_mesh.AlongsideMesh(repo, saved)
    mi = _meminfo(128, 120)
    ok, lines = lane.start(building=True, backend="docker", limits=_auto(mi),
                           meminfo=mi, env={}, is_free=_all_free, holder=lambda p: "")
    assert ok, lines
    assert os.path.isdir(os.path.join(lane.worktree, ".git")) or \
        os.path.isfile(os.path.join(lane.worktree, ".git"))
    assert seen["gen"] == lane.worktree != repo
    assert seen["project"] == images_mesh.project_for(saved.id)
    env = seen["env"]
    assert env["COMPOSE_PROJECT_NAME"] == seen["project"]
    assert env["PUBLIC_HOST_PORT"] == "18088" and env["PUBLIC_HTTPS_PORT"] == "18488"
    assert env["FRONT_DOOR"] == "http://localhost:18088"
    assert env["STACK_NO_CLONE"] == "1"           # the source tree is never reset
    assert seen["cfg"].env == "test" and seen["cfg"].auth_key == ""
    assert seen["cfg"].out_dir.startswith(lane.worktree)
    rec = saved_meshes.load(saved.path())
    assert rec.lanes["host_ports"]["PUBLIC_HOST_PORT"] == 18088
    assert rec.run_state() == "ran"


def test_a_failing_start_returns_false_and_never_raises(saved, tmp_path, monkeypatch):
    def boom(*_a, **_k):
        raise RuntimeError("compose fell over")
    monkeypatch.setattr(LocalMeshBootstrap, "up", boom)
    lane = images_mesh.AlongsideMesh(_scratch_repo(tmp_path), saved)
    ok, lines = lane.start(building=False, meminfo=_meminfo(128, 120), env={},
                           is_free=_all_free, holder=lambda p: "")
    assert not ok and any("compose fell over" in ln for ln in lines)


def test_stop_halts_only_this_project_and_never_the_overlay(saved, tmp_path,
                                                             monkeypatch):
    from hugmesh_studio.core import mesh_node
    calls = []
    monkeypatch.setattr(LocalMeshBootstrap, "down",
                        lambda *a, **k: calls.append("bootstrap.down") or (True, []))
    monkeypatch.setattr(mesh_node.MeshNode, "stop",
                        lambda *a, **k: calls.append("overlay.stop") or (True, ""))

    def fake_stop(node):
        calls.append(("stack.stop", node.project,
                      node._build_env(write_overlays=False)["COMPOSE_PROJECT_NAME"]))
        return True, ""
    monkeypatch.setattr(local_stack_node.LocalStackNode, "stop", fake_stop)
    monkeypatch.setattr(local_stack_node.LocalStackNode, "status",
                        lambda self: local_stack_node.StackStatus(True, "3 container(s)"))
    lane = images_mesh.AlongsideMesh(_scratch_repo(tmp_path), saved)
    assert lane.stop()[0] is True                       # never started: nothing to do
    assert calls == []
    os.makedirs(lane.worktree)
    ok, lines = lane.stop()
    assert ok, lines
    project = images_mesh.project_for(saved.id)
    assert calls == [("stack.stop", project, project)]


# ── 5. the stack node's project parameter ─────────────────────────────────────
def test_default_stack_node_env_is_unchanged():
    env = local_stack_node.LocalStackNode(GENERATOR_DIR)._build_env(write_overlays=False)
    assert "COMPOSE_PROJECT_NAME" not in env or \
        env["COMPOSE_PROJECT_NAME"] == os.environ.get("COMPOSE_PROJECT_NAME")
    assert local_stack_node.LocalStackNode(GENERATOR_DIR)._project_args() == []


def test_other_project_moves_every_published_port():
    node = local_stack_node.LocalStackNode(
        GENERATOR_DIR, project="hugmesh-img-abc",
        host_ports={"PUBLIC_HOST_PORT": 18088, "PUBLIC_HTTPS_PORT": 18488,
                    "TOR_SOCKS_HOST_PORT": 19050, "ANUBIS_HOST_PORT": 18923})
    env = node._build_env(write_overlays=False)
    assert env["COMPOSE_PROJECT_NAME"] == "hugmesh-img-abc"
    assert (env["PUBLIC_HOST_PORT"], env["PUBLIC_HTTPS_PORT"], env["TOR_SOCKS_HOST_PORT"],
            env["ANUBIS_HOST_PORT"]) == ("18088", "18488", "19050", "18923")
    assert node.web_url == "https://localhost:18488"
    assert node._project_args() == ["-p", "hugmesh-img-abc"]
    assert "label=com.docker.compose.project=hugmesh-img-abc" in \
        local_stack_node._tor_ps_filters(node.project)


# ── 6. CLI parity ──────────────────────────────────────────────────────────────
def test_cli_saves_a_worklist_and_gates_it(tmp_path, capsys):
    cfg = _images_cfg()
    path = tmp_path / "wl.json"
    path.write_text(json.dumps(_worklist(cfg).to_dict()), encoding="utf-8")
    rc = images_mesh.main(["--generator-dir", GENERATOR_DIR, "save", str(path),
                           "--label", "from the cli"])
    out = capsys.readouterr().out
    assert rc == 0, out
    rid = out.strip().splitlines()[-1].split("id: ", 1)[1]
    rec = saved_meshes.find(rid)
    assert rec.label == "from the cli" and rec.build["worklist_ids"] == ["mesh.x86",
                                                                          "pki.rpi5"]
    rc = images_mesh.main(["--generator-dir", GENERATOR_DIR, "gate", rid])
    assert rc in (0, 1)
    assert "beside the build" in capsys.readouterr().out


# ── 7. PR #937 round 2: a record with its own project is NEVER driven as the ───────
#       checkout's hugmesh-local (for_record, mesh-restore, start_saved, down/clean)
_SENTINEL = "E2E_PASSWORD=operator-live-mesh-do-not-touch\n"


@pytest.fixture
def checkout(tmp_path):
    """A scratch generator checkout standing in for the operator's: a git repo with
    the operator's live ``.e2e-credentials`` in it."""
    repo = _scratch_repo(tmp_path)
    os.makedirs(os.path.join(repo, ".stack-src"))
    with open(os.path.join(repo, ".e2e-credentials"), "w", encoding="utf-8") as fh:
        fh.write(_SENTINEL)
    return repo


@pytest.fixture
def makes(monkeypatch):
    """Every `make` a LocalStackNode would run, recorded instead of run — with the
    directory it runs in, its compose project and the env it would export. The host
    probes in front of it say yes, so the ONLY thing between a record and a `make`
    is the code under test."""
    seen: list[dict] = []

    def fake_make(self, target, timeout, extra_env=None, on_line=None, cancel=None,
                  args=None):
        env = self._build_env(extra_env, write_overlays=False)
        seen.append({"target": target, "cwd": self.generator_dir,
                     "project": self.project,
                     "COMPOSE_PROJECT_NAME": env.get("COMPOSE_PROJECT_NAME", ""),
                     "PUBLIC_HOST_PORT": env.get("PUBLIC_HOST_PORT", ""),
                     "FRONT_DOOR": env.get("FRONT_DOOR", "")})
        return True, "ok"
    LSN = local_stack_node.LocalStackNode
    monkeypatch.setattr(LSN, "_make", fake_make)
    monkeypatch.setattr(LSN, "available", lambda self: (True, ""))
    monkeypatch.setattr(LSN, "preflight", lambda self: [])
    monkeypatch.setattr(LSN, "cold_build_expected", lambda self: False)
    monkeypatch.setattr(LSN, "_write_looks", lambda self: None)
    monkeypatch.setattr(LSN, "status",
                        lambda self: local_stack_node.StackStatus(False, "not started"))
    monkeypatch.setattr(LocalMeshBootstrap, "preflight", lambda self: [])
    monkeypatch.setattr(LocalMeshBootstrap, "validate", lambda self: [])
    monkeypatch.setattr(LocalMeshBootstrap, "_await_onion", lambda self, *a, **k: "")
    monkeypatch.setattr(LocalMeshBootstrap, "read_superadmin",
                        lambda self: {"username": "sa", "password": "pw"})
    from hugmesh_studio.core import mesh_node
    monkeypatch.setattr(mesh_node.MeshNode, "stop",
                        lambda self: seen.append({"target": "overlay-stop"}) or
                        (True, ""))
    # what the machine says for the record: volumes gone, nothing running — RESEED
    monkeypatch.setattr(saved_meshes, "probe_state", lambda rec, project="": seen.append(
        {"target": "probe_state"}) or {
        "volumes_present": False, "volumes_seen": 0, "volumes_missing": (),
        "images_present": True, "creds_match": False, "mesh_running": False,
        "unanswered": (), "source_ok": True, "source_drift": (),
        "copies_missing": ()})
    return seen


def _img_record(checkout):
    cfg = _images_cfg()
    res = images_mesh.save(checkout, cfg, _worklist(cfg))
    assert res.ok, res.message
    return res.record


def _sentinel_intact(checkout) -> bool:
    with open(os.path.join(checkout, ".e2e-credentials"), encoding="utf-8") as fh:
        return fh.read() == _SENTINEL


def test_a_draft_img_record_never_reaches_make_or_the_checkout(checkout, makes,
                                                               capsys):
    """The round-1 refutation: a hugmesh-img-<id> draft (saved, never started beside a
    build) restored from a saved record ran `make stack-up` + `stack-seed` in the
    operator's checkout on hugmesh-local. Now every acting door refuses with one
    sentence and no `make` runs anywhere."""
    from hugmesh_studio.core import local_mesh_bootstrap as lmb
    rec = _img_record(checkout)
    assert saved_meshes.is_own_project(rec)
    assert rec.compose_project() == images_mesh.project_for(rec.id)
    boot = LocalMeshBootstrap.for_record(checkout, rec)
    assert boot.project == images_mesh.project_for(rec.id)
    assert os.path.abspath(boot.generator_dir) != os.path.abspath(checkout)
    assert "never been started" in boot.lane_refusal
    assert boot.e2e_credentials_path() != os.path.join(checkout, ".e2e-credentials")
    for verb in (lambda: boot.restore(rec), lambda: boot.start_saved(rec),
                 boot.up, boot.down, boot.clean):
        ok, lines = verb()
        assert ok is False
        assert any("never been started" in ln for ln in lines), lines
    assert boot.guard_host_local()[0] is False
    # the CLI door: refused before any probe, rc 1
    rc = lmb.main(["mesh-restore", rec.id, "--generator-dir", checkout])
    out = capsys.readouterr().out
    assert rc == 1 and "[refused]" in out and "never been started" in out
    assert makes == []
    assert _sentinel_intact(checkout)


def test_an_img_record_whose_worktree_is_gone_refuses(checkout, makes):
    rec = _img_record(checkout)
    rec.lanes["host_ports"] = {"PUBLIC_HOST_PORT": 18088, "PUBLIC_HTTPS_PORT": 18488}
    saved_meshes.save(rec)
    boot = LocalMeshBootstrap.for_record(checkout, rec)
    assert "is gone" in boot.lane_refusal
    ok, lines = boot.restore(rec)
    assert not ok and any("is gone" in ln for ln in lines)
    assert makes == [] and _sentinel_intact(checkout)


def test_an_img_record_restores_only_its_own_project_in_its_own_worktree(
        checkout, makes, capsys):
    """With its worktree and ports recorded (it ran beside a build), mesh-restore of
    a hugmesh-img-<id> record runs `make stack-up` + `stack-seed` IN THAT WORKTREE,
    exporting ITS project and ports — never in the checkout, never on hugmesh-local,
    and the checkout's .e2e-credentials is not read or written."""
    from hugmesh_studio.core import local_mesh_bootstrap as lmb
    rec = _img_record(checkout)
    wt = rec.lanes["worktree"]
    os.makedirs(os.path.join(wt, ".git"))
    rec.lanes["host_ports"] = {"PUBLIC_HOST_PORT": 18090, "PUBLIC_HTTPS_PORT": 18490,
                               "TOR_SOCKS_HOST_PORT": 19051, "ANUBIS_HOST_PORT": 18924}
    saved_meshes.save(rec)
    # the record's credential pointer is ITS worktree's file, not the operator's
    assert rec.credentials["e2e_file"]["path"] == os.path.join(wt, ".e2e-credentials")
    rc = lmb.main(["mesh-restore", rec.id, "--generator-dir", checkout])
    out = capsys.readouterr().out
    assert rc == 0, out
    targets = [m["target"] for m in makes]
    assert "stack-up" in targets and "stack-seed" in targets, targets
    project = images_mesh.project_for(rec.id)
    makes[:] = [m for m in makes if m["target"] != "probe_state"]
    for m in makes:
        assert m.get("target") != "overlay-stop"
        assert m["cwd"] == wt, m
        assert m["project"] == project and m["COMPOSE_PROJECT_NAME"] == project, m
        assert m["PUBLIC_HOST_PORT"] == "18090"
        assert m["FRONT_DOOR"] == "http://localhost:18090"
    assert _sentinel_intact(checkout)


def test_stopping_an_img_record_never_stops_the_overlay_or_the_checkout(checkout,
                                                                        makes):
    rec = _img_record(checkout)
    os.makedirs(os.path.join(rec.lanes["worktree"], ".git"))
    rec.lanes["host_ports"] = {"PUBLIC_HOST_PORT": 18090}
    saved_meshes.save(rec)
    stops = []
    monkey_stop = lambda self: stops.append((self.generator_dir, self.project)) \
        or (True, "")                                      # noqa: E731
    local_stack_node.LocalStackNode.stop, orig = monkey_stop, \
        local_stack_node.LocalStackNode.stop
    try:
        ok, lines = LocalMeshBootstrap.for_record(checkout, rec).down()
    finally:
        local_stack_node.LocalStackNode.stop = orig
    assert ok, lines
    assert stops == [(rec.lanes["worktree"], images_mesh.project_for(rec.id))]
    assert not any(m.get("target") == "overlay-stop" for m in makes)


def test_a_checkout_record_still_runs_in_the_checkout(checkout, makes):
    """The default lane is unchanged: a record saved on the local-mesh page (no
    project, or hugmesh-local) drives the checkout, with no project exported."""
    rec = saved_meshes.SavedMesh(id=saved_meshes.new_id(), label="plain",
                                 generator_dir=checkout,
                                 config=LocalMeshBootstrapConfig().to_dict())
    assert not saved_meshes.is_own_project(rec)
    boot = LocalMeshBootstrap.for_record(checkout, rec)
    assert boot.generator_dir == os.path.abspath(checkout)
    assert boot.project == "" and boot.lane_refusal == ""
    rec.lanes = {"compose_project": "hugmesh-local"}
    assert not saved_meshes.is_own_project(rec)


def test_restore_plan_names_the_records_own_project_when_it_runs(checkout):
    rec = _img_record(checkout)
    plan = saved_meshes.restore_plan(rec, volumes_present=True, images_present=True,
                                     mesh_running=True)
    assert plan.mode == saved_meshes.MODE_BLOCKED
    assert images_mesh.project_for(rec.id) in plan.sentence


def test_the_monitor_lists_and_scales_the_nodes_own_project():
    """mesh_monitor drives the project of the node it is given: a scale of a
    hugmesh-img-<id> node can never land on hugmesh-local."""
    from hugmesh_studio.core import mesh_monitor as mm
    node = local_stack_node.LocalStackNode(GENERATOR_DIR, project="hugmesh-img-abc",
                                           host_ports={"PUBLIC_HOST_PORT": 18088})
    assert mm._node_project(node) == "hugmesh-img-abc"
    assert mm._node_project(local_stack_node.LocalStackNode(GENERATOR_DIR)) == \
        "hugmesh-local"
    unit = mm.MeshUnit(lane="compose", namespace="hugmesh-img-abc", name="x",
                       owner="hugmesh-fe-gateway", phase="Running", ready=True,
                       reason="", state="ok",
                       scale=mm.ScaleTarget("compose-service", "hugmesh-fe-gateway",
                                            "hugmesh-img-abc", refused=""))
    argv, refused = mm.scale_argv(unit, 2, generator_dir=GENERATOR_DIR, node=node)
    if refused:                         # no docker compose on this host
        pytest.skip(refused)
    i = argv.index("-p")
    assert argv[i + 1] == "hugmesh-img-abc"


def test_the_monitor_lists_the_nodes_own_project_never_hugmesh_local(monkeypatch):
    """The compose lane of the Mesh Monitor lists the node's project: `compose ps`
    carries `-p hugmesh-img-<id>` (the compose file's own name is hugmesh-local), the
    `docker ps` fallback filters on that project's label, and every row's controls
    and scale target name it."""
    from hugmesh_studio.core import mesh_monitor as mm
    seen = []

    class Node:
        project = "hugmesh-img-abc"
        compose_file = "/x/tests/stack/compose.local.yaml"
        public_https_port, public_host_port, web_url = 18488, 18088, ""

        def status(self):
            return local_stack_node.StackStatus(True, "1 container(s)")

        def _probe(self, cmd, timeout):
            seen.append(list(cmd))
            if "compose" in cmd:
                return 1, "rejected"            # force the docker-ps fallback too
            return 0, json.dumps({"Names": "hugmesh-img-abc-hugmesh-fe-gateway-1",
                                  "State": "running", "Status": "Up",
                                  "Labels": "com.docker.compose.project=hugmesh-img-abc,"
                                            "com.docker.compose.service="
                                            "hugmesh-fe-gateway"})

        def onion_url(self):
            return ""
    monkeypatch.setattr(mm.shutil, "which", lambda name: "/usr/bin/" + name)
    monkeypatch.setattr(mm, "_compose_base", lambda: ["docker", "compose"])
    lane, units, _notes, _errors = mm._compose_units(
        Node(), GENERATOR_DIR, None, {}, mm._Budget(30))
    compose_ps = next(c for c in seen if "compose" in c)
    assert compose_ps[compose_ps.index("-p") + 1] == "hugmesh-img-abc"
    docker_ps = next(c for c in seen if "compose" not in c)
    assert "label=com.docker.compose.project=hugmesh-img-abc" in docker_ps
    assert "hugmesh-local" not in " ".join(" ".join(c) for c in seen)
    assert "hugmesh-img-abc" in lane.detail
    assert units and all(u.namespace == "hugmesh-img-abc" for u in units)
    assert all(u.scale.namespace == "hugmesh-img-abc" for u in units if u.scale.kind)


# ── 8. PR #937 round 2: the memory gate subtracts the cap the build REALLY gets ──
def test_gate_refuses_beside_a_native_build_even_on_a_big_host():
    """Native builds run on the host under sudo with NO cgroup cap; the gate used to
    subtract HUGMESH_BUILD_MEMORY's auto value anyway and say ok on 128 GiB."""
    plan = images_mesh.plan_alongside(_boot(), building=True, backend="native",
                                      meminfo=_meminfo(128, 120), env={},
                                      is_free=_all_free, holder=lambda p: "")
    assert not plan.ok
    assert any("native build" in r and "no memory cap" in r for r in plan.reasons)


def test_gate_refuses_when_the_backend_is_not_said():
    plan = images_mesh.plan_alongside(_boot(), building=True,
                                      meminfo=_meminfo(128, 120), env={},
                                      is_free=_all_free, holder=lambda p: "")
    assert not plan.ok and any("backend" in r for r in plan.reasons)
    # not building: the build's backend does not matter
    assert images_mesh.plan_alongside(_boot(), building=False,
                                      meminfo=_meminfo(128, 120), env={},
                                      is_free=_all_free, holder=lambda p: "").ok


@pytest.fixture
def saved_limits(tmp_path, monkeypatch):
    """The operator's SAVED GUI resource limits, in a throwaway config dir."""
    monkeypatch.setenv("XDG_CONFIG_HOME", str(tmp_path / "xdg"))
    monkeypatch.delenv(hr.MEMORY_ENV, raising=False)
    return lambda **kw: rl.save(rl.ResourceLimits(**kw))


def test_gate_reads_a_saved_all_memory_setting_as_no_cap(saved_limits):
    """Saved 'all memory' -> `docker run` gets no --memory; the gate used to read
    HUGMESH_BUILD_MEMORY's auto value instead and report ~20 GiB of headroom."""
    saved_limits(cpus=4.0, memory=None)
    assert rl.effective(env={}).memory is None
    plan = images_mesh.plan_alongside(_boot(), building=True, backend="docker",
                                      meminfo=_meminfo(128, 120), env={},
                                      is_free=_all_free, holder=lambda p: "")
    assert not plan.ok
    assert any("all memory" in r and "no cap" in r for r in plan.reasons)


def test_gate_subtracts_a_saved_115g_cap(saved_limits):
    saved_limits(cpus=4.0, memory="115g")
    plan = images_mesh.plan_alongside(_boot(), building=True, backend="docker",
                                      meminfo=_meminfo(128, 120), env={},
                                      is_free=_all_free, holder=lambda p: "")
    assert not plan.ok and any("not enough memory" in r for r in plan.reasons)
    assert plan.headroom_bytes == 120 * GIB - hr.HOST_RESERVE_BYTES - 115 * GIB


def test_gate_env_cap_wins_over_the_saved_setting(saved_limits):
    saved_limits(cpus=4.0, memory=None)
    plan = images_mesh.plan_alongside(_boot(), building=True, backend="docker",
                                      meminfo=_meminfo(128, 120),
                                      env={hr.MEMORY_ENV: "20g"},
                                      is_free=_all_free, holder=lambda p: "")
    assert plan.ok, plan.reasons
    assert plan.headroom_bytes == 120 * GIB - hr.HOST_RESERVE_BYTES - 20 * GIB


def test_gate_cap_matches_what_the_docker_build_argv_carries(saved_limits):
    """One source: the cap the gate subtracts is the --memory build_driver puts on
    `docker run`."""
    from hugmesh_studio.core import build_driver
    saved_limits(cpus=4.0, memory="17g")
    argv = build_driver.docker_limit_args()
    assert argv[argv.index("--memory") + 1] == "17g"
    assert images_mesh.build_memory_cap("docker", env={})[1] == "17g"


def test_cli_gate_says_which_backend_it_gated(saved_limits, tmp_path, capsys):
    cfg = _images_cfg()
    rid = images_mesh.save(GENERATOR_DIR, cfg, _worklist(cfg)).record.id
    rc = images_mesh.main(["--generator-dir", GENERATOR_DIR, "gate", rid,
                           "--backend", "native"])
    out = capsys.readouterr().out
    assert rc == 1 and "native build" in out
