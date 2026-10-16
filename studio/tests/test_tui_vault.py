"""The TUI secrets-store step (issue #224, extended by #335) — VaultScreen, the twin
of gui/pages/vault.py.

Qt-free. Pins: the step is in the mesh walk (after system) and absent from the
standalone/cloud walks; every edit goes through config.vault_field_error and a
refusal is an inline status with state unchanged (never a silently ineffective command);
clearing the internal address clears everything that hangs off it; Enter keeps the
values and continues; the walk ends in a config the CLI emits the flags from.

#335 adds the EXTERNAL address ('x') and the BASE CA list ('c' to add, 'r' to
remove) to this face, through the SAME two predicates the GUI uses — so the two
faces cannot drift into accepting different things. The GUI picks a certificate with
a file dialog and this one takes a typed path; that is the only difference, and it
is why this file drives ca_cert_error with real fixture PEMs.
"""
import pytest
from ca_fixtures import CA_ALT, CA_ROOT, HAVE_CRYPTOGRAPHY
from hugmesh_studio.core.config import (
    MODE_SKIPPED_PAGES, VAULT_FIELDS, ImageConfig, vault_field_error)
from hugmesh_studio.core.worklist import load_any
from hugmesh_studio.tui import journey

ADDR = "https://vault.acme.example:8200"          # INTERNAL — the pre-#335 field
EXT = "https://vault.acme.example.com:8200"      # EXTERNAL (#335) — must differ


def _to_vault() -> journey.Journey:
    j = journey.Journey(".")
    j.feed("")            # -> mode
    j.feed("3")           # mesh -> idp
    j.feed("")            # casdoor -> worklist
    j.feed("1")           # one row
    for _ in range(20):
        if j.slug == "vault":
            return j
        j.feed("n" if j.slug.endswith("_choice") else "")
    raise AssertionError(f"never reached vault (stuck on {j.slug})")


def _visited(j, feeds):
    seen = [j.slug]
    for line in feeds:
        j.feed(line)
        seen.append(j.slug)
    return seen


# ── placement ────────────────────────────────────────────────────────────────────────
def test_the_step_follows_system_identity_in_the_mesh_walk():
    j = _to_vault()
    assert journey.PAGE_ORDER.index("vault") == journey.PAGE_ORDER.index("system") + 1
    assert isinstance(j.screen(), journey.VaultScreen)
    assert "Secrets store" in j.title()


def test_the_standalone_walk_never_visits_it():
    j = journey.Journey(".")
    seen = _visited(j, [""] * 14)
    assert j.done and "vault" not in seen
    assert "vault" in MODE_SKIPPED_PAGES["standalone"]
    assert "vault" in MODE_SKIPPED_PAGES["cloud"]


# ── the offline default ──────────────────────────────────────────────────────────────
def test_enter_keeps_the_offline_default_and_continues():
    j = _to_vault()
    text = "\n".join(j.lines())
    assert "no flag" in text and "brand.conf" in text and "a URL|-" in text
    j.feed("")
    assert j.slug != "vault"
    assert all(getattr(j.cfg, f) == "" for f in VAULT_FIELDS)


# ── edits: the shared rule, inline refusals, state unchanged ────────────────────────
def test_sets_the_pair_through_the_shared_rule():
    j = _to_vault()
    j.feed(f"a {ADDR}")
    assert j.status == "" and j.cfg.vault_addr == ADDR
    j.feed(f"x {EXT}")
    assert (j.cfg.vault_addr, j.cfg.vault_external_addr) == (ADDR, EXT)
    text = "\n".join(j.lines())
    assert ADDR in text and EXT in text
    assert "vault.conf" in text


def test_the_removed_path_commands_are_gone_from_the_vocabulary_and_the_screen():
    """#285, decision 22 on #347: neither the KV mount nor the read prefix is a
    choice -- the mount is pinned by the shipped ClusterSecretStore and the
    ExternalSecrets read the literal hugmesh/<service> -- so 'm' and 'p' were
    removed with the fields and the two builder flags.
    A dropped command must be UNRECOGNISED, never silently ineffective — the TUI's own
    rule — and the screen must say why rather than going quiet about it."""
    j = _to_vault()
    j.feed(f"a {ADDR}")
    for line in ("m kv", "p acme/prod"):
        j.feed(line)
        assert "unrecognised" in j.status, line
        assert "a/x set a value" in j.status
    assert "m" not in journey.VAULT_COMMANDS and "p" not in journey.VAULT_COMMANDS
    assert not hasattr(j.cfg, "vault_kv_mount")
    assert not hasattr(j.cfg, "vault_base_path")
    text = "\n".join(j.lines())
    assert "hugmesh/<service>" in text                 # the design, stated
    assert "m NAME" not in text and "p PATH" not in text


def test_refusals_are_inline_and_leave_state_untouched():
    j = _to_vault()
    j.feed(f"x {EXT}")                                 # an external addr with nowhere to point
    assert j.status == "refused: " + vault_field_error("", EXT)
    assert j.cfg.vault_external_addr == "" and j.slug == "vault"
    j.feed("a http://vault.acme.example")
    assert "https://" in j.status and j.cfg.vault_addr == ""
    j.feed(f"a {ADDR}")
    j.feed("x $(rm -rf /)")
    assert "external Vault address" in j.status and j.cfg.vault_external_addr == ""
    j.feed("a")                                        # no value
    assert "needs a value" in j.status and j.cfg.vault_addr == ADDR
    j.feed("zz")
    assert "unrecognised" in j.status


def test_clearing_the_address_clears_everything_that_hangs_off_it():
    j = _to_vault()
    j.feed(f"a {ADDR}")
    j.feed(f"x {EXT}")
    j.feed("a -")
    assert all(getattr(j.cfg, f) == "" for f in VAULT_FIELDS)
    j.feed(f"a {ADDR}")
    j.feed(f"x {EXT}")
    j.feed("x -")                                      # clear just the external one
    assert j.cfg.vault_external_addr == "" and j.cfg.vault_addr == ADDR


# ── the walk ends in a config the CLI emits the flags from ──────────────────────────
def test_the_saved_worklist_carries_the_pair_into_every_node_argv(tmp_path):
    j = _to_vault()
    j.feed(f"a {ADDR}")
    j.feed(f"x {EXT}")
    for _ in range(len(journey.PAGE_ORDER)):
        if j.slug == "build":
            break
        j.feed("n" if j.slug.endswith("_choice") else "")
    assert j.slug == "build"
    path = tmp_path / "mesh.json"
    j.feed(f"s {path}")
    assert "saved to" in j.status
    base, wl = load_any(str(path))
    assert base.vault_addr == ADDR and base.vault_external_addr == EXT
    cfgs = [c for _entry, c in wl.materialize() if c.platform in ("x86", "rpi5")]
    assert cfgs, "the default mesh row is an x86/rpi5 node"
    for c in cfgs:
        args = c.to_cli_args()
        assert ("--vault-addr", ADDR) in list(zip(args, args[1:]))
        assert ("--vault-external-addr", EXT) in list(zip(args, args[1:]))
        assert "--vault-kv-mount" not in args and "--vault-base-path" not in args


def test_a_loaded_config_renders_its_values():
    cfg = ImageConfig(mode="mesh", role="omnibus", vault_addr=ADDR,
                      vault_external_addr=EXT)
    j = journey.Journey(".", cfg=cfg)
    j.goto("vault")
    text = "\n".join(j.lines())
    assert ADDR in text and EXT in text
    # where the cluster reads is STATED, not offered as a value to edit (#285), and
    # it is stated as the LITERAL prefix the ExternalSecrets carry — not as a
    # brand-derived path, which is what the landing review measured as false.
    assert "hugmesh/<service>" in text


# ── the external address (#335), through the same shared rule ───────────────────────
def test_the_external_address_is_its_own_command_in_VAULT_FIELDS_order():
    """VAULT_COMMANDS is asserted == VAULT_FIELDS at import time, which is what stops
    a field landing on one face only. Pin the vocabulary itself so a future field is
    a deliberate change to both faces rather than a rename that silently passes."""
    assert journey.VAULT_COMMANDS == {
        "a": "vault_addr", "x": "vault_external_addr"}
    assert tuple(journey.VAULT_COMMANDS.values()) == VAULT_FIELDS


def test_sets_the_external_address_and_shows_it():
    j = _to_vault()
    j.feed(f"a {ADDR}")
    j.feed(f"x {EXT}")
    assert j.status == "" and j.cfg.vault_external_addr == EXT
    text = "\n".join(j.lines())
    assert EXT in text and "internal" in text and "external" in text
    assert "no reader at all" in text            # the honest limit, on the surface


def test_the_external_address_refusals_match_the_gui():
    j = _to_vault()
    j.feed(f"x {EXT}")                            # no internal address yet
    assert j.status == "refused: " + vault_field_error("", EXT)
    assert "no Vault address" in j.status and j.cfg.vault_external_addr == ""
    j.feed(f"a {ADDR}")
    j.feed("x http://ext.acme.example")
    assert "https://" in j.status and j.cfg.vault_external_addr == ""
    j.feed(f"x {ADDR}")                           # identical to the internal one
    assert "same as the internal" in j.status and j.cfg.vault_external_addr == ""
    j.feed(f"x {EXT}")
    assert j.cfg.vault_external_addr == EXT
    j.feed("x -")                                 # and it clears on its own
    assert j.cfg.vault_external_addr == "" and j.cfg.vault_addr == ADDR


def test_the_external_address_reaches_every_node_argv(tmp_path):
    j = _to_vault()
    j.feed(f"a {ADDR}")
    j.feed(f"x {EXT}")
    for _ in range(len(journey.PAGE_ORDER)):
        if j.slug == "build":
            break
        j.feed("n" if j.slug.endswith("_choice") else "")
    path = tmp_path / "mesh.json"
    j.feed(f"s {path}")
    base, wl = load_any(str(path))
    assert base.vault_external_addr == EXT
    cfgs = [c for _e, c in wl.materialize() if c.platform in ("x86", "rpi5")]
    assert cfgs
    for c in cfgs:
        args = c.to_cli_args()
        assert ("--vault-external-addr", EXT) in list(zip(args, args[1:]))


# ── the base CA list (#335): typed paths, the same predicate as the GUI picker ──────
@pytest.mark.skipif(not HAVE_CRYPTOGRAPHY,
                    reason="subject/expiry need python-cryptography (optional dependency)")
def test_adding_a_certificate_records_it_and_reports_subject_and_expiry():
    j = _to_vault()
    j.feed(f"c {CA_ROOT}")
    assert j.cfg.base_ca_certs == [CA_ROOT]
    assert "added ca-root.pem" in j.status
    assert "HugMesh Studio Test Root CA" in j.status and "expires 2126" in j.status
    text = "\n".join(j.lines())
    assert "ca-root.pem" in text
    assert "RECORDED ONLY" in text               # the honest label, on the surface


def test_a_file_that_is_not_a_certificate_is_refused_inline(tmp_path):
    junk = tmp_path / "notes.txt"
    junk.write_text("not a certificate\n", encoding="utf-8")
    j = _to_vault()
    j.feed(f"c {junk}")
    assert j.cfg.base_ca_certs == [] and j.status.startswith("refused:")
    assert "BEGIN CERTIFICATE" in j.status
    j.feed("c /nowhere/absent.pem")
    assert j.cfg.base_ca_certs == [] and "not a readable file" in j.status
    j.feed("c")
    assert "needs the path" in j.status


def test_the_same_certificate_cannot_be_added_twice():
    j = _to_vault()
    j.feed(f"c {CA_ROOT}")
    j.feed(f"c {CA_ROOT}")
    assert j.cfg.base_ca_certs == [CA_ROOT] and "already listed" in j.status


def test_removing_a_certificate_clears_the_domains_that_picked_it():
    """The same repair the GUI does on commit: a domain may not name a CA the config
    no longer carries, so the drop clears it — and SAYS which domains it cleared."""
    j = _to_vault()
    j.feed(f"c {CA_ROOT}")
    j.feed(f"c {CA_ALT}")
    j.cfg.domain_ca = {"a.example": CA_ROOT, "b.example": CA_ALT}
    j.feed("r 1")
    assert j.cfg.base_ca_certs == [CA_ALT]
    assert j.cfg.domain_ca == {"b.example": CA_ALT}
    assert "removed ca-root.pem" in j.status and "a.example" in j.status
    j.cfg.validate_identity()                    # a stranded choice raises here
    j.feed("r 9")
    assert "no such certificate row" in j.status and j.cfg.base_ca_certs == [CA_ALT]
    j.feed("r nope")
    assert "no such certificate row" in j.status


def test_the_pointer_to_the_domains_step_names_a_command_that_exists():
    """The Vault screen tells the operator where to PICK a certificate. It used to
    name a 'c' command on the Domains step; 'c' there is unrecognised — the per-domain
    picker is 'b NUMBER CERT'. A cross-reference to a command that does not exist is
    the same defect class as a knob that does nothing, so it is pinned against the
    Domains step's OWN command list rather than against a copy of the string."""
    from hugmesh_studio.tui import domains_step               # noqa: PLC0415
    j = _to_vault()
    j.feed(f"c {CA_ROOT}")
    line = [ln for ln in j.lines() if "no domain has picked one yet" in ln]
    assert line, "the unpicked hint should be on the screen"
    assert "'c' command" not in line[0]
    assert "b NUMBER CERT" in line[0]
    # and that verb really is the Domains step's, read from its own source
    src = open(domains_step.__file__, encoding="utf-8").read()
    assert "b NUMBER CERT|-=set its base CA" in src


def test_the_ca_list_emits_nothing():
    j = _to_vault()
    before = j.cfg.to_cli_args()
    j.feed(f"c {CA_ROOT}")
    assert j.cfg.base_ca_certs == [CA_ROOT]
    assert j.cfg.to_cli_args() == before


def test_the_empty_step_still_names_the_two_new_commands():
    j = _to_vault()
    text = "\n".join(j.lines())
    for fragment in ("x URL|-", "c PATH", "r NUMBER", "base CA certificates:",
                     "(none)"):
        assert fragment in text, fragment
    j.feed("zz")
    assert "c/r edit the base CA list" in j.status
