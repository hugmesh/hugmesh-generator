import { test, expect } from '@playwright/test';

// 18 — PENDING RBAC specs for Phase 8/10 UI surfaces NOT YET BUILT.
//
// These are clearly-marked test.skip() stubs — they do NOT fake a pass. Each
// references the role + the intended ALLOW/DENY assertion, and the surface it
// waits on, so it activates the moment that UI/identity lands. The investigation
// found these surfaces do not exist today:
//
//   * NO systems-host /games/admin UI mount, NO ROLE_GAMES/ROLE_MOD-conditional
//     nav in the host shell (hugmesh-matrix-ui/projects/host).
//   * NO app-level ROLE_MOD moderation UI (the Matrix UI kick/power-level is
//     gated by MATRIX power levels, not the Casdoor ROLE_MOD).
//   * SessionService only derives isAdmin (binary) — no isMod/isGames/isGamesAdmin.
//   * svc-* service identities are seeded/asserted NOWHERE.
//
// When the UI exists, drive it with a real-Casdoor login per SYSTEMS_SEED_USERS
// entry (token grant per spec 14 / a UI login helper modeled on the games
// roles.ts login()), then replace the body of the matching stub.

test.describe('PENDING (Phase 8/10): systems host shell role-conditional nav', () => {
  test.skip('host shell shows admin nav for ROLE_ADMIN, hides it for ROLE_USER', async () => {
    // TODO(Phase8): when SessionService derives isAdmin from the Casdoor JWT
    // `roles` claim (not just the mock email), assert e2e-admin sees nav-admin and
    // e2e-user does not. Surface: hugmesh-matrix-ui/projects/host nav.
    expect(true).toBe(true);
  });

  test.skip('host shell shows a ROLE_GAMES games entry-point only for games members', async () => {
    // TODO(Phase8): no ROLE_GAMES reference exists in the host shell yet. When a
    // /games entry-point lands, assert e2e-gamesonly + e2e-gamesadmin see it and
    // e2e-user/e2e-mod do not. NOTE: plain ROLE_GAMES grants a games ENTRY-POINT,
    // not games ADMIN.
    expect(true).toBe(true);
  });

  test.skip('host shell shows a ROLE_MOD moderation entry-point only for moderators', async () => {
    // TODO(Phase10): SessionService has no isMod() today. When it does, assert
    // e2e-mod sees the moderation nav and e2e-user/e2e-admin-only-by-itself follow
    // the sibling rule (admin is NOT auto a mod in the nav unless also ROLE_MOD).
    expect(true).toBe(true);
  });
});

test.describe('PENDING (Phase 8/10): app-level ROLE_MOD moderation UI', () => {
  test.skip('ROLE_MOD reaches the akkoma/Matrix moderation UI but NOT infra/logs/server-admin', async () => {
    // TODO(Phase10): the only moderation UI today (Matrix member-list kick /
    // power-levels) is gated by MATRIX power levels (PL50), NOT a Casdoor ROLE_MOD
    // guard. When an app-level ROLE_MOD-guarded moderation surface exists, log in
    // as e2e-mod and assert: moderation panels visible; any infra/logs/server-admin
    // link absent + direct nav blocked. Contract already covered by spec 16.
    expect(true).toBe(true);
  });
});

test.describe('PENDING (Phase 8/10): games-admin gate at the real UI', () => {
  test.skip('e2e-gamesadmin reaches /games/admin/** UI; e2e-gamesonly + e2e-adminonly are DENIED', async () => {
    // TODO(Phase8): no systems-host /games/admin mount exists. When the fe-gateway
    // + the games-admin UI land, log in (real Casdoor) as:
    //   e2e-gamesadmin  -> /games/admin/** renders (derived ROLE_GAMES_ADMIN)
    //   e2e-gamesonly   -> 403 / redirect (ROLE_GAMES alone)
    //   e2e-adminonly   -> 403 / redirect (ROLE_ADMIN alone)
    // The gateway-layer version of this assertion is LIVE in spec 14 (LIVE_GATEWAY)
    // and contract-locked in spec 12.
    expect(true).toBe(true);
  });
});

test.describe('PENDING (Phase 8/10): svc-* service identities', () => {
  test.skip('svc-* identities authenticate with ONLY their service role and reach nothing user-facing', async () => {
    // TODO: the svc-pki-gateway / svc-be-gateway / svc-fe-gateway /
    // svc-api / svc-admin-bff machine users (manifests/casdoor init-data) are not
    // seeded or asserted by any harness. When a stack provisions them, assert each
    // svc-* token reaches ONLY its declared service surface and is denied the
    // human role-gated routes (/admin, moderation, /games/admin). No UI — pure
    // token-grant + gateway probe (extend spec 14's LIVE_PROBES).
    expect(true).toBe(true);
  });
});
