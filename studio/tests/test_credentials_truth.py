"""core/credentials_truth — the pure state machine behind the credentials banner.

WHY THIS FILE EXISTS. The credentials dialog used to present whatever the checkout's
seeder scripts declared and whatever password sat in ``.e2e-credentials`` as the way
into the mesh that is running — with no evidence that anything had been seeded, that
the file's value matched the identities, or that the superadmin it named was the one
the Studio minted. ``assess()`` is the whole state machine and is PURE, so every state
below is driven with plain facts and no docker; ``probe_credentials()`` is the blocking
gatherer, exercised here only through fakes at its documented seam.

Two rules are pinned hard: UNKNOWN is never rendered as absent (a probe that could not
run is not a "no"), and no password ever reaches ``headline`` or ``detail`` (they go
to tooltips, banners and the page's state line).
"""
from __future__ import annotations

import os
import subprocess
import sys
import time
from types import SimpleNamespace

import pytest

from hugmesh_studio.core import credentials_truth as ct

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

T0 = 1_750_000_000.0            # an arbitrary epoch; only ORDER matters below
HOUR = 3600.0
FIXTURE_PW = "fixture-pw-9Xq7wLm2"        # a KNOWN value the strings must not carry


def _file(tmp_path, *, mtime: float | None = T0, content="E2E_PASSWORD=" + FIXTURE_PW + "\n",
          exists=True):
    p = tmp_path / ".e2e-credentials"
    if exists:
        p.write_text(content)
        if mtime is not None:
            os.utime(p, (mtime, mtime))
    return ct.credentials_file(str(tmp_path), {})


def _facts(tmp_path, **over):
    if "creds" not in over:                    # lazy: a test may have chmod'd the file
        over["creds"] = _file(tmp_path)
    base = dict(mesh_running=False, volumes_present=False, seeded_admin=None,
                seeded_operator=None, casdoor_created=None,
                secrets_mtime=None, last_seed_ok=None, lane=ct.LANE_COMPOSE,
                operator_user="mesh-operator", superadmin=("", ""),
                env_password=False, checked_at="now")
    base.update(over)
    return base


# ── the eight states ──────────────────────────────────────────────────────────────

def test_stack_down_with_no_volumes_is_no_mesh(tmp_path):
    t = ct.assess(**_facts(tmp_path))
    assert t.state == ct.STATE_NO_MESH
    assert "No mesh is running" in t.headline and "WOULD create" in t.headline
    assert t.marker == ct.NOT_SEEDED
    assert t.stage2 is False


def test_stack_down_with_volumes_is_halted_and_says_credentials_still_valid(tmp_path):
    t = ct.assess(**_facts(tmp_path, volumes_present=True, casdoor_created=T0 - HOUR,
                           last_seed_ok=T0 + HOUR))
    assert t.state == ct.STATE_HALTED
    assert "kept the volumes" in t.headline and "still valid" in t.headline
    assert t.marker == ct.HALTED


def test_up_but_unseeded_names_stack_seed(tmp_path):
    t = ct.assess(**_facts(tmp_path, mesh_running=True, volumes_present=True,
                           seeded_admin=False))
    assert t.state == ct.STATE_UP_UNSEEDED
    assert "make stack-seed" in t.headline and "Add user" in t.headline
    assert t.marker == ct.NOT_SEEDED


def test_file_rewritten_after_the_last_completed_seed_is_suspect(tmp_path):
    """The shape seed-e2e.sh leg 1c names: a persisted casdoor volume whose identities
    were reconciled to a value the (lost/regenerated) file no longer holds. Every
    sign-in 401s until a re-seed reconciles them again."""
    t = ct.assess(**_facts(tmp_path, mesh_running=True, volumes_present=True,
                           seeded_admin=True, seeded_operator=True,
                           casdoor_created=T0 - 3 * HOUR, last_seed_ok=T0 - 2 * HOUR,
                           creds=_file(tmp_path, mtime=T0)))       # file NEWER than seed
    assert t.state == ct.STATE_SEEDED_SUSPECT
    assert "DIFFERENT password" in t.headline and "401" in t.headline
    assert "make stack-seed" in t.detail                            # the fix is named
    assert t.marker == ct.STALE


def test_file_older_than_the_running_casdoor_is_NOT_suspect_when_a_seed_completed_after_it(tmp_path):
    """e2e_password_ensure REUSES the file's value when the file exists, so a
    second-generation mesh (volume recreated after a clean, file kept) is valid with
    an OLDER file. Mtime order between file and volume proves nothing; a completed
    seed after both does."""
    t = ct.assess(**_facts(tmp_path, mesh_running=True, volumes_present=True,
                           seeded_admin=True, seeded_operator=True,
                           creds=_file(tmp_path, mtime=T0 - 10 * HOUR),  # Aug-27 style
                           casdoor_created=T0 - HOUR,                    # volume newer
                           last_seed_ok=T0))                             # seed after both
    assert t.state == ct.STATE_SEEDED
    assert t.marker == ct.LIVE


def test_file_newer_than_casdoor_is_seeded_when_the_seed_completed_after_it(tmp_path):
    t = ct.assess(**_facts(tmp_path, mesh_running=True, volumes_present=True,
                           seeded_admin=True, seeded_operator=True,
                           casdoor_created=T0 - 2 * HOUR,
                           creds=_file(tmp_path, mtime=T0 - HOUR),
                           last_seed_ok=T0))
    assert t.state == ct.STATE_SEEDED
    assert t.headline.startswith("Seeded.")
    assert ".e2e-credentials" in t.headline           # names the file, not the value
    assert t.stage2 is True
    assert t.verified


def test_minted_secrets_without_a_seed_is_minted_not_seeded(tmp_path):
    """Today's shape on the reference host: a bring-up re-minted secrets.json and then
    failed at stack-up — nothing holds the minted superadmin."""
    t = ct.assess(**_facts(tmp_path, secrets_mtime=T0, last_seed_ok=T0 - HOUR,
                           superadmin=("superadmin", FIXTURE_PW)))
    assert t.state == ct.STATE_MINTED_NOT_SEEDED
    assert "minted a superadmin" in t.headline and "failed before seeding" in t.headline
    assert t.superadmin_seeded is False
    assert t.marker == ct.NOT_SEEDED


def test_minted_after_a_seed_over_a_kept_volume_says_the_store_holds_the_previous_seed(tmp_path):
    t = ct.assess(**_facts(tmp_path, volumes_present=True, casdoor_created=T0 - 3 * HOUR,
                           secrets_mtime=T0, last_seed_ok=T0 - HOUR,
                           superadmin=("superadmin", FIXTURE_PW)))
    assert t.state == ct.STATE_MINTED_NOT_SEEDED
    assert "PREVIOUS seed" in t.detail
    assert t.superadmin_seeded is False
    assert t.marker == ct.UNVERIFIED                   # kept identities: not "not seeded"


def test_a_seeded_then_cleaned_mesh_is_no_mesh_not_minted_not_seeded(tmp_path):
    """The mint WAS seeded (Bootstrapping-ok after secrets.json) and the store was then
    destroyed — that is "no mesh", not "minted and never seeded"."""
    t = ct.assess(**_facts(tmp_path, secrets_mtime=T0 - HOUR, last_seed_ok=T0,
                           superadmin=("superadmin", FIXTURE_PW)))
    assert t.state == ct.STATE_NO_MESH


def test_halted_store_created_after_the_recorded_seed_is_unverified_not_still_valid(tmp_path):
    """The reference host on 2026-09-02: mint 04:40, recorded seed 04:43, stack-clean
    04:49, then a casdoor-pg created 07:29 by a run the Studio never recorded. Press
    Stop and the old rule said "still valid" with stage 2 asserted and the minted
    superadmin "seeded" — into a store that seed never touched."""
    t = ct.assess(**_facts(tmp_path, volumes_present=True, casdoor_created=T0 + HOUR,
                           last_seed_ok=T0, secrets_mtime=T0 - HOUR,
                           creds=_file(tmp_path, mtime=T0 - 2 * HOUR),
                           superadmin=("superadmin", FIXTURE_PW)))
    assert t.state == ct.STATE_HALTED
    assert t.marker == ct.UNVERIFIED
    assert "unverified" in t.headline and "still valid" not in t.headline
    assert "created after the last recorded seed" in t.detail
    assert t.stage2 is None
    assert t.superadmin_seeded is None


def test_halted_with_no_recorded_seed_is_unverified(tmp_path):
    t = ct.assess(**_facts(tmp_path, volumes_present=True, casdoor_created=T0 - HOUR,
                           last_seed_ok=None))
    assert t.state == ct.STATE_HALTED
    assert t.marker == ct.UNVERIFIED and t.stage2 is None
    assert "still valid" not in t.headline
    assert "No completed seed is recorded" in t.detail


def test_halted_file_rewritten_after_the_recorded_seed_is_stale(tmp_path):
    """Leg 1c's shape while stopped: the recorded seed populated THIS store, and the
    file was regenerated since — the kept identities hold the previous value."""
    t = ct.assess(**_facts(tmp_path, volumes_present=True, casdoor_created=T0 - 2 * HOUR,
                           last_seed_ok=T0 - HOUR, creds=_file(tmp_path, mtime=T0)))
    assert t.state == ct.STATE_HALTED
    assert t.marker == ct.STALE
    assert "DIFFERENT password" in t.headline and "401" in t.headline
    assert "make stack-seed" in t.detail
    assert t.stage2 is True


def test_running_store_created_after_the_recorded_seed_is_unknown_even_with_a_newer_file(tmp_path):
    """A newer file over a store the record does not cover is NOT stale: the
    unrecorded seed that populated the store may have run after the rewrite, and
    the store's CreatedAt is only a lower bound on when it ran."""
    t = ct.assess(**_facts(tmp_path, mesh_running=True, volumes_present=True,
                           seeded_admin=True, seeded_operator=True,
                           casdoor_created=T0 + HOUR, last_seed_ok=T0,
                           creds=_file(tmp_path, mtime=T0 + 2 * HOUR),
                           secrets_mtime=T0 - HOUR,
                           superadmin=("superadmin", FIXTURE_PW)))
    assert t.state == ct.STATE_UNKNOWN
    assert t.marker == ct.UNVERIFIED
    assert "created after the last seed this Studio recorded" in t.headline
    assert t.stage2 is True                      # Casdoor ANSWERED that; it is a fact
    assert t.superadmin_seeded is None           # the store the mint was seeded into is gone


def test_running_store_of_unestablished_age_is_unknown_not_live(tmp_path):
    """`docker volume inspect --format {{.CreatedAt}}` can exit non-zero, or print a
    layout parse_docker_time does not recognise; probe_credentials then hands
    casdoor_created=None. Coercing that "not established" to "not after" made the
    module hand back its STRONGEST positive claim — live / verified / superadmin
    seeded — about a store nothing had dated, which is precisely the recreated-store
    case the guard exists to catch. None must stay unknown."""
    facts = dict(mesh_running=True, volumes_present=True, seeded_admin=True,
                 seeded_operator=True, last_seed_ok=T0, secrets_mtime=T0 - HOUR,
                 creds=_file(tmp_path, mtime=T0 - 2 * HOUR),
                 superadmin=("superadmin", FIXTURE_PW))
    t = ct.assess(**_facts(tmp_path, casdoor_created=None, **facts))
    assert t.state == ct.STATE_UNKNOWN
    assert t.marker == ct.UNVERIFIED
    assert t.verified is False
    assert t.superadmin_seeded is None
    assert "could not be established" in t.headline
    assert "docker volume inspect" in t.detail
    assert t.stage2 is True                      # Casdoor ANSWERED that; it is a fact
    # CONTROL: the identical facts with a store KNOWN to predate the record are the
    # positive claim — so this test fails only on the coercion, not on the shape.
    ok = ct.assess(**_facts(tmp_path, casdoor_created=T0 - HOUR, **facts))
    assert (ok.state, ok.marker, ok.verified) == (ct.STATE_SEEDED, ct.LIVE, True)
    assert ok.superadmin_seeded is True


def test_halted_store_of_unestablished_age_is_not_still_valid(tmp_path):
    """Same coercion, the halted shape: it printed "these credentials are still valid
    for the next start" and asserted stage 2, about a store whose age nothing knew."""
    facts = dict(volumes_present=True, last_seed_ok=T0, secrets_mtime=T0 - HOUR,
                 creds=_file(tmp_path, mtime=T0 - 2 * HOUR),
                 superadmin=("superadmin", FIXTURE_PW))
    t = ct.assess(**_facts(tmp_path, casdoor_created=None, **facts))
    assert t.state == ct.STATE_HALTED
    assert t.marker == ct.UNVERIFIED
    assert "still valid" not in t.headline
    assert t.stage2 is None and t.superadmin_seeded is None
    assert "did not answer with a time this Studio can read" in t.detail
    # and it must NOT claim the store was created after the seed — that is a
    # different fact, equally unestablished.
    assert "created after the last recorded seed" not in t.detail
    ok = ct.assess(**_facts(tmp_path, casdoor_created=T0 - HOUR, **facts))
    assert (ok.state, ok.marker, ok.stage2) == (ct.STATE_HALTED, ct.HALTED, True)
    assert "still valid" in ok.headline


@pytest.mark.skipif(os.geteuid() == 0, reason="root reads everything")
def test_unreadable_credentials_file_reports_the_permission_reason_not_not_seeded(tmp_path):
    p = tmp_path / ".e2e-credentials"
    p.write_text("E2E_PASSWORD=" + FIXTURE_PW + "\n")
    p.chmod(0)
    try:
        creds = ct.credentials_file(str(tmp_path), {})
        assert creds.exists and not creds.readable
        assert "PermissionError" in creds.error
        assert creds.keys == ()
        t = ct.assess(**_facts(tmp_path, creds=creds, mesh_running=True,
                               volumes_present=True, seeded_admin=True))
        assert t.state == ct.STATE_UNREADABLE
        assert "cannot be read" in t.headline
        assert "sudo chown" in t.detail and str(p) in t.detail
        assert "not seeded" not in t.headline.lower()
        assert t.password_marker == ct.UNREADABLE_MARKER
        # and the thin wrapper the resolver uses still degrades to {} (never raises)
        assert ct.read_values(str(tmp_path), {}) == {}
    finally:
        p.chmod(0o600)


def test_kind_lane_reports_stage2_unknown_not_false(tmp_path):
    t = ct.assess(**_facts(tmp_path, lane=ct.LANE_KIND, mesh_running=False))
    assert t.state == ct.STATE_UNKNOWN
    assert t.lane == ct.LANE_KIND
    assert t.stage2 is None
    assert t.operator_user == ""
    assert "no host port" in t.headline
    assert t.marker == ct.UNKNOWN


def test_unknown_is_never_rendered_as_absent(tmp_path):
    """docker did not answer: the passwords stay on screen marked unverified, and no
    string claims anything is missing or wrong."""
    t = ct.assess(**_facts(tmp_path, mesh_running=None, volumes_present=None))
    assert t.state == ct.STATE_UNKNOWN
    assert t.marker == ct.UNVERIFIED
    assert t.password_marker == ""                     # values still render
    for bad in ("not seeded", "no mesh", "401", "wrong"):
        assert bad not in t.headline.lower()
    # Casdoor not answering on a running stack is likewise unknown, not unseeded
    t = ct.assess(**_facts(tmp_path, mesh_running=True, volumes_present=True,
                           seeded_admin=None))
    assert t.state == ct.STATE_UNKNOWN
    assert "not established" in t.headline
    assert "unseeded" not in t.headline.lower()


def test_seeded_with_no_studio_record_is_unverified_not_asserted(tmp_path):
    """A terminal `make stack-seed` leaves no record here. Casdoor holds the personas,
    but nothing corroborates the file's value — unverified, never "seeded" and never
    "stale"."""
    t = ct.assess(**_facts(tmp_path, mesh_running=True, volumes_present=True,
                           seeded_admin=True, casdoor_created=T0 - HOUR,
                           last_seed_ok=None))
    assert t.state == ct.STATE_UNKNOWN
    assert "did not record" in t.headline
    assert t.marker == ct.UNVERIFIED


def test_seeded_but_file_gone_names_the_re_seed(tmp_path):
    t = ct.assess(**_facts(tmp_path, mesh_running=True, volumes_present=True,
                           seeded_admin=True, creds=_file(tmp_path, exists=False),
                           last_seed_ok=T0))
    assert t.state == ct.STATE_UNKNOWN
    assert "file is gone" in t.headline
    assert "make stack-seed" in t.detail


def test_env_password_counts_as_the_source_when_the_file_is_absent(tmp_path):
    t = ct.assess(**_facts(tmp_path, mesh_running=True, volumes_present=True,
                           seeded_admin=True, seeded_operator=False,
                           creds=_file(tmp_path, exists=False), env_password=True,
                           casdoor_created=T0 - HOUR, last_seed_ok=T0))
    assert t.state == ct.STATE_SEEDED
    assert "E2E_PASSWORD" in t.headline
    assert t.stage2 is False and "NOT on this lane" in t.detail


def test_every_state_is_reachable_and_pinned():
    assert set(ct.STATES) == {ct.STATE_UNKNOWN, ct.STATE_NO_MESH, ct.STATE_HALTED,
                              ct.STATE_UP_UNSEEDED, ct.STATE_SEEDED,
                              ct.STATE_SEEDED_SUSPECT, ct.STATE_MINTED_NOT_SEEDED,
                              ct.STATE_UNREADABLE}
    assert len(ct.STATES) == 8


# ── secret discipline ─────────────────────────────────────────────────────────────

def _every_truth(tmp_path):
    sa = ("superadmin", FIXTURE_PW + "-sa")
    yield ct.assess(**_facts(tmp_path, superadmin=sa))
    yield ct.assess(**_facts(tmp_path, volumes_present=True, superadmin=sa,
                             last_seed_ok=T0))
    yield ct.assess(**_facts(tmp_path, mesh_running=True, seeded_admin=False,
                             superadmin=sa, secrets_mtime=T0))
    # Both of these need a store the record demonstrably COVERS — a dated store
    # older than the recorded seed. Left at casdoor_created=None they are UNKNOWN,
    # because an undated store may have been recreated since the seed was recorded.
    yield ct.assess(**_facts(tmp_path, mesh_running=True, seeded_admin=True,
                             seeded_operator=True, superadmin=sa,
                             casdoor_created=T0 - 2 * HOUR,
                             creds=_file(tmp_path, mtime=T0), last_seed_ok=T0 - HOUR))
    yield ct.assess(**_facts(tmp_path, mesh_running=True, seeded_admin=True,
                             seeded_operator=True, superadmin=sa,
                             casdoor_created=T0 - 2 * HOUR,
                             creds=_file(tmp_path, mtime=T0 - HOUR), last_seed_ok=T0,
                             secrets_mtime=T0 - 2 * HOUR))
    yield ct.assess(**_facts(tmp_path, secrets_mtime=T0, superadmin=sa))
    yield ct.assess(**_facts(tmp_path, lane=ct.LANE_KIND, superadmin=sa))
    yield ct.assess(**_facts(tmp_path, mesh_running=None, superadmin=sa))
    # halted, store created after the record / no record / file rewritten after it
    yield ct.assess(**_facts(tmp_path, volumes_present=True, casdoor_created=T0 + HOUR,
                             last_seed_ok=T0, secrets_mtime=T0 - HOUR, superadmin=sa))
    yield ct.assess(**_facts(tmp_path, volumes_present=True, superadmin=sa))
    yield ct.assess(**_facts(tmp_path, volumes_present=True, last_seed_ok=T0 - HOUR,
                             creds=_file(tmp_path, mtime=T0), superadmin=sa))
    # running over a store the record does not cover
    yield ct.assess(**_facts(tmp_path, mesh_running=True, seeded_admin=True,
                             seeded_operator=True, superadmin=sa,
                             casdoor_created=T0 + HOUR, last_seed_ok=T0,
                             secrets_mtime=T0 - HOUR))


def test_headline_and_detail_never_contain_a_password(tmp_path):
    seen = set()
    for t in _every_truth(tmp_path):
        seen.add(t.state)
        for text in (t.headline, t.detail):
            assert FIXTURE_PW not in text, (t.state, text)
        assert t.file.keys in ((), ("E2E_PASSWORD",))            # names only
    assert seen >= {ct.STATE_NO_MESH, ct.STATE_HALTED, ct.STATE_UP_UNSEEDED,
                    ct.STATE_SEEDED_SUSPECT, ct.STATE_SEEDED,
                    ct.STATE_MINTED_NOT_SEEDED, ct.STATE_UNKNOWN}


def test_credentials_file_carries_key_names_only(tmp_path):
    c = _file(tmp_path, content="# comment\nE2E_PASSWORD=" + FIXTURE_PW
                                + "\nE2E_ADMIN_PASSWORD=other\n")
    assert c.keys == ("E2E_PASSWORD", "E2E_ADMIN_PASSWORD")
    assert FIXTURE_PW not in repr(c)
    assert c.readable and c.exists and c.mtime is not None and c.written


def test_credentials_file_honours_the_env_override_and_absence(tmp_path):
    other = tmp_path / "elsewhere"
    other.write_text("E2E_PASSWORD=x\n")
    c = ct.credentials_file(str(tmp_path), {"E2E_CREDENTIALS_FILE": str(other)})
    assert c.path == str(other) and c.readable
    c = ct.credentials_file(str(tmp_path / "nowhere"), {})
    assert not c.exists and not c.readable and c.error == "absent"
    assert ct.read_values(str(tmp_path / "nowhere"), {}) == {}


# ── the gatherer at its seam ──────────────────────────────────────────────────────

class _Node:
    """A LocalStackNode stand-in: docker answers are scripted per command."""

    def __init__(self, *, running=True, volumes="hugmesh-local_casdoor-pg\n",
                 created=None, users=("e2e-admin",),
                 kind_ps="", raise_status=False):
        # docker's RFC-3339 CreatedAt, two hours BEFORE the seed the tests record
        created = created or time.strftime("%Y-%m-%dT%H:%M:%S%z",
                                           time.localtime(T0 - 2 * HOUR))
        created = created[:-2] + ":" + created[-2:] if created[-3] != ":" else created
        self._running, self._volumes, self._created = running, volumes, created
        self._users, self._kind_ps, self._raise = set(users), kind_ps, raise_status
        self.calls: list[list[str]] = []

    def status(self):
        if self._raise:
            raise OSError("docker: not found")
        return SimpleNamespace(running=self._running,
                               detail="3 container(s)" if self._running else "0")

    def _probe(self, cmd, timeout=15):
        self.calls.append(list(cmd))
        if self._raise:
            return 1, "docker: not found"
        if cmd[:2] == ["docker", "ps"]:
            return 0, self._kind_ps
        if cmd[:3] == ["docker", "volume", "ls"]:
            assert cmd[4].startswith("label=com.docker.compose.project=")
            return 0, self._volumes
        if cmd[:3] == ["docker", "volume", "inspect"]:
            return 0, self._created
        return 1, "unexpected"

    def seeded_user(self, username):
        if self._raise:
            return None, "Casdoor not answering"
        return (username in self._users), ""


class _Boot:
    def __init__(self, tmp_path, *, mint=True, sa=("superadmin", FIXTURE_PW)):
        self.secrets_json = str(tmp_path / "keys-out" / "vault" / "secrets.json")
        if mint:
            os.makedirs(os.path.dirname(self.secrets_json), exist_ok=True)
            with open(self.secrets_json, "w") as fh:
                fh.write("{}")
            os.utime(self.secrets_json, (T0 - HOUR, T0 - HOUR))
        self._sa = sa

    def superadmin_login(self):
        return self._sa


def _logs(tmp_path, *stamps):
    d = tmp_path / "state" / "logs"
    d.mkdir(parents=True, exist_ok=True)
    for stamp in stamps:
        (d / f"{stamp}-Bootstrapping-ok.log").write_text("# ok\n")
    return str(d)


def test_probe_credentials_never_raises_when_docker_is_absent(tmp_path):
    _file(tmp_path)
    t = ct.probe_credentials(str(tmp_path), {}, _Node(raise_status=True),
                             _Boot(tmp_path), operator_user="mesh-operator",
                             logs_dir=str(tmp_path / "no-logs"))
    assert t.state == ct.STATE_UNKNOWN
    assert t.marker == ct.UNVERIFIED
    assert t.superadmin == ("superadmin", FIXTURE_PW)
    assert FIXTURE_PW not in t.headline + t.detail


def test_probe_credentials_joins_every_fact_into_seeded(tmp_path):
    seed_stamp = time.strftime("%Y%m%d-%H%M%S", time.localtime(T0))
    logs = _logs(tmp_path, seed_stamp)
    creds = _file(tmp_path, mtime=T0 - HOUR)
    node = _Node(users=("e2e-admin", "mesh-operator"))
    t = ct.probe_credentials(str(tmp_path), {}, node, _Boot(tmp_path),
                             operator_user="mesh-operator", logs_dir=logs)
    assert t.state == ct.STATE_SEEDED, (t.headline, t.detail)
    assert t.stage2 is True
    assert t.superadmin_seeded is True                # minted T0-1h, seeded T0
    assert t.file.path == creds.path
    assert t.lane == ct.LANE_COMPOSE
    # the identity volume was asked about by LABEL, never by compose-file listing
    assert any(c[:3] == ["docker", "volume", "ls"] for c in node.calls)
    assert any(c[:3] == ["docker", "volume", "inspect"] and c[3].endswith("_casdoor-pg")
               for c in node.calls)


def test_probe_credentials_marks_a_terminal_seed_without_the_operator(tmp_path):
    seed_stamp = time.strftime("%Y%m%d-%H%M%S", time.localtime(T0))
    _file(tmp_path, mtime=T0 - HOUR)
    node = _Node(users=("e2e-admin",))                 # no mesh-operator
    t = ct.probe_credentials(str(tmp_path), {}, node, _Boot(tmp_path),
                             operator_user="mesh-operator",
                             logs_dir=_logs(tmp_path, seed_stamp))
    assert t.state == ct.STATE_SEEDED
    assert t.stage2 is False


def test_probe_credentials_switches_to_the_kind_lane_when_compose_is_down(tmp_path):
    _file(tmp_path)
    node = _Node(running=False, volumes="", kind_ps="hugmesh-local-control-plane\n")
    t = ct.probe_credentials(str(tmp_path), {}, node, _Boot(tmp_path, mint=False),
                             operator_user="mesh-operator",
                             logs_dir=str(tmp_path / "no-logs"))
    assert t.lane == ct.LANE_KIND
    assert t.state == ct.STATE_UNKNOWN and t.stage2 is None
    # the kind question was asked about THIS repo's cluster name, by exact name
    ps = next(c for c in node.calls if c[:2] == ["docker", "ps"])
    assert "name=^hugmesh-local-control-plane$" in ps


def test_probe_credentials_reports_no_mesh_when_nothing_is_up(tmp_path):
    _file(tmp_path)
    node = _Node(running=False, volumes="hugmesh-local_synapse\n")   # orphan, no identity
    t = ct.probe_credentials(str(tmp_path), {}, node, _Boot(tmp_path, mint=False),
                             operator_user="mesh-operator",
                             logs_dir=str(tmp_path / "no-logs"))
    assert t.state == ct.STATE_NO_MESH


# ── helpers ───────────────────────────────────────────────────────────────────────

def test_parse_docker_time_accepts_both_layouts_and_rejects_garbage():
    a = ct.parse_docker_time("2026-08-27T06:20:11-07:00")
    b = ct.parse_docker_time("2026-08-27 06:20:11 -0700 PDT")
    assert a is not None and b is not None and abs(a - b) < 1
    assert ct.parse_docker_time("") is None
    assert ct.parse_docker_time("no such volume") is None


def test_last_seed_ok_reads_only_completed_seeding_verbs(tmp_path):
    d = tmp_path / "logs"
    d.mkdir()
    for name in ("20260901-224411-Bootstrapping-FAILED.log",       # failed: not a seed
                 "20260902-043818-Stopping-and-cleaning-Docker-ok.log",  # not a seed
                 "20260902-044312-Bootstrapping-ok.log",
                 "20260902-050000-Adding-user-alice-ok.log"):
        (d / name).write_text("")
    when = ct.last_seed_ok(str(d))
    assert when == time.mktime(time.strptime("20260902-050000", "%Y%m%d-%H%M%S"))
    assert ct.last_seed_ok(str(tmp_path / "absent")) is None


def test_module_is_qt_free():
    # must run in the Qt-free CI lane (proven in a FRESH interpreter, since this
    # suite imports Qt elsewhere).
    probe = (
        "import hugmesh_studio.core.credentials_truth as m, sys;"
        "assert callable(m.assess) and callable(m.probe_credentials);"
        "bad=[x for x in sys.modules if x.startswith(('PySide6','PyQt6','PyQt5'))];"
        "assert not bad, bad"
    )
    env = dict(os.environ, PYTHONPATH=STUDIO_ROOT)
    r = subprocess.run([sys.executable, "-c", probe], env=env,
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
