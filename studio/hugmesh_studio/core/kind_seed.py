"""Add ONE named account to the RUNNING **kind** mesh (#540) — through Casdoor's admin
API (``core.mesh_accounts``), not the seeder scripts.

WHY THE KIND LANE HAS ITS OWN MODULE. The compose lane's Casdoor is on loopback with this
checkout's admin password in ``tests/stack/.env``; the kind lane's is a ClusterIP whose
admin password lives in Vault. This module supplies those two things — the door and the
password — and hands the apply to the same ``mesh_accounts.create_account`` the compose
lane and every domain's Users tab use (2026-11-19, the operator: "adding users should
work without the e2e scripts"). It used to render with ``tests/qemu/seed-accounts.sh
--roles`` and apply ``roles/apply-systems-roles.sh``; that needed the test scripts, the
cluster's shared seed password (or it would rotate every persona), and the FULL spec
list of every account added this session (the apply set each role to exactly its
render). The native apply adds one account and ADDS it to its roles; nothing else moves.

THE STUDIO STILL NEVER SPAWNS A ``kubectl port-forward`` OF ITS OWN. bootstrap-kind.sh
reaches the ClusterIP Casdoor with a short-lived forward of its own; this module does
NOT copy that part, because ``core/view_doors`` states the rule plainly — hugmesh-view.py
owns a session-owner guard (one ``up`` per state dir) and a sweep of its own children,
and a second forwarder started from the GUI would fight it. Instead this ASKS
(``view_doors.live_doors``) for the ``casdoor`` door that ``make view LANE=kind-svc``
already publishes, and REFUSES with that exact remedy when it is not up. The door
serves HTTPS under the view session's own CA, which the apply verifies against.

SUCCESS IS READ BACK, NOT REPORTED. The apply reads its own writes back, and the
post-condition here is independent of it: the account must be present in the cluster's
own Casdoor database (``credentials_truth.gather_kind_identities``, the #539 reader) AND
hold every role it was granted. A user created with ROLE_MOD on a cluster whose ROLE_MOD
has no members afterwards is a FAILED add, not a successful one.

Qt-free by construction. Every external effect goes through an injected override point
(``runner`` / ``doors`` / ``identities`` / ``opener``), which is how the whole path is
exercised against a fake cluster without touching one.
"""
from __future__ import annotations

import base64
import os
import subprocess
from collections.abc import Mapping
from dataclasses import dataclass, field

from . import credentials_truth as _truth
from . import mesh_accounts, view_doors

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

#: Where bootstrap-kind.sh records the password its seed used (read by the credentials
#: view, not by an add any more), and where the Vault bootstrap token lives.
SEED_SECRET_NS = _truth.KIND_SEED_SECRET_NS
SEED_SECRET = _truth.KIND_SEED_SECRET
SEED_SECRET_KEY = _truth.KIND_SEED_SECRET_KEY
VAULT_NS = "vault"
VAULT_POD = "vault-0"
VAULT_BOOTSTRAP_SECRET = "vault-bootstrap"

READ_TIMEOUT_S = 30

#: Stage ids, so a caller (and a test) can say WHERE it stopped without matching prose.
STAGE_DOOR = "door"
STAGE_ADMIN = "admin-password"
STAGE_APPLY = "apply"
STAGE_READBACK = "read-back"
STAGE_OK = "ok"


@dataclass(frozen=True)
class AddUserOutcome:
    """What the verb did, in terms a page can render. ``password`` is set only when the
    apply GENERATED one (shown once by the page, never logged); ``message`` never
    carries a password."""
    ok: bool
    stage: str
    message: str
    #: Roles the cluster actually grants the new account afterwards.
    granted: tuple[str, ...] = field(default=())
    #: Roles it was asked for that the cluster does NOT grant it.
    missing: tuple[str, ...] = field(default=())
    password: str = ""


def _run(cmd, *, env=None, cwd=None, timeout=60) -> tuple[int, str]:
    """The default override point: one bounded subprocess, stdout+stderr folded, never raising."""
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


def add_user_kind(*, generator_dir: str, cluster: str, username: str, roles,
                  password: str = "", email: str = "", brand: str = "hugmesh",
                  env: Mapping[str, str] | None = None, runner=_run,
                  doors=view_doors.live_doors, identities=None, opener=None,
                  on_line=None) -> AddUserOutcome:
    """Add ``username`` with ``roles`` to the running kind mesh, through its casdoor
    door and ``mesh_accounts.create_account``. An empty ``password`` is generated and
    returned in ``AddUserOutcome.password``.

    Override points: ``runner`` (every subprocess), ``doors`` (the live view doors),
    ``opener`` (every HTTP call) and ``identities`` (the read-back; defaults to the #539
    kind reader). A test supplies them and nothing touches a cluster."""
    def note(line: str):
        if on_line:
            on_line(line)

    ctx = f"kind-{cluster}"
    kubectl = _kubectl(generator_dir)

    # 1. THE DOOR. Asked, never started here.
    url, why = _door_url(generator_dir, env, doors)
    if not url:
        return AddUserOutcome(False, STAGE_DOOR, why)
    note(f"[add-user/kind] applying through the '{DOOR_NAME}' view door")

    # 2. THE CASDOOR ADMIN PASSWORD, from Vault — bootstrap-kind.sh's own read.
    admin_pw, why = casdoor_admin_password(runner, kubectl, ctx, brand=brand)
    if not admin_pw:
        return AddUserOutcome(False, STAGE_ADMIN,
                              f"Cannot authenticate to Casdoor: {why}. A denied admin "
                              f"call is HTTP 200 with a status=error envelope, so "
                              f"nothing is attempted without authenticating first.")

    # 3. APPLY, through the door, verifying it against the view session's own CA.
    ca = os.path.join(view_doors.state_dir(generator_dir, env), CA_REL)
    target = mesh_accounts.Target(url, "", True, "the kind mesh's Casdoor",
                                  cafile=ca if os.path.exists(ca) else "")
    note(f"[add-user/kind] creating {username} through Casdoor's admin API …")
    applied = mesh_accounts.create_account(
        target, generator_dir, username, password, roles, email=email,
        env={"CASDOOR_ADMIN_PASS": admin_pw}, opener=opener, on_line=on_line)
    if not applied.ok:
        return AddUserOutcome(False, STAGE_APPLY, applied.message)
    out = applied.message
    generated = applied.password
    roles = (mesh_accounts.FLOOR_ROLE,) + tuple(
        r for r in (roles or ()) if r and r != mesh_accounts.FLOOR_ROLE)

    # 4. READ THE IDENTITY BACK from the cluster's own database, independently of the
    #    apply's own read-back.
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
            "Casdoor's admin API reported the account created, but the cluster's "
            f"identity store could NOT be read back ({found.reason or 'the cluster did not answer'}), "
            "so this add is unproven. Nothing here will call it a "
            "success on the apply's own word.", password=generated)
    if username not in found.users:
        return AddUserOutcome(
            False, STAGE_READBACK,
            f"'{username}' is NOT in the cluster's identity store, although Casdoor's "
            f"admin API said: {out}", password=generated)

    wanted = tuple(r for r in (roles or ()) if r)
    granted = tuple(r for r in wanted
                    if found.roles is not None
                    and username in dict(found.roles).get(r, frozenset()))
    if found.roles is None:
        return AddUserOutcome(
            True, STAGE_READBACK,
            f"'{username}' exists in the cluster's identity store. Its ROLE "
            f"memberships could not be read ({found.reason or 'no reason given'}), "
            f"so they are unverified — check them before relying on them.",
            password=generated)
    missing = tuple(r for r in wanted if r not in granted)
    if missing:
        return AddUserOutcome(
            False, STAGE_READBACK,
            f"'{username}' was created but the cluster grants it none of: "
            f"{', '.join(missing)}. An account in none of its roles signs in on the "
            f"gateway floor and then 403s on every page, so this is a failed add, "
            f"not a successful one.", granted=granted, missing=missing,
            password=generated)
    return AddUserOutcome(
        True, STAGE_OK,
        f"'{username}' exists in the cluster's identity store and holds "
        f"{', '.join(granted) if granted else 'no roles (none were requested)'} — "
        f"read back from Casdoor's own database, not from the apply's own word.",
        granted=granted, password=generated)
