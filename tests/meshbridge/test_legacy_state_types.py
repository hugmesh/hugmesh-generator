"""Legacy room-flag spellings — stdlib only (run: python3 -m unittest discover tests/meshbridge).

Room state is never rewritten, so a mesh that ran under an older brand can still
carry its per-room mesh flag under that brand's event type. The bridge honors the
built-in post-squash spelling, plus any spelling the operator lists in
MESHBRIDGE_LEGACY_STATE_TYPES. These tests use a placeholder brand
(systems.exampleorg.mesh.bridge): the tree names no real one.
"""

import asyncio
import importlib
import os
import pathlib
import sys
import unittest

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent.parent / "specs/cluster/manifests/meshbridge/app"))

OLD = "systems.exampleorg.mesh.bridge"
ENV = "MESHBRIDGE_LEGACY_STATE_TYPES"


def load_bridge(env_value):
    """Import bridge.py fresh with ENV set (or unset), then restore the env."""
    saved = os.environ.get(ENV)
    try:
        if env_value is None:
            os.environ.pop(ENV, None)
        else:
            os.environ[ENV] = env_value
        import bridge  # noqa: E402
        return importlib.reload(bridge)
    finally:
        if saved is None:
            os.environ.pop(ENV, None)
        else:
            os.environ[ENV] = saved


class FakeMatrix:
    def __init__(self, state):
        self.state = state

    async def room_state(self, room_id):
        return self.state


def room_state(flag_type, sender="@admin:mesh.example", channel=3):
    return [
        {"type": "m.room.power_levels", "state_key": "",
         "content": {"users": {sender: 100}, "state_default": 50}},
        {"type": flag_type, "state_key": "", "sender": sender,
         "content": {"enabled": True, "device": "default", "meshChannel": channel}},
    ]


def refresh(mod, state):
    b = mod.Bridge(FakeMatrix(state), {"default": object()})
    asyncio.run(b.refresh_room("!r:mesh.example"))
    return b.mappings.get("!r:mesh.example")


class LegacyStateTypes(unittest.TestCase):
    def test_a_configured_old_spelling_is_honored_on_read(self):
        mod = load_bridge(f" {OLD} ,")
        self.assertIn(OLD, mod.MESH_STATE_TYPES)
        self.assertEqual(mod.MESH_STATE_TYPES[0], "net.hugmesh.mesh.bridge")
        self.assertEqual(refresh(mod, room_state(OLD)),
                         {"enabled": True, "device": "default", "meshChannel": 3})

    def test_unconfigured_the_old_spelling_is_ignored(self):
        mod = load_bridge(None)
        self.assertNotIn(OLD, mod.MESH_STATE_TYPES)
        self.assertIsNone(refresh(mod, room_state(OLD)))

    def test_the_built_in_post_squash_spelling_still_reads_without_config(self):
        mod = load_bridge(None)
        self.assertIsNotNone(refresh(mod, room_state("systems.hugmesh.mesh.bridge")))

    def test_canonical_wins_over_a_configured_old_spelling(self):
        mod = load_bridge(OLD)
        state = room_state(OLD, channel=5) + [
            {"type": "net.hugmesh.mesh.bridge", "state_key": "",
             "sender": "@admin:mesh.example",
             "content": {"enabled": True, "device": "default", "meshChannel": 1}}]
        self.assertEqual(refresh(mod, state)["meshChannel"], 1)

    def test_an_old_spelling_is_gated_by_its_own_power_level(self):
        mod = load_bridge(OLD)
        state = room_state(OLD)
        state[0]["content"]["events"] = {OLD: 101}
        self.assertIsNone(refresh(mod, state))

    def test_the_list_is_cleaned(self):
        mod = load_bridge(None)
        got = mod.configured_legacy_state_types(
            f"{OLD},net.hugmesh.mesh.bridge,systems.hugmesh.mesh.bridge,{OLD},"
            "bad type,,other.example.flag")
        self.assertEqual(got, (OLD, "other.example.flag"))
        self.assertEqual(mod.configured_legacy_state_types(None), ())

    @classmethod
    def tearDownClass(cls):
        load_bridge(None)


if __name__ == "__main__":
    unittest.main()
