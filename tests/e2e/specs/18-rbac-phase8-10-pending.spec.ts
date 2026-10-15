import { test, expect, Page } from '@playwright/test';
import { onboard, SHELL_AFTER_PROVISION_MS } from './helpers';
import { loginPassword } from './rbac-roles';
import { tags } from './report-tags';

// 18 — PENDING RBAC specs for Phase 8/10 UI surfaces NOT YET BUILT.
//
// These are clearly-marked test.skip() stubs — they do NOT fake a pass. Each
// references the role + the intended ALLOW/DENY assertion, and the surface it
// waits on, so it activates the moment that UI/identity lands. The investigation
// found these surfaces do not exist today:
//
//   * NO systems-host /games/admin UI mount, NO ROLE_GAMES/ROLE_MOD-conditional
//     nav in the host shell (hugmesh-matrix-ui/projects/host).
//     ^ SUPERSEDED for ROLE_GAMES: the shell that actually ships is
//     hugmesh-host-shell (apps/40-frontend.yaml + the fe-gateway routes in
//     apps/20-gateway-fe.yaml), NOT hugmesh-matrix-ui/projects/host, and it now
//     renders a ROLE_GAMES-gated games entry-point. See the LIVE describe at the
//     bottom of this file, which replaced that stub.
//   * NO app-level ROLE_MOD moderation UI (the Matrix UI kick/power-level is
//     gated by MATRIX power levels, not the Casdoor ROLE_MOD).
//   * SessionService only derives isAdmin (binary) — no isMod/isGames/isGamesAdmin.
//     ^ ALSO SUPERSEDED: hugmesh-host-shell's SessionService derives isMod, isGames
//     and isGamesAdmin (the last as ROLE_GAMES ∩ (ROLE_ADMIN ∪ ROLE_MOD), never
//     granted directly). The ROLE_MOD stub above stays pending only because its
//     app-level moderation SURFACE is what is missing, not the role derivation.
//   * svc-* service identities are seeded/asserted NOWHERE.
//
// When the UI exists, drive it with a real-Casdoor login per SYSTEMS_SEED_USERS
// entry (token grant per spec 14 / a UI login helper modeled on the games
// roles.ts login()), then replace the body of the matching stub.

test.describe('PENDING (Phase 8/10): systems host shell role-conditional nav', () => {
  // The 'host shell shows admin nav for ROLE_ADMIN, hides it for ROLE_USER' stub
  // that sat here is LIVE in spec 33 (33-console-access-matrix.spec.ts): e2e-admin
  // must see `nav-admin`, e2e-user must render none. hugmesh-host-shell's isAdmin()
  // reads the session `roles` (menu.component.ts gates nav-admin on it), not the
  // mock email this stub waited to see replaced. Its greyed-with-helptext twin, the
  // `/home` admin launcher card, is LIVE in spec 24 (E).
  //
  // The ROLE_GAMES games entry-point stub that sat here is now the LIVE describe
  // at the bottom of this file — the surface it waited on shipped.

  test.skip('host shell shows a ROLE_MOD moderation entry-point only for moderators', async () => {
    // TODO(Phase10): STILL PENDING, but NOT for the reason this stub used to give.
    // The old premise ("SessionService has no isMod() today") is FALSE:
    // hugmesh-host-shell/src/app/session.service.ts defines isMod, menu.component.ts
    // hides the Moderation entry unless isMod(), and the home launcher carries a
    // `mod` card. What blocks un-skipping is the ASSERTION this stub names, not the
    // surface: isMod() is DELIBERATELY WIDENED to `mod || admin || superadmin`
    // (session.service.ts documents why — an admin without a literal mod role was
    // locked out of the Matrix/Mastodon moderation console). So "admin is NOT auto a
    // mod in the nav unless also ROLE_MOD" is the OPPOSITE of what this shell ships.
    // Writing the test needs someone to decide which behaviour is the contract —
    // that is a product decision, not a test detail, so it is not settled here.
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
    // TODO(Phase8): the old premise ("no systems-host /games/admin mount exists")
    // is FALSE — hugmesh-host-shell/src/app/app.routes.ts mounts `games/admin`
    // behind gamesAdminGuard. What it mounts is a GUARDED LOCAL PLACEHOLDER
    // (GamesAdminPlaceholderComponent), not a console, so there is still no
    // games-admin UI to assert ALLOW/DENY against beyond the guard itself; the
    // CARD-level half of this contract is now LIVE at the bottom of this file.
    // When the real games-admin UI lands, log in (real Casdoor) as:
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

// ────────────────────────────────────────────────────────────────────────────
// LIVE (Phase 8) — the host shell's ROLE_GAMES games entry-point.
//
// This replaced the `test.skip('host shell shows a ROLE_GAMES games entry-point
// only for games members')` stub. The stub's premise was checked before it was
// rewritten, and the answer changed BOTH the verdict and the surface:
//
//   * The shell that ships is hugmesh-host-shell, not the demo host the stub
//     named (hugmesh-matrix-ui/projects/host). apps/40-frontend.yaml deploys
//     hugmesh-host-shell and every apex fe-gateway route in
//     apps/20-gateway-fe.yaml forwards to it.
//   * hugmesh-host-shell has NO `nav-games` menubar entry — grep finds none, and
//     MenuComponent's entry list carries no games row. Asserting `nav-games`
//     would have been an assertion against a testid nothing renders.
//   * The entry-point it DOES render is the launcher card on the public `/home`
//     page: HomeServicesComponent's `data-testid="card-games"`, whose catalog
//     row is `{ id: 'games', route: '/games', slug: 'games',
//     requiresRole: 'games' }`, gated on SessionService.isGames().
//
// SHAPE OF THE ASSERTION — the shell greys, it does not hide. Every card renders
// for every signed-in principal and carries `data-state`; only the state changes:
//   enabled -> an <a> to the route
//   role    -> a disabled <span aria-disabled="true"> + a `card-<id>-help`
//              helptext naming the role you would need
//   absent  -> the OPTIONAL service is not installed on this deployment
// So "only for games members" cannot be asserted as presence/absence — the real
// contract is enabled-vs-role-gated, and asserting toHaveCount(0) for a
// non-member would fail against a correct shell. That is precisely why the stub
// had to be re-derived from the shipped UI rather than un-skipped as written.
//
// ⚠ ON EVERY LANE THIS REPO BRINGS UP BY DEFAULT, THESE FOUR TESTS SKIP. Read
// that before reading the assertions: the role half of this contract does NOT
// execute on `make stack-up && make stack-seed && make stack-e2e`, and calling
// this TODO "fixed" without that sentence overstates it.
//
// WHY. `games` is an OPTIONAL service and it is DEFAULT-OFF everywhere:
//   * specs/cluster/optional-services.yaml — "DEFAULT-OFF (must be specifically
//     added): games, owncast, tube, character-studio, character-forge ... games
//     moved from default-on to DEFAULT-OFF here".
//   * specs/cluster/manifests/federation-modules-gate/sql/gate.sql — the
//     committed baseline is `UPDATE federation_modules SET enabled = false WHERE
//     slug = 'games';`, and the host shell resolves install-state from THAT table.
//   * specs/cluster/bootstrap/kind-local/bootstrap-kind.sh — "Explicitly NOT
//     applied ...: games (50-games, 06-casdoor-games)".
//   * Makefile — `STACK_GAMES_PROFILE := $(if $(strip $(GAMES)),--profile games,)`,
//     i.e. the compose games tier is opt-in.
// CapabilitiesService fails CLOSED (an unknown slug, or a failed fetch, reports
// NOT installed), so installed('games') is false and HomeServicesService.resolve
// returns 'absent' — which DOMINATES the role gate (it is ordered first). Every
// principal then sees the same absent card and the role contract is untestable.
//
// TO ACTUALLY RUN THE ROLE HALF, on the compose lane, both knobs are needed:
//   GAMES=1 make stack-up                      # bring the games tier up
//   HUGMESH_FEDERATION_ENABLE='games' make stack-seed
//                                              # seed-e2e.sh leg 4 flips the
//                                              # federation_modules row to true
// then `make stack-e2e E2E_SPECS=specs/18-rbac-phase8-10-pending.spec.ts`. On
// kind, additionally apply apps/50-games.yaml + apps/06-casdoor-games.yaml, which
// bootstrap-kind.sh deliberately does not.
//
// WHAT STILL RUNS ON THE DEFAULT LANE, so this is not a decorative test:
//   * cardState() asserts the card is ATTACHED before any skip can fire, so the
//     shell's greys-it-never-hides contract is exercised for all four principals.
//   * onboard() is a real Casdoor sign-in — a broken login fails here, it does
//     not skip.
//   * the absent branch below asserts absence is COHERENT (both cards absent
//     together, since `games` and `games-admin` share one install-state slug) and
//     EXPLAINED (aria-disabled + a helptext) before skipping. A shell that hid an
//     absent card, or greyed only one of the pair, fails on the default lane.
//
// NOT ASSERTED, deliberately: e2e-adminonly. The CARD gate is isGames() alone,
// while hugmesh-host-shell's gamesGuard admits isGames() || isAdmin() ||
// isSuperadmin() — so a bare admin is offered a greyed card for a route their
// own guard would let them open. That is a real cross-surface inconsistency in
// the shell, not something this spec should silently pick a side on; pinning it
// belongs in a host-shell issue, not in an assertion invented here.
// ────────────────────────────────────────────────────────────────────────────

/** The card states HomeServicesService can resolve (service-card.model.ts). */
type CardState = 'enabled' | 'role' | 'registration' | 'absent';

interface GamesEntryExpectation {
  username: string;
  /** `card-games` — the ROLE_GAMES ENTRY-POINT. */
  entry: CardState;
  /** `card-games-admin` — the DERIVED ROLE_GAMES_ADMIN console. A bare
   *  ROLE_GAMES must NOT earn it; that was the stub's own closing note. */
  adminEntry: CardState;
  why: string;
}

const GAMES_ENTRY: GamesEntryExpectation[] = [
  {
    username: 'e2e-gamesonly', entry: 'enabled', adminEntry: 'role',
    why: 'ROLE_GAMES alone: earns the entry-point, and NOT games-admin (the derived '
       + 'role needs ROLE_GAMES ∩ (ROLE_ADMIN ∪ ROLE_MOD))',
  },
  {
    username: 'e2e-gamesadmin', entry: 'enabled', adminEntry: 'enabled',
    why: 'ROLE_GAMES + ROLE_ADMIN: earns both the entry-point and the derived games-admin console',
  },
  {
    username: 'e2e-user', entry: 'role', adminEntry: 'role',
    why: 'ROLE_USER only: both cards greyed with the role helptext, never hidden',
  },
  {
    username: 'e2e-mod', entry: 'role', adminEntry: 'role',
    why: 'ROLE_MOD is a SIBLING of games, not a superset: mod alone earns neither card',
  },
];

/** Read a launcher card's resolved state off the rendered `/home` grid. */
async function cardState(page: Page, testid: string): Promise<CardState> {
  const card = page.getByTestId(testid);
  await expect(
    card,
    `${testid} must render for every signed-in principal — this shell GREYS gated `
    + 'entries rather than hiding them, so a missing card is a defect, not a deny',
  ).toBeAttached({ timeout: SHELL_AFTER_PROVISION_MS });
  return (await card.getAttribute('data-state')) as CardState;
}

test.describe('LIVE (Phase 8): host shell ROLE_GAMES games entry-point', () => {
  for (const c of GAMES_ENTRY) {
    test(`${c.username}: games entry-point is ${c.entry}, games-admin is ${c.adminEntry} — ${c.why} `
      + tags({ role: 'ROLE_GAMES', layer: 'ui' }), async ({ page }) => {
      await onboard(page, c.username, loginPassword());
      // The launcher grid lives on the PUBLIC /home page (HomeServicesComponent),
      // not on the signed-in /user home — MenuComponent's isHomeUrl() explicitly
      // excludes /home from its own home-cards branch precisely because /home
      // already carries this full grid. Signed in, /home has no guard and the
      // cards read the live session.
      await page.goto('/home');

      // Both cards up front: `games` and `games-admin` share ONE install-state
      // slug ('games'), so the absent branch below can check they agree instead
      // of skipping on an unexamined single reading.
      const entry = await cardState(page, 'card-games');
      const adminEntry = await cardState(page, 'card-games-admin');

      if (entry === 'absent') {
        // NOT a bare skip. Absence is the DEFAULT outcome here (see the header),
        // so it is the branch that actually runs in CI — assert what absence is
        // still required to look like before standing down.
        expect(adminEntry,
          `${c.username}: card-games and card-games-admin share the SAME 'games' `
          + 'install-state slug, so absent must dominate BOTH or neither — one absent '
          + 'and one not means the install-state gate is not being applied uniformly')
          .toBe('absent');
        await expect(page.getByTestId('card-games')).toHaveAttribute('aria-disabled', 'true');
        await expect(page.getByTestId('card-games-help'))
          .toHaveText(/not available on this deployment/i);
        test.skip(
          true,
          'the OPTIONAL `games` service is not installed on this deployment — the DEFAULT '
          + 'state on every lane this repo brings up (games is DEFAULT-OFF; see the header '
          + 'for the two knobs that turn it on). The greys-not-hides + coherent-absence '
          + 'contract above DID run; the ROLE_GAMES gate below did not.',
        );
      }

      expect(entry, `${c.username}: ${c.why}`).toBe(c.entry);
      expect(adminEntry,
        `${c.username}: games-admin is DERIVED, never granted directly`).toBe(c.adminEntry);

      if (c.entry === 'enabled') {
        // Enabled means followable, not merely un-greyed: the card is the <a>
        // branch of the template and points at the guarded /games mount.
        await expect(page.getByTestId('card-games')).toHaveAttribute('href', /\/games$/);
      } else {
        // Greyed means EXPLAINED: aria-disabled plus a helptext naming the role.
        // A silently-hidden or unexplained entry is the failure this shell's
        // disabled+helptext idiom exists to prevent.
        await expect(page.getByTestId('card-games')).toHaveAttribute('aria-disabled', 'true');
        await expect(page.getByTestId('card-games-help')).toHaveText(/games member/i);
      }
    });
  }
});
