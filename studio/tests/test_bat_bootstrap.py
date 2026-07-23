"""The Windows bootstrap .bat — always-on Linux-side checks (no qemu, no Windows).

``hugmesh-studio.bat`` is now a guided bootstrapper (detect / consent-gated winget
installs / venv / launch). It cannot execute on Linux, but nearly all of its failure
modes are TEXTUAL, so they are provable from the bytes of the file:

  - LF-only line endings silently break cmd's goto/call label scanner   -> test_crlf_strict
  - a typo'd goto/call target dies at runtime                           -> test_goto_call_labels_resolve
  - an unpinned winget ID installs the wrong package                    -> test_winget_ids_pinned
  - an install that skips the consent gate violates the consent rule    -> test_installs_consent_gated
  - piping remote scripts violates the no-remote-execution rule         -> test_no_remote_execution
  - a prompt on the automation path hangs the qemu guest forever        -> test_headless_never_prompts
  - a renamed DETECT facet desyncs the qemu harness assertions          -> test_detect_report_facets
  - a drifted launch line breaks the #345 byte-compatible contract      -> test_launch_contract_byte_exact
  - a drifted Python floor desyncs the README                           -> test_python_floor_matches_readme
  - `if errorlevel 1` after winget misses negative HRESULTs             -> test_winget_failure_checks_are_signed
  - `...%VAR%>> file` eats the expanded digit on REAL cmd.exe           -> test_no_digit_eating_redirects

The dark-gated qemu harness (tests/qemu/windows-studio-e2e.sh) is the real-Windows half
of the proof and asserts the SAME pinned vocabulary (DETECT lines, the winget ``set``
lines, the launch line) — one vocabulary, two provers.
"""
import os
import re

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO_ROOT = os.path.dirname(STUDIO_ROOT)
BAT_PATH = os.path.join(STUDIO_ROOT, "hugmesh-studio.bat")
QEMU_E2E_PATH = os.path.join(REPO_ROOT, "tests", "qemu", "windows-studio-e2e.sh")
GITATTRIBUTES_PATH = os.path.join(REPO_ROOT, ".gitattributes")
README_PATH = os.path.join(STUDIO_ROOT, "README.md")

LAUNCH_LINE = "python -m hugmesh_studio %*"
WINGET_PYTHON_PIN = 'set "WINGET_PYTHON_ID=Python.Python.3.12"'
WINGET_DOCKER_PIN = 'set "WINGET_DOCKER_ID=Docker.DockerDesktop"'


def _bat_bytes():
    with open(BAT_PATH, "rb") as fh:
        return fh.read()


def _bat_lines():
    """The .bat as text lines with the CR stripped (CRLF is asserted separately)."""
    return [ln.rstrip("\r") for ln in _bat_bytes().decode("utf-8").split("\n")]


def _is_display(line):
    """True for lines that only SHOW text: blank, REM, echo (incl. ``echo(``), and
    ``if "<cond>"=="<val>" echo …`` guards that carry no goto/call/set-p payload."""
    s = line.strip()
    if not s:
        return True
    if re.match(r"(?i)^@?(rem\b|echo\b|echo\()", s):
        return True
    if (re.match(r"(?i)^if\s", s) and re.search(r"(?i)\becho\b", s)
            and not re.search(r"(?i)\b(goto|call|set)\b", s)):
        return True
    return False


def _labels():
    """Ordered [(line_index, label_name)] of every label definition."""
    out = []
    for i, ln in enumerate(_bat_lines()):
        m = re.match(r"^\s*:([A-Za-z_]\w*)\s*$", ln)
        if m:
            out.append((i, m.group(1).lower()))
    return out


def _block(name):
    """The lines from label ``name`` (exclusive) to the next label (exclusive)."""
    lines, labels = _bat_lines(), _labels()
    for idx, (pos, lbl) in enumerate(labels):
        if lbl == name:
            end = labels[idx + 1][0] if idx + 1 < len(labels) else len(lines)
            return lines[pos + 1:end]
    raise AssertionError("label :%s not found" % name)


def _enclosing_label(line_index):
    cur = None
    for pos, lbl in _labels():
        if pos < line_index:
            cur = lbl
        else:
            break
    return cur


# ── 1. CRLF: cmd's label scanner breaks on LF-only files ──────────────────────────────
def test_crlf_strict():
    data = _bat_bytes()
    assert data, "the .bat is empty"
    assert data.count(b"\n") > 0
    # every \n preceded by \r, and no lone \r: LF count == CRLF count == CR count
    assert data.count(b"\n") == data.count(b"\r\n"), "found LF not preceded by CR"
    assert data.count(b"\r") == data.count(b"\r\n"), "found CR not followed by LF"
    # the .gitattributes rule guards the repo-root `* text=auto eol=lf` default from
    # silently re-normalizing the bootstrapper back to LF on checkout.
    attrs = open(GITATTRIBUTES_PATH, encoding="utf-8").read()
    assert re.search(r"(?m)^\*\.bat\s+text\s+eol=crlf\s*$", attrs), attrs


# ── 2. every goto/call target resolves; no duplicate labels ───────────────────────────
def test_goto_call_labels_resolve():
    label_names = [lbl for _, lbl in _labels()]
    assert len(label_names) == len(set(label_names)), "duplicate labels: %s" % (
        sorted(n for n in set(label_names) if label_names.count(n) > 1))
    targets = set()
    for ln in _bat_lines():
        if _is_display(ln):
            continue
        # goto's colon is optional in cmd; call only targets a label WITH the colon
        # (`call winget …` invokes a program, not a label).
        for m in re.finditer(r"(?i)\bgoto\s+:?([A-Za-z_]\w*)", ln):
            targets.add(m.group(1).lower())
        for m in re.finditer(r"(?i)\bcall\s+:([A-Za-z_]\w*)", ln):
            targets.add(m.group(1).lower())
    targets.discard("eof")          # cmd builtin pseudo-label
    missing = targets - set(label_names)
    assert not missing, "goto/call to undefined labels: %s" % sorted(missing)
    assert targets, "no goto/call targets found at all — wrong file?"


# ── 3. winget IDs are pinned constants; every install references them + --exact ───────
def test_winget_ids_pinned():
    lines = _bat_lines()
    assert any(ln.strip() == WINGET_PYTHON_PIN for ln in lines)
    assert any(ln.strip() == WINGET_DOCKER_PIN for ln in lines)
    for ln in lines:
        if "winget install" not in ln:
            continue
        assert "--exact" in ln, "winget install without --exact: %r" % ln
        assert "%WINGET_PYTHON_ID%" in ln or "%WINGET_DOCKER_ID%" in ln, \
            "winget install not using a pinned ID constant: %r" % ln
    # no other winget-ID-shaped literal (Vendor.Product) anywhere else in the file
    id_re = re.compile(r"\b[A-Z][A-Za-z0-9]*\.[A-Z][A-Za-z0-9]*")
    for ln in lines:
        if ln.strip() in (WINGET_PYTHON_PIN, WINGET_DOCKER_PIN):
            continue
        m = id_re.search(ln)
        assert not m, "unpinned winget-ID-shaped literal %r in: %r" % (m and m.group(0), ln)


# ── 4. every install subroutine leads with the consent gate; no stray installers ──────
def test_installs_consent_gated():
    lines = _bat_lines()
    # entry install subroutines = every `call :install_*` target in the file
    entries = set()
    for ln in lines:
        if _is_display(ln):
            continue
        for m in re.finditer(r"(?i)\bcall\s+:(install_\w+)", ln):
            entries.add(m.group(1).lower())
    assert entries >= {"install_python", "install_venv", "install_venv_refresh",
                       "install_docker"}, entries
    for name in sorted(entries):
        block = _block(name)
        first_exec = next((ln.strip() for ln in block if not _is_display(ln)), None)
        assert first_exec is not None and re.match(r"(?i)^call\s+:confirm\b", first_exec), \
            ":%s must start with `call :confirm`, got %r" % (name, first_exec)
    # the :confirm gate itself: a set /p prompt that defaults to NO
    confirm = "\n".join(_block("confirm"))
    assert re.search(r"(?im)^\s*set\s+/p\s+ANS=", confirm), confirm
    assert re.search(r'(?im)^\s*if\s+/i\s+"!ANS!"=="y"\s+exit\s+/b\s+0', confirm), confirm
    assert re.search(r"(?im)^\s*exit\s+/b\s+1\s*$", confirm), \
        ":confirm must fall through to exit /b 1 (default NO)"
    # the ONLY set /p in the whole file is the one inside :confirm
    prompts = [i for i, ln in enumerate(lines) if re.search(r"(?i)\bset\s+/p\b", ln)
               and not _is_display(ln)]
    assert all(_enclosing_label(i) == "confirm" for i in prompts), \
        "set /p outside :confirm at lines %s" % prompts
    # every winget/pip invocation lives inside an :install_* block
    for i, ln in enumerate(lines):
        if _is_display(ln):
            continue
        if "winget install" in ln or "pip install" in ln:
            lbl = _enclosing_label(i)
            assert lbl and lbl.startswith("install_"), \
                "installer invocation outside an :install_* block (in :%s): %r" % (lbl, ln)


# ── 5. no remote-script execution, ever ───────────────────────────────────────────────
def test_no_remote_execution():
    text = "\n".join(_bat_lines())
    lowered = text.lower()
    for needle in ("invoke-expression", "invoke-webrequest", "downloadstring",
                   "bitsadmin", "certutil -urlcache", "curl ", "powershell"):
        assert needle not in lowered, "forbidden remote-execution token %r" % needle
    assert not re.search(r"(?i)\biex\b", text)
    assert not re.search(r"(?i)\biwr\b", text)


# ── 6. automation (--args) and /detect can never hit a prompt ─────────────────────────
def test_headless_never_prompts():
    lines = _bat_lines()
    text = "\n".join(lines)
    argscan = text.index("for %%A in (%*)")
    headless_dispatch = text.index("goto :headless")
    detect_dispatch = text.index("goto :detect_only")
    first_prompt = min(text.index("set /p"), text.index("call :confirm"))
    assert argscan < first_prompt
    assert headless_dispatch < first_prompt
    assert detect_dispatch < first_prompt
    # the /detect block reaches exit /b 0 with no prompt and no install offer
    detect_only = [ln for ln in _block("detect_only") if not _is_display(ln)]
    assert any(re.match(r"(?i)^exit\s+/b\s+0", ln.strip()) for ln in detect_only)
    for ln in detect_only + [l for l in _block("headless") if not _is_display(l)]:
        assert "call :confirm" not in ln.lower() and "set /p" not in ln.lower(), ln
        assert not re.search(r"(?i)\bcall\s+:install_", ln), ln
    # the headless block flows to the launch contract
    assert any("goto :launch" in ln for ln in _block("headless"))


# ── 7. the DETECT vocabulary the qemu leg asserts (one vocabulary, two provers) ───────
def test_detect_report_facets():
    text = "\n".join(_bat_lines())
    for facet in ("DETECT python=", "DETECT pyside6=", "DETECT venv=",
                  "DETECT docker=", "DETECT winget="):
        assert facet in text, "missing DETECT facet %r" % facet
    # the docker facet is always labeled optional in the report
    assert "OPTIONAL" in text and "native builds are not available on Windows" in text


# ── 8. the launch line is byte-identical to the #345 contract ─────────────────────────
def test_launch_contract_byte_exact():
    lines = _bat_lines()
    exact = [i for i, ln in enumerate(lines) if ln == LAUNCH_LINE]
    assert len(exact) == 1, "expected exactly one %r line, found %d" % (LAUNCH_LINE, len(exact))
    # the venv wins by PATH prepend under :launch, BEFORE the pinned line — never by
    # changing the launch line itself
    launch_pos = next(i for i, lbl in _labels() if lbl == "launch")
    prepend = [i for i, ln in enumerate(lines) if "%VENV_DIR%\\Scripts;%PATH%" in ln]
    assert prepend and launch_pos < prepend[0] < exact[0], (launch_pos, prepend, exact)
    # still cd's into its own directory first (the #345 static requirement)
    assert any(ln.strip().lower().startswith("cd /d") and "%~dp0" in ln for ln in lines)


# ── 9. the Python floor is one constant, mirrored in the README ──────────────────────
def test_python_floor_matches_readme():
    text = "\n".join(_bat_lines())
    m = re.search(r'(?m)^set "PYTHON_MIN=(\d+\.\d+)"\s*$', text)
    assert m, "PYTHON_MIN pin missing from the .bat"
    bat_floor = m.group(1)
    assert bat_floor == "3.10"
    readme = open(README_PATH, encoding="utf-8").read()
    floors = re.findall(r"Python (\d+\.\d+)\+", readme)
    assert floors, "studio/README.md no longer states a Python floor"
    assert all(f == bat_floor for f in floors), (bat_floor, floors)
    # the version probe derives from the same constant (no second hardcoded floor)
    assert "v='%PYTHON_MIN%'.split('.')" in text


# ── 10. post-winget checks must see NEGATIVE exit codes ───────────────────────────────
def test_winget_failure_checks_are_signed():
    """winget failures return 0x8A15xxxx APPINSTALLER HRESULTs, which cmd stores as
    NEGATIVE signed 32-bit %ERRORLEVEL% values. ``if errorlevel 1`` is a signed >= 1
    test — FALSE for them — so a failed install would fall through to the success
    message (an honesty-rule violation). The check after every ``call winget install``
    must be the signed form ``if %ERRORLEVEL% NEQ 0 goto :install_*_failed``."""
    lines = _bat_lines()
    winget_calls = [i for i, ln in enumerate(lines)
                    if re.match(r"(?i)^\s*call\s+winget\s+install\b", ln)]
    assert len(winget_calls) == 2, "expected exactly 2 winget invocations: %s" % winget_calls
    for i in winget_calls:
        nxt = next((ln.strip() for ln in lines[i + 1:] if not _is_display(ln)), None)
        assert nxt is not None and re.match(
            r"(?i)^if\s+%ERRORLEVEL%\s+NEQ\s+0\s+goto\s+:install_\w+_failed$", nxt), \
            "post-winget check must be `if %%ERRORLEVEL%% NEQ 0 goto :install_*_failed`" \
            " (signed — catches winget's negative HRESULTs), got %r" % nxt


# ── 11. no digit-eating redirects (real-cmd quirk wine does not reproduce) ────────────
def test_no_digit_eating_redirects():
    """Real cmd.exe parses a digit immediately before ``>``/``>>`` as a stream handle
    even mid-token: ``echo X=%ERRORLEVEL%>> f`` expands to ``X=0>> f`` on success and
    the 0 is EATEN (handle 0 gets redirected; ``X=0`` never lands in the file). wine's
    cmd does NOT reproduce the quirk, so a live wine smoke cannot catch a regression —
    only this static check (and stage_payload's mirror of it) can. The safe spelling is
    redirect-first: ``>> f echo X=%ERRORLEVEL%``. Applies to the shipped .bat and to
    the GUEST_RUNNER cmd script embedded in windows-studio-e2e.sh (the .sh's own bash
    comments/greps legitimately mention the pattern, so only the runner block is
    scanned there)."""
    sh_text = open(QEMU_E2E_PATH, encoding="utf-8").read()
    m = re.search(r"GUEST_RUNNER='([^']*)'", sh_text)
    assert m, "GUEST_RUNNER block missing from windows-studio-e2e.sh"
    sources = [("hugmesh-studio.bat", "\n".join(_bat_lines())),
               ("windows-studio-e2e.sh GUEST_RUNNER", m.group(1))]
    for name, text in sources:
        for n, ln in enumerate(text.split("\n"), 1):
            assert "%>" not in ln, \
                "digit-eating '%%>' redirect in %s line %d: %r (use the redirect-first" \
                " form: `>> file echo ...%%VAR%%`)" % (name, n, ln)
