"""``hugmesh-studio --qemu-windows ACTION [options]`` — the MSI console twin's way in.

Pure-core path through app.main(): everything after ``--qemu-windows`` reaches
core/qemu_windows.run_cli through that module's OWN parser (so the option names
cannot drift), the Studio's resolved checkout is the default --generator-dir, and
no Qt binding is ever imported.
"""
import sys

import pytest

from hugmesh_studio import app
from hugmesh_studio.core import qemu_windows as qw


@pytest.fixture
def seen(monkeypatch):
    got = []
    monkeypatch.setattr(qw, "run_cli", lambda args: got.append(args) or 0)
    return got


def test_check_reaches_run_cli(tmp_path, seen):
    assert app.main(["--generator-dir", str(tmp_path), "--qemu-windows", "check",
                     "--tcg"]) == 0
    (args,) = seen
    assert (args.action, args.tcg, args.generator_dir) == ("check", True, str(tmp_path))


def test_options_after_the_action_are_qemu_windows_own(tmp_path, seen):
    # --json and --generator-dir are ALSO Studio flags: after --qemu-windows they
    # belong to qemu_windows, never to the Studio's parser.
    assert app.main(["--qemu-windows", "plan", "--img", "a.img.xz", "--row", "x86/a",
                     "--mem", "1024", "--window", "--keep", "--json",
                     "--generator-dir", str(tmp_path)]) == 0
    (args,) = seen
    assert (args.action, args.img, args.row, args.mem, args.window, args.keep,
            args.json, args.generator_dir) == ("plan", "a.img.xz", "x86/a", 1024, True,
                                               True, True, str(tmp_path))


def test_exit_code_is_run_clis(monkeypatch):
    monkeypatch.setattr(qw, "run_cli", lambda args: 2)
    assert app.main(["--qemu-windows", "status"]) == 2


def test_unknown_action_is_an_argparse_error(capsys):
    with pytest.raises(SystemExit) as e:
        app.main(["--qemu-windows", "boot-everything"])
    assert e.value.code == 2
    assert "hugmesh-studio --qemu-windows" in capsys.readouterr().err


def test_qemu_windows_never_imports_qt(monkeypatch, capsys):
    monkeypatch.setattr(qw, "blocker", lambda accel="whpx": "not on this host")
    before = {m for m in sys.modules if m.split(".")[0] in ("PySide6", "PyQt6")}
    assert app.main(["--qemu-windows", "check"]) == 2
    after = {m for m in sys.modules if m.split(".")[0] in ("PySide6", "PyQt6")}
    assert after == before
    assert capsys.readouterr().out.strip() == "not on this host"
