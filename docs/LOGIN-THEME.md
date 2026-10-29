# Login theme rendering — `scripts/tooling/derive-theme.py`

Renders the login-ui `snap-theme.css` text — or a Kubernetes ConfigMap carrying
it — from brand colours, fonts and theme presets, **at render time on a dev/CI
box**. The derivation itself is `studio/hugmesh_studio/core/theme.py`
(`compose_login_css()`), **imported, never copied**: the Studio GUI's token
board, the mesh-bootstrap CLI and this script all call the same function, so a
palette cannot differ between the in-window preview, the local compose stack and
a rendered cluster manifest. This file contains zero colour arithmetic by
design — a second implementation is exactly how previews start lying.

It runs from a repo checkout (it imports `studio/`); PyYAML is needed only for
`--brand-yaml`.

## Inputs

Two mutually exclusive colour paths, plus the axes the Studio also exposes:

| Flag | Meaning |
|---|---|
| `--primary #RRGGBB` / `--secondary #RRGGBB` | Hand-picked brand colours. Legibility is guaranteed by construction — colours are never rejected, only warned about. |
| `--preset ID` | A theme preset (`nord`, `pride`, `dark`, …; `studio/hugmesh_studio/core/theme_presets.py`). Mutually exclusive with `--primary`/`--secondary`. |
| `--ramp MODE` | Time-of-day neutral ramp (`theme_presets.MODES`). |
| `--style NAME` | Shape axis (`theme.STYLE_VARIANTS`; default `soft`). |
| `--decor NAME` | Decorative nav text (`theme.DECOR_VARIANTS`; default `none`). |
| `--font NAME` | A `core/fonts.py` `FONT_PRESETS` name. **System stacks only**: the shipped CSP `font-src 'self' data:` blocks any CDN. |
| `--font-file PATH` | Embed a `.woff2`/`.woff`/`.ttf`/`.otf` face as a `data:` URI. **Requires** `--font-licence` and `--font-source` — embedding a face is a licensing decision, recorded (with the file's sha256) in the emitted css header so the artifact carries its provenance. `--font-family` overrides the family name derived from the file name. |
| `--brand-yaml brands/<brand>.yaml` | Read the optional `login_theme:` block instead (keys `primary`, `secondary`, `font`, `font_file`, `font_licence`, `font_source`; paths relative to the yaml). `brands/acme.yaml` carries a commented example. |

## Outputs

| Mode | Emits |
|---|---|
| default | The raw `snap-theme.css` text on stdout (or `--out FILE`). Feed it to `HUG_THEME_CSS` for the compose stack or the login-ui entrypoint directly; the fleet's `50-snap-theme.sh` still accepts the legacy `SNAP_THEME_CSS` spelling. |
| `--configmap` | A `v1` ConfigMap manifest (default name `login-theme`, namespace `hugmesh-frontend`; `--name`/`--namespace` override) with data key `HUG_THEME_CSS`. The login-ui Deployment consumes it through an **optional** `configMapKeyRef`: apply it and restart the pod to rebrand, delete it to return to the shipped brand. A ConfigMap produced before the key was renamed (data key `SNAP_THEME_CSS`) still resolves — the Deployment declares both refs. |

Exit codes: **0** ok (including "nothing chosen", which yields empty output) ·
**2** blocked input (printed as `derive-theme: BLOCKED: …`).

```sh
# hand-picked colours, raw css for the compose stack
scripts/tooling/derive-theme.py --primary '#ffd700' --secondary '#7c4dff' --font 'System UI' > theme.css
HUG_THEME_CSS="$(cat theme.css)" make stack-up

# a preset, rendered as the cluster ConfigMap
scripts/tooling/derive-theme.py --preset nord --configmap | kubectl apply -f -
```

## Pictures, shape, and what the writer refuses (#654)

The Studio's look editor adds two web pictures and two shape settings to the
stylesheet. `derive-theme.py` does not take them yet; the Studio and the mesh start
commands write them through the same `theme.py`.

| Token | Meaning |
|---|---|
| `--sd-logo-image` and its twin `--hug-logo-image` | The brand's logo, a `url(data:image/png;base64,...)` or JPEG, at most 256x256 pixels. |
| `--sd-login-bg-image` and its twin `--hug-login-bg-image` | The sign-in page's background picture, at most 1280x720 pixels. |
| shape and decoration tokens | The `style` and `decor` choices (`theme.STYLE_VARIANTS`, `theme.DECOR_VARIANTS`). Left out when they are the shipped value. |

**One brand's finished stylesheet may be at most 100 KiB (102,400 bytes).** The two
pictures are what spend it, so the look editor shows a meter and refuses a picture that
would not fit, with the numbers. A brand's stylesheet is the superbrand's look plus the
brand's own changes, so a superbrand edit that would push one brand over the budget is
refused with that brand's name. Several looks share one ConfigMap on the kind cluster
(1 MiB in all); the same refusal applies there.

A picture is never the uploaded file. It is rebuilt from the parts a browser needs and
only a PNG or JPEG is accepted (SVG can carry script and is refused). Anything after the
end of the pixel data inside the file is dropped on upload, and a picture that still
carries any is refused when a record names it.

The writer (`theme.css_root`) writes only custom properties named `--sd-*`, `--hug-*` or
`--bs-*`, and refuses, outside a quoted string: `var(`, any control character (including
DEL and the C1 range), a backslash, a comment opener or closer, `{`, `}`, `;`, `@`
(it would open an at-rule such as `@import`), `<` and `>` (they could close a `<style>`
element), an unterminated quote, `url(` on any token except the two picture tokens and
then only one data: PNG or JPEG whose bytes match its label, and the functions that
fetch a picture without `url(` (`image-set(`, `src(`, `image(`, `cross-fade(`,
`element(`, `paint(`). Text inside a quoted string is inert and passes.

Related: [`BRANDING.md`](BRANDING.md) covers what a tenant's *rendered generator
copy* rebrands (names, domains, files); this page is only the login page's
look. The Studio's own theme system and its pride presets are described in
[`STUDIO-WALKTHROUGH.md`](STUDIO-WALKTHROUGH.md).
