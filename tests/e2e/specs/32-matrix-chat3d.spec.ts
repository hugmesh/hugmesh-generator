import { test, expect } from '@playwright/test';
import type { APIRequestContext, Page } from '@playwright/test';
import { onboard, matrixUserId, createRoom, shot, requirePlatformPersonas } from './helpers';
import { tags } from './report-tags';

// ────────────────────────────────────────────────────────────────────────────
// 32 — MATRIX 3D CHAT ROOM (shadows-of-the-net Godot WASM) + CHARACTER
// GENERATION, proven end-to-end on the mock stack:
//
//   A. the exported Godot bundle is DELIVERED intact (all four files 200,
//      index.wasm with the application/wasm MIME that enables streaming
//      instantiation — serve-ui.mjs serves it as a STATIC remote under
//      /_remotes/wasm-fragment/);
//   B. the 3D room BOOTS headless: enable `net.hugmesh.chat3d` room state,
//      enter as a seeded random guest, and the "Loading the 3D room…" banner
//      (chat3d-loading) clears — matrix-ui flips it on the FIRST validated
//      game→host postMessage envelope (ready/localPose), which only the real
//      wasm running inside the iframe can send. The host then publishes my
//      avatar as `net.hugmesh.chat3d.avatar` room state (state_key = my mxid);
//   C. CHARACTER GENERATION → avatar: create + activate a character through
//      the character-forge BFF routes (mock-bff.mjs mirrors the real
//      CharacterForgeController shapes), see the join menu OFFER it by name
//      (not greyed), enter with it, and find the published avatar state
//      carrying the forge character (mode:'forge', its name, its config).
//
// WHO DRIVES THIS: the seed catalogue's non-domain-locked ROLE_MATRIX holders
// (helpers.platformPersonas — see spec 31's header for why the alice@/bob@
// invite handles cannot touch the homeserver backend). B and C use DIFFERENT
// personas so C's active forge character can never bleed into B's join menu.
//
// Every Matrix CS-API call rides the user-bff hsproxy with the RAW-pchar path
// spelling (see pathParam below and the spec-31 encoding note). The homeserver
// is tests/stack/mock-matrix.mjs, which now carries real room-STATE endpoints
// (joined-members-only GET/PUT, the trailing-slash empty-state-key form
// matrix.service uses, and full-state GET with membership rows).
//
// STATE-TYPE GENERATIONS (a DEPLOYED-BUNDLE divergence, measured 2026-08-12):
// matrix-ui main's canonical chat3d types are `net.hugmesh.chat3d` /
// `net.hugmesh.chat3d.avatar` (with the older systems.hugmesh names as
// read-only legacy fallbacks) — but the matrix remote actually BUILT
// into tests/stack/.uidist predates the .net rename: grepping its chunks finds
// ONLY `systems.hugmesh.chat3d*` (3+4+3 hits) and ZERO `net.hugmesh.*`, so the
// deployed join menu reads, and the deployed host publishes, the OLD names.
// This spec therefore (a) writes the enable flag under BOTH generation names
// (identical content — whichever bundle is deployed reads its own), and
// (b) resolves the published avatar through the same newest-first generation
// chain the current source ships (LEGACY_CHAT3D_AVATAR_TYPES), so it stays
// green across a .uidist rebuild without ever faking the boot/publish proof.
//
// The wasm bundle is assembled by tests/stack/up.sh from the sibling
// hugmesh-games repo; when absent, up.sh warns and serves without it, and
// these tests SKIP with that exact pointer instead of failing on a 404 iframe.
// On lanes that do not serve /_remotes/** at all (the compose gateway routes
// /_fragments/** and answers 403 here), they skip with a lane reason instead.
// ────────────────────────────────────────────────────────────────────────────

/** Where serve-ui.mjs exposes the static Godot export (correct wasm MIME). */
const BUNDLE = '/_remotes/wasm-fragment/shadows-of-the-net';

/** The skip reason when the bundle was never assembled — points at the exact
 *  up.sh warn (`WARN: shadows-of-the-net bundle not found at <GAMES_REPO>/…
 *  — 3D-room e2e will skip`) and the documented fix. */
const BUNDLE_SKIP =
  `GET ${BUNDLE}/index.html is 404 — the wasm bundle was not assembled. tests/stack/up.sh `
  + `printed "WARN: shadows-of-the-net bundle not found at <GAMES_REPO>/backend/src/main/`
  + `resources/assets/levels/shadows-of-the-net — 3D-room e2e will skip". Build it in the `
  + `sibling hugmesh-games repo (make build-godot, preset Shadows-Of-The-Net), then re-run `
  + `tests/stack/up.sh (it copies the committed export under .uidist/_remotes/wasm-fragment/).`;

/** The skip reason when the LANE has no /_remotes/** URL space at all:
 *  /_remotes/** is mock-lane serving (tests/stack/serve-ui.mjs + .uidist);
 *  the compose gateway routes /_fragments/** and answers 403 here. Measured
 *  live on the compose lane (:8488): all four assets 403 — a lane mismatch,
 *  not a product defect (spec-08 absent-dependency skip pattern). */
const laneSkip = (status: number): string =>
  `GET ${BUNDLE}/index.html is ${status} (not 404) — this lane does not serve /_remotes/** `
  + `(mock-lane URL space: tests/stack/serve-ui.mjs + .uidist serve it; the compose gateway `
  + `routes /_fragments/** and has no /_remotes/** route, answering 403). Run this spec `
  + `against the rootless mock stack (tests/stack/up.sh, :8443).`;

/**
 * Probe the bundle once and gate the CALLING test: 404 → the up.sh
 * assembled-bundle skip; any other non-200 (403 on the compose lane) → the
 * lane skip. Falls through only when index.html is honestly served.
 */
async function gateOnBundle(request: APIRequestContext): Promise<void> {
  const status = (await request.get(`${BUNDLE}/index.html`)).status();
  test.skip(status === 404, BUNDLE_SKIP);
  test.skip(status !== 200, laneSkip(status));
}

// Mirrors helpers.ts MATRIX_HSPROXY (module-private there): the same-origin
// user-bff hsproxy prefix every CS-API call below is addressed to.
const HS = '/bff/user/matrix';

/**
 * Mirrors helpers.ts `pathParam` (module-private there): percent-encode a path
 * segment, then restore the characters RFC 3986 permits LITERALLY in a segment
 * (pchar — notably ':'), the raw spelling every other room-scoped call in this
 * suite sends. Keep identical to helpers.ts — see spec 31's encoding note for
 * the full live-probed story.
 */
function pathParam(value: string): string {
  return encodeURIComponent(value).replace(
    /%(24|26|2B|2C|3A|3B|3D|40)/gi,
    (m) => decodeURIComponent(m),
  );
}

/**
 * Budget for the Godot wasm to boot inside the iframe and deliver the first
 * game→host envelope. A cold boot measures <20s here; 120s keeps a generous
 * margin for a cold cache/slow CI without letting a truly dead bridge hang the
 * suite (test.setTimeout is widened alongside it in each boot test).
 */
const BOOT_MS = 120_000;

/** The room-state content a moderator writes to switch the 3D room on
 *  (Chat3dStateService shape; stageModOnly false keeps the stage out of the
 *  way — this spec proves boot + avatar, not the stage grant). */
const CHAT3D_ON = {
  enabled: true, style: 'noir', maxParticipants: 8, allowMedia: true, stageModOnly: false,
};

/** The chat3d ENABLE state type's generation chain, newest first — matrix-ui
 *  main's canonical name plus the pre-rename names its Chat3dStateService
 *  falls back to (and which the CURRENTLY BUILT .uidist bundle still treats
 *  as canonical — see the header). */
const CHAT3D_STATE_GENERATIONS = [
  'net.hugmesh.chat3d', 'systems.hugmesh.chat3d',
] as const;

/** The avatar state type's generation chain, newest first (matrix-ui
 *  CHAT3D_AVATAR_TYPE + LEGACY_CHAT3D_AVATAR_TYPES). */
const CHAT3D_AVATAR_GENERATIONS = [
  'net.hugmesh.chat3d.avatar', 'systems.hugmesh.chat3d.avatar',
] as const;

/** Enable the 3D room on `roomId` — the same PUT the room-settings UI issues
 *  (`/rooms/{id}/state/<type>` through the hsproxy, raw room id), written
 *  under BOTH generation names with identical content: whichever matrix-ui
 *  build is deployed reads its own canonical name first, and the two never
 *  disagree because they carry the same content (see the header's
 *  deployed-bundle divergence note). */
async function enableChat3d(page: Page, roomId: string): Promise<void> {
  for (const type of CHAT3D_STATE_GENERATIONS) {
    const r = await page.request.put(
      `${HS}/_matrix/client/v3/rooms/${pathParam(roomId)}/state/${type}`,
      { data: CHAT3D_ON },
    );
    expect(r.ok(), `enable ${type} on ${roomId} (HTTP ${r.status()})`).toBe(true);
  }
}

/** The room's full current state through the hsproxy (array of state events). */
async function roomStateOf(page: Page, roomId: string): Promise<any[]> {
  const r = await page.request.get(
    `${HS}/_matrix/client/v3/rooms/${pathParam(roomId)}/state`,
  );
  expect(r.ok(), `GET room state of ${roomId} (HTTP ${r.status()})`).toBe(true);
  return r.json();
}

/** The published chat3d avatar state event whose state_key is `mxid`, or
 *  undefined — the proof the host actually published my avatar. Resolved
 *  through the NEWEST-FIRST generation chain (exactly how matrix-ui's own
 *  roster read works): the deployed .uidist bundle publishes the
 *  systems.hugmesh generation, a rebuilt one publishes net.hugmesh — either
 *  way it is the same publish-on-enter proof, never a fake pass. */
async function avatarEventOf(page: Page, roomId: string, mxid: string): Promise<any | undefined> {
  const state = await roomStateOf(page, roomId);
  for (const type of CHAT3D_AVATAR_GENERATIONS) {
    const ev = state.find((e) => e.type === type && e.state_key === mxid);
    if (ev) return ev;
  }
  return undefined;
}

/** Drive the join menu's Enter and wait for the wasm boot proof: the host
 *  view renders, and chat3d-loading clears on the first validated game→host
 *  envelope — nothing but the booted Godot bridge can send one. */
async function enterAndAwaitBoot(page: Page, shotName: string): Promise<void> {
  await page.getByTestId('btn-chat3d-enter').click();
  await expect(page.getByTestId('chat3d-host')).toBeVisible();
  await expect(
    page.getByTestId('chat3d-loading'),
    'the wasm boots and the bridge delivers a game→host envelope (ready/localPose)',
  ).toBeHidden({ timeout: BOOT_MS });
  await shot(page, shotName);
}

test(`wasm bundle delivery: shadows-of-the-net html/js/wasm/pck all 200, index.wasm served as application/wasm ${tags({ role: 'ROLE_USER', layer: 'ui' })}`,
  async ({ page }) => {
    await gateOnBundle(page.request);
    for (const f of ['index.html', 'index.js', 'index.wasm', 'index.pck']) {
      const r = await page.request.get(`${BUNDLE}/${f}`);
      expect(r.status(), `${BUNDLE}/${f}`).toBe(200);
      if (f === 'index.wasm') {
        // application/wasm is load-bearing: octet-stream forces Godot onto the
        // slow non-streaming instantiation path (serve-ui.mjs MIME table).
        expect(r.headers()['content-type'],
          'index.wasm content-type (streaming instantiation)').toBe('application/wasm');
      }
    }
  });

test(`3D room boot: enable chat3d, enter as a seeded guest, the wasm boots headless and my avatar is published as room state ${tags({ role: 'ROLE_USER', layer: 'ui' })}`,
  async ({ page }) => {
    await gateOnBundle(page.request);
    test.setTimeout(300_000); // onboarding + a full cold wasm boot (BOOT_MS)

    const [{ username, password }] = requirePlatformPersonas('ROLE_MATRIX', 1);
    await onboard(page, username, password);
    const myId = await matrixUserId(page);

    // A fresh room with the 3D chamber switched ON (the state PUT the
    // room-settings UI issues; the join menu re-reads it itself).
    const roomId = await createRoom(page, [], 'e2e chat3d boot', { preset: 'private_chat' });
    await enableChat3d(page, roomId);

    await page.goto(`/social/matrix/rooms/${encodeURIComponent(roomId)}/chat3d`);
    await expect(page.getByTestId('chat3d-join')).toBeVisible();
    // The guest source needs no backend at all — pick it explicitly (it is
    // also the default when neither forge character nor sticker pack exists).
    await page.getByTestId('input-source-guest').check();
    await shot(page, '32-join-menu-guest');

    await enterAndAwaitBoot(page, '32-3d-room-booted-guest');
    // The host publishes my avatar BEFORE the game becomes ready; a failed
    // publish would have surfaced the avatar-note instead.
    await expect(page.getByTestId('chat3d-avatar-note')).toHaveCount(0);

    // The proof the room now knows me: a net.hugmesh.chat3d.avatar state event
    // keyed by MY mxid (the Matrix auth rule lets me write only my own).
    const ev = await avatarEventOf(page, roomId, myId);
    expect(ev, `net.hugmesh.chat3d.avatar with state_key ${myId} in ${roomId}`).toBeTruthy();
    expect(ev.sender, 'avatar state sender is its owner').toBe(myId);
    expect(ev.content?.v, 'avatar envelope version').toBe(1);
    expect(ev.content?.mode, 'guest join publishes a guest-mode avatar').toBe('guest');
  });

/** The character created in C — an id and hue distinctive enough that finding
 *  them in the published room state can only mean the forge config traveled. */
const FORGE_NAME = 'E2E Forge Dragon';
const FORGE_FUR = '#12ab34';

/** A MINIMAL definition matrix-ui's char3d-config mirror accepts: every
 *  required top-level key present, enums from the shipped lists, no unknown
 *  keys (parseChar3dConfig REJECTS those — an invalid definition would
 *  null-out and grey the forge option, which C asserts against). */
const FORGE_DEFINITION = {
  schemaVersion: 1,
  name: FORGE_NAME,
  body: { archetype: 'dragon', build: 0.5, height: 1 },
  head: { family: 'dragon', variant: '', snoutLength: 0.5, earStyle: null, hornStyle: null },
  parts: {},
  materials: { fur: FORGE_FUR },
  style: 'toon',
};

test(`character generation → avatar: a created+activated forge character is offered by name in the join menu and rides the published avatar state ${tags({ role: 'ROLE_USER', layer: 'ui' })}`,
  async ({ page }) => {
    await gateOnBundle(page.request);
    test.setTimeout(300_000); // onboarding + a full cold wasm boot (BOOT_MS)

    // The SECOND roster persona — B's user must never inherit this character.
    const { username, password } = requirePlatformPersonas('ROLE_MATRIX', 2)[1];
    await onboard(page, username, password);
    const myId = await matrixUserId(page);

    // CHARACTER GENERATION through the character-forge BFF surface (mock-bff
    // mirrors the real CharacterForgeController route + CharacterView shapes):
    // create → 201 {id,…}, activate → active:true, and the exact GET the join
    // menu's CharacterForgeBffService performs answers {name, definition}.
    const created = await page.request.post('/bff/character-forge/characters',
      { data: { name: FORGE_NAME, definition: FORGE_DEFINITION } });
    expect(created.status(), 'POST /bff/character-forge/characters').toBe(201);
    const view = await created.json();
    expect(typeof view.id, 'CharacterView.id (uuid string)').toBe('string');
    expect(view.name).toBe(FORGE_NAME);

    const activated = await page.request.put(`/bff/character-forge/characters/${view.id}/active`);
    expect(activated.status(), `PUT /bff/character-forge/characters/${view.id}/active`).toBe(200);
    expect((await activated.json()).active, 'activation marks the character active').toBe(true);

    const active = await page.request.get('/bff/character-forge/characters/active');
    expect(active.status(), 'GET /bff/character-forge/characters/active').toBe(200);
    const activeView = await active.json();
    expect(activeView.name).toBe(FORGE_NAME);
    expect(activeView.definition, 'active response carries the definition').toBeTruthy();

    // A fresh enabled room, exactly as in the boot test.
    const roomId = await createRoom(page, [], 'e2e chat3d forge', { preset: 'private_chat' });
    await enableChat3d(page, roomId);
    await page.goto(`/social/matrix/rooms/${encodeURIComponent(roomId)}/chat3d`);
    await expect(page.getByTestId('chat3d-join')).toBeVisible();

    // OFFERED, not greyed — and by name. A definition failing matrix-ui's
    // mirror validation would null out and disable this radio instead.
    const forgeRadio = page.getByTestId('input-source-forge');
    await expect(forgeRadio, 'forge option enabled once an active character exists').toBeEnabled();
    await expect(page.getByTestId('chat3d-forge-name')).toContainText(FORGE_NAME);
    await forgeRadio.check();
    await shot(page, '32-join-menu-forge-offered');

    await enterAndAwaitBoot(page, '32-3d-room-booted-forge');

    // The published avatar carries THE forge character: stable fields only
    // (mode/name + the distinctive config values), never deep-equality — the
    // publish path normalizes the config (fills part slots, default materials).
    const ev = await avatarEventOf(page, roomId, myId);
    expect(ev, `net.hugmesh.chat3d.avatar with state_key ${myId} in ${roomId}`).toBeTruthy();
    expect(ev.content?.v).toBe(1);
    expect(ev.content?.mode, 'forge join publishes a forge-mode avatar').toBe('forge');
    expect(ev.content?.name, 'the avatar wears the forge character name').toBe(FORGE_NAME);
    expect(ev.content?.config?.head?.family, 'the forge config head family traveled').toBe('dragon');
    expect(ev.content?.config?.materials?.fur, 'the forge coat colour traveled').toBe(FORGE_FUR);
  });
