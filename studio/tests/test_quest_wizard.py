"""MDM Quest headset wizard — the ModePage's quest side-flow (QuestPage) and the
quest device-class posture of the shared Qt-free core (core/phone_wizard.py).

The quest page rides the SAME PhoneWizard runner the phone page uses (one canonical
driver, scripts/phone-wizard.sh, with --device-class quest); what THESE tests pin is
everything the class changes:
  - --device-class quest rides FIRST on argv (the Makefile _QUEST_ARGS shape), the
    shared flags keep the ncurses order, and the headwind/XR management-plane flags
    thread after them — with the --authkey-file pair still LAST;
  - catalog CLASS-SCOPING: quest resolves quest-devices.tsv, phone keeps
    phone-devices.tsv — `panther` is BOTH the Pixel 7 and the Quest 3S, so the class
    must pick the catalog (the real shipped quest catalog is asserted too:
    eureka = Meta Quest 3, panther = Meta Quest 3S);
  - the quest verb subset: mdm-enroll IS streamable on quest (the phone fresh-device
    gates become non-interactive advisories there), fetch/flash/attest/profile are
    ABSENT from the page (the driver refuses them fail-closed);
  - the XR-chat toggle: the URL is emitted ONLY while the checkbox is on.

Everything is HERMETIC (stub driver through the SNAP_PHONE_WIZARD env seam — the
test_phone_wizard.py pattern); the GUI runs on Qt's offscreen platform.
"""
import os

import pytest

# must be set BEFORE the first QApplication is created
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.phone_wizard import (  # noqa: E402
    QUEST_STREAM_VERBS, QUEST_TERMINAL_VERBS, STREAM_VERBS, PhoneWizard,
    PhoneWizardConfig,
)
from hugmesh_studio.gui import wizard as wizard_mod  # noqa: E402
from hugmesh_studio.gui.pages import ModePage  # noqa: E402
from hugmesh_studio.gui.pages import quest as quest_mod  # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets  # noqa: E402
from tests.test_phone_wizard import (  # noqa: E402 — shared hermetic fixtures
    _drain_worker, _install_stub, qapp,  # noqa: F401 (qapp is a fixture)
)

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)


def _install_quest_tsv(tmp_path, tsv):
    """Drop a quest-devices.tsv next to the already-installed stub driver (the
    class-scoped catalog seam: same dirname as SNAP_PHONE_WIZARD)."""
    (tmp_path / "quest-devices.tsv").write_text(tsv)


# ---- pure-core: the quest device class on argv ----------------------------------

def test_quest_run_argv_class_first_flags_ordered_secret_off_argv(tmp_path, monkeypatch):
    out = _install_stub(tmp_path, monkeypatch)
    secret = "tskey-auth-Qu3st Secret!"
    pw = PhoneWizard(str(tmp_path), PhoneWizardConfig(
        device_class="quest", codename="eureka", channel="", serial="Q1",
        login_server="https://hs", role="user", auth_key=secret,
        headwind_apk="/apks/hmdm.apk", headwind_signer="AABB11",
        headwind_url="https://hmdm.example", headwind_config="xr-fleet",
        xr_chat_url="https://mesh.example/chat3d"))
    lines = []
    rc = pw.run("mdm-enroll", on_line=lines.append)

    assert rc == 0
    argv = (out / "argv").read_text().splitlines()
    # --device-class quest FIRST (the Makefile _QUEST_ARGS shape), then the shared
    # ncurses-ordered subset, then the management-plane flags, --authkey-file LAST.
    assert argv[:19] == [
        "mdm-enroll", "--device-class", "quest", "--codename", "eureka",
        "--serial", "Q1", "--login-server", "https://hs", "--role", "user",
        "--headwind-apk", "/apks/hmdm.apk", "--headwind-signer-sha256", "AABB11",
        "--headwind-url", "https://hmdm.example", "--headwind-config", "xr-fleet"]
    assert argv[19:21] == ["--xr-chat-url", "https://mesh.example/chat3d"]
    assert argv[21] == "--authkey-file"
    # the secret NEVER appears anywhere on argv; it rode a 0600 file, then shredded
    assert secret not in (out / "argv").read_text()
    assert (out / "key-content").read_text() == secret
    assert (out / "key-mode").read_text().strip() == "600"
    assert not os.path.exists((out / "key-path").read_text())
    assert any("stub ran verb=mdm-enroll" in ln for ln in lines)


def test_quest_bare_config_emits_only_the_class_flag(tmp_path, monkeypatch):
    out = _install_stub(tmp_path, monkeypatch)
    pw = PhoneWizard(str(tmp_path), PhoneWizardConfig(device_class="quest", channel=""))
    assert pw.run("status") == 0
    assert (out / "argv").read_text().splitlines() == ["status", "--device-class", "quest"]
    assert not (out / "key-path").exists()


def test_phone_default_emits_no_class_flag():
    # device_class="" (the default) keeps every existing phone argv byte-identical.
    assert "--device-class" not in PhoneWizardConfig(codename="comet").to_cli_args()


# ---- pure-core: class-scoped catalogs -------------------------------------------

def test_devices_tsv_is_class_scoped(tmp_path, monkeypatch):
    _install_stub(tmp_path, monkeypatch, tsv="panther\tPixel 7\n")
    _install_quest_tsv(tmp_path, "panther\tMeta Quest 3S\n")
    phone_rows = PhoneWizard(str(tmp_path)).device_catalog()
    quest_rows = PhoneWizard(
        str(tmp_path), PhoneWizardConfig(device_class="quest")).device_catalog()
    # the SAME codename resolves to a different device per class — the split is the
    # whole point (panther = Pixel 7 AND Quest 3S)
    assert phone_rows == [("panther", "Pixel 7")]
    assert quest_rows == [("panther", "Meta Quest 3S")]


def test_quest_catalog_reads_the_real_shipped_catalog():
    # against the real scripts/quest-devices.tsv: the two supported headsets, with
    # the codenames verified from authoritative sources (Quest 3 = eureka,
    # Quest 3S = panther).
    rows = PhoneWizard(GENERATOR_DIR,
                       PhoneWizardConfig(device_class="quest")).device_catalog()
    cats = dict(rows)
    assert cats["eureka"] == "Meta Quest 3"
    assert cats["panther"] == "Meta Quest 3S"
    # and the phone catalog still owns panther-the-Pixel — the class split is real
    phone_cats = dict(PhoneWizard(GENERATOR_DIR).device_catalog())
    assert phone_cats["panther"] == "Pixel 7"


# ---- pure-core: the quest verb subset -------------------------------------------

def test_quest_verb_sets_pin_the_class_contract():
    """mdm-enroll streams on quest (fresh-device gates are advisories there); the
    GrapheneOS-only verbs are absent; wizard stays the one TTY verb."""
    assert "mdm-enroll" in QUEST_STREAM_VERBS
    assert "mdm-enroll" not in STREAM_VERBS          # phone GUI keeps it gated
    for unsupported in ("fetch", "flash", "attest", "profile"):
        assert unsupported not in QUEST_STREAM_VERBS
        assert unsupported not in QUEST_TERMINAL_VERBS
    assert QUEST_TERMINAL_VERBS == ("wizard",)


# ---- GUI: the QuestPage surface (offscreen) --------------------------------------

def test_quest_page_populates_picker_from_the_quest_catalog(qapp):
    dlg = quest_mod.QuestDialog(GENERATOR_DIR)
    quest_rows = PhoneWizard(
        GENERATOR_DIR, PhoneWizardConfig(device_class="quest")).device_catalog()
    assert dlg.codename.count() == len(quest_rows) + 1   # <detect at run> + catalog
    assert dlg.codename.itemData(0) == ""                # first item = detect-at-run
    labels = [dlg.codename.itemText(i) for i in range(dlg.codename.count())]
    assert any("Meta Quest 3 (eureka)" in t for t in labels)
    assert any("Meta Quest 3S (panther)" in t for t in labels)
    # NOT the phone catalog: no Pixel ever offered on the quest page
    assert not any("Pixel" in t for t in labels)
    assert dlg.auth_key.echoMode() == QtWidgets.QLineEdit.EchoMode.Password
    assert dlg.page.isComplete() is True


def test_quest_page_exposes_only_the_quest_verbs(qapp):
    dlg = quest_mod.QuestDialog(GENERATOR_DIR)
    assert set(dlg._buttons) == {"wizard", "plan", "detect", "mdm-enroll",
                                 "enroll", "ingest", "status"}
    # the GrapheneOS-only verbs are NOT offered at all (the driver would refuse
    # them fail-closed; the page never even surfaces the temptation)
    for verb in ("fetch", "flash", "attest", "profile"):
        assert verb not in dlg._buttons


def test_quest_page_collect_pins_the_class_and_maps_widgets(qapp):
    dlg = quest_mod.QuestDialog(GENERATOR_DIR)
    i = dlg.codename.findData("eureka")
    assert i > 0
    dlg.codename.setCurrentIndex(i)
    dlg.serial.setText("Q1")
    dlg.login_server.setText("https://hs")
    dlg.role.setCurrentIndex(dlg.role.findData("admin"))
    dlg.auth_key.setText("tskey-q")
    dlg.headwind_url.setText("https://hmdm.example")
    dlg.headwind_apk.setText("/apks/hmdm.apk")
    dlg.headwind_signer.setText("AABB11")
    dlg.headwind_config.setText("xr-fleet")
    cfg = dlg.collect()
    assert cfg.device_class == "quest"
    assert cfg.channel == ""                 # no GrapheneOS channel on a headset
    assert (cfg.codename, cfg.serial, cfg.login_server, cfg.role) == \
        ("eureka", "Q1", "https://hs", "admin")
    assert (cfg.headwind_url, cfg.headwind_apk, cfg.headwind_signer,
            cfg.headwind_config) == \
        ("https://hmdm.example", "/apks/hmdm.apk", "AABB11", "xr-fleet")
    assert cfg.auth_key == "tskey-q"
    assert "tskey-q" not in cfg.to_cli_args()
    assert cfg.to_cli_args()[:2] == ["--device-class", "quest"]


def test_quest_page_xr_chat_url_rides_only_while_toggled(qapp):
    dlg = quest_mod.QuestDialog(GENERATOR_DIR)
    # off by default: the URL field is disabled and collect() emits ""
    assert dlg.xr_chat_enabled.isChecked() is False
    assert dlg.xr_chat_url.isEnabled() is False
    dlg.xr_chat_url.setText("https://mesh.example/chat3d")
    assert dlg.collect().xr_chat_url == ""
    assert "--xr-chat-url" not in dlg.collect().to_cli_args()
    # toggled on: the field arms and the URL threads through
    dlg.xr_chat_enabled.setChecked(True)
    assert dlg.xr_chat_url.isEnabled() is True
    assert dlg.collect().xr_chat_url == "https://mesh.example/chat3d"
    args = dlg.collect().to_cli_args()
    assert args[args.index("--xr-chat-url") + 1] == "https://mesh.example/chat3d"
    # and back off again: the stale text no longer leaks onto argv
    dlg.xr_chat_enabled.setChecked(False)
    assert dlg.xr_chat_url.isEnabled() is False
    assert "--xr-chat-url" not in dlg.collect().to_cli_args()


def test_quest_config_thin_desktop_args_ride_after_xr_chat(tmp_path, monkeypatch):
    """--thin-desktop (+ its value knobs) thread AFTER the XR-chat flag, toggle
    first — the driver refuses value knobs without the toggle, so the order and
    the pairing are part of the face contract."""
    out = _install_stub(tmp_path, monkeypatch)
    pw = PhoneWizard(str(tmp_path), PhoneWizardConfig(
        device_class="quest", codename="eureka", channel="", serial="Q1",
        xr_chat_url="https://mesh.example/chat3d",
        thin_desktop=True, moonlight_apk="/apks/moonlight.apk",
        moonlight_signer="CCDD22", thin_desktop_hosts="frite,box2.hugmesh.internal"))
    rc = pw.run("mdm-enroll")
    assert rc == 0
    argv = (out / "argv").read_text().splitlines()
    x = argv.index("--xr-chat-url")
    assert argv[x + 2:x + 9] == [
        "--thin-desktop", "--moonlight-apk", "/apks/moonlight.apk",
        "--moonlight-signer-sha256", "CCDD22",
        "--thin-desktop-hosts", "frite,box2.hugmesh.internal"]


def test_quest_config_thin_desktop_default_emits_nothing():
    """The un-toggled default emits NO thin-desktop flag — every existing quest
    argv stays byte-identical (the device_class-default invariant's twin)."""
    args = PhoneWizardConfig(device_class="quest", codename="eureka",
                             channel="").to_cli_args()
    for flag in ("--thin-desktop", "--moonlight-apk",
                 "--moonlight-signer-sha256", "--thin-desktop-hosts"):
        assert flag not in args


def test_quest_page_thin_desktop_rides_only_while_toggled(qapp):
    dlg = quest_mod.QuestDialog(GENERATOR_DIR)
    # off by default: fields disabled, collect() emits nothing thin-desktop
    assert dlg.thin_desktop_enabled.isChecked() is False
    assert dlg.moonlight_signer.isEnabled() is False
    assert dlg.thin_desktop_hosts.isEnabled() is False
    dlg.moonlight_apk.setText("/apks/moonlight.apk")
    dlg.moonlight_signer.setText("CCDD22")
    dlg.thin_desktop_hosts.setText("frite")
    cfg = dlg.collect()
    assert cfg.thin_desktop is False
    assert (cfg.moonlight_apk, cfg.moonlight_signer, cfg.thin_desktop_hosts) == \
        ("", "", "")
    assert "--thin-desktop" not in cfg.to_cli_args()
    # toggled on: fields arm and the whole set threads through together
    dlg.thin_desktop_enabled.setChecked(True)
    assert dlg.moonlight_signer.isEnabled() is True
    assert dlg.thin_desktop_hosts.isEnabled() is True
    cfg = dlg.collect()
    assert cfg.thin_desktop is True
    assert (cfg.moonlight_apk, cfg.moonlight_signer, cfg.thin_desktop_hosts) == \
        ("/apks/moonlight.apk", "CCDD22", "frite")
    args = cfg.to_cli_args()
    assert "--thin-desktop" in args
    assert args[args.index("--thin-desktop-hosts") + 1] == "frite"
    # and back off: the stale texts no longer leak onto argv (driver would die 1)
    dlg.thin_desktop_enabled.setChecked(False)
    args = dlg.collect().to_cli_args()
    for flag in ("--thin-desktop", "--moonlight-apk",
                 "--moonlight-signer-sha256", "--thin-desktop-hosts"):
        assert flag not in args


def test_quest_page_streamed_verb_runs_off_thread_with_the_class_flag(
        qapp, tmp_path, monkeypatch):
    dlg = quest_mod.QuestDialog(GENERATOR_DIR)     # picker from the real catalog
    out = _install_stub(tmp_path, monkeypatch)     # but the RUN uses the stub
    dlg.codename.setCurrentText("eureka")          # typed -> raw codename
    dlg.serial.setText("Q1")
    dlg._run_stream("plan", "Plan")
    _drain_worker(qapp, dlg.page)
    argv = (out / "argv").read_text().splitlines()
    assert argv[0] == "plan"
    assert argv[1:3] == ["--device-class", "quest"]
    assert "--codename" in argv and "eureka" in argv
    assert dlg.page.isComplete() is True           # Finish re-armed after done
    assert "stub ran verb=plan" in dlg.log.toPlainText()


def test_quest_module_imports_no_qtwebengine():
    """QtWebEngine is absent under PyQt6 in this env and is never needed here — the
    page must not import it (directly or transitively)."""
    import sys

    import hugmesh_studio.gui.pages.quest as m
    with open(m.__file__, encoding="utf-8") as fh:
        assert "QtWebEngine" not in fh.read()
    assert not any("QtWebEngine" in name for name in sys.modules)


def test_mode_page_quest_radio_flows_into_the_terminal_page(qapp):
    """Selecting the MDM Quest headset radio raises wiz.quest_selected, leaves
    cfg.mode an image mode, and routes into the terminal QuestPage (the phone
    side-flow contract, quest twin)."""
    wiz = wizard_mod.StudioWizard(GENERATOR_DIR)
    try:
        mp = next(p for p in wiz._pages if isinstance(p, ModePage))
        before = wiz.cfg.mode
        for b in mp.group.buttons():
            if b.property("mode") == "quest":
                b.setChecked(True)
        assert mp.isComplete() is True
        assert mp.validatePage() is True
        assert wiz.quest_selected is True
        assert wiz.phone_selected is False
        assert wiz.localmesh_selected is False
        assert wiz.cfg.mode == before                # cfg.mode untouched (not an image mode)
        qp = wiz.page(wiz._page_ids["quest"])
        assert qp.applies_to(wiz.cfg) is True
        assert qp.nextId() == -1 and qp.isFinalPage()
    finally:
        wiz.deleteLater()
