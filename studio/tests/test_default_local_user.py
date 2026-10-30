"""The default image login is the invoking account FOLDED into a legal unix login.

On Windows 11 the 0.3.0-beta.1 MSI's own smoke command, ``--print-specs``, exited 2 with
"invalid local_user: 'Magus' — rejected by the identity allowlist": the default was
the raw account name, and Windows account names are capitalised or contain spaces.
The release job never saw it because the runner's account is ``runneradmin``.
"""
from __future__ import annotations

import pytest

from hugmesh_studio.core import config
from hugmesh_studio.core.validate import validate_username


@pytest.mark.parametrize("account,login", [
    ("magus", "magus"),                    # already legal: unchanged (Linux, the CI runner)
    ("runneradmin", "runneradmin"),
    ("Magus", "magus"),                    # the measured Windows failure
    ("Jane Doe", "janedoe"),
    ("O'Brien", "obrien"),
    ("2fast", "fast"),                     # a login must not start with a digit
    ("_svc-build", "_svc-build"),
    ("Ünïcode", "ncode"),
    ("x" * 40, "x" * 32),
    ("ÄÖÜ", "user"),                       # nothing legal left
    ("", "user"),
])
def test_the_account_is_folded_into_a_login_the_allowlist_accepts(monkeypatch, account, login):
    monkeypatch.setattr(config.getpass, "getuser", lambda: account)
    got = config.default_local_user()
    assert got == login
    validate_username(got)


def test_a_missing_account_is_user(monkeypatch):
    def boom():
        raise KeyError("no passwd entry")
    monkeypatch.setattr(config.getpass, "getuser", boom)
    assert config.default_local_user() == "user"


def test_a_default_config_with_a_windows_account_validates(monkeypatch):
    monkeypatch.setattr(config.getpass, "getuser", lambda: "Magus")
    cfg = config.ImageConfig()
    assert cfg.local_user == "magus"
    cfg.validate_identity()
