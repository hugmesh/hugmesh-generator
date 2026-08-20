"""Tool output must never be able to KILL the console that is displaying it.

The reported symptom was a Python error in the Studio's merge console during emerge
builds. The cause is that every streaming subprocess was opened with a bare
``text=True``, which does not mean UTF-8 — it means the LAUNCHER's locale. Two distinct
failures follow from that, and both are tested here because each can occur without the
other:

  * an undecodable byte raises ``UnicodeDecodeError`` out of ``for line in proc.stdout``.
    That does not garble a character, it TEARS DOWN the reader mid-build and the console
    just stops. ``text=True`` defaults to ``errors="strict"``, so this reproduces in ANY
    locale — which is what makes it testable here rather than only on the operator's box.

  * under a C/POSIX locale the codec is ASCII, so even perfectly valid UTF-8 fails. That
    is why it looks intermittent and why emerge triggers it when ``docker build`` does
    not: GCC quotes every diagnostic with U+2018/U+2019 curly quotes.

These run the REAL streaming path (a real subprocess, real pipe, real read loop) rather
than asserting on Popen kwargs — the bug lives in how the bytes are read back, so a test
that only inspected the call arguments could pass while the read still raised.
"""
import subprocess
import sys

import pytest

from hugmesh_studio.core import proc_text
from hugmesh_studio.core.build_driver import BuildDriver
from hugmesh_studio.core.platform_info import HostInfo


def host():
    return HostInfo(os="linux", is_gentoo=True, has_docker=True, has_bash=True,
                    has_kvm=False, is_root=True, builder_image="hugmesh-builder")


def _emit(payload: str) -> list[str]:
    """A child process writing raw BYTES to stdout, exactly as a build tool does."""
    return [sys.executable, "-c",
            "import sys; sys.stdout.buffer.write(" + payload + "); sys.stdout.buffer.flush()"]


class TestTheStreamSurvivesRealToolOutput:

    def test_an_undecodable_byte_degrades_one_cell_instead_of_killing_the_reader(self, tmp_path):
        # A lone 0xFF is not valid UTF-8 in any locale. Before the fix this raised
        # UnicodeDecodeError out of the read loop and the console stopped mid-build.
        d = BuildDriver(str(tmp_path), host())
        seen: list[str] = []
        code = d._stream(_emit(rb"b'before\xff after\n'".decode()), seen.append, "docker")

        assert code == 0
        assert len(seen) == 1
        assert seen[0].startswith("before")
        assert seen[0].endswith("after")
        # Visibly replaced, not silently deleted: a U+FFFD is a signal the operator can
        # act on, where "ignore" would turn a corrupted line into a plausible wrong one.
        assert "�" in seen[0]

    def test_gcc_style_smart_quotes_survive_intact(self, tmp_path):
        # The actual emerge payload: GCC writes 'x' with U+2018/U+2019, which is what
        # trips an ASCII locale. Pinned to utf-8, the characters arrive unharmed.
        d = BuildDriver(str(tmp_path), host())
        seen: list[str] = []
        code = d._stream(
            _emit(r"'warning: unused variable ‘x’\n'.encode('utf-8')"),
            seen.append, "docker")

        assert code == 0
        assert seen == ["warning: unused variable ‘x’"]

    def test_a_multi_byte_character_split_across_reads_is_not_mangled(self, tmp_path):
        # Long lines are delivered to the reader in chunks; a boundary landing mid
        # character must not produce two replacement chars.
        d = BuildDriver(str(tmp_path), host())
        seen: list[str] = []
        payload = r"(('x' * 9000) + '‘quoted’' + ('y' * 9000) + '\n').encode('utf-8')"
        code = d._stream(_emit(payload), seen.append, "docker")

        assert code == 0
        assert len(seen) == 1
        assert "‘quoted’" in seen[0]
        assert "�" not in seen[0]

    def test_output_still_streams_line_by_line(self, tmp_path):
        # Guard against "fixed the encoding, broke the streaming": the console depends on
        # receiving lines as they are produced, not one blob at the end.
        d = BuildDriver(str(tmp_path), host())
        seen: list[str] = []
        code = d._stream(_emit(r"b'one\ntwo\nthree\n'"), seen.append, "docker")

        assert code == 0
        assert seen == ["one", "two", "three"]


class TestTheSharedDecodingRule:

    def test_it_pins_utf8_rather_than_trusting_the_locale(self):
        assert proc_text.TEXT_IO["encoding"] == "utf-8"

    def test_it_replaces_rather_than_raising_or_deleting(self):
        assert proc_text.TEXT_IO["errors"] == "replace"

    @pytest.mark.parametrize("module", [
        "build_driver", "worklist_driver", "golive_driver",
        "phone_wizard", "qemu_tests", "local_stack_node",
    ])
    def test_every_streaming_module_uses_it(self, module):
        # A new streaming call site that forgets this is the way the bug comes back, and
        # it would come back invisibly: the console works fine until a build emits a
        # character outside the launcher's locale, which no CI run would catch.
        import importlib
        src = importlib.import_module(f"hugmesh_studio.core.{module}").__file__
        with open(src, encoding="utf-8") as fh:
            text = fh.read()
        assert "proc_text.TEXT_IO" in text, f"{module} streams output without the shared decoding rule"


class TestTheEmulationPagesHaveOnlyOneSpawnLane:
    """The rule above only holds if there is ONE place to apply it.

    Both emulation screens stream a subprocess into a console, and both used to do
    it themselves: the test page carried its own ``_DeviceJob`` (a second Popen with
    its own read loop) alongside ``QemuTestRunner``'s, and the mesh page a third. A
    decoding rule — or a cancel rule, or a process-group rule — applied to one of
    those is not applied to the others, which is exactly how the two screens came to
    kill devices differently.

    After T3 every runner invocation on both pages goes through
    ``core.emulation.spawn``, the single process boundary the facade documents. That
    is what makes these pages testable with no docker and no qemu (the tests replace
    that one function), and it is what leaves exactly ONE call site where the shared
    decoding rule has to hold.

    NOTE for whoever lands the decoding fix in the facade: ``emulation.spawn`` still
    opens its pipe with a bare ``text=True`` — i.e. the launcher's locale — where
    ``qemu_tests.QemuTestRunner`` (its sibling, and the lane it replaced) pins
    ``proc_text.TEXT_IO``. That is a core/ change, deliberately not made from the GUI
    workstream; these assertions are what guarantee it is a ONE-LINE change when it
    is made, rather than four.
    """

    #: The GUI modules that may spawn at all, and what each is allowed to spawn.
    #: Detached desktop launches (a terminal, an ssh tunnel) are fine — they own
    #: their own tty or nothing at all, and the page never reads their output — but
    #: a PIPED spawn is a second console lane and is refused.
    PAGES = ["qemu", "mesh_emulation", "_emulation_common"]

    def _source(self, page):
        import importlib
        src = importlib.import_module(f"hugmesh_studio.gui.pages.{page}").__file__
        with open(src, encoding="utf-8") as fh:
            return fh.read()

    @pytest.mark.parametrize("page", PAGES)
    def test_no_page_reads_a_pipe_of_its_own(self, page):
        text = self._source(page)
        for forbidden in ("stdout=subprocess.PIPE", "stderr=subprocess.PIPE",
                          "subprocess.run(", "subprocess.call(",
                          "subprocess.check_output("):
            assert forbidden not in text, (
                f"gui/pages/{page}.py reads a pipe of its own — that is a second "
                "streaming lane the shared decoding rule does not cover")

    @pytest.mark.parametrize("page", ["qemu", "mesh_emulation"])
    def test_every_runner_invocation_goes_through_the_facade(self, page):
        text = self._source(page)
        assert "emulation.spawn(" in text
        assert "QemuTestRunner" not in text, (
            f"gui/pages/{page}.py still drives the old runner lane, which spawns "
            "and decodes independently of core.emulation.spawn")

    @pytest.mark.parametrize("page", ["qemu", "mesh_emulation"])
    def test_a_detached_launch_is_detached_and_unread(self, page):
        # The only Popen either page may reach for: a terminal or an ssh tunnel,
        # start_new_session'd so it outlives the wizard, with no pipe to decode.
        text = self._source(page)
        if "subprocess.Popen(" in text:
            assert "start_new_session=True" in text
