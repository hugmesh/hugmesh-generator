"""Start / Stop / Restart / Logs for ONE domain of a locally running mesh, and the
Tor Browser hand-off for every onion it publishes (operator ask, 2026-10-21: "make
sure that controls for local running mesh pods are labeled and controllable per
domain with an ability to open multiple tor domains").

WHAT A DOMAIN'S CONTROLS TOUCH. Only the rows ``core.mesh_monitor`` attributed to that
ONE domain (``MeshUnit.domain``): the per-domain own Casdoor and its database (the
``hugmesh.net/domain`` label the Studio's overlay writes), a compose service only that
domain chose, a kind pod carrying the label. A shared row — the gateway, the central
Casdoor, the one tor container that carries every onion — is never touched by a
domain's buttons: stopping it would stop every domain. Those rows are labelled
"All domains" and keep the mesh-wide controls they always had.

HOW EACH LANE RUNS A VERB.

* Compose rows are CONTAINERS and are driven by name with the docker CLI (``docker
  start|stop|restart|logs <container>``). By name, not ``docker compose -f …``: the
  per-domain Casdoors live in a generated overlay and behind a profile, and a compose
  command that did not load exactly the files and profiles the stack came up with
  would answer "no such service" for exactly the containers this exists for.
* Kind rows are PODS. Restart deletes the pod so its controller makes a new one — no
  spec edit, so ArgoCD has nothing to revert. Start and Stop are REFUSED with the
  reason (``mesh_monitor.KIND_STOP_REFUSAL``): self-heal owns the replica count.

Every function here is Qt-free, and the two that run anything NEVER raise: they are
called from a worker thread whose only contract is to emit ``(ok, text)``.
"""
from __future__ import annotations

import shutil
import subprocess
from dataclasses import dataclass, field

from . import devops_tools
from .local_stack_node import _kind_cluster_name
from .mesh_monitor import CONTROL_VERBS, MeshUnit

#: Lines of log per unit. Enough to see a crash loop's last start; the full log is a
#: ``docker logs`` / ``kubectl logs`` away and the button's tooltip names it.
LOG_TAIL = 200
#: Per-unit ceiling. ``docker stop`` waits up to 10 s for a clean exit before killing,
#: and a Casdoor that is mid-migration takes a while to come back.
CONTROL_TIMEOUT_S = 60
#: How much log text one press may hand the GUI (the inline box is not a pager).
LOG_TEXT_MAX = 200_000

VERB_WORDS = {"start": "Start", "stop": "Stop", "restart": "Restart", "logs": "Logs"}


def control_argv(unit: MeshUnit, verb: str, *, generator_dir: str = ""
                 ) -> tuple[list[str], str]:
    """``(argv, refusal)`` for one verb on one row. One of the two is always empty.
    Pure — builds a command, runs nothing."""
    if verb not in CONTROL_VERBS:
        return [], f"{verb!r} is not one of {', '.join(CONTROL_VERBS)}"
    ctl = unit.control
    why = ctl.refusal(verb)
    if why:
        return [], why
    if ctl.kind == "container":
        if verb == "logs":
            return ["docker", "logs", "--tail", str(LOG_TAIL), "--timestamps",
                    ctl.name], ""
        return ["docker", verb, ctl.name], ""
    if ctl.kind == "pod":
        kubectl = devops_tools.which("kubectl", generator_dir) if generator_dir else \
            shutil.which("kubectl")
        if not kubectl:
            return [], ("kubectl is not installed — press 'Install DevOps "
                        "prerequisites' on the local-mesh page")
        ctx = f"kind-{_kind_cluster_name()}"
        if verb == "logs":
            return [kubectl, "--context", ctx, "logs", "-n", ctl.namespace, ctl.name,
                    "--all-containers", "--prefix", f"--tail={LOG_TAIL}"], ""
        if verb == "restart":
            return [kubectl, "--context", ctx, "delete", "pod", "-n", ctl.namespace,
                    ctl.name, "--wait=false"], ""
    return [], "this row carries nothing to start, stop or read logs from"


def _wanted(unit: MeshUnit, verb: str) -> str:
    """"" when ``verb`` makes sense for the row's CURRENT state, else why it is
    skipped. Start skips what is up and finished one-shots (re-running an init job is
    not starting a service); Stop skips what is already down."""
    # A container that is up but unhealthy reads state "failed" with phase
    # "running (unhealthy)" — it is still UP, so Stop must reach it.
    up = unit.state in ("ok", "running") or unit.phase.lower().startswith("running")
    if verb == "start":
        if unit.state == "completed":
            return "a one-shot that already ran to completion"
        if up:
            return "already running"
    if verb == "stop" and not up and unit.state != "queued":
        return "already stopped"
    if verb == "restart" and unit.state == "completed":
        return "a one-shot that already ran to completion"
    return ""


@dataclass(frozen=True)
class DomainPlan:
    """What one press of a domain's verb button will do, BEFORE it runs: the rows it
    acts on and every row of that domain it leaves alone, each with its reason. The
    GUI shows ``summary()`` under the buttons, so the operator reads the plan first."""
    domain: str
    verb: str
    targets: tuple[MeshUnit, ...] = ()
    skipped: tuple[tuple[MeshUnit, str], ...] = ()

    def summary(self) -> str:
        word = VERB_WORDS.get(self.verb, self.verb)
        if not self.targets and not self.skipped:
            return f"{self.domain}: no row of this mesh serves only this domain."
        bits = []
        if self.targets:
            bits.append(f"{word} acts on " + ", ".join(u.name for u in self.targets))
        else:
            bits.append(f"{word} has nothing to act on")
        for u, why in self.skipped:
            bits.append(f"{u.name}: {why}")
        return f"{self.domain} — " + "; ".join(bits) + "."


def domain_plan(units, domain: str, verb: str) -> DomainPlan:
    """The rows of ``domain`` that ``verb`` would act on, and the ones it skips.
    Only rows whose ``domain`` IS ``domain`` are considered — a shared row never."""
    rows = getattr(units, "units", units) or ()
    targets: list[MeshUnit] = []
    skipped: list[tuple[MeshUnit, str]] = []
    seen_controls: set[tuple[str, str, str]] = set()
    for u in rows:
        if u.domain != domain:
            continue
        why = u.control.refusal(verb)
        if not why:
            why = _wanted(u, verb)
        if not why:
            ident = (u.control.kind, u.control.namespace, u.control.name)
            if ident in seen_controls:
                why = "the same container as a row above"
            else:
                seen_controls.add(ident)
        if why:
            skipped.append((u, why))
        else:
            targets.append(u)
    targets = _dependency_order(targets)
    if verb == "stop":
        targets.reverse()             # dependents first, their databases last
    return DomainPlan(domain, verb, tuple(targets), tuple(skipped))


def _dependency_order(units: list[MeshUnit]) -> list[MeshUnit]:
    """Order so that a row comes after every row whose compose service it waits for
    (``UnitControl.depends_on``, read from compose's own label). Stable otherwise; a
    cycle (compose would refuse one) keeps the given order for what is left."""
    pending = list(units)
    done: list[MeshUnit] = []
    placed: set[str] = set()
    services = {u.control.service for u in units if u.control.service}
    while pending:
        progressed = False
        for u in list(pending):
            needs = [d for d in u.control.depends_on if d in services and d not in placed]
            if not needs:
                done.append(u)
                pending.remove(u)
                if u.control.service:
                    placed.add(u.control.service)
                progressed = True
        if not progressed:
            done.extend(pending)
            break
    return done


def _run(node, argv: list[str], timeout: int) -> tuple[int, str]:
    """Run ``argv`` with stdout AND stderr kept, in the node's build env when it has
    one (so kubectl resolves the way every other monitor read does). ``docker logs``
    replays a container's stderr on its own stderr, so the probe runner — which keeps
    only one of the two streams — would lose half of a crash's log. Never raises."""
    env = None
    try:
        build = getattr(node, "_build_env", None)
        if callable(build):
            env = build(write_overlays=False)
    except Exception:                                 # noqa: BLE001 — env is a nicety
        env = None
    try:
        r = subprocess.run(argv, env=env, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, text=True, timeout=timeout)
        return r.returncode, r.stdout or ""
    except subprocess.TimeoutExpired:
        return 124, f"timed out after {timeout}s"
    except (OSError, subprocess.SubprocessError) as exc:
        return 1, f"{type(exc).__name__}: {exc}"


@dataclass
class DomainResult:
    """What a press did: ``ok`` only when every target's verb exited 0. ``text`` is
    the one status line; ``logs`` the gathered log text (Logs only)."""
    ok: bool
    text: str
    logs: str = ""
    ran: list[list[str]] = field(default_factory=list)
    domain: str = ""
    verb: str = ""


def run_domain_action(generator_dir: str, node, units, domain: str, verb: str, *,
                      timeout_s: int = CONTROL_TIMEOUT_S) -> DomainResult:
    """Run ``verb`` on every row of ``domain`` the plan targets, one after another.
    NEVER raises. One failed row does not stop the rest — each says how it went."""
    try:
        plan = domain_plan(units, domain, verb)
    except Exception as exc:                          # noqa: BLE001
        return DomainResult(False, f"could not plan {verb}: {type(exc).__name__}: {exc}",
                            domain=domain, verb=verb)
    word = VERB_WORDS.get(verb, verb)
    if not plan.targets:
        return DomainResult(False, f"Nothing run. {plan.summary()}", domain=domain,
                            verb=verb)
    results: list[str] = []
    logs: list[str] = []
    ran: list[list[str]] = []
    ok = True
    for u in plan.targets:
        argv, refused = control_argv(u, verb, generator_dir=generator_dir)
        if refused:
            ok = False
            results.append(f"{u.name}: not run — {refused}")
            continue
        ran.append(argv)
        rc, out = _run(node, argv, max(1, int(timeout_s)))
        if verb == "logs":
            logs.append(f"── {u.name} ({u.lane}) ──\n{out.rstrip()}\n")
        if rc != 0:
            ok = False
            last = (out.strip().splitlines() or ["no output"])[-1][:300]
            results.append(f"{u.name}: failed (exit {rc}) — {last}")
        elif verb != "logs":
            results.append(f"{u.name}: done")
    text = (f"{word} {domain}: " + "; ".join(results) if results
            else f"{word} {domain}: read {len(plan.targets)} log(s)")
    if verb in ("start", "restart") and ok:
        text += " — the table shows whether each came up on the next refresh"
    log_text = "\n".join(logs)
    if len(log_text) > LOG_TEXT_MAX:
        log_text = "… (earlier lines cut)\n" + log_text[-LOG_TEXT_MAX:]
    return DomainResult(ok, text, log_text, ran, domain=domain, verb=verb)


# ── Tor Browser ────────────────────────────────────────────────────────────────────
#: Launchers that take a URL argument, in the order they are tried. The distro
#: launcher first (it keeps Tor Browser updated), then the bundle's own script.
TOR_BROWSER_COMMANDS = ("torbrowser-launcher", "torbrowser", "tor-browser",
                        "start-tor-browser")


def tor_browser_argv(url: str, which=None) -> list[str]:
    """``[launcher, url]`` for the first Tor Browser launcher on PATH, or [] when none
    is installed — the GUI then offers Copy only and says so. ``url`` must be an
    onion address: this is never a way to hand an arbitrary URL to a program."""
    if not url or ".onion" not in url or not url.startswith(("http://", "https://")):
        return []
    which = which or shutil.which         # looked up per call (PATH can change)
    for cmd in TOR_BROWSER_COMMANDS:
        path = which(cmd)
        if path:
            return [path, url]
    return []


def tor_browser_missing_reason() -> str:
    return ("No Tor Browser launcher was found on PATH (looked for "
            + ", ".join(TOR_BROWSER_COMMANDS)
            + "). Install Tor Browser, or press Copy and paste the address into it.")


def onion_lines(onions) -> str:
    """Every onion as copyable lines: ``<domain>\t<login address>``."""
    return "\n".join(f"{o.domain}\t{o.login}" for o in (onions or ()))


__all__ = ["LOG_TAIL", "CONTROL_TIMEOUT_S", "VERB_WORDS", "DomainPlan", "DomainResult",
           "control_argv", "domain_plan", "run_domain_action", "tor_browser_argv",
           "tor_browser_missing_reason", "onion_lines", "TOR_BROWSER_COMMANDS"]
