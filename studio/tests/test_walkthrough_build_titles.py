"""docs/STUDIO-WALKTHROUGH.md quotes the Review page's section titles verbatim
(issue #601, decisions 109a = A / 109b = A on #347).

The walkthrough's "Review" chapter names each section of the Studio's Build/Review page
by the exact text on its header, and a reader finds a section by matching that text. The
two drifted apart once ("Secure Boot (x86)" in the doc against "Secure Boot signing
(x86)" on screen; "Build plumbing" against "Build plumbing (advanced)"; the exact-command
fold quoted lower-case with no "(advanced)"), and nothing noticed.

The titles are read off the RUNNING page, not scraped out of build.py: a title in source
can be replaced before anyone sees it (network.py's 'Network, Identity, and Egress' is
rewritten in every mode), and a scrape would flag that as a mismatch against a screen
that never shows it. The comparison is byte-for-byte. Ignoring "(advanced)" would not
make "Secure Boot (x86)" match "Secure Boot signing (x86)" either, so there is no fuzzy
or case-folded match here, deliberately.

A title counts as quoted when it sits, whole, inside the doc's Review chapter as a
heading, a bold lead (**Title**) or an emphasised name (*Title*).
"""
import os
import re

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.platform_info import HostInfo            # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod               # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                       # noqa: E402
from hugmesh_studio.gui.pages._widgets import Collapsible         # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
# The doc is overridable only so the mutation check can point the test at a damaged copy.
DOC = os.environ.get("HUGMESH_WALKTHROUGH_DOC",
                     os.path.join(GENERATOR_DIR, "docs", "STUDIO-WALKTHROUGH.md"))

HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")

# The three titles the doc once got wrong (#601). Named so a collection that silently
# finds nothing, or loses these, fails instead of passing on an empty loop.
ONCE_WRONG = ("Secure Boot signing (x86)", "Build plumbing (advanced)",
              "Exact builder command (advanced)")


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.show()
    yield w
    w.close()
    w.deleteLater()


def _advance_to_build_page(wiz):
    """Walk the real flow, as test_pages_build_exec_help.advance_to does."""
    from hugmesh_studio.core.config import WIZARD_PAGE_SLUGS
    for _ in range(len(WIZARD_PAGE_SLUGS) + 1):
        page = wiz.currentPage()
        if isinstance(page, wizard_mod.BuildPage):
            return page
        before = wiz.currentId()
        wiz.next()
        assert wiz.currentId() != before, \
            f"flow stuck on {type(page).__name__} (validatePage rejected?)"
    raise AssertionError("never reached BuildPage")


def _page_titles(build):
    """Every titled section the running page shows: its collapsible headers plus the
    device table, which is deliberately a titled group box and not a collapsible."""
    titles = [c.title() for c in build.findChildren(Collapsible)]
    titles.append(build.device_table.title())
    return titles


def _review_chapter(path):
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    m = re.search(r"^### Review\n(.*?)(?=^### )", text, re.S | re.M)
    assert m, f"no '### Review' chapter in {path}"
    return m.group(1)


def _quoted(title, chapter):
    t = re.escape(title)
    heading = rf"^#+ +{t} *$"
    emphasised = rf"(?<!\*)\*{{1,2}}{t}\*{{1,2}}(?!\*)"
    return bool(re.search(f"{heading}|{emphasised}", chapter, re.M))


def test_the_page_yields_its_sections(wiz):
    """Guards the guard: an empty or shrunken title list would let the comparison below
    pass without comparing anything."""
    titles = _page_titles(_advance_to_build_page(wiz))
    assert len(titles) >= 8, f"the page yielded only {titles!r}"
    assert len(set(titles)) == len(titles), f"duplicate section titles: {titles!r}"
    for t in ONCE_WRONG:
        assert t in titles, f"the page no longer shows {t!r}; update ONCE_WRONG on purpose"


def test_every_build_page_title_is_quoted_verbatim_in_the_walkthrough(wiz):
    titles = _page_titles(_advance_to_build_page(wiz))
    chapter = _review_chapter(DOC)
    missing = [t for t in titles if not _quoted(t, chapter)]
    assert not missing, (
        "docs/STUDIO-WALKTHROUGH.md, chapter 'Review', does not quote these Build-page "
        f"titles exactly as the running page renders them: {missing!r}")
