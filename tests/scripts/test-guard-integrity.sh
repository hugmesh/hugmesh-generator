#!/usr/bin/env bash
# test-guard-integrity.sh — the guard over the guards.
#
# THE DISEASE THIS REPO KEEPS RELAPSING INTO IS A GUARD THAT CANNOT FAIL.
# It has shipped in three distinct shapes, all of them found only by hand:
#
#   (1) AN HONEST SUITE WITH A DISHONEST EXIT STATUS.
#       tests/node-storage/test-appset.sh printed its verdict and then ended on
#           echo "---EXIT $?---"
#       With no `set -e`, a script's status is its LAST command's status, and
#       echo always succeeds. The suite printed "---EXIT 1---" and exited 0, so
#       node-storage-verify's fourth leg was structurally incapable of failing
#       from the day it was wired.
#
#   (2) A SUITE NOTHING RUNS.
#       tests/desktop-governance/test-desktop-sudo-mapper.sh — the ONLY coverage
#       of the desktop-sudo mapper's JWKS signature verification, iss/aud/exp
#       checks, identity binding, alg=none and rogue-key rejection — landed with
#       PR #530 wired into neither .gitlab-ci.yml nor the Makefile. Roughly forty
#       other suites were in the same state.
#
#   (3) A LOOP THAT THROWS THE STATUS AWAY.
#       A CI leg that iterates suites must accumulate a failure code; a bare
#       `for t in …; do bash "$t"; done` exits with the LAST suite's status and
#       silently forgives every earlier one.
#
# Each of those was fixed once, by hand, after it had already shipped. This suite
# makes all three fail-closed and mechanical, so the NEXT instance is caught by a
# pipeline instead of by an audit.
#
# Pure static analysis of the repo's own files. No network, no root, no docker,
# no cluster, python3 stdlib only (no PyYAML) so it runs in python:3-slim.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"

command -v python3 >/dev/null 2>&1 || { echo "  FAIL python3 not available"; exit 2; }

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }

# ── The unwired allowlist ────────────────────────────────────────────────────
# A suite may sit outside every pipeline ONLY with a recorded reason. The
# allowlist is itself guarded below: an entry naming a file that no longer
# exists, or naming a suite that IS now wired, FAILS — so it cannot rot into a
# blanket amnesty. Nothing may be added here because it is red; a red suite is a
# bug report, not an exemption.
ALLOW_UNWIRED=(
  "tests/api/test-bff-admin.sh|needs a LIVE admin-BFF + Casdoor on localhost (it asserts real 401/403 route-access responses); belongs to the compose/e2e lanes, not a static verify job"
  "tests/scripts/test-studio-launch.sh|drives the PyQt/PySide Studio entrypoint and takes minutes with a GUI toolkit venv; belongs to the studio pytest lane"
)

# GUARD_ROOT lets the negative-control section below re-run this ANALYSER against
# a synthesised tree carrying each defect on purpose, so a green run over the real
# repo cannot be vacuous. GUARD_ALLOW overrides the allowlist for those runs.
GUARD_ROOT="${GUARD_ROOT:-${REPO}}"
if [ -n "${GUARD_ALLOW+x}" ]; then ALLOW_TEXT="${GUARD_ALLOW}"
else ALLOW_TEXT="$(printf '%s\n' "${ALLOW_UNWIRED[@]}")"; fi

# How many suites are wired into a pull_request-triggered workflow (check 7).
# GUARD_PREMERGE overrides it for the negative-control children below, exactly as
# GUARD_ALLOW does for the allowlist: this number describes THE REAL REPO, and a
# synthesised one-suite tree cannot be measured against it.
PREMERGE_BASELINE="${GUARD_PREMERGE:-106}"

echo "== guard integrity: every guard can fail, and something runs it =="

REPO="${GUARD_ROOT}" ALLOW_UNWIRED="${ALLOW_TEXT}" PREMERGE_BASELINE="${PREMERGE_BASELINE}" python3 - <<'PY'
import os, re, sys

repo = os.environ["REPO"]
allow = {}
for line in os.environ["ALLOW_UNWIRED"].splitlines():
    line = line.strip()
    if not line:
        continue
    path, _, reason = line.partition("|")
    allow[path] = reason

P = [0]; F = [0]
def ok(m):  print("  PASS " + m); P[0] += 1
def bad(m): print("  FAIL " + m); F[0] += 1

# ── collect the suites ───────────────────────────────────────────────────────
suites = []
for root, dirs, files in os.walk(os.path.join(repo, "tests")):
    dirs[:] = [d for d in dirs if d not in (".git", "node_modules")]
    for fn in files:
        if fn.startswith("test-") and fn.endswith(".sh"):
            suites.append(os.path.relpath(os.path.join(root, fn), repo))
suites.sort()

if not suites:
    bad("found ZERO test-*.sh suites under tests/ — this guard would be vacuous")
    print()
    print("== guard integrity: %d passed, %d failed ==" % (P[0], F[0]))
    sys.exit(1)
ok("enumerated %d test-*.sh suites under tests/" % len(suites))

# ── "what is the last thing this script actually runs?" ──────────────────────
# Read BACKWARD from EOF. A forward heredoc-state machine is the obvious design
# and it is wrong here: these suites embed awk and python programs, and a `<<`
# inside a quoted awk regex (`/<<CHROOT/`), a `<<'"'"'PY'"'"'` opener, or a `<<<`
# herestring all fool a regex scanner into thinking a heredoc opened and never
# closed — after which it swallows the rest of the file, including the verdict it
# came to inspect. Backward is exact for the only question asked: valid bash
# cannot end INSIDE a heredoc body, so the last non-blank/non-comment line is
# either the final statement or a heredoc TERMINATOR, and the terminator case is
# decidable by looking for its opener.
HEREDOC_OPEN = r"(?<!<)<<(?!<)-?\s*['\"]?%s['\"]?\s*$"
SET_E        = re.compile(r"^set\s+-[a-zA-Z]*e")   # column 0: the repo's convention
BAREWORD     = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")

def last_statement(text):
    """(lineno, source) of the last line bash executes, or None."""
    lines = text.split("\n")
    i = len(lines) - 1
    while i >= 0 and (not lines[i].strip() or lines[i].strip().startswith("#")):
        i -= 1
    if i < 0:
        return None
    s = lines[i].strip()
    if BAREWORD.match(s):
        # Could be a heredoc terminator (`PY`, `EOF`, …). If an opener exists
        # above it, the statement is the OPENER line, not the delimiter.
        pat = re.compile(HEREDOC_OPEN % re.escape(s))
        for j in range(i - 1, -1, -1):
            if pat.search(lines[j]):
                return (j + 1, lines[j].strip())
    return (i + 1, s)

def has_set_e(text):
    return any(SET_E.match(l) for l in text.split("\n"))

# The last SIMPLE command on a line decides the line's exit status: `echo x; exit 1`
# is honest, a bare `echo x` is not. Split on ';' only — '&&'/'||' chains still end
# on their last command, and `a && b` with b an echo is just as dishonest.
STATUS_BLIND = re.compile(r"^(echo|printf|:|true|cat)\b")

def last_command(line):
    parts = [p.strip() for p in line.split(";")]
    parts = [p for p in parts if p]
    return parts[-1] if parts else line

# ── 1) EXIT STATUS: no suite may end on a status-blind command without set -e ─
print()
print("-- 1) every suite's exit status carries its verdict --")
blind = []
for rel in suites:
    text = open(os.path.join(repo, rel), encoding="utf-8", errors="replace").read()
    st = last_statement(text)
    if st is None:
        blind.append((rel, 0, "<empty>", "no executable line at all"))
        continue
    lineno, line = st
    tail = last_command(line)
    if STATUS_BLIND.match(tail) and not has_set_e(text):
        blind.append((rel, lineno, tail, "ends on a status-blind command and does not `set -e`"))
if blind:
    bad("suite(s) whose exit status cannot express failure:")
    for rel, lineno, tail, why in blind:
        print("         %s:%d: %s  <- %s" % (rel, lineno, tail[:70], why))
else:
    ok("all %d suites end on a real verdict (or run under `set -e`)" % len(suites))

# ── 2) A FAILURE COUNTER MUST BE RE-RAISED ───────────────────────────────────
# The repo idiom is `F=0; bad(){ …; F=$((F+1)); }` closed by `[ "${F}" -eq 0 ]`.
# Counting failures and then exiting 0 anyway is the same defect wearing a
# different hat: the suite prints FAIL lines nobody's pipeline ever notices.
#
# Deliberately asks a WHOLE-FILE question ("does any expression turn this counter
# into an exit status?") rather than "is it in the last N lines". Position needs a
# parser to get right; existence does not, and a gate must not invent failures.
print()
print("-- 2) a suite that COUNTS failures must also RAISE them --")
FUNC  = re.compile(r"^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{")
INCR  = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)=\$\(\(\s*\1\s*\+\s*1\s*\)\)")
FAILY = re.compile(r"^(bad|fail|failed|neg_bad|err|error|nope|ko)$", re.I)

def raises(text, var):
    v = re.escape(var)
    return re.search(
        r"(\[\[?\s*\"?\$\{?%s\}?\"?\s*-(eq|ne|gt|lt|ge|le)\b"    # [ "${F}" -eq 0 ]
        r"|exit\s+\"?\$\{?%s\}?"                                  # exit "${F}"
        # `return $(( fails > 0 ))` / `exit $(( F != 0 ))`: an arithmetic
        # expansion handed straight to return/exit IS the status. Omitting this
        # made the analyser red on tests/node-storage/test-bake-coverage.sh —
        # a guard-guard failing a guard that is in fact correct, which is the
        # "red for a reason that is not a defect" half of the same disease.
        r"|(return|exit)\s+\"?\$\(\([^)]*\b%s\b"
        r"|\(\(\s*%s\s*\)\))" % (v, v, v, v),                     # (( F ))
        text)

unraised = []
for rel in suites:
    text = open(os.path.join(repo, rel), encoding="utf-8", errors="replace").read()
    if has_set_e(text):
        continue                      # set -e already re-raises
    counters, cur = set(), None
    for line in text.split("\n"):
        s = line.strip()
        if s.startswith("#"):
            continue
        m = FUNC.match(line)
        if m:
            cur = m.group(1)
        if cur and FAILY.match(cur):
            for c in INCR.finditer(line):
                counters.add(c.group(1))
        if s.startswith("}"):
            cur = None
    missing = sorted(c for c in counters if not raises(text, c))
    if missing:
        unraised.append((rel, missing))
if unraised:
    bad("suite(s) that increment a failure counter nothing turns into an exit status:")
    for rel, counters in unraised:
        print("         %s: counter(s) %s counted but never raised" % (rel, ",".join(counters)))
else:
    ok("every failure counter feeds an exit-status expression")

# ── 3) WIRING: something must actually run each suite ────────────────────────
print()
print("-- 3) every suite is invoked by .gitlab-ci.yml or the Makefile --")
ci_path = os.path.join(repo, ".gitlab-ci.yml")
mk_path = os.path.join(repo, "Makefile")
ci = open(ci_path, encoding="utf-8", errors="replace").read() if os.path.isfile(ci_path) else ""
mk = open(mk_path, encoding="utf-8", errors="replace").read() if os.path.isfile(mk_path) else ""
if not ci:
    bad(".gitlab-ci.yml is missing or empty — wiring cannot be verified")
if not mk:
    bad("Makefile is missing or empty — wiring cannot be verified")
runners = ci + "\n" + mk

# A `bash <path>` mention, or a directory glob that sweeps the suite in.
def wired(rel):
    if rel in runners:
        return True
    glob = os.path.dirname(rel) + "/*.sh"
    return glob in runners

orphans  = [s for s in suites if not wired(s)]
unlisted = [s for s in orphans if s not in allow]
if unlisted:
    bad("suite(s) nothing runs — neither .gitlab-ci.yml nor the Makefile invokes them:")
    for s in unlisted:
        print("         %s" % s)
    print("         (wire them, or add them to ALLOW_UNWIRED with a reason)")
else:
    ok("all %d suites are invoked by a pipeline job or a make target (%d allowlisted)"
       % (len(suites), len(allow)))

# ── 4) THE ALLOWLIST ITSELF MUST NOT ROT ─────────────────────────────────────
print()
print("-- 4) the ALLOW_UNWIRED allowlist stays honest --")
stale = [p for p in allow if not os.path.isfile(os.path.join(repo, p))]
nolonger = [p for p in allow if os.path.isfile(os.path.join(repo, p)) and wired(p)]
noreason = [p for p, r in allow.items() if len(r.strip()) < 20]
if stale:
    bad("ALLOW_UNWIRED names file(s) that do not exist: %s" % ", ".join(sorted(stale)))
else:
    ok("every allowlisted path exists")
if nolonger:
    bad("ALLOW_UNWIRED still exempts suite(s) that ARE wired now — drop them: %s"
        % ", ".join(sorted(nolonger)))
else:
    ok("no allowlist entry shadows a suite that is already wired")
if noreason:
    bad("ALLOW_UNWIRED entr(y/ies) carry no real reason: %s" % ", ".join(sorted(noreason)))
else:
    ok("every allowlist entry records why the suite is unrunnable in a verify job")

# ── 5) A CI LOOP OVER SUITES MUST ACCUMULATE ITS EXIT CODES ──────────────────
# `for t in …; do bash "$t"; done` exits with the LAST suite's status: every
# earlier failure is forgiven. Any loop in .gitlab-ci.yml that runs tests/ files
# must either accumulate an rc or abort on the first failure.
print()
print("-- 5) CI loops over suites do not swallow failures --")
# Match on the loop VARIABLE being handed to bash, not on the word "tests/"
# appearing in the `for` header: an explicit suite list is usually built in a
# variable above the loop (`for t in ${SUITES}`), and a header-only match would
# skip exactly those jobs.
loops = []
lines = ci.split("\n")
for i, line in enumerate(lines):
    m = re.search(r"^\s*for\s+(\w+)\s+in\s+", line)
    if not m:
        continue
    var = m.group(1)
    body = []
    for j in range(i, min(i + 20, len(lines))):
        body.append(lines[j])
        if re.match(r"^\s*done\b", lines[j]):
            break
    text = "\n".join(body)
    runs_suite = re.search(r"bash\s+\"?\$\{?%s\}?\"?" % re.escape(var), text) \
                 or re.search(r"tests/\S*\.sh", line)
    if runs_suite:
        loops.append((i + 1, text))
if not loops:
    ok("no shell loop in .gitlab-ci.yml iterates suites (nothing to swallow)")
else:
    swallowing = []
    for lineno, body in loops:
        # honest shapes: `|| rc=1` / `|| { rc=1; … }` (+ a later `exit "${rc}"`),
        # or `|| exit` (abort on the first failing suite).
        accumulates = re.search(r"\|\|\s*\{?\s*(rc|RC|fail|FAIL|failed|status)\s*=", body)
        aborts      = re.search(r"\|\|\s*exit\b", body)
        if not (accumulates or aborts):
            swallowing.append((lineno, body.strip().split("\n")[0].strip()))
    if swallowing:
        bad("CI loop(s) over tests/ suites that discard a failing suite's status:")
        for lineno, first in swallowing:
            print("         .gitlab-ci.yml:%d: %s" % (lineno, first[:80]))
    else:
        ok("all %d CI loop(s) over tests/ suites accumulate or abort on failure" % len(loops))

# ── 6) A SUITE A CI BATCH JOB RUNS MAY NOT SKIP ITSELF ───────────────────────
# The FOURTH shape of "this guard cannot fail", and the one that shipped inside
# the very job that was supposed to end the disease. orphan-guards-verify ran on
# `alpine:3`, which has no JDK, so the three tests/keystores suites hit
#     for t in openssl keytool python3; do
#       command -v "$t" >/dev/null || { echo "SKIP: need $t"; exit 0; }; done
# and reported green while checking nothing — and the fourth keytool consumer,
# test-headscale-oidc-secret-staging.sh, went hard RED for the same missing
# binary. On a workstation `SKIP … exit 0` is honest; in a CI job the image
# decides which tools exist, so it silently converts "this runner is
# under-provisioned" into "the property holds".
#
# The rule, mechanical: any suite named in a `SUITES="…"` batch list in
# .gitlab-ci.yml must be fail-closed on tooling. Adding a suite to such a job
# enrols it automatically — there is no registry to forget to update.
print()
print("-- 6) suites a CI batch job runs cannot silently skip themselves --")
OPT_OUT = "GUARD_TOOLING_ALLOW_SKIP"
LIB_REL = "tests/lib/guard-preflight.sh"

# Any shell variable in the CI file whose body is nothing but tests/… .sh paths
# IS a batch list, whatever it is called. Keying on the literal name `SUITES`
# would let the next job named LEGS= or GUARDS= walk straight out of this check.
batch = []
for m in re.finditer(r'([A-Za-z_][A-Za-z0-9_]*)="\s*\n(.*?)\n\s*"', ci, re.S):
    entries = [l.strip() for l in m.group(2).splitlines() if l.strip()]
    if entries and all(e.startswith("tests/") and e.endswith(".sh") for e in entries):
        batch.extend(entries)
batch = sorted(set(batch))

SKIPWORD = re.compile(r"SKIP", re.I)
PROBE    = re.compile(r"command -v\b")

def silent_skips(text):
    """(lineno, source) for every `exit 0` reachable from a tooling/SKIP probe.

    Looks BACKWARD three non-blank/non-comment lines as well as at the line
    itself, so the two-line shape
        echo "SKIP: need bash >= 4.4"
        exit 0
    is caught as surely as the one-liner. Everything named here is a place the
    suite hands back exit 0 without having checked what it exists to check."""
    found = []
    ls = text.split("\n")
    for i, l in enumerate(ls):
        s = l.strip()
        if s.startswith("#") or not re.search(r"\bexit\s+0\b", s):
            continue
        ctx, j, back = [s], i - 1, 0
        while j >= 0 and back < 3:
            p = ls[j].strip()
            if p and not p.startswith("#"):
                ctx.append(p)
                back += 1
            j -= 1
        joined = "\n".join(ctx)
        if SKIPWORD.search(joined) or PROBE.search(joined):
            found.append((i + 1, s))
    return found

if not batch:
    ok("no .gitlab-ci.yml job runs a SUITES batch list (nothing to check here)")
else:
    offenders = []
    unsourced = []
    for rel in batch:
        path = os.path.join(repo, rel)
        if not os.path.isfile(path):
            bad("SUITES batch list names a file that does not exist: %s" % rel)
            continue
        text = open(path, encoding="utf-8", errors="replace").read()
        for lineno, src in silent_skips(text):
            offenders.append((rel, lineno, src))
        # A helper call that was never sourced is worse than the skip it replaced:
        # `guard_require_tools` would be a 127 command-not-found and, with no
        # `set -e`, the suite would sail straight past its own preflight.
        if re.search(r"\bguard_require_(tools|capability)\b", text) \
           and "guard-preflight.sh" not in text.replace("guard_require", ""):
            unsourced.append(rel)
    if offenders:
        bad("suite(s) a CI batch job runs that hand back exit 0 instead of a verdict:")
        for rel, lineno, src in offenders:
            print("         %s:%d: %s" % (rel, lineno, src[:78]))
        print("         (use tests/lib/guard-preflight.sh: guard_require_tools / "
              "guard_require_capability)")
    else:
        ok("all %d batch-run suite(s) are fail-closed on tooling — none can exit 0 unchecked"
           % len(batch))
    if unsourced:
        bad("suite(s) calling guard_require_* without sourcing %s (127 would be ignored): %s"
            % (LIB_REL, ", ".join(unsourced)))
    else:
        ok("every suite calling guard_require_* sources %s" % LIB_REL)

# The escape hatch must be a LOCAL one. This is the same control (t3) that
# tests/scripts/test-eso-seed-contract.sh runs on its own opt-out: a promise that
# "CI never sets it" is worth nothing unless something fails when CI does.
if OPT_OUT in ci:
    bad(".gitlab-ci.yml mentions %s — CI could switch every tooling preflight off:" % OPT_OUT)
    for i, line in enumerate(ci.split("\n")):
        if OPT_OUT in line:
            print("         .gitlab-ci.yml:%d: %s" % (i + 1, line.strip()[:78]))
else:
    ok(".gitlab-ci.yml never mentions %s — the CI path cannot opt out of a preflight" % OPT_OUT)

# And the helper itself must not become an unconditional skip.
lib_path = os.path.join(repo, LIB_REL)
if any(re.search(r"\bguard_require_(tools|capability)\b",
                 open(os.path.join(repo, r), encoding="utf-8", errors="replace").read())
       for r in suites if os.path.isfile(os.path.join(repo, r))):
    if not os.path.isfile(lib_path):
        bad("suites call guard_require_* but %s does not exist" % LIB_REL)
    else:
        lib = open(lib_path, encoding="utf-8", errors="replace").read()
        body = "\n".join(l for l in lib.split("\n") if not l.strip().startswith("#"))
        if OPT_OUT not in body:
            bad("%s no longer gates its skip on %s — it is an unconditional skip" % (LIB_REL, OPT_OUT))
        elif not re.search(r"exit\s+1", body):
            bad("%s never exits 1 — a missing tool would not fail anything" % LIB_REL)
        else:
            ok("%s skips ONLY under %s and otherwise exits 1" % (LIB_REL, OPT_OUT))

# ── 7) HOW MANY SUITES ACTUALLY GATE A PULL REQUEST ──────────────────────────
# Check 3 asks "does ANYTHING run this suite?" and answers it honestly. It is not
# the same question as "can this suite stop a bad merge", and conflating the two
# is how 123 guards came to gate nothing at all while this analyser printed green.
#
# Both runners check 3 accepts are POST-merge or no-merge:
#   * .gitlab-ci.yml — GitLab here is an in-cluster PULL MIRROR
#     (mirror_trigger_builds:true). Its pipelines run on the mirrored commit,
#     i.e. AFTER the merge that introduced the defect.
#   * the Makefile — a local target. It gates nothing; it is a convenience.
#
# Measured 2026-08-21 on this repo: 123 suites on disk, ZERO named by any
# GitHub Actions workflow. The one pull_request-triggered workflow
# (studio-tests.yml) runs the Studio pytest suite only — path-filtered, with
# tests/known-failures.txt deselected.
#
# This check does NOT demand the 123 be wired: which of them can even run in a
# hosted runner (docker, qemu, kind, node) is a real design question, not
# something a static analyser should force. What it refuses to allow is the
# number being INVISIBLE. It prints the ratio on every run and pins it, so the
# gap is a stated fact rather than an inference nobody draws, and so neither
# direction of drift is silent: unwiring a gated suite fails, and gating a new
# one fails until the baseline is raised to match (the same honesty rule check 4
# already applies to ALLOW_UNWIRED).
print()
print("-- 7) how many suites actually gate a pull request --")
PREMERGE_BASELINE = int(os.environ.get("PREMERGE_BASELINE", "0"))
wf_dir = os.path.join(repo, ".github", "workflows")
pr_wf, wf_text = [], ""
if os.path.isdir(wf_dir):
    for fn in sorted(os.listdir(wf_dir)):
        if not fn.endswith((".yml", ".yaml")):
            continue
        t = open(os.path.join(wf_dir, fn), encoding="utf-8", errors="replace").read()
        # Scan the top-level `on:` block WITHOUT PyYAML (python:3-slim has no yaml).
        # A trigger counts only inside that block, so a `pull_request` mentioned in
        # a job name, a comment or an `if:` does not fool this.
        on_block, in_on = [], False
        for line in t.split("\n"):
            if re.match(r"^(on|True)\s*:", line):
                in_on = True
                on_block.append(line)
                continue
            if in_on:
                if line.strip() and not line.startswith((" ", "\t")):
                    break
                on_block.append(line)
        if re.search(r"\bpull_request\b", "\n".join(on_block)):
            pr_wf.append(fn)
            # Comment lines are STRIPPED before matching. A workflow that documents
            # which suites it deliberately does NOT run — and it should — would
            # otherwise have those names counted as gated, so the number would grow
            # by writing prose. This check must measure what CI executes, not what
            # the file mentions.
            wf_text += "\n".join(
                l for l in t.split("\n") if not l.lstrip().startswith("#")
            ) + "\n"

gated = [s for s in suites
         if s in wf_text or (os.path.dirname(s) + "/*.sh") in wf_text]
n, total = len(gated), len(suites)
print("         %d of %d suites are named by a pull_request-triggered workflow"
      % (n, total))
print("         pull_request workflows: %s"
      % (", ".join(pr_wf) if pr_wf else "NONE"))
if n == PREMERGE_BASELINE:
    if n == 0:
        ok("pre-merge suite coverage pinned at 0/%d — no shell guard blocks a merge, "
           "and that fact is now asserted rather than implied" % total)
    else:
        ok("pre-merge suite coverage pinned at %d/%d" % (n, total))
elif n < PREMERGE_BASELINE:
    bad("pre-merge suite coverage DROPPED to %d, baseline is %d — a suite that used "
        "to block a bad merge no longer does" % (n, PREMERGE_BASELINE))
else:
    bad("pre-merge suite coverage rose to %d, baseline still says %d — raise "
        "PREMERGE_BASELINE to %d so the recorded number stays true"
        % (n, PREMERGE_BASELINE, n))

print()
print("== guard integrity: %d passed, %d failed ==" % (P[0], F[0]))
sys.exit(1 if F[0] else 0)
PY
rc=$?

# Re-raise the python verdict. (The very defect this suite exists to catch: the
# status has to survive the last line of the script.)
if [ "${rc}" -eq 0 ]; then ok "static guard-integrity analysis clean"; else bad "guard-integrity analysis reported defects (above)"; fi

# ── NEGATIVE CONTROLS ────────────────────────────────────────────────────────
# The whole point of this suite is that a guard which cannot go red is worthless,
# so it must demonstrate its OWN red. Synthesise a miniature repo carrying one
# deliberate instance of each defect and re-run the analyser against it via
# GUARD_ROOT; every case must FAIL, with the message that names it. A green run
# above therefore means "clean", never "the analyser silently did nothing".
if [ -z "${GUARD_SELFTEST_CHILD:-}" ]; then
  echo
  echo "-- negative controls: the analyser must go RED on planted defects --"
  SELF="${BASH_SOURCE[0]}"
  NEG="$(mktemp -d "${TMPDIR:-/tmp}/guard-integrity-neg.XXXXXX")"
  trap 'rm -rf "${NEG}"' EXIT

  # neg_case NAME EXPECTED_SUBSTRING  (tree already built in ${NEG}/tree)
  neg_case() {
    local name="$1" want="$2" out crc
    out="$(GUARD_SELFTEST_CHILD=1 GUARD_ROOT="${NEG}/tree" GUARD_ALLOW="" GUARD_PREMERGE=0 bash "${SELF}" 2>&1)"; crc=$?
    if [ "${crc}" -ne 0 ] && printf '%s' "${out}" | grep -qF "${want}"; then
      ok "negative control bites: ${name}"
    else
      bad "negative control did NOT bite (rc=${crc}): ${name} — wanted '${want}'"
      printf '%s\n' "${out}" | sed 's/^/           /'
    fi
  }

  build_tree() { # build_tree SUITE_BODY  -> a minimal repo whose only suite is that body
    rm -rf "${NEG}/tree"
    mkdir -p "${NEG}/tree/tests/probe"
    printf '%s\n' "$1" > "${NEG}/tree/tests/probe/test-probe.sh"
    printf 'probe-job:\n  script:\n    - bash tests/probe/test-probe.sh\n' > "${NEG}/tree/.gitlab-ci.yml"
    printf 'all:\n\t@true\n' > "${NEG}/tree/Makefile"
  }

  # (a) status-blind ending — the test-appset.sh shape, but a DIFFERENT instance:
  #     a `printf` verdict line rather than `echo "---EXIT $?---"`, and the
  #     verdict is produced by an awk program (so a naive scanner reading the
  #     last line of the embedded program would see something else entirely).
  build_tree 'F=0
awk "BEGIN{ print \"checking\" }" </dev/null
if ! grep -q nothing /dev/null; then F=1; fi
printf "probe: %s failed\n" "${F}"'
  neg_case "a suite ending on printf with no set -e" "ends on a status-blind command"

  # (b) counted-but-never-raised: bad() increments F, nothing turns F into a status.
  build_tree 'P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }
bad "something is wrong"
echo "== ${P} passed, ${F} failed =="
exit 0'
  neg_case "a failure counter nothing raises" "counted but never raised"

  # (c) the ORPHAN case: a second suite that no job and no make target names.
  build_tree 'echo ok
exit 0'
  printf 'echo orphan\nexit 0\n' > "${NEG}/tree/tests/probe/test-orphan.sh"
  neg_case "a suite nothing runs" "tests/probe/test-orphan.sh"

  # (d) a CI loop that runs suites and throws their status away.
  build_tree 'echo ok
exit 0'
  printf 'probe-job:\n  script:\n    - |\n      for t in tests/probe/*.sh; do\n        bash "${t}"\n      done\n' \
    > "${NEG}/tree/.gitlab-ci.yml"
  neg_case "a CI loop that discards a failing suite's status" "discard a failing suite"

  # (f) THE SILENT SELF-SKIP, in a shape nobody here wrote the check around:
  #     not `command -v`, not a one-liner, and the word SKIP is on a DIFFERENT
  #     line from the exit. A `[ -x … ]` probe on an absolute interpreter path is
  #     how a suite most naturally excuses itself without ever saying "command -v".
  build_tree 'P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }
if [ ! -x /opt/java/openjdk/bin/keytool ]; then
  echo "  SKIP no JDK in this image"
  exit 0
fi
ok "checked something"
echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]'
  printf 'batch-job:\n  script:\n    - |\n      SUITES="\n        tests/probe/test-probe.sh\n      "\n      rc=0\n      for t in ${SUITES}; do bash "$t" || rc=1; done\n      exit "${rc}"\n' \
    > "${NEG}/tree/.gitlab-ci.yml"
  neg_case "a batch-run suite that skips itself when the image lacks a tool" \
           "hand back exit 0 instead of a verdict"

  # (g) the escape hatch turned into a CI-wide off switch.
  build_tree 'P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }
ok "fine"
echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]'
  printf 'variables:\n  GUARD_TOOLING_ALLOW_SKIP: "1"\nbatch-job:\n  script:\n    - |\n      SUITES="\n        tests/probe/test-probe.sh\n      "\n      rc=0\n      for t in ${SUITES}; do bash "$t" || rc=1; done\n      exit "${rc}"\n' \
    > "${NEG}/tree/.gitlab-ci.yml"
  neg_case "CI setting the deliberate-local-opt-out variable" \
           "CI could switch every tooling preflight off"

  # (h) the helper called but never sourced: `guard_require_tools` would be a 127
  #     command-not-found and, with no `set -e`, execution walks straight past the
  #     preflight it was supposed to enforce.
  build_tree 'P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }
guard_require_tools openssl keytool
ok "fine"
echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]'
  printf 'batch-job:\n  script:\n    - |\n      SUITES="\n        tests/probe/test-probe.sh\n      "\n      rc=0\n      for t in ${SUITES}; do bash "$t" || rc=1; done\n      exit "${rc}"\n' \
    > "${NEG}/tree/.gitlab-ci.yml"
  neg_case "guard_require_* called without sourcing the helper" \
           "without sourcing tests/lib/guard-preflight.sh"

  # (i) check 7's own red: a suite that IS pull_request-gated while the recorded
  #     PREMERGE_BASELINE still says none is. The tree is otherwise CLEAN, so this
  #     case can only be biting on check 7. Without it the baseline could be pinned
  #     at a number nothing ever compares against — a check that only ever agrees
  #     with itself is the exact shape this file exists to catch.
  build_tree 'P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }
ok "nothing wrong"
echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]'
  mkdir -p "${NEG}/tree/.github/workflows"
  printf 'name: pr\non:\n  pull_request:\njobs:\n  t:\n    runs-on: ubuntu-latest\n    steps:\n      - run: bash tests/probe/test-probe.sh\n' \
    > "${NEG}/tree/.github/workflows/pr.yml"
  neg_case "a pre-merge-gated suite the baseline does not record" \
           "raise PREMERGE_BASELINE"

  # (e) POSITIVE control: the same miniature repo, all defects removed, must PASS.
  #     Without this, cases (a)-(d) could be passing because the child ALWAYS fails.
  build_tree 'P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }
ok "nothing wrong"
echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]'
  if GUARD_SELFTEST_CHILD=1 GUARD_ROOT="${NEG}/tree" GUARD_ALLOW="" GUARD_PREMERGE=0 bash "${SELF}" >/dev/null 2>&1; then
    ok "positive control: a clean miniature repo passes (the analyser is not just always-red)"
  else
    bad "positive control FAILED — the analyser rejects a clean tree, so (a)-(d) prove nothing"
    GUARD_SELFTEST_CHILD=1 GUARD_ROOT="${NEG}/tree" GUARD_ALLOW="" GUARD_PREMERGE=0 bash "${SELF}" 2>&1 | sed 's/^/           /'
  fi

  # ── DYNAMIC control: the real suites, really missing a real tool ────────────
  # Sections above are static analysis of source text. This runs three of the
  # actual guards with keytool genuinely absent from PATH and requires the
  # behaviour, not the shape: exit non-zero, naming keytool. It is the direct
  # re-enactment of what orphan-guards-verify did on alpine:3, where all three
  # printed "SKIP: need keytool" and exited 0.
  echo
  echo "-- dynamic control: a keytool-less PATH must make the keystore guards RED --"
  NOKT="${NEG}/nokeytool-bin"
  mkdir -p "${NOKT}"
  # openssl and python3 stay reachable so the failure message names keytool ALONE
  # — a message listing all three would not prove the JDK was what was missed.
  for b in bash env dirname mktemp rm openssl python3 cat sed grep awk; do
    src="$(command -v "${b}" 2>/dev/null)" && ln -sf "${src}" "${NOKT}/${b}"
  done
  if [ -x "${NOKT}/openssl" ] && [ -x "${NOKT}/python3" ] && [ -x "${NOKT}/dirname" ]; then
    for ks in test-keystores.sh test-keystores-external-ca.sh test-keystores-multidomain.sh; do
      KSP="${REPO}/tests/keystores/${ks}"
      [ -f "${KSP}" ] || { bad "dynamic control: ${KSP} missing"; continue; }
      KO="$(env -u GUARD_TOOLING_ALLOW_SKIP PATH="${NOKT}" bash "${KSP}" 2>&1)"; KRC=$?
      if [ "${KRC}" -ne 0 ] && printf '%s' "${KO}" | grep -qF "missing required tool(s): keytool"; then
        ok "dynamic: ${ks} FAILS (rc=${KRC}) with keytool absent — no silent green"
      else
        bad "dynamic: ${ks} did not fail closed without keytool (rc=${KRC}): ${KO}"
      fi
      KO="$(env GUARD_TOOLING_ALLOW_SKIP=1 PATH="${NOKT}" bash "${KSP}" 2>&1)"; KRC=$?
      if [ "${KRC}" -eq 0 ] && printf '%s' "${KO}" | grep -qF "GUARD_TOOLING_ALLOW_SKIP=1 was set"; then
        ok "dynamic: ${ks} honours the DELIBERATE local opt-out (rc=0, loud SKIP line)"
      else
        bad "dynamic: ${ks} ignored the explicit opt-out (rc=${KRC}): ${KO}"
      fi
    done
  else
    bad "dynamic control could not be set up (no openssl/python3/dirname to symlink) — not proven"
  fi
fi

echo
echo "== ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
