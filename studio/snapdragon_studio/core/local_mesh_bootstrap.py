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
import re
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

# A BCP-47-shaped locale tag: a primary subtag plus optional script/region subtags
# (e.g. de, fr, pt-BR, zh-Hant, en-XA). Deliberately lenient on SHAPE only — the
# authority on whether a catalog EXISTS is the login-ui build, which fails loudly
# on a requested locale with no messages.<locale>.xlf. Validating existence here
# would invent a constraint this config cannot honestly check (the login-ui repo
# is not cloned until `make stack-clone`).
_LOCALE_RE = re.compile(r"^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$")

_REPO_ROOT = os.path.abspath(
    os.path.join(os.path.dirname(__file__), os.pardir, os.pardir, os.pardir))

# BRAND is a Vault path segment AND a dot-sourced profile selector (brands/<BRAND>.conf).
# Mirror scripts/gen-keystores.sh:45-53's DNS-label gate EXACTLY — that script hard-errors
# and refuses to source the profile for a non-label BRAND, so we BLOCK the same shape (and
# no stricter). A value like `../../evil` would otherwise select an arbitrary shell file.
_BRAND_DNS_LABEL = re.compile(r"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")

# brands/domains.conf is a MULTI-DOMAIN CA registry (its own header :1-8 says so), not a
# brand profile — never offer it as a brand slug.
_NON_BRAND_CONF = frozenset({"domains"})

# The `context:` values compose.local.yaml resolves are ${STACK_SRC:-…}/snapdragon-<name>.
# Parse the repo dir name straight out of the consumer file so the "expected build context"
# set cannot drift from what `docker compose build` will actually resolve.
_CONTEXT_RE = re.compile(r"\$\{STACK_SRC[^}]*\}/(snapdragon[A-Za-z0-9._-]+)")
_COMPOSE_LOCAL = os.path.join("tests", "stack", "compose.local.yaml")


def discover_brands(generator_dir: str) -> list[str]:
    """Brand slugs with a real shell profile at brands/<slug>.conf — the ONLY files
    gen-cluster-secrets.sh:36-38 and the builders ever source. DEFAULT_BRAND leads even
    though it has NO .conf: the `-f` guard silently skips a missing profile, and that is
    exactly what the CLI's ``--brand`` default resolves to (brands/README.md documents
    ``.conf`` as the profile form). Deliberately does NOT offer ``acme`` (only acme.yaml
    exists — a tenant-set manifest for the render path, a DIFFERENT catalog with a
    DIFFERENT consumer) nor ``domains`` (a CA registry, see _NON_BRAND_CONF)."""
    brands_dir = os.path.join(generator_dir, "brands")
    slugs: set[str] = set()
    try:
        for name in os.listdir(brands_dir):
            if name.endswith(".conf"):
                slug = name[: -len(".conf")]
                if slug and slug not in _NON_BRAND_CONF:
                    slugs.add(slug)
    except OSError:
        pass
    slugs.discard(DEFAULT_BRAND)
    return [DEFAULT_BRAND] + sorted(slugs)


def expected_build_contexts(generator_dir: str) -> list[str]:
    """The repo directory names ``docker compose build`` will resolve as build contexts,
    parsed from the ${STACK_SRC:-…}/snapdragon-<name> ``context:`` values in
    tests/stack/compose.local.yaml. Derived from the file compose ACTUALLY reads, so it
    cannot drift from what a build resolves (deriving from clone-all-repos.sh's REPOS
    would drift — the two sets differ). Sorted + de-duplicated (snapdragon-gateway
    appears 3x — one image, three service roles)."""
    path = os.path.join(generator_dir, _COMPOSE_LOCAL)
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except OSError:
        return []
    return sorted(set(_CONTEXT_RE.findall(text)))


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
    # WHERE the buildable repo source comes from:
    #   "clone"    — TODAY'S behaviour: `make stack-clone` downloads all repos into
    #                ./.stack-src, then compose builds from there. source_dir ignored.
    #   "existing" — build from a tree the operator already has (STACK_SRC=<source_dir>),
    #                and SKIP the clone (STACK_NO_CLONE=1) so it is never git-reset.
    # DEFAULT "clone" + empty source_dir == zero regression: LocalStackNode._build_env()
    # sets nothing new, STACK_SRC stays unset, the Makefile's own default resolves as now.
    source_mode: str = "clone"
    source_dir: str = ""
    # Translation catalogs the login-ui image is BUILT with. EMPTY (the default) =
    # English-only: the image ships zero catalog files and the browser issues zero
    # catalog requests — the smallest artifact, and no i18n network surface at all
    # on the LAN-only/offline test path this config defaults to.
    #
    # This is a CLUSTER-plane fact, not desktop theming: the web login is served to
    # browsers by the mesh, so it is NOT scoped to x86 and does NOT belong with
    # brand_logo/color_scheme/login_background (all _X86, all desktop-class
    # surfaces a mesh node never carries). It lives here, on the config that
    # actually brings up the stack that BUILDS the login-ui image.
    web_locales: tuple[str, ...] = ()

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
                              social=self.cfg.social, domain=domain,
                              source_mode=self.cfg.source_mode,
                              source_dir=self.cfg.source_dir,
                              web_locales=self.cfg.web_locales)

    def _mesh_node(self) -> LocalMeshNode:
        return LocalMeshNode(self.generator_dir, LocalMeshConfig(
            auth_key=self.cfg.auth_key, node_name=self.cfg.node_name,
            login_server=self.cfg.login_server))

    # ---- source-tree coverage (Qt-free; drives the GUI source axis) -------------
    def expected_contexts(self) -> list[str]:
        """Repo dir names compose.local.yaml will build (see expected_build_contexts)."""
        return expected_build_contexts(self.generator_dir)

    def source_coverage(self) -> tuple[list[str], list[str]]:
        """(found, missing) expected build contexts under ``cfg.source_dir`` — only
        meaningful in 'existing' mode. found+missing == expected_contexts(). Never
        rounds up: a context counts as found only if the directory is really there."""
        expected = self.expected_contexts()
        base = self.cfg.source_dir.strip()
        if not base or not os.path.isdir(base):
            return [], expected
        found = [c for c in expected if os.path.isdir(os.path.join(base, c))]
        missing = [c for c in expected if c not in found]
        return found, missing

    # ---- brand-profile discovery (Qt-free) --------------------------------------
    def brand_conf_path(self) -> str:
        return os.path.join(self.generator_dir, "brands", f"{self.cfg.brand}.conf")

    def brand_has_conf(self) -> bool:
        """True when brands/<brand>.conf exists — the file gen-cluster-secrets.sh's
        `-f` guard sources. DEFAULT_BRAND has none, and that is correct (built-in
        defaults); this just reports the honest state rather than pretending."""
        return bool(self.cfg.brand.strip()) and os.path.isfile(self.brand_conf_path())

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
        # BRAND — a Vault path segment + a dot-sourced profile selector. BLOCK only the
        # shapes the tool itself hard-errors on (#387): empty (BASE=${BRAND:-snapdragon}
        # would silently mean something other than the UI shows) and non-DNS-label
        # (gen-keystores.sh:45-53 refuses to source brands/<brand>.conf). A brand with no
        # .conf is NOT blocked — the tool accepts it and exits 0 (see warnings()).
        brand = self.cfg.brand.strip()
        if not brand:
            problems.append("Brand must not be empty — it is the secret/<BRAND>/ Vault "
                            "base path segment.")
        elif not _BRAND_DNS_LABEL.match(brand):
            problems.append(f"Brand '{brand}' is not a DNS label [a-z0-9-] — "
                            f"gen-keystores.sh refuses to source brands/{brand}.conf.")
        # SOURCE axis — BLOCK only where compose will certainly hard-error.
        sm = self.cfg.source_mode
        if sm not in ("clone", "existing"):
            problems.append(f"source_mode must be 'clone' or 'existing' (got '{sm}').")
        elif sm == "existing":
            sd = self.cfg.source_dir.strip()
            if not sd:
                problems.append("Building from an existing tree needs a directory — "
                                "an empty STACK_SRC would silently fall back to the "
                                "Makefile default and build the WRONG tree.")
            elif not os.path.isdir(sd):
                problems.append(f"Source tree not found: {sd} — compose hard-errors on "
                                f"a missing build context.")
            else:
                found, _missing = self.source_coverage()
                if not found:
                    problems.append(
                        f"{sd} holds NONE of the {len(self.expected_contexts())} "
                        f"expected build contexts (snapdragon-*) — almost certainly the "
                        f"wrong directory; compose errors on the first build context.")
        # FORM only. Whether a catalog actually EXISTS for a locale is checked by the
        # login-ui build itself (tools/i18n/emit-shipped-locales.mjs fails loudly on a
        # requested locale with no messages.<locale>.xlf). The catalogs live in that
        # repo, which is not even cloned yet at this point (`make stack-clone` fetches
        # it), so validating existence here would mean inventing a constraint this
        # config cannot honestly check — and getting it wrong in BOTH directions:
        # rejecting a locale the repo does have, or passing one it doesn't.
        for loc in self.cfg.web_locales:
            if not _LOCALE_RE.match(loc):
                problems.append(f"web locale '{loc}' is not a BCP-47-shaped tag "
                                f"(e.g. de, fr, pt-BR, en-XA).")
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

    def warnings(self) -> list[str]:
        """ADVISORY (never blocks — per the #387 rule these are shapes the tools accept
        and exit 0 on): a brand with no profile file, and an existing tree missing some
        of the build contexts compose will eventually ask for."""
        out: list[str] = []
        brand = self.cfg.brand.strip()
        if brand and _BRAND_DNS_LABEL.match(brand) and not self.brand_has_conf():
            if brand != DEFAULT_BRAND:
                out.append(
                    f"No brands/{brand}.conf profile — gen-cluster-secrets.sh runs fine "
                    f"with built-in defaults (the -f guard just skips sourcing), but "
                    f"MAIL_*/OAuth presets a profile would set stay unset.")
        if self.cfg.source_mode == "existing" and self.cfg.source_dir.strip() \
                and os.path.isdir(self.cfg.source_dir.strip()):
            found, missing = self.source_coverage()
            if found and missing:
                out.append(
                    f"{len(found)} of {len(found) + len(missing)} expected build "
                    f"contexts found under {self.cfg.source_dir.strip()} — compose "
                    f"builds fine until it reaches a missing one "
                    f"(missing: {', '.join(missing[:4])}"
                    + (", …" if len(missing) > 4 else "") + ").")
        return out

    def preflight(self) -> list[str]:
        """Fail-fast COLD-BUILD readiness (LocalStackNode.preflight): docker daemon,
        BuildKit/buildx visibility in the EXACT env `make stack-up` will run with,
        disk headroom, and the private-maven prerequisites when the service images
        must cold-build. Returns SHORT actionable problems (empty = ready) — the
        alternative is the operator diagnosing a truncated compose-build tail.
        Unlike validate() (pure config), this probes the host, so it runs on
        ``up`` (and is callable from the GUI) but never on mere selection."""
        return self._stack_node().preflight()

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
        lines.append("Web login:  "
                     + (", ".join(c.web_locales) + " (+ English source)" if c.web_locales
                        else "English only (no translation catalogs shipped)"))
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
        if c.source_mode == "existing":
            found, missing = self.source_coverage()
            lines.append(f"      SOURCE: your existing tree {c.source_dir.strip()}")
            lines.append(f"              ({len(found)} of {len(found) + len(missing)} "
                         "expected build contexts found; STACK_NO_CLONE=1 — your")
            lines.append("               checkouts are NEVER fetched, updated, or reset)")
        else:
            lines.append("      SOURCE: download/update all repos into ./.stack-src")
            lines.append("              (make stack-clone — every compose service builds")
            lines.append("               from those real, buildable files)")
        lines.append(f"      make stack-up   (ENV={c.env}, SOCIAL={'on' if c.social else 'off'})")
        _wl = ",".join(c.web_locales)
        lines.append(f"      make stack-up   (ENV={c.env}, SOCIAL={'on' if c.social else 'off'}"
                     + (f", SNAP_WEB_LOCALES={_wl}" if _wl else "") + ")")
        if _wl:
            lines.append(f"          -> login-ui image ships i18n/{{{_wl}}}.json catalogs")
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

        # Host preflight BEFORE any side effect (no creds are minted for a host
        # that cannot build/run the stack). On failure the operator gets a SHORT
        # actionable plan — e.g. "run `make stack-m2-bootstrap` first" — instead
        # of a wall of compose noise 30 minutes into a doomed cold build.
        problems = self.preflight()
        if problems:
            return False, ["preflight failed — nothing was generated or started. "
                           "Fix, then retry:",
                           *(f"  - {p}" for p in problems)]

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


def _parse_web_locales(raw: str) -> tuple[str, ...]:
    """Parse a comma/space-separated --web-locales value into a deduped tuple,
    order-preserving. Empty => () => English-only."""
    seen: list[str] = []
    for tok in re.split(r"[,\s]+", raw or ""):
        tok = tok.strip()
        if tok and tok not in seen:
            seen.append(tok)
    return tuple(seen)


def _cfg_from_args(args: argparse.Namespace) -> LocalMeshBootstrapConfig:
    return LocalMeshBootstrapConfig(
        env=args.env, superadmin_username=args.superadmin_username,
        out_dir=args.out, social=args.social, auth_key=_read_authkey(args),
        login_server=args.login_server, node_name=args.node_name,
        brand=args.brand, cluster_domain=args.cluster_domain,
        source_mode=args.source_mode, source_dir=args.source_dir,
        web_locales=_parse_web_locales(args.web_locales))


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
    p.add_argument("--source-mode", choices=("clone", "existing"), default="clone",
                   help="'clone' (default) = make stack-clone downloads/updates all "
                        "repos into ./.stack-src and compose builds from there — "
                        "today's exact behaviour. 'existing' = build from a tree you "
                        "already have (--source-dir), with STACK_NO_CLONE=1 so your "
                        "checkouts are never fetched or git-reset.")
    p.add_argument("--source-dir", default="",
                   help="the source tree for --source-mode existing; each service "
                        "builds from <dir>/snapdragon-<name>.")
    p.add_argument("--web-locales", default="",
                   help="translation catalogs the web login image ships, comma-"
                        "separated (e.g. de,fr,pt-BR). EMPTY (default) = English-"
                        "only: zero catalog files, zero catalog requests. English is "
                        "the source language and needs no catalog.")
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
