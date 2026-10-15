# The brand model: one superbrand governing its brands

This document is the one place the words of the brand model are written down
(hugmesh-generator#654, decisions D1 to D5 and D10). The Studio reads the same
words from one table, `studio/hugmesh_studio/core/plain_words.py`, and
`studio/tests/test_brand_record_words.py` checks that the table and this document
agree, so a screen cannot quietly start calling the same thing by a second name.

Every example here uses placeholders (`acme`, `mesh.example`, `example`). Nothing
specific to any real organisation belongs in this repository.

## The seven words

| Word | Meaning |
|---|---|
| superbrand | the mesh's one governing brand: its id, title, organisation, public name, internal root name and central sign-in, plus the default look and the default ways to reach it that every brand starts from |
| brand | one named identity under the superbrand: a public name, a title, a look and ways to reach it (a Domain row in the code; the record calls the list brands and the manifest keeps the key domains) |
| sign-in | where a brand's people sign in: through the superbrand (same people, same admins, not separate) or with its own sign-in (its own people and admins, separate) |
| ways to reach a brand | an internal name on the mesh's own network, a Tor address, or a public name through a provider |
| internal root name | the name every node of the mesh joins under on its own network (the builders call it --superdomain; screens never say superdomain) |
| Go live | start the Tor addresses; it opens no public port |
| Open public ports 80 and 443 | what the old public flip does: open this computer's web ports to the internet, for every brand on it at once |

The role names *domain admin* (the admin of one brand that has its own sign-in) and
*superadmin* stay, because they are the names of the roles. Brand screens never say
tenant, issuer, slug, epoch, generation, residency or capability.

## What the superbrand is at run time

The superbrand is one block of the record and the first row of every brand list. At
run time it is the tenant key `default` plus the mesh's central sign-in; that key is
stored data in every back end and is never renamed. The mesh's own Tor address
belongs to the superbrand.

A brand that signs in through the superbrand is a name, a title, a look and ways to
reach it, served as the superbrand's tenant: same people, same admins. It may still
have its own Tor address; that address leads to the superbrand's people, and only a
superadmin can switch it, because the brand has no admin of its own. A brand with
its own sign-in is separate: its own people, its own admins, its own tenant key.

## The record

One file per mesh, `brand-record.json`, in the Studio state folder
(`$HUGMESH_STUDIO_STATE_DIR`, default `~/.hugmesh/studio`), never in the shared
`brands/` checkout. Its shape (schema 1):

```json
{
  "schema": 1,
  "superbrand": {
    "id": "acme",
    "title": "Acme Mesh",
    "org": "example",
    "public_name": "mesh.example",
    "internal_root": "acme.internal",
    "central_signin": "https://id.mesh.example",
    "look": {"primary": "#112233", "font": "System UI", "style": "glass"},
    "ways": {"tor": true}
  },
  "brands": [
    {"name": "shop.mesh.example", "title": "Shop", "idp": "own", "tor": true,
     "look": {"primary": "#aa0000"}, "issuer_port": 8002,
     "ways": {"internal_name": "shop.acme.internal"},
     "images": [], "optional_services": []}
  ],
  "copied_from": {"design": "acme-blue", "date": "2026-10-14"}
}
```

Rules the writer (`core/brand_model.py`) keeps:

- **Every key that says nothing is left out**, so a record, a saved config or a
  saved mesh that uses none of the new keys keeps exactly the bytes it had before
  the keys existed. The row keys `id`, `tor`, `look`, `ways` and `issuer_port` are
  all omit-when-empty.
- **No secret.** Every save runs a scan that refuses token-shaped values (tailnet
  keys, GitHub and GitLab tokens, Slack and AWS keys, Vault tokens, JWTs, long opaque
  strings), PEM blocks, Tor key lines, and any value under a key that names a secret
  (`token_file` is a pointer and is allowed; the token itself never is). A refused
  save writes nothing.
- **No clock value.** The window and the text screens, given the same inputs, write
  the same bytes. The date a stored design was copied in is an input the caller
  hands over.
- **Migration.** A mesh manifest written before the record existed (the header keys
  and `domains`) loads as a record: its header becomes the superbrand block and its
  rows the brands, with the ids the running mesh already uses.

## The id rule

Every brand gets one id when it is added: the default is its public name with each
run of characters outside `a-z0-9` turned into one dash (`shop.mesh.example` becomes
`shop-mesh-example`). It is shown editable until the record is first saved, then
frozen. It is checked once against the strictest rule in use — a DNS label of at most
59 characters, starting and ending with a letter or digit — and refused when it is
`default` (the superbrand's run-time key), `domains` (the CA registry's file), the
superbrand's own id, the name of an existing `brands/*.conf` profile, a name ending
in `-pki` (another brand's PKI namespace), or already taken by another brand.

**What the Docker start now refuses that it accepted before.** `python3 -m
hugmesh_studio.core.local_mesh_bootstrap up` and the Studio's Docker route run these rules (with the 63-character DNS label
instead of 59, and no title rule) on any mesh that carries a superbrand block or a
domain row. A mesh that started on the old main with one of these now stops with the
reason, and these are deliberate: a superbrand id that ends in `-pki` (it would be
confused with another brand's PKI namespace), a superbrand or brand id of `default` (the
run-time key of every back end) or `domains` (the CA registry's file), two brands that
derive the same id, and a brand id that names an existing `brands/*.conf` profile
(`make BRAND=<id>` would source that file). The superbrand's own id may name a profile:
it is usually that very profile.

The id is the same text as the registry's namespace prefix, the tenant key of a
brand with its own sign-in, the Tor key-folder name, the brand column of the
certificate list and the Vault path segment. Today one consumer still derives it:
the Docker mesh's stack node (`core/local_stack_node.py`) hands `own_casdoor` the
brand names only, so its tenant keys and compose services come from the name while
the Tor key folder (`domain_services.onion_slug`) reads the stored id. A stored id
that differs from the derived one would therefore mint an onion for a tenant the
gateway never registers, and the record **refuses it** (`brand_model.stored_id_problem`)
until that file passes the record's ids — `own_casdoor.tenancy_env` and
`compose_overlay` already take an `ids` mapping. Until then every consumer derives
the same text, which is the one-id rule kept the only way it can be kept today.

A brand with its own sign-in has its sign-in port stored in the record
(`issuer_port`); the stored port is what `issuer_ports` keeps when a brand is removed
or reordered. The Docker mesh does not read it yet: the stack node still publishes
Casdoor by table position (`own_casdoor.port_for`), so `show-record` prints both
numbers when they differ ("sign-in port 8002 recorded — the Docker mesh still
publishes it at 8001") and the plan says the same under the own-sign-in list. The
stored port becomes the published port when the stack node passes
`brand_model.issuer_ports(record)` to `own_casdoor`, which already accepts it. The
test-only `BRAND_B` knob owns port 8001, so `issuer_ports(record, brand_b=True)`
allocates from 8002; nothing passes that flag yet (the stack node does not read
`BRAND_B`), so today the Studio's brands start at 8001 whether or not brand B runs.

## The look: inherit, then override

The superbrand's `look` holds the default for eight fields: `primary`, `secondary`,
`preset`, `mode`, `font`, `style`, `decor`, `bg_effect`. A brand's `look` holds only
the fields it changes. `brand_model.effective_look` resolves a brand's look field by
field and says where each value comes from — "inherited from the superbrand" or
"this brand's own". An unknown field or an unknown value is refused on save. The
sign-in page's shape and menu decoration are the look's `style` and `decor` and
nothing else: the image config's `login_style`/`login_decor` and the manifest header's
keys of the same name are projections of those two look fields, so `show-record`, the
image config and the manifest cannot read different values for one thing.

## The ways to reach a brand

Each brand records how it is reached once, through one function,
`brand_model.set_ways`: an internal name (default `<id>.<internal root name>`), a Tor
address (yes or no — the row's `tor` field, the same field the manifest, the Docker
mesh and the builders read), and a public name through a provider (the provider, its
non-secret inputs, and a pointer to the file that holds its token). The Go-Live
wizard is the one editing home for all of it; the mesh page's Tor switch writes the
same field through the same function. The superbrand's own Tor address is
`superbrand.ways.tor`, and `up --record` / `plan --record` start the mesh with Tor on
or off from it: a `--with-tor` or `--services` flag that says the opposite is a
contradiction and is refused with the reason, never quietly overridden, so the mesh
`show-record` describes is the mesh that starts. A record without the key leaves the
flags as they were.

What each start path does with a recorded way today is printed by `show-record` and
held in `plain_words.WAY_EFFECT`. In short: the Tor choice is applied on the Docker
mesh (with Tor on) and per brand on the kind cluster; an image built with Tor on
starts its Tor service at first boot and its address is live whenever that service
runs (`hugmesh-go-live` says so) — no image holds it until Go live today; the
internal name is recorded and not served yet; a public name is recorded only on the
Docker mesh and the kind cluster, and baked into the plan the Go-Live wizard reads
on a device.

**The production hold (D14) is not built yet.** D14 holds a production Docker mesh's
Tor addresses until Go live through the Makefile knob `TOR_HOLD=1`, which the Studio
passes to `make stack-up` for a production mesh with Tor on whose Go live was not
pressed (`--tor-release` says it was). The Makefile's side belongs to the
docker-mesh-tor lane and does not exist today: `make stack-up TOR=1` starts
`hugmesh-tor` on every env. The Studio measures this
(`LocalMeshBootstrap.makefile_holds_tor`, a word-match on `TOR_HOLD` in the
Makefile) and the confirm-before-run plan says which is true: "HELD … until Go live"
only when the knob is read, otherwise "NOT HELD YET: this production mesh publishes
its Tor address at start". `studio/tests/test_brand_record_cli.py` pins the sentence
to the real Makefile, so it flips the day the hold lands.

## What is written from the record

- **The mesh manifest** is a projection: `superbrand.id` is the manifest's `brand`,
  the internal root name its `superdomain`, `brands` its `domains`. Both manifest
  writers (`ImageConfig.mesh_manifest` and `WorklistDriver.manifest_v2`) call the
  same two functions, so they cannot disagree.
- **The Docker mesh**: `python3 -m hugmesh_studio.core.local_mesh_bootstrap up --record FILE`
  starts a mesh from a record (the record decides the brand, the public name, the brands and their
  sign-ins, and whether the mesh starts with Tor on; every other flag still
  applies), and `show-record --record FILE` prints
  every brand's effective look with the source of each value and the effect of each
  way on each path, in the words above, from a fresh process. Without a record file
  both read the flags, in the order given: two own sign-ins named `zed` then `alpha`
  get ports 8001 and 8002 in `show-record`, in the plan and on the running mesh alike.
  The Docker start runs the record's id, duplicate, look, ways and secret checks
  (`record_problems(…, docker_start=True)`) but not the title rule, and allows the
  bootstrap's 63-character label: a title is written into no sourced file on this
  path, so a mesh that started before the record existed — a brand titled "Bob's
  Shop", a 61-character brand — still starts. The record file and the generated
  profile keep the strict rule at their own write. The window and the text screens
  follow the same split: the design of a superbrand on the Docker route is checked the
  way the start checks it, so a brand row titled "Bob's Shop" never blocks it; when the
  record FILE is then refused, the page says "The brand record file was not written"
  and that the mesh itself still starts (in the window, under the drop-down and on the
  plan; in the text screens, on the status line).
  A **test mesh has no public name**: a record saved from a test design carries no
  public name and no central sign-in address (the start derives both), so it cannot
  start a production plan on the placeholder apex. A record's public name that differs
  from an explicit `--cluster-domain` is a contradiction, refused like a Tor
  disagreement.
- **The image builders**: a generated shell profile
  (`python3 -m hugmesh_studio.core.brand_model profile --record FILE --out PROFILE`).
  Every value is single-quoted and limited to letters, digits, space and
  `. _ : / @ + , = -`; the Studio re-parses the file strictly before any builder
  sources it, and a title such as `$(touch /tmp/x)` is refused, so no file is written
  and nothing can run. A record that `validate` refuses (a reserved or duplicate id,
  a secret-shaped value) writes no profile either. A branding folder (`brand.conf`
  in the strict `KEY="VALUE"` form the desktop applier reads without sourcing) is
  written the same way.
- **Key generation** on the image path is given the brand and the internal root name
  (`BRAND` and `--superdomain`), so a node's `provision.json` names the root the
  images were built for.
- **The saved mesh** embeds the bootstrap config, and so the record.

## The superbrand store

A superbrand design can be kept in the Studio state folder under `superbrands/`. A
design is the part of a superbrand one would reuse on another mesh: its title,
organisation and look (`brand_model.DESIGN_KEYS`); the fields that name a mesh (id,
public name, internal root name, central sign-in) and its ways are never stored in a
design and never overwritten by one. Choosing a design **copies** those three into
the mesh record and notes "copied from design X on <date>"; the record never refers
back to the store, and editing the stored design later changes no existing mesh.

## The copy sites

A brand row used to be copied by hand-written key lists in about ten places, and
each dropped a key it did not know. They are listed by name in
`brand_model.COPY_SITES`, every one now copies by the field list, and
`studio/tests/test_brand_record_copy_sites.py` drives one row through all of them and
back (image config, local mesh, saved mesh, image config again, fleet), then deletes a
key at each site in turn and shows the round trip go red.

The window's Domains table (`gui/pages/domains.py`, `DomainsTableBody.rows`, which the
Docker mesh page's `_commit_domains` also uses) has no cell for a brand's `id`, `look`,
`ways`, `issuer_port` or Tor choice, so it carries each of those by name from the
config's row. A Next through the table keeps them; `test_a_next_through_the_table_keeps_each_brands_id_look_ways_and_port`
shows it red when the table builds a row from its cells alone.

## The unaffiliated rule

An unaffiliated image refuses brand identity and allows a look. The record writer is
the fourth place that enforces it: no superbrand title, organisation or id and no
brands on an unaffiliated image; its look is allowed.

## Not in this document on purpose

What the brand screens look like, the design step, the Go-Live wizard's pages, the
console's Tor addresses screen and the new-address flow are other lanes of the same
design. Nothing here is proven on a live mesh: the record, its projections and the
generated profile are checked offline.
