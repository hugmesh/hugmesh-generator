"""The GPU driver presets and the optional-service list: every face's copy equals core's.

core/config.py owns both (``GPU_DRIVER_CHOICES``, ``OPTIONAL_SERVICES_CHOICES`` with
``BUILTIN_DEFAULT_SERVICES``). The GUI and the TUI import them. The ``make menu`` screen
(scripts/build-menu.sh) is shell and cannot, so it spells both out by hand, and nothing
compared those copies with core. These tests do, by SET equality (the order a menu lists
things in is the menu's own), so a preset or a service added in one place and not the
other fails here instead of shipping a menu that cannot pick it or offers one the builder
refuses. They also parse the builder's own accepted set, and walk the GUI and TUI sources
for a hand-written copy of either list.

There is no web copy of either list in this repository. Tests that read the builders and
the menu: test_desktop_spec.py (the cards matrix), test_services_section.py
(USER_LEVEL_SERVICES, the built-in defaults) and test_desktop_option_parity.py (the
Desktop options the menu drives).
"""
from __future__ import annotations

import ast
import json
import os
import re
from types import SimpleNamespace

from hugmesh_studio.core import desktop_spec as ds
from hugmesh_studio.core.config import (
    BUILTIN_DEFAULT_SERVICES, GPU_DRIVER_ALIASES, GPU_DRIVER_CHOICES, INFRA_SERVICES_CHOICES,
    OPTIONAL_SERVICES_BY_PLATFORM, OPTIONAL_SERVICES_CHOICES, USER_LEVEL_SERVICES)

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
PACKAGE = os.path.join(STUDIO_ROOT, "hugmesh_studio")

#: the presets as the builder takes them: core's tuple without the Studio-only "auto"
BUILDER_GPU = set(GPU_DRIVER_CHOICES) - {"auto"}
#: what the standalone screen leaves out, and why: "auto" is the Studio's don't-emit
#: value, and "none" (no GPU driver) is the headless setting of a node, not of the desktop
#: image this screen builds
MENU_GPU_OMITS = {"auto", "none"}


def _read(*parts: str) -> str:
    with open(os.path.join(GENERATOR_DIR, *parts), encoding="utf-8") as fh:
        return fh.read()


def _menu() -> str:
    return _read("scripts", "build-menu.sh")


def _between(text: str, start: str, end: str) -> str:
    i = text.index(start)
    return text[i:text.index(end, i)]


# ── the GPU driver presets ──────────────────────────────────────────────────────────────
def test_core_gpu_presets_are_the_builders_accepted_set():
    src = _read("build-x86-host-stage4.sh")
    case = re.search(r"^\s*((?:[a-z]+(?:-[a-z]+)?\|)+none)\) ;;\s*$", src, re.M)
    assert case, "build-x86-host-stage4.sh no longer validates --gpu-driver with a case arm"
    assert set(case.group(1).split("|")) == BUILDER_GPU
    said = re.search(r"--gpu-driver must be: ([a-z| -]+) \(got", src)
    assert said and {t.strip() for t in said.group(1).split("|")} == BUILDER_GPU


def test_core_gpu_tuple_and_the_card_table_agree():
    assert set(ds.X86_GPU_VIDEO_CARDS) == BUILDER_GPU
    for alias, canonical in GPU_DRIVER_ALIASES.items():
        assert canonical in BUILDER_GPU, alias


def test_the_menu_offers_the_presets_core_has():
    menu = _menu()
    block = _between(menu, 'gpu)     OPT_SA_GPU="$(ui_menu "GPU driver"', ";;")
    offered = set(re.findall(r'^\s+([a-z]+(?:-[a-z]+)?) "', block, re.M))
    assert offered == set(GPU_DRIVER_CHOICES) - MENU_GPU_OMITS
    listed = re.search(r'^OPT_SA_GPU="[a-z-]+"\s+# ([a-z|-]+)\s*$', menu, re.M)
    assert listed and set(listed.group(1).split("|")) == offered, (
        "the menu's own OPT_SA_GPU comment no longer lists what its screen offers")


def test_the_menus_default_driver_is_the_one_core_resolves():
    default = re.search(r'^OPT_SA_GPU="([a-z-]+)"', _menu(), re.M).group(1)
    core_default = ds.gpu_driver_effective(
        SimpleNamespace(gpu_driver="auto", role="standalone-thick"))
    assert default == core_default and default in GPU_DRIVER_CHOICES


def test_the_tui_gpu_help_names_only_real_presets():
    from hugmesh_studio.tui.desktop_step import COMMANDS
    (help_text,) = [d for c, d in COMMANDS if c == "gpu PRESET"]
    named = set(re.findall(r"\b(?:all-free|nvidia-free|nvidia|amd-free|amd-pro|intel-free"
                           r"|intel-pro|none)\b", help_text))
    assert named and named <= BUILDER_GPU


def test_hardware_profiles_name_only_drivers_the_studio_takes():
    with open(os.path.join(GENERATOR_DIR, "specs-x86", "hwprofiles", "profiles.json"),
              encoding="utf-8") as fh:
        data = json.load(fh)
    profiles = data["profiles"] if isinstance(data, dict) else data
    assert len(profiles) > 10
    known = set(GPU_DRIVER_CHOICES) | set(GPU_DRIVER_ALIASES)
    bad = {p["id"]: p["gpu_driver"] for p in profiles
           if p.get("gpu_driver") and p["gpu_driver"] not in known}
    assert not bad, f"hardware profiles name a GPU driver the Studio does not offer: {bad}"


# ── the optional services ───────────────────────────────────────────────────────────────
def test_the_menus_service_checklist_is_the_user_level_set():
    slugs = re.search(r"^SERVICE_SLUGS=\(([^)]*)\)", _menu(), re.M).group(1).split()
    assert len(slugs) == len(set(slugs))
    assert set(slugs) == set(OPTIONAL_SERVICES_CHOICES) == set(USER_LEVEL_SERVICES)


def test_the_menu_describes_every_checklist_row_and_no_other():
    menu = _menu()
    slugs = set(re.search(r"^SERVICE_SLUGS=\(([^)]*)\)", menu, re.M).group(1).split())
    body = _between(menu, "local -A desc=(", "\n    )")
    assert set(re.findall(r"^\s+\[([a-z-]+)\]=", body, re.M)) == slugs


def test_the_menus_defaults_are_the_builders_defaults():
    menu = _menu()
    screen = _between(menu, "services_screen() {", "\n}\n")
    untouched = re.search(r'cur="([a-z,-]+)"', screen).group(1)
    assert set(untouched.split(",")) == set(BUILTIN_DEFAULT_SERVICES)
    shown = re.search(r"<default: ([a-z,-]+)>", menu).group(1)
    assert set(shown.split(",")) == set(BUILTIN_DEFAULT_SERVICES)
    prose = re.search(r"\(defaults: ([a-z+-]+) ON; ([a-z/-]+) OFF\)", screen)
    assert prose, "the checklist prompt no longer states its defaults in one sentence"
    assert set(prose.group(1).split("+")) == set(BUILTIN_DEFAULT_SERVICES)
    assert set(prose.group(2).split("/")) == set(USER_LEVEL_SERVICES) - set(BUILTIN_DEFAULT_SERVICES)
    comment = re.search(r"Comma list of user-level slugs \{(.*?)\}", menu, re.S)
    assert comment, "the OPT_SERVICES comment no longer lists the user-level slugs"
    assert set(re.findall(r"[a-z]+(?:-[a-z]+)*", comment.group(1).replace("#", " "))) == set(
        OPTIONAL_SERVICES_CHOICES)


def test_every_service_the_studio_offers_on_x86_is_one_the_builder_accepts():
    src = _read("build-x86-host-stage4.sh")
    selectable = set(re.search(r'^SELECTABLE_OPTIONAL_SERVICES="([^"]*)"', src, re.M)
                     .group(1).split())
    offered = set(OPTIONAL_SERVICES_BY_PLATFORM["x86"])
    assert offered == set(OPTIONAL_SERVICES_CHOICES) | set(INFRA_SERVICES_CHOICES)
    assert offered <= selectable, (
        f"offered on x86 but not selectable in the builder: {sorted(offered - selectable)}")


# ── no hand-written copy in the GUI or the TUI ──────────────────────────────────────────
_COPIES = {"GPU driver presets": set(GPU_DRIVER_CHOICES),
           "optional services": set(OPTIONAL_SERVICES_CHOICES) | set(INFRA_SERVICES_CHOICES)}


def _list_literal_copies(source: str):
    """(line, what, matched members) for every list/tuple/set literal of strings that
    carries three or more members of one of the two lists. (A dict is not a list: the
    network page's slug -> flag table is a mapping, not a copy.)"""
    found = []
    for node in ast.walk(ast.parse(source)):
        if not isinstance(node, (ast.Tuple, ast.List, ast.Set)):
            continue
        members = {e.value for e in node.elts
                   if isinstance(e, ast.Constant) and isinstance(e.value, str)}
        for what, reference in _COPIES.items():
            hit = members & reference
            if len(hit) >= 3:
                found.append((node.lineno, what, sorted(hit)))
    return found


def _front_end_sources():
    for sub in ("gui", "tui"):
        for root, _dirs, files in os.walk(os.path.join(PACKAGE, sub)):
            for name in files:
                if name.endswith(".py"):
                    path = os.path.join(root, name)
                    with open(path, encoding="utf-8") as fh:
                        yield os.path.relpath(path, PACKAGE), fh.read()


def test_no_gui_or_tui_source_lists_the_presets_or_the_services_itself():
    sources = list(_front_end_sources())
    assert len(sources) > 20, "the walk found no front-end files"
    offenders = [(rel, *hit) for rel, text in sources for hit in _list_literal_copies(text)]
    assert not offenders, (
        "a front end spells out a list core owns (import GPU_DRIVER_CHOICES / "
        f"OPTIONAL_SERVICES_CHOICES instead): {offenders}")


def test_the_scan_catches_a_planted_copy_and_leaves_a_mapping_alone():
    gpu = '_P = ("all-free", "nvidia-free", "nvidia", "none")\n'
    svc = 'S = ["akkoma", "tuwunel", "phpbb"]\n'
    assert [h[1] for h in _list_literal_copies(gpu)] == ["GPU driver presets"]
    assert [h[1] for h in _list_literal_copies(svc)] == ["optional services"]
    assert _list_literal_copies('_M = {"tor": 1, "games": 2, "akkoma": 3, "tube": 4}\n') == []
    assert _list_literal_copies('_T = ("akkoma", "tuwunel")\n') == []     # two is a pair
