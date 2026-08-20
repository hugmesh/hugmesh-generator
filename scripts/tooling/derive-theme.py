#!/usr/bin/env python3
"""derive-theme.py — render the login-ui snap-theme.css text (or its ConfigMap) from
brand colours/fonts, at RENDER time on a dev/CI box.

The derivation is studio/hugmesh_studio/core/theme.py — imported, never copied:
the Studio GUI, the mesh-bootstrap CLI and this script all call the SAME
compose_login_css(), so a palette can never differ between the in-window token
board, the local compose stack and a rendered cluster manifest. (A second
implementation — shell/JS colour maths at render time — is exactly how previews
start lying, so this file contains zero colour arithmetic.)

Inputs, either:
  --primary/--secondary  "#RRGGBB" brand colours (legibility is guaranteed by
                         construction — colours are never rejected, only warned)
  --font                 a core/fonts.py FONT_PRESETS name (system stacks only:
                         the shipped CSP `font-src 'self' data:` blocks any CDN)
  --font-file            a .woff2/.woff/.ttf/.otf face, embedded as a data: URI;
                         REQUIRES --font-licence + --font-source: embedding a face
                         is a licensing decision, recorded (with the sha256) in the
                         emitted css header so the artifact carries its provenance
or:
  --brand-yaml brands/<brand>.yaml   reads the OPTIONAL `login_theme:` block
                         (keys: primary, secondary, font, font_file, font_licence,
                         font_source; paths relative to the yaml). Needs PyYAML.

Output (stdout, or --out FILE):
  default      the raw snap-theme.css text -> feed to HUG_THEME_CSS (compose) or
               the login-ui entrypoint directly. The fleet's 50-snap-theme.sh also
               still accepts the legacy SNAP_THEME_CSS spelling.
  --configmap  a v1 ConfigMap manifest (data key HUG_THEME_CSS) the login-ui
               Deployment consumes via an OPTIONAL configMapKeyRef — apply it and
               restart the pod to rebrand; delete it to return to the shipped brand.
               A ConfigMap produced BEFORE the key was renamed (data key
               SNAP_THEME_CSS) still resolves: the Deployment declares both refs.

Exit codes: 0 ok (including "nothing chosen" -> empty output), 2 blocked input.
"""
from __future__ import annotations

import argparse
import os
import sys

_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(_ROOT, "studio"))

from hugmesh_studio.core import domain_theme, fonts, theme, theme_presets  # noqa: E402

DEFAULT_CONFIGMAP_NAME = "login-theme"
DEFAULT_NAMESPACE = "hugmesh-frontend"


def _fail(msg: str) -> "int":
    print(f"derive-theme: BLOCKED: {msg}", file=sys.stderr)
    return 2


def _load_brand_yaml(path: str) -> dict:
    try:
        import yaml  # type: ignore
    except ImportError:
        raise SystemExit(_fail(
            "--brand-yaml needs PyYAML (python3 -m pip install pyyaml); or pass "
            "--primary/--secondary/--font explicitly — same derivation either way"))
    with open(path, encoding="utf-8") as fh:
        doc = yaml.safe_load(fh) or {}
    block = doc.get("login_theme") or {}
    if not isinstance(block, dict):
        raise SystemExit(_fail(f"login_theme in {path} must be a mapping"))
    return block


def _configmap(css: str, name: str, namespace: str) -> str:
    # Emitted without a yaml dependency: the css rides a literal block scalar, which
    # takes any printable text verbatim once indented under the key.
    #
    # EXACTLY ONE data key, and it is the NEW spelling. The tempting belt-and-braces
    # move — emit SNAP_THEME_CSS as well so an older deployment.yaml still resolves —
    # is refused HERE specifically, and the asymmetry with compose (which does keep a
    # legacy fallback) is the point:
    #   * a ConfigMap is a STANDING, hand-editable object. Two keys holding the same
    #     css is two keys a human can edit ONE of; since the Deployment prefers
    #     HUG_THEME_CSS, editing only the SNAP copy would change nothing, with no
    #     error — a drift hazard that does not exist for a shell variable computed
    #     fresh on every bring-up.
    #   * the compat it would buy is bought instead on the CONSUMER side, where it
    #     cannot drift: specs/cluster/manifests/social-ui/deployment.yaml declares
    #     BOTH env refs, each `optional: true`, so a ConfigMap of EITHER vintage
    #     resolves — a pre-existing SNAP-only one the operator saved and re-applies,
    #     or this new HUG-only one. Producers emit one canonical name, consumers
    #     accept both: the same discipline the entrypoint hooks already run on.
    indented = "\n".join(f"    {line}" if line else "" for line in css.split("\n"))
    return (
        "apiVersion: v1\n"
        "kind: ConfigMap\n"
        "metadata:\n"
        f"  name: {name}\n"
        f"  namespace: {namespace}\n"
        "  labels: { app.kubernetes.io/part-of: hugmesh, app.kubernetes.io/component: login-theme }\n"
        "data:\n"
        "  HUG_THEME_CSS: |\n"
        f"{indented}\n"
    )


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    p.add_argument("--brand-yaml", default="", help="brands/<brand>.yaml with an "
                   "optional login_theme: block (needs PyYAML)")
    p.add_argument("--primary", default="", help="#RRGGBB primary brand colour")
    p.add_argument("--secondary", default="", help="#RRGGBB secondary/accent colour")
    p.add_argument("--font", default="", help="font preset NAME, one of: "
                   + ", ".join(fonts.FONT_PRESETS))
    p.add_argument("--font-file", default="", help=".woff2/.woff/.ttf/.otf to embed "
                   "as a data: URI (requires --font-licence and --font-source)")
    p.add_argument("--font-family", default="", help="family name for the uploaded "
                   "face (default: derived from the file name)")
    p.add_argument("--font-licence", default="", help="licence of the uploaded face "
                   "(recorded in the css header)")
    p.add_argument("--font-source", default="", help="vendor/URL the face came from "
                   "(recorded in the css header)")
    # ── the PRESET path: the other three axes, which were unreachable from tooling ──
    # theme.py has carried preset/ramp/style (and now decor) for some time, and the Studio
    # pushes all four, but this CLI could only ever render the primary/secondary path. So
    # an operator scripting a rebrand could not produce the theme their own Studio shows.
    p.add_argument("--preset", default="", help="theme preset id (e.g. nord, pride, "
                   "dark). Mutually exclusive with --primary/--secondary, which are the "
                   "hand-picked-colour path")
    p.add_argument("--ramp", default=theme_presets.MODES[0],
                   help="time-of-day neutral ramp, one of: " + ", ".join(theme_presets.MODES))
    p.add_argument("--style", default=theme.DEFAULT_STYLE,
                   help="shape axis, one of: " + ", ".join(theme.STYLE_VARIANTS))
    p.add_argument("--decor", default=theme.DEFAULT_DECOR,
                   help="decorative nav text, one of: " + ", ".join(theme.DECOR_VARIANTS)
                        + " (default none)")
    p.add_argument("--configmap", action="store_true",
                   help="emit a v1 ConfigMap manifest instead of raw css")
    p.add_argument("--name", default=DEFAULT_CONFIGMAP_NAME,
                   help=f"ConfigMap name (default {DEFAULT_CONFIGMAP_NAME})")
    p.add_argument("--namespace", default=DEFAULT_NAMESPACE,
                   help=f"ConfigMap namespace (default {DEFAULT_NAMESPACE})")
    p.add_argument("--out", default="", help="write here instead of stdout")
    args = p.parse_args(argv)

    primary, secondary = args.primary, args.secondary
    font_preset, font_file = args.font, args.font_file
    font_family = args.font_family
    licence, source = args.font_licence, args.font_source
    if args.brand_yaml:
        block = _load_brand_yaml(args.brand_yaml)
        primary = primary or str(block.get("primary") or "")
        secondary = secondary or str(block.get("secondary") or "")
        font_preset = font_preset or str(block.get("font") or "")
        yaml_file = str(block.get("font_file") or "")
        if not font_file and yaml_file:
            font_file = os.path.join(os.path.dirname(os.path.abspath(args.brand_yaml)),
                                     yaml_file) if not os.path.isabs(yaml_file) else yaml_file
        licence = licence or str(block.get("font_licence") or "")
        source = source or str(block.get("font_source") or "")

    font_bytes = b""
    header = ""
    if font_file:
        if not (licence.strip() and source.strip()):
            return _fail("an uploaded font REQUIRES --font-licence and --font-source "
                         "(or font_licence/font_source in the yaml): embedding a face "
                         "we cannot attribute is the licensing landmine the upload "
                         "path exists to make explicit")
        try:
            with open(font_file, "rb") as fh:
                font_bytes = fh.read()
        except OSError as exc:
            return _fail(f"cannot read font file: {exc}")
        blocks, warns = fonts.check_font(os.path.basename(font_file), font_bytes)
        if blocks:
            return _fail("; ".join(blocks))
        for w in warns:
            print(f"derive-theme: WARNING: {w}", file=sys.stderr)
        font_family = font_family.strip() or \
            os.path.splitext(os.path.basename(font_file))[0].replace("-", " ").replace("_", " ")
        # the artifact carries its own provenance: sha + licence travel with the css.
        header = ("/* embedded font: "
                  f"{font_family} sha256:{fonts.font_sha256(font_bytes)} "
                  f"licence: {licence.strip()} source: {source.strip()} */\n")

    if args.preset and (primary or secondary):
        return _fail("--preset and --primary/--secondary are different paths: a preset "
                     "BRINGS its colours, so combining them would silently discard one "
                     "or the other. Pick one.")

    try:
        if args.preset:
            # THE SAME RENDER THE STUDIO PUSHES, not a second assembly of the same
            # tokens. domain_theme.render_css is what fills the per-domain stylesheet
            # cache, so routing this through it means a theme rendered here and a theme
            # rendered by the Studio cannot drift -- which is the whole reason the colour
            # maths has exactly one implementation.
            css = domain_theme.render_css(domain_theme.ThemeSelection(
                preset=args.preset, ramp=args.ramp, style=args.style, decor=args.decor))
        else:
            css = theme.compose_login_css(primary, secondary, font_preset=font_preset,
                                          font_family=font_family, font_bytes=font_bytes)
    except ValueError as exc:
        return _fail(str(exc))

    if css and not args.preset:
        # The colour warnings are about an operator's HAND-PICKED pair; a preset's colours
        # are already contrast-solved by the derivation, so running them here would emit
        # advice about colours nobody chose.
        for w in theme.warnings(primary or theme._DEFAULT_PRIMARY, secondary):
            print(f"derive-theme: WARNING: {w}", file=sys.stderr)
        css = header + css
    out_text = _configmap(css, args.name, args.namespace) if args.configmap else css
    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(out_text)
        print(f"derive-theme: wrote {len(out_text)} chars to {args.out}",
              file=sys.stderr)
    else:
        sys.stdout.write(out_text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
