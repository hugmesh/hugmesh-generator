#!/usr/bin/env bash
# test-e2e-shell-nav-entry.sh — the DRIFT GUARD for the shell's Matrix nav entry.
#
# WHY THIS EXISTS. hugmesh-host-shell renders ONE of two mutually exclusive
# navigation branches (menu.component.html, `@if (barVisible()) … @else if
# (homeCardsActive())`): a `role="menubar"` whose Matrix entry carries
# `data-testid="nav-matrix"` on every non-home route, and — on the signed-in HOME
# ('/user', where roleHomeGuard lands EVERY authenticated identity, so where every
# sign-in lands) — a grid of service CARDS where the SAME entry carries
# `data-testid="home-card-nav-matrix"` instead. host-shell commit 00c092e
# (2026-08-19, issue #19: "on home the services ARE the navigation") made that
# swap, and the e2e tree kept asserting the bar form after sign-in. Live
# 2026-09-04 that surfaced as onboard() failing "element(s) not found" (specs
# 04/05/17 and their Gherkin mirrors) and, when the assertion caught the bar
# during the pre-redirect first paint, as "element was detached from the DOM,
# retrying" on the next click (spec 07).
#
# The fix is tests/e2e/specs/helpers.ts's matrixEntry / expectMatrixUnlocked /
# openMatrix. NOTHING OFFLINE GUARDED IT: an adversarial review mutation-measured
# the repo's thirteen e2e suites against a full revert of that semantic core and
# EVERY ONE stayed green (only the new Gherkin step BINDING was caught, by bddgen).
# Correctness rested entirely on one live run that cannot be re-measured with the
# stack down. This suite is that missing guard.
#
# WHAT IT ASSERTS (pure static analysis of tests/e2e/, no stack, no browser)
#   1. helpers.ts exports matrixEntry / expectMatrixUnlocked / openMatrix.
#   2. matrixEntry resolves BOTH testids in one `.or()` locator — dropping either
#      half re-breaks exactly one of the two routes.
#   3. expectMatrixUnlocked asserts the ENABLED form via
#      toHaveAttribute('href', '/social/matrix'). Both templates give the LOCKED
#      form the SAME testid (a `<button>`/`<span aria-disabled="true">`), so a bare
#      toBeVisible() proves rendering and NOT unlocking; href is the one attribute
#      only the enabled branch sets.
#   4. openMatrix asserts unlocked BEFORE it clicks. The locked home-card form is a
#      `<span>`, which Playwright will click (a span has no disabled actionability
#      state), so without this the click silently no-ops and the run dies seconds
#      later on the unrelated-looking "matrix-view is not visible".
#   5. onboard() waits on matrixEntry() and on no bare nav-matrix locator.
#   6. onboard() does NOT call expectMatrixUnlocked. THIS IS A SCOPE ASSERTION, NOT
#      A STYLE ONE, and it is deliberately fail-closed in the other direction from
#      the rest of this file. onboard() is the shared sign-in — 20+ spec call sites
#      plus the Gherkin Given "I am signed in as the persona for this scenario",
#      which 100+ scenarios across wiki, tube, owncast, games, forum and character
#      features reach. The enabled form is gated on
#      `capabilities.installed('matrix')` and host-shell's CapabilitiesService fails
#      CLOSED (an unreachable /api/federation/capabilities leaves an EMPTY map and
#      installed() returns false), so asserting the UNLOCKED form inside onboard()
#      would make "Matrix installed AND the federation-api answered" a precondition
#      of signing in at all, and a core-only stack would fail a hundred scenarios
#      that have nothing to do with Matrix.
#   7. No bare `nav-matrix` locator survives anywhere else under tests/e2e/specs or
#      tests/e2e/steps — matrixEntry is the only legitimate site.
#   8. No EXECUTING .feature step names the bare "nav-matrix" test id (comments may
#      still explain it; a step line may not use it).
#   9. The Gherkin Then "the shell offers Matrix unlocked" is bound in steps/ and
#      used by at least one .feature — a step defined and never used is decoration,
#      one used and never defined fails bddgen.
#
# NEGATIVE CONTROLS. The analyser is re-run against synthesised copies of the tree
# carrying each defect ON PURPOSE — including the exact revert that survived all
# thirteen existing suites — so a green run here cannot be vacuous. The copies live
# under a scratch dir; the real tests/e2e tree is never written to.
#
# OFFLINE. bash + python3 only. No node_modules, no chromium, no stack, no cluster,
# no network, no root. It refuses to be vacuous: a missing prerequisite or a
# missing input file exits 2 saying it checked NOTHING, never 0.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"

command -v python3 >/dev/null 2>&1 || {
  echo "  SKIPPED-LOUDLY python3 is not on PATH — this guard checked NOTHING"; exit 2; }

E2E="${REPO}/tests/e2e"
for f in "${E2E}/specs/helpers.ts" "${E2E}/steps/matrix.steps.ts"; do
  [ -f "${f}" ] || {
    echo "  SKIPPED-LOUDLY missing input ${f} — this guard checked NOTHING"; exit 2; }
done

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

echo "== e2e shell nav entry: the Matrix entry is menubar OR home card, and unlocked means <a href> =="

# ── the analyser ─────────────────────────────────────────────────────────────
# Parameterised by NAV_ROOT so the negative controls below can point it at a
# mutated copy. Prints one "CHECK n <verdict>" line per assertion and exits
# non-zero if any failed.
ANALYSER="$(mktemp -t nav-entry-analyser.XXXXXX.py)"
SCRATCH="$(mktemp -d -t nav-entry-controls.XXXXXX)"
cleanup() { rm -f "${ANALYSER}"; rm -rf "${SCRATCH}"; }
trap cleanup EXIT INT TERM

cat > "${ANALYSER}" <<'PY'
import os, re, sys, io

root = os.environ["NAV_ROOT"]
helpers = os.path.join(root, "specs", "helpers.ts")
steps_dir = os.path.join(root, "steps")
specs_dir = os.path.join(root, "specs")
feat_dir  = os.path.join(root, "features")

fails = []
def check(n, cond, msg):
    print(("  CHECK %d PASS " % n) + msg if cond else ("  CHECK %d FAIL " % n) + msg)
    if not cond:
        fails.append(n)

def read(p):
    with io.open(p, encoding="utf-8", errors="replace") as fh:
        return fh.read()

def code_only(src):
    """The same string with every comment blanked to spaces (newlines kept), so
    line numbers and offsets are unchanged. A guard that greps raw source counts
    the PROSE that explains a rule as an instance of breaking it — check 6 below
    is exactly that shape: onboard()'s comment names expectMatrixUnlocked in
    order to say why it must NOT be called there."""
    out = list(src)
    i, n = 0, len(src)
    q = None          # the open quote char, or None
    while i < n:
        c = src[i]
        if q:
            if c == "\\":
                i += 2
                continue
            if c == q:
                q = None
            i += 1
            continue
        if c in "'\"`":
            q = c
            i += 1
            continue
        if c == "/" and i + 1 < n and src[i + 1] == "/":
            while i < n and src[i] != "\n":
                out[i] = " "
                i += 1
            continue
        if c == "/" and i + 1 < n and src[i + 1] == "*":
            j = src.find("*/", i + 2)
            j = n if j < 0 else j + 2
            while i < j:
                if out[i] != "\n":
                    out[i] = " "
                i += 1
            continue
        i += 1
    return "".join(out)

H = code_only(read(helpers))

def body_of(src, name):
    """The source of `export [async] function <name>(...) { ... }`, brace-matched."""
    m = re.search(r"export\s+(?:async\s+)?function\s+" + re.escape(name) + r"\s*\(", src)
    if not m:
        return None
    i = src.find("{", m.end())
    if i < 0:
        return None
    depth, j = 0, i
    while j < len(src):
        if src[j] == "{":
            depth += 1
        elif src[j] == "}":
            depth -= 1
            if depth == 0:
                return src[i:j + 1]
        j += 1
    return None

entry_b   = body_of(H, "matrixEntry")
unlock_b  = body_of(H, "expectMatrixUnlocked")
open_b    = body_of(H, "openMatrix")
onboard_b = body_of(H, "onboard")

# 1 — the three helpers exist and are exported
missing = [n for n, b in (("matrixEntry", entry_b), ("expectMatrixUnlocked", unlock_b),
                          ("openMatrix", open_b), ("onboard", onboard_b)) if b is None]
check(1, not missing,
      "helpers.ts exports matrixEntry / expectMatrixUnlocked / openMatrix (+ onboard)"
      if not missing else "helpers.ts is missing exported function(s): " + ", ".join(missing))

# 2 — matrixEntry resolves BOTH forms in one .or() locator
if entry_b is None:
    check(2, False, "matrixEntry is absent, so it cannot resolve either form")
else:
    both = ("home-card-nav-matrix" in entry_b and
            re.search(r"getByTestId\(\s*['\"]nav-matrix['\"]\s*\)", entry_b) is not None and
            ".or(" in entry_b)
    check(2, both,
          "matrixEntry .or()s home-card-nav-matrix WITH nav-matrix (both routes resolve)"
          if both else
          "matrixEntry does NOT resolve both forms via .or() — one of the two routes "
          "(signed-in home / everywhere else) can no longer find the entry")

# 3 — expectMatrixUnlocked discriminates the ENABLED form by href
if unlock_b is None:
    check(3, False, "expectMatrixUnlocked is absent, so nothing proves the unlock")
else:
    href = re.search(r"toHaveAttribute\(\s*['\"]href['\"]\s*,\s*['\"]/social/matrix['\"]", unlock_b)
    vis  = "toBeVisible()" in unlock_b
    check(3, bool(href) and vis,
          "expectMatrixUnlocked asserts toBeVisible AND href=/social/matrix (the locked "
          "form shares the testid, so visibility alone proves nothing)"
          if (href and vis) else
          "expectMatrixUnlocked no longer asserts the enabled-form discriminator "
          "toHaveAttribute('href', '/social/matrix') — a greyed aria-disabled entry "
          "would satisfy it")

# 4 — openMatrix asserts unlocked BEFORE clicking
if open_b is None:
    check(4, False, "openMatrix is absent")
else:
    call = open_b.find("expectMatrixUnlocked(")
    clik = open_b.find(".click()")
    check(4, call >= 0 and clik >= 0 and call < clik,
          "openMatrix asserts expectMatrixUnlocked BEFORE it clicks"
          if (call >= 0 and clik >= 0 and call < clik) else
          "openMatrix clicks without first asserting the entry is unlocked — the locked "
          "home-card form is a <span>, which Playwright clicks happily, so the failure "
          "would surface later as a missing matrix-view instead of at the nav")

# 5 — onboard() waits on matrixEntry, not on a bare nav-matrix locator
if onboard_b is None:
    check(5, False, "onboard is absent")
else:
    uses_entry = "matrixEntry(" in onboard_b
    bare = re.search(r"getByTestId\(\s*['\"]nav-matrix['\"]\s*\)", onboard_b)
    check(5, uses_entry and not bare,
          "onboard() waits on matrixEntry() and on no bare nav-matrix locator"
          if (uses_entry and not bare) else
          "onboard() does not resolve the entry through matrixEntry() — after sign-in "
          "the shell is on the home, where nav-matrix is NOT in the DOM")

# 6 — onboard() must NOT require the UNLOCKED form (blast-radius scope assertion)
if onboard_b is None:
    check(6, False, "onboard is absent")
else:
    over = "expectMatrixUnlocked(" in onboard_b
    check(6, not over,
          "onboard() asserts the entry is RENDERED, not that Matrix is installed — so "
          "the shared sign-in does not impose a Matrix precondition on 100+ unrelated "
          "scenarios"
          if not over else
          "onboard() calls expectMatrixUnlocked(), which makes capabilities.installed"
          "('matrix') a precondition of EVERY sign-in (the shared Gherkin Given "
          "included); CapabilitiesService fails closed, so a core-only stack or a "
          "federation-api blip would fail scenarios that never touch Matrix")

# 7 — no bare nav-matrix locator anywhere else in specs/ or steps/
stray = []
for d in (specs_dir, steps_dir):
    if not os.path.isdir(d):
        continue
    for dirpath, _dirs, files in os.walk(d):
        for fn in files:
            if not fn.endswith(".ts"):
                continue
            p = os.path.join(dirpath, fn)
            txt = code_only(read(p))
            for i, line in enumerate(txt.splitlines(), 1):
                if re.search(r"getByTestId\(\s*['\"]nav-matrix['\"]\s*\)", line):
                    rel = os.path.relpath(p, root)
                    if rel == os.path.join("specs", "helpers.ts") and entry_b and line.strip() in entry_b:
                        continue          # the ONE legitimate site: matrixEntry itself
                    stray.append("%s:%d" % (rel, i))
check(7, not stray,
      "matrixEntry is the only site that names the bare nav-matrix testid"
      if not stray else
      "bare nav-matrix locator(s) outside matrixEntry: " + ", ".join(stray) +
      " — these break on the signed-in home")

# 8 — no EXECUTING feature step names the bare nav-matrix test id
feat_hits = []
if os.path.isdir(feat_dir):
    for dirpath, _dirs, files in os.walk(feat_dir):
        for fn in files:
            if not fn.endswith(".feature"):
                continue
            p = os.path.join(dirpath, fn)
            for i, line in enumerate(read(p).splitlines(), 1):
                s = line.strip()
                if s.startswith("#"):
                    continue              # a comment may still EXPLAIN nav-matrix
                if re.search(r'test id\s+"nav-matrix"', s):
                    feat_hits.append("%s:%d" % (os.path.relpath(p, root), i))
check(8, not feat_hits,
      "no executing .feature step names the bare nav-matrix test id"
      if not feat_hits else
      "feature step(s) still name the bar-only testid: " + ", ".join(feat_hits))

# 9 — the unlock step is both DEFINED and USED
STEP = "the shell offers Matrix unlocked"
defined = False
if os.path.isdir(steps_dir):
    for dirpath, _dirs, files in os.walk(steps_dir):
        for fn in files:
            if fn.endswith(".ts") and re.search(
                    r"""(Then|Given|When)\(\s*['"]""" + re.escape(STEP) + r"""['"]""",
                    code_only(read(os.path.join(dirpath, fn)))):
                defined = True
used = False
if os.path.isdir(feat_dir):
    for dirpath, _dirs, files in os.walk(feat_dir):
        for fn in files:
            if not fn.endswith(".feature"):
                continue
            for line in read(os.path.join(dirpath, fn)).splitlines():
                t = line.strip()
                if t.startswith("#"):
                    continue      # a Gherkin comment is not a use
                if STEP in t:
                    used = True
check(9, defined and used,
      'the Then "%s" is defined in steps/ and used by a .feature' % STEP
      if (defined and used) else
      'the Then "%s" is %s' % (STEP,
        "used by a .feature but NOT defined (bddgen will fail generation)" if used and not defined
        else "defined but used by no .feature (decoration)" if defined and not used
        else "neither defined nor used"))

sys.exit(1 if fails else 0)
PY

# ── the real tree ────────────────────────────────────────────────────────────
echo
echo "-- the repo's own tests/e2e --"
NAV_ROOT="${E2E}" python3 "${ANALYSER}"
REAL_RC=$?
if [ "${REAL_RC}" -eq 0 ]; then
  ok "every shell-nav-entry assertion holds on tests/e2e"
else
  bad "the shell-nav-entry contract is broken on tests/e2e (see the CHECK lines above)"
fi

# ── negative controls: break production on purpose, one way at a time ────────
# Each mutation is applied to a COPY. The analyser must go RED for every one; a
# mutation that survives means this guard does not guard what its header claims.
echo
echo "-- negative controls (each must turn the analyser RED) --"
mkdir -p "${SCRATCH}/base"
cp -a "${E2E}/specs" "${E2E}/steps" "${E2E}/features" "${SCRATCH}/base/" 2>/dev/null || {
  echo "  SKIPPED-LOUDLY could not copy tests/e2e for the controls — this guard's "
  echo "  negative controls checked NOTHING"; exit 2; }

MC=0; MS=0
mutate() {
  # $1 = label, $2 = python mutation program (reads/writes files under $ROOT)
  local label="$1"
  local prog="$2"
  local root="${SCRATCH}/m$((MC + MS))"
  rm -rf "${root}"
  cp -a "${SCRATCH}/base" "${root}"
  MUT_ROOT="${root}" python3 -c "${prog}" || {
    bad "control '${label}' could not be applied — it proves nothing"
    MS=$((MS + 1)); return; }
  local out
  out="$(NAV_ROOT="${root}" python3 "${ANALYSER}" 2>&1)"
  if [ $? -ne 0 ]; then
    echo "  CAUGHT  ${label}"
    MC=$((MC + 1))
  else
    echo "  SURVIVED ${label}"
    printf '%s\n' "${out}" | sed 's/^/      /'
    MS=$((MS + 1))
  fi
}

# The exact revert an adversarial review measured as surviving all thirteen
# existing e2e suites: matrixEntry stops resolving the home card, and
# expectMatrixUnlocked stops discriminating the enabled form.
mutate "the full semantic revert (bar-only locator + bare toBeVisible)" '
import os, io, re
p = os.path.join(os.environ["MUT_ROOT"], "specs", "helpers.ts")
s = io.open(p, encoding="utf-8").read()
s = s.replace("page.getByTestId(\x27home-card-nav-matrix\x27).or(page.getByTestId(\x27nav-matrix\x27))",
              "page.getByTestId(\x27nav-matrix\x27)")
s = re.sub(r"\n\s*await expect\(entry\)\.toHaveAttribute\([^\n]*\n", "\n", s)
io.open(p, "w", encoding="utf-8").write(s)
'

mutate "matrixEntry loses the home-card half" '
import os, io
p = os.path.join(os.environ["MUT_ROOT"], "specs", "helpers.ts")
s = io.open(p, encoding="utf-8").read()
s = s.replace("page.getByTestId(\x27home-card-nav-matrix\x27).or(page.getByTestId(\x27nav-matrix\x27))",
              "page.getByTestId(\x27nav-matrix\x27)")
io.open(p, "w", encoding="utf-8").write(s)
'

mutate "expectMatrixUnlocked drops the href discriminator" '
import os, io, re
p = os.path.join(os.environ["MUT_ROOT"], "specs", "helpers.ts")
s = io.open(p, encoding="utf-8").read()
s = re.sub(r"\n\s*await expect\(entry\)\.toHaveAttribute\([^\n]*\n", "\n", s)
io.open(p, "w", encoding="utf-8").write(s)
'

mutate "openMatrix clicks without asserting the unlock" '
import os, io
p = os.path.join(os.environ["MUT_ROOT"], "specs", "helpers.ts")
s = io.open(p, encoding="utf-8").read()
s = s.replace("  await expectMatrixUnlocked(page);\n  await matrixEntry(page).click();",
              "  await matrixEntry(page).click();")
io.open(p, "w", encoding="utf-8").write(s)
'

mutate "onboard waits on the bar-only testid again (the original defect)" '
import os, io
p = os.path.join(os.environ["MUT_ROOT"], "specs", "helpers.ts")
s = io.open(p, encoding="utf-8").read()
s = s.replace("  await expect(matrixEntry(page)).toBeVisible();\n  return getSession(page, username);",
              "  await expect(page.getByTestId(\x27nav-matrix\x27)).toBeVisible();\n  return getSession(page, username);")
io.open(p, "w", encoding="utf-8").write(s)
'

mutate "onboard over-strengthens to expectMatrixUnlocked (Matrix becomes a sign-in precondition)" '
import os, io
p = os.path.join(os.environ["MUT_ROOT"], "specs", "helpers.ts")
s = io.open(p, encoding="utf-8").read()
s = s.replace("  await expect(matrixEntry(page)).toBeVisible();\n  return getSession(page, username);",
              "  await expectMatrixUnlocked(page);\n  return getSession(page, username);")
io.open(p, "w", encoding="utf-8").write(s)
'

mutate "a feature step asserts the bare nav-matrix testid again" '
import os, io
p = os.path.join(os.environ["MUT_ROOT"], "features", "rbac", "pending-approval-gate.feature")
s = io.open(p, encoding="utf-8").read()
s = s.replace("And the shell offers Matrix unlocked",
              "And the element with test id \"nav-matrix\" is visible")
io.open(p, "w", encoding="utf-8").write(s)
'

mutate "the unlock step binding is deleted" '
import os, io, re
p = os.path.join(os.environ["MUT_ROOT"], "steps", "matrix.steps.ts")
s = io.open(p, encoding="utf-8").read()
s = re.sub(r"Then\(\x27the shell offers Matrix unlocked\x27[\s\S]*?\n\}\);\n", "", s, count=1)
io.open(p, "w", encoding="utf-8").write(s)
'

mutate "a spec re-introduces a bare nav-matrix locator" '
import os, io
p = os.path.join(os.environ["MUT_ROOT"], "specs", "17-rbac-user-and-pending.spec.ts")
s = io.open(p, encoding="utf-8").read()
s = s.replace("await expectMatrixUnlocked(page);",
              "await expect(page.getByTestId(\x27nav-matrix\x27)).toBeVisible();")
io.open(p, "w", encoding="utf-8").write(s)
'

echo "  mutations: ${MC} caught, ${MS} survived"
if [ "${MS}" -eq 0 ] && [ "${MC}" -gt 0 ]; then
  ok "every mutation was caught — this guard is not vacuous"
else
  bad "${MS} mutation(s) SURVIVED — this guard does not guard what it claims to"
fi

# ── the real tree is untouched ───────────────────────────────────────────────
if [ -z "$(git -C "${REPO}" status --porcelain -- tests/e2e 2>/dev/null)" ]; then
  ok "tests/e2e is unmodified by this run (nothing was mutated in place)"
else
  echo "  NOTE tests/e2e has uncommitted changes; this guard never writes there," \
       "so they are the caller's own edits"
  ok "this guard mutated only its scratch copies"
fi

echo
echo "== e2e shell nav entry: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
