import { test, expect } from '@playwright/test';
import * as fs from 'node:fs';
import * as os from 'node:os';
import * as path from 'node:path';
import { execFileSync } from 'node:child_process';

// 35 — STACK-FREE unit coverage for shot-harness/evidence.mjs's missing-decoder path.
//
// hugmesh-generator#382: assertRealEvidence() flat-checks a screenshot with pngjs,
// but used to catch EVERY throw from `require('pngjs')` — including the decoder
// being unresolvable — and silently downgrade to `flatChecked: false, exit 0`.
// The README's own stated rationale for this whole module is "an empty or
// error-page PNG under a believable filename is worse than no PNG: it is
// indistinguishable from evidence to everyone who did not run the harness" — with
// pngjs unresolvable the gate did the OPPOSITE of that on exactly the images it
// exists to stop.
//
// THIS RUNS THE REAL evidence.mjs SOURCE, copied (never symlinked — Node resolves
// a symlink's real path for module resolution, which would land back on THIS
// repo's own node_modules and defeat the whole point) into an isolated tmp
// directory with no node_modules anywhere in its ancestry, so `require('pngjs')`
// from that copy genuinely cannot resolve — the same failure a skipped `npm ci`
// produces. It is not a stub standing in for the module; it is the file itself.

const REAL_EVIDENCE = path.resolve(__dirname, '..', 'shot-harness', 'evidence.mjs');
const PNG_SIG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

/** A buffer that clears every check BEFORE the pngjs require (signature, byte
 *  count, IHDR width/height) — real pixel data is irrelevant to this test. */
function fakePng(width = 400, height = 300, totalBytes = 4096): Buffer {
  const buf = Buffer.alloc(totalBytes);
  PNG_SIG.copy(buf, 0);
  buf.writeUInt32BE(width, 16);
  buf.writeUInt32BE(height, 20);
  return buf;
}

function isolatedEvidenceCopy(): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'evidence-mjs-no-pngjs-'));
  const dest = path.join(dir, 'evidence.mjs');
  fs.writeFileSync(dest, fs.readFileSync(REAL_EVIDENCE));
  return dest;
}

type ExecErr = { status: number | null; stdout?: string; stderr?: string };

test('fixture check: pngjs is genuinely unresolvable from the isolated copy '
  + '(or this whole spec proves nothing)', () => {
  const dest = isolatedEvidenceCopy();
  const probe = path.join(path.dirname(dest), 'probe.mjs');
  fs.writeFileSync(
    probe,
    "import { createRequire } from 'node:module';\n"
    + "createRequire(import.meta.url)('pngjs');\n"
    + "console.log('RESOLVED');\n",
  );
  expect(() => execFileSync(process.execPath, [probe], { stdio: 'pipe' })).toThrow();
});

test('a screenshot cleared by every pre-decode check is REJECTED, not silently '
  + 'accepted, when pngjs cannot be required', () => {
  const evidencePath = isolatedEvidenceCopy();
  const pngPath = path.join(path.dirname(evidencePath), 'shot.png');
  fs.writeFileSync(pngPath, fakePng());

  let stdout = '';
  let stderr = '';
  let status: number | null = 0;
  try {
    stdout = execFileSync(process.execPath, [evidencePath, pngPath], { encoding: 'utf8' });
  } catch (e) {
    const err = e as ExecErr;
    status = err.status;
    stdout = err.stdout ?? '';
    stderr = err.stderr ?? '';
  }

  // FAIL CLOSED: non-zero exit, nothing printed to stdout claiming "evidence",
  // and the file is still on disk (a broken harness is not the same failure as
  // a blank screenshot, so this is not the DELETING rejection path).
  expect(status).not.toBe(0);
  expect(stdout).not.toMatch(/evidence \(/);
  expect(stderr).toMatch(/pngjs/i);
  expect(fs.existsSync(pngPath)).toBe(true);
});

test('the SAME shape of fixture PNG, run through the real evidence.mjs in its own '
  + 'tree where pngjs IS resolvable, is accepted — proving the isolated copy is '
  + 'the only thing that changed between the two previous results', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'evidence-mjs-with-pngjs-'));
  const pngPath = path.join(dir, 'shot.png');

  // pngjs has no TS types shipped; evidence.mjs itself reaches it the same way,
  // via createRequire rather than a typed `import`.
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  const { PNG } = require('pngjs');
  const img = new PNG({ width: 400, height: 300 });
  for (let i = 0; i < img.data.length; i += 4) {
    const v = i % 256;
    img.data[i] = v; img.data[i + 1] = 255 - v; img.data[i + 2] = v % 128; img.data[i + 3] = 255;
  }
  fs.writeFileSync(pngPath, PNG.sync.write(img));

  const stdout = execFileSync(process.execPath, [REAL_EVIDENCE, pngPath], { encoding: 'utf8' });
  expect(stdout).toMatch(/evidence \(/);
  expect(stdout).toMatch(/flat-checked=true/);
});
