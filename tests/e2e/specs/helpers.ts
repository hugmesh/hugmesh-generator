import { Page, APIRequestContext, expect } from '@playwright/test';
import * as fs from 'node:fs';
import * as path from 'node:path';

export const SHOTS = path.resolve(process.env.SNAP_SHOTS || 'screenshots');
fs.mkdirSync(SHOTS, { recursive: true });

export interface Session {
  id: string;
  label: string;
  provider: 'google' | 'discord';
  roles: string[];
  registrationComplete: boolean;
  matrix: { token: string; userId: string } | null;
  mastodon: { token: string } | null;
}

export async function shot(page: Page, name: string): Promise<void> {
  await page.screenshot({ path: path.join(SHOTS, `${name}.png`), fullPage: true });
}

export function getSession(page: Page): Promise<Session> {
  return page.evaluate(() => JSON.parse(localStorage.getItem('snap.session')!));
}

/** Stage 1 only: register an invited identity but do NOT complete (for gating). */
export async function registerOnly(page: Page, handle: string, provider: 'google' | 'discord' = 'google'): Promise<void> {
  await page.goto('/login');
  if (provider === 'discord') {
    await page.getByTestId('login-discord').fill(handle);
    await page.getByTestId('login-discord-register').click();
  } else {
    await page.getByTestId('login-email').fill(handle);
    await page.getByTestId('login-google-register').click();
  }
}

/** Full onboarding: register (stage 1) + complete (stage 2). Returns the
 *  fully-registered session with Matrix + Mastodon tokens. */
export async function onboard(page: Page, handle: string, provider: 'google' | 'discord' = 'google'): Promise<Session> {
  await registerOnly(page, handle, provider);
  // The login UI (snapdragon-login-ui eaadfce, 2026-06-12) requires a display
  // name before "Complete registration" enables (completeBlocked()). An ASCII
  // name also skips the conditional screen-reader-name prompt.
  await page.getByTestId('register-display-name').fill(handle);
  await page.getByTestId('login-complete').click();
  await expect(page.getByTestId('nav-user')).toHaveText(handle);
  await expect(page.getByTestId('nav-matrix')).toBeVisible();
  return getSession(page);
}

export async function createRoom(req: APIRequestContext, me: Session, peerUserId: string, name: string): Promise<string> {
  const r = await req.post(`/_matrix/client/v3/createRoom`, {
    headers: { authorization: `Bearer ${me.matrix!.token}` },
    data: { name, invite: [peerUserId] },
  });
  return (await r.json()).room_id;
}

export async function joinRoom(req: APIRequestContext, who: Session, roomId: string): Promise<void> {
  await req.post(`/_matrix/client/v3/rooms/${encodeURIComponent(roomId)}/join`, {
    headers: { authorization: `Bearer ${who.matrix!.token}` },
  });
}
