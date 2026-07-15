"""Local Docker mesh — the Qt-free runner behind the ModePage's fourth first-screen
choice ("Local Docker mesh"). It runs a dockerized Snapdragon mesh node on THIS
machine instead of building an image, reusing the SAME compose template + lifecycle
as the tray's MeshNode (core/mesh_node.py) so "run a node on my own machine" behaves
identically whether launched from the wizard or the tray.

Design split (mirrors fleet's FleetConfig/FleetDriver and golive):
  - ``LocalMeshConfig`` — the pure-data knobs the operator provides (the tailnet /
    headscale auth key the mesh overlay's ``TS_AUTHKEY:?`` interpolation REQUIRES,
    plus optional node name + self-hosted headscale login-server URL).
  - ``LocalMeshNode`` — a thin ``MeshNode`` subclass that stages those knobs into the
    workdir ``.env`` so ``docker compose up`` sees them, and gates ``available()`` on
    the required auth key. It adds NO new compose invocation of its own — start/stop/
    status/logs are inherited verbatim, so the local-mesh path and the tray path share
    one lifecycle. core/mesh_node.py is imported, never modified.

This module NEVER touches ImageConfig / to_cli_args() / the mesh manifest: a local mesh
builds no image, so it emits nothing into the builder argv the build-matrix guards.
"""
from __future__ import annotations

import os
from dataclasses import dataclass

from .mesh_node import MeshNode

# The env-var names the shipped mesh overlay (specs/usr/share/snapdragon/stack/
# docker-compose.mesh.yml) interpolates. TS_AUTHKEY is REQUIRED there (``:?``);
# the other two are optional with compose-side defaults.
ENV_AUTHKEY = "TS_AUTHKEY"
ENV_NODE_NAME = "SNAPDRAGON_NODE_NAME"
ENV_EXTRA_ARGS = "TS_EXTRA_ARGS"


@dataclass
class LocalMeshConfig:
    """Operator-provided knobs for a local dockerized mesh node.

    ``auth_key`` is the tailnet/headscale pre-auth key the tailscale container joins
    with (the overlay's required ``TS_AUTHKEY``). ``login_server``, when set, points the
    node at a self-hosted headscale control plane by appending ``--login-server=<url>``
    to ``TS_EXTRA_ARGS`` (alongside the overlay's default ``--accept-routes``).
    ``workdir`` overrides where the compose project is staged (default:
    ~/.snapdragon/mesh-node, same as MeshNode)."""
    auth_key: str = ""
    node_name: str = ""
    login_server: str = ""
    workdir: str = ""

    def env(self) -> dict[str, str]:
        """The env keys to stage into the workdir ``.env`` for compose interpolation.
        Only non-empty knobs are emitted; TS_EXTRA_ARGS keeps the overlay's
        ``--accept-routes`` default and appends ``--login-server`` only when a
        self-hosted control plane URL was given."""
        e: dict[str, str] = {}
        if self.auth_key.strip():
            e[ENV_AUTHKEY] = self.auth_key.strip()
        if self.node_name.strip():
            e[ENV_NODE_NAME] = self.node_name.strip()
        extra = ["--accept-routes"]
        if self.login_server.strip():
            extra.append(f"--login-server={self.login_server.strip()}")
        e[ENV_EXTRA_ARGS] = " ".join(extra)
        return e


def _parse_env(path: str) -> dict[str, str]:
    """Read a docker ``.env`` (KEY=VALUE per line; blanks/`#` comments ignored). The
    whole remainder after the first ``=`` is the value (compose does not shell-split)."""
    out: dict[str, str] = {}
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                s = line.strip()
                if not s or s.startswith("#") or "=" not in s:
                    continue
                k, v = s.split("=", 1)
                out[k.strip()] = v
    except OSError:
        pass
    return out


def _write_env(path: str, values: dict[str, str]) -> None:
    with open(path, "w", encoding="utf-8") as fh:
        for k, v in values.items():
            fh.write(f"{k}={v}\n")


class LocalMeshNode(MeshNode):
    """A MeshNode that stages the operator's auth key + node knobs into the workdir
    ``.env`` before ``docker compose up``, so the mesh overlay's required ``TS_AUTHKEY``
    interpolation is satisfied. Everything else (start/stop/status/logs, the compose
    invocation) is inherited unchanged from MeshNode — the local-mesh flow and the tray
    reuse one lifecycle."""

    def __init__(self, generator_dir: str, cfg: LocalMeshConfig | None = None):
        self.cfg = cfg or LocalMeshConfig()
        super().__init__(generator_dir, workdir=(self.cfg.workdir or None))

    def available(self) -> tuple[bool, str]:
        # Gate on the auth key FIRST (the one thing the operator MUST supply, and the
        # actionable message in the dialog) — then defer to MeshNode for docker/template.
        if not self.cfg.auth_key.strip():
            return False, ("Enter a tailnet/headscale auth key (TS_AUTHKEY) to run a "
                           "local mesh node.")
        return super().available()

    def _stage(self) -> None:
        # Stage the compose template + any bundled assets exactly as MeshNode does,
        # THEN merge our env on top (our keys win over any copied stack .env) so the
        # required TS_AUTHKEY is present for `docker compose up`.
        super()._stage()
        env_path = os.path.join(self.workdir, ".env")
        merged = _parse_env(env_path)
        merged.update(self.cfg.env())
        _write_env(env_path, merged)
