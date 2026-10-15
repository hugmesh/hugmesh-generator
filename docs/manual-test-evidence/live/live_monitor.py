"""Render Studio's monitor table against the LIVE compose + kind lanes (read-only).
usage: QT_QPA_PLATFORM=offscreen python live_monitor.py <generator_dir> <out.png> <out.txt>"""
import sys, os
gen, png, txt = sys.argv[1:4]
sys.path.insert(0, os.path.join(gen, "studio"))
from hugmesh_studio.gui.qt import QtWidgets
app = QtWidgets.QApplication([])
from hugmesh_studio.core import mesh_monitor
from hugmesh_studio.core.local_stack_node import LocalStackNode
from hugmesh_studio.gui.pages._mesh_monitor_widget import MeshMonitorWidget
node = LocalStackNode(gen)
snap = mesh_monitor.snapshot(gen, node)
w = MeshMonitorWidget(scaling=True); w.resize(1500, 900); w.render(snap); w.show(); app.processEvents()
w.grab().save(png)
lines = [f"taken_at={snap.taken_at}", f"compose lane: running={snap.compose.running} error={snap.compose.error!r}",
         f"kind lane: running={snap.kind.running} error={snap.kind.error!r}", f"errors={snap.errors}"]
from collections import Counter
lines.append("units by lane: %s" % dict(Counter(u.lane for u in snap.units)))
lines.append("lane | ns | name | state | scale kind | scale name | replicas_now | external")
for u in snap.units:
    lines.append(" | ".join([u.lane, u.namespace, u.name, u.state, u.scale.kind, u.scale.name,
        str(mesh_monitor.replicas_now(snap.units, u.scale)) if u.scale.kind else "-", u.external]))
open(txt, "w").write("\n".join(lines) + "\n")
print("\n".join(lines[:60]))
