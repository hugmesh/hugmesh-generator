"""WorklistDriver (design 2.5) — sequential, failure-tolerant execution: per-image status,
continue-on-failure with a nonzero summary (build-all-roles.sh semantics), the once-per-run
mesh manifest v2 + per-node key generation, per-image and whole-run cancel, and aggregate
preflight. Qt-free; BuildDriver + gen-provision-keys are mocked so no real build runs."""
import json
import os

import pytest

from snapdragon_studio.core.config import Domain, ImageConfig, User
from snapdragon_studio.core.platform_info import HostInfo
from snapdragon_studio.core import worklist_driver as wd
from snapdragon_studio.core.worklist_driver import WorklistDriver, key_profile
from snapdragon_studio.core.worklist import WorklistConfig, WorklistEntry, synthesize


def host(is_root=True, has_docker=True):
    return HostInfo(os="linux", is_gentoo=True, has_docker=has_docker, has_bash=True,
                    has_kvm=False, is_root=is_root, builder_image="snapdragon-builder")


def _base(tmp_path):
    b = ImageConfig(mode="mesh", role="omnibus", platform="x86", brand="acme",
                    brand_title="Acme", org="Acme-Inc", cluster_domain="acme.example",
                    superdomain="core.acme.internal", output_dir=str(tmp_path / "out"))
    b.domains = [Domain(name="acme.example", title="Acme"),
                 Domain(name="team.acme.example", title="Team", images=["be.rpi5"])]
    b.users = [User(username="root-admin", domain="core.acme.internal", role="superadmin")]
    return b


def _worklist(tmp_path, roles=(("pki", "x86"), ("be", "rpi5"), ("rpi5-desktop", "rpi5"))):
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
    assert key_profile("pki") == "pki"
    assert key_profile("be") == "backend"
    assert key_profile("fe") == "frontend"
    assert key_profile("omnibus") == "pki"        # single-node CP analogue
    assert key_profile("edge_ai") == "host"
    assert key_profile("full") == "pki"           # jetson single-node CP
    assert key_profile("gpu-host") == "host"
    assert key_profile("anything-else") == "host"  # fallback = worker key profile


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
    _install_fake_builddriver(monkeypatch, codes={"be": 3})   # middle image fails
    _install_fake_genkeys(monkeypatch)
    drv = WorklistDriver(str(tmp_path), _worklist(tmp_path), host=host())
    code = drv.run_all()
    assert [r.status for r in drv.results] == ["ok", "failed", "ok"]   # continued past the failure
    assert drv.results[1].exit_code == 3
    assert code == 1                                                    # nonzero summary
    assert drv.summary_exit_code() == 1


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
    assert [img["id"] for img in m["images"]] == ["pki.x86", "be.rpi5", "rpi5-desktop.rpi5"]
    assert {d["name"] for d in m["domains"]} == {"acme.example", "team.acme.example"}
    assert m["users"][0]["username"] == "root-admin"


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
    assert {e[0] for e in keys_events} == {"pki.x86", "be.rpi5"}


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
def test_preflight_shared_once_and_per_entry_labelled(tmp_path):
    # empty generator dir + non-root native: every image lacks its (platform-specific)
    # builder script AND shares the "needs root" problem.
    wl = _worklist(tmp_path, roles=(("pki", "x86"), ("be", "x86"), ("pki", "rpi5")))
    drv = WorklistDriver(str(tmp_path), wl, host=host(is_root=False), backend="native")
    problems = drv.preflight()
    root_msgs = [p for p in problems if "needs root" in p]
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
