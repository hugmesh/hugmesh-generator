"""WorklistDriver (design 2.5) — sequential, failure-tolerant execution: per-image status,
continue-on-failure with a nonzero summary (build-all-roles.sh semantics), the once-per-run
mesh manifest v2 + per-node key generation, per-image and whole-run cancel, and aggregate
preflight. Qt-free; BuildDriver + gen-provision-keys are mocked so no real build runs."""
import json
import os

import pytest

from hugmesh_studio.core.config import Domain, ImageConfig, User
from hugmesh_studio.core.platform_info import HostInfo
from hugmesh_studio.core import worklist_driver as wd
from hugmesh_studio.core import build_driver as bd
from hugmesh_studio.core.roles import RoleVocabularyError
from hugmesh_studio.core.worklist_driver import WorklistDriver, key_profile
from hugmesh_studio.core.worklist import WorklistConfig, WorklistEntry, synthesize


def host(is_root=True, has_docker=True):
    return HostInfo(os="linux", is_gentoo=True, has_docker=has_docker, has_bash=True,
                    has_kvm=False, is_root=is_root, builder_image="hugmesh-builder")


def _base(tmp_path):
    b = ImageConfig(mode="mesh", role="omnibus", platform="x86", brand="acme",
                    brand_title="Acme", org="Acme-Inc", cluster_domain="acme.example",
                    superdomain="core.acme.internal", output_dir=str(tmp_path / "out"))
    b.domains = [Domain(name="acme.example", title="Acme"),
                 Domain(name="team.acme.example", title="Team", images=["backend.rpi5"])]
    b.users = [User(username="root-admin", domain="core.acme.internal", role="superadmin")]
    return b


def _worklist(tmp_path, roles=(("pki", "x86"), ("backend", "rpi5"), ("rpi5-desktop", "rpi5"))):
    return WorklistConfig(base=_base(tmp_path),
                          entries=[WorklistEntry(role=r, platform=p) for r, p in roles])


# ── fakes ─────────────────────────────────────────────────────────────────────────────
def _install_fake_builddriver(monkeypatch, codes=None, on_run=None):
    """Replace BuildDriver in the driver module. ``codes`` maps entry role -> exit code;
    ``on_run(fake, cfg)`` is a hook fired inside run() (used to trigger cancel mid-build)."""
    codes = codes or {}
    made = []

    class FakeBuildDriver:
        def __init__(self, gen, host, graphical=False, workdir=None):
            self.workdir = workdir
            self.cancelled = False
            self.graphical = graphical
            made.append(self)

        def run(self, cfg, backend, on_line=None):
            if on_line:
                on_line(f"==> building {cfg.role}")
            if on_run:
                on_run(self, cfg)
            return codes.get(cfg.role, 0)

        def cancel(self):
            self.cancelled = True

        def preflight(self, cfg, backend):
            return []

        def command_string(self, cfg, backend=None):
            return f"cmd:{cfg.role}"

    monkeypatch.setattr(wd, "BuildDriver", FakeBuildDriver)
    return made


def _install_fake_genkeys(monkeypatch, fail_roles=()):
    """Replace subprocess.Popen used for gen-provision-keys; fail for any keys dir whose
    entry id maps to a role in ``fail_roles``. Returns the captured commands."""
    calls = []

    class FakeProc:
        def __init__(self, code):
            self.stdout = iter(["generating keys"])
            self._code = code

        def wait(self):
            return self._code

    def fake_popen(cmd, **kwargs):
        calls.append(list(cmd))
        out = cmd[cmd.index("--out") + 1]
        fail = any(f".{r}." in os.path.basename(out) or os.path.basename(out).endswith(r)
                   or f"keys-{r}." in os.path.basename(out) for r in fail_roles)
        return FakeProc(1 if fail else 0)

    monkeypatch.setattr(wd.subprocess, "Popen", fake_popen)
    return calls


# ── role -> key profile map (mirrors build-all-roles.sh) ─────────────────────────────
def test_key_profile_map():
    """The profile comes from the ONE table (scripts/_roles-lib.sh
    HUGMESH_ROLE_KEYPROFILE), read through core/roles.py — it is no longer a dict
    in worklist_driver.py, which was the fourth hand-copy of the same mapping."""
    assert key_profile("pki") == "pki"
    assert key_profile("backend") == "backend"
    assert key_profile("frontend") == "frontend"
    assert key_profile("omnibus") == "pki"        # single-node control plane
    assert key_profile("edge-ai") == "host"
    # `backend-gpu` IS a backend worker, so it takes the backend profile — on jetson
    # too. Its jetson spelling (`gpu-host`) used to land on the `*) -> host`
    # catch-all in build-all-roles.sh while the SAME role got `backend` on x86: one
    # logical node, two keys profiles, decided by which platform built it.
    assert key_profile("backend-gpu") == "backend"
    assert key_profile("gpu-host") == "backend"   # the old jetson spelling, folded
    assert key_profile("full") == "pki"           # the old jetson spelling of omnibus
    assert key_profile("be") == "backend"         # the old x86 spellings still resolve
    assert key_profile("fe") == "frontend"
    assert key_profile("frite") == "host"         # a Studio platform-pseudo role id


def test_key_profile_refuses_to_guess():
    """NO fallback. The old `.get(role, "host")` answered every unknown id with the
    worker profile, so a stale table produced a node holding the WRONG credentials
    and nothing anywhere said so. The caller turns this into a failed KEYS step for
    that one image instead."""
    with pytest.raises(RoleVocabularyError):
        key_profile("anything-else")


# ── happy path: all succeed ──────────────────────────────────────────────────────────
def test_all_succeed_status_and_callbacks(monkeypatch, tmp_path):
    _install_fake_builddriver(monkeypatch)
    _install_fake_genkeys(monkeypatch)
    wl = _worklist(tmp_path)
    drv = WorklistDriver(str(tmp_path), wl, host=host())
    starts, dones, manifests, lines = [], [], [], []
    code = drv.run_all(on_entry_start=starts.append,
                       on_entry_done=lambda i, c: dones.append((i, c)),
                       on_manifest=manifests.append,
                       on_line=lambda i, ln: lines.append((i, ln)))
    assert code == 0
    assert [r.status for r in drv.results] == ["ok", "ok", "ok"]
    assert starts == [0, 1, 2]
    assert dones == [(0, 0), (1, 0), (2, 0)]
    assert len(manifests) == 1                     # manifest written once, up front
    assert any("building pki" in ln for _i, ln in lines)


# ── failure tolerance ────────────────────────────────────────────────────────────────
def test_failure_is_tolerated_and_summary_nonzero(monkeypatch, tmp_path):
    _install_fake_builddriver(monkeypatch, codes={"backend": 3})   # middle image fails
    _install_fake_genkeys(monkeypatch)
    drv = WorklistDriver(str(tmp_path), _worklist(tmp_path), host=host())
    code = drv.run_all()
    assert [r.status for r in drv.results] == ["ok", "failed", "ok"]   # continued past the failure
    assert drv.results[1].exit_code == 3
    assert code == 1                                                    # nonzero summary
    assert drv.summary_exit_code() == 1


def test_a_raising_entry_is_failed_not_left_running_and_the_loop_continues(monkeypatch, tmp_path):
    """#374: BuildDriver.run can RAISE (ElevationRefused under HUGMESH_STUDIO_NO_ELEVATION
    / pytest, an OSError from Popen). Unhandled, run_all propagated with that entry still
    RUNNING and still registered in _drivers, on_entry_done never called, and the session
    later recorded 'stopped' (the operator-Stop state) instead of 'failed'."""
    def boom(fake, cfg):
        if cfg.role == "backend":
            raise bd.ElevationRefused("refusing to spawn sudo (HUGMESH_STUDIO_NO_ELEVATION is set)")

    _install_fake_builddriver(monkeypatch, on_run=boom)
    _install_fake_genkeys(monkeypatch)
    drv = WorklistDriver(str(tmp_path), _worklist(tmp_path), host=host())
    lines, dones = [], []
    code = drv.run_all(on_line=lambda i, ln: lines.append((i, ln)),
                       on_entry_done=lambda i, c: dones.append((i, c)))
    assert [r.status for r in drv.results] == ["ok", "failed", "ok"]   # tolerated, continued
    assert drv.results[1].exit_code == 1
    assert dones == [(0, 0), (1, 1), (2, 0)]        # the row reaches a terminal glyph
    assert drv._drivers == {}                        # nothing left registered
    assert any(i == 1 and ln.startswith("!! ") and "HUGMESH_STUDIO_NO_ELEVATION" in ln
               for i, ln in lines), lines
    assert code == 1
    from hugmesh_studio.core import build_sessions as bs
    assert bs.overall_status([r.status for r in drv.results]) == "failed"


# ── mesh manifest v2 ─────────────────────────────────────────────────────────────────
def test_manifest_v2_written_up_front(monkeypatch, tmp_path):
    _install_fake_builddriver(monkeypatch)
    _install_fake_genkeys(monkeypatch)
    drv = WorklistDriver(str(tmp_path), _worklist(tmp_path), host=host())
    path = drv.write_manifest_v2()
    m = json.loads(open(path).read())
    assert m["format"] == 2
    assert m["superdomain"] == "core.acme.internal"
    assert m["cluster_domain"] == "acme.example"
    assert [img["id"] for img in m["images"]] == ["pki.x86", "backend.rpi5", "rpi5-desktop.rpi5"]
    assert {d["name"] for d in m["domains"]} == {"acme.example", "team.acme.example"}
    assert m["users"][0]["username"] == "root-admin"
    # the additive per-image "hostname" (issue #229): "" = the builder derives it
    assert [img["hostname"] for img in m["images"]] == ["", "", ""]


def test_manifest_v2_carries_each_images_own_hostname(monkeypatch, tmp_path):
    """A per-entry hostname reaches the manifest's image record AND that entry's own
    build (the driver is per-entry already: one BuildDriver per materialized cfg), and
    only that entry's."""
    _install_fake_builddriver(monkeypatch)
    _install_fake_genkeys(monkeypatch)
    wl = _worklist(tmp_path)
    wl.entries[0].hostname = "ca-1"
    wl.entries[1].hostname = "be-pi"
    drv = WorklistDriver(str(tmp_path), wl, host=host())
    m = drv.manifest_v2()
    assert [(img["id"], img["hostname"]) for img in m["images"]] == [
        ("pki.x86", "ca-1"), ("backend.rpi5", "be-pi"), ("rpi5-desktop.rpi5", "")]
    argvs = {e.id: cfg.to_cli_args() for e, cfg in drv.materialize()}
    assert argvs["pki.x86"][argvs["pki.x86"].index("--hostname") + 1] == "ca-1"
    assert argvs["backend.rpi5"][argvs["backend.rpi5"].index("--hostname") + 1] == "be-pi"
    assert "--hostname" not in argvs["rpi5-desktop.rpi5"]


def test_manifest_v2_carries_the_desktop_derived_person(monkeypatch, tmp_path):
    """Issue #279: a desktop entry's named person is a manifest User (operator ask
    2026-08-14, ``WorklistConfig.desktop_users``). Before the fix manifest_v2 emitted
    ``base.users`` alone, so the person reached every per-image ``ImageConfig.users``
    and the v1 shim but never the v2 envelope cluster provisioning reads. Pin: the
    v2 user rows equal the per-image v1 shim's rows, byte for byte, and the derived
    row carries the FULL role set (tier + grants, issue #228)."""
    _install_fake_builddriver(monkeypatch)
    _install_fake_genkeys(monkeypatch)
    wl = _worklist(tmp_path, roles=(("pki", "x86"), ("laptop", "x86")))
    wl.entries[1].desktop_user = "alice"
    wl.entries[1].desktop_user_roles = ["games", "admin"]
    drv = WorklistDriver(str(tmp_path), wl, host=host())
    m = drv.manifest_v2()
    assert [u["username"] for u in m["users"]] == ["root-admin", "alice"]
    alice = m["users"][1]
    assert alice["domain"] == "core.acme.internal"            # the Tailscale root domain
    assert alice["role"] == "admin" and alice["roles"] == ["admin", "games"]
    # v2 and every image's v1 shim agree row for row (the shim already carried her)
    for _entry, cfg in drv.materialize():
        assert cfg.mesh_manifest()["users"] == m["users"]
    # the written artifact carries her too, not just the in-memory dict
    written = json.loads(open(drv.write_manifest_v2()).read())
    assert [u["username"] for u in written["users"]] == ["root-admin", "alice"]
    # manifest_users() builds a NEW list: base.users is not the list it appended to
    # (an aliasing `users = base.users` would push alice into the envelope on every
    # call, and the second manifest would carry her twice). The sibling test below
    # cannot see this — there alice is already a table row, so nothing is appended.
    assert [u.username for u in wl.base.users] == ["root-admin"]
    assert drv.manifest_v2()["users"] == m["users"]


def test_manifest_v2_lets_a_users_table_row_win_over_the_derived_person(monkeypatch, tmp_path):
    """Same dedup as _materialize_one step 3: a superadmin who already named the person
    in the Users table keeps their richer row (email survives) and the desktop entry
    adds no second row; a desktop entry with no named person adds nothing."""
    _install_fake_builddriver(monkeypatch)
    _install_fake_genkeys(monkeypatch)
    wl = _worklist(tmp_path, roles=(("pki", "x86"), ("laptop", "x86"), ("rpi5-desktop", "rpi5")))
    wl.base.users.append(User(username="alice", domain="core.acme.internal", role="mod",
                              email="alice@acme.example"))
    wl.entries[1].desktop_user = "alice"
    wl.entries[1].desktop_user_roles = ["admin"]
    drv = WorklistDriver(str(tmp_path), wl, host=host())
    m = drv.manifest_v2()
    assert [u["username"] for u in m["users"]] == ["root-admin", "alice"]
    assert m["users"][1]["email"] == "alice@acme.example"
    assert m["users"][1]["role"] == "mod"                     # the table row, not the entry's tier
    # the base envelope itself is untouched (manifest_users() must not mutate base.users)
    assert [u.username for u in wl.base.users] == ["root-admin", "alice"]


def test_non_mesh_writes_no_manifest(monkeypatch, tmp_path):
    _install_fake_builddriver(monkeypatch)
    cfg = ImageConfig(mode="standalone", role="standalone-thick", platform="x86",
                      brand="acme", output_dir=str(tmp_path / "out"))
    drv = WorklistDriver(str(tmp_path), synthesize(cfg), host=host())
    manifests = []
    code = drv.run_all(on_manifest=manifests.append)
    assert code == 0 and manifests == []
    assert not os.path.exists(os.path.join(str(tmp_path / "out"), wd.MANIFEST_NAME))


# ── per-node key generation ──────────────────────────────────────────────────────────
def test_keys_generated_for_nodes_only_with_right_profile(monkeypatch, tmp_path):
    _install_fake_builddriver(monkeypatch)
    calls = _install_fake_genkeys(monkeypatch)
    drv = WorklistDriver(str(tmp_path), _worklist(tmp_path), host=host())
    keys_events = []
    drv.run_all(on_keys=lambda i, p, ok: keys_events.append((drv.results[i].entry.id, p, ok)))
    # nodes pki.x86 + be.rpi5 got keys; the desktop entry did NOT
    profiles = {c[c.index("--role") + 1] for c in calls}
    assert profiles == {"pki", "backend"}
    assert drv.results[0].keys_ok is True and drv.results[1].keys_ok is True
    assert drv.results[2].keys_ok is None                       # desktop -> no keys attempt
    assert drv.results[2].keys_path is None
    assert {e[0] for e in keys_events} == {"pki.x86", "backend.rpi5"}


def test_keys_not_generated_for_failed_build(monkeypatch, tmp_path):
    _install_fake_builddriver(monkeypatch, codes={"pki": 2})
    calls = _install_fake_genkeys(monkeypatch)
    drv = WorklistDriver(str(tmp_path), _worklist(tmp_path), host=host())
    drv.run_all()
    # pki build failed -> no keys attempted for it; be still gets its keys
    assert {c[c.index("--role") + 1] for c in calls} == {"backend"}
    assert drv.results[0].keys_ok is None


def test_keys_failure_removes_partial_and_fails_summary(monkeypatch, tmp_path):
    _install_fake_builddriver(monkeypatch)
    _install_fake_genkeys(monkeypatch, fail_roles=("pki",))
    drv = WorklistDriver(str(tmp_path), _worklist(tmp_path, roles=(("pki", "x86"),)),
                         host=host())
    code = drv.run_all()
    assert drv.results[0].status == "ok"          # the build itself was fine
    assert drv.results[0].keys_ok is False
    assert code == 1                              # KEYS_FAILED -> nonzero summary
    assert not os.path.exists(drv.results[0].keys_path)   # partial folder removed


def test_generate_keys_opt_out(monkeypatch, tmp_path):
    _install_fake_builddriver(monkeypatch)
    calls = _install_fake_genkeys(monkeypatch)
    drv = WorklistDriver(str(tmp_path), _worklist(tmp_path), host=host(), generate_keys=False)
    drv.run_all()
    assert calls == []
    assert all(r.keys_ok is None for r in drv.results)


# ── cancel ───────────────────────────────────────────────────────────────────────────
def test_cancel_entry_before_start_skips_it(monkeypatch, tmp_path):
    built = _install_fake_builddriver(monkeypatch)
    _install_fake_genkeys(monkeypatch)
    drv = WorklistDriver(str(tmp_path), _worklist(tmp_path), host=host())
    drv.cancel(1)                                  # skip the middle image before running
    drv.run_all()
    assert [r.status for r in drv.results] == ["ok", "stopped", "ok"]
    assert len(built) == 2                         # only two builds actually ran


def test_cancel_all_midrun_stops_current_and_remaining(monkeypatch, tmp_path):
    box = {}

    def on_run(fake, cfg):
        if cfg.role == "pki":                      # cancel while the FIRST image "builds"
            box["driver"].cancel_all()
    built = _install_fake_builddriver(monkeypatch, on_run=on_run)
    _install_fake_genkeys(monkeypatch)
    drv = WorklistDriver(str(tmp_path), _worklist(tmp_path), host=host())
    box["driver"] = drv
    code = drv.run_all()
    assert drv.results[0].status == "stopped"      # current image marked stopped
    assert [r.status for r in drv.results[1:]] == ["stopped", "stopped"]  # rest skipped
    assert built[0].cancelled is True              # the live driver got a real cancel()
    assert len(built) == 1                         # no further builds spawned
    assert code == 1


# ── aggregate preflight (REAL BuildDriver against the tree) ───────────────────────────
def test_preflight_shared_once_and_per_entry_labelled(tmp_path, monkeypatch):
    # empty generator dir + non-root native: every image lacks its (platform-specific)
    # builder script AND shares the elevation problem. NOTE: non-root alone is NOT a
    # problem any more — the driver elevates via sudo/pkexec (2026-07-17: blocking it
    # made every GUI native build undispatchable), so the shared-problem fixture here
    # hides BOTH helpers to keep exercising the shared-vs-per-entry dedup contract.
    monkeypatch.setattr(bd.shutil, "which", lambda n: None)
    wl = _worklist(tmp_path, roles=(("pki", "x86"), ("backend", "x86"), ("pki", "rpi5")))
    drv = WorklistDriver(str(tmp_path), wl, host=host(is_root=False), backend="native")
    problems = drv.preflight()
    root_msgs = [p for p in problems if "elevation helper" in p]
    assert len(root_msgs) == 1 and not root_msgs[0].startswith("[")   # shared -> once, unlabelled
    # x86 script missing appears labelled for BOTH x86 entries; rpi5 for its one entry
    assert sum(1 for p in problems if "build-x86-host-stage4.sh" in p) == 2
    assert all(p.startswith("[") for p in problems if "build-x86-host-stage4.sh" in p)
    assert any("build-rpi5-stage4.sh" in p and p.startswith("[pki.rpi5]") for p in problems)


def test_single_entry_preflight_unlabelled(tmp_path):
    cfg = ImageConfig(mode="standalone", role="standalone-thick", platform="x86",
                      brand="acme", output_dir=str(tmp_path / "out"))
    drv = WorklistDriver(str(tmp_path), synthesize(cfg), host=host(is_root=False),
                         backend="native")
    problems = drv.preflight()
    assert problems and not any(p.startswith("[") for p in problems)   # 1 image -> no labels


def test_command_string_delegates(monkeypatch, tmp_path):
    _install_fake_builddriver(monkeypatch)
    drv = WorklistDriver(str(tmp_path), _worklist(tmp_path), host=host())
    _entry, cfg = drv.materialize()[0]
    assert drv.command_string(cfg) == f"cmd:{cfg.role}"


# ── output-dir writability preflight (the "stuck at queued" regression) ───────────────
# A NATIVE (sudo) build leaves <out>/sessions/ owned by root; the Studio runs as the
# desktop user, so the NEXT GUI run cannot create its own session dir. A mesh hit this
# hardest: run_all() writes the v2 manifest into the session workdir BEFORE the first
# image starts, so the PermissionError escaped _WorklistWorker.run(), killed the QThread
# with finished_all never emitted, and the GUI sat forever at "queued - image 1 of N"
# with an empty log and no error anywhere. preflight() must catch it BEFORE dispatch.

def test_preflight_flags_unwritable_output_dir(tmp_path, monkeypatch):
    out = tmp_path / "out"
    (out / "sessions").mkdir(parents=True)
    workdir = out / "sessions" / "20260815-142447-5194e0"   # not created yet, as at dispatch

    # Deny write on the nearest EXISTING ancestor (the sessions dir) — what root
    # ownership does, without needing a real root-owned tree in the test.
    real_access = os.access
    monkeypatch.setattr(
        wd.os, "access",
        lambda p, m: False if os.path.abspath(p) == str(out / "sessions") else real_access(p, m))

    drv = WorklistDriver(str(tmp_path), _worklist(tmp_path), host=host(),
                         workdir=str(workdir))
    problems = drv.preflight()
    hits = [p for p in problems if "not writable" in p]
    assert len(hits) == 1, f"expected exactly one writability problem, got {problems}"
    assert str(out / "sessions") in hits[0]      # names the ancestor actually at fault
    assert "chown" in hits[0]                    # and the remedy
    # The remedy must never be `chown -R <probe>`: followed on <out>, that hands
    # the build system (<out>/snap-build-*/sysroot) to the user and the next
    # --resume builds an image whose every directory is theirs (hugmesh-generator#659).
    assert "chown -R" not in hits[0].split("(not 'chown -R'")[0]
    assert "-name sysroot -prune" in hits[0]
    assert "chown -h" in hits[0]


def test_preflight_remedy_quotes_an_output_dir_with_a_space(tmp_path, monkeypatch):
    # The remedy is a command to paste: a path with a space in it must reach `find`
    # as ONE argument, or the person is told to chown two other directories.
    out = tmp_path / "my builds" / "out"
    (out / "sessions").mkdir(parents=True)
    workdir = out / "sessions" / "20260930-090000-abcdef"
    real_access = os.access
    monkeypatch.setattr(
        wd.os, "access",
        lambda p, m: False if os.path.abspath(p) == str(out / "sessions") else real_access(p, m))
    drv = WorklistDriver(str(tmp_path), _worklist(tmp_path), host=host(), workdir=str(workdir))
    hits = [p for p in drv.preflight() if "not writable" in p]
    assert len(hits) == 1
    assert f"sudo find '{out / 'sessions'}' -type d -name sysroot -prune" in hits[0]


def test_preflight_silent_when_output_dir_writable(tmp_path):
    # Control: the same shape with a writable tree must NOT produce a writability
    # problem (a check that fires on every run is worse than no check).
    workdir = tmp_path / "out" / "sessions" / "20260815-142447-5194e0"
    drv = WorklistDriver(str(tmp_path), _worklist(tmp_path), host=host(),
                         workdir=str(workdir))
    assert not [p for p in drv.preflight() if "not writable" in p]


def test_run_all_hands_each_entry_its_own_hostname_to_its_own_builddriver(monkeypatch, tmp_path):
    """The RUN path, not just materialize(): run_all() constructs one BuildDriver per
    entry and calls run(cfg) with THAT entry's projected config, so the hostname typed
    for one image is what that image's builder invocation receives — and the sibling
    invocations receive theirs (or nothing, and derive). The per-row value has to
    reach the builder for that row; this is the assertion that it does."""
    seen = []
    made = _install_fake_builddriver(
        monkeypatch, on_run=lambda fake, cfg: seen.append((cfg.build_subdir, cfg.hostname)))
    _install_fake_genkeys(monkeypatch)
    wl = _worklist(tmp_path)
    wl.entries[0].hostname = "ca-1"
    wl.entries[1].hostname = "be-pi"
    drv = WorklistDriver(str(tmp_path), wl, host=host())
    assert drv.run_all() == 0
    # one run per entry, each with its own name; the third derives (no explicit -H)
    assert seen == [("wl-pki.x86", "ca-1"), ("wl-backend.rpi5", "be-pi"),
                    ("wl-rpi5-desktop.rpi5", "")]
    # one BuildDriver per entry and none shared, so no invocation can see another's cfg
    assert len(made) == 3
    # and the argv each of those cfgs translates to is the one the builder sees
    argvs = [cfg.to_cli_args() for _e, cfg in drv.materialize()]
    assert [(a[a.index("--hostname") + 1] if "--hostname" in a else None) for a in argvs] == [
        "ca-1", "be-pi", None]


# ── #494: the own domain's per-domain services on the v2 envelope ─────────────────
def test_manifest_v2_omits_cluster_domain_services_when_empty(monkeypatch, tmp_path):
    """OMIT-WHEN-EMPTY: an own domain that takes the cluster-wide set leaves the v2
    envelope a mesh build writes byte-identical to one from before the key existed
    (PR #595 skeptics: the v1 shim was pinned, the envelope was not)."""
    _install_fake_builddriver(monkeypatch)
    _install_fake_genkeys(monkeypatch)
    wl = _worklist(tmp_path)
    assert wl.base.cluster_domain_services == []
    drv = WorklistDriver(str(tmp_path), wl, host=host())
    assert "cluster_domain_services" not in drv.manifest_v2()
    assert "cluster_domain_services" not in json.loads(open(drv.write_manifest_v2()).read())


def test_manifest_v2_carries_cluster_domain_services_when_picked(monkeypatch, tmp_path):
    _install_fake_builddriver(monkeypatch)
    _install_fake_genkeys(monkeypatch)
    wl = _worklist(tmp_path)
    wl.base.cluster_domain_services = ["games", "akkoma"]
    drv = WorklistDriver(str(tmp_path), wl, host=host())
    assert drv.manifest_v2()["cluster_domain_services"] == ["games", "akkoma"]
    written = json.loads(open(drv.write_manifest_v2()).read())
    assert written["cluster_domain_services"] == ["games", "akkoma"]
    # the v1 shim and the v2 envelope agree
    for _entry, cfg in drv.materialize():
        assert cfg.mesh_manifest()["cluster_domain_services"] == ["games", "akkoma"]
