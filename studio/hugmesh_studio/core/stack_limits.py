"""Apply the operator's resource limits to the local docker-compose mesh.

The compose stack is the one lane with no Python ``docker`` invocation to decorate:
:mod:`hugmesh_studio.core.local_stack_node` drives ``make``, and the Makefile drives
``docker compose``. So the limit is delivered the same way the second-brand Casdoor
overlay already is (see :mod:`own_casdoor`): a generated, dot-prefixed, gitignored
compose file that the Makefile picks up through a ``$(wildcard ...)`` include.

That mechanism is chosen over the alternatives on purpose:

  * editing ``tests/stack/compose.local.yaml`` would put a machine-specific core
    count into a COMMITTED file that every other operator and CI shares;
  * passing ``--cpus`` to ``docker compose`` is not a thing — compose expresses
    limits per service, in the file;
  * a ``docker update`` sweep after the stack is up would leave a window where 52
    unbounded services are already competing for the machine, which is exactly the
    window that froze a host in the 2026-07-15 incident.

WHAT GETS LIMITED. The limit is the operator's budget for the WHOLE mesh, not for
each of its 52 services: writing ``cpus: 6`` onto every service would authorise 312
cores. The budget is therefore divided across the services that actually compete for
CPU, with a floor so no single service is throttled into uselessness.
"""
from __future__ import annotations

import os

from .resource_limits import ResourceLimits

#: Where the overlay is written, relative to the generator checkout. Dot-prefixed
#: and gitignored exactly like tests/stack/.compose.own-domains.yaml, so it is
#: regenerated per bring-up and never committed.
OVERLAY_RELPATH = os.path.join("tests", "stack", ".compose.limits.yaml")

#: Never give one service less than this share of a core. Below roughly a quarter
#: of a core a JVM service does not start inside its healthcheck window, and a
#: "limit" that turns into a failed bring-up teaches operators to switch the
#: feature off rather than to tune it.
MIN_SERVICE_CPUS = 0.25

#: Likewise for memory: a Spring Boot service below this simply OOMs at boot.
MIN_SERVICE_MEMORY_MB = 384


def per_service_cpus(total_cpus: float, service_count: int) -> float:
    """Split a whole-mesh CPU budget across the services that share it.

    Deliberately NOT ``total / count``: compose limits are ceilings, not
    reservations, and services are bursty and mostly idle — dividing a 6-core budget
    by 52 services would cap every one of them at 0.115 cores and the stack would
    never come up. The budget is instead treated as the SUSTAINED total, with each
    service allowed to burst to a generous fraction of it, floored at
    :data:`MIN_SERVICE_CPUS`. The host-level protection that actually matters comes
    from the sum being bounded by the machine, plus the operator keeping a core back
    (see :func:`resource_limits.default_cpus`).
    """
    if service_count <= 0:
        return max(MIN_SERVICE_CPUS, total_cpus)
    # A quarter of the whole budget per service: enough for one service to do real
    # work while several are busy, and small enough that no single one can pin the
    # machine on its own.
    share = total_cpus / 4.0
    return max(MIN_SERVICE_CPUS, round(share, 2))


def parse_size(value: str) -> int | None:
    """A docker size string ("16g", "8192m", "512") to bytes, or None if unparseable.

    Unparseable yields None rather than a guess, and the caller then omits the memory
    limit entirely — the same "never invent a number the operator did not ask for"
    rule the CPU knob follows.
    """
    raw = value.strip().lower()
    if not raw:
        return None
    units = {"b": 1, "k": 1024, "m": 1024 ** 2, "g": 1024 ** 3, "t": 1024 ** 4}
    factor = 1
    if raw[-1] in units:
        factor = units[raw[-1]]
        raw = raw[:-1]
    try:
        return int(float(raw) * factor)
    except ValueError:
        return None


def per_service_memory(total_memory: str, service_count: int) -> str | None:
    """Split a whole-mesh MEMORY budget across the services that share it.

    Unlike CPU, memory is genuinely additive and a compose ``memory`` limit is a hard
    ceiling enforced by the OOM killer — so writing the WHOLE budget onto each of 41
    services would authorise 41x the machine's RAM and protect nothing at all. This
    divides, with a floor at :data:`MIN_SERVICE_MEMORY_MB` because a Spring Boot
    service below that OOMs during startup and the bring-up fails.

    Returns None when the budget is unparseable or so small that the floor would
    exceed an even share — in that case NO memory limit is written, because a limit
    every service immediately breaches is worse than none.
    """
    total = parse_size(total_memory)
    if total is None or service_count <= 0:
        return None
    share_mb = (total // service_count) // (1024 ** 2)
    if share_mb < MIN_SERVICE_MEMORY_MB:
        return None
    return f"{share_mb}m"


def render_overlay(limits: ResourceLimits, services: list[str]) -> str:
    """The compose overlay YAML for these limits, or ``""`` when nothing is limited.

    Returning an empty string (and the caller then REMOVING the file) is what keeps
    the "limits off == byte-identical behaviour" contract: with no overlay on disk
    the Makefile's ``$(wildcard)`` include contributes no ``-f`` flag at all, so the
    compose invocation is exactly what it was before this feature existed.

    Hand-rendered rather than emitted with PyYAML: PyYAML is not a hard dependency of
    the Studio (requirements.txt is PySide6 alone), and the shape here is a fixed
    three-level mapping, not arbitrary data.
    """
    if limits.cpus is None and limits.memory is None or not services:
        return ""

    cpus = per_service_cpus(limits.cpus, len(services)) if limits.cpus is not None else None
    memory = per_service_memory(limits.memory, len(services)) if limits.memory else None
    if cpus is None and memory is None:
        return ""

    lines = [
        "# GENERATED by hugmesh_studio.core.stack_limits — do not edit, do not commit.",
        "# Rewritten on every stack bring-up from the Studio's resource-limit setting",
        "# (Studio -> Resource limits, or the HUGMESH_CPUS / HUGMESH_BUILD_MEMORY env",
        "# knobs). Deleting this file restores the unlimited stack exactly.",
        "services:",
    ]
    for name in services:
        lines.append(f"  {name}:")
        lines.append("    deploy:")
        lines.append("      resources:")
        lines.append("        limits:")
        if cpus is not None:
            lines.append(f"          cpus: '{cpus:g}'")
        if memory is not None:
            lines.append(f"          memory: {memory}")
    return "\n".join(lines) + "\n"


def write_overlay(generator_dir: str, limits: ResourceLimits,
                  services: list[str]) -> str | None:
    """Write (or REMOVE) the overlay. Returns the path written, or None if removed.

    Removal is as important as writing: an operator who turns limits off and brings
    the stack up again must get an unlimited stack, and a stale overlay from the
    previous run would silently keep throttling it.
    """
    path = os.path.join(generator_dir, OVERLAY_RELPATH)
    body = render_overlay(limits, services)
    if not body:
        try:
            os.remove(path)
        except FileNotFoundError:
            pass
        return None
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(body)
    os.replace(tmp, path)
    return path


def compose_services(compose_path: str) -> list[str]:
    """Service names from a compose file, read without a YAML parser.

    A two-space-indented key directly under a top-level ``services:`` block is the
    whole grammar that matters here, and the file in question
    (tests/stack/compose.local.yaml) is generated and uniformly formatted. Taking a
    hard dependency on PyYAML to read 52 keys out of a file whose shape we control
    would be the larger cost.
    """
    names: list[str] = []
    in_services = False
    try:
        with open(compose_path, "r", encoding="utf-8") as fh:
            for line in fh:
                stripped = line.rstrip("\n")
                if not stripped or stripped.lstrip().startswith("#"):
                    continue
                if not stripped.startswith((" ", "\t")):
                    in_services = stripped.split(":", 1)[0].strip() == "services"
                    continue
                if not in_services:
                    continue
                # Exactly two spaces of indent = a service name.
                if stripped.startswith("  ") and not stripped.startswith("   "):
                    key = stripped.strip()
                    if key.endswith(":"):
                        names.append(key[:-1].strip())
    except OSError:
        return []
    return names
