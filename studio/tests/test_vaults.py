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


def _quiet_probe(monkeypatch, volumes=(), listing=None):
    """Make the dialog's REAL background probe harmless: it runs the moment the dialog
    is built, and must never reach docker, kubectl or a cluster from a test."""
    monkeypatch.setattr(vaults, "list_volumes", lambda *a, **k: list(volumes))
    monkeypatch.setattr(vaults, "docker_available", lambda: Capability(True))
    cap = Capability(False, "no vault", "start the lane")
    monkeypatch.setattr(vaults, "vault_route",
                        lambda *a, **k: vaults.VaultRoute("", cap))
    monkeypatch.setattr(vaults, "list_entries",
                        lambda *a, **k: listing if listing is not None else ([], cap))


def _settle(qapp, d):
    """Let the construction-time probe finish and deliver, so it cannot overwrite the
    state a test then renders by hand."""
    probe = getattr(d, "_probe", None)
    if probe is not None:
        probe.wait(5000)
    qapp.processEvents()


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
        _quiet_probe(monkeypatch, volumes)
        d = VaultsDialog(project="hugmesh-local")
        _settle(qapp, d)
        d._on_probe((volumes, ([], Capability(False, "no vault", "start the lane")),
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
        # back the route's own remedy rather than a bare failure.
        monkeypatch.setattr(vaults, "vault_route",
                            lambda project=vaults.DEFAULT_PROJECT: vaults.VaultRoute(
                                "", vaults.Capability(
                                    False, detail="Vault is not running on this mesh.",
                                    remedy="Start the DevOps lane.")))
        fake = FakeRun({})
        monkeypatch.setattr(vaults, "_run", fake)
        value, cap = vaults.get_entry("secret/hugmesh/studio", "admin_token")
        assert value is None
        assert fake.calls == []
        assert "not running" in cap.detail


# ── the kind lane's Vault (2026-10-21: "the vaults can never be viewed") ─────────────
#
# Before this, vault_capability only asked `docker ps` and $VAULT_ADDR, so with the kind
# lane up — the only place Vault runs — the tab still said "not running on this mesh",
# and even past that every read ran a host `vault` binary this host does not have.
# These tests drive the kind route from RECORDED kubectl answers (tests/fixtures/
# vaults_kind/README.md says which were recorded live and which are hand-built).

import base64  # noqa: E402
import pathlib  # noqa: E402

_FX = pathlib.Path(__file__).parent / "fixtures" / "vaults_kind"
_TOKEN = "hvs.FIXTURE-not-a-real-token"


def _fx(name: str) -> str:
    return (_FX / name).read_text()


def _kind_table(*, lane_up=True, replicas="1", halt=None, pod=None, pod_err="",
                secret_rc=0, sts_err="", kv=None):
    """argv-fragment -> (rc, stdout, stderr). Order matters: FakeRun takes the first
    fragment found, so the specific kv-list paths come before the shorter ones."""
    t: dict[str, tuple[int, str, str]] = {}
    for frag, ans in (kv or {}).items():
        t[frag] = ans
    t["label=com.docker.compose.project"] = (0, "", "")          # no compose vault
    t["name=^hugmesh-local-control-plane$"] = (
        0, "hugmesh-local-control-plane\n" if lane_up else "", "")
    t["get statefulset vault"] = (1, "", sts_err) if sts_err else (0, replicas, "")
    t["get configmap hugmesh-kind-halt"] = (
        (0, halt, "") if halt is not None
        else (1, "", 'Error from server (NotFound): configmaps "hugmesh-kind-halt" not found'))
    if pod is not None:
        t["get pod vault-0"] = (0, pod, "")
    else:
        t["get pod vault-0"] = (1, "", pod_err or _fx("pod-vault-0-notfound.stderr"))
    t["get secret vault-bootstrap"] = (
        (0, base64.b64encode(_TOKEN.encode()).decode(), "") if secret_rc == 0
        else (1, "", 'Error from server (Forbidden): secrets "vault-bootstrap" is forbidden'))
    return t


@pytest.fixture
def kind_env(monkeypatch):
    for v in ("VAULT_ADDR", "VAULT_TOKEN", "KIND_CLUSTER_NAME"):
        monkeypatch.delenv(v, raising=False)
    monkeypatch.setattr(vaults, "_kubectl_path", lambda: "/fake/kubectl")

    def install(**kw):
        fake = FakeRun(_kind_table(**kw))
        monkeypatch.setattr(vaults, "_run", fake)
        return fake
    return install


def _secret_reads(fake):
    return [c for c in fake.calls if "secret" in c and "vault-bootstrap" in c]


class TestKindLaneVault:
    def test_a_HALTED_lane_says_halted_since_when_and_how_to_resume(self, kind_env):
        """The live state on 2026-10-21: lane up, kind-halt.sh had scaled vault to 0."""
        fake = kind_env(replicas=_fx("sts-replicas-halted.txt"),
                        halt=_fx("halt-record-completed.json"))
        cap = vaults.vault_capability()
        assert cap.available is False
        assert "HALTED" in cap.detail and "2026-10-21T09:22:04Z" in cap.detail
        assert "vault-0 does not exist" in cap.detail
        assert "Resume DevOps lane" in cap.remedy and "kind-resume" in cap.remedy
        assert not _secret_reads(fake), "a halted lane must not have its token read"

    def test_an_interrupted_halt_is_named_as_interrupted(self, kind_env):
        kind_env(replicas="0", halt='{"completed": false, "halted_at": "2026-10-21T01:00:00Z"}')
        cap = vaults.vault_capability()
        assert "interrupted" in cap.detail

    def test_scaled_to_zero_without_a_halt_record_says_NOT_by_the_halt(self, kind_env):
        kind_env(replicas="0", halt=None)
        cap = vaults.vault_capability()
        assert cap.available is False
        assert "NOT by the halt control" in cap.detail

    def test_lane_not_up_says_so_with_the_start_remedy(self, kind_env):
        fake = kind_env(lane_up=False)
        cap = vaults.vault_capability()
        assert cap.available is False
        assert "not up" in cap.detail and "hugmesh-local-control-plane" in cap.detail
        assert "Start DevOps lane" in cap.remedy
        assert not any("/fake/kubectl" in c for c in fake.calls), \
            "with no cluster there is nothing for kubectl to ask"

    def test_KIND_CLUSTER_NAME_override_is_the_cluster_asked_about(self, kind_env, monkeypatch):
        monkeypatch.setenv("KIND_CLUSTER_NAME", "other")
        fake = kind_env(lane_up=False)
        vaults.vault_capability()
        assert any("name=^other-control-plane$" in " ".join(c) for c in fake.calls)

    def test_a_dead_api_server_is_not_reported_as_no_vault(self, kind_env):
        kind_env(sts_err="Unable to connect to the server: dial tcp 127.0.0.1:41721: "
                         "connect: connection refused")
        cap = vaults.vault_capability()
        assert "did not answer" in cap.detail and "connection refused" in cap.detail

    def test_vault_not_deployed(self, kind_env):
        kind_env(sts_err='Error from server (NotFound): statefulsets.apps "vault" not found')
        cap = vaults.vault_capability()
        assert "not deployed" in cap.detail
        assert "application vault" in cap.remedy

    def test_a_SEALED_vault_says_sealed_and_never_reads_the_token(self, kind_env):
        fake = kind_env(pod=_fx("pod-vault-0-sealed.json"))
        cap = vaults.vault_capability()
        assert cap.available is False
        assert "sealed" in cap.detail
        assert "vault-unseal" in cap.remedy
        assert not _secret_reads(fake)

    def test_a_crash_looping_vault_names_the_reason(self, kind_env):
        kind_env(pod=_fx("pod-vault-0-crashloop.json"))
        cap = vaults.vault_capability()
        assert "CrashLoopBackOff" in cap.detail

    def test_an_unreadable_token_secret_names_the_secret_and_not_its_bytes(self, kind_env):
        kind_env(pod=_fx("pod-vault-0-ready.json"), secret_rc=1)
        cap = vaults.vault_capability()
        assert cap.available is False
        assert "vault/vault-bootstrap" in cap.detail and "Forbidden" in cap.detail

    def test_every_cluster_call_is_a_read(self, kind_env):
        """Never write to the cluster while probing: get only (exec is the listing)."""
        fake = kind_env(pod=_fx("pod-vault-0-ready.json"))
        vaults.vault_capability()
        verbs = [c[c.index("-n") + 2] for c in fake.calls if c[0] == "/fake/kubectl"]
        assert verbs and set(verbs) == {"get"}, verbs
        assert all("--context" in c and "kind-hugmesh-local" in c
                   for c in fake.calls if c[0] == "/fake/kubectl")


def _ready_with_kv(kind_env, kv):
    return kind_env(pod=_fx("pod-vault-0-ready.json"), kv=kv)


_KV_TREE = {
    "kv list -format=json secret/hugmesh/db": (0, _fx("kv-list-secret-hugmesh-db.json"), ""),
    "kv list -format=json secret/hugmesh": (0, _fx("kv-list-secret-hugmesh.json"), ""),
    "kv list -format=json secret": (0, _fx("kv-list-secret.json"), ""),
}


class TestKindLaneListing:
    def test_a_running_lane_LISTS_its_entries_recursively(self, kind_env):
        """THE regression: with vault-0 up and unsealed the tab must show entries."""
        _ready_with_kv(kind_env, _KV_TREE)
        entries, cap = vaults.list_entries()
        assert cap.available is True, cap
        assert [e.path for e in entries] == [
            "secret/hugmesh/casdoor", "secret/hugmesh/db/admin-bff",
            "secret/hugmesh/db/forum-bff", "secret/hugmesh/matrix"]
        assert "vault-0 on kind-hugmesh-local" in cap.detail

    def test_listing_goes_through_kubectl_exec_into_vault_0_not_a_host_vault(self, kind_env):
        fake = _ready_with_kv(kind_env, _KV_TREE)
        vaults.list_entries()
        execs = [c for c in fake.calls if "exec" in c]
        assert execs, "the kind route must exec into vault-0"
        for c in execs:
            assert c[:4] == ["/fake/kubectl", "--context", "kind-hugmesh-local", "-n"]
            assert ["exec", "-i", "vault-0", "-c", "vault"] == c[5:10]
        assert not any(c[0] == "vault" for c in fake.calls), "no host vault CLI on kind"

    def test_the_TOKEN_never_appears_in_any_argv(self, kind_env):
        """argv is world-readable via /proc; the earlier exec pattern put
        VAULT_TOKEN=<token> right in kubectl's argv."""
        fake = _ready_with_kv(kind_env, {**_KV_TREE, "kv get": (0, "v\n", ""),
                                         "kv put": (0, "", "")})
        vaults.list_entries()
        vaults.get_entry("secret/hugmesh/casdoor", "admin_password_plain")
        vaults.put_entry("secret/hugmesh/studio", "k", "the-written-value")
        assert fake.calls
        for c in fake.calls:
            assert not any(_TOKEN in a for a in c), f"token leaked into argv: {c}"
            assert not any("the-written-value" in a for a in c)

    def test_token_is_the_first_stdin_line_and_a_written_value_follows_it(self, kind_env):
        fake = _ready_with_kv(kind_env, {"kv put": (0, "", "")})
        vaults.put_entry("secret/hugmesh/studio", "k", "the-written-value")
        assert fake.last_stdin == _TOKEN + "\n" + "the-written-value"
        put = next(c for c in fake.calls if "put" in c)
        assert put[-3:] == ["put", "secret/hugmesh/studio", "k=-"]

    def test_the_in_pod_shell_never_interpolates_the_path(self, kind_env):
        """The path rides as a positional ("$@"), so a hostile path cannot run shell."""
        fake = _ready_with_kv(kind_env, {"kv list": (0, "[]", "")})
        vaults.list_entries(path="x;rm -rf ~")
        ex = next(c for c in fake.calls if "exec" in c)
        sh = ex[ex.index("-c", 10) + 1]
        assert sh == vaults._EXEC_SH and "$@" in sh and "secret" not in sh
        assert ex[-1] == "secret/x;rm -rf ~"

    def test_an_EMPTY_vault_is_available_with_no_entries_not_an_error(self, kind_env):
        """vault 1.21.4 with -format=json: rc 2, `{}` on stdout, nothing on stderr."""
        _ready_with_kv(kind_env, {"kv list": (2, _fx("kv-list-empty-json.stdout"), "")})
        entries, cap = vaults.list_entries()
        assert entries == [] and cap.available is True

    def test_an_empty_vault_in_table_format_is_also_empty(self, kind_env):
        _ready_with_kv(kind_env, {"kv list": (2, "", _fx("kv-list-empty.stderr"))})
        entries, cap = vaults.list_entries()
        assert entries == [] and cap.available is True

    def test_a_rejected_token_names_the_http_code_and_reason(self, kind_env):
        _ready_with_kv(kind_env, {"kv list": (2, "", _fx("kv-list-403.stderr"))})
        entries, cap = vaults.list_entries()
        assert cap.available is False
        assert "HTTP 403" in cap.detail and "invalid token" in cap.detail

    def test_a_failed_root_listing_is_a_reason_not_an_empty_list(self, kind_env):
        _ready_with_kv(kind_env, {"kv list": (2, "", "Error listing secret/metadata: "
                                                    "permission denied")})
        entries, cap = vaults.list_entries()
        assert entries == [] and cap.available is False
        assert "permission denied" in cap.detail

    def test_a_runaway_tree_stops_and_SAYS_it_stopped(self, kind_env, monkeypatch):
        monkeypatch.setattr(vaults, "MAX_LIST_CALLS", 2)
        _ready_with_kv(kind_env, {"kv list": (0, '["a/", "b/", "leaf"]', "")})
        entries, cap = vaults.list_entries()
        assert cap.available is True
        assert "NOT everything was listed" in cap.detail

    def test_get_entry_reads_through_the_same_kind_route(self, kind_env):
        fake = _ready_with_kv(kind_env, {"kv get": (0, "the-value\n", "")})
        value, cap = vaults.get_entry("secret/hugmesh/casdoor", "admin_password_plain")
        assert value == "the-value" and cap.available
        g = next(c for c in fake.calls if "get" in c and "exec" in c)
        assert g[-3:] == ["get", "-field=admin_password_plain", "secret/hugmesh/casdoor"]


class TestDialogShowsKindVault:
    """The dialog half: entries fetched OFF the GUI thread, rendered as a visible list;
    a blocked vault rendered as a visible, readable reason."""

    def test_render_never_lists_on_the_gui_thread(self, qapp, monkeypatch):
        _quiet_probe(monkeypatch)
        d = VaultsDialog(project="hugmesh-local")
        _settle(qapp, d)

        def boom(*a, **k):
            raise AssertionError("list_entries ran on the GUI thread")
        monkeypatch.setattr(vaults, "list_entries", boom)
        monkeypatch.setattr(vaults, "vault_route", boom)
        entries = [vaults.VaultEntry("secret/hugmesh/casdoor"),
                   vaults.VaultEntry("secret/hugmesh/matrix")]
        d._on_probe(([], (entries, Capability(True, "vault-0 on kind-hugmesh-local")),
                     Capability(True)))
        lst = d.vault_page.findChild(QtWidgets.QListWidget, "vaultEntries")
        assert lst is not None
        assert [lst.item(i).text() for i in range(lst.count())] == [
            "secret/hugmesh/casdoor", "secret/hugmesh/matrix"]

    def test_the_probe_carries_the_entries_it_listed(self, qapp, monkeypatch):
        """_VaultsProbe.run() is where the listing happens — run it synchronously."""
        from hugmesh_studio.gui.vaults_dialog import _VaultsProbe
        entries = [vaults.VaultEntry("secret/hugmesh/casdoor")]
        _quiet_probe(monkeypatch, listing=(entries, Capability(True, "ok")))
        probe = _VaultsProbe("hugmesh-local")
        got = []
        probe.result.connect(got.append)
        probe.run()
        vols, (ents, cap), _docker = got[0]
        assert ents == entries and cap.available

    def test_entries_list_is_visible_enabled_and_a_sane_size(self, qapp, monkeypatch):
        _quiet_probe(monkeypatch)
        d = VaultsDialog(project="hugmesh-local")
        _settle(qapp, d)
        entries = [vaults.VaultEntry(f"secret/hugmesh/e{i}") for i in range(5)]
        d._on_probe(([], (entries, Capability(True, "vault-0 on kind-hugmesh-local")),
                     Capability(True)))
        d.show()
        d.tabs.setCurrentWidget(d.vault_page)
        qapp.processEvents()
        lst = d.vault_page.findChild(QtWidgets.QListWidget, "vaultEntries")
        summary = d.vault_page.findChild(QtWidgets.QLabel, "vaultSummary")
        try:
            for w in (lst, summary):
                assert w.isVisible() and w.isEnabled()
                assert w.width() >= 300, w.width()
            assert lst.height() >= 150, lst.height()
            assert "5 entry path(s)" in summary.text()
        finally:
            d.close()

    def test_blocked_vault_reason_is_visible_and_readable(self, qapp, monkeypatch):
        _quiet_probe(monkeypatch)
        d = VaultsDialog(project="hugmesh-local")
        _settle(qapp, d)
        cap = Capability(False, "Vault is not running: the DevOps lane is HALTED",
                         "Press 'Resume DevOps lane'")
        d._on_probe(([], ([], cap), Capability(True)))
        d.show()
        d.tabs.setCurrentWidget(d.vault_page)
        qapp.processEvents()
        lab = d.vault_page.findChild(QtWidgets.QLabel, "vaultBlocker")
        try:
            assert lab.isVisible() and lab.width() >= 300 and lab.height() >= 30
            assert "HALTED" in lab.text() and "Resume DevOps lane" in lab.text()
            assert not d.vault_page.findChildren(QtWidgets.QListWidget)
        finally:
            d.close()
