import { test, expect } from '@playwright/test';
import type { APIRequestContext, APIResponse } from '@playwright/test';
import { shot, apiContext } from './helpers';
import { totpCode, totpCodeForStep } from './totp';

// 29 — GATEWAY MFA ENFORCEMENT on the seeded mfa_required rows, end-to-end against
// the real compose stack. First e2e coverage of the two halves that were previously
// proven ONLY by hugmesh-gateway unit tests (GatewayRouteAccessFilterTest, the D8
// privileged-floor block) — the seed rows landed in #495, the gateway env wiring in
// the companion change, and nothing ever exercised the pair together.
//
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
// seed) FAILS loudly with the real reason. The ONLY skip in this file is the
// MFA_FLOOR env gate, mirroring spec 14's LIVE_GATEWAY gate.

const FLOOR = process.env.MFA_FLOOR === '1';
const LOGIN_PASSWORD = process.env.E2E_PASSWORD || 'e2e-pass';

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
  const r = await api.post('/bff/login', { data: { username, password: LOGIN_PASSWORD } });
  expect(
    r.status(),
    `native login ${username} -> ${r.status()} — the persona must be seeded ` +
      '(tests/stack/seed-e2e.sh EXTRA_SPECS) with the deterministic e2e password',
  ).toBe(200);
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

// ── the compose-DEFAULT per-row gate (enabled=true, floor off) — UNGATED ─────────

test.describe('MFA per-row gate: the seeded mfa_required rows bite at the compose default', () => {
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
    await page.getByTestId('login-password').fill(LOGIN_PASSWORD);
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
