"""The TUI Desktop step — DesktopScreen, the twin of gui/pages/desktop.py (Qt-free).

Same model and rules (core/desktop_spec.py), same pretend run and parser
(core/desktop_pretend.py). Pins: the step is on the standalone walk between system and
build and off a node-only mesh walk; every command edits the spec through the shared
grammar (a refusal is an inline status, state unchanged); the extra account's password
is read from a FILE and never saved; ``p`` runs the gated check and ``a`` applies
portage's own suggestion into the history as "autounmask"; Enter refuses while an error
stands.
"""
import os

from hugmesh_studio.core import desktop_pretend as dp
from hugmesh_studio.core import desktop_spec as ds
from hugmesh_studio.core.config import ImageConfig
from hugmesh_studio.core.platform_info import HostInfo
from hugmesh_studio.tui import journey
from hugmesh_studio.tui.desktop_step import DesktopScreen

HOST = HostInfo(os="linux", is_gentoo=False, has_docker=True, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")
NEEDS = ["==> Pretend result: status=needs rc=1 seed_python=python3_13 video_cards=intel",
         "==> Pretend needs: package.use >=media-video/ffmpeg-7.1.5 opus x264",
         "==> Pretend needs: accept_keywords =media-video/obs-studio-32.2.2 ~amd64"]


def _to_desktop() -> journey.Journey:
    j = journey.Journey(".")
    j.feed("")                    # -> mode (standalone default)
    for _ in range(20):
        if j.slug == "desktop":
            return j
        j.feed("")
    raise AssertionError(f"never reached desktop (stuck on {j.slug})")


def test_the_standalone_walk_visits_the_step_before_build():
    j = _to_desktop()
    assert "Environment, login" in "\n".join(j.lines())
    j.feed("")
    assert j.slug == "build"


def test_a_node_only_mesh_walk_skips_it():
    from hugmesh_studio.core.worklist import WorklistConfig, WorklistEntry
    cfg = ImageConfig(mode="mesh")
    j = journey.Journey(".", cfg)
    j.worklist = WorklistConfig(base=cfg, entries=[WorklistEntry(role="backend", platform="x86")])
    j.goto("home")
    j.advance()
    assert j.slug == "build"
    j.worklist.entries.append(WorklistEntry(role="laptop", platform="x86"))
    j.goto("home")
    j.advance()
    assert j.slug == "desktop"


def test_commands_edit_the_spec(tmp_path):
    j = _to_desktop()
    j.cfg.role = "chromebook"
    pw = tmp_path / "pw"
    pw.write_text("first-pw\n", encoding="utf-8")
    for cmd in ("env xfce", "steam flatpak", "s +i3 +picom", "default i3", "cards intel virgl",
                f"user add ann pass={pw}", "app firefox native", "app obs-studio native",
                "py +python3_13", "py single python3_13", "use media-libs/mesa vulkan",
                "kw gui-wm/labwc ~amd64"):
        j.feed(cmd)
        assert j.slug == "desktop" and not j.status.startswith(("not ", "unrec")), (cmd, j.status)
    spec = ds.spec_of(j.cfg)
    assert spec.sessions == ["i3", "picom"] and spec.default_session == "i3"
    assert spec.video_cards == ["intel", "virgl"]
    assert spec.extra_users == [ds.ExtraUser("ann", False)]
    assert [a.atom for a in spec.apps] == ["www-client/firefox-bin", "media-video/obs-studio"]
    assert (j.cfg.desktop, j.cfg.steam) == ("full", "flatpak")
    assert ds.parse_passwords(j.cfg.extra_local_passes) == {"ann": "first-pw"}
    assert "first-pw" not in str(j.cfg.to_dict())
    a = j.cfg.to_cli_args()
    assert a[a.index("--extra-local-users") + 1] == "ann"
    j.feed("")
    assert j.slug == "build"


def test_a_refusal_is_inline_and_changes_nothing():
    j = _to_desktop()
    before = dict(j.cfg.desktop_spec)
    j.feed("use */* -X")
    assert "not a plain package atom" in j.status and j.cfg.desktop_spec == before
    j.feed("s +hyprland")
    assert "unknown session" in j.status and j.cfg.desktop_spec == before


def test_enter_refuses_while_an_error_stands():
    j = _to_desktop()
    j.cfg.role = "chromebook"
    j.feed("user add ann pass=/nonexistent/file")
    assert j.status.startswith("not done")
    ds.store(j.cfg, ds.DesktopSpec(extra_users=[ds.ExtraUser("ann")]))   # no password typed
    j.feed("")
    assert j.slug == "desktop" and "first-login password" in j.status


class _FakeDriver:
    host = HOST

    def command(self, cfg, backend=None):
        return ["fake", *cfg.to_cli_args()]

    def _stream(self, argv, on_line, backend):
        for ln in NEEDS:
            on_line(ln)
        return 3


def test_p_then_a_applies_portages_own_suggestion(tmp_path, monkeypatch):
    monkeypatch.setattr(dp, "gate", lambda *a, **k: "")      # a quiet machine
    j = _to_desktop()
    screen = j.screen()
    assert isinstance(screen, DesktopScreen)
    msg = screen.run_pretend(j, driver=_FakeDriver(), out_dir=str(tmp_path))
    assert msg == "emerge --pretend: needs"
    text = "\n".join(j.lines())
    assert "needs: package.use >=media-video/ffmpeg-7.1.5 opus x264" in text
    assert "+>=media-video/ffmpeg-7.1.5 opus x264" in text
    j.feed("a")
    spec = ds.spec_of(j.cfg)
    assert spec.use_lines == [">=media-video/ffmpeg-7.1.5 opus x264"]
    assert {h["source"] for h in spec.history} == {"autounmask"}
    j.feed("u")
    assert ds.spec_of(j.cfg).use_lines == []


def test_p_waits_its_turn(monkeypatch):
    j = _to_desktop()
    monkeypatch.setattr(dp, "gate", lambda *a, **k: "Another build or emulated device is running")
    j.feed("p")
    assert "Another build" in j.status


def test_the_screen_lists_the_shared_catalogs():
    j = _to_desktop()
    text = "\n".join(j.lines())
    for s in ds.SESSION_CATALOG:
        assert s.name in text
    for a in ds.app_catalog():
        assert a["id"] in text
    assert ds.LOGIN_MANAGER_NOTE in text
    assert os.path.basename(__file__)


def test_an_arm_board_refuses_a_delivery_that_does_not_exist_there():
    j = _to_desktop()
    j.cfg.mode, j.cfg.role, j.cfg.platform = "cloud", "rpi5-desktop", "rpi5"
    before = dict(j.cfg.desktop_spec)
    j.feed("app thunderbird native")
    assert "amd64" in j.status and j.cfg.desktop_spec == before
    j.feed("app blender flatpak")
    assert "x86_64" in j.status and j.cfg.desktop_spec == before
    j.feed("app libreoffice flatpak")
    assert [a.flatpak for a in ds.spec_of(j.cfg).apps] == ["org.libreoffice.LibreOffice"]
    text = "\n".join(j.lines())
    assert "thunderbird" in text and "x86_64" in text


def test_an_unchecked_native_pick_is_a_note_on_the_screen_and_enter_still_advances():
    j = _to_desktop()
    j.cfg.role = "chromebook"
    j.feed("app element native")
    text = "\n".join(j.lines())
    assert "Note: Not checked against the portage tree yet: net-im/element-desktop-bin" in text
    dp.record(j.cfg, dp.PretendResult(status="clean", rc=0, run_id="t"))
    assert "Not checked against the portage tree" not in "\n".join(j.lines())
    j.feed("")
    assert j.slug == "build"
