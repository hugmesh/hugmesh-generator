"""Managed backing services (I8/M2) — pins Studio's ImageConfig.managed_services axis
to the two node builders' OWN --managed-service tier registry AND to the design registry
specs/cluster/backing-services.yaml, so the three can never silently drift, plus the
fail-closed boundary (tier-3 refused, unknown refused, endpoint charset) and the dict
round-trip.

The field's byte-identity (empty default emits nothing), platform scope (x86/rpi5 only)
and emission are already proven by test_cli_args.py's _FIELD_PROBE before/after differ —
this file owns the correctness that differ cannot see.

Pure-core: no Qt import — runs in the headless suite.

VACUOUS-PASS GUARDS (a source/regex miss must FAIL this file, never pass it seeing an
empty set): _builder_ids() asserts each parse is non-empty, and the yaml agreement asserts
it parsed >0 services before comparing. The pyyaml import is importorskip (optional dep —
the studio venv may lack it; a missing dep must SKIP, never FAIL — the same rule the M1
registry test learned).
"""
import os
import re

import pytest

from hugmesh_studio.core.config import (
    ImageConfig,
    MANAGED_SERVICE_TIER12_IDS,
    MANAGED_SERVICE_TIER3_IDS,
    MANAGED_SERVICE_TIER3_BLOCKER,
)
from hugmesh_studio.core.validate import IdentityValidationError

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
X86_BUILDER = os.path.join(GENERATOR_DIR, "build-x86-host-stage4.sh")
RPI5_BUILDER = os.path.join(GENERATOR_DIR, "build-rpi5-stage4.sh")
BACKING_YAML = os.path.join(GENERATOR_DIR, "specs", "cluster", "backing-services.yaml")


def _builder_ids(path, var):
    """Extract the space-separated id list from a builder's `VAR="a b c"` line. Asserts a
    match AND a non-empty result so a regex/source drift can never let this file pass
    vacuously on the empty set."""
    src = open(path, encoding="utf-8").read()
    m = re.search(rf'^{re.escape(var)}="([^"]*)"', src, re.MULTILINE)
    assert m, f"{var} not found in {os.path.basename(path)} (builder source drift?)"
    ids = tuple(m.group(1).split())
    assert ids, f"{var} parsed EMPTY in {os.path.basename(path)} (vacuous-pass guard)"
    return ids


# ── (1) three-source agreement: config <-> BOTH node builders (the flag's parsers) ──
@pytest.mark.parametrize("path", [X86_BUILDER, RPI5_BUILDER], ids=["x86", "rpi5"])
def test_tier12_ids_match_the_builder(path):
    assert _builder_ids(path, "_MGD_TIER12_IDS") == MANAGED_SERVICE_TIER12_IDS


@pytest.mark.parametrize("path", [X86_BUILDER, RPI5_BUILDER], ids=["x86", "rpi5"])
def test_tier3_ids_match_the_builder(path):
    assert _builder_ids(path, "_MGD_TIER3_IDS") == MANAGED_SERVICE_TIER3_IDS


def test_tier_sets_disjoint_nonempty_and_every_tier3_has_a_blocker():
    assert MANAGED_SERVICE_TIER12_IDS and MANAGED_SERVICE_TIER3_IDS
    assert not (set(MANAGED_SERVICE_TIER12_IDS) & set(MANAGED_SERVICE_TIER3_IDS))
    for sid in MANAGED_SERVICE_TIER3_IDS:
        assert MANAGED_SERVICE_TIER3_BLOCKER.get(sid), f"tier-3 {sid} has no blocker note"


# ── (2) design-registry agreement: config <-> backing-services.yaml (SKIP w/o pyyaml) ──
def test_config_ids_match_backing_services_yaml():
    yaml = pytest.importorskip("yaml")  # optional dep -> SKIP, never FAIL, when absent
    doc = yaml.safe_load(open(BACKING_YAML, encoding="utf-8"))
    svcs = []

    def walk(o):
        if isinstance(o, dict):
            for v in o.values():
                if isinstance(v, list) and any(isinstance(x, dict) and "id" in x for x in v):
                    svcs.extend(x for x in v if isinstance(x, dict) and "id" in x)
                else:
                    walk(v)
        elif isinstance(o, list):
            for x in o:
                walk(x)

    walk(doc)
    assert svcs, "parsed 0 services from backing-services.yaml (vacuous-pass guard)"
    y_t12 = {s["id"] for s in svcs if not s.get("docsOnly")}
    y_t3 = {s["id"] for s in svcs if s.get("docsOnly")}
    assert y_t12 == set(MANAGED_SERVICE_TIER12_IDS), "yaml tier-1/2 != config"
    assert y_t3 == set(MANAGED_SERVICE_TIER3_IDS), "yaml tier-3 (docsOnly) != config"


# ── (3) fail-closed boundary: tier-3 and unknown ids are REFUSED ──
def _cfg(ms):
    return ImageConfig(mode="mesh", role="backend", platform="x86", managed_services=ms)


@pytest.mark.parametrize("sid", MANAGED_SERVICE_TIER3_IDS)
def test_tier3_id_refused_with_its_blocker(sid):
    with pytest.raises(IdentityValidationError) as ei:
        _cfg({sid: "host:9999"}).validate_identity()
    msg = str(ei.value)
    assert "TIER-3" in msg
    assert MANAGED_SERVICE_TIER3_BLOCKER[sid] in msg


def test_unknown_id_refused():
    with pytest.raises(IdentityValidationError):
        _cfg({"totally-bogus": "host:1"}).validate_identity()


# ── (4) endpoint charset: shell/sed-safe accepted, metacharacters refused ──
@pytest.mark.parametrize("ep", [
    "aws", "msk-broker:9098", "b1:9092,b2:9092,b3:9092",
    "https://smtp.example.com:587", "bucket@s3.amazonaws.com", "10.0.0.5:5432",
])
def test_valid_endpoint_accepted(ep):
    _cfg({"kafka": ep}).validate_identity()  # must not raise


@pytest.mark.parametrize("ep", [
    "", "host 9092", "host;rm -rf /", "$(whoami)", "`id`", "a|b", "a&b",
    "<x>", "h'o", 'h"o', ":9092", "-flag",
])
def test_malformed_endpoint_refused(ep):
    with pytest.raises(IdentityValidationError):
        _cfg({"kafka": ep}).validate_identity()


# ── (5) emission: repeatable `--managed-service id=endpoint`, SORTED, on both builders ──
@pytest.mark.parametrize("platform", ["x86", "rpi5"])
def test_emission_sorted_and_repeatable(platform):
    cfg = ImageConfig(mode="mesh", role="backend", platform=platform,
                      managed_services={"smtp": "mail:587", "kafka": "msk:9098"})
    args = cfg.to_cli_args()
    pairs = [args[i + 1] for i, a in enumerate(args) if a == "--managed-service"]
    assert pairs == ["kafka=msk:9098", "smtp=mail:587"], pairs  # deterministic sorted-by-id


@pytest.mark.parametrize("platform", ["x86", "rpi5"])
def test_empty_default_emits_nothing(platform):
    assert "--managed-service" not in ImageConfig(
        mode="mesh", role="backend", platform=platform).to_cli_args()


# ── (6) round-trip: the dict field survives to_dict/from_dict + save/load ──
def test_round_trip_to_dict_from_dict():
    ms = {"kafka": "msk:9098", "postgres-casdoor": "pg:5432"}
    back = ImageConfig.from_dict(_cfg(ms).to_dict())
    assert back.managed_services == ms


def test_round_trip_save_load(tmp_path):
    ms = {"clickhouse": "ch:8443"}
    p = str(tmp_path / "c.json")
    _cfg(ms).save(p)
    assert ImageConfig.load(p).managed_services == ms
