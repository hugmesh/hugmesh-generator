import { test, expect } from '@playwright/test';
import type { APIRequestContext, APIResponse } from '@playwright/test';
import { shot, apiContext } from './helpers';
import { totpCode, totpCodeForStep } from './totp';
import { loginPassword } from './rbac-roles';

// 29 — GATEWAY MFA ENFORCEMENT on the seeded mfa_required rows, end-to-end against
// the real compose stack. First e2e coverage of the two halves that were previously
// proven ONLY by hugmesh-gateway unit tests (GatewayRouteAccessFilterTest, the D8
// privileged-floor block) — the seed rows landed in #495, the gateway env wiring in
// the companion change, and nothing ever exercised the pair together.
//
//   • OFF POSTURE — cluster DEFAULT (APP_MFA_ENABLED=false). The EXACT COMPLEMENT of
//     the per-row block: it runs when that one skips, so a stack always gets stack
//     coverage of whichever posture it holds. Proves the seeded mfa_required rows are
//     INERT (a pure ROLE_FLEET_ADMIN is not gateway-denied on them) while the ROLE
//     wall on the same rows is NOT (a plain user still gets the gateway's 403), and
//     that an un-enrolled admin is never asked for a second factor.
//   • PER-ROW GATE — compose DEFAULT (APP_MFA_ENABLED=true, floor off). Of the 9
//     mfa_required rows specs/cluster/manifests/route-access/initdb/20-schema.sql
//     seeds, the only principal decide() can gate is a PURE ROLE_FLEET_ADMIN on
//     /bff/admin/phone-fleet/**: privileged roles short-circuit BEFORE decide().
//     Without a fresh stamp that principal gets the gateway's 403
//     (docs/MFA-ROLLOUT.md §3.1). UNGATED — it must hold on every real compose
//     stack, floor on or off.
//   • PRIVILEGED FLOOR — `make stack-up MFA_FLOOR=1`
//     (APP_MFA_ENFORCE_PRIVILEGED_FLOOR=true on the gateways). An ADMIN on an
//     mfa_required surface is HARD-denied without a FRESH second factor (the floor
//     sits ABOVE the admin bypass; SUPERADMIN is not exempt), passes after a real
//     TOTP enroll + step-up challenge driven through the SHIPPED login-ui pages, and
//     non-mfa_required surfaces / non-privileged principals are untouched. Gated on
//     the same MFA_FLOOR=1 the stack knob uses.
//
// WIRE SHAPE (leg d) — read from the source, not assumed. GatewayRouteAccessFilter
// has ONE reject(): 403 + `X-Route-Denied: <gateway>:<path>` + empty body, shared by
// the floor deny and the role deny. There is NO floor-specific marker, so the two are
// INDISTINGUISHABLE on the wire; the only observable difference is BEHAVIOURAL, and
// this file proves both directions. Its cold-start sibling notPrimed() is the one
// distinct shape: 503 + `Retry-After: 5`, privileged principals only, floor only.
//
// HONESTY — no fake-green paths. Every precondition (persona not seeded, wrong roles
// on the session, MFA surface dark, route-access volume predating the mfa_required
// seed) FAILS loudly with the real reason. The ONLY skip that can leave a stack with
// NO coverage is the MFA_FLOOR env gate, mirroring spec 14's LIVE_GATEWAY gate: the
// APP_MFA_ENABLED gate no longer can, because the two blocks it selects between are
// complements rather than one block and nothing.

const FLOOR = process.env.MFA_FLOOR === '1';

/**
 * Whether the stack under test has the gateway's MFA enforcement leg ON.
 *
 * DEFAULT TRUE, on purpose. compose sets APP_MFA_ENABLED=true so the leg is
 * exercisable end to end, and that is the posture this describe-block was written
 * against — so an unset variable RUNS the tests and fails loudly. Defaulting the
 * other way would let a forgotten export silently skip the only e2e coverage the
 * per-row gate has, which is the "guard that never guards" failure this repo keeps
 * shipping.
 *
 * It SELECTS a block rather than gating one. `false` runs the OFF-posture block
 * above; anything else runs the per-row block below. A wrong value therefore fails
 * the wrong block loudly instead of skipping everything — and against a real cluster
 * the value need not be guessed at all: `make kind-e2e-mfa` reads it back off the
 * running gateway pod's own env rather than trusting the caller's shell.
 *
 * The cluster deliberately ships it OFF and that is NOT a defect to fix here:
 * tests/stack/compose.local.yaml documents the asymmetry — "enabling the floor
 * before operators have enrolled a second factor locks them out of the privileged
 * plane. Turning the cluster on is therefore an operator action with ONE
 * precondition" — and tests/stack/test-gateway-mfa-env.sh pins it in BOTH
 * directions, so flipping the manifest to make this spec green would break that
 * gate and create a real lockout risk.
 *
 * Confirmed live on kind 2026-08-06: with APP_MFA_ENABLED=false the gateway never
 * consults the mfa_required rows, the request reaches admin-bff, and its
 * entitlement wall answers 403 with NO x-route-denied header — a deny from the
 * wrong layer that looks like a pass of the wrong test.
 */
const MFA_ENFORCEMENT = process.env.APP_MFA_ENABLED !== 'false';
// Resolved/generated, never a literal (see rbac-roles.ts sharedPassword()).

// fe-gateway mfa_required surfaces (20-schema.sql, after its closing UPDATE):
//   /bff/admin/**              -> ROLE_ADMIN
//   /bff/admin/phone-fleet/**  -> ROLE_FLEET_ADMIN | ROLE_ADMIN | ROLE_SUPERADMIN
// Matching is longest-pattern-wins (AntPathMatcher, GatewayRouteAccessService), so a
// path UNDER phone-fleet is decided by the fleet rows and everything else under
// /bff/admin by the ROLE_ADMIN blanket.
const ADMIN_MFA_ROUTE = '/bff/admin/usage';
// A sub-path (not the bare collection) so BOTH the `/**` match and the
// longest-pattern tie-break are unambiguous. The device id need not exist: every
// assertion here is about the GATEWAY verdict, which is reached before admin-bff.
const FLEET_MFA_ROUTE = '/bff/admin/phone-fleet/e2e-mfa-probe';
// A GOVERNED but NOT mfa_required privileged surface (`/bff/mod/** -> ROLE_ADMIN`,
// outside the /bff/admin + /bff/superadmin prefixes the seed's UPDATE covers) — the
// e2e twin of the unit test privilegedFloor_nonMfaSurface_adminBypassesUnaffected.
// Same request spec 28 makes; the query string is not part of the gateway's path
// value, so X-Route-Denied would read `<gateway>:/bff/mod/findings`.
const NON_MFA_ADMIN_ROUTE = '/bff/mod/findings?status=held';
// The compose front door is the fe gateway (compose.local.yaml sets
// SPRING_APPLICATION_NAME: hugmesh-fe-gateway, which is GatewayRouteAccessService's
// gatewayName and therefore the X-Route-Denied prefix).
const FE_GATEWAY = 'hugmesh-fe-gateway';

/** What the GATEWAY did with a request, independent of whatever the upstream would
 *  have answered. Only the gateway sets X-Route-Denied (admin-bff's own entitlement
 *  wall 403s WITHOUT it), and only the privileged floor's cold-start hold answers
 *  503 + Retry-After — so these three verdicts are readable black-box. */
type Verdict = 'DENIED' | 'HOLDING' | 'PASSED' | 'UNAUTHENTICATED';

function verdict(r: APIResponse): Verdict {
  if (r.status() === 403 && r.headers()['x-route-denied']) return 'DENIED';
  if (r.status() === 503 && r.headers()['retry-after']) return 'HOLDING';
  if (r.status() === 401) return 'UNAUTHENTICATED';
  return 'PASSED';
}

function why(r: APIResponse): string {
  return `${r.status()} x-route-denied=${r.headers()['x-route-denied'] ?? '<none>'}`;
}

/** Native sign-in through OUR /bff/login: the opaque httpOnly bff_session cookie
 *  lands in THIS context's jar and rides every later /bff/** call. Same contract as
 *  specs 13/27. A missing persona 401s here — a loud setup failure, never a skip. */
async function loginAs(api: APIRequestContext, username: string): Promise<void> {
  const r = await api.post('/bff/login', { data: { username, password: loginPassword() } });
  expect(
    r.status(),
    `native login ${username} -> ${r.status()} — the persona must be seeded ` +
      '(tests/e2e-extra-personas.sh, applied by BOTH lanes) with the deterministic e2e password',
  ).toBe(200);

  // ONBOARD, don't assume someone else did. A seeded Casdoor persona logging in for
  // the first time gets an account row with registration_complete=false: the flag is
  // set by registration STAGE 2, the step the login-ui's "Complete registration"
  // button drives, and nothing in the seed performs it. While it is false the gateway
  // grants only the bare ROLE_USER floor (BffSessionAuthFilter.buildAuthorities), so
  // every role assertion below would be vacuous and sessionOf() rightly refuses.
  //
  // This spec is API-only and never opens the registration UI, so it previously
  // depended on some EARLIER spec in the suite having onboarded the same persona —
  // an invisible ordering dependency that made it unrunnable standalone and against
  // a fresh cluster. Doing stage 2 here explicitly (and asserting it took) makes the
  // spec self-sufficient. It is the same call a real user's browser makes, not a
  // back door: POST /bff/register/complete is admin-bff's public AuthController
  // endpoint, reached through the gateway with the session cookie this context holds.
  const session = await api.get('/bff/session', { headers: { accept: 'application/json' } });
  expect(session.status(), `${username}: GET /bff/session after login`).toBe(200);
  if (!(await session.json()).registrationComplete) {
    const done = await api.post('/bff/register/complete', { data: { displayName: username } });
    expect(
      done.status(),
      `${username}: POST /bff/register/complete -> ${done.status()}. A 404 here means the ` +
        'gateway route table sends /bff/register/** to user-bff, which does not implement ' +
        'stage 2 — admin-bff does (apps/20-gateway-fe.yaml declares the exact path first)',
    ).toBe(200);
  }
}

/** The non-secret session identity: `GET /bff/session` roles are LOWERCASED and
 *  ROLE_-stripped ('admin', 'fleet_admin' — see spec 15's `toEqual(['user'])`), and
 *  registrationComplete gates whether the gateway maps them to authorities at all
 *  (BffSessionAuthFilter.buildAuthorities returns the bare ROLE_USER floor while it
 *  is false). Both are asserted by callers so a 403 below can never be a role deny
 *  masquerading as an MFA deny. */
async function sessionOf(api: APIRequestContext, who: string): Promise<{ roles: string[]; registrationComplete: boolean }> {
  const r = await api.get('/bff/session', { headers: { accept: 'application/json' } });
  expect(r.status(), `${who}: GET /bff/session after login`).toBe(200);
  const body = await r.json();
  expect(Array.isArray(body.roles), `${who}: /bff/session returned a roles array`).toBe(true);
  expect(
    !!body.registrationComplete,
    `${who}: registrationComplete is false, so the gateway grants only the ROLE_USER ` +
      'floor and every role assertion below would be vacuous',
  ).toBe(true);
  return { roles: body.roles as string[], registrationComplete: !!body.registrationComplete };
}

/** GET `path`, riding out the privileged floor's cold-start hold. 503 + Retry-After
 *  means route-access has not been primed from the datastore yet, so the gateway
 *  cannot know whether the path is an mfa_required surface and fails CLOSED by
 *  design (~one refresh interval after gateway boot). Any 503 WITHOUT the header —
 *  or one that never clears — is returned as-is so the caller's assertion fails on
 *  it rather than looping forever. */
async function primedGet(api: APIRequestContext, path: string): Promise<APIResponse> {
  let last = await api.get(path);
  const deadline = Date.now() + 60_000;
  while (verdict(last) === 'HOLDING' && Date.now() < deadline) {
    await new Promise((f) => setTimeout(f, 2_000));
    last = await api.get(path);
  }
  return last;
}

// ── the TOTP code generator itself (no stack, no gate) ───────────────────────────
//
// Runs first so a failing challenge downstream can never be blamed on our own code
// generation. Pure-local consistency tests are established idiom here (spec 15's
// "seed catalogue is internally consistent").

test.describe('TOTP generator: RFC 6238 Appendix B (stack-free)', () => {
  test('the six SHA-1 vectors reproduce at DIGITS=6', () => {
    // Appendix B's secret is ASCII "12345678901234567890"; its base32 form is what
    // an authenticator app (and our enroll wizard) shows. The published codes are
    // 8-digit; the platform is DIGITS=6 (auth-core TotpService), so the expectation
    // is the low 6 digits of each.
    const SECRET = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ';
    const VECTORS: [number, string][] = [
      [59, '287082'],
      [1111111109, '081804'],
      [1111111111, '050471'],
      [1234567890, '005924'],
      [2000000000, '279037'],
      [20000000000, '353130'],
    ];
    for (const [t, expected] of VECTORS) {
      const step = Math.floor(t / 30);
      expect(totpCodeForStep(SECRET, step), `RFC 6238 T=${t} (step ${step})`).toBe(expected);
    }
  });

  test('a non-base32 secret throws instead of hashing garbage', () => {
    // A garbled `mfa-secret` read off the page must fail HERE, not produce a
    // plausible-looking 6 digits the server then rejects for the wrong reason.
    expect(() => totpCode('not base32!')).toThrow(/base32/i);
  });
});

// ── the CLUSTER-DEFAULT OFF posture (enabled=false) — the complement ─────────────
//
// WHY THIS BLOCK EXISTS. `MFA_ENFORCEMENT` used to gate the ONLY stack coverage in
// this file, so on a stack running the posture every cluster the generator produces
// actually ships — APP_MFA_ENABLED=false, pinned in BOTH directions by
// tests/stack/test-gateway-mfa-env.sh assertion (4) — all five stack cases skipped
// and nothing was asserted at all. Confirmed live on kind 2026-08-20: spec 29 against
// the running SSO slice reported "2 passed, 5 skipped", and the two that passed were
// the stack-free TOTP vectors. The shipped posture had no e2e coverage whatsoever.
//
// That is the repo's own "guard that never guards" failure in mirror image. Turning a
// guard OFF has two ways to go wrong and neither was observable:
//   · the flag does not actually reach the gateway, so the stack silently ENFORCES
//     while every manifest and every gate says it does not (an operator lockout that
//     looks like a broken BFF), or
//   · turning MFA off also drops the ROLE wall on the same rows, so the privileged
//     plane opens to anyone (`decide()` reads `mfa_required` and `allow` off the SAME
//     row, and `mfaEnabled` gates one of them).
//
// So this block is the EXACT COMPLEMENT of the per-row block below: `test.skip` on
// `MFA_ENFORCEMENT` here, on `!MFA_ENFORCEMENT` there. Exactly one of the two runs on
// any stack, whichever posture it holds, and neither can be silently skipped by a
// forgotten export. Everything asserted here was verified by hand against the live
// kind lane first (fe-gateway APP_MFA_ENABLED=false, 9 mfa_required rows seeded; 10
// since #244 ACCEPT added the fe-gateway /bff/superadmin/** browser-door row, which
// the seed's flip UPDATE picks up — see the note on the count below).

test.describe('MFA OFF posture: the mfa_required rows are inert and the role wall is not', () => {
  test.skip(
    MFA_ENFORCEMENT,
    'APP_MFA_ENABLED is not false on this stack — the gateway MFA leg is ON, so the ' +
      'per-row block below is the one that applies. This block asserts the CLUSTER ' +
      'posture (enabled=false), which is what specs/cluster and every kind bring-up ' +
      'without `MFA=1` actually run.',
  );

  test('the mfa_required column is INERT: a pure ROLE_FLEET_ADMIN is not gateway-denied on /bff/admin/phone-fleet/**', async ({ baseURL }) => {
    const fleet = await apiContext(baseURL);
    await loginAs(fleet, 'e2e-fleet');

    // Same anti-fake-green preconditions as the ON leg: this persona is the ONE
    // principal among the seeded mfa_required rows that `decide()` can MFA-gate at
    // all, so if it is mis-seeded (no fleet role, or an accidental ROLE_ADMIN that
    // short-circuits before decide()) the assertion below is vacuous in the passing
    // direction. THE COUNT MOVED AND THE "ONE" DID NOT: #244's ACCEPT took the flip
    // set from 9 rows to 10 by adding hugmesh-fe-gateway /bff/superadmin/**, but that
    // row names ROLE_SUPERADMIN, and superadmin short-circuits in
    // GatewayRouteAccessFilter BEFORE decide() runs — so it adds a governed surface,
    // not a second MFA-gateable principal. e2e-fleet is still the only one.
    const { roles } = await sessionOf(fleet, 'e2e-fleet');
    expect(
      roles.some((r) => /fleet/i.test(r)),
      `e2e-fleet session roles ${JSON.stringify(roles)} carry no fleet role — re-seed ` +
        '(tests/e2e-extra-personas.sh, sourced by BOTH lanes). Without the granting row ' +
        'this case could not distinguish "MFA is inert" from "the role never granted".',
    ).toBe(true);
    expect(
      roles.some((r) => /^(role_)?admin$/i.test(r)),
      `e2e-fleet must NOT hold ROLE_ADMIN (got ${JSON.stringify(roles)}) — an admin ` +
        'bypasses decide() entirely and would reach the row for the wrong reason',
    ).toBe(false);

    // THE CLAIM. The route-access row for this path carries mfa_required=true (the
    // seed's UPDATE, 20-schema.sql) and this session carries NO second factor. With
    // APP_MFA_ENABLED=false, GatewayRouteAccessService.decide() must not consult the
    // column: the request is GRANTED at the gateway and whatever answers is upstream.
    // Asserted as "the GATEWAY did not reject", not as 200 — admin-bff's own
    // entitlement wall may still 403 this probe device, and that is a verdict from a
    // different layer, distinguishable because only the gateway sets X-Route-Denied.
    const r = await primedGet(fleet, FLEET_MFA_ROUTE);
    expect(
      r.headers()['x-route-denied'],
      `fleet GET ${FLEET_MFA_ROUTE} -> ${why(r)}. An X-Route-Denied here means the ` +
        'gateway DID consult mfa_required — this stack is enforcing MFA while ' +
        'APP_MFA_ENABLED reads false, so the declared posture and the live posture ' +
        'disagree (check the gateway pod env, not the chart values)',
    ).toBeUndefined();
    expect(verdict(r), `fleet GET ${FLEET_MFA_ROUTE} -> ${why(r)}`).not.toBe('DENIED');
    expect(verdict(r), 'the session itself must be authenticated').not.toBe('UNAUTHENTICATED');
    await fleet.dispose();
  });

  test('MFA off does NOT open the privileged plane: a plain user is still role-denied on /bff/admin/**', async ({ baseURL }) => {
    // The other direction, and the one that matters most. `decide()` reads `allow`
    // and `mfa_required` off the same rows and gates only the second on `mfaEnabled`;
    // a change that gated the first as well would turn the cluster default into an
    // open admin plane, and every existing case in this file would still skip.
    const user = await apiContext(baseURL);
    await loginAs(user, 'e2e-user');
    const { roles } = await sessionOf(user, 'e2e-user');
    expect(
      roles.some((r) => /^(role_)?(admin|superadmin|game.master)$/i.test(r)),
      `e2e-user must be non-privileged (got ${JSON.stringify(roles)})`,
    ).toBe(false);

    const denied = await primedGet(user, ADMIN_MFA_ROUTE);
    expect(
      verdict(denied),
      `plain user GET ${ADMIN_MFA_ROUTE} with MFA off -> ${why(denied)}. A PASSED ` +
        'verdict means turning MFA off also dropped the ROLE gate on these rows',
    ).toBe('DENIED');
    expect(
      denied.headers()['x-route-denied'],
      'the deny is the gateway route-access reject, not an upstream entitlement wall',
    ).toBe(`${FE_GATEWAY}:${ADMIN_MFA_ROUTE}`);
    expect((await denied.text()).length, 'the gateway reject carries no body').toBe(0);
    await user.dispose();
  });

  test('an ADMIN reaches the mfa_required blanket with no factor and no challenge', async ({ baseURL }) => {
    // §3.1's "quiet cluster" sentence, asserted for the OFF posture: an operator who
    // has never enrolled anything still works normally. This is the property the
    // enroll-before-you-enforce precondition (§2) exists to protect, so it is worth
    // an assertion rather than an assumption.
    //
    // ⚠ Its live negative control is the FLOOR block, not a mutation. Below the floor
    // there is NO route on which the gateway denies an admin — the SUPERADMIN / ADMIN
    // / GAME-MASTER bypass runs before decide(), so even /bff/superadmin/** answers
    // 403 from admin-bff's entitlement wall WITHOUT X-Route-Denied (verified live,
    // 2026-08-20). That is exactly why this reads as 'PASSED' rather than 200: the
    // verdict is scoped to the GATEWAY's decision, and only a floor/enforcement
    // regression can move it.
    const admin = await apiContext(baseURL);
    await loginAs(admin, 'e2e-admin');
    const { roles } = await sessionOf(admin, 'e2e-admin');
    expect(
      roles.some((r) => /^(role_)?admin$/i.test(r)),
      `e2e-admin session roles ${JSON.stringify(roles)} lack admin — nothing here is about MFA`,
    ).toBe(true);

    const r = await primedGet(admin, ADMIN_MFA_ROUTE);
    expect(
      verdict(r),
      `un-stamped admin GET ${ADMIN_MFA_ROUTE} with MFA off -> ${why(r)}`,
    ).toBe('PASSED');
    // And nothing anywhere in the chain asks for a second factor: the gateway has no
    // challenge response (its only rejects are 403 + X-Route-Denied and the floor's
    // 503 + Retry-After), so a redirect at the MFA pages would mean some OTHER layer
    // started demanding one — the failure mode §2's precondition warns about.
    expect(
      r.headers()['location'] ?? '',
      'no layer redirected an un-enrolled admin to the MFA challenge',
    ).not.toMatch(/\/login\/mfa/);
    await admin.dispose();
  });
});

// ── the compose-DEFAULT per-row gate (enabled=true, floor off) — UNGATED ─────────

test.describe('MFA per-row gate: the seeded mfa_required rows bite at the compose default', () => {
  // Not a convenience skip: with enforcement off the gateway never consults the
  // mfa_required rows at all, so a 403 here comes from admin-bff's entitlement wall
  // instead — the right status from the wrong layer, which would "pass" a test about
  // something else entirely. Skipping with the reason stated beats asserting a
  // property the stack is deliberately configured not to have.
  test.skip(
    !MFA_ENFORCEMENT,
    'APP_MFA_ENABLED=false on this stack — the gateway MFA leg is OFF by deliberate ' +
      'design on clusters (enabling it before operators enrol a second factor locks ' +
      'them out; see compose.local.yaml and tests/stack/test-gateway-mfa-env.sh). ' +
      'These cases require the compose posture APP_MFA_ENABLED=true.',
  );

  test('a pure ROLE_FLEET_ADMIN without a fresh stamp is DENIED /bff/admin/phone-fleet/**', async ({ baseURL }) => {
    const fleet = await apiContext(baseURL);
    await loginAs(fleet, 'e2e-fleet');

    // PRECONDITIONS (anti-fake-green). The deny below must be the MFA leg of the
    // GRANTING ROLE_FLEET_ADMIN row, not an ungranted-role deny, and the persona
    // must not be an admin (an admin bypasses decide() while the floor is off).
    const { roles } = await sessionOf(fleet, 'e2e-fleet');
    expect(
      roles.some((r) => /fleet/i.test(r)),
      `e2e-fleet session roles ${JSON.stringify(roles)} carry no fleet role — re-seed ` +
        '(tests/stack/seed-e2e.sh grants e2e-fleet ROLE_FLEET_ADMIN and ensure_roles ' +
        'creates the Casdoor role object); without it a 403 here proves nothing about MFA',
    ).toBe(true);
    expect(
      roles.some((r) => /^(role_)?admin$/i.test(r)),
      `e2e-fleet must NOT hold ROLE_ADMIN (got ${JSON.stringify(roles)}) — an admin ` +
        'short-circuits before decide() at floor=off and the MFA gate would never run',
    ).toBe(false);

    const denied = await primedGet(fleet, FLEET_MFA_ROUTE);
    expect(
      verdict(denied),
      `fleet GET ${FLEET_MFA_ROUTE} without a stamp -> ${why(denied)}. A PASSED verdict ` +
        'means the mfa_required rows are not in this stack\'s route-access DB: the seed ' +
        'UPDATE in 20-schema.sql only runs on a FRESH route-access-pg volume ' +
        '(`docker compose down -v` / `make stack-clean` before `make stack-up`)',
    ).toBe('DENIED');
    expect(
      denied.headers()['x-route-denied'],
      'the deny is the gateway route-access reject, not admin-bff\'s entitlement wall',
    ).toBe(`${FE_GATEWAY}:${FLEET_MFA_ROUTE}`);
    expect((await denied.text()).length, 'the gateway reject carries no body').toBe(0);

    // Control: the session itself is healthy — ungoverned surfaces still answer.
    expect(verdict(await primedGet(fleet, '/bff/session')), 'fleet /bff/session').toBe('PASSED');
    await fleet.dispose();
  });

  test('§3.1 small print: the SAME admin on the SAME blanket is bypassed at floor OFF and denied at floor ON', async ({ baseURL }) => {
    // docs/MFA-ROLLOUT.md §3.1 — "do not read a quiet cluster after step 6 as
    // evidence that admin MFA works". This is that sentence as an executable claim,
    // and it is the reason the fleet leg above cannot stand in for admin coverage.
    const admin = await apiContext(baseURL);
    await loginAs(admin, 'e2e-admin');
    const { roles } = await sessionOf(admin, 'e2e-admin');
    expect(
      roles.some((r) => /^(role_)?admin$/i.test(r)),
      `e2e-admin session roles ${JSON.stringify(roles)} lack admin — nothing below is about MFA`,
    ).toBe(true);

    const r = await primedGet(admin, ADMIN_MFA_ROUTE);
    if (FLOOR) {
      expect(
        verdict(r),
        `floor ON: admin GET ${ADMIN_MFA_ROUTE} un-stamped -> ${why(r)}`,
      ).toBe('DENIED');
    } else {
      expect(
        verdict(r),
        `floor OFF: an ADMIN must reach the mfa_required ${ADMIN_MFA_ROUTE} row WITHOUT a ` +
          `second factor (the bypass runs before decide()) -> ${why(r)}`,
      ).toBe('PASSED');
    }
    await admin.dispose();
  });
});

// ── the PRIVILEGED FLOOR (MFA_FLOOR=1 stacks only) ──────────────────────────────

test.describe('MFA privileged floor: an admin needs a FRESH factor on mfa_required rows', () => {
  test.skip(
    !FLOOR,
    'the privileged-floor legs need a floor-enabled stack: `make stack-up MFA_FLOOR=1` ' +
      '(APP_MFA_ENFORCE_PRIVILEGED_FLOOR=true on the compose gateways), then run this ' +
      'spec with MFA_FLOOR=1 in the environment',
  );

  test('a) an admin WITHOUT a fresh factor is denied /bff/admin/** by the gateway', async ({ baseURL }) => {
    const admin = await apiContext(baseURL);
    await loginAs(admin, 'e2e-admin');
    const { roles } = await sessionOf(admin, 'e2e-admin');
    expect(
      roles.some((r) => /^(role_)?admin$/i.test(r)),
      `e2e-admin session roles ${JSON.stringify(roles)} lack admin — a 403 below would be a role deny`,
    ).toBe(true);

    // An ENROLLED factor alone must not satisfy the floor. This is a fresh session
    // with no challenge on it, so even on a stack where an earlier run enrolled TOTP
    // for e2e-admin there is no fresh stamp and the floor must still bite.
    const denied = await primedGet(admin, ADMIN_MFA_ROUTE);
    expect(
      verdict(denied),
      `admin GET ${ADMIN_MFA_ROUTE} without a fresh factor -> ${why(denied)}`,
    ).toBe('DENIED');
    expect(denied.headers()['x-route-denied']).toBe(`${FE_GATEWAY}:${ADMIN_MFA_ROUTE}`);
    expect((await denied.text()).length, 'gateway reject carries no body').toBe(0);
    await admin.dispose();
  });

  test('b+d) TOTP enroll + challenge through the shipped login-ui flips the SAME route to passing; a role deny does not move', async ({ page, baseURL }) => {
    // Sign in as e2e-admin through the native form (spec 27's contract). The browser
    // route is deliberate: the shipped pages carry the CSRF double-submit header the
    // mutating /bff/mfa/* calls require, so this exercises the real operator path.
    await page.goto('/login');
    await page.getByTestId('login-username').fill('e2e-admin');
    await page.getByTestId('login-password').fill(loginPassword());
    const loginPost = page.waitForResponse(
      (r) => r.url().includes('/bff/login') && r.request().method() === 'POST',
    );
    await page.getByTestId('login-submit').click();
    expect((await loginPost).status(), 'admin browser login').toBeLessThan(400);

    // Baseline ON THIS SESSION (page.request shares the page's cookie jar).
    const before = await primedGet(page.request, ADMIN_MFA_ROUTE);
    expect(verdict(before), `pre-challenge floor deny -> ${why(before)}`).toBe('DENIED');
    expect(before.headers()['x-route-denied']).toBe(`${FE_GATEWAY}:${ADMIN_MFA_ROUTE}`);

    // ENROLL at the shipped wizard (login-ui MfaEnrollComponent). A dark MFA surface
    // renders the terminal `mfa-dark` step instead of the secret — that is a broken
    // PRECONDITION (APP_CASDOOR_MFA_ENABLED / APP_MFA_FACTOR_KEY on the compose
    // admin-bff), so it fails here by name rather than timing out anonymously.
    await page.goto('/login/mfa/enroll');
    await expect(page.getByTestId('mfa-enroll-view')).toBeVisible();
    await page.getByTestId('mfa-choose-totp').click();
    await expect(page.getByTestId('mfa-secret').or(page.getByTestId('mfa-dark'))).toBeVisible();
    await expect(
      page.getByTestId('mfa-dark'),
      'the admin-bff MFA surface is DARK (every /bff/mfa/* call 503s) — compose must set ' +
        'APP_CASDOOR_MFA_ENABLED=true AND APP_MFA_FACTOR_KEY; enrollment cannot be driven',
    ).toHaveCount(0);

    // The base32 secret is display-once: read it BEFORE verify, which clears it.
    const secret = (await page.getByTestId('mfa-secret').innerText()).trim();
    expect(secret.length, 'display-once base32 secret shown').toBeGreaterThan(0);

    const verifyPost = page.waitForResponse(
      (r) => r.url().includes('/bff/mfa/enroll/totp/verify') && r.request().method() === 'POST',
    );
    await page.getByTestId('mfa-passcode').fill(totpCode(secret));
    await page.getByTestId('mfa-verify-totp').click();
    expect((await verifyPost).status(), 'POST /bff/mfa/enroll/totp/verify').toBe(200);
    // Display-once recovery codes prove the factor flipped enabled server-side.
    await expect(page.getByTestId('mfa-recovery')).toBeVisible();
    await expect(page.getByTestId('mfa-recovery-codes')).not.toBeEmpty();
    await shot(page, '29-mfa-enroll-recovery');
    await page.getByTestId('mfa-recovery-done').click();

    // CHALLENGE at the shipped step-up page (login-ui MfaChallengeComponent).
    // Enroll-verify stamped the accepted step as the factor's replay floor
    // (MfaEnrollmentService.enableTotpAndIssueRecovery), and TotpService.verifyAt
    // accepts current±1 STRICTLY ABOVE that floor — so a code for step+1 verifies
    // immediately instead of sleeping out the rest of the 30-second window.
    await page.goto('/login/mfa/challenge');
    await expect(page.getByTestId('mfa-challenge-view')).toBeVisible();
    await expect(
      page.getByTestId('mfa-challenge-dark'),
      'the step-up surface is DARK — see the enroll precondition above',
    ).toHaveCount(0);
    await page.getByTestId('mfa-method-totp').check();
    const challengePost = page.waitForResponse(
      (r) => r.url().includes('/bff/mfa/challenge') && r.request().method() === 'POST',
    );
    await page.getByTestId('mfa-challenge-code').fill(totpCode(secret, 1));
    await page.getByTestId('mfa-challenge-submit').click();
    const challenged = await challengePost;
    // Asserted on the RESPONSE, not on `mfa-challenge-ok`: the component navigates to
    // `?returnTo=` (default /login/security) in the same tick it sets satisfied(), so
    // the success paragraph is a race. The response is the durable fact.
    expect(challenged.status(), 'POST /bff/mfa/challenge').toBe(200);
    expect((await challenged.json()).mfaSatisfied, 'the BFF stamped the session').toBe(true);
    await shot(page, '29-mfa-challenge-done');

    // THE FLIP (leg b): identical principal, identical route, the ONLY changed input
    // is factor freshness — so the 403 that clears was the FLOOR, not the role.
    // Polled because the stamp reaches the gateway through admin-bff introspect on
    // the next request, but the END state is asserted hard.
    await expect
      .poll(async () => verdict(await page.request.get(ADMIN_MFA_ROUTE)), {
        message: `a freshly stamped admin still cannot reach ${ADMIN_MFA_ROUTE}`,
        timeout: 30_000,
      })
      .toBe('PASSED');

    // Leg (d), the other direction. A plain user's deny on the SAME route is a ROLE
    // deny, and no amount of MFA freshness in the world moves it. Its wire shape is
    // BYTE-IDENTICAL to the floor deny above (GatewayRouteAccessFilter.reject() is
    // shared: same 403, same X-Route-Denied value, same empty body) — asserted here
    // so that if a floor-specific marker is ever added, this test and
    // docs/MFA-ROLLOUT.md §3.1 have to be updated together rather than drifting.
    const user = await apiContext(baseURL);
    await loginAs(user, 'e2e-user');
    const { roles: userRoles } = await sessionOf(user, 'e2e-user');
    expect(
      userRoles.some((r) => /^(role_)?(admin|superadmin|game.master)$/i.test(r)),
      `e2e-user must be non-privileged (got ${JSON.stringify(userRoles)})`,
    ).toBe(false);
    const roleDeny = await primedGet(user, ADMIN_MFA_ROUTE);
    expect(verdict(roleDeny), `plain user on the admin surface -> ${why(roleDeny)}`).toBe('DENIED');
    expect(
      roleDeny.headers()['x-route-denied'],
      'role deny and floor deny share reject() — same header, same value',
    ).toBe(before.headers()['x-route-denied']);
    expect(roleDeny.status(), 'role deny and floor deny share the status').toBe(before.status());
    expect((await roleDeny.text()).length, 'role deny carries no body either').toBe(0);
    await user.dispose();
  });

  test('c) unaffected: non-privileged principals and non-mfa_required surfaces see no floor', async ({ baseURL }) => {
    // The floor gates PRIVILEGED principals only — a plain user is untouched by it
    // (it is decide() that adjudicates them, and /bff/session is ungoverned).
    const user = await apiContext(baseURL);
    await loginAs(user, 'e2e-user');
    const session = await primedGet(user, '/bff/session');
    expect(verdict(session), `user /bff/session -> ${why(session)}`).toBe('PASSED');
    await user.dispose();

    // And the floor is PER-ROW, not a blanket MFA wall on privileged principals: an
    // UN-stamped admin still reaches a governed ROLE_ADMIN surface that is outside
    // the seed's /bff/admin + /bff/superadmin prefixes. The e2e twin of the unit test
    // privilegedFloor_nonMfaSurface_adminBypassesUnaffected. Asserted as "the gateway
    // did not reject" rather than 200: /bff/mod/findings 500s on the stock compose
    // stack (federation findings backend dark, see spec 28), which is not an auth
    // verdict — the same idiom spec 28 uses for this surface.
    const admin = await apiContext(baseURL);
    await loginAs(admin, 'e2e-admin');
    const nonMfa = await primedGet(admin, NON_MFA_ADMIN_ROUTE);
    expect(
      verdict(nonMfa),
      `un-stamped admin on the NON-mfa_required ${NON_MFA_ADMIN_ROUTE} -> ${why(nonMfa)}`,
    ).toBe('PASSED');
    await admin.dispose();
  });
});
