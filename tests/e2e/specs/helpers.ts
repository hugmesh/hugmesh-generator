import { Page, expect, request } from '@playwright/test';
import type { Locator } from '@playwright/test';
import type { APIRequestContext, APIResponse, Browser, BrowserContext } from '@playwright/test';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { SUPERADMIN_USERNAME, SYSTEMS_SEED_USERS, passwordFor, loginPassword } from './rbac-roles';
export { SUPERADMIN_USERNAME };
import type { SystemsRole } from './rbac-roles';

export const SHOTS = path.resolve(process.env.SNAP_SHOTS || 'screenshots');
fs.mkdirSync(SHOTS, { recursive: true });

/**
 * `--host-resolver-rules` is BROWSER-ONLY. Kind runs address the cluster by its
 * real hostname (the fe-gateway Ingress matches on Host) and hand Chromium
 * `SNAP_HOST_RESOLVER` so no /etc/hosts edit or sudo is needed. Node never sees
 * that flag, so anything Playwright sends from Node — `request.newContext()`,
 * `page.request` — dies on `getaddrinfo ENOTFOUND hugmesh.net`.
 *
 * Verified, not assumed: BOTH Node-side context kinds fail this way, including
 * `page.request`, which is easy to mistake for browser-side because it shares the
 * browser's cookie jar.
 *
 * The fix is to dial the mapped IP and carry the hostname in the `Host` header,
 * which is what ingress-nginx routes on. Proven live on kind with its own control:
 *
 *     Host: hugmesh.net  -> 401 from the BFF   (routed to the gateway)
 *     (no Host header)       -> 404 from nginx     (default backend; did not route)
 *
 * NO-OP WITHOUT THE FLAG. When SNAP_HOST_RESOLVER is unset — every compose run —
 * these return their input untouched, so the compose lane cannot be affected by
 * this at all. That is deliberate: it is the property that makes adopting the
 * helper safe in specs that only ever run against compose.
 */
/**
 * Parse Chromium's `--host-resolver-rules` syntax:
 * `"MAP hugmesh.net 127.0.0.1, MAP *.hugmesh.net 127.0.0.1"`.
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

// ── the Tor front door (make stack-up TOR=1; run.sh --via onion) ─────────────
/**
 * Where `tests/e2e/run.sh --via onion` pointed this run: the docker stack's v3
 * .onion (https — see below) and the SOCKS5 proxy that reaches it.
 * `null` when the run was not pointed at an onion, which is how a @via:onion
 * scenario knows to SKIP with a reason in an ordinary lane instead of failing.
 *
 * HTTPS, never http, and it throws rather than "fixing" an http URL: the
 * gateway's CSP carries upgrade-insecure-requests, so a page entered over
 * http://<onion>/ has every subresource and fetch() upgraded to https:// and the
 * SPA never boots (measured 2026-09-23 over a live onion; tests/stack/tor/
 * entrypoint.sh). The onion's :443 is the stack's TLS front.
 */
export interface OnionFrontDoor {
  /** https://<56 base32 chars>.onion — no trailing slash. */
  baseUrl: string;
  /** The onion hostname every request of the scenario must carry. */
  host: string;
  /** socks5://host:port — a .onion resolves only inside Tor. */
  proxy: string;
}

const V3_ONION_HOST = /^[a-z2-7]{56}\.onion$/;

export function onionFrontDoor(env: NodeJS.ProcessEnv = process.env): OnionFrontDoor | null {
  const raw = (env.SNAP_ONION_BASE_URL || '').replace(/\/+$/, '');
  const proxy = env.SNAP_PROXY || '';
  if (!raw && !proxy) return null;
  if (!raw || !proxy) {
    throw new Error(
      `half a Tor front door: SNAP_ONION_BASE_URL='${raw}' SNAP_PROXY='${proxy}'. `
      + 'tests/e2e/run.sh --via onion sets both; setting one alone would send the '
      + 'browser to the onion without Tor, or through Tor to nowhere.',
    );
  }
  const u = new URL(raw);
  if (u.protocol !== 'https:' || !V3_ONION_HOST.test(u.hostname) || u.port !== '') {
    throw new Error(`SNAP_ONION_BASE_URL='${raw}' is not https://<v3>.onion (no port)`);
  }
  if (!/^socks5:\/\/[^/\s]+:\d+$/.test(proxy)) {
    throw new Error(`SNAP_PROXY='${proxy}' is not socks5://host:port`);
  }
  return { baseUrl: raw, host: u.hostname, proxy };
}

/**
 * A browser context that reaches the mesh ONLY through Tor: `baseURL` is the
 * onion, so every relative `page.goto('/login')` in the shared helpers (onboard(),
 * registerOnly()) follows it unchanged, and `page.request` inherits the proxy
 * (measured: a Node-side request through the context resolved the .onion inside
 * Tor and came back 200). `<-loopback>` sends loopback THROUGH the proxy too, so
 * an absolute http(s)://localhost:8488/... link baked into a UI cannot quietly
 * succeed around Tor. Measured 2026-09-23 over a live onion: with it, goto
 * http://127.0.0.1:<port>/ and http://localhost:<port>/ both died
 * net::ERR_SOCKS_CONNECTION_FAILED while the onion answered 200. Playwright 1.61
 * already adds the token by default (the same run without it behaved
 * identically); it is spelled out so the property does not hang on a default.
 */
export async function onionContext(
  browser: Browser,
  door: OnionFrontDoor,
  harPath?: string,
): Promise<BrowserContext> {
  return browser.newContext({
    baseURL: door.baseUrl,
    proxy: { server: door.proxy, bypass: '<-loopback>' },
    // The onion's :443 is the stack's TLS front, whose cert is minted per machine
    // for the cluster domain — it can never name a .onion.
    ignoreHTTPSErrors: true,
    ...(harPath ? { recordHar: { path: harPath, content: 'omit' as const } } : {}),
  });
}

/**
 * Default native sign-in password for the ad-hoc e2e personas these specs drive
 * (alice@…, bob@…, admin@…, dragoneer, …). Mirrors the seed-catalogue resolver in
 * rbac-roles.ts (sharedPassword): explicit E2E_PASSWORD, else the run-state
 * credentials file tests/stack/e2e-password.sh maintains, else THROW — never a
 * literal fallback. The LIVE run must seed each persona as a native Casdoor
 * account (username = the persona handle) with this SAME password (`make
 * stack-seed` does, via that same generator).
 */
export { loginPassword };

/**
 * The SUPERADMIN identity is the one persona whose login handle is not fixed:
 * a Studio-bootstrapped mesh seeds it under the operator's minted username
 * (seed-e2e.sh reads CASDOOR_SUPERADMIN_USERNAME; the terminal lane defaults to
 * 'e2e-superadmin') with the minted E2E_SUPERADMIN_PASSWORD. Specs MUST use
 * these instead of literals, or they 401 on every studio-bootstrapped mesh —
 * exactly the spec-28 failure of 2026-08-14.
 */
/**
 * Per-persona password resolution, mirroring seed-e2e.sh persona_password():
 * the persona's own E2E_<FOLDED>_PASSWORD env (non-alphanumerics fold to '_',
 * so 'e2e-mod' -> E2E_MOD_PASSWORD) -> shared loginPassword(). The superadmin's
 * env is pinned to E2E_SUPERADMIN_PASSWORD whatever its username (the seed
 * render pins the same passwordEnv on the persona).
 */
export function personaPassword(username: string): string {
  if (username === SUPERADMIN_USERNAME) {
    return process.env.E2E_SUPERADMIN_PASSWORD ?? loginPassword();
  }
  const folded = username.toUpperCase().replace(/[^A-Z0-9]/g, '_');
  return process.env[`${folded}_PASSWORD`] ?? loginPassword();
}

// ── platform-access personas (who may drive Matrix / Mastodon at all) ─────────
/**
 * Matrix and Mastodon are gated on the PER-PLATFORM access roles
 * ROLE_MATRIX / ROLE_MASTODON. The broad ROLE_USER homeserver floor was removed
 * (commit 0100d3b, see rbac-roles.ts on `e2e-user`), so the invite-handle personas
 * (alice@…, bob@…, carol@…) — ROLE_USER and nothing else — are DENIED the
 * homeserver backend BY DESIGN, and spec 17 asserts exactly that deny. Any spec
 * that actually exercises Matrix/Mastodon must therefore drive a persona holding
 * the platform role; granting alice ROLE_MATRIX to "fix" such a spec would
 * contradict spec 17.
 *
 * Derived from the seed catalogue rather than hard-coded here so a roster change
 * lands in one place. DOMAIN-LOCKED holders are excluded even though they carry
 * the base access role: their federation lock is the SUBJECT of specs 19-23, and
 * borrowing them for ordinary chat/post flows would entangle two proofs.
 */
export interface PlatformPersona {
  /** Casdoor login handle. */
  username: string;
  /** Resolved per the catalogue's env-override chain (rbac-roles.ts passwordFor).
   *  Resolved ON READ — see platformPersonas() for why it must not be eager. */
  password: string;
  /** Roles granted in the seed — carried for assertion/diagnostic use. */
  roles: readonly SystemsRole[];
}

export function platformPersonas(role: 'ROLE_MATRIX' | 'ROLE_MASTODON'): PlatformPersona[] {
  const locked: SystemsRole = role === 'ROLE_MATRIX'
    ? 'ROLE_MATRIX_DOMAINLOCKED'
    : 'ROLE_MASTODON_DOMAINLOCKED';
  return SYSTEMS_SEED_USERS
    .filter((u) => u.roles.includes(role) && !u.roles.includes(locked) && u.registrationComplete)
    // `password` is a GETTER, not a resolved value. Specs 05/06/10/11 call
    // requirePlatformPersonas() at MODULE SCOPE, so resolving here would drag the
    // credential throw back into import time and break `--list` all over again —
    // the same defect the lazy loginPassword() removes one layer up. A getter
    // still satisfies `password: string` for every reader.
    .map((u) => ({
      username: u.username,
      get password() { return passwordFor(u); },
      roles: u.roles,
    }));
}

/**
 * The first `count` platform-access personas for `role`, or a precise failure when
 * the roster cannot supply them. The two-party specs (05/06/10/11) need TWO — if
 * the catalogue ever shrinks to one, this says so by name instead of the spec
 * dying on `undefined.username`, and the fix is a roster addition (a second
 * seeded ROLE_MATRIX/ROLE_MASTODON persona), never granting the platform role to
 * a plain-ROLE_USER handle.
 */
export function requirePlatformPersonas(
  role: 'ROLE_MATRIX' | 'ROLE_MASTODON',
  count: number,
): PlatformPersona[] {
  const all = platformPersonas(role);
  if (all.length < count) {
    throw new Error(
      `need ${count} ${role} platform-access personas, the seed catalogue has ${all.length} `
      + `(${all.map((p) => p.username).join(', ') || 'none'}). Add another seeded ${role} persona to `
      + `SYSTEMS_SEED_USERS + seed-accounts.sh — do NOT grant ${role} to a plain ROLE_USER handle `
      + `(alice@/bob@/…), which spec 17 asserts is denied the homeserver backend.`,
    );
  }
  return all.slice(0, count);
}

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

/**
 * Which persona a page is signed in as, remembered at sign-in time.
 *
 * The opaque-cookie model gives the browser NO readable identity (see Session
 * above), so a failing helper cannot ask the page who it is. Every sign-in path
 * goes through registerOnly(), so recording the handle there is enough to name
 * the actor in an error message — which is the difference between "403" and
 * "403 for a persona that never held the platform-access role". Keyed weakly so
 * closed pages are collectable.
 */
const PERSONA = new WeakMap<Page, string>();

/** The handle `page` last signed in as, or a placeholder when a spec drove the
 *  login itself instead of going through registerOnly()/onboard(). */
export function personaOf(page: Page): string {
  return PERSONA.get(page) ?? '<unknown persona: page did not sign in via onboard()/registerOnly()>';
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
export async function registerOnly(page: Page, username: string, password = loginPassword()): Promise<void> {
  PERSONA.set(page, username); // so a later helper failure can name the actor
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
 * the real tuwunel" and provisions BEFORE navigating deliberately, to avoid an
 * hsproxy token race.
 * The playwright.config global `expect.timeout` of 15s is a UI-interaction
 * default and cannot reliably cover this chain — that mismatch is what makes the
 * nav-user waits flake across specs 02/04-09. 60s keeps a 4x margin over the
 * default while still sitting inside the 90s per-test `timeout`, so a genuinely
 * hung shell still fails the test rather than hanging the run.
 */
export const SHELL_AFTER_PROVISION_MS = 60_000;

/**
 * Full onboarding: native sign-in (stage 1) + complete registration (stage 2).
 * Returns the fully-registered session hydrated from GET /bff/session.
 */
export async function onboard(page: Page, username: string, password = loginPassword()): Promise<Session> {
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
  // already loaded and nav-user attached, so the Matrix entry is a same-shell
  // render gated only on the shell's own registrationComplete read — one round
  // trip, not the provisioning chain. Widening this one would hide a real unlock
  // bug.
  //
  // WHICH element (see matrixEntry): the shell lands every signed-in identity on
  // the member home (roleHomeGuard -> '/user'), and on the signed-in home
  // host-shell renders the menubar's service entries as service CARDS instead of
  // a bar, so `nav-matrix` is NOT in the DOM here — the same entry is
  // `home-card-nav-matrix`. Waiting on `nav-matrix` failed onboard() with
  // "element(s) not found" (specs 04/05/17 and their Gherkin mirrors, live
  // 2026-09-04) or, when it caught the bar during the pre-redirect first paint,
  // handed the next click a detached element (spec 07). matrixEntry() resolves
  // whichever form the route renders, which is the whole of the fix here.
  //
  // WHY toBeVisible() AND NOT expectMatrixUnlocked() — deliberate, do not
  // "strengthen" this line. onboard() is the SHARED sign-in: 23 direct call sites
  // under specs/ and steps/, PLUS the Gherkin Given "I am signed in as the persona
  // for this scenario" (steps/common.steps.ts), which 33 hand-written .feature
  // files use 102 times — wiki, tube, owncast, games, forum and character consoles
  // among them, none of which touch Matrix. The enabled form is gated on
  // `capabilities.installed('matrix')` (host-shell menu.component.ts navEntries)
  // and CapabilitiesService fails CLOSED — an unreachable
  // /api/federation/capabilities leaves an EMPTY map and installed() returns
  // false. Asserting the UNLOCKED form here would make "Matrix is installed and
  // the federation-api answered" a precondition of signing in at all, so a
  // core-only stack or a federation-api blip would fail a hundred scenarios that
  // have nothing to do with Matrix. The unlock is asserted where the unlock IS
  // the claim: expectMatrixUnlocked() in openMatrix(), spec 04's returning-user
  // test, spec 17, and the Gherkin Then "the shell offers Matrix unlocked".
  await expect(matrixEntry(page)).toBeVisible();
  return getSession(page, username);
}

// ── the shell's Matrix entry: menubar link OR signed-in-home service card ─────
/**
 * The host shell's Matrix navigation entry, in whichever form the current route
 * renders it.
 *
 * hugmesh-host-shell's MenuComponent renders ONE of two mutually exclusive
 * branches (`@if (barVisible()) … @else if (homeCardsActive())`, menu.component
 * .html): on every non-home route the `role="menubar"`, whose entry carries
 * `data-testid="nav-matrix"`; on the signed-in HOME ('/user' exactly — where
 * roleHomeGuard lands every authenticated identity, so where EVERY sign-in
 * lands) a grid of service CARDS instead, where the SAME entry carries
 * `data-testid="home-card-nav-matrix"` (operator requirement, host-shell issue
 * #19, commit 00c092e 2026-08-19 — "on home the services ARE the navigation").
 * Verified against the deployed image, not just source: after POST /bff/login
 * the document is /user with `home-card-nav-matrix` = `a[href=/social/matrix]`
 * and NO `nav-matrix`/menubar; on /social/matrix the menubar + `nav-matrix`
 * are back and the cards are gone.
 *
 * Both forms are an `<a href="/social/matrix">` when the entry is ENABLED
 * (service installed AND registration complete — menu.component.ts navEntries)
 * and a `<button>`/`<span>` with `aria-disabled="true"` and the SAME testid when
 * it is not. `.or()` is strict-mode safe because the two branches never render
 * together.
 */
export function matrixEntry(page: Page): Locator {
  return page.getByTestId('home-card-nav-matrix').or(page.getByTestId('nav-matrix'));
}

/**
 * The Matrix entry is rendered AND unlocked: the enabled `<a href>` form, not
 * the greyed aria-disabled one that shares its testid. `href` is the discriminator
 * because it is the ONE attribute only the enabled branch sets (both templates).
 */
export async function expectMatrixUnlocked(page: Page): Promise<void> {
  const entry = matrixEntry(page);
  await expect(entry).toBeVisible();
  await expect(entry).toHaveAttribute('href', '/social/matrix');
}

/** Open Matrix through the shell's OWN navigation — the service card on the
 *  signed-in home, the menubar link everywhere else.
 *
 *  The unlock is asserted BEFORE the click and not left to the click to discover:
 *  the LOCKED home-card form is a `<span aria-disabled="true">`, which Playwright
 *  will happily click (a span has no disabled actionability state), so the click
 *  would silently no-op and the run would fail several seconds later on the
 *  unrelated-looking `matrix-view is not visible`. Asserting first reports the
 *  real cause — the entry is present but greyed — at the nav. */
export async function openMatrix(page: Page): Promise<void> {
  await expectMatrixUnlocked(page);
  await matrixEntry(page).click();
}

// ── Matrix room setup via the user-bff hsproxy (no browser-held token) ─────────
// Every Matrix CS-API call goes through the same-origin user-bff hsproxy at
// `/bff/user/matrix` (MATRIX_PROXY_PREFIX): the proxy strips the prefix, forwards
// the verbatim `/_matrix/...` path and INJECTS the server-held homeserver token
// whose owner is the bff_session subject. Auth is SOLELY the httpOnly bff_session
// cookie (credentials: include; no bearer, no CSRF) — mirrors matrix.service.ts
// hsFetch(). `page.request` reuses the page's cookie jar, so the cookie rides.
const MATRIX_HSPROXY = '/bff/user/matrix';

/**
 * Render a CS-API path PARAMETER (a room id, an mxid) as a URI path segment the
 * whole chain actually understands.
 *
 * `encodeURIComponent(roomId)` — what these helpers used to do — is the textbook
 * spelling and it DOES NOT WORK against this stack. Proven live, same room, same
 * session, same second:
 *
 *   POST …/rooms/%21LmrBEFNwdPsY0FfToB%3Alocalhost/join
 *     -> 400 {"errcode":"M_BAD_JSON","error":"deserialization failed: leading
 *             sigil is incorrect or missing"}
 *   POST …/rooms/!LmrBEFNwdPsY0FfToB:localhost/join
 *     -> 200 {"room_id":"!LmrBEFNwdPsY0FfToB:localhost"}
 *
 * The user-bff hsproxy forwards the ALREADY-ENCODED path verbatim on purpose
 * (HsReverseProxy: "the request path value + raw query are already URL-encoded →
 * build(true)", part of its SSRF guard), and tuwunel v1.7.0 does not
 * percent-decode the segment before handing it to the room-id deserializer — so
 * `%21…` reaches it as the literal characters and the sigil check fails. That is
 * an upstream/homeserver behaviour, not something a test can fix; the fix
 * available here is to not encode what does not need encoding.
 *
 * So: percent-encode, then restore the characters RFC 3986 permits LITERALLY in a
 * path segment (pchar = unreserved / sub-delims / ':' / '@'). `!` needs no help —
 * encodeURIComponent already leaves it — `:` is the one that matters for
 * `!room:server` and `@user:server`. This is a strictly VALID URI either way, so
 * it is equally correct against a decoding server: the light lane's
 * tests/stack/mock-matrix.mjs decodeURIComponent()s each segment, and decoding an
 * unencoded segment is the identity.
 *
 * `/` stays encoded (it would otherwise split the segment) and therefore remains
 * unreachable on tuwunel — no Matrix identifier grammar produces one.
 */
function pathParam(value: string): string {
  return encodeURIComponent(value).replace(
    /%(24|26|2B|2C|3A|3B|3D|40)/gi,
    (m) => decodeURIComponent(m),
  );
}

/**
 * Fail an hsproxy call with the facts needed to diagnose it: the status, the URL
 * and the PERSONA that made the call.
 *
 * WHY THIS EXISTS. Every one of these helpers used to do `(await r.json())` on an
 * unchecked response. The gateway denies a caller without the per-platform access
 * role with a 403 carrying an EMPTY body (verified live: alice@gmail.com, roles
 * ["user"], POST createRoom -> 403, zero bytes), so `r.json()` threw
 * "SyntaxError: Unexpected end of JSON input" from inside helpers.ts and the
 * actual RBAC deny never appeared anywhere in the report. A 403 must read as a
 * 403. The 403 branch names the likely cause because that is the single most
 * common way these helpers fail: ROLE_MATRIX/ROLE_MASTODON are per-platform
 * ACCESS roles and a plain ROLE_USER does NOT reach the homeserver backend
 * (rbac-roles.ts; spec 17 asserts that deny).
 */
async function hsproxyFail(page: Page, r: APIResponse, what: string): Promise<never> {
  const body = (await r.text().catch(() => '')).trim();
  const hint = r.status() === 403
    ? '\n  403 = RBAC deny. Matrix/Mastodon are gated on the per-platform ROLE_MATRIX/'
      + 'ROLE_MASTODON access roles; a plain ROLE_USER is DENIED the homeserver backend '
      + '(see specs/rbac-roles.ts and spec 17). Drive this flow with a platform-access '
      + 'persona (e2e-matrix / e2e-mastodon and their peers).'
    : '';
  throw new Error(
    `${what} failed: HTTP ${r.status()} ${r.statusText()}\n`
    + `  url:     ${r.url()}\n`
    + `  persona: ${personaOf(page)}\n`
    + `  body:    ${body.length ? body.slice(0, 500) : '<empty>'}${hint}`,
  );
}

/** Assert an hsproxy response is 2xx; on anything else throw the status/URL/persona
 *  message above rather than letting the caller parse a body that isn't there. */
async function hsproxyOk(page: Page, r: APIResponse, what: string): Promise<APIResponse> {
  if (!r.ok()) await hsproxyFail(page, r, what);
  return r;
}

/** Status-checked JSON: never hands an unparsed error body to JSON.parse, and
 *  reports a genuinely-malformed 2xx body as such instead of as a bare SyntaxError. */
async function hsproxyJson(page: Page, r: APIResponse, what: string): Promise<any> {
  await hsproxyOk(page, r, what);
  const text = await r.text();
  try {
    return JSON.parse(text);
  } catch {
    throw new Error(
      `${what} returned HTTP ${r.status()} with a non-JSON body\n`
      + `  url:     ${r.url()}\n`
      + `  persona: ${personaOf(page)}\n`
      + `  body:    ${text.length ? text.slice(0, 500) : '<empty>'}`,
    );
  }
}

/** Resolve the caller's own Matrix user_id via the hsproxy whoami — the browser
 *  no longer holds it (it lived on the deleted Session.matrix.userId). */
export async function matrixUserId(page: Page): Promise<string> {
  const url = `${MATRIX_HSPROXY}/_matrix/client/v3/account/whoami`;
  const r = await page.request.get(url);
  const body = await hsproxyJson(page, r, 'matrix whoami');
  if (typeof body.user_id !== 'string' || !body.user_id) {
    throw new Error(`matrix whoami returned no user_id for persona ${personaOf(page)}: ${JSON.stringify(body)}`);
  }
  return body.user_id;
}

/** Create a Matrix room as the signed-in `page` user, through the hsproxy.
 *  `invitees` takes one user_id or several — a lone string keeps the historical
 *  one-peer call sites (specs 05/10/11) source-compatible. `opts` forwards the
 *  optional createRoom knobs the group specs exercise (preset/is_direct/topic);
 *  omitted knobs are omitted from the body, preserving the server defaults the
 *  existing specs were created under. Returns the room_id. */
export async function createRoom(
  page: Page,
  invitees: string | string[],
  name: string,
  opts: { preset?: string; isDirect?: boolean; topic?: string } = {},
): Promise<string> {
  const invite = Array.isArray(invitees) ? invitees : [invitees];
  const r = await page.request.post(`${MATRIX_HSPROXY}/_matrix/client/v3/createRoom`, {
    data: {
      name,
      invite,
      ...(opts.preset && { preset: opts.preset }),
      ...(opts.isDirect && { is_direct: true }),
      ...(opts.topic && { topic: opts.topic }),
    },
  });
  const body = await hsproxyJson(page, r, `createRoom '${name}' inviting [${invite.join(', ')}]`);
  if (typeof body.room_id !== 'string' || !body.room_id) {
    throw new Error(
      `createRoom '${name}' returned no room_id for persona ${personaOf(page)}: ${JSON.stringify(body)}`,
    );
  }
  return body.room_id;
}

/** Invite `userId` into an existing room as the signed-in `page` user, through
 *  the hsproxy. The invitee sees the room under /sync `rooms.invite` (the UI's
 *  pending-invite rows) until they join or leave (decline). */
export async function inviteToRoom(page: Page, roomId: string, userId: string): Promise<void> {
  const r = await page.request.post(
    `${MATRIX_HSPROXY}/_matrix/client/v3/rooms/${pathParam(roomId)}/invite`,
    { data: { user_id: userId } },
  );
  // Same reason as createRoom: an unchecked invite made a later "the invite row
  // never appeared" the visible failure instead of the deny that caused it.
  await hsproxyOk(page, r, `invite ${userId} into ${roomId}`);
}

/** Join a Matrix room as the signed-in `page` user, through the hsproxy. */
export async function joinRoom(page: Page, roomId: string): Promise<void> {
  const r = await page.request.post(`${MATRIX_HSPROXY}/_matrix/client/v3/rooms/${pathParam(roomId)}/join`);
  await hsproxyOk(page, r, `join ${roomId}`);
}

/** The room-scoped event PUT the matrix-ui issues for a composed message or a
 *  call-signalling event: `/rooms/<roomId>/send/<eventType>/<txn>`. */
export const UI_ROOM_SEND = /\/_matrix\/client\/v3\/rooms\/[^/]+\/send\//;

/**
 * Run `action` (a UI interaction) and require the hsproxy call it triggers — the
 * first response whose URL matches `pathRe` — to come back 2xx.
 *
 * DIAGNOSTIC, NOT A WEAKENING: the assertions that follow are unchanged; this only
 * makes the FIRST thing that broke the visible failure. Without it, a UI-side
 * CS-API call that 4xx/5xxs surfaces 15s later as `toContainText` receiving `""`,
 * which names neither the request nor the status — exactly how the encoded-room-id
 * defect below hid. It also pins WHICH request the click is supposed to make.
 */
export async function expectUiCallOk<T>(
  page: Page,
  pathRe: RegExp,
  what: string,
  action: () => Promise<T>,
): Promise<T> {
  const pending = page.waitForResponse((r) => pathRe.test(r.url()));
  const result = await action();
  const r = await pending;
  if (!r.ok()) {
    const body = (await r.text().catch(() => '')).trim();
    throw new Error(
      `${what}: the UI's own request failed — HTTP ${r.status()}\n`
      + `  url:     ${r.url()}\n`
      + `  persona: ${personaOf(page)}\n`
      + `  body:    ${body.length ? body.slice(0, 500) : '<empty>'}`,
    );
  }
  return result;
}

// ── Mastodon setup via the user-bff hsproxy (same custody model as Matrix) ─────
// MastodonProxyController is the sibling of MatrixProxyController in the same
// hsproxy package: same-origin prefix, prefix stripped, verbatim `/api/...` path
// forwarded, server-held token injected, auth = the httpOnly bff_session cookie.
const MASTODON_HSPROXY = '/bff/user/mastodon';

/** The signed-in `page` user's OWN Mastodon account id. Like matrixUserId(), this
 *  has to come from the server: the browser holds no Mastodon token or account id,
 *  and the account's username is the opaque Casdoor subject, not the handle. */
export async function mastodonAccountId(page: Page): Promise<string> {
  const r = await page.request.get(`${MASTODON_HSPROXY}/api/v1/accounts/verify_credentials`);
  const body = await hsproxyJson(page, r, 'mastodon verify_credentials');
  if (!body.id) {
    throw new Error(`mastodon verify_credentials returned no account id for persona ${personaOf(page)}`);
  }
  return String(body.id);
}

/**
 * The signed-in `page` user FOLLOWS `accountId`.
 *
 * Needed because the UI's "Home" tab is the real `/api/v1/timelines/home` — the
 * FOLLOW graph decides what lands there, so "user B sees user A's post" is only
 * true once B follows A. (On the light lane's mock-mastodon every status shows up
 * on home regardless, which is why a spec could look green without this.) Follow
 * BEFORE the author posts: Mastodon fans a new status out to its followers' home
 * feeds at post time, so that ordering needs no backfill and no polling for it.
 */
export async function mastodonFollow(page: Page, accountId: string): Promise<void> {
  const r = await page.request.post(`${MASTODON_HSPROXY}/api/v1/accounts/${pathParam(accountId)}/follow`);
  await hsproxyOk(page, r, `follow mastodon account ${accountId}`);
}
