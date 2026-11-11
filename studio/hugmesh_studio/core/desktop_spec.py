"""The Desktop step's data model — Qt-free, shared by the GUI page, the text UI and the CLI.

Operator ask (2026-11-11): "allow for a step to configure each desktop, login, window
managers on board, compositers, per build being made, users, roles, installed apps and if
they're native or flatpak, video drivers, and the ai assistant will help it run emerge
pretend and resolve any build flag or package useflag issues. It can also configure python."

ONE step ("desktop", after "home", before "build") holds, per build that produces a
desktop:

* the desktop ENVIRONMENT — a view over the fields that already existed (``cfg.desktop``
  thin/full and ``cfg.capable``); nothing new is stored for it;
* the LOGIN manager — lightdm + lightdm-gtk-greeter, fixed and said why (the SSO PAM stack
  in scripts/_desktop-sso-lib.sh exists for lightdm only, and a desktop must allow local
  AND SSO login); the SSO state is shown, owned by the Network step;
* extra window managers / compositors (``sessions``) and the greeter's ``default_session``;
* VIDEO drivers — the ``cfg.gpu_driver`` preset plus an optional VIDEO_CARDS override;
* extra local ACCOUNTS (not administrators unless ticked — operator rule) — the primary
  account stays on the Home step;
* APPS, each delivered Native (an emerge atom, folded into --packages-add) or Flatpak;
* PYTHON targets (only ever WIDEN the seed's set);
* a portage OVERLAY (package.use / package.accept_keywords lines) with an append-only
  history of where each line came from — portage's own suggestion from a pretend run
  ("autounmask"), the local AI assistant ("assistant") or the operator ("operator").

Storage: ``ImageConfig.desktop_spec`` (a plain dict, OMITTED from the saved JSON while
empty, so every existing config keeps its bytes) — and, in mesh mode, per worklist row
(``WorklistEntry.desktop_spec``), stamped onto that image's config by materialize().
Emission: :func:`cli_args` (the builders' Desktop-step flags, scripts/_desktop-config-lib.sh)
and :func:`effective_packages_add` (native apps folded into the ONE --packages-add the
builders read last-wins). Both emit NOTHING unless the image really produces a desktop, so
a stale spec on a node config can never reach a builder that would refuse the flags.

The extra accounts' passwords are SECRETS: typed at build time into
``ImageConfig.extra_local_passes`` (SECRET_FIELDS — never saved), staged to a 0600 file
at dispatch and handed to the builder as ``--extra-local-pass-file``. The argv a preview
shows carries :data:`EXTRA_PASS_PLACEHOLDER` instead of a path.
"""
from __future__ import annotations

import json
import os
import re
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from typing import Any, Iterable

# ── platform facts ────────────────────────────────────────────────────────────

#: The builders that can produce a desktop and parse the Desktop-step flags.
DESKTOP_PLATFORMS = ("x86", "rpi5", "jetson", "frite", "orangepi5", "orangepi4-lts")

#: The testing keyword an accept_keywords line may name, per platform.
PLATFORM_ARCH = {"x86": "amd64", "rpi5": "arm64", "jetson": "arm64", "frite": "arm64",
                 "orangepi5": "arm64", "orangepi4-lts": "arm64"}

#: ARM boards: VIDEO_CARDS is fixed by the SoC (each board's make.conf.tmpl literal).
ARM_FIXED_VIDEO_CARDS = {
    "rpi5": "v3d vc4", "jetson": "tegra", "frite": "lima",
    "orangepi5": "panfrost", "orangepi4-lts": "panfrost",
}

#: build-x86-host-stage4.sh gpu_video_cards() — the --gpu-driver preset matrix.
#: tests/test_desktop_spec.py reads the builder's function and compares.
X86_GPU_VIDEO_CARDS = {
    "all-free": "amdgpu radeonsi radeon intel iris nouveau",
    "nvidia-free": "nouveau",
    "nvidia": "nouveau nvidia",
    "amd-free": "amdgpu radeonsi radeon",
    "amd-pro": "amdgpu radeonsi radeon",
    "intel-free": "intel iris",
    "intel-pro": "intel iris",
    "none": "",
}

#: The tokens a --video-cards override may name (scripts/_desktop-config-lib.sh
#: DC_VIDEO_CARD_TOKENS). "virtio" is not a Mesa token: VM virtio-gpu is "virgl".
VIDEO_CARD_TOKENS = ("intel", "i915", "amdgpu", "radeonsi", "radeon", "nouveau", "nvidia",
                     "virgl", "vmware", "lavapipe", "zink")
VIDEO_CARD_LABELS = {
    "intel": "Intel (iris/crocus)", "i915": "Intel legacy (i915)", "amdgpu": "AMD (amdgpu)",
    "radeonsi": "AMD GCN+ (radeonsi)", "radeon": "AMD legacy (radeon)",
    "nouveau": "NVIDIA open (nouveau)", "nvidia": "NVIDIA proprietary",
    "virgl": "VM virtio-gpu (virgl)", "vmware": "VMware SVGA",
    "lavapipe": "Software Vulkan (lavapipe)", "zink": "OpenGL on Vulkan (zink)",
}


@dataclass(frozen=True)
class Session:
    name: str           # --desktop-sessions token
    atom: str           # what the builder folds into --packages-add
    session: str        # the greeter session name ("" for a compositor)
    kind: str           # x11 | wayland | compositor
    label: str


#: scripts/_desktop-config-lib.sh dc_session_map — the builder owns the table; this is
#: its mirror (tests/test_desktop_spec.py diffs the two).
SESSION_CATALOG: tuple[Session, ...] = (
    Session("openbox", "x11-wm/openbox", "openbox", "x11", "Openbox (X11 window manager; always on board)"),
    Session("i3", "x11-wm/i3", "i3", "x11", "i3 (X11 tiling window manager)"),
    Session("picom", "x11-misc/picom", "", "compositor", "picom (X11 compositor)"),
    Session("sway", "gui-wm/sway", "sway", "wayland", "Sway (Wayland tiling compositor)"),
    Session("wayfire", "gui-wm/wayfire", "wayfire", "wayland", "Wayfire (Wayland 3D compositor)"),
    Session("labwc", "gui-wm/labwc", "labwc", "wayland", "labwc (Wayland stacking compositor)"),
)
SESSIONS = {s.name: s for s in SESSION_CATALOG}
#: openbox is a mandatory x86 client atom (build-x86 SNAP_MANDATORY_ATOMS): always there.
ALWAYS_ON_SESSIONS = ("openbox",)

#: Desktop environments: id -> (label, greeter session name).
ENVIRONMENTS = {
    "lxde": ("LXDE (light: openbox + lxpanel + pcmanfm)", "LXDE"),
    "xfce": ("XFCE (full)", "xfce"),
    "plasma": ("KDE Plasma (most capable; X11 session)", "plasmax11"),
}

PYTHON_TARGET_CHOICES = ("python3_12", "python3_13", "python3_14", "python3_15")
FLATHUB_URL = "https://dl.flathub.org/repo/flathub.flatpakrepo"
#: The only remote a GOVERNED mesh desktop keeps: provisioning deletes flathub and every
#: default remote (specs/etc/keys-provision/provision.sh, flathub-disable.conf).
GOVERNED_REMOTE = "hugmesh-discover"

#: What the argv preview shows for the extra accounts' password file: the real path
#: exists only for one dispatch (core/build_driver.py swaps it in).
EXTRA_PASS_PLACEHOLDER = "<extra-local-passwords: typed at build time>"

LOGIN_MANAGER_NOTE = (
    "Login manager: LightDM with the GTK greeter, on every desktop image. It is the only "
    "greeter the SSO sign-in (PAM device flow) is built for, and every desktop must offer "
    "BOTH a local account login and SSO sign-in (standalone, tailnet and mesh). SDDM, GDM "
    "and greetd are not offered: swapping the greeter needs that PAM stack ported first.")

HISTORY_SOURCES = ("autounmask", "assistant", "operator")

# ── the model ─────────────────────────────────────────────────────────────────


@dataclass
class DesktopApp:
    id: str                     # catalog id, or the atom / app id for a free entry
    label: str
    delivery: str = "native"    # native | flatpak
    atom: str = ""              # native: category/name
    flatpak: str = ""           # flatpak: reverse-DNS app id
    remote: str = "flathub"     # flatpak: remote name

    def token(self) -> str:
        return self.atom if self.delivery == "native" else f"{self.remote}:{self.flatpak}"


@dataclass
class ExtraUser:
    name: str
    admin: bool = False


@dataclass
class DesktopSpec:
    sessions: list[str] = field(default_factory=list)
    default_session: str = ""
    video_cards: list[str] = field(default_factory=list)
    extra_users: list[ExtraUser] = field(default_factory=list)
    apps: list[DesktopApp] = field(default_factory=list)
    flatpak_remotes: dict[str, str] = field(default_factory=dict)
    python_extra_targets: list[str] = field(default_factory=list)
    python_single_target: str = ""
    use_lines: list[str] = field(default_factory=list)
    keyword_lines: list[str] = field(default_factory=list)
    history: list[dict] = field(default_factory=list)
    last_pretend: dict = field(default_factory=dict)

    # ---- (de)serialization: omit-when-empty ------------------------------
    def to_dict(self) -> dict[str, Any]:
        d = asdict(self)
        return {k: v for k, v in d.items() if v not in ("", [], {}, None)}

    @classmethod
    def from_dict(cls, d: Any) -> "DesktopSpec":
        if not isinstance(d, dict):
            return cls()

        def _strs(v: Any) -> list[str]:
            return [str(x) for x in v] if isinstance(v, (list, tuple)) else []

        users = [ExtraUser(name=str(u.get("name", "")), admin=bool(u.get("admin", False)))
                 for u in d.get("extra_users") or [] if isinstance(u, dict)]
        app_f = set(DesktopApp.__dataclass_fields__)
        apps = [DesktopApp(**{k: str(v) for k, v in a.items() if k in app_f})
                for a in d.get("apps") or [] if isinstance(a, dict) and a.get("id")]
        rem = d.get("flatpak_remotes")
        return cls(
            sessions=_strs(d.get("sessions")),
            default_session=str(d.get("default_session") or ""),
            video_cards=_strs(d.get("video_cards")),
            extra_users=users, apps=apps,
            flatpak_remotes={str(k): str(v) for k, v in rem.items()} if isinstance(rem, dict) else {},
            python_extra_targets=_strs(d.get("python_extra_targets")),
            python_single_target=str(d.get("python_single_target") or ""),
            use_lines=_strs(d.get("use_lines")),
            keyword_lines=_strs(d.get("keyword_lines")),
            history=[h for h in d.get("history") or [] if isinstance(h, dict)],
            last_pretend=d.get("last_pretend") if isinstance(d.get("last_pretend"), dict) else {},
        )

    def is_empty(self) -> bool:
        return not self.to_dict()

    def emits(self) -> bool:
        """True when anything here would reach the builder (history/last_pretend never do)."""
        d = self.to_dict()
        d.pop("history", None)
        d.pop("last_pretend", None)
        return bool(d)


def spec_of(cfg) -> DesktopSpec:
    return DesktopSpec.from_dict(getattr(cfg, "desktop_spec", None) or {})


def store(cfg, spec: DesktopSpec) -> None:
    cfg.desktop_spec = spec.to_dict()


# ── catalog ───────────────────────────────────────────────────────────────────

_CATALOG_PATH = os.path.join(os.path.dirname(__file__), "desktop_apps.json")


def app_catalog() -> list[dict]:
    with open(_CATALOG_PATH, encoding="utf-8") as fh:
        return list(json.load(fh)["apps"])


def catalog_app(app_id: str, delivery: str = "native") -> DesktopApp | None:
    for a in app_catalog():
        if a["id"] == app_id:
            if delivery == "flatpak" and not a.get("flatpak"):
                return None
            if delivery == "native" and not a.get("atom"):
                return None
            return DesktopApp(id=a["id"], label=a["label"], delivery=delivery,
                              atom=a.get("atom", "") if delivery == "native" else "",
                              flatpak=a.get("flatpak", "") if delivery == "flatpak" else "")
    return None


# ── which images get the step ─────────────────────────────────────────────────


def applies(cfg) -> bool:
    """True when this config's image produces a desktop (lightdm session).

    The role class is the authority (config.image_class mirrors the x86 builder's
    ROLE_CLIENT, GUARD B); frite is desktop-class but builds headless with
    ``--desktop none``, so that one value opts it out."""
    from .config import image_class
    plat = getattr(cfg, "platform", "") or "x86"
    if plat not in DESKTOP_PLATFORMS:
        return False
    if image_class(getattr(cfg, "mode", ""), getattr(cfg, "role", "")) != "desktop":
        return False
    if plat == "frite" and getattr(cfg, "desktop", "") == "none":
        return False
    return True


def is_x86(cfg) -> bool:
    return (getattr(cfg, "platform", "") or "x86") == "x86"


# ── environment: a view over cfg.desktop / cfg.capable ───────────────────────

#: x86 roles whose builder arm pins the environment (it errors on a contradiction).
_ROLE_DEFAULT_WEIGHT = {"desktop": "full", "standalone-thick": "full",
                        "standalone-unaffiliated": "full"}
_ROLE_LOCKED_ENV = {"standalone-thick": "plasma", "standalone-unaffiliated": "plasma"}
_ROLE_PINNED_WEIGHT = {"standalone-thin": "thin"}


def environment(cfg) -> str:
    if not is_x86(cfg):
        return "lxde"
    role = getattr(cfg, "role", "")
    if role in _ROLE_LOCKED_ENV or getattr(cfg, "capable", False):
        return "plasma"
    weight = getattr(cfg, "desktop", "") or _ROLE_DEFAULT_WEIGHT.get(role, "thin")
    return "xfce" if weight == "full" else "lxde"


def environment_lock(cfg) -> str:
    """Why the environment cannot change here ("" when it can)."""
    plat = getattr(cfg, "platform", "") or "x86"
    if plat != "x86":
        return (f"The {plat} desktop ships LXDE only (its builder has one desktop "
                "package set); more environments on ARM are a later step.")
    role = getattr(cfg, "role", "")
    if role in _ROLE_LOCKED_ENV:
        return f"The {role} role IS the most-capable (Plasma) payload; pick another role to change it."
    return ""


def environment_choices(cfg) -> list[str]:
    if environment_lock(cfg):
        return [environment(cfg)]
    role = getattr(cfg, "role", "")
    if role in _ROLE_PINNED_WEIGHT:            # standalone-thin: thin, or thin + capable
        return ["lxde", "plasma"]
    return list(ENVIRONMENTS)


def set_environment(cfg, env: str) -> None:
    """Write the chosen environment back onto cfg.desktop / cfg.capable, emitting the
    smallest change (the role's own default weight leaves cfg.desktop empty)."""
    if env not in environment_choices(cfg):
        raise ValueError(f"environment {env!r} is not available for this image")
    if not is_x86(cfg) or environment_lock(cfg):
        return
    role = getattr(cfg, "role", "")
    default_weight = _ROLE_DEFAULT_WEIGHT.get(role, "thin")
    if env == "plasma":
        cfg.capable = True
        return
    cfg.capable = False
    weight = "full" if env == "xfce" else "thin"
    cfg.desktop = "" if weight == default_weight else weight


def de_session(cfg) -> str:
    return ENVIRONMENTS[environment(cfg)][1]


def installed_sessions(cfg, spec: DesktopSpec) -> list[str]:
    """Every greeter session this image will carry: the environment's own, openbox, and
    each extra window manager / compositor that has a session."""
    out = [de_session(cfg), "openbox"]
    for name in spec.sessions:
        s = SESSIONS.get(name)
        if s and s.session and s.session not in out:
            out.append(s.session)
    return out


# ── video ─────────────────────────────────────────────────────────────────────


def gpu_driver_effective(cfg) -> str:
    v = getattr(cfg, "gpu_driver", "auto") or "auto"
    if v == "auto":
        return "nvidia" if getattr(cfg, "role", "") == "edge-ai" else "all-free"
    from .config import GPU_DRIVER_ALIASES
    return GPU_DRIVER_ALIASES.get(v, v)


def effective_video_cards(cfg, spec: DesktopSpec | None = None) -> str:
    """The VIDEO_CARDS the image's make.conf will carry (builder-mirrored)."""
    plat = getattr(cfg, "platform", "") or "x86"
    if plat != "x86":
        return ARM_FIXED_VIDEO_CARDS.get(plat, "")
    spec = spec or spec_of(cfg)
    if not spec.video_cards:
        return X86_GPU_VIDEO_CARDS.get(gpu_driver_effective(cfg), "")
    out: list[str] = []
    for c in spec.video_cards:
        if c not in out:
            out.append(c)
        if c == "radeonsi":
            for extra in ("radeon", "amdgpu"):
                if extra not in out:
                    out.append(extra)
    return " ".join(out)


# ── governance (Flatpak remotes) ──────────────────────────────────────────────


def governed(cfg) -> bool:
    """A KEYS-provisioned mesh desktop with SSO on: provisioning DELETES flathub and
    every default remote, so only the hugmesh-discover remote survives."""
    try:
        sso = cfg.sso_enabled()
    except Exception:  # noqa: BLE001 — a half-built test config: assume not governed
        sso = False
    return bool(sso) and getattr(cfg, "mode", "") in ("mesh", "cloud") \
        and getattr(cfg, "role", "") != "standalone-unaffiliated"


# ── overlay grammar (mirrors scripts/_desktop-config-lib.sh) ─────────────────

_ATOM_PLAIN = re.compile(
    r"^[a-z0-9][a-z0-9+._-]*/[A-Za-z0-9+_][A-Za-z0-9+_-]*(:[A-Za-z0-9+._-]+(/[A-Za-z0-9+._-]+)?)?$")
_ATOM_VER = re.compile(
    r"^(>=|<=|=|~|<|>)[a-z0-9][a-z0-9+._-]*/[A-Za-z0-9+_][A-Za-z0-9+_-]*-[0-9][0-9.]*[a-z]?"
    r"(_(alpha|beta|pre|rc|p)[0-9]*)*(-r[0-9]+)?(:[A-Za-z0-9+._-]+(/[A-Za-z0-9+._-]+)?)?$")
_USE_FLAG = re.compile(r"^-?[a-z0-9][a-z0-9+_@.-]*$")
_USERNAME = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")
_FLATPAK_ID = re.compile(r"^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+){2,}$")
_REMOTE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
_REMOTE_URL = re.compile(r"^https://[A-Za-z0-9._~:/?#@!&+,=%-]+$")
_PY_TARGET = re.compile(r"^python3_[0-9]{1,2}t?$")


def valid_atom(atom: str) -> bool:
    return bool(_ATOM_PLAIN.fullmatch(atom) or _ATOM_VER.fullmatch(atom))


def check_use_line(line: str) -> str:
    """"" when ``line`` is a legal package.use overlay line, else the reason."""
    words = line.split()
    if len(words) < 2:
        return f"package.use line {line!r}: want ATOM FLAG [FLAG...]"
    if not valid_atom(words[0]):
        return f"package.use line {line!r}: {words[0]!r} is not a plain package atom (no wildcards)"
    for flag in words[1:]:
        if not _USE_FLAG.fullmatch(flag):
            return f"package.use line {line!r}: {flag!r} is not a USE flag"
        bare = flag.lstrip("-")
        if bare.startswith("video_cards_"):
            return (f"package.use line {line!r}: video cards belong to the Video section, "
                    "never to one package")
        if bare.startswith(("python_targets_", "python_single_target_")):
            return f"package.use line {line!r}: Python targets belong to the Python section"
    return ""


def check_keyword_line(line: str, arch: str) -> str:
    words = line.split()
    if not 1 <= len(words) <= 2:
        return f"accept_keywords line {line!r}: want ATOM [~{arch}]"
    if not valid_atom(words[0]):
        return f"accept_keywords line {line!r}: {words[0]!r} is not a plain package atom (no wildcards)"
    if len(words) == 2 and words[1] != f"~{arch}":
        return (f"accept_keywords line {line!r}: only the testing keyword ~{arch} may be "
                "accepted here (no '**', no other arch)")
    return ""


def normalise_line(line: str) -> str:
    return " ".join(line.split())


# ── validation ────────────────────────────────────────────────────────────────


@dataclass(frozen=True)
class Problem:
    level: str      # error | warning
    section: str    # sessions | video | users | apps | python | portage
    text: str


def problems(cfg, spec: DesktopSpec | None = None, *, passwords: dict | None = None) -> list[Problem]:
    """Everything wrong with this spec for this image (errors block Next and the build;
    warnings are said and allowed). ``passwords`` (name -> typed password) is checked
    only when given — a loaded config carries no passwords by design."""
    spec = spec or spec_of(cfg)
    out: list[Problem] = []
    if not applies(cfg):
        if spec.emits():
            out.append(Problem("warning", "sessions",
                               "This image builds no desktop; the Desktop settings are kept but not used."))
        return out
    x86 = is_x86(cfg)
    plat = getattr(cfg, "platform", "") or "x86"
    arch = PLATFORM_ARCH.get(plat, "amd64")

    def err(section: str, text: str) -> None:
        out.append(Problem("error", section, text))

    def warn(section: str, text: str) -> None:
        out.append(Problem("warning", section, text))

    env = environment(cfg)
    # sessions
    if spec.sessions and not x86:
        err("sessions", "Extra window managers / compositors are x86-only for now; this board ships LXDE.")
    seen: set[str] = set()
    for s in spec.sessions:
        if s not in SESSIONS:
            err("sessions", f"Unknown session {s!r}.")
        elif s in seen:
            err("sessions", f"{s} is listed twice.")
        seen.add(s)
    wayland = any(SESSIONS[s].kind == "wayland" for s in spec.sessions if s in SESSIONS)
    if "picom" in spec.sessions:
        if env == "plasma" and not ({"i3", "openbox"} & set(spec.sessions)):
            err("sessions", "picom composites for an X11 window manager without its own "
                "compositor (LXDE/openbox or i3); Plasma's kwin already composites. Add i3, or drop picom.")
        elif env == "xfce":
            warn("sessions", "picom with XFCE: turn xfwm4's own compositing off in the session, "
                 "or the two compositors fight.")
    if wayland and x86:
        if gpu_driver_effective(cfg) == "nvidia":
            err("sessions", "A Wayland compositor with the proprietary NVIDIA driver needs "
                "nvidia-drivers[wayland] and kernel modesetting, which the builder does not set up "
                "yet. Use the open nouveau driver or an X11 session.")
        if not effective_video_cards(cfg, spec):
            err("sessions", "A Wayland compositor needs a Mesa video driver (pick a GPU driver "
                "other than none, or a video card).")
    # default session
    if spec.default_session and spec.default_session not in installed_sessions(cfg, spec):
        err("sessions", f"Default session {spec.default_session!r} is not installed "
            f"(installed: {', '.join(installed_sessions(cfg, spec))}).")
    # video
    if spec.video_cards:
        if not x86:
            err("video", f"VIDEO_CARDS is fixed by the {plat} SoC ({ARM_FIXED_VIDEO_CARDS.get(plat, '')}).")
        for c in spec.video_cards:
            if c not in VIDEO_CARD_TOKENS:
                err("video", f"Unknown video card {c!r}.")
        drv = gpu_driver_effective(cfg)
        if "nvidia" in spec.video_cards and drv != "nvidia":
            err("video", "The NVIDIA proprietary card needs the 'nvidia' GPU driver preset.")
        if drv == "nvidia" and "nvidia" not in spec.video_cards:
            err("video", "The 'nvidia' GPU driver preset needs the NVIDIA proprietary card in the list.")
    # users
    primary = (getattr(cfg, "local_user", "") or getattr(cfg, "user", "") or "").strip()
    names: set[str] = set()
    for u in spec.extra_users:
        if not _USERNAME.fullmatch(u.name):
            err("users", f"{u.name!r} is not a valid login name (lowercase letters, digits, _ and -).")
            continue
        if u.name in ("root", primary) or u.name in names:
            err("users", f"{u.name!r} is root, the primary account or listed twice.")
        names.add(u.name)
        if passwords is not None and not (passwords.get(u.name) or ""):
            err("users", f"Type a first-login password for {u.name} (it is never saved; "
                "the account must change it at first login).")
    # apps
    gov = governed(cfg)
    for a in spec.apps:
        if a.delivery == "native":
            if not valid_atom(a.atom) or a.atom.startswith(("<", ">", "=", "~")):
                err("apps", f"{a.label}: {a.atom!r} is not a category/name atom.")
        elif a.delivery == "flatpak":
            if not _FLATPAK_ID.fullmatch(a.flatpak):
                err("apps", f"{a.label}: {a.flatpak!r} is not a Flatpak app id (e.g. org.mozilla.firefox).")
            if not _REMOTE.fullmatch(a.remote):
                err("apps", f"{a.label}: {a.remote!r} is not a remote name.")
            elif a.remote != "flathub" and a.remote not in spec.flatpak_remotes:
                err("apps", f"{a.label}: remote {a.remote!r} has no URL (add it under Flatpak remotes).")
            if gov and a.remote != GOVERNED_REMOTE:
                err("apps", f"{a.label}: a governed mesh desktop deletes every Flatpak remote but "
                    f"{GOVERNED_REMOTE} at provisioning, so a {a.remote} app would never install. "
                    "Deliver it natively, or from hugmesh-discover.")
        else:
            err("apps", f"{a.label}: delivery must be native or flatpak.")
    for name, url in spec.flatpak_remotes.items():
        if not _REMOTE.fullmatch(name) or not _REMOTE_URL.fullmatch(url):
            err("apps", f"Flatpak remote {name}={url!r}: want a name and an https:// .flatpakrepo URL.")
    # python
    for t in spec.python_extra_targets:
        if not _PY_TARGET.fullmatch(t):
            err("python", f"{t!r} is not a python3_NN target.")
    if spec.python_single_target:
        if not re.fullmatch(r"python3_[0-9]{1,2}", spec.python_single_target):
            err("python", "The single target must be a python3_NN target (not free-threading).")
    # portage overlay
    for line in spec.use_lines:
        reason = check_use_line(line)
        if reason:
            err("portage", reason)
    for line in spec.keyword_lines:
        reason = check_keyword_line(line, arch)
        if reason:
            err("portage", reason)
    return out


def grammar_errors(cfg, spec: DesktopSpec | None = None) -> list[str]:
    """Only the values that are not WELL-FORMED (names, atoms, flags, ids, tokens) —
    what to_cli_args refuses outright, whatever the image. Combination rules (picom with
    Plasma, a governed flathub app, ...) are :func:`problems`' job."""
    spec = spec or spec_of(cfg)
    arch = PLATFORM_ARCH.get(getattr(cfg, "platform", "") or "x86", "amd64")
    out: list[str] = []
    out += [f"unknown session {s!r}" for s in spec.sessions if s not in SESSIONS]
    if spec.default_session and not re.fullmatch(r"[A-Za-z0-9_.+-]+", spec.default_session):
        out.append(f"default session {spec.default_session!r} is not a session name")
    out += [f"unknown video card {c!r}" for c in spec.video_cards if c not in VIDEO_CARD_TOKENS]
    out += [f"{u.name!r} is not a login name" for u in spec.extra_users if not _USERNAME.fullmatch(u.name)]
    for a in spec.apps:
        if a.delivery == "native" and not _ATOM_PLAIN.fullmatch(a.atom):
            out.append(f"{a.atom!r} is not a category/name atom")
        if a.delivery == "flatpak" and not (_FLATPAK_ID.fullmatch(a.flatpak) and _REMOTE.fullmatch(a.remote)):
            out.append(f"{a.remote}:{a.flatpak} is not REMOTE:app.id")
        if a.delivery not in ("native", "flatpak"):
            out.append(f"delivery {a.delivery!r} is not native or flatpak")
    for name, url in spec.flatpak_remotes.items():
        if not (_REMOTE.fullmatch(name) and _REMOTE_URL.fullmatch(url)):
            out.append(f"flatpak remote {name}={url!r} is not NAME=https://URL")
    out += [f"{t!r} is not a python3_NN target" for t in spec.python_extra_targets
            if not _PY_TARGET.fullmatch(t)]
    if spec.python_single_target and not re.fullmatch(r"python3_[0-9]{1,2}", spec.python_single_target):
        out.append(f"{spec.python_single_target!r} is not a python3_NN target")
    out += [r for r in (check_use_line(x) for x in spec.use_lines) if r]
    out += [r for r in (check_keyword_line(x, arch) for x in spec.keyword_lines) if r]
    return out


def errors(cfg, spec: DesktopSpec | None = None, **kw) -> list[str]:
    return [p.text for p in problems(cfg, spec, **kw) if p.level == "error"]


# ── emission ──────────────────────────────────────────────────────────────────


def _emitting_spec(cfg) -> DesktopSpec | None:
    if not applies(cfg):
        return None
    spec = spec_of(cfg)
    return spec if spec.emits() else None


def native_atoms(spec: DesktopSpec) -> list[str]:
    out: list[str] = []
    for a in spec.apps:
        if a.delivery == "native" and a.atom and a.atom not in out:
            out.append(a.atom)
    return out


def effective_packages_add(cfg) -> str:
    """``cfg.packages_add`` plus the Desktop step's NATIVE app atoms — emitted ONCE as
    --packages-add (every builder reads that flag last-wins). packages_add itself is never
    rewritten, so the Packages dialog keeps owning its own list."""
    base = (getattr(cfg, "packages_add", "") or "").split()
    spec = _emitting_spec(cfg)
    if spec is not None:
        for atom in native_atoms(spec):
            if atom not in base:
                base.append(atom)
    return " ".join(base)


def cli_args(cfg) -> list[str]:
    """The Desktop-step builder flags (scripts/_desktop-config-lib.sh). Empty unless the
    image produces a desktop AND the spec sets something — a stale spec on a node config
    never reaches a builder (they refuse these flags on a headless role)."""
    spec = _emitting_spec(cfg)
    if spec is None:
        return []
    x86 = is_x86(cfg)
    a: list[str] = []
    if spec.sessions and x86:
        a += ["--desktop-sessions", " ".join(spec.sessions)]
    if spec.default_session:
        a += ["--default-session", spec.default_session]
    if spec.video_cards and x86:
        a += ["--video-cards", " ".join(spec.video_cards)]
    if spec.extra_users:
        a += ["--extra-local-users",
              " ".join(u.name + (":admin" if u.admin else "") for u in spec.extra_users)]
        a += ["--extra-local-pass-file", EXTRA_PASS_PLACEHOLDER]
    flat = [x for x in spec.apps if x.delivery == "flatpak"]
    if flat:
        a += ["--flatpak-apps", " ".join(x.token() for x in flat)]
    if spec.flatpak_remotes:
        a += ["--flatpak-remotes", " ".join(f"{k}={v}" for k, v in sorted(spec.flatpak_remotes.items()))]
    if spec.python_extra_targets:
        a += ["--python-extra-targets", " ".join(spec.python_extra_targets)]
    if spec.python_single_target:
        a += ["--python-single-target", spec.python_single_target]
    if spec.use_lines:
        a += ["--package-use", ";".join(normalise_line(x) for x in spec.use_lines)]
    if spec.keyword_lines:
        a += ["--accept-keywords", ";".join(normalise_line(x) for x in spec.keyword_lines)]
    return a


def extra_pass_file_text(spec: DesktopSpec, passwords: dict) -> str:
    """The NAME:PASSWORD lines the builder hashes (--extra-local-pass-file)."""
    lines = []
    for u in spec.extra_users:
        pw = passwords.get(u.name, "")
        if pw:
            if "\n" in pw:
                raise ValueError(f"the password for {u.name} contains a line break")
            lines.append(f"{u.name}:{pw}")
    return "\n".join(lines) + ("\n" if lines else "")


def parse_passwords(text: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for line in (text or "").splitlines():
        name, sep, pw = line.partition(":")
        if sep and name:
            out[name] = pw
    return out


# ── overlay edits with an append-only history ────────────────────────────────


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


@dataclass(frozen=True)
class OverlayChange:
    kind: str       # package.use | accept_keywords
    line: str


def overlay_diff(spec: DesktopSpec, changes: Iterable[OverlayChange]) -> list[str]:
    """A unified-style diff of the two overlay files before/after ``changes``."""
    out: list[str] = []
    for kind, current, fname in (("package.use", spec.use_lines, "package.use/zz-hugmesh-studio"),
                                 ("accept_keywords", spec.keyword_lines,
                                  "package.accept_keywords/zz-hugmesh-studio")):
        add = [normalise_line(c.line) for c in changes if c.kind == kind]
        add = [x for x in add if x not in current]
        if not add:
            continue
        out.append(f"--- a/etc/portage/{fname}")
        out.append(f"+++ b/etc/portage/{fname}")
        out += [f" {x}" for x in current]
        out += [f"+{x}" for x in add]
    return out


def check_change(change: OverlayChange, cfg) -> str:
    arch = PLATFORM_ARCH.get(getattr(cfg, "platform", "") or "x86", "amd64")
    if change.kind == "package.use":
        return check_use_line(change.line)
    if change.kind == "accept_keywords":
        return check_keyword_line(change.line, arch)
    return f"{change.kind} changes are an operator decision and are never applied from here"


def apply_changes(cfg, changes: Iterable[OverlayChange], *, source: str,
                  pretend_run: str = "") -> list[OverlayChange]:
    """Append each legal, new line to the overlay and record it in the history.
    Returns the changes actually applied (Undo removes exactly those)."""
    if source not in HISTORY_SOURCES:
        raise ValueError(f"unknown source {source!r}")
    spec = spec_of(cfg)
    applied: list[OverlayChange] = []
    for ch in changes:
        if check_change(ch, cfg):
            continue
        line = normalise_line(ch.line)
        target = spec.use_lines if ch.kind == "package.use" else spec.keyword_lines
        if line in target:
            continue
        target.append(line)
        applied.append(OverlayChange(ch.kind, line))
        spec.history.append({"op": "add", "kind": ch.kind, "line": line, "source": source,
                             "pretend_run": pretend_run, "at": _now()})
    store(cfg, spec)
    return applied


def undo_changes(cfg, applied: Iterable[OverlayChange], *, source: str) -> None:
    spec = spec_of(cfg)
    for ch in applied:
        target = spec.use_lines if ch.kind == "package.use" else spec.keyword_lines
        if ch.line in target:
            target.remove(ch.line)
            spec.history.append({"op": "undo", "kind": ch.kind, "line": ch.line,
                                 "source": source, "at": _now()})
    store(cfg, spec)


def summary_lines(cfg) -> list[str]:
    """Plain-words facts for the Review page, the assistant and the text UI."""
    if not applies(cfg):
        return ["Desktop: this image builds no desktop."]
    spec = spec_of(cfg)
    env = environment(cfg)
    out = [f"Desktop environment: {ENVIRONMENTS[env][0]}",
           "Login: LightDM greeter, local account" + (" + SSO sign-in" if _sso(cfg) else
                                                      " (SSO sign-in off on this image)")]
    if spec.sessions:
        out.append("Extra sessions: " + ", ".join(spec.sessions))
    out.append("Default session: " + (spec.default_session or de_session(cfg)))
    out.append("VIDEO_CARDS: " + (effective_video_cards(cfg, spec) or "none"))
    if spec.extra_users:
        out.append("Extra accounts: " + ", ".join(
            u.name + (" (administrator)" if u.admin else "") for u in spec.extra_users))
    if spec.apps:
        out.append("Apps: " + ", ".join(f"{a.label} ({a.delivery})" for a in spec.apps))
    if spec.python_extra_targets or spec.python_single_target:
        out.append("Python: + " + " ".join(spec.python_extra_targets)
                   + (f", single {spec.python_single_target}" if spec.python_single_target else ""))
    if spec.use_lines or spec.keyword_lines:
        out.append(f"Portage overlay: {len(spec.use_lines)} package.use, "
                   f"{len(spec.keyword_lines)} accept_keywords line(s)")
    if spec.last_pretend:
        out.append(f"Last emerge --pretend: {spec.last_pretend.get('status', '?')} "
                   f"({spec.last_pretend.get('at', '')})")
    return out


def _sso(cfg) -> bool:
    try:
        return bool(cfg.sso_enabled())
    except Exception:  # noqa: BLE001
        return False
