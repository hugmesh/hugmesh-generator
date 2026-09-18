"""Add ONE named account to the RUNNING **kind** mesh (#540), through the kind lane's
own seeding machinery — never a bespoke Casdoor call.

WHY A SECOND PATH AT ALL. ``localmesh._add_user`` applies by re-running the COMPOSE
seeder (``make stack-seed`` with ``EXTRA_ROLE_USERS`` appended). The kind lane seeds
differently: ``bootstrap-kind.sh`` step 10 renders with ``tests/qemu/seed-accounts.sh
--roles`` into a temp dir and applies ``roles/apply-systems-roles.sh`` against the live
Casdoor, with the Casdoor admin password read back from Vault. So on a kind mesh the
compose verb either is not offered or drives the wrong seeder. This module is the kind
half, and it deliberately runs the SAME two scripts in the same order, so an account
added here is created by exactly the machinery that created every other persona and
cannot drift from it.

THE STUDIO STILL NEVER SPAWNS A ``kubectl port-forward`` OF ITS OWN. bootstrap-kind.sh
reaches the ClusterIP Casdoor with a short-lived forward of its own; this module does
NOT copy that part, because ``core/view_doors`` states the rule plainly — hugmesh-view.py
owns a session-owner guard (one ``up`` per state dir) and a sweep of its own children,
and a second forwarder started from the GUI would fight it. Instead this ASKS
(``view_doors.live_doors``) for the ``casdoor`` door that ``make view LANE=kind-svc``
already publishes, and REFUSES with that exact remedy when it is not up. The Studio
already has the button that starts it. A refusal here is a refusal, never a fallback
into spawning one.

THE PASSWORD THE RENDER USES IS THE CLUSTER'S, NOT THIS CHECKOUT'S. seed-accounts.sh
resolves ``E2E_PASSWORD`` from an explicit override, else the run-state credentials
file, else it MINTS A FRESH ONE — and ``apply-systems-roles.sh`` reconciles EVERY
persona's stored password to whatever it was handed. So letting it mint would rotate
the whole cluster's roster as a side effect of adding one user, and every existing
sign-in would start 401ing. This module therefore takes the value the bring-up
recorded in the ``test-seed-passwords`` Secret, falls back to the local run-state file,
and REFUSES when it has neither. The value travels in the subprocess env only — never
argv, never a log line, never a returned string.

SUCCESS IS READ BACK, NOT REPORTED. Casdoor answers a DENIED call with HTTP 200 +
``{"status":"error"}``, which is how an earlier seeding run "succeeded" while entirely
unauthenticated. apply-systems-roles.sh now checks that envelope itself — and that is
still the hook reporting on its own work. The post-condition here is independent: the
account must be present in the cluster's own Casdoor database (``credentials_truth.
gather_kind_identities``, the #539 reader) AND hold every role it was granted. A user
created with ROLE_MOD on a cluster whose ROLE_MOD has no members afterwards is a FAILED
add, not a successful one.

Qt-free by construction. Every external effect goes through an injected seam
(``runner`` / ``doors`` / ``identities``), which is how the whole path is exercised
against a fake cluster without seeding anything anywhere.
"""
from __future__ import annotations

import base64
import os
import shutil
import subprocess
import tempfile
from collections.abc import Mapping
from dataclasses import dataclass, field

from . import credentials_truth as _truth
from . import view_doors

#: The view catalog row that publishes the kind Casdoor, and the lane that carries it
#: (scripts/hugmesh-view.tsv: ``casdoor  kind-svc  -  k8s+http://hugmesh-pki/casdoor:8000``).
#: Named here so the refusal can quote the exact command that makes the door.
DOOR_NAME = "casdoor"
VIEW_LANE = "kind-svc"
#: The door serves HTTPS under hugmesh-view's loopback-only CA, which lives in the
#: view session's state dir. curl honours CURL_CA_BUNDLE, so the seeder's own curl
#: trusts that door WITHOUT `-k` — an apply that disabled verification would be
#: indistinguishable from one talking to something else entirely.
CA_REL = os.path.join("tls", "ca.crt")

#: The scripts, repo-relative. Both are the kind lane's own — this module adds no
#: seeding logic of its own, it sequences theirs.
SEED_ACCOUNTS_REL = os.path.join("tests", "qemu", "seed-accounts.sh")
APPLY_ROLES_REL = os.path.join("roles", "apply-systems-roles.sh")

#: Where bootstrap-kind.sh records the password its seed used, and where the Vault
#: bootstrap token lives — the same two reads that script makes.
SEED_SECRET_NS = _truth.KIND_SEED_SECRET_NS
SEED_SECRET = _truth.KIND_SEED_SECRET
SEED_SECRET_KEY = _truth.KIND_SEED_SECRET_KEY
VAULT_NS = "vault"
VAULT_POD = "vault-0"
VAULT_BOOTSTRAP_SECRET = "vault-bootstrap"

RENDER_TIMEOUT_S = 180
APPLY_TIMEOUT_S = 300
READ_TIMEOUT_S = 30

#: Stage ids, so a caller (and a test) can say WHERE it stopped without matching prose.
STAGE_DOOR = "door"
STAGE_PASSWORD = "password"
STAGE_ADMIN = "admin-password"
STAGE_RENDER = "render"
STAGE_APPLY = "apply"
STAGE_READBACK = "read-back"
STAGE_OK = "ok"


@dataclass(frozen=True)
class AddUserOutcome:
    """What the verb did, in terms a page can render. Password-free by contract."""
    ok: bool
    stage: str
    message: str
    #: Roles the cluster actually grants the new account afterwards.
    granted: tuple[str, ...] = field(default=())
    #: Roles it was asked for that the cluster does NOT grant it.
    missing: tuple[str, ...] = field(default=())


def _run(cmd, *, env=None, cwd=None, timeout=60) -> tuple[int, str]:
    """The default seam: one bounded subprocess, stdout+stderr folded, never raising."""
    try:
        r = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True,
                           timeout=timeout)
        return r.returncode, (r.stdout or "") + (r.stderr or "")
    except (OSError, subprocess.SubprocessError) as e:
        return 1, f"{type(e).__name__}: {e}"


def kind_lane_up(runner=_run, cluster: str = "hugmesh-local") -> bool | None:
    """Is the kind control-plane container there? True / False / **None** (docker did
    not answer). The same exact-name filter ``credentials_truth.probe_credentials``
    uses, so the two can never disagree about which cluster is meant."""
    rc, out = runner(["docker", "ps", "--filter",
                      f"name=^{cluster}-control-plane$", "--format", "{{.Names}}"],
                     timeout=READ_TIMEOUT_S)
    return bool((out or "").strip()) if rc == 0 else None


def _kubectl(generator_dir: str):
    try:
        from . import devops_tools
        return devops_tools.which("kubectl", generator_dir) or ""
    except Exception:                                    # noqa: BLE001
        return ""


def cluster_seed_password(runner, kubectl: str, ctx: str) -> tuple[str, str]:
    """The password THIS CLUSTER was seeded with, from ``test-seed-passwords``.

    Returns ``(value, "")`` or ``("", why)``. The value is handed straight to the
    seeder's env by the caller and is never logged or returned to the GUI."""
    if not kubectl:
        return "", "kubectl is not installed"
    rc, out = runner([kubectl, "--context", ctx, "-n", SEED_SECRET_NS, "get", "secret",
                      SEED_SECRET, "-o", "jsonpath={.data." + SEED_SECRET_KEY + "}"],
                     timeout=READ_TIMEOUT_S)
    raw = (out or "").strip()
    if rc != 0 or not raw:
        return "", (f"the {SEED_SECRET} Secret is not readable in {SEED_SECRET_NS} "
                    f"({raw[:160] or 'no output'})")
    try:
        return base64.b64decode(raw).decode("utf-8").strip(), ""
    except Exception as e:                               # noqa: BLE001
        return "", f"the {SEED_SECRET} Secret could not be decoded ({type(e).__name__})"


def casdoor_admin_password(runner, kubectl: str, ctx: str,
                           brand: str = "hugmesh") -> tuple[str, str]:
    """The Casdoor built-in admin password, read back from Vault — the SAME two reads
    bootstrap-kind.sh makes (``vault-bootstrap``'s token, then
    ``secret/<brand>/casdoor`` field ``admin_password_plain``).

    It is deliberately not re-derived: gen-cluster-secrets.sh MINTS it per cluster, so
    any local derivation would be a guess, and a wrong admin password is the documented
    fresh-cluster state that used to let a whole seed run unauthenticated."""
    if not kubectl:
        return "", "kubectl is not installed"
    rc, out = runner([kubectl, "--context", ctx, "-n", VAULT_NS, "get", "secret",
                      VAULT_BOOTSTRAP_SECRET, "-o", "jsonpath={.data.token}"],
                     timeout=READ_TIMEOUT_S)
    raw = (out or "").strip()
    if rc != 0 or not raw:
        return "", (f"the Vault bootstrap token is not readable "
                    f"({raw[:160] or 'no output'})")
    try:
        token = base64.b64decode(raw).decode("utf-8").strip()
    except Exception as e:                               # noqa: BLE001
        return "", f"the Vault bootstrap token could not be decoded ({type(e).__name__})"
    if not token:
        return "", "the Vault bootstrap token is empty"
    rc, out = runner([kubectl, "--context", ctx, "-n", VAULT_NS, "exec", VAULT_POD,
                      "-c", "vault", "--", "env",
                      "VAULT_ADDR=https://127.0.0.1:8200", "VAULT_SKIP_VERIFY=true",
                      f"VAULT_TOKEN={token}", "vault", "kv", "get",
                      "-field=admin_password_plain", f"secret/{brand}/casdoor"],
                     timeout=READ_TIMEOUT_S)
    value = (out or "").strip()
    if rc != 0 or not value:
        return "", ("the Casdoor admin password is not in Vault at "
                    f"secret/{brand}/casdoor ({value[:160] or 'no output'})")
    return value, ""


def _door_url(generator_dir: str, env, doors) -> tuple[str, str]:
    live = doors(generator_dir, env) if doors is not None else {}
    url = (live or {}).get(DOOR_NAME, "")
    if url:
        return url, ""
    return "", (
        f"the '{DOOR_NAME}' door is not up, and this Studio does not start a "
        f"kubectl port-forward of its own (hugmesh-view.py owns that, one session "
        f"per state dir). Open it first: `make view LANE={VIEW_LANE}` — or press "
        f"'Open the browser door' with that lane — then try again.")


def add_user_kind(*, generator_dir: str, cluster: str, specs, username: str,
                  roles, password: str = "", password_env: str = "",
                  brand: str = "hugmesh", env: Mapping[str, str] | None = None,
                  runner=_run, doors=view_doors.live_doors,
                  identities=None, on_line=None) -> AddUserOutcome:
    """Add ``username`` to the running kind mesh through the kind lane's seeders.

    ``specs`` is the FULL ``EXTRA_ROLE_USERS`` list this session has accumulated, not
    just the new one — apply-systems-roles.sh sets each role's members to EXACTLY the
    rendered list, so a single-user render would wipe every other persona's
    memberships. That is the same reason the compose verb re-seeds wholesale.

    Seams: ``runner`` (every subprocess), ``doors`` (the live view doors) and
    ``identities`` (the read-back; defaults to the #539 kind reader). A test supplies
    all three and nothing touches a cluster."""
    def note(line: str):
        if on_line:
            on_line(line)

    src = dict(env if env is not None else os.environ)
    ctx = f"kind-{cluster}"
    kubectl = _kubectl(generator_dir)

    # 1. THE DOOR. Asked, never started here.
    url, why = _door_url(generator_dir, env, doors)
    if not url:
        return AddUserOutcome(False, STAGE_DOOR, why)
    note(f"[add-user/kind] applying through the '{DOOR_NAME}' view door")

    # 2. THE CLUSTER'S OWN SEED PASSWORD. Never let the seeder mint a fresh one:
    #    apply-systems-roles.sh reconciles EVERY persona to whatever it is handed.
    shared, why = cluster_seed_password(runner, kubectl, ctx)
    if not shared:
        shared = str(src.get(_truth.SHARED_PASSWORD_ENV) or "") or \
            _truth.read_values(generator_dir, env).get(_truth.SHARED_PASSWORD_ENV, "")
        if not shared:
            return AddUserOutcome(
                False, STAGE_PASSWORD,
                f"Refusing to add a user: {why}, and no shared password is on disk "
                f"either. Rendering without one makes seed-accounts.sh MINT a fresh "
                f"value, and apply-systems-roles.sh would then reconcile every "
                f"existing persona to it — every current sign-in would start "
                f"failing. Re-run the identity seed first.")
        note("[add-user/kind] the cluster's recorded seed password is unreadable; "
             "using the run-state file's value (they must agree, or every persona "
             "would be rotated)")

    # 3. THE CASDOOR ADMIN PASSWORD, from Vault — bootstrap-kind.sh's own read.
    admin_pw, why = casdoor_admin_password(runner, kubectl, ctx, brand=brand)
    if not admin_pw:
        return AddUserOutcome(False, STAGE_ADMIN,
                              f"Cannot authenticate to Casdoor: {why}. Without it "
                              f"apply-systems-roles.sh would be rejected — and a "
                              f"rejection is HTTP 200 with a status=error envelope, "
                              f"so it must not be attempted blind.")

    # 4. RENDER, with the FULL spec list (see the docstring).
    work = tempfile.mkdtemp(prefix="hugmesh-studio-kind-seed-")
    try:
        render_env = dict(src)
        render_env["EXTRA_ROLE_USERS"] = " ".join(specs)
        render_env[_truth.SHARED_PASSWORD_ENV] = shared
        if password and password_env:
            render_env[password_env] = password        # env-only, never argv
        note("[add-user/kind] rendering the role matrix (seed-accounts.sh --roles) …")
        rc, out = runner(["bash", os.path.join(generator_dir, SEED_ACCOUNTS_REL),
                          "--roles", work],
                         env=render_env, cwd=generator_dir, timeout=RENDER_TIMEOUT_S)
        if rc != 0:
            return AddUserOutcome(False, STAGE_RENDER,
                                  f"seed-accounts.sh --roles failed: "
                                  f"{(out or '').strip()[-400:] or 'no output'}")
        apply_sh = os.path.join(work, APPLY_ROLES_REL)
        if not os.path.exists(apply_sh):
            return AddUserOutcome(False, STAGE_RENDER,
                                  f"seed-accounts.sh --roles rendered no "
                                  f"{APPLY_ROLES_REL}")

        # 5. APPLY, through the door, with the door's own CA so curl verifies.
        apply_env = dict(src)
        apply_env["CASDOOR_URL"] = url
        apply_env["CASDOOR_ADMIN_PASS"] = admin_pw     # env-only, never argv
        apply_env[_truth.SHARED_PASSWORD_ENV] = shared
        if password and password_env:
            apply_env[password_env] = password
        ca = os.path.join(view_doors.state_dir(generator_dir, env), CA_REL)
        if os.path.exists(ca):
            apply_env["CURL_CA_BUNDLE"] = ca
        note("[add-user/kind] applying (apply-systems-roles.sh) …")
        rc, out = runner(["bash", apply_sh], env=apply_env, cwd=generator_dir,
                         timeout=APPLY_TIMEOUT_S)
        applied_ok = rc == 0 and '"status":"error"' not in (out or "").replace(" ", "")
    finally:
        shutil.rmtree(work, ignore_errors=True)

    # 6. READ THE IDENTITY BACK. The seeder's own success line is not evidence.
    if identities is None:
        def identities(_gd=generator_dir, _c=cluster):
            class _N:
                def _probe(self, cmd, timeout=15):
                    return _run(cmd, timeout=timeout)
            return _truth.gather_kind_identities(_N(), _gd, _c)
    try:
        found = identities()
    except Exception as e:                               # noqa: BLE001
        found = _truth.KindIdentities(reason=f"{type(e).__name__}: {e}")

    if found.users is None:
        return AddUserOutcome(
            False, STAGE_READBACK,
            ("The seeder reported success, but the identity could NOT be read back "
             if applied_ok else "The seeder failed, and the identity could not be "
             "read back either ")
            + f"({found.reason or 'the cluster did not answer'}), so this add is "
            f"unproven. Nothing here will call it a success on the seeder's own word.")
    if username not in found.users:
        return AddUserOutcome(
            False, STAGE_READBACK,
            f"'{username}' is NOT in the cluster's identity store after the seed"
            + (", although apply-systems-roles.sh exited 0" if applied_ok else "")
            + f". {(out or '').strip()[-300:]}")

    wanted = tuple(r for r in (roles or ()) if r)
    granted = tuple(r for r in wanted
                    if found.roles is not None
                    and username in dict(found.roles).get(r, frozenset()))
    if found.roles is None:
        return AddUserOutcome(
            True, STAGE_READBACK,
            f"'{username}' exists in the cluster's identity store. Its ROLE "
            f"memberships could not be read ({found.reason or 'no reason given'}), "
            f"so they are unverified — check them before relying on them.")
    missing = tuple(r for r in wanted if r not in granted)
    if missing:
        return AddUserOutcome(
            False, STAGE_READBACK,
            f"'{username}' was created but the cluster grants it none of: "
            f"{', '.join(missing)}. An account in none of its roles signs in on the "
            f"gateway floor and then 403s on every page, so this is a failed add, "
            f"not a successful one.", granted=granted, missing=missing)
    return AddUserOutcome(
        True, STAGE_OK,
        f"'{username}' exists in the cluster's identity store and holds "
        f"{', '.join(granted) if granted else 'no roles (none were requested)'} — "
        f"read back from Casdoor's own database, not from the seeder's exit code.",
        granted=granted)
