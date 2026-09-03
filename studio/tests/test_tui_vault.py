"""The TUI secrets-store step (issue #224) — VaultScreen, the twin of gui/pages/vault.py.

Qt-free. Pins: the step is in the mesh walk (after system) and absent from the
standalone/cloud walks; every edit goes through config.vault_field_error and a
refusal is an inline status with state unchanged (never a silently-inert command);
clearing the address clears the two paths; Enter keeps the values and continues;
the walk ends in a config the CLI emits the flags from.
"""
from hugmesh_studio.core.config import (
    MODE_SKIPPED_PAGES, VAULT_FIELDS, ImageConfig, vault_field_error)
from hugmesh_studio.core.worklist import load_any
from hugmesh_studio.tui import journey

ADDR = "https://vault.acme.example:8200"


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
def test_sets_the_trio_through_the_shared_rule():
    j = _to_vault()
    j.feed(f"a {ADDR}")
    assert j.status == "" and j.cfg.vault_addr == ADDR
    j.feed("m kv")
    j.feed("p acme/prod")
    assert (j.cfg.vault_kv_mount, j.cfg.vault_base_path) == ("kv", "acme/prod")
    text = "\n".join(j.lines())
    assert ADDR in text and "kv" in text and "acme/prod" in text
    assert "vault.conf" in text


def test_refusals_are_inline_and_leave_state_untouched():
    j = _to_vault()
    j.feed("m kv")                                     # a mount with nowhere to point
    assert j.status == "refused: " + vault_field_error("", "kv", "")
    assert j.cfg.vault_kv_mount == "" and j.slug == "vault"
    j.feed("a http://vault.acme.example")
    assert "https://" in j.status and j.cfg.vault_addr == ""
    j.feed(f"a {ADDR}")
    j.feed("p $(rm -rf /)")
    assert "base path" in j.status and j.cfg.vault_base_path == ""
    j.feed("a")                                        # no value
    assert "needs a value" in j.status and j.cfg.vault_addr == ADDR
    j.feed("zz")
    assert "unrecognised" in j.status


def test_clearing_the_address_clears_the_two_paths():
    j = _to_vault()
    j.feed(f"a {ADDR}")
    j.feed("m kv")
    j.feed("p acme")
    j.feed("a -")
    assert all(getattr(j.cfg, f) == "" for f in VAULT_FIELDS)
    j.feed(f"a {ADDR}")
    j.feed("m kv")
    j.feed("m -")                                      # back to the builder default
    assert j.cfg.vault_kv_mount == "" and j.cfg.vault_addr == ADDR


# ── the walk ends in a config the CLI emits the flags from ──────────────────────────
def test_the_saved_worklist_carries_the_trio_into_every_node_argv(tmp_path):
    j = _to_vault()
    j.feed(f"a {ADDR}")
    j.feed("m kv")
    for _ in range(len(journey.PAGE_ORDER)):
        if j.slug == "build":
            break
        j.feed("n" if j.slug.endswith("_choice") else "")
    assert j.slug == "build"
    path = tmp_path / "mesh.json"
    j.feed(f"s {path}")
    assert "saved to" in j.status
    base, wl = load_any(str(path))
    assert base.vault_addr == ADDR and base.vault_kv_mount == "kv"
    cfgs = [c for _entry, c in wl.materialize() if c.platform in ("x86", "rpi5")]
    assert cfgs, "the default mesh row is an x86/rpi5 node"
    for c in cfgs:
        args = c.to_cli_args()
        assert ("--vault-addr", ADDR) in list(zip(args, args[1:]))
        assert ("--vault-kv-mount", "kv") in list(zip(args, args[1:]))


def test_a_loaded_config_renders_its_values():
    cfg = ImageConfig(mode="mesh", role="omnibus", vault_addr=ADDR, vault_base_path="acme")
    j = journey.Journey(".", cfg=cfg)
    j.goto("vault")
    text = "\n".join(j.lines())
    assert ADDR in text and "acme" in text and "secret (builder default)" in text
