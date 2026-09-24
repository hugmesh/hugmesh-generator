// onion-session.ts — the ONE judgement both @via:onion lanes make about the
// /bff/session body their proxied browser read back (hugmesh-generator#624).
// Used by tor-onion.steps.ts (compose, #576) and kind-onion.steps.ts (kind, #577).
//
// PURE: it takes the status and body text the step already fetched and never
// touches the network. The fetch stays in each step file, in-page, riding the
// proxied browser, where tor_flip_wiring.py T15 and tests/scripts/test-kind-tor.sh
// can see it. Moving it here would hide it from both guards.
//
// WHY NOT `handle === username`. That was the original assertion, and it can
// never pass on a Casdoor-backed mesh. user-bff's native login keys the account
// by the token SUBJECT (OidcLoginCompletionService: ensureAccount("casdoor",
// subjectOf(tokens))), so /bff/session answers
//   {"id":"casdoor:<sub>","provider":"casdoor","handle":"<sub>",
//    "registrationComplete":true,"roles":["user"]}
// with the Casdoor sub UUID as `handle` (measured live 2026-09-24, #624, on the
// local door and over the onion, byte-identical). The server never returns the
// username. The "e2e-user" the shell shows in its nav is login-ui's
// localStorage mirror (host-shell session.service fromBody: label falls back to
// the stored value), so it is not server evidence either. specs/helpers.ts
// onboard() says the same: "The opaque-cookie session does NOT expose the display
// label to the browser".
//
// WHAT IS ASSERTED INSTEAD, the way the rest of the suite reads a session
// (common.steps.ts "my session holds the role", moderation-media.steps.ts
// sessionRoles): a well-formed identity (a non-empty `id`, the field host-shell
// itself rejects a body without), registration complete, and the session's roles
// EQUAL to the persona's seeded roles from specs/rbac-roles.ts. Equal, not "contains":
// every privileged persona also carries ROLE_USER, so "contains user" would pass
// for an admin session. /bff/session reports roles lower-cased with ROLE_ stripped
// ("user", "fleet_admin"), so the catalogue's ROLE_* names are normalised the same
// way before comparing.
//
// No provider, no `casdoor:` prefix and no id shape are pinned: those describe the
// SSO backend, not the claim "this persona signed in over the onion".

import { expect } from '@playwright/test';
import { systemsUser } from '../specs/rbac-roles';
import { effectiveRoles } from '../specs/rbac-route-access';

/** ROLE_FOO_BAR -> foo_bar: the spelling /bff/session reports. */
export function sessionRoleName(role: string): string {
  return role.replace(/^ROLE_/i, '').toLowerCase();
}

/** The roles /bff/session must report for a seeded persona, normalised and sorted. */
export function expectedSessionRoles(handle: string): string[] {
  const u = systemsUser(handle);
  return [...new Set(effectiveRoles(u.roles, u.expectGamesAdmin).map(sessionRoleName))].sort();
}

/**
 * Assert that a /bff/session read over an onion door is the signed-in persona's.
 * `where` names the door in every message ("the onion", "the kind onion").
 */
export function expectOnionSessionIsPersona(
  status: number, text: string, handle: string, where: string,
): void {
  expect(status, `GET /bff/session over ${where} -> ${status}: ${text.slice(0, 300)}`).toBe(200);
  let body: { id?: unknown; roles?: unknown; registrationComplete?: unknown };
  try {
    body = JSON.parse(text) as typeof body;
  } catch {
    throw new Error(`GET /bff/session over ${where} returned 200 but not JSON: ${text.slice(0, 300)}`);
  }
  expect(typeof body.id === 'string' && body.id !== '',
    `the session over ${where} names no account id: ${text.slice(0, 300)}`).toBe(true);
  expect(body.registrationComplete,
    `${handle} signed in over ${where} but registration is not complete`).toBe(true);
  expect(Array.isArray(body.roles),
    `the session over ${where} carries no roles array: ${text.slice(0, 300)}`).toBe(true);
  const got = [...new Set((body.roles as unknown[]).map((r) => sessionRoleName(String(r))))].sort();
  expect(got,
    `the session over ${where} must be ${handle}'s: its roles must equal ${handle}'s seeded `
    + 'roles (specs/rbac-roles.ts). A superset means a different, more privileged persona '
    + `signed in; a subset means a different or half-seeded one. Session: ${text.slice(0, 300)}`)
    .toEqual(expectedSessionRoles(handle));
}
