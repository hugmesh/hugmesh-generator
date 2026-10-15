"""The anubis (public proof-of-work gate) tri-state — issue #384, core half.

ImageConfig.anubis is "" (the build's ENV policy: prod on, test off), "on" or "off".
There is no flag for it: both builders read it out of --optional-services, "on" as the
`anubis` slug and "off" as the `-anubis` token (never --exclude-services, which they
refuse for it). A force-off beside an empty picker is a list of ONLY a deselect token,
which the builders (operator decision B on #444) read as "keep the built-in defaults".

The last block runs the REAL builders on the argv Studio emits, because the argv is only
right if the builder reads it the way this file says; a green emission test beside a
builder that disagrees is the failure this repo keeps naming.

Pure core: no Qt, so it runs in the headless suite.
"""
import os
import re
import subprocess
from pathlib import Path

import pytest

from hugmesh_studio.core.config import (
    ANUBIS_CHOICES,
    BUILTIN_DEFAULT_SERVICES,
    SERVICES_ALL,
    SERVICES_NONE,
    USER_LEVEL_SERVICES,
    ImageConfig,
)

REPO = Path(__file__).resolve().parents[2]
BUILDERS = {"x86": REPO / "build-x86-host-stage4.sh", "rpi5": REPO / "build-rpi5-stage4.sh"}
DEFAULTS = " ".join(BUILTIN_DEFAULT_SERVICES)


def svc_args(**kw):
    return ImageConfig(platform=kw.pop("platform", "x86"), **kw)._services_args()


# --------------------------------------------------------------------------- emission

def test_default_emits_exactly_what_it_emitted_before_the_field_existed():
    assert svc_args() == []
    assert svc_args(optional_services=["akkoma", "games"]) == \
        ["--optional-services", "akkoma games"]
    assert svc_args(optional_services=[SERVICES_NONE]) == ["--optional-services", ""]
    assert svc_args(optional_services=[SERVICES_ALL]) == ["--all-services"]
    assert svc_args(exclude_services=["games"]) == ["--exclude-services", "games"]


def test_force_off_emits_the_deselect_token_in_optional_services():
    assert svc_args(anubis="off") == ["--optional-services", "-anubis"]
    assert svc_args(anubis="off", optional_services=["akkoma", "tuwunel"]) == \
        ["--optional-services", "akkoma tuwunel -anubis"]


def test_force_off_is_never_spelled_as_exclude_services():
    """Both builders refuse `--exclude-services anubis` (subtraction cannot beat the ENV
    default), so the knob that works must not be the knob that is refused."""
    for picker in ([], [SERVICES_NONE], [SERVICES_ALL], ["akkoma"], ["akkoma", "anubis"]):
        argv = svc_args(anubis="off", optional_services=picker)
        excl = argv[argv.index("--exclude-services") + 1].split() \
            if "--exclude-services" in argv else []
        assert "anubis" not in excl, (picker, argv)
        assert "--optional-services" in argv, (picker, argv)
        assert "-anubis" in argv[argv.index("--optional-services") + 1].split()


def test_force_on_emits_the_slug_and_keeps_the_defaults():
    # [] means "the builder default"; a bare ["anubis"] would REPLACE it.
    assert svc_args(anubis="on") == ["--optional-services", f"{DEFAULTS} anubis"]
    assert svc_args(anubis="on", optional_services=["akkoma"]) == \
        ["--optional-services", "akkoma anubis"]
    assert svc_args(anubis="on", optional_services=[SERVICES_NONE]) == \
        ["--optional-services", "anubis"]


def test_force_off_beside_explicit_none_subtracts_the_defaults_instead():
    """A lone `-anubis` gives the defaults back, so none + veto keeps the veto and
    subtracts the default slugs; the user's own exclusions survive, deduplicated."""
    assert svc_args(anubis="off", optional_services=[SERVICES_NONE]) == \
        ["--optional-services", "-anubis", "--exclude-services", DEFAULTS]
    assert svc_args(anubis="off", optional_services=[SERVICES_NONE],
                    exclude_services=["games", "akkoma"]) == \
        ["--optional-services", "-anubis", "--exclude-services", "games akkoma tuwunel phpbb"]


def test_the_all_sentinel_cannot_carry_a_positive_slug_but_can_carry_the_veto():
    """The builders' `all` expansion keeps deselect tokens and drops everything else, so
    force-off rides the sentinel and force-on spells the set out."""
    assert svc_args(anubis="off", optional_services=[SERVICES_ALL]) == \
        ["--optional-services", f"{SERVICES_ALL} -anubis"]
    argv = svc_args(anubis="on", optional_services=[SERVICES_ALL])
    assert argv[0] == "--optional-services" and "--all-services" not in argv
    assert argv[1].split() == [*USER_LEVEL_SERVICES, "anubis"]


def test_the_field_beats_a_contradicting_slug_or_token_in_the_picker():
    """The builders let a positive slug beat a deselect token, so the contradiction has
    to be resolved here or the force-off would silently lose."""
    assert svc_args(anubis="off", optional_services=["akkoma", "anubis"]) == \
        ["--optional-services", "akkoma -anubis"]
    assert svc_args(anubis="on", optional_services=["akkoma", "-anubis"]) == \
        ["--optional-services", "akkoma anubis"]
    assert svc_args(anubis="on", optional_services=["akkoma", "no-anubis"]) == \
        ["--optional-services", "akkoma anubis"]
    # an existing veto is not doubled
    assert svc_args(anubis="off", optional_services=["akkoma", "no-anubis"]) == \
        ["--optional-services", "akkoma no-anubis"]


@pytest.mark.parametrize("platform", ["x86", "rpi5"])
def test_it_reaches_the_full_argv_on_both_node_builders(platform):
    argv = ImageConfig(platform=platform, anubis="off").to_cli_args()
    assert argv[argv.index("--optional-services") + 1] == "-anubis"
    argv = ImageConfig(platform=platform, anubis="on").to_cli_args()
    assert argv[argv.index("--optional-services") + 1] == f"{DEFAULTS} anubis"


def test_a_platform_with_no_cluster_tree_emits_nothing_for_it():
    for platform in ("jetson", "frite"):
        argv = ImageConfig(platform=platform, anubis="off").to_cli_args()
        assert "-anubis" not in " ".join(argv) and "--optional-services" not in argv


# ---------------------------------------------------------------- the field itself

def test_the_choices_are_the_three_states():
    assert ANUBIS_CHOICES == ("", "on", "off")


def test_it_round_trips_through_save_and_load():
    for v in ANUBIS_CHOICES:
        assert ImageConfig.from_dict(ImageConfig(anubis=v).to_dict()).anubis == v


@pytest.mark.parametrize("raw,want", [(True, "on"), (False, ""), (None, ""),
                                      ("ON", "on"), (" off ", "off"), ("", "")])
def test_load_normalises_the_spellings_a_hand_written_config_uses(raw, want):
    assert ImageConfig.from_dict({"anubis": raw}).anubis == want


@pytest.mark.parametrize("junk", ["yes", "disabled", 3, ["off"]])
def test_load_refuses_junk_instead_of_reading_it_as_default(junk):
    """A typo that silently meant "default" would ship the public PoW gate the operator
    asked to be rid of."""
    with pytest.raises(ValueError, match="anubis"):
        ImageConfig.from_dict({"anubis": junk})


# ------------------------------------------------- the REAL builders read the argv

def _plain(text):
    return re.sub(r"\x1b\[[0-9;]*m", "", text)


def run_builder(platform, argv):
    """Run the real builder on Studio's own argv; it dies at role validation, after the
    OPTIONAL_SERVICES resolution it reports on. Returns the de-coloured output."""
    env = {k: v for k, v in os.environ.items()
           if k not in ("OPTIONAL_SERVICES", "EXCLUDE_SERVICES")}
    out = subprocess.run(["bash", str(BUILDERS[platform]), *argv, "--role", "bogus"],
                         capture_output=True, text=True, timeout=120, env=env)
    text = _plain(out.stdout + out.stderr)
    assert "--role must be one of" in text, f"builder never got past service resolution: {text}"
    assert "command not found" not in text and "FATAL(optional-services)" not in text, text
    return text


@pytest.mark.parametrize("platform", ["x86", "rpi5"])
def test_builder_keeps_the_defaults_for_force_off_with_an_untouched_picker(platform):
    text = run_builder(platform, svc_args(platform=platform, anubis="off"))
    assert f"kept the built-in default selection: {DEFAULTS} -anubis" in text


@pytest.mark.parametrize("platform", ["x86", "rpi5"])
def test_builder_gives_none_plus_veto_exactly_the_veto(platform):
    argv = svc_args(platform=platform, anubis="off", optional_services=[SERVICES_NONE])
    text = run_builder(platform, argv)
    assert "(final selection: -anubis)" in text, text


@pytest.mark.parametrize("platform", ["x86", "rpi5"])
def test_builder_carries_the_veto_across_the_all_sentinel(platform):
    argv = svc_args(platform=platform, anubis="off", optional_services=[SERVICES_ALL])
    text = run_builder(platform, argv)
    assert re.search(r"sentinel expanded to every user-level slug: .* -anubis\s*$", text, re.M), text


@pytest.mark.parametrize("platform", ["x86", "rpi5"])
def test_builder_leaves_an_allow_list_with_a_veto_alone(platform):
    argv = svc_args(platform=platform, anubis="off", optional_services=["akkoma"])
    text = run_builder(platform, argv)
    assert "kept the built-in default selection" not in text


@pytest.mark.parametrize("platform", ["x86", "rpi5"])
def test_builder_keeps_explicit_none_as_none(platform):
    """The lone-veto rule must not fire on an EMPTY list: Studio's explicit-none is
    `--optional-services ""` and has to stay none, not turn back into the defaults."""
    text = run_builder(platform, svc_args(platform=platform, optional_services=[SERVICES_NONE]))
    assert "kept the built-in default selection" not in text
