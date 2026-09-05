"""One themed PLATFORM preview page: the REAL captured login snapshot beside
representative Matrix-chat / Akkoma-feed / forum-thread panes, all painted from the
SAME ``--sd-*`` token text the login preview substitutes (theme.compose_login_css /
theme.css_root) — so the brand preview stays truthful across surfaces instead of
claiming only the login page.

WHY ONE SELF-CONTAINED FILE (not an index + linked pages): the open path is the
fragile half of this feature — QDesktopServices/xdg-open dispatch failures are
exactly what produced the operator's "the login page preview isn't working" report
(see gui/pages/_logintheme.py) — so the preview is a SINGLE ``file://`` artifact:
one open action, no relative links to break when the file is copied out of the
cache dir or attached to a bug report, and the login snapshot rides along inside
it (iframe ``srcdoc``, so its captured component styles stay isolated from the
pane styles here).

HONESTY SPLIT (mirrors the login preview's own rules):
  * the LOGIN pane is the real captured login-ui DOM — login_preview.preview_html,
    same asset, same ``/*__SNAP_THEME_CSS__*/`` marker, same ``:root:root``
    substitution that ships to containers;
  * the MATRIX / AKKOMA / FORUM panes are REPRESENTATIVE mockups and each says so
    in-pane ("representative preview — not the live UI"): the real chat/feed/forum
    UIs are Angular apps in sibling repos and no captured snapshot of them exists
    in this repo. The login asset was produced by a headless-chromium dump-dom
    pipeline (see assets/login-preview.html's provenance header) — the same capture
    COULD be run against those apps later and slotted in exactly like the login
    pane; until then a mockup labelled as such is honest, a fake "capture" is not.

This module does ZERO colour maths (the core/theme.py contract): the top-level page
carries a plain ``:root`` fallback built from theme.default_tokens() — mirroring the
compiled fallback inside the captured login asset — and the operator's theme lands
as ALREADY-DERIVED token text under ``:root:root``, which out-specifies the fallback
exactly as in production. Every pane colour is a ``var(--sd-*)`` reference.

Sample content is deterministic NEUTRAL demo text: personas amara / kenji / sol on
the non-delegated host ``demo.mesh`` — no real names, no real domains.

Qt-free like the rest of core/ (the GUI only writes the file and opens the URL).
"""
from __future__ import annotations

import html as _html
import os

from . import fonts, login_preview, theme

MARKER = login_preview.MARKER          # the SAME substitution mechanism, on purpose
PLATFORM_PREVIEW_BASENAME = "hugmesh-platform-preview.html"

# In-pane small print for the three mock surfaces. A module constant so the tests and
# the GUI tooltip quote the exact honesty text rather than drifting copies of it.
HONESTY_LABEL = "representative preview — not the live UI"
# Short and concrete (operator ask, issue #225: the preview's explainer prose was
# "clanker text to delete" — the header paragraph is gone, and this in-pane line
# says only what the pane is). Provenance detail stays in assets/login-preview.html.
LOGIN_PANE_LABEL = ("captured copy of the real login page — themed with the exact "
                    "css that ships")

# srcdoc slot: substituted AFTER the theme marker, and chosen so neither the marker
# text nor any escaped snapshot byte can collide with it.
_LOGIN_SLOT = "__LOGIN_SRCDOC__"

# Defence in depth for the TOP-LEVEL style#snap-theme (the iframe copy is already
# html.escape'd, so this was the one raw substitution in the page). ONE implementation,
# owned by login_preview next to the marker it protects — see the long note there for
# why `<style>` raw text is the hazard and why this neutralises instead of raising.
raw_text_safe = login_preview.raw_text_safe

# Belt and braces on the generated artifact itself: a frozen, self-contained preview
# needs no script, no network and no plugin, so say so. If a sink bug ever gets markup
# into the page again, `default-src 'none'` means it cannot execute or phone home.
# (`style-src 'unsafe-inline'` is required — the whole page IS inline <style>, and the
# srcdoc login document inherits this policy; `font-src data:` is the embedded
# @font-face; the snapshot references no images, scripts or external sheets.)
# (measured in chromium: `base-uri 'none'` is deliberately NOT here — the captured
# login-ui snapshot carries Angular's `<base href="/">`, and the srcdoc document
# inherits this policy, so it logged a violation on every load for no gain: nothing
# can be fetched under `default-src 'none'` regardless of what the base URI is.)
PREVIEW_CSP = ("default-src 'none'; style-src 'unsafe-inline'; font-src data:; "
               "img-src data:; form-action 'none'")


# persona -> avatar/name colour classes. Fixed mapping (not hashed) so the same
# persona is the same colour in every pane and every render — determinism is pinned
# by tests. accent-soft carries dark text from the token contract itself: soft_for_text
# lightens until >= 4.5:1 against the dark shell (core/theme.py), so --sd-bg-0 text on
# an accent-soft fill is legible by the same construction.
_PERSONA_CLASS = {"amara": "primary", "kenji": "secondary", "sol": "accent"}


def sample_content() -> dict:
    """Demo content for the three representative panes. Pure literals returning the
    SAME value on every call (a fresh dict, but equal bytes) — pinned by tests, so a
    preview diff is always a THEME diff, never sample-content noise."""
    return {
        "matrix": {
            "room": "#welcome:demo.mesh",
            "topic": "General chat for this mesh",
            "events": [
                {"kind": "message", "author": "amara", "time": "12:04",
                 "text": "Morning all — the new build finished overnight."},
                {"kind": "message", "author": "kenji", "time": "12:06",
                 "text": "Nice. Does the kiosk image pick it up automatically?"},
                {"kind": "message", "author": "amara", "time": "12:07",
                 "text": "On next boot, yes. The flash sticks are already updated."},
                {"kind": "join", "author": "sol", "time": "12:10"},
                {"kind": "message", "author": "sol", "time": "12:11",
                 "text": "Just joined from the new laptop — login worked first try."},
            ],
        },
        "akkoma": {
            "statuses": [
                {"author": "amara", "handle": "@amara@demo.mesh", "time": "2h",
                 "text": "First post from our own mesh. Feels good to own the whole "
                         "stack.", "boosts": 3, "likes": 7},
                {"author": "kenji", "handle": "@kenji@demo.mesh", "time": "3h",
                 "text": "Garden photos are up in the shared album — link in my bio.",
                 "boosts": 1, "likes": 4},
                {"author": "sol", "handle": "@sol@demo.mesh", "time": "5h",
                 "text": "Reminder: maintenance window tonight 22:00–22:30. Expect a "
                         "short blip.", "boosts": 5, "likes": 2},
                {"author": "amara", "handle": "@amara@demo.mesh", "time": "6h",
                 "text": "Welcome sol — say hi, everyone.", "boosts": 0, "likes": 9},
            ],
        },
        "forum": {
            "topic": "Tips for first-time mesh operators",
            "posts": [
                {"author": "amara", "time": "Yesterday 18:20",
                 "text": "Starting a thread for things we wish we'd known on day "
                         "one. I'll go first: label your flash sticks.",
                 "quote": "", "quote_from": ""},
                {"author": "kenji", "time": "Yesterday 19:02",
                 "text": "Seconded — and keep one stick per device role.",
                 "quote": "label your flash sticks", "quote_from": "amara"},
                {"author": "sol", "time": "Yesterday 21:47",
                 "text": "Bookmark the status page before you need it, not after.",
                 "quote": "", "quote_from": ""},
                {"author": "amara", "time": "Today 08:15",
                 "text": "Adding these to the pinned checklist — keep them coming.",
                 "quote": "", "quote_from": ""},
            ],
        },
    }


# ── pane rendering (all text escaped, all colours var(--sd-*)) ──────────────────────
def _e(text: str) -> str:
    return _html.escape(str(text), quote=True)


def _avatar(author: str) -> str:
    cls = _PERSONA_CLASS.get(author, "secondary")
    return (f'<span class="av av-{cls}" aria-hidden="true">'
            f'{_e(author[:1].upper())}</span>')


def _name(author: str) -> str:
    cls = _PERSONA_CLASS.get(author, "secondary")
    return f'<span class="name name-{cls}">{_e(author)}</span>'


def _matrix_pane(content: dict) -> str:
    mx = content["matrix"]
    rows = []
    for ev in mx["events"]:
        if ev["kind"] == "join":
            rows.append(f'<p class="mx-join">→ {_e(ev["author"])} joined the room '
                        f'<span class="mx-time">{_e(ev["time"])}</span></p>')
        else:
            rows.append(
                '<div class="mx-msg">' + _avatar(ev["author"]) +
                f'<div><p class="mx-head">{_name(ev["author"])}'
                f'<span class="mx-time">{_e(ev["time"])}</span></p>'
                f'<p class="mx-text">{_e(ev["text"])}</p></div></div>')
    return (
        '<section class="pane" id="pane-matrix">\n'
        '<div class="pane-head"><h2>Matrix chat</h2>'
        '<span class="surface">matrix-ui</span></div>\n'
        f'<div class="pane-body"><p class="mx-room">{_e(mx["room"])}</p>'
        f'<p class="mx-topic">{_e(mx["topic"])}</p>\n'
        + "\n".join(rows) +
        f'\n</div>\n<p class="pane-honesty">{_e(HONESTY_LABEL)}</p>\n</section>')


def _akkoma_pane(content: dict) -> str:
    rows = []
    for st in content["akkoma"]["statuses"]:
        rows.append(
            '<article class="ak-status">' + _avatar(st["author"]) +
            f'<div><p class="ak-head">{_name(st["author"])}'
            f'<span class="ak-handle">{_e(st["handle"])}</span>'
            f'<span class="ak-time">{_e(st["time"])}</span></p>'
            f'<p class="ak-text">{_e(st["text"])}</p>'
            f'<p class="ak-counts"><span class="boost" title="boosts">↻ '
            f'{int(st["boosts"])}</span><span class="like" title="likes">★ '
            f'{int(st["likes"])}</span></p></div></article>')
    return (
        '<section class="pane" id="pane-akkoma">\n'
        '<div class="pane-head"><h2>Akkoma feed</h2>'
        '<span class="surface">fediverse</span></div>\n'
        '<div class="pane-body pane-body-flush">\n' + "\n".join(rows) +
        f'\n</div>\n<p class="pane-honesty">{_e(HONESTY_LABEL)}</p>\n</section>')


def _forum_pane(content: dict) -> str:
    fm = content["forum"]
    rows = []
    for post in fm["posts"]:
        quote = ""
        if post["quote"]:
            quote = (f'<blockquote><span class="fm-quote-from">'
                     f'{_e(post["quote_from"])} wrote:</span> '
                     f'{_e(post["quote"])}</blockquote>')
        rows.append(
            '<article class="fm-post"><p class="fm-meta">' + _avatar(post["author"]) +
            f'{_name(post["author"])}<span class="fm-time">{_e(post["time"])}</span>'
            f'</p>{quote}<p class="fm-text">{_e(post["text"])}</p></article>')
    # Pagination STUB: static spans, no links — a preview affordance, not navigation.
    pages = ('<nav class="fm-pages" aria-label="pages (pagination stub)" '
             'title="pagination stub — not functional">'
             '<span class="cur">1</span><span>2</span><span>3</span><span>…</span>'
             '</nav>')
    return (
        '<section class="pane" id="pane-forum">\n'
        '<div class="pane-head"><h2>Forum thread</h2>'
        '<span class="surface">forum-ui</span></div>\n'
        f'<div class="pane-body pane-body-flush"><p class="fm-topic">'
        f'{_e(fm["topic"])}</p>\n' + "\n".join(rows) + pages +
        f'\n</div>\n<p class="pane-honesty">{_e(HONESTY_LABEL)}</p>\n</section>')


def _login_pane() -> str:
    # sandbox="": the snapshot is already script-stripped (pinned by
    # tests/test_login_preview.py), the empty sandbox just makes that structural —
    # nothing in the frame can ever run or submit, it is a picture made of DOM.
    return (
        '<section class="pane" id="pane-login">\n'
        '<div class="pane-head"><h2>Login</h2>'
        '<span class="surface">login-ui (captured)</span></div>\n'
        f'<iframe class="login-frame" title="HugMesh login — captured real page" '
        f'sandbox="" srcdoc="{_LOGIN_SLOT}"></iframe>\n'
        f'<p class="pane-honesty real">{_e(LOGIN_PANE_LABEL)}</p>\n</section>')


def _fallback_root_css() -> str:
    """A plain ``:root`` fallback holding the UNBRANDED default tokens + the shipped
    font stacks — the same role the compiled global stylesheet plays inside the login
    asset: unthemed renders the shipped brand, and a substituted theme's ``:root:root``
    out-specifies it regardless of order (theme.css_root's documented mechanism)."""
    tokens = dict(theme.default_tokens())
    tokens.update(fonts.font_tokens(""))
    lines = [":root {"] + [f"  {k}: {v};" for k, v in tokens.items()] + ["}"]
    return "\n".join(lines)


# Pane styling: every colour is a var(--sd-*) so the substituted theme reaches ALL
# panes through the one :root:root rule. The only non-token values are structure
# (spacing, radii) and the two contrast anchors the token contract itself guarantees
# (see _PERSONA_CLASS note for av-accent's dark text).
_STYLES = """
* { box-sizing: border-box; }
body { margin: 0; background: var(--sd-bg-0); color: var(--sd-text);
       font-family: var(--sd-font-sans, Arial, Helvetica, sans-serif); }
.pp-head { padding: 1rem 1.25rem; border-bottom: 1px solid var(--sd-border); }
.pp-head h1 { margin: 0 0 .3rem; font-size: 1.25rem; color: var(--sd-primary-soft); }
.pp-head p { margin: 0; color: var(--sd-text-muted); font-size: .8125rem;
             max-width: 70rem; }
.pp-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(21rem, 1fr));
           gap: 1rem; padding: 1rem 1.25rem; align-items: start; }
.pane { background: var(--sd-bg-1); border: 1px solid var(--sd-border);
        border-radius: .75rem; overflow: hidden; }
.pane-head { display: flex; justify-content: space-between; align-items: baseline;
             gap: .5rem; padding: .6rem .9rem; background: var(--sd-bg-2);
             border-bottom: 1px solid var(--sd-border); }
.pane-head h2 { margin: 0; font-size: .9375rem; color: var(--sd-text); }
.pane-head .surface { color: var(--sd-text-muted); font-size: .75rem; }
.pane-body { padding: .75rem .9rem; }
.pane-body-flush { padding: 0; }
.pane-honesty { margin: 0; padding: .45rem .9rem; font-size: .6875rem;
                color: var(--sd-text-muted); border-top: 1px solid var(--sd-border);
                font-style: italic; }
.pane-honesty.real { color: var(--sd-success); font-style: normal; }
.av { display: inline-flex; width: 2rem; height: 2rem; border-radius: 50%;
      align-items: center; justify-content: center; font-weight: 700;
      flex: 0 0 auto; }
.av-primary { background: var(--sd-primary); color: var(--sd-primary-on); }
.av-secondary { background: var(--sd-secondary); color: var(--sd-secondary-on); }
.av-accent { background: var(--sd-accent-soft); color: var(--sd-bg-0); }
.name { font-weight: 700; }
.name-primary { color: var(--sd-primary-soft); }
.name-secondary { color: var(--sd-secondary-soft); }
.name-accent { color: var(--sd-accent-soft); }
/* matrix */
.mx-room { margin: 0; font-weight: 700; color: var(--sd-text); }
.mx-topic { margin: .1rem 0 .6rem; color: var(--sd-text-muted); font-size: .75rem;
            border-bottom: 1px solid var(--sd-border); padding-bottom: .5rem; }
.mx-join { color: var(--sd-text-muted); font-size: .75rem; font-style: italic;
           margin: .55rem 0; }
.mx-msg { display: flex; gap: .6rem; margin: .55rem 0; }
.mx-head { margin: 0; }
.mx-time { color: var(--sd-text-muted); font-size: .6875rem; margin-left: .4rem; }
.mx-text { margin: .1rem 0 0; font-size: .875rem; }
/* akkoma */
.ak-status { display: flex; gap: .6rem; padding: .7rem .9rem;
             border-bottom: 1px solid var(--sd-border); }
.ak-status:last-child { border-bottom: 0; }
.ak-head { margin: 0; }
.ak-handle { color: var(--sd-text-muted); font-size: .75rem; margin-left: .4rem; }
.ak-time { color: var(--sd-text-muted); font-size: .6875rem; margin-left: .4rem; }
.ak-text { margin: .15rem 0 0; font-size: .875rem; }
.ak-counts { margin: .4rem 0 0; font-size: .75rem; display: flex; gap: 1rem; }
.ak-counts .boost { color: var(--sd-success); }
.ak-counts .like { color: var(--sd-primary-soft); }
/* forum */
.fm-topic { margin: 0; padding: .6rem .9rem; font-weight: 700;
            color: var(--sd-primary-soft);
            border-bottom: 1px solid var(--sd-border); }
.fm-post { padding: .7rem .9rem; border-bottom: 1px solid var(--sd-border); }
.fm-meta { display: flex; gap: .55rem; align-items: center; margin: 0 0 .3rem; }
.fm-time { color: var(--sd-text-muted); font-size: .6875rem; }
.fm-text { margin: 0; font-size: .875rem; }
.fm-post blockquote { margin: .3rem 0 .45rem; padding: .35rem .6rem;
                      border-left: 3px solid var(--sd-accent);
                      background: var(--sd-bg-2); color: var(--sd-text-muted);
                      font-size: .8125rem; }
.fm-quote-from { color: var(--sd-accent-soft); font-weight: 700; }
/* --sd-secondary-on is the right on-colour for an --sd-accent fill: derive() sets
   --sd-accent = secondary (core/theme.py) and the contract has no --sd-accent-on. */
.fm-pages { display: flex; gap: .35rem; padding: .6rem .9rem; font-size: .75rem; }
.fm-pages span { padding: .15rem .55rem; border: 1px solid var(--sd-border);
                 border-radius: .35rem; color: var(--sd-accent-soft); }
.fm-pages .cur { background: var(--sd-accent); color: var(--sd-secondary-on);
                 border-color: var(--sd-accent); }
/* login */
.login-frame { display: block; width: 100%; height: 34rem; border: 0;
               background: var(--sd-bg-0); }
"""


def platform_preview_html(theme_css: str) -> str:
    """The complete self-contained platform preview page with ``theme_css``
    (theme.compose_login_css output, or "" for the shipped default) substituted into
    BOTH substitution points: the top-level ``style#snap-theme`` (which the three
    representative panes inherit through ``var(--sd-*)``) and the embedded login
    snapshot's own marker (login_preview.preview_html — which also carries the
    asset-intact guard: a snapshot that lost its marker raises rather than silently
    previewing the unthemed page)."""
    login_doc = login_preview.preview_html(theme_css)
    content = sample_content()
    shell = (
        "<!DOCTYPE html>\n"
        "<!-- GENERATED by hugmesh_studio.core.platform_preview — one themed page,\n"
        "     four surfaces. Login pane: REAL captured login-ui snapshot (see\n"
        "     assets/login-preview.html provenance). Matrix/Akkoma/forum panes:\n"
        "     representative mockups, labelled as such in-pane. -->\n"
        '<html lang="en"><head>\n'
        '<meta charset="utf-8">\n'
        '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
        f'<meta http-equiv="Content-Security-Policy" content="{PREVIEW_CSP}">\n'
        "<title>HugMesh platform preview</title>\n"
        f'<style id="compiled-default-tokens">{_fallback_root_css()}</style>\n'
        f'<style id="snap-theme">{MARKER}</style>\n'
        f'<style id="platform-preview-styles">{_STYLES}</style>\n'
        "</head><body>\n"
        '<header class="pp-head">\n'
        "<h1>HugMesh platform preview</h1>\n"
        "</header>\n"
        '<main class="pp-grid">\n'
        + _login_pane() + "\n"
        + _matrix_pane(content) + "\n"
        + _akkoma_pane(content) + "\n"
        + _forum_pane(content) + "\n"
        "</main>\n"
        "</body></html>\n")
    # Marker first, srcdoc second: the substituted login doc no longer contains the
    # marker (and an unthemed one carries an empty style block), so the top-level
    # replace can never eat the iframe's copy.
    page = shell.replace(MARKER, raw_text_safe(theme_css), 1)
    return page.replace(_LOGIN_SLOT, _html.escape(login_doc, quote=True), 1)


def write_platform_preview(theme_css: str, out_dir: str) -> str:
    """Write the substituted platform preview into ``out_dir`` and return its path
    (the GUI hands this to the operator's browser as a file:// URL). Mirrors
    login_preview.write_preview, which stays untouched for login-only callers."""
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, PLATFORM_PREVIEW_BASENAME)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(platform_preview_html(theme_css))
    return path
