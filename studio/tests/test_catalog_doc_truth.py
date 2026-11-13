"""Catalog and docs truth pass (hugmesh-generator #1060, lane E1 of the platform expansion).

The device catalog and the docs that describe it said things the tree does not back:

* a "Raspberry Pi 6" row for a product that does not exist;
* reasons that cited an outside thread instead of saying, in tree terms, why;
* "generic RK3399 needs a new builder" next to an Orange Pi 4 row that already
  points at the RK3399 builder this repo has (orangepi4-lts);
* an omnibus row in docs/BUILD-MATRIX.md naming the Pi 4, which rpi_boards_for_role
  never offers for omnibus (it needs 16 GB; a Pi 4 has 8 GB at most);
* a Jetson docstring saying --encrypt-root "landed" on Jetson, whose builder refuses it;
* a ROCm "future path" for the edge-ai role, which bakes CUDA and nothing else;
* the Jetson l4t kernel flavour OFFERED in every channel although the builder exits 1
  on it by design;
* walkthrough counts typed by hand that had already drifted from the catalog.

Each guard below derives its expectation from the code or the catalog, never from a
literal kept here, so the next catalog change fails the docs that it falsifies.
Pure-core: no Qt import.
"""
from __future__ import annotations

import json
import os
import re

from hugmesh_studio.core import config
from hugmesh_studio.core import device_catalog as dc
from hugmesh_studio.core.config import (
    KERNEL_FLAVOR_CHOICES, KERNEL_FLAVOR_REFUSED, rpi_boards_for_role,
)

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
CATALOG_JSON = os.path.join(STUDIO_ROOT, "hugmesh_studio", "core", "device-catalog.json")
WEB_CATALOG_JSON = os.path.join(GENERATOR_DIR, "docs", "catalog", "image-catalog.json")
# The doc is overridable only so a mutation check can point the test at a damaged copy.
WALKTHROUGH = os.environ.get("HUGMESH_WALKTHROUGH_DOC",
                             os.path.join(GENERATOR_DIR, "docs", "STUDIO-WALKTHROUGH.md"))

CAT = dc.load_catalog()


def _read(*parts: str) -> str:
    with open(os.path.join(GENERATOR_DIR, *parts), encoding="utf-8") as fh:
        return fh.read()


def _raw_catalog() -> dict:
    with open(CATALOG_JSON, encoding="utf-8") as fh:
        return json.load(fh)


# ---- rows ---------------------------------------------------------------------------

def test_raspberry_pi_6_row_is_removed_everywhere():
    """The product does not exist, so neither the Studio catalog nor the web catalog
    the admin UI reads may list it, by id or by name."""
    for path in (CATALOG_JSON, WEB_CATALOG_JSON):
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        ids = {d["id"] for d in data["devices"]}
        labels = " ".join(d["label"] for d in data["devices"])
        assert "rpi6" not in ids, path
        assert not re.search(r"Raspberry Pi 6\b", labels), path


def test_refused_rows_keep_their_reasons():
    """Removing rows is for things that do not exist. Every refused row that remains
    still says why."""
    unsupported = [d for d in CAT.devices if d.status == "unsupported"]
    assert unsupported
    for d in unsupported:
        assert d.reason.strip(), d.id


def test_catalog_rationales_cite_no_outside_thread():
    """A reason is read by someone choosing a device. It must say, in tree terms, why,
    not point at a discussion elsewhere ('#351 verdict')."""
    raw = _raw_catalog()
    texts = [("_comment", raw["_comment"])]
    for d in raw["devices"]:
        texts += [(d["id"] + ".reason", d.get("reason") or ""),
                  (d["id"] + ".notes", d.get("notes") or "")]
    cited = [(where, m.group(0)) for where, text in texts
             for m in re.finditer(r"#\d+", text)]
    assert not cited, cited


# ---- Orange Pi 4 versus generic RK3399 ----------------------------------------------

def test_rk3399_rows_agree_with_the_rk3399_builder_that_exists():
    """The Orange Pi 4 LTS has a builder (platform orangepi4-lts). The plain Orange Pi 4
    row says promoting it is a validation task on that builder; the generic RK3399 row
    must not then claim a new builder is needed, nor blame the RK3588 recipe."""
    lts = CAT.device("orange-pi-4-lts")
    assert lts.builder_platform == "orangepi4-lts"
    assert lts.builder_platform in config.PLATFORM_LABELS
    for did in ("opi4", "rk3399-generic"):
        reason = CAT.device(did).reason
        assert "orangepi4-lts" in reason, did
        assert not re.search(r"new builder would be required|RK3588 recipe is not reusable",
                             reason), did


# ---- Jetson -------------------------------------------------------------------------

def _jetson_rows():
    rows = [d for d in CAT.devices if d.builder_platform == "jetson"]
    assert rows
    return rows


def test_jetson_encryption_wording_matches_the_builder():
    """Jetson is the one platform whose builder refuses --encrypt-root. Every Jetson row
    says so in the same words, and nothing in config.py says encryption landed there."""
    assert "jetson" not in config._ENC_PLATFORMS
    phrases = set()
    for d in _jetson_rows():
        m = re.search(r"no root-disk encryption: [^;]*", d.reason)
        assert m, d.id
        phrases.add(m.group(0))
    assert len(phrases) == 1, phrases
    doc = config.ImageConfig._encrypt_root_args.__doc__ or ""
    assert not re.search(r"landed on [^.;]*Jetson", doc), doc
    assert "EXCEPT Jetson" in doc


def _builder_refused_flavours() -> set[str]:
    """The kernel flavours build-jetson-stage4.sh accepts on the command line and then
    exits 1 on unconditionally, parsed out of the builder itself."""
    src = _read("build-jetson-stage4.sh")
    refused = set()
    for m in re.finditer(
            r'^if \[ "\$\{KERNEL_FLAVOR\}" = "([a-z0-9-]+)" \]; then\n(.*?)^fi$', src,
            re.M | re.S):
        if re.search(r"^\s*exit 1\b", m.group(2), re.M):
            refused.add(m.group(1))
    return refused


def _builder_accepted_flavours() -> set[str]:
    src = _read("build-jetson-stage4.sh")
    m = re.search(r"^\s*([a-z0-9|-]+)\) ;;\n\s*\*\) err \"--kernel-flavor must be", src, re.M)
    assert m, "the builder's --kernel-flavor case statement moved"
    return set(m.group(1).split("|"))


def test_no_offered_kernel_flavour_exits_non_zero_by_design():
    """An option that always exits 1 is not an option. Every flavour the builder refuses
    is in KERNEL_FLAVOR_REFUSED (shown greyed with a reason), none is in the offered
    KERNEL_FLAVOR_CHOICES, and every offered flavour is one the builder accepts."""
    builder_refused = _builder_refused_flavours()
    assert builder_refused == {"l4t"}, builder_refused   # real case: the parse finds it
    assert set(KERNEL_FLAVOR_REFUSED) == builder_refused
    assert not set(KERNEL_FLAVOR_CHOICES) & builder_refused
    assert set(KERNEL_FLAVOR_CHOICES) <= _builder_accepted_flavours() - builder_refused
    for flavour, reason in KERNEL_FLAVOR_REFUSED.items():
        assert "non-zero" in reason and "TEGRAFLASH.md" in reason, flavour


def test_jetson_rows_say_l4t_is_not_offered():
    for d in _jetson_rows():
        assert "l4t kernel flavour is not offered" in d.reason, d.id
        assert "stub" not in d.reason, d.id


def test_text_menu_reason_matches_the_studio_reason():
    """The text menu cannot import Python, so it carries its own copy of the l4t reason;
    the copy must be the same words the Studio shows."""
    src = _read("scripts", "build-menu.sh")
    m = re.search(r'^JETSON_L4T_REASON="([^"]*)"$', src, re.M)
    assert m, "build-menu.sh lost JETSON_L4T_REASON"
    assert m.group(1) == KERNEL_FLAVOR_REFUSED["l4t"]


# ---- omnibus on a Pi 4 --------------------------------------------------------------

_PI_NAMES = {"Pi 5": "rpi5", "Pi 4": "rpi4", "Pi 3": "rpi3"}


def test_build_matrix_role_table_names_only_boards_the_role_offers():
    """docs/BUILD-MATRIX.md's canonical-role table may qualify rpi5 with the Pi boards a
    role runs on; those boards must be exactly rpi_boards_for_role(role)."""
    doc = _read("docs", "BUILD-MATRIX.md")
    rows = re.findall(r"^\| `([a-z-]+)` \| [^|]+ \| ([^|]+) \|$", doc, re.M)
    qualified = [(role, plats) for role, plats in rows if "rpi5 (" in plats]
    assert any(role == "omnibus" for role, _ in qualified), "omnibus row lost its rpi5 note"
    for role, plats in qualified:
        note = re.search(r"rpi5 \(([^)]*)\)", plats).group(1)
        named = {board for name, board in _PI_NAMES.items()
                 if re.search(rf"\b{name}\b", note)}
        assert named == set(rpi_boards_for_role(role)), (role, note)


# ---- ROCm ---------------------------------------------------------------------------

def test_edge_ai_gpu_wording_is_cuda_only():
    """The edge-ai role turns CUDA on for the NVIDIA driver and bakes nothing for any
    other GPU; no doc or builder comment may promise a ROCm path."""
    for parts in (("docs", "EDGE-AI.md"), ("build-x86-host-stage4.sh",)):
        text = _read(*parts)
        assert not re.search(r"ROCm[^.\n]*future|future[^.\n]*ROCm", text), parts
    assert "GPU inference is CUDA only" in _read("docs", "EDGE-AI.md")


# ---- walkthrough counts -------------------------------------------------------------

def _one(pattern: str, text: str) -> re.Match:
    found = list(re.finditer(pattern, text))
    assert len(found) == 1, f"expected the walkthrough sentence /{pattern}/ exactly once"
    return found[0]


def test_walkthrough_counts_are_computed_from_the_catalog():
    """Every count docs/STUDIO-WALKTHROUGH.md states about the catalog equals the count
    the catalog yields today. A reworded sentence fails here too, so the count cannot
    slip out of this check by being rephrased."""
    with open(WALKTHROUGH, encoding="utf-8") as fh:
        doc = fh.read()
    n_devices = len(CAT.devices)
    n_families = len({d.family for d in CAT.devices})
    n_unsupported = sum(d.status == "unsupported" for d in CAT.devices)
    # the worklist's checkbox counts exactly this population (worklist.py _info_items)
    n_not_mesh = sum(not dc.mesh_capable(d.id) for d in CAT.devices)

    m = _one(r"(\d+) devices across (\d+) families today", doc)
    assert (int(m.group(1)), int(m.group(2))) == (n_devices, n_families)
    m = _one(r"(\d+) of the (\d+) are in that state", doc)
    assert (int(m.group(1)), int(m.group(2))) == (n_unsupported, n_devices)
    m = _one(r'"Also list the (\d+) devices that cannot be mesh nodes"', doc)
    assert int(m.group(1)) == n_not_mesh

    # "including everything under ARMv7 and RISC-V": still true only while every
    # device on those archs is unsupported.
    if re.search(r"including everything under ARMv7 and RISC-V", doc):
        for d in CAT.devices:
            if d.arch in ("armv7", "riscv64"):
                assert d.status == "unsupported", d.id
    # the architecture list in parentheses names every catalog arch, in order
    m = _one(r"First the \*\*architecture\*\* \(([^)]*)\)", doc)
    assert [a.strip() for a in m.group(1).split(",")] == \
        [a.label.split(" (")[0] for a in CAT.archs]
