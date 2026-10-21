"""The seven words of the brand model, each with one meaning (hugmesh-generator#654, D1).

Every window page, text screen and printed plan that talks about brands reads its
words from THIS table, and docs/BRAND-MODEL.md carries the same table in prose.
studio/tests/test_brand_record_words.py checks the two are equal, so a screen cannot
quietly start calling the same thing by a second name.

Why a table and not a comment: the survey behind #654 found 'brand' already meant a
build id, a make profile name, a tenant row, a runtime tenant key, a Vault path
segment, a look and a GitOps tree. Nothing short of one place that every reader
imports keeps the eighth meaning out.

Qt-free, stdlib only. Nothing here formats a sentence for a particular widget: the
screens do that, with these words.
"""
from __future__ import annotations

__all__ = [
    "WORDS", "WORD_KEYS", "SIGN_IN", "LOOK_SOURCE", "PATHS", "WAYS", "WAY_EFFECT",
    "FORBIDDEN_ON_SCREENS", "term", "meaning",
]

#: (key, the term as a screen writes it, its one meaning). Order is the order the
#: document lists them in.
WORDS: tuple[tuple[str, str, str], ...] = (
    ("superbrand", "superbrand",
     "the mesh's one governing brand: its id, title, organisation, public name, "
     "internal root name and central sign-in, plus the default look and the default "
     "ways to reach it that every brand starts from"),
    ("brand", "brand",
     "one named identity under the superbrand: a public name, a title, a look and "
     "ways to reach it (a Domain row in the code; the record calls the list brands "
     "and the manifest keeps the key domains)"),
    ("sign_in", "sign-in",
     "where a brand's people sign in: through the superbrand (same people, same "
     "admins, not separate) or with its own sign-in (its own people and admins, "
     "separate)"),
    ("ways", "ways to reach a brand",
     "an internal name on the mesh's own network, a Tor address, or a public name "
     "through a provider"),
    ("internal_root", "internal root name",
     "the name every node of the mesh joins under on its own network (the builders "
     "call it --superdomain; screens never say superdomain)"),
    ("go_live", "Go live",
     "start the Tor addresses; it opens no public port"),
    ("open_ports", "Open public ports 80 and 443",
     "what the old public flip does: open this computer's web ports to the "
     "internet, for every brand on it at once"),
)

WORD_KEYS: tuple[str, ...] = tuple(k for k, _t, _m in WORDS)

#: Domain.idp value -> the sentence a screen shows beside a brand's sign-in.
SIGN_IN: dict[str, str] = {
    "superdomain": "signs in through the superbrand (same people, same admins, "
                   "not separate)",
    "own": "has its own sign-in (its own people and admins, separate)",
}

#: Where an effective look value comes from (D7).
LOOK_SOURCE: dict[str, str] = {
    "inherited": "inherited from the superbrand",
    "own": "this brand's own",
    # the superbrand's own row: its value IS the default (the shipped page where empty)
    "default": "the superbrand's default",
}

#: The three start paths a way is applied on, in the order the screens list them.
PATHS: tuple[tuple[str, str], ...] = (
    ("docker", "Docker mesh"),
    ("kind", "kind cluster"),
    ("image", "node image"),
)

#: The three ways to reach a brand, in the order the screens list them.
WAYS: tuple[tuple[str, str], ...] = (
    ("internal_name", "internal name"),
    ("tor", "Tor address"),
    ("public", "public name through a provider"),
    ("tailnet", "VPN (the mesh's private network)"),
    ("egress", "outbound traffic (egress)"),
)

#: (way, path) -> what that path DOES with the recorded choice today (D10). These are
#: the sentences show-record prints; a path that only records a choice says so.
WAY_EFFECT: dict[tuple[str, str], str] = {
    ("internal_name", "docker"):
        "recorded; not served yet (this mesh has no tailnet name service)",
    ("internal_name", "kind"):
        "recorded; not served yet (the cluster runs no tailnet name service)",
    ("internal_name", "image"):
        "recorded; not served yet (one headscale record per brand is a later lane)",
    ("tor", "docker"):
        "applied: with Tor on, starting the mesh makes this brand's Tor address and "
        "tells the gateway which sign-in it opens",
    ("tor", "kind"):
        "applied per brand through the kind Tor step once the cluster is up",
    ("tor", "image"):
        "baked: an image built with Tor on starts its Tor service at first boot, and "
        "the address is live whenever that service runs (hugmesh-go-live); no image "
        "holds it until Go live today",
    ("public", "docker"):
        "recorded only: this mesh has no public name; nothing here applies this yet",
    ("public", "kind"):
        "recorded only: this cluster has no public name; nothing here applies this yet",
    ("public", "image"):
        "baked into the plan the Go-Live wizard reads on the device; opening public "
        "ports applies to the whole computer",
    # per-domain VPN membership and egress (core/domain_reach): recorded on every path,
    # applied on none yet — each mesh joins ONE private network and runs ONE egress
    ("tailnet", "docker"):
        "recorded only: this mesh joins its private network as a whole (production "
        "only); nothing here applies a per-brand choice yet",
    ("tailnet", "kind"):
        "recorded only: the cluster joins no private network; nothing here applies "
        "this yet",
    ("tailnet", "image"):
        "recorded only: a node joins its mesh's private network as a whole; no "
        "builder reads a per-brand choice yet",
    ("egress", "docker"):
        "recorded only: this mesh runs one egress for all its brands; nothing here "
        "applies a per-brand choice yet",
    ("egress", "kind"):
        "recorded only: the cluster has no egress VPN; nothing here applies this yet",
    ("egress", "image"):
        "recorded only: an image's egress VPN covers the whole computer; no builder "
        "reads a per-brand choice yet",
}

#: Words a brand screen never shows (D1). Exported for the screen lanes and their
#: walks; the word guard does not grep today's screens for them, because screens
#: this lane does not own still say some of them.
FORBIDDEN_ON_SCREENS: tuple[str, ...] = (
    "tenant", "issuer", "slug", "epoch", "generation", "residency", "capability",
)


def term(key: str) -> str:
    """The term for a word key, e.g. ``term("internal_root")`` -> 'internal root name'."""
    for k, t, _m in WORDS:
        if k == key:
            return t
    raise KeyError(f"not one of the seven words: {key!r}")


def meaning(key: str) -> str:
    """The one meaning of a word key."""
    for k, _t, m in WORDS:
        if k == key:
            return m
    raise KeyError(f"not one of the seven words: {key!r}")
