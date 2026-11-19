"""A new Tor (onion) address for ONE domain of the running local Docker mesh
(hugmesh-generator#652, "generate a new service onion url per domain ... also make sure
this can be done in the studio").

The work happens inside the mesh's own Tor container: ``hugmesh-tor-rotate <slug>``
(tests/stack/tor/entrypoint.sh, ``rotate`` mode) withdraws the old name from the
gateway's host map, moves only that domain's key folder aside, reloads tor once, waits
for the new name and publishes it. This module finds the container, runs the command
and turns its answer into words for the screens. Qt-free; ``run`` is the one override
point a test replaces.

What it never does: rotate the mesh's own (primary) address (the container refuses
it, and so do the screens), or fall back to running the entrypoint itself when a
container predates the command. The old entrypoint ignores its arguments, so that
fallback would restart Tor inside the running container. A container without the
command is told to restart the mesh instead.
"""
from __future__ import annotations

import re
import shutil
import subprocess
from dataclasses import dataclass

from . import proc_text
from .domain_services import onion_slug
from .local_stack_node import _COMPOSE_PROJECT, _tor_ps_filters

__all__ = ["RenewOutcome", "renew_domain_onion", "ROTATE_COMMAND", "CONFIRM_SENTENCE"]

ROTATE_COMMAND = "hugmesh-tor-rotate"
#: what the screens say before the second click
CONFIRM_SENTENCE = ("A new address replaces this domain's Tor address. The old one stops "
                    "working at once, for everyone who has it, and cannot be brought "
                    "back from here.")
_TIMEOUT_S = 180
_ROTATED = re.compile(r"^ROTATED (\S+) ([a-z2-7]{56}\.onion) -> ([a-z2-7]{56}\.onion)$",
                      re.M)


@dataclass(frozen=True)
class RenewOutcome:
    ok: bool
    message: str
    old: str = ""
    new: str = ""


def _container(project: str, run) -> tuple[str, str]:
    """(container id, "") of the running Tor container, or ("", why)."""
    try:
        r = run(["docker", "ps", "-q", "--no-trunc", *_tor_ps_filters(project)],
                capture_output=True, text=True, timeout=10, **proc_text.TEXT_IO)
    except (OSError, subprocess.SubprocessError) as e:
        return "", f"docker did not answer ({type(e).__name__})."
    ids = (r.stdout or "").split() if r.returncode == 0 else []
    if not ids:
        return "", ("The mesh's Tor container is not running, so there is no Tor address "
                    "to replace. Start the mesh with Tor first.")
    return ids[0], ""


def renew_domain_onion(name: str, stored_id: str = "", *, project: str = _COMPOSE_PROJECT,
                       run=subprocess.run, which=shutil.which) -> RenewOutcome:
    """Give the Tor domain ``name`` (its stored brand id, if the record has one) a new
    onion address on the running Docker mesh. Blocking (up to about three minutes while
    tor mints the key); never raises."""
    slug = onion_slug(name, stored_id)
    if not slug:
        return RenewOutcome(False, f"{name or 'This domain'} has no Tor key name, so it "
                                   "has no Tor address of its own.")
    if not which("docker"):
        return RenewOutcome(False, "docker is not installed, so the mesh cannot be reached.")
    cid, why = _container(project, run)
    if not cid:
        return RenewOutcome(False, why)
    try:
        r = run(["docker", "exec", cid, ROTATE_COMMAND, slug], capture_output=True,
                text=True, timeout=_TIMEOUT_S, **proc_text.TEXT_IO)
    except subprocess.TimeoutExpired:
        return RenewOutcome(False, "Tor did not answer within three minutes. The "
                                   "container's own log says whether the old address "
                                   "is still served.")
    except (OSError, subprocess.SubprocessError) as e:
        return RenewOutcome(False, f"docker did not run the command ({type(e).__name__}).")
    out, err = r.stdout or "", (r.stderr or "").strip()
    last = err.splitlines()[-1] if err else ""
    if r.returncode == 0:
        m = _ROTATED.search(out)
        if not m or m.group(1) != slug:
            return RenewOutcome(False, "The Tor container answered, but not with a new "
                                       "address this Studio can read; nothing is shown.")
        return RenewOutcome(True, f"{name} has a new Tor address. The old one no longer "
                                  "works; its key is kept for 7 days inside the mesh.",
                            old=m.group(2), new=m.group(3))
    if r.returncode in (126, 127) or "executable file not found" in err:
        return RenewOutcome(False, "This mesh's Tor container is older than this Studio "
                                   f"and has no {ROTATE_COMMAND}. Restart the mesh, then "
                                   "try again.")
    words = {
        2: f"{name} is not one of this mesh's Tor domains (it had no Tor tick when the "
           "mesh started). Nothing was changed.",
        3: "Another new address is being made right now. Wait for it, then try again.",
        4: f"{name}'s Tor address is not published yet, so there is nothing to replace.",
        5: f"No new address was made for {name}; its old address is served again.",
    }
    return RenewOutcome(False, words.get(r.returncode,
                                         f"The Tor container refused (exit {r.returncode})."
                                         + (f" {last}" if last else "")))
