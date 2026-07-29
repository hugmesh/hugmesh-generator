"""Phoneme -> viseme collapse table for the even-split viseme timeline (v1).

The TTS service does NOT ship a renderer. It hands the matrix-ui VN client a small,
deterministic viseme timeline; the client maps each viseme key onto a mouth shape.

╔══════════════════════════════════════════════════════════════════════════════╗
║ CONTRACT — KEEP IN SYNC WITH matrix-ui viseme.ts (B3-PR2).                    ║
║ The 7-key VISEME vocabulary below is the wire contract. If you add/rename a   ║
║ key here you MUST mirror it in matrix-ui's viseme.ts mouth-shape map, or the  ║
║ client will fall back to `rest` for the unknown key (lipsync degrades to a    ║
║ closed mouth — safe, but silent on that phoneme).                            ║
╚══════════════════════════════════════════════════════════════════════════════╝

7-key viseme vocabulary (Preston-Blair-ish, collapsed for 2D VN mouths):
    rest  — neutral/closed mouth, silence, and any unmapped phoneme (fail-safe)
    AI    — open front/central vowels: a, ah, ay, eye  (wide-open mouth)
    E     — mid/close front vowels: e, eh, ee          (spread, slightly open)
    O     — rounded back vowels: o, oh, aw, ow          (rounded, medium open)
    U     — close rounded vowels + w/r glides: oo, u, w (tight rounded / pucker)
    L     — tongue-tip / dental: l, t, d, n, s, z, th   (tongue visible, teeth)
    MBP   — bilabial closures: m, b, p                  (lips pressed together)

Phonemes arrive as espeak-ng IPA-ish symbols from piper-phonemize (the same
phonemizer Piper itself uses). We normalise to a base symbol (strip stress
marks, length marks, ties) and look it up. Multi-char IPA symbols are checked
before single chars so e.g. "tʃ" collapses before "t".
"""
from __future__ import annotations

# The 7 keys, exported so app.py and tests can assert the vocabulary is closed.
VISEME_KEYS: tuple[str, ...] = ("rest", "AI", "E", "O", "U", "L", "MBP")

REST = "rest"

# Diacritics / suprasegmentals we strip before lookup. espeak-ng emits primary
# (ˈ) and secondary (ˌ) stress, length (ː), syllabic and tie marks, and spaces.
_STRIP = "ˈˌːˑ̩̯͡‿ \t\n.,;:!?\"'"

# Multi-character IPA clusters are matched first (longest-prefix), then singles.
# Keys are normalised (stress/length already stripped); values are viseme keys.
_PHONEME_TO_VISEME: dict[str, str] = {
    # ── affricates / multi-char consonants (check before single chars) ──
    "tʃ": "L",   # ch
    "dʒ": "L",   # j (judge)
    "ʃ": "L",    # sh
    "ʒ": "L",    # vision
    "θ": "L",    # th (thin)
    "ð": "L",    # th (this)
    "ŋ": "L",    # ng
    # ── diphthongs (espeak often emits as two symbols, but cover the glyphs) ──
    "aɪ": "AI",  # eye
    "eɪ": "E",   # ay
    "ɔɪ": "O",   # boy
    "aʊ": "O",   # ow
    "oʊ": "O",   # oh
    "əʊ": "O",   # (RP) oh
    "ɪə": "E",   # ear
    "eə": "E",   # air
    "ʊə": "U",   # tour
    # ── open / central vowels -> AI ──
    "a": "AI", "ɑ": "AI", "ɐ": "AI", "ʌ": "AI", "æ": "AI", "ɒ": "AI",
    "ə": "AI",  # schwa — neutral; AI keeps the mouth gently moving (vs rest)
    # ── front vowels -> E ──
    "e": "E", "ɛ": "E", "i": "E", "ɪ": "E", "ɜ": "E", "ɝ": "E",
    # ── rounded back vowels -> O ──
    "o": "O", "ɔ": "O",
    # ── close rounded vowels + rounded glides -> U ──
    "u": "U", "ʊ": "U", "ʉ": "U", "y": "U", "w": "U", "ʍ": "U",
    "r": "U", "ɹ": "U", "ɚ": "U",  # rhotic glide rounds/protrudes the lips
    # ── bilabial closures -> MBP ──
    "m": "MBP", "b": "MBP", "p": "MBP",
    # ── labiodental -> MBP-ish closure (lip to teeth); group with MBP ──
    "f": "MBP", "v": "MBP",
    # ── tongue-tip / coronal / sibilant / velar -> L ──
    "l": "L", "ɫ": "L", "t": "L", "d": "L", "n": "L", "ɲ": "L",
    "s": "L", "z": "L", "k": "L", "ɡ": "L", "g": "L", "h": "L",
    "j": "L",  # palatal glide (yes) — tongue raised, mouth spread; group with L
    "ʔ": "L", "x": "L", "ç": "L", "ʁ": "L", "ɣ": "L",
}

# Longest multi-char IPA keys first, so "tʃ" wins over "t".
_MULTI = sorted((k for k in _PHONEME_TO_VISEME if len(k) > 1), key=len, reverse=True)


def normalize(phoneme: str) -> str:
    """Strip stress/length/tie/punct marks from one espeak-ng symbol."""
    return "".join(ch for ch in phoneme if ch not in _STRIP)


def to_viseme(phoneme: str) -> str:
    """Map a single (raw) espeak-ng phoneme symbol to one of VISEME_KEYS.

    Fail-safe: any symbol we do not recognise collapses to `rest` (closed mouth),
    never an exception — a missing mapping must never break synthesis.
    """
    p = normalize(phoneme)
    if not p:
        return REST
    if p in _PHONEME_TO_VISEME:
        return _PHONEME_TO_VISEME[p]
    # longest-prefix match for un-split clusters (e.g. "tʃ" inside a token)
    for cluster in _MULTI:
        if p.startswith(cluster):
            return _PHONEME_TO_VISEME[cluster]
    # try the first base character (covers length-marked / decorated vowels)
    if p[0] in _PHONEME_TO_VISEME:
        return _PHONEME_TO_VISEME[p[0]]
    return REST


def collapse_runs(visemes: list[str]) -> list[str]:
    """Collapse consecutive identical visemes into one (so "AAAII" -> "AI").

    Adjacent identical mouth shapes look the same on screen; collapsing them
    yields fewer, longer holds which read better for short VN lines.
    """
    out: list[str] = []
    for v in visemes:
        if not out or out[-1] != v:
            out.append(v)
    return out
