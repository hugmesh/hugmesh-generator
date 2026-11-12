"""GUI-14, the Qt-free half: a character budget on every Studio wizard step subtitle.

The real check is geometric and lives in test_wizard.py
(test_no_step_subtitle_is_cut_off_by_the_wizard_header): it measures each subtitle in
the wizard's own header, which holds two lines and clips the rest. That test needs a Qt
binding, and the GitHub pytest job installs none, so on its own it would never gate a
pull request. This file reads the same subtitles from the source (tests/_subtitles.py)
and holds them to a budget, so a paragraph pasted into a setSubTitle() goes red there
too.

The budget is a tripwire, not a fit test. Every subtitle that was cut off measured 263
characters or more (Mode 518, Secrets store 370, Domains 355), every one fits at 180 or
fewer, and 200 sits between: well clear of a two-line sentence, well short of a
paragraph.
"""
import _subtitles

SUBTITLE_BUDGET = 200

#: setSubTitle() sources the scan cannot read as text, and who measures them instead.
#: A new one fails test_every_unreadable_subtitle_is_a_known_one: make it a constant
#: the scan can read, or add it here with the test that covers it.
KNOWN_UNREADABLE = {
    ("domain_services.py", "subtitle"):
        "composed per domain ('Domain 2 of 3 — …'); measured in the header by "
        "test_domain_services_selection_column.py",
    ("localmesh.py", "want"):
        "a step's SUBTITLE or DOCKED_SUBTITLE, each read here as a class constant",
    ("localmesh.py", "LocalMeshEnvPage.SUBTITLE"):
        "an f-string (the superbrand term); test_wizard.py measures it from the live class",
}


def test_every_subtitle_is_within_the_budget():
    found, _unreadable = _subtitles.scan()
    over = [f"{where} ({len(text)} chars): {text[:70]}…"
            for where, text in found if len(text) > SUBTITLE_BUDGET]
    assert not over, (
        f"{len(over)} wizard subtitle(s) over {SUBTITLE_BUDGET} characters — the header "
        "shows two lines and cuts the rest off mid-sentence. Keep the subtitle to one or "
        "two short sentences and move the explanation into a muted label at the top of "
        "the page body:\n  " + "\n  ".join(over))


def test_the_scan_reads_the_steps_it_is_meant_to():
    """Not vacuous: the scan sees every page module's subtitles, including the three
    GUI-14 found cut off and the later, per-mode and docked ones."""
    found, _unreadable = _subtitles.scan()
    files = {where.split(":")[0] for where, _t in found}
    assert {"mode.py", "domains.py", "vault.py", "worklist.py", "e2e.py", "deploy.py",
            "idp.py", "keyzip.py", "localmesh.py", "role.py", "network.py"} <= files
    wheres = [where for where, _t in found]
    assert any("LocalMeshPage.DOCKED_SUBTITLE" in w for w in wheres)
    assert len(found) >= 45, len(found)
    assert "golive.py" not in files, "GoLiveWizard's pages are measured by their own window"


def test_every_unreadable_subtitle_is_a_known_one():
    _found, unreadable = _subtitles.scan()
    assert unreadable == set(KNOWN_UNREADABLE), (
        f"new: {sorted(unreadable - set(KNOWN_UNREADABLE))}, "
        f"gone: {sorted(set(KNOWN_UNREADABLE) - unreadable)}")
