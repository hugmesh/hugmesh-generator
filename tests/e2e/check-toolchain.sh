#!/usr/bin/env bash
# check-toolchain.sh — is tests/e2e actually runnable on THIS box, right now?
#
# THE DEFECT THIS REPLACES (measured 2026-08-27 on origin/main f1c41bb3). Every
# e2e make target guarded itself with `[ -d tests/e2e/node_modules ]`, which any
# node_modules satisfies, however stale. On a box whose install predated the
# Gherkin lane the check passed and every target then died on
#     Error: Cannot find module 'playwright-bdd'
# from playwright.config.ts line 2 — or, for the browser half, a Studio-driven run
# (tests/e2e/test-results/studio-20260827-062152/report.json) recorded 36 of its
# 38 failures as
#     browserType.launch: Executable doesn't exist at .../chromium_headless_shell-1228/...
# because the pinned @playwright/test wanted headless-shell r1228 and only r1234
# (from some other Playwright) was in ~/.cache/ms-playwright. Every browser test
# failed for the toolchain, not the product, and nothing before the run said so.
# Meanwhile `make playwright-deps` ran `npm ci || npm install`, so a lock that had
# drifted from package.json (playwright-bdd declared, never locked) was papered
# over silently instead of failing.
#
# WHAT THIS VERIFIES, without network, in well under a second:
#   1. package.json and the COMMITTED package-lock.json agree — the lock's root
#      entry (`packages[""]`) carries the same dependency/devDependency ranges,
#      byte for byte, and the same lockfileVersion as npm's hidden lockfile below.
#      This is exactly the "in sync" `npm ci` demands; drift here is a REPO defect
#      (regenerate + commit the lock), not a box defect, and is reported as such.
#   2. node_modules exists and was written by npm (node_modules/.package-lock.json,
#      the hidden lockfile npm >= 7 writes after every install/ci) and that hidden
#      lockfile lists the SAME package set at the SAME versions as package-lock.json.
#      Equivalence chosen: every non-optional `packages` entry of the lock must be
#      in the hidden lock at the same version, every hidden entry must be in the
#      lock at the same version (an extraneous package is drift too), and
#      `optional: true` entries (fsevents on linux) may be absent but must match
#      when present. That is a full transitive comparison, not just the declared
#      deps: it costs one JSON parse each and catches a hand-copied or
#      partially-upgraded tree that a declared-deps-only check would pass.
#   3. The tree on DISK agrees with both locks: every non-optional lock entry has
#      node_modules/<path>/package.json at the locked version. The hidden lockfile
#      is npm's cache, not the truth — `rm -rf node_modules/playwright-bdd` leaves
#      it listing a package that is gone — so the disk is read as well.
#   4. Every dependency package.json declares resolves from tests/e2e
#      (`require.resolve`), which is what playwright.config.ts's own `require`s
#      will do.
#   5. The Chromium build the INSTALLED playwright-core pins is present under the
#      Playwright browsers path: for `chromium` and `chromium-headless-shell` (the
#      two `npx playwright install chromium` installs, and the two the suite
#      launches — headless runs use the headless shell), the revision named by
#      node_modules/playwright-core/browsers.json must have its directory
#      `<name with '-' -> '_'>-<revision>` and Playwright's own
#      INSTALLATION_COMPLETE marker there — and, because `playwright install`
#      writes that marker LAST, a marker over an emptied directory is a lie:
#      the revision dir must also hold at least one EXECUTABLE regular file
#      (a partial rm/cp of the cache leaves marker-only dirs that would die at
#      browserType.launch), and a revision dir that is a SYMLINK to a
#      DIFFERENT revision's directory (the re-planted r1228 -> r1234 alias)
#      is refused by name; a symlinked cache keeping the same revision passes. The path honours PLAYWRIGHT_BROWSERS_PATH
#      exactly as Playwright does ("0" = node_modules/playwright-core/.local-browsers,
#      a relative path resolves against INIT_CWD or $PWD, unset = XDG_CACHE_HOME or
#      ~/.cache on linux, ~/Library/Caches on darwin, then ms-playwright/). As a
#      second opinion from the runtime itself, playwright-core's PUBLIC
#      chromium.executablePath() must point at a file that exists.
#      NOT handled: browsers.json `revisionOverrides` (none exist for chromium; a
#      future one would make this report the base revision missing, i.e. fail
#      CLOSED, never open).
#
# OUTPUT — ALL OF IT ON STDERR, stdout stays empty. `make stack-e2e-list` runs this
# first and its stdout IS the JSON listing (`make stack-e2e-list | jq …`); a READY
# line on stdout would corrupt that document, which is exactly what the first
# version of this probe did. On success one line: `e2e toolchain: READY ...`, exit
# 0. Otherwise every problem found (not just the first), each naming the thing that
# is missing, then ONE fix line — `make playwright-deps` for anything about this
# box, or the regenerate-and-commit command when the lock itself has drifted — and
# exit 1. Exit 2 means the probe could not run at all (no node on PATH, no tests/e2e).
#
# KNOBS (all optional):
#   E2E_DIR=<path>              the tree to probe (default: this script's own dir)
#   PLAYWRIGHT_BROWSERS_PATH    as Playwright reads it
#   E2E_BROWSERS='chromium chromium-headless-shell'   which browsers.json entries
#                               must be installed
#
# This is a HELPER, not a test suite: tests/scripts/test-e2e-toolchain-readiness.sh
# is the suite, and it drives this file against synthesised trees carrying each
# defect on purpose.
set -euo pipefail

E2E_DIR="${E2E_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
E2E_BROWSERS="${E2E_BROWSERS:-chromium chromium-headless-shell}"

if [ ! -d "${E2E_DIR}" ]; then
  echo "e2e toolchain: cannot probe — ${E2E_DIR} is not a directory" >&2
  exit 2
fi
if ! command -v node >/dev/null 2>&1; then
  echo "e2e toolchain: cannot probe — 'node' is not on PATH (Node.js is required for the e2e suite at all)" >&2
  exit 2
fi

# ── the browsers path, resolved the way playwright-core resolves it ──────────
# Kept in bash rather than asked of playwright-core, because the whole point is
# to answer BEFORE trusting that node_modules is loadable.
browsers_path() {
  local env_defined="${PLAYWRIGHT_BROWSERS_PATH-}"
  local result=""
  if [ "${env_defined}" = "0" ]; then
    result="${E2E_DIR}/node_modules/playwright-core/.local-browsers"
  elif [ -n "${env_defined}" ]; then
    result="${env_defined}"
  else
    case "$(uname -s)" in
      Darwin) result="${HOME}/Library/Caches/ms-playwright" ;;
      *)      result="${XDG_CACHE_HOME:-${HOME}/.cache}/ms-playwright" ;;
    esac
  fi
  case "${result}" in
    /*) ;;
    *)  result="${INIT_CWD:-${PWD}}/${result}" ;;
  esac
  printf '%s\n' "${result}"
}
BROWSERS_PATH="$(browsers_path)"

# ── collect problems; never stop at the first ────────────────────────────────
PROBLEMS=()
LOCK_DRIFT=0
problem() { PROBLEMS+=("$1"); }

PKG="${E2E_DIR}/package.json"
LOCK="${E2E_DIR}/package-lock.json"
NM="${E2E_DIR}/node_modules"
HIDDEN="${NM}/.package-lock.json"

[ -f "${PKG}" ]  || problem "package.json is missing at ${PKG}"
[ -f "${LOCK}" ] || problem "package-lock.json is missing at ${LOCK} — it is COMMITTED (git checkout -- tests/e2e/package-lock.json), npm ci cannot run without it"
if [ ! -d "${NM}" ]; then
  problem "node_modules is missing at ${NM}"
elif [ ! -f "${HIDDEN}" ]; then
  problem "node_modules/.package-lock.json is missing — node_modules was not written by 'npm ci' / 'npm install' (npm >= 7), so nothing vouches for what is in it"
fi

# Everything JSON-shaped happens in ONE node process. It prints one line per
# problem, prefixed `DRIFT ` when the defect is the committed lock disagreeing
# with package.json (a different fix) and `PROBLEM ` otherwise, then a final
# `SUMMARY ...` line on success. It exits 0 in every case it could evaluate; a
# non-zero exit is a crash and is reported as its own problem below.
if [ -f "${PKG}" ] && [ -f "${LOCK}" ]; then
  NODE_ERR="$(mktemp "${TMPDIR:-/tmp}/e2e-toolchain-err.XXXXXX")"
  set +e
  NODE_OUT="$(E2E_DIR="${E2E_DIR}" BROWSERS_PATH="${BROWSERS_PATH}" E2E_BROWSERS="${E2E_BROWSERS}" node - 2>"${NODE_ERR}" <<'JS'
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const dir = process.env.E2E_DIR;
const browsersPath = process.env.BROWSERS_PATH;
const wanted = process.env.E2E_BROWSERS.split(/\s+/).filter(Boolean);
const out = [];
const drift = (m) => out.push('DRIFT ' + m);
const problem = (m) => out.push('PROBLEM ' + m);

const readJson = (p) => JSON.parse(fs.readFileSync(p, 'utf8'));
const pkg = readJson(path.join(dir, 'package.json'));
const lock = readJson(path.join(dir, 'package-lock.json'));
const nm = path.join(dir, 'node_modules');
const hiddenPath = path.join(nm, '.package-lock.json');

// 1. package.json vs the committed lock's root entry — the `npm ci` "in sync" rule.
const root = (lock.packages || {})[''] || {};
for (const field of ['dependencies', 'devDependencies']) {
  const want = pkg[field] || {};
  const have = root[field] || {};
  for (const [name, range] of Object.entries(want)) {
    if (!(name in have)) drift(`${field}.${name} is "${range}" in package.json but ABSENT from package-lock.json`);
    else if (have[name] !== range) drift(`${field}.${name} is "${range}" in package.json but "${have[name]}" in package-lock.json`);
  }
  for (const name of Object.keys(have)) {
    if (!(name in want)) drift(`${field}.${name} is in package-lock.json but not in package.json`);
  }
}
const declared = Object.keys(Object.assign({}, pkg.dependencies || {}, pkg.devDependencies || {}));

// 2. + 3. the hidden lockfile and the tree on disk vs the committed lock.
let installed = 0;
if (fs.existsSync(hiddenPath)) {
  const hidden = readJson(hiddenPath);
  if (hidden.lockfileVersion !== lock.lockfileVersion) {
    problem(`node_modules/.package-lock.json is lockfileVersion ${hidden.lockfileVersion} but package-lock.json is ${lock.lockfileVersion} — installed by a different npm; reinstall`);
  }
  const hp = hidden.packages || {};
  const lp = lock.packages || {};
  for (const [key, entry] of Object.entries(lp)) {
    if (key === '') continue;
    const h = hp[key];
    if (!h) {
      if (entry.optional) continue;        // e.g. fsevents on linux: legitimately absent
      problem(`${key} (locked at ${entry.version}) is not in node_modules/.package-lock.json — not installed`);
      continue;
    }
    if (h.version !== entry.version) {
      problem(`${key} is ${h.version} in node_modules but package-lock.json locks ${entry.version}`);
    }
    // the disk, not npm's cache of the disk
    const onDisk = path.join(dir, key, 'package.json');
    if (!fs.existsSync(onDisk)) {
      problem(`${key} is listed in node_modules/.package-lock.json but ${key}/package.json is gone from disk`);
    } else {
      let v;
      try { v = readJson(onDisk).version; } catch (e) { v = `<unreadable: ${e.message}>`; }
      if (v !== entry.version) problem(`${key}/package.json on disk says ${v} but package-lock.json locks ${entry.version}`);
      else installed++;
    }
  }
  for (const key of Object.keys(hp)) {
    if (!(key in lp)) problem(`${key} is installed (node_modules/.package-lock.json) but not in package-lock.json — extraneous; reinstall from the lock`);
  }
}

// 4. every declared dependency resolves from tests/e2e, as the config's require() will.
for (const name of declared) {
  try {
    require.resolve(name, { paths: [dir] });
  } catch (e) {
    problem(`dependency '${name}' does not resolve from ${dir} (${e.code || e.message})`);
  }
}

// 5. the browser build the INSTALLED playwright-core pins.
let pwCoreDir = null;
try {
  pwCoreDir = path.dirname(require.resolve('playwright-core/package.json', { paths: [dir] }));
} catch (e) {
  problem(`playwright-core does not resolve from ${dir} (${e.code || e.message}) — cannot even read which browser build is needed`);
}
const browserSummary = [];

// First file called `target` under root (symlinks followed, unreadable entries skipped).
const findFile = (root, target) => {
  const stack = [root];
  while (stack.length) {
    const cur = stack.pop();
    let entries = [];
    try { entries = fs.readdirSync(cur, { withFileTypes: true }); } catch (e) { continue; }
    for (const ent of entries) {
      const p = path.join(cur, ent.name);
      let st;
      try { st = fs.statSync(p); } catch (e) { continue; }
      if (st.isDirectory()) stack.push(p);
      else if (st.isFile() && ent.name === target) return p;
    }
  }
  return null;
};
// Run `<binary> --version`. null when it runs (or there is no such file to run);
// {exe, why} when the binary is there and does not execute. Fails CLOSED on a
// spawn error, a timeout, a signal and a non-zero exit.
const notRunnable = (bdir, target) => {
  const exe = findFile(bdir, target);
  if (!exe) return null;
  const r = spawnSync(exe, ['--version'], { timeout: 20000, encoding: 'utf8', stdio: ['ignore', 'ignore', 'pipe'] });
  if (r.error) return { exe, why: `could not be spawned (${r.error.code || r.error.message})` };
  if (r.signal) return { exe, why: `was killed by ${r.signal}` };
  if (r.status !== 0) return { exe, why: `exited ${r.status}${r.stderr ? ': ' + String(r.stderr).trim().split('\n')[0].slice(0, 200) : ''}` };
  return null;
};
if (pwCoreDir) {
  let descriptors = [];
  try {
    descriptors = readJson(path.join(pwCoreDir, 'browsers.json')).browsers || [];
  } catch (e) {
    problem(`${path.join(pwCoreDir, 'browsers.json')} is unreadable (${e.message})`);
  }
  for (const name of wanted) {
    const d = descriptors.find((b) => b.name === name);
    if (!d) { problem(`browsers.json of the installed playwright-core has no entry '${name}'`); continue; }
    const bdir = path.join(browsersPath, name.replace(/-/g, '_') + '-' + d.revision);
    const marker = path.join(bdir, 'INSTALLATION_COMPLETE');
    if (!fs.existsSync(bdir)) {
      // A DANGLING SYMLINK is the shape this box had: /var/tmp/portage/pw-browsers/
      // chromium_headless_shell-1228 -> ~/.cache/ms-playwright/chromium_headless_shell-1234,
      // planted 2026-08-26 to alias one revision as another, then orphaned when
      // `playwright install` pruned r1234. Name the target so nobody "fixes" it by
      // recreating the alias.
      let dangling = null;
      try { dangling = fs.readlinkSync(bdir); } catch (e) { /* not a symlink */ }
      problem(`${name} r${d.revision} (${d.browserVersion || 'version unknown'}) is not installed: ${bdir} ${dangling ? `is a symlink to ${dangling}, which does not exist` : 'does not exist'}`);
    } else if (!fs.existsSync(marker)) {
      problem(`${name} r${d.revision} is incomplete: ${marker} is missing (interrupted download?)`);
    } else {
      // The marker alone is not proof of a binary: `playwright install` writes
      // INSTALLATION_COMPLETE *last*, so an interrupted download never has it —
      // but a partial rm/cp (or a disk-full restore) can leave the marker over
      // an emptied directory, and a marker-only dir dies at browserType.launch
      // with exactly the "Executable doesn't exist" this probe exists to kill.
      // Headless shell has no public executablePath() accessor, so walk the
      // revision dir for at least one executable regular file besides
      // Playwright's own markers. Symlinks are followed; unreadable entries
      // are skipped (that can only make this fail CLOSED, never open).
      const hasExecutable = (root) => {
        const stack = [root];
        while (stack.length) {
          const cur = stack.pop();
          let entries = [];
          try { entries = fs.readdirSync(cur, { withFileTypes: true }); } catch (e) { continue; }
          for (const ent of entries) {
            const p = path.join(cur, ent.name);
            let st;
            try { st = fs.statSync(p); } catch (e) { continue; }   // dangling symlink etc.
            if (st.isDirectory()) stack.push(p);
            else if (st.isFile() && (st.mode & 0o111) && ent.name !== 'INSTALLATION_COMPLETE' && ent.name !== 'DEPENDENCIES_VALIDATED') return true;
          }
        }
        return false;
      };
      // A LIVE alias is the other half of the 2026-08-26 shape: the DANGLING
      // r1228 -> r1234 symlink is named above, but RECREATING the alias against
      // a directory that exists used to pass silently — and then a different
      // browser build runs. If the revision dir is a symlink whose target's
      // basename ends in `-<digits>`, those digits must be the pinned revision.
      // A relocated cache whose target keeps the same name (or carries no
      // revision suffix) still passes: symlinks are not banned, lies are.
      let alias = null;
      try {
        const target = fs.readlinkSync(bdir);   // throws when bdir is not a symlink
        const m = path.basename(target).match(/-(\d+)$/);
        if (m && m[1] !== d.revision) alias = { target, rev: m[1] };
      } catch (e) { /* not a symlink */ }
      if (alias) {
        problem(`${name} r${d.revision} is ALIASED to a different revision: ${bdir} is a symlink to ${alias.target} (r${alias.rev}) — a different browser build would run; remove the alias and install the real r${d.revision}`);
      } else if (!hasExecutable(bdir)) {
        problem(`${name} r${d.revision} is broken: ${bdir} carries INSTALLATION_COMPLETE but contains NO executable file — the binary is gone (partial copy or delete of the cache; the marker is written last, so this is not an interrupted download); reinstall`);
      } else {
        // The last rung: an executable bit is not a runnable binary. On
        // node:24-alpine (musl) Playwright downloads a GLIBC ubuntu24.04 fallback
        // build; every file check above passes, and the kernel then refuses the
        // ELF because its interpreter (/lib64/ld-linux-x86-64.so.2) is absent, which
        // spawn reports as a bare ENOENT. So actually RUN the binary. Only the
        // layouts this probe knows (chrome / chrome-headless-shell on Linux) are
        // run; an unknown layout is not guessed at (that can only skip this rung).
        const bad = notRunnable(bdir, name === 'chromium' ? 'chrome' : 'chrome-headless-shell');
        if (bad) {
          problem(`${name} r${d.revision} cannot execute: ${bad.exe} is on disk with its exec bit but \`--version\` ${bad.why} — the wrong libc or platform (a glibc build on musl/alpine reports spawn ENOENT), or missing shared libraries; reinstall a build that runs on this host`);
        } else {
          browserSummary.push(`${name} r${d.revision}`);
        }
      }
    }
  }
  // The runtime's own answer for the headed binary (public API). Headless-shell
  // has no public accessor, which is why the marker check above exists.
  if (wanted.includes('chromium')) {
    try {
      const pw = require(require.resolve('playwright-core', { paths: [dir] }));
      const exe = pw.chromium.executablePath();
      if (!exe) problem('playwright-core.chromium.executablePath() returned nothing for this platform');
      else if (!fs.existsSync(exe)) problem(`playwright-core says chromium lives at ${exe} and it does not exist`);
    } catch (e) {
      problem(`playwright-core could not be loaded to ask for chromium's executable path (${e.message.split('\n')[0]})`);
    }
  }
}

if (!out.length) {
  out.push(`SUMMARY node_modules matches package-lock.json (${installed} packages on disk, ${declared.length} declared deps resolve); ${browserSummary.join(' + ')} under ${browsersPath}`);
}
process.stdout.write(out.join('\n') + '\n');
JS
)"
  NODE_RC=$?
  set -e
  # The helper's stderr still reaches the caller as before (passthrough held the
  # stack trace), but a copy is kept so a crash can NAME its error in the problem
  # line instead of quoting the empty tail of an empty stdout.
  cat "${NODE_ERR}" >&2
  if [ "${NODE_RC}" -ne 0 ]; then
    ERR_HINT="$(grep -m 1 -e 'Error' "${NODE_ERR}" || tail -n 1 "${NODE_ERR}")"
    [ -n "${ERR_HINT}" ] || ERR_HINT="$(printf '%s' "${NODE_OUT}" | tail -n 1)"
    problem "the probe's node helper crashed (rc=${NODE_RC}): ${ERR_HINT}"
  else
    while IFS= read -r line; do
      case "${line}" in
        "DRIFT "*)   LOCK_DRIFT=1; problem "package.json / package-lock.json DISAGREE: ${line#DRIFT }" ;;
        "PROBLEM "*) problem "${line#PROBLEM }" ;;
        "SUMMARY "*) SUMMARY="${line#SUMMARY }" ;;
        "")          ;;
        *)           problem "unexpected probe output: ${line}" ;;
      esac
    done <<<"${NODE_OUT}"
  fi
  rm -f "${NODE_ERR}"
fi

if [ "${#PROBLEMS[@]}" -eq 0 ]; then
  echo "e2e toolchain: READY — ${SUMMARY:-verified}" >&2
  exit 0
fi

echo "e2e toolchain: NOT READY — ${#PROBLEMS[@]} problem(s) in ${E2E_DIR}:" >&2
for p in "${PROBLEMS[@]}"; do
  echo "  - ${p}" >&2
done
if [ "${LOCK_DRIFT}" -eq 1 ]; then
  echo "fix: the COMMITTED lock has drifted from package.json — regenerate and commit it:" >&2
  echo "       (cd ${E2E_DIR} && npm install) && git add ${E2E_DIR}/package-lock.json" >&2
  echo "     'make playwright-deps' runs 'npm ci' and will REFUSE until they agree." >&2
elif [ -n "${PLAYWRIGHT_BROWSERS_PATH-}" ]; then
  # `npx playwright install` honours the same variable, so the fix must carry it:
  # a bare `make playwright-deps` would install into the DEFAULT cache and this
  # probe, run again with the variable, would still say the browser is missing.
  echo "fix: PLAYWRIGHT_BROWSERS_PATH='${PLAYWRIGHT_BROWSERS_PATH}' make playwright-deps" >&2
else
  echo "fix: make playwright-deps" >&2
fi
exit 1
