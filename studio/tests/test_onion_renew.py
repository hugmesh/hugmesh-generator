"""core.onion_renew: a new Tor address for one domain of the running Docker mesh (#652).

Docker is faked (``run``), so nothing here reaches a mesh. Pinned: the container is
found by the stack's own filters and only ``hugmesh-tor-rotate <slug>`` is executed in
it; each exit status of the container command becomes its own sentence; an older
container without the command is told to restart the mesh, never driven through the
entrypoint; an answer that does not name the requested domain shows nothing.
"""
import subprocess

import pytest

from hugmesh_studio.core import onion_renew
from hugmesh_studio.core.local_stack_node import _tor_ps_filters

OLD, NEW = "a" * 56 + ".onion", "c" * 56 + ".onion"


class FakeDocker:
    def __init__(self, ps_ids="cid123\n", rc=0, out="", err="", raise_on=None):
        self.calls = []
        self.ps_ids, self.rc, self.out, self.err, self.raise_on = ps_ids, rc, out, err, raise_on

    def __call__(self, cmd, **kw):
        self.calls.append(cmd)
        if self.raise_on and cmd[1] == self.raise_on:
            raise self.raise_on_exc
        if cmd[1] == "ps":
            return subprocess.CompletedProcess(cmd, 0, self.ps_ids, "")
        return subprocess.CompletedProcess(cmd, self.rc, self.out, self.err)


def _renew(fake, name="acme.example", sid=""):
    return onion_renew.renew_domain_onion(name, sid, run=fake, which=lambda _n: "/usr/bin/docker")


def test_a_rotation_runs_only_the_rotate_command_in_the_running_tor_container():
    fake = FakeDocker(out=f"ROTATED acme-example {OLD} -> {NEW}\n[hugmesh-tor] ...\n")
    out = _renew(fake)
    assert out.ok and out.old == OLD and out.new == NEW
    assert fake.calls[0] == ["docker", "ps", "-q", "--no-trunc",
                             *_tor_ps_filters(onion_renew._COMPOSE_PROJECT)]
    assert fake.calls[1] == ["docker", "exec", "cid123", "hugmesh-tor-rotate", "acme-example"]
    assert len(fake.calls) == 2


def test_the_stored_brand_id_is_the_key_name_when_the_record_has_one():
    fake = FakeDocker(out=f"ROTATED shop {OLD} -> {NEW}\n")
    assert _renew(fake, "acme.example", sid="shop").ok
    assert fake.calls[1][-1] == "shop"


def test_an_answer_that_names_another_domain_shows_nothing():
    fake = FakeDocker(out=f"ROTATED brandb {OLD} -> {NEW}\n")
    out = _renew(fake)
    assert not out.ok and not out.new and "nothing is shown" in out.message


def test_no_running_tor_container_is_said_and_nothing_is_executed():
    fake = FakeDocker(ps_ids="")
    out = _renew(fake)
    assert not out.ok and "not running" in out.message
    assert all(c[1] != "exec" for c in fake.calls)


def test_an_older_container_is_told_to_restart_never_driven_through_the_entrypoint():
    fake = FakeDocker(rc=127, err='exec: "hugmesh-tor-rotate": executable file not found in $PATH')
    out = _renew(fake)
    assert not out.ok and "Restart the mesh" in out.message
    assert not any("hugmesh-tor-entrypoint" in " ".join(c) for c in fake.calls)


def test_each_refusal_has_its_own_sentence():
    words = {}
    for rc in (2, 3, 4, 5):
        words[rc] = _renew(FakeDocker(rc=rc, err="x")).message
    assert "not one of this mesh's Tor domains" in words[2]
    assert "being made right now" in words[3]
    assert "not published yet" in words[4]
    assert "old address is served again" in words[5]
    assert len(set(words.values())) == 4


def test_a_domain_without_a_key_name_and_no_docker_are_refused_up_front():
    fake = FakeDocker()
    assert not _renew(fake, name="").ok and not fake.calls
    out = onion_renew.renew_domain_onion("acme.example", run=fake, which=lambda _n: None)
    assert not out.ok and "docker is not installed" in out.message and not fake.calls


def test_a_timeout_is_reported_not_raised():
    def slow(cmd, **kw):
        if cmd[1] == "ps":
            return subprocess.CompletedProcess(cmd, 0, "cid\n", "")
        raise subprocess.TimeoutExpired(cmd, 180)
    out = onion_renew.renew_domain_onion("acme.example", run=slow, which=lambda _n: "docker")
    assert not out.ok and "three minutes" in out.message


# ── the text screen (section 5, Ways) ────────────────────────────────────────────
def _text_view(tmp_path, route="docker", tor=True, own=False):
    from types import SimpleNamespace
    from hugmesh_studio.core.config import Domain, ImageConfig
    from hugmesh_studio.core.local_mesh_bootstrap import LocalMeshBootstrapConfig
    from hugmesh_studio.core.local_mesh_domains import LocalMeshDomains
    from hugmesh_studio.tui import brand_step
    from hugmesh_studio.tui.superbrand_step import session_for
    rows = [Domain(name="shop.example", tor=tor)]
    if route == "image":
        cfg = ImageConfig()
        cfg.mode, cfg.domains = "mesh", rows
        source = cfg
    else:
        source = (LocalMeshBootstrapConfig(),
                  LocalMeshDomains(domains=[Domain(name="mesh.example"), *rows],
                                   own_name="mesh.example"))
    session = session_for(SimpleNamespace(), route, source, str(tmp_path))
    return brand_step, brand_step.brand_view(
        session, "mesh.example" if own else "shop.example", own=own)


def test_the_text_screen_asks_first_then_renews(tmp_path, monkeypatch):
    bs, view = _text_view(tmp_path)
    calls = []
    monkeypatch.setattr(onion_renew, "renew_domain_onion",
                        lambda name, sid="": calls.append((name, sid)) or
                        onion_renew.RenewOutcome(True, "done.", old=OLD, new=NEW))
    assert "tor new" in bs.feed_ways(view, "help")
    asked = bs.feed_ways(view, "tor new")
    assert onion_renew.CONFIRM_SENTENCE in asked and "tor new yes" in asked and not calls
    done = bs.feed_ways(view, "tor new yes")
    assert calls == [("shop.example", "")] and f"https://{NEW}/" in done and OLD in done


def test_the_text_screen_refuses_where_the_window_draws_no_row(tmp_path, monkeypatch):
    monkeypatch.setattr(onion_renew, "renew_domain_onion",
                        lambda *a, **k: pytest.fail("renew must not run"))
    for kw in ({"route": "image"}, {"tor": False}, {"own": True}):
        bs, view = _text_view(tmp_path / str(len(kw)) / next(iter(kw)), **kw)
        assert bs.feed_ways(view, "tor new yes").startswith("Not changed:")
        assert "tor new" not in bs.feed_ways(view, "help")
