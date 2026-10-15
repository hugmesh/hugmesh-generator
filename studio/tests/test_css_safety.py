"""Header and footer text cannot add stylesheet rules (hugmesh-generator#654, D19).

``theme.css_string`` turns operator-typed text into a CSS single-quoted string literal
that lands verbatim in a ``content:`` declaration of the web chrome block. Until this
fix it escaped only the backslash, the quote, CR and LF. CSS reads a FORM FEED as a
newline too (the tokenizer normalises CR, FF and CRLF to LF before it ever sees a
string), so a form feed ended the string early — a <bad-string-token> — and whatever
followed it was parsed as further declarations and rules. Header text was a way to
add a rule, including a ``url(`` that fetches from anywhere.

The checks below read the rendered stylesheet the way a CSS tokenizer does: strip
every string literal (ending at the matching quote OR at the first unescaped LF, CR
or FF, exactly as the tokenizer does), then look at what is left. A test that merely
looked for the text in the output would pass for the wrong reason, because the
hostile text is SUPPOSED to be in the output, inside the string.
"""
import re

import pytest

from hugmesh_studio.core import theme

# The operator's header text in the design's C-STYLE scenario: a form feed, a closing
# brace and a url(). With the old escape the string ended at the form feed and the
# remainder became a real rule with a real url().
HOSTILE = "Welcome\x0c} .x{background:url(https://x)}"

# A CSS <string-token> as the tokenizer consumes it: an escaped anything (including an
# escaped newline, which is a continuation), or any char that is not the quote, a
# backslash or a newline; it ends at the quote, or — as a bad string — just before an
# unescaped LF/CR/FF, or at the end of input.
_STRING = re.compile(r"'(?:\\.|[^'\\\n\r\f])*(?:'|(?=[\n\r\f])|$)", re.S)

# A CSS escape: up to six hex digits followed by one optional whitespace, or any one
# other character. The whitespace matters: without it `\A` + `b` would read as `\Ab`.
_ESCAPE = re.compile(r"\\([0-9A-Fa-f]{1,6})[ \n\t]?|\\(.)", re.S)


def outside_strings(css: str) -> str:
    """``css`` with every string literal replaced by an empty one."""
    return _STRING.sub("''", css)


def decode(literal: str) -> str:
    """The text a CSS parser reads out of a single-quoted string literal."""
    assert literal.startswith("'") and literal.endswith("'"), literal
    body = literal[1:-1]
    assert not re.search(r"[\n\r\f]", body), "a raw newline inside the literal ends it"

    def one(m):
        if m.group(1) is not None:
            return chr(int(m.group(1), 16))
        return m.group(2)

    return _ESCAPE.sub(one, body)


def normalised(text: str) -> str:
    """What css_string promises to preserve: every newline spelling becomes LF."""
    return text.replace("\r\n", "\n").replace("\r", "\n").replace("\f", "\n")


CONTROL_CHARS = [chr(c) for c in range(0x00, 0x20)] + [chr(c) for c in range(0x7F, 0xA0)]


class TestHostileChromeTextAddsNoRule:
    @pytest.mark.parametrize("surface", ["header", "footer"])
    def test_form_feed_brace_and_url_add_no_rule_and_no_url(self, surface):
        css = theme.chrome_css(**{f"{surface}_text": HOSTILE})
        bare = outside_strings(css)
        # one :root:root block, and nothing opened or closed outside it
        assert bare.count("{") == 1, bare
        assert bare.count("}") == 1, bare
        assert "url(" not in bare, bare
        # exactly the two content declarations the writer emits for one surface
        decls = [ln.strip() for ln in bare.splitlines() if ln.strip().endswith(";")]
        assert decls == [f"--sd-{surface}-content: '';", f"--hug-{surface}-content: '';"], bare
        # and the raw form feed is gone from the output altogether
        assert "\x0c" not in css

    def test_the_text_still_reaches_the_page_as_the_operator_typed_it(self):
        literal = theme.css_string(HOSTILE)
        assert decode(literal) == normalised(HOSTILE)


class TestEveryControlCharacterIsEscaped:
    @pytest.mark.parametrize("ch", CONTROL_CHARS, ids=lambda c: f"U+{ord(c):04X}")
    def test_no_raw_control_character_survives(self, ch):
        literal = theme.css_string(f"a{ch}b")
        assert ch not in literal, repr(literal)
        # the literal is one string to the tokenizer: nothing outside it
        assert outside_strings(literal) == "''", repr(literal)

    @pytest.mark.parametrize("ch", CONTROL_CHARS, ids=lambda c: f"U+{ord(c):04X}")
    def test_the_escape_round_trips_including_before_a_hex_digit(self, ch):
        # 'F' after the escape is the trap: `\1F` would be ONE code point unless the
        # escape is terminated by whitespace.
        text = f"a{ch}F"
        assert decode(theme.css_string(text)) == normalised(text)

    def test_every_newline_spelling_is_one_css_newline(self):
        for text in ("a\nb", "a\r\nb", "a\rb", "a\x0cb"):
            assert theme.css_string(text) == "'a\\A b'", repr(text)


class TestTheOldContractStillHolds:
    def test_quotes_and_backslashes(self):
        assert theme.css_string("it's \\ here") == "'it\\'s \\\\ here'"
        assert decode(theme.css_string("it's \\ here")) == "it's \\ here"

    def test_plain_text_is_untouched(self):
        assert theme.css_string("Welcome to mesh.example") == "'Welcome to mesh.example'"

    def test_non_ascii_text_is_untouched(self):
        text = "Bienvenue — ようこそ"
        assert theme.css_string(text) == f"'{text}'"

    def test_chrome_tokens_use_it_for_both_surfaces(self):
        tokens = theme.chrome_tokens(header_text="h\x0c}", footer_text="f\x0c}")
        for key in ("--sd-header-content", "--sd-footer-content"):
            assert "\x0c" not in tokens[key]
            assert outside_strings(tokens[key]) == "''"
