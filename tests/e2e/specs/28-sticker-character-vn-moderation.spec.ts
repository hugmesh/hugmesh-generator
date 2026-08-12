import { test, expect, request } from '@playwright/test';
import type { APIRequestContext } from '@playwright/test';
import { LOGIN_PASSWORD } from './helpers';
import { tags } from './report-tags';

// ────────────────────────────────────────────────────────────────────────────
// 28 — STICKER + CHARACTER/VN CONVERSATION & MODERATION.
//
// HONEST VERDICT (read this before trusting a green run):
//   The fine-grained capability the product owner asked for —
//   "an ADMIN/MOD bans USAGE of a specific sticker / character (or bans a specific
//    USER or ROLE from stickers/characters) WITHOUT affecting that user's ability
//    to post plain TEXT or use other features" —
//   DOES NOT EXIST in the codebase today. There is no endpoint, no role, no
//   entitlement/deny-table and no per-message character identity that could drive
//   it (see the GROUP B comment block for the verbatim gap). So it CANNOT be
//   asserted as passing behaviour, and this spec never fakes it.
//
//   GROUP A tests below assert REAL behaviour observed live against the running
//   front door (http://localhost:8088): the sticker/character asset library
//   (save + sanitized serve), the protocol-level m.sticker send, the MOD-gated
//   content-approval surface (authz only — the backend round-trip is dark), the
//   ONLY thing the platform calls a "ban" (coarse, whole-platform, and it kills
//   text too), the text baseline the missing feature would have to preserve, and
//   a negative-space contract lock.
//
//   GROUP B tests are `test.fixme` CONTRACT specs: their bodies encode the DESIRED
//   endpoint+verb+status for the unbuilt fine-grained ban so that, when the
//   capability is built, flipping `test.fixme` -> `test` turns each into a live
//   test. They must NOT be read as failing bugs — they are the executable spec of
//   a MISSING feature.
//
// Ground truth: a read-only investigation of the sticker/character/VN/moderation
// surface, captured 2026-07-11 in session scratch (not committed — the facts are
// reproduced inline in this file's comments and test bodies).
// Live-probe corrections applied while writing (differ from the facts draft):
//   * EVERY authenticated role reaches POST /bff/user/character/stickers -> 200,
//     including MOD, ADMIN, and SUPERADMIN (NOT 403, and NOT 401 for SUPERADMIN
//     as an earlier draft of this comment incorrectly claimed — see the A1 test
//     body below for the corrected mechanism: CasdoorAuthorities unconditionally
//     floors every authenticated principal to ROLE_USER, independent of the
//     Spring RoleHierarchy bean, which only defines SUPERADMIN>{ADMIN,MOD,USER}
//     edges). So there is no clean authenticated "non-USER -> 403" case; the
//     only save-surface DENY is anonymous (401).
//   * GET /bff/mod/findings currently 500s (the federation findings backend is
//     dark on the stock compose stack) — so A4 asserts only the AUTHZ gate
//     (MOD authorized, USER 403) and marks the finding round-trip pending.
//   * The Matrix send path needs the ROLE_MATRIX access role: e2e-user (plain
//     ROLE_USER) is 403 on the hsproxy, so e2e-matrix is the Matrix actor.
//   * The room_id in a CS-API path is sent RAW. On Synapse that was load-bearing
//     (encoded PUT -> 403, raw PUT -> 200, verified live); tuwunel accepts BOTH
//     forms (verified live against the swapped stack: raw AND percent-encoded
//     PUT -> 200). Raw stays the one portable spelling — keep sending it.
// ────────────────────────────────────────────────────────────────────────────

// A minimal but genuinely-valid 1x1 PNG (passes the magic-byte sniff). Used for
// the sticker save round-trip.
const PNG_1x1 = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
  'base64',
);
// PNG magic bytes + >1MB of payload — passes the sniff, trips the 1MB cap (-> 400).
const PNG_OVERSIZE = Buffer.concat([
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
  Buffer.alloc(1_200_000),
]);
// Not an image (SVG is text/markup) — trips the magic-byte sniff (-> 400).
const SVG_BYTES = Buffer.from('<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"><rect width="8" height="8"/></svg>');

const HS = '/bff/user/matrix';                       // user-bff homeserver (tuwunel) reverse proxy
const MASTO = '/bff/user/mastodon';                  // user-bff Mastodon reverse proxy
const BOGUS_ID = '00000000-0000-0000-0000-000000000000';

/** Native sign-in through OUR /bff/login: mints the opaque httpOnly bff_session
 *  cookie into THIS request context's jar (no bearer token exposed). Mirrors the
 *  loginAs in spec 13/17. Every seeded persona uses the deterministic e2e password. */
async function loginAs(api: APIRequestContext, username: string): Promise<void> {
  const r = await api.post('/bff/login', { data: { username, password: LOGIN_PASSWORD } });
  expect(r.status(), `native login ${username}`).toBe(200);
}

/** A fresh request context already signed in as `username`. */
async function loggedIn(baseURL: string | undefined, username: string): Promise<APIRequestContext> {
  const api = await request.newContext({ baseURL, ignoreHTTPSErrors: true });
  await loginAs(api, username);
  return api;
}

/** Defensive CSRF: the mock/native stack does not set XSRF-TOKEN today, but mirror
 *  the spec-17 idiom so the mutating BFF calls stay correct if it ever does. */
async function csrf(api: APIRequestContext): Promise<Record<string, string>> {
  const t = (await api.storageState()).cookies.find((c) => c.name === 'XSRF-TOKEN')?.value;
  return t ? { 'X-CSRF-TOKEN': t } : {};
}

/** Create a Matrix room through the hsproxy (creator is auto-joined). Returns the
 *  room_id. No invite (self-contained); auth is the bff_session cookie only. */
async function createRoom(api: APIRequestContext, name: string): Promise<string> {
  const r = await api.post(`${HS}/_matrix/client/v3/createRoom`, { data: { name } });
  expect(r.status(), 'createRoom').toBe(200);
  return (await r.json()).room_id as string;
}

/** Unique CS-API transaction id. */
function txn(): string {
  return `${Date.now()}-${Math.random().toString(36).slice(2)}`;
}

// ════════════════════════════════════════════════════════════════════════════
// GROUP A — REAL behaviour, must genuinely pass against the live :8088 stack.
// ════════════════════════════════════════════════════════════════════════════
test.describe('28 GROUP A — sticker/character/VN surfaces that EXIST today', () => {
  test(`A1 sticker save round-trip: USER saves a PNG -> 200 PENDING, GET lists it; SVG/oversize -> 400; anon -> 401 ${tags({ role: 'ROLE_USER', layer: 'bff' })}`,
    async ({ baseURL }) => {
      const user = await loggedIn(baseURL, 'e2e-user');
      const h = await csrf(user);

      // Save a real PNG at a canonical expression -> 200, status PENDING, stub mxc.
      const saved = await user.post('/bff/user/character/stickers', {
        headers: h,
        multipart: {
          file: { name: 'neutral.png', mimeType: 'image/png', buffer: PNG_1x1 },
          expression: 'neutral',
        },
      });
      expect(saved.status(), 'save PNG sticker').toBe(200);
      const body = await saved.json();
      expect(body.status, 'a freshly-saved sticker is PENDING (binary global lifecycle)').toBe('PENDING');
      expect(body.expression).toBe('neutral');
      expect(String(body.mxcUrl).startsWith('mxc://'), 'stub mxc assigned').toBe(true);
      const id = body.id as string;

      // GET lists it (owner + domain scoped).
      const list = await user.get('/bff/user/character/stickers');
      expect(list.status()).toBe(200);
      const rows = await list.json();
      expect(Array.isArray(rows) && rows.some((r: any) => r.id === id && r.status === 'PENDING'),
        'the saved sticker is listed for its owner').toBe(true);

      // Validation: a non-image (SVG markup) fails the magic-byte sniff -> 400.
      const svg = await user.post('/bff/user/character/stickers', {
        headers: h,
        multipart: {
          file: { name: 'x.svg', mimeType: 'image/svg+xml', buffer: SVG_BYTES },
          expression: 'happy',
        },
      });
      expect(svg.status(), 'SVG rejected by the magic-byte sniff').toBe(400);

      // Validation: > 1MB -> 400.
      const big = await user.post('/bff/user/character/stickers', {
        headers: h,
        multipart: {
          file: { name: 'big.png', mimeType: 'image/png', buffer: PNG_OVERSIZE },
          expression: 'sad',
        },
      });
      expect(big.status(), 'oversize rejected by the 1MB cap').toBe(400);

      // Anonymous -> 401 (the ONLY save-surface DENY — see the hierarchy note below).
      const anon = await request.newContext({ baseURL, ignoreHTTPSErrors: true });
      const anonSave = await anon.post('/bff/user/character/stickers', {
        multipart: {
          file: { name: 'neutral.png', mimeType: 'image/png', buffer: PNG_1x1 },
          expression: 'neutral',
        },
      });
      expect(anonSave.status(), 'anonymous save denied').toBe(401);
      await anon.dispose();

      // HONEST CORRECTION to the facts draft: there is NO authenticated "non-USER
      // -> 403" on this surface. EVERY authenticated role reaches it (MOD, ADMIN,
      // and SUPERADMIN are all admitted; GET -> 200, non-destructive probes). This
      // is NOT the Spring RoleHierarchy bean at work (user-bff-api's hierarchy only
      // defines SUPERADMIN>{ADMIN,MOD,USER} edges — there is no MOD>USER or
      // ADMIN>USER edge that would explain a MOD reaching a USER-gated endpoint).
      // The real mechanism: CasdoorAuthorities unconditionally grants ROLE_USER to
      // every authenticated principal regardless of their Casdoor role claims, so
      // hasRole('USER') is really an "any authenticated user" floor here. The ONLY
      // DENY is anonymous (401, asserted above).
      for (const role of ['e2e-mod', 'e2e-superadmin']) {
        const api = await loggedIn(baseURL, role);
        const g = await api.get('/bff/user/character/stickers');
        expect(g.status(), `${role} is unconditionally floored to ROLE_USER -> reaches the sticker surface`).toBe(200);
        await api.dispose();
      }
      test.info().annotations.push({
        type: 'observed',
        description: 'Every authenticated role (USER/MOD/ADMIN/SUPERADMIN) reaches the sticker surface (200) because CasdoorAuthorities floors every authenticated principal to ROLE_USER, not via the Spring RoleHierarchy bean; the only DENY is anonymous (401). The facts draft "non-USER -> 403" is NOT the live reality.',
      });
      await user.dispose();
    });

  test(`A2 sticker SEND: protocol-level m.sticker PUT round-trips the VN content shape ${tags({ role: 'ROLE_MATRIX', layer: 'homeserver' })}`,
    async ({ baseURL }) => {
      // The real send-half. A full-UI picker click is BLOCKED on the stock stack —
      // the pack advertisement is dark (sticker.matrix.register.enabled=false), so
      // the picker renders `sticker-empty` for every seeded persona (that UI flow is
      // A2b below, pending-on-seed). Here we drive the wire directly, exactly as
      // MatrixService.sendEvent(roomId,'m.sticker',content) does. Actor is e2e-matrix
      // (ROLE_MATRIX); e2e-user (plain ROLE_USER) is 403 on the hsproxy.
      const mx = await loggedIn(baseURL, 'e2e-matrix');
      const roomId = await createRoom(mx, 'A2 sticker send');

      const content = {
        body: 'neutral sticker',
        url: 'mxc://stub.invalid/e2e-a2',
        info: { w: 256, h: 256, mimetype: 'image/png' },
        'systems.hugmesh.vn': { expression: 'neutral' },
      };
      // NB raw room_id in the path — the portable spelling. Synapse rejected the
      // percent-encoded form (403, verified live); tuwunel accepts both raw and
      // encoded (200, verified live — this exact content shape round-trips
      // verbatim, systems.hugmesh.vn namespace included). Raw works everywhere.
      const put = await mx.put(`${HS}/_matrix/client/v3/rooms/${roomId}/send/m.sticker/${txn()}`, { data: content });
      expect(put.status(), 'm.sticker send accepted by the homeserver').toBe(200);
      const eventId = (await put.json()).event_id as string;
      expect(eventId).toBeTruthy();

      // Read the event back: the VN sticker content shape round-trips verbatim.
      const ev = await mx.get(`${HS}/_matrix/client/v3/rooms/${roomId}/event/${eventId}`);
      expect(ev.status()).toBe(200);
      const stored = await ev.json();
      expect(stored.type).toBe('m.sticker');
      expect(String(stored.content.url).startsWith('mxc://')).toBe(true);
      expect(stored.content['systems.hugmesh.vn'].expression).toBe('neutral');
      expect(stored.content.body).toBe('neutral sticker');
      await mx.dispose();
    });

  test.fixme(`A2b sticker picker UI click (pending: pack advertisement dark) ${tags({ role: 'ROLE_MATRIX', layer: 'ui' })}`,
    async ({ page }) => {
      // PENDING-ON-SEED (not a bug): the full-UI picker path exists in matrix-ui
      // (btn-sticker -> composer-sticker-picker -> sticker-<shortcode> -> sendEvent
      // 'm.sticker'), but the pack is never advertised on the stock stack
      // (sticker.matrix.register.enabled=false) so `sticker-empty` renders and no
      // tile is clickable. When a pack is seeded, flip fixme -> test:
      //   await onboard(page, 'e2e-matrix');
      //   await page.goto('/social/matrix?room=<room>');
      //   await page.getByTestId('btn-sticker').click();
      //   await expect(page.getByTestId('sticker-picker')).toBeVisible();
      //   await page.getByTestId('sticker-neutral').click();          // sends m.sticker
      //   await expect(page.getByTestId('matrix-log')).toContainText(/* the sticker */);
      expect(page).toBeTruthy();
    });

  test(`A3 character part save -> 200 PENDING; GET /parts/{id}/svg serves a sanitized image/svg+xml ${tags({ role: 'ROLE_USER', layer: 'bff' })}`,
    async ({ baseURL }) => {
      const user = await loggedIn(baseURL, 'e2e-user');
      const h = await csrf(user);
      // Include a <script> to prove the sanitizer strips it.
      const dirtySvg = '<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"><script>alert(1)</script><rect width="8" height="8"/></svg>';
      const saved = await user.post('/bff/user/character/parts', {
        headers: h,
        data: { name: 'e2e-part', headArchetype: 'round', svg: dirtySvg },
      });
      expect(saved.status(), 'save character part').toBe(200);
      const body = await saved.json();
      expect(body.status, 'a freshly-saved part is PENDING').toBe('PENDING');
      expect(String(body.svg).includes('<script'), 'stored svg is sanitized (no <script>)').toBe(false);
      const id = body.id as string;

      const svg = await user.get(`/bff/user/character/parts/${id}/svg`);
      expect(svg.status(), 'serve part svg').toBe(200);
      expect((svg.headers()['content-type'] || '').includes('image/svg+xml')).toBe(true);
      const text = await svg.text();
      expect(text.includes('<svg'), 'served body is svg').toBe(true);
      expect(text.includes('<script'), 'served svg is sanitized').toBe(false);
      await user.dispose();
    });

  test(`A4 mod content-approval surface: MOD-gated findings/resolve are authorized, USER is denied; the ACTIVE-flip round-trip is pending ${tags({ role: 'ROLE_MOD', layer: 'bff' })}`,
    async ({ baseURL }) => {
      // The only fine-grained moderation channel that exists is per-ITEM content
      // approval via the mod findings queue. On the stock compose stack the
      // *effect* round-trip is NOT observable (test-seed -> 503 with
      // APP_TEST_SEED_ENABLED unset; the FindingActivationReconciler is dark; and
      // GET /bff/mod/findings itself 500s because the federation findings backend is
      // down). What IS observable and stable is the RBAC gate, so that is all we
      // assert as real; the flip is Group B (B1).
      const mod = await loggedIn(baseURL, 'e2e-mod');
      const user = await loggedIn(baseURL, 'e2e-user');

      // DENY: a plain USER cannot reach the mod queue or resolve.
      const userList = await user.get('/bff/mod/findings?status=held');
      expect(userList.status(), 'USER denied the mod findings queue').toBe(403);
      const userResolve = await user.post(`/bff/mod/findings/${BOGUS_ID}/resolve?actioned=false`);
      expect(userResolve.status(), 'USER denied finding resolution').toBe(403);

      // AUTHORIZED: the MOD is past the RBAC gate (not 401/403). The list currently
      // 500s (federation backend dark) and resolve of a bogus id 400s — both prove
      // authorization succeeded; neither is an auth denial.
      const modList = await mod.get('/bff/mod/findings?status=held');
      expect([401, 403], `MOD must be AUTHORIZED for the findings queue (got ${modList.status()})`).not.toContain(modList.status());
      const modResolve = await mod.post(`/bff/mod/findings/${BOGUS_ID}/resolve?actioned=false`);
      expect([401, 403], `MOD must be AUTHORIZED to resolve (got ${modResolve.status()})`).not.toContain(modResolve.status());

      test.info().annotations.push({
        type: 'observed',
        description: `mod GET /bff/mod/findings -> ${modList.status()} (federation findings backend dark), mod resolve(bogus) -> ${modResolve.status()}. The held -> resolve -> ACTIVE/REJECTED flip is pending (test-seed 503, reconciler dark) — see B1.`,
      });
      await mod.dispose();
      await user.dispose();
    });

  test(`A5 CONTROL: the only "ban" is coarse/whole-platform — no sticker/character ban target, and withdrawing platform access kills TEXT too ${tags({ role: 'ROLE_MOD', layer: 'bff' })}`,
    async ({ baseURL }) => {
      const mod = await loggedIn(baseURL, 'e2e-mod');
      const h = await csrf(mod);

      // The ban surface accepts ONLY platform matrix|mastodon|profile. A feature-
      // scoped target is rejected at validation BEFORE any effect (safe, non-
      // destructive — we never enact a real ban on a shared persona).
      for (const platform of ['sticker', 'character']) {
        const r = await mod.post('/bff/mod/ban', {
          headers: h,
          data: { platform, target: 'e2e-user', reason: 'A5 control' },
        });
        expect(r.status(), `ban {platform:${platform}} rejected (no feature-scoped ban target)`).toBe(400);
        const err = await r.json().catch(() => ({} as any));
        expect(JSON.stringify(err)).toMatch(/matrix.*mastodon.*profile/i);
      }
      await mod.dispose();

      // The modelled "banned from the platform" state is a user holding only
      // ROLE_USER (no ROLE_MATRIX/ROLE_MASTODON) — exactly what a whole-platform
      // suspension leaves behind. e2e-banned is 403 on BOTH homeserver surfaces,
      // i.e. it cannot send TEXT either. This is the crux: the only real block is
      // coarse and takes text with it.
      const banned = await loggedIn(baseURL, 'e2e-banned');
      const bMx = await banned.get(`${HS}/_matrix/client/v3/account/whoami`);
      expect(bMx.status(), 'no-platform-access user is 403 on the Matrix text path').toBe(403);
      const bMasto = await banned.get(`${MASTO}/api/v1/accounts/verify_credentials`);
      expect(bMasto.status(), 'no-platform-access user is 403 on the Mastodon path').toBe(403);
      await banned.dispose();
    });

  test(`A6 text baseline: a platform-access member sends Matrix TEXT + a Mastodon status -> success (the invariant a feature ban must preserve) ${tags({ role: 'ROLE_MATRIX', layer: 'homeserver' })}`,
    async ({ baseURL }) => {
      // Matrix text via e2e-matrix (ROLE_MATRIX).
      const mx = await loggedIn(baseURL, 'e2e-matrix');
      const roomId = await createRoom(mx, 'A6 text baseline');
      const marker = `A6 text ${txn()}`;
      const put = await mx.put(`${HS}/_matrix/client/v3/rooms/${roomId}/send/m.room.message/${txn()}`,
        { data: { msgtype: 'm.text', body: marker } });
      expect(put.status(), 'Matrix m.text send accepted').toBe(200);
      const evId = (await put.json()).event_id as string;
      const ev = await mx.get(`${HS}/_matrix/client/v3/rooms/${roomId}/event/${evId}`);
      expect(ev.status()).toBe(200);
      expect((await ev.json()).content.body).toBe(marker);
      await mx.dispose();

      // Mastodon status via e2e-mastodon (ROLE_MASTODON).
      const masto = await loggedIn(baseURL, 'e2e-mastodon');
      const h = await csrf(masto);
      const toot = await masto.post(`${MASTO}/api/v1/statuses`, {
        headers: h,
        data: { status: `A6 baseline toot ${txn()}`, visibility: 'public' },
      });
      expect(toot.status(), 'Mastodon status accepted').toBe(200);
      expect((await toot.json()).id, 'the created status has an id').toBeTruthy();
      await masto.dispose();
    });

  test(`A7 negative-space contract lock: no sticker/character/VN feature-role in the session; no /bff/mod ban target for a sticker/character id ${tags({ role: 'ROLE_USER', layer: 'bff' })}`,
    async ({ baseURL }) => {
      // (1) No role encodes a sticker/character/VN entitlement. If a role-scoped
      //     feature ban is ever built (B3), a ROLE_STICKER/ROLE_CHARACTER/ROLE_VN
      //     (or a role->feature deny-map) would appear here and this lock flips.
      for (const username of ['e2e-matrix', 'e2e-admin']) {
        const api = await loggedIn(baseURL, username);
        const s = await api.get('/bff/session');
        expect(s.status()).toBe(200);
        const roles: string[] = (await s.json()).roles ?? [];
        expect(roles.length, `${username} session hydrated with roles`).toBeGreaterThan(0);
        for (const role of roles) {
          expect(role, `${username} carries no sticker/character/VN feature-role (${role})`).not.toMatch(/sticker|character|\bvn\b/i);
        }
        await api.dispose();
      }

      // (2) The ban surface has no sticker/character id target — the only ban is
      //     keyed on platform (matrix|mastodon|profile). A sticker/character id as a
      //     platform value is rejected at validation.
      const mod = await loggedIn(baseURL, 'e2e-mod');
      const h = await csrf(mod);
      const r = await mod.post('/bff/mod/ban', {
        headers: h,
        data: { platform: 'sticker:some-sticker-id', target: 'e2e-user', reason: 'A7 lock' },
      });
      expect(r.status(), 'no ban target accepts a sticker/character id').toBe(400);
      await mod.dispose();
    });
});

// ════════════════════════════════════════════════════════════════════════════
// GROUP B — CONTRACT / PENDING. The fine-grained ban DOES NOT EXIST. These are
// `test.fixme` specs whose bodies encode the DESIRED endpoint+verb+status. They do
// NOT run (and would fail if run — the endpoints are unbuilt). Flip fixme -> test
// when the capability lands. Verbatim gap (sticker-vn-test-facts.md, "THE GAP"):
//
//   (a) Ban a SPECIFIC sticker/character globally/retroactively — NO. The closest is
//       REJECTing one owner's PENDING row via finding resolution, but it's keyed on
//       that owner's row id (not a global asset/pHash ban), it's PENDING-guarded (an
//       already-ACTIVE asset CANNOT be revoked), it's reactive to the auto-filed
//       finding queue (no proactive pick-any-asset-and-ban), and there is no
//       de-registration from im.ponies.user_emotes on REJECT. No direct admin "ban
//       sticker/character id" endpoint exists.
//   (b) Ban a USER from stickers/characters while preserving TEXT — MISSING ENTIRELY.
//       StickerController/CharacterPartController gate only on flat hasRole('USER');
//       no per-user feature marker/entitlement/deny-table on the sticker/character
//       path. The only per-user levers are whole-platform/whole-account suspensions,
//       and the suspension gate hard-403s the whole session — killing text too.
//   (c) Ban a ROLE from stickers/characters — MISSING ENTIRELY. No ROLE_STICKER/
//       ROLE_CHARACTER/ROLE_VN, no role->feature deny-map.
//
//   SILVER LINING: text and the VN asset library are ALREADY independent surfaces
//   (A6 proves text is untouched by any VN moderation state), so a correctly-scoped
//   feature ban would naturally leave text intact — only the ban mechanism is missing.
// ════════════════════════════════════════════════════════════════════════════
test.describe('28 GROUP B — fine-grained sticker/character ban (CONTRACT, capability NOT built)', () => {
  test.fixme(`B1 admin bans a SPECIFIC sticker id retroactively (ACTIVE -> REJECTED, de-registered from the pack) ${tags({ role: 'ROLE_ADMIN', layer: 'bff' })}`,
    async ({ baseURL }) => {
      // DESIRED (gap a): a direct, proactive, global asset ban that revokes an
      // already-ACTIVE sticker for EVERYONE and de-registers it from the pack.
      //   POST /bff/admin/character/stickers/{stickerId}/ban { reason }   -> 200
      //   GET  /bff/admin/character/stickers/{stickerId}                  -> status REJECTED
      //   effect: removed from the owner's im.ponies.user_emotes account-data pack.
      const admin = await loggedIn(baseURL, 'e2e-admin');
      const stickerId = 'an-ACTIVE-sticker-id';                       // pre-activated asset
      const ban = await admin.post(`/bff/admin/character/stickers/${stickerId}/ban`, { data: { reason: 'policy' } });
      expect(ban.status()).toBe(200);
      const after = await admin.get(`/bff/admin/character/stickers/${stickerId}`);
      expect((await after.json()).status).toBe('REJECTED');
      await admin.dispose();
    });

  test.fixme(`B2 admin bans a USER from stickers/characters while TEXT stays 200 ${tags({ role: 'ROLE_ADMIN', layer: 'bff' })}`,
    async ({ baseURL }) => {
      // DESIRED (gap b): a per-user feature ban that leaves text working.
      //   POST /bff/admin/users/{subject}/feature-ban { feature: 'sticker' }  -> 200
      //   THEN, as that user:
      //     POST /bff/user/character/stickers                       -> 403 (save denied)
      //     PUT  .../rooms/{room}/send/m.sticker/{txn}              -> 403 (send denied / render suppressed)
      //   WHILE text is UNAFFECTED:
      //     PUT  .../rooms/{room}/send/m.room.message/{txn} m.text  -> 200
      const admin = await loggedIn(baseURL, 'e2e-admin');
      const ban = await admin.post('/bff/admin/users/e2e-matrix/feature-ban', { data: { feature: 'sticker' } });
      expect(ban.status()).toBe(200);
      await admin.dispose();

      const target = await loggedIn(baseURL, 'e2e-matrix');
      const room = await createRoom(target, 'B2');
      const save = await target.post('/bff/user/character/stickers', {
        multipart: { file: { name: 'n.png', mimeType: 'image/png', buffer: PNG_1x1 }, expression: 'neutral' },
      });
      expect(save.status(), 'feature-banned user cannot SAVE a sticker').toBe(403);
      const sticker = await target.put(`${HS}/_matrix/client/v3/rooms/${room}/send/m.sticker/${txn()}`,
        { data: { body: 'x', url: 'mxc://stub.invalid/x', info: { w: 256, h: 256 }, 'systems.hugmesh.vn': { expression: 'neutral' } } });
      expect(sticker.status(), 'feature-banned user cannot SEND a sticker').toBe(403);
      const textMsg = await target.put(`${HS}/_matrix/client/v3/rooms/${room}/send/m.room.message/${txn()}`,
        { data: { msgtype: 'm.text', body: 'text still works' } });
      expect(textMsg.status(), 'TEXT is preserved by the feature ban').toBe(200);
      await target.dispose();
    });

  test.fixme(`B3 admin bans a ROLE from stickers/characters, text preserved ${tags({ role: 'ROLE_ADMIN', layer: 'casdoor' })}`,
    async ({ baseURL }) => {
      // DESIRED (gap c): a role-scoped feature ban. A dedicated feature role
      // (ROLE_STICKER/ROLE_CHARACTER/ROLE_VN) or a role->feature deny-map gates the
      // sticker/character path WITHOUT touching the platform access roles that gate
      // text. A user in the banned role:
      //   POST /bff/user/character/stickers                       -> 403
      //   PUT  .../send/m.sticker/{txn}                           -> 403
      //   PUT  .../send/m.room.message/{txn} m.text               -> 200
      // and GET /bff/session for that user would surface the (currently absent)
      // feature role — which is exactly what A7 locks against today.
      const admin = await loggedIn(baseURL, 'e2e-admin');
      const grant = await admin.post('/bff/admin/roles/ROLE_STICKER_BANNED/assign', { data: { target: 'e2e-matrix' } });
      expect(grant.status()).toBe(200);
      await admin.dispose();

      const target = await loggedIn(baseURL, 'e2e-matrix');
      const save = await target.post('/bff/user/character/stickers', {
        multipart: { file: { name: 'n.png', mimeType: 'image/png', buffer: PNG_1x1 }, expression: 'neutral' },
      });
      expect(save.status(), 'role-banned user cannot save a sticker').toBe(403);
      const room = await createRoom(target, 'B3');
      const textMsg = await target.put(`${HS}/_matrix/client/v3/rooms/${room}/send/m.room.message/${txn()}`,
        { data: { msgtype: 'm.text', body: 'text still works' } });
      expect(textMsg.status(), 'TEXT is preserved by the role ban').toBe(200);
      await target.dispose();
    });

  test.fixme(`B4 ban a SPECIFIC character used in messages (needs first-class per-message character identity + send-time enforcement) ${tags({ role: 'ROLE_ADMIN', layer: 'homeserver' })}`,
    async ({ baseURL }) => {
      // DESIRED (gap a, character variant): a character is a first-class identity
      // carried per-message (e.g. content['systems.hugmesh.vn'].characterId), and
      // banning it enforces at SEND time.
      //   POST /bff/admin/character/{characterId}/ban { reason }  -> 200
      //   THEN a send referencing that character:
      //     PUT .../send/m.room.message/{txn} { 'systems.hugmesh.vn': { characterId } } -> 403 (or stripped)
      //   WHILE a plain-text send (no characterId) is unaffected -> 200.
      // Today the only per-message VN field is a free-form `vn.expression`; there is
      // NO stored character identity and NO send-time enforcement (the homeserver
      // forwards custom content verbatim — A2 proves it round-trips unchecked).
      const admin = await loggedIn(baseURL, 'e2e-admin');
      const characterId = 'a-character-id';
      const ban = await admin.post(`/bff/admin/character/${characterId}/ban`, { data: { reason: 'policy' } });
      expect(ban.status()).toBe(200);
      await admin.dispose();

      const target = await loggedIn(baseURL, 'e2e-matrix');
      const room = await createRoom(target, 'B4');
      const withChar = await target.put(`${HS}/_matrix/client/v3/rooms/${room}/send/m.room.message/${txn()}`,
        { data: { msgtype: 'm.text', body: 'in character', 'systems.hugmesh.vn': { characterId } } });
      expect(withChar.status(), 'a send referencing the banned character is rejected').toBe(403);
      const plain = await target.put(`${HS}/_matrix/client/v3/rooms/${room}/send/m.room.message/${txn()}`,
        { data: { msgtype: 'm.text', body: 'plain text' } });
      expect(plain.status(), 'plain text is unaffected').toBe(200);
      await target.dispose();
    });

  test.fixme(`B5 Akkoma/Mastodon sticker/character moderation — N/A (no such feature exists there) ${tags({ role: 'ROLE_MOD', layer: 'homeserver' })}`,
    async ({ baseURL }) => {
      // N/A, not merely pending: Mastodon/Akkoma has ZERO sticker/character/VN
      // feature (the only sticker-like analog is a standard custom_emoji shortcode
      // in status text). There is nothing platform-native to moderate, so a
      // cross-platform sticker/character ban is impossible there until such a
      // feature is built on the Mastodon side. If it ever is, the desired shape
      // mirrors B1/B2 against a Mastodon moderation endpoint; recorded here so the
      // cross-platform matrix is explicit rather than silently missing.
      const mod = await loggedIn(baseURL, 'e2e-mod');
      const r = await mod.post('/bff/mod/mastodon/character/ban', { data: { characterId: 'x' } });
      expect(r.status()).toBe(200);
      await mod.dispose();
    });
});
