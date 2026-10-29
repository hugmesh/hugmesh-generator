// function-catalogue.ts — the FUNCTION axis for the four media/games services
// (owncast, tube, games, character-studio + character-forge).
//
// WHY A FOURTH AXIS EXISTS. steps/dimensions.ts spells ROLE × PLATFORM × SERVICE
// and steps/dimensions.ts (env/interface) spells WHICH MESH × HOW DRIVEN. None of
// them says WHAT THE USER IS DOING. "owncast is covered" was true of a suite that
// opened the console and never asked whether a stream can be published, watched,
// granted or moderated — four different code paths, four different gates, one
// green tick. The operator's requirement is "every user in every FUNCTION in every
// service", so the function is a first-class, enumerated thing, and a function
// with no scenario is a HOLE THE GUARD REPORTS rather than a hole nobody counts.
//
// THIS FILE IS THE ORACLE, NOT THE COVERAGE. Nothing here drives a browser. Each
// entry records, for one function of one service:
//   * the gateway surface it actually travels (gateway + url pattern), read off
//     the SAME committed route-access seed steps/uncovered-services.steps.ts
//     parses — never re-typed here, only NAMED here;
//   * the role that seed grants at that surface;
//   * whether the function can be driven end-to-end on a default-seeded mesh, and
//     when it cannot, the VERBATIM reason.
//
// THE THREE DRIVEABILITY VERDICTS, and why "no-audience" is not the same as
// "absent":
//   'ui'          a seeded persona really can drive it in a browser today.
//   'no-audience' the surface EXISTS and is wired, but no persona in either e2e
//                 roster holds the role that reaches it. The scenario is written
//                 and PENDING; the day a persona is seeded, seededAudience()
//                 changes and the guard in media-games-function-matrix.feature
//                 goes red, which is the prompt to un-pend it.
//   'absent'      nothing is mounted to drive at all — the code that would serve
//                 this function is not in the mesh. A pending scenario here would
//                 be waiting on a BUILD, not on a seed.
//
// NOTHING IN THIS FILE IS READ FROM A SIBLING CHECKOUT AT RUN TIME. The selectors
// and BFF paths quoted in the notes were read by hand out of hugmesh-owncast-ui,
// hugmesh-tube-ui, hugmesh-character-studio-ui, hugmesh-character-forge-bff-api
// and hugmesh-host-shell while writing this — exactly as the handwritten specs'
// selectors were, and exactly as uncovered-services.steps.ts already documents.
// The ASSERTIONS resolve against files in THIS repo only.

import { SYSTEMS_SEED_USERS } from '../specs/rbac-roles';
import { shellRoster, knownPersonas, service } from './dimensions';

/** The two gateways whose route-access rows this domain's functions travel. */
export type FunctionGateway = 'hugmesh-fe-gateway' | 'hugmesh-be-gateway';

export type Driveability = 'ui' | 'no-audience' | 'absent';

export interface MeshFunction {
  /** The service id — MUST be a legal steps/dimensions.ts SERVICES id. */
  service: string;
  /** Canonical function id — the exact spelling a `@function:` tag uses. */
  id: string;
  /** What the user is actually doing, in the product's own words. */
  name: string;
  /** The gateway whose route-access row governs this function. */
  gateway: FunctionGateway;
  /** The url_pattern of that row, verbatim as the seed spells it. */
  pattern: string;
  /** The role that row grants. */
  gateRole: string;
  driveability: Driveability;
  /**
   * For 'no-audience' / 'absent': the reason, verbatim, in the form a pending
   * scenario quotes. Empty for 'ui' — a drivable function needs no excuse.
   */
  blockedBy: string;
  note: string;
}

/** The services this catalogue is scoped to. Pinned so that adding a service
 *  here without adding it to the census Examples table fails loudly. */
export const CATALOGUED_SERVICES = [
  'owncast', 'tube', 'games', 'character-studio', 'character-forge',
] as const;

export const FUNCTIONS: MeshFunction[] = [
  // ── owncast ────────────────────────────────────────────────────────────────
  {
    service: 'owncast', id: 'console', name: 'open the console and see the role-aware nav',
    gateway: 'hugmesh-fe-gateway', pattern: '/owncast/**', gateRole: 'ROLE_OWNCAST',
    driveability: 'ui', blockedBy: '',
    note: 'The host-shell owncastGuard admits admin | superadmin | ROLE_OWNCAST, and the '
        + 'gateway admin-bypass carries admins past the ROLE_OWNCAST floor row, so the '
        + 'seeded admin personas reach the shell. Nav items: owncast-nav-stream (streamers), '
        + 'owncast-nav-grants (admin|superadmin), owncast-nav-moderation (mod|admin|superadmin).',
  },
  {
    service: 'owncast', id: 'publish', name: 'create and edit my own stream',
    gateway: 'hugmesh-fe-gateway', pattern: '/bff/owncast/**', gateRole: 'ROLE_OWNCAST',
    driveability: 'no-audience',
    blockedBy: 'no persona in either e2e roster holds ROLE_OWNCAST, so nothing can reach '
             + '/owncast/stream — the in-remote owncastStreamGuard is canStream() = '
             + 'ROLE_OWNCAST ALONE and an admin is not a streamer. Seed e.g. '
             + 'e2e-owncast:ROLE_OWNCAST,ROLE_USER:E2E_OWNCAST_PASSWORD in '
             + 'tests/e2e-extra-personas.sh, then un-pend this scenario.',
    note: 'owncast-stream-title-input / owncast-stream-desc-input / owncast-stream-save.',
  },
  {
    service: 'owncast', id: 'visibility', name: 'flip my stream between internal and public',
    gateway: 'hugmesh-fe-gateway', pattern: '/bff/owncast/**', gateRole: 'ROLE_OWNCAST',
    driveability: 'no-audience',
    blockedBy: 'same missing ROLE_OWNCAST persona as owncast/publish; the visibility '
             + 'fieldset lives INSIDE /owncast/stream, which nothing seeded can open.',
    note: 'owncast-stream-vis-internal / owncast-stream-vis-public / '
        + 'owncast-stream-public-disabled-help / owncast-stream-try-public. The public '
        + 'radio is the canonical disabled+helptext gate: it disables only alongside a '
        + 'VISIBLE explanation of why.',
  },
  {
    service: 'owncast', id: 'watch', name: 'watch a stream in-platform',
    gateway: 'hugmesh-fe-gateway', pattern: '/bff/owncast/**', gateRole: 'ROLE_OWNCAST',
    driveability: 'no-audience',
    blockedBy: 'the only in-platform player in the owncast console is the OWNER preview '
             + 'inside /owncast/stream (owncast-stream-video / owncast-stream-player), so '
             + 'watching needs the same un-seeded ROLE_OWNCAST persona AND a live HLS '
             + 'origin. There is no viewer-facing watch surface in the console at all.',
    note: 'Recorded as a function so the absence of a VIEWER surface is counted, not '
        + 'quietly folded into publish.',
  },
  {
    service: 'owncast', id: 'grant', name: 'grant, time out, ban or restore a broadcaster',
    gateway: 'hugmesh-fe-gateway', pattern: '/bff/owncast/admin/**', gateRole: 'ROLE_ADMIN',
    driveability: 'ui', blockedBy: '',
    note: 'The one surface in this domain with its OWN ROLE_ADMIN row rather than relying '
        + 'on the admin-bypass. owncast-grants-user / -action-* / -ttl / -reason / -submit.',
  },
  {
    service: 'owncast', id: 'grant-audit', name: 'read the active grants and a principal history',
    gateway: 'hugmesh-fe-gateway', pattern: '/bff/owncast/**', gateRole: 'ROLE_OWNCAST',
    driveability: 'ui', blockedBy: '',
    note: 'SUPERADMIN-only panels INSIDE the admin grants console (canManageAll()): '
        + 'owncast-grants-active-panel + owncast-grants-history-panel. An ADMIN sees the '
        + 'action form and NOT these two — the sharpest per-function role boundary in the '
        + 'domain, and one an "is the grants page there" assertion cannot see. The seed '
        + 'gives /bff/owncast/superadmin/** no row of its own; it inherits /bff/owncast/**.',
  },
  {
    service: 'owncast', id: 'moderate', name: 'list, hide, kill or restore other people streams',
    gateway: 'hugmesh-fe-gateway', pattern: '/bff/owncast/**', gateRole: 'ROLE_OWNCAST',
    driveability: 'ui', blockedBy: '',
    note: 'The in-remote owncastModGuard is MOD | ADMIN | SUPERADMIN, but the HOST mount '
        + 'guard is admin | superadmin | ROLE_OWNCAST — so a BARE MOD, the persona this '
        + 'view was built for, never reaches /owncast at all and only admin/superadmin '
        + 'can drive it. owncast-moderation-feed / -hide / -kill / -restore.',
  },

  // ── tube ───────────────────────────────────────────────────────────────────
  {
    service: 'tube', id: 'console', name: 'open the console and land on the personal queue view',
    gateway: 'hugmesh-fe-gateway', pattern: '/tube/**', gateRole: 'ROLE_TUBE',
    driveability: 'ui', blockedBy: '',
    note: "Unlike owncast, tube's default view ('' -> my) is behind tubeReadGuard = "
        + 'canUse() = ROLE_TUBE | admin | superadmin, so a seeded admin renders the '
        + 'whole console. tube-nav-my / tube-nav-access / tube-nav-budgets.',
  },
  {
    service: 'tube', id: 'queue', name: 'enqueue a download and watch the queue drain',
    gateway: 'hugmesh-fe-gateway', pattern: '/bff/tube/**', gateRole: 'ROLE_TUBE',
    driveability: 'no-audience',
    blockedBy: 'no persona in either e2e roster holds ROLE_TUBE. An admin renders '
             + '/tube/my through the admin-bypass, but the queue itself is per-PRINCIPAL '
             + 'tube access: the bff answers access-not-granted and the view shows '
             + 'tube-my-access-denied instead of a queue. Seed e.g. '
             + 'e2e-tube:ROLE_TUBE,ROLE_USER:E2E_TUBE_PASSWORD, then un-pend.',
    note: 'tube-enqueue / tube-queue-empty / tube-job-state-<id>.',
  },
  {
    service: 'tube', id: 'watch', name: 'watch a completed download in-platform',
    gateway: 'hugmesh-be-gateway', pattern: '/tube/content/**', gateRole: 'ROLE_TUBE',
    driveability: 'no-audience',
    blockedBy: 'needs the same un-seeded ROLE_TUBE persona AND a COMPLETED job: playback '
             + 'is an HMAC-signed URL minted by GET /bff/tube/media/sign for a contentPath '
             + 'that only exists once a download finished. Nothing in this suite can make '
             + 'a real download complete.',
    note: 'The media row is the ONE be-gateway surface in the tube function set. '
        + 'tube-watch-<id> / tube-watch-video-<id> / tube-watch-error-<id>.',
  },
  {
    service: 'tube', id: 'subscribe', name: 'connect a Google account and sync subscriptions',
    gateway: 'hugmesh-fe-gateway', pattern: '/bff/tube/**', gateRole: 'ROLE_TUBE',
    driveability: 'absent',
    blockedBy: 'this function leaves the mesh entirely: it is a real Google OAuth consent '
             + 'flow against accounts.google.com plus a YouTube Data API quota. There is '
             + 'no seeded credential and no stub, and driving a third-party consent screen '
             + 'from Playwright would be asserting Google, not hugmesh. Seeding a '
             + 'ROLE_TUBE persona does NOT unblock it.',
    note: 'tube-google-connect / tube-google-sync / tube-google-degraded. Catalogued so '
        + 'the un-drivable third-party leg is COUNTED rather than silently omitted.',
  },
  {
    service: 'tube', id: 'access', name: 'grant, time out, ban or restore a member tube access',
    gateway: 'hugmesh-fe-gateway', pattern: '/bff/tube/**', gateRole: 'ROLE_TUBE',
    driveability: 'ui', blockedBy: '',
    note: 'TUBE_MANAGE = admin | superadmin at the in-remote guard. NOTE the asymmetry '
        + 'with owncast: owncast has a dedicated /bff/owncast/admin/** -> ROLE_ADMIN seed '
        + 'row, tube has NO /bff/tube/admin/** row and rides the gateway admin-bypass '
        + 'instead. Both work; only one is legible from the seed. tube-access-user / '
        + '-action-* / -submit.',
  },
  {
    service: 'tube', id: 'budgets', name: 'set a per-user storage budget',
    gateway: 'hugmesh-fe-gateway', pattern: '/bff/tube/**', gateRole: 'ROLE_TUBE',
    driveability: 'ui', blockedBy: '',
    note: 'Shares tubeManageGuard with access — asserted separately anyway, because '
        + 'sharing a guard is exactly why a regression would drop BOTH and a single '
        + 'assertion would still be green on the other. tube-budget-user / -gb / -submit.',
  },

  // ── games ──────────────────────────────────────────────────────────────────
  {
    service: 'games', id: 'entry', name: 'reach the games entry point',
    gateway: 'hugmesh-fe-gateway', pattern: '/games/**', gateRole: 'ROLE_GAMES',
    driveability: 'ui', blockedBy: '',
    note: 'Since 2026-10-28 the fe gateway proxies /games/** to the `games` federation '
        + 'remote (hugmesh-games/games-ui, fe route games-ui) behind a ROLE_GAMES floor '
        + '(+ROLE_ADMIN/ROLE_MOD supersets) — the host shell mounts its GAMES_ROUTES at '
        + '/games (games-catalog, games-card-<slug>, games-play-frame). Before that the '
        + 'fe side had NO /games/** row and /games was a guarded local placeholder. The '
        + 'be-gateway /games/** trio still governs the standalone PORTAL door.',
  },
  {
    service: 'games', id: 'admin', name: 'reach the derived games-admin mount',
    gateway: 'hugmesh-fe-gateway', pattern: '/games/admin/**', gateRole: 'ROLE_GAMES_ADMIN',
    driveability: 'ui', blockedBy: '',
    note: 'ROLE_GAMES_ADMIN is DERIVED: ROLE_GAMES intersect (ROLE_ADMIN union ROLE_MOD), '
        + 'materialised by derive-games-admin.sh on compose and games-admin-sync on the '
        + 'cluster. A bare ROLE_GAMES and a bare ROLE_ADMIN each hold one half and are '
        + 'BOTH refused. The mount is the remote\'s GAMES_ADMIN_ROUTES (games-admin-shell: '
        + 'overview, live sessions, session logs, access, settings) and its API rides the '
        + 'sibling /games/api/admin/** row keyed on the same composite.',
  },
  {
    service: 'games', id: 'catalogue', name: 'list the games offered to my domain',
    gateway: 'hugmesh-be-gateway', pattern: '/bff/games-services/catalog/**',
    gateRole: 'ROLE_GAMES_SERVICES',
    driveability: 'absent',
    blockedBy: 'this is the games APP-STORE control plane (games-services: server '
             + 'instances offered per domain), a DIFFERENT surface from the games member '
             + 'catalog the `games` remote lists from /games/api/games. It has no UI '
             + 'mounted in this mesh and no persona holds ROLE_GAMES_SERVICES. Nothing '
             + 'exists to list an app-store catalogue from.',
    note: 'The route-access row is real and seeded — the gate is ready, the surface is not.',
  },
  {
    service: 'games', id: 'launch', name: 'create, run and stop a game instance',
    gateway: 'hugmesh-be-gateway', pattern: '/bff/games-services/instances/**',
    gateRole: 'ROLE_GAMES_SERVICES_ADMIN',
    driveability: 'absent',
    blockedBy: 'same missing app-store UI as games/catalogue, and ROLE_GAMES_SERVICES_ADMIN '
             + '(games-services intersect (admin|mod)) is held by no seeded persona. The '
             + 'instance lifecycle is a control-plane API with no mounted client here — '
             + 'not to be confused with a games member LAUNCHING a title in the remote '
             + '(POST /games/api/games/<slug>/launch, driven by games-console.feature).',
    note: 'ROLE_GAMES_SERVICES_RUNNER is the mod-delegated run/stop half of the same row.',
  },
  {
    service: 'games', id: 'instance-console', name: 'open a running instance HTTP console',
    gateway: 'hugmesh-be-gateway', pattern: '/games/servers/**', gateRole: 'ROLE_GAMES_SERVICES',
    driveability: 'absent',
    blockedBy: 'there is nothing to open: an instance console only exists once games/launch '
             + 'has started an instance, and games/launch has no mounted client.',
    note: 'Admins and mods are supersets on this row.',
  },
  {
    service: 'games', id: 'operator-ui', name: 'curate the app-store from the operator console',
    gateway: 'hugmesh-fe-gateway', pattern: '/admin/games-services/**',
    gateRole: 'ROLE_GAMES_SERVICES_ADMIN',
    driveability: 'absent',
    blockedBy: 'the admin-ui federated remote at /admin/games-services is not part of the '
             + 'seeded local stack, and no persona holds ROLE_GAMES_SERVICES_ADMIN or '
             + 'ROLE_GAMES_SERVICES_RUNNER.',
    note: 'The one fe-gateway surface of the app-store; the rest is be-gateway.',
  },

  // ── character-studio (2D) ──────────────────────────────────────────────────
  {
    service: 'character-studio', id: 'open', name: 'mount the layered 2D editor',
    gateway: 'hugmesh-fe-gateway', pattern: '/character-studio/**', gateRole: 'ROLE_USER',
    driveability: 'ui', blockedBy: '',
    note: 'registeredGuard in the host shell — any fully registered identity, no '
        + 'per-service role. cs-status / cs-studio-header.',
  },
  {
    service: 'character-studio', id: 'create', name: 'pick parts, recolour and blend a character',
    gateway: 'hugmesh-fe-gateway', pattern: '/character-studio/**', gateRole: 'ROLE_USER',
    driveability: 'ui', blockedBy: '',
    note: 'cs-surprise / cs-slot-<slot> / cs-part-pick-<slot>-<id> / cs-palette-<region> / '
        + 'cs-blend-target-<slot> (the body-type blend axis) / cs-validity.',
  },
  {
    service: 'character-studio', id: 'export', name: 'download the character as a PNG',
    gateway: 'hugmesh-fe-gateway', pattern: '/character-studio/**', gateRole: 'ROLE_USER',
    driveability: 'ui', blockedBy: '',
    note: 'cs-export-download + cs-export-status. Purely client-side rasterisation — the '
        + 'only function in this domain that needs no BFF at all.',
  },
  {
    service: 'character-studio', id: 'save', name: 'set the character as my mesh avatar',
    gateway: 'hugmesh-fe-gateway', pattern: '/bff/user/**', gateRole: 'ROLE_USER',
    driveability: 'ui', blockedBy: '',
    note: 'POST /bff/user/profile/avatar, moderated server-side (the PENDING->ACTIVE '
        + 'character-moderation flip spec 28 already drives from the sticker side). '
        + 'cs-set-avatar / cs-use-everywhere / cs-platform-results, whose per-platform '
        + '"skipped" states a ROLE fact (no ROLE_MATRIX = no avatar to set there), not '
        + 'an error.',
  },

  // ── character-forge (3D) ───────────────────────────────────────────────────
  {
    service: 'character-forge', id: 'open', name: 'mount the 3D forge',
    gateway: 'hugmesh-fe-gateway', pattern: '/character-forge/**', gateRole: 'ROLE_USER',
    driveability: 'ui', blockedBy: '',
    note: 'registeredGuard, same floor as character-studio. cf-header / cf-status.',
  },
  {
    service: 'character-forge', id: 'create', name: 'tune the forge parameters for a character',
    gateway: 'hugmesh-fe-gateway', pattern: '/character-forge/**', gateRole: 'ROLE_USER',
    driveability: 'ui', blockedBy: '',
    note: 'cf-seed / cf-surprise / cf-editor / cf-body-archetype / cf-build / cf-height / '
        + 'cf-family. DOM-level only — the parameter form renders without the 3D engine.',
  },
  {
    service: 'character-forge', id: 'save', name: 'save, list and activate forge characters',
    gateway: 'hugmesh-fe-gateway', pattern: '/bff/character-forge/**', gateRole: 'ROLE_USER',
    driveability: 'ui', blockedBy: '',
    note: 'cf-save-new / cf-save-over / cf-load-active / cf-save-list / cf-active-badge. '
        + 'Ownership is enforced in the BFF (owner = jwt subject; foreign id => 404), '
        + 'which is why the seed mints no per-service role for it.',
  },
  {
    service: 'character-forge', id: 'export', name: 'snapshot the 3D render and use it everywhere',
    gateway: 'hugmesh-fe-gateway', pattern: '/bff/user/**', gateRole: 'ROLE_USER',
    driveability: 'absent',
    blockedBy: 'both cf-snapshot and cf-use-everywhere are aria-disabled until '
             + 'engine.ready(), and the engine is a WebGL/3D bundle. Asserting a '
             + 'headless-Chromium GPU path would be asserting the harness, not the '
             + 'product — the forge itself reports the gap honestly through '
             + 'cf-engine-loading / cf-engine-absent / cf-engine-error. Seeding a persona '
             + 'does NOT unblock it.',
    note: 'The engine-gated half of the forge, catalogued so it is COUNTED as uncovered '
        + 'rather than mistaken for covered by the create/save scenarios beside it.',
  },
];

// ── lookups ──────────────────────────────────────────────────────────────────

const BY_KEY = new Map(FUNCTIONS.map((f) => [`${f.service}/${f.id}`, f]));

/** Every function catalogued for one service, in declaration order. */
export function functionsOf(serviceId: string): MeshFunction[] {
  service(serviceId);   // validate through the SAME throw-naming-the-legal-set path
  return FUNCTIONS.filter((f) => f.service === serviceId);
}

/** Resolve `<service>/<function>`, or throw naming every legal id for that service. */
export function meshFunction(serviceId: string, functionId: string): MeshFunction {
  const found = BY_KEY.get(`${serviceId}/${functionId}`);
  if (!found) {
    const legal = functionsOf(serviceId).map((f) => f.id);
    throw new Error(
      `unknown function '${functionId}' for service '${serviceId}'. Legal function ids `
      + `(steps/function-catalogue.ts FUNCTIONS): ${legal.join(', ') || '<none>'}. Add the `
      + `function to the catalogue — do NOT spell a new one inline in a .feature file, or `
      + `the census guard cannot see it and the coverage it claims is unmeasured.`,
    );
  }
  return found;
}

// ── the roster side: who could actually drive a function ─────────────────────

/**
 * Every role a persona handle holds, across BOTH rosters. Union, not either —
 * specs/rbac-roles.ts and tests/e2e-extra-personas.sh disagree today and
 * dimensions.ts already accepts the union for the identity itself; taking one
 * side here would make a persona's ROLES disagree with its EXISTENCE.
 */
export function personaRoles(handle: string): string[] {
  const out = new Set<string>();
  for (const u of SYSTEMS_SEED_USERS) if (u.username === handle) u.roles.forEach((r) => out.add(r));
  for (const p of shellRoster()) if (p.username === handle) p.roles.forEach((r) => out.add(r));
  return [...out].sort();
}

/**
 * The roster personas that hold at least one of `roles` — the set a route-access
 * allow-row admits ON ITS OWN TERMS.
 *
 * DELIBERATELY NOT MODELLED: the gateway ADMIN-BYPASS. The seed's own comments
 * say admins reach a floor row "via the gateway admin-bypass", which is why
 * /owncast/**, /tube/** and /social/forum/** pair no ROLE_ADMIN. Folding that
 * bypass in here would make this function answer a RUNTIME question it cannot
 * observe offline; instead it answers exactly one question — who does the SEED
 * name — and the driven scenarios answer the other. Two honest facts beat one
 * blended guess.
 */
export function rosterPersonasHolding(roles: readonly string[]): string[] {
  const want = new Set(roles);
  return knownPersonas().filter((h) => personaRoles(h).some((r) => want.has(r))).sort();
}

/** Render a persona set the way a feature file spells it. */
export function renderPersonas(handles: readonly string[]): string {
  return [...handles].sort().join(', ');
}

/** Parse the way a feature file spells a persona set. */
export function parsePersonas(text: string): string[] {
  return text.split(',').map((s) => s.trim()).filter(Boolean).sort();
}
