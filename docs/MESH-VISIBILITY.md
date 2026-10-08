# Mesh device visibility — the `friends` decision

Every registered mesh device carries a `visibility` setting chosen by its owner:
`private` | `friends` | `channels`. Two of the three are implemented and
enforced. **`friends` is not** — it currently behaves as `private` for everyone
but the owner, deliberately, because the platform has no friendship graph to
enforce it against. This note records why, what the options are, and what has to
be decided before it can ship. It is the reference for the four surfaces that
store, render or enforce visibility: user-bff (stores the setting, hands it to
the bridge), mesh-bff (the node directory and the owner's own device list, and the
only place the rule is enforced), matrix-ui (the mesh-devices section of user
settings), and user-mesh-ui (a scaffold: its routes import components that do not
exist yet, so it does not build).

## Current, shipped behaviour

| Visibility | Who sees the owner attribution + LoRa status | Status |
|---|---|---|
| `private` | the owner only (and a superadmin); everyone else sees a bare node id: no owner, no telemetry | enforced |
| `channels` | any caller who can reach the directory (`ROLE_MESH`, or `ROLE_ADMIN` at the route) in the same domain (a blank or `default` directory domain counts as every domain) — a v1 approximation of "members of the mesh-enabled rooms this radio participates in" | enforced (approximated; see below) |
| `friends` | **the owner only** (and a superadmin) — identical to `private` for everyone else | **not enforced as designed** |

The `friends` gap fails in the SAFE direction: a caller is shown *less* than the
owner asked for, never more. An owner who picks `friends` today gets `private`
semantics, so no attribution leaks — the setting is honest about what it
stores, not about what it currently grants. The `channels` gap does NOT fail
safe: it shows *more* than its stated meaning, to every same-domain caller
rather than only to members of the rooms the radio reaches (see "The `channels`
approximation").

Unregistered/anonymous nodes are unaffected by any of this: LoRa is a public
broadcast medium, so an anonymous node is always listed, with its telemetry, and
always without owner attribution. A registered node hidden from a caller is not
the same thing: it shows as a bare node id with no telemetry at all.

A superadmin sees every registered node in full. The predicate
(`directory.Visibility.permits` in mesh-bff) adds that bypass on top of the three
levels, as it does for every other cross-tenant check on the platform.

## Why `friends` is unimplemented

There is no server-side friendship primitive anywhere in the platform's
backends. Verified again on 2026-10-07 by search across user-bff, admin-bff, mod-bff,
forum-bff and mesh-bff: no friend/follow/contact table, column, or endpoint exists. The
only matches are prose ("`ForumDto` and friends"), the Mastodon `follow` OAuth scope
in user-bff, and unrelated identifiers (`contact_email`, a Cassandra contact point). The closest
thing the platform has to a social graph lives in the **homeservers**, not in
any platform database:

1. **Matrix `m.direct`** — per-user account data on the Matrix homeserver
   listing the counterparties a user has DMs with (read today by matrix-ui's
   room list). A "people I talk to directly" set.
2. **Akkoma/Mastodon follows** — the follow graph on the social homeserver,
   reachable through the Mastodon API.

Neither is a *mutual consent* relation in the way "friends" implies: `m.direct`
records that a DM room exists (one-sided creation is enough), and a follow is
explicitly one-directional. Picking either as "friend" changes who can see a
user's physical radio's last-seen time and battery — a location-adjacent
privacy signal. That is a product decision with a real privacy consequence, so
it is deliberately not being made in code by default.

## Options (for whoever decides)

| Option | Definition of "friend" | Cost | Privacy posture |
|---|---|---|---|
| **A. Mutual Matrix DM** | both users appear in each other's `m.direct` | a homeserver read per visibility check (or a cached projection); needs a service-credential path to read *another* user's account data, which the CS API does not straightforwardly grant | tightest of the three; mutual consent is implied |
| **B. Mutual Akkoma follow** | A follows B and B follows A | Mastodon API call per check + custody of a token that may read follow lists | reasonable; mutual, explicit |
| **C. Native friend table** | an explicit request/accept relation owned by the platform | new table + endpoints + UI in user-bff/user-ui; the most work | cleanest and most honest — the relation means exactly what the setting says |
| **D. Drop the level** | remove `friends` from the vocabulary | a migration + UI change; user-visible removal | simplest, but loses a setting users may already have chosen |

**Recommendation: C**, with **A** as a stop-gap only if a native relation is
not wanted. The `friends` label promises a mutual, deliberate relationship;
options A and B both re-purpose a graph that was built to mean something else,
and a radio's status is exactly the kind of data where a surprising definition
of "friend" is a privacy incident rather than a UX quibble. Whatever is chosen,
enforcement belongs in **one** place — mesh-bff's visibility predicate, which
is already the only place that enforces it — not re-implemented per surface.

## The `channels` approximation

`channels` is enforced today as "any caller who can reach the directory, in the same domain",
which is *broader* than its stated meaning ("members of the mesh-enabled rooms
this radio participates in"). Tightening it needs a room-membership check
against the homeserver for the rooms a device's traffic actually reaches — the
same class of homeserver-read problem as option A above, and worth solving
once, for both. Until then the UI copy should not over-promise: say
"others on your mesh" rather than "only people in your channels". It still does
over-promise today: matrix-ui's settings help text
(`user-settings.component.html`) says "Friends lets your friends see it; Channels shows it to
members of the mesh-enabled rooms it participates in".

## Definition of done

- one authoritative predicate in mesh-bff, consumed (not duplicated) by
  user-bff and both UIs;
- a real relation behind `friends` per the decision above;
- the `channels` room-membership tightening;
- tests covering the matrix of {owner, friend, same-domain stranger,
  cross-domain stranger} × {private, friends, channels}, asserting that each
  non-owner sees a bare node id (no owner, no telemetry) rather than an
  *attributed* node where not permitted, and that a superadmin sees all of it;
- UI copy updated to match whatever the levels actually mean once enforced.
