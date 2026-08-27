// chat3d.steps.ts — the Matrix 3D chat room (shadows-of-the-net Godot WASM) +
// character-generation step vocabulary. Backs features/matrix/chat3d.feature,
// the executable form of tests/e2e/specs/32-matrix-chat3d.spec.ts.
//
// Three claims, kept separate so a failure names which one broke:
//   A. the exported Godot bundle is DELIVERED intact (four files 200, index.wasm
//      with the application/wasm MIME that enables streaming instantiation);
//   B. the 3D room BOOTS headless and the host publishes my avatar as room state;
//   C. a forge character created through the character-forge BFF is OFFERED by
//      name in the join menu and RIDES the published avatar state.
//
// STATE-TYPE GENERATIONS. matrix-ui main's canonical names are net.hugmesh.chat3d*,
// but the matrix remote actually built into tests/stack/.uidist predates the .net
// rename and reads/writes systems.hugmesh.chat3d*. The enable flag is therefore
// written under BOTH generation names with IDENTICAL content (whichever bundle is
// deployed reads its own), and the published avatar is resolved through the same
// newest-first chain matrix-ui itself ships — so this stays green across a .uidist
// rebuild without ever faking the boot/publish proof. Copied from spec 32, whose
// header carries the full measurement.

import { expect } from '@playwright/test';
import type { Page } from '@playwright/test';
import { Given, When, Then, substep } from './world';
import { service } from './dimensions';
import { createRoom, matrixUserId } from '../specs/helpers';

/** Where tests/stack/serve-ui.mjs exposes the static Godot export. */
const BUNDLE = '/_remotes/wasm-fragment/shadows-of-the-net';

/** Mirrors helpers.ts MATRIX_HSPROXY (module-private there). */
const HS = '/bff/user/matrix';

/** Mirrors helpers.ts `pathParam` — see the note in steps/matrix.steps.ts. */
function pathParam(value: string): string {
  return encodeURIComponent(value).replace(/%(24|26|2B|2C|3A|3B|3D|40)/gi, (m) => decodeURIComponent(m));
}

const BUNDLE_SKIP =
  `GET ${BUNDLE}/index.html is 404 — the wasm bundle was not assembled. tests/stack/up.sh `
  + `printed "WARN: shadows-of-the-net bundle not found at <GAMES_REPO>/backend/src/main/`
  + `resources/assets/levels/shadows-of-the-net — 3D-room e2e will skip". Build it in the `
  + `sibling hugmesh-games repo (make build-godot, preset Shadows-Of-The-Net), then re-run `
  + `tests/stack/up.sh (it copies the committed export under .uidist/_remotes/wasm-fragment/).`;

const laneSkip = (status: number): string =>
  `GET ${BUNDLE}/index.html is ${status} (not 404) — this lane does not serve /_remotes/** `
  + `(mock-lane URL space: tests/stack/serve-ui.mjs + .uidist serve it; the compose gateway `
  + `routes /_fragments/** and has no /_remotes/** route, answering 403). Run this scenario `
  + `against the rootless mock stack (tests/stack/up.sh, :8443).`;

/** The room-state content a moderator writes to switch the 3D room on
 *  (Chat3dStateService shape; stageModOnly false keeps the stage out of the way —
 *  these scenarios prove boot + avatar, not the stage grant). */
const CHAT3D_ON = { enabled: true, style: 'noir', maxParticipants: 8, allowMedia: true, stageModOnly: false };

const CHAT3D_STATE_GENERATIONS = ['net.hugmesh.chat3d', 'systems.hugmesh.chat3d'] as const;
const CHAT3D_AVATAR_GENERATIONS = [
  'net.hugmesh.chat3d.avatar', 'systems.hugmesh.chat3d.avatar', 'systems.snapdragon.chat3d.avatar',
] as const;

/** Budget for the Godot wasm to boot inside the iframe and deliver the first
 *  game->host envelope. A cold boot measures <20s; 120s keeps a margin for a cold
 *  cache without letting a truly dead bridge hang the suite. */
const BOOT_MS = 120_000;

/** The distinctive forge values: finding THESE in the published room state can
 *  only mean the forge config actually travelled. */
const FORGE_FUR = '#12ab34';

/** A MINIMAL definition matrix-ui's char3d-config mirror accepts: every required
 *  top-level key present, enums from the shipped lists, no unknown keys —
 *  parseChar3dConfig REJECTS those, and an invalid definition would null out and
 *  GREY the forge option, which scenario C asserts against. */
const forgeDefinition = (name: string) => ({
  schemaVersion: 1,
  name,
  body: { archetype: 'dragon', build: 0.5, height: 1 },
  head: { family: 'dragon', variant: '', snoutLength: 0.5, earStyle: null, hornStyle: null },
  parts: {},
  materials: { fur: FORGE_FUR },
  style: 'toon',
});

const ROOM = 'chat3d-room-id';
const MXID = 'chat3d-my-mxid';
const FORGE = 'chat3d-forge-name';

async function enableChat3d(page: Page, roomId: string): Promise<void> {
  for (const type of CHAT3D_STATE_GENERATIONS) {
    const r = await page.request.put(
      `${HS}/_matrix/client/v3/rooms/${pathParam(roomId)}/state/${type}`,
      { data: CHAT3D_ON },
    );
    expect(r.ok(), `enable ${type} on ${roomId} (HTTP ${r.status()})`).toBe(true);
  }
}

async function avatarEventOf(page: Page, roomId: string, mxid: string): Promise<any | undefined> {
  const r = await page.request.get(`${HS}/_matrix/client/v3/rooms/${pathParam(roomId)}/state`);
  expect(r.ok(), `GET room state of ${roomId} (HTTP ${r.status()})`).toBe(true);
  const state: any[] = await r.json();
  for (const type of CHAT3D_AVATAR_GENERATIONS) {
    const ev = state.find((e) => e.type === type && e.state_key === mxid);
    if (ev) return ev;
  }
  return undefined;
}

// ── A. bundle delivery ───────────────────────────────────────────────────────

/**
 * Probe the bundle once and gate the scenario. 404 -> the up.sh assembled-bundle
 * skip; any other non-200 (403 on the compose lane) -> the lane skip. Both skips
 * name the exact cause and the exact fix; neither is silent, and neither ever
 * degrades into a pass.
 */
Given('the shadows-of-the-net wasm bundle is served on this lane', async ({ page, $testInfo }) => {
  const status = (await page.request.get(`${BUNDLE}/index.html`)).status();
  $testInfo.skip(status === 404, BUNDLE_SKIP);
  $testInfo.skip(status !== 200, laneSkip(status));
});

Then('the wasm bundle file {string} is served with status {int}',
  async ({ page }, file: string, status: number) => {
    const r = await page.request.get(`${BUNDLE}/${file}`);
    expect(r.status(), `${BUNDLE}/${file}`).toBe(status);
  });

Then('the wasm bundle file {string} is served as {string}',
  async ({ page }, file: string, contentType: string) => {
    const r = await page.request.get(`${BUNDLE}/${file}`);
    // application/wasm is load-bearing: octet-stream forces Godot onto the slow
    // NON-streaming instantiation path (serve-ui.mjs MIME table).
    expect(r.headers()['content-type'], `${file} content-type (streaming instantiation)`)
      .toBe(contentType);
  });

// ── B/C. the 3D room ─────────────────────────────────────────────────────────

Given('I create a fresh Matrix room named {string} with the 3D chamber enabled',
  async ({ page, world, $testInfo }, name: string) => {
    $testInfo.setTimeout(300_000); // onboarding already ran + a full cold wasm boot
    world.set(MXID, await matrixUserId(page));
    const roomId = await createRoom(page, [], name, { preset: 'private_chat' });
    await enableChat3d(page, roomId);
    world.set(ROOM, roomId);
  });

When('I open the 3D room join menu', async ({ page, world }) => {
  await page.goto(`/social/matrix/rooms/${encodeURIComponent(world.get<string>(ROOM))}/chat3d`);
  await expect(page.getByTestId('chat3d-join')).toBeVisible();
});

When('I choose the guest avatar source', async ({ page }) => {
  // The guest source needs no backend at all — chosen explicitly rather than
  // relied on as the default.
  await page.getByTestId('input-source-guest').check();
});

When('I choose the forge avatar source', async ({ page }) => {
  await page.getByTestId('input-source-forge').check();
});

When('I enter the 3D room and wait for the wasm to boot', async ({ page }) => {
  await page.getByTestId('btn-chat3d-enter').click();
  await expect(page.getByTestId('chat3d-host')).toBeVisible();
  // chat3d-loading clears on the FIRST validated game->host envelope
  // (ready/localPose) — nothing but the booted Godot bridge can send one.
  await expect(
    page.getByTestId('chat3d-loading'),
    'the wasm boots and the bridge delivers a game->host envelope',
  ).toBeHidden({ timeout: BOOT_MS });
});

Then('no chat3d avatar publish note is shown', async ({ page }) => {
  // The host publishes my avatar BEFORE the game becomes ready; a FAILED publish
  // surfaces the avatar-note instead.
  await expect(page.getByTestId('chat3d-avatar-note')).toHaveCount(0);
});

Then('my published chat3d avatar state has mode {string}', async ({ page, world }, mode: string) => {
  const mxid = world.get<string>(MXID);
  const roomId = world.get<string>(ROOM);
  const ev = await avatarEventOf(page, roomId, mxid);
  expect(ev, `a chat3d avatar state event with state_key ${mxid} in ${roomId}`).toBeTruthy();
  expect(ev.sender, 'avatar state sender is its owner').toBe(mxid);
  expect(ev.content?.v, 'avatar envelope version').toBe(1);
  expect(ev.content?.mode, `join source '${mode}' publishes a ${mode}-mode avatar`).toBe(mode);
});

Given('I create and activate a forge character named {string}', async ({ page, world }, name: string) => {
  // The character-forge BFF prefix comes from the SERVICE catalogue
  // (steps/dimensions.ts), never spelled inline — spec 32 POSTs the same route.
  const prefix = service('character-forge').bffPrefix;
  expect(prefix, 'character-forge must carry a pinned BFF prefix in steps/dimensions.ts').toBeTruthy();
  let id = '';
  await substep('create the character', async () => {
    const created = await page.request.post(`${prefix}/characters`,
      { data: { name, definition: forgeDefinition(name) } });
    expect(created.status(), `POST ${prefix}/characters`).toBe(201);
    const view = await created.json();
    expect(typeof view.id, 'CharacterView.id is a uuid string').toBe('string');
    expect(view.name).toBe(name);
    id = view.id;
  });
  await substep('activate it', async () => {
    const activated = await page.request.put(`${prefix}/characters/${id}/active`);
    expect(activated.status(), `PUT ${prefix}/characters/${id}/active`).toBe(200);
    expect((await activated.json()).active, 'activation marks the character active').toBe(true);
  });
  await substep('the join menu\'s own GET answers with the definition', async () => {
    const active = await page.request.get(`${prefix}/characters/active`);
    expect(active.status(), `GET ${prefix}/characters/active`).toBe(200);
    const view = await active.json();
    expect(view.name).toBe(name);
    expect(view.definition, 'the active response carries the definition').toBeTruthy();
  });
  world.set(FORGE, name);
});

Then('the 3D join menu offers my forge character by name', async ({ page, world }) => {
  // OFFERED, not greyed — a definition failing matrix-ui's mirror validation
  // would null out and DISABLE this radio instead.
  await expect(
    page.getByTestId('input-source-forge'),
    'the forge option is enabled once an active character exists',
  ).toBeEnabled();
  await expect(page.getByTestId('chat3d-forge-name')).toContainText(world.get<string>(FORGE));
});

Then('my published chat3d avatar carries the forge character', async ({ page, world }) => {
  const ev = await avatarEventOf(page, world.get<string>(ROOM), world.get<string>(MXID));
  expect(ev, 'a chat3d avatar state event for me').toBeTruthy();
  // Stable fields only, never deep equality: the publish path NORMALIZES the
  // config (fills part slots, default materials).
  expect(ev.content?.v).toBe(1);
  expect(ev.content?.mode, 'a forge join publishes a forge-mode avatar').toBe('forge');
  expect(ev.content?.name, 'the avatar wears the forge character name').toBe(world.get<string>(FORGE));
  expect(ev.content?.config?.head?.family, 'the forge config head family travelled').toBe('dragon');
  expect(ev.content?.config?.materials?.fur, 'the forge coat colour travelled').toBe(FORGE_FUR);
});
