"""Review page, "Build execution" — the four controls explain themselves (issue #231).

Operator's Image Studio builder notes, verbatim (issue #231):

    - [ ] Review page text is good (keep)
    - [ ] Build execution: add tooltips
    - [ ] rename "output dir" to "output location", "output folder", or "output directory"

The section decides HOW and WHERE a multi-hour build runs — backend engine, baked stack
environment, work directory, parallelism — and carried ZERO tooltips, while every other
section of the same page (artifact flag pairs, root image size, the QEMU device-test box)
already explained itself on hover. The bare names are not self-explanatory: "Backend
auto" does not say what auto resolves to on THIS host, "--env test" does not say the value
is baked into the image, and "Parallel jobs 8" does not say the 8 was measured from this
machine's memory rather than picked.

Three things are pinned here, and the third is the one that goes stale quietest:

1. PRESENCE — all four controls, and their _row() label wrappers, carry help. The wrapper
   matters: the label is what an operator reads before deciding to hover anything, and a
   tooltip only on the combo leaves the label mute (the HomePage idiom, PR #237).

2. FORM — rich text (<qt>). Issue #232's lesson, already encoded on self.img_size: a
   plain-text Qt tooltip does not wrap, so a three-sentence one renders as a single
   ~1000px line that runs off the edge of a small screen. Wayland and WSL2 are both
   supported targets and neither lets us reposition it.

3. SUBSTANCE — each tooltip states the FACT its field's name hides, checked against the
   code that implements it. A tooltip is not testable prose, but "does it still mention
   the thing it exists to say" is, and that is what stops the text drifting into
   confident nonsense. The Backend tooltip previously drafted for this issue claimed auto
   picks "native if it can build as root", which is simply not the rule
   (platform_info.HostInfo.default_backend never looks at is_root) — exactly the class of
   error these assertions catch.

...plus the rename itself, swept. "Output dir" became "Output directory" — the spelling
the Studio's own operator-facing text already used (worklist_driver.py:237/248 "Output
directory is unreachable" / "is not writable", and FleetPage's file-dialog caption). Per
vocabulary rule #240, ONE spelling per role: FleetPage's row said "Output dir" while its
own picker one line up said "Output directory", and DeployPage said "Out dir". All three
pages now agree, and this file fails if any of them drifts back.

Sentence case, deliberately: #231's first bullet is "Review page text is good (keep)", and
every other label on the Review page is sentence-cased. Title-casing headings/labels is
issue #226's ask and has to happen page-wide in one move — a half-cased page is worse
than either convention.
"""
import ast
import os
import re

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.platform_info import HostInfo            # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod               # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                       # noqa: E402
from hugmesh_studio.gui.pages import build as build_mod           # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
PAGES_DIR = os.path.join(STUDIO_ROOT, "hugmesh_studio", "gui", "pages")

HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")


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


def advance_to(wiz, page_cls):
    """Walk the real flow (BuildPage needs the upstream pages' collect) — the harness
    test_pages_build_sections.py uses."""
    from hugmesh_studio.core.config import WIZARD_PAGE_SLUGS
    for _ in range(len(WIZARD_PAGE_SLUGS) + 1):
        page = wiz.currentPage()
        if isinstance(page, page_cls):
            return page
        before = wiz.currentId()
        wiz.next()
        assert wiz.currentId() != before, \
            f"flow stuck on {type(page).__name__} (validatePage rejected?)"
    raise AssertionError(f"never reached {page_cls.__name__}")


def _exec_controls(build):
    return {"Backend": build.backend, "Environment (--env)": build.env,
            "Output directory": build.outdir, "Parallel jobs": build.jobs}


def _row_wrapper_for(build, control):
    """The _row() wrapper a control sits in: the widget whose accessibleName _row set on
    the control, i.e. the nearest ancestor inside the exec box. Found by walking up from
    the control until the parent is the exec box's layout host."""
    w = control
    while w.parent() is not None and w.parent() is not build.exec_box:
        w = w.parent()
    return w


# ------------------------------------------------------------------ 1. presence

def test_every_build_execution_control_has_help(wiz):
    """The whole ask, in one assertion: nothing in this section is left unexplained."""
    build = advance_to(wiz, wizard_mod.BuildPage)
    for name, ctl in _exec_controls(build).items():
        tip = ctl.toolTip()
        assert tip.strip(), f"{name} has no tooltip — issue #231's ask"
        assert len(tip) > 120, f"{name}'s tooltip is a stub, not an explanation: {tip!r}"


def test_the_row_labels_carry_the_same_help_so_hovering_the_name_works(wiz):
    """A tooltip only on the widget leaves the LABEL mute, and the label is the part an
    operator reads before deciding the name is unclear. HomePage (PR #237) puts the help
    on the _row() wrapper for exactly this reason; this section follows it."""
    build = advance_to(wiz, wizard_mod.BuildPage)
    for name, ctl in _exec_controls(build).items():
        row = _row_wrapper_for(build, ctl)
        assert row is not ctl, f"{name}: could not find its _row wrapper"
        assert row.toolTip().strip(), f"{name}'s label row has no tooltip"
        assert row.toolTip() == ctl.toolTip(), \
            f"{name}: label and control disagree about what the field does"


def test_the_help_survives_a_revisit(wiz, monkeypatch):
    """These four are absent from this page's gate_widgets map, so nothing rewrites their
    tooltips — unlike HomePage, which has to re-assert after gating. Pinned so a later
    gate that DOES touch them cannot silently blank the help."""
    build = advance_to(wiz, wizard_mod.BuildPage)
    before = {n: c.toolTip() for n, c in _exec_controls(build).items()}
    monkeypatch.setattr(wiz, "collect_all", lambda: None)
    build.initializePage()
    for name, ctl in _exec_controls(build).items():
        assert ctl.toolTip() == before[name], f"{name}'s tooltip was rewritten on revisit"


# --------------------------------------------------------------------- 2. form

def test_the_help_is_rich_text_so_it_wraps(wiz):
    """Issue #232's lesson, already applied to self.img_size: a plain-text Qt tooltip does
    NOT wrap, so a multi-sentence one renders as one enormous single line and runs off a
    small screen. Every tooltip in this section is long enough to need <qt>."""
    build = advance_to(wiz, wizard_mod.BuildPage)
    for name, ctl in _exec_controls(build).items():
        tip = ctl.toolTip()
        assert tip.startswith("<qt>") and tip.endswith("</qt>"), \
            f"{name}'s tooltip is not rich text — it will render as one unwrapped line"
        assert "<p>" in tip, f"{name}'s tooltip has no paragraphs to wrap at"


# ---------------------------------------------------------------- 3. substance

def test_backend_help_states_the_actual_resolution_rule(wiz):
    """platform_info.HostInfo.default_backend: native iff can_build_native (linux AND
    gentoo AND bash), else docker iff has_docker. is_root is NOT consulted — a draft of
    this tooltip said auto picks "native if it can build as root", which would send an
    operator looking at the wrong thing entirely. Root belongs to the OTHER half of the
    story: a native build needs it at dispatch, where build_driver prepends sudo/pkexec
    and preflight blocks only when neither helper exists (build_driver.py:695)."""
    build = advance_to(wiz, wizard_mod.BuildPage)
    tip = build.backend.toolTip().lower()
    assert "gentoo" in tip, "auto's rule is about Gentoo, and the tooltip does not say so"
    assert "docker daemon" in tip, "does not say what the docker backend actually needs"
    assert "chroot" in tip, "does not say WHY native needs root"
    assert "sudo" in tip and "pkexec" in tip, \
        "does not name the elevation helpers preflight looks for"
    # and it must not resurrect the false rule
    assert "native if it can build as root" not in tip


def test_env_help_says_the_value_is_baked_into_the_image(wiz):
    """The one fact the name "--env" hides completely. build-x86-host-stage4.sh:4466
    writes it to /etc/hugmesh/env and gate_env_apps() (:2918) prunes the baked ArgoCD app
    tree by it: prod drops the LAN wildcard-DNS app and pins release image tags, test
    drops the cloudflared go-live app. Choosing it is a decision about the SHIPPED image,
    not about this build run."""
    build = advance_to(wiz, wizard_mod.BuildPage)
    tip = build.env.toolTip()
    assert "/etc/hugmesh/env" in tip, "does not say the value is baked into the image"
    low = tip.lower()
    assert "cloudflared" in low or "go-live" in low, \
        "does not say which apps the env prunes"
    assert "keys usb" in low, "does not say prod expects credentials from the KEYS USB"
    # the consequence one row down on this same page (_sync_qemu_device_tests_gate)
    assert "device test" in low, \
        "does not mention that the post-build device tests need --env test"


def test_outdir_help_explains_the_per_session_subfolder(wiz):
    """The field is pre-filled on every visit, so an operator never sees it empty and
    never learns what it is: the builder's -w work directory (build_driver.py:348 native,
    :363 bind-mounted at /out for docker), under which every DISPATCH gets its own
    <out>/sessions/<id>/ (build_sessions.session_workdir) — the -w the command pane
    actually renders — with node key-zips inside it as keys-<entry id>/. Reachability and
    writability are BLOCKING preflight problems (worklist_driver.py:237/248)."""
    build = advance_to(wiz, wizard_mod.BuildPage)
    tip = build.outdir.toolTip()
    assert "-w" in tip, "does not connect the field to the builder's -w flag"
    assert "/out" in tip, "does not say where it is mounted on the docker backend"
    assert "sessions/" in tip, "does not mention the per-session subfolder"
    low = tip.lower()
    assert "keys-" in low, "does not say where node key-zips land"
    assert "writable" in low, "does not warn that an unwritable path blocks Continue"


def test_jobs_help_keeps_the_promise_the_walkthrough_already_made(wiz):
    """docs/STUDIO-WALKTHROUGH.md tells the operator "the jobs default is derived from
    this host's cores and available memory, not a fixed number" — a claim that was
    nowhere on screen. host_resources.default_jobs: HUGMESH_BUILD_JOBS wins outright,
    else max(2, min(nproc, MemAvailable_GiB // 2)), else min(nproc, 8) when /proc/meminfo
    is unreadable at all — native Windows/macOS, NOT WSL2: platform_info.py:15-16 makes
    WSL2 the supported Windows route and it has a real /proc/meminfo, so it takes the
    memory branch."""
    build = advance_to(wiz, wizard_mod.BuildPage)
    tip = build.jobs.toolTip()
    assert "HUGMESH_BUILD_JOBS" in tip, "does not name the override env var"
    low = tip.lower()
    assert "-j" in tip, "does not connect the spinbox to the builder's -j flag"
    assert "cores" in low and "gib" in low, \
        "does not say the default is derived from cores and memory"
    assert "ram" in low or "memory-tight" in low, \
        "does not warn that raising it costs memory"
    # A WRONG token, not a missing one: the battery's mutations only delete, so nothing
    # in it could catch the tooltip blaming the flat-8 fallback on WSL — the one platform
    # where it CANNOT fire, because WSL2 is a real Linux kernel with /proc/meminfo.
    assert "wsl" not in low or "not wsl2" in low, \
        "attributes the flat-8 fallback to WSL, which reads /proc/meminfo fine"


# ------------------------------------------------------- the rename, and its sweep

def test_the_review_row_says_output_directory(wiz):
    """The rename, on the surface it is about. _row() also sets the label as the widget's
    accessibleName, so this is the screen-reader name too."""
    build = advance_to(wiz, wizard_mod.BuildPage)
    labels = [lab.text() for lab in build.exec_box.findChildren(QtWidgets.QLabel)]
    assert "Output directory" in labels, f"Review row label is still: {labels}"
    assert "Output dir" not in labels and "Out dir" not in labels
    # _row() sets the caption as the accessibleName of the widget it was HANDED — here
    # the line-edit+Browse composite, since that is what the row is built around — so the
    # screen-reader name lives on the composite, not on the outer wrapper.
    row = _row_wrapper_for(build, build.outdir)
    names = [w.accessibleName() for w in [row, *row.findChildren(QtWidgets.QWidget)]]
    assert "Output directory" in names, \
        f"screen-reader name did not follow the rename: {[n for n in names if n]!r}"
    assert not any(n in ("Output dir", "Out dir") for n in names)


def test_the_browse_dialog_caption_followed_the_rename(wiz, monkeypatch):
    """The file-dialog caption is the SAME string in the source and is easy to miss —
    renaming only the row leaves the picker saying something else."""
    build = advance_to(wiz, wizard_mod.BuildPage)
    seen = []

    class _Stub:
        @staticmethod
        def getExistingDirectory(parent, caption, *a, **kw):
            seen.append(caption)
            return ""            # cancel: nothing is written into the field

    monkeypatch.setattr(QtWidgets, "QFileDialog", _Stub)
    row = _row_wrapper_for(build, build.outdir)
    buttons = row.findChildren(QtWidgets.QPushButton)
    assert buttons, "no Browse… button beside the output directory field"
    buttons[0].click()
    assert seen == ["Output directory"], f"picker caption is {seen}"


def _row_labels(module_path):
    """Every literal that reaches a _row() caption or a *_picker caption in one page
    module, read out of the AST — so a comment mentioning the old spelling cannot pass or
    fail this on its own."""
    tree = ast.parse(open(module_path, encoding="utf-8").read())
    out = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call) or not isinstance(node.func, ast.Name):
            continue
        name = node.func.id
        if name == "_row" and node.args:
            first = node.args[0]
            if isinstance(first, ast.Constant) and isinstance(first.value, str):
                out.append(first.value)
        elif name in ("_file_picker", "_picker_row") and len(node.args) >= 3:
            third = node.args[2]
            if isinstance(third, ast.Constant) and isinstance(third.value, str):
                out.append(third.value)
    return out


def test_no_gui_page_still_abbreviates_the_output_directory():
    """Vocabulary rule (#240): ONE spelling per role, swept in full — the omission #243
    had to clean up after. FleetPage disagreed with ITSELF (picker "Output directory",
    row "Output dir") and DeployPage said "Out dir"; all three pages now say the same
    thing, and this scans every page module so a fourth cannot appear."""
    offenders = {}
    for fn in sorted(os.listdir(PAGES_DIR)):
        if not fn.endswith(".py"):
            continue
        bad = [s for s in _row_labels(os.path.join(PAGES_DIR, fn))
               if re.fullmatch(r"(?i)\s*(out|output)\s+dir\s*", s)]
        if bad:
            offenders[fn] = bad
    assert not offenders, f"abbreviated output-directory labels left: {offenders}"


def test_the_three_pages_that_have_this_field_all_name_it_the_same():
    """Real-cases check for the sweep above: the labels really are there, and really agree —
    an empty scan would otherwise 'pass' if _row were renamed out from under it."""
    for fn in ("build.py", "fleet.py", "deploy.py"):
        labels = _row_labels(os.path.join(PAGES_DIR, fn))
        assert "Output directory" in labels, \
            f"{fn} no longer labels its output directory row: {labels}"


def test_the_review_page_stayed_sentence_cased():
    """#231's first bullet is "Review page text is good (keep)". The rename must not smuggle
    in the Title Case sweep that belongs to #226 — a page half in each convention is worse
    than either, so 'Output Directory' beside 'Root image size' is a failure here."""
    labels = _row_labels(os.path.join(PAGES_DIR, "build.py"))
    assert "Root image size" in labels, "harness stale: sentence-cased anchor is gone"
    assert "Output Directory" not in labels, \
        "Title Case landed piecemeal — sweep the whole page under #226 or none of it"


_ABBREV = re.compile(r"(?i)\b(out|output)\s+dir\b")


def _visible_strings(module_path):
    """Every string literal in a page module EXCEPT docstrings, read out of the AST.

    Docstrings are excluded deliberately: launch.py, progress.py and sessions_widget.py
    discuss "the out dir" in prose that never reaches a widget, and failing on those
    would push the next author to reword a comment instead of a label."""
    tree = ast.parse(open(module_path, encoding="utf-8").read())
    docstrings = set()
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef,
                             ast.AsyncFunctionDef)):
            body = getattr(node, "body", None)
            if (body and isinstance(body[0], ast.Expr)
                    and isinstance(body[0].value, ast.Constant)
                    and isinstance(body[0].value.value, str)):
                docstrings.add(id(body[0].value))
    return [node.value for node in ast.walk(tree)
            if isinstance(node, ast.Constant) and isinstance(node.value, str)
            and id(node) not in docstrings]


def test_no_page_shows_the_abbreviation_anywhere_a_user_can_read_it():
    """The row-label scan above is not the whole surface, and renaming ONLY row labels is
    how a page ends up disagreeing with itself — the exact defect this PR cites as its
    reason for touching FleetPage (row "Output dir" vs its own picker "Output directory").

    DeployPage had it in three more places that _row_labels cannot see, because they are
    not row captions: a button tooltip, an action tooltip, and a bare QFileDialog caption
    that is not routed through _file_picker. So scan every non-docstring literal."""
    offenders = {}
    for fn in sorted(os.listdir(PAGES_DIR)):
        if not fn.endswith(".py"):
            continue
        bad = [s for s in _visible_strings(os.path.join(PAGES_DIR, fn))
               if _ABBREV.search(s)]
        if bad:
            offenders[fn] = bad
    assert not offenders, f"abbreviated output-directory text left on a page: {offenders}"


def test_the_cloud_plan_preview_agrees_with_the_field_it_describes():
    """cloud_deploy.preview() is rendered INTO DeployPage (deploy.py, plan_view), so its
    text is on the same screen as the row this PR renamed. It stays column-aligned — the
    keys pad to 12 and the sibling key is "keys dir:" — but it must not say "out dir"
    while the field above it says "Output directory"."""
    src = open(os.path.join(GENERATOR_DIR, "studio", "hugmesh_studio", "core",
                            "cloud_deploy.py"), encoding="utf-8").read()
    assert "out dir:" not in src, \
        "the plan preview still labels the field 'out dir:' under a renamed row"
    assert "into the out dir" not in src, \
        "the plan preview's numbered steps still abbreviate the output directory"
