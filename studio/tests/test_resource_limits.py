"""CPU/GPU/memory limits for every lane that builds or RUNS a mesh — no Qt, no docker.

The 2026-07-15 host-freeze guard capped MEMORY on single-image builds and nothing
else: CPU was unbounded everywhere, and the fleet lane — which is the lane the
incident actually was — had no cap at all. These tests pin the extension of that
guard across the build, fleet, compose and QEMU lanes, and the property that makes it
safe to add: with every limit OFF the argv is byte-identical to the pre-limit
command.
"""
import json
import os

import pytest

from hugmesh_studio.core import host_resources as hr
from hugmesh_studio.core import resource_limits as rl
from hugmesh_studio.core import stack_limits as sl

GIB = hr.GIB

INCIDENT_MEMINFO = {"MemTotal": 31 * GIB, "MemAvailable": 20 * GIB, "SwapTotal": 4 * GIB,
                    "SwapFree": 4 * GIB}


# ── The auto formula ─────────────────────────────────────────────────────────────

def test_auto_cpus_reserves_a_core_for_the_desktop():
    # The thing that makes a machine feel broken under load is having no core left
    # for the compositor — an absolute shortfall, not a proportional one.
    assert rl.default_cpus(nproc=8) == 7.0
    assert rl.default_cpus(nproc=16) == 15.0


def test_auto_cpus_never_returns_less_than_one():
    # A "limit" of 0 cores is a hang, not a limit.
    assert rl.default_cpus(nproc=1) == 1.0
    assert rl.default_cpus(nproc=0) >= 1.0


def test_auto_limits_take_memory_from_the_existing_guard():
    limits = rl.auto_limits(nproc=8, meminfo=INCIDENT_MEMINFO)
    assert limits.memory == hr.build_memory_flag(env={}, meminfo=INCIDENT_MEMINFO)


def test_auto_limits_leave_memory_alone_where_meminfo_is_unreadable():
    # Windows and macOS have no /proc/meminfo. The memory guard's contract is to
    # cap nothing rather than guess; CPU is still capped, because os.cpu_count()
    # works everywhere.
    limits = rl.auto_limits(nproc=8, meminfo={})
    assert limits.memory is None
    assert limits.cpus == 7.0


def test_auto_limits_do_not_take_the_gpu():
    # A mesh running in the background on somebody's desktop must not silently take
    # the GPU away from what they are actually doing.
    assert rl.auto_limits(nproc=8, meminfo=INCIDENT_MEMINFO).gpus is None


# ── The three-way knob contract ──────────────────────────────────────────────────

@pytest.mark.parametrize("off", ["0", "off", "none", "OFF", "None"])
def test_cpu_knob_off_disables_the_cap(off):
    limits = rl.from_env(env={rl.CPUS_ENV: off}, nproc=8, meminfo={})
    assert limits.cpus is None


def test_cpu_knob_passes_a_value_through_verbatim():
    assert rl.from_env(env={rl.CPUS_ENV: "1.5"}, nproc=8, meminfo={}).cpus == 1.5


def test_cpu_knob_unset_falls_back_to_the_auto_formula():
    assert rl.from_env(env={}, nproc=8, meminfo={}).cpus == 7.0


def test_a_malformed_cpu_knob_yields_no_cap_and_says_so():
    # Silently substituting a default would use a number the operator never asked
    # for, and nobody finds out until a host freezes anyway.
    env = {rl.CPUS_ENV: "lots"}
    assert rl.from_env(env=env, nproc=8, meminfo={}).cpus is None
    assert any("not a positive number" in w for w in rl.limit_warnings(env))


def test_a_valid_cpu_knob_produces_no_warning():
    assert rl.limit_warnings({rl.CPUS_ENV: "4"}) == []


def test_fields_resolve_independently():
    # An operator must be able to pin CPU and leave memory automatic.
    limits = rl.from_env(env={rl.CPUS_ENV: "2"}, nproc=8, meminfo=INCIDENT_MEMINFO)
    assert limits.cpus == 2.0
    assert limits.memory is not None


def test_gpu_defaults_to_off_and_is_opt_in():
    assert rl.from_env(env={}, nproc=4, meminfo={}).gpus is None
    assert rl.from_env(env={rl.GPUS_ENV: "all"}, nproc=4, meminfo={}).gpus == "all"


# ── docker run rendering ─────────────────────────────────────────────────────────

def test_unlimited_renders_no_flags_at_all():
    # THE property that makes this safe to add: with limits off the surrounding argv
    # is byte-identical to the command that existed before this feature.
    assert rl.docker_run_args(rl.ResourceLimits()) == []


def test_docker_args_pin_swap_equal_to_memory():
    # memory-swap == memory means ZERO container swap, so a runaway compile OOMs
    # promptly instead of thrashing the host's swap — the 2026-07-15 signature.
    args = rl.docker_run_args(rl.ResourceLimits(memory="8g"))
    assert args == ["--memory", "8g", "--memory-swap", "8g"]


def test_docker_args_render_a_whole_number_of_cpus_without_a_decimal_point():
    assert rl.docker_run_args(rl.ResourceLimits(cpus=6.0))[:2] == ["--cpus", "6"]
    assert rl.docker_run_args(rl.ResourceLimits(cpus=1.5))[:2] == ["--cpus", "1.5"]


def test_docker_args_include_gpus_only_when_asked():
    assert "--gpus" not in rl.docker_run_args(rl.ResourceLimits(cpus=2.0))
    assert rl.docker_run_args(rl.ResourceLimits(gpus="device=0")) == ["--gpus", "device=0"]


# ── compose rendering ────────────────────────────────────────────────────────────

def test_compose_block_is_empty_when_unlimited():
    assert rl.compose_resource_block(rl.ResourceLimits()) == {}


def test_compose_block_uses_the_spec_shape():
    block = rl.compose_resource_block(rl.ResourceLimits(cpus=4.0, memory="8g"))
    assert block == {"limits": {"cpus": "4", "memory": "8g"}}


def test_compose_gpus_are_a_reservation_not_a_limit():
    # The compose spec has no GPU "limit"; devices are a reservation.
    block = rl.compose_resource_block(rl.ResourceLimits(gpus="all"))
    devices = block["reservations"]["devices"]
    assert devices[0]["count"] == "all"
    assert devices[0]["capabilities"] == [["gpu"]]


def test_compose_gpu_device_selector_becomes_device_ids():
    block = rl.compose_resource_block(rl.ResourceLimits(gpus="device=0,1"))
    assert block["reservations"]["devices"][0]["device_ids"] == ["0", "1"]


# ── QEMU ─────────────────────────────────────────────────────────────────────────

def test_qemu_smp_rounds_down_never_up():
    # -smp is a whole number of vCPUs, and the setting is a CEILING: rounding 1.5 up
    # to 2 would hand the guest more of the host than the operator allowed.
    assert rl.qemu_smp(rl.ResourceLimits(cpus=1.5)) == 1
    assert rl.qemu_smp(rl.ResourceLimits(cpus=4.0)) == 4


def test_qemu_smp_respects_a_floor():
    assert rl.qemu_smp(rl.ResourceLimits(cpus=0.5), floor=1) == 1


def test_qemu_smp_defers_to_the_caller_when_uncapped():
    assert rl.qemu_smp(rl.ResourceLimits()) is None


# ── GPU availability ─────────────────────────────────────────────────────────────

def test_gpu_warning_when_requested_but_no_runtime():
    warnings = rl.gpu_warnings(rl.ResourceLimits(gpus="all"), probe=lambda: False)
    assert len(warnings) == 1
    assert "no GPU runtime" in warnings[0]


def test_no_gpu_warning_when_the_runtime_is_present():
    assert rl.gpu_warnings(rl.ResourceLimits(gpus="all"), probe=lambda: True) == []


def test_no_gpu_warning_when_no_gpu_was_asked_for():
    # The probe must not even run — it shells out to docker.
    def explode():
        raise AssertionError("probe must not run when no GPU was requested")
    assert rl.gpu_warnings(rl.ResourceLimits(cpus=2.0), probe=explode) == []


# ── Persistence and precedence ───────────────────────────────────────────────────

def test_round_trips_through_disk(tmp_path):
    path = str(tmp_path / "limits.json")
    original = rl.ResourceLimits(cpus=3.5, memory="6g", gpus="device=1")
    rl.save(original, path)
    assert rl.load(path) == original


def test_load_returns_none_when_nothing_was_ever_saved(tmp_path):
    # None ("use the auto formula") and a saved all-None ("the operator explicitly
    # wants no limits") are different answers and must not be conflated.
    assert rl.load(str(tmp_path / "absent.json")) is None


def test_an_explicit_unlimited_choice_survives_a_round_trip(tmp_path):
    path = str(tmp_path / "limits.json")
    rl.save(rl.ResourceLimits(), path)
    loaded = rl.load(path)
    assert loaded is not None and loaded.is_unlimited()


def test_a_corrupt_settings_file_falls_back_instead_of_crashing(tmp_path):
    path = tmp_path / "limits.json"
    path.write_text("{not json", encoding="utf-8")
    assert rl.load(str(path)) is None


def test_saving_is_atomic(tmp_path):
    # A crash mid-write must not leave a truncated file that then fails to parse
    # and silently reverts the operator's setting.
    path = str(tmp_path / "limits.json")
    rl.save(rl.ResourceLimits(cpus=2.0), path)
    assert json.loads(open(path, encoding="utf-8").read()) == {"cpus": 2.0}
    assert not os.path.exists(f"{path}.tmp")


def test_environment_beats_the_saved_setting(tmp_path):
    path = str(tmp_path / "limits.json")
    rl.save(rl.ResourceLimits(cpus=2.0), path)
    effective = rl.effective(env={rl.CPUS_ENV: "9"}, path=path, nproc=8, meminfo={})
    assert effective.cpus == 9.0


def test_the_saved_setting_beats_the_auto_formula(tmp_path):
    path = str(tmp_path / "limits.json")
    rl.save(rl.ResourceLimits(cpus=2.0), path)
    assert rl.effective(env={}, path=path, nproc=64, meminfo={}).cpus == 2.0


def test_auto_applies_when_neither_env_nor_a_saved_setting_exists(tmp_path):
    effective = rl.effective(env={}, path=str(tmp_path / "none.json"), nproc=8, meminfo={})
    assert effective.cpus == 7.0


def test_describe_is_readable_for_a_menu(tmp_path):
    assert rl.ResourceLimits(cpus=6.0, memory="12g").describe() == "6 CPU, 12g, no GPU"
    assert rl.ResourceLimits().describe() == "all CPUs, all memory, no GPU"


# ── The compose stack overlay ────────────────────────────────────────────────────

def test_size_parsing_handles_the_docker_suffixes():
    assert sl.parse_size("1g") == 1024 ** 3
    assert sl.parse_size("512m") == 512 * 1024 ** 2
    assert sl.parse_size("1024") == 1024
    assert sl.parse_size("nonsense") is None


def test_memory_is_DIVIDED_across_services_not_repeated():
    # Writing the whole budget onto each of 41 services would authorise 41x the
    # machine's RAM and protect nothing: a compose memory limit is a hard per-service
    # ceiling, and memory is additive.
    per = sl.per_service_memory("41g", 41)
    assert sl.parse_size(per) <= 1024 ** 3


def test_memory_limit_is_omitted_when_the_share_would_be_unusable():
    # A limit every service breaches at startup is worse than no limit — it just
    # teaches operators to switch the feature off.
    assert sl.per_service_memory("2g", 41) is None


def test_cpu_share_is_floored_so_a_service_can_still_start():
    assert sl.per_service_cpus(0.1, 41) >= sl.MIN_SERVICE_CPUS


def test_overlay_is_empty_when_limits_are_off():
    # Empty means the caller REMOVES the file, the Makefile's $(wildcard) include
    # contributes no -f flag, and the compose invocation is exactly what it was.
    assert sl.render_overlay(rl.ResourceLimits(), ["a", "b"]) == ""


def test_overlay_is_empty_when_there_are_no_services():
    assert sl.render_overlay(rl.ResourceLimits(cpus=4.0), []) == ""


def test_overlay_names_every_service_and_marks_itself_generated():
    body = sl.render_overlay(rl.ResourceLimits(cpus=4.0), ["alpha", "beta"])
    assert "GENERATED" in body and "do not commit" in body
    assert "  alpha:" in body and "  beta:" in body
    assert body.count("cpus:") == 2


def test_writing_then_disabling_REMOVES_the_overlay(tmp_path):
    # A stale overlay from a previous run would keep throttling a stack the operator
    # has since un-limited.
    gen = str(tmp_path)
    os.makedirs(os.path.join(gen, "tests", "stack"), exist_ok=True)
    path = sl.write_overlay(gen, rl.ResourceLimits(cpus=4.0), ["alpha"])
    assert path and os.path.exists(path)

    assert sl.write_overlay(gen, rl.ResourceLimits(), ["alpha"]) is None
    assert not os.path.exists(os.path.join(gen, sl.OVERLAY_RELPATH))


def test_removing_an_absent_overlay_is_not_an_error(tmp_path):
    assert sl.write_overlay(str(tmp_path), rl.ResourceLimits(), ["alpha"]) is None


def test_service_names_are_read_from_a_real_compose_file(tmp_path):
    compose = tmp_path / "compose.yaml"
    compose.write_text(
        "# comment\n"
        "name: stack\n"
        "services:\n"
        "  alpha:\n"
        "    image: a\n"
        "    environment:\n"
        "      FOO: bar\n"
        "  beta:\n"
        "    image: b\n"
        "volumes:\n"
        "  data:\n",
        encoding="utf-8")
    assert sl.compose_services(str(compose)) == ["alpha", "beta"]


def test_an_unreadable_compose_file_yields_no_services_rather_than_raising(tmp_path):
    assert sl.compose_services(str(tmp_path / "absent.yaml")) == []
