"""The test files tests/test_look.py starts, one fresh interpreter each (#647, #656).

Its own module, with no Qt import, so tests/test_qt_suite_census.py can read it where no
Qt binding is installed: test_look.py importorskips Qt, so a check that lived there was
skipped by the Qt-free GitHub job, and the list went stale on main without anything
going red.

A file whose ``test_look_*`` cases call ``_look.child_only()`` (they skip in an ordinary
run) must be listed here, or those cases never run anywhere. The census fails when one
is not listed.
"""

LOOK_FILES = ("test_anubis_tristate_page.py", "test_localcloud_nodes.py",
              "test_pages_qemu.py", "test_pages_mesh_emulation.py",
              "test_look_editor.py", "test_launch_save_mesh.py")
