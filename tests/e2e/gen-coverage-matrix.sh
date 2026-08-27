#!/usr/bin/env bash
# gen-coverage-matrix.sh — re-emit tests/e2e/features/coverage/ from the
# catalogues. Run this after adding a persona, a service or a function.
#
#   bash tests/e2e/gen-coverage-matrix.sh                 # write into the repo
#   bash tests/e2e/gen-coverage-matrix.sh --out <dir>     # write into <dir> instead
#
# WHY A SHELL WRAPPER AND NOT `node tools/emit-coverage-matrix.ts`. The catalogue
# reaches steps/dimensions.ts, which imports '../specs/rbac-roles' EXTENSIONLESS.
# Node's own type-stripping loads a .ts file as ESM, and ESM resolution has no
# extension search — so a bare `node` invocation dies with ERR_MODULE_NOT_FOUND
# no matter what the emitter does (measured on node v26.7.0, both for .ts and
# .cts, with and without --experimental-strip-types). Playwright's TypeScript
# transform resolves it exactly as the test suite does, so the emitter runs
# through a one-test Playwright config in a scratch dir with node_modules
# SYMLINKED beside it (module resolution walks up from the config's own
# directory, so a config outside tests/e2e cannot otherwise find
# @playwright/test).
#
# NOTHING IS STARTED. This reads committed files and writes .feature files.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E="${HERE}"
OUT="${E2E}/features/coverage"

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ ! -d "${E2E}/node_modules/@playwright/test" ]; then
  echo "SKIPPED-LOUDLY: ${E2E}/node_modules/@playwright/test is missing — run" >&2
  echo "  (cd ${E2E} && npm install)   [or: make playwright-deps]" >&2
  echo "NOTHING WAS EMITTED. Exiting 2 rather than 0." >&2
  exit 2
fi

WORK="${TMPDIR:-/var/tmp/portage}/coverage-emit.$$"
mkdir -p "${WORK}"
trap 'rm -rf "${WORK}"' EXIT
ln -sfn "${E2E}/node_modules" "${WORK}/node_modules"

# outputDir is pinned INSIDE the scratch dir on purpose: Playwright writes
# test-results/.last-run.json relative to the invoking cwd otherwise, so running
# this from the repo root littered an untracked test-results/ into the tree.
cat > "${WORK}/pw.config.ts" <<'TS'
import { defineConfig } from '@playwright/test';
import * as path from 'node:path';
export default defineConfig({
  testDir: __dirname, outputDir: path.join(__dirname, 'pw-out'),
  reporter: [['dot']], workers: 1, retries: 0, timeout: 120_000,
});
TS

# QUOTED heredoc + sed'd placeholders: an unquoted one would let bash execute the
# backticks and ${...} inside the emitted TypeScript, a trap this repo has been
# bitten by before.
cat > "${WORK}/emit.spec.ts" <<'TS'
import { test } from '@playwright/test';
import { writeAll } from '__EMITTER__';

test('emit the coverage matrix', () => {
  const r = writeAll('__OUT__');
  for (const f of r.removed) process.stdout.write(`REMOVED ${f}\n`);
  for (const f of r.written) process.stdout.write(`WROTE   ${f}\n`);
  process.stdout.write(`EMITTED ${r.written.length} feature file(s) into __OUT__\n`);
});
TS
sed -i -e "s|__EMITTER__|${E2E}/tools/emit-coverage-matrix|" \
       -e "s|__OUT__|${OUT}|g" "${WORK}/emit.spec.ts"

mkdir -p "${OUT}"
npx --prefix "${E2E}" playwright test -c "${WORK}/pw.config.ts" --reporter=list 2>&1 \
  | sed -n '/^\(WROTE\|REMOVED\|EMITTED\)/p;/Error\|error\|✘/p'
rc="${PIPESTATUS[0]}"
if [ "${rc}" -ne 0 ]; then
  echo "EMIT FAILED (rc=${rc}). The feature files were NOT refreshed." >&2
  exit "${rc}"
fi
