"""Local Docker mesh — the Qt-free runner behind the ModePage's fourth first-screen
choice ("Local Docker mesh"). It runs a dockerized HugMesh mesh node on THIS
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

import argparse
import os
import sys
from dataclasses import dataclass

from .mesh_node import MeshNode

# The env-var names the shipped mesh overlay (specs/usr/share/hugmesh/stack/
# docker-compose.mesh.yml) interpolates. TS_AUTHKEY is REQUIRED there (``:?``);
# the other two are optional with compose-side defaults.
ENV_AUTHKEY = "TS_AUTHKEY"
ENV_NODE_NAME = "HUGMESH_NODE_NAME"
ENV_EXTRA_ARGS = "TS_EXTRA_ARGS"


@dataclass
class LocalMeshConfig:
    """Operator-provided knobs for a local dockerized mesh node.

    ``auth_key`` is the tailnet/headscale pre-auth key the tailscale container joins
    with (the overlay's required ``TS_AUTHKEY``). ``login_server``, when set, points the
    node at a self-hosted headscale control plane by appending ``--login-server=<url>``
    to ``TS_EXTRA_ARGS`` (alongside the overlay's default ``--accept-routes``).
    ``workdir`` overrides where the compose project is staged (default:
    ~/.hugmesh/mesh-node, same as MeshNode)."""
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

    def _authkey(self) -> str:
        # The EFFECTIVE key start()/_env() consult: the operator's field value wins, with
        # the environment as a fallback. This is what makes the launcher's "type the key
        # into the dialog" UX actually dispatch `docker compose up` — MeshNode.start() used
        # to gate solely on os.environ TS_AUTHKEY, so a field-provided key dead-ended, and
        # the inherited _env() injected only a teardown placeholder that shadowed the staged
        # real key in the subprocess environment.
        return self.cfg.auth_key.strip() or super()._authkey()

    def _stage(self) -> None:
        # Stage the compose template + any bundled assets exactly as MeshNode does,
        # THEN merge our env on top (our keys win over any copied stack .env) so the
        # required TS_AUTHKEY is present for `docker compose up`.
        super()._stage()
        env_path = os.path.join(self.workdir, ".env")
        merged = _parse_env(env_path)
        merged.update(self.cfg.env())
        _write_env(env_path, merged)


# ── Qt-free CLI face (the SHARED entrypoint) ────────────────────────────────────
# The ncurses menu (scripts/build-menu.sh) and the Makefile `mesh-node-up` target
# both shell `python3 -m hugmesh_studio.core.local_mesh <sub> …`, so GUI + ncurses
# + CLI drive the SAME LocalMeshConfig -> LocalMeshNode object graph the GUI dialog
# (gui/pages/localmesh.py) builds — not merely "the same lifecycle". This module
# imports only .mesh_node (os/subprocess/shutil/dataclasses — NO Qt), so it runs in
# the Qt-free/system-python environment CI uses.
#
# This is the DIFFERENT product surface from clients/docker-mesh-node/mesh-node.sh:
# that is the shipped END-USER joiner appliance (FD-09) — a KEYS folder mounted into
# a baked hugmesh/mesh-node:latest image, installed to a desktop as the
# `hugmesh-mesh-node` binary. This fourth-choice face instead consumes ONE
# TS_AUTHKEY + the generator's shipped docker-compose.mesh.yml overlay on the build
# host. They are intentionally not unified (see --help) and never share a PATH name:
# this face is invoked by module path (`python3 -m …`) / `make mesh-node-up` only.

_REPO_ROOT = os.path.abspath(
    os.path.join(os.path.dirname(__file__), os.pardir, os.pardir, os.pardir))


def _read_authkey(args: argparse.Namespace) -> str:
    """Resolve the auth key from --authkey-file (preferred: keeps the secret off the
    argv / process table) or the inline --authkey. Trailing whitespace/newlines are
    stripped so a `printf '%s' key >file` and an `echo key >file` behave the same."""
    if args.authkey_file:
        with open(args.authkey_file, encoding="utf-8") as fh:
            return fh.read().strip()
    return (args.authkey or "").strip()


def main(argv: list[str] | None = None) -> int:
    """Qt-free entrypoint shared by the ncurses menu + the Makefile mesh-node targets.

    Builds the SAME LocalMeshConfig/LocalMeshNode the GUI's LocalMeshDialog builds and
    runs one lifecycle verb (up|down|status|logs) against it."""
    p = argparse.ArgumentParser(
        prog="hugmesh-mesh-node",
        description=(
            "Run a HugMesh mesh node on THIS machine in Docker (the wizard's fourth "
            "choice: 'Local Docker mesh'). Builds NO image — it runs the shipped "
            "docker-compose.mesh.yml overlay locally. Shares one lifecycle with the "
            "Studio tray + wizard launcher (core/mesh_node.py)."),
        epilog=(
            "To PERMANENTLY enroll THIS desktop with an admin-issued keys folder + a "
            "tray/desktop launcher, use the installed end-user appliance "
            "`hugmesh-mesh-node` from clients/docker-mesh-node/install.sh instead — "
            "that is a different product surface (a baked joiner image + KEYS profile), "
            "not this generator-host build-time face."))
    p.add_argument("subcommand", choices=("up", "down", "status", "logs"),
                   help="up = start the local node; down = stop it; status = running? ; "
                        "logs = tail its container logs")
    key = p.add_mutually_exclusive_group()
    key.add_argument("--authkey-file", default="",
                     help="path to a file holding the tailnet/headscale auth key "
                          "(TS_AUTHKEY). Preferred over --authkey (keeps the secret off "
                          "the process table). Required for `up`.")
    key.add_argument("--authkey", default="",
                     help="the tailnet/headscale auth key inline (use --authkey-file to "
                          "keep it off the argv).")
    p.add_argument("--node-name", default="",
                   help="optional hostname on the tailnet (default: hugmesh-node).")
    p.add_argument("--login-server", default="",
                   help="optional self-hosted headscale control-plane URL.")
    p.add_argument("--workdir", default="",
                   help="override where the compose project is staged "
                        "(default: ~/.hugmesh/mesh-node).")
    p.add_argument("--generator-dir", default=_REPO_ROOT,
                   help="the hugmesh-generator checkout that ships "
                        "specs/…/docker-compose.mesh.yml (default: this module's repo).")
    args = p.parse_args(argv)

    auth_key = _read_authkey(args)
    cfg = LocalMeshConfig(auth_key=auth_key, node_name=args.node_name,
                          login_server=args.login_server, workdir=args.workdir)
    node = LocalMeshNode(args.generator_dir, cfg)

    # No os.environ export needed here: LocalMeshNode._authkey() already prefers
    # cfg.auth_key over the environment, and _env() always overwrites TS_AUTHKEY from
    # that effective key before every compose invocation — an ambient env var would be
    # clobbered anyway. Same reasoning covers the GUI's _start(), which builds its
    # LocalMeshNode straight from the form-collected cfg.

    if args.subcommand == "up":
        ok, why = node.available()
        if not ok:
            print(f"[local-mesh] cannot start: {why}", file=sys.stderr)
            return 2
        ok, why = node.start()
        print(why or ("started" if ok else "failed"))
        return 0 if ok else 1
    if args.subcommand == "down":
        ok, why = node.stop()
        print(why or ("stopped" if ok else "failed"))
        return 0 if ok else 1
    if args.subcommand == "status":
        st = node.status()
        print(f"{'running' if st.running else 'stopped'} ({st.detail})")
        return 0
    # logs
    print(node.logs() or "(no logs — node not started?)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
