"""Per-domain OWN-Casdoor compose overlay (issue #47) — the LOCAL/compose lane.

A superadmin's Domains table can now say, per domain, WHERE its sign-in lives
(core.config.Domain.idp): "superdomain" (the default — the mesh's one central
Casdoor, today's stack byte-for-byte) or "own" (the domain runs its OWN Casdoor
instance). This module is the local-stack translation of "own": it renders a
docker-compose OVERLAY with one Casdoor (+ its postgres) per own-idp domain,
mirroring the PROVEN second-Casdoor wiring of tests/stack/compose.brand-b.yaml
service for service, and derives the multi-issuer registry env
(APP_TENANCY_ISSUERS / APP_TENANCY_HOSTS) the gateways' opt-in per-brand token
decoder consumes — the exact env-var contract `make stack-up BRAND_B=1` threads via the
Makefile's STACK_BRAND_B_ENV, scaled from one hardcoded second brand to N
domains.

PORT ALLOCATION: brand A's central Casdoor owns host :8000; compose.brand-b.yaml
proved the second instance on host :8001 with the container LISTEN port pinned
at 8000 (an httpport env override was tried and DISPROVEN LIVE — see that
file's note). Own-idp domains continue the same sequence in Domains-table
order: 8001, 8002, …. BRAND_B is a test-only knob for the same first slot; the
two are not meant to be composed.

ISSUER DERIVATION (per domain): http://casdoor-<slug>.localtest.me:<port> —
the exact shape brand-b standardizes. It resolves BOTH on the host
(localtest.me -> 127.0.0.1, published port) and in-network (the dotted service
alias below), which is required because the per-brand decoder runs OIDC
discovery against the iss URL from INSIDE the containers.

Everything here is pure text derivation (Qt-free, docker-free, never raises on
domain content — names were already validated at the table). LocalStackNode
does the writing + env threading; the Makefile the wildcard -f include + the
`own-casdoor` profile gating (a stale overlay with OWN_CASDOOR unset changes
nothing — the BRAND_B gating shape).
"""
from __future__ import annotations

import os

from .config import default_brand_id, runs_own_casdoor

# Base host port of the per-domain sequence (brand A's Casdoor owns :8000; the
# brand-b proof runs the second instance on :8001).
BASE_PORT = 8001
# The single opt-in compose profile EVERY generated service sits behind.
PROFILE = "own-casdoor"
# Where LocalStackNode writes the overlay, relative to the generator dir.
# Dot-prefixed + gitignored like tests/stack/.theme.css: generated per
# bring-up, never committed, and a terminal `make stack-up` keeps honouring it
# (the Makefile's wildcard -f include).
OVERLAY_RELPATH = os.path.join("tests", "stack", ".compose.own-domains.yaml")


def own_domain_names(domains) -> tuple[str, ...]:
    """The names of the domains that run their OWN Casdoor (idp='own' with no external
    provider — config.runs_own_casdoor), in table order (the order the port sequence
    is allocated from). Accepts config.Domain rows."""
    return tuple(d.name for d in domains if runs_own_casdoor(d) and d.name)


def slug(name: str) -> str:
    """DNS name -> compose-safe service/tenant slug ("acme.example" ->
    "acme-example") — the analogue of brand-b's literal 'brandb' id. Since #654 this
    is the brand's DEFAULT id (config.default_brand_id, one rule in one place); a
    record may store a different id, which brand_model.brand_id prefers."""
    return default_brand_id(name)


def port_for(index: int) -> int:
    """Published host port of the index-th own-idp domain (0-based table order)."""
    return BASE_PORT + index


# The first port a Studio own-sign-in brand may take while the test-only BRAND_B knob
# is set: BRAND_B owns :8001 (compose.brand-b.yaml), so the Studio's brands start one
# higher (hugmesh-generator#654, D4). Without BRAND_B the sequence is BASE_PORT as
# before.
BASE_PORT_WITH_BRAND_B = BASE_PORT + 1


def ports_for(names, stored=None, *, brand_b: bool = False) -> dict[str, int]:
    """name -> published host port for the own-sign-in domains ``names``, honouring
    the ports the brand record already STORES (``stored``: name -> port, 0 = none)
    and allocating the rest from the first free port of the sequence (D4: a stored
    port is never recomputed from table position, so removing or reordering a brand
    moves nobody else's issuer). A stored port that two names claim is kept by the
    first and re-allocated for the second, so one port can never serve two brands.
    With ``stored`` None and ``brand_b`` False this is exactly ``port_for(index)``."""
    stored = dict(stored or {})
    base = BASE_PORT_WITH_BRAND_B if brand_b else BASE_PORT
    out: dict[str, int] = {}
    taken: set[int] = set()
    for n in names:
        p = int(stored.get(n) or 0)
        if p >= base and p not in taken:
            out[n] = p
            taken.add(p)
    nxt = base
    for n in names:
        if n in out:
            continue
        while nxt in taken:
            nxt += 1
        out[n] = nxt
        taken.add(nxt)
        nxt += 1
    return out


def brand_id_for(name: str, ids=None) -> str:
    """The one text every consumer of an own-sign-in domain shares (#654, D4): the
    id the brand record STORES for ``name`` (``ids``: name -> id) when it has one,
    else the derived slug. Every service name, volume name, tenant key and issuer
    below goes through this, so a stored id reaches all of them or none."""
    return str((ids or {}).get(name) or "").strip() or slug(name)


def issuer_for(name: str, index: int, port: int | None = None,
               brand_id: str = "") -> str:
    """The per-domain Casdoor issuer/origin URL (the brand-b shape: PUBLISHED
    host URL, resolvable in-network via the dotted alias). ``port`` (a stored
    port, see :func:`ports_for`) wins over the table-position default; ``brand_id``
    (a stored id) over the derived slug."""
    return (f"http://casdoor-{brand_id or slug(name)}.localtest.me:"
            f"{port or port_for(index)}")


def overlay_path(generator_dir: str) -> str:
    return os.path.join(generator_dir, OVERLAY_RELPATH)


def tenancy_env(names, base_issuer: str, ports=None, ids=None) -> dict[str, str]:
    """The gateways' opt-in multi-issuer registry for the own-idp domains: the
    central issuer stays tenant `default`, each own domain maps its derived
    issuer AND its Host to its slug (STACK_BRAND_B_ENV's shape, scaled per
    domain). {} when no domain opted in, so the untouched `make stack-*` env
    stays byte-identical — the same emit-nothing-by-default rule every other
    stack knob follows. ``ports`` (name -> port, :func:`ports_for`) overrides the
    table-position ports; None keeps them. ``ids`` (name -> stored brand id,
    :func:`brand_id_for`) names the tenant keys; None derives them as before."""
    names = tuple(names)
    if not names:
        return {}
    ports = dict(ports or {})
    issuers = [f"{base_issuer}=default"] + [
        f"{issuer_for(n, i, ports.get(n), brand_id_for(n, ids))}={brand_id_for(n, ids)}"
        for i, n in enumerate(names)]
    hosts = [f"{n}={brand_id_for(n, ids)}" for n in names]
    return {"APP_TENANCY_ISSUERS": ",".join(issuers),
            "APP_TENANCY_HOSTS": ",".join(hosts)}


_HEADER = """\
# .compose.own-domains.yaml — GENERATED by HugMesh Studio (core/own_casdoor.py).
# DO NOT EDIT: regenerated on every Studio bring-up whose Domains table carries
# an idp='own' row. One Casdoor (+ postgres) per own-idp domain, mirroring the
# PROVEN wiring of compose.brand-b.yaml (see that file for why the container
# LISTEN port stays 8000 and only the PUBLISHED host port moves). Every service
# sits behind the `own-casdoor` profile (OWN_CASDOOR=1 -> the Makefile passes
# --profile own-casdoor), so this file lying around changes nothing by itself.
# Delete it — or bring the stack up without any own-idp domain — for a
# single-Casdoor stack.
name: hugmesh-local

services:
"""

_SERVICE_TMPL = """\
  casdoor-{slug}-db:
    image: postgres:16-alpine
    profiles: ["{profile}"]
    environment: {{ POSTGRES_DB: casdoor, POSTGRES_USER: casdoor, POSTGRES_PASSWORD: casdoor }}
    volumes: [casdoor-{slug}-pg:/var/lib/postgresql/data]
    healthcheck: {{ test: ["CMD-SHELL", "pg_isready -U casdoor"], interval: 5s, retries: 20 }}

  # {name}: own Casdoor (issue #47). Issuer/origin = the PUBLISHED host URL;
  # in-network JWKS = http://casdoor-{slug}:8000/.well-known/jwks (brand-b's split).
  casdoor-{slug}:
    image: casbin/casdoor:latest
    profiles: ["{profile}"]
    depends_on: {{ casdoor-{slug}-db: {{ condition: service_healthy }} }}
    environment:
      RUNNING_IN_DOCKER: "true"
      driverName: postgres
      dataSourceName: "user=casdoor password=casdoor host=casdoor-{slug}-db port=5432 sslmode=disable dbname=casdoor"
      origin: "{issuer}"
    ports:
      # host {port} -> container 8000 (the central Casdoor owns host 8000;
      # own-idp domains take 8001+ in Domains-table order — the brand-b scheme).
      - "{port}:8000"
    networks:
      default:
        aliases: [casdoor-{slug}.localtest.me]

"""


def compose_overlay(names, ports=None, ids=None) -> str:
    """The overlay YAML text for the given own-idp domain names, "" when there
    are none (write nothing — the superdomain-only stack stays byte-identical).
    ``ports`` and ``ids`` as in :func:`tenancy_env`: the same mappings must be given
    to both, or the issuer the gateway trusts and the service Casdoor runs as
    disagree."""
    names = tuple(names)
    if not names:
        return ""
    ports = dict(ports or {})
    parts = [_HEADER]
    for i, name in enumerate(names):
        port = ports.get(name) or port_for(i)
        bid = brand_id_for(name, ids)
        parts.append(_SERVICE_TMPL.format(
            name=name, slug=bid, profile=PROFILE,
            issuer=issuer_for(name, i, port, bid), port=port))
    parts.append("volumes:\n")
    parts += [f"  casdoor-{brand_id_for(n, ids)}-pg:\n" for n in names]
    return "".join(parts)
