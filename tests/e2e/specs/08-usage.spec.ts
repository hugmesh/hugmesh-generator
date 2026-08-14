import { test, expect } from '@playwright/test';
import { onboard, shot } from './helpers';

// By the time this runs, earlier specs have generated real login/complete/
// invite events that the BFF wrote to ClickHouse. The admin Usage view reads
// the aggregates back. (Native login records a 'login' event — there is no
// 'register' action; the removed google/discord self-registration is gone.)
//
// Usage analytics lives inside admin-ui's own per-module menu (admin.component.ts's
// `menu()`, reached via the host's Admin profile-menu entry) — there is no
// host-level top-nav shortcut. This spec previously assumed a `nav-usage`
// testid that no longer exists anywhere in the current UI.
//
// INFRASTRUCTURE DEPENDENCY — ClickHouse (added 2026-08-12). The title's
// "(ClickHouse-backed)" is the whole point of the first test: it asserts the
// aggregates the admin Usage view reads back out of the ClickHouse analytics
// warehouse that admin-bff writes events into (via Kafka). The COMPOSE lane has
// NEITHER — tests/stack/compose.local.yaml states it outright: "The
// kafka/clickhouse analytics wiring is OMITTED here (no Kafka/ClickHouse in the
// local core stack)... Analytics endpoints (/bff/admin/usage) are NOT exercised
// locally (documented limitation)". ClickHouse exists only as a k8s Deployment
// (specs/cluster/manifests/analytics/clickhouse/) — `docker ps` on this stack
// shows no such container.
//
// admin-bff therefore degrades to the CLEARLY-MARKED in-memory fallback
// (UsageService; BackingServiceCatalog: "admin-bff degrades to in-memory when
// absent"), which self-reports in the payload. Verified live:
//   GET /bff/admin/usage ->
//     {"byAction":[{"action":"complete"},{"action":"matrix.entitled"},
//                  {"action":"mastodon.entitled"},{"action":"admin.invite"}],
//      ...,"source":"in-memory"}
// The fallback records a DIFFERENT, narrower action vocabulary than the
// warehouse — there is no 'login' row at all — which is exactly where the
// assertion below died. That is the missing dependency showing through, not a UI
// bug, so the test SKIPS on the dependency rather than being loosened to match
// whatever the fallback happens to emit. The assertions are UNCHANGED and run in
// full the moment a lane serves source="clickhouse" (the k8s/heavy lane), the
// same way specs 19-23 skip on an absent federation peer.
test('admin views live infra usage analytics (ClickHouse-backed)', async ({ page }) => {
  await onboard(page, 'admin@hugmesh.net'); // admin role; also generates events

  // Ask the BFF which analytics backend actually served this request. `source`
  // is admin-bff's own honest self-report, so this detects the dependency
  // instead of hard-coding a lane guess.
  const probe = await page.request.get('/bff/admin/usage', { headers: { accept: 'application/json' } });
  const source = probe.ok() ? String((await probe.json().catch(() => ({})))?.source ?? '') : '';
  test.skip(
    source !== 'clickhouse',
    `ClickHouse is not deployed on this stack — GET /bff/admin/usage reports source=`
    + `"${source || '<unavailable>'}" (admin-bff's documented in-memory fallback). `
    + `tests/stack/compose.local.yaml omits the Kafka/ClickHouse analytics wiring entirely; `
    + `ClickHouse ships only in specs/cluster/manifests/analytics/clickhouse/. The in-memory `
    + `fallback records a narrower action vocabulary (no 'login' row), so the warehouse-backed `
    + `aggregates below cannot be proven here. Run this on a lane with ClickHouse wired.`,
  );

  await page.getByTestId('profile-trigger').click();
  await page.getByTestId('menu-admin').click();
  await expect(page.getByTestId('admin-view')).toBeVisible();
  await page.locator('[data-menu="usage"]').click();
  await expect(page.getByTestId('usage-view')).toBeVisible();

  // Active users + total events are real, non-zero aggregates.
  await expect(page.getByTestId('usage-total')).not.toHaveText('0');
  await expect(page.getByTestId('usage-active')).not.toHaveText('0');

  // Module + action breakdowns are populated (native login flow at least).
  await expect(page.getByTestId('usage-by-module').locator('[data-module="login-ui"]')).toBeVisible();
  await expect(page.getByTestId('usage-by-action').locator('[data-action="login"]')).toBeVisible();

  await shot(page, '08-usage');
});

test('non-admin cannot reach the usage view', async ({ page }) => {
  await onboard(page, 'alice@gmail.com');
  // The host's Admin profile-menu entry itself is role-gated (session.isAdmin()).
  await page.getByTestId('profile-trigger').click();
  await expect(page.getByTestId('menu-admin')).toHaveCount(0);
  // Direct navigation is also blocked server-side.
  await page.goto('/admin/usage');
  await expect(page.getByTestId('usage-view')).toHaveCount(0);
  await shot(page, '08-usage-denied');
});
