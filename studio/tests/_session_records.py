"""Shared fixture helper for #637: write a BUILD RECORD (``<state>/sessions/<id>.json``)
for an artifact session dir, the way ``build_sessions.new_session`` would at dispatch —
so ``core.domain_services.session_boot_gate_reason`` has something to read.

Test-only; every caller isolates ``$HUGMESH_STUDIO_STATE_DIR`` first.
"""
from hugmesh_studio.core import build_sessions
from hugmesh_studio.core.config import Domain, ImageConfig
from hugmesh_studio.core.worklist import WorklistConfig, WorklistEntry


def write_build_record(session_id: str, domains=(), reviewed=(),
                       cluster_domain: str = "hugmesh.net") -> str:
    """The record for ``session_id``: a mesh build whose base config names
    ``domains`` and marks ``reviewed`` walked. Returns the record path."""
    base = ImageConfig(mode="mesh", cluster_domain=cluster_domain,
                       domains=[Domain(name=n) for n in domains],
                       domain_services_reviewed=list(reviewed))
    wl = WorklistConfig(base=base,
                        entries=[WorklistEntry(role="backend", platform="x86")])
    rec = build_sessions.BuildSession(id=session_id, config=wl.to_dict())
    build_sessions.save(rec)
    assert build_sessions.find(session_id) is not None, "the record did not land"
    return rec.path()
