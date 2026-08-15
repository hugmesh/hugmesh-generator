"""Terminal output rendering: what the operator should SEE.

Pure-function tests (no Qt), because the GUI suite segfaults headless here and this is
the part that can be checked without a widget.
"""
import pytest

from hugmesh_studio.core import ansi


class TestCarriageReturnOverwrite:
    """A progress bar is ONE line, not one line per redraw."""

    def test_a_redraw_replaces_rather_than_appends(self):
        assert ansi.collapse_carriage_returns("[ 43%]\r[ 67%]\r[ 91%]") == "[ 91%]"

    def test_a_shorter_overwrite_keeps_the_tail_it_did_not_reach(self):
        # Real terminal semantics: the cursor returns to column 0 and overwrites only as
        # far as the new text goes. Dropping the tail would silently truncate.
        assert ansi.collapse_carriage_returns("12345\rab") == "ab345"

    def test_a_line_without_a_redraw_is_untouched(self):
        assert ansi.collapse_carriage_returns("plain line") == "plain line"

    def test_a_trailing_return_does_not_blank_the_line(self):
        assert ansi.collapse_carriage_returns("done\r") == "done"


class TestEscapeStripping:

    def test_sgr_colour_is_removed(self):
        assert ansi.strip_ansi("\x1b[32;01m*\x1b[0m ok") == "* ok"

    def test_cursor_and_erase_sequences_are_removed(self):
        assert ansi.strip_ansi("a\x1b[2Kb\x1b[1Ac") == "abc"

    def test_a_window_title_sequence_is_removed_whole(self):
        # OSC carries arbitrary text; leaking its payload into the log would be worse
        # than leaking the escape itself.
        assert ansi.strip_ansi("\x1b]0;building foo\x07ready") == "ready"


class TestHtmlRendering:

    def test_emerge_flag_colours_become_spans(self):
        # The four-value alphabet emerge --color=y actually uses.
        out = ansi.to_html("\x1b[32;01m*\x1b[0m dev-libs/foo")
        assert "<span" in out and "#2e8b45" in out
        assert "font-weight:600" in out
        assert "dev-libs/foo" in out
        assert "\x1b" not in out

    def test_a_reset_closes_the_span_so_colour_does_not_bleed(self):
        out = ansi.to_html("\x1b[31mbad\x1b[0m good")
        assert out.count("<span") == 1
        assert out.index("</span>") < out.index("good")

    def test_html_in_tool_output_is_escaped_not_interpreted(self):
        # Build tools emit angle brackets constantly (C++ templates, <stdin>). In an
        # appendHtml pane an unescaped one would silently eat the rest of the line.
        out = ansi.to_html("error in <stdin>: vector<int> & 3")
        assert "&lt;stdin&gt;" in out
        assert "&amp;" in out
        assert "<stdin>" not in out

    def test_indentation_is_preserved(self):
        # Portage aligns columns with runs of spaces; HTML would collapse them.
        assert "&nbsp;" in ansi.to_html("    indented")

    def test_256_colour_and_truecolor_are_supported(self):
        assert "#" in ansi.to_html("\x1b[38;5;196mred\x1b[0m")
        assert "#123456" in ansi.to_html("\x1b[38;2;18;52;86mexact\x1b[0m")

    def test_non_sgr_sequences_are_dropped_not_rendered(self):
        out = ansi.to_html("a\x1b[2Jb")
        assert "2J" not in out
        assert "ab" in out

    def test_a_progress_redraw_renders_as_its_final_state(self):
        out = ansi.to_html("[ 10%]\r[ 99%]")
        assert "99%" in out
        assert "10%" not in out

    def test_inverse_video_flips_even_when_only_one_side_is_set(self):
        out = ansi.to_html("\x1b[7minverse\x1b[0m")
        assert "background-color" in out and "color" in out

    def test_a_bare_reset_sequence_is_treated_as_sgr0(self):
        # `\x1b[m` is legal shorthand for `\x1b[0m`; treating it as "no codes" would
        # leave the previous colour open.
        out = ansi.to_html("\x1b[31mred\x1b[mplain")
        assert out.count("<span") == 1
        assert out.index("</span>") < out.index("plain")


class TestTheFastPath:

    @pytest.mark.parametrize("line", ["plain", "no escapes here", ""])
    def test_plain_lines_are_detected_as_needing_no_conversion(self, line):
        assert not ansi.has_escapes(line)

    @pytest.mark.parametrize("line", ["\x1b[31mred", "bar\rredraw"])
    def test_lines_needing_work_are_detected(self, line):
        assert ansi.has_escapes(line)
