"""Fleet build on the TUI (#587; operator decision 71 = A: TUI parity in the same PR).

The GUI's fleet window (``gui/pages/fleet.py``, ``hugmesh_studio --fleet``) is:
Platforms -> Roles & boards -> Shared options -> **Domains** -> **Domain services** ->
Review -> Run. Before #587 the TUI had no fleet at all. This screen
(``python -m hugmesh_studio.tui --fleet``) hosts the same route over the same Qt-free
objects:

* OPTIONS — every ``FleetConfig`` knob, set by NAME (``set x86_omnibus on``,
  ``set rpi_roles pki backend``), validated by ``FleetConfig.validate`` — the same
  fail-closed allowlist the GUI's preview uses. One generic surface instead of the
  GUI's five grouped panes: the knobs ARE the field names build-all-roles.sh documents;
* DOMAINS — row 1 is the fleet's own domain (the ``cluster_domain`` knob, else the
  builders' default: ``core.fleet.seed_fleet_domains``, the GUI's call), added rows via
  ``a NAME``; leaving it goes through ``core.fleet.commit_fleet_domains`` (the GUI's
  call), which refuses a junk / duplicate / own-again row with the same words. No
  Sign-in column, as on the GUI: a fleet stands up no Casdoor;
* DOMAIN SERVICES — ``tui/domain_services_step.DomainServicesScreen``, the image
  flow's own screen, walking the rows one domain at a time with the fleet's lane note
  (``core.fleet.FLEET_LANE_NOTE``, the GUI's words);
* REVIEW — the SAME gate the GUI's preflight runs (``core.fleet.fleet_gate_reason``),
  and only once it is clear, the exact ``build-all-roles.sh`` command for a native
  root builder (``FleetDriver.command_string``).

What it does NOT do: start the fleet. A fleet run needs root or the docker builder
image and writes a session record; the GUI's window does both. The review says so and
hands over the command instead.
"""
from __future__ import annotations

from dataclasses import fields

from ..core.config import IdentityValidationError
from ..core.domain_services import normalise_slugs, record_reviewed, reviewed_names
from ..core.fleet import (FLEET_LANE_NOTE, WITH_TOR_NOTE, FleetConfig, FleetDomains,
                          FleetDriver, commit_fleet_domains, fleet_domain_fields,
                          fleet_gate_reason, seed_fleet_domains)
from ..core.local_mesh_domains import DOMAIN_NAME_RE
from ..core.config import Domain
from ..core.platform_info import HostInfo
from . import model
from .domain_services_step import DomainServicesScreen

__all__ = ["FleetScreen", "FLEET_KNOBS", "PREVIEW_HOST"]

#: Every FleetConfig field the OPTIONS stage sets by name — all of them but the two
#: the Domains steps own.
FLEET_KNOBS: tuple[str, ...] = tuple(
    f.name for f in fields(FleetConfig)
    if f.name not in ("domains", "domain_services_reviewed"))

#: The host the review's command is rendered for: a native ROOT builder, so the
#: preview is the bare command (no sudo, no docker wrapper). A PREVIEW — never run.
PREVIEW_HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                        has_kvm=False, is_root=True, builder_image="hugmesh-builder")

_TRUE = ("1", "on", "yes", "true", "y")
_FALSE = ("0", "off", "no", "false", "n", "-")


class FleetScreen:
    """``options`` -> ``domains`` -> ``services`` -> ``review``."""

    slug = "fleet"
    title = "Fleet build"
    #: ``b`` means BACK inside the flow; ``q`` still quits (not claimed).
    wants_q = False

    def __init__(self):
        self.stage = "options"
        self.services = DomainServicesScreen(
            cfg_of=lambda j: self.state(j),
            on_continue=lambda j: self._goto(j, "review"),
            on_back=lambda j: self._goto(j, "domains"),
            lane_note=FLEET_LANE_NOTE)

    # ── state (on the journey, never in j.cfg — a fleet is not an ImageConfig) ────
    @staticmethod
    def options(j) -> FleetConfig:
        cfg = getattr(j, "fleet_cfg", None)
        if cfg is None:
            cfg = FleetConfig()
            j.fleet_cfg = cfg
        return cfg

    @staticmethod
    def state(j) -> FleetDomains:
        st = getattr(j, "fleet_domains", None)
        if st is None:
            st = FleetDomains()
            j.fleet_domains = st
        return st

    def config(self, j) -> FleetConfig:
        """The FleetConfig the review gates and previews: the knobs + the rows, built
        through the same ``fleet_domain_fields`` the GUI's collect() uses."""
        base = self.options(j)
        kw = {f.name: getattr(base, f.name) for f in fields(FleetConfig)}
        kw.update(fleet_domain_fields(self.state(j)))
        return FleetConfig(**kw)

    def _goto(self, j, stage: str) -> None:
        if stage == "domains":
            seed_fleet_domains(self.state(j), self.options(j).cluster_domain)
        if stage == "services":
            self.services.enter(j)
        self.stage = stage

    # ── screen protocol ─────────────────────────────────────────────────────────
    def enter(self, j) -> None:  # noqa: ARG002
        self.stage = "options"

    def prompt(self, j) -> str:
        if self.stage == "services":
            return self.services.prompt(j)
        return f"fleet-{self.stage}> "

    def lines(self, j) -> list[str]:
        return getattr(self, f"_lines_{self.stage}")(j)

    def feed(self, j, line: str) -> None:
        getattr(self, f"_feed_{self.stage}")(j, line.strip())

    # ── options ─────────────────────────────────────────────────────────────────
    def _lines_options(self, j) -> list[str]:
        cfg, default = self.options(j), FleetConfig()
        out = ["Build every role of a release with scripts/build-all-roles.sh. Set the "
               "knobs by name; anything not set keeps the script's own default.", ""]
        rows = [[name, str(getattr(cfg, name))] for name in FLEET_KNOBS
                if getattr(cfg, name) != getattr(default, name)]
        if rows:
            out += model.format_table(["knob", "value"], rows)
        else:
            out.append("(every knob at its default — the default fleet: rpi5 "
                       "pki/backend/frontend + x86 pki/backend/frontend/backend-gpu)")
        out += ["", "knobs: " + " ".join(FLEET_KNOBS), "",
                # the GUI's note under its Tor checkbox — the same words here
                "with_tor: " + WITH_TOR_NOTE, "",
                "commands: set NAME VALUE (on/off for switches; - resets) · "
                "Enter=continue to Domains"]
        return out

    def _feed_options(self, j, line: str) -> None:
        if line == "":
            self._goto(j, "domains")
            return
        verb, _, rest = line.partition(" ")
        name, _, value = rest.strip().partition(" ")
        value = value.strip()
        if verb.lower() != "set" or name not in FLEET_KNOBS:
            j.status = (f"unrecognised command: {line!r}" if verb.lower() != "set"
                        else f"no such knob: {name!r}")
            return
        cfg = self.options(j)
        default = getattr(FleetConfig(), name)
        old = getattr(cfg, name)
        try:
            if value == "-":
                new = default
            elif isinstance(default, bool):
                if value.lower() not in _TRUE + _FALSE:
                    j.status = f"{name} is a switch: on or off"
                    return
                new = value.lower() in _TRUE
            elif isinstance(default, int):
                new = int(value)
            else:
                new = value
            setattr(cfg, name, new)
            cfg.validate()
        except (ValueError, IdentityValidationError) as e:
            setattr(cfg, name, old)
            j.status = f"refused: {e}"
            return
        j.status = f"{name} -> {getattr(cfg, name)}"

    # ── domains ─────────────────────────────────────────────────────────────────
    def table(self, j) -> tuple[list[str], list[list[str]]]:
        st = self.state(j)
        done = reviewed_names(st)
        rows = []
        for i, d in enumerate(st.domains, 1):
            svcs = ", ".join(normalise_slugs(d.optional_services)) or "cluster default"
            rows.append([f"{i} (own)" if i == 1 else str(i), d.name,
                         svcs if d.name in done else "not configured yet"])
        return ["#", "domain", "services"], rows

    def _lines_domains(self, j) -> list[str]:
        out = ["Every domain this fleet's mesh serves, its own domain first (the "
               "cluster_domain knob, or the builders' default). Each one gets its own "
               "service page on the next step, and the review refuses while any domain "
               "here has never been through it.", ""]
        out += model.format_table(*self.table(j))
        out += ["", "Row 1 is this fleet's OWN domain: it is always served and cannot "
                "be removed (set cluster_domain on the options step to rename it).",
                "commands: a NAME=add a domain · d NUMBER=delete · b=back to the "
                "options · Enter=continue"]
        return out

    def _feed_domains(self, j, line: str) -> None:
        st = self.state(j)
        if line == "":
            problems = commit_fleet_domains(st, st.domains[1:])
            if problems:
                j.status = "\n".join(problems + ["Fix or remove these rows to continue."])
                return
            self._goto(j, "services")
            return
        if line.lower() == "b":
            self.stage = "options"
            return
        verb, _, arg = line.partition(" ")
        verb, arg = verb.lower(), arg.strip()
        if verb == "a":
            if not DOMAIN_NAME_RE.match(arg):
                j.status = (f"not a domain name: {arg!r} (lowercase dotted hostname, "
                            "e.g. chat.example.org)")
                return
            if arg in st.names():
                j.status = (f"{arg} is this fleet's own domain (row 1) — it is already "
                            "listed" if arg == st.own_name else f"already listed: {arg}")
                return
            st.domains.append(Domain(name=arg, title=""))
            return
        if verb == "d":
            try:
                n = int(arg)
            except ValueError:
                n = 0
            if not 1 <= n <= len(st.domains):
                j.status = f"no such domain row: {arg!r}"
                return
            if n == 1:
                j.status = "row 1 is this fleet's own domain — it cannot be removed."
                return
            removed = st.domains.pop(n - 1)
            record_reviewed(st, st.domain_services_reviewed)
            j.status = f"removed {removed.name}"
            return
        j.status = f"unrecognised command: {line!r}"

    # ── services (the image flow's screen, re-hosted) ───────────────────────────
    def _lines_services(self, j) -> list[str]:
        return self.services.lines(j)

    def _feed_services(self, j, line: str) -> None:
        self.services.feed(j, line)

    # ── review: the gate, then the command ──────────────────────────────────────
    def refusal(self, j) -> str:
        return fleet_gate_reason(self.config(j))

    def command(self, j) -> str:
        return FleetDriver(j.generator_dir, PREVIEW_HOST).command_string(
            self.config(j), "native")

    def _lines_review(self, j) -> list[str]:
        refusal = self.refusal(j)
        if refusal:
            return [refusal, "", "commands: b=back to the Domain services step · "
                    "Enter=back to the options"]
        st = self.state(j)
        out = ["Domains and their services are configured (recorded with the fleet, "
               "not passed to any builder — see the Domain services step's note).", ""]
        out += model.format_table(*self.table(j))
        try:
            cmd = self.command(j)
        except IdentityValidationError as e:
            cmd = f"INVALID: {e}"
        out += ["", "The TUI does not start the fleet (a run needs root or the docker "
                "builder image, and the GUI's fleet window records its session). The "
                "exact command, for a native root builder:",
                "  " + cmd,
                "", f"({len(st.domains)} domain(s) recorded; build-all-roles.sh "
                "receives none of them.)",
                "commands: b=back to the Domain services step · Enter=back to the "
                "options"]
        return out

    def _feed_review(self, j, line: str) -> None:
        if line.lower() == "b":
            self._goto(j, "services")
            return
        if line == "":
            self.stage = "options"
            return
        j.status = f"unrecognised command: {line!r}"
