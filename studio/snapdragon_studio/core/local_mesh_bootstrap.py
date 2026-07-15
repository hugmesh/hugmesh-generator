"""Local Docker mesh — FROM-SCRATCH superadmin bootstrapper.

Extends the fourth first-screen choice ("Local Docker mesh") from a JOIN-only flow
(core/local_mesh.py: LocalMeshNode joins an existing tailnet with a provided
TS_AUTHKEY) into a *generate-and-start-a-new-mesh-from-scratch* flow: mint ALL
platform credentials locally, bring up the FULL platform stack seeded with a fresh
superadmin identity, and (in prod) attach the tailscale overlay.

Design split (mirrors local_mesh.py's LocalMeshConfig/LocalMeshNode,
local_stack_node.py's LocalStackNode, and golive_driver.py's driver/options):
  - ``LocalMeshBootstrapConfig`` — the pure-data knobs the operator provides.
  - ``LocalMeshBootstrap`` — the orchestrator. It forks NO new local-mesh mechanism:
    it COMPOSES the three EXISTING pieces —
      1. the gen scripts (scripts/gen-cluster-secrets.sh + gen-provision-keys.sh),
      2. ``LocalStackNode`` (make stack-up / stack-seed / stack-down),
      3. ``LocalMeshNode`` (the #340 tailscale overlay) —
    adding NO compose invocation of its own.

Two mutually-exclusive paths surface in ONE place (the GUI LocalMeshDialog, the
ncurses menu, and this module's CLI):
  - JOIN (core/local_mesh.py, unchanged): LocalMeshConfig -> LocalMeshNode.start()
    with a provided TS_AUTHKEY.
  - BOOTSTRAP-FROM-SCRATCH (this module): generate creds -> full platform stack
    seeded with the minted superadmin -> optionally attach the mesh overlay.

Non-destructive by default: NOTHING is generated or started on mere selection.
``plan()`` is pure/side-effect-free (the confirm-before-run manifest); only the
explicit ``up`` action mints creds + starts containers. It is host-local (docker on
the operator's own machine) and refuses to run inside a cluster pod.

This module NEVER touches ImageConfig / to_cli_args() / the mesh manifest — a local
bootstrap builds no image, so it emits nothing into the builder argv the
build-matrix guards (the same non-image side-flow discipline as #340).
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from dataclasses import dataclass

from .local_mesh import ENV_AUTHKEY, LocalMeshConfig, LocalMeshNode
from .local_stack_node import LocalStackNode
from .mesh_node import MeshNode

# The two credential generators (repo-relative). Reused VERBATIM via subprocess
# (like MeshNode shells `docker compose` and golive shells its driver) — this module
# NEVER reimplements secret generation.
GEN_CLUSTER_SECRETS = "scripts/gen-cluster-secrets.sh"
GEN_PROVISION_KEYS = "scripts/gen-provision-keys.sh"

# The env-var NAME seed-e2e.sh resolves the ROLE_SUPERADMIN persona's password from
# (its persona spec is `<user>:ROLE_SUPERADMIN:E2E_SUPERADMIN_PASSWORD` — the third
# field is a var NAME, not the value). Bridging the minted password in under this name
# provisions the running platform's ROLE_SUPERADMIN with it.
SEED_SUPERADMIN_PASSWORD_ENV = "E2E_SUPERADMIN_PASSWORD"

# The env-var seed-e2e.sh reads for the ROLE_SUPERADMIN persona's LOGIN NAME. seed-e2e
# defaults it to `e2e-superadmin` (so ordinary e2e runs are unchanged), but the
# bootstrap bridges the minted/advertised username in under it so the seeded login
# matches the plan, the log, and the minted secrets.json — otherwise the operator
# would be told to log in as a username the running stack never created.
SEED_SUPERADMIN_USERNAME_ENV = "CASDOOR_SUPERADMIN_USERNAME"

# Default brand + its apex domain (mirrors gen-cluster-secrets.sh's own defaults).
DEFAULT_BRAND = "snapdragon"
DEFAULT_DOMAIN = "snapdragon.systems"

_REPO_ROOT = os.path.abspath(
    os.path.join(os.path.dirname(__file__), os.pardir, os.pardir, os.pardir))


@dataclass
class LocalMeshBootstrapConfig:
    """Operator-provided knobs for minting + starting a from-scratch local mesh.

    ``env`` ("test"|"prod") threads to BOTH creds and stack, matching the
    platform-wide ENV knob:
      - test (DEFAULT, LAN-only/safe): issuer http://localhost:8000, brand-default
        domain, no public DNS/OAuth/SMTP, mesh overlay SKIPPED (no tailnet needed).
      - prod: real public domain (``cluster_domain`` REQUIRED) -> issuer
        https://id.<domain>; the mesh overlay attaches (``auth_key`` REQUIRED).

    ``out_dir`` is the RUNTIME creds dir (default the gitignored ``keys-out/``); the
    minted secrets land under ``<out_dir>/vault`` + ``<out_dir>/keys`` at runtime
    only — never committed. ``auth_key``/``login_server``/``node_name`` are only
    used (and only required) on the prod overlay path."""
    env: str = "test"
    superadmin_username: str = "superadmin"
    out_dir: str = ""
    social: bool = False
    auth_key: str = ""
    login_server: str = ""
    node_name: str = ""
    brand: str = DEFAULT_BRAND
    cluster_domain: str = ""

    def is_prod(self) -> bool:
        return self.env == "prod"

    def resolved_domain(self) -> str:
        """The apex the minted Casdoor issuer/superadmin align with. In prod the
        operator-supplied ``cluster_domain`` (or brand default); in test the brand
        default (never surfaced as a public issuer — test issuer is localhost)."""
        return (self.cluster_domain.strip() or DEFAULT_DOMAIN)

    def issuer(self) -> str:
        """The Casdoor issuer the stack derives (Makefile ENV->issuer, mirrored here
        for the plan preview only — LocalStackNode/Makefile remain the authority)."""
        if self.is_prod():
            return f"https://id.{self.resolved_domain()}"
        return "http://localhost:8000"


class LocalMeshBootstrap:
    """Orchestrates the from-scratch path by COMPOSING the gen scripts + LocalStackNode
    + LocalMeshNode. Lives beside LocalMeshNode and imports it — it adds NO compose
    invocation of its own (same discipline as LocalMeshNode)."""

    def __init__(self, generator_dir: str, cfg: LocalMeshBootstrapConfig | None = None):
        self.generator_dir = os.path.abspath(generator_dir)
        self.cfg = cfg or LocalMeshBootstrapConfig()

    # ---- resolved runtime paths (named in the plan so the operator sees them) ----
    @property
    def out_dir(self) -> str:
        return os.path.abspath(
            self.cfg.out_dir.strip()
            or os.path.join(self.generator_dir, "keys-out"))

    @property
    def vault_dir(self) -> str:
        return os.path.join(self.out_dir, "vault")

    @property
    def keys_dir(self) -> str:
        return os.path.join(self.out_dir, "keys")

    @property
    def secrets_json(self) -> str:
        return os.path.join(self.vault_dir, "secrets.json")

    def overlay_will_attach(self) -> bool:
        """The mesh overlay's tailscale service REQUIRES ``${TS_AUTHKEY:?}``, so it is
        only attached when a key is supplied — the prod path. In test/LAN-only mode
        it is skipped (the from-scratch platform still comes up fully without a key)."""
        return self.cfg.is_prod() and bool(self.cfg.auth_key.strip())

    # ---- composed drivers -------------------------------------------------------
    def _stack_node(self) -> LocalStackNode:
        # In prod, thread the resolved apex as DOMAIN so `make stack-up` derives the
        # SAME Casdoor issuer (https://id.<domain>) the secrets were minted for and
        # the plan advertised — otherwise the running issuer silently defaults to the
        # brand apex. In test the issuer is localhost, so DOMAIN is left empty.
        domain = self.cfg.resolved_domain() if self.cfg.is_prod() else ""
        return LocalStackNode(self.generator_dir, env=self.cfg.env,
                              social=self.cfg.social, domain=domain)

    def _mesh_node(self) -> LocalMeshNode:
        return LocalMeshNode(self.generator_dir, LocalMeshConfig(
            auth_key=self.cfg.auth_key, node_name=self.cfg.node_name,
            login_server=self.cfg.login_server))

    # ---- guards -----------------------------------------------------------------
    @staticmethod
    def _in_cluster_pod() -> bool:
        """True when running inside a k8s pod. Bootstrapping is HOST-LOCAL (docker on
        the operator's machine) and cannot run in a cluster pod."""
        return bool(os.environ.get("KUBERNETES_SERVICE_HOST")) or \
            os.path.exists("/var/run/secrets/kubernetes.io")

    def guard_host_local(self) -> tuple[bool, str]:
        """Refuse unless this is a host-local run with docker/compose/make present.
        Reuses LocalStackNode.available() (make + compose + stack file) and, when the
        overlay will attach, MeshNode.available() (the mesh compose template)."""
        if self._in_cluster_pod():
            return False, ("Refusing to bootstrap a from-scratch mesh inside a cluster "
                           "pod — this is a HOST-LOCAL action (docker on the operator's "
                           "own machine).")
        ok, why = self._stack_node().available()
        if not ok:
            return False, why
        if self.overlay_will_attach():
            ok, why = MeshNode(self.generator_dir).available()
            if not ok:
                return False, why
        return True, ""

    def validate(self) -> list[str]:
        """Config problems that would stop an ``up`` (empty = OK). Courtesy preflight
        surfaced in the plan; ``up`` re-checks the same guards."""
        problems: list[str] = []
        if self.cfg.env not in ("test", "prod"):
            problems.append(f"ENV must be 'test' or 'prod' (got '{self.cfg.env}').")
        if not self.cfg.superadmin_username.strip():
            problems.append("Superadmin username must not be empty.")
        if self.cfg.is_prod():
            if not self.cfg.cluster_domain.strip():
                problems.append("prod requires a public cluster domain "
                                "(--cluster-domain) so the minted issuer/superadmin "
                                "align with the real apex.")
            if not self.cfg.auth_key.strip():
                problems.append("prod requires a tailnet/headscale auth key "
                                "(--authkey-file) to attach the mesh overlay to the "
                                "real tailnet.")
        return problems

    # ---- confirm-before-run manifest (PURE, no side effects) --------------------
    def plan(self) -> str:
        """A human-readable manifest of EXACTLY what an ``up`` will generate + start —
        side-effect-free. The GUI shows it in a read-only preview the operator must
        acknowledge; the CLI prints it. Renders: (a) which scripts run + the out dir,
        (b) which compose projects come up, (c) ENV/issuer/domain, (d) the superadmin
        USERNAME + WHERE its freshly-minted password will be written (NEVER the value)."""
        c = self.cfg
        overlay = self.overlay_will_attach()
        lines: list[str] = []
        lines.append("Generate & start a NEW local Docker mesh FROM SCRATCH")
        lines.append("=" * 56)
        lines.append("")
        lines.append(f"ENV:        {c.env}"
                     + ("  (LAN-only / offline — the safe default)" if not c.is_prod()
                        else "  (REAL public domain)"))
        lines.append(f"Brand:      {c.brand}")
        lines.append(f"Domain:     {c.resolved_domain()}"
                     + ("" if c.is_prod() else "  (brand default; not a public issuer in test)"))
        lines.append(f"Issuer:     {c.issuer()}")
        lines.append("")
        lines.append("(1) GENERATE credentials (offline — VAULT_ADDR left unset):")
        lines.append(f"      {GEN_CLUSTER_SECRETS} --out {self.vault_dir}")
        lines.append("          -> Casdoor/ClickHouse/Uptrace secrets + the platform")
        lines.append(f"             superadmin, written to {self.secrets_json}")
        lines.append(f"      {GEN_PROVISION_KEYS} -o {self.keys_dir} --random")
        lines.append(f"          -> SSH keypairs + password hashes under {self.keys_dir}")
        lines.append("             (vault-seed/ private material stays VAULT-ONLY —")
        lines.append("              never baked, bundled, or logged by this bootstrap)")
        lines.append("")
        lines.append("(2) START the full platform stack (compose project via")
        lines.append("    tests/stack/compose.local.yaml — Casdoor + DB + gateway + BFFs):")
        lines.append(f"      make stack-up   (ENV={c.env}, SOCIAL={'on' if c.social else 'off'})")
        lines.append("      make stack-seed (provisions ROLE_SUPERADMIN with the minted")
        lines.append("                       password, bridged via env only)")
        lines.append("")
        lines.append("(3) MESH OVERLAY (snapdragon-mesh compose project, tailscale):")
        if overlay:
            lines.append("      ATTACHED — prod + auth key supplied; joins the real tailnet"
                         + (f" via {c.login_server}" if c.login_server.strip() else ""))
        else:
            lines.append("      SKIPPED — LAN-only (no TS_AUTHKEY); the from-scratch")
            lines.append("      platform still comes up fully without a tailnet.")
        lines.append("")
        lines.append("SUPERADMIN identity:")
        lines.append(f"      username: {c.superadmin_username}")
        lines.append("      password: minted fresh (openssl rand) — written ONLY to")
        lines.append(f"                {self.secrets_json}")
        lines.append(f"                (under {c.brand}-pki -> casdoor-superadmin; the")
        lines.append("                 value is NEVER printed, logged, or committed)")
        lines.append("")
        lines.append(f"Creds land in a runtime dir: {self.out_dir}  (gitignored)")
        problems = self.validate()
        if problems:
            lines.append("")
            lines.append("BLOCKERS (fix before 'up'):")
            lines.extend(f"  - {p}" for p in problems)
        return "\n".join(lines)

    # ---- credential generation (subprocess; values never argv / never logged) ---
    def _gen_env(self) -> dict[str, str]:
        """Curated env for the gen scripts. VAULT_ADDR/VAULT_TOKEN are DELIBERATELY
        removed so the mint stays offline (USB/secrets.json only). BRAND +
        CASDOOR_SUPERADMIN_USERNAME steer gen-cluster-secrets.sh; CLUSTER_DOMAIN is
        pinned in prod so the issuer/superadmin align with the real apex (in test it
        is left to the brand default). NONINTERACTIVE=1 makes gen-provision-keys.sh
        skip every prompt."""
        env = os.environ.copy()
        env.pop("VAULT_ADDR", None)
        env.pop("VAULT_TOKEN", None)
        env["BRAND"] = self.cfg.brand
        env["CASDOOR_SUPERADMIN_USERNAME"] = self.cfg.superadmin_username
        env["NONINTERACTIVE"] = "1"
        if self.cfg.is_prod():
            env["CLUSTER_DOMAIN"] = self.cfg.resolved_domain()
        return env

    def generate_creds(self) -> tuple[bool, str]:
        """Run BOTH generators verbatim (cwd=generator_dir). Returns (ok, message).
        Secret VALUES only ever ride the scripts' internals + their output files —
        never this process's argv, and the curated env is never logged."""
        env = self._gen_env()
        for script, out_flag, out_dir, extra in (
                (GEN_CLUSTER_SECRETS, "--out", self.vault_dir, []),
                (GEN_PROVISION_KEYS, "-o", self.keys_dir, ["--random"])):
            cmd = ["bash", script, out_flag, out_dir, *extra]
            try:
                r = subprocess.run(cmd, cwd=self.generator_dir, env=env,
                                   capture_output=True, text=True, timeout=600)
            except (OSError, subprocess.SubprocessError) as e:
                return False, f"{script}: {e}"
            if r.returncode != 0:
                return False, f"{script} failed: {(r.stderr or r.stdout).strip()}"
        return True, f"credentials generated under {self.out_dir}"

    def read_superadmin(self, path: str | None = None) -> dict[str, str]:
        """Parse the minted ``<brand>-pki.casdoor-superadmin`` -> {username, password}
        from the offline bundle (stdlib json). Returns {} when unreadable/absent."""
        p = path or self.secrets_json
        try:
            with open(p, encoding="utf-8") as fh:
                data = json.load(fh)
        except (OSError, ValueError):
            return {}
        pki = data.get(f"{self.cfg.brand}-pki", {})
        sa = pki.get("casdoor-superadmin", {})
        if not isinstance(sa, dict):
            return {}
        return {"username": str(sa.get("username", "")),
                "password": str(sa.get("password", ""))}

    # ---- lifecycle --------------------------------------------------------------
    def up(self) -> tuple[bool, list[str]]:
        """The from-scratch bring-up. Returns (ok, log-lines). NO secret VALUE ever
        appears in the log lines — only the username + the path its password landed
        in. Order: guard -> generate -> read superadmin -> stack-up -> stack-seed
        (password bridged via env) -> (prod) attach overlay."""
        log: list[str] = []
        ok, why = self.guard_host_local()
        if not ok:
            return False, [why]
        problems = self.validate()
        if problems:
            return False, ["cannot start:", *(f"  - {p}" for p in problems)]

        ok, msg = self.generate_creds()
        log.append(f"[creds] {msg}")
        if not ok:
            return False, log

        sa = self.read_superadmin()
        if not sa.get("password"):
            log.append(f"[creds] could not read the minted superadmin from "
                       f"{self.secrets_json}")
            return False, log
        # NOTE: log the USERNAME + WHERE the password is — never the value.
        log.append(f"[creds] minted superadmin '{sa['username']}' "
                   f"(password in {self.secrets_json})")

        stack = self._stack_node()
        ok, msg = stack.start()
        log.append(f"[stack-up] {'ok' if ok else 'FAILED'}: {msg[:400]}")
        if not ok:
            return False, log

        # Bridge BOTH the minted username and password into `make stack-seed` (env
        # only, never argv): the username so seed-e2e provisions the ROLE_SUPERADMIN
        # persona under the login the plan/log/secrets advertise (not the hardcoded
        # e2e-superadmin default), the password so it is actually usable.
        ok, msg = stack.seed({
            SEED_SUPERADMIN_USERNAME_ENV: sa["username"],
            SEED_SUPERADMIN_PASSWORD_ENV: sa["password"],
        })
        log.append(f"[stack-seed] {'ok' if ok else 'FAILED'}: {msg[:400]}")
        if not ok:
            return False, log

        if self.overlay_will_attach():
            mesh = self._mesh_node()
            # MeshNode.start() reads os.environ["TS_AUTHKEY"] for its guard +
            # compose interpolation (LocalMeshNode stages it into .env but does not
            # export it — same gap local_mesh.main() closes before start()).
            os.environ[ENV_AUTHKEY] = self.cfg.auth_key.strip()
            ok, msg = mesh.start()
            log.append(f"[mesh-overlay] {'ok' if ok else 'FAILED'}: {msg[:400]}")
            if not ok:
                return False, log
        else:
            log.append("[mesh-overlay] skipped (LAN-only / no auth key)")

        log.append(f"[done] platform up. Front door: {self._stack_node().web_url}  "
                   f"| Casdoor issuer: {self.cfg.issuer()}")
        return True, log

    def down(self) -> tuple[bool, list[str]]:
        """Tear down BOTH composed projects: the stack (make stack-down) + the mesh
        overlay (LocalMeshNode.stop())."""
        log: list[str] = []
        ok_stack, msg = self._stack_node().stop()
        log.append(f"[stack-down] {'ok' if ok_stack else 'FAILED'}: {msg[:400]}")
        ok_mesh, msg = self._mesh_node().stop()
        log.append(f"[mesh-overlay down] {'ok' if ok_mesh else 'FAILED'}: {msg[:400]}")
        return (ok_stack and ok_mesh), log

    def status(self) -> list[str]:
        st = self._stack_node().status()
        ms = self._mesh_node().status()
        return [
            f"platform stack: {'running' if st.running else 'stopped'} ({st.detail})",
            f"mesh overlay:   {'running' if ms.running else 'stopped'} ({ms.detail})",
        ]


# ── Qt-free CLI face (the SHARED entrypoint) ────────────────────────────────────
# The ncurses menu (scripts/build-menu.sh) and the Makefile mesh-bootstrap-* targets
# both shell `python3 -m snapdragon_studio.core.local_mesh_bootstrap <sub> …`, so GUI
# + ncurses + CLI drive the SAME LocalMeshBootstrapConfig -> LocalMeshBootstrap object
# graph — exactly as mesh-node-up wraps core.local_mesh. Imports only sibling core
# modules (NO Qt), so it runs in the Qt-free/system-python environment CI uses.


def _read_authkey(args: argparse.Namespace) -> str:
    """Resolve the auth key from --authkey-file (preferred: off the argv/process
    table) or --authkey. Trailing whitespace/newlines stripped."""
    if args.authkey_file:
        with open(args.authkey_file, encoding="utf-8") as fh:
            return fh.read().strip()
    return (args.authkey or "").strip()


def _cfg_from_args(args: argparse.Namespace) -> LocalMeshBootstrapConfig:
    return LocalMeshBootstrapConfig(
        env=args.env, superadmin_username=args.superadmin_username,
        out_dir=args.out, social=args.social, auth_key=_read_authkey(args),
        login_server=args.login_server, node_name=args.node_name,
        brand=args.brand, cluster_domain=args.cluster_domain)


def main(argv: list[str] | None = None) -> int:
    """Qt-free entrypoint shared by the ncurses menu + the Makefile mesh-bootstrap
    targets. Verbs: plan | up | down | status.

    Non-destructive by default: ``plan`` only prints the manifest; ``up`` is the sole
    action that mints creds + starts containers, and a prod ``up`` requires an
    interactive TTY confirm with NO bypass flag (mirroring golive's no-bypass
    posture)."""
    p = argparse.ArgumentParser(
        prog="snapdragon-mesh-bootstrap",
        description=(
            "Generate ALL credentials from scratch and start a NEW superadmin-"
            "controlled Snapdragon mesh on THIS machine in Docker — the 'generate & "
            "start from scratch' path of the wizard's fourth choice. Builds NO image; "
            "composes the gen scripts + `make stack-up` + the docker-compose.mesh.yml "
            "overlay. Host-local only (refuses to run in a cluster pod)."))
    p.add_argument("subcommand", choices=("plan", "up", "down", "status"),
                   help="plan = print the confirm-before-run manifest (no side "
                        "effects); up = GENERATE creds + START the stack (explicit "
                        "action; prod TTY-confirms); down = stop both projects; "
                        "status = are they running?")
    p.add_argument("--env", choices=("test", "prod"), default="test",
                   help="test (DEFAULT, LAN-only/offline) or prod (real public domain).")
    p.add_argument("--superadmin-username", default="superadmin",
                   help="the platform superadmin login to mint (default: superadmin).")
    p.add_argument("--out", default="",
                   help="runtime creds dir (default: the gitignored keys-out/).")
    p.add_argument("--social", action="store_true",
                   help="also bring up the social (Matrix/Mastodon) profile.")
    p.add_argument("--brand", default=DEFAULT_BRAND,
                   help=f"brand slug (default: {DEFAULT_BRAND}).")
    p.add_argument("--cluster-domain", default="",
                   help="public apex domain (REQUIRED in prod).")
    key = p.add_mutually_exclusive_group()
    key.add_argument("--authkey-file", default="",
                     help="path to a file holding the tailnet/headscale auth key "
                          "(REQUIRED in prod; keeps the secret off the process table).")
    key.add_argument("--authkey", default="",
                     help="the tailnet/headscale auth key inline (prefer --authkey-file).")
    p.add_argument("--node-name", default="",
                   help="optional hostname on the tailnet (prod overlay).")
    p.add_argument("--login-server", default="",
                   help="optional self-hosted headscale control-plane URL (prod overlay).")
    p.add_argument("--generator-dir", default=_REPO_ROOT,
                   help="the snapdragon-generator checkout (default: this module's repo).")
    args = p.parse_args(argv)

    cfg = _cfg_from_args(args)
    boot = LocalMeshBootstrap(args.generator_dir, cfg)

    if args.subcommand == "plan":
        print(boot.plan())
        return 0

    if args.subcommand == "status":
        for line in boot.status():
            print(line)
        return 0

    if args.subcommand == "down":
        ok, log = boot.down()
        for line in log:
            print(line)
        return 0 if ok else 1

    # up — the ONLY action that mints + starts. Show the plan, then (prod) require a
    # real-TTY confirm with NO bypass flag (golive's posture: unattended from-scratch
    # prod bring-up is not offered).
    print(boot.plan())
    print()
    if cfg.is_prod():
        if not sys.stdin.isatty():
            print("[refused] prod bootstrap requires an interactive TTY to confirm "
                  "(there is deliberately no --yes bypass).", file=sys.stderr)
            return 2
        try:
            reply = input("Type 'yes' to GENERATE credentials and START this prod "
                          "mesh from scratch: ").strip().lower()
        except (EOFError, KeyboardInterrupt):
            reply = ""
        if reply != "yes":
            print("[aborted] no changes made.")
            return 1
    ok, log = boot.up()
    for line in log:
        print(line)
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
