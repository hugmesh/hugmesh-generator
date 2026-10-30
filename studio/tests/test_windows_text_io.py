"""Text and encoding on native Windows (issue #827 group 4). Qt-free.

Three ways a Windows text default broke the Studio there and nowhere else:
  * a text-mode stdin writes "\\n" as "\\r\\n", so the Vault token line read in the pod
    ended in "\\r" and every Vault call over the kind route was refused;
  * ``text=True`` with no encoding decodes docker/kubectl output as cp1252, so a byte
    it cannot map raised UnicodeDecodeError past the "never raises" guards;
  * Notepad saves JSON with a BOM and Windows PowerShell saves UTF-16, which
    ``open(encoding="utf-8")`` + ``json.load`` refuses ("Load config" did nothing).
"""
from __future__ import annotations

import ast
import json
import pathlib
import sys

import pytest

from hugmesh_studio.core import json_files, vaults
from hugmesh_studio.core.config import ImageConfig
from hugmesh_studio.core.worklist import load_any

CORE = pathlib.Path(__file__).resolve().parents[1] / "hugmesh_studio" / "core"


def test_the_vault_stdin_reaches_the_child_byte_for_byte():
    echo = "import sys; sys.stdout.write(repr(sys.stdin.buffer.read()))"
    r = vaults._run([sys.executable, "-c", echo], stdin="s.token\nkv-value")
    assert r.returncode == 0, r.stderr
    assert r.stdout == repr(b"s.token\nkv-value")         # no \r on Windows


def test_vault_output_is_text_with_plain_newlines():
    out = "import sys; sys.stdout.buffer.write('caf\\u00e9\\r\\nok\\n'.encode())"
    r = vaults._run([sys.executable, "-c", out])
    assert r.stdout == "café\nok\n" and r.stderr == ""


@pytest.mark.parametrize("encoding", ["utf-8", "utf-8-sig", "utf-16"])
def test_hand_edited_json_loads_whatever_windows_saved_it_as(tmp_path, encoding):
    p = tmp_path / "c.json"
    p.write_text(json.dumps({"hostname": "nøde"}), encoding=encoding)
    assert json_files.load(str(p)) == {"hostname": "nøde"}
    assert ImageConfig.load(str(p)).hostname == "nøde"
    base, wl = load_any(str(p))
    assert wl is None and base.hostname == "nøde"


#: The modules group 4 named. Every text-mode subprocess call in them must pin the
#: decoding (``**proc_text.TEXT_IO`` or an explicit ``encoding=``).
PINNED = ["mesh_controls.py", "mesh_node.py", "local_stack_node.py", "e2e_catalogue.py"]


@pytest.mark.parametrize("name", PINNED)
def test_no_text_mode_call_decodes_with_the_code_page(name):
    tree = ast.parse((CORE / name).read_text(encoding="utf-8"))
    bare = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        kws = {k.arg for k in node.keywords}
        text = any(k.arg == "text" and isinstance(k.value, ast.Constant) and k.value.value
                   for k in node.keywords)
        if text and "encoding" not in kws and None not in kws:     # None = **kwargs
            bare.append(node.lineno)
    assert not bare, f"{name}: text=True without an encoding at lines {bare}"
