# SPDX-License-Identifier: Apache-2.0
"""The BFF<->worker seam, pinned from the JAVA side's point of view.

WHY THIS FILE EXISTS. Until 2026-08-14 this worker served exactly one /poison encoding
(multipart image=/mode=/sizes=, returning raw image bytes) and had no /survival at all,
while hugmesh-user-bff-api's PoisonWorkerClient sent a completely different request
(application/octet-stream + X-Cloak-* headers), decoded a completely different response
(the JSON PoisonModels.PoisonResult), and called /survival. Both sides had tests. Both
sides passed. Neither side had a test that spoke the OTHER side's wire format, so every
real cloak attempt died on a bare 422 and the gate 404'd, in a feature whose /health
probe stayed green the whole time.

So the assertions here are deliberately written against the Java contract as the source
of truth — the exact header names PoisonWorkerClient sets, the exact JSON field names
PoisonModels declares — rather than against whatever this module happens to do. A test
that only asks "does the worker do what the worker does" is what let the drift through.

Reference (hugmesh-user-bff-api):
  media/PoisonWorkerClient.java  — sets X-Cloak-Mode / -Filename / -Content-Type /
                                   -Thumbnail-Sizes, POSTs octet-stream, decodes
                                   PoisonResult; POSTs /survival with -Mode / -Size.
  media/PoisonModels.java        — record PoisonResult(boolean ok, String backend,
                                   byte[] poisonedOriginal, List<SizedBytes> thumbnails,
                                   String detail)
                                   record SurvivalVerdict(boolean present, Double score,
                                   String detail)
"""

from __future__ import annotations

import base64
import io

import pytest

pytest.importorskip("fastapi", reason="worker HTTP tests need fastapi")
pytest.importorskip("PIL", reason="perturbation tests need Pillow")
pytest.importorskip("numpy", reason="perturbation tests need numpy")

import numpy as np  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402
from PIL import Image  # noqa: E402

from app.main import app  # noqa: E402
from app.poison import SURVIVAL_MIN_SCORE  # noqa: E402

client = TestClient(app)

# ── the exact header names the Java client sets (PoisonWorkerClient) ──────────────
H_MODE = "X-Cloak-Mode"
H_FILENAME = "X-Cloak-Filename"
H_CONTENT_TYPE = "X-Cloak-Content-Type"
H_SIZES = "X-Cloak-Thumbnail-Sizes"
H_SIZE = "X-Cloak-Size"

# What the BFF actually puts in X-Cloak-Thumbnail-Sizes: application.yml's
# app.media.poisoning.thumbnail-sizes, "akkoma 'small'; Matrix 240x240". LABELS, not
# ints — the original int-only parser dropped both.
BFF_SIZES = "small,240x240"


def photo_like(width: int = 320, height: int = 240) -> bytes:
    """A JPEG with gradients, grain and a hard-edged object.

    Not a flat or synthetic field: a constant image makes any correlation detector look
    far better than it is, so the discrimination assertions below would be vacuous.
    """
    rng = np.random.default_rng(11)
    yy, xx = np.mgrid[0:height, 0:width]
    base = (120 + 60 * np.sin(xx / 90.0) + 40 * np.cos(yy / 70.0)).astype(np.float32)
    base += rng.normal(0, 12, (height, width))
    base[40:140, 60:200] += 45
    arr = np.clip(np.dstack([base, base * 0.95, base * 0.9]), 0, 255).astype(np.uint8)
    buf = io.BytesIO()
    Image.fromarray(arr).save(buf, format="JPEG", quality=92)
    return buf.getvalue()


def bff_poison(payload: bytes, mode: str = "glaze", sizes: str = BFF_SIZES):
    """POST /poison EXACTLY as PoisonWorkerClient.poison() does."""
    return client.post(
        "/poison",
        content=payload,
        headers={
            "Content-Type": "application/octet-stream",
            H_MODE: mode,
            H_FILENAME: "upload.png",
            H_CONTENT_TYPE: "image/png",
            H_SIZES: sizes,
        },
    )


class TestPoisonSpeaksTheBffsWire:
    def test_the_bffs_exact_request_is_accepted(self) -> None:
        """The regression guard for the live 422.

        Before the fix this asserted-shape request returned 422 Unprocessable Content
        from FastAPI (no multipart 'image' field), which the BFF logged as
        "poison job failed (mode=glaze)" and turned into status=failed on every upload.
        """
        r = bff_poison(photo_like())
        assert r.status_code == 200, r.text

    def test_response_carries_every_field_PoisonResult_declares(self) -> None:
        body = bff_poison(photo_like()).json()
        # Jackson maps these names verbatim; a rename here is a silent null there.
        assert set(body) >= {"ok", "backend", "poisonedOriginal", "thumbnails", "detail"}
        assert body["ok"] is True
        assert isinstance(body["detail"], str)

    def test_poisonedOriginal_is_base64_because_java_declares_byte_array(self) -> None:
        """PoisonResult.poisonedOriginal is byte[]; Jackson decodes byte[] from base64.

        Returning the bytes as a raw body (what this worker used to do) leaves that
        field null, and MediaPoisonService treats a null poisonedOriginal as failure —
        so the shape matters as much as the status code.
        """
        body = bff_poison(photo_like()).json()
        decoded = base64.b64decode(body["poisonedOriginal"], validate=True)
        assert decoded[:2] == b"\xff\xd8", "expected re-encoded JPEG bytes"
        assert decoded != photo_like(), "bytes must actually be perturbed"

    def test_backend_is_one_of_the_tokens_the_java_enum_parses(self) -> None:
        # PoisonModels.Backend: cuda | rocm | cpu | none.
        assert bff_poison(photo_like()).json()["backend"] in {"cuda", "rocm", "cpu", "none"}

    def test_thumbnails_is_a_list_so_List_copyOf_cannot_npe(self) -> None:
        assert isinstance(bff_poison(photo_like()).json()["thumbnails"], list)

    def test_mode_none_forwards_unchanged(self) -> None:
        src = photo_like()
        body = bff_poison(src, mode="none").json()
        assert body["ok"] is True
        assert base64.b64decode(body["poisonedOriginal"]) == src

    def test_undecodable_input_is_415_not_a_pretend_success(self) -> None:
        """A non-image must NOT come back ok=true — the BFF would upload it and the gate
        would then be measuring bytes nothing ever perturbed."""
        assert bff_poison(b"definitely not an image").status_code == 415

    @pytest.mark.parametrize("sizes", ["small,240x240", "small", "240x240", "", "garbage"])
    def test_the_served_size_labels_never_break_the_call(self, sizes: str) -> None:
        """The BFF sends LABELS. Unparseable ones must degrade to defaults, not 500."""
        assert bff_poison(photo_like(), sizes=sizes).status_code == 200


class TestSurvivalGate:
    def test_endpoint_exists(self) -> None:
        """It 404'd before this change, so the BFF's gate could never return true and no
        upload could ever earn 'protected'."""
        r = client.post("/survival", content=photo_like(),
                        headers={"Content-Type": "application/octet-stream",
                                 H_MODE: "glaze", H_SIZE: "original"})
        assert r.status_code == 200, r.text

    def test_verdict_field_names_match_SurvivalVerdict(self) -> None:
        body = client.post("/survival", content=photo_like(),
                           headers={H_MODE: "glaze", H_SIZE: "original"}).json()
        assert set(body) >= {"present", "score", "detail"}
        assert isinstance(body["present"], bool)

    def test_a_cloaked_image_is_detected(self) -> None:
        poisoned = base64.b64decode(bff_poison(photo_like()).json()["poisonedOriginal"])
        body = client.post("/survival", content=poisoned,
                           headers={H_MODE: "glaze", H_SIZE: "original"}).json()
        assert body["present"] is True
        assert body["score"] >= SURVIVAL_MIN_SCORE

    def test_a_CLEAN_image_is_NOT_detected(self) -> None:
        """The half of the pair that gives the other half its meaning: a gate that says
        'present' for everything is worse than no gate, because it launders an
        unprotected upload into a 'protected' badge."""
        body = client.post("/survival", content=photo_like(),
                           headers={H_MODE: "glaze", H_SIZE: "original"}).json()
        assert body["present"] is False
        assert body["score"] < SURVIVAL_MIN_SCORE

    def test_survives_a_same_size_reencode(self) -> None:
        """What the homeserver does to a full-size original."""
        poisoned = base64.b64decode(bff_poison(photo_like()).json()["poisonedOriginal"])
        im = Image.open(io.BytesIO(poisoned)).convert("RGB")
        out = io.BytesIO()
        im.save(out, format="JPEG", quality=85)
        body = client.post("/survival", content=out.getvalue(),
                           headers={H_MODE: "glaze", H_SIZE: "original"}).json()
        assert body["present"] is True

    def test_does_NOT_survive_a_downscale_and_says_so(self) -> None:
        """Pins the KNOWN LIMITATION rather than hiding it (see detect_perturbation's
        measured table): _lean_perturb's pattern is in pixel coordinates and discards
        `sizes`, so a thumbnail is effectively clean and the gate must report that.
        If a future backend makes the pattern scale-invariant this test SHOULD fail —
        that is the signal to update poison.py's claim about per-size poisoning."""
        poisoned = base64.b64decode(bff_poison(photo_like()).json()["poisonedOriginal"])
        im = Image.open(io.BytesIO(poisoned)).convert("RGB")
        im = im.resize((im.width // 2, im.height // 2), Image.LANCZOS)
        out = io.BytesIO()
        im.save(out, format="JPEG", quality=80)
        body = client.post("/survival", content=out.getvalue(),
                           headers={H_MODE: "thumbnail" and "glaze", H_SIZE: "thumbnail"}).json()
        assert body["present"] is False

    def test_unmeasurable_input_fails_honest(self) -> None:
        body = client.post("/survival", content=b"not an image",
                           headers={H_MODE: "glaze", H_SIZE: "original"}).json()
        assert body["present"] is False
        assert body["score"] is None


class TestLegacyMultipartStillWorks:
    """The previously documented encoding. Kept working so the fix is additive."""

    def test_multipart_returns_raw_image_bytes(self) -> None:
        r = client.post("/poison",
                        files={"image": ("a.jpg", photo_like(), "image/jpeg")},
                        data={"mode": "glaze", "sizes": "240"})
        assert r.status_code == 200
        assert r.headers["content-type"] == "image/jpeg"
        assert r.content != photo_like()

    def test_multipart_without_the_image_field_is_422(self) -> None:
        assert client.post("/poison", data={"mode": "glaze"},
                           files={"wrong": ("a.jpg", photo_like(), "image/jpeg")}).status_code == 422
