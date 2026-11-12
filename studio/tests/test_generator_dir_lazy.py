"""``--generator-dir`` is resolved only by the paths that use it (#936 refute, round 2).

Inside the installed Flatpak no checkout is found, so the default resolution ends in
``managed_generator.ensure()``, which places the bundled 133 MB generator copy (3263
files). That default used to be computed while the argument parser was BUILT
(``add_argument(..., default=_default_generator_dir())``), so ``--help`` and
``--print-specs`` -- which never touch the generator -- placed it too. Here the
Flatpak's situation is reproduced without a Flatpak: nothing is a checkout, and
``ensure()`` is a recorder.
"""
from __future__ import annotations

import ast
import io
from pathlib import Path

import pytest

from hugmesh_studio import app
from hugmesh_studio.core import generator_dir, managed_generator
from hugmesh_studio.tui import app as tui_app


@pytest.fixture
def no_checkout_anywhere(tmp_path, monkeypatch):
    """No source tree, cwd, env or saved pick is a checkout: what the Flatpak sees."""
    monkeypatch.chdir(tmp_path)
    monkeypatch.delenv(generator_dir.ENV, raising=False)
    monkeypatch.setattr(generator_dir, "is_checkout", lambda path: False)
    placed = []

    def ensure(*a, **k):
        placed.append((a, k))
        return managed_generator.Placed()
    monkeypatch.setattr(managed_generator, "ensure", ensure)
    return placed


def test_help_places_nothing(no_checkout_anywhere, capsys):
    with pytest.raises(SystemExit) as e:
        app.main(["--help"])
    assert e.value.code == 0
    assert "--generator-dir" in capsys.readouterr().out
    assert no_checkout_anywhere == [], "--help placed the managed generator copy"


def test_print_specs_places_nothing(no_checkout_anywhere, capsys):
    assert app.main(["--print-specs"]) == 0
    assert capsys.readouterr().out.strip().startswith("{")
    assert no_checkout_anywhere == [], "--print-specs placed the managed generator copy"


def test_a_bad_flag_places_nothing(no_checkout_anywhere):
    with pytest.raises(SystemExit) as e:
        app.main(["--no-such-flag"])
    assert e.value.code == 2
    assert no_checkout_anywhere == []


def test_a_path_that_uses_the_generator_still_resolves_it(no_checkout_anywhere,
                                                          monkeypatch, capsys):
    """--self-check needs the tree: the default is resolved there, exactly once."""
    calls = []
    real = app._default_generator_dir

    def counted():
        calls.append(1)
        return real()
    monkeypatch.setattr(app, "_default_generator_dir", counted)
    app.main(["--self-check", "--json"])
    capsys.readouterr()
    assert calls == [1]
    assert len(no_checkout_anywhere) >= 1        # resolve() reached the managed copy


def test_an_explicit_generator_dir_is_never_resolved(no_checkout_anywhere, monkeypatch,
                                                     tmp_path, capsys):
    monkeypatch.setattr(app, "_default_generator_dir",
                        lambda: pytest.fail("an explicit --generator-dir was resolved"))
    assert app.main(["--print-command", "--generator-dir", str(tmp_path)]) == 2
    assert str(tmp_path) in capsys.readouterr().err


def test_tui_help_places_nothing(no_checkout_anywhere, capsys):
    with pytest.raises(SystemExit) as e:
        tui_app.main(["--help"])
    assert e.value.code == 0
    assert no_checkout_anywhere == []


def test_tui_worklist_view_places_nothing(no_checkout_anywhere):
    rc = tui_app.main(["--worklist", "no-such-session", "--plain"],
                      inp=io.StringIO(""), out=io.StringIO())
    assert rc == 2
    assert no_checkout_anywhere == []


def test_go_live_target_cli_resolves_the_default(monkeypatch, tmp_path):
    """#931's Qt-free ``--go-live-target`` block merged after the lazy default and
    passed ``args.generator_dir`` on raw: None, so ``--go-live-target targets`` with
    no --generator-dir died in os.path.join (#974 refute, round 1b). It goes through
    ``_generator_dir(args)`` like every other path."""
    from hugmesh_studio.core import golive_target
    monkeypatch.setattr(app, "_default_generator_dir", lambda: str(tmp_path))
    seen = []
    monkeypatch.setattr(golive_target, "run_studio_cli",
                        lambda rest, gen: seen.append((list(rest), gen)) or 0)
    assert app.main(["--go-live-target", "targets"]) == 0
    assert seen == [(["targets"], str(tmp_path))]


def _raw_generator_dir_reads(path: Path) -> list[str]:
    """Every READ of a ``.generator_dir`` attribute (or ``getattr(x,
    "generator_dir")``) in ``path`` outside its ``_generator_dir`` resolver, as
    "file:line". Writes (``args.generator_dir = ...``) are not reads."""
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    allowed = [range(n.lineno, n.end_lineno + 1) for n in ast.walk(tree)
               if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef))
               and n.name == "_generator_dir"]
    assert allowed, f"{path.name} lost its _generator_dir resolver"
    out = []
    for n in ast.walk(tree):
        hit = (isinstance(n, ast.Attribute) and n.attr == "generator_dir"
               and isinstance(n.ctx, ast.Load))
        hit = hit or (isinstance(n, ast.Call) and isinstance(n.func, ast.Name)
                      and n.func.id == "getattr" and len(n.args) >= 2
                      and isinstance(n.args[1], ast.Constant)
                      and n.args[1].value == "generator_dir")
        if hit and not any(n.lineno in r for r in allowed):
            out.append(f"{path.name}:{n.lineno}")
    return out


@pytest.mark.parametrize("module", [app, tui_app], ids=["app", "tui_app"])
def test_no_raw_read_of_the_generator_dir_outside_the_resolver(module):
    """``--generator-dir`` defaults to None, so a raw ``args.generator_dir`` is None
    on every path that did not call ``_generator_dir(args)`` first. A later merge
    reintroduced one (the class of the #931 merge above); the behaviour tests stay
    green on such a line until someone runs that exact flag, so pin the source."""
    assert _raw_generator_dir_reads(Path(module.__file__)) == []
