"""The NVD key's CLI (``python -m hugmesh_studio.core.nvd_key``) and TUI ``nvd`` verbs.

FAKE keys only. Pins: no flag takes the key on the command line; stdin ``-`` works;
an empty stdin exits 2 and stores nothing; with no terminal and no file ``set``
refuses; ``verify`` exit codes; ``push-org-secret`` hands a fake ``gh`` exactly the key
bytes on stdin and refuses an empty key without running gh; the TUI's ``nvd set``
masks/hides exactly one line and never echoes it.
"""
from __future__ import annotations

import io
import os
import subprocess
import sys

import pytest

from hugmesh_studio.core import nvd_key

from test_nvd_key_core import NVD_200, NVD_404_KEY, FakeOpener

KEY = "11111111-2222-4333-8444-555555555555"
STUDIO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


class _Pipe(io.StringIO):
    def isatty(self):
        return False


class _Tty(io.StringIO):
    def isatty(self):
        return True


def test_there_is_no_flag_that_takes_the_key_on_argv(capsys):
    for bad in (["set", "--key", KEY], ["set", KEY], ["set", "--api-key", KEY],
                ["verify", "--key", KEY]):
        with pytest.raises(SystemExit) as ei:
            nvd_key.main(bad, stdin=_Pipe(""))
        assert ei.value.code == 2, bad
    assert not os.path.exists(nvd_key.key_path())


def test_set_reads_stdin_dash_and_trims(capsys):
    assert nvd_key.main(["set", "--key-file", "-"], stdin=_Pipe(f"  {KEY}\n")) == 0
    assert nvd_key.load() == KEY
    out = capsys.readouterr().out
    assert KEY not in out and nvd_key.ACTIVATION_WARNING in out


def test_set_reads_a_key_file(tmp_path):
    f = tmp_path / "k"
    f.write_text(KEY + "\n")
    assert nvd_key.main(["set", "--key-file", str(f)]) == 0 and nvd_key.load() == KEY


@pytest.mark.parametrize("body", ["", "\n", "   \n"])
def test_empty_stdin_exits_2_and_stores_nothing(body, capsys):
    assert nvd_key.main(["set", "--key-file", "-"], stdin=_Pipe(body)) == 2
    assert nvd_key.EMPTY_REFUSED in capsys.readouterr().err
    assert not os.path.exists(nvd_key.key_path())


def test_no_tty_and_no_file_refuses(capsys):
    assert nvd_key.main(["set"], stdin=_Pipe(KEY)) == 2
    assert "refusing: no key source" in capsys.readouterr().err
    assert not os.path.exists(nvd_key.key_path())


def test_a_terminal_gets_a_hidden_prompt(capsys):
    asked = []
    assert nvd_key.main(["set"], stdin=_Tty(""),
                        prompt=lambda p: asked.append(p) or KEY) == 0
    assert asked and "not echoed" in asked[0] and nvd_key.load() == KEY


@pytest.mark.parametrize("outcome, code, word", [
    (NVD_200, 0, "OK"), (NVD_404_KEY, 3, "NOT_ACCEPTED"),
    (ConnectionRefusedError(111, "x"), 4, "OFFLINE"), ((503, b"", {}), 4, "NVD_UNAVAILABLE"),
    ((429, b"", {}), 5, "RATE_LIMITED"),
])
def test_verify_exit_codes_and_verdict_words(outcome, code, word, capsys):
    nvd_key.save(KEY)
    assert nvd_key.main(["verify"], opener=FakeOpener(outcome)) == code
    cap = capsys.readouterr()
    assert cap.out.startswith(word + " ") and KEY not in cap.out + cap.err
    assert nvd_key.VERIFY_CONSENT in cap.err


def test_verify_with_nothing_stored_says_where_to_get_one(capsys):
    assert nvd_key.main(["verify"]) == 2
    assert nvd_key.REQUEST_URL in capsys.readouterr().out


def test_status_prints_every_shared_line(capsys):
    assert nvd_key.main(["status"]) == 0
    out = capsys.readouterr().out
    for s in (nvd_key.NEED_LINE, nvd_key.REQUEST_URL, nvd_key.ACTIVATION_WARNING,
              nvd_key.EMPTY_REFUSED, nvd_key.GUIDE_URL):
        assert s in out


def test_the_module_runs_headless_and_refuses_without_a_source():
    env = dict(os.environ, PYTHONPATH=STUDIO)
    r = subprocess.run([sys.executable, "-m", "hugmesh_studio.core.nvd_key", "set"],
                       stdin=subprocess.DEVNULL, capture_output=True, text=True, env=env,
                       cwd=STUDIO, timeout=60)
    assert r.returncode == 2 and "refusing: no key source" in r.stderr


# ── push-org-secret against a FAKE gh on PATH ────────────────────────────────────────
@pytest.fixture
def fake_gh(tmp_path, monkeypatch):
    if os.name == "nt":
        pytest.skip("POSIX shell fake")
    rec = tmp_path / "rec"
    rec.mkdir()
    gh = tmp_path / "bin" / "gh"
    gh.parent.mkdir()
    gh.write_text(f"""#!/bin/sh
echo "$@" >> "{rec}/argv"
if [ "$1" = secret ]; then cat > "{rec}/stdin"; exit 0; fi
if [ "$1" = api ]; then printf '2026-11-10T10:33:00Z\\nall\\n'; exit 0; fi
exit 9
""")
    gh.chmod(0o755)
    monkeypatch.setenv("PATH", f"{gh.parent}{os.pathsep}{os.environ['PATH']}")
    return rec


def test_push_hands_gh_exactly_the_key_bytes_on_stdin(fake_gh, capsys):
    nvd_key.save(f"{KEY}\n")
    assert nvd_key.main(["push-org-secret", "--org", "acme", "--yes"]) == 0
    assert (fake_gh / "stdin").read_bytes() == KEY.encode()
    argv = (fake_gh / "argv").read_text()
    assert KEY not in argv and "secret set NVD_API_KEY --org acme --visibility all" in argv
    assert "set on acme at 2026-11-10T10:33:00Z, visibility all" in capsys.readouterr().out


def test_push_refuses_an_unverified_key_without_yes(fake_gh, capsys):
    nvd_key.save(KEY)
    assert nvd_key.main(["push-org-secret", "--org", "acme"]) == 1
    assert not (fake_gh / "argv").exists()
    assert nvd_key.ACTIVATION_WARNING in capsys.readouterr().err


def test_push_with_nothing_stored_never_runs_gh(fake_gh, capsys):
    assert nvd_key.main(["push-org-secret", "--org", "acme", "--yes"]) == 1
    assert not (fake_gh / "argv").exists()
    assert nvd_key.EMPTY_REFUSED in capsys.readouterr().err


# ── the TUI's `nvd` verbs ──────────────────────────────────────────────────────────
def _fleet_journey():
    from hugmesh_studio.tui import journey
    j = journey.Journey(os.path.dirname(STUDIO))
    j.goto("fleet")
    return j


def test_tui_nvd_set_hides_exactly_one_line_and_never_echoes_it():
    from hugmesh_studio.tui.nvd_step import SECRET_PROMPT
    j = _fleet_journey()
    j.feed("nvd set")
    assert j.secret_input() and j.prompt() == SECRET_PROMPT
    j.feed(f"  {KEY} ")
    assert not j.secret_input() and nvd_key.load() == KEY
    assert KEY not in "\n".join(j.lines()) and KEY not in j.status
    assert nvd_key.ACTIVATION_WARNING in j.status


def test_tui_secret_line_bypasses_the_global_commands():
    j = _fleet_journey()
    j.feed("nvd set")
    j.feed("q")                     # a hidden line is the key's line, never 'quit'
    assert not j.done and not j.secret_input()
    assert "not saved" in j.status and nvd_key.load() == ""


def test_tui_nvd_set_with_the_key_on_the_line_is_refused():
    j = _fleet_journey()
    j.feed(f"nvd set {KEY}")
    assert "refused" in j.status and nvd_key.load() == "" and not j.secret_input()


def test_tui_empty_hidden_line_is_refused():
    j = _fleet_journey()
    j.feed("nvd set")
    j.feed("")
    assert nvd_key.EMPTY_REFUSED in j.status and nvd_key.load() == ""


def test_tui_options_show_the_block_once_a_pentest_is_on():
    j = _fleet_journey()
    assert nvd_key.NEED_LINE not in "\n".join(j.lines())
    j.feed("set pentest on")
    text = "\n".join(j.lines())
    for s in (nvd_key.NEED_LINE, nvd_key.REQUEST_URL, nvd_key.ACTIVATION_WARNING,
              nvd_key.EMPTY_REFUSED, nvd_key.VERIFY_CONSENT):
        assert s in text


def test_tui_verify_records_the_verdict(monkeypatch):
    j = _fleet_journey()
    nvd_key.save(KEY)
    scr = j.screen()
    scr.nvd.opener = FakeOpener(NVD_404_KEY)
    j.feed("nvd verify")
    assert j.status.startswith(nvd_key.VERDICT_LABELS[nvd_key.NOT_ACCEPTED])
    assert "not accepted yet" in nvd_key.status_line()


def test_plain_face_reads_the_hidden_line_and_never_prints_it():
    from hugmesh_studio.tui import plain
    out = io.StringIO()
    plain.run_journey(_Pipe(f"nvd set\n{KEY}\nq\n"), out,
                      generator_dir=os.path.dirname(STUDIO), start="fleet")
    assert nvd_key.load() == KEY
    assert KEY not in out.getvalue()
    assert "NVD API key (hidden; not echoed)> " in out.getvalue()
