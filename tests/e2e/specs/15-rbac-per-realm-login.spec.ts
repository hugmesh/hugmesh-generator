import { test, expect, request } from '@playwright/test';
import type { APIRequestContext } from '@playwright/test';
import {
  SYSTEMS_SEED_USERS, GAMES_SEED_USERS, passwordFor, systemsUser,
} from './rbac-roles';

// 15 — Per-realm login.
//
// Two INDEPENDENT realms:
//   * SYSTEMS Casdoor (org "hugmesh", issuer id.hugmesh.systems)
//   * GAMES  Casdoor (org "threewizards", issuer id.hugmesh.games)
//
// What's testable TODAY vs what's pending:
//   * SYSTEMS, mock stack: the mock-bff models exactly TWO role tiers it can
//     distinguish by username (admin via ADMIN_EMAILS, else plain user). We assert
//     BOTH sign in through OUR native /bff/login and carry the right `roles` back
//     from GET /bff/session (the httpOnly bff_session cookie — the only browser-
//     readable identity in the native model) — the realistic floor of the systems
//     login at a surface that runs right now.
//   * SYSTEMS, real Casdoor: a full per-ROLE login (ROLE_MOD / ROLE_GAMES /
//     ROLE_GAMES_ADMIN / pending) needs a real seeded Casdoor — provisioned by
//     tests/qemu/seed-accounts.sh --roles. That login is exercised by spec 14
//     (LIVE_GATEWAY); here we assert the seed CATALOGUE is internally consistent
//     so the seeder + the live login agree on usernames/passwords/roles.
//   * GAMES realm login is owned by hugmesh.games/e2e (roles.ts login()); we
//     only assert the cross-realm catalogue agrees (the e2e-player handle + the
//     synced e2e-gamesadmin -> games admin expectation).

const ADMIN_EMAIL = process.env.ADMIN_EMAIL || 'admin@hugmesh.systems';
// Deterministic native password every seeded/invited persona signs in with.
const LOGIN_PASSWORD = process.env.E2E_PASSWORD || 'e2e-pass';

// Native sign-in through OUR /bff/login: the opaque httpOnly bff_session cookie is
// stored in THIS context's cookie jar and rides subsequent /bff/** calls (no bearer
// token is ever exposed). An un-provisioned username 401s.
async function loginAs(api: APIRequestContext, username: string, password = LOGIN_PASSWORD): Promise<void> {
  const r = await api.post('/bff/login', { data: { username, password } });
  expect(r.status(), `native login ${username} -> ${r.status()}`).toBe(200);
}

test.describe('RBAC: per-realm login', () => {
  test('SYSTEMS realm — admin logs in via the BFF and carries the admin role', async ({ baseURL }) => {
    const api = await request.newContext({ baseURL, ignoreHTTPSErrors: true });
    await loginAs(api, ADMIN_EMAIL);
    // GET /bff/session round-trips the role-set from the httpOnly cookie session —
    // the ONLY browser-readable identity in the native model (no token is exposed).
    const me = await api.get('/bff/session', { headers: { accept: 'application/json' } });
    expect(me.status()).toBe(200);
    expect((await me.json()).roles, 'admin username -> roles include admin').toContain('admin');
    await api.dispose();
  });

  test('SYSTEMS realm — a plain invited user logs in WITHOUT the admin role', async ({ baseURL }) => {
    // Admin (its own context/cookie) invites a plain user; the invite provisions a
    // native account with roles ['user'] so it can sign in.
    const adminApi = await request.newContext({ baseURL, ignoreHTTPSErrors: true });
    await loginAs(adminApi, ADMIN_EMAIL);
    await adminApi.post('/bff/admin/allowlist', { data: { email: 'rbac-login-user@gmail.com' } });

    // The invited user signs in natively in its OWN context and carries ['user'].
    const userApi = await request.newContext({ baseURL, ignoreHTTPSErrors: true });
    await loginAs(userApi, 'rbac-login-user@gmail.com');
    const me = await userApi.get('/bff/session', { headers: { accept: 'application/json' } });
    const session = await me.json();
    expect(session.roles).toEqual(['user']);
    expect(session.roles).not.toContain('admin');
    await userApi.dispose();
    await adminApi.dispose();
  });

  test('SYSTEMS realm — seed catalogue is internally consistent (deterministic passwords + roles)', async () => {
    // Each seed user has a username, a per-user password env, and (except the
    // pending user) at least one role. ROLE_GAMES_ADMIN is NEVER directly granted.
    const usernames = new Set<string>();
    for (const u of SYSTEMS_SEED_USERS) {
      expect(u.username, 'username present').toBeTruthy();
      expect(usernames.has(u.username), `duplicate username ${u.username}`).toBeFalsy();
      usernames.add(u.username);
      expect(u.passwordEnv).toMatch(/^E2E_.*_PASSWORD$/);
      expect(passwordFor(u), `password resolves for ${u.username}`).toBeTruthy();
      expect(u.roles, `${u.username}: ROLE_GAMES_ADMIN must never be granted directly`)
        .not.toContain('ROLE_GAMES_ADMIN');
      if (u.username === 'e2e-pending') {
        expect(u.roles).toHaveLength(0);
        expect(u.registrationComplete).toBe(false);
      } else {
        expect(u.roles.length).toBeGreaterThan(0);
      }
    }
    // The exact required matrix is present.
    for (const required of ['e2e-admin', 'e2e-mod', 'e2e-gamesadmin', 'e2e-gamesonly', 'e2e-adminonly', 'e2e-user', 'e2e-pending']) {
      expect(usernames.has(required), `missing required seed user ${required}`).toBeTruthy();
    }
  });

  test('GAMES realm — catalogue has a native player + the synced games admin expectation', async () => {
    const player = GAMES_SEED_USERS.find((u) => u.username === 'e2e-player');
    expect(player, 'native games player seeded').toBeTruthy();
    expect(player!.roles).toContain('player');

    const syncedAdmin = GAMES_SEED_USERS.find((u) => u.syncedFromSystems === 'ROLE_GAMES_ADMIN');
    expect(syncedAdmin, 'games admin expected via systems->games sync').toBeTruthy();
    // The systems-side source of that sync must be a games-admin-qualifying user.
    expect(systemsUser(syncedAdmin!.username).expectGamesAdmin,
      'the synced games admin must come from a ROLE_GAMES_ADMIN systems user').toBe(true);
    // (The cross-realm sync assertion itself lives in hugmesh-actions/e2e.)
  });

  // Full per-ROLE UI login (mod / games / gamesadmin / pending) against a real
  // systems Casdoor — pending the real-Casdoor stack. See spec 14 for the live
  // token-grant path; this stub records the intent at the UI layer.
  test.skip('SYSTEMS realm — UI login as each ROLE_* principal (needs real Casdoor)', async () => {
    // TODO(real-Casdoor): when tests/stack grows a role-seeded Casdoor (apply via
    // seed-accounts.sh --roles), drive /login per SYSTEMS_SEED_USERS entry and
    // assert the JWT `roles` claim matches the catalogue. The mock-bff cannot mint
    // ROLE_MOD/ROLE_GAMES today (binary admin|user only).
  });
});
