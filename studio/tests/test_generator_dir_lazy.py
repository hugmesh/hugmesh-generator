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

import io

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
