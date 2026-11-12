"""core/desktop_spec.py — the Desktop step's model, rules and emission (Qt-free).

The builder half is scripts/_desktop-config-lib.sh (tests/scripts/test-desktop-config-lib.sh);
here the Studio half is pinned AGAINST it where the two must agree: the session map, the
--gpu-driver card matrix, the card tokens, the overlay grammar (run through the real bash
functions) and the flags each desktop builder parses.
"""
from __future__ import annotations

import os
import re
import subprocess

import pytest

from hugmesh_studio.core import desktop_spec as ds
from hugmesh_studio.core.config import BUILDER_SCRIPTS, ImageConfig
from hugmesh_studio.core.worklist import WorklistConfig, WorklistEntry, synthesize

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GEN = os.path.dirname(STUDIO_ROOT)
LIB = os.path.join(GEN, "scripts", "_desktop-config-lib.sh")
X86 = os.path.join(GEN, "build-x86-host-stage4.sh")


def _laptop(**kw) -> ImageConfig:
    return ImageConfig(**{"mode": "standalone", "role": "chromebook", "platform": "x86", **kw})


def _with(cfg, **spec) -> ImageConfig:
    ds.store(cfg, ds.DesktopSpec(**spec))
    return cfg


def _bash(snippet: str) -> subprocess.CompletedProcess:
    return subprocess.run(["bash", "-c", f'. "{LIB}"; {snippet}'], capture_output=True, text=True)


# ── drift against the builder ────────────────────────────────────────────────────────

def test_the_session_catalog_is_the_builders_map():
    out = _bash("dc_session_map").stdout.split("\n")
    rows = [line.split() for line in out if line.strip()]
    assert [(s.name, s.atom, s.session or "-", s.kind) for s in ds.SESSION_CATALOG] == \
        [tuple(r) for r in rows]


def test_the_card_tokens_are_the_builders():
    out = _bash('printf "%s" "${DC_VIDEO_CARD_TOKENS}"').stdout.split()
    assert tuple(out) == ds.VIDEO_CARD_TOKENS


def test_the_gpu_matrix_is_the_builders():
    src = open(X86, encoding="utf-8").read()
    body = re.search(r"^gpu_video_cards\(\) \{.*?^\}", src, re.M | re.S).group(0)
    pairs = dict(re.findall(r"^\s+([a-z-]+)\)\s+echo \"([^\"]*)\"", body, re.M))
    assert {k: v for k, v in ds.X86_GPU_VIDEO_CARDS.items() if k != "none"} == pairs


def test_the_arm_fixed_cards_are_each_boards_make_conf():
    for plat, cards in ds.ARM_FIXED_VIDEO_CARDS.items():
        tmpl = os.path.join(GEN, f"specs-{plat}", "portage", "make.conf.tmpl")
        text = open(tmpl, encoding="utf-8").read()
        assert re.search(rf'^VIDEO_CARDS="{re.escape(cards)}"', text, re.M), plat


@pytest.mark.parametrize("line,ok", [
    (">=media-video/ffmpeg-7.1.5 opus x264", True),
    ("media-libs/mesa vulkan -llvm", True),
    ("=dev-qt/qtbase-6.9.1-r2:6 icu", True),
    ("x11-libs/libdrm:0 video_cards_radeon", False),
    ("*/* -X", False),
    ("media-video/ffmpeg-7.1.5 opus", False),          # a version needs an operator
    ("dev-lang/python python_targets_python3_12", False),
    ("media-libs/mesa VIDEO_CARDS: intel", False),
    ("media-libs/mesa", False),
])
def test_the_use_line_grammar_matches_the_builder(line, ok):
    assert (ds.check_use_line(line) == "") is ok
    assert (_bash(f"dc_check_use_line {line!r}").returncode == 0) is ok


@pytest.mark.parametrize("line,ok", [
    ("=media-video/obs-studio-32.2.2 ~amd64", True),
    ("gui-wm/labwc", True),
    ("gui-wm/labwc **", False),
    ("gui-wm/labwc ~arm64", False),
    ("gui-wm/* ~amd64", False),
])
def test_the_keyword_line_grammar_matches_the_builder(line, ok):
    assert (ds.check_keyword_line(line, "amd64") == "") is ok
    assert (_bash(f"dc_check_keyword_line {line!r} amd64").returncode == 0) is ok


def test_every_flag_cli_args_can_emit_is_parsed_by_that_builder():
    full = dict(sessions=["i3", "sway"], default_session="i3", video_cards=["intel"],
                extra_users=[ds.ExtraUser("ann", True)],
                apps=[ds.DesktopApp("firefox", "Firefox", "flatpak", flatpak="org.mozilla.firefox")],
                flatpak_remotes={"mine": "https://example.org/x.flatpakrepo"},
                python_extra_targets=["python3_13"], python_single_target="python3_13",
                use_lines=["media-libs/mesa vulkan"], keyword_lines=["gui-wm/labwc ~amd64"])
    roles = {"x86": "laptop", "rpi5": "rpi5-desktop", "jetson": "jetson-desktop",
             "frite": "frite", "orangepi5": "orangepi5", "orangepi4-lts": "orangepi4-lts"}
    for plat, role in roles.items():
        spec = dict(full)
        if plat != "x86":
            spec["keyword_lines"] = ["gui-wm/labwc ~arm64"]
            spec["default_session"] = "openbox"
        cfg = _with(ImageConfig(mode="cloud", role=role, platform=plat), **spec)
        flags = {a for a in ds.cli_args(cfg) if a.startswith("--")}
        src = open(os.path.join(GEN, BUILDER_SCRIPTS[plat]), encoding="utf-8").read()
        parser = re.search(r"^while \[\[ \$# -gt 0 \]\].*?^done", src, re.M | re.S).group(0)
        for f in flags:
            assert re.search(rf"^\s+{re.escape(f)}\)", parser, re.M), (plat, f)
        if plat != "x86":
            assert "--desktop-sessions" not in flags and "--video-cards" not in flags


# ── which images ─────────────────────────────────────────────────────────────────────

def test_applies_follows_the_image_class():
    assert ds.applies(_laptop())
    assert ds.applies(ImageConfig(mode="mesh", role="rpi5-desktop", platform="rpi5"))
    assert not ds.applies(ImageConfig(mode="mesh", role="backend", platform="x86"))
    assert not ds.applies(ImageConfig(mode="cloud", role="frite", platform="frite", desktop="none"))
    assert not ds.applies(ImageConfig(mode="cloud", role="orangepizero2", platform="orangepizero2"))


def test_a_stale_spec_on_a_node_emits_nothing():
    cfg = _with(ImageConfig(mode="mesh", role="backend", platform="x86"),
                sessions=["i3"], apps=[ds.DesktopApp("vim", "vim", "native", atom="app-editors/vim")])
    assert ds.cli_args(cfg) == [] and ds.effective_packages_add(cfg) == ""
    assert "--packages-add" not in cfg.to_cli_args()


# ── emission ─────────────────────────────────────────────────────────────────────────

def test_an_empty_spec_is_byte_identical():
    cfg = _laptop()
    before = (cfg.to_cli_args(), cfg.to_dict())
    ds.store(cfg, ds.DesktopSpec())
    assert (cfg.to_cli_args(), cfg.to_dict()) == before
    assert "desktop_spec" not in cfg.to_dict() and "extra_local_passes" not in cfg.to_dict()


def test_native_apps_fold_into_the_one_packages_add():
    cfg = _with(_laptop(packages_add="app-editors/vim"),
                apps=[ds.DesktopApp("obs", "OBS", "native", atom="media-video/obs-studio"),
                      ds.DesktopApp("vim", "vim", "native", atom="app-editors/vim")])
    a = cfg.to_cli_args()
    assert a.count("--packages-add") == 1
    assert a[a.index("--packages-add") + 1] == "app-editors/vim media-video/obs-studio"
    assert cfg.packages_add == "app-editors/vim"                     # never rewritten


def test_history_and_last_pretend_never_reach_the_builder():
    cfg = _with(_laptop(), history=[{"op": "add"}], last_pretend={"status": "clean"})
    assert ds.cli_args(cfg) == []
    assert "desktop_spec" in cfg.to_dict()                            # but they are saved


def test_the_spec_round_trips_through_a_saved_config(tmp_path):
    cfg = _with(_laptop(), sessions=["i3"], use_lines=["media-libs/mesa vulkan"],
                extra_users=[ds.ExtraUser("ann", True)],
                apps=[ds.DesktopApp("firefox", "Firefox", "flatpak", flatpak="org.mozilla.firefox")])
    cfg.extra_local_passes = "ann:secret-pw\n"
    path = str(tmp_path / "c.json")
    cfg.save(path)
    assert "secret-pw" not in open(path, encoding="utf-8").read()
    back = ImageConfig.load(path)
    assert ds.spec_of(back) == ds.spec_of(cfg)
    assert back.extra_local_passes == ""
    assert back.to_cli_args() == cfg.to_cli_args()


def test_a_hand_edited_junk_spec_loads_as_absent():
    assert ImageConfig.from_dict({"desktop_spec": "nonsense"}).desktop_spec == {}
    assert ImageConfig.from_dict({"desktop_spec": {"sessions": ["i3"], "bogus": 1}}).desktop_spec \
        == {"sessions": ["i3"]}


def test_to_cli_args_refuses_a_value_outside_the_grammar():
    cfg = _with(_laptop(), use_lines=["*/* -X"])
    with pytest.raises(ValueError, match="desktop step"):
        cfg.to_cli_args()


# ── the environment view ─────────────────────────────────────────────────────────────

def test_set_environment_emits_the_smallest_change():
    cfg = ImageConfig(mode="cloud", role="laptop", platform="x86")
    ds.set_environment(cfg, "xfce")
    assert (cfg.desktop, cfg.capable) == ("full", False)
    ds.set_environment(cfg, "lxde")
    assert (cfg.desktop, cfg.capable) == ("", False)                  # the role's default
    ds.set_environment(cfg, "plasma")
    assert cfg.capable is True and ds.environment(cfg) == "plasma"
    with pytest.raises(ValueError):
        ds.set_environment(ImageConfig(mode="standalone", role="standalone-thin", platform="x86"), "xfce")


# ── rules ────────────────────────────────────────────────────────────────────────────

def _errs(cfg, **kw):
    return " | ".join(ds.errors(cfg, **kw))


def test_rules():
    assert "kwin" in _errs(_with(_laptop(capable=True), sessions=["picom"]))
    assert _errs(_with(_laptop(capable=True), sessions=["i3", "picom"])) == ""
    assert "xfwm4" in " ".join(p.text for p in ds.problems(_with(_laptop(desktop="full"), sessions=["picom"])))
    assert "Mesa video driver" in _errs(_with(_laptop(gpu_driver="none"), sessions=["sway"]))
    assert "nvidia-drivers[wayland]" in _errs(_with(_laptop(gpu_driver="nvidia"), sessions=["sway"],
                                                    video_cards=["nouveau", "nvidia"]))
    assert "not installed" in _errs(_with(_laptop(), default_session="sway"))
    assert _errs(_with(_laptop(), sessions=["sway"], default_session="sway")) == ""
    assert "NVIDIA proprietary card needs" in _errs(_with(_laptop(), video_cards=["nvidia"]))
    assert "x86-only" in _errs(_with(ImageConfig(mode="cloud", role="orangepi5", platform="orangepi5"),
                                     sessions=["i3"]))
    assert "first-login password for ann" in _errs(_with(_laptop(), extra_users=[ds.ExtraUser("ann")]),
                                                   passwords={})
    assert "root, the primary account" in _errs(_with(_laptop(local_user="bob"),
                                                      extra_users=[ds.ExtraUser("bob")]))
    assert "no URL" in _errs(_with(_laptop(), apps=[ds.DesktopApp("x", "X", "flatpak",
                                                                  flatpak="org.x.Y", remote="mine")]))


def test_a_governed_mesh_desktop_keeps_only_the_discover_remote():
    app = ds.DesktopApp("firefox", "Firefox", "flatpak", flatpak="org.mozilla.firefox")
    mesh = _with(ImageConfig(mode="mesh", role="laptop", platform="x86"), apps=[app])
    assert mesh.sso_enabled() and "hugmesh-discover" in _errs(mesh)
    standalone = _with(_laptop(), apps=[app])
    assert _errs(standalone) == ""
    ok = _with(ImageConfig(mode="mesh", role="laptop", platform="x86"),
               apps=[ds.DesktopApp("x", "X", "flatpak", flatpak="org.x.Y", remote=ds.GOVERNED_REMOTE)],
               flatpak_remotes={ds.GOVERNED_REMOTE: "https://discover.example/repo.flatpakrepo"})
    assert _errs(ok) == ""


def test_effective_video_cards_closes_radeonsi_like_the_builder():
    cfg = _with(_laptop(), video_cards=["radeonsi", "virgl"])
    assert ds.effective_video_cards(cfg) == "radeonsi radeon amdgpu virgl"
    got = _bash('DC_VIDEO_CARDS="radeonsi virgl"; dc_effective_video_cards x').stdout.strip()
    assert got == ds.effective_video_cards(cfg)


# ── overlay edits + history ──────────────────────────────────────────────────────────

def test_apply_and_undo_record_an_append_only_history():
    cfg = _laptop()
    ch = [ds.OverlayChange("package.use", ">=media-video/ffmpeg-7.1.5  opus x264"),
          ds.OverlayChange("accept_keywords", "=media-video/obs-studio-32.2.2 ~amd64"),
          ds.OverlayChange("mask", "=x/y-1"),
          ds.OverlayChange("package.use", "*/* -X")]
    applied = ds.apply_changes(cfg, ch, source="autounmask", pretend_run="r1")
    assert [c.kind for c in applied] == ["package.use", "accept_keywords"]
    spec = ds.spec_of(cfg)
    assert spec.use_lines == [">=media-video/ffmpeg-7.1.5 opus x264"]
    assert ds.apply_changes(cfg, ch[:1], source="assistant") == []          # already there
    ds.undo_changes(cfg, applied, source="autounmask")
    spec = ds.spec_of(cfg)
    assert spec.use_lines == [] and spec.keyword_lines == []
    assert [(h["op"], h["source"]) for h in spec.history] == [
        ("add", "autounmask"), ("add", "autounmask"), ("undo", "autounmask"), ("undo", "autounmask")]
    with pytest.raises(ValueError):
        ds.apply_changes(cfg, ch, source="somebody")


def test_overlay_diff_shows_only_the_new_lines():
    spec = ds.DesktopSpec(use_lines=["media-libs/mesa vulkan"])
    diff = ds.overlay_diff(spec, [ds.OverlayChange("package.use", "media-libs/mesa vulkan"),
                                  ds.OverlayChange("package.use", "media-video/ffmpeg opus")])
    assert diff == ["--- a/etc/portage/package.use/zz-hugmesh-studio",
                    "+++ b/etc/portage/package.use/zz-hugmesh-studio",
                    " media-libs/mesa vulkan", "+media-video/ffmpeg opus"]


# ── per build: the mesh worklist ─────────────────────────────────────────────────────

def test_each_mesh_row_carries_its_own_spec_and_saves_it_omit_when_empty(tmp_path):
    base = ImageConfig(mode="mesh")
    a = WorklistEntry(role="laptop", platform="x86",
                      desktop_spec={"sessions": ["i3"]})
    b = WorklistEntry(role="desktop", platform="x86")
    node = WorklistEntry(role="backend", platform="x86", desktop_spec={"sessions": ["i3"]})
    wl = WorklistConfig(base=base, entries=[a, b, node])
    got = {e.id: c for e, c in wl.materialize()}
    assert "--desktop-sessions" in got[a.id].to_cli_args()
    assert "--desktop-sessions" not in got[b.id].to_cli_args()
    assert "--desktop-sessions" not in got[node.id].to_cli_args()          # a node never
    assert "desktop_spec" not in b.to_dict() and a.to_dict()["desktop_spec"] == {"sessions": ["i3"]}
    path = str(tmp_path / "wl.json")
    wl.save(path)
    from hugmesh_studio.core.worklist import load_any
    _, back = load_any(path)
    assert back.entries[0].desktop_spec == {"sessions": ["i3"]}


def test_a_single_image_build_keeps_its_spec_through_synthesize():
    cfg = _with(_laptop(), sessions=["i3"])
    (_, out), = synthesize(cfg).materialize()
    assert ds.cli_args(out) == ds.cli_args(cfg) == ["--desktop-sessions", "i3"]


def test_step_applies_in_mesh_follows_the_rows():
    cfg = ImageConfig(mode="mesh")
    wl = WorklistConfig(base=cfg, entries=[WorklistEntry(role="backend", platform="x86")])
    assert not ds.step_applies(cfg, wl)
    wl.entries.append(WorklistEntry(role="frite", platform="frite", desktop="none"))
    assert not ds.step_applies(cfg, wl)
    wl.entries.append(WorklistEntry(role="orangepi4-lts", platform="orangepi4-lts"))
    assert ds.step_applies(cfg, wl)


def test_passwords_file_text():
    spec = ds.DesktopSpec(extra_users=[ds.ExtraUser("ann"), ds.ExtraUser("bob")])
    assert ds.extra_pass_file_text(spec, {"ann": "a:1", "bob": ""}) == "ann:a:1\n"
    assert ds.parse_passwords("ann:a:1\n") == {"ann": "a:1"}
    with pytest.raises(ValueError):
        ds.extra_pass_file_text(spec, {"ann": "two\nlines"})


def test_account_lines_name_the_login_account_and_the_role_owner():
    cfg = _laptop(local_user="ann", local_admin=False)
    assert ds.account_lines(cfg)[0] == "Login account: ann — not an administrator (Home step)."
    cloud = ImageConfig(mode="cloud", role="laptop", platform="x86", person_role="mod")
    assert "Person role: mod (System step)." in ds.account_lines(cloud)
    e = WorklistEntry(role="laptop", platform="x86", desktop_user="bob",
                      desktop_user_roles=["admin", "games"])
    lines = ds.account_lines(ImageConfig(mode="mesh"), e)
    assert "Mesh person on this desktop: bob — roles admin, games (Worklist step)." in lines


def test_a_governed_desktop_refuses_an_extra_local_administrator():
    """sudo on a governed (SSO + KEYS) mesh desktop flows only through the revocable
    desktop-sudo claim; 02-extra-local-users.start grants nothing there either. It keys
    on keys-provision's OWN marker (keys-users.created), never users.created, which
    01-firstboot touches for its local account in the same boot (that withheld wheel
    from every standalone and --local-pass image). The per-shape EFFECT (real 01, then
    02, on one root) is tests/scripts/test-desktop-config-lib.sh section 4b."""
    mesh = _with(ImageConfig(mode="mesh", role="laptop", platform="x86"),
                 extra_users=[ds.ExtraUser("ann", True)])
    assert "desktop-sudo" in _errs(mesh)
    assert _errs(_with(ImageConfig(mode="mesh", role="laptop", platform="x86"),
                       extra_users=[ds.ExtraUser("ann", False)])) == ""
    assert _errs(_with(_laptop(), extra_users=[ds.ExtraUser("ann", True)])) == ""
    script = open(os.path.join(GEN, "scripts", "desktop-config", "02-extra-local-users.start"),
                  encoding="utf-8").read()
    assert "[ -d /etc/hugmesh/desktop-governance ]" in script
    assert "/var/lib/keys-provision/keys-users.created" in script
    assert "users.created ]" not in script.replace("keys-users.created", "")
    prov = open(os.path.join(GEN, "specs", "etc", "keys-provision", "provision.sh"),
                encoding="utf-8").read()
    assert 'KEYS_USERS_MARKER="${STATE_DIR}/keys-users.created"' in prov


# ── catalog deliveries that do not exist for the image's arch ──────────────────────────
# Structural facts, measured 2026-11-12 (gentoo tree 2026-11-10, flathub.org/api/v2/summary):
# thunderbird-bin and libreoffice-bin carry no arm64 keyword at all (a binary Mozilla /
# TDF ship for amd64 only, so no accept_keywords line can reach them), and Flathub builds
# Thunderbird, Blender and OBS Studio for x86_64 only. Keyword STABILITY is not encoded
# (it drifts; the ARM boards accept ~arm64 and x86 has the emerge --pretend check).

def _rpi5(**spec) -> ImageConfig:
    return _with(ImageConfig(mode="cloud", role="rpi5-desktop", platform="rpi5"), **spec)


def test_an_arch_limit_names_a_real_arch_and_says_why():
    arches = set(ds.PLATFORM_ARCH.values())
    for a in ds.app_catalog():
        for how, key in (("native", "atom"), ("flatpak", "flatpak")):
            lim = a.get(f"{how}_arches")
            if lim is None:
                continue
            assert a.get(key), f"{a['id']}: an arch limit on a delivery it does not offer"
            assert lim and set(lim) <= arches, (a["id"], how, lim)
            assert a.get(f"{how}_why"), f"{a['id']}: {how}_arches without its reason"


def test_a_delivery_that_does_not_exist_on_arm_is_refused_with_its_reason():
    tb_native = ds.catalog_app("thunderbird", "native")
    tb_flat = ds.catalog_app("thunderbird", "flatpak")
    lo_native = ds.catalog_app("libreoffice", "native")
    lo_flat = ds.catalog_app("libreoffice", "flatpak")
    blender_flat = ds.catalog_app("blender", "flatpak")
    obs_flat = ds.catalog_app("obs-studio", "flatpak")
    obs_native = ds.catalog_app("obs-studio", "native")
    for app in (tb_native, tb_flat, lo_native, blender_flat, obs_flat):
        why = ds.delivery_block(_rpi5(), app)
        assert why, app
        assert why in _errs(_rpi5(apps=[app]))
        assert ds.delivery_block(_laptop(), app) == ""
        assert _errs(_with(_laptop(), apps=[app])) == ""
    for app in (lo_flat, obs_native, ds.catalog_app("firefox", "native")):
        # (a cloud rpi5 desktop is governed: its flathub refusal is a different rule)
        assert ds.delivery_block(_rpi5(), app) == ""
        assert "is not available on" not in _errs(_rpi5(apps=[app]))
    # the same package typed as a free entry is refused the same way
    free = ds.DesktopApp("mail-client/thunderbird-bin", "mail-client/thunderbird-bin",
                         "native", atom="mail-client/thunderbird-bin")
    assert "amd64" in _errs(_rpi5(apps=[free]))
    free_flat = ds.DesktopApp("org.blender.Blender", "org.blender.Blender", "flatpak",
                              flatpak="org.blender.Blender")
    assert "x86_64" in _errs(_rpi5(apps=[free_flat]))


def test_catalog_blocks_lists_every_delivery_this_image_cannot_take():
    by_id = {a["id"]: a for a in ds.app_catalog()}
    assert set(ds.catalog_blocks(_rpi5(), by_id["thunderbird"])) == {"native", "flatpak"}
    assert set(ds.catalog_blocks(_rpi5(), by_id["libreoffice"])) == {"native"}
    assert set(ds.catalog_blocks(_rpi5(), by_id["blender"])) == {"flatpak"}
    assert ds.catalog_blocks(_rpi5(), by_id["firefox"]) == {}
    assert all(ds.catalog_blocks(_laptop(), a) == {} for a in ds.app_catalog())
