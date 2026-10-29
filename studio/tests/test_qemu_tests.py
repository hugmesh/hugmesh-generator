"""Hermetic tests for core/qemu_tests.py — the containerized emulated-device driver.

Everything here runs WITHOUT docker, qemu, or a single real image: the module's job is
resolution (which artifacts imply which device rows) and argv construction, both of
which are pure. The one thing that cannot be faked — that the shell runner parses
artifact names the same way this module does — is pinned by
``test_shell_and_python_agree_on_row_discovery``, which runs the real script's
``--list`` over a fabricated artifacts dir.
"""
import json
import os
import shutil
import subprocess

import pytest

from hugmesh_studio.core import qemu_tests as qt

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
RUNNER = os.path.join(GENERATOR_DIR, qt.RUNNER_SCRIPT)

#: Real artifact names from the 2026-08-07 build session, plus the hyphenated-role and
#: decoy cases the parser has to survive.
_REAL_NAMES = [
    "hugmesh-rpi5-arm64-pki-test-20260807T153808Z.img.xz",
    "hugmesh-rpi5-arm64-backend-test-20260807T185415Z.img.xz",
    "hugmesh-rpi5-arm64-frontend-test-20260807T205908Z.img.xz",
    "hugmesh-x86-amd64-be-test-20260807T172418Z.img.xz",
    "hugmesh-x86-amd64-omnibus-test-20260807T213853Z.img.xz",
]

#: The REAL artifact names from out/sessions/20260830-185641-8e88a6 — the operator's
#: 2026-08-30 three-image Pi mesh, built with ``--brand sdhm``. Every one of these
#: parsed as NOTHING while the parser required a literal ``hugmesh-`` prefix, so the
#: whole finished session read "0 images" and the Studio's emulation picker was empty
#: ("mesh emulation screen dropdown can't seem to use the 3 pi images session that
#: completed successfully"). They are spelled out verbatim rather than generated:
#: the defect was in the FIRST field of a real filename, and a generated name would
#: have been generated from the same wrong assumption.
_BRANDED_PI_NAMES = [
    "sdhm-rpi5-arm64-pki-test-20260831T015954Z.img.xz",
    "sdhm-rpi5-arm64-backend-test-20260831T025801Z.img.xz",
    "sdhm-rpi5-arm64-frontend-test-20260831T033915Z.img.xz",
]

#: The per-image build logs that session holds (core/build_sessions.image_log_name
#: over the manifest ids), and its manifest brand. ``expected_image_count`` reads
#: the logs, so a fixture without them cannot show "3 of 3".
_BRANDED_PI_LOGS = ["build-pki.rpi5.log", "build-be.rpi5.log", "build-fe.rpi5.log"]
_BRANDED_PI_MANIFEST = {
    "format": 2, "brand": "sdhm", "brand_title": "Example Hugmesh", "org": "sdhm",
    "cluster_domain": "mesh.example", "superdomain": "example.local",
    "domains": [], "users": [],
    "images": [
        {"id": "pki.rpi5", "role": "pki", "platform": "rpi5", "board": "rpi5",
         "flavor": "", "encrypt_root": True},
        # The file on disk spells these two ids' role field with the ALIASES
        # ("be" / "fe"). They are written canonically here because
        # tests/scripts/test-role-key-spelling.sh bans emitting an alias as a
        # `"role":` JSON value anywhere in the tree, and nothing in qemu_tests
        # reads this field — expected_image_count counts the `images` list (and
        # prefers the per-image LOGS over it entirely). The IDS keep their real
        # spelling, because those ARE what build_sessions.image_log_name joins on.
        {"id": "be.rpi5", "role": "backend", "platform": "rpi5", "board": "rpi5",
         "flavor": "", "encrypt_root": True},
        {"id": "fe.rpi5", "role": "frontend", "platform": "rpi5", "board": "rpi5",
         "flavor": "", "encrypt_root": True},
    ],
}


def _branded_pi_session(root, name="20260830-185641-8e88a6"):
    """A byte-for-name copy of the operator's finished sdhm Pi session.

    Mirrors what is actually in the dir: the three ``.img.xz`` images, their
    non-image siblings (``.iso`` / ``.stage4.tar.xz`` / ``.fs.tar.xz``, which must
    NOT become rows), the three per-image build logs, the shared build.log, and the
    format-2 manifest whose ``brand`` is ``sdhm``.
    """
    sess = root / "out" / "sessions" / name
    sess.mkdir(parents=True)
    for img in _BRANDED_PI_NAMES:
        stem = img[: -len(".img.xz")]
        _write(str(sess), img, stem + ".iso", stem + ".stage4.tar.xz",
               stem + ".fs.tar.xz")
    for log in _BRANDED_PI_LOGS:
        (sess / log).write_text("=== Post-install ===\n")
    (sess / "build.log").write_text("brand=sdhm\n")
    (sess / qt.MESH_MANIFEST_NAME).write_text(json.dumps(_BRANDED_PI_MANIFEST))
    return sess


def test_parse_artifact_name_real_names():
    assert qt.parse_artifact_name(
        "hugmesh-rpi5-arm64-pki-test-20260807T153808Z.img.xz") == ("rpi5", "arm64", "pki", "test")
    assert qt.parse_artifact_name(
        "hugmesh-x86-amd64-omnibus-test-20260807T213853Z.img") == ("x86", "amd64", "omnibus", "test")


def test_parse_artifact_name_keeps_hyphenated_roles():
    """standalone-thin must not truncate to 'standalone'.

    The role sits between the arch and the trailing <env>-<stamp>, so it is parsed
    from both ends; a naive split('-')[3] loses everything after the first hyphen.
    """
    assert qt.parse_artifact_name(
        "hugmesh-x86-amd64-standalone-thin-prod-20260807T213853Z.img") == (
            "x86", "amd64", "standalone-thin", "prod")
    assert qt.parse_artifact_name(
        "hugmesh-x86-amd64-standalone-unaffiliated-test-20260101T000000Z.img.xz") == (
            "x86", "amd64", "standalone-unaffiliated", "test")


@pytest.mark.parametrize("name,parsed", [
    ("sdhm-rpi5-arm64-pki-test-20260831T015954Z.img.xz", ("rpi5", "arm64", "pki", "test")),
    ("sdhm-rpi5-arm64-backend-test-20260831T025801Z.img.xz",
     ("rpi5", "arm64", "backend", "test")),
    ("sdhm-rpi5-arm64-frontend-test-20260831T033915Z.img.xz",
     ("rpi5", "arm64", "frontend", "test")),
    # an unaffiliated build forces BRAND=gentoo (build-x86-host-stage4.sh), and its
    # hyphenated role must still survive the both-ends parse
    ("gentoo-x86-amd64-standalone-unaffiliated-test-20260901T120000Z.img",
     ("x86", "amd64", "standalone-unaffiliated", "test")),
    # any other slug --brand accepts; the ROLE is still canonicalized on the way
    # out (edge_ai -> edge-ai), which is the one transform this function applies
    ("acme-jetson-arm64-edge_ai-prod-20260719T000000Z.img",
     ("jetson", "arm64", "edge-ai", "prod")),
])
def test_parse_artifact_name_reads_any_brand(name, parsed):
    """The FIRST field is ${BRAND}, not the literal "hugmesh".

    The builders name artifacts ``${BRAND}-<platform>-<arch>-<role>-<env>-<stamp>``
    (build-rpi5-stage4.sh IMG_PATH, build-x86-host-stage4.sh IMG_PATH) and BRAND is
    whatever ``--brand`` the build ran under — "hugmesh" only by DEFAULT. Requiring
    the default here meant the operator's finished 3-image sdhm Pi mesh parsed as
    zero rows and its session vanished from the emulation picker entirely.

    This is the assertion that fails on the unfixed parser; everything else in this
    file passed throughout, because every other fixture was named for the default
    brand.
    """
    assert qt.parse_artifact_name(name) == parsed


@pytest.mark.parametrize("name,brand", [
    ("sdhm-rpi5-arm64-pki-test-20260831T015954Z.img.xz", "sdhm"),
    ("hugmesh-x86-amd64-be-test-20260807T172418Z.img", "hugmesh"),
    ("gentoo-x86-amd64-standalone-test-20260901T120000Z.img", "gentoo"),
    ("some-third-party.img", ""),
])
def test_artifact_brand_reads_the_brand_field(name, brand):
    """The brand is READ (a row can say where it came from) and never MATCHED on."""
    assert qt.artifact_brand(name) == brand


@pytest.mark.parametrize("name", [
    "hugmesh-rpi5-arm64-pki-test-20260807T153808Z.stage4.tar.xz",  # not a disk
    "hugmesh-rpi5-arm64-pki-test-20260807T153808Z.iso",            # not a disk
    "kernel_2712.img",                                             # kernel blob
    "hugmesh-rpi5-arm64-pki-test-initramfs.img",                   # initramfs blob
    "some-third-party.img",                                        # not ours
    "hugmesh-too-short.img",                                       # missing fields
    # WHAT REPLACED THE BRAND PREFIX AS THE "not ours" RULE. With the brand opaque,
    # SHAPE is the only thing left that can refuse a foreign file, so the trailing
    # BUILD_TS stamp has to do that work: these have six-plus fields and would
    # otherwise become bootable rows in a session dir.
    "a-very-long-user-named-backup-file.img",
    "sdhm-rpi5-arm64-pki-test-notastamp.img",
    "sdhm-rpi5-arm64-pki-test-20260831T0159Z.img",                 # truncated stamp
])
def test_parse_artifact_name_rejects_non_rows(name):
    assert qt.parse_artifact_name(name) is None


def test_discover_rows_skips_zero_byte_images(tmp_path):
    """A 0-byte .img is a KILLED build, not a device.

    ``IMG_PATH`` is created before the builder partitions it, so a run killed in
    that window leaves an empty file behind — out/sessions/20260830-173335-d51b24
    holds exactly that beside a finished .stage4.tar.xz. Counting it would boot a
    guest off nothing AND make an aborted 1-of-2 build read as complete, which is
    the same lie ``is_partial`` exists to prevent. tests/qemu/run-qemu-docker.sh
    applies the identical rule (``[ -s ]``).
    """
    (tmp_path / "sdhm-rpi5-arm64-pki-test-20260831T003614Z.img").write_bytes(b"")
    _write(str(tmp_path), "sdhm-rpi5-arm64-backend-test-20260831T025801Z.img")
    rows = qt.discover_rows(str(tmp_path))
    assert [r.label for r in rows] == ["rpi5/backend"]


def test_platform_rank_orders_pi_first_then_arm_then_x86():
    assert qt.platform_rank("rpi5") < qt.platform_rank("orangepi5")
    assert qt.platform_rank("orangepi5") < qt.platform_rank("x86")


def _write(dirpath, *names):
    for n in names:
        with open(os.path.join(dirpath, n), "w", encoding="utf-8") as fh:
            fh.write("x")


def test_discover_rows_orders_pi_first(tmp_path):
    _write(str(tmp_path), *_REAL_NAMES)
    rows = qt.discover_rows(str(tmp_path))
    assert [r.label for r in rows][:3] == ["rpi5/backend", "rpi5/frontend", "rpi5/pki"]
    assert {r.label for r in rows[3:]} == {"x86/backend", "x86/omnibus"}


def test_discover_rows_prefers_decompressed_over_xz(tmp_path):
    """A row must not re-expand 20GB it already has on disk."""
    _write(str(tmp_path),
           "hugmesh-rpi5-arm64-pki-test-20260807T153808Z.img.xz",
           "hugmesh-rpi5-arm64-pki-test-20260807T153808Z.img")
    rows = qt.discover_rows(str(tmp_path))
    assert len(rows) == 1
    assert not rows[0].compressed
    assert rows[0].image.endswith(".img")


def test_discover_rows_picks_newest_build_of_a_role(tmp_path):
    """A rebuilt role must supersede its predecessor, not lose to it.

    Entries are enumerated in sorted-name order, i.e. OLDEST first, so the old
    keep-the-incumbent rule pinned the row to the stale artifact: rebuilding a
    role produced a green run whose bits were never tested.
    """
    _write(str(tmp_path),
           "hugmesh-rpi5-arm64-pki-test-20260807T153808Z.img",
           "hugmesh-rpi5-arm64-pki-test-20260814T160000Z.img")
    rows = qt.discover_rows(str(tmp_path))
    assert len(rows) == 1
    assert rows[0].basename == "hugmesh-rpi5-arm64-pki-test-20260814T160000Z.img"


def test_discover_rows_newest_wins_even_when_older_is_decompressed(tmp_path):
    """Freshness outranks the re-expansion shortcut.

    The stale build is the convenient one here — already decompressed, no xz
    pass needed — and picking it would still be wrong.
    """
    _write(str(tmp_path),
           "hugmesh-rpi5-arm64-pki-test-20260807T153808Z.img",
           "hugmesh-rpi5-arm64-pki-test-20260814T160000Z.img.xz")
    rows = qt.discover_rows(str(tmp_path))
    assert len(rows) == 1
    assert rows[0].stamp == "20260814T160000Z"
    assert rows[0].compressed


def test_discover_rows_empty_for_missing_dir(tmp_path):
    assert qt.discover_rows(str(tmp_path / "nope")) == []


def test_discover_sessions_hides_empty_and_sorts_newest_first(tmp_path):
    sessions_root = tmp_path / "out" / "sessions"
    empty = sessions_root / "20260101-000000-aaaaaa"
    full = sessions_root / "20260807-071119-5c1ccb"
    for d in (empty, full):
        d.mkdir(parents=True)
    _write(str(full), *_REAL_NAMES)
    # A session dir is minted when a build STARTS, so empty ones are common.
    os.utime(full, (2_000_000_000, 2_000_000_000))
    os.utime(empty, (1_000_000_000, 1_000_000_000))

    sessions = qt.discover_sessions(str(tmp_path))
    assert [s.name for s in sessions] == [full.name]
    assert qt.newest_session(str(tmp_path)).name == full.name
    assert sessions[0].platforms == ["rpi5", "x86"]
    assert "5 image(s)" in sessions[0].summary()


def test_discover_sessions_can_include_empty(tmp_path):
    (tmp_path / "out" / "sessions" / "empty").mkdir(parents=True)
    sessions = qt.discover_sessions(str(tmp_path), only_with_images=False)
    assert [s.name for s in sessions] == ["empty"]
    assert not sessions[0].has_images


def test_session_summary_names_the_roles_under_each_platform(tmp_path):
    """``summary()`` is the picker line (gui/pages/_emulation_common.py builds the
    session combo out of it), so it is the ONLY place an operator sees WHAT a
    session can boot before choosing it. A line that says "2 image(s): rpi5; x86"
    cannot be told apart from a different session with the same platform spread,
    which is exactly how the wrong session gets picked.

    Three platforms on purpose: ``frite`` sorts BEFORE ``rpi5`` alphabetically but
    AFTER it by ``platform_rank`` (Pi first, other ARM next, x86 last), so the
    positional assertion below fails if the grouping ever falls back to plain
    name order instead of the boot order the runner will actually use.
    """
    sess = tmp_path / "out" / "sessions" / "20260807-071119-5c1ccb"
    sess.mkdir(parents=True)
    _write(str(sess),
           "hugmesh-rpi5-arm64-pki-test-20260807T153808Z.img.xz",
           "hugmesh-rpi5-arm64-backend-test-20260807T185415Z.img.xz",
           "hugmesh-frite-arm64-be-test-20260807T190000Z.img.xz",
           "hugmesh-x86-amd64-standalone-thin-prod-20260807T172418Z.img")

    session, = qt.discover_sessions(str(tmp_path))
    text = session.summary()

    assert "4 image(s)" in text
    # roles, grouped under their platform — not a bare platform list, and not one
    # flat role list that loses which device each role belongs to
    assert "rpi5 (backend, pki)" in text
    # The frite artifact was BUILT as "-be-" and keeps that filename forever (it is
    # an already-emitted artifact); the parsed ROLE is canonicalized, so the row and
    # the summary say `backend` — one spelling everywhere the role is read back.
    assert "frite (backend)" in text
    assert "x86 (standalone-thin)" in text
    # ...in platform_rank order, which is NOT alphabetical here
    assert text.index("rpi5 (") < text.index("frite (") < text.index("x86 (")
    # .platforms stays the plain alphabetical set the pickers filter on
    assert session.platforms == ["frite", "rpi5", "x86"]


# ---- session completeness ------------------------------------------------------------
# The shape of out/sessions/20260819-125930-89bb8e: a mesh build that ABORTED with
# 1 bootable image where 4 per-image build logs (and a 7-image manifest) say more
# was intended. Offering it as "the session" silently emulates a fraction of the
# configured mesh, so pickers badge it and the default selection skips it.

def _partial_session(root, name, *, images, logs=(), manifest_images=0, mtime=None):
    sess = root / "out" / "sessions" / name
    sess.mkdir(parents=True)
    _write(str(sess), *images)
    for log in logs:
        (sess / log).write_text("…")
    if manifest_images:
        (sess / qt.MESH_MANIFEST_NAME).write_text(json.dumps(
            {"format": 2, "images": [{"id": f"img{i}"} for i in range(manifest_images)]}))
    if mtime is not None:
        os.utime(sess, (mtime, mtime))
    return sess


def test_expected_image_count_prefers_build_logs_over_the_manifest(tmp_path):
    """A per-image log exists only for a build that STARTED, so the log count is
    what the run attempted — the aborted 08-19 session reads "1 of 4", not
    "1 of 7", because three manifest images never even began. The shared build.log
    is not a per-image log and must not count."""
    sess = _partial_session(
        tmp_path, "20260819-125930-89bb8e",
        images=["hugmesh-x86-amd64-pki-test-20260819T195951Z.img.xz"],
        logs=["build.log", "build-pki.x86.log", "build-pki.rpi5.log",
              "build-backend.x86.log", "build-backend.rpi5.log"],
        manifest_images=7)
    assert qt.expected_image_count(str(sess)) == 4
    session, = qt.discover_sessions(str(tmp_path))
    assert session.expected_images == 4
    assert session.is_partial
    assert session.completeness_badge() == "PARTIAL — 1 of 4 image(s)"
    assert "[PARTIAL — 1 of 4 image(s)]" in session.summary()


def test_expected_image_count_falls_back_to_the_manifest(tmp_path):
    """A builder that died before minting a single per-image log still declared its
    intent in the mesh manifest."""
    sess = _partial_session(
        tmp_path, "20260819-000000-dead00",
        images=["hugmesh-x86-amd64-pki-test-20260819T000000Z.img"],
        logs=["build.log"], manifest_images=3)
    assert qt.expected_image_count(str(sess)) == 3
    session, = qt.discover_sessions(str(tmp_path))
    assert session.is_partial and "1 of 3" in session.completeness_badge()


def test_sessions_without_intent_witnesses_read_complete(tmp_path):
    """No logs, no manifest: nothing can accuse the session of missing images, and
    a corrupt manifest is 'unknown', never a crash or a false PARTIAL."""
    sess = _partial_session(tmp_path, "20260101-000000-bare00",
                            images=["hugmesh-x86-amd64-pki-test-20260101T000000Z.img"])
    assert qt.expected_image_count(str(sess)) == 0
    (sess / qt.MESH_MANIFEST_NAME).write_text("{not json")
    assert qt.expected_image_count(str(sess)) == 0
    session, = qt.discover_sessions(str(tmp_path))
    assert not session.is_partial and session.completeness_badge() == ""


def test_default_session_is_the_newest_complete_one(tmp_path):
    """The newest session being an aborted build must not become the default: its
    images are individually runnable, but 'the whole mesh' from it is a fraction of
    what was configured. Only when EVERY session is partial does the newest partial
    win — runnable-with-a-badge beats nothing."""
    _partial_session(
        tmp_path, "20260810-000000-comple",
        images=["hugmesh-x86-amd64-pki-test-20260810T000000Z.img"],
        logs=["build-pki.x86.log"], mtime=1_000_000_000)
    _partial_session(
        tmp_path, "20260819-125930-89bb8e",
        images=["hugmesh-x86-amd64-pki-test-20260819T195951Z.img.xz"],
        logs=["build-pki.x86.log", "build-pki.rpi5.log",
              "build-backend.x86.log", "build-backend.rpi5.log"],
        mtime=2_000_000_000)
    # newest_session keeps its historical meaning: literally the newest.
    assert qt.newest_session(str(tmp_path)).name == "20260819-125930-89bb8e"
    assert qt.default_session(str(tmp_path)).name == "20260810-000000-comple"

    # All partial: the newest partial is still offered rather than nothing.
    import shutil as _shutil
    _shutil.rmtree(tmp_path / "out" / "sessions" / "20260810-000000-comple")
    assert qt.default_session(str(tmp_path)).name == "20260819-125930-89bb8e"
    assert qt.default_session(str(tmp_path / "nowhere")) is None


def test_the_operators_branded_pi_session_lists_complete_and_becomes_the_default(tmp_path):
    """THE REPORTED DEFECT, at session level: "mesh emulation screen dropdown can't
    seem to use the 3 pi images session that completed successfully".

    out/sessions/20260830-185641-8e88a6 is a FINISHED three-image Pi mesh — three
    .img.xz, three per-image build logs that all reach the post-install banner, a
    format-2 manifest listing pki/be/fe — and the picker showed nothing at all,
    with "No build session under out/sessions/ holds a bootable image yet".

    Its one distinguishing property is that it was built ``--brand sdhm``, so every
    artifact is named ``sdhm-…`` instead of ``hugmesh-…``. The parser required the
    default brand, so ``discover_rows`` returned [], ``has_images`` was False, and
    ``discover_sessions(only_with_images=True)`` — what the picker is filled from —
    dropped the session before the UI ever saw it.

    Asserted end to end here because the failure was invisible one layer at a time:
    the images existed, the logs said the build finished, and the manifest was
    valid; only the JOIN of "name -> row -> session" was empty.
    """
    sess = _branded_pi_session(tmp_path)

    rows = qt.discover_rows(str(sess))
    assert [r.label for r in rows] == ["rpi5/backend", "rpi5/frontend", "rpi5/pki"]
    # the .iso / .stage4.tar.xz / .fs.tar.xz siblings are not bootable disks
    assert [os.path.basename(r.image) for r in rows] == [
        "sdhm-rpi5-arm64-backend-test-20260831T025801Z.img.xz",
        "sdhm-rpi5-arm64-frontend-test-20260831T033915Z.img.xz",
        "sdhm-rpi5-arm64-pki-test-20260831T015954Z.img.xz",
    ]
    assert {r.brand for r in rows} == {"sdhm"}

    session, = qt.discover_sessions(str(tmp_path))
    assert session.name == "20260830-185641-8e88a6"
    assert session.expected_images == 3 and len(session.rows) == 3
    # COMPLETE, not "PARTIAL — 0 of 3": the picker used to badge this finished build
    # as an aborted one whenever it was asked to list image-less sessions at all.
    assert not session.is_partial
    assert session.completeness_badge() == ""
    assert "3 image(s): rpi5 (backend, frontend, pki)" in session.summary()
    assert qt.default_session(str(tmp_path)).name == session.name


def test_a_branded_session_does_not_lose_the_partial_badge(tmp_path):
    """Reading the brand must not also make every branded session read "complete".

    The aborted sibling on the same box, out/sessions/20260830-173335-d51b24, is
    two per-image logs, a finished .stage4.tar.xz and a ZERO-BYTE .img from the run
    that was killed. It has to stay 0-of-2 and stay out of the default selection —
    the newest session being an abort is the trap ``default_session`` exists for,
    and it would be reintroduced by counting the empty image as a row.
    """
    _branded_pi_session(tmp_path)
    os.utime(tmp_path / "out" / "sessions" / "20260830-185641-8e88a6",
             (1_000_000_000, 1_000_000_000))

    abort = tmp_path / "out" / "sessions" / "20260830-173335-d51b24"
    abort.mkdir(parents=True)
    (abort / "sdhm-rpi5-arm64-pki-test-20260831T003614Z.img").write_bytes(b"")
    _write(str(abort), "sdhm-rpi5-arm64-pki-test-20260831T003614Z.stage4.tar.xz")
    for log in ("build-pki.rpi5.log", "build-be.rpi5.log"):
        (abort / log).write_text("…")
    os.utime(abort, (2_000_000_000, 2_000_000_000))

    by_name = {s.name: s for s in
               qt.discover_sessions(str(tmp_path), only_with_images=False)}
    assert by_name["20260830-173335-d51b24"].completeness_badge() == \
        "PARTIAL — 0 of 2 image(s)"
    # the newest session is the abort; the default must still be the finished one
    assert qt.newest_session(str(tmp_path)).name == "20260830-185641-8e88a6"
    assert qt.default_session(str(tmp_path)).name == "20260830-185641-8e88a6"


def test_manifest_and_log_spellings_match_their_authors():
    """qemu_tests spells the manifest/log names locally to stay import-light; the
    OWNING modules are worklist_driver (manifest) and build_sessions (logs). Drift
    in either direction silently turns every session into 'complete'."""
    from hugmesh_studio.core import build_sessions, worklist_driver
    assert qt.MESH_MANIFEST_NAME == worklist_driver.MANIFEST_NAME
    assert qt.SHARED_BUILD_LOG == build_sessions.LOG_NAME
    assert build_sessions.image_log_name("pki.x86") == \
        qt.IMAGE_LOG_PREFIX + "pki.x86" + qt.IMAGE_LOG_SUFFIX


def test_runner_command_defaults_and_filters():
    opts = qt.QemuRunOptions(artifacts_dir="/art", work_dir="/work", platform="rpi5",
                             jobs=3, mem_mb=4096, timeout_s=1800)
    cmd = qt.runner_command("/gen", opts)
    assert cmd[0] == os.path.join("/gen", qt.RUNNER_SCRIPT)
    assert cmd[cmd.index("--artifacts") + 1] == "/art"
    assert cmd[cmd.index("--platform") + 1] == "rpi5"
    assert cmd[cmd.index("--jobs") + 1] == "3"
    assert cmd[cmd.index("--mem") + 1] == "4096"
    assert cmd[cmd.index("--timeout") + 1] == "1800"
    # golden is the runner's own default; not emitting it keeps the preview readable
    # and lets a future default change live in one place (the shell script).
    assert "--mode" not in cmd
    assert "--list" not in cmd


def test_runner_command_defaults_the_work_dir_under_the_generator():
    """``--work`` is the one envelope flag with a computed default, and it is always
    emitted: the runner caches multi-GB decompressed images, per-row results and the
    device registry under it, and core/qemu_devices.py resolves saves against the
    SAME directory (its ``default_work_dir``). A drifted default does not fail — it
    quietly splits the run and the saves across two trees.
    """
    from hugmesh_studio.core import qemu_devices

    cmd = qt.runner_command("/gen", qt.QemuRunOptions())
    assert cmd[cmd.index("--work") + 1] == os.path.join("/gen", qt.DEFAULT_WORK_SUBDIR)
    assert cmd[cmd.index("--work") + 1] == qemu_devices.default_work_dir("/gen")
    # an explicit work dir still wins
    explicit = qt.runner_command("/gen", qt.QemuRunOptions(work_dir="/scratch"))
    assert explicit[explicit.index("--work") + 1] == "/scratch"


def test_runner_command_emits_every_row_filter():
    """--platform / --role / --only / --only-exact are four DIFFERENT ways to narrow
    the matrix, and each is silently ignorable: a filter that never reaches the argv
    boots the whole fan-out (hours of TCG guests) instead of the one row asked for.
    Absent from a default argv, verbatim when set.
    """
    default = qt.runner_command("/gen", qt.QemuRunOptions())
    for flag in ("--platform", "--role", "--only", "--only-exact"):
        assert flag not in default

    cmd = qt.runner_command("/gen", qt.QemuRunOptions(
        platform="rpi5", role="pki", only="rpi5/pki", only_exact="rpi5/pki"))
    assert cmd[cmd.index("--platform") + 1] == "rpi5"
    assert cmd[cmd.index("--role") + 1] == "pki"
    assert cmd[cmd.index("--only") + 1] == "rpi5/pki"
    assert cmd[cmd.index("--only-exact") + 1] == "rpi5/pki"


def test_runner_command_emits_mode_list_and_build_image():
    cmd = qt.runner_command("/gen", qt.QemuRunOptions(mode="stage4", list_only=True,
                                                      build_image=True, keep=True))
    assert cmd[cmd.index("--mode") + 1] == "stage4"
    assert "--list" in cmd and "--build-image" in cmd and "--keep" in cmd


def test_runner_command_emits_the_t1_knobs_only_when_asked():
    """--only-exact / --assert-timeout / --cache-max-gb / --extra-user are all
    non-default knobs: absent from a default argv (the shell stays the home of the
    defaults) and emitted verbatim when set."""
    default = qt.runner_command("/gen", qt.QemuRunOptions())
    for flag in ("--only-exact", "--assert-timeout", "--cache-max-gb", "--extra-user"):
        assert flag not in default

    cmd = qt.runner_command("/gen", qt.QemuRunOptions(
        only_exact="x86/backend", assert_timeout_s=900, cache_max_gb=120,
        extra_users=("alice", "bob")))
    assert cmd[cmd.index("--only-exact") + 1] == "x86/backend"
    assert cmd[cmd.index("--assert-timeout") + 1] == "900"
    assert cmd[cmd.index("--cache-max-gb") + 1] == "120"
    users = [cmd[i + 1] for i, a in enumerate(cmd) if a == "--extra-user"]
    assert users == ["alice", "bob"]


def test_read_results_sorts_failures_first(tmp_path):
    results = tmp_path / "results"
    results.mkdir()
    for label, status in (("rpi5_frontend", "PASS"), ("rpi5_pki", "FAIL"),
                          ("x86_fe", "ERROR")):
        (results / f"{label}.json").write_text(json.dumps({
            "label": label.replace("_", "/"), "status": status,
            "assertions_passed": 1, "assertions_failed": 0, "duration_s": 5}))
    got = qt.read_results(str(tmp_path))
    assert [r["status"] for r in got] == ["FAIL", "ERROR", "PASS"]
    assert qt.results_summary(got) == (1, 2, 3)


def test_read_results_survives_a_corrupt_file(tmp_path):
    """A half-written result must not blank the whole table."""
    results = tmp_path / "results"
    results.mkdir()
    (results / "good.json").write_text(json.dumps({"label": "a", "status": "PASS"}))
    (results / "bad.json").write_text("{not json")
    assert [r["label"] for r in qt.read_results(str(tmp_path))] == ["a"]


def test_read_results_scopes_to_this_runs_labels(tmp_path):
    """Rows from an earlier run must not be reported as this run's outcome.

    The results dir lives under the persistent work dir (it caches multi-GB
    decompressed images and is never wiped), so it accumulates every row ever
    run. Reading it wholesale showed a one-image session as an 8-device matrix,
    mixing artifacts and days.
    """
    results = tmp_path / "results"
    results.mkdir()
    for name, label, status in (("rpi5_pki.json", "rpi5/pki", "PASS"),
                                ("x86_be.json", "x86/backend", "FAIL"),
                                ("x86_omnibus.json", "x86/omnibus", "PASS")):
        (results / name).write_text(json.dumps({"label": label, "status": status}))

    scoped = qt.read_results(str(tmp_path), labels=["rpi5/pki"])
    assert [r["label"] for r in scoped] == ["rpi5/pki"]
    # No labels = legacy whole-dir read, still supported for ad-hoc inspection.
    assert len(qt.read_results(str(tmp_path))) == 3
    # An empty label list is "this run had no rows", NOT "show me everything".
    assert qt.read_results(str(tmp_path), labels=[]) == []


def test_result_filename_matches_the_runner(tmp_path):
    """Mirrors RESULT_JSON in docker-entrypoint.sh: label -> <platform>_<role>.json."""
    assert qt.result_filename("rpi5/pki") == "rpi5_pki.json"
    assert qt.result_filename("x86/standalone-thin") == "x86_standalone-thin.json"


def test_read_results_empty_without_dir(tmp_path):
    assert qt.read_results(str(tmp_path)) == []


#: The two cross-checks below shell out to the real script; both carry this mark.
#: It used to sit on ``_shell_rows`` instead, where pytest never reads it — a mark
#: on a plain helper does nothing, so a missing runner ERRORed the tests it was meant
#: to skip.
_needs_runner = pytest.mark.skipif(not os.path.exists(RUNNER),
                                   reason="runner script not present")


def _docker_usable() -> str:
    """Empty string when run-qemu-docker.sh can get far enough to --list.

    Returns the REASON it cannot, otherwise "". The script's preflight is two
    checks, both ABOVE row discovery and both reached even for --list (--list
    only sets LIST_ONLY at parse time, run-qemu-docker.sh:329):

        run-qemu-docker.sh:1753  command -v docker >/dev/null || die "docker not found"
        run-qemu-docker.sh:1754  docker info >/dev/null 2>&1  || die "cannot talk to the docker daemon ..."

    so the CLI merely being on PATH is not enough — a host with docker installed
    but the user outside the `docker` group dies on the second line. Both are
    checked here for that reason.
    """
    if shutil.which("docker") is None:
        return "docker CLI absent"
    try:
        probe = subprocess.run(["docker", "info"], capture_output=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as exc:   # pragma: no cover
        return f"docker info failed to run: {exc}"
    if probe.returncode != 0:                              # pragma: no cover
        return "docker daemon unreachable (user not in the 'docker' group?)"
    return ""


_DOCKER_WHY = _docker_usable()

#: #326 item 2. The seven cross-checks below execute the REAL run-qemu-docker.sh
#: --list, so they inherit its docker preflight. In an image without docker they
#: did not fail because the contract they pin is broken — they failed before the
#: script parsed a single artifact name, on "[qemu-docker] ERROR: docker not found".
#:
#: MEASURED 2026-09-09, this file only, on one tree:
#:   dev host (docker present):        63 passed in 0.68s
#:   python:3-slim, the test:studio-suite image, no docker:
#:                                     7 failed, 54 passed, 2 skipped
#: All 7 failures were this preflight; the 7 are exactly the tests marked here.
#:
#: A skip is what this suite's own rule prescribes for this shape —
#: studio/tests/known-failures.txt: "a missing optional dependency is an
#: importorskip in the test, a stale pin is a fix to the pin, a live drift is a
#: fix to the artifact. Only a real defect this pipeline did not cause belongs in
#: a deselect." That header records eight tests already converted from deselects
#: to importorskip for the identical reason (the workflow installs no Qt binding).
#: So these SKIP where docker is absent and still RUN, unchanged, everywhere it is
#: present — which is where the shell-vs-python contract can actually be checked.
#:
#: DELIBERATELY NOT DONE: relaxing the runner's own preflight so --list works
#: without docker. Enumerating artifact rows arguably needs no daemon, but that is
#: a change to production behaviour to suit a test environment, and it is not what
#: #326 asked for. If it is ever made, delete this mark rather than leaving a guard
#: that skips something now runnable.
_needs_docker = pytest.mark.skipif(bool(_DOCKER_WHY),
                                   reason=f"run-qemu-docker.sh preflight: {_DOCKER_WHY}")


def _shell_rows(tmp_path) -> set[tuple[str, str]]:
    """(label, image basename) pairs from the real runner's --list."""
    proc = subprocess.run(
        ["bash", RUNNER, "--artifacts", str(tmp_path), "--work", str(tmp_path / "w"), "--list"],
        capture_output=True, text=True, timeout=120)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    rows = set()
    for line in proc.stdout.splitlines():
        parts = line.split()
        # rows render as: "<n> <platform> <role> <env> <image>"
        if len(parts) >= 5 and parts[0].isdigit():
            rows.add((f"{parts[1]}/{parts[2]}", parts[4]))
    return rows


def _py_rows(tmp_path) -> set[tuple[str, str]]:
    return {(r.label, r.basename) for r in qt.discover_rows(str(tmp_path))}


@_needs_runner
@_needs_docker
def test_shell_and_python_agree_on_row_discovery(tmp_path):
    """The shell runner and this module must select the SAME rows.

    They parse artifact names independently (bash in run-qemu-docker.sh, Python here),
    so drift in either direction would silently boot the wrong image for a row. This is
    the only test that can catch that, and it needs no docker: --list enumerates and
    exits before the image build or any container starts.

    The comparison includes the chosen IMAGE, not just the label. Comparing labels
    alone is what let the two implementations diverge unnoticed: both agreed there
    was one ``rpi5/pki`` row while disagreeing about which artifact it meant.
    """
    _write(str(tmp_path), *_REAL_NAMES)
    assert _shell_rows(tmp_path) == _py_rows(tmp_path)


@_needs_runner
@_needs_docker
def test_shell_and_python_agree_on_which_build_wins(tmp_path):
    """Parity under ambiguity: same role rebuilt, and one artifact in both forms.

    Six files collapse to two rows. Before the fix bash emitted all six and Python
    emitted two stale ones — agreeing on neither count nor content.
    """
    _write(str(tmp_path),
           "hugmesh-rpi5-arm64-pki-test-20260807T153808Z.img",
           "hugmesh-rpi5-arm64-pki-test-20260807T153808Z.img.xz",
           "hugmesh-rpi5-arm64-pki-test-20260814T160000Z.img",
           "hugmesh-x86-amd64-be-test-20260814T112817Z.img",
           "hugmesh-x86-amd64-be-test-20260814T112817Z.img.xz",
           "hugmesh-x86-amd64-be-test-20260801T090000Z.img")

    expected = {
        ("rpi5/pki", "hugmesh-rpi5-arm64-pki-test-20260814T160000Z.img"),
        ("x86/backend", "hugmesh-x86-amd64-be-test-20260814T112817Z.img"),
    }
    assert _py_rows(tmp_path) == expected
    assert _shell_rows(tmp_path) == expected


@_needs_runner
@_needs_docker
def test_shell_and_python_agree_on_branded_artifacts(tmp_path):
    """Parity across BRANDS — the half of the contract the fix had to keep.

    Both sides carried the same ``hugmesh-`` literal, so both were wrong together
    and this cross-check stayed green on a defect that hid a whole session. It can
    only see the drift if the sample names include a brand that is not the default,
    so the operator's real sdhm names are used, plus a ``gentoo-`` unaffiliated
    build and an ``acme-`` third slug.

    The REJECTIONS are in the sample on purpose: the brand check is gone, so the
    field-count and stamp-shape rules are all that keep a foreign .img out, and bash
    and Python have to refuse the same ones. The last two are short names that DO
    end in a real stamp, which is the only shape the stamp anchor cannot refuse on
    its own — without them the field-count rule is unguarded on both twins, and a
    one-field remainder parses into platform == arch == role == env == the stamp.
    """
    _write(str(tmp_path),
           *_BRANDED_PI_NAMES,
           "gentoo-x86-amd64-standalone-unaffiliated-test-20260901T120000Z.img",
           "acme-jetson-arm64-edge_ai-prod-20260719T000000Z.img",
           "a-very-long-user-named-backup-file.img",
           "sdhm-rpi5-arm64-pki-test-notastamp.img",
           "hugmesh-20260831T015954Z.img",
           "sdhm-rpi5-20260831T015954Z.img")

    expected = {
        ("rpi5/backend", "sdhm-rpi5-arm64-backend-test-20260831T025801Z.img.xz"),
        ("rpi5/frontend", "sdhm-rpi5-arm64-frontend-test-20260831T033915Z.img.xz"),
        ("rpi5/pki", "sdhm-rpi5-arm64-pki-test-20260831T015954Z.img.xz"),
        ("jetson/edge-ai", "acme-jetson-arm64-edge_ai-prod-20260719T000000Z.img"),
        ("x86/standalone-unaffiliated",
         "gentoo-x86-amd64-standalone-unaffiliated-test-20260901T120000Z.img"),
    }
    assert _py_rows(tmp_path) == expected
    assert _shell_rows(tmp_path) == expected


@_needs_runner
@_needs_docker
def test_shell_and_python_agree_that_a_zero_byte_image_is_not_a_row(tmp_path):
    """Both twins skip the builder's pre-partition placeholder, or the two
    enumerations disagree exactly on an aborted session — the one place a wrong
    answer is most expensive."""
    (tmp_path / "sdhm-rpi5-arm64-pki-test-20260831T003614Z.img").write_bytes(b"")
    _write(str(tmp_path), "sdhm-rpi5-arm64-backend-test-20260831T025801Z.img")
    expected = {("rpi5/backend",
                 "sdhm-rpi5-arm64-backend-test-20260831T025801Z.img")}
    assert _py_rows(tmp_path) == expected
    assert _shell_rows(tmp_path) == expected


# ── A brand may contain '-', and only the manifest knows where it ends ───────
# ``validate_brand`` (core/validate.py) accepts any DNS label, and a DNS label may
# hold hyphens — so ``--brand my-mesh`` is legal and mints
# ``my-mesh-rpi5-arm64-pki-test-<stamp>.img``. Splitting that positionally reads
# brand=my, platform=mesh, arch=rpi5, role=arm64-pki: the session would list as
# COMPLETE while planning a device whose platform no launcher can dispatch, and
# flash-disk.sh would call one rpi5 dir a cross-platform ambiguity. Before the
# brand stopped anchoring such a session was merely invisible; the fix has to end
# the brand correctly, not just stop matching it.
_HYPHEN_BRAND_MANIFEST = {
    "format": 2, "brand": "my-mesh", "brand_title": "My Mesh",
    "images": [{"id": "pki.rpi5", "role": "pki", "platform": "rpi5"}],
}


def test_declared_brand_reads_the_session_manifest(tmp_path):
    (tmp_path / qt.MESH_MANIFEST_NAME).write_text(json.dumps(_HYPHEN_BRAND_MANIFEST))
    assert qt.declared_brand(str(tmp_path)) == "my-mesh"


def test_declared_brand_is_empty_without_a_usable_manifest(tmp_path):
    """No manifest, unreadable JSON, and a manifest that names no brand all mean
    "fall back to the positional split" — never a crash, and never a filter."""
    assert qt.declared_brand(str(tmp_path)) == ""
    (tmp_path / qt.MESH_MANIFEST_NAME).write_text("{not json")
    assert qt.declared_brand(str(tmp_path)) == ""
    (tmp_path / qt.MESH_MANIFEST_NAME).write_text(json.dumps({"format": 2}))
    assert qt.declared_brand(str(tmp_path)) == ""
    (tmp_path / qt.MESH_MANIFEST_NAME).write_text(json.dumps({"brand": 7}))
    assert qt.declared_brand(str(tmp_path)) == ""


def test_a_hyphenated_brand_is_ended_by_name_not_by_position():
    name = "my-mesh-rpi5-arm64-pki-test-20260831T015954Z.img"
    # Positional: every field shifts one to the left and all four are wrong.
    assert qt.parse_artifact_name(name) == ("mesh", "rpi5", "arm64-pki", "test")
    # Told where the brand ends, the same name parses correctly.
    assert qt.parse_artifact_name(name, "my-mesh") == ("rpi5", "arm64", "pki", "test")
    assert qt.artifact_brand(name, "my-mesh") == "my-mesh"
    assert qt.artifact_stamp(name, "my-mesh") == "20260831T015954Z"


def test_a_declared_brand_needs_the_trailing_hyphen_to_match():
    """Brand "exam" must not swallow the head of ``example-…`` — the strip is
    ``<brand>-``, not a bare prefix, or one brand truncates another's platform."""
    name = "example-rpi5-arm64-pki-test-20260831T015954Z.img"
    assert qt.parse_artifact_name(name, "exam") == ("rpi5", "arm64", "pki", "test")
    assert qt.artifact_brand(name, "exam") == "example"


def test_a_hyphenated_brand_session_plans_the_right_devices(tmp_path):
    """End to end through discover_rows: the manifest is beside the artifacts, so
    nothing has to be threaded in by a caller."""
    (tmp_path / qt.MESH_MANIFEST_NAME).write_text(json.dumps(_HYPHEN_BRAND_MANIFEST))
    _write(str(tmp_path),
           "my-mesh-rpi5-arm64-pki-test-20260831T015954Z.img",
           "my-mesh-rpi5-arm64-backend-test-20260831T025801Z.img")
    rows = qt.discover_rows(str(tmp_path))
    assert [r.label for r in rows] == ["rpi5/backend", "rpi5/pki"]
    assert {r.arch for r in rows} == {"arm64"}
    assert {r.brand for r in rows} == {"my-mesh"}


def test_a_declared_brand_still_never_rejects_a_foreign_one(tmp_path):
    """The manifest brand ends a field; it does NOT filter. An ``out/`` dir holding
    another brand's image must still enumerate it — filtering on the brand is the
    defect this whole change exists to remove, and re-introducing it as
    "only the declared brand counts" would hide exactly the same sessions."""
    (tmp_path / qt.MESH_MANIFEST_NAME).write_text(json.dumps(_HYPHEN_BRAND_MANIFEST))
    _write(str(tmp_path),
           "my-mesh-rpi5-arm64-pki-test-20260831T015954Z.img",
           "hugmesh-x86-amd64-be-test-20260814T112817Z.img")
    assert {r.label for r in qt.discover_rows(str(tmp_path))} == {"rpi5/pki", "x86/backend"}


@_needs_runner
@_needs_docker
def test_shell_and_python_agree_on_a_hyphenated_brand(tmp_path):
    """Parity for the manifest lookup itself. The shell twin reads the brand out of
    the same file with sed rather than a JSON parser, so this is the only check that
    the two agree about a hyphenated brand — and it is written against a manifest
    serialized WITHOUT indent, because worklist_driver writes it with indent=2 and a
    line-anchored sed would pass on the pretty form while diverging on the compact
    one."""
    (tmp_path / qt.MESH_MANIFEST_NAME).write_text(json.dumps(_HYPHEN_BRAND_MANIFEST))
    _write(str(tmp_path),
           "my-mesh-rpi5-arm64-pki-test-20260831T015954Z.img",
           "my-mesh-rpi5-arm64-backend-test-20260831T025801Z.img",
           "hugmesh-x86-amd64-be-test-20260814T112817Z.img")
    expected = {
        ("rpi5/pki", "my-mesh-rpi5-arm64-pki-test-20260831T015954Z.img"),
        ("rpi5/backend", "my-mesh-rpi5-arm64-backend-test-20260831T025801Z.img"),
        ("x86/backend", "hugmesh-x86-amd64-be-test-20260814T112817Z.img"),
    }
    assert _py_rows(tmp_path) == expected
    assert _shell_rows(tmp_path) == expected


def test_runner_script_is_executable():
    """run-qemu-docker.sh must keep its +x bit.

    The Studio spawns it as argv[0] (``QemuRunner.run`` -> ``subprocess.Popen``,
    and every ``*_argv`` builder in core/emulation.py and core/qemu_devices.py puts
    the script path first), NOT as ``bash <script>``. Strip the mode bit and every
    one of those becomes OSError -> "could not start the runner", at the moment an
    operator tries to boot a device.

    Nothing else in the suite can see this: the two ``--list`` cross-checks above
    invoke it through ``bash``, which runs a non-executable file happily. A lost
    mode bit is also invisible in a review diff and survives a merge, so the check
    covers BOTH the file on disk and the mode git has recorded — a commit that drops
    it to 100644 leaves this developer's checkout executable and only breaks on the
    next fresh clone.
    """
    assert os.path.isfile(RUNNER), f"missing runner: {RUNNER}"
    assert os.access(RUNNER, os.X_OK), "run-qemu-docker.sh must keep its +x bit"
    with open(RUNNER, "rb") as fh:
        assert fh.read(2) == b"#!", "run-qemu-docker.sh must keep its shebang"

    try:
        tracked = subprocess.run(
            ["git", "ls-files", "-s", "--", qt.RUNNER_SCRIPT],
            cwd=GENERATOR_DIR, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as exc:   # pragma: no cover
        pytest.skip(f"git unavailable: {exc}")
    if tracked.returncode != 0 or not tracked.stdout.strip():   # pragma: no cover
        pytest.skip("not a git checkout")
    assert tracked.stdout.split()[0] == "100755", \
        f"git has run-qemu-docker.sh as mode {tracked.stdout.split()[0]}, not 100755"


@pytest.mark.skipif(shutil.which("docker") is None, reason="docker not installed")
def test_docker_available_returns_a_reason():
    ok, why = qt.docker_available()
    assert isinstance(ok, bool) and why


def test_docker_available_async_probes_off_thread(monkeypatch):
    """The pages froze 15s in initializePage running docker_available inline. The
    async variant must return a started daemon thread immediately, run the SAME
    probe with the SHORT timeout, and deliver (ok, reason) through the callback —
    including when the probe itself blows up (a mute probe thread is a page that
    says 'checking…' forever)."""
    import threading

    seen = {}

    def _fake_available(timeout_s=15.0):
        seen["timeout"] = timeout_s
        return False, "no daemon here"

    monkeypatch.setattr(qt, "docker_available", _fake_available)
    delivered = []
    done = threading.Event()

    def _cb(ok, why):
        delivered.append((ok, why))
        done.set()

    thread = qt.docker_available_async(_cb)
    assert thread.daemon
    assert done.wait(10), "the probe callback never fired"
    thread.join(10)
    assert delivered == [(False, "no daemon here")]
    assert seen["timeout"] == qt.DOCKER_PROBE_TIMEOUT_S
    assert qt.DOCKER_PROBE_TIMEOUT_S < 15   # the whole point: shorter than inline

    def _boom(timeout_s=15.0):
        raise RuntimeError("docker exploded")

    monkeypatch.setattr(qt, "docker_available", _boom)
    delivered.clear()
    done.clear()
    qt.docker_available_async(_cb).join(10)
    assert delivered and delivered[0][0] is False
    assert "docker exploded" in delivered[0][1]


def _mini_repo(tmp_path):
    """A throwaway generator checkout holding just what ``--list`` reads.

    The session picker keys off ``${REPO_DIR}/out/sessions/*/``, and REPO_DIR is
    derived from the script's own location, so the only way to exercise the picker
    is to run a COPY of the runner from a fabricated tree. Passing ``--artifacts``
    (what every other cross-check here does) skips the picker entirely, which is
    exactly why the picker went uncovered.
    """
    repo = tmp_path / "repo"
    (repo / "tests" / "qemu").mkdir(parents=True)
    (repo / "scripts").mkdir(parents=True)
    shutil.copy2(RUNNER, repo / qt.RUNNER_SCRIPT)
    # The only two files the runner reads before it prints rows: the roles library
    # it sources, and the identity reader it die()s on the absence of.
    shutil.copy2(os.path.join(GENERATOR_DIR, "scripts", "_roles-lib.sh"),
                 repo / "scripts" / "_roles-lib.sh")
    shutil.copy2(os.path.join(GENERATOR_DIR, "tests", "qemu", "mesh-identities.sh"),
                 repo / "tests" / "qemu" / "mesh-identities.sh")
    return repo


def _shell_picked_session(repo):
    """The artifacts dir the runner resolves ON ITS OWN, with no --artifacts."""
    proc = subprocess.run(
        ["bash", str(repo / qt.RUNNER_SCRIPT), "--work", str(repo / "w"), "--list"],
        capture_output=True, text=True, timeout=120)
    if proc.returncode != 0:
        return None, proc.stdout + proc.stderr
    for line in proc.stdout.splitlines():
        if line.strip().startswith("artifacts :"):
            return line.split(":", 1)[1].strip(), proc.stdout
    return None, proc.stdout


@_needs_runner
@_needs_docker
def test_shell_and_python_agree_on_which_session_is_the_default(tmp_path):
    """The runner's SESSION picker must apply the same "holds an image" rule its
    row discovery does.

    The picker used to select on bare existence (``compgen -G '<dir>/*.img'``) while
    discover_rows had been tightened to skip a zero-byte placeholder and to require a
    ``YYYYmmddTHHMMSSZ`` stamp. A killed build leaves exactly such a placeholder in a
    session NEWER than the last finished one, so the picker chose the aborted session,
    row discovery then correctly found nothing in it, and the run died at "no runnable
    rows found" WITHOUT falling through to the finished build sitting right next to it
    — the CLI half of the very "my completed session is invisible" symptom this
    resolver exists to prevent, and reachable from a bare ``make qemu-docker-list``.

    Python never had the split (``default_session`` is built FROM the rows), so the
    Studio offered a session the CLI swore did not exist. This pins the two together.
    """
    repo = _mini_repo(tmp_path)
    good = repo / "out" / "sessions" / "20260901-000000-good"
    abort = repo / "out" / "sessions" / "20260902-000000-abort"
    nostamp = repo / "out" / "sessions" / "20260903-000000-nostamp"
    for d in (good, abort, nostamp):
        d.mkdir(parents=True)
    _write(str(good),
           "sdhm-rpi5-arm64-pki-test-20260901T010000Z.img.xz",
           "sdhm-rpi5-arm64-backend-test-20260901T020000Z.img.xz")
    # The two ways a NEWER session can hold a file that is not a bootable artifact:
    # the builder's pre-partition placeholder, and a name carrying no build stamp.
    (abort / "sdhm-rpi5-arm64-pki-test-20260902T003614Z.img").write_bytes(b"")
    _write(str(nostamp), "sdhm-x86-be.img")
    # ls -1dt orders by mtime, so make the decoys unambiguously newer.
    for i, d in enumerate((good, abort, nostamp)):
        os.utime(d, (1_790_000_000 + i * 86400,) * 2)

    picked, out = _shell_picked_session(repo)
    assert picked == str(good), f"runner picked {picked!r}, wanted {good}\n{out}"

    session = qt.default_session(str(repo))
    assert session is not None and session.path == str(good)
    # Same session AND the same rows in it — a picker that agreed by luck while
    # enumerating different images would still boot the wrong thing.
    assert {r.basename for r in session.rows} == {
        "sdhm-rpi5-arm64-pki-test-20260901T010000Z.img.xz",
        "sdhm-rpi5-arm64-backend-test-20260901T020000Z.img.xz",
    }
    assert qt.discover_rows(str(abort)) == []
    assert qt.discover_rows(str(nostamp)) == []


@_needs_runner
@_needs_docker
def test_the_session_picker_reads_each_session_s_own_declared_brand(tmp_path):
    """The manifest lookup has to happen PER SESSION DIR, inside row discovery.

    The picker walks every ``out/sessions/*/`` before ``--artifacts`` has a value,
    so a brand read once into a script-global — from ``${ARTIFACTS}``, at parse
    time — is empty for the whole scan and stale for the listing that follows.
    A hyphenated brand would then fall back to the positional split on the ONLY
    path a bare ``make qemu-docker-list`` takes: shell rows ``mesh/arm64-pki``
    against Python's ``rpi5/pki``, the two twins silently disagreeing about what
    the same session holds. Passing ``--artifacts`` hides it, which is why this
    goes through the picker.
    """
    repo = _mini_repo(tmp_path)
    session = repo / "out" / "sessions" / "20260901-000000-hyphen"
    session.mkdir(parents=True)
    (session / qt.MESH_MANIFEST_NAME).write_text(json.dumps(_HYPHEN_BRAND_MANIFEST))
    _write(str(session),
           "my-mesh-rpi5-arm64-pki-test-20260901T010000Z.img.xz",
           "my-mesh-rpi5-arm64-backend-test-20260901T020000Z.img.xz")

    picked, out = _shell_picked_session(repo)
    assert picked == str(session), f"runner picked {picked!r}, wanted {session}\n{out}"
    shell_rows = {f"{p[1]}/{p[2]}" for p in
                  (line.split() for line in out.splitlines())
                  if len(p) >= 5 and p[0].isdigit()}
    assert shell_rows == {"rpi5/pki", "rpi5/backend"}, out

    py_session = qt.default_session(str(repo))
    assert py_session is not None and py_session.path == str(session)
    assert {r.label for r in py_session.rows} == shell_rows
    assert {r.brand for r in py_session.rows} == {"my-mesh"}
