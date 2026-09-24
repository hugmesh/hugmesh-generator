"""Local Docker mesh — FROM-SCRATCH superadmin bootstrapper.

Extends the fourth first-screen choice ("Local Docker mesh") from a JOIN-only flow
(core/local_mesh.py: LocalMeshNode joins an existing tailnet with a provided
TS_AUTHKEY) into a *generate-and-start-a-new-mesh-from-scratch* flow: mint ALL
platform credentials locally, bring up the FULL platform stack seeded with a fresh
superadmin identity, and (in prod) attach the tailscale overlay.

Design split (mirrors local_mesh.py's LocalMeshConfig/LocalMeshNode,
local_stack_node.py's LocalStackNode, and golive_driver.py's driver/options):
  - ``LocalMeshBootstrapConfig`` — the pure-data knobs the operator provides.
  - ``LocalMeshBootstrap`` — the orchestrator. It forks NO new local-mesh mechanism:
    it COMPOSES the three EXISTING pieces —
      1. the gen scripts (scripts/gen-cluster-secrets.sh + gen-provision-keys.sh),
      2. ``LocalStackNode`` (make stack-up / stack-seed / stack-down),
      3. ``LocalMeshNode`` (the #340 tailscale overlay) —
    adding NO compose invocation of its own.

Two mutually-exclusive paths surface in ONE place (the GUI LocalMeshDialog, the
ncurses menu, and this module's CLI):
  - JOIN (core/local_mesh.py, unchanged): LocalMeshConfig -> LocalMeshNode.start()
    with a provided TS_AUTHKEY.
  - BOOTSTRAP-FROM-SCRATCH (this module): generate creds -> full platform stack
    seeded with the minted superadmin -> optionally attach the mesh overlay.

Non-destructive by default: NOTHING is generated or started on mere selection.
``plan()`` is pure/side-effect-free (the confirm-before-run manifest); only the
explicit ``up`` action mints creds + starts containers. It is host-local (docker on
the operator's own machine) and refuses to run inside a cluster pod.

This module NEVER touches ImageConfig / to_cli_args() / the mesh manifest — a local
bootstrap builds no image, so it emits nothing into the builder argv the
build-matrix guards (the same non-image side-flow discipline as #340).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from dataclasses import asdict, dataclass, fields
from typing import NamedTuple

from . import own_casdoor, theme
from .config import IDP_CHOICES, IDP_LABELS, _IDP_CLIENT_ID_RE, _IDP_URL_RE, \
    idp_effective_jwks
from .local_mesh import ENV_AUTHKEY, LocalMeshConfig, LocalMeshNode
from .local_services import (
    FEDERATION_DISABLE_ENV, FEDERATION_ENABLE_ENV, PROFILE_AKKOMA, PROFILE_ANUBIS,
    PROFILE_EDGE_AI_TTS, PROFILE_EGRESS_VPN, PROFILE_GAMES, PROFILE_PHPBB,
    PROFILE_SOCIAL, PROFILE_TOR,
    by_slug as by_local_slug, federation_env, federation_selection,
    federation_slugs, local_slugs, profile_flags, profile_slugs, validate_selection,
    PROFILE_MEDIA_POISONER, KIND_LANE_LABEL, kind_slugs,
)
from .egress_conf import validate_egress_conf
from .local_stack_node import M2_BOOTSTRAP_HINT, LocalStackNode
from .mesh_node import MeshNode

# The two credential generators (repo-relative). Reused VERBATIM via subprocess
# (like MeshNode shells `docker compose` and golive shells its driver) — this module
# NEVER reimplements secret generation.
GEN_CLUSTER_SECRETS = "scripts/gen-cluster-secrets.sh"
GEN_PROVISION_KEYS = "scripts/gen-provision-keys.sh"

# The env-var NAME seed-e2e.sh resolves the ROLE_SUPERADMIN persona's password from
# (its persona spec is `<user>:ROLE_SUPERADMIN:E2E_SUPERADMIN_PASSWORD` — the third
# field is a var NAME, not the value). Bridging the minted password in under this name
# provisions the running platform's ROLE_SUPERADMIN with it.
SEED_SUPERADMIN_PASSWORD_ENV = "E2E_SUPERADMIN_PASSWORD"

# The env-var seed-e2e.sh reads for the ROLE_SUPERADMIN persona's LOGIN NAME. seed-e2e
# defaults it to `e2e-superadmin` (so ordinary e2e runs are unchanged), but the
# bootstrap bridges the minted/advertised username in under it so the seeded login
# matches the plan, the log, and the minted secrets.json — otherwise the operator
# would be told to log in as a username the running stack never created.
SEED_SUPERADMIN_USERNAME_ENV = "CASDOOR_SUPERADMIN_USERNAME"

# Default brand + its apex domain (mirrors gen-cluster-secrets.sh's own defaults).
DEFAULT_BRAND = "hugmesh"
DEFAULT_DOMAIN = "hugmesh.net"

# A BCP-47-shaped locale tag: a primary subtag plus optional script/region subtags
# (e.g. de, fr, pt-BR, zh-Hant, en-XA). Deliberately lenient on SHAPE only — the
# authority on whether a catalog EXISTS is the login-ui build, which fails loudly
# on a requested locale with no messages.<locale>.xlf. Validating existence here
# would invent a constraint this config cannot honestly check (the login-ui repo
# is not cloned until `make stack-clone`).
_LOCALE_RE = re.compile(r"^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$")

_REPO_ROOT = os.path.abspath(
    os.path.join(os.path.dirname(__file__), os.pardir, os.pardir, os.pardir))

# BRAND is a Vault path segment AND a dot-sourced profile selector (brands/<BRAND>.conf).
# Mirror scripts/gen-keystores.sh:45-53's DNS-label gate EXACTLY — that script hard-errors
# and refuses to source the profile for a non-label BRAND, so we BLOCK the same shape (and
# no stricter). A value like `../../evil` would otherwise select an arbitrary shell file.
_BRAND_DNS_LABEL = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")

# brands/domains.conf is a MULTI-DOMAIN CA registry (its own header :1-8 says so), not a
# brand profile — never offer it as a brand slug.
_NON_BRAND_CONF = frozenset({"domains"})

# The `context:` values compose.local.yaml resolves are ${STACK_SRC:-…}/hugmesh-<name>.
# Parse the repo dir name straight out of the consumer file so the "expected build context"
# set cannot drift from what `docker compose build` will actually resolve.
_CONTEXT_RE = re.compile(r"\$\{STACK_SRC[^}]*\}/(hugmesh[A-Za-z0-9._-]+)")
_COMPOSE_LOCAL = os.path.join("tests", "stack", "compose.local.yaml")


def _tail(msg: str, limit: int = 600) -> str:
    """The LAST ``limit`` chars of a command's captured output — never the first.

    Every `make stack-*` recipe prints its banner and then the whole clone/build
    transcript BEFORE anything fails, so a head slice reports "==> Cloning 24
    HugMesh repos into …" and hides the one line that says what actually broke.
    That is not hypothetical: a live bring-up failure surfaced in the GUI as the
    clone banner while the real cause ("unable to prepare context: path
    …/.stack-src/hugmesh-remote-fragment not found") sat ~40 lines further down,
    off the end of the slice. The tail always carries the failure. An ellipsis
    marks a truncated head so the reader knows output was dropped."""
    msg = (msg or "").strip()
    return msg if len(msg) <= limit else "…" + msg[-limit:]


def discover_brands(generator_dir: str) -> list[str]:
    """Brand slugs with a real shell profile at brands/<slug>.conf — the ONLY files
    gen-cluster-secrets.sh:36-38 and the builders ever source. DEFAULT_BRAND leads even
    though it has NO .conf: the `-f` guard silently skips a missing profile, and that is
    exactly what the CLI's ``--brand`` default resolves to (brands/README.md documents
    ``.conf`` as the profile form). Deliberately does NOT offer ``acme`` (only acme.yaml
    exists — a tenant-set manifest for the render path, a DIFFERENT catalog with a
    DIFFERENT consumer) nor ``domains`` (a CA registry, see _NON_BRAND_CONF)."""
    brands_dir = os.path.join(generator_dir, "brands")
    slugs: set[str] = set()
    try:
        for name in os.listdir(brands_dir):
            if name.endswith(".conf"):
                slug = name[: -len(".conf")]
                if slug and slug not in _NON_BRAND_CONF:
                    slugs.add(slug)
    except OSError:
        pass
    slugs.discard(DEFAULT_BRAND)
    return [DEFAULT_BRAND] + sorted(slugs)


def expected_build_contexts(generator_dir: str) -> list[str]:
    """The repo directory names ``docker compose build`` will resolve as build contexts,
    parsed from the ${STACK_SRC:-…}/hugmesh-<name> ``context:`` values in
    tests/stack/compose.local.yaml. Derived from the file compose ACTUALLY reads, so it
    cannot drift from what a build resolves (deriving from clone-all-repos.sh's REPOS
    would drift — the two sets differ). Sorted + de-duplicated (hugmesh-gateway
    appears 3x — one image, three service roles)."""
    path = os.path.join(generator_dir, _COMPOSE_LOCAL)
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except OSError:
        return []
    return sorted(set(_CONTEXT_RE.findall(text)))


def _domain_record(x: dict) -> dict:
    """One recorded domain row, coerced to its JSON shape (str fields, a list of str
    slugs) — see ``LocalMeshBootstrapConfig.domains``."""
    svcs = x.get("optional_services") or ()
    return {"name": str(x.get("name") or "").strip(),
            "title": str(x.get("title") or "").strip(),
            "idp": str(x.get("idp") or "superdomain"),
            "optional_services": [str(s) for s in svcs] if isinstance(svcs, (list, tuple)) else []}


@dataclass
class LocalMeshBootstrapConfig:
    """Operator-provided knobs for minting + starting a from-scratch local mesh.

    ``env`` ("test"|"prod") threads to BOTH creds and stack, matching the
    platform-wide ENV knob:
      - test (DEFAULT, LAN-only/safe): issuer http://localhost:8000, brand-default
        domain, no public DNS/OAuth/SMTP, mesh overlay SKIPPED (no tailnet needed).
      - prod: real public domain (``cluster_domain`` REQUIRED) -> issuer
        https://id.<domain>; the mesh overlay attaches (``auth_key`` REQUIRED).

    ``out_dir`` is the RUNTIME creds dir (default the gitignored ``keys-out/``); the
    minted secrets land under ``<out_dir>/vault`` + ``<out_dir>/keys`` at runtime
    only — never committed. ``auth_key``/``login_server``/``node_name`` are only
    used (and only required) on the prod overlay path."""
    env: str = "test"
    superadmin_username: str = "superadmin"
    out_dir: str = ""
    social: bool = False
    # Publish the local mesh's fe-gateway as a Tor v3 .onion (the OPT-IN `tor`
    # compose profile — docs/TOR-HIDDEN-SERVICE.md). DEFAULT off; when on, the
    # from-scratch bring-up also starts the hugmesh-tor service and up() reports
    # the minted .onion address. Mirrors the NODE `tor` optional service, scaled to
    # the local docker mesh; reachability is over Tor, with no public IP/DNS/ports.
    with_tor: bool = False
    # WHICH individual services the local mesh runs (core/local_services.py's
    # catalogue slugs). Two mechanisms behind one list: the compose-profile slugs
    # (`tuwunel` -> the social profile, `tor`) start/stop containers at bring-up,
    # the federation slugs (wiki/owncast/tube/character-*) flip their
    # federation_modules.enabled row at seed time on a stack whose containers are
    # already up regardless.
    #
    # DEFAULT None means "no picker was ever used": profiles then come from the
    # legacy `social`/`with_tor` booleans exactly as before, and NOTHING federation-
    # shaped is exported, so the whole from-scratch path stays byte-identical for
    # every existing caller (the CLI, the ncurses menu, the tests that construct this
    # config positionally). A tuple — even an empty one — is an EXPLICIT selection and
    # becomes authoritative for BOTH mechanisms; the GUI always sends one, and keeps
    # `social`/`with_tor` in lock-step because its social/tor rows ARE those two
    # checkboxes (one widget, never a second copy that can disagree).
    services: tuple[str, ...] | None = None
    # The VPN provider conf backing an `egress-vpn` selection (WireGuard .conf or
    # OpenVPN .ovpn — core.egress_conf validates both with the container's own
    # sniff rules). REQUIRED whenever the egress-vpn slug is selected: validate()
    # blocks the up and the page unchecks the box rather than leave it lying
    # (operator ask 2026-08-14 — fail-closed at every layer).
    egress_vpn_conf: str = ""
    auth_key: str = ""
    login_server: str = ""
    node_name: str = ""
    brand: str = DEFAULT_BRAND
    cluster_domain: str = ""
    # WHERE the buildable repo source comes from:
    #   "clone"    — TODAY'S behaviour: `make stack-clone` downloads all repos into
    #                ./.stack-src, then compose builds from there. source_dir ignored.
    #   "existing" — build from a tree the operator already has (STACK_SRC=<source_dir>),
    #                and SKIP the clone (STACK_NO_CLONE=1) so it is never git-reset.
    # DEFAULT "clone" + empty source_dir == zero regression: LocalStackNode._build_env()
    # sets nothing new, STACK_SRC stays unset, the Makefile's own default resolves as now.
    source_mode: str = "clone"
    source_dir: str = ""
    # Translation catalogs the login-ui image is BUILT with. EMPTY (the default) =
    # English-only: the image ships zero catalog files and the browser issues zero
    # catalog requests — the smallest artifact, and no i18n network surface at all
    # on the LAN-only/offline test path this config defaults to.
    #
    # This is a CLUSTER-plane fact, not desktop theming: the web login is served to
    # browsers by the mesh, so it is NOT scoped to x86 and does NOT belong with
    # brand_logo/color_scheme/login_background (all _X86, all desktop-class
    # surfaces a mesh node never carries). It lives here, on the config that
    # actually brings up the stack that BUILDS the login-ui image.
    web_locales: tuple[str, ...] = ()
    # ALREADY-DERIVED snap-theme.css text for the login-ui (studio core/theme.py is
    # the single derivation; GUI/CLI compose it, this config only CARRIES it). Like
    # web_locales this is cluster-plane web-login data, not desktop theming — but
    # unlike web_locales it is RUNTIME: compose passes it as the HUG_THEME_CSS env
    # and the login-ui entrypoint writes snap-theme.css at container start, so a
    # rebrand needs no image rebuild. EMPTY = shipped default brand, byte-identical.
    login_theme_css: str = ""
    # ── identity provider (I6.6 — the SAME picker the node wizard carries) ──
    # "casdoor" (the DEFAULT) threads NOTHING: the stack env stays byte-identical
    # to before these fields existed (the #1 invariant). An external provider
    # threads OIDC_ISSUER / OIDC_CLIENT_ID / OIDC_JWKS_URI into the `make stack-*`
    # env (env vars ONLY), and the Makefile CONSUMES all three (the Lane-B seam,
    # landed): OIDC_ISSUER -> CASDOOR_ISSUER_URI, OIDC_CLIENT_ID ->
    # CASDOOR_APP_CLIENT_ID (the BFF login/exchange client id), OIDC_JWKS_URI ->
    # CASDOOR_JWKS_URI (gateway + resource-server key fetch). So the running
    # local stack really does VALIDATE tokens against the external issuer/JWKS.
    # HONEST LIMIT, narrowed but real: validation is the only leg that moves —
    # native /bff/login, MFA step-up and role claims stay Casdoor-coupled
    # (docs/IDENTITY-PROVIDERS.md "Honest limits"), and stack-seed still seeds
    # the in-stack Casdoor, so there is no full external login ROUND-TRIP in the
    # test stack. plan() says so out loud instead of overclaiming.
    idp: str = "casdoor"               # IDP_CHOICES: casdoor | entra | aws | oidc
    idp_issuer: str = ""               # external OIDC issuer (https://…)
    idp_client_id: str = ""            # external OIDC client id (public, not a secret)
    idp_jwks: str = ""                 # external JWKS URL ("" = per-provider derivation)
    # ── per-domain OWN Casdoor (issue #47) — names of the domains whose
    # Domains-table row picked idp='own' (ImageConfig.own_idp_domains()), in
    # table order. EMPTY (the default — and every pre-#47 caller, this field is
    # appended so positional construction is unchanged) threads NOTHING: the
    # stack env and compose model stay byte-identical. Non-empty, LocalStackNode
    # stands up one Casdoor (+ postgres) per name the way compose.brand-b.yaml
    # proves (host ports 8001+, issuer http://casdoor-<slug>.localtest.me:<port>)
    # and threads the gateways' multi-issuer registry — see core/own_casdoor.py.
    own_idp_domains: tuple[str, ...] = ()
    # ── the DOMAINS this mesh serves, as RECORDED by the Studio's Domains step
    # (#494; core/local_mesh_domains.bootstrap_domain_records). One JSON-shaped row
    # per domain: {"name", "title", "idp", "optional_services"}. Every added domain
    # is here; the mesh's OWN domain (cluster_domain / brand default) only when it
    # says something the rest of this config does not — a title, an own sign-in or
    # a per-domain selection — so an untouched flow records () and stays
    # byte-identical to a config from before the field existed. ``own_idp_domains``
    # above is what the compose lane CONSUMES (derived from the same rows); this
    # tuple is what the saved-mesh record and the plan carry. The per-domain
    # ``optional_services`` are recorded and NOT enforced on this lane: the compose
    # profiles come from ``services`` (the mesh-wide Services step).
    domains: tuple[dict, ...] = ()
    # WHICH of the recorded ``domains`` rows had been through the Studio's Domain
    # services step when this config was collected (#494 fix round). A saved-mesh
    # Start/Restore gates on THE RECORD's rows (never the form's draft), and a record
    # can be written from a form holding un-walked rows (Save mesh records the page's
    # config) or by the CLI (``own_idp_domains`` with no rows at all), so "the row is
    # in the record" is not evidence it was reviewed; this is. Only names that are
    # also in ``domains`` are ever collected, so an untouched flow records () —
    # byte-identical env, argv and plan (the to_dict key set grows by one, as it did
    # for ``domains``). The mesh's own domain, when it is not a recorded row, is the
    # implicit cluster default and is never asked about on a saved start.
    domain_services_reviewed: tuple[str, ...] = ()
    # WHICH infra Applications the DEVOPS (kind) lane adds to its curated set
    # (core/local_services.KIND_ADDONS slugs). A SEPARATE axis from `services`:
    # these are Kubernetes Applications, they have no compose profile and no
    # federation row, and the docker bring-up ignores them entirely.
    #
    # DEFAULT None means "no picker was used" and exports nothing, so
    # `make kind-up` runs byte-identically to before this axis existed. An EMPTY
    # tuple is an explicit "none of them" and IS exported (as the literal `none`) —
    # see local_services.kind_addon_env for why those two must not collapse.
    kind_addons: tuple[str, ...] | None = None

    def is_prod(self) -> bool:
        return self.env == "prod"

    # ── services selection -> the two back-ends ─────────────────────────────────
    def effective_social(self) -> bool:
        """Whether the `social` compose profile comes up. An explicit services
        selection decides it (the picker's Matrix row IS the social switch — one
        profile, six containers); with no selection the legacy flag still rules, so
        every pre-picker caller behaves exactly as it did."""
        if self.services is None:
            return self.social
        return profile_flags(self.services).get(PROFILE_SOCIAL, False)

    def effective_with_tor(self) -> bool:
        """Same rule as effective_social(), for the `tor` profile."""
        if self.services is None:
            return self.with_tor
        return profile_flags(self.services).get(PROFILE_TOR, False)

    def effective_phpbb(self) -> bool:
        """Same rule again, for the `phpbb` profile (PHPBB=1 -> STACK_ALT_PROFILE).

        No legacy flag to fall back on: unlike social/tor these slugs never had a
        pre-picker boolean, so with NO selection they are simply off — which keeps a
        pre-picker caller's stack byte-identical to before these profiles existed."""
        if self.services is None:
            return False
        return profile_flags(self.services).get(PROFILE_PHPBB, False)

    def effective_akkoma(self) -> bool:
        """Same rule, for the `akkoma` profile (AKKOMA=1 -> STACK_ALT_PROFILE)."""
        if self.services is None:
            return False
        return profile_flags(self.services).get(PROFILE_AKKOMA, False)

    def effective_games(self) -> bool:
        """Same rule, for the `games` profile (GAMES=1 -> STACK_GAMES_PROFILE).
        No legacy flag, like phpbb/akkoma: with no selection it is simply off."""
        if self.services is None:
            return False
        return profile_flags(self.services).get(PROFILE_GAMES, False)

    def effective_anubis(self) -> bool:
        """Same rule, for the `anubis` profile (ANUBIS=1 -> STACK_ALT_PROFILE)."""
        if self.services is None:
            return False
        return profile_flags(self.services).get(PROFILE_ANUBIS, False)

    def effective_tts(self) -> bool:
        """Same rule, for the `edge-ai-tts` profile (TTS=1). Threading this was
        MISSED when the row graduated (2026-08-14): the checkbox existed but
        exported nothing, so a checked box brought up no container."""
        if self.services is None:
            return False
        return profile_flags(self.services).get(PROFILE_EDGE_AI_TTS, False)

    def effective_poisoner(self) -> bool:
        """Same rule, for the `media-poisoner` profile (POISONER=1) — the AI
        media cloak. Threading this is NOT optional bookkeeping: the exact same
        link was missed for edge-ai-tts above, and the symptom is a checkbox
        that reports success and brings up nothing."""
        if self.services is None:
            return False
        return profile_flags(self.services).get(PROFILE_MEDIA_POISONER, False)

    def effective_egress_vpn(self) -> bool:
        """Same rule, for the `egress-vpn` profile (EGRESS_VPN=1 +
        EGRESS_VPN_CONF=<path> -> STACK_EGRESS_FLAGS)."""
        if self.services is None:
            return False
        return profile_flags(self.services).get(PROFILE_EGRESS_VPN, False)

    def federation_services(self) -> tuple[str, ...]:
        """The federation-mechanism half of the selection (catalogue order)."""
        return federation_selection(self.services)

    def idp_external(self) -> bool:
        return self.idp != "casdoor"

    def effective_idp_jwks(self) -> str:
        """The JWKS URL the external threading advertises (explicit override, else
        the per-provider derivation — the ONE derivation config.py owns)."""
        return idp_effective_jwks(self.idp, self.idp_issuer.strip(),
                                  self.idp_jwks.strip())

    def resolved_domain(self) -> str:
        """The apex the minted Casdoor issuer/superadmin align with. In prod the
        operator-supplied ``cluster_domain`` (or brand default); in test the brand
        default (never surfaced as a public issuer — test issuer is localhost)."""
        return (self.cluster_domain.strip() or DEFAULT_DOMAIN)

    def issuer(self) -> str:
        """The Casdoor issuer the stack derives (Makefile ENV->issuer, mirrored here
        for the plan preview only — LocalStackNode/Makefile remain the authority)."""
        if self.is_prod():
            return f"https://id.{self.resolved_domain()}"
        return "http://localhost:8000"

    # ── JSON round-trip (the saved-mesh record; core/saved_meshes.py) ──────────
    # THE TRAP these two exist to hold: ``services`` and ``kind_addons`` are
    # ``tuple | None``, and None ("no picker was ever used" — profiles come from
    # the legacy social/with_tor booleans, nothing federation-shaped is exported,
    # `make kind-up` runs byte-identically) is NOT the same as () ("the operator
    # explicitly chose none", exported as the literal `none`). None is encoded as
    # JSON null and () as [], and BOTH directions are pinned by test — collapsing
    # them silently re-enables metrics-server and flips the profile semantics.
    _TUPLE_OR_NONE_FIELDS = ("services", "kind_addons")
    _TUPLE_FIELDS = ("web_locales", "own_idp_domains", "domain_services_reviewed")
    #: tuples of JSON objects (the recorded domain rows, #494).
    _DICT_TUPLE_FIELDS = ("domains",)
    _BOOL_FIELDS = ("social", "with_tor")

    def to_dict(self) -> dict:
        """Every field, JSON-shaped. A pure serialiser: it drops NOTHING — the
        saved-mesh record is what blanks ``auth_key`` (and says so in its
        ``blanked_secrets``), so that a round-trip through this pair is exact."""
        d = asdict(self)
        for k in self._TUPLE_OR_NONE_FIELDS:
            d[k] = None if d[k] is None else list(d[k])
        for k in self._TUPLE_FIELDS:
            d[k] = list(d[k] or ())
        for k in self._DICT_TUPLE_FIELDS:
            d[k] = [dict(x) for x in (d[k] or ())]
        return d

    @classmethod
    def from_dict(cls, d: dict) -> "LocalMeshBootstrapConfig":
        """The inverse of :meth:`to_dict`: unknown keys are FILTERED (a record from
        a newer Studio must still load), every declared-str field is coerced (a
        record is JSON on a writable disk), lists re-tuple, and null/[] keep
        their distinct meanings for the two ``tuple | None`` fields."""
        if not isinstance(d, dict):
            raise ValueError("bootstrap config must be a JSON object")
        known = {f.name: f for f in fields(cls)}
        vals = {k: v for k, v in d.items() if k in known}
        for k in cls._TUPLE_OR_NONE_FIELDS:
            if k in vals:
                v = vals[k]
                vals[k] = None if v is None else tuple(str(x) for x in v)
        for k in cls._TUPLE_FIELDS:
            if k in vals:
                vals[k] = tuple(str(x) for x in (vals[k] or ()))
        for k in cls._DICT_TUPLE_FIELDS:
            if k in vals:
                # a row that is not an object is junk from a hand-edited record: it
                # is dropped (fail-closed: the mesh records nothing it cannot read)
                # rather than turned into a row with a made-up name.
                vals[k] = tuple(_domain_record(x) for x in (vals[k] or ())
                                if isinstance(x, dict))
        for k in cls._BOOL_FIELDS:
            if k in vals:
                vals[k] = bool(vals[k])
        for k, f in known.items():
            if k in vals and f.type == "str" and not isinstance(vals[k], str):
                vals[k] = "" if vals[k] is None else str(vals[k])
        # ONE AUTHORITY PER PROFILE (#579). With a services TUPLE the picker's rows are
        # what decide the social/tor profiles (effective_social/effective_with_tor), and
        # the legacy booleans are ignored — so a record whose booleans disagree with its
        # own tuple (hand-edited, or written by a page that let them drift) loads as a
        # config that says two things: `with_tor=True, services=("tuwunel",)` brings up
        # NO hugmesh-tor while every reader of the raw flag believes it does. NORMALISED
        # here, not rejected: the tuple is what the saved mesh actually ran, and
        # refusing the record would strand an operator's saved mesh over bookkeeping.
        # services=None (CLI-made, "no picker was used") keeps the booleans as the
        # authority, untouched.
        svc = vals.get("services")
        if svc is not None:
            flags = profile_flags(svc)
            vals["with_tor"] = bool(flags.get(PROFILE_TOR, False))
            vals["social"] = bool(flags.get(PROFILE_SOCIAL, False))
        return cls(**vals)


class LocalMeshBootstrap:
    """Orchestrates the from-scratch path by COMPOSING the gen scripts + LocalStackNode
    + LocalMeshNode. Lives beside LocalMeshNode and imports it — it adds NO compose
    invocation of its own (same discipline as LocalMeshNode)."""

    def __init__(self, generator_dir: str, cfg: LocalMeshBootstrapConfig | None = None):
        self.generator_dir = os.path.abspath(generator_dir)
        self.cfg = cfg or LocalMeshBootstrapConfig()

    # ---- built from a saved-mesh record (core/saved_meshes.py) -------------------
    @classmethod
    def for_record(cls, generator_dir: str, rec,
                   auth_key: str = "") -> "LocalMeshBootstrap":
        """The bootstrap a saved-mesh record describes: its OWN config (never the
        form's re-collection), plus the one field a record never carries — the
        tailnet auth key, which the caller supplies. THE seam `mesh-restore` and the
        localcloud identity import share, so a saved mesh's services selection —
        tor included — is read the same way wherever a record becomes a mesh."""
        cfg = LocalMeshBootstrapConfig.from_dict(dict(getattr(rec, "config", None) or {}))
        if auth_key:
            cfg.auth_key = auth_key
        return cls(generator_dir, cfg)

    @classmethod
    def for_checkout(cls, generator_dir: str, hostname: str | None = None):
        """``(bootstrap, record-or-None)`` for the local mesh THIS checkout drives, as
        far as anything on disk can say: the newest saved-mesh record for this
        checkout and host, else a default config (the brand default, no Tor).

        OFFLINE by contract (plain file reads — it runs in page ``initializePage``):
        the running stack is never probed. That is also its limit, stated where the
        answer is used: a record is the mesh AS SAVED, and ``capture()`` records the
        form's selection, not a docker probe of what is running (#309)."""
        from . import saved_meshes
        try:
            rec = saved_meshes.latest_for_checkout(generator_dir, hostname=hostname)
        except Exception:                                  # noqa: BLE001 — offline read
            rec = None
        if rec is None:
            return cls(generator_dir), None
        try:
            return cls.for_record(generator_dir, rec), rec
        except (TypeError, ValueError):
            return cls(generator_dir), None

    # ---- resolved runtime paths (named in the plan so the operator sees them) ----
    @property
    def out_dir(self) -> str:
        return os.path.abspath(
            self.cfg.out_dir.strip()
            or os.path.join(self.generator_dir, "keys-out"))

    @property
    def vault_dir(self) -> str:
        return os.path.join(self.out_dir, "vault")

    @property
    def keys_dir(self) -> str:
        return os.path.join(self.out_dir, "keys")

    @property
    def secrets_json(self) -> str:
        return os.path.join(self.vault_dir, "secrets.json")

    def superadmin_login(self) -> tuple[str, str] | None:
        """(username, password) of the MINTED platform superadmin from the runtime
        secrets bundle, or None when no bundle exists (terminal-seeded stack — the
        deterministic e2e defaults apply there). Read fresh each call: the bundle
        is re-minted by every from-scratch bring-up. Used to bridge the suite's
        CASDOOR_SUPERADMIN_USERNAME / E2E_SUPERADMIN_PASSWORD (subprocess env,
        never argv, never logged)."""
        try:
            with open(self.secrets_json, encoding="utf-8") as fh:
                s = json.load(fh)
            entry = s[f"{self.cfg.brand}-pki"]["casdoor-superadmin"]
            user, pw = entry["username"], entry["password"]
        except (OSError, ValueError, KeyError, TypeError):
            return None
        return (user, pw) if user and pw else None

    def overlay_will_attach(self) -> bool:
        """The mesh overlay's tailscale service REQUIRES ``${TS_AUTHKEY:?}``, so it is
        only attached when a key is supplied — the prod path. In test/LAN-only mode
        it is skipped (the from-scratch platform still comes up fully without a key)."""
        return self.cfg.is_prod() and bool(self.cfg.auth_key.strip())

    # ---- composed drivers -------------------------------------------------------
    def _stack_node(self) -> LocalStackNode:
        # In prod, thread the resolved apex as DOMAIN so `make stack-up` derives the
        # SAME Casdoor issuer (https://id.<domain>) the secrets were minted for and
        # the plan advertised — otherwise the running issuer silently defaults to the
        # brand apex. In test the issuer is localhost, so DOMAIN is left empty.
        domain = self.cfg.resolved_domain() if self.cfg.is_prod() else ""
        # social/with_tor go through the config's effective_* rules so ONE fact
        # decides each profile: the services picker when there is one, the legacy
        # flags when there is not. `services` rides separately because the stack node
        # consumes only its FEDERATION half (an env pair for `make stack-seed`) — the
        # compose half has already become these two booleans by the time it gets here.
        return LocalStackNode(self.generator_dir, env=self.cfg.env,
                              social=self.cfg.effective_social(), domain=domain,
                              services=self.cfg.services,
                              source_mode=self.cfg.source_mode,
                              source_dir=self.cfg.source_dir,
                              web_locales=self.cfg.web_locales,
                              login_theme_css=self.cfg.login_theme_css,
                              with_tor=self.cfg.effective_with_tor(),
                              with_phpbb=self.cfg.effective_phpbb(),
                              with_akkoma=self.cfg.effective_akkoma(),
                              with_games=self.cfg.effective_games(),
                              with_anubis=self.cfg.effective_anubis(),
                              with_tts=self.cfg.effective_tts(),
                              with_poisoner=self.cfg.effective_poisoner(),
                              with_egress_vpn=self.cfg.effective_egress_vpn(),
                              egress_vpn_conf=self.cfg.egress_vpn_conf.strip(),
                              idp=self.cfg.idp,
                              idp_issuer=self.cfg.idp_issuer.strip(),
                              idp_client_id=self.cfg.idp_client_id.strip(),
                              idp_jwks=self.cfg.effective_idp_jwks(),
                              own_idp_domains=self.cfg.own_idp_domains,
                              kind_addons=self.cfg.kind_addons)

    def _mesh_node(self) -> LocalMeshNode:
        return LocalMeshNode(self.generator_dir, LocalMeshConfig(
            auth_key=self.cfg.auth_key, node_name=self.cfg.node_name,
            login_server=self.cfg.login_server))

    # ---- source-tree coverage (Qt-free; drives the GUI source axis) -------------
    def expected_contexts(self) -> list[str]:
        """Repo dir names compose.local.yaml will build (see expected_build_contexts)."""
        return expected_build_contexts(self.generator_dir)

    def source_coverage(self) -> tuple[list[str], list[str]]:
        """(found, missing) expected build contexts under ``cfg.source_dir`` — only
        meaningful in 'existing' mode. found+missing == expected_contexts(). Never
        rounds up: a context counts as found only if the directory is really there."""
        expected = self.expected_contexts()
        base = self.cfg.source_dir.strip()
        if not base or not os.path.isdir(base):
            return [], expected
        found = [c for c in expected if os.path.isdir(os.path.join(base, c))]
        missing = [c for c in expected if c not in found]
        return found, missing

    # ---- brand-profile discovery (Qt-free) --------------------------------------
    def brand_conf_path(self) -> str:
        return os.path.join(self.generator_dir, "brands", f"{self.cfg.brand}.conf")

    def brand_has_conf(self) -> bool:
        """True when brands/<brand>.conf exists — the file gen-cluster-secrets.sh's
        `-f` guard sources. DEFAULT_BRAND has none, and that is correct (built-in
        defaults); this just reports the honest state rather than pretending."""
        return bool(self.cfg.brand.strip()) and os.path.isfile(self.brand_conf_path())

    # ---- guards -----------------------------------------------------------------
    @staticmethod
    def _in_cluster_pod() -> bool:
        """True when running inside a k8s pod. Bootstrapping is HOST-LOCAL (docker on
        the operator's machine) and cannot run in a cluster pod."""
        return bool(os.environ.get("KUBERNETES_SERVICE_HOST")) or \
            os.path.exists("/var/run/secrets/kubernetes.io")

    def guard_host_local(self) -> tuple[bool, str]:
        """Refuse unless this is a host-local run with docker/compose/make present.
        Reuses LocalStackNode.available() (make + compose + stack file) and, when the
        overlay will attach, MeshNode.available() (the mesh compose template)."""
        if self._in_cluster_pod():
            return False, ("Refusing to bootstrap a from-scratch mesh inside a cluster "
                           "pod — this is a HOST-LOCAL action (docker on the operator's "
                           "own machine).")
        ok, why = self._stack_node().available()
        if not ok:
            return False, why
        if self.overlay_will_attach():
            ok, why = MeshNode(self.generator_dir).available()
            if not ok:
                return False, why
        return True, ""

    def validate(self) -> list[str]:
        """Config problems that would stop an ``up`` (empty = OK). Courtesy preflight
        surfaced in the plan; ``up`` re-checks the same guards."""
        problems: list[str] = []
        if self.cfg.env not in ("test", "prod"):
            problems.append(f"ENV must be 'test' or 'prod' (got '{self.cfg.env}').")
        if not self.cfg.superadmin_username.strip():
            problems.append("Superadmin username must not be empty.")
        # BRAND — a Vault path segment + a dot-sourced profile selector. BLOCK only the
        # shapes the tool itself hard-errors on (#387): empty (BASE=${BRAND:-hugmesh}
        # would silently mean something other than the UI shows) and non-DNS-label
        # (gen-keystores.sh:45-53 refuses to source brands/<brand>.conf). A brand with no
        # .conf is NOT blocked — the tool accepts it and exits 0 (see warnings()).
        brand = self.cfg.brand.strip()
        if not brand:
            problems.append("Brand must not be empty — it is the secret/<BRAND>/ Vault "
                            "base path segment.")
        elif not _BRAND_DNS_LABEL.match(brand):
            problems.append(f"Brand '{brand}' is not a DNS label [a-z0-9-] — "
                            f"gen-keystores.sh refuses to source brands/{brand}.conf.")
        # SOURCE axis — BLOCK only where compose will certainly hard-error.
        sm = self.cfg.source_mode
        if sm not in ("clone", "existing"):
            problems.append(f"source_mode must be 'clone' or 'existing' (got '{sm}').")
        elif sm == "existing":
            sd = self.cfg.source_dir.strip()
            if not sd:
                problems.append("Building from an existing tree needs a directory — "
                                "an empty STACK_SRC would silently fall back to the "
                                "Makefile default and build the WRONG tree.")
            elif not os.path.isdir(sd):
                problems.append(f"Source tree not found: {sd} — compose hard-errors on "
                                f"a missing build context.")
            else:
                found, _missing = self.source_coverage()
                if not found:
                    problems.append(
                        f"{sd} holds NONE of the {len(self.expected_contexts())} "
                        f"expected build contexts (hugmesh-*) — almost certainly the "
                        f"wrong directory; compose errors on the first build context.")
        # SERVICES — refuse a slug the local docker stack has no mechanism for, WITH
        # the reason. Silently dropping it is the failure mode this whole axis exists
        # to kill: the operator would be told the mesh runs something it cannot.
        problems.extend(validate_selection(self.cfg.services))
        # EGRESS VPN — selected means a VALID provider conf must back it (the
        # container refuses to start without one, fail-closed; this preflight moves
        # that refusal from minutes into the up to the plan). Same sniff rules as
        # the entrypoint via core.egress_conf.
        if self.cfg.effective_egress_vpn():
            _kind, err = validate_egress_conf(self.cfg.egress_vpn_conf.strip())
            if err:
                problems.append(f"Egress VPN is selected but has no usable config "
                                f"file: {err}")
        # FORM only. Whether a catalog actually EXISTS for a locale is checked by the
        # login-ui build itself (tools/i18n/emit-shipped-locales.mjs fails loudly on a
        # requested locale with no messages.<locale>.xlf). The catalogs live in that
        # repo, which is not even cloned yet at this point (`make stack-clone` fetches
        # it), so validating existence here would mean inventing a constraint this
        # config cannot honestly check — and getting it wrong in BOTH directions:
        # rejecting a locale the repo does have, or passing one it doesn't.
        for loc in self.cfg.web_locales:
            if not _LOCALE_RE.match(loc):
                problems.append(f"web locale '{loc}' is not a BCP-47-shaped tag "
                                f"(e.g. de, fr, pt-BR, en-XA).")
        # ── identity provider (I6.6) — the SAME fail-closed rules ImageConfig
        # enforces (external needs https issuer + client id; casdoor requires the
        # other fields EMPTY so the default env stays byte-identical).
        if self.cfg.idp not in IDP_CHOICES:
            problems.append(f"idp must be one of {', '.join(IDP_CHOICES)} "
                            f"(got '{self.cfg.idp}').")
        elif not self.cfg.idp_external():
            for fld in ("idp_issuer", "idp_client_id", "idp_jwks"):
                if getattr(self.cfg, fld).strip():
                    problems.append(f"{fld} is set but idp is 'casdoor' (the built-in "
                                    "default) — clear it or pick an external provider.")
        else:
            iss = self.cfg.idp_issuer.strip()
            cid = self.cfg.idp_client_id.strip()
            jwks = self.cfg.idp_jwks.strip()
            if not iss or not _IDP_URL_RE.fullmatch(iss):
                problems.append(f"idp={self.cfg.idp} requires an https:// issuer URL "
                                f"(got '{iss}').")
            if not cid or not _IDP_CLIENT_ID_RE.fullmatch(cid):
                problems.append(f"idp={self.cfg.idp} requires a client id "
                                f"(allowlist [A-Za-z0-9._:/-], got '{cid}').")
            if jwks and not _IDP_URL_RE.fullmatch(jwks):
                problems.append(f"idp_jwks must be an https:// URL (got '{jwks}') — "
                                "leave empty to derive the provider default.")
        # ── per-domain OWN Casdoor (issue #47) — in the GUI these names come off
        # the validated Domains table, but the CLI/menu hand them in raw. Block
        # (with the reason) any name that is not a DNS name: own_casdoor.py would
        # otherwise derive a broken casdoor-<slug> service/issuer from it, and a
        # silent drop is the exact failure mode this axis exists to kill.
        for name in self.cfg.own_idp_domains:
            if not name.strip() or not all(
                    _BRAND_DNS_LABEL.match(lbl)
                    for lbl in name.strip().lower().split(".")):
                problems.append(
                    f"own-Casdoor domain '{name}' is not a DNS name (dot-"
                    f"separated [a-z0-9-] labels) — no casdoor-<slug> "
                    f"service/issuer can be derived from it.")
        # Two rows with one name, or a row named after the mesh's OWN apex (#494 fix
        # round). own_casdoor derives one compose service + one postgres volume per
        # NAME, so a duplicate emits the same casdoor-<slug> key twice on two ports,
        # and the own apex already signs in via the central Casdoor — an own one for
        # it maps APP_TENANCY_HOSTS to a phantom. The CLI collapses duplicates on
        # parse and the Studio refuses both inline; this is the backstop for a
        # hand-edited record or any other door.
        seen_idp: set[str] = set()
        apex = self.cfg.resolved_domain().strip().lower()
        for name in self.cfg.own_idp_domains:
            key = name.strip().lower()
            if not key:
                continue
            if key in seen_idp:
                problems.append(f"own-Casdoor domain '{name.strip()}' is listed twice "
                                "— each domain gets exactly one own Casdoor.")
            seen_idp.add(key)
            if key == apex:
                problems.append(
                    f"own-Casdoor domain '{name.strip()}' is this mesh's own domain — "
                    "it signs in via the central Casdoor and cannot have an own one.")
        if self.cfg.is_prod():
            if not self.cfg.cluster_domain.strip():
                problems.append("prod requires a public cluster domain "
                                "(--cluster-domain) so the minted issuer/superadmin "
                                "align with the real apex.")
            if not self.cfg.auth_key.strip():
                problems.append("prod requires a tailnet/headscale auth key "
                                "(--authkey-file) to attach the mesh overlay to the "
                                "real tailnet.")
        return problems

    def warnings(self) -> list[str]:
        """ADVISORY (never blocks — per the #387 rule these are shapes the tools accept
        and exit 0 on): a brand with no profile file, and an existing tree missing some
        of the build contexts compose will eventually ask for."""
        out: list[str] = []
        brand = self.cfg.brand.strip()
        if brand and _BRAND_DNS_LABEL.match(brand) and not self.brand_has_conf():
            if brand != DEFAULT_BRAND:
                out.append(
                    f"No brands/{brand}.conf profile — gen-cluster-secrets.sh runs fine "
                    f"with built-in defaults (the -f guard just skips sourcing), but "
                    f"MAIL_*/OAuth presets a profile would set stay unset.")
        if self.cfg.source_mode == "existing" and self.cfg.source_dir.strip() \
                and os.path.isdir(self.cfg.source_dir.strip()):
            found, missing = self.source_coverage()
            if found and missing:
                out.append(
                    f"{len(found)} of {len(found) + len(missing)} expected build "
                    f"contexts found under {self.cfg.source_dir.strip()} — compose "
                    f"builds fine until it reaches a missing one "
                    f"(missing: {', '.join(missing[:4])}"
                    + (", …" if len(missing) > 4 else "") + ").")
        return out

    def preflight(self) -> list[str]:
        """Fail-fast COLD-BUILD readiness (LocalStackNode.preflight): docker daemon,
        BuildKit/buildx visibility in the EXACT env `make stack-up` will run with,
        disk headroom, and the private-maven prerequisites when the service images
        must cold-build. Returns SHORT actionable problems (empty = ready) — the
        alternative is the operator diagnosing a truncated compose-build tail.
        Unlike validate() (pure config), this probes the host, so it runs on
        ``up`` (and is callable from the GUI) but never on mere selection."""
        return self._stack_node().preflight()

    # ---- confirm-before-run manifest (PURE, no side effects) --------------------
    def plan(self) -> str:
        """A human-readable manifest of EXACTLY what an ``up`` will generate + start —
        side-effect-free. The GUI shows it in a read-only preview above the start
        button; the CLI prints it. Renders: (a) which scripts run + the out dir,
        (b) which compose projects come up, (c) ENV/issuer/domain, (d) the superadmin
        USERNAME + WHERE its freshly-minted password will be written (NEVER the value)."""
        c = self.cfg
        overlay = self.overlay_will_attach()
        lines: list[str] = []
        lines.append("Generate & start a NEW local Docker mesh FROM SCRATCH")
        lines.append("=" * 56)
        lines.append("")
        lines.append(f"ENV:        {c.env}"
                     + ("  (LAN-only / offline — the safe default)" if not c.is_prod()
                        else "  (REAL public domain)"))
        lines.append(f"Brand:      {c.brand}")
        lines.append(f"Domain:     {c.resolved_domain()}"
                     + ("" if c.is_prod() else "  (brand default; not a public issuer in test)"))
        lines.append(f"Issuer:     {c.issuer()}")
        # I6.6: disclose the chosen IdP — and the honest external-mode limit
        # (the Makefile seam consumes all three vars, so token VALIDATION really
        # re-points at the external issuer/JWKS; the coupled login/MFA/role legs
        # do not move — docs/IDENTITY-PROVIDERS.md "Honest limits").
        lines.append(f"IdP:        {IDP_LABELS.get(c.idp, c.idp)}")
        if c.idp_external():
            lines.append(f"            issuer: {c.idp_issuer.strip()}")
            lines.append(f"            client: {c.idp_client_id.strip()}")
            lines.append(f"            jwks:   {c.effective_idp_jwks()}")
            lines.append("            Threaded as OIDC_ISSUER/OIDC_CLIENT_ID/OIDC_JWKS_URI env;")
            lines.append("            the Makefile maps them onto CASDOOR_ISSUER_URI/")
            lines.append("            CASDOOR_APP_CLIENT_ID/CASDOOR_JWKS_URI, so gateway + BFF")
            lines.append("            token VALIDATION runs against this external issuer/JWKS.")
            lines.append("            LIMIT: native login, MFA step-up and role claims stay")
            lines.append("            Casdoor-coupled (no full external login round-trip in the")
            lines.append("            test stack) — see docs/IDENTITY-PROVIDERS.md.")
        lines.append("Web login:  "
                     + (", ".join(c.web_locales) + " (+ English source)" if c.web_locales
                        else "English only (no translation catalogs shipped)"))
        lines.append("")
        lines.append("(1) GENERATE credentials (offline — VAULT_ADDR left unset):")
        lines.append(f"      {GEN_CLUSTER_SECRETS} --out {self.vault_dir}")
        lines.append("          -> Casdoor/ClickHouse/Uptrace secrets + the platform")
        lines.append(f"             superadmin, written to {self.secrets_json}")
        lines.append(f"      {GEN_PROVISION_KEYS} -o {self.keys_dir} --random")
        lines.append(f"          -> SSH keypairs + password hashes under {self.keys_dir}")
        lines.append("             (vault-seed/ private material stays VAULT-ONLY —")
        lines.append("              never baked, bundled, or logged by this bootstrap)")
        lines.append("")
        lines.append("(2) START the full platform stack (compose project via")
        lines.append("    tests/stack/compose.local.yaml — Casdoor + DB + gateway + BFFs):")
        if c.source_mode == "existing":
            found, missing = self.source_coverage()
            lines.append(f"      SOURCE: your existing tree {c.source_dir.strip()}")
            lines.append(f"              ({len(found)} of {len(found) + len(missing)} "
                         "expected build contexts found; STACK_NO_CLONE=1 — your")
            lines.append("               checkouts are NEVER fetched, updated, or reset)")
        else:
            lines.append("      SOURCE: download/update all repos into ./.stack-src")
            lines.append("              (make stack-clone — every compose service builds")
            lines.append("               from those real, buildable files)")
        # (a stray duplicate of this line — the pre-locale variant — shipped in the
        # i18n union-rebase; ONE line, with every knob it carries, is the contract)
        _wl = ",".join(c.web_locales)
        lines.append(f"      make stack-up   (ENV={c.env}, "
                     f"SOCIAL={'on' if c.effective_social() else 'off'}"
                     + f", TOR={'on' if c.effective_with_tor() else 'off'}"
                     + (f", HUG_WEB_LOCALES={_wl}" if _wl else "")
                     + (", HUG_THEME_CSS=<derived>" if c.login_theme_css.strip() else "")
                     + (f", OIDC_ISSUER={c.idp_issuer.strip()}"
                        f", OIDC_CLIENT_ID={c.idp_client_id.strip()}"
                        f", OIDC_JWKS_URI={c.effective_idp_jwks()}"
                        if c.idp_external() else "")
                     + (", OWN_CASDOOR=1" if c.own_idp_domains else "")
                     + ")")
        if c.effective_with_tor():
            lines.append("          -> also starts hugmesh-tor (the `tor` profile):")
            lines.append("             publishes the fe-gateway as a v3 .onion, reachable")
            lines.append("             in Tor Browser (no public IP/DNS/ports). The address")
            lines.append("             is reported at the end + via `make stack-onion`.")
        if _wl:
            lines.append(f"          -> login-ui image ships i18n/{{{_wl}}}.json catalogs")
        if c.login_theme_css.strip():
            lines.append(f"          -> login-ui serves the CUSTOM login theme "
                         f"({len(c.login_theme_css)} chars of derived --sd-* css,")
            lines.append("             written to snap-theme.css at container start — "
                         "rebrand needs no rebuild)")
        # Per-domain OWN Casdoor (issue #47): disclose EXACTLY what the compose
        # lane derives — the same ports/issuers own_casdoor.py allocates and
        # LocalStackNode threads into APP_TENANCY_ISSUERS — so the plan and the
        # running stack cannot disagree. Empty (the default) renders NOTHING:
        # the superdomain-only plan stays byte-identical.
        if c.own_idp_domains:
            lines.append("          -> OWN-Casdoor domains (issue #47): each runs its "
                         "own Casdoor")
            lines.append("             (+ postgres) behind the `own-casdoor` profile; "
                         "every other")
            lines.append(f"             domain signs in via the superdomain Casdoor "
                         f"({c.issuer()}")
            lines.append("             = tenant `default`):")
            for i, name in enumerate(c.own_idp_domains):
                lines.append(f"             * {name}: host port "
                             f"{own_casdoor.port_for(i)}, issuer "
                             f"{own_casdoor.issuer_for(name, i)}")
        # The DOMAINS the Studio's Domains step recorded (#494). Empty (the default,
        # and every flow that never opened the step) renders NOTHING. Per-domain
        # services are shown as what they are on this lane: recorded, not what picks
        # the compose profiles — that is the Services step, printed below.
        if c.domains:
            lines.append("          -> domains recorded with this mesh (per-domain "
                         "services are RECORDED, not enforced:")
            lines.append("             the compose profiles come from the Services "
                         "step below):")
            for row in c.domains:
                svcs = ", ".join(row.get("optional_services") or []) or "cluster default"
                title = row.get("title") or ""
                lines.append(f"             * {row.get('name', '')}"
                             + (f" ({title})" if title else "")
                             + f": sign-in={row.get('idp', 'superdomain')}, "
                             f"services: {svcs}")
        lines.append("      make stack-seed (provisions ROLE_SUPERADMIN with the minted")
        lines.append("                       password, bridged via env only)")
        # SERVICES — spelled out per mechanism, because the operator's two questions
        # ("does it start containers?" and "when does it take effect?") have opposite
        # answers for the two halves, and a single flat list would hide that.
        # THREE blocks, not two: the services table shows a third kind of row (the
        # DevOps/Kubernetes lane), and a confirm-before-run manifest that silently
        # omits rows the operator was just shown is describing a different mesh than
        # the one on screen. The third block is marked NOT-RUN rather than checkboxed,
        # which is the same thing the rows themselves say.
        fed = c.federation_services()
        fed_env = federation_env(c.services)
        if c.services is not None:
            chosen = set(c.services)
            lines.append("")
            lines.append("      SERVICES (compose profiles — start/stop containers here):")
            for slug in profile_slugs():
                lines.append(f"        [{'x' if slug in chosen else ' '}] {slug}"
                             f"  (--profile {by_local_slug(slug).profile})")
            lines.append("      SERVICES (federation registry — containers are ALWAYS up;")
            lines.append("                this flips federation_modules.enabled at seed):")
            for slug in federation_slugs():
                lines.append(f"        [{'x' if slug in fed else ' '}] {slug}"
                             f"  (module {by_local_slug(slug).module})")
            if fed_env:
                lines.append(f"        -> {FEDERATION_ENABLE_ENV}="
                             f"{fed_env[FEDERATION_ENABLE_ENV] or '(none)'}")
                lines.append(f"           {FEDERATION_DISABLE_ENV}="
                             f"{fed_env[FEDERATION_DISABLE_ENV] or '(none)'}")
                # No longer PENDING: seed-e2e.sh grew a leg-4 that consumes both
                # vars verbatim against the compose federation-db and reads the
                # registry back. The disclaimer that used to live here was true for
                # as long as the checkboxes were inert; deleting it in the SAME
                # change that made them real is what keeps the surface and the
                # seeder from disagreeing again.
                lines.append("           (applied by `make stack-seed` — leg 4 sets "
                             "these rows and reads the registry back)")
            else:
                lines.append("        (matches what the registry ships — nothing to "
                             "flip, env unchanged)")
            if kind_slugs():
                lines.append("      SERVICES (DevOps lane — Kubernetes controllers;")
                lines.append("                NOT started by this bring-up):")
                for slug in kind_slugs():
                    lines.append(f"        [-] {slug}  {KIND_LANE_LABEL}")
                lines.append("        -> nothing here starts them and nothing here "
                             "can: they need")
                lines.append("           the local Kubernetes cluster. Use "
                             "'Start DevOps lane' on this")
                lines.append("           page — it is separate from, and changes "
                             "nothing about, the")
                lines.append("           docker mesh above.")
        lines.append("")
        lines.append("(3) MESH OVERLAY (hugmesh-mesh compose project, tailscale):")
        if overlay:
            lines.append("      ATTACHED — prod + auth key supplied; joins the real tailnet"
                         + (f" via {c.login_server}" if c.login_server.strip() else ""))
        else:
            lines.append("      SKIPPED — LAN-only (no TS_AUTHKEY); the from-scratch")
            lines.append("      platform still comes up fully without a tailnet.")
        lines.append("")
        lines.append("(4) SERVE / EXPOSE (this bring-up serves the mesh LOCALLY):")
        lines.append(f"      Local front door once up: {self._stack_node().web_url}")
        # effective_*, never the raw flag (#586): with a services selection the tor ROW
        # decided the profile, so `with_tor` could say ON over a stack that starts no
        # hugmesh-tor (and OFF over one that does) — step (3) above already reads it
        # this way, and one plan must not say both things.
        if c.effective_with_tor():
            lines.append("      Public (no IP/DNS): already ON — the Tor v3 .onion above.")
        else:
            lines.append("      Public exposure is a SEPARATE, opt-in step — run Go Live")
            lines.append("      after this is up (Studio 'Go Live' page / `hugmesh-go-live`):")
            lines.append("        * tor-onion  — a Tor v3 onion service, no public")
            lines.append("                       IP/DNS/ports (or re-run this with Tor on)")
            lines.append("        * duckdns    — a common Dynamic-DNS host (dynamic IP)")
            lines.append("        * cloudflare-tunnel / byo-domain / router-portforward")
            lines.append("      All are registry-driven, so they appear in every front-end.")
        lines.append("")
        lines.append("SUPERADMIN identity:")
        lines.append(f"      username: {c.superadmin_username}")
        lines.append("      password: minted fresh (openssl rand) — written ONLY to")
        lines.append(f"                {self.secrets_json}")
        lines.append(f"                (under {c.brand}-pki -> casdoor-superadmin; the")
        lines.append("                 value is NEVER printed, logged, or committed)")
        lines.append("")
        lines.append(f"Creds land in a runtime dir: {self.out_dir}  (gitignored)")
        problems = self.validate()
        if problems:
            lines.append("")
            lines.append("BLOCKERS (fix before 'up'):")
            lines.extend(f"  - {p}" for p in problems)
        return "\n".join(lines)

    # ---- credential generation (subprocess; values never argv / never logged) ---
    def _gen_env(self) -> dict[str, str]:
        """Curated env for the gen scripts. VAULT_ADDR/VAULT_TOKEN are DELIBERATELY
        removed so the mint stays offline (USB/secrets.json only). BRAND +
        CASDOOR_SUPERADMIN_USERNAME steer gen-cluster-secrets.sh; CLUSTER_DOMAIN is
        pinned in prod so the issuer/superadmin align with the real apex (in test it
        is left to the brand default). NONINTERACTIVE=1 makes gen-provision-keys.sh
        skip every prompt."""
        env = os.environ.copy()
        env.pop("VAULT_ADDR", None)
        env.pop("VAULT_TOKEN", None)
        env["BRAND"] = self.cfg.brand
        env["CASDOOR_SUPERADMIN_USERNAME"] = self.cfg.superadmin_username
        env["NONINTERACTIVE"] = "1"
        if self.cfg.is_prod():
            env["CLUSTER_DOMAIN"] = self.cfg.resolved_domain()
        return env

    def generate_creds(self) -> tuple[bool, str]:
        """Run BOTH generators verbatim (cwd=generator_dir). Returns (ok, message).
        Secret VALUES only ever ride the scripts' internals + their output files —
        never this process's argv, and the curated env is never logged."""
        env = self._gen_env()
        for script, out_flag, out_dir, extra in (
                (GEN_CLUSTER_SECRETS, "--out", self.vault_dir, []),
                (GEN_PROVISION_KEYS, "-o", self.keys_dir, ["--random"])):
            cmd = ["bash", script, out_flag, out_dir, *extra]
            try:
                r = subprocess.run(cmd, cwd=self.generator_dir, env=env,
                                   capture_output=True, text=True, timeout=600)
            except (OSError, subprocess.SubprocessError) as e:
                return False, f"{script}: {e}"
            if r.returncode != 0:
                return False, f"{script} failed: {(r.stderr or r.stdout).strip()}"
        return True, f"credentials generated under {self.out_dir}"

    def read_superadmin(self, path: str | None = None) -> dict[str, str]:
        """Parse the minted ``<brand>-pki.casdoor-superadmin`` -> {username, password}
        from the offline bundle (stdlib json). Returns {} when unreadable/absent."""
        p = path or self.secrets_json
        try:
            with open(p, encoding="utf-8") as fh:
                data = json.load(fh)
        except (OSError, ValueError):
            return {}
        pki = data.get(f"{self.cfg.brand}-pki", {})
        sa = pki.get("casdoor-superadmin", {})
        if not isinstance(sa, dict):
            return {}
        return {"username": str(sa.get("username", "")),
                "password": str(sa.get("password", ""))}

    # ---- lifecycle --------------------------------------------------------------
    def m2_bootstrap(self, on_line=None, cancel=None) -> tuple[bool, list[str]]:
        """`make stack-m2-bootstrap` — the cold-build prerequisite preflight names
        ("run `make stack-m2-bootstrap` first"): builds the org-private maven
        artifacts FROM SOURCE and serves them from the local registry container.
        Exposed here so the GUI can run it — a from-scratch bring-up must never
        require a terminal detour. Streams via ``on_line``; ``cancel`` terminates
        the whole build process group."""
        ok, why = self.guard_host_local()
        if not ok:
            return False, [why]
        ok, msg = self._stack_node().m2_bootstrap(on_line=on_line, cancel=cancel)
        return ok, [f"[m2-bootstrap] {'ok' if ok else 'FAILED'}: {_tail(msg)}"]

    def _prepare(self, _note, on_line=None, cancel=None) -> bool:
        """guard -> validate -> host preflight (+ the m2 self-heal). Shared by
        :meth:`up` and :meth:`restore`, so a restore can never skip a gate an
        ``up`` runs. Every refusal STREAMS through ``_note`` (see :meth:`up` for
        why a plain return would be invisible in the GUI)."""
        ok, why = self.guard_host_local()
        if not ok:
            _note(why)
            return False
        problems = self.validate()
        if problems:
            for _ln in ["cannot start:", *(f"  - {p}" for p in problems)]:
                _note(_ln)
            return False

        # Host preflight BEFORE any side effect (no creds are minted for a host
        # that cannot build/run the stack). On failure the operator gets a SHORT
        # actionable plan — e.g. "run `make stack-m2-bootstrap` first" — instead
        # of a wall of compose noise 30 minutes into a doomed cold build.
        problems = self.preflight()
        # SELF-HEAL THE ONE PREREQUISITE WE CAN. After "Stop & clean" (or on a fresh
        # box) the ONLY blocker is usually the local private-maven registry, and the
        # fix is a button the operator has to know to press first — a cliff that made
        # "clean, then start a new mesh" look broken. If that is the sole problem, run
        # it here and re-check; anything else still refuses, because the rest of
        # preflight (docker daemon, buildx, disk headroom) is not ours to fix.
        if problems and all(M2_BOOTSTRAP_HINT in p for p in problems):
            _note("[m2-bootstrap] the private-maven registry is not up — building it "
                  "now (the one prerequisite of a cold build); this is exactly what "
                  "the 'Build maven prereqs (m2)' button does.")
            ok_m2, m2_log = self.m2_bootstrap(on_line=on_line, cancel=cancel)
            for _ln in m2_log:
                _note(_ln)
            if not ok_m2:
                _note("[m2-bootstrap] FAILED — nothing was generated or started.")
                return False
            problems = self.preflight()
        if problems:
            for _ln in ["preflight failed — nothing was generated or started. "
                        "Fix, then retry:",
                        *(f"  - {p}" for p in problems)]:
                _note(_ln)
            return False
        return True

    def _start_seed_overlay(self, _note, sa_user: str, sa_password: str,
                            seed_env: dict[str, str] | None = None,
                            on_line=None, cancel=None) -> bool:
        """stack-up -> stack-seed (password bridged via env) -> (prod) overlay ->
        tor onion -> the [done] line. The tail :meth:`up` and :meth:`restore`
        share; the ONLY difference between the two is what runs BEFORE it (mint
        fresh credentials, or reuse the saved ones)."""
        stack = self._stack_node()
        ok, msg = stack.start(on_line=on_line, cancel=cancel)
        _note(f"[stack-up] {'ok' if ok else 'FAILED'}: {_tail(msg)}")
        if not ok:
            return False

        # Bridge BOTH the minted username and password into `make stack-seed` (env
        # only, never argv): the username so seed-e2e provisions the ROLE_SUPERADMIN
        # persona under the login the plan/log/secrets advertise (not the hardcoded
        # e2e-superadmin default), the password so it is actually usable.
        env = {
            SEED_SUPERADMIN_USERNAME_ENV: sa_user,
            SEED_SUPERADMIN_PASSWORD_ENV: sa_password,
        }
        env.update(seed_env or {})
        ok, msg = stack.seed(env, on_line=on_line, cancel=cancel)
        _note(f"[stack-seed] {'ok' if ok else 'FAILED'}: {_tail(msg)}")
        if not ok:
            return False

        if self.overlay_will_attach():
            mesh = self._mesh_node()
            # MeshNode.start() reads os.environ["TS_AUTHKEY"] for its guard +
            # compose interpolation (LocalMeshNode stages it into .env but does not
            # export it — same gap local_mesh.main() closes before start()).
            os.environ[ENV_AUTHKEY] = self.cfg.auth_key.strip()
            ok, msg = mesh.start()
            _note(f"[mesh-overlay] {'ok' if ok else 'FAILED'}: {_tail(msg)}")
            if not ok:
                return False
        else:
            _note("[mesh-overlay] skipped (LAN-only / no auth key)")

        # Tor onion — report the minted .onion once the hugmesh-tor service
        # publishes it (tor bootstraps + uploads the descriptor in ~30s). Never
        # fatal: a slow/absent publish just tells the operator how to read it later.
        # effective_*, not the raw flag: with a services selection the tor ROW is what
        # decided whether hugmesh-tor was started, so reading `with_tor` here would
        # wait for (or skip) an onion that disagrees with the profile actually brought
        # up — the stack node already went through the same rule.
        if self.cfg.effective_with_tor():
            onion = self._await_onion(stack, _note, cancel)
            if onion:
                _note(f"[tor] onion published — reachable in Tor Browser: {onion}")
            else:
                _note("[tor] onion still publishing — read it later with "
                      "`make stack-onion` (or tests/stack/tor-onion/hostname)")

        _note(f"[done] platform up. Front door: {self._stack_node().web_url}  "
              f"| Casdoor issuer: {self.cfg.issuer()}")
        return True

    def up(self, on_line=None, cancel=None) -> tuple[bool, list[str]]:
        """The from-scratch bring-up. Returns (ok, log-lines). NO secret VALUE ever
        appears in the log lines — only the username + the path its password landed
        in. Order: guard -> generate -> read superadmin -> stack-up -> stack-seed
        (password bridged via env) -> (prod) attach overlay.

        ``on_line`` streams progress AS IT HAPPENS (creds milestones + the live
        `make` output) — without it a cold bring-up is an hour of silence ending in
        one text blob; ``cancel`` terminates the running build's process group."""
        log: list[str] = []

        def _note(line: str) -> None:
            log.append(line)
            if on_line is not None:
                on_line(line)
        # NOTE: these refusals MUST stream via _note(). _MeshWorker's stream mode
        # deliberately discards the returned lines (they normally already streamed),
        # so a plain `return False, [...]` here is INVISIBLE in the GUI — the operator
        # sees the "generating credentials…" line and then nothing at all.
        if not self._prepare(_note, on_line=on_line, cancel=cancel):
            return False, log

        ok, msg = self.generate_creds()
        _note(f"[creds] {msg}")
        if not ok:
            return False, log

        sa = self.read_superadmin()
        if not sa.get("password"):
            _note(f"[creds] could not read the minted superadmin from "
                  f"{self.secrets_json}")
            return False, log
        # NOTE: log the USERNAME + WHERE the password is — never the value.
        _note(f"[creds] minted superadmin '{sa['username']}' "
              f"(password in {self.secrets_json})")

        ok = self._start_seed_overlay(_note, sa["username"], sa["password"],
                                      on_line=on_line, cancel=cancel)
        return ok, log

    # ── saved meshes (core/saved_meshes.py) ──────────────────────────────────
    def e2e_credentials_path(self) -> str:
        """``<generator_dir>/.e2e-credentials`` — the run-state file the seeder
        writes and every later seed reads (tests/stack/e2e-password.sh)."""
        from .saved_meshes import E2E_CREDENTIALS_BASENAME
        return os.path.join(self.generator_dir, E2E_CREDENTIALS_BASENAME)

    def _put_saved_credentials_back(self, rec, _note) -> None:
        from . import saved_meshes
        restored = saved_meshes.put_copies_back(
            rec, e2e_target=self.e2e_credentials_path(),
            secrets_target=self.secrets_json)
        if restored:
            _note("[creds] put the saved credential file(s) back in place: "
                  + ", ".join(restored) + " (0600; values never logged)")

    def _live_plan(self, rec, _note):
        """Re-decide the saved-mesh plan on the WORKER, from what is on the machine
        NOW — never from the row's probe-time answer, which is as old as the last
        page entry or ``_mesh_up`` flip (hours, easily). Two facts a stale plan
        hides: a mesh brought up from a terminal since the row was read (a start
        over it stacks a second project on the same compose name; a restore
        re-seeds the LIVE mesh's passwords), and volumes cleaned since (a warm
        start would create EMPTY volumes and no seed runs, while the log says
        "reattaching"). Same gatherer, same pure decision as the row
        (:func:`.saved_meshes.probe_state` / :func:`.saved_meshes.restore_plan`),
        so the two can never disagree about what a case IS. None = nothing could
        be established, and the caller refuses: a claim about the operator's data
        that nothing established is the page's own rule."""
        from . import saved_meshes
        try:
            facts = saved_meshes.probe_state(rec)
            return saved_meshes.restore_plan(rec, **facts)
        except Exception as exc:                      # noqa: BLE001 — refuse, never raise
            _note("[saved-mesh] refused — what is on this machine could not be "
                  f"established ({type(exc).__name__}: {exc}); nothing was started.")
            return None

    def start_saved(self, rec, on_line=None, cancel=None) -> tuple[bool, list[str]]:
        """The WARM restore (saved-mesh case 1: volumes + images present, after
        'Stop mesh'): ``stack.start()`` ONLY — no credentials are minted and no
        seed runs, so identity, rooms and posts come back exactly as they were.

        Re-checked HERE, on the worker, that it still IS case 1 (:meth:`_live_plan`):
        the row's Start was decided when the row was probed, not when it was
        pressed.

        The one guard: if the on-disk ``.e2e-credentials`` no longer matches the
        record AND the record kept a copy, the copy is put back first — without
        that the next seed from this page mints a second password and every persona
        401s (seed-e2e.sh leg 1c, exit 3). No copy -> the current file is used and
        the log says so."""
        log: list[str] = []

        def _note(line: str) -> None:
            log.append(line)
            if on_line is not None:
                on_line(line)
        from . import saved_meshes
        ok, why = self.guard_host_local()
        if not ok:
            _note(why)
            return False, log
        plan = self._live_plan(rec, _note)
        if plan is None:
            return False, log
        if plan.mode == saved_meshes.MODE_RESEED:
            _note("[saved-mesh] refused — the record's data volumes are not all here "
                  f"any more ({plan.volumes_text}): a warm start would create EMPTY "
                  "volumes and no seed runs. Use 'Restore (reseed)' for this record. "
                  "Nothing was started.")
            return False, log
        if plan.mode != saved_meshes.MODE_START:
            _note(f"[saved-mesh] refused — {plan.sentence} Nothing was started.")
            return False, log
        if rec.has_credential_copies():
            self._put_saved_credentials_back(rec, _note)
        else:
            _note("[creds] no credential copy in this record — the current "
                  f"{os.path.basename(self.e2e_credentials_path())} is used as it is")
        _note(f"[saved-mesh] starting '{rec.label}' — reattaching its "
              f"{rec.volume_count()} data volume(s); nothing is re-minted or re-seeded")
        stack = self._stack_node()
        ok, msg = stack.start(on_line=on_line, cancel=cancel)
        _note(f"[stack-up] {'ok' if ok else 'FAILED'}: {_tail(msg)}")
        if ok:
            _note(f"[done] platform up. Front door: {stack.web_url}  "
                  f"| Casdoor issuer: {self.cfg.issuer()}")
        return ok, log

    def restore(self, rec, on_line=None, cancel=None) -> tuple[bool, list[str]]:
        """The COLD restore (saved-mesh case 2: volumes gone, after 'Stop && clean
        Docker'): the :meth:`up` sequence MINUS ``generate_creds``.

        This is the single most important correctness point of the saved-mesh
        lane: ``up()`` ALWAYS re-mints ``secrets.json``, so a restore routed
        through it would overwrite the very bundle the record points at. Here the
        saved copies (when the record kept any) are put back in place, the
        superadmin is READ (never minted) and the seed runs with
        :func:`.saved_meshes.restore_env` merged in — env only, never argv, never a
        log line. Refuses with one sentence when the record declares copies that
        are no longer on disk."""
        from . import saved_meshes
        log: list[str] = []

        def _note(line: str) -> None:
            log.append(line)
            if on_line is not None:
                on_line(line)
        missing = [p for p in rec.credential_copies() if not os.path.isfile(p)]
        if missing:
            _note("[restore] refused — this record declares saved credential files "
                  "that are no longer on disk: "
                  + ", ".join(os.path.basename(p) for p in missing)
                  + ". Restoring anyway would seed different passwords than the "
                    "record promises; delete the record or put the files back.")
            return False, log
        # A mesh that came up since the row was probed: a restore over it would
        # run `make stack-seed` with THIS record's credentials against the live
        # mesh's identities — every one of its users re-passworded. The page's
        # gate is probe-time; this one is now.
        plan = self._live_plan(rec, _note)
        if plan is None:
            return False, log
        if plan.mode == saved_meshes.MODE_BLOCKED:
            _note(f"[restore] refused — {plan.sentence} Nothing was started or seeded.")
            return False, log
        if not self._prepare(_note, on_line=on_line, cancel=cancel):
            return False, log

        if rec.has_credential_copies():
            self._put_saved_credentials_back(rec, _note)
        env = saved_meshes.restore_env(rec)
        sa = self.read_superadmin()
        user = (env.get(SEED_SUPERADMIN_USERNAME_ENV) or sa.get("username")
                or self.cfg.superadmin_username)
        password = env.get(SEED_SUPERADMIN_PASSWORD_ENV) or sa.get("password") or ""
        if not password:
            _note("[creds] no superadmin password is available: the secrets bundle "
                  f"at {self.secrets_json} is gone and this record kept no copy — "
                  "use 'Generate && start' to mint a new one.")
            return False, log
        # NOTE: log the USERNAME + WHERE the password came from — never the value.
        _note(f"[creds] reusing superadmin '{user}' "
              + ("from the record's saved copy"
                 if SEED_SUPERADMIN_PASSWORD_ENV in env else
                 f"from {self.secrets_json}")
              + " — nothing is re-minted")
        env.pop(SEED_SUPERADMIN_USERNAME_ENV, None)
        env.pop(SEED_SUPERADMIN_PASSWORD_ENV, None)
        ok = self._start_seed_overlay(_note, user, password, seed_env=env,
                                      on_line=on_line, cancel=cancel)
        return ok, log

    def _await_onion(self, stack, note, cancel, timeout_s: int = 45) -> str:
        """Poll the stack for the published .onion URL, up to ``timeout_s`` (tor
        needs ~30s to bootstrap + upload the v3 descriptor). Returns the URL, or ""
        if it has not appeared yet / was cancelled. Cancel-aware; 1s granularity."""
        deadline = time.monotonic() + timeout_s
        announced = False
        while time.monotonic() < deadline:
            if cancel is not None and cancel():
                return ""
            url = stack.onion_url()
            if url:
                return url
            if not announced:
                note("[tor] waiting for the onion descriptor to publish (~30s)…")
                announced = True
            time.sleep(1)
        return stack.onion_url()

    def down(self) -> tuple[bool, list[str]]:
        """Stop BOTH composed projects: the stack (``make stack-halt`` — the
        volumes are KEPT, see LocalStackNode.stop) + the mesh overlay
        (LocalMeshNode.stop()). ``clean()`` is the one that drops volumes."""
        log: list[str] = []
        stack = self._stack_node()
        # WHAT the stop did, in words. `make stack-down` echoes its whole STACK_ENV
        # command line and compose says nothing when there is nothing to remove, so a
        # successful stop rendered as a wall of env vars and no outcome — reported as
        # "tried stopping and nothing happened". Sample the state FIRST, then say so.
        before = stack.status()
        ok_stack, msg = stack.stop()
        if ok_stack:
            log.append("[stack-down] ok: " + (f"stopped the platform stack ({before.detail}) "
                                              f"and kept its volumes (make stack-halt)"
                                              if before.running else
                                              "nothing was running — no containers to stop"))
        else:
            log.append(f"[stack-down] FAILED: {_tail(msg)}")
        ok_mesh, msg = self._mesh_node().stop()
        log.append(f"[mesh-overlay down] {'ok' if ok_mesh else 'FAILED'}: {_tail(msg)}")
        return (ok_stack and ok_mesh), log

    def clean(self, on_line=None, cancel=None) -> tuple[bool, list[str]]:
        """Tear down AND reclaim disk: the mesh overlay stops, then `make stack-clean`
        removes the stack's containers, volumes and the images it built. DESTRUCTIVE
        by design (every caller confirms first) — the next bring-up is a cold build.
        Never touches images this stack did not build."""
        log: list[str] = []
        ok_mesh, msg = self._mesh_node().stop()
        log.append(f"[mesh-overlay down] {'ok' if ok_mesh else 'FAILED'}: {_tail(msg)}")
        ok_stack, msg = self._stack_node().clean(on_line=on_line, cancel=cancel)
        log.append(f"[stack-clean] {'ok' if ok_stack else 'FAILED'}: {_tail(msg)}")
        if ok_stack:
            # Say what to do next, in the log the operator is already reading. After a
            # clean there are no service images and no maven registry, so "start" is a
            # COLD build — and it now bootstraps the registry itself (see up()), which
            # is the part that previously needed insider knowledge.
            log.append("[stack-clean] done — every container, volume and built image "
                       "of this stack is gone (other projects' images untouched).")
            log.append("[stack-clean] to start a NEW mesh: press 'Generate & start'. "
                       "It rebuilds the maven prerequisites automatically, then does a "
                       "full COLD build (hours) — output streams here.")
        return (ok_stack and ok_mesh), log

    def status(self) -> list[str]:
        st = self._stack_node().status()
        ms = self._mesh_node().status()
        return [
            f"platform stack: {'running' if st.running else 'stopped'} ({st.detail})",
            f"mesh overlay:   {'running' if ms.running else 'stopped'} ({ms.detail})",
        ]


# ── Qt-free CLI face (the SHARED entrypoint) ────────────────────────────────────
# The ncurses menu (scripts/build-menu.sh) and the Makefile mesh-bootstrap-* targets
# both shell `python3 -m hugmesh_studio.core.local_mesh_bootstrap <sub> …`, so GUI
# + ncurses + CLI drive the SAME LocalMeshBootstrapConfig -> LocalMeshBootstrap object
# graph — exactly as mesh-node-up wraps core.local_mesh. Imports only sibling core
# modules (NO Qt), so it runs in the Qt-free/system-python environment CI uses.


class LocalMeshIdentity(NamedTuple):
    """What the node-image flows import from the local mesh (#50/#579): its apex
    domain, the Studio-provisioned accounts ``[(username, roles)]``, whether it ran
    the Tor onion, and one line saying WHERE that came from (a saved record's label,
    or "" for the defaults). A NamedTuple, so ``domain, users, with_tor = ...`` still
    unpacks the first three and a canned 3-tuple builds one.

    ``mesh_domains`` (#636): the saved mesh's domain rows as a
    ``core.local_mesh_domains.LocalMeshDomains`` (``imported_mesh_domains``) — row 0 the
    mesh's own domain, then every added domain with its title, sign-in and per-domain
    services, and the record's own reviewed markers — or None when the record carries
    none, which imports exactly what the apex-only import did."""
    domain: str
    users: list
    with_tor: bool = False
    source: str = ""
    mesh_domains: object = None


def saved_mesh_source(rec) -> str:
    """One human line naming the record an import read, or "" when none was."""
    if rec is None:
        return ""
    label = str(getattr(rec, "label", "") or getattr(rec, "id", "") or "?")
    when = str(getattr(rec, "updated", "") or getattr(rec, "created", "") or "")
    return f"saved mesh '{label}'" + (f" (saved {when})" if when else "")


def tor_carrier_platforms(platforms) -> tuple[tuple[str, ...], tuple[str, ...]]:
    """Split ``platforms`` into (can carry the Tor onion, cannot) — by what the
    builders actually express: x86's dedicated ``--with-tor`` or a platform whose
    ``--optional-services`` catalogue lists ``tor`` (rpi5). Every other builder bakes
    no net-vpn/tor, so a node there is built WITHOUT the onion whatever the mesh ran
    (worklist._apply_infra_services drops it rather than emit a dead flag)."""
    from .config import OPTIONAL_SERVICES_BY_PLATFORM, PLATFORM_FIELD_SUPPORT
    flag = PLATFORM_FIELD_SUPPORT.get("tor_onion_service", ("x86",))
    seen = list(dict.fromkeys(p for p in platforms if p))
    can = tuple(p for p in seen
                if p in flag or "tor" in OPTIONAL_SERVICES_BY_PLATFORM.get(p, ()))
    return can, tuple(p for p in seen if p not in can)


def localcloud_tor_note(platforms) -> str:
    """The inline (never modal) sentence the localcloud gate shows when the imported
    mesh ran Tor — the GUI page and the TUI screen render this one string."""
    can, cannot = tor_carrier_platforms(platforms)
    text = ("Tor onion: this mesh ran Tor (TOR=1), so the node images will carry the "
            "Tor v3 onion service too (net-vpn/tor + hugmesh-tor-reconcile) — the "
            "mesh-wide Tor row on the Network step starts ticked; untick it there to "
            "build without. Carried on " + (", ".join(can) or "no platform")
            + " node images (x86 via --with-tor, rpi5 as the tor node service); a "
            "laptop/desktop image never carries it.")
    if cannot:
        text += (" This platform cannot carry Tor: " + ", ".join(cannot)
                 + " — its builder bakes no net-vpn/tor, so a node there is built "
                   "without the onion.")
    return text


def _read_authkey(args: argparse.Namespace) -> str:
    """Resolve the auth key from --authkey-file (preferred: off the argv/process
    table) or --authkey. Trailing whitespace/newlines stripped."""
    if args.authkey_file:
        with open(args.authkey_file, encoding="utf-8") as fh:
            return fh.read().strip()
    return (args.authkey or "").strip()


def _parse_web_locales(raw: str) -> tuple[str, ...]:
    """Parse a comma/space-separated --web-locales value into a deduped tuple,
    order-preserving. Empty => () => English-only."""
    seen: list[str] = []
    for tok in re.split(r"[,\s]+", raw or ""):
        tok = tok.strip()
        if tok and tok not in seen:
            seen.append(tok)
    return tuple(seen)


def _parse_own_casdoor_domains(raw: list[str] | None) -> tuple[str, ...]:
    """The repeatable --own-casdoor-domain values -> the config tuple: stripped,
    order-preserving (the port sequence 8001+ is allocated from it — the
    Domains-table-order rule), duplicates collapsed to the first occurrence.
    None/empty => () => the pre-#47 byte-identical default."""
    seen: list[str] = []
    for name in raw or []:
        name = name.strip()
        if name and name not in seen:
            seen.append(name)
    return tuple(seen)


def _cfg_from_args(args: argparse.Namespace) -> LocalMeshBootstrapConfig:
    # Compose the theme HERE (raising on a malformed colour / unknown preset before
    # anything starts) so the config carries only the derived text and every
    # entrypoint shares theme.compose_login_css — never a second derivation. The
    # legibility WARNINGS (never blocking, #387) ride the same composition site.
    login_theme_css = theme.compose_login_css(
        args.login_primary, args.login_secondary, font_preset=args.login_font)
    for w in theme.warnings(args.login_primary or theme._DEFAULT_PRIMARY,
                            args.login_secondary) if login_theme_css else []:
        print(f"WARNING: {w}", file=sys.stderr)
    return LocalMeshBootstrapConfig(
        env=args.env, superadmin_username=args.superadmin_username,
        out_dir=args.out, social=args.social, with_tor=args.with_tor,
        # None (the flag absent) is NOT the same as an empty selection: absent means
        # "no picker was used", which keeps --social/--with-tor authoritative and the
        # stack env byte-identical to a pre-flag invocation. `--services ""` is the
        # EXPLICIT nothing, the same none/untouched split --optional-services carries.
        services=(None if args.services is None
                  else tuple(args.services.replace(",", " ").split())),
        auth_key=_read_authkey(args),
        login_server=args.login_server, node_name=args.node_name,
        brand=args.brand, cluster_domain=args.cluster_domain,
        source_mode=args.source_mode, source_dir=args.source_dir,
        web_locales=_parse_web_locales(args.web_locales),
        login_theme_css=login_theme_css,
        idp=args.idp, idp_issuer=args.idp_issuer,
        idp_client_id=args.idp_client_id, idp_jwks=args.idp_jwks,
        own_idp_domains=_parse_own_casdoor_domains(args.own_casdoor_domain))


def _confirm_prod(action: str) -> int:
    """The prod TTY confirm `up` and `mesh-restore` share: 0 = go, else the exit
    code. No bypass flag by design (golive's posture)."""
    if not sys.stdin.isatty():
        print(f"[refused] prod {action} requires an interactive TTY to confirm "
              "(there is deliberately no --yes bypass).", file=sys.stderr)
        return 2
    try:
        reply = input(f"Type 'yes' to {action} this prod mesh: ").strip().lower()
    except (EOFError, KeyboardInterrupt):
        reply = ""
    if reply != "yes":
        print("[aborted] no changes made.")
        return 1
    return 0


def _saved_mesh_cli(args: argparse.Namespace) -> int:
    """``mesh-save`` / ``mesh-restore`` over the SAME core the GUI page uses, so
    the record format is never a GUI-only artifact."""
    from . import saved_meshes
    if args.subcommand == "mesh-save":
        cfg = _cfg_from_args(args)
        boot = LocalMeshBootstrap(args.generator_dir, cfg)
        node = boot._stack_node()
        if not node.status().running:
            print("[refused] no local mesh is running — there is nothing to save. "
                  "(mesh-save records the RUNNING mesh; use `up` first.)",
                  file=sys.stderr)
            return 1
        rec = saved_meshes.capture(args.generator_dir, cfg, node, boot,
                                  label=args.label,
                                  copy_credentials=args.copy_credentials)
        path = saved_meshes.save(rec)
        if not path:
            print(f"[failed] the record could not be written under "
                  f"{saved_meshes.meshes_dir()}", file=sys.stderr)
            return 1
        print(f"saved {rec.id} -> {path}")
        print(f"  {rec.volume_count()} data volume(s) inventoried, NOT copied "
              f"(included=false: {saved_meshes.VOLUMES_NOT_INCLUDED_REASON})")
        print("  credential files: " + ("copied at 0600 into the record's side dir"
                                        if args.copy_credentials else
                                        "pointers only (paths, hashes, mtimes)"))
        return 0

    # mesh-restore
    if not args.mesh_id:
        print("mesh-restore needs a record id "
              "(`python3 -m hugmesh_studio.core.saved_meshes list`).", file=sys.stderr)
        return 2
    rec = saved_meshes.find(args.mesh_id)
    if rec is None:
        print(f"no saved mesh with id {args.mesh_id}", file=sys.stderr)
        return 1
    # the one field a record never carries (the auth key) rides the seam's argument
    boot = LocalMeshBootstrap.for_record(args.generator_dir, rec,
                                         auth_key=_read_authkey(args))
    cfg = boot.cfg
    plan = saved_meshes.restore_plan(rec, **saved_meshes.probe_state(rec))
    print(f"{rec.id}  {rec.label}")
    print(f"  {plan.sentence}")
    for w in plan.warnings:
        print(f"  WARNING: {w}")
    if plan.mode == saved_meshes.MODE_BLOCKED:
        return 1
    if cfg.is_prod():
        rc = _confirm_prod("restore")
        if rc:
            return rc
    if plan.can_start():
        ok, log = boot.start_saved(rec, on_line=print)
    else:
        ok, log = boot.restore(rec, on_line=print)
    return 0 if ok else 1


def main(argv: list[str] | None = None) -> int:
    """Qt-free entrypoint shared by the ncurses menu + the Makefile mesh-bootstrap
    targets. Verbs: plan | up | down | status | mesh-save | mesh-restore.

    Non-destructive by default: ``plan`` only prints the manifest; ``up`` is the sole
    action that mints creds + starts containers, and a prod ``up`` requires an
    interactive TTY confirm with NO bypass flag (mirroring golive's no-bypass
    posture)."""
    p = argparse.ArgumentParser(
        prog="hugmesh-mesh-bootstrap",
        description=(
            "Generate ALL credentials from scratch and start a NEW superadmin-"
            "controlled HugMesh mesh on THIS machine in Docker — the 'generate & "
            "start from scratch' path of the wizard's fourth choice. Builds NO image; "
            "composes the gen scripts + `make stack-up` + the docker-compose.mesh.yml "
            "overlay. Host-local only (refuses to run in a cluster pod)."))
    p.add_argument("subcommand", choices=("plan", "up", "down", "status",
                                          "mesh-save", "mesh-restore"),
                   help="plan = print the confirm-before-run manifest (no side "
                        "effects); up = GENERATE creds + START the stack (explicit "
                        "action; prod TTY-confirms); down = stop both projects; "
                        "status = are they running?; mesh-save = record the RUNNING "
                        "mesh as a saved-mesh record (core/saved_meshes.py — "
                        "config, source HEADs, credential POINTERS, a volume "
                        "inventory; never volume contents, never a password); "
                        "mesh-restore <id> = bring a saved mesh back: a warm start "
                        "when its volumes+images are still here, else bring up + "
                        "re-seed WITHOUT re-minting credentials.")
    p.add_argument("mesh_id", nargs="?", default="",
                   help="mesh-restore: the saved record id "
                        "(`python3 -m hugmesh_studio.core.saved_meshes list`).")
    p.add_argument("--label", default="",
                   help="mesh-save: a human label for the record (default: derived).")
    p.add_argument("--copy-credentials", action="store_true",
                   help="mesh-save: ALSO copy .e2e-credentials and keys-out/vault/"
                        "secrets.json into the record's side dir (0600). OFF by "
                        "default — the record holds pointers only. Needed to bring "
                        "the SAME passwords back after `stack-clean`.")
    p.add_argument("--env", choices=("test", "prod"), default="test",
                   help="test (DEFAULT, LAN-only/offline) or prod (real public domain).")
    p.add_argument("--superadmin-username", default="superadmin",
                   help="the platform superadmin login to mint (default: superadmin).")
    p.add_argument("--out", default="",
                   help="runtime creds dir (default: the gitignored keys-out/).")
    p.add_argument("--social", action="store_true",
                   help="also bring up the social (Matrix/Mastodon) profile.")
    p.add_argument("--with-tor", action="store_true",
                   help="also publish the fe-gateway as a Tor v3 .onion (the `tor` "
                        "profile) — reachable in Tor Browser, no public IP/DNS/ports.")
    # The GUI grew a services picker; without this flag the CLI would be strictly less
    # capable than the wizard — the same dead-default asymmetry --brand was added to
    # fix. Absent = untouched (see _cfg_from_args).
    p.add_argument("--services", default=None,
                   help="which services this local mesh runs — space/comma separated "
                        f"from: {' '.join(local_slugs())}. Omit to leave the stack as "
                        "shipped (--social/--with-tor still apply); pass an empty "
                        "string for an explicit none.")
    p.add_argument("--brand", default=DEFAULT_BRAND,
                   help=f"brand slug (default: {DEFAULT_BRAND}).")
    p.add_argument("--cluster-domain", default="",
                   help="public apex domain (REQUIRED in prod).")
    p.add_argument("--source-mode", choices=("clone", "existing"), default="clone",
                   help="'clone' (default) = make stack-clone downloads/updates all "
                        "repos into ./.stack-src and compose builds from there — "
                        "today's exact behaviour. 'existing' = build from a tree you "
                        "already have (--source-dir), with STACK_NO_CLONE=1 so your "
                        "checkouts are never fetched or git-reset.")
    p.add_argument("--source-dir", default="",
                   help="the source tree for --source-mode existing; each service "
                        "builds from <dir>/hugmesh-<name>.")
    p.add_argument("--web-locales", default="",
                   help="translation catalogs the web login image ships, comma-"
                        "separated (e.g. de,fr,pt-BR). EMPTY (default) = English-"
                        "only: zero catalog files, zero catalog requests. English is "
                        "the source language and needs no catalog.")
    p.add_argument("--login-primary", default="",
                   help="web login-theme primary colour (#RRGGBB). Derives the full "
                        "palette (core/theme.py) into HUG_THEME_CSS; the "
                        "login-ui writes it to snap-theme.css at container start. "
                        "EMPTY (default) = the shipped brand, byte-identical.")
    p.add_argument("--login-secondary", default="",
                   help="web login-theme secondary/accent colour (#RRGGBB); empty = "
                        "the shipped accent (#7c4dff).")
    p.add_argument("--login-font", default="",
                   help="web login font preset by NAME (see studio core/fonts.py "
                        "FONT_PRESETS, e.g. 'System UI', 'Bootstrap native stack'); "
                        "system stacks only — no CDN (the shipped CSP blocks it), no "
                        "bundled binaries. Font-file upload lives in the Studio GUI "
                        "and scripts/tooling/derive-theme.py, which also record the "
                        "licence decision.")
    p.add_argument("--idp", choices=IDP_CHOICES, default="casdoor",
                   help="identity provider (I6.6): casdoor (DEFAULT — the built-in "
                        "IdP; threads NOTHING, byte-identical env) | entra | aws | "
                        "oidc. External providers thread OIDC_ISSUER/OIDC_CLIENT_ID/"
                        "OIDC_JWKS_URI into the stack env; the Makefile maps them "
                        "onto CASDOOR_ISSUER_URI/CASDOOR_APP_CLIENT_ID/"
                        "CASDOOR_JWKS_URI, so gateway + BFF token VALIDATION runs "
                        "against the external issuer/JWKS. HONEST LIMIT: native "
                        "login/MFA/role claims stay Casdoor-coupled — no full "
                        "external login round-trip in the local test stack "
                        "(docs/IDENTITY-PROVIDERS.md).")
    p.add_argument("--idp-issuer", default="",
                   help="external OIDC issuer URL (https://…; required unless "
                        "--idp casdoor).")
    p.add_argument("--idp-client-id", default="",
                   help="external OIDC client id (public identifier — never a "
                        "secret; required unless --idp casdoor).")
    p.add_argument("--idp-jwks", default="",
                   help="external JWKS URL override (empty = the provider's "
                        "documented default derived from the issuer).")
    # Per-domain OWN Casdoor (issue #47) — the Domains-table 'Sign-in' choice
    # (core.config.Domain.idp) on the CLI: one repeatable flag per domain whose
    # row says 'own'. Omitted entirely (every domain keeps the DEFAULT —
    # superdomain Casdoor), the config/env/plan stay byte-identical, the same
    # omit-when-default rule the manifest emitters follow.
    p.add_argument("--own-casdoor-domain", action="append", default=None,
                   metavar="NAME",
                   help="a domain whose sign-in runs its OWN Casdoor instance "
                        "instead of the superdomain's central Casdoor (issue "
                        "#47 — the per-domain Domains-table choice; REPEAT the "
                        "flag per domain). Each named domain gets its own "
                        "Casdoor (+ postgres) behind the `own-casdoor` compose "
                        "profile, host ports 8001+ in the order given, issuer "
                        "http://casdoor-<slug>.localtest.me:<port>. Domains "
                        "NOT named keep the default superdomain sign-in.")
    key = p.add_mutually_exclusive_group()
    key.add_argument("--authkey-file", default="",
                     help="path to a file holding the tailnet/headscale auth key "
                          "(REQUIRED in prod; keeps the secret off the process table).")
    key.add_argument("--authkey", default="",
                     help="the tailnet/headscale auth key inline (prefer --authkey-file).")
    p.add_argument("--node-name", default="",
                   help="optional hostname on the tailnet (prod overlay).")
    p.add_argument("--login-server", default="",
                   help="optional self-hosted headscale control-plane URL (prod overlay).")
    p.add_argument("--generator-dir", default=_REPO_ROOT,
                   help="the hugmesh-generator checkout (default: this module's repo).")
    args = p.parse_args(argv)

    if args.subcommand in ("mesh-save", "mesh-restore"):
        return _saved_mesh_cli(args)

    cfg = _cfg_from_args(args)
    boot = LocalMeshBootstrap(args.generator_dir, cfg)

    if args.subcommand == "plan":
        print(boot.plan())
        return 0

    if args.subcommand == "status":
        for line in boot.status():
            print(line)
        return 0

    if args.subcommand == "down":
        ok, log = boot.down()
        for line in log:
            print(line)
        return 0 if ok else 1

    # up — the ONLY action that mints + starts. Show the plan, then (prod) require a
    # real-TTY confirm with NO bypass flag (golive's posture: unattended from-scratch
    # prod bring-up is not offered).
    print(boot.plan())
    print()
    if cfg.is_prod():
        rc = _confirm_prod("GENERATE credentials and START from scratch")
        if rc:
            return rc
    ok, log = boot.up()
    for line in log:
        print(line)
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
