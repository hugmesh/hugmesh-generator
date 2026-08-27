"""The TUI's RUN E2E TESTS screen (:mod:`hugmesh_studio.tui.e2e`).

Qt-FREE, like every TUI file here: the screen renders strings and routes, and the
model behind it (:mod:`hugmesh_studio.core.e2e_environments`) has no toolkit at all.
The GUI twin is covered by test_pages_e2e_run.py; the id/label/description parity of
the two mode menus by test_tui_gui_parity.py.

WHAT THIS SCREEN REPLACED. The "QEMU device tests" card was removed from BOTH menus
on 2026-08-27 ("remove QEMU device emulation menu item as it does not do anything that
cannot be done from the other menu, but add the run e2e tests button"). The QEMU
device-test SCREEN survives — it is the only door to the Playwright-on-an-emulated-
device harness and the SELinux AVC workout — and this screen is how it is reached, so
that routing is pinned here.

THE HONESTY THIS FILE GUARDS. A read-only screen cannot arm a lying button, because
it has no button. Its one available dishonesty is claiming to know something it never
measured, so it must (a) print only commands the core authored, and (b) say plainly
that it does not probe readiness and name what does.
"""
import pytest

from hugmesh_studio.core import e2e_environments as env_mod
from hugmesh_studio.tui import e2e as tui_e2e
from hugmesh_studio.tui import journey

E2E_CARD_NUMBER = str([m for m, _, _ in journey.MODE_CHOICES].index("e2e") + 1)


def _at_e2e(generator_dir: str = ".") -> journey.Journey:
    j = journey.Journey(generator_dir)
    j.feed("")                        # welcome -> mode
    j.feed(E2E_CARD_NUMBER)
    assert j.slug == "e2e"
    return j


# ── the card, and the screen behind it ───────────────────────────────────────

def test_the_card_is_in_the_menu_and_the_removed_one_is_not():
    ids = [m for m, _, _ in journey.MODE_CHOICES]
    assert "e2e" in ids
    assert "qemu" not in ids


def test_the_card_opens_a_real_screen_not_a_stub():
    j = _at_e2e()
    assert isinstance(j.screen_for("e2e"), tui_e2e.E2EScreen)
    assert not isinstance(j.screen_for("e2e"), journey.PendingSideFlow)
    assert j.flags["e2e_selected"] is True
    assert "not yet ported to the TUI" not in "\n".join(j.lines())


def test_the_card_commits_no_image_mode():
    j = _at_e2e()
    assert j.cfg.mode == "standalone"          # the untouched default


# ── the chooser: the catalogue, never a restated list ────────────────────────

def test_every_catalogued_environment_is_offered():
    text = "\n".join(_at_e2e().lines())
    for row in env_mod.describe():
        assert row["id"] in text
        assert row["label"] in text


def test_the_root_requirement_is_badged_on_the_row_that_has_it():
    """qemu is the one environment whose BRING-UP needs root. Neither face may offer
    to spawn that: an unanswerable password prompt does not fail, it hangs."""
    lines = tui_e2e.environment_lines()
    joined = "\n".join(lines)
    assert "BRINGING THIS UP NEEDS ROOT" in joined
    assert sum(1 for e in env_mod.E2E_ENVIRONMENTS if e.boot_needs_root) == \
        joined.count("BRINGING THIS UP NEEDS ROOT")


def test_a_number_opens_that_environments_plan():
    j = _at_e2e()
    j.feed("2")                                 # kind
    text = "\n".join(j.lines())
    assert "environment  kind" in text
    assert f"{env_mod.ENV_VAR}=kind" in text


def test_enter_takes_the_default_which_is_todays_behaviour():
    j = _at_e2e()
    j.feed("")
    assert f"environment  {env_mod.DEFAULT_ENVIRONMENT}" in "\n".join(j.lines())
    assert env_mod.DEFAULT_ENVIRONMENT == "docker"


def test_a_bad_pick_says_what_the_keys_are_and_stays_put():
    j = _at_e2e()
    j.feed("9")
    assert j.slug == "e2e"
    assert "pick 1-3" in j.status
    j.feed("banana")
    assert j.slug == "e2e"
    assert "a NUMBER picks an environment" in j.status


# ── the printed command IS the core's, not a second spelling ─────────────────

@pytest.mark.parametrize("env_id", list(env_mod.environment_ids()))
def test_the_printed_run_is_the_plans_own_argv_and_env(env_id):
    """A hint composed here would be a second way to run the suite, free to drift
    from what the GUI spawns and what `make` does. Every token is the plan's."""
    plan = env_mod.plan(env_id)
    text = "\n".join(tui_e2e.plan_lines(env_id))
    for token in plan.argv:
        assert token in text
    for key, value in plan.env.items():
        assert f"{key}={value}" in text or f"{key}={value!r}" in text
    assert plan.start_hint in text


@pytest.mark.parametrize("env_id", list(env_mod.environment_ids()))
def test_the_printed_run_never_contains_a_boot_command(env_id):
    """The standing rule: this face renders a start command as TEXT under 'START it',
    and never as part of the run line. A boot verb inside the runnable command would
    be a screen that starts a mesh."""
    run_line = [ln for ln in tui_e2e.plan_lines(env_id)
                if env_mod.RUN_TARGET in ln]
    assert run_line, "the copy-ready run line vanished"
    for cmd in env_mod.BOOT_COMMANDS:
        assert cmd not in run_line[0]


def test_the_screen_says_it_does_not_probe_readiness():
    """The one dishonesty available to a read-only screen is implying it measured
    something. It says it did not, and names the two things that do."""
    text = "\n".join(tui_e2e.plan_lines("docker"))
    assert "READINESS IS NOT PROBED ON THIS SCREEN" in text
    assert "e2e_ready" in text
    assert "SKIPS" in text


def test_a_refusal_is_rendered_rather_than_acted_on():
    """plan(boot=True) is refused for qemu. Whatever the core refuses, this face
    prints — it has no code path that could act on it."""
    refused = env_mod.plan("qemu", boot=True)
    assert not refused.runnable
    # the screen only ever asks for the non-boot plan, so its own render is runnable…
    assert "REFUSED:" not in "\n".join(tui_e2e.plan_lines("qemu"))
    # …and the module it reads from is the one that would refuse.
    assert refused.refusals


# ── the door the removed card left behind ────────────────────────────────────

def test_the_device_lane_key_opens_the_real_qemu_screen():
    from hugmesh_studio.tui.qemu import QemuScreen
    j = _at_e2e()
    j.feed(tui_e2e.DEVICE_LANE_KEY)
    assert j.slug == "qemu"
    assert isinstance(j.screen_for("qemu"), QemuScreen)
    assert j.flags["qemu_selected"] is True


def test_the_device_lane_names_the_three_harnesses_before_you_press_it():
    """The removed card's blurb said "ephemeral asserted boots", which is the half
    Mesh emulation can also do. What it UNIQUELY held is named here instead."""
    text = "\n".join(tui_e2e.device_lane_lines())
    for script in ("run-qemu-docker.sh", "run-qemu-e2e.sh", "avc-workout.sh"):
        assert script in text


def test_the_device_lane_key_is_not_the_back_key():
    """`q` is the journey-wide back/quit key on every screen. Stealing it here would
    make the one screen that hosts a sub-flow behave unlike all the others."""
    assert tui_e2e.DEVICE_LANE_KEY not in ("q", "quit", "exit")
    j = _at_e2e()
    j.feed("q")
    assert j.slug == "mode"


def test_q_walks_back_through_the_sub_states_not_out_of_the_journey():
    j = _at_e2e()
    j.feed("1")
    assert "environment  docker" in "\n".join(j.lines())
    j.feed("q")
    assert j.slug == "e2e"
    assert "environment  docker" not in "\n".join(j.lines())
    assert not j.done


def test_re_entering_the_screen_forgets_the_open_plan():
    j = _at_e2e()
    j.feed("3")
    assert "environment  qemu" in "\n".join(j.lines())
    j.goto("mode")
    j.feed(E2E_CARD_NUMBER)
    assert "environment  qemu" not in "\n".join(j.lines())
