"""Mesh control over Tor: how nodes reach the control plane on first boot (OPT-IN).

docs/MESH-CONTROL-OVER-TOR.md. ``lan`` (the default) is today's behaviour: workers dial
the pki on the LAN before go-live (core/pki_lan.py). ``lan+onion`` and ``onion`` give
every node ONE stable control name behind a node-local relay that prefers the pki on
the LAN (``lan+onion``) and falls back to the pki's dedicated control onion — a
permanent fallback, never a handover.

Operator decisions (2026-11-11) this module carries:
  * the control onion key is minted at KEYS time on THIS computer and goes onto the
    PKI STICK ONLY — so the Studio asks for that consent explicitly
    (``mesh_control_onion_mint``) and removes the secret key from this computer once
    the run has made every stick;
  * first sign-in uses the sticks' pre-auth keys; OIDC is switched on once the
    identity provider answers (on the node: hugmesh-headscale-oidc-defer);
  * opt-in and default-off.

Qt-free: the Network page, the TUI and the WorklistDriver use the same words.
"""
from __future__ import annotations

import os

#: (value, label) — the order the faces offer them.
CHOICES = (
    ("lan", "Local network only (default)"),
    ("lan+onion", "Local network, then Tor (no public address needed)"),
    ("onion", "Tor only"),
)
LABELS = dict(CHOICES)
QUESTION = "How do new nodes reach the control plane on first boot?"
MINT_LABEL = ("Create the control-plane onion address on this computer "
              "(its key goes only onto the PKI stick)")

WHY = ("With Tor, every node dials one stable control name. A small relay on each "
       "node sends that to the PKI node on your local network while it answers, and "
       "otherwise to the PKI node's own onion address through Tor — so a node can "
       "join before the mesh has any public address. Tor needs the internet: an "
       "offline network still needs the local path. Each node runs a Tor client and "
       "is visibly a Tor user to its network. Joins over Tor took 13-37 s in "
       "measurement, and about 1 in 8 stalled until Tor was told to build new "
       "circuits; relayed traffic over the onion adds 1.4-2.1 s.")

#: The platforms whose builder can bake Tor (core/config.py PLATFORM_FIELD_SUPPORT).
TOR_PLATFORMS = ("x86", "rpi5")

#: The per-run directory (under the run's output dir) the control onion key lives in
#: between the keys steps of one run.
ONION_DIRNAME = "mesh-control-onion"


def transport(cfg) -> str:
    v = (getattr(cfg, "mesh_control_transport", "") or "").strip()
    return v or "lan"


def is_tor(cfg) -> bool:
    return getattr(cfg, "mode", "") == "mesh" and transport(cfg) != "lan"


def onion_dir(out_dir: str) -> str:
    return os.path.join(out_dir, ONION_DIRNAME)


def genkeys_args(cfg, out_dir: str) -> list[str]:
    """The ``gen-provision-keys.sh`` arguments for ``cfg`` (nothing on lan)."""
    if not is_tor(cfg):
        return []
    a = ["--mesh-control-transport", transport(cfg),
         "--mesh-control-onion-dir", onion_dir(out_dir)]
    if getattr(cfg, "mesh_control_onion_mint", False):
        a.append("--mesh-control-onion-mint")
    return a


def problems(worklist) -> list[str]:
    """What stops a Tor transport from making this worklist's sticks (empty = none)."""
    base = worklist.base
    if not is_tor(base):
        return []
    out = []
    if not getattr(base, "mesh_control_onion_mint", False):
        out.append(f"{LABELS[transport(base)]}: tick '{MINT_LABEL}' — the control "
                   "onion's key is created on this computer and goes onto the PKI "
                   "stick only.")
    from .config import image_class          # local import: keeps this module light
    for e in worklist.entries:
        if image_class(base.mode, e.role) != "node":
            continue
        if (e.platform or "x86") not in TOR_PLATFORMS:
            out.append(f"{LABELS[transport(base)]}: the {e.platform} builder cannot "
                       f"bake Tor ({e.id}); only x86 and rpi5 nodes can — choose "
                       f"'{LABELS['lan']}' or drop that image.")
    return out


def forget_secret(cfg, out_dir: str) -> None:
    """Remove the control onion's SECRET key from this computer (keep the address)."""
    if not is_tor(cfg):
        return
    d = onion_dir(out_dir)
    for name in ("hs_ed25519_secret_key", "hs_ed25519_public_key"):
        try:
            os.remove(os.path.join(d, name))
        except FileNotFoundError:
            pass
        except OSError:
            pass
