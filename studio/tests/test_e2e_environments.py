"""The e2e ENVIRONMENT channel — one contract for the GUI and the terminal.

Qt-FREE on purpose: core/e2e_environments.py is what `python -m hugmesh_studio
--e2e-plan` runs, and that has to work on a host with no display and no Qt
binding at all. Importing the GUI here would make this file silently
un-runnable in exactly that environment.

THE PROPERTY THAT MATTERS is not "the module has three ids". It is that the
operator's choice REACHES THE SPAWNED RUN and that nothing else can re-point it:
  * SNAP_ENV always carries the choice (test_snap_env_always_present);
  * a bridge dict cannot override it (test_extra_env_cannot_repoint);
  * the python list and the harness's own TS list agree (test_ids_match_dimensions_ts);
  * no plan ever emits a command that STARTS a mesh (test_no_plan_starts_anything).
"""
import json
import os
import subprocess
import sys

import pytest

from hugmesh_studio.core import e2e_environments as env_mod

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def test_ids_are_the_three_the_operator_asked_for():
    assert env_mod.environment_ids() == ("docker", "kind", "qemu")
    assert env_mod.DEFAULT_ENVIRONMENT == "docker"


def test_ids_match_dimensions_ts():
    """THE DRIFT GUARD. This module necessarily restates ids that also live in
    tests/e2e/steps/dimensions.ts. A copy is a list that can diverge silently —
    this repo already carries one unreconciled pair of persona catalogues — so
    the TS file is PARSED and the two are compared. Adding an environment on one
    side only fails here instead of going unnoticed."""
    ts = env_mod.legal_ids_from_dimensions_ts(env_mod.dimensions_ts_path(REPO))
    assert tuple(sorted(ts)) == tuple(sorted(env_mod.environment_ids())), (
        "the Studio's environment list %s and the harness's %s disagree. Both "
        "must change together, or a GUI run drives a mesh the harness will not "
        "resolve." % (env_mod.environment_ids(), ts))


def test_dimensions_reader_refuses_to_pass_vacuously(tmp_path):
    """An unreadable / renamed array must RAISE, never return (). An empty tuple
    would make the cross-check above pass while checking nothing."""
    p = tmp_path / "dimensions.ts"
    p.write_text("export const SOMETHING_ELSE = ['a'];\n", encoding="utf-8")
    with pytest.raises(ValueError) as exc:
        env_mod.legal_ids_from_dimensions_ts(str(p))
    assert "ENVIRONMENTS" in str(exc.value)


def test_dimensions_reader_ignores_a_commented_out_array(tmp_path):
    """Comment-stripped BEFORE the search. This repo has been bitten five times
    by a grep/count assertion that matched a commented-out token; a `//` example
    of the array inside a doc comment must not win."""
    p = tmp_path / "dimensions.ts"
    p.write_text(
        "// export const ENVIRONMENTS = ['bogus'] as const;\n"
        "/* export const ENVIRONMENTS = ['alsobogus'] as const; */\n"
        "export const ENVIRONMENTS = ['docker', 'kind', 'qemu'] as const;\n",
        encoding="utf-8")
    assert env_mod.legal_ids_from_dimensions_ts(str(p)) == ("docker", "kind", "qemu")


@pytest.mark.parametrize("env_id", ["docker", "kind", "qemu"])
def test_snap_env_always_present(env_id):
    """The whole contract with tests/e2e/steps/world.ts in one key."""
    plan = env_mod.plan(env_id, ambient={})
    assert plan.env[env_mod.ENV_VAR] == env_id
    assert plan.to_dict()["channel"] == "SNAP_ENV"


def test_kind_carries_the_host_resolver_rules():
    """SNAP_ENV alone would send every kind browser scenario into a DNS failure
    that reads like 'kind is broken' instead of 'a variable is missing'."""
    e = env_mod.plan("kind", ambient={}).env
    assert e["SNAP_BASE_URL"] == "https://hugmesh.net:8443"
    assert "MAP hugmesh.net 127.0.0.1" in e["SNAP_HOST_RESOLVER"]


def test_qemu_base_url_follows_the_forwarded_ui_port():
    """run-qemu-e2e.sh's UI_PORT is the forwarded HOST port; a run with
    --ui-port 9443 must resolve there, not at whatever else holds 8443."""
    assert env_mod.plan("qemu", ambient={}).env["SNAP_BASE_URL"] \
        == "https://localhost:8443"
    assert env_mod.plan("qemu", ambient={"UI_PORT": "9443"}).env["SNAP_BASE_URL"] \
        == "https://localhost:9443"
    assert env_mod.plan("qemu", ambient={"SNAP_QEMU_UI_PORT": "7443"}).env["SNAP_BASE_URL"] \
        == "https://localhost:7443"


def test_ambient_value_wins_over_the_default():
    """An operator who exported SNAP_BASE_URL meant it. Silently overriding them
    is how a run drives a mesh nobody asked for."""
    e = env_mod.plan("docker", ambient={"SNAP_BASE_URL": "https://localhost:9999"}).env
    assert e["SNAP_BASE_URL"] == "https://localhost:9999"


def test_extra_env_cannot_repoint():
    """The chooser is the ONLY thing that selects an environment. A bridge dict
    (the superadmin identity, the report dir) that could re-point the run would
    make the GUI's label a lie with no symptom."""
    with pytest.raises(ValueError) as exc:
        env_mod.run_env("kind", {"SNAP_ENV": "docker"})
    assert "SNAP_ENV" in str(exc.value)
    # The same key with the SAME value is fine — that is not a re-pointing.
    assert env_mod.run_env("kind", {"SNAP_ENV": "kind"}, ambient={})["SNAP_ENV"] == "kind"


def test_extra_env_is_otherwise_merged():
    e = env_mod.run_env("docker", {"SNAP_REPORT_DIR": "test-results/x"}, ambient={})
    assert e["SNAP_REPORT_DIR"] == "test-results/x"
    assert e["SNAP_ENV"] == "docker"


def test_unknown_environment_names_the_legal_set_and_the_near_twins():
    with pytest.raises(ValueError) as exc:
        env_mod.environment("compose")
    msg = str(exc.value)
    for legal in env_mod.environment_ids():
        assert legal in msg
    assert "near-twin" in msg
    assert "dimensions.ts" in msg, "the message must say where the OTHER list is"


@pytest.mark.parametrize("env_id", ["docker", "kind", "qemu"])
def test_no_plan_starts_anything(env_id):
    """NEITHER FRONT-END MAY BRING A MESH UP. The harness holds its own runners
    to this ('a step naming `make stack-up` is a bug'), and the operator's
    standing rule here is that no agent starts the docker stack, the kind
    cluster or a QEMU device. Asserted over the module's own list, so extending
    BOOT_COMMANDS extends the check."""
    line = " ".join(env_mod.plan(env_id, ambient={}).argv)
    assert env_mod.BOOT_COMMANDS, "BOOT_COMMANDS is empty — this check is vacuous"
    for forbidden in env_mod.BOOT_COMMANDS:
        assert forbidden not in line, "%s plan would run %r" % (env_id, line)


@pytest.mark.parametrize("env_id", ["docker", "kind", "qemu"])
def test_one_target_for_every_environment(env_id):
    """Deliberately the SAME target for all three. A per-environment recipe would
    have to re-spell that environment's pins in a Makefile, and a recipe-level
    `SNAP_BASE_URL=...` OVERRIDES the caller's — which is precisely how a run
    launched 'against kind' would have driven docker."""
    assert env_mod.plan(env_id, ambient={}).argv == ("make", env_mod.RUN_TARGET)


def test_the_run_target_exists_in_the_makefile():
    """A plan pointing at a target `make` does not have is a plan that fails at
    the shell with 'No rule to make target'."""
    with open(os.path.join(REPO, "Makefile"), encoding="utf-8") as fh:
        body = fh.read()
    assert ("\n%s:" % env_mod.RUN_TARGET) in body, \
        "Makefile has no `%s` target" % env_mod.RUN_TARGET


def test_boot_is_refused_for_every_environment():
    """Bringing a mesh up is the operator's act. For qemu the refusal is
    expensive to get wrong: its launcher needs root, and on this box an
    unanswerable password prompt does not fail — it hangs as a root process only
    a human can clear."""
    for env_id in env_mod.environment_ids():
        p = env_mod.plan(env_id, boot=True, ambient={})
        assert not p.runnable
        assert p.refusals, "%s refused with no reason" % env_id
        assert p.start_hint and p.start_hint in " ".join(p.refusals), \
            "the refusal for %s must name what to run instead" % env_id
    qemu = env_mod.plan("qemu", boot=True, ambient={})
    assert "requires root" in " ".join(qemu.refusals)
    assert "HANGS" in " ".join(qemu.refusals)


def test_every_environment_has_a_start_hint_and_a_note():
    """Rendered in the chooser tooltip and in every skip reason. A blank one
    sends the reader to the source instead of fixing it in two seconds."""
    for row in env_mod.describe():
        assert row["startHint"].strip(), row["id"]
        assert row["note"].strip(), row["id"]
        assert row["source"].strip(), row["id"]


def test_emulator_probe_is_name_anchored():
    """MEASURED TRAP: `pgrep -f qemu-system-` MATCHES ITS OWN INVOKING SHELL — it
    returned a hit in this tree with no emulator running. The probe must use a
    NAME anchor. Asserted on the argv the probe actually passes, because that is
    the thing that would silently regress."""
    seen = {}

    class R:
        returncode = 1
        stdout = ""

    def fake_run(argv, **kw):
        seen["argv"] = argv
        return R()

    env_mod.emulator_running(runner=fake_run)
    assert seen["argv"][0] == "pgrep"
    assert "-f" not in seen["argv"], \
        "pgrep -f self-matches the invoking shell and reports a phantom emulator"
    assert seen["argv"][1].startswith("^"), \
        "the pattern must be name-anchored, or an unrelated command line matches"


def test_emulator_probe_tri_state():
    """rc 0 with output = running; rc 1 = not running; anything else = UNKNOWN,
    reported as None rather than guessed at."""
    def mk(rc, out=""):
        class R:
            returncode = rc
            stdout = out
        return lambda argv, **kw: R()

    assert env_mod.emulator_running(runner=mk(0, "1234\n")) is True
    assert env_mod.emulator_running(runner=mk(1)) is False
    assert env_mod.emulator_running(runner=mk(2)) is None

    def boom(argv, **kw):
        raise OSError("pgrep is not installed")
    assert env_mod.emulator_running(runner=boom) is None


# ── the CLI channel, end to end ──────────────────────────────────────────────

def _studio_cli(*args):
    return subprocess.run(
        [sys.executable, "-m", "hugmesh_studio", *args],
        cwd=os.path.join(REPO, "studio"),
        capture_output=True, text=True, timeout=120)


def test_cli_plan_is_json_and_carries_the_channel():
    r = _studio_cli("--e2e-plan", "--e2e-env", "kind", "--json")
    assert r.returncode == 0, r.stderr
    doc = json.loads(r.stdout.strip().splitlines()[-1])
    assert doc["env"]["SNAP_ENV"] == "kind"
    assert doc["argv"] == ["make", env_mod.RUN_TARGET]
    assert doc["channel"] == "SNAP_ENV"


def test_cli_plan_rejects_an_unknown_environment():
    r = _studio_cli("--e2e-plan", "--e2e-env", "k8s", "--json")
    assert r.returncode == 2
    assert "docker, kind, qemu" in r.stderr


def test_cli_and_module_agree():
    """ONE CONTRACT. If the CLI could print something the module would not
    produce, the terminal and the GUI would be describing different runs."""
    for env_id in env_mod.environment_ids():
        r = _studio_cli("--e2e-plan", "--e2e-env", env_id, "--json")
        assert r.returncode == 0, r.stderr
        doc = json.loads(r.stdout.strip().splitlines()[-1])
        assert doc["environment"] == env_mod.plan(env_id).environment
        assert doc["argv"] == list(env_mod.plan(env_id).argv)
        assert doc["env"] == env_mod.plan(env_id).env


# ── the SPAWN boundary: the choice must reach the child process ──────────────
#
# Everything above proves the PLAN is right. These two prove the plan is what
# actually gets spawned — the step the brief singles out ("prove the selected
# environment reaches the spawned runner's argv with a stub"). A correct plan
# that the runner then ignores is the exact bug with no symptom: the GUI label
# says kind and the suite drives docker.

def test_run_e2e_hands_the_environment_to_make():
    """Stub the make layer and read back what run_e2e would have spawned."""
    from hugmesh_studio.core.local_stack_node import LocalStackNode
    node = LocalStackNode(REPO)
    node.e2e_ready = lambda environment="docker": []
    seen = {}

    def fake_make(target, timeout, extra_env=None, on_line=None, cancel=None,
                  args=None):
        seen["target"] = target
        seen["env"] = dict(extra_env or {})
        return True, "stubbed"

    node._make = fake_make
    ok, msg = node.run_e2e(environment="kind")
    assert ok, msg
    assert seen["target"] == env_mod.RUN_TARGET
    assert seen["env"]["SNAP_ENV"] == "kind"
    assert seen["env"]["SNAP_BASE_URL"] == "https://hugmesh.net:8443"
    assert "MAP hugmesh.net" in seen["env"]["SNAP_HOST_RESOLVER"]
    # ...and the report dir the summary is read back from is still threaded in.
    assert seen["env"]["SNAP_REPORT_DIR"].startswith("test-results")


def test_run_e2e_reports_which_environment_it_ran():
    """The counts line names the mesh. Without it a log full of results says
    nothing about which of three meshes produced them."""
    from hugmesh_studio.core.local_stack_node import LocalStackNode
    node = LocalStackNode(REPO)
    node.e2e_ready = lambda environment="docker": []
    node._make = lambda *a, **k: (True, "stubbed")
    lines = []
    ok, msg = node.run_e2e(environment="qemu", on_line=lines.append)
    assert any("[e2e/qemu]" in ln for ln in lines), lines


def test_the_make_child_really_receives_snap_env(monkeypatch):
    """One layer deeper: the actual subprocess environment. `make` imports the
    environment into its own variable namespace, which is what makes
    `SNAP_ENV=kind make stack-e2e-bdd-env` work from a terminal — so the child's
    env is the real contract surface, not an argv flag."""
    import subprocess as sp
    from hugmesh_studio.core import local_stack_node as lsn
    node = lsn.LocalStackNode(REPO)
    node.e2e_ready = lambda environment="docker": []
    captured = {}

    class R:
        returncode = 0
        stdout = "ok"
        stderr = ""

    def fake_run(argv, **kw):
        captured["argv"] = list(argv)
        captured["env"] = dict(kw.get("env") or {})
        return R()

    monkeypatch.setattr(lsn.subprocess, "run", fake_run)
    ok, _msg = node.run_e2e(environment="kind")
    assert ok
    assert captured["argv"] == ["make", env_mod.RUN_TARGET]
    assert captured["env"]["SNAP_ENV"] == "kind", (
        "the chosen environment never reached the child process; the run would "
        "have driven docker while every label said kind")


def test_run_e2e_rejects_an_unknown_environment():
    from hugmesh_studio.core.local_stack_node import LocalStackNode
    node = LocalStackNode(REPO)
    node._make = lambda *a, **k: (True, "stubbed")
    ok, msg = node.run_e2e(environment="compose")
    assert not ok
    assert "docker, kind, qemu" in msg
