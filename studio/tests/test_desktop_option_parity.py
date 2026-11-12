"""Every Desktop option, on every face that builds a standalone desktop.

Operator rule: GUI, TUI and CLI parity, and every standalone menu offers every option or
shows it greyed with its reason (never an inert one). The faces:

* gui  — the Studio window's Desktop step (gui/pages/desktop.py; the GPU driver and the
         login account are the Hardware and Home steps' rows, linked from it);
* tui  — the text UI's Desktop step (tui/desktop_step.py);
* cli  — a config JSON for ``--print-command`` (+ ``--desktop-options``, ``--desktop-pretend``);
* menu — ``make menu`` (scripts/build-menu.sh desktop_screen, which reads the same model
         through core/desktop_menu.py); its real handler (_desk_edit) is driven with
         canned answers and the composed ``make`` argv is read back.

The option list is FROZEN here (not read from the code), so a face that drops one, or a
model that loses one, fails. Each live cell SETS the option through that face and checks
the builder argv carries it; each greyed cell checks the face shows the same reason.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import textwrap

import pytest

from hugmesh_studio.core import desktop_cli
from hugmesh_studio.core import desktop_menu as dm
from hugmesh_studio.core import desktop_spec as ds
from hugmesh_studio.core.config import ImageConfig
from hugmesh_studio.tui import journey
from hugmesh_studio.tui.desktop_step import COMMANDS

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

#: The frozen option list (docs/DESKTOP-STEP.md "Every option, every face").
EXPECTED_OPTION_IDS = (
    "environment", "steam", "login_manager", "openbox", "i3", "picom", "sway", "wayfire",
    "labwc", "default_session", "gpu_driver", "video_cards", "primary_account",
    "extra_users", "apps_native", "apps_flatpak", "flatpak_remotes", "python", "overlay",
    "pretend", "assistant",
)

REMOTE = "kde=https://distribute.kde.org/kderepo.flatpakrepo"

#: Live options: how each face sets it, and the argv it must then carry. ``want`` is a
#: list of fragments of the space-joined argv with shell quotes removed.
#:   tui: the text UI commands; cli: the config JSON keys; menu: (tag, canned answers);
#:   gui: a setter name in GUI_SETTERS below.
LIVE = {
    "environment": dict(tui=["env plasma"], cli={"capable": True},
                        menu=("environment", ["plasma"]), want=["--capable"]),
    "steam": dict(tui=["steam flatpak"], cli={"steam": "flatpak"},
                  menu=("steam", ["flatpak"]), want=["--steam flatpak"]),
    "default_session": dict(tui=["default openbox"], cli={"desktop_spec": {"default_session": "openbox"}},
                            menu=("default_session", ["openbox"]), want=["--default-session openbox"]),
    "gpu_driver": dict(tui=["gpu nvidia-free"], cli={"gpu_driver": "nvidia-free"},
                       menu=("gpu_driver", ["nvidia-free"]), want=["--gpu-driver nvidia-free"]),
    "video_cards": dict(tui=["cards intel virgl"], cli={"desktop_spec": {"video_cards": ["intel", "virgl"]}},
                        menu=("video_cards", ["intel virgl"]), want=["--video-cards intel virgl"]),
    "primary_account": dict(tui=["login alice admin pass={pw}"],
                            cli={"local_user": "alice", "local_admin": True},
                            menu=("primary_account", ["alice", "yes"]),
                            want=["--local-user alice", "--local-admin"],
                            # a config JSON holds no password, and --local-admin rides
                            # with the password typed at build time
                            want_cli=["--local-user alice"]),
    "extra_users": dict(tui=["user add ann pass={pw}"],
                        cli={"desktop_spec": {"extra_users": [{"name": "ann"}]}},
                        menu=("extra_users", ["add", "ann", "no", "first-pw"]),
                        want=["--extra-local-users ann", "--extra-local-pass-file"]),
    "apps_native": dict(tui=["app gimp native"],
                        cli={"desktop_spec": {"apps": [{"id": "gimp", "label": "GIMP", "delivery": "native",
                                                        "atom": "media-gfx/gimp"}]}},
                        menu=("apps_native", ["pick", "gimp"]), want=["--packages-add", "media-gfx/gimp"]),
    "apps_flatpak": dict(tui=["app gimp flatpak"],
                         cli={"desktop_spec": {"apps": [{"id": "gimp", "label": "GIMP", "delivery": "flatpak",
                                                         "flatpak": "org.gimp.GIMP", "remote": "flathub"}]}},
                         menu=("apps_flatpak", ["pick", "gimp"]), want=["--flatpak-apps flathub:org.gimp.GIMP"]),
    "flatpak_remotes": dict(tui=[f"remote {REMOTE}"],
                            cli={"desktop_spec": {"flatpak_remotes": dict([REMOTE.split("=", 1)])}},
                            menu=("flatpak_remotes", ["add", REMOTE]), want=[f"--flatpak-remotes {REMOTE}"]),
    "python": dict(tui=["py +python3_13", "py single python3_13"],
                   cli={"desktop_spec": {"python_extra_targets": ["python3_13"],
                                         "python_single_target": "python3_13"}},
                   menu=("python", ["extra", "python3_13"]),
                   want=["--python-extra-targets python3_13"]),
    "overlay": dict(tui=["use media-gfx/gimp lua"], cli={"desktop_spec": {"use_lines": ["media-gfx/gimp lua"]}},
                    menu=("overlay", ["use", "media-gfx/gimp lua"]), want=["--package-use media-gfx/gimp lua"]),
}
for _s in ds.SESSION_OPTION_IDS:
    LIVE[_s] = dict(tui=[f"s +{_s}"], cli={"desktop_spec": {"sessions": [_s]}},
                    menu=("sessions", [_s]), want=[f"--desktop-sessions {_s}"])

#: Options with nothing to set (shown on every face) and the one action.
INFO = ("login_manager", "openbox")
ACTION = ("pretend",)
GUI_ONLY = ("assistant",)

FACES = ("gui", "tui", "cli", "menu")


def _flat(argv) -> str:
    return " ".join(argv).replace("'", "")


def test_the_option_list_is_the_frozen_one():
    assert ds.OPTION_IDS == EXPECTED_OPTION_IDS
    covered = set(LIVE) | set(INFO) | set(ACTION) | set(GUI_ONLY)
    assert covered == set(EXPECTED_OPTION_IDS), covered ^ set(EXPECTED_OPTION_IDS)
    # the menu's rows cover every option exactly once
    rows = [o for _t, _k, oids in dm.ROWS for o in oids]
    assert sorted(rows) == sorted(EXPECTED_OPTION_IDS)


# ── the faces ───────────────────────────────────────────────────────────────────────


def _base(platform="x86", role="standalone-thin") -> ImageConfig:
    return ImageConfig(mode="standalone", role=role, platform=platform, local_user="snap")


def tui_argv(opt: str, tmp_path) -> str:
    pw = tmp_path / "pw"
    pw.write_text("first-pw\n", encoding="utf-8")
    j = journey.Journey(GENERATOR_DIR, _base())
    j.goto("desktop")
    assert j.slug == "desktop"
    for cmd in LIVE[opt]["tui"]:
        j.feed(cmd.format(pw=pw))
        assert not j.status or not j.status.startswith(("not ", "unrec", "Fix")), j.status
    assert not ds.errors(j.cfg, passwords=ds.parse_passwords(j.cfg.extra_local_passes)), \
        ds.errors(j.cfg)
    return _flat(j.cfg.to_cli_args())


def _merge(d: dict, extra: dict) -> dict:
    out = json.loads(json.dumps(d))
    for k, v in extra.items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k].update(v)
        else:
            out[k] = v
    return out


def cli_argv(opt: str, tmp_path) -> str:
    path = tmp_path / "cfg.json"
    path.write_text(json.dumps(_merge(_base().to_dict(), LIVE[opt]["cli"])), encoding="utf-8")
    cfg = ImageConfig.load(str(path))
    assert not ds.errors(cfg), ds.errors(cfg)
    return _flat(cfg.to_cli_args())


MENU_HARNESS = textwrap.dedent(r'''
    set -u
    export SNAP_MENU_STATE="$1" NO_TUI=1; Q="$2"; LOG="$3"; TARGET="$4"; TAG="$5"
    source scripts/build-menu.sh
    _next() { local a; a="$(head -n 1 "${Q}")"; sed -i 1d "${Q}"; printf '%s' "${a}"; }
    ui_menu() {
        local t="$1" tags=""; shift 2
        while [ "$#" -ge 2 ]; do tags+=" $1"; shift 2; done
        printf 'MENU %s ::%s\n' "${t}" "${tags}" >> "${LOG}"
        _next
    }
    ui_checklist() { _next; }
    ui_input() { _next; }
    ui_password() { _next; }
    ui_password_confirmed() { _next; }
    ui_yesno() { local a; a="$(_next)"; [ "${a}" = yes ]; }
    ui_msg() { printf 'MSG %s: %s\n' "$1" "$2" >> "${LOG}"; }
    # never start a build from a test, whatever a mutated screen does
    launch_build() { echo "LAUNCH ${RUN_MAKE[*]}" >> "${LOG}"; return 0; }
    monitor_build() { :; }
    eval "$(declare -f _desk | sed '1s/^_desk /_desk_real /')"
    _desk() { if [ "$2" = pretend ]; then echo "PRETEND $*" >> "${LOG}"; else _desk_real "$@"; fi; }
    OPT_SA_GPU=all-free OPT_SA_STEAM=native OPT_SA_USER=snap SA_LOCAL_PASS=login-pw OPT_EXTRA_FLAGS=""
    case "${TAG}" in
        ROWS) _desk "${TARGET}" rows; exit 0 ;;
        SCREEN) "${TARGET}"; exit 0 ;;
    esac
    _desk_edit "${TARGET}" "${TAG}" "the option"
    echo "SAID=${DESK_SAID}" >> "${LOG}"
    build_make_cmd "${TARGET}" t 1
    echo "BLOCK=${DESKTOP_BLOCK}" >> "${LOG}"
    printf '%s\n' "${RUN_MAKE[@]}"
    [ -n "${LOGIN_PASS_DIR}" ] && rm -rf -- "${LOGIN_PASS_DIR}"
    exit 0
''')


def run_menu(tmp_path, target: str, tag: str, answers: list[str]) -> tuple[str, str]:
    state = tmp_path / "menu-state"
    state.mkdir(exist_ok=True)
    q = tmp_path / "answers"
    q.write_text("".join(a + "\n" for a in answers), encoding="utf-8")
    log = tmp_path / "menu.log"
    log.write_text("", encoding="utf-8")
    script = tmp_path / "harness.sh"
    script.write_text(MENU_HARNESS, encoding="utf-8")
    p = subprocess.run(["bash", str(script), str(state), str(q), str(log), target, tag],
                       cwd=GENERATOR_DIR, capture_output=True, text=True, timeout=120)
    assert p.returncode == 0, p.stderr
    return p.stdout, log.read_text(encoding="utf-8")


def menu_argv(opt: str, tmp_path) -> str:
    tag, answers = LIVE[opt]["menu"]
    out, log = run_menu(tmp_path, "x86-standalone-thin", tag, answers)
    assert "BLOCK=\n" in log, log
    flags = [x for x in out.splitlines() if x.startswith("STANDALONE_FLAGS=")]
    assert len(flags) == 1, out
    return flags[0].replace("'", "")


# ── GUI ───────────────────────────────────────────────────────────────────────────

def _gui():
    os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding (PySide6/PyQt6) installed")
    from hugmesh_studio.gui import wizard as wizard_mod
    from hugmesh_studio.gui.qt import QtCore, QtWidgets
    return wizard_mod, QtCore, QtWidgets


@pytest.fixture
def gui_page(monkeypatch):
    wizard_mod, _QtCore, QtWidgets = _gui()
    from hugmesh_studio.core.platform_info import HostInfo
    from _helpers import advance_to, pick_mode, pick_role
    host = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                    has_kvm=False, is_root=False, builder_image="hugmesh-builder")
    monkeypatch.setattr(wizard_mod, "detect", lambda builder_image="hugmesh-builder": host)
    for name in ("information", "warning", "critical", "question", "about"):
        monkeypatch.setattr(QtWidgets.QMessageBox, name, staticmethod(
            lambda *a, **k: (_ for _ in ()).throw(AssertionError("a modal dialog opened"))))
    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication(["t"])
    assert app is not None
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.show()

    def open_(role="standalone-thin"):
        pick_mode(w, "standalone")
        pick_role(w, role)
        return w, advance_to(w, wizard_mod.DesktopPage)
    yield open_
    w.close()
    w.deleteLater()


def _gui_set(opt: str, wiz, page) -> None:
    _w, QtCore, _QtWidgets = _gui()
    if opt == "environment":
        page.env.setCurrentIndex(page.env.findData("plasma"))
    elif opt == "steam":
        page.steam.setCurrentText("flatpak")
    elif opt in ds.SESSION_OPTION_IDS:
        cb = page.session_checks[opt]
        assert cb.isEnabled()
        cb.setChecked(True)
    elif opt == "default_session":
        page.default_session.setCurrentIndex(page.default_session.findData("openbox"))
    elif opt == "gpu_driver":
        # the Hardware step owns it; the Desktop step links there
        assert page.gpu_link.isVisibleTo(page)
        hw = wiz.page(wiz._page_ids["hardware"])
        idx = hw.gpu.findText("nvidia-free")
        assert idx >= 0
        hw.gpu.setCurrentIndex(idx)
        wiz.cfg.gpu_driver = hw.gpu.currentText()   # what HardwarePage.validatePage stores
    elif opt == "video_cards":
        page.cards_override.setChecked(True)
        page.card_checks["intel"].setChecked(True)
        page.card_checks["virgl"].setChecked(True)
    elif opt == "primary_account":
        # the Home step owns it; the Desktop step shows it and links there
        assert "Login account" in page.primary_state.text()
        home = wiz.page(wiz._page_ids["home"])
        home.local_user.setText("alice")
        home.local_pass.setText("login-pw")
        home.local_pass_confirm.setText("login-pw")
        home.local_admin.setChecked(True)
        wiz.cfg.local_user = home.local_user.text()
        wiz.cfg.local_pass = home.local_pass.text()
        wiz.cfg.local_admin = home.local_admin.isChecked()
    elif opt == "extra_users":
        page._add_user_row("ann", False, "first-pw")
    elif opt in ("apps_native", "apps_flatpak"):
        how = "native" if opt == "apps_native" else "flatpak"
        for r in range(page.apps_table.rowCount()):
            if page.apps_table.item(r, 0).data(QtCore.Qt.ItemDataRole.UserRole)[0] == "gimp":
                combo = page.apps_table.cellWidget(r, 1)
                combo.setCurrentIndex(combo.findData(how))
    elif opt == "flatpak_remotes":
        assert page.remotes.isEnabled()
        page.remotes.setText(REMOTE)
    elif opt == "python":
        page.py_checks["python3_13"].setChecked(True)
        page.py_single.setCurrentIndex(page.py_single.findData("python3_13"))
    elif opt == "overlay":
        page.use_lines.setPlainText("media-gfx/gimp lua")
    else:
        raise AssertionError(f"no GUI setter for {opt}")


def gui_argv(opt: str, gui_page) -> str:
    wiz, page = gui_page()
    _gui_set(opt, wiz, page)
    assert page.validatePage(), page.problems.text()
    return _flat(wiz.cfg.to_cli_args())


# ── live options: set through each face, read the builder argv ─────────────────────

@pytest.mark.parametrize("face", FACES)
@pytest.mark.parametrize("opt", sorted(LIVE))
def test_a_live_option_reaches_the_builder_from_every_face(opt, face, tmp_path, request):
    if face == "gui":
        got = gui_argv(opt, request.getfixturevalue("gui_page"))
    else:
        got = {"tui": tui_argv, "cli": cli_argv, "menu": menu_argv}[face](opt, tmp_path)
    want = LIVE[opt].get(f"want_{face}", LIVE[opt]["want"])
    for frag in want:
        assert frag in got, f"{face} dropped {opt}: {frag!r} not in {got}"


# ── information rows and the actions ──────────────────────────────────────────────

def _cli_options_json() -> str:
    import io
    buf = io.StringIO()
    assert desktop_cli.options(as_json=True, out=buf) == 0
    return buf.getvalue()


def _menu_rows(tmp_path, target: str) -> dict[str, list[str]]:
    out, _log = run_menu(tmp_path, target, "ROWS", [])
    return {ln.split("\t")[0]: ln.split("\t") for ln in out.splitlines() if "\t" in ln}


@pytest.mark.parametrize("face", FACES)
def test_the_information_rows_show_on_every_face(face, tmp_path, request):
    assert ds.option_state(_base(), "login_manager")[0] == "info"
    assert ds.option_state(_base(), "openbox")[0] == "info"
    if face == "tui":
        j = journey.Journey(GENERATOR_DIR, _base())
        j.goto("desktop")
        text = "\n".join(j.lines())
        assert ds.LOGIN_MANAGER_NOTE in text and "openbox (on)" in text
    elif face == "cli":
        data = json.loads(_cli_options_json())
        ids = {o["id"]: o for o in data["options"]}
        assert data["login_manager"] == ds.LOGIN_MANAGER_NOTE
        assert ids["openbox"]["images"]["x86-standalone-thin"]["state"] == "info"
        assert ids["login_manager"]["images"]["orangepi4-lts"]["state"] == "info"
    elif face == "menu":
        rows = _menu_rows(tmp_path, "x86-standalone-thin")
        assert rows["login_manager"][1] == "info" and rows["login_manager"][3] == ds.LOGIN_MANAGER_NOTE
        assert rows["openbox"][1] == "info"
    else:
        _wiz, page = request.getfixturevalue("gui_page")()
        assert page.session_checks["openbox"].isChecked()
        assert not page.session_checks["openbox"].isEnabled()
        assert "Sign-in on this image" in page.sso_state.text()


@pytest.mark.parametrize("face", FACES)
def test_the_pretend_check_is_offered_on_every_face_on_x86(face, tmp_path, request):
    assert ds.option_state(_base(), "pretend", face)[0] == "live"
    if face == "tui":
        assert any(c == "p" for c, _w in COMMANDS) and any(c.startswith("a / u") for c, _w in COMMANDS)
    elif face == "cli":
        assert "--desktop-pretend" in desktop_cli.CONFIG_KEYS["pretend"]
        assert "--apply-portage-fixes" in desktop_cli.CONFIG_KEYS["pretend"]
    elif face == "menu":
        # the real handler, with the builder run replaced by a recorder
        _out, log = run_menu(tmp_path, "x86-standalone-thin", "pretend", ["check"])
        assert "PRETEND x86-standalone-thin pretend --generator-dir" in log, log
        _out, log = run_menu(tmp_path, "x86-standalone-thin", "pretend", ["apply"])
        assert "--apply" in log, log
    else:
        _wiz, page = request.getfixturevalue("gui_page")()
        assert page.pretend_btn.text().startswith("Check with emerge --pretend")


@pytest.mark.parametrize("face", FACES)
def test_the_assistant_is_greyed_with_its_reason_outside_the_window(face, tmp_path):
    cfg = _base()
    if face == "gui":
        assert ds.option_state(cfg, "assistant", "gui")[0] == "live"
        # the GUI's caller of the portage card is the Local AI dock
        with open(os.path.join(STUDIO_ROOT, "hugmesh_studio", "gui", "_local_ai_dock.py"),
                  encoding="utf-8") as fh:
            assert "pretend_block" in fh.read()
        return
    assert ds.option_state(cfg, "assistant", face) == ("grey", ds.ASSISTANT_GUI_ONLY)
    if face == "tui":
        j = journey.Journey(GENERATOR_DIR, _base())
        j.goto("desktop")
        assert ds.ASSISTANT_GUI_ONLY in "\n".join(j.lines())
    elif face == "cli":
        table = {o["id"]: o for o in json.loads(_cli_options_json())["options"]}
        assert table["assistant"]["images"]["x86-standalone-thin"] == {
            "state": "grey", "text": ds.ASSISTANT_GUI_ONLY}
    else:
        row = _menu_rows(tmp_path, "x86-standalone-thin")["assistant"]
        assert row[1] == "grey" and row[3] == ds.ASSISTANT_GUI_ONLY


# ── greyed options: the same reason on every face ─────────────────────────────────

_ARM_GREYED = ("environment", "steam", *ds.SESSION_OPTION_IDS, "gpu_driver", "video_cards", "pretend")
#: (make target, Studio role, platform, the options greyed there)
GREYED = (
    ("orangepi4-lts", "orangepi4-lts", "orangepi4-lts", _ARM_GREYED),
    ("frite", "frite", "frite", _ARM_GREYED),
    ("orangepi5", "orangepi5", "orangepi5", _ARM_GREYED),
    ("x86-standalone-thick", "standalone-thick", "x86", ("environment",)),
)


@pytest.mark.parametrize("face", FACES)
@pytest.mark.parametrize("target,role,platform,greyed", GREYED, ids=[g[0] for g in GREYED])
def test_a_greyed_option_says_the_same_reason_on_every_face(target, role, platform, greyed,
                                                            face, tmp_path, request):
    cfg = _base(platform, role)
    reasons = {o: ds.option_state(cfg, o, face)[1] for o in greyed}
    assert all(ds.option_state(cfg, o, face)[0] == "grey" and why for o, why in reasons.items())
    if face == "tui":
        j = journey.Journey(GENERATOR_DIR, _base(platform, role))
        j.goto("desktop")
        shown = "\n".join(j.lines())
        for o, why in reasons.items():
            assert why in shown, f"tui hides why {o} is not on {target}"
        # and refuses to set it, saying why
        if platform != "x86":
            j.feed("gpu nvidia")
            assert j.status == reasons["gpu_driver"]
            assert j.cfg.gpu_driver in ("", "auto")
    elif face == "cli":
        table = {o["id"]: o for o in json.loads(_cli_options_json())["options"]}
        for o, why in reasons.items():
            assert table[o]["images"][target] == {"state": "grey", "text": why}, o
    elif face == "menu":
        rows = _menu_rows(tmp_path, target)
        for o, why in reasons.items():
            tag = "sessions" if o in ds.SESSION_OPTION_IDS else o
            assert rows[tag][1] == "grey" and rows[tag][3] == why, (o, rows[tag])
        # a greyed row cannot be set, whatever is typed
        if platform != "x86":
            st = tmp_path / "menu-state" / "desktop" / f"{target}.json"
            assert dm.main([target, str(st), "set", "sessions", "i3"]) == 2
            assert not st.exists()
    else:
        _wiz, page = request.getfixturevalue("gui_page")(role)
        shown = page.greyed.text()
        for o, why in reasons.items():
            assert why in shown, f"gui hides why {o} is not on {target}"


def test_the_menu_falls_back_with_a_reason_without_python(tmp_path):
    """No python3 (or no importable model): the Desktop item says why, and a saved
    Desktop choice blocks the build rather than being silently dropped."""
    bash = shutil.which("bash")
    script = tmp_path / "nopy.sh"
    script.write_text(textwrap.dedent(r'''
        set -u
        export SNAP_MENU_STATE="$1" NO_TUI=1
        source scripts/build-menu.sh
        mkdir -p "${DESK_STATE_DIR}"; echo '{}' > "$(_desk_state x86-laptop)"
        PATH=/nonexistent
        desktop_label x86-laptop; echo
        _desktop_compose x86-laptop; echo "BLOCK=${DESKTOP_BLOCK}"
    '''), encoding="utf-8")
    p = subprocess.run([bash, str(script), str(tmp_path / "st")], cwd=GENERATOR_DIR,
                       capture_output=True, text=True, timeout=60)
    assert "unavailable: python3" in p.stdout, p.stdout + p.stderr
    assert "BLOCK=Desktop options are saved for x86-laptop, but python3 is required" in p.stdout


@pytest.mark.parametrize("target", ["x86-standalone-thick", "x86-standalone-unaffiliated",
                                    "x86-laptop", "x86-chromebook", "x86-desktop",
                                    "rpi-desktop", "jetson-desktop", "frite", "orangepi5",
                                    "orangepi4-lts"])
def test_the_menu_carries_the_options_on_every_desktop_target(target, tmp_path):
    """Every make target the Desktop options open on hands them to its builder (the x86
    targets through the x86 flag string, the ARM ones through _arm_standalone_flags)."""
    _out, log = run_menu(tmp_path, target, "python", ["extra", "python3_13"])
    assert "SAID=\n" in log, log
    out, log = run_menu(tmp_path, target, "overlay", ["use", "media-gfx/gimp lua"])
    assert "BLOCK=\n" in log, log
    flags = [x.replace("'", "") for x in out.splitlines() if x.startswith("STANDALONE_FLAGS=")]
    assert len(flags) == 1, out
    assert "--python-extra-targets python3_13" in flags[0]
    assert "--package-use media-gfx/gimp lua" in flags[0]
    assert flags[0].count("--package-use") == 1


#: (screen function, canned answers up to the stop before building) per desktop target
SCREENS = {
    "x86-standalone-thin": ("single_role_screen", ["x86", "standalone-thin", "back"]),
    "x86-laptop": ("single_role_screen", ["x86", "laptop", "back"]),
    "x86-chromebook": ("single_role_screen", ["x86", "chromebook", "back"]),
    "x86-desktop": ("single_role_screen", ["x86", "desktop", "back"]),
    "rpi-desktop": ("single_role_screen", ["rpi", "desktop", "rpi5", "pass", "pw", "done", "back"]),
    "jetson-desktop": ("single_role_screen", ["jetson", "desktop", "orin-nano", "mainline",
                                              "pass", "pw", "done", "back"]),
    "orangepi5": ("single_role_screen", ["orangepi5", "desktop", "orange-pi-5-plus", "both",
                                         "pass", "pw", "done", "back"]),
    "orangepi4-lts": ("single_role_screen", ["orangepi4-lts", "desktop", "both", "pass", "pw",
                                             "done", "back"]),
    "frite": ("frite_screen", ["la-frite", "both", "light", "pass", "pw", "done", "back"]),
}


@pytest.mark.parametrize("target", sorted(SCREENS))
def test_every_menu_path_to_a_desktop_reaches_the_desktop_options(target, tmp_path):
    """Walk the real menu screens (canned answers) to the point before the build: the
    Desktop options item must be on offer there."""
    fn, answers = SCREENS[target]
    _out, log = run_menu(tmp_path, fn, "SCREEN", answers)
    menus = [ln.split("::", 1)[1].split() for ln in log.splitlines() if ln.startswith("MENU ")]
    assert "LAUNCH" not in log, log
    assert menus and {"desktop", "build"} <= set(menus[-1]), menus
