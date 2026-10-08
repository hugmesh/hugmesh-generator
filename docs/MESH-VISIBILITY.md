# Mesh device visibility — the `friends` decision

Every registered mesh device has a `visibility` setting chosen by its owner:
`private` | `friends` | `channels`. Two of the three are implemented and
enforced. **`friends` is not.** For everyone but the owner it behaves as `private`,
on purpose: the platform has no friendship graph to enforce it against. The setting
promises a relationship the platform cannot check.

This note records why, lists the options, and names what must be decided before
`friends` can ship. It is the reference for the four surfaces that store, render or
enforce visibility:

- user-bff stores the setting and hands it to the bridge.
- mesh-bff serves the node directory and the owner's own device list. It is the only
  place the rule is enforced.
- matrix-ui has the mesh-devices section of user settings.
- user-mesh-ui is a scaffold. Its routes import components that do not exist yet, so it
  does not build.

## Current, shipped behaviour

| Visibility | Who sees the owner attribution + LoRa status | Status |
|---|---|---|
| `private` | the owner only (and a superadmin); everyone else sees a bare node id: no owner, no telemetry | enforced |
| `channels` | any caller who can reach the directory (`ROLE_MESH`, or `ROLE_ADMIN` at the route) in the same domain (a blank or `default` directory domain counts as every domain) — a v1 approximation of "members of the mesh-enabled rooms this radio participates in" | enforced (approximated; see below) |
| `friends` | **the owner only** (and a superadmin) — identical to `private` for everyone else | **not enforced as designed** |

The `friends` gap fails in the SAFE direction. A caller sees *less* than the owner
asked for, never more. An owner who picks `friends` gets `private` semantics, so no
attribution leaks. The setting is honest about what it stores, not about what it grants.

The `channels` gap does NOT fail safe. It shows *more* than its stated meaning: to every
same-domain caller, not only to members of the rooms the radio reaches (see "The `channels`
approximation").

Unregistered (anonymous) nodes are unaffected. LoRa is a public broadcast medium, so an
anonymous node is always listed, with its telemetry, and never with owner attribution. A
registered node hidden from a caller is different: it shows as a bare node id with no
telemetry at all.

A superadmin sees every registered node in full. The predicate
(`directory.Visibility.permits` in mesh-bff) adds that bypass on top of the three levels,
as every other cross-tenant check on the platform does.

## Why `friends` is unimplemented

No backend has a friendship primitive. A search on 2026-10-07 across user-bff, admin-bff,
mod-bff, forum-bff and mesh-bff found no friend/follow/contact table, column or endpoint.
The only matches are prose ("`ForumDto` and friends"), the Mastodon `follow` OAuth scope in
user-bff, and unrelated identifiers (`contact_email`, a Cassandra contact point).

The nearest thing to a social graph lives in the **homeservers**, not in a platform database:

1. **Matrix `m.direct`** — per-user account data on the Matrix homeserver. It lists the
   counterparties a user has DMs with (matrix-ui's room list reads it today). A "people I
   talk to directly" set.
2. **Akkoma/Mastodon follows** — the follow graph on the social homeserver, reachable
   through the Mastodon API.

Neither is a *mutual consent* relation. `m.direct` records that a DM room exists, and one
side can create it. A follow is one-directional by definition. Using either as "friend"
changes who can see the last-seen time and battery of a user's physical radio, which is a
location-adjacent privacy signal. That is a product decision with a real privacy cost, so
code does not make it by default.

## Options (for whoever decides)

| Option | Definition of "friend" | Cost | Privacy posture |
|---|---|---|---|
| **A. Mutual Matrix DM** | both users appear in each other's `m.direct` | a homeserver read per visibility check (or a cached projection); needs a service-credential path to read *another* user's account data, which the CS API does not straightforwardly grant | tightest of the three; mutual consent is implied |
| **B. Mutual Akkoma follow** | A follows B and B follows A | Mastodon API call per check + custody of a token that may read follow lists | reasonable; mutual, explicit |
| **C. Native friend table** | an explicit request/accept relation owned by the platform | new table + endpoints + UI in user-bff/user-ui; the most work | cleanest and most honest — the relation means exactly what the setting says |
| **D. Drop the level** | remove `friends` from the vocabulary | a migration + UI change; user-visible removal | simplest, but loses a setting users may already have chosen |

**Recommendation: C**, with **A** as a stop-gap only if a native relation is not wanted.
The `friends` label promises a mutual, deliberate relationship. Options A and B re-purpose
a graph built to mean something else. A radio's status is the kind of data where a
surprising definition of "friend" is a privacy incident, not a UX quibble.

Whatever is chosen, enforce it in **one** place: mesh-bff's visibility predicate, which
already is the only place that enforces it. Do not re-implement it per surface.

## The `channels` approximation

`channels` is enforced today as "any caller who can reach the directory, in the same
domain". That is *broader* than its stated meaning ("members of the mesh-enabled rooms this
radio participates in"). To tighten it, check room membership against the homeserver for
the rooms a device's traffic actually reaches. That is the same kind of homeserver read as
option A, so solve it once, for both.

Until then the UI copy must not over-promise. Say "others on your mesh", not "only people in
your channels". It does over-promise today: matrix-ui's settings help text
(`user-settings.component.html`) says "Friends lets your friends see it; Channels shows it to
members of the mesh-enabled rooms it participates in".

## Definition of done

- one authoritative predicate in mesh-bff, consumed (not duplicated) by user-bff and both UIs;
- a real relation behind `friends` per the decision above;
- the `channels` room-membership tightening;
- tests covering the matrix of {owner, friend, same-domain stranger, cross-domain stranger}
  × {private, friends, channels}, asserting that each non-owner sees a bare node id (no
  owner, no telemetry) rather than an *attributed* node where not permitted, and that a
  superadmin sees all of it;
- UI copy updated to match whatever the levels mean once enforced.
