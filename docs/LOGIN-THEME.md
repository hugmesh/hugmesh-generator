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

Related: [`BRANDING.md`](BRANDING.md) covers what a tenant's *rendered generator
copy* rebrands (names, domains, files); this page is only the login page's
look. The Studio's own theme system and its pride presets are described in
[`STUDIO-WALKTHROUGH.md`](STUDIO-WALKTHROUGH.md).
