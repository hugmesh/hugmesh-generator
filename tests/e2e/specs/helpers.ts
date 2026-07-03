import { Page, expect } from '@playwright/test';
import * as fs from 'node:fs';
import * as path from 'node:path';

export const SHOTS = path.resolve(process.env.SNAP_SHOTS || 'screenshots');
fs.mkdirSync(SHOTS, { recursive: true });

/**
 * Default native sign-in password for the ad-hoc e2e personas these specs drive
 * (alice@…, bob@…, admin@…, dragoneer, …). Mirrors the seed-catalogue resolver in
 * rbac-roles.ts (passwordFor): a shared E2E_PASSWORD, falling back to the
 * deterministic 'e2e-pass' the seeder uses. The LIVE run must seed each persona
 * as a native Casdoor account (username = the persona handle) with this password.
 */
export const LOGIN_PASSWORD = process.env.E2E_PASSWORD ?? 'e2e-pass';

/**
 * Non-secret session identity the login-ui carries post-login.
 *
 * Native login mints ONLY the opaque httpOnly `bff_session` cookie — the browser
 * never holds a Matrix/Mastodon homeserver token, a Casdoor JWT, or a persisted
 * `snap.session` — so the only identity a black-box test can read is what
 * `GET /bff/session` returns (roles + registrationComplete). `provider` is always
 * 'password' now; the deleted Google/Discord social-login (and its
 * 'google'/'discord' provider) is gone.
 */
export interface Session {
  /** The username typed into our own login form. The opaque-cookie session does
   *  not expose a display label to the browser, so the test carries it itself. */
  username: string;
  /** Native username/password login — never 'google'/'discord' (removed). */
  provider: 'password';
  /** Casdoor roles, hydrated from GET /bff/session (never from web storage). */
  roles: string[];
  /** Two-stage registration gate, hydrated from GET /bff/session. */
  registrationComplete: boolean;
}

export async function shot(page: Page, name: string): Promise<void> {
  await page.screenshot({ path: path.join(SHOTS, `${name}.png`), fullPage: true });
}

/**
 * Hydrate the non-secret session identity from `GET /bff/session` — the ONLY
 * browser-readable identity source in the opaque-cookie model (nothing is
 * persisted to localStorage). `page.request` shares the page's BrowserContext
 * cookie jar, so the httpOnly `bff_session` cookie minted by /bff/login rides
 * along automatically; a non-OK response means "not logged in".
 */
export async function getSession(page: Page, username: string): Promise<Session> {
  const r = await page.request.get('/bff/session', { headers: { accept: 'application/json' } });
  const data = r.ok() ? await r.json().catch(() => ({} as any)) : ({} as any);
  return {
    username,
    provider: 'password',
    roles: Array.isArray(data.roles) ? data.roles : [],
    registrationComplete: !!data.registrationComplete,
  };
}

/**
 * Stage 1 only: sign in through OUR native login-ui username/password form but do
 * NOT complete registration (for the two-stage gating specs). A provisioned but
 * not-yet-fully-registered sign-in lands on the "Complete registration" card
 * (login.component pending()); an unprovisioned identity surfaces a `login-error`
 * instead (native login has no self-registration surface).
 */
export async function registerOnly(page: Page, username: string, password = LOGIN_PASSWORD): Promise<void> {
  await page.goto('/login');
  await page.getByTestId('login-username').fill(username);
  await page.getByTestId('login-password').fill(password);
  await page.getByTestId('login-submit').click();
}

/**
 * Full onboarding: native sign-in (stage 1) + complete registration (stage 2).
 * Returns the fully-registered session hydrated from GET /bff/session.
 */
export async function onboard(page: Page, username: string, password = LOGIN_PASSWORD): Promise<Session> {
  await registerOnly(page, username, password);
  // IDEMPOTENT: a first-time (provisioned-but-incomplete) sign-in lands on the
  // complete-registration card (register-display-name); a RETURNING account that has
  // already completed lands straight on the host shell (nav-user) — the same account is
  // onboarded by several specs against the shared mock BFF, so a second onboard must not
  // wait for a complete-view that never appears. Branch on whichever surfaces first.
  const displayName = page.getByTestId('register-display-name');
  const navUser = page.getByTestId('nav-user');
  await expect(displayName.or(navUser).first()).toBeVisible({ timeout: 15000 });
  if (await displayName.isVisible()) {
    // Stage 2: the login-ui requires a display name before "Complete registration"
    // enables (completeBlocked()); an ASCII handle also skips the conditional
    // screen-reader-name prompt (needsScreenReaderName()).
    await displayName.fill(username);
    await page.getByTestId('login-complete').click();
  }
  // Logged in + registered: the host shell shows the user nav and unlocks Matrix.
  // The opaque-cookie session does NOT expose the display label to the browser,
  // so assert the nav is present rather than its (custody-hidden) text.
  await expect(navUser).toBeAttached();
  await expect(page.getByTestId('nav-matrix')).toBeVisible();
  return getSession(page, username);
}

// ── Matrix room setup via the user-bff hsproxy (no browser-held token) ─────────
// Every Matrix CS-API call goes through the same-origin user-bff hsproxy at
// `/bff/user/matrix` (MATRIX_PROXY_PREFIX): the proxy strips the prefix, forwards
// the verbatim `/_matrix/...` path and INJECTS the server-held homeserver token
// whose owner is the bff_session subject. Auth is SOLELY the httpOnly bff_session
// cookie (credentials: include; no bearer, no CSRF) — mirrors matrix.service.ts
// hsFetch(). `page.request` reuses the page's cookie jar, so the cookie rides.
const MATRIX_HSPROXY = '/bff/user/matrix';

/** Resolve the caller's own Matrix user_id via the hsproxy whoami — the browser
 *  no longer holds it (it lived on the deleted Session.matrix.userId). */
export async function matrixUserId(page: Page): Promise<string> {
  const r = await page.request.get(`${MATRIX_HSPROXY}/_matrix/client/v3/account/whoami`);
  return (await r.json()).user_id;
}

/** Create a Matrix room (inviting `peerUserId`) as the signed-in `page` user,
 *  through the hsproxy. Returns the room_id. */
export async function createRoom(page: Page, peerUserId: string, name: string): Promise<string> {
  const r = await page.request.post(`${MATRIX_HSPROXY}/_matrix/client/v3/createRoom`, {
    data: { name, invite: [peerUserId] },
  });
  return (await r.json()).room_id;
}

/** Join a Matrix room as the signed-in `page` user, through the hsproxy. */
export async function joinRoom(page: Page, roomId: string): Promise<void> {
  await page.request.post(`${MATRIX_HSPROXY}/_matrix/client/v3/rooms/${encodeURIComponent(roomId)}/join`);
}
