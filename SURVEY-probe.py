"""Survey probe: defaults + gating + argv on the CURRENT base. Read-only."""
import os, sys
sys.path.insert(0, os.environ["STUDIO"])
from hugmesh_studio.gui.qt import QtWidgets, Qt
from hugmesh_studio.core.config import ImageConfig
from hugmesh_studio.core.worklist import WorklistConfig, WorklistEntry

app = QtWidgets.QApplication([])
from hugmesh_studio.gui.wizard import StudioWizard

NAMES = {Qt.CheckState.Unchecked: "Unchecked", Qt.CheckState.Checked: "Checked",
         Qt.CheckState.PartiallyChecked: "PartiallyChecked"}


def cs(b):
    return NAMES.get(b.checkState(), str(b.checkState()))


def run(base_role, tag):
    w = StudioWizard(os.environ["GEN"])
    c = w.cfg
    c.mode = "mesh"
    c.platform = "x86"
    c.role = base_role
    wl = WorklistConfig(base=c)
    wl.entries = [WorklistEntry(id="e0", role=base_role, platform="x86"),
                  WorklistEntry(id="e1", role="pki", platform="x86")]
    w.worklist = wl
    net = w.page(w._page_ids["network"]); net.initializePage()
    bld = w.page(w._page_ids["build"]); bld.initializePage()
    hom = w.page(w._page_ids["home"]); hom.initializePage()
    sysp = w.page(w._page_ids["system"]); sysp.initializePage()
    usr = w.page(w._page_ids["users"]); usr.initializePage()
    brand = w.page(w._page_ids["branding"]); brand.initializePage()
    print(f"=== {tag}  (mesh, base role={base_role!r}) ===")
    for n in ("aide", "edge_ai", "tor_onion", "character_studio", "character_forge",
              "edge_ai_tts"):
        b = getattr(net, n)
        print(f"  NET tri {n:<18} {cs(b):<17} tristate={b.isTristate()}")
    for n in ("snort", "edge_ai_analysis", "services_none", "services_all", "games",
              "egress_locked"):
        b = getattr(net, n)
        print(f"  NET 2st {n:<18} checked={b.isChecked()}")
    print(f"  NET proxy_stack={net.proxy_stack.currentText()!r} "
          f"exclude={net.exclude.text()!r} svc_checked="
          f"{[net.services.item(i).text() for i in range(net.services.count()) if net.services.item(i).checkState()==Qt.CheckState.Checked]}")
    for n in ("build_img", "live_iso", "build_tar", "secure_boot"):
        print(f"  BLD tri {n:<18} {cs(getattr(bld, n))}")
    for n in ("cached", "live_toram", "bundle_source", "compress", "resume",
              "installer_iso", "build_iso", "sd_only", "skip_iso", "image_only"):
        print(f"  BLD 2st {n:<18} checked={getattr(bld, n).isChecked()}")
    print(f"  HOME login group visible={hom.login.isVisibleTo(hom)} "
          f"title={hom.login.title()!r}")
    print(f"  HOME standalone visible={hom.standalone.isVisibleTo(hom)} "
          f"local_user visible={hom.local_user.isVisibleTo(hom)} text={hom.local_user.text()!r}")
    print(f"  HOME media_data visible={hom.media_data.isVisibleTo(hom)} "
          f"no_vaults visible={hom.no_vaults.isVisibleTo(hom)}")
    print(f"  HOME home_box mode enabled={hom.mode.isEnabled()} visible={hom.mode.isVisibleTo(hom)}")
    print(f"  HOME encrypt_root checked={hom.encrypt_root.isChecked()} "
          f"visible={hom.encrypt_root.isVisibleTo(hom)}  cfg.encrypt_root={c.encrypt_root}")
    print(f"  NET  egress_row visible={net.egress_row.isVisibleTo(net)} "
          f"egress_section visible={net.egress_section.isVisibleTo(net)}")
    print(f"  SYS  creds visible={sysp.creds.isVisibleTo(sysp)}  "
          f"hostname={sysp.hostname.text()!r} tz_widget={type(sysp.timezone).__name__} "
          f"tz={sysp.timezone.text()!r} user={sysp.user.text()!r}")
    print(f"  USR  person_role={usr.person_role.currentText()!r} "
          f"row_visible={usr.person_role_row.isVisibleTo(usr)}")
    print(f"  BRAND form enabled={brand.form.isEnabled()} "
          f"themes={[brand.theme.itemText(i) for i in range(brand.theme.count())]} "
          f"rb_preset={brand.rb_preset.isChecked()} rb_custom={brand.rb_custom.isChecked()}")
    print(f"  BLD bundle_source visible={bld.bundle_source.isVisibleTo(bld)} "
          f"installer_ui enabled={bld.installer_ui.isEnabled()}")
    w.deleteLater()


run("pki", "NODE-FIRST")
run("rpi5-desktop", "DESKTOP-FIRST")

# argv probe: a bare mesh x86 pki config
c = ImageConfig(mode="mesh", platform="x86", role="pki")
argv = c.to_cli_args()
print("\n=== bare mesh x86 pki argv ===")
print(" ".join(argv))
for f in ("--local-user", "--bundle-source", "--uncached", "--live-toram",
          "--no-tor", "--with-tor", "--encrypt-root", "--snort", "--live-iso",
          "--compress", "--resume", "--installer-iso"):
    print(f"  {f:<18} {'PRESENT' if f in argv else '-'}")
