"""tui — no secret is typed into, shown by, or saved from the text UI (G38).

``config.SECRET_FIELDS`` are the plaintext secrets a config may hold in memory and a
saved file must never carry: ``local_pass``, ``luks_pass``, ``user_password``,
``root_password`` and ``extra_local_passes``. The window types them into masked fields.
The text UI has no such field, and the audit below is why none is needed: the only
secrets a screen can set are the two the Desktop step reads from a FILE (``pass=FILE``,
the first line), so a password is never typed on the terminal, never on the screen and
never in a scrollback; and nothing here saves one.

A new typed entry for a secret would break the first test on purpose: it must use the
hidden line (``Journey.secret_input``, which the NVD API key already uses: masked in the
urwid face, read with getpass in the plain one) and add its own pins here.
"""
import glob
import json
import os
import re

import pytest

from hugmesh_studio.core.config import SECRET_FIELDS
from hugmesh_studio.tui import journey

TUI_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                       "hugmesh_studio", "tui")
#: what a secret FILE holds in these tests — a sentinel no other text on a screen contains
PW = "s3cret-sentinel-Q7"
LITERAL = "typed-literal-sentinel-Z9"


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


def _to_desktop() -> journey.Journey:
    j = journey.Journey(".")
    j.feed("")                    # welcome -> mode (standalone default)
    for _ in range(20):
        if j.slug == "desktop":
            return j
        j.feed("")
    raise AssertionError(f"never reached desktop (stuck on {j.slug})")


def _pwfile(tmp_path, text=PW + "\n"):
    path = tmp_path / "pw"
    path.write_text(text, encoding="utf-8")
    return str(path)


def _everything_shown(j) -> str:
    """The screen, its inline status, and the Build screen with the command shown."""
    out = ["\n".join(j.lines())]
    here = j.slug
    j.goto("build")
    j.feed("c")
    out.append("\n".join(j.lines()))
    j.feed("c")
    j.goto(here)
    return "\n".join(out)


# ── the audit: which secrets can a screen set at all ────────────────────────────────
def test_the_only_secrets_a_text_ui_screen_sets_are_the_two_read_from_a_file():
    names = "|".join(SECRET_FIELDS)
    assign = re.compile(rf"\b({names})\b\s*=(?!=)")          # attribute or keyword
    quoted = re.compile(rf"""['"]({names})['"]""")           # a field table / setattr
    found = set()
    files = sorted(glob.glob(os.path.join(TUI_DIR, "*.py")))
    assert len(files) > 20
    for path in files:
        with open(path, "rb") as fh:
            raw = fh.read()
        assert b"\0" not in raw, path                        # a NUL would blind a grep audit
        for line in raw.decode("utf-8").splitlines():
            for m in (*assign.finditer(line), *quoted.finditer(line)):
                found.add((os.path.basename(path), m.group(1)))
    assert found == {("desktop_step.py", "local_pass"),
                     ("desktop_step.py", "extra_local_passes")}, (
        "a text UI screen now sets a plaintext secret: enter it on the hidden line "
        "(Journey.secret_input), never echoed, and pin it in this file")
    # the three it never sets are exactly the window's masked-only ones
    assert set(SECRET_FIELDS) - {n for _f, n in found} == {
        "luks_pass", "user_password", "root_password"}


def test_no_step_of_the_walk_asks_for_a_hidden_line():
    """The hidden-line mechanism exists for the NVD API key of the fleet and Go-Live
    screens (not a SECRET_FIELD: core.nvd_key stores it). No step of the image walk asks
    for one, because no step of the image walk takes a typed secret."""
    j = journey.Journey(".")
    for slug in journey.PAGE_ORDER:
        if slug in journey.SIDE_FLOW_SLUGS:
            continue
        j.goto(slug)
        assert j.secret_input() is False, slug


# ── the two that exist: from a FILE, never shown, never saved ───────────────────────
def test_a_password_read_from_a_file_is_never_shown_and_never_saved(tmp_path):
    j = _to_desktop()
    pw = _pwfile(tmp_path)
    j.feed(f"login ann admin pass={pw}")
    assert j.status.startswith("login account: ann (administrator); password read")
    j.feed(f"user add bob pass={pw}")
    assert not j.status.startswith("not "), j.status
    assert j.cfg.local_pass == PW and f"bob:{PW}" in j.cfg.extra_local_passes   # held in memory...
    shown = _everything_shown(j)
    assert PW not in shown                                  # ...never on a screen
    assert "--local-pass" in shown and journey.SECRET_SHOWN in shown
    j.goto("build")
    out = tmp_path / "saved.json"
    j.feed(f"s {out}")
    assert j.status.startswith("saved to "), j.status
    text = out.read_text(encoding="utf-8")
    assert PW not in text                                   # ...and never on disk
    saved = json.loads(text)
    assert saved["local_pass"] == "" and "extra_local_passes" not in saved
    for name in SECRET_FIELDS:
        assert not saved.get(name), name


def test_a_password_typed_where_the_file_name_goes_is_not_repeated_back(tmp_path):
    """``pass=hunter2``: the person typed the password instead of a file name. The refusal
    says what to do and does not echo it (the OSError's own text names the file)."""
    j = _to_desktop()
    for line in (f"login ann pass={LITERAL}", f"user add bob pass={LITERAL}"):
        j.feed(line)
        assert j.status.startswith("not done: "), j.status
        assert LITERAL not in j.status and LITERAL not in "\n".join(j.lines())
        assert "first line of a FILE, never typed here" in j.status
    assert j.cfg.local_pass == "" and j.cfg.extra_local_passes == ""


def test_a_file_that_cannot_be_read_is_said_without_its_name_for_every_kind_of_failure(tmp_path):
    j = _to_desktop()
    (tmp_path / "dir").mkdir()
    binary = tmp_path / "bin"
    binary.write_bytes(b"\xff\xfe\x00\x80 not utf-8 \xff")
    for target, why in ((tmp_path / "missing" / LITERAL, "No such file"),
                        (tmp_path / "dir", "Is a directory"),
                        (binary, "not readable as UTF-8 text")):
        j.feed(f"login ann pass={target}")
        assert j.status.startswith("not done: pass=FILE could not be read ("), j.status
        assert why in j.status, j.status
        assert LITERAL not in j.status
    assert j.cfg.local_pass == ""


def test_a_refused_password_changes_nothing_not_even_the_account(tmp_path):
    """The file is read BEFORE the account is touched: ``login ann admin pass=BAD`` used to
    leave the account renamed and made an administrator while saying "not done"."""
    j = _to_desktop()
    before = (j.cfg.local_user, j.cfg.local_admin, j.cfg.local_pass)
    j.feed(f"login ann admin pass={tmp_path / 'missing'}")
    assert j.status.startswith("not done: ")
    assert (j.cfg.local_user, j.cfg.local_admin, j.cfg.local_pass) == before
    j.feed(f"login ann admin pass={_pwfile(tmp_path)}")        # and the good one still works
    assert (j.cfg.local_user, j.cfg.local_admin, j.cfg.local_pass) == ("ann", True, PW)
