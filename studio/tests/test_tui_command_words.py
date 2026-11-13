"""The TUI's command-line splitter keeps a Windows path whole (part of the Windows contract).

Found 2026-11-13 on Windows 11: ``shlex.split`` treats a backslash as an escape, so
``k 1 C:\\Users\\ann\\root.crt`` reached the Domain CA keys step as
``C:Usersannroot.crt`` and the Desktop step's ``pass=FILE`` the same way.
"""
from __future__ import annotations

import os
import shlex

import pytest

from hugmesh_studio.tui import command_words, desktop_step, domain_ca_keys_step

WIN = r"C:\Users\ann\keys\root.crt"


def test_a_windows_path_survives_on_windows():
    assert command_words.split(f"k 1 {WIN}", osname="nt") == ["k", "1", WIN]


def test_quotes_still_group_a_path_with_spaces_and_are_removed_on_windows():
    line = r'k 1 "C:\My Keys\signing.crt" "C:\My Keys\signing.key" pass=C:\pw.txt'
    assert command_words.split(line, osname="nt") == [
        "k", "1", r"C:\My Keys\signing.crt", r"C:\My Keys\signing.key", r"pass=C:\pw.txt"]


def test_a_trailing_backslash_and_a_unc_path_are_kept_on_windows():
    assert command_words.split(r"r 1 \\server\share\ca.crt C:\dir\ ", osname="nt") == [
        "r", "1", r"\\server\share\ca.crt", "C:\\dir\\"]


def test_an_unclosed_quote_is_a_value_error_on_both_hosts():
    for osname in ("nt", "posix"):
        with pytest.raises(ValueError):
            command_words.split('k 1 "C:\\no end', osname=osname)


@pytest.mark.parametrize("line", [
    "k 1 /tmp/a.crt /tmp/a.key pass=/tmp/pw",
    "r 1 'a file.crt'",
    r"r 1 a\ file.crt",
    "user add ann admin pass=/home/ann/pw",
    "",
])
def test_posix_hosts_split_exactly_as_before(line):
    assert command_words.split(line, osname="posix") == shlex.split(line)


def test_both_path_taking_steps_split_through_it():
    # a step that went back to shlex.split would lose the backslashes again
    for mod in (domain_ca_keys_step, desktop_step):
        src = open(mod.__file__, encoding="utf-8").read()
        assert "command_words.split(" in src and "shlex.split(" not in src, mod.__name__


@pytest.mark.skipif(os.name != "nt", reason="a real Windows path, read by the real step")
def test_the_domain_ca_step_reads_a_windows_path_on_windows(tmp_path):
    pytest.importorskip("cryptography")
    import _throwaway_ca as tca                                 # noqa: PLC0415
    from hugmesh_studio.core import domain_ca_keys as dca
    from hugmesh_studio.tui import journey
    chain = tca.Chain(tmp_path)
    assert "\\" in str(chain.root_path)
    j = journey.Journey(os.path.dirname(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__)))))
    j.cfg.mode = "mesh"
    j.cfg.cluster_domain = "mesh.example"
    j.goto(dca.STEP_SLUG)
    j.feed(f"r 1 {chain.root_path}")
    assert j.status.startswith("imported"), j.status
