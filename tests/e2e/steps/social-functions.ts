// social-functions.ts — the FUNCTION axis for the three social services
// (tuwunel / akkoma / phpbb), and the drift guard that keeps it honest.
//
// WHY THIS FILE EXISTS. The operator asked for "every user in every function in
// every service ... with all interactions". steps/dimensions.ts already spells
// ROLE x PLATFORM x SERVICE x ENV x INTERFACE. What it does NOT carry is the
// FUNCTION: the individual thing a user DOES inside a service — send a message,
// boost a post, accept an invite, remove somebody else's topic. Without that
// axis, "every function" is unmeasurable and "we covered Matrix" is a claim
// nothing can falsify.
//
// THE VOLUME PROBLEM, AND THE ANSWER. 31 seeded personas x ~50 functions x 3
// environments x 2 interfaces is tens of thousands of cells. Hand-writing that
// is decoration by volume: a .feature nobody reads, that generates a report
// nobody can act on. So the coverage here is GENERATIVE in the only way that
// survives contact with playwright-bdd's static Examples tables:
//
//   * the CATALOGUE below is the single source of truth for what a function is;
//   * the per-function scenarios iterate the WHOLE seeded roster INSIDE the step
//     (so adding a persona widens every function row with no feature edit);
//   * the per-persona scenario iterates the WHOLE catalogue INSIDE the step (so
//     adding a function widens every persona row with no feature edit);
//   * and the DRIFT GUARD (features/platform/social-function-drift.feature) goes
//     RED when a catalogued function, service or persona has no scenario at all.
//
// That last one is the real deliverable. The scenarios are its output.
//
// ── WHAT A "PROBE" IS, AND WHAT IT IS NOT ───────────────────────────────────
// Every function names a (gateway, probePath) probe. The ONLY load-bearing
// property of a probePath is WHICH route-access url_pattern it matches — the
// scenarios assert the GATE, never that the endpoint exists or that a real
// server answers it. Concrete ids inside a probe path ('!e2e:hugmesh.net', a
// status id of 1) are therefore representative, and are spelled that way on
// purpose so nobody mistakes a contract row for a live call. The LIVE half of
// each function lives in the journey features, which are @env:docker and skip
// loudly when nothing is running.
//
// ── THE TWO INDEPENDENT SOURCES ─────────────────────────────────────────────
// A test that computed the expectation from the thing under test would be
// circular. So:
//
//   EXPECTED  this catalogue's hand-declared `gate` (which role a function
//             requires, and which roles are supersets of it) x the persona's
//             seeded roles (specs/rbac-roles.ts + tests/e2e-extra-personas.sh)
//   ACTUAL    the DEPLOYED contract — the INSERT rows of
//             specs/cluster/manifests/route-access/initdb/20-schema.sql, read
//             through steps/uncovered-services.steps.ts accessRows() (the same
//             parser the uncovered-services contract scenarios use; a second
//             parser over the same SQL is the divergence this repo keeps
//             growing).
//
// Change either side alone and the matrix goes red naming the function, the
// persona, the pattern and both decisions.

import * as fs from 'node:fs';
import * as path from 'node:path';

import { SYSTEMS_SEED_USERS } from '../specs/rbac-roles';
import { effectiveRoles } from '../specs/rbac-route-access';
import { shellRoster, knownPersonas, personaSource, service } from './dimensions';
import { accessRows } from './uncovered-services.steps';
import type { AccessRow } from './uncovered-services.steps';

/** Repo root — steps/ is tests/e2e/steps, so three levels up. */
export const REPO_ROOT = path.resolve(__dirname, '..', '..', '..');

/** The gateways a social function can be probed on. Spelled as the seed spells
 *  them, so a typo here cannot silently select zero rows (selectRows throws). */
export type ProbeGateway = 'hugmesh-fe-gateway' | 'hugmesh-be-gateway';

/** The three social services this unit covers, in the exact `@service:` spelling. */
export const SOCIAL_SERVICES = ['tuwunel', 'akkoma', 'phpbb'] as const;
export type SocialServiceId = (typeof SOCIAL_SERVICES)[number];

/**
 * How many DISTINCT signed-in identities a function needs to mean anything.
 *   solo   one identity acting on its own state (post, sync, set a display name)
 *   pair   TWO identities where the point is that B observes A (message, boost,
 *          invite+accept, a mod removing somebody else's post)
 *   group  THREE or more (attribution across a room, a pending-invite fan-out)
 * `pair` and `group` are the "interactions" half of the requirement, and the
 * drift guard REFUSES a pair/group function that names neither a journey feature
 * on disk nor a written pending reason.
 */
export type Arity = 'solo' | 'pair' | 'group';

/**
 * The access gate a function sits behind.
 *   role     the named role, or any of `supersets`, reaches it
 *   public   no Casdoor identity required (the seed spells this role 'PUBLIC')
 *   rowless  DELIBERATELY ungoverned: the gateway is DEFAULT-DENY, so a surface
 *            with no seed row is refused to EVERYONE including an admin. Pinning
 *            that is how "somebody helpfully added the missing row" becomes a
 *            failure instead of a silently opened backend.
 */
export type FunctionGate =
  | { kind: 'role'; role: string; supersets: string[] }
  | { kind: 'public' }
  | { kind: 'rowless' };

export interface SocialFunction {
  /** Service-scoped id. The `function` Examples cell uses this exact spelling. */
  id: string;
  service: SocialServiceId;
  /** What the USER is doing, in the words a user would use. */
  name: string;
  arity: Arity;
  gate: FunctionGate;
  gateway: ProbeGateway;
  /** A REPRESENTATIVE path in the surface this function uses. See the header. */
  probePath: string;
  /**
   * The feature file that DRIVES this function against a live stack, repo-
   * relative, or null. A pair/group function with `journey: null` MUST carry a
   * `pending` reason — the drift guard fails otherwise, which is what stops an
   * interaction being catalogued and then never driven.
   */
  journey: string | null;
  /** Why this function has no journey yet. Named, never silent. */
  pending: string | null;
  /**
   * True when the catalogue ASSERTS that no seeded persona can perform this
   * function — a real roster gap kept visible instead of quietly driven as an
   * admin. The guard fails if the gap CLOSES, which is the prompt to widen the
   * coverage (same tripwire shape as features/uncovered-services/access-role-roster.feature).
   */
  expectNoPersona?: boolean;
  note: string;
}

// ── THE CATALOGUE ───────────────────────────────────────────────────────────
// Ordered service by service. Every probePath below was checked against the
// committed seed patterns; see tests/scripts/test-e2e-social-function-matrix.sh,
// which fails when a probePath matches NO pattern at all (an unreachable probe
// would make its row vacuously DENY and prove nothing).

export const SOCIAL_FUNCTIONS: SocialFunction[] = [
  // ── tuwunel (Matrix) ──────────────────────────────────────────────────────
  {
    id: 'whoami', service: 'tuwunel', name: 'discover my own Matrix user id', arity: 'solo',
    gate: { kind: 'role', role: 'ROLE_MATRIX', supersets: ['ROLE_MOD', 'ROLE_ADMIN'] },
    gateway: 'hugmesh-be-gateway', probePath: '/_matrix/client/v3/account/whoami',
    journey: 'tests/e2e/features/matrix/platform-access-wall.feature', pending: null,
    note: 'The whoami the access wall drives live; helpers.matrixUserId().',
  },
  {
    id: 'sync', service: 'tuwunel', name: 'receive the room timeline', arity: 'solo',
    gate: { kind: 'role', role: 'ROLE_MATRIX', supersets: ['ROLE_MOD', 'ROLE_ADMIN'] },
    gateway: 'hugmesh-be-gateway', probePath: '/_matrix/client/v3/sync',
    journey: 'tests/e2e/features/matrix/two-party-chat.feature', pending: null,
    note: 'The long-poll every other Matrix function is observed through.',
  },
  {
    id: 'create-room', service: 'tuwunel', name: 'create a room', arity: 'solo',
    gate: { kind: 'role', role: 'ROLE_MATRIX', supersets: ['ROLE_MOD', 'ROLE_ADMIN'] },
    gateway: 'hugmesh-be-gateway', probePath: '/_matrix/client/v3/createRoom',
    journey: 'tests/e2e/features/matrix/two-party-chat.feature', pending: null,
    note: 'helpers.createRoom(); also the middle leg of the domain-lock proof.',
  },
  {
    id: 'invite', service: 'tuwunel', name: 'invite another user into a room', arity: 'pair',
    gate: { kind: 'role', role: 'ROLE_MATRIX', supersets: ['ROLE_MOD', 'ROLE_ADMIN'] },
    gateway: 'hugmesh-be-gateway', probePath: '/_matrix/client/v3/rooms/!e2e:hugmesh.net/invite',
    journey: 'tests/e2e/features/matrix/group-chat.feature', pending: null,
    note: 'Driven two ways: helpers.inviteToRoom, and the UI Accept row in group-chat.',
  },
  {
    id: 'join', service: 'tuwunel', name: 'accept an invite and join a room', arity: 'pair',
    gate: { kind: 'role', role: 'ROLE_MATRIX', supersets: ['ROLE_MOD', 'ROLE_ADMIN'] },
    gateway: 'hugmesh-be-gateway', probePath: '/_matrix/client/v3/join/!e2e:hugmesh.net',
    journey: 'tests/e2e/features/matrix/group-chat.feature', pending: null,
    note: 'The invitee half of the invite interaction.',
  },
  {
    id: 'leave', service: 'tuwunel', name: 'leave a room', arity: 'pair',
    gate: { kind: 'role', role: 'ROLE_MATRIX', supersets: ['ROLE_MOD', 'ROLE_ADMIN'] },
    gateway: 'hugmesh-be-gateway', probePath: '/_matrix/client/v3/rooms/!e2e:hugmesh.net/leave',
    journey: 'tests/e2e/features/matrix/interactions.feature', pending: null,
    note: 'A pair function: leaving is only observable because the OTHER member sees the membership change.',
  },
  {
    id: 'send-message', service: 'tuwunel', name: 'send a text message', arity: 'pair',
    gate: { kind: 'role', role: 'ROLE_MATRIX', supersets: ['ROLE_MOD', 'ROLE_ADMIN'] },
    gateway: 'hugmesh-be-gateway',
    probePath: '/_matrix/client/v3/rooms/!e2e:hugmesh.net/send/m.room.message/1',
    journey: 'tests/e2e/features/matrix/two-party-chat.feature', pending: null,
    note: 'KNOWN PRODUCT BLOCKER on the live leg (hsproxy re-escapes the %-encoded room id).',
  },
  {
    id: 'redact', service: 'tuwunel', name: 'delete a message I sent', arity: 'pair',
    gate: { kind: 'role', role: 'ROLE_MATRIX', supersets: ['ROLE_MOD', 'ROLE_ADMIN'] },
    gateway: 'hugmesh-be-gateway',
    probePath: '/_matrix/client/v3/rooms/!e2e:hugmesh.net/redact/$evt:hugmesh.net/1',
    journey: 'tests/e2e/features/matrix/interactions.feature', pending: null,
    note: 'The redaction has to be observed in the PEER timeline or it proves nothing.',
  },
  {
    id: 'read-receipt', service: 'tuwunel', name: 'mark a room as read', arity: 'pair',
    gate: { kind: 'role', role: 'ROLE_MATRIX', supersets: ['ROLE_MOD', 'ROLE_ADMIN'] },
    gateway: 'hugmesh-be-gateway',
    probePath: '/_matrix/client/v3/rooms/!e2e:hugmesh.net/receipt/m.read/$evt:hugmesh.net',
    journey: 'tests/e2e/features/matrix/group-chat.feature', pending: null,
    note: 'The unread-badge scenario is the driven form; it is KNOWN RED behind the same proxy defect.',
  },
  {
    id: 'room-state', service: 'tuwunel', name: 'read and publish room state', arity: 'solo',
    gate: { kind: 'role', role: 'ROLE_MATRIX', supersets: ['ROLE_MOD', 'ROLE_ADMIN'] },
    gateway: 'hugmesh-be-gateway', probePath: '/_matrix/client/v3/rooms/!e2e:hugmesh.net/state',
    journey: 'tests/e2e/features/matrix/chat3d.feature', pending: null,
    note: 'The chat3d avatar is published as room state.',
  },
  {
    id: 'call-invite', service: 'tuwunel', name: 'place a voice/video call', arity: 'pair',
    gate: { kind: 'role', role: 'ROLE_MATRIX', supersets: ['ROLE_MOD', 'ROLE_ADMIN'] },
    gateway: 'hugmesh-be-gateway',
    probePath: '/_matrix/client/v3/rooms/!e2e:hugmesh.net/send/m.call.invite/1',
    journey: 'tests/e2e/features/matrix/matrix-call.feature', pending: null,
    note: 'Signalled as room events, so it shares the room-scoped hsproxy blocker.',
  },
  {
    id: 'call-answer', service: 'tuwunel', name: 'answer a call somebody placed', arity: 'pair',
    gate: { kind: 'role', role: 'ROLE_MATRIX', supersets: ['ROLE_MOD', 'ROLE_ADMIN'] },
    gateway: 'hugmesh-be-gateway',
    probePath: '/_matrix/client/v3/rooms/!e2e:hugmesh.net/send/m.call.answer/1',
    journey: 'tests/e2e/features/matrix/chat-then-call.feature', pending: null,
    note: 'The callee half; chat-then-call asserts a LIVE remote audio track, not a label.',
  },
  {
    id: 'send-sticker', service: 'tuwunel', name: 'send a VN sticker', arity: 'pair',
    gate: { kind: 'role', role: 'ROLE_MATRIX', supersets: ['ROLE_MOD', 'ROLE_ADMIN'] },
    gateway: 'hugmesh-be-gateway',
    probePath: '/_matrix/client/v3/rooms/!e2e:hugmesh.net/send/m.sticker/1',
    journey: 'tests/e2e/features/moderation-media/sticker-character-vn.feature', pending: null,
    note: 'The m.sticker round-trip with an mxc url and the VN expression.',
  },
  {
    id: 'upload-media', service: 'tuwunel', name: 'upload an image or file', arity: 'solo',
    gate: { kind: 'role', role: 'ROLE_MATRIX', supersets: ['ROLE_MOD', 'ROLE_ADMIN'] },
    gateway: 'hugmesh-be-gateway', probePath: '/_matrix/media/v3/upload',
    journey: null,
    pending: 'no spec uploads to the Matrix media repo yet; the sticker lane stubs the mxc url '
           + 'rather than uploading, so a driven upload would be new product surface, not new coverage.',
    note: 'Contract tier only.',
  },
  {
    id: 'set-displayname', service: 'tuwunel', name: 'change my display name', arity: 'pair',
    gate: { kind: 'role', role: 'ROLE_MATRIX', supersets: ['ROLE_MOD', 'ROLE_ADMIN'] },
    gateway: 'hugmesh-be-gateway',
    probePath: '/_matrix/client/v3/profile/@e2e-matrix:hugmesh.net/displayname',
    journey: 'tests/e2e/features/matrix/interactions.feature', pending: null,
    note: 'A pair function: the point of a display name is what the OTHER member sees on my messages.',
  },
  {
    id: 'public-rooms', service: 'tuwunel', name: 'browse the public room directory', arity: 'solo',
    gate: { kind: 'role', role: 'ROLE_MATRIX', supersets: ['ROLE_MOD', 'ROLE_ADMIN'] },
    gateway: 'hugmesh-be-gateway', probePath: '/_matrix/client/v3/publicRooms',
    journey: null,
    pending: 'the shipped matrix-ui has no directory surface; driving the CS-API alone would assert '
           + 'a server capability no user of ours can reach.',
    note: 'Contract tier only.',
  },
  {
    id: 'wellknown-delegation', service: 'tuwunel', name: 'resolve the homeserver by delegation', arity: 'solo',
    gate: { kind: 'role', role: 'ROLE_MATRIX', supersets: ['ROLE_MOD', 'ROLE_ADMIN'] },
    gateway: 'hugmesh-be-gateway', probePath: '/.well-known/matrix/client',
    journey: null,
    pending: 'a native-client bootstrap step; no e2e persona runs a native client today.',
    note: 'Spec-required delegation document; gated exactly like the client surface.',
  },
  {
    id: 'external-client-login', service: 'tuwunel',
    name: 'sign a NATIVE Matrix client in against our homeserver', arity: 'solo',
    gate: { kind: 'role', role: 'ROLE_MATRIX_EXTERNAL_CLIENT', supersets: [] },
    gateway: 'hugmesh-be-gateway', probePath: '/_matrix/client/v3/login',
    journey: null,
    pending: 'needs a real third-party client process; the browser lane never calls /login because '
           + 'the hsproxy holds the token server-side.',
    note: 'EXACT-PATH row: this is NOT reachable by a plain ROLE_MATRIX holder, which is the whole '
        + 'point of the separate external-client role. Our own UI must never hit it.',
  },
  {
    id: 'external-client-register', service: 'tuwunel',
    name: 'register a NATIVE Matrix client account', arity: 'solo',
    gate: { kind: 'role', role: 'ROLE_MATRIX_EXTERNAL_CLIENT', supersets: [] },
    gateway: 'hugmesh-be-gateway', probePath: '/_matrix/client/v3/register',
    journey: null,
    pending: 'same as external-client-login — no native client runs in this suite.',
    note: 'Exact-path row, same tier.',
  },
  {
    id: 'shell-route', service: 'tuwunel', name: 'open Matrix inside the host shell', arity: 'solo',
    gate: { kind: 'role', role: 'ROLE_USER', supersets: [] },
    gateway: 'hugmesh-fe-gateway', probePath: '/social/matrix/room',
    journey: 'tests/e2e/features/matrix/native-sign-in.feature', pending: null,
    note: 'DELIBERATELY a different gate from the backend: the shell ROUTE is ROLE_USER, the '
        + 'homeserver behind it is ROLE_MATRIX. "the shell routes me to Matrix" and "I can use '
        + 'Matrix" are different claims (native-sign-in.feature makes only the first).',
  },
  {
    id: 'federate-remote-join', service: 'tuwunel', name: 'join a room on another server', arity: 'pair',
    gate: { kind: 'role', role: 'ROLE_MATRIX', supersets: ['ROLE_MOD', 'ROLE_ADMIN'] },
    gateway: 'hugmesh-be-gateway', probePath: '/_matrix/client/v3/join/!remote:peer.example',
    journey: 'tests/e2e/features/federation/matrix-domain-lock.feature', pending: null,
    note: 'The ROUTE gate cannot express domain lock — there is no per-user federation control in '
        + 'tuwunel at all. The lock is an EGRESS backstop, which is why the journey probes egress '
        + 'and this contract row only says the CS-API path itself is ROLE_MATRIX.',
  },

  // ── akkoma (Mastodon) ─────────────────────────────────────────────────────
  {
    id: 'verify-credentials', service: 'akkoma', name: 'discover my own account', arity: 'solo',
    gate: { kind: 'role', role: 'ROLE_MASTODON', supersets: ['ROLE_MOD', 'ROLE_ADMIN'] },
    gateway: 'hugmesh-be-gateway', probePath: '/api/v1/accounts/verify_credentials',
    journey: 'tests/e2e/features/matrix/platform-access-wall.feature', pending: null,
    note: 'The access-wall probe; helpers.mastodonAccountId().',
  },
  {
    id: 'home-timeline', service: 'akkoma', name: 'read my home timeline', arity: 'pair',
    gate: { kind: 'role', role: 'ROLE_MASTODON', supersets: ['ROLE_MOD', 'ROLE_ADMIN'] },
    gateway: 'hugmesh-be-gateway', probePath: '/api/v1/timelines/home',
    journey: 'tests/e2e/features/mastodon/two-party-timeline.feature', pending: null,
    note: 'A pair function by construction: home is decided by the FOLLOW GRAPH, so it only has '
        + 'contents because somebody else posted.',
  },
  {
    id: 'public-timeline', service: 'akkoma', name: 'read the local public timeline', arity: 'pair',
    gate: { kind: 'role', role: 'ROLE_MASTODON', supersets: ['ROLE_MOD', 'ROLE_ADMIN'] },
    gateway: 'hugmesh-be-gateway', probePath: '/api/v1/timelines/public',
    journey: 'tests/e2e/features/mastodon/interactions.feature', pending: null,
    note: 'The follow-independent surface — the control that says a missing home post is a follow '
        + 'problem and not a posting problem.',
  },
  {
    id: 'post-status', service: 'akkoma', name: 'post a status', arity: 'solo',
    gate: { kind: 'role', role: 'ROLE_MASTODON', supersets: ['ROLE_MOD', 'ROLE_ADMIN'] },
    gateway: 'hugmesh-be-gateway', probePath: '/api/v1/statuses',
    journey: 'tests/e2e/features/mastodon/two-party-timeline.feature', pending: null,
    note: 'Driven through the UI composer in the two-party journey.',
  },
  {
    id: 'reply-status', service: 'akkoma', name: "reply to somebody else's status", arity: 'pair',
    gate: { kind: 'role', role: 'ROLE_MASTODON', supersets: ['ROLE_MOD', 'ROLE_ADMIN'] },
    gateway: 'hugmesh-be-gateway', probePath: '/api/v1/statuses',
    journey: 'tests/e2e/features/mastodon/interactions.feature', pending: null,
    note: 'Same path as post-status, different FUNCTION — in_reply_to_id is what makes it an '
        + 'interaction. Two functions may share a probe; the id is the key.',
  },
  {
    id: 'boost-status', service: 'akkoma', name: "boost somebody else's status", arity: 'pair',
    gate: { kind: 'role', role: 'ROLE_MASTODON', supersets: ['ROLE_MOD', 'ROLE_ADMIN'] },
    gateway: 'hugmesh-be-gateway', probePath: '/api/v1/statuses/1/reblog',
    journey: 'tests/e2e/features/mastodon/interactions.feature', pending: null,
    note: 'The canonical A-amplifies-B interaction.',
  },
  {
    id: 'favourite-status', service: 'akkoma', name: "favourite somebody else's status", arity: 'pair',
    gate: { kind: 'role', role: 'ROLE_MASTODON', supersets: ['ROLE_MOD', 'ROLE_ADMIN'] },
    gateway: 'hugmesh-be-gateway', probePath: '/api/v1/statuses/1/favourite',
    journey: 'tests/e2e/features/mastodon/interactions.feature', pending: null,
    note: 'Observed on the AUTHOR side as a notification, never only on the actor side.',
  },
  {
    id: 'follow-account', service: 'akkoma', name: 'follow another account', arity: 'pair',
    gate: { kind: 'role', role: 'ROLE_MASTODON', supersets: ['ROLE_MOD', 'ROLE_ADMIN'] },
    gateway: 'hugmesh-be-gateway', probePath: '/api/v1/accounts/1/follow',
    journey: 'tests/e2e/features/mastodon/two-party-timeline.feature', pending: null,
    note: 'helpers.mastodonFollow(); the precondition of the home timeline.',
  },
  {
    id: 'unfollow-account', service: 'akkoma', name: 'unfollow an account', arity: 'pair',
    gate: { kind: 'role', role: 'ROLE_MASTODON', supersets: ['ROLE_MOD', 'ROLE_ADMIN'] },
    gateway: 'hugmesh-be-gateway', probePath: '/api/v1/accounts/1/unfollow',
    journey: 'tests/e2e/features/mastodon/interactions.feature', pending: null,
    note: 'The negative half of the follow graph: after unfollowing, new posts must STOP arriving.',
  },
  {
    id: 'notifications', service: 'akkoma', name: 'see who interacted with me', arity: 'pair',
    gate: { kind: 'role', role: 'ROLE_MASTODON', supersets: ['ROLE_MOD', 'ROLE_ADMIN'] },
    gateway: 'hugmesh-be-gateway', probePath: '/api/v1/notifications',
    journey: 'tests/e2e/features/mastodon/interactions.feature', pending: null,
    note: 'The observation surface for boost/favourite/follow/reply — the receiving end of every '
        + 'Mastodon interaction in this catalogue.',
  },
  {
    id: 'account-statuses', service: 'akkoma', name: "read another account's posts", arity: 'pair',
    gate: { kind: 'role', role: 'ROLE_MASTODON', supersets: ['ROLE_MOD', 'ROLE_ADMIN'] },
    gateway: 'hugmesh-be-gateway', probePath: '/api/v1/accounts/1/statuses',
    journey: 'tests/e2e/features/federation/mastodon-domain-lock.feature', pending: null,
    note: 'How the federation observer peer checks its OWN copy of a local actor.',
  },
  {
    id: 'upload-media', service: 'akkoma', name: 'attach an image to a post', arity: 'solo',
    gate: { kind: 'role', role: 'ROLE_MASTODON', supersets: ['ROLE_MOD', 'ROLE_ADMIN'] },
    gateway: 'hugmesh-be-gateway', probePath: '/api/v2/media',
    journey: null,
    pending: 'the shipped mastodon-ui composer has no attachment control pinned by any spec; a '
           + 'driven upload would need a test id nothing in this repo can source.',
    note: 'Contract tier only. NOTE the /api/v2/** row is a SEPARATE pattern from /api/v1/**.',
  },
  {
    id: 'media-proxy', service: 'akkoma', name: 'load an image somebody posted', arity: 'solo',
    gate: { kind: 'role', role: 'ROLE_MASTODON', supersets: ['ROLE_MOD', 'ROLE_ADMIN'] },
    gateway: 'hugmesh-be-gateway', probePath: '/media/e2e-attachment.png',
    journey: null,
    pending: 'follows upload-media — nothing uploads, so nothing is served back.',
    note: 'Its own top-level /media/** pattern.',
  },
  {
    id: 'streaming', service: 'akkoma', name: 'receive live timeline updates', arity: 'pair',
    gate: { kind: 'role', role: 'ROLE_MASTODON', supersets: ['ROLE_MOD', 'ROLE_ADMIN'] },
    gateway: 'hugmesh-be-gateway', probePath: '/api/v1/streaming/user',
    journey: null,
    pending: 'the two-party journey re-reads the timeline instead of holding a websocket; a '
           + 'streaming assertion needs a socket fixture this harness does not have.',
    note: 'More specific than /api/v1/** and therefore its OWN winning pattern — worth pinning, '
        + 'because a row deleted here would silently fall through to the broader one.',
  },
  {
    id: 'oauth-authorize', service: 'akkoma', name: 'authorise an app against my account', arity: 'solo',
    gate: {
      kind: 'role', role: 'ROLE_MASTODON',
      // The external-client role is a SIBLING allow row at the SAME pattern, not a
      // more specific one — so it belongs in supersets. Today no persona holds it
      // without also holding ROLE_MASTODON, which is exactly why declaring it here
      // rather than discovering it later matters: seed one that does and the cell
      // stays green instead of failing for a reason that is not a defect.
      supersets: ['ROLE_MOD', 'ROLE_ADMIN', 'ROLE_MASTODON_EXTERNAL_CLIENT'],
    },
    gateway: 'hugmesh-be-gateway', probePath: '/oauth/authorize',
    journey: null,
    pending: 'the hsproxy holds the token server-side, so no browser lane reaches /oauth.',
    note: 'ALSO granted to ROLE_MASTODON_EXTERNAL_CLIENT at the same pattern — a sibling row, not '
        + 'a more specific one.',
  },
  {
    id: 'external-client-apps', service: 'akkoma',
    name: 'register a NATIVE Mastodon client', arity: 'solo',
    gate: { kind: 'role', role: 'ROLE_MASTODON_EXTERNAL_CLIENT', supersets: [] },
    gateway: 'hugmesh-be-gateway', probePath: '/api/v1/apps',
    journey: null,
    pending: 'needs a real third-party client process.',
    note: 'EXACT-PATH row: a plain ROLE_MASTODON holder is DENIED here. That asymmetry is the '
        + 'reason the external-client role exists at all.',
  },
  {
    id: 'mod-list-statuses', service: 'akkoma', name: 'review reported statuses as a moderator', arity: 'pair',
    gate: { kind: 'role', role: 'ROLE_MOD', supersets: ['ROLE_ADMIN'] },
    gateway: 'hugmesh-be-gateway', probePath: '/api/v1/pleroma/admin/statuses',
    journey: 'tests/e2e/features/rbac/gateway-route-access.feature', pending: null,
    note: 'The moderation plane is a DIFFERENT gate from the member plane — ROLE_MASTODON does '
        + 'NOT reach it, which is what stops a member moderating.',
  },
  {
    id: 'mod-delete-status', service: 'akkoma', name: "remove somebody else's status", arity: 'pair',
    gate: { kind: 'role', role: 'ROLE_MOD', supersets: ['ROLE_ADMIN'] },
    gateway: 'hugmesh-be-gateway', probePath: '/api/v1/pleroma/admin/statuses/1',
    journey: 'tests/e2e/features/moderation-media/sticker-character-ban-contract.feature', pending: null,
    note: 'The two-party moderation interaction: A posts, MOD removes.',
  },
  {
    id: 'mod-ban-account', service: 'akkoma', name: 'ban an account from the platform', arity: 'pair',
    gate: { kind: 'role', role: 'ROLE_MOD', supersets: ['ROLE_ADMIN'] },
    gateway: 'hugmesh-be-gateway', probePath: '/api/v1/pleroma/admin/users/deactivate',
    journey: 'tests/e2e/features/rbac/domainlock-mod-ban.feature', pending: null,
    note: 'Driven end to end (ban, verify the subject cannot post, lift) by the domain-lock x mod-ban feature.',
  },
  {
    id: 'shell-route', service: 'akkoma', name: 'open Mastodon inside the host shell', arity: 'solo',
    gate: { kind: 'role', role: 'ROLE_USER', supersets: [] },
    gateway: 'hugmesh-fe-gateway', probePath: '/social/mastodon/home',
    journey: 'tests/e2e/features/mastodon/two-party-timeline.feature', pending: null,
    note: 'Same deliberate split as the Matrix shell route: ROLE_USER at the route, ROLE_MASTODON '
        + 'at the backend.',
  },
  {
    id: 'federate-outbound', service: 'akkoma', name: 'have my post reach another instance', arity: 'pair',
    gate: { kind: 'role', role: 'ROLE_MASTODON', supersets: ['ROLE_MOD', 'ROLE_ADMIN'] },
    gateway: 'hugmesh-be-gateway', probePath: '/api/v1/statuses',
    journey: 'tests/e2e/features/federation/mastodon-domain-lock.feature', pending: null,
    note: 'Same probe as post-status: the ROUTE cannot express domain lock, the MRF/egress gate '
        + 'does. Catalogued separately so the interaction is named and its journey is pinned.',
  },

  // ── phpbb (forum) ─────────────────────────────────────────────────────────
  {
    id: 'board-index', service: 'phpbb', name: 'open the forum index', arity: 'solo',
    gate: { kind: 'role', role: 'ROLE_FORUM', supersets: [] },
    gateway: 'hugmesh-fe-gateway', probePath: '/social/forum/',
    journey: 'tests/e2e/features/uncovered-services/forum-console.feature', pending: null,
    note: 'MIND THE SPLIT: the SEED gates /social/forum/** on ROLE_FORUM, while the shipped '
        + 'forum-ui guard (forumGuard) admits ANY authenticated identity. The seed is the gate '
        + 'this row asserts; forum-console.feature drives the app-level guard. They disagree '
        + 'today and the disagreement is real — see the drift scenario that names it.',
  },
  {
    id: 'search', service: 'phpbb', name: 'search the board', arity: 'solo',
    gate: { kind: 'role', role: 'ROLE_FORUM', supersets: [] },
    gateway: 'hugmesh-fe-gateway', probePath: '/social/forum/search',
    journey: 'tests/e2e/features/uncovered-services/forum-console.feature', pending: null,
    note: 'The search entry is the pinned chrome forum-console.feature asserts.',
  },
  {
    id: 'view-topic', service: 'phpbb', name: 'read a topic', arity: 'pair',
    gate: { kind: 'role', role: 'ROLE_FORUM', supersets: [] },
    gateway: 'hugmesh-fe-gateway', probePath: '/social/forum/topic/1',
    journey: null,
    pending: 'reading a topic needs a SEEDED topic; no seeder creates forum content, so a driven '
           + 'read would assert against an empty board and pass for the wrong reason.',
    note: 'Contract tier only.',
  },
  {
    id: 'vn-profile', service: 'phpbb', name: 'show my VN profile on the board', arity: 'solo',
    gate: { kind: 'role', role: 'ROLE_FORUM', supersets: [] },
    gateway: 'hugmesh-fe-gateway', probePath: '/bff/forum/vn-profile',
    journey: 'tests/e2e/features/uncovered-services/forum-console.feature', pending: null,
    note: 'The VN-profile toggle is the one piece of forum chrome that only a logged-in identity gets.',
  },
  {
    id: 'list-categories', service: 'phpbb', name: 'list the boards', arity: 'solo',
    gate: { kind: 'role', role: 'ROLE_FORUM', supersets: [] },
    gateway: 'hugmesh-fe-gateway', probePath: '/bff/forum/categories',
    journey: null,
    pending: 'no seeded category exists; forum-console.feature deliberately stops at the mount.',
    note: 'Contract tier only.',
  },
  {
    id: 'post-topic', service: 'phpbb', name: 'start a topic', arity: 'pair',
    gate: { kind: 'role', role: 'ROLE_FORUM', supersets: [] },
    gateway: 'hugmesh-fe-gateway', probePath: '/bff/forum/topics',
    journey: null,
    pending: 'TWO blockers, neither of them a test-harness gap. phpBB lives behind the `phpbb` '
           + 'compose profile and is DEFAULT-OFF (tests/stack/compose.alt-social.yaml), and no '
           + 'seeder creates a category to post into. Beyond that, no spec anywhere in this repo '
           + 'pins a forum-ui composer test id, so a driven post would need an INVENTED selector '
           + '— a scenario that can never pass. Arm it with `make stack-up PHPBB=1`, a seeded '
           + 'category, and a pinned composer test id, in that order.',
    note: 'Contract tier only, deliberately.',
  },
  {
    id: 'reply-topic', service: 'phpbb', name: "reply to somebody else's topic", arity: 'pair',
    gate: { kind: 'role', role: 'ROLE_FORUM', supersets: [] },
    gateway: 'hugmesh-fe-gateway', probePath: '/bff/forum/posts',
    journey: null,
    pending: 'same two blockers as post-topic (profile default-off, no seeded category, no pinned '
           + 'composer test id). The canonical forum interaction, and the one this unit could NOT '
           + 'drive — reported rather than faked.',
    note: 'Contract tier only, deliberately.',
  },
  {
    id: 'mod-remove-post', service: 'phpbb', name: "remove somebody else's post as a board moderator",
    arity: 'pair',
    gate: { kind: 'role', role: 'ROLE_FORUM_MOD', supersets: [] },
    gateway: 'hugmesh-fe-gateway', probePath: '/bff/forum/moderation/posts/1',
    journey: null,
    pending: 'NO SEEDED PERSONA HOLDS ROLE_FORUM_MOD, so there is nobody to drive it as. Seed '
           + 'e2e-forum-mod:ROLE_FORUM_MOD,ROLE_FORUM,ROLE_USER into tests/e2e-extra-personas.sh '
           + 'and the roster-gap scenario goes red, which is the prompt to write the journey.',
    expectNoPersona: true,
    note: 'A real roster gap, kept visible rather than papered over by driving it as an admin — '
        + 'and ROLE_ADMIN does NOT reach this pattern anyway, /bff/forum/admin/** is the admin one.',
  },
  {
    id: 'admin-board-settings', service: 'phpbb', name: 'administer the board', arity: 'solo',
    gate: { kind: 'role', role: 'ROLE_ADMIN', supersets: [] },
    gateway: 'hugmesh-fe-gateway', probePath: '/bff/forum/admin/settings',
    journey: null,
    pending: 'the admin console has no forum module pinned by any spec.',
    note: 'A SIBLING prefix that must stay ABOVE the /bff/forum/** catch-all, or an admin call '
        + 'would be decided as a plain member call.',
  },
  {
    id: 'api-forum-admin', service: 'phpbb', name: 'administer the board through the API', arity: 'solo',
    gate: { kind: 'role', role: 'ROLE_ADMIN', supersets: [] },
    gateway: 'hugmesh-be-gateway', probePath: '/api/forum/admin/boards',
    journey: null,
    pending: 'no admin-BFF spec covers a forum module.',
    note: 'The be-gateway half of the admin plane.',
  },
  {
    id: 'phpbb-pod', service: 'phpbb', name: 'reach the phpBB pod directly', arity: 'solo',
    gate: { kind: 'rowless' },
    gateway: 'hugmesh-fe-gateway', probePath: '/social/phpbb/index.php',
    journey: 'tests/e2e/features/uncovered-services/route-contract.feature', pending: null,
    note: 'CONTRACTUALLY ROW-LESS. The gateway is default-deny, so the backend-only pod is refused '
        + 'to EVERYONE, admin included. Pinned as a rowless gate so "adding the missing row" is a '
        + 'red scenario, not a silent opening.',
  },
];

// ── lookups ─────────────────────────────────────────────────────────────────

const BY_KEY = new Map(SOCIAL_FUNCTIONS.map((f) => [`${f.service}/${f.id}`, f]));

/** Every function of one social service, in catalogue order. */
export function socialFunctions(serviceId: string): SocialFunction[] {
  if (!(SOCIAL_SERVICES as readonly string[]).includes(serviceId)) {
    throw new Error(
      `'${serviceId}' is not one of the social services this catalogue covers `
      + `(${SOCIAL_SERVICES.join(', ')}). steps/dimensions.ts SERVICES carries the full service `
      + `list; the FUNCTION axis is defined only for the social ones. Add the service to `
      + `SOCIAL_SERVICES and give it functions before tagging a function scenario with it.`,
    );
  }
  return SOCIAL_FUNCTIONS.filter((f) => f.service === serviceId);
}

/** One function, or a throw naming every legal id for that service. */
export function socialFunction(serviceId: string, id: string): SocialFunction {
  const found = BY_KEY.get(`${serviceId}/${id}`);
  if (!found) {
    throw new Error(
      `unknown function '${id}' for service '${serviceId}'. Legal ids: `
      + `${socialFunctions(serviceId).map((f) => f.id).join(', ')}. Add it to SOCIAL_FUNCTIONS in `
      + `steps/social-functions.ts — never spell a new function inline in a .feature file, or the `
      + `drift guard cannot see it.`,
    );
  }
  return found;
}

// ── the persona side ────────────────────────────────────────────────────────

export interface RosterPersona {
  handle: string;
  /** EFFECTIVE roles: granted + the derived ROLE_GAMES_ADMIN where it applies. */
  roles: string[];
  source: 'ts-catalogue' | 'shell-roster' | 'both';
  /** false only for the deliberately-unapproved pending persona. */
  registrationComplete: boolean;
}

let rosterCache: RosterPersona[] | undefined;

/**
 * Every persona EITHER seeder creates, with its effective role set.
 *
 * The two rosters disagree (steps/dimensions.ts says so at length) and this
 * accepts the UNION, exactly as `knownPersonas()` does — with one refinement: a
 * handle both sources seed gets the UNION of both role lists, because both
 * seeders really run and Casdoor ends up holding both grants. Pretending only
 * one side counted would make a persona's decision depend on which file the
 * reader happened to open.
 */
export function socialRoster(): RosterPersona[] {
  if (rosterCache) return rosterCache;
  const out: RosterPersona[] = [];
  for (const handle of knownPersonas()) {
    const ts = SYSTEMS_SEED_USERS.find((u) => u.username === handle);
    const sh = shellRoster().find((p) => p.username === handle);
    const roles = new Set<string>();
    if (ts) for (const r of effectiveRoles(ts.roles, ts.expectGamesAdmin)) roles.add(r);
    if (sh) for (const r of sh.roles) roles.add(r);
    out.push({
      handle,
      roles: [...roles].sort(),
      source: personaSource(handle)!,
      registrationComplete: ts ? ts.registrationComplete : true,
    });
  }
  if (out.length === 0) {
    throw new Error('the social roster resolved to ZERO personas — knownPersonas() is empty, '
      + 'which would make every function-matrix scenario vacuously green.');
  }
  rosterCache = out;
  return out;
}

/** One persona's effective roles, or a throw naming the legal handles. */
export function rosterPersona(handle: string): RosterPersona {
  const found = socialRoster().find((p) => p.handle === handle);
  if (!found) {
    throw new Error(
      `'${handle}' is seeded by neither roster. Legal handles: `
      + `${socialRoster().map((p) => p.handle).join(', ')}.`,
    );
  }
  return found;
}

// ── the DEPLOYED oracle: the route-access seed ──────────────────────────────

export type Decision = 'ALLOW' | 'DENY';

/**
 * Match a seed url_pattern against a path, mirroring Spring's most-specific-
 * pattern-wins. Handles the three shapes the committed seed actually uses:
 * a `/**` suffix, a single-segment `*` glob (`/*.js`), and an exact path.
 *
 * NOT a copy of specs/rbac-route-access.ts patternMatch(): that one mirrors the
 * hand-maintained TS subset (which has no `*` patterns and no PUBLIC spelling)
 * and is asserted against by the 33 handwritten specs. This one reads the SQL
 * the cluster actually seeds, which is a SUPERSET — it carries /social/forum/**,
 * /bff/forum/**, /media/** and the whole forum plane the TS mirror never grew.
 * Merging them is real work and is deliberately NOT attempted here; the
 * divergence is instead made VISIBLE by a drift scenario that names it.
 */
function patternMatch(pattern: string, p: string): { matched: boolean; specificity: number } {
  if (pattern.endsWith('/**')) {
    const prefix = pattern.slice(0, -3);
    const matched = p === prefix || p.startsWith(prefix + '/');
    return { matched, specificity: matched ? prefix.length * 2 : -1 };
  }
  if (pattern === '/') {
    return { matched: p === '/', specificity: p === '/' ? 1 : -1 };
  }
  if (pattern.includes('*')) {
    // single-segment glob, e.g. /*.js — '*' must not cross a '/'
    const rx = new RegExp('^' + pattern.split('*').map(escapeRe).join('[^/]*') + '$');
    const matched = rx.test(p);
    const literal = pattern.replace(/\*/g, '').length;
    return { matched, specificity: matched ? literal * 2 : -1 };
  }
  const matched = p === pattern;
  return { matched, specificity: matched ? pattern.length * 2 + 1 : -1 };
}

function escapeRe(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

export interface SeedVerdict {
  decision: Decision;
  /** The winning url_pattern, or null when NO pattern matched (default-deny). */
  pattern: string | null;
  /** Every role granted at the winning pattern by an allow=true row. */
  grantedRoles: string[];
}

/**
 * What the DEPLOYED route-access seed decides for a caller holding `roles`.
 *
 * `PUBLIC` is the seed's spelling for "no Casdoor JWT required"; the TS mirror
 * spells the same thing ROLE_ANONYMOUS. Both are accepted so a probe path that
 * lands on a public row is not mis-reported as a deny.
 *
 * allow=false rows are NOT bans — the schema comment is explicit that the table
 * is an OR of ALLOW rows and that a removal makes a path governed-but-ungranted.
 * They are therefore simply not counted as grants.
 */
export function seedVerdict(gateway: ProbeGateway, p: string, roles: string[]): SeedVerdict {
  const rows: AccessRow[] = accessRows().filter((r) => r.gateway === gateway);
  if (rows.length === 0) {
    throw new Error(
      `the route-access seed carries ZERO rows for gateway '${gateway}'. Either the gateway name `
      + `changed or the parser stopped matching — refusing to decide, because an empty row set `
      + `makes every probe vacuously DENY and the whole function matrix green for nothing.`,
    );
  }
  let best = -1;
  let winners: AccessRow[] = [];
  for (const r of rows) {
    const { matched, specificity } = patternMatch(r.pattern, p);
    if (!matched) continue;
    if (specificity > best) { best = specificity; winners = []; }
    if (specificity === best) winners.push(r);
  }
  if (best < 0) return { decision: 'DENY', pattern: null, grantedRoles: [] };
  const allows = winners.filter((r) => r.allow);
  const grantedRoles = [...new Set(allows.map((r) => r.role))].sort();
  const isPublic = grantedRoles.includes('PUBLIC') || grantedRoles.includes('ROLE_ANONYMOUS');
  const decision: Decision = isPublic || grantedRoles.some((g) => roles.includes(g))
    ? 'ALLOW' : 'DENY';
  return { decision, pattern: winners[0].pattern, grantedRoles };
}

/** What THIS CATALOGUE says should happen — the independent expectation. */
export function catalogueExpectation(fn: SocialFunction, p: RosterPersona): Decision {
  switch (fn.gate.kind) {
    case 'public': return 'ALLOW';
    case 'rowless': return 'DENY';
    case 'role': {
      const accepted = [fn.gate.role, ...fn.gate.supersets];
      return accepted.some((r) => p.roles.includes(r)) ? 'ALLOW' : 'DENY';
    }
  }
}

/** Personas the catalogue expects to be ABLE to perform a function. */
export function personasWhoCan(fn: SocialFunction): RosterPersona[] {
  return socialRoster().filter((p) => catalogueExpectation(fn, p) === 'ALLOW');
}

export interface CellDisagreement {
  handle: string;
  functionId: string;
  service: string;
  expected: Decision;
  actual: Decision;
  pattern: string | null;
  grantedRoles: string[];
  personaRoles: string[];
}

/**
 * Compare the catalogue against the deployed seed for a set of cells. Returns
 * ONLY the disagreements, so a step can assert on an empty list and print every
 * offending cell in one failure rather than dying on the first.
 */
export function disagreements(fns: SocialFunction[], people: RosterPersona[]): CellDisagreement[] {
  const out: CellDisagreement[] = [];
  for (const fn of fns) {
    for (const p of people) {
      const expected = catalogueExpectation(fn, p);
      const v = seedVerdict(fn.gateway, fn.probePath, p.roles);
      if (v.decision !== expected) {
        out.push({
          handle: p.handle, functionId: fn.id, service: fn.service,
          expected, actual: v.decision, pattern: v.pattern,
          grantedRoles: v.grantedRoles, personaRoles: p.roles,
        });
      }
    }
  }
  return out;
}

/** Render disagreements as a readable block for an assertion message. */
export function renderDisagreements(rows: CellDisagreement[]): string {
  return rows.map((d) =>
    `  ${d.service}/${d.functionId}  persona=${d.handle}\n`
    + `      catalogue expected ${d.expected}, the route-access seed says ${d.actual}\n`
    + `      winning url_pattern: ${d.pattern ?? '<none — default-deny>'}\n`
    + `      roles granted there: ${d.grantedRoles.join(', ') || '<none>'}\n`
    + `      persona holds:       ${d.personaRoles.join(', ') || '<none>'}`,
  ).join('\n');
}

// ── the DRIFT GUARD's inputs ────────────────────────────────────────────────

const FEATURES_DIR = path.join(REPO_ROOT, 'tests', 'e2e', 'features');

/**
 * Every .feature file's text with COMMENT LINES STRIPPED.
 *
 * Stripping is not fussiness. This repo has been bitten five times by a grep
 * that counted a token inside a comment as wiring: a function id mentioned only
 * in prose would satisfy "this function has a scenario" while nothing executed
 * it — the exact decorative-coverage failure the whole lane exists to prevent.
 */
export function featureSources(): { file: string; text: string }[] {
  const out: { file: string; text: string }[] = [];
  const walk = (dir: string): void => {
    for (const e of fs.readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      const abs = path.join(dir, e.name);
      if (e.isDirectory()) walk(abs);
      else if (e.name.endsWith('.feature')) {
        const raw = fs.readFileSync(abs, 'utf8');
        const stripped = raw.split('\n').filter((l) => !/^\s*#/.test(l)).join('\n');
        out.push({ file: path.relative(REPO_ROOT, abs), text: stripped });
      }
    }
  };
  if (!fs.existsSync(FEATURES_DIR)) {
    throw new Error(`${FEATURES_DIR} does not exist — the Gherkin tree is gone.`);
  }
  walk(FEATURES_DIR);
  if (out.length === 0) throw new Error(`no .feature files under ${FEATURES_DIR}.`);
  return out;
}

/**
 * Does any EXECUTABLE Gherkin line name this token as an Examples cell or a
 * quoted step argument? Comment lines are already gone (featureSources), and a
 * bare substring match is deliberately NOT used: 'search' would match the word
 * search in a step name and report coverage that does not exist.
 */
export function tokenIsExercised(token: string, sources = featureSources()): string[] {
  const cell = new RegExp(`\\|\\s*${escapeRe(token)}\\s*\\|`);
  const quoted = new RegExp(`"${escapeRe(token)}"`);
  return sources.filter((s) => cell.test(s.text) || quoted.test(s.text)).map((s) => s.file);
}

/** Does a journey path point at a file that is really on disk? */
export function journeyExists(rel: string): boolean {
  return fs.existsSync(path.join(REPO_ROOT, rel));
}

/**
 * The social service ids, RESOLVED THROUGH steps/dimensions.ts.
 *
 * Calling service(id) is the point: a social service id that stops existing in
 * the SERVICES catalogue (renamed, dropped) throws here naming the legal set,
 * instead of quietly producing an empty function list that every scenario would
 * pass against.
 */
export function socialServiceIds(): string[] {
  return (SOCIAL_SERVICES as readonly string[]).map((id) => service(id).id);
}
