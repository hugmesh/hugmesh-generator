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
                                                             monkeypatch, fake_docker):
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
    # never started: nothing of its project runs (asked by label), nothing to do
    assert lane.stop()[0] is True
    assert calls == [] and fake_docker.downs == []
    os.makedirs(os.path.join(lane.worktree, ".git"))
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
    # every fixed host port free (this host may well run hugmesh-local on 8000)
    monkeypatch.setattr(images_mesh, "port_free", lambda p: True)
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
                                                               fake_docker, capsys):
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
                 boot.up, boot.clean):
        ok, lines = verb()
        assert ok is False
        assert any("never been started" in ln for ln in lines), lines
    # down() is a STOP (PR #937 round 4): a draft whose first `make stack-up` died on
    # a port can leave hugmesh-img-<id> containers running with no ports recorded, so
    # it asks docker by the record's own project label — never make, never the
    # checkout. Nothing of it runs here: nothing is stopped, and it says so.
    ok, lines = boot.down()
    assert ok is True and any("nothing to stop" in ln for ln in lines), lines
    assert fake_docker.downs == []
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


def test_an_img_record_is_refused_while_another_mesh_holds_casdoor(checkout, makes,
                                                                   monkeypatch):
    """With its worktree and ports in place but hugmesh-local up on 8000, a restore
    refuses BEFORE `make stack-up` — naming the holder — instead of creating the
    record's containers and dying on the bind."""
    rec = _img_record(checkout)
    os.makedirs(os.path.join(rec.lanes["worktree"], ".git"))
    rec.lanes["host_ports"] = {"PUBLIC_HOST_PORT": 18090}
    saved_meshes.save(rec)
    monkeypatch.setattr(images_mesh, "port_free", lambda p: p != 8000)
    monkeypatch.setattr(images_mesh, "port_holder",
                        lambda p: "hugmesh-local-casdoor-1")
    boot = LocalMeshBootstrap.for_record(checkout, rec)
    assert boot.lane_refusal == ""
    for verb in (lambda: boot.restore(rec), lambda: boot.start_saved(rec)):
        ok, lines = verb()
        assert not ok
        assert any("8000" in ln and "hugmesh-local-casdoor-1" in ln for ln in lines)
    assert not [m for m in makes if m["target"] != "probe_state"]
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


# ── 9. PR #937 round 3 ─────────────────────────────────────────────────────────
#  (1) every images_mesh verb refuses a record it did not make, writing nothing,
#      and a failed start leaves its own record byte-identical;
#  (2) the "worktree is gone" remedy really starts the mesh (stale registration);
#  (3) cleaning an own-project mesh never removes the shared m2 registry;
#  (4) the REVERSE collision: hugmesh-local refuses while an img mesh holds 8000.
def _record_bytes(rec) -> bytes:
    with open(rec.path(), "rb") as fh:
        return fh.read()


def _checkout_record(checkout, **lanes) -> saved_meshes.SavedMesh:
    """A record saved on the local-mesh page: the checkout's own hugmesh-local."""
    rec = saved_meshes.SavedMesh(id=saved_meshes.new_id(), label="operator mesh",
                                 generator_dir=checkout,
                                 config=LocalMeshBootstrapConfig().to_dict(),
                                 lanes=dict(lanes))
    assert saved_meshes.save(rec)
    return rec


@pytest.fixture
def no_host_gate(monkeypatch):
    """The start gate says yes on any host (this one may run hugmesh-local on 8000
    and be short of memory) and every git/make a start would run is recorded: the
    ONLY thing between a verb and a write is the code under test."""
    monkeypatch.setattr(images_mesh, "plan_alongside", lambda *a, **k:
                        images_mesh.AlongsidePlan(ok=True, ports={
                            "PUBLIC_HOST_PORT": 18088, "PUBLIC_HTTPS_PORT": 18488,
                            "TOR_SOCKS_HOST_PORT": 19050,
                            "ANUBIS_HOST_PORT": 18923}))
    ups = []
    monkeypatch.setattr(LocalMeshBootstrap, "up", lambda self, **k: ups.append(
        self.generator_dir) or (False, ["[stack-up] FAILED: no docker here"]))
    return ups


@pytest.mark.parametrize("lanes", [{}, {"compose_project": "hugmesh-local"}],
                         ids=["no-project", "hugmesh-local"])
def test_round3_every_images_verb_refuses_a_checkout_record_and_writes_nothing(
        checkout, no_host_gate, tmp_path, capsys, lanes):
    """The round-2 refutation: `images_mesh start <default id> --not-building`
    rewrote a hugmesh-local record's compose project to hugmesh-img-<id> (+worktree,
    ports) even when the start FAILED, and `save --record <default id>` did the same.
    Now gate/start/stop/save --record each refuse with a sentence, rc 2, and the
    record file is byte-identical; no worktree is made, no up runs."""
    rec = _checkout_record(checkout, **lanes)
    before = _record_bytes(rec)
    cfg_path = tmp_path / "images.json"
    cfg_path.write_text(json.dumps(_images_cfg().to_dict()), encoding="utf-8")
    verbs = (["gate", rec.id, "--not-building"], ["start", rec.id, "--not-building"],
             ["stop", rec.id], ["save", str(cfg_path), "--record", rec.id])
    for verb in verbs:
        rc = images_mesh.main(["--generator-dir", checkout, *verb])
        err = capsys.readouterr()
        assert rc == 2, (verb, err)
        assert "this checkout's own mesh" in err.err + err.out, (verb, err)
        assert _record_bytes(rec) == before, verb
    assert no_host_gate == []
    assert not os.path.exists(images_mesh.worktree_path(rec.id))
    assert len(saved_meshes.scan()[0]) == 1           # save made no new record either
    # save() itself refuses too (the GUI's Save strip and the dispatch save call it)
    res = images_mesh.save(checkout, _images_cfg(), None, record_id=rec.id)
    assert not res.ok and "this checkout's own mesh" in res.message
    assert _record_bytes(rec) == before and len(saved_meshes.scan()[0]) == 1
    # the lane itself refuses too (the GUI builds it directly)
    lane = images_mesh.AlongsideMesh(checkout, saved_meshes.find(rec.id))
    ok, lines = lane.start(building=False)
    assert not ok and any("this checkout's own mesh" in ln for ln in lines)
    ok, lines = lane.stop()
    assert not ok and any("this checkout's own mesh" in ln for ln in lines)
    assert _record_bytes(rec) == before and no_host_gate == []
    assert _sentinel_intact(checkout)


def test_round3_a_record_not_saved_from_images_is_refused_too(checkout, no_host_gate,
                                                              capsys):
    """Its own compose project but no images build pointer (hand-made, or another
    flow): the node-image verbs do not act on it either."""
    rec = _checkout_record(checkout, compose_project="hugmesh-other")
    before = _record_bytes(rec)
    assert images_mesh.foreign_record_refusal(rec)
    rc = images_mesh.main(["--generator-dir", checkout, "start", rec.id,
                           "--not-building"])
    assert rc == 2 and "not saved from the node-image flow" in capsys.readouterr().err
    assert _record_bytes(rec) == before and no_host_gate == []
    # ...while a record this flow made is accepted
    assert images_mesh.foreign_record_refusal(_img_record(checkout)) == ""


@pytest.mark.parametrize("failure", ["returns-false", "raises"])
def test_round3_a_failed_start_leaves_the_images_record_byte_identical(
        checkout, monkeypatch, failure):
    rec = _img_record(checkout)
    before = _record_bytes(rec)

    def up(self, on_line=None, cancel=None):
        if failure == "raises":
            raise RuntimeError("compose fell over")
        return False, ["[stack-up] FAILED"]
    monkeypatch.setattr(LocalMeshBootstrap, "up", up)
    lane = images_mesh.AlongsideMesh(checkout, rec)
    ok, _lines = lane.start(building=False, meminfo=_meminfo(128, 120), env={},
                            is_free=_all_free, holder=lambda p: "")
    assert not ok
    assert os.path.exists(os.path.join(lane.worktree, ".git"))   # it got that far
    assert _record_bytes(rec) == before
    assert "host_ports" not in saved_meshes.find(rec.id).lanes


def _git_worktrees(repo) -> list[str]:
    out = subprocess.run(["git", "-C", repo, "worktree", "list", "--porcelain"],
                         capture_output=True, text=True, check=True).stdout
    return [ln.split(" ", 1)[1] for ln in out.splitlines() if ln.startswith("worktree ")]


def test_round3_the_gone_worktree_remedy_really_starts_the_mesh(checkout, tmp_path,
                                                                monkeypatch, capsys):
    """Deleting a record's worktree directory leaves it REGISTERED in the checkout;
    the refusal says "Start it again with `... start <id> --not-building`, which
    makes a new one", and that command died in `git worktree add` ("missing but
    already registered worktree"). Run here, verbatim, it now makes the worktree and
    reaches the bring-up — and another worktree of the checkout that still exists
    is untouched (prune drops only registrations whose directory is gone)."""
    import re
    import shutil
    rec = _img_record(checkout)
    lane = images_mesh.AlongsideMesh(checkout, rec)
    ok, msg = lane.prepare_worktree()
    assert ok, msg
    rec.lanes["host_ports"] = {"PUBLIC_HOST_PORT": 18090, "PUBLIC_HTTPS_PORT": 18490}
    saved_meshes.save(rec)
    other = str(tmp_path / "someone-elses-worktree")
    subprocess.run(["git", "-C", checkout, "worktree", "add", "-q", "--detach", other,
                    "HEAD"], check=True, capture_output=True)
    shutil.rmtree(lane.worktree)
    refusal = LocalMeshBootstrap.for_record(checkout, rec).lane_refusal
    assert "is gone" in refusal
    cmd = re.search(r"`python -m hugmesh_studio\.core\.images_mesh ([^`]+)`",
                    refusal).group(1).split()
    assert cmd[:2] == ["start", rec.id]
    # the host gate says yes (this host may hold 8000 / be short of memory)
    monkeypatch.setattr(images_mesh, "port_free", lambda p: True)
    monkeypatch.setenv(images_mesh.MESH_MEMORY_ENV, "1")
    ups = []
    monkeypatch.setattr(LocalMeshBootstrap, "up", lambda self, **k: ups.append(
        self.generator_dir) or (True, []))
    rc = images_mesh.main(["--generator-dir", checkout, *cmd])
    out = capsys.readouterr().out
    assert rc == 0, out
    assert "git worktree add failed" not in out
    assert ups == [lane.worktree]
    assert os.path.exists(os.path.join(lane.worktree, ".git"))
    assert LocalMeshBootstrap.for_record(checkout, saved_meshes.find(rec.id)) \
        .lane_refusal == ""
    assert other in _git_worktrees(checkout) and os.path.isdir(other)


def test_round3_cleaning_an_own_project_keeps_the_shared_m2_registry(monkeypatch):
    """`make stack-clean` ends with `docker rm -f hugmesh-m2-registry` — ONE container
    per host, the one the checkout's hugmesh-local builds from. A clean of a
    hugmesh-img-<id> mesh passes STACK_CLEAN_KEEP_M2=1; the checkout's own clean is
    unchanged."""
    seen = []

    def fake_make(self, target, timeout, extra_env=None, on_line=None, cancel=None,
                  args=None):
        seen.append((self.project, target, list(args or ())))
        return True, "ok"
    monkeypatch.setattr(local_stack_node.LocalStackNode, "_make", fake_make)
    # no hugmesh-img-* mesh up (round 4 asks docker for the checkout's own clean)
    monkeypatch.setattr(local_stack_node, "running_img_projects", lambda: [])
    local_stack_node.LocalStackNode(GENERATOR_DIR, project="hugmesh-img-abc").clean()
    local_stack_node.LocalStackNode(GENERATOR_DIR).clean()
    assert seen == [("hugmesh-img-abc", "stack-clean", ["STACK_CLEAN_KEEP_M2=1"]),
                    ("hugmesh-local", "stack-clean", [])]


def test_round3_an_own_project_records_clean_carries_the_keep_knob(checkout, makes,
                                                                   monkeypatch):
    """The whole path: Saved meshes -> Stop && clean of an img record."""
    rec = _img_record(checkout)
    os.makedirs(os.path.join(rec.lanes["worktree"], ".git"))
    rec.lanes["host_ports"] = {"PUBLIC_HOST_PORT": 18090}
    saved_meshes.save(rec)
    argv = []
    orig = local_stack_node.LocalStackNode._make

    def spy(self, target, timeout, extra_env=None, on_line=None, cancel=None,
            args=None):
        argv.append((self.generator_dir, target, list(args or ())))
        return orig(self, target, timeout, extra_env, on_line, cancel, args)
    monkeypatch.setattr(local_stack_node.LocalStackNode, "_make", spy)
    ok, lines = LocalMeshBootstrap.for_record(checkout, rec).clean()
    assert ok, lines
    assert argv == [(rec.lanes["worktree"], "stack-clean", ["STACK_CLEAN_KEEP_M2=1"])]


def test_round3_the_makefile_keep_knob_drops_the_registry_removal():
    """What the knob does to the recipe (`make -n`: printed, never run)."""
    import shutil
    if not shutil.which("make"):
        pytest.skip("no make on this host")

    def recipe(*extra):
        r = subprocess.run(["make", "-n", "-s", "-C", GENERATOR_DIR, "stack-clean",
                            *extra], capture_output=True, text=True, timeout=120)
        assert r.returncode == 0, r.stderr[-2000:]
        return r.stdout
    plain = recipe()
    kept = recipe("STACK_CLEAN_KEEP_M2=1")
    assert "docker rm -f hugmesh-m2-registry" in plain
    assert "rm -f tests/stack/.m2-registry.env" in plain
    assert "docker rm -f hugmesh-m2-registry" not in kept
    assert ".m2-registry.env" not in kept
    assert "down -v --rmi local" in kept                # the project's own clean stays


def test_round3_hugmesh_local_refuses_while_an_img_mesh_holds_casdoor(checkout, makes,
                                                                      monkeypatch):
    """The REVERSE collision: with a hugmesh-img-<id> mesh up on 8000, a start or
    restore of the checkout's own hugmesh-local refused nothing up front — `make
    stack-up` created its containers and died on the bind. Now up / start_saved /
    restore refuse before any `make`, naming the holder and how to stop it."""
    img = _img_record(checkout)
    holder = images_mesh.project_for(img.id) + "-casdoor-1"
    monkeypatch.setattr(images_mesh, "port_free", lambda p: p != 8000)
    monkeypatch.setattr(images_mesh, "port_holder", lambda p: holder)
    # (round 4: "another local mesh" and its stop remedy only for a holder whose
    # compose project LABEL is hugmesh-img-*)
    monkeypatch.setattr(images_mesh, "container_project",
                        lambda name: images_mesh.project_for(img.id))
    rec = _checkout_record(checkout)
    boot = LocalMeshBootstrap(checkout, LocalMeshBootstrapConfig())
    assert not boot._own_project()
    why = boot.fixed_port_refusal()
    assert "8000" in why and holder in why
    assert f"images_mesh stop {img.id}" in why
    for verb in (boot.up, lambda: boot.start_saved(rec), lambda: boot.restore(rec)):
        ok, lines = verb()
        assert ok is False
        assert any(holder in ln and "8000" in ln for ln in lines), lines
    assert not [m for m in makes if m["target"] != "probe_state"], makes
    assert _sentinel_intact(checkout)


@pytest.mark.parametrize("holder,label", [
    ("hugmesh-local-casdoor-1", ""),             # the checkout's own mesh, already up
    ("hugmesh-casdoor", "hugmesh-local"),        # ditto, by its compose label
    ("", ""),                                     # not a container docker can name
])
def test_round3_hugmesh_local_is_not_refused_over_its_own_casdoor(monkeypatch, holder,
                                                                  label):
    """A warm re-up or restore of the RUNNING hugmesh-local finds 8000 held by its
    own Casdoor: that is not a collision, and an unnamed holder is not refused on
    a guess."""
    monkeypatch.setattr(images_mesh, "port_free", lambda p: p != 8000)
    monkeypatch.setattr(images_mesh, "port_holder", lambda p: holder)
    monkeypatch.setattr(images_mesh, "container_project", lambda name: label)
    boot = LocalMeshBootstrap(GENERATOR_DIR, LocalMeshBootstrapConfig())
    assert boot.fixed_port_refusal() == ""


def test_round3_m2_bootstrap_is_not_refused_over_the_fixed_ports(monkeypatch):
    """The fixed-port check lives in _prepare/start_saved, not in guard_host_local:
    building the maven registry binds none of those ports."""
    monkeypatch.setattr(images_mesh, "port_free", lambda p: False)
    monkeypatch.setattr(images_mesh, "port_holder", lambda p: "hugmesh-img-zzz-casdoor-1")
    monkeypatch.setattr(images_mesh, "container_project", lambda name: "")
    monkeypatch.setattr(local_stack_node.LocalStackNode, "available",
                        lambda self: (True, ""))
    monkeypatch.setattr(LocalMeshBootstrap, "_in_cluster_pod", lambda self: False)
    monkeypatch.setattr(LocalMeshBootstrap, "overlay_will_attach", lambda self: False)
    assert LocalMeshBootstrap(GENERATOR_DIR, LocalMeshBootstrapConfig()) \
        .guard_host_local() == (True, "")


# ── 10. PR #937 round 4 ────────────────────────────────────────────────────────
#  (1) a node-image mesh whose worktree is GONE still stops — by its own compose
#      project label, through the one stop path (CLI, Saved meshes Stop, down());
#  (2) the stale-registration fix drops only THIS record's registration;
#  (3) the reverse refusal says "another local mesh" only for a hugmesh-img-* holder;
#  (4) STACK_CLEAN_KEEP_M2: only 1/true/yes keep the registry;
#  (5) hugmesh-local's own clean keeps the registry while an img mesh is up.
class _FakeDocker:
    """`docker ps -q --filter label=com.docker.compose.project=<p>` and `docker compose
    -p <p> down` against an in-memory set of running containers. Every other command
    runs for real (git in the scratch checkout); any OTHER docker call (a save's
    `docker volume ls`) answers as a docker that is not there, and is kept apart."""

    def __init__(self, real_run):
        self.real_run = real_run
        self.running: dict[str, list[str]] = {}
        self.downs: list[list[str]] = []
        self.calls: list[list[str]] = []
        self.other: list[list[str]] = []
        # per compose call: (cwd, --project-directory, what cwd held, COMPOSE_* seen)
        self.compose_dirs: list[tuple] = []

    def __call__(self, argv, *a, **kw):
        argv = [str(x) for x in argv] if isinstance(argv, (list, tuple)) else argv
        if not isinstance(argv, list) or argv[:1] != ["docker"]:
            return self.real_run(argv, *a, **kw)
        if argv[1:3] == ["compose", "--project-directory"]:
            # the label stop runs from an EMPTY dir that is its project directory
            # (studio-lows follow-up to #937 round 4); recorded, then matched as
            # the plain `docker compose -p <p> down` it is
            cwd = kw.get("cwd")
            env = kw.get("env")
            self.compose_dirs.append((
                cwd, argv[3], sorted(os.listdir(cwd)) if cwd and os.path.isdir(cwd)
                else None,
                None if env is None else sorted(k for k in env
                                                if k.upper().startswith("COMPOSE_"))))
            argv = argv[:2] + argv[4:]
        if not (argv[1:3] == ["ps", "-q"] or argv[1:3] == ["compose", "-p"]):
            self.other.append(argv)
            return subprocess.CompletedProcess(argv, 1, "", "no docker here")
        self.calls.append(argv)
        if argv[1:3] == ["ps", "-q"] and argv[3] == "--filter":
            proj = argv[4].split("=", 2)[2]
            out = "\n".join(self.running.get(proj, []))
            return subprocess.CompletedProcess(argv, 0, out, "")
        if argv[1:3] == ["compose", "-p"] and argv[4:] == ["down"]:
            self.downs.append(argv)
            self.running.pop(argv[3], None)
            return subprocess.CompletedProcess(argv, 0, "", "")
        raise AssertionError(f"unexpected docker compose call: {argv}")


@pytest.fixture
def fake_docker(monkeypatch):
    fd = _FakeDocker(subprocess.run)
    monkeypatch.setattr(subprocess, "run", fd)
    monkeypatch.setattr(local_stack_node, "_compose_base", lambda: ["docker", "compose"])
    return fd


def _ran_then_worktree_gone(checkout):
    """An img record that ran beside its build (worktree + ports recorded), whose
    worktree directory was then deleted while its containers stayed up."""
    import shutil
    rec = _img_record(checkout)
    lane = images_mesh.AlongsideMesh(checkout, rec)
    ok, msg = lane.prepare_worktree()
    assert ok, msg
    rec.lanes["host_ports"] = {"PUBLIC_HOST_PORT": 18090, "PUBLIC_HTTPS_PORT": 18490}
    saved_meshes.save(rec)
    shutil.rmtree(lane.worktree)
    return saved_meshes.find(rec.id)


def test_round4_a_gone_worktree_mesh_stops_by_its_label_and_frees_casdoor(
        checkout, makes, fake_docker, monkeypatch, capsys):
    """The round-3 refutation: hugmesh-local refused ("stop it first (`images_mesh
    stop <id>` ...)") while a hugmesh-img mesh held 8000, and that very command, with
    the worktree deleted, printed "nothing to stop (... never started here)" and
    stopped nothing — so the refusal stayed. Now the remedy, run verbatim, stops the
    project by its compose label (`docker compose -p <it> down`, no -v), and the
    refusal is gone."""
    import re
    rec = _ran_then_worktree_gone(checkout)
    proj = saved_meshes.record_project(rec)
    fake_docker.running[proj] = ["c-casdoor", "c-gateway"]
    # 8000 is held exactly while that project runs
    monkeypatch.setattr(images_mesh, "port_free",
                        lambda p: not (p == 8000 and fake_docker.running.get(proj)))
    monkeypatch.setattr(images_mesh, "port_holder", lambda p: f"{proj}-casdoor-1")
    monkeypatch.setattr(images_mesh, "container_project", lambda name: proj)
    boot = LocalMeshBootstrap(checkout, LocalMeshBootstrapConfig())
    why = boot.fixed_port_refusal()
    assert "another local mesh" in why and "Stop on its row in Saved meshes" in why
    cmd = re.search(r"`python -m hugmesh_studio\.core\.images_mesh ([^`]+)`",
                    why).group(1).split()
    assert cmd == ["stop", rec.id]
    rc = images_mesh.main(["--generator-dir", checkout, *cmd])
    out = capsys.readouterr()
    assert rc == 0, out
    assert "nothing to stop" not in out.out and "stopped " + proj in out.out
    assert fake_docker.downs == [["docker", "compose", "-p", proj, "down"]]
    assert boot.fixed_port_refusal() == ""
    # never make, never the checkout's project, never the overlay
    assert not [m for m in makes if m["target"] != "probe_state"]
    assert not any("hugmesh-local" in " ".join(c) for c in fake_docker.calls)
    assert _sentinel_intact(checkout)


def test_round4_down_of_a_gone_worktree_record_is_the_same_label_stop(checkout, makes,
                                                                      fake_docker):
    """Saved meshes / mesh-restore drive a record through for_record: its down() used
    to refuse with lane_refusal while the containers kept 8000."""
    rec = _ran_then_worktree_gone(checkout)
    proj = saved_meshes.record_project(rec)
    fake_docker.running[proj] = ["c1"]
    boot = LocalMeshBootstrap.for_record(checkout, rec)
    assert "is gone" in boot.lane_refusal                # Start/Restore still refuse
    ok, lines = boot.down()
    assert ok, lines
    assert fake_docker.downs == [["docker", "compose", "-p", proj, "down"]]
    assert not any(m.get("target") == "overlay-stop" for m in makes)
    # clean still refuses: it needs the worktree's Makefile
    ok, lines = boot.clean()
    assert not ok and any("is gone" in ln for ln in lines)
    # nothing left running: a second stop says so and runs no down
    ok, lines = images_mesh.AlongsideMesh(checkout, rec).stop()
    assert ok and any("nothing to stop" in ln for ln in lines)
    assert len(fake_docker.downs) == 1


@pytest.mark.parametrize("project", [
    "hugmesh-local", "hugmesh-mesh", "", "hugmesh-img-", "hugmesh-img-a b",
    "hugmesh-img-x;rm", "other-img-abc"])
def test_round4_a_label_stop_never_names_any_other_project(checkout, fake_docker,
                                                           project):
    """Whatever a (hand-edited) record says, the label stop acts on a hugmesh-img-<id>
    project only — never the checkout's hugmesh-local or the overlay's hugmesh-mesh."""
    fake_docker.running[project] = ["c1"]
    assert images_mesh.label_stop_refusal(project)
    ok, lines = images_mesh.halt_by_label(project)
    assert not ok and "refused" in lines[0]
    rec = _img_record(checkout)
    rec.lanes["compose_project"] = project or "x"
    if project:
        ok, lines = images_mesh.AlongsideMesh(checkout, rec).stop()
        assert not ok
    assert fake_docker.calls == [] and fake_docker.downs == []


def test_round4_a_failed_label_stop_says_so(checkout, fake_docker, monkeypatch):
    rec = _ran_then_worktree_gone(checkout)
    proj = saved_meshes.record_project(rec)
    fake_docker.running[proj] = ["c1"]

    def stuck(argv, *a, **kw):
        if list(argv)[:2] == ["docker", "compose"]:
            return subprocess.CompletedProcess(argv, 1, "", "permission denied")
        return fake_docker(argv, *a, **kw)
    monkeypatch.setattr(subprocess, "run", stuck)
    ok, lines = images_mesh.AlongsideMesh(checkout, rec).stop()
    assert not ok and "FAILED" in lines[0] and "still running" in lines[0]


def test_round4_the_stale_registration_fix_drops_only_this_records_one(checkout,
                                                                       tmp_path):
    """Round 3 ran an UNSCOPED `git worktree prune` in the operator's checkout: it
    also dropped every other session's registration whose directory was merely not
    reachable (an unmounted eCryptfs home). Two missing registrations here — ours and
    another session's: only ours goes, the other stays registered."""
    import shutil
    rec = _img_record(checkout)
    lane = images_mesh.AlongsideMesh(checkout, rec)
    ok, msg = lane.prepare_worktree()
    assert ok, msg
    other = str(tmp_path / "unmounted" / "another-sessions-worktree")
    subprocess.run(["git", "-C", checkout, "worktree", "add", "-q", "--detach", other,
                    "HEAD"], check=True, capture_output=True)
    shutil.rmtree(lane.worktree)
    shutil.rmtree(other)
    regs = _git_worktrees(checkout)
    assert lane.worktree in regs and other in regs        # both missing, both registered
    ok, msg = lane.prepare_worktree()
    assert ok, msg
    regs = _git_worktrees(checkout)
    assert other in regs, "another session's registration was pruned"
    assert regs.count(lane.worktree) == 1 and os.path.isdir(lane.worktree)


def test_round4_a_present_registration_is_never_dropped(checkout, tmp_path):
    other = str(tmp_path / "live-worktree")
    subprocess.run(["git", "-C", checkout, "worktree", "add", "-q", "--detach", other,
                    "HEAD"], check=True, capture_output=True)
    assert images_mesh.drop_stale_registration(checkout, other) == ""
    assert other in _git_worktrees(checkout) and os.path.isdir(other)


@pytest.mark.parametrize("holder,label,mesh", [
    ("myapp-web-1", "myapp", False),             # another compose project
    ("lonely-postgres", "", False),              # a plain `docker run` container
    ("hugmesh-mesh-casdoor-1", "hugmesh-mesh", False),
    ("hugmesh-img-abc-casdoor-1", "hugmesh-img-abc", True),
    ("hugmesh-img-abc-casdoor-1", "", False),    # a NAME alone never makes it a mesh
])
def test_round4_the_reverse_refusal_names_a_mesh_only_for_a_hugmesh_img_holder(
        monkeypatch, holder, label, mesh):
    monkeypatch.setattr(images_mesh, "port_free", lambda p: p != 8000)
    monkeypatch.setattr(images_mesh, "port_holder", lambda p: holder)
    monkeypatch.setattr(images_mesh, "container_project", lambda name: label)
    why = LocalMeshBootstrap(GENERATOR_DIR, LocalMeshBootstrapConfig()) \
        .fixed_port_refusal()
    assert "8000" in why and holder in why
    if mesh:
        assert "another local mesh (hugmesh-img-abc)" in why
        assert "not a HugMesh mesh" not in why
    else:
        assert "another local mesh" not in why
        assert "not a HugMesh mesh" in why
        assert "images_mesh stop" not in why and "Saved meshes" not in why
        assert (f"its compose project is {label}" if label else
                "it belongs to no compose project") in why


def _clean_recipe(*extra):
    import shutil
    if not shutil.which("make"):
        pytest.skip("no make on this host")
    r = subprocess.run(["make", "-n", "-s", "-C", GENERATOR_DIR, "stack-clean", *extra],
                       capture_output=True, text=True, timeout=120)
    assert r.returncode == 0, r.stderr[-2000:]
    return r.stdout


@pytest.mark.parametrize("value,kept", [
    ("1", True), ("true", True), ("yes", True),
    ("0", False), ("false", False), ("no", False), ("", False)])
def test_round4_only_1_true_yes_keep_the_registry(value, kept):
    """Round 3 kept the registry for ANY non-empty value: STACK_CLEAN_KEEP_M2=0 kept it."""
    out = _clean_recipe(f"STACK_CLEAN_KEEP_M2={value}")
    assert ("docker rm -f hugmesh-m2-registry" not in out) is kept, out
    assert (".m2-registry.env" not in out) is kept, out
    assert "down -v --rmi local" in out


@pytest.mark.parametrize("up,keep,says", [
    (["hugmesh-img-abc"], True, "hugmesh-img-abc is running"),
    (None, True, "docker could not say"),
    ([], False, ""),
])
def test_round4_hugmesh_locals_clean_keeps_the_registry_while_an_img_mesh_is_up(
        checkout, makes, monkeypatch, up, keep, says):
    """'Stop && clean Docker' of the checkout's own hugmesh-local ran `make
    stack-clean` with no knob — `docker rm -f hugmesh-m2-registry` — while a
    hugmesh-img mesh beside it was up and building from that registry. Now that part
    is refused with a sentence and the rest of the clean runs; what the argv does to
    the recipe is checked with `make -n`."""
    monkeypatch.setattr(local_stack_node, "running_img_projects", lambda: up,
                        raising=False)   # so it also runs (and fails) on the round-3 code
    argv = []

    def spy(self, target, timeout, extra_env=None, on_line=None, cancel=None,
            args=None):
        argv.append((self.project, target, list(args or ())))
        return True, "make output"
    monkeypatch.setattr(local_stack_node.LocalStackNode, "_make", spy)
    streamed = []
    ok, lines = LocalMeshBootstrap(checkout, LocalMeshBootstrapConfig()).clean(
        on_line=streamed.append)
    assert ok, lines
    assert argv == [("hugmesh-local", "stack-clean",
                     ["STACK_CLEAN_KEEP_M2=1"] if keep else [])]
    recipe = _clean_recipe(*argv[0][2])
    assert ("docker rm -f hugmesh-m2-registry" in recipe) is (not keep)
    assert "down -v --rmi local" in recipe               # the rest of the clean runs
    if keep:
        assert any(says in ln and "KEPT" in ln for ln in streamed), streamed
        # a buffered caller sees it too
        _ok, msg = local_stack_node.LocalStackNode(checkout).clean()
        assert says in msg and "make output" in msg
    else:
        assert not any("KEPT" in ln for ln in streamed)


def test_round4_the_img_project_probe_reads_compose_labels(monkeypatch):
    """The real probe behind running_img_projects (pinned to [] suite-wide by
    conftest): hugmesh-img-* labels only, de-duplicated; a docker that does not
    answer is None (the clean then keeps the registry and says why)."""
    out = "hugmesh-local\nhugmesh-img-abc\n\nhugmesh-img-abc\nmyapp\nhugmesh-img-z9\n"
    seen = []

    def fake(argv, *a, **kw):
        seen.append(list(argv))
        return subprocess.CompletedProcess(argv, 0, out, "")
    monkeypatch.setattr(subprocess, "run", fake)
    assert local_stack_node.probe_running_img_projects() == ["hugmesh-img-abc",
                                                             "hugmesh-img-z9"]
    assert seen[0][:2] == ["docker", "ps"] and "-a" not in seen[0]
    monkeypatch.setattr(subprocess, "run", lambda argv, *a, **kw:
                        subprocess.CompletedProcess(argv, 1, "", "denied"))
    assert local_stack_node.probe_running_img_projects() is None


# ── 11. #937 round-4 refute follow-ups (studio-lows) ───────────────────────────
#  (1) the native Windows gate comes FIRST in down() (before the record's lane
#      stop) and guards the CLI `images_mesh stop` / halt_by_label too;
#  (2) an unanswered `docker inspect` is said as such, never "not a HugMesh mesh";
#  (3) the four mutations the refuter found surviving are killed here;
#  (4) the KEPT sentence's plural;
#  (5) the label stop runs from an empty project directory, with no COMPOSE_* env.
def _pin_native_windows(monkeypatch):
    from functools import partial
    from hugmesh_studio.core import platform_info
    monkeypatch.setattr(platform_info, "native_windows_blocker",
                        partial(platform_info.native_windows_blocker, osname="nt"))


def test_followup_down_on_native_windows_refuses_before_the_lane_stop(
        checkout, makes, fake_docker):
    rec = _ran_then_worktree_gone(checkout)
    proj = saved_meshes.record_project(rec)
    fake_docker.running[proj] = ["c1"]
    boot = LocalMeshBootstrap.for_record(checkout, rec)
    assert callable(boot.lane_stop) and boot.lane_refusal
    ok, lines = boot.down(osname="nt")
    assert not ok and len(lines) == 1, lines
    assert "WSL2" in lines[0], lines
    assert fake_docker.calls == [] and fake_docker.downs == []
    assert fake_docker.running[proj] == ["c1"]


def test_followup_the_cli_stop_and_halt_by_label_refuse_on_native_windows(
        checkout, makes, fake_docker, monkeypatch, capsys):
    rec = _ran_then_worktree_gone(checkout)
    proj = saved_meshes.record_project(rec)
    fake_docker.running[proj] = ["c1"]
    ok, lines = images_mesh.halt_by_label(proj, osname="nt")
    assert not ok and "WSL2" in lines[0], lines
    ok, lines = images_mesh.AlongsideMesh(checkout, rec).stop(osname="nt")
    assert not ok and "WSL2" in lines[0], lines
    _pin_native_windows(monkeypatch)            # the CLI: this host IS native Windows
    rc = images_mesh.main(["--generator-dir", checkout, "stop", rec.id])
    out = capsys.readouterr().out
    assert rc == 1 and "WSL2" in out, out
    assert fake_docker.calls == [] and fake_docker.downs == []


def test_followup_a_stop_with_its_worktree_present_is_gated_too(checkout, makes,
                                                                fake_docker):
    """AlongsideMesh.stop's own gate: the worktree path (`make stack-halt` in it) is
    refused on native Windows as well, not only the label path."""
    rec = _img_record(checkout)
    lane = images_mesh.AlongsideMesh(checkout, rec)
    ok, msg = lane.prepare_worktree()
    assert ok, msg
    ok, lines = lane.stop(osname="nt")
    assert not ok and "WSL2" in lines[0], lines
    assert not [m for m in makes if m["target"] != "probe_state"], makes
    assert fake_docker.calls == []


def test_followup_halt_by_label_with_no_docker_answer_stops_nothing(monkeypatch):
    """Mutation R2: 'docker did not answer' must never read as 'nothing to stop'."""
    monkeypatch.setattr(images_mesh, "project_running_ids", lambda p: None)
    monkeypatch.setattr(subprocess, "run", lambda *a, **k: (_ for _ in ()).throw(
        AssertionError("no compose call may run")))
    ok, lines = images_mesh.halt_by_label("hugmesh-img-abc")
    assert not ok, lines
    assert "docker did not answer" in lines[0] and "nothing to stop" not in lines[0]


def test_followup_halt_by_label_fails_when_docker_stops_answering_after_down(
        monkeypatch):
    """Mutation R4: after a down that returned 0, an unanswered re-check (after=None)
    is a FAILURE (whether it stopped is not known), never a success."""
    answers = iter([["c1", "c2"], None])
    monkeypatch.setattr(images_mesh, "project_running_ids", lambda p: next(answers))
    monkeypatch.setattr(local_stack_node, "_compose_base", lambda: ["docker", "compose"])
    monkeypatch.setattr(subprocess, "run", lambda argv, *a, **k:
                        subprocess.CompletedProcess(argv, 0, "", ""))
    ok, lines = images_mesh.halt_by_label("hugmesh-img-abc")
    assert not ok and "stop FAILED" in lines[0], lines


def test_followup_a_locked_stale_registration_is_kept(checkout, tmp_path):
    """Mutation R5: a LOCKED registration is never removed, even with its dir gone."""
    import shutil
    wt = str(tmp_path / "locked-worktree")
    subprocess.run(["git", "-C", checkout, "worktree", "add", "-q", "--detach", wt,
                    "HEAD"], check=True, capture_output=True)
    subprocess.run(["git", "-C", checkout, "worktree", "lock", wt], check=True,
                   capture_output=True)
    shutil.rmtree(wt)
    msg = images_mesh.drop_stale_registration(checkout, wt)
    assert "locked" in msg and "left as it is" in msg, msg
    assert wt in _git_worktrees(checkout)


def test_followup_losing_another_registration_is_reported(monkeypatch, tmp_path):
    """Mutation R6: the 'every other registration is still listed' check. If the
    remove ever took another registration with it, the result says which."""
    mine = str(tmp_path / "mine")
    other = str(tmp_path / "other")
    regs = iter([
        [{"path": str(tmp_path / "repo"), "locked": False, "prunable": False},
         {"path": mine, "locked": False, "prunable": True},
         {"path": other, "locked": False, "prunable": True}],
        [{"path": str(tmp_path / "repo"), "locked": False, "prunable": False}],
    ])
    monkeypatch.setattr(images_mesh, "_worktree_registrations", lambda repo: next(regs))
    removed = []
    monkeypatch.setattr(subprocess, "run", lambda argv, *a, **k: removed.append(argv)
                        or subprocess.CompletedProcess(argv, 0, "", ""))
    msg = images_mesh.drop_stale_registration(str(tmp_path / "repo"), mine)
    assert "also lost" in msg and other in msg, msg
    assert removed and removed[0][-1] == mine


def test_followup_an_unanswered_inspect_is_not_called_a_non_mesh(monkeypatch):
    """docker did not say which compose project holds 8000: say exactly that, with
    the Stop remedy, never "not a HugMesh mesh (it belongs to no compose project)"."""
    monkeypatch.setattr(images_mesh, "port_free", lambda p: p != 8000)
    monkeypatch.setattr(images_mesh, "port_holder", lambda p: "hugmesh-img-abc-casdoor-1")
    monkeypatch.setattr(images_mesh, "container_project", lambda name: None)
    why = LocalMeshBootstrap(GENERATOR_DIR, LocalMeshBootstrapConfig()) \
        .fixed_port_refusal()
    assert "8000" in why and "docker did not say who holds it" in why, why
    assert "not a HugMesh mesh" not in why and "no compose project" in why
    assert "Stop on its row in Saved meshes" in why and "images_mesh stop" in why
    assert "Nothing was started" in why


@pytest.mark.parametrize("rc,stdout,want", [
    (0, "hugmesh-img-abc\n", "hugmesh-img-abc"),
    (0, "<no value>\n", ""),                 # docker answered: no compose label
    (1, "", None),                           # docker did not answer
    (0, "\n", None),                         # an empty reply says nothing either
])
def test_followup_container_project_tells_no_label_from_no_answer(monkeypatch, rc,
                                                                  stdout, want):
    monkeypatch.setattr(subprocess, "run", lambda argv, *a, **k:
                        subprocess.CompletedProcess(argv, rc, stdout, ""))
    assert images_mesh.container_project("c") == want


def test_followup_container_project_with_no_docker_is_no_answer(monkeypatch):
    def gone(*a, **k):
        raise FileNotFoundError("docker")
    monkeypatch.setattr(subprocess, "run", gone)
    assert images_mesh.container_project("c") is None


@pytest.mark.parametrize("up,want,once", [
    (["hugmesh-img-a"], "hugmesh-img-a is running (a mesh started beside a node-image "
     "build) and builds from it", "once that mesh is stopped"),
    (["hugmesh-img-a", "hugmesh-img-b"], "hugmesh-img-a and hugmesh-img-b are running "
     "(meshes started beside node-image builds) and build from it",
     "once those meshes are stopped"),
    (["hugmesh-img-a", "hugmesh-img-b", "hugmesh-img-c"],
     "hugmesh-img-a, hugmesh-img-b and hugmesh-img-c are running (meshes started "
     "beside node-image builds) and build from it", "once those meshes are stopped"),
])
def test_followup_the_kept_sentence_agrees_in_number(monkeypatch, up, want, once):
    monkeypatch.setattr(local_stack_node, "running_img_projects", lambda: up)
    args, says = local_stack_node.LocalStackNode(GENERATOR_DIR)._clean_args()
    assert args == ["STACK_CLEAN_KEEP_M2=1"]
    assert want in says and f"clean again {once} to remove" in says, says


def test_followup_the_label_stop_loads_no_stray_compose_file(
        checkout, makes, fake_docker, monkeypatch, tmp_path):
    """`docker compose -p <p> down` with no file still LOOKS for a compose.yaml (cwd
    and up) and an .env (project dir), and reads COMPOSE_FILE. The label stop runs
    from a fresh empty dir that is its --project-directory, with no COMPOSE_* env,
    and removes that dir afterwards."""
    rec = _ran_then_worktree_gone(checkout)
    proj = saved_meshes.record_project(rec)
    fake_docker.running[proj] = ["c1"]
    stray = tmp_path / "stray-cwd"
    stray.mkdir()
    (stray / "compose.yaml").write_text("services: {x: {image: nope}}\n")
    (stray / ".env").write_text("COMPOSE_PROJECT_NAME=hugmesh-local\n")
    monkeypatch.chdir(stray)
    monkeypatch.setenv("COMPOSE_FILE", str(stray / "compose.yaml"))
    monkeypatch.setenv("COMPOSE_PROFILES", "social")
    ok, lines = images_mesh.AlongsideMesh(checkout, rec).stop()
    assert ok, lines
    assert fake_docker.downs == [["docker", "compose", "-p", proj, "down"]]
    ((cwd, project_dir, listing, compose_env),) = fake_docker.compose_dirs
    assert cwd and cwd == project_dir and cwd != str(stray), (cwd, project_dir)
    assert listing == [] and compose_env == [], (listing, compose_env)
    assert not os.path.exists(cwd), "the empty project dir was left behind"
