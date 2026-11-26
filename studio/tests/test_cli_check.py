"""Headless ``--check``: a config validated without the GUI (hugmesh-generator parity gaps
G44, G50, G58, G59, G62).

Pure-core paths through ``app.main()``: no Qt, no display. Pins the verb's exit status
(0 nothing blocks, 1 problems, 2 bad input), its stable ``--json`` schema, that the
gates behind it are the wizard's own (core/config_check.py has the per-gate cases), and
that the verbs that were already tolerant of a config keep their tolerance.
"""
import json
import os
import subprocess
import sys

import pytest

from hugmesh_studio import app
from hugmesh_studio.core import worklist_driver
from hugmesh_studio.core.config import ImageConfig
from hugmesh_studio.core.platform_info import HostInfo

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)


@pytest.fixture(autouse=True)
def _a_root_host_without_docker(monkeypatch, tmp_path):
    """The preflight asks THIS host about Docker, free disk and the output folder: pin
    the answers so the verdict is the config's, whatever machine runs the suite."""
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setattr(
        worklist_driver, "detect",
        lambda builder_image="hugmesh-builder": HostInfo(
            os="linux", is_gentoo=True, has_docker=False, has_bash=True, has_kvm=False,
            is_root=True, builder_image=builder_image))


def _write(tmp_path, name="cfg.json", **fields) -> str:
    base = ImageConfig(mode="cloud", role="laptop", platform="x86",
                       output_dir=str(tmp_path / "out")).to_dict()
    base.update(fields)
    path = tmp_path / name
    path.write_text(json.dumps(base))
    return str(path)


def _check(path, *extra):
    return app.main(["--check", "--config", path, "--generator-dir", GENERATOR_DIR,
                     "--backend", "native", *extra])


# ── exit status ────────────────────────────────────────────────────────────────────────
def test_a_clean_config_exits_zero(tmp_path, capsys):
    assert _check(_write(tmp_path)) == 0
    lines = capsys.readouterr().out.splitlines()
    assert lines[0] == "config: 1 image(s): laptop.x86" and lines[-1] == "ok"


def test_a_config_with_problems_exits_one_and_names_each(tmp_path, capsys):
    path = _write(tmp_path, bogus_key=1, optional_services=["akoma"], img_size=1000)
    assert _check(path) == 1
    out = capsys.readouterr().out
    assert "[unknown-key] unknown key 'bogus_key'" in out
    assert "[service] optional_services: unknown service 'akoma' (did you mean 'akkoma'?)" in out
    assert "[root-size] laptop.x86: Root image size 1000 MiB is below" in out
    assert out.splitlines()[-1].startswith("FAILED: 3 problem(s)")


def test_warnings_print_and_do_not_change_the_exit(tmp_path, capsys):
    path = _write(tmp_path, role="pki", mode="mesh", standalone=True)   # x86: accepted, wrong
    rc = _check(path)
    out = capsys.readouterr().out
    assert "warning  [scope]" in out and "silently wrong" in out
    # the problems it does have (a mesh with no pki address, an unreviewed domain) are
    # others'; the warning itself never made the exit non-zero
    assert rc == (1 if "problem  " in out else 0)


@pytest.mark.parametrize("name,text", [("missing.json", None), ("bad.json", "{nope"),
                                       ("array.json", "[1, 2]")])
def test_a_file_that_is_no_config_exits_two(tmp_path, capsys, name, text):
    path = tmp_path / name
    if text is not None:
        path.write_text(text)
    assert _check(str(path), "--json") == 2
    cap = capsys.readouterr()
    assert cap.out == ""                           # stdout stays machine-readable
    assert cap.err.startswith("error: ")


def test_check_against_a_folder_that_is_no_checkout_exits_two(tmp_path, capsys):
    """Like --print-command: a build cannot run from there, and the table in --help
    promises 2 for it."""
    rc = app.main(["--check", "--config", _write(tmp_path), "--generator-dir",
                   str(tmp_path / "empty")])
    assert rc == 2
    assert "(pass --generator-dir)" in capsys.readouterr().err


def test_check_without_a_config_exits_two(capsys):
    assert app.main(["--check"]) == 2
    assert "--check needs --config FILE" in capsys.readouterr().err


# ── --json ─────────────────────────────────────────────────────────────────────────────
def test_json_schema_is_stable(tmp_path, capsys):
    path = _write(tmp_path, bogus_key=1)
    assert _check(path, "--json") == 1
    d = json.loads(capsys.readouterr().out)
    # the STABLE schema: extending it is a deliberate contract change
    assert set(d) == {"ok", "kind", "images", "problems", "warnings"}
    assert d["ok"] is False and d["kind"] == "config" and d["images"] == ["laptop.x86"]
    [p] = d["problems"]
    assert set(p) == {"check", "image", "message"}
    assert p["check"] == "unknown-key" and p["image"] == ""
    # warnings are the same shape (which ones a host adds, e.g. missing squashfs tools,
    # is the host's)
    assert all(set(w) == {"check", "image", "message"} for w in d["warnings"])


def test_json_of_a_clean_config(tmp_path, capsys):
    assert _check(_write(tmp_path), "--json") == 0
    d = json.loads(capsys.readouterr().out)
    assert (d["ok"], d["problems"]) == (True, [])


def test_a_worklist_envelope_is_checked_as_one(tmp_path, capsys):
    from hugmesh_studio.core.worklist import WorklistConfig, WorklistEntry
    cfg = ImageConfig(mode="mesh", role="omnibus", platform="x86", tailscale=True,
                      pki_lan_ip="192.168.1.10", pki_lan_ip_fixed=True,
                      output_dir=str(tmp_path / "out"))
    cfg.domain_services_reviewed = [cfg.cluster_domain]
    env = WorklistConfig(base=cfg, entries=[WorklistEntry(role="omnibus", platform="x86"),
                                            WorklistEntry(role="backend", platform="x86")]
                         ).to_dict()
    env["entries"][1]["colour"] = "red"
    path = tmp_path / "wl.json"
    path.write_text(json.dumps(env))
    assert _check(str(path), "--json") == 1
    d = json.loads(capsys.readouterr().out)
    assert d["kind"] == "worklist" and d["images"] == ["omnibus.x86", "backend.x86"]
    assert [p["check"] for p in d["problems"]] == ["unknown-key"]
    assert "'entries[1].colour'" in d["problems"][0]["message"]


# ── what it must not disturb ───────────────────────────────────────────────────────────
def test_the_print_verbs_keep_their_tolerance(tmp_path, capsys):
    """--check is the strict reader. --print-command still loads a config with a key it
    does not know (a config from a newer Studio) and builds the command: forward
    compatibility there is deliberate, and reporting is this verb's job."""
    path = _write(tmp_path, bogus_key=1)
    assert app.main(["--print-command", "--config", path, "--generator-dir",
                     GENERATOR_DIR, "--backend", "native"]) == 0
    assert "build-x86-host-stage4.sh" in capsys.readouterr().out


def test_check_never_imports_qt(tmp_path, capsys):
    before = {m for m in sys.modules if m.split(".")[0] in ("PySide6", "PyQt6")}
    assert _check(_write(tmp_path)) == 0
    after = {m for m in sys.modules if m.split(".")[0] in ("PySide6", "PyQt6")}
    assert after == before
    capsys.readouterr()


def test_check_checks_what_the_gui_build_page_checks(tmp_path, capsys):
    """G50: the root-size floor was GUI-only. The words printed here are the words
    core.root_size_floor gives the Build page (which reads the same function)."""
    from hugmesh_studio.core import root_size_floor
    from hugmesh_studio.core.worklist import synthesize
    path = _write(tmp_path, img_size=1000)
    assert _check(path) == 1
    out = capsys.readouterr().out
    cfg = ImageConfig.load(path)
    [(_eid, words)] = root_size_floor.entry_errors(synthesize(cfg).entries, cfg)
    assert words in out


# ── --help documents the verb and the exit status (G62) ────────────────────────────────
def test_help_documents_the_verb_and_every_exit_status(capsys):
    with pytest.raises(SystemExit):
        app.main(["--help"])
    text = " ".join(capsys.readouterr().out.split())
    assert "--check" in text and "Exit 0 = nothing blocks, 1 = problems, 2 = the file cannot be read" in text
    assert "exit status of the headless verbs:" in text
    for code in ("0 done", "1 it ran and found a problem", "2 bad input", "3 refused"):
        assert code in text, code


# ── a real process, no display ─────────────────────────────────────────────────────────
def test_check_in_a_real_process_needs_no_display(tmp_path):
    path = _write(tmp_path, bogus_key=1)
    env = dict(os.environ, PYTHONPATH=STUDIO_ROOT, HUGMESH_STUDIO_NO_ELEVATION="1",
               HUGMESH_STUDIO_STATE_DIR=str(tmp_path / "state"))
    env.pop("DISPLAY", None)
    env.pop("WAYLAND_DISPLAY", None)
    r = subprocess.run(
        [sys.executable, "-m", "hugmesh_studio", "--check", "--json", "--config", path,
         "--generator-dir", GENERATOR_DIR, "--backend", "native"],
        capture_output=True, text=True, timeout=120, env=env, cwd=STUDIO_ROOT)
    assert r.returncode == 1, r.stderr
    d = json.loads(r.stdout)
    assert d["ok"] is False
    assert [p for p in d["problems"] if p["check"] == "unknown-key"]
