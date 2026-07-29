# Mesh device visibility — the `friends` decision

Every registered mesh device carries a `visibility` setting chosen by its owner:
`private` | `friends` | `channels`. Two of the three are implemented and
enforced. **`friends` is not** — it currently behaves as `private` for everyone
but the owner, deliberately, because the platform has no friendship graph to
enforce it against. This note records why, what the options are, and what has to
be decided before it can ship. It is the reference for the four surfaces that
render or enforce visibility: user-bff (the owner's own view + the bridge
mapping), mesh-bff (the node directory), matrix-ui (My Mesh Devices), and
user-mesh-ui.

## Current, shipped behaviour

| Visibility | Who sees the owner attribution + LoRa status | Status |
|---|---|---|
| `private` | the owner only; everyone else sees the node as anonymous | enforced |
| `channels` | any ROLE_MESH caller in the same domain — a v1 approximation of "members of the mesh-enabled rooms this radio participates in" | enforced (approximated; see below) |
| `friends` | **the owner only** — identical to `private` for non-owners | **not enforced as designed** |

Both gaps fail in the SAFE direction: a caller is shown *less* than the owner
asked for, never more. An owner who picks `friends` today gets `private`
semantics, so no attribution leaks — the setting is honest about what it
stores, not about what it currently grants.

Unregistered/anonymous nodes are unaffected by any of this: LoRa is a public
broadcast medium, so an anonymous node is always listed, always without owner
attribution.

## Why `friends` is unimplemented

There is no server-side friendship primitive anywhere in the platform's
backends. Verified by search across user-bff, admin-bff, mod-bff and forum-bff:
no friend/follow/contact table, column, or endpoint exists — the only matches
are prose ("`ForumDto` and friends") and unrelated identifiers. The closest
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
user-bff and the UIs already defer to — not re-implemented per surface.

## The `channels` approximation

`channels` is enforced today as "any ROLE_MESH caller in the same domain",
which is *broader* than its stated meaning ("members of the mesh-enabled rooms
this radio participates in"). Tightening it needs a room-membership check
against the homeserver for the rooms a device's traffic actually reaches — the
same class of homeserver-read problem as option A above, and worth solving
once, for both. Until then the UI copy should not over-promise: say
"others on your mesh" rather than "only people in your channels".

## Definition of done

- one authoritative predicate in mesh-bff, consumed (not duplicated) by
  user-bff and both UIs;
- a real relation behind `friends` per the decision above;
- the `channels` room-membership tightening;
- tests covering the matrix of {owner, friend, same-domain stranger,
  cross-domain stranger} × {private, friends, channels}, asserting that each
  non-owner sees *anonymous* rather than *attributed* where not permitted;
- UI copy updated to match whatever the levels actually mean once enforced.
