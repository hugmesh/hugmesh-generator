"""core.keyzip.emit_passwordless_login_roles — the opt-in, additive KEYS-extraction
step that mirrors ONLY human-loginable credentials into the local-login roles
manifest (core.local_login_agent).

USER-APPROVED MECHANISM (verbatim, implemented exactly): "when a KEYS USB is
extracted in Studio, write human-loginable role credentials (superadmin, admin —
never DB passwords, mTLS keys, or other machine secrets) into the local roles.json
manifest, gated behind an explicit opt-in flag (default OFF) so it never happens
silently."

These tests are pure-Python / no Qt (see conftest.py) and cover:
  * opt-in OFF -> no manifest write at all, regardless of what the bundle carries.
  * opt-in ON  -> only the human-loginable role(s) appear; every machine/service
    credential present in the same secrets.json is excluded, and none of their
    values leak into the written manifest file.
  * the no-op paths: no vault/secrets.json, corrupt JSON, incomplete role entry.
  * 0600 permissions on the written manifest (the RolesManifest.write() contract).
  * merge-not-clobber against a pre-existing manifest.
  * a full extract() -> emit_passwordless_login_roles() integration path using a
    real KEYS zip.
"""
from __future__ import annotations

import json
import os
import stat
import zipfile

import pytest

from hugmesh_studio.core import keyzip
from hugmesh_studio.core.keyzip import KeyZipContents
from hugmesh_studio.core.local_login_agent import load_manifest


# A realistic (trimmed) offline vault/secrets.json, mirroring the EXACT shape
# scripts/gen-cluster-secrets.sh writes (see keys-template/vault/secrets.example.json
# + keys-template/vault/README.md): the human-loginable casdoor-superadmin entry
# alongside a representative sample of machine/service secrets that must NEVER be
# mirrored, including the two ambiguous-but-excluded admin logins.
SECRETS_JSON = {
    "hugmesh-pki": {
        "casdoor-google": {"clientId": "REPLACE", "clientSecret": "REPLACE"},
        # ambiguous (Casdoor built-in superuser, but the generator's own comment
        # ties it to the casdoor-init Job's machine API login) -> must be EXCLUDED.
        "casdoor-admin": {"username": "admin", "password": "ADMIN-PLAINTEXT-SECRET"},
        # the ONLY entry this feature should ever pick up.
        "casdoor-superadmin": {"username": "superadmin", "password": "SUPERADMIN-SECRET-XYZ"},
        "casdoor-db": {"username": "casdoor", "password": "CASDOOR-DB-SECRET"},
        "route-access-db-roles": {
            "owner_password": "ROUTE-OWNER-SECRET",
            "admin_bff_password": "ROUTE-ADMIN-BFF-SECRET",
        },
        "admin-bff-mfa": {"factor-key": "MFA-FACTOR-KEY-SECRET"},
    },
    "hugmesh-backend": {
        "clickhouse-auth": {"password": "CLICKHOUSE-SECRET"},
        "federation-db": {"password": "FED-DB-SECRET", "app_password": "FED-APP-SECRET"},
    },
    "hugmesh-games": {
        # the games-realm twin of casdoor-admin — same exclusion reasoning.
        "casdoor-games-admin": {"username": "admin", "password": "GAMES-ADMIN-SECRET"},
        "casdoor-games-db": {"username": "threewizards", "password": "GAMES-DB-SECRET"},
    },
    "observability": {
        "uptrace-auth": {"pg-password": "UPTRACE-PG-SECRET", "project-token": "UPTRACE-TOKEN-SECRET"},
    },
}

# The actual sensitive/credential-shaped values in SECRETS_JSON that must NEVER
# appear in the written manifest — everything except the one value this feature
# is supposed to mirror. (Deliberately hand-listed, not derived from usernames/
# clientIds, which can legitimately substring-collide with role ids like
# "superadmin" containing "admin".)
ALL_EXCLUDED_SECRET_VALUES = [
    "ADMIN-PLAINTEXT-SECRET", "CASDOOR-DB-SECRET", "ROUTE-OWNER-SECRET",
    "ROUTE-ADMIN-BFF-SECRET", "MFA-FACTOR-KEY-SECRET", "CLICKHOUSE-SECRET",
    "FED-DB-SECRET", "FED-APP-SECRET", "GAMES-ADMIN-SECRET", "GAMES-DB-SECRET",
    "UPTRACE-PG-SECRET", "UPTRACE-TOKEN-SECRET",
]


def _bundle(tmp_path, secrets_obj=SECRETS_JSON, extra_files=None):
    """A staging dir shaped like a post-extract() KEYS bundle: vault/secrets.json
    plus a keys/ dir (so it also looks like a real has_keys=True bundle)."""
    staging = tmp_path / "staging"
    vault_dir = staging / "vault"
    vault_dir.mkdir(parents=True)
    if secrets_obj is not None:
        (vault_dir / "secrets.json").write_text(json.dumps(secrets_obj), encoding="utf-8")
    keys_dir = staging / "keys"
    keys_dir.mkdir()
    (keys_dir / "ca.crt").write_text("dummy-ca", encoding="utf-8")
    for rel, body in (extra_files or {}).items():
        p = staging / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(body, encoding="utf-8")
    return KeyZipContents(staging_dir=str(staging), has_keys=True)


# ── opt-in OFF: strict no-op ─────────────────────────────────────────────────

def test_disabled_opt_in_returns_nothing_and_never_writes(tmp_path):
    contents = _bundle(tmp_path)
    manifest_path = tmp_path / "roles.json"
    result = keyzip.emit_passwordless_login_roles(
        contents, enabled=False, manifest_path=str(manifest_path))
    assert result == []
    assert not manifest_path.exists()


def test_disabled_opt_in_is_a_noop_even_with_a_pre_existing_manifest(tmp_path):
    """Disabled must not touch an already-existing manifest either (no read, no
    rewrite, no truncation) — a strict no-op, not just 'no new roles'."""
    manifest_path = tmp_path / "roles.json"
    manifest_path.write_text('{"version": 1, "origins": [], "roles": []}', encoding="utf-8")
    before = manifest_path.read_bytes()
    contents = _bundle(tmp_path)
    result = keyzip.emit_passwordless_login_roles(
        contents, enabled=False, manifest_path=str(manifest_path))
    assert result == []
    assert manifest_path.read_bytes() == before


# ── opt-in ON: only the human-loginable role, nothing else ──────────────────

def test_enabled_writes_only_the_superadmin_role(tmp_path):
    contents = _bundle(tmp_path)
    manifest_path = tmp_path / "roles.json"
    result = keyzip.emit_passwordless_login_roles(
        contents, enabled=True, manifest_path=str(manifest_path))
    assert result == ["superadmin"]
    assert manifest_path.exists()

    m = load_manifest(str(manifest_path))
    assert [r.id for r in m.roles] == ["superadmin"]
    role = m.roles[0]
    assert role.username == "superadmin"
    assert role.secret == "SUPERADMIN-SECRET-XYZ"
    assert role.brand == "hugmesh"
    assert role.label  # non-empty human label


def test_enabled_never_leaks_machine_credentials_into_the_manifest(tmp_path):
    """Even though casdoor-admin / casdoor-games-admin / DB passwords / MFA keys /
    route-access passwords / uptrace creds all sit in the SAME secrets.json, none
    of their values may appear anywhere in the written manifest's raw bytes."""
    contents = _bundle(tmp_path)
    manifest_path = tmp_path / "roles.json"
    keyzip.emit_passwordless_login_roles(
        contents, enabled=True, manifest_path=str(manifest_path))
    raw = manifest_path.read_text(encoding="utf-8")
    assert "SUPERADMIN-SECRET-XYZ" in raw   # sanity: the one value that SHOULD be there
    for excluded_value in ALL_EXCLUDED_SECRET_VALUES:
        assert excluded_value not in raw, f"machine/ambiguous secret leaked: {excluded_value!r}"
    # and no machine role ids were minted either
    m = load_manifest(str(manifest_path))
    ids = {r.id for r in m.roles}
    assert "admin" not in ids
    assert "games-admin" not in ids
    assert ids == {"superadmin"}


def test_enabled_manifest_is_mode_0600(tmp_path):
    contents = _bundle(tmp_path)
    manifest_path = tmp_path / "roles.json"
    keyzip.emit_passwordless_login_roles(
        contents, enabled=True, manifest_path=str(manifest_path))
    mode = stat.S_IMODE(os.stat(manifest_path).st_mode)
    assert mode == 0o600


# ── no-op paths that must not crash ──────────────────────────────────────────

def test_enabled_but_no_vault_secrets_json_is_a_noop(tmp_path):
    contents = _bundle(tmp_path, secrets_obj=None)   # no vault/secrets.json at all
    manifest_path = tmp_path / "roles.json"
    result = keyzip.emit_passwordless_login_roles(
        contents, enabled=True, manifest_path=str(manifest_path))
    assert result == []
    assert not manifest_path.exists()


def test_enabled_but_corrupt_secrets_json_is_a_noop(tmp_path):
    staging = tmp_path / "staging"
    (staging / "vault").mkdir(parents=True)
    (staging / "vault" / "secrets.json").write_text("{not valid json", encoding="utf-8")
    contents = KeyZipContents(staging_dir=str(staging), has_keys=True)
    manifest_path = tmp_path / "roles.json"
    result = keyzip.emit_passwordless_login_roles(
        contents, enabled=True, manifest_path=str(manifest_path))
    assert result == []
    assert not manifest_path.exists()


def test_enabled_but_secrets_json_is_a_list_is_a_noop(tmp_path):
    contents = _bundle(tmp_path, secrets_obj=[1, 2, 3])
    manifest_path = tmp_path / "roles.json"
    result = keyzip.emit_passwordless_login_roles(
        contents, enabled=True, manifest_path=str(manifest_path))
    assert result == []
    assert not manifest_path.exists()


@pytest.mark.parametrize("broken_entry", [
    {"username": "superadmin"},                       # missing password
    {"password": "x"},                                 # missing username
    {"username": "", "password": "x"},                  # empty username
    {"username": "superadmin", "password": ""},          # empty password
    {"username": 123, "password": "x"},                  # wrong type
    "not-a-dict",
])
def test_incomplete_superadmin_entry_is_skipped(tmp_path, broken_entry):
    obj = {"hugmesh-pki": {"casdoor-superadmin": broken_entry}}
    contents = _bundle(tmp_path, secrets_obj=obj)
    manifest_path = tmp_path / "roles.json"
    result = keyzip.emit_passwordless_login_roles(
        contents, enabled=True, manifest_path=str(manifest_path))
    assert result == []
    assert not manifest_path.exists()


def test_no_pki_section_at_all_is_a_noop(tmp_path):
    obj = {"hugmesh-backend": {"clickhouse-auth": {"password": "x"}}}
    contents = _bundle(tmp_path, secrets_obj=obj)
    manifest_path = tmp_path / "roles.json"
    result = keyzip.emit_passwordless_login_roles(
        contents, enabled=True, manifest_path=str(manifest_path))
    assert result == []
    assert not manifest_path.exists()


# ── brand slug derivation ────────────────────────────────────────────────────

def test_brand_slug_derived_from_the_pki_section_key(tmp_path):
    obj = {"acme-pki": {"casdoor-superadmin": {"username": "root", "password": "s3cr3t"}}}
    contents = _bundle(tmp_path, secrets_obj=obj)
    manifest_path = tmp_path / "roles.json"
    keyzip.emit_passwordless_login_roles(
        contents, enabled=True, manifest_path=str(manifest_path))
    m = load_manifest(str(manifest_path))
    assert m.roles[0].brand == "acme"
    assert m.roles[0].username == "root"


# ── merge, not clobber ───────────────────────────────────────────────────────

def test_merges_with_an_existing_manifest_instead_of_clobbering_it(tmp_path):
    manifest_path = tmp_path / "roles.json"
    manifest_path.write_text(json.dumps({
        "version": 1,
        "origins": ["https://login.acme.internal"],
        "roles": [{"id": "brandowner", "label": "Brand Owner", "brand": "acme",
                   "username": "brandowner@acme.local", "secret": "existing-secret"}],
    }), encoding="utf-8")

    contents = _bundle(tmp_path)
    result = keyzip.emit_passwordless_login_roles(
        contents, enabled=True, manifest_path=str(manifest_path))
    assert result == ["superadmin"]

    m = load_manifest(str(manifest_path))
    ids = {r.id for r in m.roles}
    assert ids == {"brandowner", "superadmin"}
    assert "https://login.acme.internal" in m.origins  # origins preserved too


def test_reimport_updates_the_same_role_id_idempotently(tmp_path):
    contents = _bundle(tmp_path)
    manifest_path = tmp_path / "roles.json"
    keyzip.emit_passwordless_login_roles(contents, enabled=True, manifest_path=str(manifest_path))

    rotated = json.loads(json.dumps(SECRETS_JSON))
    rotated["hugmesh-pki"]["casdoor-superadmin"]["password"] = "ROTATED-SECRET"
    contents2 = _bundle(tmp_path / "second", secrets_obj=rotated)
    keyzip.emit_passwordless_login_roles(contents2, enabled=True, manifest_path=str(manifest_path))

    m = load_manifest(str(manifest_path))
    assert [r.id for r in m.roles] == ["superadmin"]   # still exactly one, not duplicated
    assert m.roles[0].secret == "ROTATED-SECRET"


# ── default manifest path resolution ─────────────────────────────────────────

def test_default_manifest_path_used_when_none_given(tmp_path, monkeypatch):
    target = tmp_path / "custom-dir" / "roles.json"
    monkeypatch.setenv("HUGMESH_LOCAL_LOGIN_MANIFEST", str(target))
    contents = _bundle(tmp_path)
    result = keyzip.emit_passwordless_login_roles(contents, enabled=True, manifest_path=None)
    assert result == ["superadmin"]
    assert target.exists()


# ── full extract() -> emit_passwordless_login_roles() integration ───────────

def _make_zip(zip_path, entries: dict):
    with zipfile.ZipFile(zip_path, "w") as zf:
        for name, body in entries.items():
            zf.writestr(name, body)


def test_full_extract_then_emit_flow_opt_in_on(tmp_path):
    zip_path = tmp_path / "acme-keys.zip"
    _make_zip(zip_path, {
        "keys/ca.crt": "dummy-ca-cert",
        "vault/secrets.json": json.dumps(SECRETS_JSON),
    })
    staging = tmp_path / "staged"
    contents = keyzip.extract(str(zip_path), str(staging))
    assert contents.has_keys is True   # keyzip's own existing classification, untouched

    manifest_path = tmp_path / "roles.json"
    result = keyzip.emit_passwordless_login_roles(
        contents, enabled=True, manifest_path=str(manifest_path))
    assert result == ["superadmin"]
    m = load_manifest(str(manifest_path))
    assert m.roles[0].username == "superadmin"
    assert m.roles[0].secret == "SUPERADMIN-SECRET-XYZ"


def test_full_extract_then_emit_flow_opt_in_off(tmp_path):
    """Same real bundle, opt-in OFF: extract() behaves identically (additive
    guarantee) but nothing is written to the manifest."""
    zip_path = tmp_path / "acme-keys.zip"
    _make_zip(zip_path, {
        "keys/ca.crt": "dummy-ca-cert",
        "vault/secrets.json": json.dumps(SECRETS_JSON),
    })
    staging = tmp_path / "staged"
    contents = keyzip.extract(str(zip_path), str(staging))
    assert contents.has_keys is True

    manifest_path = tmp_path / "roles.json"
    result = keyzip.emit_passwordless_login_roles(
        contents, enabled=False, manifest_path=str(manifest_path))
    assert result == []
    assert not manifest_path.exists()
