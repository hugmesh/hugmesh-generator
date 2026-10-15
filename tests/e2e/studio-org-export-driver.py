#!/usr/bin/env python3
"""studio-org-export-driver.py — walk the REAL Studio wizards offscreen through the
Go-Live "Export to GitHub org" feature and report what they SHOWED and what the
stand-in GitHub RECEIVED.

WHY A THIRD DRIVER. studio-driver.py jumps to a page and grabs it;
studio-code-folders-driver.py walks the local-mesh wizard to one block. The export
feature spans two wizards — the org is typed on the local-mesh Domains step and
saved with the mesh, and the Go-Live wizard exports it — and its design choices
are only worth anything when the real wizards are walked, the real buttons pressed,
and the result is read from the bare repositories, the fake ``gh``'s log and the
``git`` shim's log rather than from the Studio's own say-so.

THE SCENARIOS (``--scenario``)
  no-org       the Go-Live wizard walked from its first page with NO saved mesh
               naming an org: the export step must not appear.
  domains-org  the local-mesh wizard walked to its Domains step; ``--org`` is TYPED
               into the own row's GitHub org cell (no focus change: the Next
               shortcut never moves focus), ``--added-org`` goes on an added row,
               Next is pressed. When Next accepts, the bring-up's configuration is
               recorded as a saved mesh (what 'Save mesh' captures from a running
               mesh: its ``boot.cfg`` is this very ``collect_bootstrap()``), a FRESH
               wizard is walked to the same step, the record is loaded through the
               Saved meshes widget's real 'Load into the form' button, and the
               cells, the state and the next record are read again.
  export       the Go-Live wizard walked from its first page with a saved mesh that
               names the org (the record ``studio/tests/_org_export_helpers`` makes
               over its fake generator checkout and source repositories); on the
               export step ``--action`` presses Plan, then Apply without the typed
               org name, or Apply with it. ``--plant-marker REPO`` first commits a
               fake fine-grained token into that source repository;
               ``--rename-map exclusions`` points the page's Rename map field at a
               file excluding that planted path; ``--own-services phpbb`` puts that
               selection on the saved mesh's own domain ROW and ``--mesh-services
               phpbb`` on the mesh-wide Services step (what the mesh actually runs;
               either way its profile's repository must then be on the plan);
               ``--preexisting TARGET:BRANCH`` plants somebody else's commit on
               BRANCH of the stand-in's TARGET repository before the walk (apply
               must refuse it and leave it untouched); ``--terminal-line`` RUNS
               the Terminal line the step showed before Plan, as a person would
               paste it, and reports the repositories that line plans.

WHAT IS REAL AND WHAT IS A STAND-IN
  real      : StudioWizard and GoLiveWizard, every page in between, the Domains
              table, the Saved meshes widget and its Load button, the export page
              and its worker, the engine (core/org_export) with its REAL
              SubprocessRunner, the real ``git`` (through a logging shim), the
              device driver specs/usr/sbin/hugmesh-go-live for the Go-Live
              wizard's status / providers (against a scratch GL_ETC_HUGMESH).
  stand-in  : GitHub. A folder of bare repositories is the organisation; ``gh``
              is the fake from the test helpers (answers ``repo view`` /
              ``repo create`` from that folder and logs every call); the export
              page's remote base is that folder (``file://``, the engine's
              documented offline-rehearsal seam — the CLI's ``--remote-base``).
              ``git`` on PATH is a one-line shim that appends its arguments to a
              log and execs the real git, so "never --force" is read from what
              git was actually asked to do.
  pinned    : the host description (a Gentoo box, no docker), the Studio state
              dir (scratch: the operator's saved meshes are never read or
              written), the git identity of "the person running the export".

CONTRACT WITH THE NODE SIDE (steps/studio-org-export.steps.ts)
  * the LAST line of stdout is one JSON object; diagnostics go to stderr;
  * success: {"ok": true, ...facts...}; failure: {"ok": false, "error": ...}, exit != 0.

EXIT CODES  0 ok · 2 bad usage · 3 no Qt binding · 4 the walk or a press failed ·
            5 no grab written

*** STARTS NOTHING. *** No mesh, no build, no elevation, no network: every path it
writes is under --scratch; the generator checkout under test is only read.
"""
from __future__ import annotations

import argparse
import codecs
import json
import os
import shutil
import stat
import subprocess
import sys
import time
import traceback

OWN_ORG_DEFAULT = "exampleorg"
ADDED_DOMAIN = "chat.example"
PLANTED_PATH = "tests/fake-token.sh"
RUNNER_IDENTITY = ("Test Exporter", "exporter@example.invalid")


def _exit_now(code: int) -> None:
    # A page may own a running QThread; Qt aborts the process if one is alive at
    # teardown (see studio-driver.py:_exit_now). The result is already printed.
    sys.stdout.flush()
    sys.stderr.flush()
    os._exit(code)


def _fail(code: int, message: str) -> None:
    print(json.dumps({"ok": False, "error": message}))
    print(message, file=sys.stderr)
    _exit_now(code)


def _write_git_shim(bindir: str, log: str) -> None:
    """A ``git`` first on PATH that logs its argument vector and execs the real one."""
    real = shutil.which("git")
    if not real:
        _fail(2, "no git on PATH")
    script = os.path.join(bindir, "git")
    with open(script, "w", encoding="utf-8") as fh:
        fh.write("#!/bin/sh\n"
                 f"printf '%s\\n' \"$*\" >> \"{log}\"\n"
                 f"exec \"{real}\" \"$@\"\n")
    os.chmod(script, os.stat(script).st_mode | stat.S_IXUSR)


def _lines(path: str) -> list:
    try:
        with open(path, encoding="utf-8") as fh:
            return [ln.rstrip("\n") for ln in fh if ln.strip()]
    except OSError:
        return []


def _dialogs(app, wiz) -> list:
    from hugmesh_studio.gui.qt import QtWidgets
    return [type(w).__name__ for w in QtWidgets.QApplication.topLevelWidgets()
            if w.isVisible() and w is not wiz
            and isinstance(w, (QtWidgets.QDialog, QtWidgets.QMessageBox))]


def _grab(wiz, dest: str, result: dict, page: str) -> None:
    pix = wiz.grab()
    dest = os.path.abspath(dest)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    if not pix.save(dest, "PNG") or not os.path.getsize(dest):
        _fail(5, "no grab written to %s" % dest)
    result.update({"png": dest, "bytes": os.path.getsize(dest), "width": pix.width(),
                   "height": pix.height(), "page": page, "binding": "unknown"})


def _wait_worker(page, app, timeout: float = 240.0) -> None:
    t0 = time.monotonic()
    while page.worker is not None and page.worker.isRunning():
        app.processEvents()
        time.sleep(0.02)
        if time.monotonic() - t0 > timeout:
            _fail(4, "the export worker did not finish within %ss" % timeout)
    for _ in range(30):                           # deliver the queued done/progress signals
        app.processEvents()


# ── the Go-Live wizard, walked from its first page ───────────────────────────────
def _walk_golive_to_after_generate(wiz, app, domain: str):
    """Preflight -> Exposure -> Provider -> Inputs -> Generate, as a person does it,
    then ONE more Next. Returns the page slugs seen, ending with the page after
    Generate (the export step when it applies, Verify otherwise)."""
    from hugmesh_studio.gui.pages import golive as gl
    ids = {v: k for k, v in wiz._page_ids.items()}
    seen = [ids.get(wiz.currentId(), "?")]
    if not isinstance(wiz.currentPage(), gl.GoLivePreflightPage):
        _fail(4, "the Go-Live wizard did not start on Preflight but on %s" % seen[0])

    def step(expect_cls):
        before = wiz.currentId()
        wiz.next()
        app.processEvents()
        if wiz.currentId() == before:
            _fail(4, "Next refused on %s" % type(wiz.currentPage()).__name__)
        seen.append(ids.get(wiz.currentId(), "?"))
        if expect_cls is not None and not isinstance(wiz.currentPage(), expect_cls):
            _fail(4, "expected %s after Next, got %s"
                     % (expect_cls.__name__, type(wiz.currentPage()).__name__))
        return wiz.currentPage()

    step(gl.GoLiveExposurePage)                   # the first exposure card is checked
    step(gl.GoLiveProviderPage)                   # row 0 of the registry's providers
    inputs = step(gl.GoLiveInputsPage)
    if not inputs.domain.text().strip():
        inputs.domain.setText(domain)
    step(gl.GoLiveGeneratePage)
    step(None)                                    # the one that may or may not be the export
    return seen


def scenario_no_org(args, app, result: dict) -> None:
    from hugmesh_studio.gui.pages import golive as gl
    wiz = gl.GoLiveWizard(args.generator_dir)
    wiz.resize(1040, 706)
    wiz.show()
    app.processEvents()
    export_id = wiz._page_ids["org-export"]
    page = wiz.page(export_id)
    seen = _walk_golive_to_after_generate(wiz, app, "mesh.example")
    result.update({
        "pagesSeen": seen,
        "exportStepApplies": bool(page.applies()),
        "pageAfterGenerate": seen[-1],
        "exportStepId": export_id, "verifyStepId": wiz._page_ids["verify"],
        "savedMeshCandidates": [],
        "dialogsOpen": _dialogs(app, wiz),
    })
    if args.grab:
        _grab(wiz, args.grab, result, "golive")


# ── the local-mesh Domains step: type, Next, save, re-open ───────────────────────
def _walk_localmesh_to_domains(app, generator_dir: str):
    from hugmesh_studio.core.platform_info import HostInfo
    from hugmesh_studio.gui import wizard as wizard_mod
    from hugmesh_studio.gui.pages import localmesh as lm
    wizard_mod.detect = lambda builder_image="hugmesh-builder": HostInfo(
        os="linux", is_gentoo=True, has_docker=False, has_bash=True,
        has_kvm=False, is_root=False, builder_image="hugmesh-builder")
    wiz = wizard_mod.StudioWizard(generator_dir)
    wiz.resize(1040, 706)
    wiz.show()
    app.processEvents()
    wiz.next()
    mode = wiz.currentPage()
    mode._buttons["localmesh"].setChecked(True)
    mode._on_mode_toggled()
    wiz.next()
    wiz.currentPage()._buttons["generate"].setChecked(True)
    wiz.next()
    ctl = wiz.localmesh_page
    for _ in range(14):
        if isinstance(wiz.currentPage(), lm.LocalMeshDomainsPage):
            break
        before = wiz.currentId()
        wiz.next()
        app.processEvents()
        if wiz.currentId() == before:
            _fail(4, "the wizard stuck on %s on the way to the Domains step"
                     % type(wiz.currentPage()).__name__)
    else:
        _fail(4, "never reached the Domains step")
    return wiz, ctl


def _record_rows(ctl) -> list:
    return [{"name": r["name"], "org": r.get("github_org")}
            for r in ctl.collect_bootstrap().domains]


def scenario_domains_org(args, app, result: dict) -> None:
    from hugmesh_studio.core import org_export as oe
    from hugmesh_studio.core import saved_meshes
    from hugmesh_studio.gui.pages.domains import _COL_ORG
    wiz, ctl = _walk_localmesh_to_domains(app, args.generator_dir)
    md = ctl.mesh_domains
    own = md.own_name
    table = ctl.domains_table
    if not table.is_own_row(0):
        _fail(4, "row 0 of the Domains table is not the own row")
    cell = table.table.cellWidget(0, _COL_ORG)
    cell.setText(args.org)                       # TYPED; no editingFinished, no focus move
    if args.added_org:
        table._add(ADDED_DOMAIN, "Chat", github_org=args.added_org)
    app.processEvents()
    typed = {"ownCell": table.own_row_github_org(), "stateOwnOrgBeforeNext": md.by_name(own).github_org}
    before = wiz.currentId()
    wiz.next()                                   # the real Next
    app.processEvents()
    accepted = wiz.currentId() != before
    result.update({
        "ownDomain": own, "typed": typed, "nextAccepted": accepted,
        "noteVisible": ctl.domains_note.isVisible(), "noteText": ctl.domains_note.text(),
        "stateOwnOrgAfterNext": ctl.mesh_domains.by_name(own).github_org,
        "stateAddedOrgAfterNext": (ctl.mesh_domains.by_name(ADDED_DOMAIN).github_org
                                   if ctl.mesh_domains.by_name(ADDED_DOMAIN) else None),
        "recordRowsAfterNext": _record_rows(ctl),
        "dialogsOpen": _dialogs(app, wiz),
    })
    if args.grab:
        _grab(wiz, args.grab, result, "localmesh")
    if not accepted:
        return
    # 'Save mesh' records boot.cfg, which the bring-up sets from this very
    # collect_bootstrap(); no mesh runs here, so the record is built from it directly
    rec = saved_meshes.SavedMesh(id="20260101-000000-e2e0", label="e2e mesh",
                                 generator_dir=args.generator_dir)
    rec.config = ctl.collect_bootstrap().to_dict()
    path = saved_meshes.save(rec)
    if not path:
        _fail(4, "the saved-mesh record could not be written")
    result["savedRecordOrgs"] = [{"name": r["name"], "org": r.get("github_org")}
                                 for r in rec.config.get("domains") or ()]
    result["savedMeshCandidates"] = [[c.domain, c.org] for c in oe.saved_mesh_candidates()]
    wiz.close()
    # a FRESH wizard, as on another day: load the record through the real button
    wiz2, ctl2 = _walk_localmesh_to_domains(app, args.generator_dir)
    sm = ctl2.saved_meshes
    sm.refresh()
    app.processEvents()
    at = next((i for i, r in enumerate(sm._rows) if r.rec is not None and r.rec.id == rec.id), -1)
    if at < 0:
        _fail(4, "the Saved meshes table does not list the record just saved")
    sm.table.selectRow(at)
    app.processEvents()
    if not sm.load_btn.isEnabled():
        _fail(4, "Load into the form is disabled for the saved record: %s" % sm.load_btn.toolTip())
    sm.load_btn.click()
    app.processEvents()
    t2 = ctl2.domains_table
    rows = [{"name": t2.table.item(r, 0).text().strip() if t2.table.item(r, 0) else "",
             "org": t2.row_github_org(r), "own": t2.is_own_row(r)}
            for r in range(t2.table.rowCount())]
    result["reopen"] = {
        "note": sm.note.text() if hasattr(sm, "note") else "",
        "rows": rows,
        "ownCell": t2.own_row_github_org(),
        "stateOwnOrg": ctl2.mesh_domains.by_name(ctl2.mesh_domains.own_name).github_org,
    }
    if args.grab:
        # the picture a person would check: the re-opened Domains table with the
        # org back in its cell, BEFORE Next moves on to the services page
        _grab(wiz2, args.grab, result, "localmesh")
    before = wiz2.currentId()
    wiz2.next()
    app.processEvents()
    result["reopen"]["nextAccepted"] = wiz2.currentId() != before
    result["reopen"]["recordRowsAfterNext"] = _record_rows(ctl2)
    result["dialogsOpen"] = _dialogs(app, wiz2)


# ── the export step over the stand-in GitHub ─────────────────────────────────────
def scenario_export(args, app, result: dict, scratch: str, bindir: str, git_log: str) -> None:
    import pathlib
    from _org_export_helpers import FAKE_GH, bare_log, git as fixture_git, make_world, \
        saved_mesh_naming_the_org
    from hugmesh_studio.gui.pages import golive as gl
    world = make_world(pathlib.Path(scratch) / "world")
    # the fake gh first on PATH (the helper's world put it beside its own runner;
    # here the engine's REAL runner finds it by PATH), answering from the bare repos
    gh = os.path.join(bindir, "gh")
    with open(gh, "w", encoding="utf-8") as fh:
        fh.write(FAKE_GH)
    os.chmod(gh, os.stat(gh).st_mode | stat.S_IXUSR)
    os.environ["FAKE_GH_ROOT"] = world["gh_root"]
    os.environ["FAKE_GH_LOG"] = os.path.join(scratch, "gh.log")
    if args.plant_marker:
        src = os.path.join(world["src"], args.plant_marker)
        if not os.path.isdir(src):
            _fail(2, "no source repository %s to plant a marker in" % args.plant_marker)
        os.makedirs(os.path.join(src, os.path.dirname(PLANTED_PATH)), exist_ok=True)
        token = "github_pat_" + "11FAKE" + "A" * 30       # the shape, never a real one
        with open(os.path.join(src, PLANTED_PATH), "w", encoding="utf-8") as fh:
            fh.write("TOKEN=%s\n" % token)
        fixture_git(src, "add", "-A")
        fixture_git(src, "-c", "commit.gpgsign=false", "commit", "-q", "-m", "plant a marker")
    preexisting_bare = ""
    if args.preexisting:
        # somebody else's repository already under the org, its content on BRANCH
        # (master by default) and no main at all — the shape that used to pass as
        # empty, so apply pushed a new main into it
        target, _, branch = args.preexisting.partition(":")
        branch = branch or "master"
        preexisting_bare = os.path.join(world["gh_root"], OWN_ORG_DEFAULT, target + ".git")
        os.makedirs(os.path.dirname(preexisting_bare), exist_ok=True)
        fixture_git(world["gh_root"], "init", "-q", "--bare", "-b", branch, preexisting_bare)
        theirs = os.path.join(scratch, "theirs")
        os.makedirs(theirs)
        with open(os.path.join(theirs, "README.md"), "w", encoding="utf-8") as fh:
            fh.write("somebody else's content, on %s\n" % branch)
        fixture_git(theirs, "init", "-q", "-b", branch)
        fixture_git(theirs, "add", "-A")
        fixture_git(theirs, "-c", "commit.gpgsign=false", "commit", "-q", "-m", "theirs")
        fixture_git(theirs, "push", "-q", preexisting_bare, "HEAD:refs/heads/" + branch)
        result["preexisting"] = {
            "target": "%s/%s" % (OWN_ORG_DEFAULT, target), "branch": branch,
            "refsBefore": _refs(fixture_git, preexisting_bare),
            "shaBefore": fixture_git(preexisting_bare, "rev-parse", branch)}
    for spec in args.plant_file:
        # REPO:PATH=CONTENT (escapes decoded): a file committed into a source repository
        where, _, content = spec.partition("=")
        repo, _, rel = where.partition(":")
        src = os.path.join(world["src"], repo)
        if not (repo and rel and os.path.isdir(src)):
            _fail(2, "--plant-file %r names no source repository" % spec)
        full = os.path.join(src, rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w", encoding="utf-8") as fh:
            fh.write(codecs.decode(content, "unicode_escape"))
        fixture_git(src, "add", "-A", "-f")
        fixture_git(src, "-c", "commit.gpgsign=false", "commit", "-q", "-m", "plant a file")
        if os.path.exists(os.path.join(src, ".git", "refs", "remotes", "origin", "main")):
            # a checkout with an origin exports origin/main, not the local branch
            fixture_git(src, "update-ref", "refs/remotes/origin/main", "HEAD")
    for spec in args.plant_bytes:
        where, _, hexdata = spec.partition("=")
        repo, _, rel = where.partition(":")
        src = os.path.join(world["src"], repo)
        if not (repo and rel and os.path.isdir(src)):
            _fail(2, "--plant-bytes %r names no source repository" % spec)
        full = os.path.join(src, rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "wb") as fh:
            fh.write(bytes.fromhex(hexdata))
        fixture_git(src, "add", "-A", "-f")
        fixture_git(src, "-c", "commit.gpgsign=false", "commit", "-q", "-m", "plant bytes")
        if os.path.exists(os.path.join(src, ".git", "refs", "remotes", "origin", "main")):
            fixture_git(src, "update-ref", "refs/remotes/origin/main", "HEAD")
    if args.global_excludes:
        # AFTER the plants (they force-add): from here on every git this run starts,
        # the export's included, reads the person's own global ignore file
        excl = os.path.join(scratch, "global-excludes")
        with open(excl, "w", encoding="utf-8") as fh:
            fh.write("\n".join(g for g in args.global_excludes.split(",") if g) + "\n")
        gcfg = os.path.join(scratch, "global-gitconfig")
        with open(gcfg, "w", encoding="utf-8") as fh:
            fh.write("[core]\n\texcludesFile = %s\n" % excl)
        os.environ["GIT_CONFIG_GLOBAL"] = gcfg
    saved_mesh_naming_the_org(world, label="e2e mesh",
                              services=[s for s in args.own_services.split(",") if s],
                              mesh_services=[s for s in args.mesh_services.split(",") if s])
    result["ownServices"] = [s for s in args.own_services.split(",") if s]
    result["meshServices"] = [s for s in args.mesh_services.split(",") if s]
    # the git shim logged the set-up above too: the walk's own calls start here
    result["gitCallsAtWalkStart"] = len(_lines(git_log))
    wiz = gl.GoLiveWizard(args.generator_dir)
    wiz.export_remote_base = "file://%s/" % world["gh_root"]    # the offline rehearsal seam
    wiz.resize(1040, 706)
    wiz.show()
    app.processEvents()
    seen = _walk_golive_to_after_generate(wiz, app, "mesh.example")
    page = wiz.currentPage()
    if not isinstance(page, gl.GoLiveOrgExportPage):
        _fail(4, "the export step did not appear after Generate; pages: %s" % seen)
    result.update({"pagesSeen": seen, "exportStepApplies": True,
                   "candidates": [page.source.itemText(i) for i in range(page.source.count())],
                   "sourceFolder": page.source_dir.text(), "worldSrc": world["src"]})
    page.out_dir.setText(os.path.join(scratch, "out"))
    sentinel = os.path.join(scratch, "escape", "precious.txt")
    if args.rename_map == "bad-target":
        # a rename that would send a repository's folder OUT of the work directory
        # (<scratch>/out/work/../../escape): the sentinel is what it would destroy
        os.makedirs(os.path.dirname(sentinel))
        with open(sentinel, "w", encoding="utf-8") as fh:
            fh.write("keep\n")
        rm = os.path.join(scratch, "bad-target.json")
        with open(rm, "w", encoding="utf-8") as fh:
            json.dump({"repos": {"hugmesh-commons": "../../escape"}}, fh)
        page.rename_map.setText(rm)
        page.rename_map.editingFinished.emit()
    if args.rename_map == "exclusions":
        rm = os.path.join(scratch, "exclusions.json")
        with open(rm, "w", encoding="utf-8") as fh:
            json.dump({"exclude": ["%s:%s" % (args.plant_marker or "hugmesh-commons",
                                               PLANTED_PATH)]}, fh)
        page.rename_map.setText(rm)
        page.rename_map.editingFinished.emit()
        result["renameMapField"] = {"text": page.rename_map.text(),
                                    "visible": page.rename_map.isVisible(),
                                    "width": page.rename_map.width()}
    if args.bad_config:
        key, _, raw = args.bad_config.partition("=")
        bad = world["cfg"].to_dict()
        bad[key] = json.loads(raw)
        bad_path = os.path.join(scratch, "bad-config.json")
        with open(bad_path, "w", encoding="utf-8") as fh:
            json.dump(bad, fh)
        before = page.source.count()
        page.config_path.setText(bad_path)
        page.add_btn.click()                         # the step's own "add" button
        app.processEvents()
        status_text, status_shown = page.status.text(), not page.status.isHidden()
        cli_args = ["--generator-dir", args.generator_dir, "--config", bad_path,
                    "--org-export", "APPLY", "--apply", "--no-probe"]
        proc = subprocess.run([sys.executable, "-m", "hugmesh_studio", *cli_args],
                              cwd=os.path.join(args.generator_dir, "studio"),
                              capture_output=True, text=True, timeout=300,
                              env=dict(os.environ), check=False)
        org_dir_now = os.path.join(world["gh_root"], OWN_ORG_DEFAULT)
        result["badConfig"] = {
            "key": key, "candidatesBefore": before, "candidatesAfter": page.source.count(),
            "statusShown": status_shown, "statusText": status_text,
            "cliRc": proc.returncode, "cliStderr": proc.stderr[-1500:],
            "cliTraceback": "Traceback" in proc.stderr,
            "reposAfterCli": sorted(os.listdir(org_dir_now)) if os.path.isdir(org_dir_now) else []}
    gh_calls_before = len(_lines(os.environ["FAKE_GH_LOG"]))
    # the Terminal line as shown BEFORE Plan (the PLAN form; after Plan it is the
    # APPLY form): what a person would copy to run the same export themselves
    result["terminalLineBeforePlan"] = page.cmd.text()
    if args.action == "flip-visibility":
        page.visibility.setCurrentText("public")          # planned as PUBLIC first
    page.plan_btn.click()
    _wait_worker(page, app)
    plan = page.plan
    result["planStatus"] = page.status.text()
    result["planFailed"] = plan is None
    result["terminalLineAfterPlan"] = page.cmd.text()
    if plan is None:
        org_dir = os.path.join(world["gh_root"], OWN_ORG_DEFAULT)
        result["ghCalls"] = _lines(os.environ["FAKE_GH_LOG"])
        result["bareReposAfterPlan"] = sorted(os.listdir(org_dir)) if os.path.isdir(org_dir) else []
        result["workFolders"] = sorted(os.listdir(os.path.join(scratch, "out", "work"))) \
            if os.path.isdir(os.path.join(scratch, "out", "work")) else []
        result["sentinel"] = (open(sentinel, encoding="utf-8").read()
                              if os.path.isfile(sentinel) else None)
        result["escapeFolder"] = sorted(os.listdir(os.path.dirname(sentinel))) \
            if os.path.isdir(os.path.dirname(sentinel)) else None
        result["dialogsOpen"] = _dialogs(app, wiz)
        if args.grab:
            _grab(wiz, args.grab, result, "golive")
        return
    rows = [*plan.repos, plan.site]
    result["planRows"] = [{"source": r.source, "target": r.target_full, "action": r.action,
                           "blocked": r.blocked, "banned": list(r.banned),
                           "excluded": list(r.excluded), "notes": list(r.notes),
                           "files": r.files,
                           "ref": r.ref, "commit": r.source_commit} for r in rows]
    result["planBlocked"] = [r.source for r in plan.blocked]
    result["tableActions"] = [page.table.item(r, 2).text() for r in range(page.table.rowCount())]
    result["tableTooltips"] = [page.table.item(r, 2).toolTip() for r in range(page.table.rowCount())]
    result["planText"] = page.plan_text.toPlainText()
    result["ghCallsDuringPlan"] = _lines(os.environ["FAKE_GH_LOG"])[gh_calls_before:]
    result["gitCallsDuringPlan"] = _lines(git_log)
    org_dir = os.path.join(world["gh_root"], plan.config.org)
    result["bareReposAfterPlan"] = sorted(os.listdir(org_dir)) if os.path.isdir(org_dir) else []
    result["applyEnabledBeforeTyping"] = page.apply_btn.isEnabled()
    page.confirm.setText("nope")
    app.processEvents()
    result["applyEnabledWrongName"] = page.apply_btn.isEnabled()
    page.confirm.setText(plan.config.org)
    app.processEvents()
    result["applyEnabledTyped"] = page.apply_btn.isEnabled()
    # the same name in another letter case arms too (slugs are case-insensitive)
    page.confirm.setText(plan.config.org.swapcase())
    app.processEvents()
    result["applyEnabledOtherCase"] = page.apply_btn.isEnabled()
    page.confirm.setText(plan.config.org)
    app.processEvents()
    if args.action == "plan":
        page.confirm.setText("")
    elif args.action == "apply-untyped":
        page.confirm.setText("")
        app.processEvents()
        result["applyEnabledUntyped"] = page.apply_btn.isEnabled()
        page.apply_btn.click()                   # a disabled button ignores this, as in the app
        page._apply()                            # and the slot itself refuses inline
        app.processEvents()
        result["applyStatus"] = page.status.text()
        result["resultAfter"] = page.result is not None
    elif args.action == "retype-after-flip":
        # planned PRIVATE (the default), the name typed and Apply armed; now the picker
        # goes to PUBLIC and Plan is pressed again: the name typed for the private plan
        # must not arm the public one
        rt = {"planVisibility": plan.config.visibility,
              "applyEnabledBeforeFlip": page.apply_btn.isEnabled()}
        page.visibility.setCurrentText("public")
        app.processEvents()
        rt["confirmTextAfterFlip"] = page.confirm.text()
        rt["applyEnabledAfterFlip"] = page.apply_btn.isEnabled()
        page.plan_btn.click()
        _wait_worker(page, app)
        rt["replanVisibility"] = page.plan.config.visibility if page.plan else None
        rt["confirmTextAfterReplan"] = page.confirm.text()
        rt["applyEnabledAfterReplan"] = page.apply_btn.isEnabled()
        page.apply_btn.click()                            # disabled: ignored, as in the app
        page._apply()                                     # and the slot refuses inline
        _wait_worker(page, app)
        rt["createCallsAfterUnretypedApply"] = [c for c in _lines(os.environ["FAKE_GH_LOG"])
                                                if c.startswith("repo create")]
        page.confirm.setText(plan.config.org)
        app.processEvents()
        rt["applyEnabledAfterRetype"] = page.apply_btn.isEnabled()
        result["retype"] = rt
    elif args.action == "flip-visibility":
        # the picker flipped back to private AFTER a public Plan armed Apply: the
        # plan on screen must be gone, so there is nothing for Apply to run
        flip = {"planVisibility": plan.config.visibility,
                "applyEnabledBeforeFlip": page.apply_btn.isEnabled()}
        page.visibility.setCurrentText("private")
        app.processEvents()
        flip.update({"pickerReads": page.visibility.currentText(),
                     "planKept": page.plan is not None,
                     "applyEnabledAfterFlip": page.apply_btn.isEnabled(),
                     "tableRowsAfterFlip": page.table.rowCount(),
                     "terminalLineAfterFlip": page.cmd.text()})
        page.confirm.setText(plan.config.org)             # the name typed, as a person would
        app.processEvents()
        flip["applyEnabledTypedAfterFlip"] = page.apply_btn.isEnabled()
        page.apply_btn.click()                            # disabled: ignored, as in the app
        page._apply()                                     # and the slot refuses with no plan
        _wait_worker(page, app)
        flip["createCallsAfterStaleApply"] = [c for c in _lines(os.environ["FAKE_GH_LOG"])
                                              if c.startswith("repo create")]
        flip["bareReposAfterStaleApply"] = (sorted(os.listdir(org_dir))
                                            if os.path.isdir(org_dir) else [])
        # a FRESH plan under what the screen shows, then Apply: private, as the picker says
        page.plan_btn.click()
        _wait_worker(page, app)
        flip["freshPlanVisibility"] = page.plan.config.visibility if page.plan else None
        page.confirm.setText(plan.config.org)
        app.processEvents()
        flip["applyEnabledAfterFreshPlan"] = page.apply_btn.isEnabled()
        page.apply_btn.click()
        _wait_worker(page, app)
        flip["createCallsAfterFreshApply"] = [c for c in _lines(os.environ["FAKE_GH_LOG"])
                                              if c.startswith("repo create")]
        result["flip"] = flip
    elif args.action == "apply":
        if not page.apply_btn.isEnabled():
            _fail(4, "Apply did not arm with the org name typed: %s" % page.status.text())
        page.apply_btn.click()
        _wait_worker(page, app)
        res = page.result
        result["applyStatus"] = page.status.text()
        result["resultRows"] = ([{"target": r.target, "action": r.action, "branch": r.branch,
                                  "commit": r.commit, "skipped": r.skipped} for r in res.repos]
                                if res is not None else None)
        result["tableResults"] = [page.table.item(r, 7).text() if page.table.item(r, 7) else ""
                                  for r in range(page.table.rowCount())]
        result["applyEnabledAfter"] = page.apply_btn.isEnabled()
    result["ghCalls"] = _lines(os.environ["FAKE_GH_LOG"])
    result["gitCalls"] = _lines(git_log)
    bare = {}
    if os.path.isdir(org_dir):
        for name in sorted(os.listdir(org_dir)):
            target = name[:-4] if name.endswith(".git") else name
            try:
                log = bare_log(world, target)
            except AssertionError:
                log = []
            bare[target] = {"commits": len(log), "log": log}
            try:
                bare[target]["files"] = fixture_git(
                    os.path.join(org_dir, name), "ls-tree", "-r", "--name-only",
                    "main").splitlines()
            except AssertionError:
                bare[target]["files"] = []
    result["bareRepos"] = bare
    # file contents read straight out of the stand-in GitHub's main (TARGET:PATH)
    result["bareFiles"] = {}
    for spec in args.read_file:
        target, _, rel = spec.partition(":")
        try:
            result["bareFiles"][spec] = fixture_git(
                os.path.join(org_dir, target + ".git"), "show", "main:" + rel)
        except AssertionError:
            result["bareFiles"][spec] = None
    if preexisting_bare:
        result["preexisting"]["refsAfter"] = _refs(fixture_git, preexisting_bare)
        result["preexisting"]["shaAfter"] = fixture_git(
            preexisting_bare, "rev-parse", result["preexisting"]["branch"])
    result["dialogsOpen"] = _dialogs(app, wiz)
    if args.terminal_line:
        # last, so every log read above is the WIZARD's own doing
        result["terminalPlan"] = _run_terminal_line(result["terminalLineBeforePlan"],
                                                    args.generator_dir)
    if args.grab:
        _grab(wiz, args.grab, result, "golive")


def _run_terminal_line(line: str, generator_dir: str) -> dict:
    """Run the PLAN line the export step showed, as a person would paste it: the same
    words, with the interpreter this driver runs under in place of the bare
    ``python3`` (so the environment that has the Studio is the one that runs it),
    from studio/ so ``-m hugmesh_studio`` resolves. PATH still leads with the fake
    gh and the git shim. Reports the CLI's exit code and the targets of the plan
    table it printed — read off its stdout, never off the wizard."""
    import re
    import shlex
    words = shlex.split(line)
    if words[:3] != ["python3", "-m", "hugmesh_studio"]:
        _fail(4, "the Terminal line does not start with python3 -m hugmesh_studio: %r" % line)
    gh_before = len(_lines(os.environ["FAKE_GH_LOG"]))
    t0 = time.monotonic()
    proc = subprocess.run([sys.executable, "-m", "hugmesh_studio", *words[3:]],
                          cwd=os.path.join(generator_dir, "studio"), capture_output=True,
                          text=True, timeout=300, env=dict(os.environ), check=False)
    # a plan-table row is "<source>  <org>/<name>  <action> ..." (plan_lines); nothing
    # else the CLI prints has a slash in its second word at column zero
    targets = re.findall(r"^\S+\s+(\S+/\S+)\s", proc.stdout, re.M)
    return {"interpreter": sys.executable, "argv": words[3:], "rc": proc.returncode,
            "seconds": round(time.monotonic() - t0, 1), "targets": targets,
            "stdoutTail": proc.stdout[-1500:], "stderrTail": proc.stderr[-1500:],
            "ghCalls": _lines(os.environ["FAKE_GH_LOG"])[gh_before:]}


def _refs(fixture_git, bare: str) -> list:
    return sorted(fixture_git(bare, "for-each-ref", "--format=%(refname)").splitlines())


def main(argv: "list[str]") -> int:
    ap = argparse.ArgumentParser(description="offscreen Studio org-export driver")
    ap.add_argument("--generator-dir", default=os.path.dirname(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
    ap.add_argument("--scratch", required=True, help="a directory this driver may write")
    ap.add_argument("--grab", help="PNG destination for a grab of the wizard")
    ap.add_argument("--scenario", required=True, choices=("no-org", "domains-org", "export"))
    ap.add_argument("--org", default=OWN_ORG_DEFAULT, help="domains-org: the own row's org")
    ap.add_argument("--added-org", default="", help="domains-org: an added row's org")
    ap.add_argument("--action", choices=("plan", "apply-untyped", "apply", "flip-visibility",
                                         "retype-after-flip"),
                    default="plan")
    ap.add_argument("--plant-bytes", action="append", default=[], metavar="REPO:PATH=HEX",
                    help="export: commit a file of these raw bytes (hex) into a source "
                         "repository first (a latin-1 file, a binary file); repeatable")
    ap.add_argument("--global-excludes", default="", metavar="GLOB[,GLOB]",
                    help="export: give the git this run uses a GLOBAL core.excludesFile "
                         "naming these patterns (every machine may have one)")
    ap.add_argument("--bad-config", default="", metavar="KEY=JSON",
                    help="export: write an export config whose KEY holds this JSON value "
                         "(a wrong type), add it through the step's config-file field, "
                         "and run it through the CLI too")
    ap.add_argument("--plant-marker", default="",
                    help="export: commit a fake token into this source repository first")
    ap.add_argument("--rename-map", choices=("none", "exclusions", "bad-target"),
                    default="none",
                    help="export: point the Rename map field at a file excluding the "
                         "planted path, or one renaming hugmesh-commons to a path "
                         "that leaves the work folder")
    ap.add_argument("--plant-file", action="append", default=[], metavar="REPO:PATH=CONTENT",
                    help="export: commit this file into a source repository first "
                         "(backslash escapes in CONTENT are decoded); repeatable")
    ap.add_argument("--read-file", action="append", default=[], metavar="TARGET:PATH",
                    help="export: after the walk, read PATH from main of the stand-in "
                         "GitHub's TARGET repository; repeatable")
    ap.add_argument("--own-services", default="",
                    help="export: comma-separated optional services selected on the "
                         "saved mesh's own domain ROW")
    ap.add_argument("--mesh-services", default="",
                    help="export: comma-separated services picked on the saved mesh's "
                         "mesh-wide Services step (what the mesh runs)")
    ap.add_argument("--terminal-line", action="store_true",
                    help="export: run the Terminal line the step showed (PLAN form) and "
                         "report the repositories it plans")
    ap.add_argument("--preexisting", default="",
                    help="export: TARGET[:BRANCH] — plant somebody else's commit on that "
                         "branch (default master) of the stand-in's TARGET before the walk")
    args = ap.parse_args(argv)

    generator_dir = os.path.abspath(args.generator_dir)
    args.generator_dir = generator_dir
    studio_root = os.path.join(generator_dir, "studio")
    for p in (studio_root, os.path.join(studio_root, "tests")):
        if p not in sys.path:
            sys.path.insert(0, p)
    scratch = os.path.abspath(args.scratch)
    os.makedirs(scratch, exist_ok=True)
    bindir = os.path.join(scratch, "bin")
    os.makedirs(bindir, exist_ok=True)
    git_log = os.path.join(scratch, "git.log")
    _write_git_shim(bindir, git_log)
    etc = os.path.join(scratch, "etc-hugmesh")
    os.makedirs(etc, exist_ok=True)
    with open(os.path.join(etc, "release-state"), "w", encoding="utf-8") as fh:
        fh.write("internal\n")
    # PINNED: the state dir (never the operator's), the device driver's /etc, the
    # git identity of the person running the export; no ambient token
    os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    os.environ["HUGMESH_STUDIO_STATE_DIR"] = os.path.join(scratch, "state")
    os.environ["GL_ETC_HUGMESH"] = etc
    os.environ["GOLIVE_CLUSTER_DOMAIN_FILE"] = os.path.join(etc, "cluster-domain")
    os.environ["GL_OUT_DIR"] = os.path.join(scratch, "go-live-out")
    os.environ["GIT_AUTHOR_NAME"], os.environ["GIT_AUTHOR_EMAIL"] = RUNNER_IDENTITY
    os.environ["GIT_COMMITTER_NAME"], os.environ["GIT_COMMITTER_EMAIL"] = RUNNER_IDENTITY
    os.environ.pop("GH_TOKEN", None)
    os.environ.pop("GITHUB_TOKEN", None)
    os.environ["PATH"] = bindir + os.pathsep + os.environ.get("PATH", "")

    try:
        from hugmesh_studio.gui.qt import QtWidgets
    except Exception as exc:                       # noqa: BLE001
        _fail(3, "no usable Qt6 binding (%s: %s)" % (type(exc).__name__, exc))
    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])

    result: dict = {"ok": True, "scenario": args.scenario, "scratch": scratch}
    try:
        if args.scenario == "no-org":
            scenario_no_org(args, app, result)
        elif args.scenario == "domains-org":
            scenario_domains_org(args, app, result)
        else:
            scenario_export(args, app, result, scratch, bindir, git_log)
    except SystemExit:
        raise
    except Exception as exc:                       # noqa: BLE001
        traceback.print_exc(file=sys.stderr)
        _fail(4, "%s: %s" % (type(exc).__name__, exc))
    print(json.dumps(result))
    _exit_now(0)
    return 0                                       # pragma: no cover


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
