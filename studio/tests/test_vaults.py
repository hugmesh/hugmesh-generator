"""Vaults & managed volumes — the core model and the dialog's destructive guard.

OPERATOR ASK (2026-08-14): "add a vaults management menu button and modal display menu
which lets a studio user who started a mesh locally or with qemu emulation manage
entries in vault and managed volumes".

The assertions worth having here are about the two ways this feature could hurt someone:

1. DELETING THE WRONG THING. A managed volume is a BFF's postgres, cassandra, or the
   uploads — no rebuild restores it and there is no undo. So: in-use volumes are refused,
   an unconfirmed delete is refused, selection is matched by compose LABEL rather than
   name prefix (a prefix match would sweep in an unrelated volume someone named
   similarly), and the dialog's Delete arms only on an exact name match against the
   SELECTED row.
2. LYING ABOUT VAULT. Vault is a cluster-lane service, absent from the docker mesh.
   Reporting "0 entries" would read as "vault is running and empty" and invite an
   operator to add an entry that goes nowhere — the do-nothing-control trap this codebase has
   hit repeatedly. It must report unavailable WITH the remedy.

Everything is driven through a fake `_run`, so the suite never needs docker and never
touches a real volume.
"""

from __future__ import annotations

import pytest

from hugmesh_studio.core import vaults
from hugmesh_studio.core.vaults import Capability, ManagedVolume

pytest.importorskip("hugmesh_studio.gui.qt", reason="dialog tests need a Qt binding")

from hugmesh_studio.gui.qt import QtWidgets  # noqa: E402
from hugmesh_studio.gui.vaults_dialog import VaultsDialog  # noqa: E402


class FakeRun:
    """Stand-in for vaults._run, keyed on a distinctive fragment of the argv."""

    def __init__(self, table: dict[str, tuple[int, str, str]]):
        self.table = table
        self.calls: list[list[str]] = []

    def __call__(self, args, *, env=None, stdin=None, timeout=None):
        self.calls.append(list(args))
        self.last_env = env
        self.last_stdin = stdin
        joined = " ".join(args)
        for frag, (rc, out, err) in self.table.items():
            if frag in joined:
                return type("R", (), {"returncode": rc, "stdout": out, "stderr": err})()
        return type("R", (), {"returncode": 0, "stdout": "", "stderr": ""})()


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


def vol(short="admin-bff-pg", in_use=(), size=1024):
    return ManagedVolume(name=f"hugmesh-local_{short}", short=short,
                         mountpoint=f"/var/lib/docker/volumes/{short}/_data",
                         size_bytes=size, in_use_by=tuple(in_use))


class TestVolumeEnumeration:
    def test_selects_by_compose_LABEL_not_name_prefix(self, monkeypatch):
        """A prefix match would sweep in any volume a user named similarly — and this
        module offers a delete."""
        fake = FakeRun({"volume ls": (0, "", "")})
        monkeypatch.setattr(vaults, "_run", fake)
        vaults.list_volumes("hugmesh-local")
        ls = next(c for c in fake.calls if "ls" in c)
        assert "label=com.docker.compose.project=hugmesh-local" in ls

    def test_empty_when_docker_fails_rather_than_raising(self, monkeypatch):
        monkeypatch.setattr(vaults, "_run", FakeRun({"volume ls": (1, "", "boom")}))
        assert vaults.list_volumes() == []

    def test_strict_raises_instead_of_reporting_none_when_docker_fails(self, monkeypatch):
        """#361: a failed `docker volume ls` is UNKNOWN, not EMPTY — a caller that makes a
        claim about the operator's data asks for strict and gets an exception."""
        monkeypatch.setattr(vaults, "_run", FakeRun({"volume ls": (1, "", "boom")}))
        with pytest.raises(vaults.DockerDidNotAnswer):
            vaults.list_volumes(strict=True)
        monkeypatch.setattr(vaults, "_run", FakeRun({"volume ls": (0, "", "")}))
        assert vaults.list_volumes(strict=True) == []      # an ANSWERED empty is still []


class TestSizeParsing:
    @pytest.mark.parametrize("raw,expected", [
        ("0B", 0), ("1.5kB", 1500), ("2GB", 2_000_000_000),
        ("1KiB", 1024), ("1.5GiB", int(1.5 * (1 << 30))),
    ])
    def test_parses_docker_human_sizes(self, raw, expected):
        assert vaults._parse_size(raw) == expected

    @pytest.mark.parametrize("raw", ["N/A", "", "-", "garbage"])
    def test_unparseable_is_None_not_zero(self, raw):
        """None renders as '—'. Zero would claim the volume is EMPTY, which invites a
        delete of something that may hold data."""
        assert vaults._parse_size(raw) is None

    def test_human_size_renders_none_as_dash(self):
        assert ManagedVolume("n", "s", "/m", size_bytes=None).human_size() == "—"


class TestDeleteGuards:
    def test_in_use_volume_is_refused_and_names_the_holder(self, monkeypatch):
        monkeypatch.setattr(vaults, "_run", FakeRun({}))
        cap = vaults.remove_volume(vol(in_use=["hugmesh-local-admin-bff-db-1"]),
                                   confirm=True)
        assert cap.available is False
        assert "hugmesh-local-admin-bff-db-1" in cap.detail

    def test_unconfirmed_delete_is_refused(self, monkeypatch):
        fake = FakeRun({})
        monkeypatch.setattr(vaults, "_run", fake)
        assert vaults.remove_volume(vol(), confirm=False).available is False
        assert not any("rm" in c for c in fake.calls), "docker must not be reached"

    def test_confirmed_free_volume_is_removed(self, monkeypatch):
        fake = FakeRun({"volume rm": (0, "", "")})
        monkeypatch.setattr(vaults, "_run", fake)
        assert vaults.remove_volume(vol(), confirm=True).available is True
        assert any("rm" in c for c in fake.calls)

    def test_stopped_containers_still_count_as_holders(self, monkeypatch):
        """`docker ps -a`, not `docker ps`: a stopped mesh still owns its data, and
        deleting because nothing is running destroys exactly what will be restarted."""
        fake = FakeRun({"ps -a": (0, "", "")})
        monkeypatch.setattr(vaults, "_run", fake)
        vaults._volume_users()
        assert any("-a" in c for c in fake.calls if "ps" in c)


class TestVaultHonesty:
    def test_absent_vault_reports_the_devops_lane_remedy(self, monkeypatch):
        monkeypatch.delenv("VAULT_ADDR", raising=False)
        monkeypatch.setattr(vaults, "_run", FakeRun({"ps": (0, "", "")}))
        cap = vaults.vault_capability()
        assert cap.available is False
        assert "DevOps" in cap.remedy or "kind-up" in cap.remedy

    def test_list_entries_reports_unavailable_NOT_an_empty_vault(self, monkeypatch):
        """The distinction the whole tab hinges on: 'cannot reach vault' and 'vault is
        empty' render differently and only one invites the operator to add an entry."""
        monkeypatch.delenv("VAULT_ADDR", raising=False)
        monkeypatch.setattr(vaults, "_run", FakeRun({"ps": (0, "", "")}))
        entries, cap = vaults.list_entries()
        assert entries == []
        assert cap.available is False and cap.remedy

    def test_reachable_vault_without_a_token_says_so(self, monkeypatch):
        monkeypatch.setenv("VAULT_ADDR", "https://vault.example:8200")
        monkeypatch.delenv("VAULT_TOKEN", raising=False)
        monkeypatch.setattr(vaults, "_run", FakeRun({"ps": (0, "", "")}))
        cap = vaults.vault_capability()
        assert cap.available is False
        assert "VAULT_TOKEN" in cap.remedy

    def test_a_written_value_NEVER_appears_in_argv(self, monkeypatch):
        """argv is world-readable via /proc, so a secret passed as an argument is
        disclosed to every local user for the lifetime of the call."""
        monkeypatch.setenv("VAULT_ADDR", "https://vault.example:8200")
        monkeypatch.setenv("VAULT_TOKEN", "t")
        fake = FakeRun({"ps": (0, "", ""), "kv put": (0, "", "")})
        monkeypatch.setattr(vaults, "_run", fake)
        vaults.put_entry("secret/app", "password", "hunter2-super-secret")
        for call in fake.calls:
            assert not any("hunter2" in a for a in call), f"secret leaked into argv: {call}"
        assert fake.last_stdin == "hunter2-super-secret"


class TestDialogDeleteArming:
    """The inline confirm, which replaces a nested modal (that would hang headless)."""

    def _dialog(self, qapp, monkeypatch, volumes):
        monkeypatch.setattr(vaults, "list_volumes", lambda *a, **k: volumes)
        monkeypatch.setattr(vaults, "docker_available", lambda: Capability(True))
        monkeypatch.setattr(vaults, "vault_capability",
                            lambda *a, **k: Capability(False, "no vault", "start the lane"))
        d = VaultsDialog(project="hugmesh-local")
        d._on_probe((volumes, Capability(False, "no vault", "start the lane"),
                     Capability(True)))
        return d

    def test_delete_is_disabled_until_the_name_is_typed(self, qapp, monkeypatch):
        d = self._dialog(qapp, monkeypatch, [vol()])
        d.table.selectRow(0)
        assert d.delete_btn.isEnabled() is False
        d.confirm.setText("admin-bff-pg")
        assert d.delete_btn.isEnabled() is True

    def test_a_wrong_name_does_not_arm_it(self, qapp, monkeypatch):
        d = self._dialog(qapp, monkeypatch, [vol()])
        d.table.selectRow(0)
        d.confirm.setText("casdoor-pg")
        assert d.delete_btn.isEnabled() is False

    def test_changing_the_selection_disarms_a_typed_confirmation(self, qapp, monkeypatch):
        """Otherwise a confirmation typed for one volume would stay armed while a
        mis-click retargeted it at a DIFFERENT volume's data."""
        d = self._dialog(qapp, monkeypatch, [vol(), vol("casdoor-pg")])
        d.table.selectRow(0)
        d.confirm.setText("admin-bff-pg")
        assert d.delete_btn.isEnabled() is True
        d.table.selectRow(1)
        assert d.delete_btn.isEnabled() is False

    def test_an_in_use_volume_can_never_be_armed(self, qapp, monkeypatch):
        d = self._dialog(qapp, monkeypatch, [vol(in_use=["hugmesh-local-admin-bff-db-1"])])
        d.table.selectRow(0)
        d.confirm.setText("admin-bff-pg")
        assert d.delete_btn.isEnabled() is False
        assert "in use" in d.danger.text()

    def test_vault_tab_shows_the_remedy_not_an_empty_list(self, qapp, monkeypatch):
        d = self._dialog(qapp, monkeypatch, [vol()])
        texts = [w.text() for w in d.vault_page.findChildren(QtWidgets.QLabel)]
        assert any("start the lane" in t for t in texts)
        assert not d.vault_page.findChildren(QtWidgets.QListWidget)


class TestGetEntry:
    """Reading a secret back out.

    The whole point of this function is WHERE the value travels. It comes back on stdout
    rather than argv, because argv is world-readable through /proc on a shared machine —
    the same reasoning put_entry states for writes. These tests pin that, and pin that a
    failure never carries the payload: echoing what came back is the obvious debugging aid
    and is exactly how a token reaches a screenshot or a bug report.
    """

    def _available(self, monkeypatch):
        monkeypatch.setenv("VAULT_ADDR", "http://vault:8200")
        monkeypatch.setenv("VAULT_TOKEN", "root-token")
        monkeypatch.setattr(vaults, "vault_capability",
                            lambda project=vaults.DEFAULT_PROJECT: vaults.Capability(True))

    def test_it_returns_the_value_from_stdout(self, monkeypatch):
        self._available(monkeypatch)
        fake = FakeRun({"kv get": (0, "s3cret-token\n", "")})
        monkeypatch.setattr(vaults, "_run", fake)
        value, cap = vaults.get_entry("secret/hugmesh/studio", "admin_token")
        assert value == "s3cret-token"
        assert cap.available

    def test_the_secret_is_never_placed_in_argv(self, monkeypatch):
        self._available(monkeypatch)
        fake = FakeRun({"kv get": (0, "s3cret-token\n", "")})
        monkeypatch.setattr(vaults, "_run", fake)
        vaults.get_entry("secret/hugmesh/studio", "admin_token")
        assert not any("s3cret-token" in " ".join(c) for c in fake.calls)

    def test_it_asks_for_a_bare_field_so_nothing_has_to_parse_the_secret(self, monkeypatch):
        self._available(monkeypatch)
        fake = FakeRun({"kv get": (0, "t\n", "")})
        monkeypatch.setattr(vaults, "_run", fake)
        vaults.get_entry("secret/hugmesh/studio", "admin_token")
        assert any("-field=admin_token" in " ".join(c) for c in fake.calls)

    def test_a_missing_key_is_reported_with_a_remedy_not_an_empty_string(self, monkeypatch):
        self._available(monkeypatch)
        monkeypatch.setattr(vaults, "_run", FakeRun({"kv get": (0, "", "")}))
        value, cap = vaults.get_entry("secret/hugmesh/studio", "admin_token")
        assert value is None
        assert not cap.available
        assert "vault kv put" in cap.remedy

    def test_a_failed_read_carries_the_reason_and_never_the_payload(self, monkeypatch):
        self._available(monkeypatch)
        monkeypatch.setattr(vaults, "_run",
                            FakeRun({"kv get": (1, "s3cret-token", "permission denied")}))
        value, cap = vaults.get_entry("secret/hugmesh/studio", "admin_token")
        assert value is None
        assert "permission denied" in cap.detail
        assert "s3cret-token" not in cap.detail
        assert "s3cret-token" not in cap.remedy

    def test_an_unavailable_vault_short_circuits_without_running_anything(self, monkeypatch):
        # The docker-lane case: no vault container. It must not shell out and must hand
        # back vault_capability's own remedy rather than a bare failure.
        monkeypatch.setattr(vaults, "vault_capability",
                            lambda project=vaults.DEFAULT_PROJECT:
                            vaults.Capability(False, detail="Vault is not running on this mesh.",
                                              remedy="Start the DevOps lane."))
        fake = FakeRun({})
        monkeypatch.setattr(vaults, "_run", fake)
        value, cap = vaults.get_entry("secret/hugmesh/studio", "admin_token")
        assert value is None
        assert fake.calls == []
        assert "not running" in cap.detail
