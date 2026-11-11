"""The test files whose ``test_look_*`` cases tests/test_look.py runs (#647, #656).

A module of its own, with no Qt import, so the census over it
(tests/test_qt_suite_guards.py) runs in the pull-request job that installs no Qt
binding. tests/test_look.py importorskips Qt at the top, so a census kept inside it
skipped there, and the census was red for a whole merge (#937) without anyone seeing.

A new look case in another file must be added here, or it never runs anywhere: it
skips in an ordinary run (``_look.child_only``) and only tests/test_look.py starts the
fresh interpreter it runs in. Paths are relative to tests/.
"""

LOOK_FILES = ("test_anubis_tristate_page.py", "test_localcloud_nodes.py",
              "test_pages_qemu.py", "test_pages_mesh_emulation.py",
              "test_look_editor.py", "test_launch_save_mesh.py",
              "test_pki_lan_page.py", "test_mesh_control_page.py")
