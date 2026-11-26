"""Check an image config without the GUI (``hugmesh_studio --check --config FILE``).

Qt-free, and the one place the wizard's gates are put in a row for a config that was
never walked through the wizard. The Build page's Review step runs the same pieces; this
module only calls them, so the two cannot disagree about what a config is worth:

* ``unknown-key``      a key the loader would DROP without a word (``from_dict`` keeps
                       the fields it knows and ignores the rest: a typo in a hand-written
                       config silently built the default);
* ``service``          a service name outside the closed set the builders and the
                       registry know (``config.REGISTRY_SERVICES``);
* ``domain-services``  the per-domain services gate (``domain_services.gate_reason``);
* ``identity``         ``validate_identity`` and the assembly rules that run with it
                       (``WorklistConfig.materialize``: duplicate image ids and hostnames);
* ``command``          the build command can be put together (``to_cli_args``);
* ``scope``            ``config.scope_violations``, split blocking / advisory exactly as
                       the Review page splits them, read on each image AS WRITTEN (the
                       assembled image has already lost what a node's role does not take);
* ``root-size``        an explicit root image size below the builder's own floor
                       (``root_size_floor``, which the Build page also reads);
* ``preflight``        ``WorklistDriver.preflight`` / ``preflight_warnings``: this host's
                       Docker, the builder image, free disk, the output folder, the paths
                       the config names.

A PROBLEM blocks (the wizard would not let Continue through, or the builder dies after
dispatch); a WARNING is the accepted-but-wrong tier. Nothing here invents a constraint a
builder does not have.

Exit status of :func:`run_cli`: 0 nothing blocks (warnings may print), 1 at least one
problem, 2 bad input (the file cannot be read, is not JSON, or is not an object). The
``--json`` shape is ``{"ok", "kind", "images", "problems", "warnings"}``, each finding
``{"check", "image", "message"}``; ``image`` is "" for a finding about the whole config.
"""
from __future__ import annotations

import copy
import difflib
import json
import sys
from dataclasses import dataclass, field
from typing import Any, Iterable

from . import json_files, root_size_floor
from .config import (
    BUILDER_DESELECTABLE_SERVICES,
    BUILDER_SELECTABLE_SERVICES,
    MIGRATED_CONFIG_KEYS,
    MIGRATED_DOMAIN_KEYS,
    REGISTRY_SERVICES,
    SERVICES_ALL,
    SERVICES_NONE,
    Domain,
    ImageConfig,
    User,
    scope_violations,
)
from .desktop_spec import DesktopApp, DesktopSpec, ExtraUser
from .domain_services import ACTION_IMAGE_BUILD, gate_reason
from .worklist import (
    WORKLIST_INFRA_SERVICES,
    WORKLIST_SCHEMA,
    WorklistConfig,
    WorklistEntry,
    synthesize,
)

#: What the domain-services refusal says to do, for a config nobody is walking through the
#: wizard: the gate's own sentence sends a reader to "this screen" and the Back button,
#: which a terminal does not have. Only the remedy differs; the predicate is the gate's.
DOMAIN_SERVICES_REMEDY = (
    "Walk the ‘Domain services’ step in the Studio window, or, in a config written by "
    "hand, list each domain's name in domain_services_reviewed once its services say what "
    "you want (domains[].optional_services; cluster_domain_services for the main domain).")

CHECK_LOAD = "load"
CHECK_UNKNOWN_KEY = "unknown-key"
CHECK_SERVICE = "service"
CHECK_DOMAIN_SERVICES = "domain-services"
CHECK_IDENTITY = "identity"
CHECK_COMMAND = "command"
CHECK_SCOPE = "scope"
CHECK_ROOT_SIZE = "root-size"
CHECK_PREFLIGHT = "preflight"

KIND_CONFIG = "config"
KIND_WORKLIST = "worklist"

EXIT_OK = 0
EXIT_PROBLEMS = 1
EXIT_BAD_INPUT = 2


@dataclass(frozen=True)
class Finding:
    """One thing the check has to say. ``image`` is the worklist entry id the finding is
    about, "" when it is about the config as a whole (or about every image alike)."""
    check: str
    message: str
    image: str = ""

    def to_dict(self) -> dict[str, str]:
        return {"check": self.check, "image": self.image, "message": self.message}


@dataclass
class CheckReport:
    kind: str = KIND_CONFIG
    images: list[str] = field(default_factory=list)
    problems: list[Finding] = field(default_factory=list)
    warnings: list[Finding] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not self.problems

    def add(self, finding: Finding, *, blocking: bool = True) -> None:
        """Record ``finding``, once: the same words about the same image from two gates
        (the scope rule is both a check of its own and part of the driver's preflight)
        are one line."""
        if any(f.image == finding.image and f.message == finding.message
               for f in (*self.problems, *self.warnings)):
            return
        (self.problems if blocking else self.warnings).append(finding)

    def to_dict(self) -> dict[str, Any]:
        return {"ok": self.ok, "kind": self.kind, "images": list(self.images),
                "problems": [f.to_dict() for f in self.problems],
                "warnings": [f.to_dict() for f in self.warnings]}


# ── unknown keys ───────────────────────────────────────────────────────────────────────
def _close(word: str, known: Iterable[str]) -> str:
    near = difflib.get_close_matches(str(word), sorted(known), n=1, cutoff=0.6)
    return f" (did you mean {near[0]!r}?)" if near else ""


def _rows(value: Any) -> list[Any]:
    """The rows of a JSON list, or none for anything else (the loader says what it makes
    of a non-list; the scan only has to not fall over it)."""
    return value if isinstance(value, list) else []


def _scan(out: list[Finding], obj: Any, known: Iterable[str], path: str, what: str) -> None:
    """Report every key of ``obj`` not in ``known``; ``path`` locates it for the reader."""
    if not isinstance(obj, dict):
        return
    known = set(known)
    for key in obj:
        if key not in known:
            where = f"{path}{key}" if path else str(key)
            out.append(Finding(
                CHECK_UNKNOWN_KEY,
                f"unknown key {where!r}{_close(key, known)}: {what} has no such setting, "
                "so loading the config drops it and the build behaves as if it were "
                "not there"))


def _scan_desktop_spec(out: list[Finding], spec: Any, path: str) -> None:
    """The Desktop step's spec and the app / extra-user rows nested in it, which
    ``DesktopSpec.from_dict`` filters the same way (``history`` / ``last_pretend`` and
    ``flatpak_remotes`` hold free-form content by design and are not walked)."""
    _scan(out, spec, DesktopSpec.__dataclass_fields__, path, "the Desktop step's spec")
    if not isinstance(spec, dict):
        return
    for i, row in enumerate(_rows(spec.get("apps"))):
        _scan(out, row, DesktopApp.__dataclass_fields__, f"{path}apps[{i}].",
              "a Desktop app row")
    for i, row in enumerate(_rows(spec.get("extra_users"))):
        _scan(out, row, ExtraUser.__dataclass_fields__, f"{path}extra_users[{i}].",
              "a Desktop extra-user row")


def _scan_config(out: list[Finding], d: Any, prefix: str) -> None:
    """The keys of one image config (a flat file, or an envelope's ``base``) and of the
    rows nested in it that the loader filters the same way."""
    if not isinstance(d, dict):
        return
    _scan(out, d, set(ImageConfig.__dataclass_fields__) | MIGRATED_CONFIG_KEYS,
          prefix, "an image config")
    for i, row in enumerate(_rows(d.get("domains"))):
        _scan(out, row, set(Domain.__dataclass_fields__) | MIGRATED_DOMAIN_KEYS,
              f"{prefix}domains[{i}].", "a domain row")
    for i, row in enumerate(_rows(d.get("users"))):
        _scan(out, row, User.__dataclass_fields__, f"{prefix}users[{i}].", "a user row")
    _scan_desktop_spec(out, d.get("desktop_spec"), f"{prefix}desktop_spec.")


def unknown_keys(data: Any) -> list[Finding]:
    """The keys of a loaded config JSON (a flat config or a worklist envelope) that
    ``from_dict`` would DROP: not a field, not a spelling it migrates. Only the shapes
    the loader filters are walked (the config, its domain / user rows, its desktop spec,
    an envelope's entries); a free-form map such as ``managed_services`` keeps whatever
    keys it has by design."""
    out: list[Finding] = []
    if not isinstance(data, dict):
        return out
    if "schema" in data:
        _scan(out, data, ("schema", "base", "entries"), "", "a worklist envelope")
        _scan_config(out, data.get("base"), "base.")
        for i, row in enumerate(_rows(data.get("entries"))):
            _scan(out, row, WorklistEntry.__dataclass_fields__, f"entries[{i}].",
                  "a worklist entry")
            if isinstance(row, dict):
                _scan_desktop_spec(out, row.get("desktop_spec"), f"entries[{i}].desktop_spec.")
    else:
        _scan_config(out, data, "")
    return out


# ── service names ──────────────────────────────────────────────────────────────────────
def _split(tokens: Any, *, comma: bool) -> list[Any]:
    """The names in one service list, as the builder reads them: each string element is
    word-split (``--optional-services`` is joined with spaces and the builder splits it
    again; ``--exclude-services`` also takes commas), so ``["akkoma tuwunel"]`` is two
    names. A non-string element is kept whole, to be refused."""
    out: list[Any] = []
    for tok in tokens:
        if isinstance(tok, str):
            out.extend((tok.replace(",", " ") if comma else tok).split())
        else:
            out.append(tok)
    return out


def _service_problems(where: str, tokens: Any, *, kind: str, x86_in_play: bool
                      ) -> tuple[list[str], list[str]]:
    """``(blocking, advisory)`` for one service list. ``kind`` is how the list is used:
    ``select`` (``--optional-services``: also takes the ``none`` / ``all`` sentinels and
    ``-anubis``), ``exclude`` (``--exclude-services``) or ``domain`` (a manifest row:
    only names the registry knows, nothing the builder reads)."""
    if tokens is None:
        return [], []
    if not isinstance(tokens, (list, tuple)):
        return [f"{where} must be a list of service names, not {tokens!r}"], []
    blocking: list[str] = []
    advisory: list[str] = []
    for tok in (_split(tokens, comma=kind == "exclude") if kind != "domain"
                else list(tokens)):
        if not isinstance(tok, str) or not tok:
            blocking.append(f"{where}: {tok!r} is not a service name")
            continue
        if kind == "select" and tok in (SERVICES_NONE, SERVICES_ALL):
            continue
        base = tok[3:] if tok.startswith("no-") else tok
        base = base[1:] if base.startswith("-") else base
        if base != tok:
            if kind == "select" and base in BUILDER_DESELECTABLE_SERVICES:
                continue
            blocking.append(
                f"{where}: {tok!r} uses the '-<name>' / 'no-<name>' spelling, which is "
                f"only for {', '.join(BUILDER_DESELECTABLE_SERVICES)} in optional_services"
                + (f"; to exclude a service write its plain name ({base!r})"
                   if kind == "exclude" else ""))
            continue
        if base not in REGISTRY_SERVICES:
            blocking.append(
                f"{where}: unknown service {tok!r}{_close(tok, REGISTRY_SERVICES)}. "
                f"The services are: {', '.join(BUILDER_SELECTABLE_SERVICES)}")
        elif kind != "domain" and base not in BUILDER_SELECTABLE_SERVICES:
            text = (f"{where}: {tok!r} is a service no builder bakes (it is switched on "
                    "in the running cluster), so naming it here does nothing")
            # the x86 builder refuses it after dispatch; the rpi5 one accepts and ignores
            (blocking if x86_in_play else advisory).append(text)
    return blocking, advisory


def service_findings(base: ImageConfig, entries: Iterable[WorklistEntry] = ()
                     ) -> tuple[list[Finding], list[Finding]]:
    """``(blocking, advisory)`` for every service list a config carries, against the
    closed set of services (``config.REGISTRY_SERVICES``). A name outside it is not a
    service on any builder: the x86 builder dies on it after dispatch, the rpi5 one
    bakes nothing and says nothing."""
    entries = list(entries)
    x86 = any((e.platform or "x86") == "x86" for e in entries) if entries \
        else (base.platform or "x86") == "x86"
    blocking: list[Finding] = []
    advisory: list[Finding] = []

    def run(where: str, tokens: Any, kind: str, image: str = "") -> None:
        b, a = _service_problems(where, tokens, kind=kind, x86_in_play=x86)
        blocking.extend(Finding(CHECK_SERVICE, m, image) for m in b)
        advisory.extend(Finding(CHECK_SERVICE, m, image) for m in a)

    run("optional_services", base.optional_services, "select")
    run("exclude_services", base.exclude_services, "exclude")
    run("cluster_domain_services", base.cluster_domain_services, "domain")
    for i, dom in enumerate(base.domains or []):
        label = getattr(dom, "name", "") or f"#{i}"
        run(f"domains[{label}].optional_services", getattr(dom, "optional_services", None),
            "domain")
    for entry in entries:
        for svc in entry.infra_services:
            if svc not in WORKLIST_INFRA_SERVICES:
                blocking.append(Finding(
                    CHECK_SERVICE,
                    f"infra_services: {svc!r} is not a per-image service (the worklist "
                    f"takes {', '.join(WORKLIST_INFRA_SERVICES)}); it would be dropped "
                    "when the image is assembled", entry.id))
    return blocking, advisory


# ── the check ──────────────────────────────────────────────────────────────────────────
def _by_image(per_image: list[tuple[str, list[str]]]) -> list[tuple[str, str]]:
    """``[(image, message)]``: a message every image carries is said once, for the whole
    config; one only some carry names its image (the preflight's own dedupe shape)."""
    n = len(per_image)
    counts: dict[str, int] = {}
    for _eid, msgs in per_image:
        for m in set(msgs):
            counts[m] = counts.get(m, 0) + 1
    out: list[tuple[str, str]] = []
    said: set[str] = set()
    for eid, msgs in per_image:
        for m in dict.fromkeys(msgs):
            if counts[m] == n:
                if m not in said:
                    out.append(("", m))
                    said.add(m)
            else:
                out.append((eid, m))
    return out


def _scope_findings(report: CheckReport, wl: WorklistConfig) -> None:
    """``scope_violations`` over every image AS WRITTEN: the config with each entry's role
    and platform stamped on it, before ``materialize`` resets what a node's role does not
    take. That order is the point. The wizard cannot set an out-of-scope value, and
    ``materialize`` silently drops one that gets in (``standalone`` on a node), so the
    assembled image would show nothing; the value the operator WROTE is still what the
    flat ``--print-command`` / worker channels hand a builder, and what the rule exists
    to name. The blocking / advisory split is ``scope_violations``'s own."""
    blocks: list[tuple[str, list[str]]] = []
    warns: list[tuple[str, list[str]]] = []
    for entry in wl.entries:
        written = copy.deepcopy(wl.base)
        written.role, written.platform = entry.role, entry.platform
        b, a = scope_violations(written)
        blocks.append((entry.id, list(b)))
        warns.append((entry.id, list(a)))
    for image, msg in _by_image(blocks):
        report.add(Finding(CHECK_SCOPE, msg, image))
    for image, msg in _by_image(warns):
        report.add(Finding(CHECK_SCOPE, msg, image), blocking=False)


def _preflight_findings(report: CheckReport, wl: WorklistConfig, generator_dir: str,
                        host, backend: str | None) -> None:
    from .worklist_driver import WorklistDriver
    ids = set(report.images)

    def finding(text: str) -> Finding:
        # WorklistDriver tags an image-specific line "[<entry id>] message"
        if text.startswith("["):
            tag, _, rest = text[1:].partition("] ")
            if tag in ids and rest:
                return Finding(CHECK_PREFLIGHT, rest, tag)
        return Finding(CHECK_PREFLIGHT, text)

    try:
        drv = WorklistDriver(generator_dir, wl, host=host, backend=backend)
        for text in drv.preflight():
            report.add(finding(text))
        for text in drv.preflight_warnings():
            report.add(finding(text), blocking=False)
    except Exception as exc:                  # noqa: BLE001 — a probe must not end the report
        report.add(Finding(CHECK_PREFLIGHT, f"the preflight could not run: {exc}"))


def check_worklist(wl: WorklistConfig, *, raw: Any = None, kind: str = KIND_WORKLIST,
                   generator_dir: str = "", host=None, backend: str | None = None,
                   preflight: bool = True) -> CheckReport:
    """Every gate the wizard puts between a config and a build, over ``wl`` (a flat
    config is ``synthesize(cfg)``, the one-image shape the wizard commits).

    ``raw`` is the JSON the config was loaded from, when there is one: only it can say
    which keys the loader dropped. ``preflight=False`` leaves out the probes of this
    host (Docker, free disk, the output folder, the paths named), for a caller that has
    its own; ``host`` and ``backend`` are the preflight's (None = detect / the default)."""
    report = CheckReport(kind=kind, images=[e.id for e in wl.entries])
    base = wl.base

    def stage(check: str, fn, *args):
        """Run one gate; a gate that cannot run on a value of the wrong type (a JSON
        number where a list belongs) is itself a problem, never a traceback."""
        try:
            return fn(*args)
        except Exception as exc:              # noqa: BLE001
            report.add(Finding(check, f"cannot be checked: {type(exc).__name__}: {exc}"))
            return None

    for f in stage(CHECK_UNKNOWN_KEY, unknown_keys, raw) or []:
        report.add(f)
    blocking, advisory = stage(CHECK_SERVICE, service_findings, base, wl.entries) or ([], [])
    for f in blocking:
        report.add(f)
    for f in advisory:
        report.add(f, blocking=False)
    why = stage(CHECK_DOMAIN_SERVICES, gate_reason, base, ACTION_IMAGE_BUILD,
                DOMAIN_SERVICES_REMEDY)
    if why:
        report.add(Finding(CHECK_DOMAIN_SERVICES, why))
    if not wl.entries:
        report.add(Finding(CHECK_IDENTITY, "the worklist has no images: nothing would be built"))
        return report
    for entry, msg in stage(CHECK_ROOT_SIZE, root_size_floor.entry_errors, wl.entries,
                            base) or []:
        report.add(Finding(CHECK_ROOT_SIZE, msg, entry))
    stage(CHECK_SCOPE, _scope_findings, report, wl)
    try:
        images = wl.materialize()
    except Exception as exc:                  # noqa: BLE001 — surfaced, as the GUI does
        report.add(Finding(CHECK_IDENTITY, str(exc) or type(exc).__name__))
        return report
    for entry, cfg in images:
        try:
            cfg.to_cli_args()
        except Exception as exc:              # noqa: BLE001
            report.add(Finding(CHECK_COMMAND, f"cannot assemble the build command: {exc}",
                               entry.id))
    if preflight:
        _preflight_findings(report, wl, generator_dir, host, backend)
    return report


def check_data(data: Any, *, generator_dir: str = "", host=None,
               backend: str | None = None, preflight: bool = True) -> CheckReport:
    """Check a config as loaded from JSON: a flat image config or a worklist envelope.
    A value the loader refuses outright (a junk tri-state, a domain with an unknown
    ``idp``) is a ``load`` problem, not an exception. ``ValueError`` for JSON that is
    not an object at all."""
    if not isinstance(data, dict):
        raise ValueError(f"config must be a JSON object, got {type(data).__name__} "
                         "(a top-level array or scalar is not a valid image config)")
    envelope = "schema" in data
    kind = KIND_WORKLIST if envelope else KIND_CONFIG
    try:
        wl = WorklistConfig.from_dict(data) if envelope \
            else synthesize(ImageConfig.from_dict(data))
    except Exception as exc:                  # noqa: BLE001
        report = CheckReport(kind=kind)
        for f in unknown_keys(data):
            report.add(f)
        report.add(Finding(CHECK_LOAD, str(exc) or type(exc).__name__))
        return report
    if envelope and data.get("schema") != WORKLIST_SCHEMA:
        pre = Finding(CHECK_LOAD, f"unknown worklist schema {data.get('schema')!r}: this "
                                  f"Studio reads {WORKLIST_SCHEMA!r}")
    else:
        pre = None
    report = check_worklist(wl, raw=data, kind=kind, generator_dir=generator_dir,
                            host=host, backend=backend, preflight=preflight)
    if pre is not None:
        report.add(pre)
    return report


# ── the command line ───────────────────────────────────────────────────────────────────
def format_report(report: CheckReport) -> list[str]:
    """The report as terminal lines: one per finding, then ``ok`` or ``FAILED``."""
    shape = (f"{len(report.images)} image(s): {', '.join(report.images)}"
             if report.images else "no images")
    lines = [f"{report.kind}: {shape}"]
    for tag, items in (("problem", report.problems), ("warning", report.warnings)):
        for f in items:
            where = f"{f.image}: " if f.image else ""
            lines.append(f"{tag:<8} [{f.check}] {where}{f.message}")
    lines.append("ok" if report.ok else
                 f"FAILED: {len(report.problems)} problem(s), {len(report.warnings)} warning(s)")
    return lines


def run_cli(config_path: str, generator_dir: str, *, backend: str | None = None,
            as_json: bool = False, host=None, out=None, err=None) -> int:
    """``--check --config FILE``: print the report and return the exit status (see the
    module docstring). A file that cannot be read or is not an object is bad input
    (stderr, 2): there is no config to report on."""
    out = out or sys.stdout
    err = err or sys.stderr
    try:
        data = json_files.load(config_path)
        report = check_data(data, generator_dir=generator_dir, host=host, backend=backend)
    except (OSError, ValueError) as exc:      # JSONDecodeError and UnicodeDecodeError are ValueErrors
        print(f"error: {exc}", file=err)
        return EXIT_BAD_INPUT
    if as_json:
        print(json.dumps(report.to_dict(), indent=1, sort_keys=True), file=out)
    else:
        print("\n".join(format_report(report)), file=out)
    return EXIT_OK if report.ok else EXIT_PROBLEMS
