"""tui — the JOURNEY: welcome flow (#67), canonical page order, mode commits.

Headless and Qt-free (the journey state machine is the model both faces render;
the plain face is driven with scripted streams exactly like test_tui_sessions).
The GUI-vs-TUI surface parity pins live in test_tui_gui_parity.py (Qt-present);
HERE the pins are against core.config's canonical contracts, which the GUI
asserts against too — the shared single source.
"""
import io
import json
import os

import pytest

from hugmesh_studio.core.config import (
    MODE_SKIPPED_PAGES, WIZARD_PAGE_SLUGS, ImageConfig, User,
)
from hugmesh_studio.core.worklist import load_any
from hugmesh_studio.tui import app as tui_app
from hugmesh_studio.tui import journey, plain


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


def _run_plain(script: str, generator_dir: str = ".") -> str:
    out = io.StringIO()
    rc = plain.run_journey(inp=io.StringIO(script), out=out,
                           generator_dir=generator_dir)
    assert rc == 0
    return out.getvalue()


def _walk(*feeds: str, generator_dir: str = ".") -> journey.Journey:
    j = journey.Journey(generator_dir)
    for line in feeds:
        j.feed(line)
    return j


# ── the canonical page order — the GUI's, consumed not copied ──────────────────────
def test_page_order_is_the_gui_slug_tuple_itself():
    # identity, not equality: a copy could drift, THE tuple cannot.
    assert journey.PAGE_ORDER is WIZARD_PAGE_SLUGS


def test_every_canonical_slug_has_a_journey_screen():
    j = journey.Journey(".")
    for slug in WIZARD_PAGE_SLUGS:
        assert j.screen_for(slug) is not None
    # side-flows are entered only via their card, never positionally — but the
    # registry still has to cover every one of them.
    for slug in journey.SIDE_FLOW_SLUGS:
        assert j.screen_for(slug).slug == slug


def test_qemu_stays_a_side_flow_slug_even_though_its_card_went():
    """A "dead branch" that must NOT be tidied away.

    ``commit_mode`` builds its flags from SIDE_FLOW_SLUGS, and since 2026-08-27
    "qemu" is no longer a mode-menu id on either face — so that comprehension's qemu
    arm only ever CLEARS the flag, which reads like leftovers. It is not: membership
    is what keeps the positional walk from ever landing on the qemu screen
    (``_advance`` skips SIDE_FLOW_SLUGS, pinned in the standalone-walk test below)
    and what lets ``goto("qemu")`` resolve a registered screen. Removing it to kill
    the dead comparison would put a device-test page in the middle of an image walk.
    """
    assert "qemu" in journey.SIDE_FLOW_SLUGS
    assert "qemu" not in [mid for mid, *_ in journey.MODE_CHOICES]
    j = journey.Journey(".")
    assert j.screen_for("qemu") is not None


def test_the_hosted_screens_are_real_not_honest_stubs():
    """Which flows the TUI actually HOSTS, pinned by name so a screen can never
    silently regress into a stub (and a stub can never quietly claim a slug)."""
    j = journey.Journey(".")
    hosted = {slug for slug in journey.SIDE_FLOW_SLUGS
              if not isinstance(j.screen_for(slug), journey.PendingSideFlow)}
    # qemu joined localcloud/meshemu once tui/qemu.py landed: both emulation
    # lanes (TEST and DEPLOY) are hosted here; the MDM/cloud drivers are not.
    # "e2e" joined them on 2026-08-27 — it is a mode-menu card on BOTH faces, so a
    # stub here would be the TUI breaking a promise the menu makes. "qemu" STAYS
    # hosted even though its own card went: it is reached from the e2e screen.
    assert hosted == {"localcloud", "e2e", "qemu", "meshemu"}


def test_the_e2e_card_opens_the_real_e2e_screen():
    from hugmesh_studio.tui.e2e import E2EScreen
    j = _walk("", "4")
    assert j.slug == "e2e"
    assert isinstance(j.screen_for("e2e"), E2EScreen)
    text = "\n".join(j.lines())
    assert "not yet ported to the TUI" not in text
    # the three catalogued environments, read from the core rather than restated
    from hugmesh_studio.core import e2e_environments as env_mod
    for env_id in env_mod.environment_ids():
        assert env_id in text


def test_the_e2e_screen_is_the_qemu_screens_only_door_now():
    """The "QEMU device tests" mode card was removed on 2026-08-27. Removing a MENU
    CARD must not delete a LANE, so the device-test screen is still real and still
    reachable — from the e2e card, on both faces (the GUI twin is E2EPage's second
    radio arm)."""
    from hugmesh_studio.tui.qemu import QemuScreen
    assert "qemu" not in [mid for mid, _, _ in journey.MODE_CHOICES]
    j = _walk("", "4", "d")
    assert j.slug == "qemu"
    assert isinstance(j.screen_for("qemu"), QemuScreen)
    assert j.flags["qemu_selected"] is True
    text = "\n".join(j.lines())
    assert "not yet ported to the TUI" not in text
    assert "pick the session" in text


def test_a_fresh_start_lands_on_welcome():
    # the #67 contract: first slug, and nothing else sets a start id.
    j = journey.Journey(".")
    assert j.slug == WIZARD_PAGE_SLUGS[0] == "welcome"


# ── welcome: the two journey entry points (#67, minus the #2 duplicate) ────────────
def test_welcome_offers_the_two_entry_points_with_the_gui_ids():
    """DECISION 2(d) (operator, 2026-08-26: "asking same questions seemingly multiple
    times"): the welcome "Start a local mesh" entry and the MODE menu's "Local Docker
    mesh" card were two doors onto one flow. The mode menu keeps it; welcome dropped
    it, in the GUI and here — tests/test_tui_gui_parity.py pins that the two front
    ends made the same cut."""
    assert [cid for cid, _, _ in journey.WELCOME_CHOICES] == ["build", "sessions"]
    assert journey.WELCOME_TARGET == {"build": "mode", "sessions": "sessions"}
    # THE NEGATIVE, kept as a negative: no orphan routing target for an entry nobody
    # can pick (the GUI calls that an unreachable branch in nextId()).
    assert "localmesh" not in journey.WELCOME_TARGET
    # ...and the journey is still REACHABLE, one screen further in
    assert "localmesh" in [mid for mid, _, _ in journey.MODE_CHOICES]


def test_welcome_default_enter_keeps_the_historical_welcome_to_mode_flow():
    j = _walk("")
    assert j.slug == "mode"
    assert j.flags.get("localmesh_selected") is False


def test_the_mode_localmesh_entry_raises_the_transient_flag():
    """RE-POINTED by DECISION 2(d): the door moved from welcome to the mode menu, so
    the walk is one screen longer ("" = Enter = Start building, then mode choice 1 =
    "Local Docker mesh"). The property is untouched — picking it raises the transient
    flag and commits no image mode."""
    j = _walk("", "1")
    assert j.slug == "localmesh"
    assert j.flags["localmesh_selected"] is True
    # the flag is transient, never persisted into cfg (cfg.mode stays an image mode)
    assert j.cfg.mode == "standalone"


def test_welcome_sessions_entry_asks_the_face_for_the_review():
    # "2", not "3": sessions is the SECOND welcome entry now that the duplicate
    # local-mesh entry between them is gone (DECISION 2(d)).
    j = _walk("2")
    assert j.effect == "sessions"
    assert j.slug == "welcome"          # the journey resumes where it was


def test_plain_face_embeds_the_sessions_review_and_resumes():
    # "2": sessions moved up one slot when the duplicate local-mesh entry was
    # removed from the welcome screen (DECISION 2(d)).
    text = _run_plain("2\nq\nq\n")      # welcome -> sessions review -> back -> quit
    assert "previous builds (newest first):" in text
    # after the review quits, the welcome screen renders again
    assert text.count("HugMesh Image Studio") >= 2


def test_welcome_explainer_names_the_getting_started_guide():
    j = journey.Journey(".")
    assert any(journey.README_GETTING_STARTED in ln for ln in j.lines())


# ── mode: the journey-ordered menu (#67, with the #65/#69 cards) ───────────────────
def test_mode_menu_ids_in_the_operator_journey_order():
    assert [mid for mid, _, _ in journey.MODE_CHOICES] == [
        "localmesh", "localcloud", "mesh", "e2e", "meshemu",
        "deploy", "phone", "quest", "cloud", "standalone"]


def test_mode_default_is_standalone_by_id():
    assert journey.MODE_DEFAULT_CHOICE == "standalone"
    j = _walk("", "")                   # plain Enter on welcome, then on mode
    assert j.cfg.mode == "standalone"
    assert j.slug == "role"


def test_each_side_flow_card_routes_to_its_slug_and_commits_no_mode():
    for number, slug in (("1", "localmesh"), ("4", "e2e"), ("5", "meshemu"),
                         ("6", "deploy"), ("7", "phone"), ("8", "quest")):
        j = _walk("", number)
        assert j.slug == slug, (number, slug, j.slug)
        assert j.cfg.mode == "standalone"       # side-flows never touch cfg.mode
        assert j.flags[f"{slug}_selected"] is True


def test_pending_side_flows_are_honest_and_return_to_the_menu():
    j = _walk("", "7")                  # MDM phone: not ported yet
    assert "not yet ported to the TUI" in "\n".join(j.lines())
    j.feed("")
    assert j.slug == "mode"


def test_mode_commit_mesh_enters_the_mesh_chain_at_idp():
    j = _walk("", "3")
    assert j.cfg.mode == "mesh"
    assert j.slug == "idp"
    assert j.cfg.role == "omnibus"      # the mesh default role, reset by id


def test_mode_commit_standalone_clears_a_mesh_detours_admin_plane():
    j = _walk("", "3")                  # into mesh
    j.cfg.users.append(  # simulate an admin-plane leftover
        User(username="alice", domain="d.example.org"))
    j.goto("mode")
    j.feed("10")                        # standalone
    assert j.cfg.mode == "standalone"
    assert j.cfg.users == [] and j.cfg.domains == []
    assert j.cfg.additional_domains is False and j.cfg.configure_users is False
    assert j.cfg.tailscale is False and j.cfg.sso is False


# ── the positional walk honours the GUI's skip rules ───────────────────────────────
def _visited(j: journey.Journey, feeds: list[str]) -> list[str]:
    seen = [j.slug]
    for line in feeds:
        j.feed(line)
        seen.append(j.slug)
    return seen


def test_standalone_walk_skips_every_admin_plane_page():
    j = journey.Journey(".")
    seen = _visited(j, ["", ""] + [""] * 10)
    assert j.done
    for slug in MODE_SKIPPED_PAGES["standalone"]:
        assert slug not in seen
    assert "sessions" not in seen                # entered only from welcome
    for slug in journey.SIDE_FLOW_SLUGS:
        assert slug not in seen                  # entered only via their card
    assert seen[-2] == "build"                   # the TUI walk terminates here


def test_mesh_walk_reaches_worklist_and_gates_the_tables():
    j = journey.Journey(".")
    j.feed("")            # -> mode
    j.feed("3")           # mesh -> idp
    j.feed("")            # idp keeps casdoor -> worklist
    assert j.slug == "worklist"
    j.feed("")            # continue without a row: refused inline
    assert j.slug == "worklist" and "at least one" in j.status
    j.feed("1")
    j.feed("")            # -> branding (role/hardware are MODE_SKIPPED_PAGES)
    assert j.slug == "branding"
    j.feed("")            # -> network
    j.feed("")            # -> keyzip
    j.feed("")            # -> domains_choice
    assert j.slug == "domains_choice"
    j.feed("n")           # no extra domains -> the domains table is skipped
    assert j.slug == "users_choice"
    j.feed("n")           # users table skipped too
    assert j.slug == "system"


def _after_system() -> str:
    """The step Enter on the System screen advances a MESH walk to — read off the
    canonical order, so a step inserted next to it (vault, #273) moves this test's
    expectation instead of breaking it."""
    return WIZARD_PAGE_SLUGS[WIZARD_PAGE_SLUGS.index("system") + 1]


def _mesh_to_system(*rows: str) -> journey.Journey:
    """A mesh walk to the System identity step with the given worklist rows checked
    (row NUMBERS on the TUI worklist: 1 = pki.x86, 2 = pki.rpi5, 3 = backend.x86 …)."""
    j = _walk("", "3", "", *rows, "")       # mode, mesh, casdoor, rows, commit
    for _ in range(len(WIZARD_PAGE_SLUGS)):
        if j.slug == "system":
            break
        j.feed("n" if j.slug.endswith("_choice") else "")
    assert j.slug == "system"
    return j


def test_system_step_is_hosted_and_names_each_image_of_a_mesh_worklist():
    """ISSUE #229 on the TUI face: the System step is a real screen (no longer a
    pending stub), it lists one row per worklist image with the name each derives,
    and `N NAME` gives row N its OWN hostname — the value lands on that entry, the
    base stays blank, and each materialized image carries only its own -H."""
    j = _mesh_to_system("1", "3")           # pki.x86 + backend.x86
    assert not isinstance(j.screen_for("system"), journey.PendingStep)
    text = "\n".join(j.lines())
    assert "not yet ported" not in text.split("Timezone")[0]   # the hostname half is real
    assert "pki.x86" in text and "backend.x86" in text
    assert "hugmesh-pki" in text and "hugmesh-backend" in text   # the derived names
    j.feed("1 ca-1")
    assert "ca-1" in j.status
    j.feed("2 be-main")
    assert {e.id: e.hostname for e in j.worklist.entries} == {
        "pki.x86": "ca-1", "backend.x86": "be-main"}
    assert j.cfg.hostname == ""
    argvs = {e.id: cfg.to_cli_args() for e, cfg in j.worklist.materialize()}
    assert argvs["pki.x86"][argvs["pki.x86"].index("--hostname") + 1] == "ca-1"
    assert argvs["backend.x86"][argvs["backend.x86"].index("--hostname") + 1] == "be-main"
    # `N -` blanks a row back to its derived name; Enter continues the walk
    j.feed("2 -")
    assert j.worklist.entries[1].hostname == ""
    j.feed("")
    assert j.slug == _after_system()


def test_system_step_refuses_duplicate_and_malformed_hostnames_inline():
    j = _mesh_to_system("1", "3")
    j.feed("1 node")
    j.feed("2 node")
    assert j.worklist.entries[1].hostname == "" and "already" in j.status
    j.feed("1 -")                           # row 1 back to its derived hugmesh-pki
    j.feed("2 hugmesh-pki")                 # equals what that blank pki row derives
    assert j.worklist.entries[1].hostname == "" and "already" in j.status
    j.feed("2 Bad_Host!")
    assert j.worklist.entries[1].hostname == "" and "not a valid hostname" in j.status
    j.feed("9 x")
    assert "no such row" in j.status
    # a base hostname riding onto every (blank) row — the #229 shape, e.g. a loaded
    # legacy envelope — cannot be committed as-is
    j.cfg.hostname = "everyone"
    j.feed("")
    assert j.slug == "system" and "same hostname" in j.status
    j.feed("2 -")                           # any edit blanks the base...
    assert j.cfg.hostname == ""
    # ...WITHOUT silently renaming the other row: it keeps the name it was going to
    # bake, explicitly, so what the operator saw is what the build gets
    assert [e.hostname for e in j.worklist.entries] == ["everyone", ""]
    j.feed("")
    assert j.slug == _after_system()


def test_system_step_names_persist_across_a_worklist_recommit_and_into_the_envelope(tmp_path):
    j = _mesh_to_system("1", "3")
    j.feed("1 ca-1")
    j.goto("worklist")                      # back to the worklist, re-commit it
    j.feed("")
    assert {e.id: e.hostname for e in j.worklist.entries} == {
        "pki.x86": "ca-1", "backend.x86": ""}
    for _ in range(len(WIZARD_PAGE_SLUGS)):
        if j.slug == "build":
            break
        j.feed("n" if j.slug.endswith("_choice") else "")
    path = tmp_path / "mesh.json"
    j.feed(f"s {path}")
    assert "saved to" in j.status
    _base, wl = load_any(str(path))
    assert [(e.id, e.hostname) for e in wl.entries] == [("pki.x86", "ca-1"),
                                                        ("backend.x86", "")]


def test_system_step_single_image_sets_the_config_hostname():
    """Outside mesh there is one image and the plain config field is the channel —
    existing single-image flows keep their shape."""
    j = _walk("", "", "")                    # standalone, default role -> ...
    for _ in range(len(WIZARD_PAGE_SLUGS)):
        if j.slug == "system":
            break
        j.feed("")
    assert j.slug == "system"
    assert "standalone-thick.x86" in "\n".join(j.lines())
    j.feed("1 my-desktop")
    assert j.cfg.hostname == "my-desktop"
    j.feed("")
    assert j.slug == "home"


def test_external_idp_is_listed_but_refused_with_the_reason():
    j = _walk("", "3")
    j.feed("2")                          # Azure Entra ID
    assert j.slug == "idp"               # not advanced
    assert "not yet ported" in j.status
    assert j.cfg.idp == "casdoor"        # state unchanged — fail closed


# ── the walk ends in a config the GUI/CLI can build ────────────────────────────────
def test_standalone_walk_saves_a_loadable_config(tmp_path):
    path = tmp_path / "standalone.json"
    script = "\n".join(["", "", "", "", "", "", "", "", f"s {path}", "q"]) + "\n"
    text = _run_plain(script)
    assert f"saved to {path}" in text
    cfg = ImageConfig.load(str(path))
    assert cfg.mode == "standalone" and cfg.role == "standalone-thick"


def test_mesh_walk_saves_a_worklist_envelope(tmp_path):
    path = tmp_path / "mesh.json"
    j = _walk("", "3", "", "1", "")      # mesh, casdoor, one worklist row
    for _ in range(len(WIZARD_PAGE_SLUGS)):   # branding..home pending steps
        if j.slug == "build":
            break
        j.feed("n" if j.slug.endswith("_choice") else "")
    assert j.slug == "build"
    j.feed(f"s {path}")
    assert "saved to" in j.status
    base, wl = load_any(str(path))
    assert base.mode == "mesh"
    assert [e.id for e in wl.entries] == ["pki.x86"]


def test_build_screen_is_honest_about_not_building():
    j = _walk("", "")
    while not j.done and j.slug != "build":
        j.feed("")
    assert "does not run builds yet" in "\n".join(j.lines())


# ── entry point wiring ─────────────────────────────────────────────────────────────
def test_main_default_opens_the_welcome_journey(capsys):
    out = io.StringIO()
    rc = tui_app.main([], inp=io.StringIO("q\n"), out=out)
    assert rc == 0
    text = out.getvalue()
    assert "HugMesh Image Studio" in text
    assert "Start building" in text and "Review prior sessions" in text


def test_main_sessions_flag_opens_the_review_directly():
    out = io.StringIO()
    rc = tui_app.main(["--sessions"], inp=io.StringIO("q\n"), out=out)
    assert rc == 0
    assert "previous builds (newest first):" in out.getvalue()


def test_unknown_input_gets_an_inline_message_never_a_crash():
    j = journey.Journey(".")
    j.feed("banana")
    assert "unrecognised" in j.status
    assert j.slug == "welcome" and not j.done
