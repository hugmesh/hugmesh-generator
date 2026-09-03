#!/usr/bin/env bash
# test-e2e-toolchain-readiness.sh — the e2e toolchain probe (tests/e2e/check-toolchain.sh)
# goes RED for every way an install can be stale, and every e2e make target runs it
# before anything else.
#
# WHY THIS FILE EXISTS. MEASURED 2026-08-27 on origin/main f1c41bb3: every e2e make
# target guarded itself with `[ -d tests/e2e/node_modules ]`, which any node_modules
# satisfies. This box's install predated the Gherkin lane, so stack-e2e,
# stack-e2e-list, stack-e2e-bdd, stack-e2e-bdd-check and stack-e2e-coverage-check
# all passed their own precondition and died on "Cannot find module 'playwright-bdd'"
# — the OFFLINE guards could not even start. The browser half was a Studio-driven
# run (tests/e2e/test-results/studio-20260827-062152/report.json) whose 36 of 38
# failures were "browserType.launch: Executable doesn't exist at
# .../chromium_headless_shell-1228/..." — the pinned @playwright/test wanted r1228,
# only r1234 was cached, and nothing before the run said so. And `make
# playwright-deps` ran `npm ci || npm install`, so a lock that had drifted from
# package.json (playwright-bdd declared, never locked) installed "successfully"
# while `npm ci` could not succeed at all.
#
# WHAT IT ASSERTS
#   A. On a synthesised, CONSISTENT tests/e2e tree (package.json, a v3 lock, npm's
#      hidden lockfile, the packages on disk, a playwright-core with a browsers.json
#      pinning revision 9999, and a browsers dir carrying r9999 with Playwright's
#      INSTALLATION_COMPLETE markers) the probe says READY and exits 0.
#   B. NEGATIVE CONTROLS: each stale-install shape, planted on a fresh copy of that
#      tree, makes the probe exit 1 and NAME the thing that is missing, plus the one
#      command that fixes it — `make playwright-deps` for the box, the
#      regenerate-and-commit command for a drifted lock. Every problem is listed,
#      not just the first. Optional deps (fsevents on linux) may be absent.
#      PLAYWRIGHT_BROWSERS_PATH is honoured exactly as playwright-core reads it.
#      Includes the 2026-08-27 skeptic's fail-open shapes: a browser dir holding
#      ONLY the INSTALLATION_COMPLETE marker (B2e), a LIVE symlink alias to a
#      different revision (B2f), and an unparseable package.json that crashes
#      the probe's node helper (B12) — each must exit 1 and be NAMED, and a
#      relocated same-revision symlink cache must still pass (B2g).
#   C. The Makefile RENDERS (`make -n`) the probe as the FIRST command of every
#      e2e target, and playwright-deps renders `npm ci` with no `|| npm install`,
#      `npx playwright install chromium` with `--with-deps` only under
#      PLAYWRIGHT_WITH_DEPS=1, and the probe again at the end.
#   D. The Makefile BEHAVES that way: in a sandbox with a stub probe and stub
#      npm/npx/run.sh, a failing probe stops every target before its real command
#      and a passing one lets it through; playwright-deps skips the install when
#      the probe passes, runs `npm ci` (never install) when it does not, fails with
#      the regenerate-and-commit message when npm ci fails, and cannot exit 0 while
#      the final probe still fails.
#   E. If THIS checkout has a tests/e2e/node_modules, the real probe must agree
#      with it: a stale toolchain on this box is exactly the defect above and is a
#      FAILURE here, naming the fix. With no install it SKIPS LOUDLY (counted, never
#      a pass) — the pre-merge images carry no node_modules.
#   F. The eight Gherkin guards under tests/scripts/test-e2e-*.sh run the probe as
#      their preflight (not a private `[ -d node_modules/playwright-bdd ]`), each
#      hands it the SAME PLAYWRIGHT_BROWSERS_PATH it runs the lane with, and a
#      failing probe makes each exit 2 SKIPPED-LOUDLY before any npx. Which path
#      that is differs per guard and the roster below is the record of it: five
#      still substitute /var/tmp/portage/pw-browsers when the caller set nothing,
#      two resolve AMBIENTLY (env-interface since PR #215, coverage-matrix since
#      PR #218 / 988d07c8), one launches no browser. MEASURED 2026-08-27:
#      stack-e2e-coverage-check got past the make-level probe (READY on the
#      default cache) and then died 20+ times on "Executable doesn't exist at
#      /var/tmp/portage/pw-browsers/chromium_headless_shell-1228" — the guard's
#      own browsers path held dangling r1228 -> r1234 aliases — reported as "the
#      whole coverage lane is not green". That measurement is WHY coverage-matrix
#      stopped defaulting; the travel is one-way (default -> ambient), so a guard
#      moving from the first list to the second is a fix and must be recorded
#      here, while one moving the other way is the regression this leg exists to
#      catch.
#
# Why revision 9999: the synthetic browsers.json pins a revision no real cache can
# satisfy, so a probe that ignored PLAYWRIGHT_BROWSERS_PATH and looked in
# ~/.cache/ms-playwright would fail leg A on a box that has real browsers installed.
#
# HERMETIC. Everything is built under mktemp; the repo's tests/e2e is only READ (leg
# E). bash + node + make. python3 is not needed.
#
#   bash tests/scripts/test-e2e-toolchain-readiness.sh
#   E2E_REAL_DIR=<tree> ... to point leg E at another installed tree.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"
PROBE="${REPO}/tests/e2e/check-toolchain.sh"
MAKEFILE="${REPO}/Makefile"
REAL_DIR="${E2E_REAL_DIR:-${REPO}/tests/e2e}"

for t in node make bash; do
  command -v "${t}" >/dev/null 2>&1 || { echo "SKIPPED-LOUDLY: ${t} is required and absent — this guard checked NOTHING (exit 2)" >&2; exit 2; }
done
[ -f "${PROBE}" ] || { echo "  FAIL ${PROBE} does not exist — the probe is gone"; exit 1; }
[ -f "${MAKEFILE}" ] || { echo "  FAIL ${MAKEFILE} does not exist"; exit 1; }

PASS=0; FAIL=0; SKIP=0
_ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
_bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1" >&2; }
_skip() { SKIP=$((SKIP+1)); printf '  SKIP %s\n' "$1"; }
eq()  { if [ "$1" = "$2" ]; then _ok "$3"; else _bad "$3"$'\n'"         got:  $1"$'\n'"         want: $2"; fi; }
has() { case "$2" in *"$1"*) _ok "$3" ;; *) _bad "$3"$'\n'"         wanted substring: $1"$'\n'"         in: $(printf '%s' "$2" | head -c 600)" ;; esac; }
hasnt() { case "$2" in *"$1"*) _bad "$3"$'\n'"         unwanted substring present: $1"$'\n'"         in: $(printf '%s' "$2" | head -c 600)" ;; *) _ok "$3" ;; esac; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/e2e-ready.XXXXXX")"
cleanup() { rm -rf "${TMP}"; }
trap cleanup EXIT INT TERM HUP

# ── the fixture: a consistent, tiny tests/e2e ────────────────────────────────
# Built by node so the JSON is real JSON. Every file the probe reads is here:
# package.json, package-lock.json (lockfileVersion 3, one nested key, one
# optional key that is NOT on disk), node_modules/.package-lock.json, each
# package's package.json + index.js, and a playwright-core whose browsers.json
# pins r9999 and whose index.js answers chromium.executablePath() the way the
# real one does (PLAYWRIGHT_BROWSERS_PATH, "0", default cache).
mk_tree() { # DIR
  node - "$1" <<'JS'
const fs = require('fs'), path = require('path');
const dir = process.argv[2];
const w = (rel, text) => { const p = path.join(dir, rel); fs.mkdirSync(path.dirname(p), { recursive: true }); fs.writeFileSync(p, text); };
const deps = { pngjs: '^7.0.0' };
const dev = { '@playwright/test': '~1.61.1', 'playwright-bdd': '^9.2.0' };
w('package.json', JSON.stringify({ name: 'probe-fixture', version: '0.0.0', private: true, dependencies: deps, devDependencies: dev }, null, 2));
const pkgs = {
  'node_modules/@playwright/test': { version: '1.61.1', dev: true },
  'node_modules/@playwright/test/node_modules/nested-dep': { version: '0.1.0', dev: true },
  'node_modules/playwright-core': { version: '1.61.1', dev: true },
  'node_modules/playwright-bdd': { version: '9.2.0', dev: true },
  'node_modules/pngjs': { version: '7.0.0' },
  'node_modules/fsevents': { version: '2.3.2', optional: true, os: ['darwin'] },
};
const lock = { name: 'probe-fixture', version: '0.0.0', lockfileVersion: 3, requires: true, packages: Object.assign({ '': { name: 'probe-fixture', version: '0.0.0', dependencies: deps, devDependencies: dev } }, pkgs) };
w('package-lock.json', JSON.stringify(lock, null, 2));
const hidden = { name: 'probe-fixture', version: '0.0.0', lockfileVersion: 3, requires: true, packages: {} };
for (const [k, v] of Object.entries(pkgs)) {
  if (k === 'node_modules/fsevents') continue;           // linux: not installed
  hidden.packages[k] = v;
  w(k + '/package.json', JSON.stringify({ name: path.basename(k), version: v.version, main: 'index.js' }));
  w(k + '/index.js', 'module.exports = {};\n');
}
w('node_modules/.package-lock.json', JSON.stringify(hidden, null, 2));
w('node_modules/playwright-core/browsers.json', JSON.stringify({ browsers: [
  { name: 'chromium', revision: '9999', installByDefault: true, browserVersion: '0.0.1' },
  { name: 'chromium-headless-shell', revision: '9999', installByDefault: true, browserVersion: '0.0.1' },
  { name: 'ffmpeg', revision: '1', installByDefault: true },
] }, null, 2));
w('node_modules/playwright-core/index.js', `
const path = require('path'), os = require('os');
function registryDir() {
  const env = process.env.PLAYWRIGHT_BROWSERS_PATH;
  let r;
  if (env === '0') r = path.join(__dirname, '.local-browsers');
  else if (env) r = env;
  else r = path.join(process.platform === 'darwin' ? path.join(os.homedir(), 'Library', 'Caches') : (process.env.XDG_CACHE_HOME || path.join(os.homedir(), '.cache')), 'ms-playwright');
  if (!path.isAbsolute(r)) r = path.resolve(process.env.INIT_CWD || process.cwd(), r);
  return r;
}
module.exports = { chromium: { executablePath: () => path.join(registryDir(), 'chromium-9999', 'chrome-linux64', 'chrome') } };
`);
JS
}

mk_browsers() { # DIR [revision]
  local rev="${2:-9999}"
  mkdir -p "$1/chromium-${rev}/chrome-linux64" "$1/chromium_headless_shell-${rev}/chrome-headless-shell-linux64"
  : > "$1/chromium-${rev}/INSTALLATION_COMPLETE"
  : > "$1/chromium-${rev}/chrome-linux64/chrome"
  : > "$1/chromium_headless_shell-${rev}/INSTALLATION_COMPLETE"
  : > "$1/chromium_headless_shell-${rev}/chrome-headless-shell-linux64/chrome-headless-shell"
  # the probe demands an EXECUTABLE regular file under each revision dir (a
  # marker-only dir is the fail-open the skeptic proved 2026-08-27), so the
  # stub binaries carry the bit a real install has.
  chmod +x "$1/chromium-${rev}/chrome-linux64/chrome" "$1/chromium_headless_shell-${rev}/chrome-headless-shell-linux64/chrome-headless-shell"
}

# fresh NAME -> a new consistent tree + browsers dir; sets T (tree) and B (browsers)
fresh() {
  T="${TMP}/$1/e2e"; B="${TMP}/$1/browsers"
  mkdir -p "${TMP}/$1"
  mk_tree "${T}"
  mk_browsers "${B}"
}

# probe [env assignments...] -> runs the REAL probe; OUT/ERR/RC set.
# PLAYWRIGHT_BROWSERS_PATH and E2E_DIR are scrubbed first so a leg that wants the
# default resolution gets it, and the operator's own setting cannot leak in.
probe() {
  local o="${TMP}/out.$$" e="${TMP}/err.$$"
  env -u PLAYWRIGHT_BROWSERS_PATH -u E2E_DIR -u XDG_CACHE_HOME -u INIT_CWD "$@" bash "${PROBE}" >"${o}" 2>"${e}"
  RC=$?
  OUT="$(cat "${o}")"; ERR="$(cat "${e}")"
}

echo "== e2e toolchain readiness: the probe bites, and every e2e target runs it =="
echo
echo "-- A) a consistent tree is READY --"
fresh a
probe E2E_DIR="${T}" PLAYWRIGHT_BROWSERS_PATH="${B}"
eq "${RC}" "0" "consistent tree: exit 0"
has "e2e toolchain: READY" "${ERR}" "consistent tree: says READY (on stderr)"
has "chromium r9999 + chromium-headless-shell r9999" "${ERR}" "READY line names the browsers and revision it verified"
has "5 packages on disk" "${ERR}" "READY line counts the packages it verified on disk (5: fsevents is optional and absent)"
# stdout is a CONTRACT: `make stack-e2e-list` runs the probe first and its stdout
# is the JSON listing — the first version of this probe printed READY there and
# broke `make stack-e2e-list | jq`. Measured, not guessed.
eq "${OUT}" "" "consistent tree: stdout is EMPTY (stack-e2e-list's stdout is a JSON document; the probe must not write into it)"

echo
echo "-- B) negative controls: every stale-install shape is NAMED, with its fix --"

# B1. the exact defect: a package the lock has and node_modules does not.
fresh b1; rm -rf "${T}/node_modules/playwright-bdd"
probe E2E_DIR="${T}" PLAYWRIGHT_BROWSERS_PATH="${B}"
eq "${RC}" "1" "B1 playwright-bdd deleted from node_modules: exit 1"
has "node_modules/playwright-bdd" "${ERR}" "B1 names node_modules/playwright-bdd"
has "gone from disk" "${ERR}" "B1 says it is gone from DISK (the hidden lockfile still lists it — the disk is what is read)"
has "dependency 'playwright-bdd' does not resolve" "${ERR}" "B1 require.resolve of the declared dep fails and is reported"
has "make playwright-deps" "${ERR}" "B1 the fix is make playwright-deps (carrying the browsers path this run was given)"
eq "${OUT}" "" "B1 stdout is EMPTY on failure too"
hasnt "toolchain: READY" "${ERR}" "B1 nothing claims READY"

# B2. the other half of the defect: the pinned browser revision is not installed.
fresh b2; rm -rf "${B}/chromium_headless_shell-9999"
probe E2E_DIR="${T}" PLAYWRIGHT_BROWSERS_PATH="${B}"
eq "${RC}" "1" "B2 headless shell r9999 absent: exit 1"
has "chromium-headless-shell r9999" "${ERR}" "B2 names chromium-headless-shell and the revision"
has "${B}/chromium_headless_shell-9999" "${ERR}" "B2 names the directory Playwright would look in"
has "make playwright-deps" "${ERR}" "B2 the fix is make playwright-deps"

fresh b2b; mk_browsers "${B}" 1234; rm -rf "${B}/chromium-9999" "${B}/chromium_headless_shell-9999"
probe E2E_DIR="${T}" PLAYWRIGHT_BROWSERS_PATH="${B}"
eq "${RC}" "1" "B2b only a DIFFERENT revision (1234) is present — the 2026-08-27 shape: exit 1"
has "chromium r9999" "${ERR}" "B2b names the revision the installed playwright-core pins, not the one that happens to be cached"
has "and it does not exist" "${ERR}" "B2b playwright-core's own executablePath() is asked and its answer checked"

fresh b2d; rm -rf "${B}/chromium_headless_shell-9999"; ln -s "${TMP}/b2d/nowhere-9999" "${B}/chromium_headless_shell-9999"
probe E2E_DIR="${T}" PLAYWRIGHT_BROWSERS_PATH="${B}"
eq "${RC}" "1" "B2d the browser dir is a DANGLING SYMLINK (the r1228 -> r1234 alias this box had): exit 1"
has "is a symlink to ${TMP}/b2d/nowhere-9999, which does not exist" "${ERR}" "B2d names the symlink's target so nobody recreates the alias"
has "fix: PLAYWRIGHT_BROWSERS_PATH='${B}' make playwright-deps" "${ERR}" "B2d the fix CARRIES the browsers path (npx playwright install honours it; a bare make playwright-deps would install elsewhere)"

fresh b2c; rm -f "${B}/chromium_headless_shell-9999/INSTALLATION_COMPLETE"
probe E2E_DIR="${T}" PLAYWRIGHT_BROWSERS_PATH="${B}"
eq "${RC}" "1" "B2c directory present but INSTALLATION_COMPLETE missing (interrupted download): exit 1"
has "incomplete" "${ERR}" "B2c says incomplete and names the marker"

# B2e. the marker WITHOUT the binary. `playwright install` writes the marker
# LAST, so this is never an interrupted download — it is a partial rm/cp of the
# cache, and it used to probe READY (the skeptic's 2026-08-27 fail-open proof:
# a dir holding only INSTALLATION_COMPLETE passed, then browserType.launch died
# with the exact "Executable doesn't exist" class the probe exists to kill).
fresh b2e; rm -rf "${B}/chromium_headless_shell-9999/chrome-headless-shell-linux64"
probe E2E_DIR="${T}" PLAYWRIGHT_BROWSERS_PATH="${B}"
eq "${RC}" "1" "B2e headless-shell dir holds ONLY the INSTALLATION_COMPLETE marker: exit 1"
has "NO executable file" "${ERR}" "B2e says no executable file is under it"
has "${B}/chromium_headless_shell-9999" "${ERR}" "B2e names the directory"
hasnt "toolchain: READY" "${ERR}" "B2e nothing claims READY"

# ... and a binary that LOST its exec bit is the same defect.
fresh b2e2; chmod -x "${B}/chromium_headless_shell-9999/chrome-headless-shell-linux64/chrome-headless-shell"
probe E2E_DIR="${T}" PLAYWRIGHT_BROWSERS_PATH="${B}"
eq "${RC}" "1" "B2e2 the headless-shell binary lost its exec bit: exit 1"
has "NO executable file" "${ERR}" "B2e2 reported as the same no-executable defect"

# B2f. a LIVE alias to a different revision — the re-planted 2026-08-26 shape.
# B2d catches the alias once it DANGLES; recreating it against a directory that
# EXISTS used to pass silently, and then a different browser build runs.
fresh b2f; mk_browsers "${B}" 1234
rm -rf "${B}/chromium_headless_shell-9999"
ln -s "${B}/chromium_headless_shell-1234" "${B}/chromium_headless_shell-9999"
probe E2E_DIR="${T}" PLAYWRIGHT_BROWSERS_PATH="${B}"
eq "${RC}" "1" "B2f the revision dir is a LIVE symlink to a different revision's dir: exit 1"
has "ALIASED" "${ERR}" "B2f says it is aliased"
has "chromium_headless_shell-1234" "${ERR}" "B2f names the target so nobody re-plants the alias"

# ... while a symlinked CACHE that keeps the revision honest still passes: the
# check compares the target basename's revision, it does not ban symlinks.
fresh b2g
b2g_store="${TMP}/b2g/real-store"; mkdir -p "${b2g_store}"
mv "${B}/chromium_headless_shell-9999" "${b2g_store}/chromium_headless_shell-9999"
ln -s "${b2g_store}/chromium_headless_shell-9999" "${B}/chromium_headless_shell-9999"
probe E2E_DIR="${T}" PLAYWRIGHT_BROWSERS_PATH="${B}"
eq "${RC}" "0" "B2g a symlink to the SAME revision (a relocated cache) is READY"

# B3. package.json bumped, lock not regenerated: the DRIFT class, different fix.
fresh b3; sed -i 's/"pngjs": "\^7.0.0"/"pngjs": "^8.0.0"/' "${T}/package.json"
grep -e '"pngjs": "^8.0.0"' "${T}/package.json" >/dev/null || _bad "B3 harness: the package.json mutation did not apply"
probe E2E_DIR="${T}" PLAYWRIGHT_BROWSERS_PATH="${B}"
eq "${RC}" "1" "B3 package.json bumped without regenerating the lock: exit 1"
has "DISAGREE" "${ERR}" "B3 says package.json / package-lock.json DISAGREE"
has 'dependencies.pngjs is "^8.0.0" in package.json but "^7.0.0" in package-lock.json' "${ERR}" "B3 names the dependency and both ranges"
has "npm install" "${ERR}" "B3 the fix is to regenerate the lock (npm install) ..."
has "package-lock.json" "${ERR}" "B3 ... and commit it"
has "REFUSE" "${ERR}" "B3 and says make playwright-deps (npm ci) will refuse until they agree"
hasnt "fix: make playwright-deps" "${ERR}" "B3 does NOT send the operator to make playwright-deps, which cannot fix a drifted lock"

fresh b3b; node -e 'const p=process.argv[1];const j=JSON.parse(require("fs").readFileSync(p));j.devDependencies["extra-dep"]="^1.0.0";require("fs").writeFileSync(p,JSON.stringify(j,null,2))' "${T}/package.json"
probe E2E_DIR="${T}" PLAYWRIGHT_BROWSERS_PATH="${B}"
eq "${RC}" "1" "B3b a dep declared in package.json but ABSENT from the lock (the playwright-bdd shape): exit 1"
has "devDependencies.extra-dep" "${ERR}" "B3b names the undeclared-in-lock dependency"
has "ABSENT from package-lock.json" "${ERR}" "B3b says it is absent from the lock"

# B4. the hidden lockfile disagrees with the committed lock.
fresh b4; sed -i 's/"version": "9.2.0"/"version": "9.1.0"/' "${T}/node_modules/.package-lock.json"
probe E2E_DIR="${T}" PLAYWRIGHT_BROWSERS_PATH="${B}"
eq "${RC}" "1" "B4 hidden lockfile has playwright-bdd 9.1.0, lock says 9.2.0: exit 1"
has "node_modules/playwright-bdd is 9.1.0 in node_modules but package-lock.json locks 9.2.0" "${ERR}" "B4 names the package and both versions"

fresh b4b; sed -i 's/"lockfileVersion": 3/"lockfileVersion": 2/' "${T}/node_modules/.package-lock.json"
probe E2E_DIR="${T}" PLAYWRIGHT_BROWSERS_PATH="${B}"
eq "${RC}" "1" "B4b lockfileVersion differs between the hidden lockfile and the lock: exit 1"
has "lockfileVersion 2 but package-lock.json is 3" "${ERR}" "B4b names both lockfile versions"

# B5. the disk disagrees with BOTH locks (a hand-copied node_modules).
fresh b5; node -e 'const p=process.argv[1];const j=JSON.parse(require("fs").readFileSync(p));j.version="6.0.0";require("fs").writeFileSync(p,JSON.stringify(j))' "${T}/node_modules/pngjs/package.json"
probe E2E_DIR="${T}" PLAYWRIGHT_BROWSERS_PATH="${B}"
eq "${RC}" "1" "B5 pngjs/package.json on disk is 6.0.0 while both locks say 7.0.0: exit 1"
has "node_modules/pngjs/package.json on disk says 6.0.0 but package-lock.json locks 7.0.0" "${ERR}" "B5 names the on-disk version against the lock"

# B6. an extraneous package (installed, unlocked).
fresh b6
mkdir -p "${T}/node_modules/leftpad"; printf '{"name":"leftpad","version":"0.0.1"}' > "${T}/node_modules/leftpad/package.json"
node -e 'const p=process.argv[1];const j=JSON.parse(require("fs").readFileSync(p));j.packages["node_modules/leftpad"]={version:"0.0.1"};require("fs").writeFileSync(p,JSON.stringify(j,null,2))' "${T}/node_modules/.package-lock.json"
probe E2E_DIR="${T}" PLAYWRIGHT_BROWSERS_PATH="${B}"
eq "${RC}" "1" "B6 a package installed but not in the lock: exit 1"
has "node_modules/leftpad" "${ERR}" "B6 names the extraneous package"
has "extraneous" "${ERR}" "B6 calls it extraneous"

# B7. the whole install is missing, or was not written by npm.
fresh b7; rm -rf "${T}/node_modules"
probe E2E_DIR="${T}" PLAYWRIGHT_BROWSERS_PATH="${B}"
eq "${RC}" "1" "B7 no node_modules at all: exit 1"
has "node_modules is missing" "${ERR}" "B7 says node_modules is missing"
has "make playwright-deps" "${ERR}" "B7 the fix is make playwright-deps"

fresh b7b; rm -f "${T}/node_modules/.package-lock.json"
probe E2E_DIR="${T}" PLAYWRIGHT_BROWSERS_PATH="${B}"
eq "${RC}" "1" "B7b node_modules present but npm's hidden lockfile absent: exit 1"
has "node_modules/.package-lock.json is missing" "${ERR}" "B7b names the hidden lockfile"

fresh b7c; rm -f "${T}/package-lock.json"
probe E2E_DIR="${T}" PLAYWRIGHT_BROWSERS_PATH="${B}"
eq "${RC}" "1" "B7c the committed lock is missing: exit 1"
has "package-lock.json is missing" "${ERR}" "B7c names the lock ..."
has "COMMITTED" "${ERR}" "B7c ... and says it is committed (restore it), since npm ci cannot run without it"

# B8. EVERY problem is listed, not the first one found.
fresh b8; rm -rf "${T}/node_modules/playwright-bdd"; rm -rf "${B}/chromium_headless_shell-9999"
probe E2E_DIR="${T}" PLAYWRIGHT_BROWSERS_PATH="${B}"
eq "${RC}" "1" "B8 two independent defects: exit 1"
has "node_modules/playwright-bdd" "${ERR}" "B8 the missing package is listed ..."
has "chromium-headless-shell r9999" "${ERR}" "B8 ... AND the missing browser, in the same run"
n_lines="$(printf '%s\n' "${ERR}" | grep -c -e '^  - ')"
if [ "${n_lines}" -ge 3 ]; then _ok "B8 ${n_lines} problem lines printed (package on disk, require.resolve, browser) — the probe does not stop at the first"; else _bad "B8 only ${n_lines} problem line(s) — the probe stops early"; fi

# B9. optional entries: absent is fine, present-but-wrong is not.
fresh b9
mkdir -p "${T}/node_modules/fsevents"; printf '{"name":"fsevents","version":"2.3.1"}' > "${T}/node_modules/fsevents/package.json"
node -e 'const p=process.argv[1];const j=JSON.parse(require("fs").readFileSync(p));j.packages["node_modules/fsevents"]={version:"2.3.1",optional:true};require("fs").writeFileSync(p,JSON.stringify(j,null,2))' "${T}/node_modules/.package-lock.json"
probe E2E_DIR="${T}" PLAYWRIGHT_BROWSERS_PATH="${B}"
eq "${RC}" "1" "B9 an optional dep that IS installed must still match the lock: exit 1"
has "node_modules/fsevents is 2.3.1 in node_modules but package-lock.json locks 2.3.2" "${ERR}" "B9 names it"
# (absent-optional-is-fine is leg A: the fixture never installs fsevents.)

echo
echo "-- B10) PLAYWRIGHT_BROWSERS_PATH is read exactly as playwright-core reads it --"
fresh b10
mk_browsers "${T}/node_modules/playwright-core/.local-browsers"
probe E2E_DIR="${T}" PLAYWRIGHT_BROWSERS_PATH=0
eq "${RC}" "0" "B10 PLAYWRIGHT_BROWSERS_PATH=0 -> node_modules/playwright-core/.local-browsers: READY when they are there"
rm -rf "${T}/node_modules/playwright-core/.local-browsers"
probe E2E_DIR="${T}" PLAYWRIGHT_BROWSERS_PATH=0
eq "${RC}" "1" "B10 ... and NOT READY when they are not, even though ${B} has them"
has ".local-browsers/chromium-9999" "${ERR}" "B10 names the .local-browsers path"

fresh b10b
home="${TMP}/b10b/home"; mkdir -p "${home}"; mk_browsers "${home}/.cache/ms-playwright"
probe E2E_DIR="${T}" HOME="${home}"
case "$(uname -s)" in
  Darwin) _skip "B10b default-path leg assumes the linux default (~/.cache/ms-playwright); on darwin it is ~/Library/Caches" ;;
  *)      eq "${RC}" "0" "B10b unset -> \$HOME/.cache/ms-playwright: READY" ;;
esac
xdg="${TMP}/b10b/xdg"; mkdir -p "${xdg}"
probe E2E_DIR="${T}" HOME="${home}" XDG_CACHE_HOME="${xdg}"
eq "${RC}" "1" "B10b XDG_CACHE_HOME wins over ~/.cache, as in playwright-core: NOT READY with an empty XDG cache"
has "${xdg}/ms-playwright/chromium-9999" "${ERR}" "B10b names the XDG path"
has "fix: make playwright-deps" "${ERR}" "B10b with PLAYWRIGHT_BROWSERS_PATH unset the fix is the BARE make playwright-deps (the install lands in the same default cache the probe looked in)"

fresh b10c
( cd "${TMP}/b10c" && mv browsers rel-browsers )
probe E2E_DIR="${T}" PLAYWRIGHT_BROWSERS_PATH=rel-browsers INIT_CWD="${TMP}/b10c"
eq "${RC}" "0" "B10c a RELATIVE path resolves against INIT_CWD (what npm/make set), as playwright-core does"
probe E2E_DIR="${T}" PLAYWRIGHT_BROWSERS_PATH=rel-browsers
eq "${RC}" "1" "B10c ... and against \$PWD without it (here: not the fixture dir)"

fresh b10d; rm -rf "${B}/chromium_headless_shell-9999"
probe E2E_DIR="${T}" PLAYWRIGHT_BROWSERS_PATH="${B}" E2E_BROWSERS=chromium
eq "${RC}" "0" "B10d E2E_BROWSERS=chromium narrows the required set (headless shell absent is then fine)"

echo
echo "-- B11) the probe cannot be mistaken for a verdict when it cannot run --"
probe E2E_DIR="${TMP}/does-not-exist" PLAYWRIGHT_BROWSERS_PATH="${TMP}"
eq "${RC}" "2" "B11 E2E_DIR that does not exist: exit 2 (not 0, not 1)"
has "cannot probe" "${ERR}" "B11 says it cannot probe"
nonode="${TMP}/nonode-bin"; mkdir -p "${nonode}"
for b in bash sh dirname uname tail printf cat env; do p="$(command -v "$b" 2>/dev/null)"; [ -n "$p" ] && ln -s "$p" "${nonode}/$b"; done
fresh b11
out="$(env -i PATH="${nonode}" HOME="${TMP}" E2E_DIR="${T}" PLAYWRIGHT_BROWSERS_PATH="${B}" bash "${PROBE}" 2>&1)"; rc=$?
eq "${rc}" "2" "B11 no node on PATH: exit 2"
has "'node' is not on PATH" "${out}" "B11 names node"

echo
echo "-- B12) a crashed helper is a PROBLEM, never READY --"
# The skeptic's 2026-08-27 blind spot: with the crash handler deleted from the
# probe, a tree whose package.json is unparseable garbage probed 'READY —
# verified' rc=0 (no problems collected, SUMMARY unset) — and this suite stayed
# green. This leg feeds the probe exactly that tree.
fresh b12; printf 'not json {' > "${T}/package.json"
probe E2E_DIR="${T}" PLAYWRIGHT_BROWSERS_PATH="${B}"
eq "${RC}" "1" "B12 package.json is unparseable garbage: exit 1"
has "node helper crashed" "${ERR}" "B12 the crash is reported as a problem, not swallowed"
has "Error" "${ERR}" "B12 the problem line carries the helper's own error (captured stderr), not an empty tail"
hasnt "toolchain: READY" "${ERR}" "B12 nothing claims READY"
eq "${OUT}" "" "B12 stdout stays empty even on a crash"

echo
echo "-- C) every e2e make target RENDERS the probe first (make -n) --"
render() { # TARGET [VAR=val...] -> rendered recipe, continuations joined, whitespace squeezed
  local target="$1"; shift
  env -u E2E_ARGS -u E2E_SPECS -u PUBLIC_HTTPS_PORT -u PLAYWRIGHT_WITH_DEPS make -n --no-print-directory -C "${REPO}" "${target}" "$@" 2>/dev/null | awk '
    { line = $0
      while (line ~ /\\$/) { sub(/\\$/, "", line); if ((getline nxt) <= 0) break; sub(/^[[:space:]]+/, "", nxt); line = line nxt }
      gsub(/[[:space:]]+/, " ", line); sub(/[[:space:]]+$/, "", line); print line }'
}
GATED_TARGETS="stack-e2e stack-e2e-list stack-e2e-bdd-gen stack-e2e-bdd-check stack-e2e-bdd stack-e2e-coverage-gen"
for t in ${GATED_TARGETS}; do
  eq "$(render "${t}" | sed -n '1p')" "bash tests/e2e/check-toolchain.sh || exit 2" \
     "${t}: the FIRST command is the probe, and its failure exits 2"
done
for t in kind-e2e kind-e2e-mfa e2e; do
  has "bash tests/e2e/check-toolchain.sh" "$(render "${t}")" "${t}: reaches the probe (through its playwright-deps prerequisite)"
done
pd="$(render playwright-deps)"
# Quoted strings are STRIPPED before the negative checks: the recipe's own failure
# message talks about the fallback it removed, and prose naming a shape must not
# read as the shape (the comment-stripping lesson in test-guard-integrity.sh).
pd_code="$(printf '%s\n' "${pd}" | sed -e 's/"[^"]*"//g' -e "s/'[^']*'//g")"
has "if bash tests/e2e/check-toolchain.sh; then exit 0; fi" "${pd}" "playwright-deps: skips the install when the PROBE passes (not when a directory exists)"
hasnt "[ -d node_modules ]" "${pd_code}" "playwright-deps: the '[ -d node_modules ]' shortcut is gone"
has "npm ci ||" "${pd_code}" "playwright-deps: runs npm ci and handles its failure ..."
hasnt "npm install" "${pd_code}" "playwright-deps: ... with NO 'npm install' anywhere in the recipe's code (lock drift must FAIL; quoted prose stripped first)"
has "COMMIT tests/e2e/package-lock.json" "${pd}" "playwright-deps: the npm ci failure message says to regenerate and COMMIT the lock"
has "npx playwright install chromium" "${pd}" "playwright-deps: installs chromium WITHOUT --with-deps by default (no sudo on this box)"
hasnt "--with-deps" "${pd}" "playwright-deps: --with-deps absent by default"
has "npx playwright install --with-deps chromium" "$(render playwright-deps PLAYWRIGHT_WITH_DEPS=1)" "playwright-deps: PLAYWRIGHT_WITH_DEPS=1 opts in to --with-deps"
case "${pd}" in
  *"npx playwright install chromium && cd ../.. && bash tests/e2e/check-toolchain.sh"*) _ok "playwright-deps: re-runs the probe AFTER installing, so it cannot exit 0 with the toolchain still broken" ;;
  *) _bad "playwright-deps: does not re-run the probe after installing"$'\n'"         got: ${pd}" ;;
esac

echo
echo "-- D) ... and BEHAVES that way (sandbox: stub probe, stub npm/npx/run.sh) --"
# The sandbox: a copy of the Makefile, a stub probe whose exit codes per call are
# scripted by PROBE_RCS (last value repeats) and counted in PROBE_COUNT, stub
# npm/npx on PATH and stub run.sh / gen-coverage-matrix.sh that record they ran.
mk_sandbox() { # -> dir
  local d
  d="$(mktemp -d "${TMP}/sbox.XXXXXX")"
  mkdir -p "${d}/tests/e2e" "${d}/bin" "${d}/scripts"
  cp "${MAKEFILE}" "${d}/Makefile"
  cat > "${d}/tests/e2e/check-toolchain.sh" <<'STUB'
#!/bin/sh
n=0; [ -f "${PROBE_COUNT}" ] && n="$(cat "${PROBE_COUNT}")"; n=$((n+1)); printf '%s\n' "$n" > "${PROBE_COUNT}"
rc=0; i=1
for r in ${PROBE_RCS:-0}; do rc="$r"; [ "$i" -ge "$n" ] && break; i=$((i+1)); done
echo "stub-probe call $n -> exit $rc"
exit "$rc"
STUB
  for s in npm npx; do
    cat > "${d}/bin/${s}" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "\${CALLS}/${s}"
[ "${s}" = npm ] && exit "\${NPM_RC:-0}"
exit 0
STUB
    chmod +x "${d}/bin/${s}"
  done
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "${CALLS}/run.sh"\nexit 0\n' > "${d}/tests/e2e/run.sh"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "${CALLS}/gen"\nexit 0\n' > "${d}/tests/e2e/gen-coverage-matrix.sh"
  # stack-e2e-bdd-check goes on to run the Gherkin guards under tests/scripts/;
  # stub every one the rendered recipe names so a PASSING probe can reach exit 0.
  for g in $(render stack-e2e-bdd-check | sed -n 's/^bash \(tests\/scripts\/[^ ]*\.sh\).*/\1/p'); do
    mkdir -p "${d}/$(dirname "${g}")"
    printf '#!/bin/sh\nexit 0\n' > "${d}/${g}"
  done
  printf '%s\n' "${d}"
}
# sandbox_make TARGET PROBE_RCS [NPM_RC] [extra make args...] -> sets RC, CALLS dir
sandbox_make() {
  local target="$1" rcs="$2" npm_rc="${3:-0}"; shift 3 2>/dev/null || shift $#
  local d
  d="$(mk_sandbox)"
  CALLS="${d}/calls"; mkdir -p "${CALLS}"
  env -u E2E_ARGS -u E2E_SPECS -u PLAYWRIGHT_WITH_DEPS PATH="${d}/bin:${PATH}" CALLS="${CALLS}" PROBE_COUNT="${CALLS}/probe.count" PROBE_RCS="${rcs}" NPM_RC="${npm_rc}" \
    make -s --no-print-directory -C "${d}" "${target}" "$@" >"${CALLS}/stdout" 2>"${CALLS}/stderr"
  RC=$?
}
called() { [ -f "${CALLS}/$1" ]; }
probe_calls() { cat "${CALLS}/probe.count" 2>/dev/null || echo 0; }

for t in ${GATED_TARGETS}; do
  case "${t}" in
    stack-e2e|stack-e2e-list) downstream=npx ;;
    stack-e2e-coverage-gen)   downstream=gen ;;
    *)                        downstream=run.sh ;;
  esac
  sandbox_make "${t}" 1
  if [ "${RC}" -ne 0 ] && ! called "${downstream}"; then
    _ok "${t}: a FAILING probe stops the target (make rc=${RC}) and ${downstream} never ran"
  else
    _bad "${t}: probe failed yet make rc=${RC}, ${downstream} ran=$(called "${downstream}" && echo yes || echo no)"
  fi
  sandbox_make "${t}" 0
  if [ "${RC}" -eq 0 ] && called "${downstream}"; then
    _ok "${t}: a PASSING probe lets the target through to ${downstream}"
  else
    _bad "${t}: probe passed yet make rc=${RC}, ${downstream} ran=$(called "${downstream}" && echo yes || echo no) — see ${CALLS}/stderr"
  fi
done

sandbox_make playwright-deps 0
if [ "${RC}" -eq 0 ] && ! called npm && ! called npx && [ "$(probe_calls)" = "1" ]; then
  _ok "playwright-deps: READY tree -> exit 0, npm and npx NOT run (kind-e2e/e2e can depend on it for free)"
else
  _bad "playwright-deps on a READY tree: rc=${RC} npm=$(called npm && echo ran || echo no) npx=$(called npx && echo ran || echo no) probe calls=$(probe_calls)"
fi

sandbox_make playwright-deps "1 0"
eq "${RC}" "0" "playwright-deps: NOT READY then READY after install -> exit 0"
eq "$(cat "${CALLS}/npm" 2>/dev/null)" "ci" "playwright-deps: npm was invoked exactly as 'npm ci' (once, never 'install')"
eq "$(cat "${CALLS}/npx" 2>/dev/null)" "playwright install chromium" "playwright-deps: npx was invoked as 'playwright install chromium' — no --with-deps"
eq "$(probe_calls)" "2" "playwright-deps: the probe ran twice — before (decides) and after (verifies)"

sandbox_make playwright-deps "1 0" 0 PLAYWRIGHT_WITH_DEPS=1
eq "$(cat "${CALLS}/npx" 2>/dev/null)" "playwright install --with-deps chromium" "playwright-deps PLAYWRIGHT_WITH_DEPS=1: npx gets --with-deps"

sandbox_make playwright-deps "1 0" 1
if [ "${RC}" -ne 0 ] && ! called npx; then _ok "playwright-deps: npm ci FAILS -> make fails (rc=${RC}) and the browser install never runs"; else _bad "playwright-deps: npm ci failed yet rc=${RC}, npx ran=$(called npx && echo yes || echo no)"; fi
has "npm ci FAILED" "$(cat "${CALLS}/stdout" "${CALLS}/stderr")" "playwright-deps: says npm ci failed ..."
has "COMMIT tests/e2e/package-lock.json" "$(cat "${CALLS}/stdout" "${CALLS}/stderr")" "playwright-deps: ... and to run npm install and COMMIT the lock"
eq "$(cat "${CALLS}/npm" 2>/dev/null)" "ci" "playwright-deps: after npm ci failed, npm was NOT re-run as 'npm install' (the old fallback stays dead)"

sandbox_make playwright-deps "1 1"
if [ "${RC}" -ne 0 ] && [ "$(probe_calls)" = "2" ]; then _ok "playwright-deps: install ran but the probe STILL fails -> make fails (rc=${RC}); it cannot exit 0 with a broken toolchain"; else _bad "playwright-deps: final probe failed yet rc=${RC} (probe calls=$(probe_calls))"; fi

echo
echo "-- E) the REAL probe against THIS checkout's install --"
if [ ! -d "${REAL_DIR}/node_modules" ]; then
  _skip "no ${REAL_DIR}/node_modules — the real-tree leg asserted nothing (the pre-merge images carry no install; run 'make playwright-deps' on a box to exercise it)"
else
  out="$(E2E_DIR="${REAL_DIR}" bash "${PROBE}" 2>&1)"; rc=$?
  if [ "${rc}" -eq 0 ]; then
    _ok "the real probe agrees with the real install: $(printf '%s' "${out}" | head -c 200)"
  else
    _bad "THE e2e TOOLCHAIN ON THIS BOX IS STALE (probe rc=${rc}) — every e2e target would have stopped here, which is the point:"$'\n'"$(printf '%s\n' "${out}" | sed 's/^/         /')"
  fi
fi

echo
echo "-- F) the Gherkin guards run the probe as THEIR preflight, with THEIR browsers path --"
# Each guard is copied into a scratch repo layout (it locates tests/e2e from its own
# path), with a stub probe that records the PLAYWRIGHT_BROWSERS_PATH it was handed
# and exits 1, and a stub npx that must never be reached. python3/git are on the
# guards' own `command -v` preflights, so they are needed here too.
GUARDS_WITH_BROWSER="test-e2e-cli-lane test-e2e-func-media-games test-e2e-governance-function-matrix test-e2e-social-function-matrix test-e2e-studio-gui-lane"
# GUARDS_AMBIENT launch a browser but resolve it AMBIENTLY — they honour
# PLAYWRIGHT_BROWSERS_PATH only if the caller set it and substitute NOTHING when
# they did not — so their probe must see the ambient (unset) path too, or it
# would vet a store the lane never uses. Two guards are here, each by a
# deliberate production change this leg follows rather than fights:
#   * env-interface-dimensions — PR #215 dropped its forced
#     /var/tmp/portage/pw-browsers override.
#   * coverage-matrix — 988d07c8 (PR #218, 2026-08-27) DELETED its lane-site
#     `export PLAYWRIGHT_BROWSERS_PATH=...pw-browsers}"` on a measurement: the
#     farm is a host-local symlink tree whose target revisions any
#     `npx playwright install` garbage-collects, and with it dangling the
#     124-cell wiki spec ran 101.6s ALL RED ("Executable doesn't exist", twice
#     per cell under retries:1) against 15.2s green with the variable unset —
#     ~29 min extrapolated over the 2105-cell lane, i.e. the >25-minute timeout
#     kill. Read the "WHERE THE BROWSER LIVES" note at the top of that guard,
#     and reference_hugmesh_pw_browsers_symlink_farm. It also stopped shipping
#     the farm in its remediation text, so nothing here may re-assert the
#     default for it: this leg went on listing it under GUARDS_WITH_BROWSER for
#     five days after #218 landed, and failed that one assertion the whole time.
# The remaining five ARE still expected to default, and are asserted to, so this
# leg keeps recording reality; retiring the default from them (in flight as
# fix/pw-browsers-never-default, PR #249) moves them here too.
GUARDS_AMBIENT="test-e2e-env-interface-dimensions test-e2e-coverage-matrix"
GUARDS_WITHOUT="test-e2e-gherkin-harness"
if ! command -v python3 >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  _skip "python3/git absent — the guards' own preflights would exit before reaching the probe; leg F asserted nothing"
else
  for g in ${GUARDS_WITH_BROWSER} ${GUARDS_AMBIENT} ${GUARDS_WITHOUT}; do
    src="${REPO}/tests/scripts/${g}.sh"
    if [ ! -f "${src}" ]; then _bad "F ${g}.sh is missing"; continue; fi
    G="${TMP}/guard-${g}"; mkdir -p "${G}/tests/scripts" "${G}/tests/e2e" "${G}/bin"
    cp "${src}" "${G}/tests/scripts/${g}.sh"
    printf '#!/bin/sh\nexit 0\n' > "${G}/tests/e2e/run.sh"     # cli-lane checks the entry point exists BEFORE probing
    printf '#!/bin/sh\nprintf "%%s\\n" "${PLAYWRIGHT_BROWSERS_PATH-<unset>}" > "%s/probe.env"\necho "stub probe: NOT READY" >&2\nexit 1\n' "${G}" > "${G}/tests/e2e/check-toolchain.sh"
    printf '#!/bin/sh\n: > "%s/npx.ran"\nexit 0\n' "${G}" > "${G}/bin/npx"; chmod +x "${G}/bin/npx"
    out="$(cd "${G}" && env -u PLAYWRIGHT_BROWSERS_PATH PATH="${G}/bin:${PATH}" bash "tests/scripts/${g}.sh" 2>&1)"; rc=$?
    if [ "${rc}" -eq 2 ] && [ ! -e "${G}/npx.ran" ]; then _ok "F ${g}: a failing probe -> exit 2, npx never reached"; else _bad "F ${g}: probe failed yet rc=${rc}, npx ran=$([ -e "${G}/npx.ran" ] && echo yes || echo no)"$'\n'"$(printf '%s\n' "${out}" | tail -n 5 | sed 's/^/         /')"; fi
    has "SKIPPED-LOUDLY" "${out}" "F ${g}: says SKIPPED-LOUDLY"
    got="$(cat "${G}/probe.env" 2>/dev/null || echo '<probe never ran>')"
    case " ${GUARDS_WITH_BROWSER} " in
      *" ${g} "*) eq "${got}" "/var/tmp/portage/pw-browsers" "F ${g}: the probe is handed the guard's own default browsers path (unset -> /var/tmp/portage/pw-browsers)" ;;
      *)
        case " ${GUARDS_AMBIENT} " in
          *" ${g} "*) eq "${got}" "<unset>" "F ${g}: NEVER defaults PLAYWRIGHT_BROWSERS_PATH, so the probe sees the ambient (unset) browsers path — the same one the lane runs with" ;;
          *)          eq "${got}" "<unset>" "F ${g}: launches no browser, so the probe sees the ambient (unset) browsers path" ;;
        esac ;;
    esac
  done
  # ... and the operator's own value reaches the probe UNCHANGED, as it does for
  # the lane. Run against coverage-matrix, an ambient guard, on purpose: for
  # those the unset leg above cannot tell "never touches the variable" from
  # "unsets it before the probe" — both hand the probe <unset> — and a guard
  # that dropped the caller's value would vet a store nobody asked for.
  g=test-e2e-coverage-matrix; G="${TMP}/guard-${g}"
  ( cd "${G}" && env PLAYWRIGHT_BROWSERS_PATH=/somewhere/else PATH="${G}/bin:${PATH}" bash "tests/scripts/${g}.sh" >/dev/null 2>&1 )
  eq "$(cat "${G}/probe.env" 2>/dev/null)" "/somewhere/else" "F ${g}: an explicit PLAYWRIGHT_BROWSERS_PATH reaches the probe unchanged"
fi

echo
echo "== RESULT: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped =="
[ "${FAIL}" -eq 0 ]
