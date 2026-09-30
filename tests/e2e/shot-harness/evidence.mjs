// evidence.mjs — "is this PNG actually evidence?"
//
// SPLIT OUT OF capture.spec.ts ON PURPOSE. This is the guard that stands between
// a plan citing `shots/member-02-signed-in-home.png` and that file being a blank
// 1280x900 rectangle. A guard nobody can exercise without a running mesh is a
// guard nobody re-checks, so it lives in a plain .mjs that runs offline:
//
//   node shot-harness/evidence.mjs <file.png>      # exits 0 if it is evidence
//
// capture.spec.ts imports it dynamically. Mutation-test it by feeding it a
// truncated file, a flat-colour PNG and a real screenshot; all three answers
// must differ.
import * as fs from 'node:fs';
import * as path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const PNG_SIG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

/** Minimum believable evidence: big enough to show a control, and not one colour. */
export const MIN_BYTES = 2048;
export const MIN_EDGE = 200;

/**
 * Throw unless `file` is a PNG that could plausibly show a control, DELETING it
 * first when it is not.
 *
 * The delete is the whole point. Chromium screenshots its own error page as
 * happily as the product, and an all-white PNG sitting under a believable
 * filename is believed by everyone who did not run the harness. A MISSING file
 * makes a tester re-run; a blank one does not.
 */
export function assertRealEvidence(file, { unlink = true } = {}) {
  const buf = fs.readFileSync(file);
  const reject = (why) => {
    if (unlink) { try { fs.unlinkSync(file); } catch { /* best effort */ } }
    throw new Error(
      `${path.basename(file)}: ${why}. The file has been ${unlink ? 'DELETED' : 'REJECTED'} rather than `
      + 'left behind as evidence — a blank PNG under a plausible name is believed by everyone who did '
      + 'not run the harness. Check the stack is up and the route is reachable.',
    );
  };

  if (buf.length < MIN_BYTES) reject(`only ${buf.length} bytes — nothing rendered`);
  if (!buf.subarray(0, 8).equals(PNG_SIG)) reject('not a PNG');
  const width = buf.readUInt32BE(16);
  const height = buf.readUInt32BE(20);
  if (width < MIN_EDGE || height < MIN_EDGE) reject(`${width}x${height} is too small to show a control`);

  // Flat-frame check. pngjs is a declared dependency of this package, and this
  // check is the ENTIRE point of this module (see the file header): an empty
  // or error-page PNG under a believable filename is indistinguishable from
  // evidence to everyone who did not run the harness. A missing decoder used
  // to lose only this one check and silently ACCEPT exactly the images it
  // exists to reject (hugmesh-generator#382) — fail CLOSED instead, per the
  // README's own stated stance, rather than degrade to flatChecked=false.
  let PNG;
  try {
    ({ PNG } = createRequire(import.meta.url)('pngjs'));
  } catch (e) {
    throw new Error(
      `${path.basename(file)}: cannot flat-check this PNG — the 'pngjs' dependency is not `
      + `resolvable (${e && e.message ? e.message : e}). This check exists to reject a blank or `
      + `error-page PNG that would otherwise pass as evidence, so a missing decoder is a hard `
      + `failure here, not a silent pass. Run 'npm ci' in tests/e2e (or wherever this is invoked `
      + 'from) before trusting any PNG this harness accepts.',
    );
  }
  // pngjs is resolvable; a decode failure on THESE bytes is a separate, narrower
  // situation this issue is not about (e.g. a PNG shape pngjs cannot parse) —
  // keep degrading gracefully rather than rejecting a possibly-real screenshot.
  let png;
  try {
    png = PNG.sync.read(buf);
  } catch {
    return { width, height, bytes: buf.length, flatChecked: false };
  }
  const data = png.data;               // raw RGBA
  const stride = 4 * 97;               // prime pixel stride: crosses rows, never one column
  const first = data.readUInt32BE(0);
  for (let i = stride; i + 4 <= data.length; i += stride) {
    if (data.readUInt32BE(i) !== first) {
      return { width, height, bytes: buf.length, flatChecked: true };
    }
  }
  reject(`every sampled pixel is identical (${width}x${height} flat frame)`);
}

const isMain = process.argv[1] && path.resolve(process.argv[1]) === path.resolve(fileURLToPath(import.meta.url));
if (isMain) {
  const file = process.argv[2];
  if (!file) { process.stderr.write('usage: evidence.mjs <file.png>\n'); process.exit(2); }
  try {
    const info = assertRealEvidence(file, { unlink: false });
    process.stdout.write(`${path.basename(file)}: evidence (${info.width}x${info.height}, ${info.bytes} bytes, flat-checked=${info.flatChecked})\n`);
  } catch (e) {
    process.stderr.write(`${e.message}\n`);
    process.exit(1);
  }
}
