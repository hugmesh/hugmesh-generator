import { Page, expect, request } from '@playwright/test';
import type { APIRequestContext } from '@playwright/test';
import * as fs from 'node:fs';
import * as path from 'node:path';

export const SHOTS = path.resolve(process.env.SNAP_SHOTS || 'screenshots');
fs.mkdirSync(SHOTS, { recursive: true });

/**
 * `--host-resolver-rules` is BROWSER-ONLY. Kind runs address the cluster by its
 * real hostname (the fe-gateway Ingress matches on Host) and hand Chromium
 * `SNAP_HOST_RESOLVER` so no /etc/hosts edit or sudo is needed. Node never sees
 * that flag, so anything Playwright sends from Node — `request.newContext()`,
 * `page.request` — dies on `getaddrinfo ENOTFOUND hugmesh.systems`.
 *
 * Verified, not assumed: BOTH Node-side context kinds fail this way, including
 * `page.request`, which is easy to mistake for browser-side because it shares the
 * browser's cookie jar.
 *
 * The fix is to dial the mapped IP and carry the hostname in the `Host` header,
 * which is what ingress-nginx routes on. Proven live on kind with its own control:
 *
 *     Host: hugmesh.systems  -> 401 from the BFF   (routed to the gateway)
 *     (no Host header)       -> 404 from nginx     (default backend; did not route)
 *
 * NO-OP WITHOUT THE FLAG. When SNAP_HOST_RESOLVER is unset — every compose run —
 * these return their input untouched, so the compose lane cannot be affected by
 * this at all. That is deliberate: it is the property that makes adopting the
 * helper safe in specs that only ever run against compose.
 */
/**
 * Parse Chromium's `--host-resolver-rules` syntax:
 * `"MAP hugmesh.systems 127.0.0.1, MAP *.hugmesh.systems 127.0.0.1"`.
 * Malformed entries are dropped rather than half-applied. Wildcards are kept
 * verbatim and matched by suffix in {@link mappedIp}.
 *
 * Exported so the rules can be INJECTED in tests. An earlier draft read the env at
 * module load and tests tried to bust the module cache to vary it, which does not
 * resolve under this runner — and a pure function taking its input is the better
 * design regardless.
 */
export function parseResolverRules(spec: string | undefined): ReadonlyMap<string, string> {
  const m = new Map<string, string>();
  for (const rule of (spec ?? '').split(',')) {
    const parts = rule.trim().split(/\s+/);
    if (parts.length === 3 && parts[0].toUpperCase() === 'MAP') m.set(parts[1], parts[2]);
  }
  return m;
}

const HOST_MAP: ReadonlyMap<string, string> = parseResolverRules(process.env.SNAP_HOST_RESOLVER);

function mappedIp(hostname: string, map: ReadonlyMap<string, string>): string | undefined {
  const exact = map.get(hostname);
  if (exact) return exact;
  for (const [pattern, ip] of map) {
    if (pattern.startsWith('*.') && hostname.endsWith(pattern.slice(1))) return ip;
  }
  return undefined;
}

/**
 * Rewrite a URL a Node-side request context can't resolve into one it can,
 * plus the `Host` header that preserves the routing decision. Returns the input
 * unchanged when there is no mapping (compose, or an unmapped host).
 *
 * The Host header carries the hostname WITHOUT the port — that is the exact shape
 * proven to route on kind above. Do not "improve" it to host:port without re-running
 * that control.
 */
export function resolveForNode(
  rawUrl: string,
  map: ReadonlyMap<string, string> = HOST_MAP,
): { url: string; headers: Record<string, string> } {
  if (map.size === 0) return { url: rawUrl, headers: {} };
  let u: URL;
  try {
    u = new URL(rawUrl);
  } catch {
    return { url: rawUrl, headers: {} }; // relative path: nothing to rewrite
  }
  const ip = mappedIp(u.hostname, map);
  if (!ip) return { url: rawUrl, headers: {} };
  const host = u.hostname;
  u.hostname = ip;
  return { url: u.toString(), headers: { Host: host } };
}

/**
 * A Node-side API context pointed at `baseUrl`, resolvable on kind and identical
 * to the plain `request.newContext({ baseURL, ignoreHTTPSErrors: true })` it
 * replaces everywhere else.
 *
 * NOT a substitute for `page.request`: that shares the browser context's cookie
 * jar, and a standalone context does not. A spec that reads a session cookie the
 * browser minted must keep using `page.request` — and on kind that call still
 * cannot resolve. See docs/KIND-SSO-E2E-FINDINGS.md item 20.
 */
export async function apiContext(baseUrl: string | undefined): Promise<APIRequestContext> {
  const t = resolveForNode(baseUrl ?? '');
  return request.newContext({
    baseURL: t.url || baseUrl,
    ignoreHTTPSErrors: true,
    ...(Object.keys(t.headers).length ? { extraHTTPHeaders: t.headers } : {}),
  });
}

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
 * Budget for "I clicked a login-ui submit; wait for the host shell to appear".
 *
 * This is NOT a padded default — it is sized to a specific chain that the
 * login-ui runs SEQUENTIALLY, entirely server-round-trip bound, BEFORE it ever
 * navigates to the host shell. Both onboard() branches pay it:
 *
 *   returning user (login-submit → host shell), login.component.ts submit():
 *     POST /bff/login                (bff.service.ts login())
 *     → await session.hydrate()      → GET /bff/session
 *     → await provisionServiceTokens()
 *         → await POST /bff/provision/matrix     ⎫ sequential, NOT Promise.all
 *         → await POST /bff/provision/mastodon   ⎭ (bff.service.ts)
 *     → goToHost() → hardNav.navigate('/')  — a HARD navigation, so the host
 *       shell then cold-boots (fresh document + Angular bootstrap) before
 *       nav-user exists at all.
 *
 *   first-time user (login-complete → host shell), login.component.ts complete():
 *     POST /bff/register/complete    (bff.service.ts completeRegistration())
 *     → await provisionServiceTokens()  (same sequential matrix→mastodon pair)
 *     → goToHost() → hard navigation → host shell cold boot.
 *
 * That is 4-5 serial network legs plus a full page load, and the provisioning
 * legs mint tokens against the real homeserver (tuwunel)/Mastodon — login-ui's
 * own comment on completeRegistration() says the broker "can be slow against
 * the real Synapse" and provisions BEFORE navigating deliberately, to avoid an
 * hsproxy token race.
 * The playwright.config global `expect.timeout` of 15s is a UI-interaction
 * default and cannot reliably cover this chain — that mismatch is what makes the
 * nav-user waits flake across specs 02/04-09. 60s keeps a 4x margin over the
 * default while still sitting inside the 90s per-test `timeout`, so a genuinely
 * hung shell still fails the test rather than hanging the run.
 */
const SHELL_AFTER_PROVISION_MS = 60_000;

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
  //
  // The two branches need DIFFERENT wait semantics: displayName is a real, rendered
  // form field (toBeVisible() is meaningful), but nav-user's own label is empty by
  // design in the opaque-cookie model (see the toBeAttached() comment below) — its
  // <span> has zero content and thus zero rendered size, so waiting for it to be
  // "visible" would never resolve. Race each locator against its own correct
  // condition rather than forcing one .toBeVisible() over the combined locator.
  //
  // BUDGET: the nav-user leg of this race is the returning-user chain (POST
  // /bff/login → hydrate → provision matrix → provision mastodon, sequential →
  // hard nav → host shell cold boot), so it needs SHELL_AFTER_PROVISION_MS, not
  // the 15s global. Both legs carry the same budget because Promise.race rejects
  // on the FIRST rejection: a shorter budget on the display-name leg would fire
  // first and abort the race while the returning-user chain was still legitimately
  // in flight — which is exactly the "nav-user timeout" these specs hit.
  const displayName = page.getByTestId('register-display-name');
  const navUser = page.getByTestId('nav-user');
  await Promise.race([
    displayName.waitFor({ state: 'visible', timeout: SHELL_AFTER_PROVISION_MS }),
    navUser.waitFor({ state: 'attached', timeout: SHELL_AFTER_PROVISION_MS }),
  ]);
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
  //
  // BUDGET: on the first-time branch above we just clicked login-complete, so THIS
  // assertion — not the race — is what spans the register-complete chain (POST
  // /bff/register/complete → provision matrix → provision mastodon, sequential →
  // hard nav → host shell cold boot). It inherited the 15s global `expect.timeout`,
  // which is the same undersized budget as the race. On the returning-user branch
  // the race already resolved on nav-user, so this costs nothing.
  await expect(navUser).toBeAttached({ timeout: SHELL_AFTER_PROVISION_MS });
  // Deliberately left on the 15s global: by the line above the shell document is
  // already loaded and nav-user attached, so nav-matrix is a same-shell render
  // gated only on the shell's own registrationComplete read — one round trip, not
  // the provisioning chain. Widening this one would hide a real unlock bug.
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
