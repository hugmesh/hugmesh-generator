"""tui — RUN E2E TESTS: the terminal face of :mod:`...core.e2e_environments`.

The GUI twin is :mod:`...gui.pages.e2e`. This screen took the mode-menu slot the
"QEMU device tests" card held until 2026-08-27 (operator: *"remove QEMU device
emulation menu item as it does not do anything that cannot be done from the other
menu, but add the run e2e tests button"*), and — exactly like the GUI page — it is
also the DOOR to the QEMU device-test screen, which was not removed. A menu card
went away; a lane did not.

TUI-appropriate scope, inherited from :mod:`.qemu` and :mod:`.meshemu` DELIBERATELY
(a design decision, not a missing feature): this screen stays READ-ONLY toward the
host. It never spawns the suite and never probes the machine — it renders the exact
argv and the exact environment ``core.e2e_environments`` would hand a runner, plus
each environment's own ``start_hint``, for a terminal operator to paste into a shell
of their own.

WHICH MEANS IT CANNOT BE A LYING BUTTON, because it has no button. The one dishonesty
available to a read-only screen is claiming to know something it has not measured, so
this one says in as many words that it does NOT probe readiness, and names the two
things that do: the GUI page's live ``LocalStackNode.e2e_ready`` gate, and the
harness's own per-scenario environment gate (``tests/e2e/steps/world.ts``), which
skips with a reason naming what to start.

EVERY STRING HERE IS AUTHORED BY THE CORE. The environment rows come from
``e2e_environments.describe()`` and the command line from ``e2e_environments.plan()``
— never a restated id, label, target or pin — so this face cannot print a spelling
the GUI, the Makefile and the CLI do not also run.
"""
from __future__ import annotations

import os
import shlex

from ..core import e2e_catalogue
from ..core import e2e_environments as env_mod

#: The checkout this package sits in (studio/hugmesh_studio/tui -> ../../..). ONLY a
#: fallback for a caller that names none: the screen passes the journey's own
#: ``generator_dir`` (the TUI's --generator-dir), exactly as the GUI e2e page reads
#: its ``self.generator_dir`` — so an installed Studio pointed at a checkout judges
#: THAT checkout's feature files, on both faces (decision 71).
_PACKAGE_CHECKOUT = os.path.abspath(
    os.path.join(os.path.dirname(__file__), os.pardir, os.pardir, os.pardir))

__all__ = ["E2EScreen", "DEVICE_LANE_KEY", "environment_lines", "plan_lines",
           "device_lane_lines"]

#: The key that opens the QEMU device-test screen from here. NOT "q" — that is the
#: journey-wide BACK/quit key, and stealing it would make the one screen that hosts
#: a sub-flow behave unlike every other.
DEVICE_LANE_KEY = "d"


def environment_lines(default_id: str = "") -> list[str]:
    """The numbered chooser: one row per catalogued environment, badged with the
    fact that decides whether the Studio may ever start it."""
    out: list[str] = []
    for i, row in enumerate(env_mod.describe(), 1):
        mark = "  (default)" if row["id"] == default_id else ""
        out.append(f"  {i}. {row['id']} — {row['label']}{mark}")
        if row["bootNeedsRoot"]:
            out.append("       BRINGING THIS UP NEEDS ROOT — neither face will "
                       "spawn it; start it yourself.")
    return out


def plan_lines(env_id: str, generator_dir: str | None = None) -> list[str]:
    """One environment's whole story: what it is, the copy-ready run, how to start it.

    ``generator_dir`` is the checkout whose lane doors are verified (the journey's
    --generator-dir); omitted, the checkout this package sits in.

    The command is ``plan()``'s own argv and env, rendered — this module composes no
    command of its own, which is what keeps the printed hint and the GUI's spawn
    identical.
    """
    plan = env_mod.plan(env_id)
    pins = " ".join(f"{k}={shlex.quote(v)}" for k, v in sorted(plan.env.items()))
    out = [
        f"environment  {plan.environment}",
        f"channel      {env_mod.ENV_VAR}={plan.environment}  "
        f"(read by tests/e2e/steps/world.ts)",
        "",
        plan.note,
        "",
        "run the Gherkin suite against it (paste into a shell):",
        f"  {pins} {shlex.join(plan.argv)}",
        "",
        f"START it (nothing here does): {plan.start_hint}",
    ]
    doors = e2e_catalogue.lane_door_lines_for_lane(generator_dir or _PACKAGE_CHECKOUT, env_id)
    if doors:
        out += ["", "also on this environment (its own door, its own command):"]
        out += [f"  - {d}" for d in doors]
    if plan.refusals:
        out += ["", "REFUSED:"] + [f"  - {r}" for r in plan.refusals]
    out += [
        "",
        "READINESS IS NOT PROBED ON THIS SCREEN. It is answered live by the GUI's "
        "e2e page (core.local_stack_node.e2e_ready) and, per scenario, by the "
        "harness itself, which SKIPS with a reason naming what to start.",
    ]
    return out


def device_lane_lines() -> list[str]:
    """What the device-lane door leads to, said before it is opened."""
    return [
        f"  {DEVICE_LANE_KEY} = QEMU device tests — the emulated-device lanes:",
        "        in-guest assertions over a build session's images "
        "(tests/qemu/run-qemu-docker.sh),",
        "        the Playwright browser suite on ONE booted guest "
        "(tests/qemu/run-qemu-e2e.sh),",
        "        and the SELinux AVC workout (tests/qemu/avc-workout.sh).",
        "        That screen had its own menu card until 2026-08-27; this is its "
        "door now.",
    ]


class E2EScreen:
    """RUN E2E TESTS: the environment chooser -> one environment's plan.

    ``q`` walks BACK through those sub-states, and ``d`` leaves for the QEMU
    device-test screen (arming ``qemu_selected``, the TUI twin of the GUI radio).
    """

    slug = "e2e"
    title = "Run e2e tests"
    wants_q = True                       # q navigates BACK through the sub-states

    def __init__(self):
        self._sub = "pick"               # pick | plan
        self._env = ""                   # the environment whose plan is open

    def enter(self, j) -> None:  # noqa: ARG002 — screen-protocol signature
        self._sub = "pick"
        self._env = ""

    def lines(self, j) -> list[str]:
        if self._sub == "plan" and self._env:
            return plan_lines(self._env, getattr(j, "generator_dir", None)) + \
                ["", "(q = back to the environment list)"]
        out = [
            "Run the end-to-end suite against a mesh that is ALREADY RUNNING. "
            "Nothing on this screen starts a mesh, and nothing on it spawns the "
            "suite: it renders the exact command and environment a run would use.",
            "",
        ]
        out += environment_lines(env_mod.DEFAULT_ENVIRONMENT)
        out += ["", *device_lane_lines()]
        out += ["", "(a NUMBER opens an environment's plan · Enter = the default ("
                + env_mod.DEFAULT_ENVIRONMENT + ") · "
                + DEVICE_LANE_KEY + " = the device lanes · q = back to the menu)"]
        return out

    def prompt(self, j) -> str:  # noqa: ARG002 — screen-protocol signature
        return f"e2e:{self._sub}> "

    def feed(self, j, line: str) -> None:
        low = line.strip().lower()
        if self._sub == "plan":
            if low in ("q", "quit", "exit", ""):
                self._sub = "pick"
                self._env = ""
            return
        if low in ("q", "quit", "exit"):
            j.goto("mode")
            return
        if low == DEVICE_LANE_KEY:
            # The TUI twin of E2EPage's second radio: arm the device-test flag and
            # go. Nothing else on either face writes qemu_selected True.
            j.flags["qemu_selected"] = True
            j.goto("qemu")
            return
        ids = env_mod.environment_ids()
        if low == "":
            self._env = env_mod.DEFAULT_ENVIRONMENT
            self._sub = "plan"
            return
        try:
            n = int(low)
        except ValueError:
            j.status = ("a NUMBER picks an environment, "
                        f"{DEVICE_LANE_KEY} opens the device lanes, q goes back.")
            return
        if not 1 <= n <= len(ids):
            j.status = f"pick 1-{len(ids)} (or {DEVICE_LANE_KEY}, or q)."
            return
        self._env = ids[n - 1]
        self._sub = "plan"
