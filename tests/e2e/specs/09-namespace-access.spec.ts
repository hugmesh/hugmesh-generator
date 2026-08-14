import { test, expect } from '@playwright/test';
import { onboard, shot } from './helpers';

// Namespace access lives inside admin-ui's own per-module menu (admin.component.ts's
// `menu()`, reached via the host's Admin profile-menu entry) — there is no
// host-level top-nav shortcut. This spec previously assumed a `nav-namespaces`
// testid that no longer exists anywhere in the current UI.
//
// Uptrace observability is server-configured (BffService.uptraceUrl(), wired to
// https://uptrace.hugmesh.net by default) but has NO UI entry point
// anywhere in admin-ui or the host — no `nav-uptrace` equivalent was ever built.
// This spec no longer asserts it (queued as an open product gap, not a test bug).
//
// ─────────────────────────────────────────────────────────────────────────────
// KNOWN-RED — PRODUCT BUG, NOT A SPEC BUG (root-caused 2026-08-12).
//
// The grant below fails because admin-bff's namespace vocabulary DISAGREES WITH
// ITS OWN DATABASE. The snapdragon -> hugmesh rename updated the Java constant
// but NOT the Liquibase CHECK constraint that mirrors it:
//
//   AccountStore.NAMESPACES (served verbatim by GET /bff/admin/namespace-access,
//   and what this view's <select> is populated from):
//     hugmesh-pki, hugmesh-backend, hugmesh-frontend, hugmesh-games, observability
//
//   ck_namespace_grant_namespace, admin-bff-api changeset
//   007-data-constraints.xml "007-namespace-grant-namespace-check" — whose own
//   comment claims it "mirrors AccountStore.NAMESPACES / isValidNamespace":
//     snapdragon-pki, snapdragon-backend, snapdragon-frontend, snapdragon-games,
//     observability
//
// So AdminController.grant() passes its store.isValidNamespace() check, issues
// the INSERT, and Postgres rejects it. Reproduced live against this stack:
//
//   POST /bff/admin/namespace-access {"user":"…","namespace":"hugmesh-backend"}
//     -> HTTP 500; admin-bff log: PostgresqlDataIntegrityViolationException
//        [23514] new row for relation "namespace_grant" violates check
//        constraint "ck_namespace_grant_namespace"
//   POST /bff/admin/namespace-access {"user":"…","namespace":"observability"}
//     -> HTTP 200, grant persisted and returned
//
// 'observability' is the ONLY value the two lists still share, which is why it
// is the only namespace an admin can currently grant: FOUR OF THE FIVE ADVERTISED
// NAMESPACES ARE UNGRANTABLE IN PRODUCTION, and the UI reports nothing — the
// component awaits bff.grantNamespace() and simply never re-renders a row.
//
// FIX (owned by hugmesh-admin-bff-api, requires a rebuild — deliberately NOT
// worked around here): add a changeset that drops and re-adds
// ck_namespace_grant_namespace over the hugmesh-* names, migrating any surviving
// snapdragon-* rows. Two secondary defects worth fixing in the same change: the
// 23514 should surface as a 4xx/5xx the UI can render rather than a bare 500,
// and a constraint that claims to mirror a Java constant should be generated
// from it (or covered by a test that fails when they diverge).
//
// This spec is left ASSERTING THE CORRECT BEHAVIOUR and therefore RED. Do not
// switch it to 'observability' and do not skip it: that would hide a real,
// user-visible product defect behind a green suite.
// ─────────────────────────────────────────────────────────────────────────────
test('admin grants a registered user access to a namespace', async ({ page }) => {
  await onboard(page, 'admin@hugmesh.net');

  await page.getByTestId('profile-trigger').click();
  await page.getByTestId('menu-admin').click();
  await expect(page.getByTestId('admin-view')).toBeVisible();
  await page.locator('[data-menu="namespaces"]').click();
  await expect(page.getByTestId('ns-view')).toBeVisible();

  // Grant alice access to the backend namespace.
  await page.getByTestId('ns-user').fill('alice@gmail.com');
  await page.getByTestId('ns-select').selectOption('hugmesh-backend');
  await page.getByTestId('ns-grant').click();

  const row = page.getByTestId('ns-grants').locator('[data-user="alice@gmail.com"]');
  await expect(row).toContainText('hugmesh-backend');
  await shot(page, '09-namespace-grant');
});

test('non-admin is blocked from the namespace access view', async ({ page }) => {
  await onboard(page, 'bob@gmail.com');
  // The host's Admin profile-menu entry itself is role-gated (session.isAdmin()).
  await page.getByTestId('profile-trigger').click();
  await expect(page.getByTestId('menu-admin')).toHaveCount(0);
  // Direct navigation is also blocked server-side.
  await page.goto('/admin/namespaces');
  await expect(page.getByTestId('ns-view')).toHaveCount(0);
  await shot(page, '09-namespace-denied');
});
