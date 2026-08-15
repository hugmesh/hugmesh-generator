# SPDX-License-Identifier: Apache-2.0
"""Perturbation backends for hugmesh-media-poisoner.

This module hosts the actual image-perturbation logic. The shipped default is a
small, CPU-portable, dependency-light perturbation so the worker is usable on any
node (including a Pi5-only cluster where the GPU node is absent and the operator
runs the worker on CPU for testing). The GPU / production paths (PGD against a
Stable-Diffusion VAE/encoder, and the full Glaze/Nightshade reference) are
documented as follow-ups below and selected at runtime via ``detect_backend()``.

DESIGN CONTRACT (do not break — the BFF depends on it):
  * ``perturb(image_bytes, mode, sizes) -> bytes`` returns re-encoded image bytes
    with an additive, bounded perturbation applied. It NEVER raises on a valid
    image; on an unsupported mode it falls back to the lean perturbation.
  * The perturbation is BEST-EFFORT training-set hygiene, NOT a guarantee. The BFF
    is responsible for the round-trip survival gate (re-fetch the homeserver-served
    bytes and confirm the signal survived) and for honest UI copy
    ("AI-cloak applied", never "protected"). This worker only applies bytes.

LICENSE NOTE (load-bearing — read before swapping in a real backend):
  Glaze and Nightshade are distributed by the University of Chicago SAND Lab as
  NON-COMMERCIAL research binaries. A default-on, federated, potentially-branded
  deployment MUST NOT ship those binaries. The production path here is the OPEN
  PyTorch *reference* approach (an L-inf-bounded PGD adversarial perturbation
  against the same Stable-Diffusion VAE/encoder the published technique targets),
  implemented from public descriptions under a permissive license — NOT the SAND
  Lab binaries. Verify the license of any model weights you mount (the SD VAE is
  CreativeML OpenRAIL-M; confirm it is acceptable for the deployment) BEFORE
  enabling a non-lean backend. See README.md.
"""

from __future__ import annotations

import io
import math
import os
from dataclasses import dataclass


# Modes the BFF may request. Strength is monotonic: none < light < glaze < nightshade.
MODE_NONE = "none"
MODE_LIGHT = "light"
MODE_GLAZE = "glaze"
MODE_NIGHTSHADE = "nightshade"
KNOWN_MODES = (MODE_NONE, MODE_LIGHT, MODE_GLAZE, MODE_NIGHTSHADE)

# Normalised-correlation threshold above which the cloak counts as STILL PRESENT in a
# re-fetched artifact (see detect_perturbation). Calibrated on the shipped lean
# perturbation: a clean photograph scores near zero because it has no reason to carry
# energy at the pattern's exact frequency AND phase, while even the weakest mode
# ("light", budget 2/255) survives a JPEG round-trip well clear of this line. Set
# deliberately BELOW the weakest mode's margin rather than midway, because the cost of
# the two errors is asymmetric: a false negative only under-claims (the UI says
# "degraded" for an image that is in fact cloaked), while a false positive would tell
# a user they are protected when they are not.
SURVIVAL_MIN_SCORE = 0.05


@dataclass(frozen=True)
class Backend:
    """The compute backend this worker resolved at startup.

    ``kind`` is reported verbatim to the BFF /health so it can render an honest,
    hardware-derived expectation (cuda ~1 min Glaze, cpu ~30s reduced-strength,
    none unavailable). ``available`` False means the worker should not have been
    scheduled (no GPU AND lean fallback disabled) — but we still serve /health so
    the BFF can probe and degrade to warn-before-post.
    """

    kind: str  # one of: cuda | rocm | cpu | none
    available: bool


def detect_backend() -> Backend:
    """Probe the available compute backend WITHOUT importing heavy deps at module load.

    Order: explicit override -> CUDA -> ROCm -> CPU. Torch is imported lazily and
    its absence is non-fatal: the lean CPU perturbation needs only Pillow+numpy, so
    a stripped image still reports ``cpu`` and works. This is what lets the same
    image run on the GPU node (reports cuda/rocm) and, for testing, on a Pi-class
    CPU (reports cpu) — the BFF reads the difference and sets expectations.
    """

    override = os.environ.get("POISON_BACKEND", "").strip().lower()
    if override in {"cuda", "rocm", "cpu", "none"}:
        return Backend(kind=override, available=override != "none")

    try:  # torch is OPTIONAL — only the GPU/SD-VAE PGD path needs it.
        import torch  # type: ignore

        if torch.cuda.is_available():  # NVIDIA CUDA build.
            return Backend(kind="cuda", available=True)
        # ROCm presents through the same torch.cuda API on a ROCm torch build;
        # torch.version.hip is set in that case.
        if getattr(torch.version, "hip", None):  # type: ignore[attr-defined]
            return Backend(kind="rocm", available=True)
    except Exception:  # noqa: BLE001 — any import/probe failure -> CPU lean path.
        pass

    return Backend(kind="cpu", available=True)


def _normalize_sizes(sizes: list[int] | None) -> list[int]:
    """The served-size set we must own so no clean derivative exists.

    The BFF enumerates the homeserver-served sizes (akkoma "small";
    Matrix 240x240 thumbnail). Each size is poisoned independently so the
    homeserver's own thumbnail cannot be regenerated clean. Defaults are a safe
    superset when the caller omits the list.
    """

    if not sizes:
        return [240, 480]
    return sorted({int(s) for s in sizes if int(s) > 0})


# ── the perturbation's spatial signature ──────────────────────────────────────────
# Period in pixels of the sinusoidal grid _lean_perturb adds. DEFINED ONCE and shared
# by the generator (_lean_perturb) and the detector (detect_perturbation), because the
# detector works by correlating against this exact basis: if the two ever held their
# own copies of the frequency, the detector would silently stop detecting and the
# survival gate would report "not present" for images that ARE cloaked — a false
# negative that reads to the user as "protection degraded".
_PATTERN_PERIOD_PX = 17.0


def _pattern(height: int, width: int):
    """The perturbation basis for an image of this size, in [-2, 2].

    Low-frequency STRUCTURE (not per-pixel noise) on purpose: it is the kind of thing a
    VAE encoder is sensitive to, and unlike white noise it survives a JPEG re-encode
    well enough for the round-trip gate to measure it.
    """

    import numpy as np  # type: ignore

    yy, xx = np.meshgrid(
        np.arange(height, dtype=np.float32),
        np.arange(width, dtype=np.float32),
        indexing="ij",
    )
    freq = 2.0 * math.pi / _PATTERN_PERIOD_PX
    return np.sin(xx * freq) + np.cos(yy * freq)


def budget_for(mode: str) -> int:
    """L-inf budget (0..255) for a mode. Unknown -> glaze-equivalent, never raises."""

    return {
        MODE_LIGHT: 2,
        MODE_GLAZE: 6,
        MODE_NIGHTSHADE: 10,
    }.get(mode, 6)


def perturb(image_bytes: bytes, mode: str, sizes: list[int] | None) -> bytes:
    """Apply a bounded perturbation and return re-encoded bytes.

    The SHIPPED implementation is the lean CPU perturbation (``_lean_perturb``):
    a tiny, structured, L-inf-bounded additive pattern that nudges VAE/encoder
    features while staying near-imperceptible. It is intentionally weak — labelled
    "light" to the user — and exists so the worker is runnable and the BFF
    round-trip gate is exercisable end-to-end without a GPU.

    Strong modes (glaze/nightshade) currently DELEGATE to the lean perturbation
    with a larger budget; swapping in the real SD-VAE PGD / Glaze-Nightshade
    reference is the documented follow-up (see README "Integration roadmap"). The
    strength scales with mode so the interface is stable across the upgrade.
    """

    if mode == MODE_NONE:
        return image_bytes  # opt-out / non-image: forwarded unchanged by the BFF too.

    return _lean_perturb(image_bytes, budget=budget_for(mode), sizes=_normalize_sizes(sizes))


def detect_perturbation(image_bytes: bytes, mode: str) -> tuple[bool, float | None, str]:
    """Is THIS image still carrying the cloak? -> (present, score, detail).

    The BFF's round-trip survival gate re-fetches what the homeserver actually SERVES
    (after its own re-encode/downscale) and asks this question per artifact. It is the
    difference between "we applied a cloak" and "a cloak is still there", so it must be
    a real measurement — a stub that answers True would turn the whole feature into the
    theatre its own design doc warns against.

    Method: high-pass the image (subtract a Gaussian blur at the pattern's own scale) to
    strip natural low-frequency content, then take the normalised correlation against
    the SAME ``_pattern`` basis the generator added. A clean photograph has no reason to
    carry energy at that exact frequency AND phase, so it scores ~0; a cloaked one scores
    positive. Fail-honest: anything we cannot measure (no Pillow/numpy, undecodable
    bytes, ``mode=none``) returns present=False with the reason, never a hopeful True.

    MEASURED BEHAVIOUR (2026-08-14, 640x480 photo-like source, threshold 0.05):

        clean original            0.006     clean downscaled+reencoded   -0.043
        light   fresh 0.082   JPEG q85 0.067   HALF-SIZE -0.045
        glaze   fresh 0.226   JPEG q85 0.185   HALF-SIZE -0.041
        nightshade    0.357   JPEG q85 0.297   HALF-SIZE -0.035

    So the cloak survives a same-size re-encode comfortably in every mode, and survives
    a 50% DOWNSCALE in NONE of them — a downscaled artifact scores exactly like a clean
    one. That is a real property of the shipped lean perturbation, not a detector
    artifact: ``_pattern`` is defined in PIXEL coordinates, so halving the image halves
    the pattern's period and it no longer matches the basis at any scale.

    Consequence, and it is load-bearing when reading a verdict: the homeserver's own
    THUMBNAIL is effectively clean, so the BFF's gate (which requires EVERY served
    artifact to pass) will report ``degraded`` rather than ``protected`` for a normal
    upload. That verdict is CORRECT — poison.py's own module doc claims each served size
    is "poisoned independently so the homeserver's own thumbnail cannot be regenerated
    clean", and for the lean backend that claim does not hold: ``_lean_perturb``
    explicitly discards ``sizes`` (``_ = sizes``). Closing that gap means either a
    scale-invariant pattern or the real SD-VAE backend from the README roadmap; until
    then the honest ``degraded`` is the point, and this detector is what makes the gap
    visible instead of assumed away.
    """

    if mode == MODE_NONE:
        return False, None, "mode=none: nothing was applied, so nothing can survive"

    try:
        import numpy as np  # type: ignore
        from PIL import Image, ImageFilter  # type: ignore
    except Exception:  # noqa: BLE001 — minimal image without Pillow/numpy.
        return False, None, "Pillow/numpy unavailable: cannot measure"

    try:
        img = Image.open(io.BytesIO(image_bytes)).convert("RGB")
    except Exception:  # noqa: BLE001 — not a decodable image.
        return False, None, "not a decodable image: cannot measure"

    if img.width < 8 or img.height < 8:
        return False, None, "image too small to measure"

    grey = img.convert("L")
    # Blur radius tied to the pattern's own period: big enough to flatten scene content,
    # small enough to leave the pattern standing.
    low = grey.filter(ImageFilter.GaussianBlur(radius=_PATTERN_PERIOD_PX / 2.0))
    residual = np.asarray(grey, dtype=np.float32) - np.asarray(low, dtype=np.float32)

    basis = _pattern(residual.shape[0], residual.shape[1])
    a = residual - residual.mean()
    b = basis - basis.mean()
    denom = float(np.sqrt((a * a).sum()) * np.sqrt((b * b).sum()))
    if denom <= 0.0:
        return False, None, "flat image: no signal to correlate"

    score = float((a * b).sum() / denom)
    present = score >= SURVIVAL_MIN_SCORE
    return present, score, (
        f"normalised correlation {score:.4f} "
        f"{'>=' if present else '<'} threshold {SURVIVAL_MIN_SCORE}"
    )


def _lean_perturb(image_bytes: bytes, budget: int, sizes: list[int]) -> bytes:
    """CPU-portable, dependency-light perturbation (Pillow + numpy).

    Adds a deterministic, spatially-structured, L-inf <= ``budget`` (0..255)
    pattern. This is a PLACEHOLDER for the SD-VAE PGD attack — it perturbs pixels,
    it survives a single round-trip in testing for the gate to measure, and it is
    honest about being weak. It does NOT claim Glaze/Nightshade-grade protection.

    Falls back to returning the original bytes only if Pillow/numpy are missing
    (so the service never 500s on a minimal image), which the BFF then sees as a
    no-op and reports as protection-degraded via the round-trip gate.
    """

    try:
        import numpy as np  # type: ignore
        from PIL import Image  # type: ignore
    except Exception:  # noqa: BLE001 — minimal image without Pillow/numpy.
        return image_bytes

    try:
        img = Image.open(io.BytesIO(image_bytes)).convert("RGB")
    except Exception:  # noqa: BLE001 — not a decodable image; let the BFF forward it.
        return image_bytes

    arr = np.asarray(img, dtype=np.int16)
    h, w, _ = arr.shape

    # A low-frequency sinusoidal grid biases broad regions (the kind of structure
    # a VAE encoder is sensitive to) rather than per-pixel noise that a denoise/
    # re-encode trivially removes. Bounded to +/- budget so it stays subtle.
    # The basis comes from the SHARED _pattern() so detect_perturbation correlates
    # against exactly what was added here (see _PATTERN_PERIOD_PX).
    pattern = np.round(_pattern(h, w) / 2.0 * budget).astype(np.int16)  # +/- budget

    perturbed = np.clip(arr + pattern[:, :, None], 0, 255).astype(np.uint8)
    out = Image.fromarray(perturbed, mode="RGB")

    # Re-encode the ORIGINAL (largest) size at high quality. The BFF separately
    # asks for / derives each served thumbnail size; "sizes" is accepted here so a
    # richer backend can poison each size in one call. The lean backend returns the
    # full-res poisoned original and lets the BFF/homeserver-size enumeration drive
    # per-size handling, while ``sizes`` is recorded for forward-compat.
    _ = sizes
    buf = io.BytesIO()
    out.save(buf, format="JPEG", quality=95, subsampling=0)
    return buf.getvalue()
