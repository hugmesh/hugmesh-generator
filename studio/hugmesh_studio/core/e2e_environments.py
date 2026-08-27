"""e2e_environments.py — WHICH MESH an e2e run drives, spelled ONCE for every front-end.

THE ASK. The operator wants e2e evidence "in docker, local devops, and qemu
emulated e2e testing through cli and gui". Three environments; two front-ends
(the terminal and the Studio). The failure mode that makes this hard is not
building either front-end — it is building them TWICE, so the Studio's idea of
"kind" drifts from the harness's and a GUI run silently drives the wrong mesh
while the log says otherwise.

SO THERE IS ONE CHANNEL AND IT IS AN ENVIRONMENT VARIABLE.

    SNAP_ENV=docker|kind|qemu

tests/e2e/steps/world.ts already reads exactly that (`const envUnderTest =
process.env.SNAP_ENV`) and skips any scenario pinned to a different environment.
The Studio does not invent a second mechanism, does not pass a --environment flag
into a script that has no such flag, and does not edit a config file the harness
would have to learn to read. It sets SNAP_ENV on the child process, which is the
same thing an operator typing `SNAP_ENV=kind make stack-e2e-bdd-env` does. One
contract, two callers.

WHY THE PYTHON LIST IS A LIABILITY, AND WHAT GUARDS IT. This module necessarily
restates three ids that are ALSO declared in tests/e2e/steps/dimensions.ts
(`export const ENVIRONMENTS`). That is a fourth-divergent-list risk of exactly the
kind this repo has been bitten by (the TS persona catalogue vs the shell roster,
still unreconciled). It is handled the way shellRoster() handles the roster: the
TS file is PARSED, not copied — `legal_ids_from_dimensions_ts()` reads the array
out of the real file, and test_e2e_environments.py asserts the two agree. Adding
an environment on one side and not the other goes RED instead of going unnoticed.

WHAT THIS MODULE IS NOT. It never RUNS anything. It builds argv and an env dict
and reports refusals; the caller runs them. It is Qt-free and stdlib-only, so the
CLI channel (`python -m hugmesh_studio --e2e-plan`) works on a host with no
display and no Qt binding at all.

*** IT STARTS NO ENVIRONMENT. *** Every plan here drives a mesh that is ALREADY
up. `make stack-up`, `make kind-up` and the QEMU launchers are named in
`start_hint` as text for a human to read — they are never argv this module emits.
"""
from __future__ import annotations

import os
import re
from dataclasses import dataclass

# ── the channel ──────────────────────────────────────────────────────────────

#: The ONE variable that carries the operator's environment choice into a run.
#: Mirrors SNAP_PLATFORM, which world.ts's platform gate already reads the same way.
ENV_VAR = "SNAP_ENV"

#: The base-URL variable the Playwright config has always read. `docker` stays
#: bound to it so an un-pinned run behaves exactly as it did before this module.
BASE_URL_VAR = "SNAP_BASE_URL"

#: chromium host-resolver rules. REQUIRED for kind + browser: hugmesh.net does not
#: resolve on a developer box, which is why `make kind-e2e` passes this rather
#: than editing /etc/hosts.
HOST_RESOLVER_VAR = "SNAP_HOST_RESOLVER"

#: Where the run's per-step evidence and manifest land (tests/e2e-relative).
REPORT_DIR_VAR = "SNAP_REPORT_DIR"


@dataclass(frozen=True)
class E2EEnvironment:
    """One mesh an e2e run can be pointed at.

    Every field here answers a question the GUI has to render honestly:
    `label` for the combo box, `note` for the tooltip, `start_hint` for the
    "it is not up" message, `boot_needs_root` for whether the Studio may ever
    offer to bring it up (it may not, when the answer is yes).
    """

    id: str
    label: str
    #: Extra environment the harness needs to reach this mesh, on top of SNAP_ENV.
    #: Values are resolved at call time by `default_pin()`, never frozen here.
    pins: tuple[str, ...] = ()
    #: What STARTS this mesh. Text for a human. NEVER argv this module emits.
    start_hint: str = ""
    #: True when bringing this mesh up requires uid 0. The Studio refuses to
    #: spawn those: on this box there is no sudo password and no askpass that
    #: can ever answer, so such a child does not fail — it HANGS as a root
    #: process only the operator can clear.
    boot_needs_root: bool = False
    note: str = ""
    #: Free-form provenance: where in this repo each fact above was read from.
    source: str = ""


#: The ONE target that runs the Gherkin suite against whichever mesh SNAP_ENV
#: names. Deliberately the SAME for all three environments: a per-environment
#: target would have to re-spell that environment's pins inside a Makefile
#: recipe, and a recipe-level `SNAP_BASE_URL=...` OVERRIDES the caller's — which
#: is exactly how a run launched "against kind" would have driven docker while
#: the label said kind. The pins live in `run_env()` and nowhere else.
RUN_TARGET = "stack-e2e-bdd-env"


#: The three meshes, in the order a chooser should list them. `docker` is first
#: and is the default because it is what an unset SNAP_ENV has always meant.
E2E_ENVIRONMENTS: tuple[E2EEnvironment, ...] = (
    E2EEnvironment(
        id="docker",
        label="Docker compose mesh (tests/stack)",
        pins=(BASE_URL_VAR,),
        start_hint="make stack-up ENV=test   (then: make stack-seed)",
        boot_needs_root=False,
        note="The default. The same TLS front door `Open web UI` opens, and the "
             "door playwright.config.ts already points at. An unset SNAP_ENV has "
             "always meant this mesh, so choosing it changes nothing.",
        source="Makefile: stack-e2e / stack-e2e-bdd set "
               "SNAP_BASE_URL='https://localhost:$(PUBLIC_HTTPS_PORT)'.",
    ),
    E2EEnvironment(
        id="kind",
        label="Local DevOps cluster (kind-hugmesh-local)",
        pins=(BASE_URL_VAR, HOST_RESOLVER_VAR),
        start_hint="make kind-images && make kind-up   "
                   "(bootstrap-kind.sh, KIND_PROFILE=sso)",
        boot_needs_root=False,
        note="The Kubernetes lane. Its ingress matches on Host, and hugmesh.net "
             "does not resolve on a developer box - so the run also needs "
             "chromium host-resolver rules, which is why this environment pins "
             "two variables rather than one. NOTE the kind NODE container binds "
             "host :8443 as soon as the cluster exists, long before any app "
             "serves it, so a bare port probe cannot tell you it is ready.",
        source="Makefile: kind-e2e sets SNAP_BASE_URL='https://hugmesh.net:8443' and "
               "SNAP_HOST_RESOLVER='MAP hugmesh.net 127.0.0.1, MAP *.hugmesh.net 127.0.0.1'.",
    ),
    E2EEnvironment(
        id="qemu",
        label="QEMU-emulated device (forwarded UI port)",
        pins=(BASE_URL_VAR,),
        start_hint="bash tests/qemu/run-qemu-e2e.sh --target x86 --img <image>   "
                   "(or --target pi); the forwarded UI port is --ui-port, default 8443",
        # BOOTING a device is the root-requiring half: run-qemu-e2e.sh exits
        # unless `id -u` is 0 and the Makefile's `e2e` target is prefixed with
        # $(SUDO). RUNNING the suite against a device somebody already booted is
        # an ordinary unprivileged browser session against a forwarded host
        # port, which is why the two are separate fields.
        boot_needs_root=True,
        note="The emulated device, reached over the launcher's FORWARDED HOST "
             "PORT - never the guest address. Running the suite against a device "
             "that is already up needs no privilege; BOOTING one needs root, and "
             "the Studio will not do that.",
        source="tests/qemu/run-qemu-e2e.sh: UI_PORT=\"${UI_PORT:-8443}\", "
               "SNAP_BASE_URL=\"https://localhost:${UI_PORT}\"; Makefile `e2e` "
               "prefixes $(SUDO) and the script exits unless `id -u` is 0.",
    ),
)

_BY_ID = {e.id: e for e in E2E_ENVIRONMENTS}

#: What an operator who has chosen nothing gets. Identical to an unset SNAP_ENV.
DEFAULT_ENVIRONMENT = "docker"


def environment_ids() -> tuple[str, ...]:
    """The legal ids, in chooser order."""
    return tuple(e.id for e in E2E_ENVIRONMENTS)


def environment(env_id: str) -> E2EEnvironment:
    """Resolve an id, or raise NAMING every legal value.

    A bare "invalid environment" sends the reader to the source; naming the set
    fixes the typo in two seconds. The message deliberately also names the
    near-twins this vocabulary refuses, because 'compose'/'k8s'/'vm' are what a
    second author reaches for and a near-twin fragments the vocabulary worse
    than a hard error does.
    """
    try:
        return _BY_ID[env_id]
    except KeyError:
        raise ValueError(
            "unknown e2e environment %r. Legal ids (core/e2e_environments.py "
            "E2E_ENVIRONMENTS): %s. Add it to E2E_ENVIRONMENTS *and* to "
            "ENVIRONMENTS in tests/e2e/steps/dimensions.ts in the same change — "
            "the two lists are cross-checked. Do NOT spell a near-twin "
            "('compose', 'k8s', 'vm'): the harness rejects those and a second "
            "spelling for one mesh is worse than a hard error."
            % (env_id, ", ".join(environment_ids()))
        ) from None


# ── the drift guard's reader ─────────────────────────────────────────────────

#: `export const ENVIRONMENTS = ['docker', 'kind', 'qemu'] as const;`
_TS_ENVIRONMENTS_RE = re.compile(
    r"export\s+const\s+ENVIRONMENTS\s*=\s*\[(?P<body>[^\]]*)\]", re.S)


def dimensions_ts_path(generator_dir: str) -> str:
    return os.path.join(generator_dir, "tests", "e2e", "steps", "dimensions.ts")


def legal_ids_from_dimensions_ts(path: str) -> tuple[str, ...]:
    """Read the harness's OWN environment list out of dimensions.ts.

    Parsed rather than copied, for the same reason dimensions.shellRoster()
    parses tests/e2e-extra-personas.sh rather than restating it: a copy is a
    third list that can drift silently, and this repo already carries one
    unreconciled pair of persona catalogues.

    Raises rather than returning () on a file it cannot read or an array it
    cannot find — an empty tuple would make the cross-check pass vacuously,
    which is precisely the failure the check exists to prevent.
    """
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    # Comment-strip first: this repo has been bitten five times by grep/count
    # assertions that matched a commented-out token. A `//` example of the array
    # inside a doc comment would otherwise win the search.
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"(?m)^\s*//.*$", "", text)
    m = _TS_ENVIRONMENTS_RE.search(text)
    if not m:
        raise ValueError(
            "no `export const ENVIRONMENTS = [...]` in %s. Either the harness "
            "renamed its environment list — in which case this reader must be "
            "updated in the same change — or the path is wrong. Refusing to "
            "return an empty list, which would let the cross-check pass while "
            "checking nothing." % path)
    ids = re.findall(r"['\"]([A-Za-z0-9_-]+)['\"]", m.group("body"))
    if not ids:
        raise ValueError("`ENVIRONMENTS` in %s parsed to zero ids" % path)
    return tuple(ids)


# ── the plan: what a run would actually do ───────────────────────────────────

@dataclass(frozen=True)
class E2EPlan:
    """Everything a caller needs to launch (or refuse) one e2e run.

    This object IS the contract between the GUI, the CLI verb and the guards.
    A test asserts on `env[ENV_VAR]` and `argv`; the GUI renders `refusals`;
    the CLI verb serialises the whole thing as JSON.
    """

    environment: str
    argv: tuple[str, ...]
    env: dict[str, str]
    #: Non-empty => this run must NOT be spawned. Each entry says why, in a
    #: sentence an operator can act on.
    refusals: tuple[str, ...] = ()
    start_hint: str = ""
    note: str = ""
    make_target: str = ""

    @property
    def runnable(self) -> bool:
        return not self.refusals

    def to_dict(self) -> dict:
        return {
            "environment": self.environment,
            "argv": list(self.argv),
            "env": dict(self.env),
            "refusals": list(self.refusals),
            "runnable": self.runnable,
            "startHint": self.start_hint,
            "note": self.note,
            "makeTarget": self.make_target,
            "channel": ENV_VAR,
        }


def default_pin(var: str, env_id: str, ambient: "dict[str, str] | None" = None) -> str:
    """The value a pinned variable takes when the ambient environment has none.

    Read off the repo, not invented - every literal here is quoted in the
    matching E2EEnvironment.source. An ambient value always WINS: an operator
    who exported SNAP_BASE_URL meant it, and silently overriding them is how a
    run drives a mesh nobody asked for.
    """
    amb = dict(ambient if ambient is not None else os.environ)
    if amb.get(var):
        return amb[var]
    if var == BASE_URL_VAR:
        if env_id == "kind":
            return "https://hugmesh.net:8443"
        if env_id == "qemu":
            port = amb.get("SNAP_QEMU_UI_PORT") or amb.get("UI_PORT") or "8443"
            return "https://localhost:%s" % port
        return "https://localhost:8443"
    if var == HOST_RESOLVER_VAR:
        return "MAP hugmesh.net 127.0.0.1, MAP *.hugmesh.net 127.0.0.1"
    return ""


def run_env(env_id: str, extra: "dict[str, str] | None" = None,
            ambient: "dict[str, str] | None" = None) -> "dict[str, str]":
    """The environment overrides a run in `env_id` needs.

    ALWAYS carries SNAP_ENV. That single key is the whole contract with the
    harness (tests/e2e/steps/world.ts reads `process.env.SNAP_ENV` and skips any
    scenario pinned elsewhere), and the mutation battery's M1 deletes it
    precisely to prove that a plan without it is CAUGHT rather than quietly
    running against docker while the GUI label says kind.

    `extra` (the superadmin identity bridge, SNAP_REPORT_DIR, ...) is merged LAST
    but may not overwrite SNAP_ENV: the chooser is the only thing that selects an
    environment, and letting an unrelated bridge dict silently re-point the run
    is a bug with no symptom.
    """
    env = environment(env_id)
    out: "dict[str, str]" = {ENV_VAR: env.id}
    for var in env.pins:
        value = default_pin(var, env.id, ambient)
        if value:
            out[var] = value
    for key, value in (extra or {}).items():
        if key == ENV_VAR and value != env.id:
            raise ValueError(
                "refusing to let extra env %s=%r override the chosen environment "
                "%r. The chooser is the only thing that selects an environment; a "
                "bridge dict that could re-point the run would make the GUI's "
                "label a lie." % (ENV_VAR, value, env.id))
        out[key] = value
    return out


#: Commands that BRING A MESH UP. This module must never emit one of these as
#: argv - `test_e2e_environments.py` asserts it over every plan. The harness has
#: the same rule on its own runners ("a step naming `make stack-up` is a bug"),
#: and the operator's standing instruction here is that no agent starts the
#: docker stack, the kind cluster or a QEMU device.
BOOT_COMMANDS = (
    "stack-up", "stack-seed", "stack-bootstrap",
    "kind-up", "kind-images", "bootstrap-kind.sh",
    "run-qemu-e2e.sh", "launch-x86.sh", "launch-pi.sh",
    "build-rpi5-stage4.sh", "build-x86-host-stage4.sh",
    "sudo",
)


def run_argv(env_id: str, extra_args: "tuple[str, ...] | list[str]" = ()) -> "tuple[str, ...]":
    """The argv that runs the Gherkin suite against `env_id`.

    ONE target for all three environments (RUN_TARGET). A make target rather
    than a raw npx line, because the target already carries this repo's
    node_modules check and the bddgen prerequisite; re-spelling those here would
    create a second way to run the suite that drifts from `make`.

    It never varies by environment, and that is the design: the environment
    rides in `run_env()`. A recipe that pinned SNAP_BASE_URL itself would
    override the caller's value, which is the precise mechanism by which a run
    launched "against kind" would have driven docker.
    """
    environment(env_id)          # validate, so a typo dies here not in a shell
    return ("make", RUN_TARGET, *tuple(extra_args))


def plan(env_id: str, extra_env: "dict[str, str] | None" = None,
         extra_args: "tuple[str, ...] | list[str]" = (),
         ambient: "dict[str, str] | None" = None,
         boot: bool = False) -> E2EPlan:
    """Build the full plan for one run, refusals included.

    `boot=True` asks this module to also BRING THE MESH UP, and is refused for
    any environment whose bring-up needs root. That refusal is the point: on
    this box there is no sudo password and no askpass that can ever answer, so a
    Studio button that shelled out to `make e2e` would not fail - it would hang
    forever as a root process only a human can clear. It has happened twice in
    this tree. The plan comes back `runnable=False` with the exact command to
    type by hand, and the GUI renders that as an INLINE sentence (never a modal:
    a QMessageBox from page logic wedges every headless test).

    Nothing else is refused statically. Whether the mesh is actually SERVING is
    a live question the harness itself answers, loudly, per scenario - see
    world.ts's environment gate, which skips with a reason naming what to start.
    Duplicating that judgement here would give an operator two answers.
    """
    env_def = environment(env_id)
    refusals: "list[str]" = []
    if boot:
        if env_def.boot_needs_root:
            refusals.append(
                "bringing up the %s environment requires root (%s). The Studio "
                "will NOT spawn it: an unanswerable password prompt does not "
                "fail, it HANGS as a root process only the operator can clear. "
                "Run it yourself: %s"
                % (env_def.id, env_def.source.split(";")[-1].strip(), env_def.start_hint))
        else:
            refusals.append(
                "this module never brings an environment up - it only runs the "
                "suite against one that is already serving. Start %s with: %s"
                % (env_def.id, env_def.start_hint))
    return E2EPlan(
        environment=env_def.id,
        argv=run_argv(env_id, extra_args),
        env=run_env(env_id, extra_env, ambient),
        refusals=tuple(refusals),
        start_hint=env_def.start_hint,
        note=env_def.note,
        make_target=RUN_TARGET,
    )


def emulator_running(runner=None) -> "bool | None":
    """Is a QEMU device actually emulating on this host? None = could not tell.

    NAME-ANCHORED on purpose. `pgrep -f qemu-system-` MATCHES ITS OWN INVOKING
    SHELL - measured in this tree: it returned a hit with no emulator running at
    all, because the pattern appears in the command line doing the search. So
    this uses `pgrep '^qemu-system-'`, which matches process NAMES. The mutation
    battery swaps it back to -f and requires the false positive to be caught.

    Read-only: it starts nothing and signals nothing.
    """
    import subprocess
    run = runner or subprocess.run
    try:
        r = run(["pgrep", "^qemu-system-"], capture_output=True, text=True, timeout=10)
    except (OSError, ValueError, subprocess.SubprocessError):
        return None
    if r.returncode == 0:
        return bool((r.stdout or "").strip())
    if r.returncode == 1:
        return False
    return None


def describe() -> "list[dict]":
    """The chooser's model: one row per environment, everything a label needs."""
    return [
        {
            "id": e.id,
            "label": e.label,
            "makeTarget": RUN_TARGET,
            "pins": list(e.pins),
            "bootNeedsRoot": e.boot_needs_root,
            "startHint": e.start_hint,
            "note": e.note,
            "source": e.source,
        }
        for e in E2E_ENVIRONMENTS
    ]
