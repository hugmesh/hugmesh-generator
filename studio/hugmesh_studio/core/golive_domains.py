"""Go-Live, per domain — the Qt-free half (#587, Go-Live part).

The ask: "Go-Live reads the baked domains[] and offers exposure per domain; keep the
single field as the default domain". Two faces render this module and nothing else
decides it: ``gui/pages/golive.py`` (the Inputs step's domain picker + the Generate
step's exposure table) and ``tui/golive.py`` (the TUI's go-live screen). Both stay
THIN front-ends of the canonical driver, which takes ONE ``--domain`` per ``plan``:
nothing here changes what the driver is asked to do, it only says which domain a run
covers and what every OTHER domain on the device gets.

WHAT IS "BAKED" ON THE DEVICE, measured on the builders rather than assumed:

* ``/etc/hugmesh/cluster-domain`` — every node; the primary domain, and what the
  driver itself autofills ``--domain`` from (``GoLiveDriver.autofill_domain``);
* ``/etc/hugmesh/domains`` — one name per line, written by build-x86-host-stage4.sh
  ONLY on a CLIENT role (the ``--domains`` tie; node roles ignore ``--domains``). So on
  the ingress node — where go-live runs — the list is normally just the primary, and
  this module says so rather than inventing domains a node does not carry;
* ``/var/lib/hugmesh/tor/hostname`` + ``/var/lib/hugmesh/tor/<slug>.hostname`` — the
  node's primary onion and one exported onion per Tor domain slug (decision 68 = A;
  hugmesh-tor-reconcile writes them, the go-live registry's ``tor-onion`` emitter reads
  the same files into ``domain-onions.txt``). A slug is NOT a DNS name, so it is shown
  as the slug the node exports, never matched to a domain by guesswork.

Every path has an env seam (the driver's own ``GOLIVE_CLUSTER_DOMAIN_FILE`` and the
registry's ``GL_ONION_EXPORT_DIR``, plus ``GOLIVE_DOMAINS_FILE``) so tests and a
non-device host read fixtures.
"""
from __future__ import annotations

import os
import re

__all__ = [
    "CLUSTER_DOMAIN_FILE", "DOMAINS_FILE", "ONION_EXPORT_DIR", "NO_EXTRA_DOMAINS_NOTE",
    "ONION_HOSTNAME_ENV", "baked_domains", "onion_export_state", "onion_exports",
    "exposure_rows", "exposure_lines", "plan_rows",
]

CLUSTER_DOMAIN_FILE = "/etc/hugmesh/cluster-domain"
DOMAINS_FILE = "/etc/hugmesh/domains"
ONION_EXPORT_DIR = "/var/lib/hugmesh/tor"

#: Said under the picker when the device carries no domain beyond the primary — which
#: is the NORMAL case on a node, and must not read as a fault.
NO_EXTRA_DOMAINS_NOTE = (
    "This device carries no domain beyond its cluster domain (/etc/hugmesh/domains is "
    "baked only into client images). Each Go-Live run exposes ONE domain; to expose "
    "another, run it again and type that domain.")

# the builders' --domains element shape (_validate_dnsname): lowercase dotted host
_DNS_RE = re.compile(r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$")
# hugmesh-tor-reconcile's slug shape ([a-z0-9][a-z0-9-]{0,62})
_SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")
# a v3 onion address (56 base32 chars + .onion)
_ONION_RE = re.compile(r"^[a-z2-7]{56}\.onion$")


#: The driver's own override of the exported hostname (specs/usr/lib/hugmesh/
#: go-live-providers.sh ``_glp_onion_hostname``: a from-a-dev-box preview, or a node
#: queried over the mesh). The Studio honours the same variable, so the table and the
#: card the driver writes cannot name different addresses.
ONION_HOSTNAME_ENV = "GL_ONION_HOSTNAME"


def _read_words(path: str) -> list[str]:
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return [ln.strip() for ln in fh.read().splitlines()]
    except OSError:
        return []


def _read_lines(path: str) -> list[str] | None:
    """The file's stripped lines; ``None`` when there is no such file; any OTHER
    OSError is raised — a file that exists but cannot be read is not "no file"."""
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return [ln.strip() for ln in fh.read().splitlines()]
    except FileNotFoundError:
        return None


def baked_domains(primary: str = "", domains_file: str | None = None) -> list[str]:
    """The domains this device serves, primary FIRST, deduped, in file order.

    ``primary`` is what the driver autofills (the baked cluster domain); then every
    line of ``/etc/hugmesh/domains`` (``$GOLIVE_DOMAINS_FILE``) that is a DNS name —
    comments, blanks and junk are skipped, never passed on to ``--domain``."""
    path = domains_file or os.environ.get("GOLIVE_DOMAINS_FILE", DOMAINS_FILE)
    out: list[str] = []
    for name in [(primary or "").strip().lower(), *_read_words(path)]:
        name = name.lower()
        if name and not name.startswith("#") and _DNS_RE.match(name) and name not in out:
            out.append(name)
    return out


def onion_export_state(export_dir: str | None = None
                       ) -> tuple[str, list[tuple[str, str]], str]:
    """``(primary onion, [(slug, onion), ...], why the export could not be read)`` as
    this host exports them — "" / [] when there are none, and the third item "" when
    the export directory is simply absent (no Tor on this host).

    UNREADABLE IS NOT ABSENT. hugmesh-tor-reconcile keeps /var/lib/hugmesh/tor
    root-only (``chmod 0700``), so a Studio run as a user on a Tor node cannot read it
    — the NORMAL state there. Until the post-merge review of #645 every OSError
    collapsed into "" / [] and the plan then said the onion was "not minted on this
    host", sending the operator to look for a fault on a node that had minted it. Now
    the reason (``"<path>: Permission denied"``) is carried and :func:`exposure_rows`
    says what it cannot see. A missing directory or file stays "" / [] / "".

    ``GL_ONION_HOSTNAME`` (:data:`ONION_HOSTNAME_ENV`) overrides the exported primary
    exactly as the driver's tor-onion card does. Only well-formed v3 addresses and
    reconcile-shaped slugs count, from the files AND from the variable — the files
    are written by a root agent, but a half-written, hand-edited or half-typed one
    must not reach a page as an address to share."""
    d = export_dir or os.environ.get("GL_ONION_EXPORT_DIR", ONION_EXPORT_DIR)
    unreadable = ""

    def _lines(name: str) -> list[str]:
        nonlocal unreadable
        path = os.path.join(d, name)
        try:
            return _read_lines(path) or []
        except OSError as e:                    # EACCES through the 0700 directory, ...
            unreadable = unreadable or f"{path}: {e.strerror or e}"
            return []

    override = os.environ.get(ONION_HOSTNAME_ENV, "").strip()
    if override and _ONION_RE.match(override):
        primary = override
    else:
        words = [w for w in _lines("hostname") if w]
        primary = words[0] if words and _ONION_RE.match(words[0]) else ""
    per: list[tuple[str, str]] = []
    try:
        names = sorted(os.listdir(d))
    except FileNotFoundError:
        names = []
    except OSError as e:                        # the directory exists and refuses us
        names = []
        unreadable = unreadable or f"{d}: {e.strerror or e}"
    for fn in names:
        if not fn.endswith(".hostname") or fn == "hostname":
            continue
        slug = fn[: -len(".hostname")]
        addr = next((w for w in _lines(fn) if w), "")
        if _SLUG_RE.match(slug) and _ONION_RE.match(addr):
            per.append((slug, addr))
    return primary, per, unreadable


def onion_exports(export_dir: str | None = None) -> tuple[str, list[tuple[str, str]]]:
    """``(primary onion, [(slug, onion), ...])`` — :func:`onion_export_state` without
    the reason; callers that render a plan want the reason and use the state."""
    primary, per, _unreadable = onion_export_state(export_dir)
    return primary, per


#: The onion row when the export exists but this user cannot read it (``{why}`` is
#: the path and the OS's reason). It must NOT read as "not minted": the export is
#: root-only by design, and a plan run as the same user writes an onion.txt that is
#: blind for the same reason (the card reads the file with ``-r``).
ONION_UNREADABLE_HOW = (
    "cannot be read by this user ({why}) — hugmesh-tor-reconcile keeps the export "
    "root-only (mode 0700), so this says nothing about whether the onion is minted; a "
    "plan run as this user writes onion.txt as NOT-YET-MINTED for the same reason. Run "
    "the Studio (or the plan) as root to see it, or read /var/lib/hugmesh/tor/hostname "
    "on the node and pass GL_ONION_HOSTNAME=<addr>, which the table and the driver's "
    "card both honour.")


def exposure_rows(domains, chosen: str, provider_id: str, mechanism: str,
                  model_label: str, onion: str = "",
                  domain_onions=(), onion_unreadable: str = "") -> list[tuple[str, str]]:
    """``[(what, how it is reached), ...]`` — the plan for EVERY domain on the device,
    not only the one this run covers.

    * the chosen domain gets this run's mechanism (``model_label`` via ``provider_id``);
    * every other domain is said NOT to be exposed by this run — Go-Live runs once per
      domain, so the operator is told to run it again rather than left to assume;
    * with the onion mechanism no clearnet domain is exposed at all (the .onion is the
      endpoint, the driver needs no domain for it);
    * the node's onions are listed whatever the mechanism — they are live with the
      firewall CLOSED, so they are exposure the operator already has;
    * ``onion_unreadable`` (the third item of :func:`onion_export_state`) is said
      whatever the mechanism too: the export exists, so there IS Tor state on this
      host, and "not minted" would be a false statement about it."""
    rows: list[tuple[str, str]] = []
    primary = domains[0] if domains else ""
    for name in domains:
        label = name + (" (cluster domain)" if name == primary else "")
        if mechanism == "onion":
            how = ("no clearnet exposure — the onion mechanism takes no domain; this "
                   "run publishes the node's .onion")
        elif name == chosen:
            how = f"{model_label} via {provider_id} — THIS run"
        else:
            how = ("not exposed by this run — run Go-Live again with this domain "
                   "picked")
        rows.append((label, how))
    if chosen and chosen not in domains and mechanism != "onion":
        rows.append((chosen + " (typed — not baked on this device)",
                     f"{model_label} via {provider_id} — THIS run"))
    if onion:
        rows.append(("Tor: this node's onion",
                     f"https://{onion}/ — live with the firewall closed, no flip"))
    elif onion_unreadable:
        rows.append(("Tor: this node's onion",
                     ONION_UNREADABLE_HOW.format(why=onion_unreadable)))
    elif mechanism == "onion":
        rows.append(("Tor: this node's onion",
                     "not minted on this host — read /var/lib/hugmesh/tor/hostname on "
                     "the node (built with --with-tor)"))
    for slug, addr in domain_onions:
        rows.append((f"Tor: domain slug '{slug}'",
                     f"https://{addr}/ — its own onion, the same gateway"))
    return rows


def exposure_lines(rows) -> list[str]:
    """The rows as text — the ONE rendering both faces show (parity-pinned)."""
    if not rows:
        return ["(no domain known yet — type one on the Inputs step)"]
    width = max(len(w) for w, _ in rows)
    return [f"{w.ljust(width)}  {h}" for w, h in rows]


def plan_rows(driver, opts) -> list[tuple[str, str]]:
    """:func:`exposure_rows` for a live ``GoLiveDriver`` + ``GoLiveOptions`` — the ONE
    call both faces make, so the GUI's Generate step and the TUI's go-live screen
    cannot word the plan differently. The domain a run covers is ``opts.domain``, else
    the baked primary (what the driver itself would autofill)."""
    p = driver.provider(opts.provider) if opts.provider else None
    mechanism = p.mechanism if p else ""
    label = f"{p.model} ({p.mechanism})" if p else "(no provider picked)"
    domains = baked_domains(driver.autofill_domain())
    chosen = (opts.domain or "").strip().lower() or (domains[0] if domains else "")
    onion, per, unreadable = onion_export_state()
    return exposure_rows(domains, chosen, p.id if p else "?", mechanism, label,
                         onion, per, unreadable)
