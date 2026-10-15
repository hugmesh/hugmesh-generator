"""The stylesheet writer's refusals (hugmesh-generator#654, D19), one test per guard.

Each guard in ``theme._check_token`` was found removable with every test still green;
each test below names the line whose removal turns it red, and was run that way.
The writer reads a value with its string literals taken out (text inside a string is
inert), so every hostile spelling is tried both bare, where it must be refused, and
inside a string, where it is just letters and must pass.
"""
import pytest

from hugmesh_studio.core import brand_images as bi
from hugmesh_studio.core import theme

from test_look_model import png_bytes


def write(value, name="--sd-header-content"):
    return theme.css_root({name: value})


@pytest.mark.parametrize("value", ["URL(https://x/a.png)", "Url(https://x)", "uRl( 'https://x' )",
                                   "linear-gradient(red, URL(//x/y))"])
@pytest.mark.parametrize("name", ["--sd-header-content", "--hug-anything", "--sd-logo-image"])
def test_url_is_refused_in_any_letter_case_on_any_token(name, value):
    """Remove ``.lower()`` from the bare value: URL( is read by the browser exactly as
    url( and would fetch from anywhere."""
    with pytest.raises(ValueError, match="url|allow"):
        write(value, name)


def test_an_upper_case_data_url_on_a_picture_token_is_refused_not_passed():
    uri = bi.reencode(png_bytes(8, 8), "logo").data_uri()
    ok = theme.css_root({"--sd-logo-image": f"url({uri})"})
    assert "--hug-logo-image" in ok
    with pytest.raises(ValueError, match="url"):
        write(f"URL({uri})", "--sd-logo-image")


def test_url_inside_a_string_is_only_letters():
    assert "url(https://x)" in write("'url(https://x)'")
    assert "URL(x)" in write("\"a URL(x) b\"")


@pytest.mark.parametrize("ch", ["\x7f", "\x80", "\x85", "\x9f"])
def test_delete_and_the_c1_controls_are_refused(ch):
    """Remove ``or 0x7F <= ord(ch) <= 0x9F``: DEL and the C1 range (NEL, 0x85, is a
    newline to some parsers) rode through untouched."""
    with pytest.raises(ValueError, match="control"):
        write(f"a{ch}b")
    with pytest.raises(ValueError, match="control"):
        write(f"'a{ch}b'")             # inside a string too: css_string escapes them


def test_the_first_printable_after_the_c1_range_is_fine():
    assert " " in write("'a b'")          # NBSP, 0xA0: one past the range


@pytest.mark.parametrize("ch", ["<", ">"])
def test_angle_brackets_outside_a_string_are_refused_and_inside_one_are_text(ch):
    """Remove '<' and '>' from _VALUE_BANNED: a value could then close a <style> element
    when the stylesheet is inlined in a page."""
    with pytest.raises(ValueError, match="may not carry"):
        write(f"a{ch}b")
    with pytest.raises(ValueError, match="may not carry"):
        write(f"</style>")
    assert f"'a{ch}b'" in write(f"'a{ch}b'")
