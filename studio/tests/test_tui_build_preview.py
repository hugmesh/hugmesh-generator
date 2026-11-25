"""tui — the Build screen tells what the window's Review step tells (G35, G36).

G35: the command each image will run, before anything is built (the window's "Show
command"; here ``c``). It is the command ``--print-commands`` prints, for a native root
builder, and a plaintext secret never rides the screen.

G36: the FieldScope gate. ``BuildDriver.preflight`` refuses a config over
``config.scope_violations(cfg)[0]`` and ``preflight_warnings`` says the rest; the walk
here can reach such a config (the new ``load`` opens one from a file, and the Desktop
step's ``gpu`` edits the field it contradicts), so the Build screen says it, per image,
in the same words — it cannot dispatch, so telling is the gate, as for the Domain
services and PKI LAN refusals above it.
"""
import io
import json
import os

import pytest

from hugmesh_studio import app
from hugmesh_studio.core import config as config_mod
from hugmesh_studio.core.build_driver import BuildDriver
from hugmesh_studio.core.config import ImageConfig, scope_violations
from hugmesh_studio.core.worklist import WorklistConfig, WorklistEntry, synthesize
from hugmesh_studio.tui import journey
from hugmesh_studio.tui.fleet import PREVIEW_HOST

#: a real checkout, which the headless channel insists on (the repo this file is in)
CHECKOUT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
CUDA_AMD = "nvidia_cuda=true with gpu_driver=amd-free"
CUDA_AUTO = "nvidia_cuda=true with gpu_driver=auto"


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


def _at_build(tmp_path, cfg=None, worklist=None) -> journey.Journey:
    j = journey.Journey(str(tmp_path), cfg)
    j.worklist = worklist
    j.goto("build")
    return j


def _text(j) -> str:
    return "\n".join(j.lines())


def _mesh(tmp_path, *ids, **base_fields):
    base = ImageConfig(mode="mesh", role="omnibus", platform="x86", brand="acme",
                       **base_fields)
    entries = [WorklistEntry(role=r, platform=p)
               for r, p in (i.split(".") for i in ids)]
    return _at_build(tmp_path, base, WorklistConfig(base=base, entries=entries))


# ── G35: the command, on demand ─────────────────────────────────────────────────────
def test_the_command_is_off_until_asked_and_c_toggles_it(tmp_path):
    j = _at_build(tmp_path)
    assert "build-x86-host-stage4.sh" not in _text(j)
    assert "c=show or hide the build command" in _text(j)
    j.feed("c")
    text = _text(j)
    assert "The command each image runs" in text
    assert "standalone-thick.x86" in text and "bash ./build-x86-host-stage4.sh" in text
    assert "--role standalone-thick" in text
    j.feed("c")
    assert "build-x86-host-stage4.sh" not in _text(j)
    assert j.slug == "build" and not j.done


def test_a_fresh_visit_to_the_screen_starts_with_the_command_hidden(tmp_path):
    j = _at_build(tmp_path)
    j.feed("c")
    j.goto("build")
    assert "build-x86-host-stage4.sh" not in _text(j)


def test_the_preview_is_the_argv_the_headless_channel_prints(tmp_path, capsys):
    cfg = ImageConfig(mode="cloud", role="laptop", platform="x86", brand="acme")
    path = tmp_path / "cloud.json"
    cfg.save(str(path))
    j = journey.Journey(CHECKOUT, cfg)
    j.goto("build")
    j.feed("c")
    shown = [ln.strip() for ln in j.lines() if ln.startswith("    ")]
    assert len(shown) == 1
    capsys.readouterr()
    assert app.main(["--print-commands", "--config", str(path), "--backend", "native",
                     "--generator-dir", CHECKOUT]) == 0
    printed = capsys.readouterr().out.strip()
    assert shown == [printed.removeprefix("sudo ")]


def test_a_mesh_shows_one_command_per_image_under_its_id(tmp_path):
    j = _mesh(tmp_path, "pki.x86", "backend.rpi5")
    j.feed("c")
    lines = j.lines()
    i = lines.index("  pki.x86")
    k = lines.index("  backend.rpi5")
    assert "./build-x86-host-stage4.sh" in lines[i + 1]
    assert "./build-rpi5-stage4.sh" in lines[k + 1]
    assert "also generates each node's KEYS folder" in _text(j)


def test_the_command_is_the_materialized_one_not_the_bare_base(tmp_path):
    """A node role on x86 builds with --installer-ui cli (the role-class resolver the
    real build applies at materialize); a preview of the base would say ``all``."""
    j = _mesh(tmp_path, "pki.x86")
    j.feed("c")
    cmd = [ln for ln in j.lines() if "build-x86-host-stage4.sh" in ln][0]
    assert "--installer-ui cli" in cmd and "--installer-ui all" not in cmd


def test_asking_for_the_command_writes_nothing_to_stderr(tmp_path, capsys):
    """materialize() prints a one-shot resolver note to stderr; on a screen the terminal
    UI owns that would land in the middle of the picture."""
    config_mod.reset_emitted_notes()
    j = _mesh(tmp_path, "pki.x86")
    _text(j)
    j.feed("c")
    _text(j)
    assert capsys.readouterr().err == ""


def test_a_configuration_that_cannot_be_assembled_is_said_not_raised(tmp_path):
    j = _at_build(tmp_path, ImageConfig(mode="standalone", platform="banana"))
    text = _text(j)                                     # said with the command hidden too
    assert "! the GUI build cannot assemble this configuration: " in text
    assert "unknown platform: 'banana'" in text
    j.feed("c")
    assert j.slug == "build" and not j.done
    assert "The command each image runs" not in _text(j)   # no command, no empty heading


# ── G35: no plaintext secret on the screen ──────────────────────────────────────────
SECRETS = {"local_pass": "lp-hunter2", "luks_pass": "luks-hunter3",
           "user_password": "up-hunter4", "root_password": "rp-hunter5"}


def test_the_command_hides_every_secret_and_leaves_the_configuration_alone(tmp_path):
    cfg = ImageConfig(mode="standalone", role="standalone-thick", platform="x86",
                      local_user="alice", **SECRETS)
    j = _at_build(tmp_path, cfg)
    j.feed("c")
    text = _text(j)
    for value in SECRETS.values():
        assert value not in text, value
    for flag in ("--local-pass", "--luks-pass", "--user-password", "--root-password"):
        assert flag in text, flag                       # said to be there...
    assert journey.SECRET_SHOWN in text                 # ...its value is not
    for name, value in SECRETS.items():                 # and the walk still holds them
        assert getattr(j.cfg, name) == value


def test_the_secret_field_list_is_the_cores_not_a_copy(tmp_path):
    """Every SECRET_FIELDS member that is a plain string is hidden — a field added to
    the core list cannot be shown by this screen for want of an edit here."""
    probe = ImageConfig()
    names = [n for n in config_mod.SECRET_FIELDS if isinstance(getattr(probe, n), str)]
    cfg = ImageConfig()
    for n in names:
        setattr(cfg, n, f"sentinel-{n}")
    hidden = journey._secrets_hidden(cfg)
    for n in names:
        assert getattr(hidden, n) == journey.SECRET_SHOWN, n
        assert getattr(cfg, n) == f"sentinel-{n}", n


def test_a_secret_never_reaches_the_screen_with_the_command_hidden_either(tmp_path):
    j = _at_build(tmp_path, ImageConfig(local_pass="lp-hunter2"))
    assert "lp-hunter2" not in _text(j)
    j.feed("c")
    assert "lp-hunter2" not in _text(j)


# ── G36: the FieldScope gate ────────────────────────────────────────────────────────
def test_a_config_the_builder_refuses_is_refused_here_in_the_same_words(tmp_path):
    cfg = ImageConfig(nvidia_cuda=True, gpu_driver="amd-free")
    j = _at_build(tmp_path, cfg)
    blocking, _advice = scope_violations(next(c for _e, c in synthesize(cfg).materialize()))
    assert blocking and CUDA_AMD in blocking[0]
    text = _text(j)
    assert "! the GUI build will refuse this configuration: " + blocking[0] in text


def test_the_refusal_is_the_one_build_preflight_raises(tmp_path):
    """The point: this screen and the window's Review step cannot disagree, because the
    line is the preflight's own problem, not a second statement of the rule."""
    cfg = ImageConfig(nvidia_cuda=True, gpu_driver="amd-free")
    [(_e, built)] = synthesize(cfg).materialize()
    problems = BuildDriver(str(tmp_path), PREVIEW_HOST).preflight(built, "native")
    refusal = [ln for ln in _text(_at_build(tmp_path, cfg)).splitlines()
               if ln.startswith("! the GUI build will refuse this configuration: " + CUDA_AMD)]
    assert refusal
    assert refusal[0].split("configuration: ", 1)[1] in problems


def test_a_shape_the_builder_accepts_is_a_note_not_a_refusal(tmp_path):
    j = _at_build(tmp_path, ImageConfig(nvidia_cuda=True, gpu_driver="auto"))
    text = _text(j)
    assert "note: " + CUDA_AUTO in text
    assert "will refuse" not in text


def test_a_clean_configuration_says_nothing_extra(tmp_path):
    text = _text(_at_build(tmp_path))
    assert "will refuse" not in text and "note:" not in text and "cannot assemble" not in text


def test_a_message_every_image_shares_is_said_once_and_a_single_images_is_tagged(tmp_path):
    both = _text(_mesh(tmp_path, "pki.x86", "backend.x86", nvidia_cuda=True,
                       gpu_driver="amd-free"))
    assert both.count(CUDA_AMD) == 1 and "[pki.x86] " + CUDA_AMD not in both
    # the cuda rule is the x86 builder's: an rpi5 row is not in it, so the x86 row is named
    one = _text(_mesh(tmp_path, "pki.x86", "pki.rpi5", nvidia_cuda=True,
                      gpu_driver="amd-free"))
    assert one.count(CUDA_AMD) == 1
    assert "refuse this configuration: [pki.x86] " + CUDA_AMD in one


def test_a_loaded_config_reaches_the_refusal_and_the_desktop_gpu_command_makes_it(tmp_path):
    """The reachable route: ``load`` opens a config that carries the CUDA bake, the
    Desktop step's ``gpu`` picks a driver that contradicts it, and the Build screen is
    where the walk ends."""
    path = tmp_path / "cuda.json"
    ImageConfig(nvidia_cuda=True, gpu_driver="nvidia").save(str(path))
    j = journey.Journey(str(tmp_path))
    j.feed(f"load {path}")
    assert j.cfg.nvidia_cuda is True
    j.goto("desktop")
    j.feed("gpu amd-free")
    assert j.cfg.gpu_driver == "amd-free", j.status
    j.goto("build")
    assert CUDA_AMD in _text(j)
    j.goto("desktop")
    j.feed("gpu nvidia")
    j.goto("build")
    assert "will refuse" not in _text(j)


def test_the_saved_file_is_still_written_when_the_build_would_refuse(tmp_path):
    """Telling is the gate here, as for the Domain services refusal above it: the
    window's Save config does not refuse a config either, only its Review step does."""
    j = _at_build(tmp_path, ImageConfig(nvidia_cuda=True, gpu_driver="amd-free"))
    out = tmp_path / "out.json"
    j.feed(f"s {out}")
    assert j.status.startswith("saved to ")
    assert json.loads(out.read_text(encoding="utf-8"))["gpu_driver"] == "amd-free"
    assert os.path.exists(out)
