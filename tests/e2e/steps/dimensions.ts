// dimensions.ts — the ROLE × PLATFORM × SERVICE matrix vocabulary every Gherkin
// feature in tests/e2e/features parameterises over.
//
// WHY THIS FILE EXISTS. The operator's requirement is Gherkin "across roles and
// platforms and services". Three axes, one vocabulary — spelled ONCE here so a
// typo in a feature file is a loud failure instead of a silently-wrong run.
// Every value a feature may name in a `@role:` / `@platform:` / `@service:` tag
// or in a `role` / `platform` / `service` Examples column is resolved through
// this module, and an unknown value THROWS with the list of legal values.
//
// SOURCES OF TRUTH — deliberately NOT re-listed here:
//   * roles/personas  -> specs/rbac-roles.ts SYSTEMS_SEED_USERS (the TS catalogue)
//                        PLUS tests/e2e-extra-personas.sh (the SHELL roster the
//                        compose + kind seeders actually execute). The two
//                        DISAGREE today — the TS catalogue carries 17 personas
//                        the shell roster does not, and the shell roster carries
//                        15 (alice@…, dragoneer, e2e-fleet, e2e-banned, …) the TS
//                        catalogue does not. Reconciling them is real work and is
//                        NOT done here; instead the UNION is accepted and
//                        `personaSource()` says which side a handle came from, so
//                        a feature can never silently drive a persona nothing
//                        seeds. Parsing the shell file rather than copying it is
//                        what stops this from becoming a third divergent list.
//   * platforms       -> the two image targets the generator builds (rpi5 / x86).
//   * services        -> SERVICES below, each carrying the surface a generic
//                        navigation step may drive. A service whose surface is
//                        NOT yet pinned to a verified path is marked
//                        `pinned: false` and navigating to it throws, naming the
//                        author's job. An invented path that 404s quietly is the
//                        thing this prevents.

import * as fs from 'node:fs';
import * as path from 'node:path';
import { SYSTEMS_SEED_USERS } from '../specs/rbac-roles';

// ── PLATFORM ─────────────────────────────────────────────────────────────────
/** The two image/host targets the generator builds and the mesh runs on. */
export const PLATFORMS = ['rpi5', 'x86'] as const;
export type Platform = (typeof PLATFORMS)[number];

export function isPlatform(v: string): v is Platform {
  return (PLATFORMS as readonly string[]).includes(v);
}

// ── SERVICE ──────────────────────────────────────────────────────────────────
/** A service the mesh exposes and a feature may drive. */
export interface ServiceDef {
  /** Canonical id — the exact spelling a `@service:` tag / Examples cell uses. */
  id: string;
  /** Human name for failure messages. */
  name: string;
  /** Browser-reachable UI path behind the gateway, or null when not yet pinned. */
  uiPath: string | null;
  /** BFF/API prefix behind the gateway, or null when not yet pinned. */
  bffPrefix: string | null;
  /**
   * True only when uiPath/bffPrefix were read off a route the repo already
   * drives (a spec, the route-access mirror, or the compose stack). False means
   * "nobody has pinned this yet" — generic navigation refuses rather than
   * guessing a path that would 404 into a green-looking test.
   */
  pinned: boolean;
  /** The Casdoor role that gates ordinary access, or null for the public floor. */
  accessRole: string | null;
  note: string;
}

export const SERVICES: ServiceDef[] = [
  {
    id: 'tuwunel', name: 'Matrix homeserver (tuwunel)',
    uiPath: '/matrix', bffPrefix: '/bff/user/matrix', pinned: true,
    accessRole: 'ROLE_MATRIX',
    note: 'Driven today by specs 05/10/11/31/32 through the matrix remote + hsproxy.',
  },
  {
    id: 'akkoma', name: 'Mastodon-compatible server (akkoma)',
    uiPath: '/mastodon', bffPrefix: '/bff/user/mastodon', pinned: true,
    accessRole: 'ROLE_MASTODON',
    note: 'Driven today by spec 06 through the mastodon remote.',
  },
  {
    id: 'phpbb', name: 'Forum (phpBB)',
    uiPath: '/forum/', bffPrefix: '/bff/forum', pinned: true,
    accessRole: 'ROLE_FORUM',
    note: 'Covered today as a gateway ROUTE CONTRACT only — never as driven UI.',
  },
  {
    id: 'games', name: 'Games platform',
    uiPath: '/games', bffPrefix: '/games/api', pinned: true,
    accessRole: 'ROLE_GAMES',
    note: 'Covered today as a gateway ROUTE CONTRACT only (/games/admin/**).',
  },
  {
    id: 'owncast', name: 'Owncast live streaming',
    uiPath: '/owncast', bffPrefix: '/bff/owncast', pinned: false,
    accessRole: null,
    note: 'ZERO e2e coverage today. /owncast appears in tests/stack/compose.local.yaml '
        + 'but no spec drives it — pin uiPath/bffPrefix against a live stack before '
        + 'writing a navigating step.',
  },
  {
    id: 'tube', name: 'Tube (video)',
    uiPath: '/tube', bffPrefix: '/bff/tube', pinned: false,
    accessRole: null,
    note: 'ZERO e2e coverage today. /tube/content/ + /tube/deployment appear in the '
        + 'compose stack; nothing drives them.',
  },
  {
    id: 'wiki', name: 'Wiki',
    uiPath: '/wiki', bffPrefix: '/bff/wiki', pinned: false,
    accessRole: null,
    note: 'ZERO e2e coverage today.',
  },
  {
    id: 'character-studio', name: 'Character studio (2D editor)',
    uiPath: null, bffPrefix: null, pinned: false,
    accessRole: null,
    note: 'ZERO e2e coverage today AND no path is pinned anywhere in this repo. '
        + 'Do not guess one — pin it from the served app, then set pinned:true.',
  },
  {
    id: 'character-forge', name: 'Character forge (3D)',
    uiPath: null, bffPrefix: '/bff/character-forge', pinned: true,
    accessRole: 'ROLE_USER',
    note: 'BFF prefix is real (spec 32 POSTs /bff/character-forge/characters). '
        + 'The standalone UI path is NOT pinned — spec 32 reaches the forge through '
        + 'the matrix chat3d join menu, not a route of its own.',
  },
  {
    id: 'gateway', name: 'fe/be/pki gateway route-access',
    uiPath: '/', bffPrefix: '/bff', pinned: true,
    accessRole: null,
    note: 'The route-access decision surface itself (specs 12/14/33, rbac-route-access.ts).',
  },
  {
    id: 'login', name: 'login-ui remote',
    uiPath: '/login', bffPrefix: '/bff/login', pinned: true,
    accessRole: null,
    note: 'The native sign-in front door (specs 01/27/28).',
  },
  {
    id: 'admin', name: 'admin-ui remote',
    uiPath: '/admin', bffPrefix: '/bff/admin', pinned: true,
    accessRole: 'ROLE_ADMIN',
    note: 'Admin console (specs 02/09/13).',
  },
];

const SERVICE_BY_ID = new Map(SERVICES.map((s) => [s.id, s]));

export function isService(v: string): boolean {
  return SERVICE_BY_ID.has(v);
}

/** Resolve a `@service:` value, or throw naming every legal id. */
export function service(id: string): ServiceDef {
  const found = SERVICE_BY_ID.get(id);
  if (!found) {
    throw new Error(
      `unknown @service:${id}. Legal service ids (steps/dimensions.ts SERVICES): `
      + `${SERVICES.map((s) => s.id).join(', ')}. Add the service to SERVICES — do NOT `
      + `spell a new one inline in a .feature file.`,
    );
  }
  return found;
}

/** The UI path for a service, or a loud failure when nobody has pinned one. */
export function serviceUiPath(id: string): string {
  const s = service(id);
  if (!s.pinned || !s.uiPath) {
    throw new Error(
      `service '${id}' (${s.name}) has no PINNED UI path, so a navigating step cannot `
      + `drive it. ${s.note} Pin ServiceDef.uiPath in steps/dimensions.ts against a live `
      + `stack and set pinned:true — never guess a path here, a 404 renders as an empty `
      + `page and the assertion that follows is what goes green.`,
    );
  }
  return s.uiPath;
}

// ── ROLE / PERSONA ───────────────────────────────────────────────────────────
/**
 * The shell roster the seeders actually execute. Parsed out of
 * tests/e2e-extra-personas.sh rather than copied, because a copy is how this
 * repo grew three divergent persona lists in the first place (see
 * tests/scripts/test-e2e-persona-catalogue.sh).
 *
 * Grammar (seed-e2e.sh): `handle:ROLE_A,ROLE_B:PASSWORD_ENV`, space separated,
 * line continuations, `${SUPERADMIN_PERSONA}` for the one non-fixed handle.
 */
export interface ShellPersona {
  username: string;
  roles: string[];
  passwordEnv: string;
}

const EXTRA_PERSONAS_SH = path.resolve(__dirname, '..', '..', 'e2e-extra-personas.sh');

let shellRosterCache: ShellPersona[] | undefined;

export function shellRoster(): ShellPersona[] {
  if (shellRosterCache) return shellRosterCache;
  let text: string;
  try {
    text = fs.readFileSync(EXTRA_PERSONAS_SH, 'utf8');
  } catch (e) {
    throw new Error(
      `cannot read the shell persona roster at ${EXTRA_PERSONAS_SH}: ${(e as Error).message}. `
      + `This file is the roster the compose AND kind seeders execute; the BDD harness `
      + `resolves @role: handles against it. Refusing to fall back to a hard-coded list — `
      + `a stale copy is exactly the divergence this reads the file to avoid.`,
    );
  }
  const superadmin = process.env.CASDOOR_SUPERADMIN_USERNAME || 'e2e-superadmin';
  const out: ShellPersona[] = [];
  const re = /(\$\{SUPERADMIN_PERSONA\}|[A-Za-z0-9@._-]+):((?:ROLE_[A-Z0-9_]+)(?:,ROLE_[A-Z0-9_]+)*):([A-Z0-9_]+)/g;
  for (const m of text.matchAll(re)) {
    const username = m[1] === '${SUPERADMIN_PERSONA}' ? superadmin : m[1];
    out.push({ username, roles: m[2].split(','), passwordEnv: m[3] });
  }
  if (out.length === 0) {
    throw new Error(
      `parsed ZERO personas out of ${EXTRA_PERSONAS_SH}. The grammar changed `
      + `(expected handle:ROLE_A,ROLE_B:PASSWORD_ENV) — fix this parser rather than `
      + `letting every @role: tag resolve against an empty roster.`,
    );
  }
  shellRosterCache = out;
  return out;
}

/** Where a `@role:` handle is seeded from. 'both' is the healthy case. */
export type PersonaSource = 'ts-catalogue' | 'shell-roster' | 'both';

export function personaSource(handle: string): PersonaSource | undefined {
  const inTs = SYSTEMS_SEED_USERS.some((u) => u.username === handle);
  const inSh = shellRoster().some((p) => p.username === handle);
  if (inTs && inSh) return 'both';
  if (inTs) return 'ts-catalogue';
  if (inSh) return 'shell-roster';
  return undefined;
}

/** Every persona handle either source seeds, sorted, de-duplicated. */
export function knownPersonas(): string[] {
  const s = new Set<string>();
  for (const u of SYSTEMS_SEED_USERS) s.add(u.username);
  for (const p of shellRoster()) s.add(p.username);
  return [...s].sort();
}

/**
 * Resolve a `@role:` value. Accepts a PERSONA HANDLE ('e2e-admin', 'alice@gmail.com')
 * — never a bare ROLE_* string, because a role is not an identity and cannot be
 * logged in as. Throws with the legal handles on a miss.
 */
export function persona(handle: string): string {
  const src = personaSource(handle);
  if (!src) {
    const known = knownPersonas();
    throw new Error(
      `unknown @role:${handle} — no seeder creates that persona.\n`
      + `  Legal handles (${known.length}, union of specs/rbac-roles.ts SYSTEMS_SEED_USERS `
      + `and tests/e2e-extra-personas.sh):\n    ${known.join('\n    ')}\n`
      + `  NOTE: @role: names a PERSONA HANDLE, not a ROLE_* string. '@role:ROLE_ADMIN' is `
      + `always wrong; '@role:e2e-admin' is the admin persona.`,
    );
  }
  return handle;
}

// ── tag / Examples parsing ───────────────────────────────────────────────────
/**
 * The resolved matrix cell a scenario runs in. Every field is optional: a
 * feature declares only the axes it actually varies, and a step that needs an
 * axis the feature never declared fails loudly via {@link requireDimension}.
 */
export interface Dimensions {
  role?: string;
  platform?: Platform;
  service?: string;
  layer?: string;
}

const AXES = ['role', 'platform', 'service', 'layer'] as const;

/**
 * Pull `@axis:value` out of a string. Used for BOTH sources:
 *   * the Gherkin tags playwright-bdd forwards as Playwright tags ($tags), which
 *     is where a FIXED dimension is declared; and
 *   * the test TITLE, which is where a Scenario Outline's SUBSTITUTED dimension
 *     lands (playwright-bdd fills `<column>` placeholders in the outline name —
 *     see the convention doc in features/README.md).
 * Title wins over tags: it is the more specific, per-example value.
 */
export function parseDimensionText(text: string): Dimensions {
  const out: Dimensions = {};
  for (const axis of AXES) {
    const m = [...text.matchAll(new RegExp(`@${axis}:([A-Za-z0-9@._-]+)`, 'g'))];
    if (m.length) (out as Record<string, string>)[axis] = m[m.length - 1][1];
  }
  return out;
}

/**
 * Resolve + VALIDATE the dimensions of one scenario from its tags and its title.
 * An unknown value on any axis throws here, at Before-hook time, naming the legal
 * set — so a typo in a feature file cannot degrade into a run that quietly drives
 * the wrong persona or a service nobody seeds.
 */
export function resolveDimensions(tags: readonly string[], title: string): Dimensions {
  const fromTags = parseDimensionText(tags.join(' '));
  const fromTitle = parseDimensionText(title);
  const merged: Dimensions = { ...fromTags, ...fromTitle };

  if (merged.role !== undefined) persona(merged.role);
  if (merged.service !== undefined) service(merged.service);
  if (merged.platform !== undefined && !isPlatform(merged.platform)) {
    throw new Error(
      `unknown @platform:${merged.platform}. Legal platforms: ${PLATFORMS.join(', ')}.`,
    );
  }
  return merged;
}

/** Read an axis a step needs, or fail naming the feature-file fix. */
export function requireDimension<K extends keyof Dimensions>(
  d: Dimensions,
  axis: K,
): NonNullable<Dimensions[K]> {
  const v = d[axis];
  if (v === undefined) {
    throw new Error(
      `this step needs the '${axis}' dimension but the scenario never declared it. `
      + `Add a '@${axis}:<value>' tag to the Feature/Scenario, or an Examples column `
      + `named '${axis}' plus the '@${axis}:<${axis}>' suffix on the Scenario Outline `
      + `name (see tests/e2e/features/README.md).`,
    );
  }
  return v as NonNullable<Dimensions[K]>;
}
