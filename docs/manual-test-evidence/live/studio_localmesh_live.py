"""Drive the REAL Studio wizard (real docker/kind host detection, NOT the pinned test host) into the
Local Docker mesh flow while the compose stack + kind cluster are live; grab each page.
usage: QT_QPA_PLATFORM=offscreen python studio_localmesh_live.py <generator_dir> <outdir>"""
import os, sys, time
gen, out = sys.argv[1:3]
os.makedirs(out, exist_ok=True)
sys.path.insert(0, os.path.join(gen, "studio")); sys.path.insert(0, os.path.join(gen, "studio", "tests"))
from hugmesh_studio.gui.qt import QtWidgets
app = QtWidgets.QApplication([])
from hugmesh_studio.gui import wizard as W
from _helpers import advance_to, pick_mode
w = W.StudioWizard(gen); w.resize(1400, 900); w.show(); app.processEvents()
log = []
def pump(s=1.5):
    t = time.time()
    while time.time() - t < s: app.processEvents(); time.sleep(0.05)
def shot(name):
    pump(); w.grab().save(os.path.join(out, name + ".png"))
    p = w.currentPage(); log.append(f"{name}: page={type(p).__name__} title={p.title()!r}")
shot("01-welcome")
pick_mode(w, "localmesh"); shot("02-mode-localmesh-picked")
i = 3
w.next(); pump(2.0)
shot("03b-choice-cards-with-live-mesh-running")
w.currentPage()._buttons["generate"].setChecked(True); pump(0.5); shot("03c-generate-card-picked")
i = 4
for _ in range(14):
    before = w.currentId(); w.next(); pump(2.5)
    if w.currentId() == before: log.append("stopped: Next did not advance"); break
    shot(f"{i:02d}-{type(w.currentPage()).__name__}"); i += 1
    if type(w.currentPage()).__name__ in ("LocalMeshPage",) and False: break
open(os.path.join(out, "walk.txt"), "w").write("\n".join(log) + "\n"); print("\n".join(log))
