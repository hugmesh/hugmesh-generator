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
  /**
   * WHICH MESH — docker | kind | qemu. Undefined means the feature never
   * declared one; {@link envOf} then supplies DEFAULT_ENVIRONMENT ('docker').
   *
   * Deliberately NOT defaulted here. The Before hook availability-gates only
   * the scenarios that EXPLICITLY opted in with an `@env:` tag, so the 453
   * pre-existing scenarios keep failing loudly against a dead stack instead of
   * quietly becoming skips — which would convert 130 real failures into 130
   * green-looking non-runs.
   */
  env?: Environment;
  /** HOW it is driven — browser | cli | studio. Undefined means browser. */
  interface?: InterfaceId;
}

const AXES = ['role', 'platform', 'service', 'layer', 'env', 'interface'] as const;

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
  // env / interface validate through the SAME throw-naming-the-legal-set path as
  // every other axis. An unknown value dies here, in the `dimensions` fixture,
  // before a browser action or a subprocess runs — never degrading into a run
  // against a mesh nobody started or an interface nothing can drive.
  if (merged.env !== undefined) environment(merged.env);
  if (merged.interface !== undefined) interfaceDef(merged.interface);
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

// ── ENVIRONMENT ──────────────────────────────────────────────────────────────
// The operator's requirement is evidence "in docker, local devops, and qemu
// emulated e2e testing". Those are three DIFFERENT meshes reached at three
// different doors, so the door is an axis exactly like platform and service is.
//
// WHY EACH ENVIRONMENT NEEDS A PROBE, MEASURED NOT ASSUMED. On this box, right
// now, `ss -ltn` shows 0.0.0.0:8443 LISTEN and a TCP connect to it SUCCEEDS —
// but `curl https://127.0.0.1:8443/` returns "Send failure: Broken pipe" and
// `docker ps` shows the port is held by `hugmesh-local-control-plane`, the KIND
// node container, whose cluster carries ArgoCD and kube-system and NO
// ingress-nginx and NO hugmesh apps. So:
//
//   * a TCP-connect probe reports the mesh UP when nothing serves it, because
//     docker's port proxy binds the port whether or not anything is behind it;
//   * a `kubectl get nodes` probe ALSO reports UP — the node is Ready;
//   * only an HTTP request tells the truth.
//
// Therefore every probe here issues a real HTTP request and requires a real
// status line back. ANY status counts as "the door answers" — 401/403/404 all
// mean something is serving — while refused/reset/timeout/EPIPE mean it is not.
//
// PORT COLLISION, DELIBERATELY SURFACED. kind-local.yaml maps 443 -> host 8443,
// and the compose stack publishes `${PUBLIC_HTTPS_PORT:-8488}:8443` — 8443 is
// the port INSIDE its tls-front container; its HOST door is PUBLIC_HTTPS_PORT
// (Makefile default 8488), so by default `@env:docker` and `@env:kind` sit side
// by side. The doors coincide as soon as an operator sets PUBLIC_HTTPS_PORT=8443
// (or something else holds the door): then only one of them can hold the port,
// and a probe that merely saw "something answers" would attribute the KIND
// ingress to the compose stack. portOwner() below reads `docker ps` (read-only)
// so the SKIP REASON can name which container actually holds the door.
//
// *** NO PROBE STARTS ANYTHING. *** Every probe is a read: an HTTP GET, a
// `docker ps`, a `kubectl config get-contexts`. Bringing an environment up is
// the operator's action and is named in startHint, never taken here.

import * as https from 'node:https';
import * as http from 'node:http';
import { execFileSync } from 'node:child_process';

/** The three meshes a scenario may be driven against. */
export const ENVIRONMENTS = ['docker', 'kind', 'qemu'] as const;
export type Environment = (typeof ENVIRONMENTS)[number];

/**
 * What an UNTAGGED scenario runs in. This is exactly today's behaviour — the
 * compose stack at playwright.config.ts's baseURL — and changing it would
 * silently re-point all 453 pre-existing scenarios at a different mesh.
 */
export const DEFAULT_ENVIRONMENT: Environment = 'docker';

export interface EnvironmentDef {
  /** Canonical id — the exact spelling an `@env:` tag / Examples cell uses. */
  id: Environment;
  name: string;
  /**
   * The URL a BROWSER drives. Resolved fresh on every call so a test-time env
   * var change is honoured; never cached into a module constant.
   */
  baseUrl(): string;
  /**
   * Where the AVAILABILITY PROBE actually connects, plus the Host header it
   * must send. These differ from baseUrl() for kind: `hugmesh.net` does NOT
   * resolve on this box (verified: `getent hosts hugmesh.net` returns nothing —
   * that is precisely why `make kind-e2e` passes chromium host-resolver-rules
   * instead of editing /etc/hosts), so probing baseUrl() would fail on DNS and
   * report "kind is down" even when the ingress is serving perfectly.
   */
  probeTarget(): { url: string; hostHeader?: string };
  /** EXACTLY what the operator must run to bring this up. Quoted in skip reasons. */
  startHint: string;
  note: string;
}

/** Strip a trailing slash so baseUrl + path never doubles it. */
function trimSlash(u: string): string { return u.replace(/\/+$/, ''); }

export const ENVIRONMENT_DEFS: Record<Environment, EnvironmentDef> = {
  docker: {
    id: 'docker',
    name: 'local docker compose stack (tests/stack)',
    // SNAP_BASE_URL is honoured FIRST and unchanged: it is what
    // playwright.config.ts already reads, what tests/e2e/run.sh sets and what
    // run-qemu-e2e.sh exports. Keeping docker bound to it is what makes the
    // 453 pre-existing scenarios behave identically.
    // THE FALLBACK PORT IS 8488, NOT 8443, and that is not a detail. compose.local.yaml
    // publishes `${PUBLIC_HTTPS_PORT:-8488}:8443` — 8443 is the port INSIDE the
    // container; the host door is 8488 (Makefile: PUBLIC_HTTPS_PORT ?= 8488, and
    // `make stack-e2e` exports SNAP_BASE_URL='https://localhost:$(PUBLIC_HTTPS_PORT)').
    //
    // So a run that sets SNAP_BASE_URL — every run through the Makefile — was always
    // right, and only the bare fallback was wrong. But the bare fallback is exactly
    // what this suite's own lanes use, and on this host :8443 is published by the KIND
    // node. Docker's probe therefore knocked on the kind ingress, got a 404, and
    // called the compose stack available. Fixing the owner check (below) makes that
    // SKIP correctly; fixing the port makes it ask the right door in the first place.
    baseUrl: () => trimSlash(
      process.env.SNAP_ENV_DOCKER_BASE_URL || process.env.SNAP_BASE_URL
        || `https://localhost:${process.env.PUBLIC_HTTPS_PORT || '8488'}`,
    ),
    probeTarget: () => ({ url: `${ENVIRONMENT_DEFS.docker.baseUrl()}/` }),
    startHint: 'make stack-up ENV=test   (then: make stack-seed)',
    note: 'The default. Same door playwright.config.ts already points at.',
  },
  kind: {
    id: 'kind',
    name: 'local devops kind cluster (kind-hugmesh-local)',
    // Both values are READ OFF the repo, not invented: the Makefile's kind-e2e
    // target sets SNAP_BASE_URL='https://hugmesh.net:8443', and
    // specs/cluster/bootstrap/kind-local/kind-local.yaml maps containerPort 443
    // -> hostPort 8443 on the node container.
    baseUrl: () => trimSlash(process.env.SNAP_ENV_KIND_BASE_URL || 'https://hugmesh.net:8443'),
    // Probe the PORT MAP directly with the Ingress's Host header — the
    // fe-gateway Ingress matches on Host, so a bare IP request would not route.
    probeTarget: () => ({
      url: process.env.SNAP_ENV_KIND_PROBE_URL || 'https://127.0.0.1:8443/',
      hostHeader: process.env.SNAP_ENV_KIND_HOST || 'hugmesh.net',
    }),
    startHint: 'make kind-images && make kind-up   (bootstrap-kind.sh, KIND_PROFILE=sso)',
    note: 'kubectl context kind-hugmesh-local. NOTE the node container binds :8443 '
        + 'as soon as the cluster exists, long before any app serves it.',
  },
  qemu: {
    id: 'qemu',
    name: 'QEMU-emulated device (tests/qemu/run-qemu-e2e.sh)',
    // run-qemu-e2e.sh: UI_PORT="${UI_PORT:-8443}" and it runs the specs with
    // SNAP_BASE_URL="https://localhost:${UI_PORT}". The launchers forward the
    // guest UI's HTTPS port to that host port. Reading UI_PORT here is what
    // makes a `--ui-port 9443` run resolve correctly instead of silently
    // driving whatever else holds 8443.
    baseUrl: () => trimSlash(
      process.env.SNAP_ENV_QEMU_BASE_URL
      || `https://localhost:${process.env.SNAP_QEMU_UI_PORT || process.env.UI_PORT || '8443'}`,
    ),
    probeTarget: () => ({ url: `${ENVIRONMENT_DEFS.qemu.baseUrl()}/` }),
    startHint: 'bash tests/qemu/run-qemu-e2e.sh --target x86 --img <image>   '
             + '(or --target pi); the forwarded UI port is --ui-port, default 8443',
    note: 'The guest UI is reached over the launcher\'s forwarded host port, '
        + 'NOT over the guest address.',
  },
};

export function isEnvironment(v: string): v is Environment {
  return (ENVIRONMENTS as readonly string[]).includes(v);
}

/** Resolve an `@env:` value, or throw naming every legal id. */
export function environment(id: string): EnvironmentDef {
  if (!isEnvironment(id)) {
    throw new Error(
      `unknown @env:${id}. Legal environments (steps/dimensions.ts ENVIRONMENTS): `
      + `${ENVIRONMENTS.join(', ')}. Add the environment to ENVIRONMENT_DEFS — do NOT `
      + `spell a new one inline in a .feature file, and do NOT reuse a near-twin `
      + `('compose', 'k8s', 'vm') which fragments the vocabulary.`,
    );
  }
  return ENVIRONMENT_DEFS[id];
}

/** The base URL a scenario in this environment drives. */
export function environmentBaseUrl(id: string): string {
  return environment(id).baseUrl();
}

/**
 * The EFFECTIVE environment of a scenario: what it declared, or the default.
 * Kept separate from `Dimensions.env` on purpose — `resolveDimensions` records
 * only what a feature ACTUALLY declared, so `requireDimension(d,'env')` can
 * still fail loudly for a step that needs an explicit one, and the Before hook's
 * annotations stay honest about which axes the author really varied.
 */
export function envOf(d: Dimensions): Environment {
  return d.env ?? DEFAULT_ENVIRONMENT;
}

// ── INTERFACE ────────────────────────────────────────────────────────────────
// The second half of the ask: coverage "through cli and gui". A mesh function
// driven from a browser, from a terminal and from the Studio wizard is three
// different code paths with three different failure modes, and evidence for
// each looks different — a PNG, a transcript, a widget grab.

export const INTERFACES = ['browser', 'cli', 'studio'] as const;
export type InterfaceId = (typeof INTERFACES)[number];

/** What an UNTAGGED scenario drives — today's Playwright page driving, exactly. */
export const DEFAULT_INTERFACE: InterfaceId = 'browser';

export interface InterfaceDef {
  id: InterfaceId;
  name: string;
  /**
   * The artefact kind a step on this interface produces as its RECORD OF
   * TRUTH. A terminal has no screenshot; its transcript is the evidence, and
   * any picture of it is a convenience rendering of that transcript.
   */
  primaryEvidence: 'screenshot' | 'transcript' | 'widget-grab';
  note: string;
}

export const INTERFACE_DEFS: Record<InterfaceId, InterfaceDef> = {
  browser: {
    id: 'browser', name: 'Playwright-driven browser', primaryEvidence: 'screenshot',
    note: 'Today\'s driving. Evidence is the per-step PNG world.ts already writes.',
  },
  cli: {
    id: 'cli', name: 'command line (mesh CLI / make targets / Studio --print-command)',
    primaryEvidence: 'transcript',
    note: 'Evidence of record is the TRANSCRIPT (argv, stdout, stderr, exit code, '
        + 'duration). A PNG rendering is written too when it is free, but the '
        + 'transcript is what an assertion is made against.',
  },
  studio: {
    id: 'studio', name: 'HugMesh Studio PyQt wizard, headless (QT_QPA_PLATFORM=offscreen)',
    primaryEvidence: 'widget-grab',
    note: 'Driven by tests/e2e/studio-driver.py, which builds the REAL '
        + 'hugmesh_studio.gui.wizard.StudioWizard offscreen and QWidget.grab()s it.',
  },
};

export function isInterface(v: string): v is InterfaceId {
  return (INTERFACES as readonly string[]).includes(v);
}

/** Resolve an `@interface:` value, or throw naming every legal id. */
export function interfaceDef(id: string): InterfaceDef {
  if (!isInterface(id)) {
    throw new Error(
      `unknown @interface:${id}. Legal interfaces (steps/dimensions.ts INTERFACES): `
      + `${INTERFACES.join(', ')}. Add it to INTERFACE_DEFS — a new interface needs an `
      + `evidence path in steps/evidence.ts too, or its steps would run producing no `
      + `artefact at all, which is the exact decoration this suite forbids.`,
    );
  }
  return INTERFACE_DEFS[id];
}

/** The EFFECTIVE interface of a scenario: what it declared, or the default. */
export function interfaceOf(d: Dimensions): InterfaceId {
  return d.interface ?? DEFAULT_INTERFACE;
}

// ── availability probes ──────────────────────────────────────────────────────

/**
 * The answer to "can this scenario actually run here?". `reason` is populated
 * ALWAYS — including when available, where it records HOW that was established.
 * A skip whose reason is empty is a silent skip wearing a coat.
 */
export interface Availability {
  available: boolean;
  /** One line, safe to put straight into testInfo.skip(). */
  reason: string;
  /** Free-form measurement detail (status code, errno, stderr tail). */
  detail: string;
}

const PROBE_TIMEOUT_MS = Number(process.env.SNAP_ENV_PROBE_TIMEOUT_MS || '3000');

/**
 * One HTTP request, TLS verification off (every one of these doors serves a
 * self-signed or cluster-default certificate). Resolves to the status code, or
 * rejects with the transport error. Deliberately does NOT follow redirects: a
 * 301/302 is still proof the door answers.
 */
function probeRequest(url: string, hostHeader?: string): Promise<number> {
  return new Promise((resolve, reject) => {
    let mod: typeof https | typeof http;
    try {
      mod = new URL(url).protocol === 'http:' ? http : https;
    } catch (e) {
      reject(new Error(`unparseable probe URL '${url}': ${(e as Error).message}`));
      return;
    }
    const req = mod.request(
      url,
      {
        method: 'GET',
        timeout: PROBE_TIMEOUT_MS,
        rejectUnauthorized: false,
        headers: hostHeader ? { Host: hostHeader } : {},
        // Node keeps the socket in the agent pool otherwise and the process
        // hangs past the last test.
        agent: false,
      },
      (res) => {
        res.resume();               // drain; we only need the status line
        resolve(res.statusCode ?? 0);
      },
    );
    req.on('timeout', () => {
      req.destroy(new Error(`no response within ${PROBE_TIMEOUT_MS}ms`));
    });
    req.on('error', reject);
    req.end();
  });
}

/**
 * Which container publishes a host port, or undefined when docker cannot say.
 * READ-ONLY (`docker ps`), and every failure mode — no docker, docker down,
 * permission denied — degrades to undefined rather than throwing, because this
 * only ever sharpens a message.
 */
function portOwner(port: string): string | undefined {
  try {
    const out = execFileSync(
      'docker', ['ps', '--format', '{{.Names}}\t{{.Ports}}'],
      { encoding: 'utf8', timeout: 5000, stdio: ['ignore', 'pipe', 'ignore'] },
    );
    for (const line of out.split('\n')) {
      const [name, ports] = line.split('\t');
      if (name && ports && ports.includes(`:${port}->`)) return name;
    }
  } catch { /* docker absent or unhappy: no extra detail to add */ }
  return undefined;
}

/**
 * Is a QEMU system emulator running at all? READ-ONLY (`pgrep`), and any failure
 * degrades to `undefined` = "cannot tell", never to a false negative.
 *
 * WHY THIS IS NEEDED, and it is not paranoia. Two environments default to host
 * port 8443 — kind-local.yaml maps 443->8443 onto it, and run-qemu-e2e.sh
 * forwards the guest UI to UI_PORT which defaults to 8443 — and the compose
 * stack lands there too whenever an operator sets PUBLIC_HTTPS_PORT=8443 (its
 * default host door is 8488; 8443 is only the port inside its tls-front
 * container). So an HTTP probe of `https://localhost:8443/` cannot, by itself,
 * distinguish "the emulated device is serving" from "the kind node (or a compose
 * stack published there) is serving". Without this check a `@env:qemu` scenario
 * would report AVAILABLE and then silently drive whatever else holds the port
 * while claiming to have tested a device — the exact silent-pass this axis
 * exists to prevent.
 *
 * The launchers exec qemu-system-x86_64 / qemu-system-aarch64 directly on the
 * host (tests/qemu/launch-x86.sh, launch-pi.sh), so a host pgrep sees them.
 *
 * MATCHED BY PROCESS NAME, NOT BY COMMAND LINE. `pgrep -f 'qemu-system-'` also
 * matches any process whose ARGUMENTS merely mention the string — including the
 * shell that invoked it, which is a documented trap in this repo and was
 * measured here: `pgrep -af 'qemu-system-'` returned one match on a host with no
 * emulator running at all, that match being its own invoking shell. A
 * false-positive here is the worst possible outcome, because it re-opens exactly
 * the silent-pass this function exists to close. Name-anchored `^qemu-system-`
 * matches comm (truncated to 15 chars: 'qemu-system-x86', 'qemu-system-aar')
 * and nothing else.
 */
function qemuRunning(): boolean | undefined {
  try {
    const out = execFileSync(
      'pgrep', ['^qemu-system-'],
      { encoding: 'utf8', timeout: 5000, stdio: ['ignore', 'pipe', 'ignore'] },
    );
    return out.split('\n').some((l) => l.trim() !== '');
  } catch (e) {
    // pgrep exits 1 when nothing matched — that is a real, decisive "no".
    // Anything else (pgrep absent) is "cannot tell".
    const status = (e as { status?: number }).status;
    if (status === 1) return false;
    return undefined;
  }
}

/** True when kubectl lists the context — i.e. the cluster was ever created. */
function kubeContextExists(ctx: string): boolean {
  try {
    const out = execFileSync(
      'kubectl', ['config', 'get-contexts', '-o', 'name'],
      { encoding: 'utf8', timeout: 5000, stdio: ['ignore', 'pipe', 'ignore'] },
    );
    return out.split('\n').map((s) => s.trim()).includes(ctx);
  } catch { return false; }
}

const envProbeCache = new Map<Environment, Promise<Availability>>();

/**
 * Is this environment serving? Cached per process — a probe per Gherkin step
 * would add seconds to every run and tell us nothing new.
 *
 * Pass force=true only from the guard suite, which must probe a mutated world.
 */
export function environmentAvailability(id: string, force = false): Promise<Availability> {
  const def = environment(id);
  const cached = envProbeCache.get(def.id);
  if (cached && !force) return cached;
  const p = probeEnvironment(def);
  if (!force) envProbeCache.set(def.id, p);
  return p;
}

/** Clear the probe cache. For the guard suite; never call this from a step. */
export function resetEnvironmentProbeCache(): void { envProbeCache.clear(); }

async function probeEnvironment(def: EnvironmentDef): Promise<Availability> {
  const { url, hostHeader } = def.probeTarget();
  const port = (() => { try { return new URL(url).port || '443'; } catch { return ''; } })();

  // kind gets an extra, CHEAPER negative: no context at all means the cluster
  // was never created, which is a different sentence from "created but serving
  // nothing" and points the operator at a different command.
  if (def.id === 'kind' && !kubeContextExists('kind-hugmesh-local')) {
    return {
      available: false,
      reason: `needs the local devops cluster: kubectl has no context `
            + `'kind-hugmesh-local', so the cluster does not exist. Start it with: ${def.startHint}`,
      detail: 'kubectl config get-contexts -o name did not list kind-hugmesh-local',
    };
  }

  // qemu gets the same kind of decisive negative: no emulator process means the
  // device is not running, whatever happens to answer on the shared port.
  if (def.id === 'qemu' && qemuRunning() === false) {
    return {
      available: false,
      reason: `needs an emulated device: no qemu-system-* process is running on this `
            + `host, so nothing answering on ${url} is the device (that port is shared `
            + `with the compose stack and the kind node). Start one with: ${def.startHint}`,
      detail: 'pgrep \'^qemu-system-\' matched no process',
    };
  }

  try {
    const status = await probeRequest(url, hostHeader);
    const owner = portOwner(port);
    // THE COLLISION APPLIES ON THE SUCCESS PATH TOO, and this is where it was
    // missing. A status line only proves SOMETHING is serving the port — the
    // paragraph at the top of this file says exactly that, and then the failure
    // branch below consults portOwner() while this branch merely PRINTED it into
    // `detail`. So with the kind node holding :8443 and answering 404, docker was
    // reported AVAILABLE by a probe whose own detail said
    // `portOwner=hugmesh-local-control-plane`.
    //
    // The consequence is not a wrong label: an @env:docker scenario then RAN
    // against the kind ingress and PASSED, instead of skipping with a reason. A
    // green scenario that never touched the environment it names is worse than a
    // red one.
    //
    // This is the same defect this suite's own mutation M6 pins for qemu
    // ("accepts any server on the shared port as a device"). qemu was guarded by
    // its pgrep gate above; docker had nothing equivalent.
    if (owner && def.id !== 'kind' && /control-plane/.test(owner)) {
      return {
        available: false,
        reason: `needs the ${def.name}, but host port :${port} is published by the `
              + `container '${owner}' (the kind node), not by ${def.name}. Something `
              + `answered HTTP ${status} at ${url} and it was NOT this environment — `
              + `the two share this port and only one can hold it. `
              + `Start it with: ${def.startHint}`,
        detail: `status=${status} probe=${url}`
              + (hostHeader ? ` host=${hostHeader}` : '')
              + ` portOwner=${owner} verdict=foreign-owner`,
      };
    }
    return {
      available: true,
      reason: `${def.name} answered HTTP ${status} at ${url}`,
      detail: `status=${status} probe=${url}`
            + (hostHeader ? ` host=${hostHeader}` : '')
            + (owner ? ` portOwner=${owner}` : ''),
    };
  } catch (e) {
    const msg = (e as Error).message;
    const owner = portOwner(port);
    // The collision case, spelled out. Something holds the port and it is not
    // this environment — reporting a bare "connection failed" here is how an
    // operator spends an hour restarting the wrong thing.
    let collision = '';
    if (owner && def.id !== 'kind' && /control-plane/.test(owner)) {
      collision = ` NOTE: host port :${port} is currently published by the container `
                + `'${owner}' (the kind node), not by the compose stack — the two `
                + `environments share this port and only one can hold it.`;
    }
    return {
      available: false,
      reason: `needs the ${def.name}: nothing answered HTTP at ${url} (${msg}).`
            + `${collision} Start it with: ${def.startHint}`,
      detail: `probe=${url}${hostHeader ? ` host=${hostHeader}` : ''} error=${msg}`
            + (owner ? ` portOwner=${owner}` : ' portOwner=<none/unknown>'),
    };
  }
}

const ifaceProbeCache = new Map<InterfaceId, Promise<Availability>>();

/** Can this interface be driven on this host at all? Cached per process. */
export function interfaceAvailability(id: string, force = false): Promise<Availability> {
  const def = interfaceDef(id);
  const cached = ifaceProbeCache.get(def.id);
  if (cached && !force) return cached;
  const p = probeInterface(def);
  if (!force) ifaceProbeCache.set(def.id, p);
  return p;
}

/** Clear the interface probe cache. For the guard suite only. */
export function resetInterfaceProbeCache(): void { ifaceProbeCache.clear(); }

/** The python the Studio interface drives. Overridable for a venv. */
export function studioPython(): string {
  return process.env.SNAP_STUDIO_PYTHON || 'python3';
}

/** Absolute path of the offscreen Studio driver. */
export function studioDriverPath(): string {
  return path.resolve(__dirname, '..', 'studio-driver.py');
}

async function probeInterface(def: InterfaceDef): Promise<Availability> {
  if (def.id === 'browser') {
    // Playwright resolved the browser before any hook ran; if it had not, there
    // would be no test to skip.
    return { available: true, reason: 'browser is driven by Playwright itself', detail: 'always' };
  }
  if (def.id === 'cli') {
    // The CLI interface shells out; bash is the floor.
    try {
      execFileSync('bash', ['-c', 'exit 0'], { timeout: 5000, stdio: 'ignore' });
      return { available: true, reason: 'bash is on PATH', detail: 'bash -c "exit 0" returned 0' };
    } catch (e) {
      return {
        available: false,
        reason: 'needs a shell for the cli interface: bash is not runnable on this host',
        detail: (e as Error).message,
      };
    }
  }
  // studio: python3 plus a Qt6 binding, checked by RUNNING the real driver's
  // self-check rather than by guessing at import names — the Studio's own
  // gui/qt.py accepts PySide6 OR PyQt6, and hard-coding one of them here would
  // report "no Qt" on a host that has the other.
  const driver = studioDriverPath();
  if (!fs.existsSync(driver)) {
    return {
      available: false,
      reason: `needs the offscreen Studio driver, which is missing: ${driver}`,
      detail: 'file does not exist',
    };
  }
  try {
    const out = execFileSync(
      studioPython(), [driver, '--self-check'],
      {
        encoding: 'utf8', timeout: 60_000, stdio: ['ignore', 'pipe', 'pipe'],
        env: { ...process.env, QT_QPA_PLATFORM: 'offscreen' },
      },
    );
    return {
      available: true,
      reason: `Studio driver self-check passed (${out.trim().slice(0, 200)})`,
      detail: out.trim().slice(0, 500),
    };
  } catch (e) {
    const err = e as { stderr?: string | Buffer; message: string };
    const tail = String(err.stderr ?? '').trim().split('\n').slice(-4).join(' | ');
    return {
      available: false,
      reason: 'needs the Studio GUI toolkit for the studio interface: '
            + `\`${studioPython()} ${driver} --self-check\` failed. Install a Qt6 binding `
            + '(PySide6 or PyQt6) into that interpreter, or point SNAP_STUDIO_PYTHON at '
            + 'one that has it — e.g. `pip install -r studio/requirements.txt`',
      detail: `${err.message} :: ${tail}`,
    };
  }
}
