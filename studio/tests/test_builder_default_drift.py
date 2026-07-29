"""Builder-drift guards — pin Studio's field-scope model to the builders' OWN source of
truth, in the three-direction style of test_device_catalog.py (which pins the device
catalog to each builder's own "--board/--role must be one of" allowlists).

GUARD B (this file today): ROLE-CLASS HONESTY. config.image_class() splits every role into
"desktop" or "node", and the whole FIELD_SCOPE role-class axis hangs off that split. The
builder has the same concept under its own name — build-x86-host-stage4.sh's ROLE_CLIENT,
set true by exactly the person-device/standalone role arms and consumed ~30 times (Xorg /
lightdm / desktop package set / sizing / branding / proxy-stack / artifact tag). If the two
disagree, Studio gates a widget on a class the builder does not agree the image has, and
every downstream scope decision is quietly wrong. So: parse the builder's role case block
and assert set-equality with image_class(), in both directions.

GUARD A (this file too): SENTINEL COMPLETENESS. build-x86-host-stage4.sh resolves four of
its own defaults with a `[ -z "${VAR}" ] && { COND && VAR=<t> || VAR=<f>; }` sentinel —
GPU_DRIVER :1190, HOME_MODE :1227, INSTALLER_UI :1244, BUNDLE_SOURCE :1248 (the five ARM
builders have none). Each is the builder saying, in its own source, what the right value is
when studio stays quiet. config.BUILDER_DEFAULTS transcribes all four; this guard parses
the real scripts and asserts the transcription matches — variable set, fork condition, and
BOTH arms — and, crucially, that each declared `policy` is the emission studio actually
produces. That last assertion is what makes the table honest rather than aspirational: the
remaining `override` entry (bundle_source) pins a KNOWN GAP (studio emits a flat constant,
so the builder's role-aware line is dead code), so the moment someone fixes it the guard
goes RED and forces the declaration to be updated with it. This is not hypothetical: the
mechanism already fired once for real. installer_ui was declared `override` while its fix
sat in a sibling PR; #384 landed underneath this branch, the marker went RED, and the
declaration was re-earned as `resolve` — which is now itself defended by
test_guard_a_policy_resolve_produces_the_builders_own_arm (a `resolve` must reproduce the
builder's own arm, or it is an `override` with a nicer name).

Pure-core: no Qt import — runs in the headless suite.

PARSING HAZARDS (each one silently BLINDS this guard — i.e. makes it pass while seeing
nothing — so each is handled explicitly below and mutation-proven in the test body):

  H1  build-x86 has FOUR `case "${ROLE}" in` blocks (three at column 0 — the 43-char
      legacy `host` alias fold at :1012, the real 4.5k role block at :1019, the 64-char
      ROLE_TAG fold at :4250 — plus an INDENTED one at :4909, inside a function, emitting
      KEYS-stick hints). A naive first-match grabs the ALIAS FOLD, which contains no
      ROLE_CLIENT at all, and the guard passes VACUOUSLY on an empty set.
      _role_case_block() therefore selects the unique block CONTAINING `ROLE_CLIENT=` and
      asserts exactly one matches. Its `esac` pattern also allows LEADING WHITESPACE: the
      fourth block's `esac` is indented, and a column-0-only pattern dropped it from the
      parser's universe entirely (found by review; see _role_case_block's docstring).

  H2  `ROLE_CLIENT=true` is set MID-LINE (`GPU=true; ROLE_CLIENT=true; ROLE_K8S="none"`),
      so it can NOT be ^-anchored: an anchored grep finds zero and the guard passes
      vacuously. _sets_role_client() anchors on a statement boundary (line start, `;`, `&`,
      or whitespace) instead.

  H3  A COMMENT inside the very same block contains the literal string `ROLE_CLIENT=true`
      (:1065, "Reuse the CLIENT desktop machinery (ROLE_CLIENT=true -> Xorg/lightdm...)").
      It sits in the `desktop)` arm's slice, so an unanchored grep over the raw slice keeps
      reporting `desktop` as a client role even if the REAL assignment is deleted — the
      guard goes blind exactly where it is supposed to bite. This is the same hole found in
      #380's log guard, so comments are STRIPPED before any arm is parsed, and the test
      below mutation-proves that deleting the real assignment goes RED.
"""
from __future__ import annotations

import os
import re

import pytest

from hugmesh_studio.core.config import (
    BUILDER_DEFAULT_POLICIES, BUILDER_DEFAULTS, BUILDER_SCRIPTS, ImageConfig,
    effective_installer_ui, image_class, roles_for_platform,
)

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

# Role tokens the x86 builder accepts as case-arm patterns that are NOT Studio role ids —
# legacy/spelling aliases that fold onto a canonical arm. Allowlisted explicitly (never
# skipped by a blanket "unknown token" rule) so a NEW builder role token cannot appear
# without this guard going RED and forcing a decision about whether Studio should offer it.
BUILDER_ONLY_ROLE_TOKENS = {
    "edge-ai",          # dash spelling of edge_ai (same arm)
    "standalone-full",  # legacy spelling of standalone-thick (same arm)
    "*",                # the `err "--role must be one of..."` catch-all arm
}


def _builder_text(platform: str) -> str:
    with open(os.path.join(GENERATOR_DIR, BUILDER_SCRIPTS[platform]), encoding="utf-8") as fh:
        return fh.read()


def _strip_comments(text: str) -> str:
    """Drop shell comments (full-line and trailing) — H3. `#` only starts a comment at a
    line start or after whitespace; the role block quotes no `#`, which _pin_ below
    asserts rather than assumes."""
    return re.sub(r"(?m)(?:(?<=^)|(?<=\s))#.*$", "", text)


def _role_case_block(text: str) -> str:
    """The body of the ONE `case "${ROLE}" in` block that assigns ROLE_CLIENT — H1.

    The closing `esac` is matched as `\\n\\s*esac`, NOT `\\nesac`: build-x86's fourth role
    case block (KEYS-stick hints) is nested inside a function, so both it and its `esac` are
    INDENTED. A column-0-only `esac` silently drops that block from the parser's universe —
    the guard would then read "exactly ONE block assigns ROLE_CLIENT" while actually meaning
    "exactly one of the THREE column-0 blocks does", and a ROLE_CLIENT assignment added to
    the indented block would be undetected drift in the very invariant H1 exists to protect.
    Mutation-proven: with `\\nesac` the parser finds 3 blocks (43/4512/64 chars) and misses
    the 792-char indented one; with `\\n\\s*esac` it finds all 4 and still yields exactly one
    owning block, so the assertion below is unchanged and green — a free tightening."""
    blocks = [m.group(1) for m in re.finditer(
        r'case\s+"\$\{ROLE\}"\s+in\n(.*?)\n\s*esac', text, re.S)]
    assert len(blocks) >= 4, (
        "expected at least FOUR `case \"${ROLE}\" in` blocks in build-x86 (alias fold, role "
        f"block, ROLE_TAG fold, indented keys-hints block); found {len(blocks)} — the parser "
        "has gone partially blind (an indented `esac` no longer matching would do it).")
    owning = [b for b in blocks if re.search(r"ROLE_CLIENT=", b)]
    assert len(owning) == 1, (
        f"expected exactly ONE `case \"${{ROLE}}\" in` block to assign ROLE_CLIENT, found "
        f"{len(owning)}. If the builder now sets role-class in several places, this guard "
        "must parse all of them — a first-match would go blind (H1).")
    return owning[0]


def _sets_role_client(arm_body: str) -> bool:
    """True iff the arm REALLY assigns ROLE_CLIENT=true — statement-anchored (H2) on a
    comment-stripped body (H3)."""
    return re.search(r"(?:^|[;&|\s])ROLE_CLIENT=true(?:\s|;|$)", arm_body, re.M) is not None


def _builder_role_arms(text: str) -> dict[str, bool]:
    """builder role token -> does its arm set ROLE_CLIENT=true. Alternation patterns
    (`laptop|chromebook)`) expand to one entry per token."""
    body = _strip_comments(_role_case_block(text))
    headers = list(re.finditer(r"(?m)^\s{0,8}([A-Za-z0-9_+*|.-]+)\)", body))
    assert len(headers) >= 10, f"role case block yielded only {len(headers)} arms — parser broke"
    arms: dict[str, bool] = {}
    for i, h in enumerate(headers):
        end = headers[i + 1].start() if i + 1 < len(headers) else len(body)
        client = _sets_role_client(body[h.end():end])
        for tok in h.group(1).split("|"):
            arms[tok] = client
    return arms


ARMS = _builder_role_arms(_builder_text("x86"))
X86_ROLES = roles_for_platform("x86")


def test_role_block_quotes_no_hash():
    """_strip_comments assumes the role block never quotes a `#`. Pin it (if the builder
    ever grows a `#` inside a string here, stripping would eat live code)."""
    for line in _role_case_block(_builder_text("x86")).splitlines():
        code = _strip_comments(line)
        assert code.count('"') % 2 == 0, f"unbalanced quotes after comment strip: {line!r}"


def test_builder_role_arms_are_parsed_non_vacuously():
    """H1/H2/H3 combined: the parse must actually SEE both classes. A vacuous parse (empty
    or all-one-class) is the failure mode every hazard above produces."""
    assert len(ARMS) >= 12, f"parsed only {sorted(ARMS)} — expected every x86 role arm"
    assert any(ARMS.values()), "parsed NO client role — guard is blind (H2/H3)"
    assert not all(ARMS.values()), "parsed NO node role — guard is blind"


def test_builder_role_tokens_are_known():
    """Every case-arm token is either a Studio x86 role id or an explicitly allowlisted
    builder-only alias — a NEW builder role goes RED here rather than sliding past."""
    unknown = set(ARMS) - set(X86_ROLES) - BUILDER_ONLY_ROLE_TOKENS
    assert not unknown, (
        f"build-x86 grew role token(s) {sorted(unknown)} that Studio neither offers nor "
        "allowlists — decide: add to ROLE_CHOICES, or to BUILDER_ONLY_ROLE_TOKENS")


def test_every_studio_x86_role_exists_in_the_builder():
    """Direction 2 (surjectivity): a Studio role the builder's case has no arm for would
    hit the `*)` arm and hard-error '--role must be one of' after dispatch."""
    missing = set(X86_ROLES) - set(ARMS)
    assert not missing, f"Studio offers x86 role(s) {sorted(missing)} the builder rejects"


@pytest.mark.parametrize("role", sorted(X86_ROLES))
def test_image_class_matches_builder_role_client(role):
    """GUARD B proper — image_class() == the builder's own ROLE_CLIENT, role by role."""
    expected = "desktop" if ARMS[role] else "node"
    assert image_class("", role) == expected, (
        f"role {role!r}: build-x86 sets ROLE_CLIENT={str(ARMS[role]).lower()} (=> "
        f"{expected}-class) but config.image_class() says {image_class('', role)!r}. "
        "DESKTOP_ROLES/NODE_ROLES have drifted from the builder — every FIELD_SCOPE "
        "role-class decision for this role is now wrong.")


def test_builder_client_set_equals_studio_desktop_set():
    """The same claim as a set-equality, so a role added to ONE side alone goes RED even
    though the parametrized test above only iterates Studio's side."""
    builder_clients = {r for r, c in ARMS.items() if c and r in X86_ROLES}
    studio_desktops = {r for r in X86_ROLES if image_class("", r) == "desktop"}
    assert builder_clients == studio_desktops, (
        f"builder-only desktops: {sorted(builder_clients - studio_desktops)}; "
        f"Studio-only desktops: {sorted(studio_desktops - builder_clients)}")


# ── mutation proofs: each hazard, and the guard itself, is proven to BITE ────────────
# A guard that cannot fail is not a guard. These run the REAL parser over a MUTATED copy
# of the builder text and assert the parse changes / the comparison flips.

def test_mutation_deleting_a_real_assignment_bites_despite_the_comment():
    """H3 proof, the important one. Delete the REAL `ROLE_CLIENT=true` from the `desktop)`
    arm. The :1065 comment containing the literal string still sits inside that arm's
    slice, so an unstripped parser keeps calling `desktop` a client and stays GREEN. The
    comment-stripping parser must go RED."""
    text = _builder_text("x86")
    mutated = text.replace(
        '    desktop)\n        GPU=true; ROLE_CLIENT=true; ROLE_K8S="none"; ROLE_HEADSCALE=false',
        '    desktop)\n        GPU=true; ROLE_K8S="none"; ROLE_HEADSCALE=false', 1)
    assert mutated != text, "mutation did not apply — the desktop arm was reformatted"
    assert _builder_role_arms(mutated)["desktop"] is False, (
        "guard is BLIND (H3): the real assignment is gone but the parser still reports "
        "desktop as a client — it is reading the comment at :1065")
    # ...and the naive/unstripped parser is proven to be the thing that goes blind, so the
    # stripping is load-bearing rather than decorative.
    naive_body = _role_case_block(mutated)   # NOT comment-stripped
    assert _sets_role_client(naive_body[naive_body.index("desktop)"):]), (
        "expected the unstripped body to still 'see' ROLE_CLIENT=true via the comment — "
        "if this fails, H3 no longer exists and _strip_comments can be revisited")


def test_mutation_flipping_a_node_arm_bites():
    """Guard B proper bites the other way: make the builder call `pki` a client and the
    set-equality must break."""
    text = _builder_text("x86")
    mutated = text.replace(
        '    pki)\n        GPU=false; ROLE_HEADSCALE=true; ROLE_K8S="control-plane"',
        '    pki)\n        GPU=false; ROLE_CLIENT=true; ROLE_HEADSCALE=true; ROLE_K8S="control-plane"', 1)
    assert mutated != text, "mutation did not apply — the pki arm was reformatted"
    arms = _builder_role_arms(mutated)
    assert arms["pki"] is True
    builder_clients = {r for r, c in arms.items() if c and r in X86_ROLES}
    studio_desktops = {r for r in X86_ROLES if image_class("", r) == "desktop"}
    assert builder_clients != studio_desktops, "set-equality guard failed to bite"


def test_mutation_first_match_block_selection_would_be_vacuous():
    """H1 proof: the FIRST `case \"${ROLE}\" in` block is the legacy `host` alias fold and
    contains no ROLE_CLIENT — a first-match parser sees an empty world and passes."""
    text = _builder_text("x86")
    blocks = [m.group(1) for m in re.finditer(
        r'case\s+"\$\{ROLE\}"\s+in\n(.*?)\nesac', text, re.S)]
    assert len(blocks) >= 3, f"expected >=3 role case blocks, got {len(blocks)}"
    assert "ROLE_CLIENT=" not in blocks[0], (
        "the first case block now assigns ROLE_CLIENT — H1's shape changed; re-check that "
        "_role_case_block still selects the right one")
    assert "ROLE_CLIENT=" in _role_case_block(text), "selector picked a block with no ROLE_CLIENT"


def test_mutation_anchored_grep_would_be_vacuous():
    """H2 proof: `ROLE_CLIENT=true` never starts a line, so a ^-anchored matcher finds
    nothing and passes vacuously."""
    body = _strip_comments(_role_case_block(_builder_text("x86")))
    assert not re.search(r"(?m)^ROLE_CLIENT=true", body), (
        "ROLE_CLIENT=true is now ^-anchored somewhere — H2's shape changed")
    assert _sets_role_client(body), "statement-anchored matcher found nothing (H2)"


def test_mutation_a_new_unknown_role_token_bites():
    """The allowlist is a ratchet, not decoration."""
    text = _builder_text("x86")
    mutated = text.replace(
        "    pki)\n", "    kubevirt-host)\n        GPU=true; ROLE_K8S=\"worker\" ;;\n    pki)\n", 1)
    arms = _builder_role_arms(mutated)
    assert "kubevirt-host" in arms
    assert set(arms) - set(X86_ROLES) - BUILDER_ONLY_ROLE_TOKENS == {"kubevirt-host"}


# ══════════════════════════════════════════════════════════════════════════════════════
# GUARD A — sentinel completeness / BuilderDefault honesty
# ══════════════════════════════════════════════════════════════════════════════════════

# The builder's self-resolving-default form:
#     [ -z "${VAR}" ] && { COND && VAR=<t> || VAR=<f>; }
#
# NOT ^-anchored, deliberately — a DEVIATION from the audited regex, and the reason matters.
# The audit's `^\[ -z "\$\{...` anchors at column 0. That happens to be where all four live
# today, so both regexes find the same four; but the anchor's safety is an accident. A new
# sentinel written one space indented (or inside an `if`) would be INVISIBLE to the anchored
# form, and this guard's whole job is to notice new ones — it would pass, vacuously, exactly
# when it must bite. `^[ \t]*` sees those. It costs nothing in precision: requiring the
# `&& {` brace fork still excludes the role-arm one-liners like :1049's
# `[ -z "${GPU_DRIVER}" ] && GPU_DRIVER="nvidia"`, which are a different mechanism (a
# per-role preset, not a global fork), and test_sentinel_regex_excludes_role_arm_presets
# pins that exclusion rather than leaving it to luck.
_SENTINEL_RE = re.compile(
    r'(?m)^[ \t]*\[\s+-z\s+"\$\{(?P<var>[A-Z_]+)\}"\s+\]\s+&&\s+\{\s+'
    r'(?P<cond>.+?)\s+&&\s+(?P=var)=(?P<t>"[^"]*"|[^\s;|]+)\s+\|\|\s+'
    r'(?P=var)=(?P<f>"[^"]*"|[^\s;|]+)\s*;\s*\}')


def _unquote(s: str) -> str:
    return s[1:-1] if len(s) >= 2 and s[0] == '"' and s[-1] == '"' else s


def _sentinels(text: str) -> dict[str, tuple[str, str, str]]:
    """var -> (condition, when_true, when_false) for every sentinel in one builder.
    Comment-stripped first (H3): a commented-out or illustrative sentinel is not code, and
    counting one would be the same class of bug as #380's log guard."""
    out: dict[str, tuple[str, str, str]] = {}
    for m in _SENTINEL_RE.finditer(_strip_comments(text)):
        out[m.group("var")] = (m.group("cond").strip(),
                               _unquote(m.group("t")), _unquote(m.group("f")))
    return out


SENTINELS = {p: _sentinels(_builder_text(p)) for p in BUILDER_SCRIPTS}
DECLARED = {bd.var: (fld, bd) for fld, bd in BUILDER_DEFAULTS.items()}


def test_sentinels_parse_non_vacuously():
    """The parse must actually SEE the sentinels — an empty parse would make every
    set-equality below trivially true."""
    assert len(SENTINELS["x86"]) >= 4, (
        f"parsed only {sorted(SENTINELS['x86'])} sentinels out of build-x86 — parser broke")


def test_guard_a_sentinel_set_matches_declarations():
    """THE guard: the set of variables the builder self-resolves == the set BUILDER_DEFAULTS
    declares. A new builder sentinel that Studio does not know about, or a declaration for a
    sentinel the builder dropped, both go RED here."""
    found = set(SENTINELS["x86"])
    assert found == set(DECLARED), (
        f"builder sentinels {sorted(found)} != declared BuilderDefault vars "
        f"{sorted(DECLARED)}. The builder resolves a default Studio has no record of (or "
        "vice-versa) — reconcile config.BUILDER_DEFAULTS with build-x86-host-stage4.sh.")


def test_guard_a_arm_builders_have_no_sentinels():
    """All four sentinels are x86-only. If an ARM builder grows one, BUILDER_DEFAULTS needs
    a platform axis it does not have today — fail loudly rather than silently mis-model it."""
    for plat, found in SENTINELS.items():
        if plat == "x86":
            continue
        assert not found, (
            f"{BUILDER_SCRIPTS[plat]} grew self-resolving default(s) {sorted(found)}. "
            "BuilderDefault currently assumes x86-only sentinels.")


def test_guard_a_declarations_match_the_real_fork():
    """Not just the NAMES: the fork condition and both arms are transcribed verbatim, so a
    builder-side edit to any part of a sentinel (e.g. flipping BUNDLE_SOURCE's arms, or
    re-forking INSTALLER_UI on something other than ${STANDALONE}) goes RED."""
    for var, (cond, when_true, when_false) in SENTINELS["x86"].items():
        fld, bd = DECLARED[var]
        assert (bd.condition, bd.when_true, bd.when_false) == (cond, when_true, when_false), (
            f"{fld}: declared BuilderDefault({bd.condition!r} ? {bd.when_true!r} : "
            f"{bd.when_false!r}) but build-x86 says ({cond!r} ? {when_true!r} : "
            f"{when_false!r})")


def test_guard_a_policies_are_known():
    for fld, bd in BUILDER_DEFAULTS.items():
        assert bd.policy in BUILDER_DEFAULT_POLICIES, f"{fld}: unknown policy {bd.policy!r}"


def _emits(fld: str, **kw) -> bool:
    """Does to_cli_args mention this field's flag for an x86 image at the field's DATACLASS
    DEFAULT? `--no-bundle-source` and `--bundle-source` both contain "bundle-source", so the
    dashed field name catches either arm of a paired flag."""
    cfg = ImageConfig(platform="x86", **kw)
    return any(fld.replace("_", "-") in tok for tok in cfg.to_cli_args())


def test_guard_a_policy_defer_really_emits_nothing():
    """`defer` is a CLAIM about studio's emission: that the field sits at a dataclass default
    which emits no flag, leaving `[ -z "${VAR}" ]` true so the builder's fork runs. Prove it
    on a desktop-class standalone image (in scope on every axis, so only the default itself
    can be suppressing the flag)."""
    for fld, bd in BUILDER_DEFAULTS.items():
        if bd.policy != "defer":
            continue
        assert not _emits(fld, mode="standalone", role="laptop"), (
            f"{fld} is declared policy='defer', but to_cli_args EMITS its flag at the "
            f"dataclass default — so build-x86's `[ -z \"${{{bd.var}}}\" ]` sentinel is "
            "dead and the builder's role-aware default is unreachable. Either stop emitting "
            "at the default, or change the declaration to describe what the code does.")


def test_guard_a_policy_override_pins_the_known_gap():
    """The two `override` entries are a GAP, recorded on purpose. installer_ui always emits
    `--installer-ui all`, so build-x86:1244 never fires and a headless node gets the ISO
    installer stack; bundle_source always emits, so :1248 never fires. This test pins the
    BROKEN behaviour deliberately: when the owning fix lands, it goes RED and whoever landed
    it must come update BUILDER_DEFAULTS. A gap nobody is forced to revisit is a gap that
    stays."""
    for fld, bd in BUILDER_DEFAULTS.items():
        if bd.policy != "override":
            continue
        assert _emits(fld, mode="standalone", role="laptop"), (
            f"{fld} no longer emits unconditionally — its builder sentinel is reachable "
            f"again. GOOD: now flip BUILDER_DEFAULTS[{fld!r}].policy from 'override' to "
            "'defer' (or 'resolve') to match.")


# How to ask, for each policy='resolve' field, what value the BUILD will actually receive.
# Deliberately the real production read-path (never a re-implementation of the rule): for
# installer_ui that is core.config.effective_installer_ui, the same helper #384's GUI combo
# and command pane consult, which itself runs resolve_installer_ui_default on a probe copy.
_RESOLVE_PROBES = {
    "installer_ui": effective_installer_ui,
}


def test_guard_a_policy_resolve_produces_the_builders_own_arm():
    """A `resolve` declaration must be EARNED, not asserted. For every field declared
    policy='resolve', studio must compute — at materialize time — the SAME value the
    builder's own sentinel would have chosen for that image, i.e. the declared
    ``when_false`` arm for a node-class image (the sentinel's condition is ${STANDALONE},
    and a node is never standalone).

    This is what makes `resolve` different from `override`: both emit a flat explicit value
    instead of letting `[ -z ... ]` fire, but `resolve` emits the value the sentinel WOULD
    have produced, so the outcome is identical to deferring. If a future edit changes the
    resolver's target value without changing the builder, this goes RED — the declaration
    can no longer quietly become a lie.

    History: installer_ui was declared `override` (a recorded GAP) while its fix lived in a
    sibling PR. #384 landed the fix (resolve_installer_ui_default, called from
    worklist._materialize_one and app.py --print-command) and the scope-marker that guarded
    the gap went RED exactly as designed, which is why the declaration is now `resolve`."""
    for fld, bd in BUILDER_DEFAULTS.items():
        if bd.policy != "resolve":
            continue
        probe = _RESOLVE_PROBES.get(fld)
        assert probe is not None, (
            f"{fld} is declared policy='resolve' but has no probe in _RESOLVE_PROBES, so "
            "nothing checks that its resolver reproduces the builder's arm. Add one — an "
            "unprobed 'resolve' is an undefended claim.")
        cfg = ImageConfig(platform="x86", mode="mesh", role="pki")  # node-class => false arm
        assert image_class(cfg.mode, cfg.role) == "node", "fixture drifted: expected node-class"
        resolved = probe(cfg)
        assert resolved == bd.when_false, (
            f"{fld} is declared policy='resolve', but materialize resolves it to "
            f"{resolved!r} while the builder's own sentinel "
            f"(`[ -z \"${{{bd.var}}}\" ]`, condition {bd.condition}) would pick "
            f"{bd.when_false!r} for a node-class image. A 'resolve' that does not reproduce "
            "the builder's arm is an 'override' wearing a friendlier label — either fix the "
            "resolver or re-declare the policy honestly.")


# ---- mutation proofs: every assertion above must BITE ---------------------------------

def test_mutation_a_fifth_sentinel_bites():
    """Inject a new builder sentinel -> the set-equality must go RED ("builder resolves a
    default Studio has no record of")."""
    text = _builder_text("x86")
    mutated = text.replace(
        '[ -z "${BUNDLE_SOURCE}" ] && {',
        '[ -z "${TELEMETRY}" ] && { ${STANDALONE} && TELEMETRY=on || TELEMETRY=off; }\n'
        '[ -z "${BUNDLE_SOURCE}" ] && {', 1)
    assert mutated != text, "mutation anchor missed — the sentinel text changed"
    assert set(_sentinels(mutated)) - set(DECLARED) == {"TELEMETRY"}


def test_mutation_an_indented_sentinel_is_still_seen():
    """The reason this guard is NOT ^-anchored (see _SENTINEL_RE). Indent a new sentinel by
    four spaces: the audited `^\\[ -z` regex goes blind and passes vacuously; ours bites."""
    text = _builder_text("x86")
    injected = '    [ -z "${TELEMETRY}" ] && { ${STANDALONE} && TELEMETRY=on || TELEMETRY=off; }\n'
    mutated = text.replace('[ -z "${BUNDLE_SOURCE}" ] && {',
                           injected + '[ -z "${BUNDLE_SOURCE}" ] && {', 1)
    anchored = re.compile(r'(?m)^\[ -z "\$\{([A-Z_]+)\}" \] && \{')
    assert "TELEMETRY" not in set(anchored.findall(mutated)), (
        "the ^-anchored form was supposed to MISS an indented sentinel — premise changed")
    assert "TELEMETRY" in set(_sentinels(mutated)), "unanchored parser missed it too"


def test_mutation_a_lost_sentinel_bites():
    """Delete build-x86:1244 (installer_ui's fork — the exemplar) -> RED the other way: a
    declaration for a sentinel the builder no longer has."""
    text = _builder_text("x86")
    mutated = text.replace(
        '[ -z "${INSTALLER_UI}" ] && { ${STANDALONE} && INSTALLER_UI=all || INSTALLER_UI=cli; }\n',
        "", 1)
    assert mutated != text, "mutation anchor missed — build-x86:1244 changed shape"
    assert set(DECLARED) - set(_sentinels(mutated)) == {"INSTALLER_UI"}


def test_mutation_a_flipped_arm_bites():
    """Swap BUNDLE_SOURCE's arms in the builder -> the verbatim-fork assertion must catch it.
    This is the half a name-only guard (the audited shape) could never see."""
    text = _builder_text("x86")
    mutated = text.replace(
        '${STANDALONE} && BUNDLE_SOURCE=true || BUNDLE_SOURCE=false;',
        '${STANDALONE} && BUNDLE_SOURCE=false || BUNDLE_SOURCE=true;', 1)
    assert mutated != text, "mutation anchor missed"
    cond, t, f = _sentinels(mutated)["BUNDLE_SOURCE"]
    bd = BUILDER_DEFAULTS["bundle_source"]
    assert (bd.when_true, bd.when_false) != (t, f), "flipped arms went unnoticed"


def test_a_commented_out_sentinel_is_not_counted():
    """A sentinel inside a comment is not code; counting one would invent a builder default
    that does not exist (#380's log-guard hole).

    HONESTY NOTE, because the first draft of this test asserted a hazard that does not
    exist: unlike GUARD B's H3 — where a comment sits INSIDE the arm slice being scanned and
    genuinely blinds the guard — a commented-out sentinel is already unreachable for GUARD A
    on its own, because `_SENTINEL_RE` requires `[` to be the first non-whitespace on the
    line and a comment always puts `#` there first. So this is belt-and-braces, and the
    assertion is only that the two independent defences agree. The claim that an unstripped
    parser would be fooled here was checked and is FALSE; it is not asserted."""
    text = _builder_text("x86")
    mutated = text.replace(
        '[ -z "${BUNDLE_SOURCE}" ] && {',
        '# [ -z "${TELEMETRY}" ] && { ${STANDALONE} && TELEMETRY=on || TELEMETRY=off; }\n'
        '[ -z "${BUNDLE_SOURCE}" ] && {', 1)
    assert mutated != text, "mutation anchor missed"
    assert "TELEMETRY" not in _sentinels(mutated), "a COMMENTED sentinel was counted as code"
    assert "TELEMETRY" not in {m.group("var") for m in _SENTINEL_RE.finditer(mutated)}, (
        "the line-start anchor stopped excluding full-line comments — _strip_comments is "
        "now load-bearing for GUARD A and this test should assert that instead")


def test_sentinel_regex_excludes_role_arm_presets():
    """build-x86:1049 (`[ -z "${GPU_DRIVER}" ] && GPU_DRIVER="nvidia"`, inside the edge_ai
    arm) is a per-ROLE preset, not a global fork: no brace, no COND ? a : b. It must not be
    read as a sentinel — doing so would make GPU_DRIVER's declaration unrepresentable and
    the fork assertion nonsense. Pin the exclusion instead of trusting it."""
    body = _role_case_block(_builder_text("x86"))
    assert '[ -z "${GPU_DRIVER}" ] && GPU_DRIVER="nvidia"' in body, (
        "build-x86's edge_ai GPU_DRIVER preset moved — this exclusion test needs a new anchor")
    assert not _sentinels(body), f"role-arm presets were misparsed as sentinels: {_sentinels(body)}"


# ── the secureboot cert-without-key preflight must stay EXPLICIT-ONLY ──────────────────
# Finding 2 added a hard error for "--secureboot-cert with no --secureboot-key" (a cert
# alone is inert: the signing block keys off SECUREBOOT_KEY, so passing one silently signs
# with a throwaway key and ships an image that will not boot under Secure Boot).
#
# The first cut gated it on ${SECUREBOOT_CERT} — the variable --keys-usb AUTO-DISCOVERY also
# writes. The two discovery probes are independent `-f` tests, so a KEYS USB carrying only
# the public kernel_key.der (private key withheld / on an HSM — a normal shape) sets CERT,
# leaves KEY empty, and the check exited 1 on a workflow that never asked to sign: it named
# a flag the operator did not pass (--secureboot-cert) and prescribed the one they did
# (--keys-usb). With no key, :378's documented default ("a throwaway org key is generated")
# is CORRECT behaviour for a dev/test image, so blocking it invented a constraint.
#
# The fix captures SECUREBOOT_CERT_EXPLICIT BEFORE discovery runs. These guards pin both
# halves — the capture must precede discovery, and the err must read the EXPLICIT variable —
# because a one-word edit silently restores a false hard error on a legitimate build, and
# nothing else in the suite would notice.

def _x86_lineno(pattern: str) -> int:
    """1-indexed line of the first line matching `pattern` in build-x86 (comments stripped,
    so the guards below anchor on CODE and a commented-out line cannot satisfy them)."""
    lines = _strip_comments(_builder_text("x86")).splitlines()
    for i, ln in enumerate(lines, 1):
        if re.search(pattern, ln):
            return i
    raise AssertionError(f"build-x86 no longer contains a line matching {pattern!r}")


def test_secureboot_cert_explicit_is_captured_before_keys_usb_discovery():
    """The capture is only meaningful ahead of the auto-discovery that overwrites the same
    variable. Order is the whole point, so pin the order, not just the presence."""
    capture = _x86_lineno(r'^\s*SECUREBOOT_CERT_EXPLICIT="\$\{SECUREBOOT_CERT\}"')
    discover = _x86_lineno(r'SECUREBOOT_CERT="\$\{KEYS_USB\}/Keys/kernel_key\.der"')
    assert capture < discover, (
        f"SECUREBOOT_CERT_EXPLICIT is captured at :{capture}, AFTER --keys-usb discovery "
        f"writes SECUREBOOT_CERT at :{discover} — so it records the DISCOVERED cert, not the "
        "operator's flag, and a der-only KEYS USB hard-errors again on a build that never "
        "asked to sign.")


def test_secureboot_cert_without_key_error_gates_on_the_explicit_flag_only():
    """The err must read SECUREBOOT_CERT_EXPLICIT. Gating on bare SECUREBOOT_CERT re-breaks
    the der-only --keys-usb workflow (private key on an HSM), whose correct outcome is the
    builder's own documented throwaway-key default plus a warning."""
    body = _strip_comments(_builder_text("x86"))
    # Anchor on the ERR itself, not on the first cert-without-key shape in the file: the
    # --keys-usb der-only WARN branch has the same `[ -n CERT ] && [ -z KEY ]` shape and
    # legitimately gates on the bare (discovered) variable, so a plain re.search finds THAT
    # one and this guard would assert against the wrong condition.
    m = re.search(r'if \[ -n "\$\{(SECUREBOOT_CERT[A-Z_]*)\}" \] && \[ -z "\$\{SECUREBOOT_KEY\}"'
                  r' \]; then\n\s*err "--secureboot-cert needs', body)
    assert m is not None, (
        "the cert-without-key preflight is gone or reshaped — if it was removed on purpose, "
        "delete this guard; if it was reshaped, re-anchor it. Do not leave it unpinned: a "
        "cert alone is inert and silently yields an unbootable Secure Boot image.")
    assert m.group(1) == "SECUREBOOT_CERT_EXPLICIT", (
        f"the cert-without-key hard error gates on ${{{m.group(1)}}}, which --keys-usb "
        "auto-discovery also writes. A KEYS USB with only Keys/kernel_key.der then exits 1 "
        "on a workflow that never asked for signing, blaming --secureboot-cert (never "
        "passed) and prescribing --keys-usb (already passed). Gate on "
        "SECUREBOOT_CERT_EXPLICIT: an explicit flag IS a request to sign; discovery is not.")


def test_keys_usb_der_only_warns_instead_of_erroring():
    """The der-only branch must stay a WARN inside the --keys-usb block: correct artifact
    (throwaway key, :378's documented default), wrong-for-Secure-Boot — so say so, loudly,
    and build. Mirrors the --distdir asymmetry: err only when the ARTIFACT is wrong."""
    body = _strip_comments(_builder_text("x86"))
    m = re.search(r'if \[ -n "\$\{SECUREBOOT_CERT\}" \] && \[ -z "\$\{SECUREBOOT_KEY\}" \];'
                  r' then\n(.*?)\n\s*fi', body, re.S)
    assert m is not None, "the --keys-usb der-only branch is gone — a der-only USB is silent again"
    branch = m.group(1)
    assert "warn " in branch, f"der-only branch no longer warns: {branch!r}"
    assert not re.search(r"(?:^|[;&\s])(err |exit 1)", branch), (
        f"the --keys-usb der-only branch now ERRORS: {branch!r}. That is the false hard "
        "error this fix removed — with no private key the builder's documented throwaway "
        "default applies and the build is a correct dev/test image.")
