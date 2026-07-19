"""MDM phone wizard — the ModePage's fifth first-screen choice (PhonePage) and the
Qt-free core it fronts (core/phone_wizard.py).

Everything here is HERMETIC: the driver is a STUB shell script pointed at through the
SNAP_PHONE_WIZARD env seam (the exact pattern tests/menu/build_menu_cmd_test.sh uses
for _phone_run) — no real adb/fastboot/flash/docker ever runs, and no terminal
emulator is ever launched. The core assertions prove the contract that matters most:
the auth key NEVER lands on argv, rides a 0600 --authkey-file, and is shredded after
the run.

Runs the REAL page on Qt's offscreen platform; skipped whole when no Qt binding is
installed (mirrors test_local_mesh.py — the pure-core assertions still need the core
import, which does not require Qt, but live here beside the GUI ones for locality).
"""
import os
import stat

import pytest

# must be set BEFORE the first QApplication is created
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("snapdragon_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from snapdragon_studio.core import phone_wizard as phone_wizard  # noqa: E402
from snapdragon_studio.core.phone_wizard import (  # noqa: E402
    PhoneWizard, PhoneWizardConfig,
)
from snapdragon_studio.gui import wizard as wizard_mod  # noqa: E402
from snapdragon_studio.gui.pages import phone as phone_mod  # noqa: E402
from snapdragon_studio.gui.pages import ModePage  # noqa: E402
from snapdragon_studio.gui.qt import QtWidgets  # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

# A stub driver that records its argv and — at CHILD runtime — the --authkey-file's
# content + octal mode + path, proving the secret travels by 0600 file only. It is
# the studio-side twin of build_menu_cmd_test.sh's EOSTUB.
_STUB = """#!/usr/bin/env bash
printf '%s\\n' "$@" >"${PHONE_STUB_OUT:?}/argv"
prev=""
for a in "$@"; do
    if [ "${prev}" = "--authkey-file" ]; then
        cat -- "${a}" >"${PHONE_STUB_OUT}/key-content" 2>/dev/null
        stat -c '%a' -- "${a}" >"${PHONE_STUB_OUT}/key-mode" 2>/dev/null
        printf '%s' "${a}" >"${PHONE_STUB_OUT}/key-path"
    fi
    prev="${a}"
done
echo "stub ran verb=$1"
exit "${PHONE_STUB_RC:-0}"
"""


def _install_stub(tmp_path, monkeypatch, tsv=None):
    """Write the stub driver + wire the SNAP_PHONE_WIZARD / PHONE_STUB_OUT seams; when
    ``tsv`` is given, drop a phone-devices.tsv next to the stub (the catalog source).
    Returns the out-dir the stub writes its captures into."""
    stub = tmp_path / "stub-phone-wizard.sh"
    stub.write_text(_STUB)
    stub.chmod(0o755)
    out = tmp_path / "stub-out"
    out.mkdir()
    if tsv is not None:
        (tmp_path / "phone-devices.tsv").write_text(tsv)
    monkeypatch.setenv("SNAP_PHONE_WIZARD", str(stub))
    monkeypatch.setenv("PHONE_STUB_OUT", str(out))
    return out


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["snapdragon-studio-tests"]))


def _drain_worker(qapp, host, timeout_ms=5000):
    """Join the _MeshWorker (verbs run OFF the GUI thread) and pump the loop so its
    queued line/done signals land before the test asserts."""
    w = getattr(host, "worker", None)
    if w is not None:
        w.wait(timeout_ms)
    for _ in range(200):
        qapp.processEvents()


# ---- pure-core: argv marshalling + off-argv 0600 secret -------------------------

def test_run_argv_is_verb_first_options_ordered_and_secret_off_argv(tmp_path, monkeypatch):
    out = _install_stub(tmp_path, monkeypatch)
    secret = "tskey-auth-Sup3r Secret!"
    pw = PhoneWizard(str(tmp_path), PhoneWizardConfig(
        codename="comet", channel="beta", serial="S1", login_server="https://hs",
        role="admin", auth_key=secret))
    lines = []
    rc = pw.run("enroll", on_line=lines.append)

    assert rc == 0
    argv = (out / "argv").read_text().splitlines()
    # verb first, options in the ncurses _phone_run order; the key rides at the tail
    assert argv[:11] == ["enroll", "--codename", "comet", "--channel", "beta",
                         "--serial", "S1", "--login-server", "https://hs",
                         "--role", "admin"]
    assert argv[11] == "--authkey-file"
    # the secret NEVER appears anywhere on argv
    assert secret not in (out / "argv").read_text()
    # it rode a 0600 file whose content is exactly the secret (no trailing newline) …
    assert (out / "key-content").read_text() == secret
    assert (out / "key-mode").read_text().strip() == "600"
    # … and the file was shredded after the run
    assert not os.path.exists((out / "key-path").read_text())
    assert any("stub ran verb=enroll" in ln for ln in lines)


def test_run_bare_verb_emits_no_empty_flags_and_no_keyfile(tmp_path, monkeypatch):
    out = _install_stub(tmp_path, monkeypatch)
    # channel="" so even the defaulted flag is suppressed: a bare verb is JUST the verb
    pw = PhoneWizard(str(tmp_path), PhoneWizardConfig(channel=""))
    assert pw.run("status") == 0
    assert (out / "argv").read_text().splitlines() == ["status"]
    assert not (out / "key-path").exists()   # no auth key -> no --authkey-file at all


def test_run_keys_dir_threads_and_server_role_stay_driver_side(tmp_path, monkeypatch):
    out = _install_stub(tmp_path, monkeypatch)
    pw = PhoneWizard(str(tmp_path), PhoneWizardConfig(channel="stable", keys_dir="/tmp/pw-keys"))
    assert pw.run("detect") == 0
    assert (out / "argv").read_text().splitlines() == [
        "detect", "--channel", "stable", "--keys-dir", "/tmp/pw-keys"]


def test_run_nonzero_driver_rc_is_returned(tmp_path, monkeypatch):
    _install_stub(tmp_path, monkeypatch)
    monkeypatch.setenv("PHONE_STUB_RC", "7")
    pw = PhoneWizard(str(tmp_path), PhoneWizardConfig(channel=""))
    assert pw.run("status") == 7


def test_to_cli_args_never_contains_the_auth_key():
    cfg = PhoneWizardConfig(codename="comet", auth_key="tskey-SECRET")
    assert "tskey-SECRET" not in cfg.to_cli_args()
    assert cfg.to_cli_args()[:2] == ["--codename", "comet"]


# ---- pure-core: device catalog + availability -----------------------------------

def test_device_catalog_parses_tabs_and_skips_comments_and_blanks(tmp_path, monkeypatch):
    _install_stub(tmp_path, monkeypatch,
                  tsv="# a comment\n\noriole\tPixel 6\nno_tab_line\ncomet\tPixel 9 Pro Fold\n")
    rows = PhoneWizard(str(tmp_path)).device_catalog()
    assert rows == [("oriole", "Pixel 6"), ("comet", "Pixel 9 Pro Fold")]


def test_device_catalog_reads_the_real_shipped_catalog():
    # against the real scripts/phone-devices.tsv (no env seam): a non-empty, well-
    # formed catalog with the known Pixel codenames present.
    rows = PhoneWizard(GENERATOR_DIR).device_catalog()
    cats = dict(rows)
    assert len(rows) >= 20
    assert cats["comet"] == "Pixel 9 Pro Fold"
    assert cats["oriole"] == "Pixel 6"


def test_available_false_when_driver_missing(tmp_path, monkeypatch):
    monkeypatch.setenv("SNAP_PHONE_WIZARD", str(tmp_path / "nope.sh"))
    ok, why = PhoneWizard(str(tmp_path)).available()
    assert ok is False and "not found" in why.lower()


def test_available_false_when_driver_not_executable(tmp_path, monkeypatch):
    f = tmp_path / "ne.sh"
    f.write_text("#!/usr/bin/env bash\n")
    f.chmod(0o644)
    monkeypatch.setenv("SNAP_PHONE_WIZARD", str(f))
    assert PhoneWizard(str(tmp_path)).available()[0] is False


def test_available_true_for_the_real_shipped_driver():
    ok, _why = PhoneWizard(GENERATOR_DIR).available()
    assert ok is True


# ---- pure-core: the TTY verbs (flash / wizard) defer to a terminal ---------------

def test_flash_defers_to_terminal_and_never_stages_the_key(tmp_path, monkeypatch):
    _install_stub(tmp_path, monkeypatch)
    monkeypatch.setattr(phone_wizard.shutil, "which", lambda *_: None)  # no emulator
    staged = {"called": False}
    monkeypatch.setattr(PhoneWizard, "_stage_authkey",
                        staticmethod(lambda s: staged.__setitem__("called", True) or "/x"))
    pw = PhoneWizard(str(tmp_path), PhoneWizardConfig(
        codename="comet", serial="S9", auth_key="tskey-SECRET"))
    ok, msg = pw.run_verb_in_terminal("flash")
    assert ok is False and "no terminal emulator" in msg.lower()
    # flash is destructive but needs no secret — the key is NEVER staged for it …
    assert staged["called"] is False
    assert "tskey-SECRET" not in msg
    # … and the exact command to run by hand is handed back (verb + typed serial)
    assert "flash" in msg and "--serial" in msg and "S9" in msg


def test_wizard_terminal_launch_keeps_the_secret_off_the_terminal_argv(tmp_path, monkeypatch):
    _install_stub(tmp_path, monkeypatch)
    monkeypatch.setattr(phone_wizard.shutil, "which", lambda name: "/usr/bin/" + name)
    launched = {}
    monkeypatch.setattr(phone_wizard.subprocess, "Popen",
                        lambda cmd, **kw: launched.update(cmd=cmd) or object())
    staged = {}
    _orig = PhoneWizard._stage_authkey
    monkeypatch.setattr(PhoneWizard, "_stage_authkey",
                        staticmethod(lambda s: staged.setdefault("path", _orig(s))))
    pw = PhoneWizard(str(tmp_path), PhoneWizardConfig(codename="comet", auth_key="tskey-SECRET"))
    ok, _msg = pw.run_verb_in_terminal("wizard")
    assert ok is True
    script = launched["cmd"][-1]
    # the wizard needs the key (it runs enroll) — but it rides a --authkey-file, so
    # the SECRET VALUE is never on the terminal's argv, and the wrapper shreds the
    # file when the session ends.
    assert "--authkey-file" in script
    assert "tskey-SECRET" not in script
    assert "shred" in script
    # the staged file itself is a 0600 file holding exactly the secret
    p = staged["path"]
    assert stat.S_IMODE(os.stat(p).st_mode) == 0o600
    with open(p) as fh:
        assert fh.read() == "tskey-SECRET"
    os.unlink(p)   # the fake terminal never ran, so remove the staged key ourselves


# ---- GUI: the PhonePage surface (offscreen) --------------------------------------

def test_phone_page_populates_picker_and_masks_the_key(qapp):
    dlg = phone_mod.PhoneDialog(GENERATOR_DIR)
    n = len(PhoneWizard(GENERATOR_DIR).device_catalog())
    assert dlg.codename.count() == n + 1            # <detect at run> + the catalog
    assert dlg.codename.itemData(0) == ""           # first item = detect-at-run
    assert dlg.auth_key.echoMode() == QtWidgets.QLineEdit.EchoMode.Password
    assert dlg.page.isComplete() is True
    # the ncurses button set is exposed
    assert set(dlg._buttons) == {"wizard", "plan", "detect", "fetch", "flash",
                                 "enroll", "profile", "ingest", "status"}


def test_phone_page_collect_maps_widgets_and_keeps_key_off_argv(qapp):
    dlg = phone_mod.PhoneDialog(GENERATOR_DIR)
    i = dlg.codename.findData("comet")
    assert i > 0
    dlg.codename.setCurrentIndex(i)
    dlg.channel.setCurrentText("beta")
    dlg.serial.setText("S1")
    dlg.login_server.setText("https://hs")
    dlg.role.setCurrentIndex(dlg.role.findData("admin"))
    dlg.auth_key.setText("tskey-x")
    cfg = dlg.collect()
    assert (cfg.codename, cfg.channel, cfg.serial, cfg.login_server, cfg.role) == \
        ("comet", "beta", "S1", "https://hs", "admin")
    assert cfg.auth_key == "tskey-x"
    assert "tskey-x" not in cfg.to_cli_args()


def test_phone_page_detect_at_run_yields_empty_codename(qapp):
    dlg = phone_mod.PhoneDialog(GENERATOR_DIR)
    dlg.codename.setCurrentIndex(0)                 # <detect at run>
    assert dlg.collect().codename == ""


def test_phone_page_streamed_verb_runs_off_thread(qapp, tmp_path, monkeypatch):
    dlg = phone_mod.PhoneDialog(GENERATOR_DIR)      # picker from the real catalog
    out = _install_stub(tmp_path, monkeypatch)      # but the RUN uses the stub
    dlg.codename.setCurrentText("comet")            # typed -> raw codename
    dlg.serial.setText("S1")
    dlg._run_stream("plan", "Plan")
    _drain_worker(qapp, dlg.page)
    argv = (out / "argv").read_text().splitlines()
    assert argv[0] == "plan"
    assert "--codename" in argv and "comet" in argv
    assert dlg.page.isComplete() is True            # Finish re-armed after done
    assert "stub ran verb=plan" in dlg.log.toPlainText()


def test_phone_module_imports_no_qtwebengine():
    """QtWebEngine is absent under PyQt6 in this env and is never needed here — the
    page must not import it (directly or transitively)."""
    import sys

    import snapdragon_studio.gui.pages.phone as m
    with open(m.__file__, encoding="utf-8") as fh:
        assert "QtWebEngine" not in fh.read()
    assert not any("QtWebEngine" in name for name in sys.modules)


def test_mode_page_phone_radio_flows_into_the_terminal_page(qapp):
    """Selecting the MDM phone radio raises wiz.phone_selected, leaves cfg.mode an
    image mode, and routes into the terminal PhonePage (mirrors the localmesh side-
    flow contract)."""
    wiz = wizard_mod.StudioWizard(GENERATOR_DIR)
    try:
        mp = next(p for p in wiz._pages if isinstance(p, ModePage))
        before = wiz.cfg.mode
        for b in mp.group.buttons():
            if b.property("mode") == "phone":
                b.setChecked(True)
        assert mp.isComplete() is True
        assert mp.validatePage() is True
        assert wiz.phone_selected is True
        assert wiz.localmesh_selected is False
        assert wiz.cfg.mode == before                # cfg.mode untouched (not an image mode)
        pp = wiz.page(wiz._page_ids["phone"])
        assert pp.applies_to(wiz.cfg) is True
        assert pp.nextId() == -1 and pp.isFinalPage()
    finally:
        wiz.deleteLater()
