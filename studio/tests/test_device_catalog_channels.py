"""Device catalog: every row reachable and labelled the same in the text UI and the CLI.

hugmesh-generator#1058 (lane R1 of the platform expansion, #1045). The text UI's
single-image step browses the catalog — architecture, then family, then device —
and ``python -m hugmesh_studio --list-devices`` lists it. The GUI twin of both is
RolePage's device tree; its half of the parity lives in
test_device_catalog_channels_gui.py (Qt-present), because this file must run on the
Qt-free CI job.

Everything is drawn from ``device-catalog.json`` itself, read RAW here (json.load,
not the accessor module), so:

* no device id, count or family is written into a test — a catalog edit (a row
  added, a row removed) changes what is checked, never whether it passes;
* the numbers a scripted session types are worked out from the raw file's own order,
  not from the browse code under test, so a browse that drops or reorders rows
  lands on the wrong row and fails;
* a refused row's reason is matched VERBATIM against the raw file.

The text-UI proof is scripted plain-face sessions (``plain.run_journey`` with a
scripted stdin), plus the journey state machine both faces drive.
"""
import io
import json

import pytest

from hugmesh_studio import app
from hugmesh_studio.core import device_catalog
from hugmesh_studio.core.config import ROLE_CHOICES
from hugmesh_studio.tui import journey, plain

#: The single-image paths: the ones whose wizard step is the device browser. Mesh
#: builds pick role x platform on the worklist step instead (not this lane).
SINGLE_IMAGE_MODES = ("standalone", "cloud")

with open(device_catalog.CATALOG_PATH, encoding="utf-8") as _fh:
    RAW = json.load(_fh)
RAW_DEVICES = RAW["devices"]
RAW_BY_ID = {d["id"]: d for d in RAW_DEVICES}


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


# ── the browse path, worked out from the RAW file's order ───────────────────────────
def _raw_path(device_id: str) -> tuple[int, int, int]:
    """(arch number, family number, device number) — 1-based, as a person types them —
    for ``device_id``, from the raw JSON alone: archs in file order that carry a device,
    families in file order that carry a device on that arch, devices in file order."""
    dev = RAW_BY_ID[device_id]
    archs = [a["id"] for a in RAW["archs"]
             if any(d["arch"] == a["id"] for d in RAW_DEVICES)]
    fams = [f["id"] for f in RAW["families"]
            if any(d["family"] == f["id"] and d["arch"] == dev["arch"]
                   for d in RAW_DEVICES)]
    rows = [d["id"] for d in RAW_DEVICES
            if d["family"] == dev["family"] and d["arch"] == dev["arch"]]
    return (archs.index(dev["arch"]) + 1, fams.index(dev["family"]) + 1,
            rows.index(device_id) + 1)


def _expected_pickable(device_id: str, mode: str) -> bool:
    """Refused = UNSUPPORTED in the raw file, or no image type on this path."""
    return (RAW_BY_ID[device_id]["status"] != "unsupported"
            and bool(device_catalog.roles_for(device_id, mode)))


def _to_role_step(mode: str) -> journey.Journey:
    j = journey.Journey(".")
    j.feed("")                                          # welcome -> mode menu
    j.feed(str([m for m, _t, _d in journey.MODE_CHOICES].index(mode) + 1))
    for _ in range(len(journey.PAGE_ORDER)):
        if j.slug == "role":
            break
        j.feed("")
    assert j.slug == "role"
    return j


def _enters_to_role_step(mode: str) -> list[str]:
    """The scripted lines that walk a fresh plain session to the role step."""
    j = journey.Journey(".")
    lines = ["", str([m for m, _t, _d in journey.MODE_CHOICES].index(mode) + 1)]
    for line in lines:
        j.feed(line)
    while j.slug != "role":
        j.feed("")
        lines.append("")
    return lines


def _browse_to(j: journey.Journey, device_id: str) -> None:
    a, f, n = _raw_path(device_id)
    for line in ("d", str(a), str(f), str(n)):
        j.feed(line)


def _cli(capsys, *argv) -> str:
    assert app.main(["--list-devices", *argv]) == 0
    return capsys.readouterr().out


# ── the CLI: --list-devices ─────────────────────────────────────────────────────────
@pytest.mark.parametrize("mode", tuple(ROLE_CHOICES))
def test_list_devices_json_has_every_raw_row_exactly_once(capsys, mode):
    doc = json.loads(_cli(capsys, "--json", "--mode", mode))
    assert doc["mode"] == mode and doc["catalog"] == RAW["schema"]
    assert doc["schema"] == device_catalog.LIST_SCHEMA
    ids = [d["id"] for d in doc["devices"]]
    assert sorted(ids) == sorted(RAW_BY_ID)            # every row, none invented
    assert len(ids) == len(set(ids))                    # each exactly once
    for row in doc["devices"]:
        raw = RAW_BY_ID[row["id"]]
        assert row["label"] == raw["label"] and row["soc"] == raw["soc"]
        assert row["arch"] == raw["arch"] and row["family"] == raw["family"]
        assert row["status"] == raw["status"]
        assert row["pickable"] is _expected_pickable(row["id"], mode), row["id"]
        if raw["status"] == "unsupported":
            # the refusal carries the raw reason, verbatim, in the label and the sentence
            assert raw["reason"] and raw["reason"] in row["status_text"], row["id"]
            assert raw["reason"] in row["refusal"], row["id"]
            assert row["roles"] == [] and row["platform"] is None
            assert row["board_axis"] == "no builder"
        else:
            assert row["platform"] == raw["builder"]["platform"]
            assert row["board"] == raw["builder"].get("board", "")
            assert f"--platform {row['platform']}" in row["board_axis"]
            if row["board"]:
                assert f"--board {row['board']}" in row["board_axis"]
        if raw["status"] == "experimental":
            assert device_catalog.EXPERIMENTAL_CAVEAT in row["detail"], row["id"]
            if row["pickable"]:
                assert row["status_text"] == device_catalog.EXPERIMENTAL_CAVEAT
        if not row["pickable"]:
            assert row["refusal"], row["id"]
        else:
            assert row["refusal"] == "" and row["roles"], row["id"]


@pytest.mark.parametrize("mode", tuple(ROLE_CHOICES))
def test_list_devices_text_names_every_row_with_its_words(capsys, mode):
    out = _cli(capsys, "--mode", mode)
    doc = device_catalog.list_devices_json(mode)
    for row in doc["devices"]:
        assert f"[{row['id']}]" in out, row["id"]
        assert f"{row['label']} — {row['soc']}" in out, row["id"]
        assert f"builds as: {row['board_axis']}" in out, row["id"]
        if row["status_text"]:
            assert f"status: {row['status_text']}" in out, row["id"]
        raw = RAW_BY_ID[row["id"]]
        if raw["status"] == "unsupported":
            assert raw["reason"] in out, row["id"]
    for arch in RAW["archs"]:
        if any(d["arch"] == arch["id"] for d in RAW_DEVICES):
            assert arch["label"] in out                # an all-refused arch is listed too


def test_list_devices_defaults_to_the_standalone_path(capsys):
    assert _cli(capsys) == _cli(capsys, "--mode", "standalone")


# ── the text UI: arch -> family -> device ───────────────────────────────────────────
@pytest.mark.parametrize("mode", SINGLE_IMAGE_MODES)
def test_every_catalog_row_is_reachable_in_the_text_ui(mode):
    """Each raw row, reached by the numbers its place in the raw file gives, shows on
    the device screen with the CLI's words for it, and the pick does what the gate
    says: a pickable row becomes the target device, a refused one prints its refusal
    and leaves the step on the same device screen."""
    doc = {d["id"]: d for d in device_catalog.list_devices_json(mode)["devices"]}
    for did, raw in RAW_BY_ID.items():
        j = _to_role_step(mode)
        a, f, n = _raw_path(did)
        for line in ("d", str(a), str(f)):
            j.feed(line)
        screen = "\n".join(j.lines())
        row = doc[did]
        number = f"{n:2d}. {raw['label']} — {raw['soc']}"
        assert number in screen, (did, screen)
        if row["status_text"]:
            assert f"status: {row['status_text']}" in screen, did
        assert f"builds as: {row['board_axis']}" in screen, did
        j.feed(str(n))
        if _expected_pickable(did, mode):
            assert j.status == f"device: {raw['label']} ({row['board_axis']})", did
            assert j.screen().view == "roles"
            assert f"{raw['label']} — {raw['soc']}" in "\n".join(j.lines())
        else:
            assert j.status == f"refused: {row['refusal']}", did
            assert j.screen().view == "device"
            if raw["status"] == "unsupported":
                assert raw["reason"] in j.status, did


@pytest.mark.parametrize("mode", SINGLE_IMAGE_MODES)
def test_a_refused_row_cannot_be_selected_in_the_text_ui(mode):
    """Picking a refused row writes nothing: the config keeps the device committed
    before it, and Enter afterwards still commits THAT device, never the refused one."""
    refused = [did for did in RAW_BY_ID if not _expected_pickable(did, mode)]
    assert refused, "the catalog has no refused row to check"
    for did in refused:
        j = _to_role_step(mode)
        before = (j.cfg.role, j.cfg.platform, j.cfg.board)
        target = j.screen().device
        _browse_to(j, did)
        assert j.status.startswith("refused: ")
        assert j.screen().device == target != did
        assert (j.cfg.role, j.cfg.platform, j.cfg.board) == before
        for _ in range(3):
            j.feed("b")                                 # device -> family -> arch -> types
        assert j.screen().view == "roles"
        j.feed("")                                      # commit what is shown
        assert j.slug != "role"
        axes = device_catalog.config_axes(target)
        assert (j.cfg.platform, j.cfg.board) == (axes["platform"], axes["board"])


@pytest.mark.parametrize("mode", SINGLE_IMAGE_MODES)
def test_picking_a_device_commits_its_builder_axes_and_a_role_it_offers(mode):
    for did in RAW_BY_ID:
        if not _expected_pickable(did, mode):
            continue
        j = _to_role_step(mode)
        _browse_to(j, did)
        j.feed("")                                      # Enter: the shown type
        raw = RAW_BY_ID[did]
        assert j.slug != "role", did
        assert j.cfg.platform == raw["builder"]["platform"], did
        assert j.cfg.board == raw["builder"].get("board", ""), did
        assert j.cfg.role in {r for r, _l in device_catalog.roles_for(did, mode)}, did


def test_enter_on_the_type_list_keeps_the_default_device_and_role():
    """The walk the rest of the journey tests rely on: one Enter on the step commits
    the default device and type, exactly what the step used to commit."""
    j = _to_role_step("standalone")
    role, platform = j.cfg.role, j.cfg.platform
    j.feed("")
    assert (j.cfg.role, j.cfg.platform, j.cfg.board) == (role, platform, "")
    assert j.slug != "role"


def test_role_numbers_are_the_chosen_devices_derived_types():
    """The type list is roles_for(device, mode) — not the whole mode catalog — so a
    number can only ever pick a type the chosen device's builder accepts."""
    for did in RAW_BY_ID:
        if not _expected_pickable(did, "cloud"):
            continue
        j = _to_role_step("cloud")
        _browse_to(j, did)
        roles = device_catalog.roles_for(did, "cloud")
        text = "\n".join(j.lines())
        for i, (_r, label) in enumerate(roles, 1):
            assert f"{i:2d}. {label}" in text, did
        j.feed(str(len(roles)))
        assert j.cfg.role == roles[-1][0], did


@pytest.mark.parametrize("back", ("b", "B", ""))
def test_back_goes_up_one_browse_level_at_a_time(back):
    """``b`` (or a bare Enter) on a browse screen goes up ONE level: device -> family
    -> architecture -> the type list. Never straight back to the types, and the
    arch/family picked on the way down are what the levels above show again."""
    did = next(iter(RAW_BY_ID))
    j = _to_role_step("standalone")
    a, f, _n = _raw_path(did)
    for line in ("d", str(a), str(f)):
        j.feed(line)
    raw = RAW_BY_ID[did]
    assert j.screen().view == "device"
    j.feed(back)
    assert j.screen().view == "family"
    assert "pick the family" in "\n".join(j.lines())
    j.feed(back)
    assert j.screen().view == "arch"
    assert "Pick the architecture" in "\n".join(j.lines())
    j.feed(back)
    assert j.screen().view == "roles"
    assert j.slug == "role"                             # backing out never commits
    # and down again lands on the same family's rows
    for line in ("d", str(a), str(f)):
        j.feed(line)
    assert f"{raw['label']} — {raw['soc']}" in "\n".join(j.lines())


def _no_image_devices(mode: str) -> list[tuple[str, str]]:
    """(device id, a role whose platforms carry its builder) for each raw row that
    HAS builder axes but no image type in ``mode`` — rows a config can still name."""
    out = []
    for did, raw in RAW_BY_ID.items():
        if raw["status"] == "unsupported" or not raw.get("builder"):
            continue
        if device_catalog.roles_for(did, mode):
            continue
        plat = raw["builder"]["platform"]
        role = next((r for r, plats, _l in ROLE_CHOICES[mode] if plat in plats), None)
        if role is not None:
            out.append((did, role))
    return out


def test_enter_is_refused_when_the_shown_device_has_no_image_here():
    """A config can name a device that has builder axes but no image on this path
    (the step opens on it). Enter on that type list must refuse and write nothing:
    no role, platform or board change, and the step stays where it is. Checked over
    both single-image paths together: a path may have no such row at all."""
    from hugmesh_studio.core.config import ImageConfig
    reached = 0
    for mode, did, role in [(m, d, r) for m in SINGLE_IMAGE_MODES
                            for d, r in _no_image_devices(m)]:
        raw = RAW_BY_ID[did]
        cfg = ImageConfig(mode=mode, role=role, platform=raw["builder"]["platform"],
                          board=raw["builder"].get("board", ""))
        j = journey.Journey(".", cfg=cfg)
        j.goto("role")
        if j.screen().device != did:
            continue        # the axes resolve to another device: not this case
        reached += 1
        before = (j.cfg.role, j.cfg.platform, j.cfg.board)
        assert "has no image on this path" in "\n".join(j.lines()), did
        j.feed("")
        assert j.slug == "role", did
        assert j.status.startswith("refused: "), (did, j.status)
        assert (j.cfg.role, j.cfg.platform, j.cfg.board) == before, did
        j.feed("1")                                     # a number is refused too
        assert j.slug == "role" and j.status.startswith("refused: "), did
        assert (j.cfg.role, j.cfg.platform, j.cfg.board) == before, did
    assert reached, "no raw row with builder axes lacks an image on a single-image path"


def test_a_committed_alias_device_comes_back_as_itself():
    """Two pickable rows can share builder axes (an experimental alias of a supported
    board). The axes alone map back to the supported one, so the step must remember
    the exact row it committed: re-entering it shows THAT row, not its twin."""
    mode = "standalone"
    groups: dict[tuple[str, str], list[str]] = {}
    for did, raw in RAW_BY_ID.items():
        if raw.get("builder") and _expected_pickable(did, mode):
            key = (raw["builder"]["platform"], raw["builder"].get("board", ""))
            groups.setdefault(key, []).append(did)
    shared = [ids for ids in groups.values() if len(ids) > 1]
    assert shared, "the catalog has no two pickable rows sharing builder axes"
    for ids in shared:
        for did in ids:
            j = _to_role_step(mode)
            _browse_to(j, did)
            j.feed("")                                  # commit it
            assert j.slug != "role", did
            j.goto("role")                              # come back to the step
            assert j.screen().device == did, (did, j.screen().device)
            raw = RAW_BY_ID[did]
            assert f"{raw['label']} — {raw['soc']}" in "\n".join(j.lines()), did


# ── the plain face, scripted end to end ─────────────────────────────────────────────
@pytest.mark.parametrize("mode", SINGLE_IMAGE_MODES)
def test_scripted_plain_session_reaches_every_row(mode, tmp_path):
    """ONE plain-face session, typed as a person would: browse to every catalog row in
    turn, pick it, and back out of each refusal. The transcript must show every row's
    label, every refusal (raw reason verbatim for the unsupported ones), and a saved
    config that holds the LAST pickable device's builder axes — the refusals in
    between changed nothing."""
    script = _enters_to_role_step(mode)
    last_ok = None
    for did in RAW_BY_ID:
        a, f, n = _raw_path(did)
        script += ["d", str(a), str(f), str(n)]
        if _expected_pickable(did, mode):
            last_ok = did
        else:
            script += ["b", "b", "b"]
    assert last_ok is not None
    path = tmp_path / "picked.json"
    script.append("")                                   # commit the shown device/type
    # walk on to the build screen and save there
    j = journey.Journey(".")
    for line in script:
        j.feed(line)
    while j.slug != "build":
        j.feed("")
        script.append("")
    script += [f"s {path}", "q"]

    out = io.StringIO()
    assert plain.run_journey(inp=io.StringIO("\n".join(script) + "\n"), out=out,
                             generator_dir=".") == 0
    text = out.getvalue()
    doc = device_catalog.list_devices_json(mode)
    for row in doc["devices"]:
        assert f"{row['label']} — {row['soc']}" in text, row["id"]
        if row["pickable"]:
            assert f"device: {row['label']} ({row['board_axis']})" in text, row["id"]
        else:
            assert f"refused: {row['refusal']}" in text, row["id"]
            raw = RAW_BY_ID[row["id"]]
            if raw["status"] == "unsupported":
                assert raw["reason"] in text, row["id"]
    saved = json.loads(path.read_text(encoding="utf-8"))
    raw = RAW_BY_ID[last_ok]
    assert saved["platform"] == raw["builder"]["platform"]
    assert saved.get("board", "") == raw["builder"].get("board", "")


# ── the urwid face renders the same screens ─────────────────────────────────────────
def test_urwid_face_shows_the_browse_and_refuses_the_same_rows(tmp_path):
    pytest.importorskip("urwid")            # soft dependency: skips where it is absent
    from hugmesh_studio.tui import urwid_ui

    mode = "standalone"
    refused = next(did for did in RAW_BY_ID if not _expected_pickable(did, mode))
    ok = next(did for did in RAW_BY_ID if _expected_pickable(did, mode))
    app_ = urwid_ui.JourneyApp(str(tmp_path))

    def typed(text):
        app_.input.set_edit_text(text)
        app_.unhandled("enter")

    def screen():
        canvas = app_.root.render((400, 400))
        return "\n".join(ln.decode("utf-8", "replace") for ln in canvas.text)

    for line in _enters_to_role_step(mode):
        typed(line)
    assert app_.journey.slug == "role"
    for did in (refused, ok):
        a, f, n = _raw_path(did)
        for line in ("d", str(a), str(f)):
            typed(line)
        raw = RAW_BY_ID[did]
        assert f"{raw['label']} — {raw['soc']}" in screen(), did
        typed(str(n))
        row = device_catalog.device_row(did, mode)
        if did == refused:
            assert f"refused: {row.refusal}" in screen()
            for _ in range(3):
                typed("b")
        else:
            assert f"device: {raw['label']}" in screen()
    typed("")
    assert app_.journey.cfg.platform == RAW_BY_ID[ok]["builder"]["platform"]
    assert app_.journey.cfg.board == RAW_BY_ID[ok]["builder"].get("board", "")
