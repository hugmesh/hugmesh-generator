import * as crypto from 'node:crypto';

// RFC-6238 TOTP, parameter-locked to the platform's authenticator contract
// (hugmesh-auth-core mfa/TotpService.java: HMAC-SHA1, DIGITS=6, STEP_SECONDS=30,
// base32 secret, ±1-step skew window above a strictly-greater-than replay floor).
// Implemented inline on node:crypto rather than pulling a TOTP dependency so the
// spec that drives the REAL enroll/challenge pages (29-mfa-privileged-floor)
// stays hermetic — and so a drift in the server's parameters shows up as a failed
// verify, never as two libraries silently agreeing with each other.
//
// Correctness is NOT asserted in this comment: 29-mfa-privileged-floor's first
// describe is a stack-free test that runs these functions against the six RFC 6238
// Appendix B SHA-1 vectors (truncated to DIGITS=6). If this file drifts, that test
// fails before any stack leg runs, so a bad code can never be misread as a server
// rejection.

const STEP_SECONDS = 30;
const DIGITS = 6;
const B32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

/** Decode an RFC-4648 base32 string (the `mfa-secret` the enroll wizard shows;
 *  whitespace/padding tolerated, case-insensitive). Throws on any other char —
 *  a garbled secret must fail loudly, not verify against garbage bytes. */
export function base32Decode(secret: string): Buffer {
  const clean = secret.toUpperCase().replace(/[\s=]/g, '');
  let bits = 0;
  let value = 0;
  const out: number[] = [];
  for (const ch of clean) {
    const idx = B32.indexOf(ch);
    if (idx < 0) throw new Error(`not a base32 TOTP secret (char '${ch}'): ${secret}`);
    value = (value << 5) | idx;
    bits += 5;
    if (bits >= 8) {
      out.push((value >>> (bits - 8)) & 0xff);
      bits -= 8;
    }
  }
  return Buffer.from(out);
}

/** The 30-second TOTP step counter for `atMillis` (server: `currentCounter`). */
export function totpStep(atMillis: number): number {
  return Math.floor(atMillis / 1000 / STEP_SECONDS);
}

/** The 6-digit code for an explicit step counter. The server verifies with a
 *  ±1-step skew window ABOVE its per-factor replay floor, so a spec that just
 *  enrolled with the code for step N can immediately challenge with step N+1
 *  instead of sleeping out the rest of the 30-second window. */
export function totpCodeForStep(base32Secret: string, step: number): string {
  const key = base32Decode(base32Secret);
  const msg = Buffer.alloc(8);
  msg.writeBigUInt64BE(BigInt(step));
  const h = crypto.createHmac('sha1', key).update(msg).digest();
  const offset = h[h.length - 1] & 0x0f;
  const bin =
    ((h[offset] & 0x7f) << 24) |
    ((h[offset + 1] & 0xff) << 16) |
    ((h[offset + 2] & 0xff) << 8) |
    (h[offset + 3] & 0xff);
  return String(bin % 10 ** DIGITS).padStart(DIGITS, '0');
}

/** The current code (stepOffset 0), or a neighbour within the server's skew
 *  window (stepOffset +1 beats the just-consumed enroll step's replay floor). */
export function totpCode(base32Secret: string, stepOffset = 0, atMillis = Date.now()): string {
  return totpCodeForStep(base32Secret, totpStep(atMillis) + stepOffset);
}
