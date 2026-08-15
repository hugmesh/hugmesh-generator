"""DeviceTable — the Review & Build "Attached devices" table (flash / keys assignment).

Replaces the single flash-with-build dropdown with a selectable table of attached
USB / SD / eMMC devices. Each row can be assigned a ROLE:

* **Flash target** — after a successful build, the chosen worklist image is written to
  that device via ``scripts/flash-disk.sh`` (multi-image worklists pick WHICH image per
  row; several devices may take the same or different images). Flash assignments never
  touch the build argv — they are a POST-BUILD plan, summarized read-only below the
  table and executed by the ProgressPage behind its TOCTOU identity re-check. Every
  row defaults to "(none)": no flashing is ever the commit default.
* **Keys USB** — marks the device's mounted directory as the fleet Secure Boot signing
  key source, written THROUGH the existing ``keys_usb`` line edit so the pre-existing
  ``--keys-usb`` axis (config.py) emits it; exclusive across rows (one axis). The role
  item is disabled-with-a-reason when the platform's builder has no ``--keys-usb`` flag
  or the device is not mounted (the hide-inapplicable honesty rule — an assignment that
  would emit nothing is never offered).

SAFETY: the table has NO detection code of its own — its only data source is
``flash_targets.list_targets()``, so the #348 root-disk exclusion (the disk backing
``/`` never appears) and the size-sanity window hold structurally. The scan runs on a
``_ScanWorker`` QThread (the build.py ``_PreflightWorker`` idiom) behind a 250 ms
debounce so ``lsblk`` (8 s worst case) never stalls the Qt main loop — the #348
freeze lesson.
"""
from __future__ import annotations

from ..qt import QtCore, QtWidgets, Signal
from ...core import flash_targets, platform_info

# role-combo data tokens
ROLE_NONE = "none"
ROLE_FLASH = "flash"
ROLE_KEYS = "keys"

_COLUMNS = ("Device", "Model / Label", "Size", "Bus", "Mounted", "Role",
            "Image / Dir", "Artifact")
_COL_ROLE = 5
_COL_EXTRA = 6
# per-flash-row FLAVOUR pick (install/live/img): which of the entry's built
# artifacts is written. Choices come from flash_targets.flavors_for_platform for the
# ASSIGNED image's platform (hide-inapplicable: a flavour that platform's builder
# cannot emit would make the plan skip 100% of the time).
_COL_FLAVOR = 7


class _ScanWorker(QtCore.QThread):
    """Runs the read-only ``flash_targets.list_targets()`` scan off the GUI thread
    (lsblk can block up to its 8 s timeout on a wedged device). Carries a req_id so
    the GUI slot can drop stale results from rapid refreshes — the _PreflightWorker
    idiom from build.py."""
    done = Signal(object, int)          # (targets: list[FlashTarget], req_id)

    def __init__(self, req_id: int):
        super().__init__()
        self._req_id = req_id

    def run(self) -> None:
        try:
            targets = flash_targets.list_targets()
        except Exception:
            targets = []
        self.done.emit(targets, self._req_id)


class DeviceTable(QtWidgets.QGroupBox):
    """The per-device assignment table (see module docstring).

    ``images_provider()`` returns ``[(entry_id, role, platform, domains)]`` for the
    would-be-committed worklist (the per-row Image combo; ``domains`` — the cluster
    domain names attached to that entry — decorates the label so a device is
    assigned "the beta.example backend", not a bare id). 3-tuples without domains
    stay accepted. ``keys_gate()`` returns
    ``(allowed, reason)`` for the platform-level Keys-USB gating (keys_usb is x86-only
    today). ``on_assignment_changed()`` fires after any role / image / dir change so
    the page can write a keys assignment through the existing keys_usb field."""

    def __init__(self, *, images_provider, keys_gate, on_assignment_changed):
        super().__init__("Attached devices — flash / keys assignment")
        self._images_provider = images_provider
        self._keys_gate = keys_gate
        self._on_assignment_changed = on_assignment_changed
        self._targets: list[flash_targets.FlashTarget] = []
        # per-path assignment state (survives repopulation — re-applied by path)
        self._assign: dict[str, dict] = {}
        self._scan_gen = 0
        self._worker: _ScanWorker | None = None

        lay = QtWidgets.QVBoxLayout(self)
        self.table = QtWidgets.QTableWidget(0, len(_COLUMNS))
        self.table.setHorizontalHeaderLabels(list(_COLUMNS))
        self.table.horizontalHeader().setStretchLastSection(False)
        self.table.verticalHeader().setVisible(False)
        self.table.setEditTriggers(QtWidgets.QAbstractItemView.EditTrigger.NoEditTriggers)
        lay.addWidget(self.table)
        btn_row = QtWidgets.QHBoxLayout()
        self.refresh_btn = QtWidgets.QPushButton("Refresh")
        self.refresh_btn.clicked.connect(self.refresh)
        btn_row.addWidget(self.refresh_btn)
        btn_row.addStretch(1)
        lay.addLayout(btn_row)
        # PLATFORM GATE — see _platform_blocked. Selectable so the operator can copy the
        # usbipd commands straight out of it; hidden entirely when flashing is available,
        # so the normal path gains no chrome.
        self.platform_note = QtWidgets.QLabel("")
        self.platform_note.setWordWrap(True)
        self.platform_note.setTextInteractionFlags(
            QtCore.Qt.TextInteractionFlag.TextSelectableByMouse)
        self.platform_note.setStyleSheet("color: #a05000;")
        self.platform_note.setVisible(False)
        lay.addWidget(self.platform_note)

        # read-only post-build plan summary (flash assignments are NOT build argv)
        self.plan_label = QtWidgets.QLabel("")
        self.plan_label.setWordWrap(True)
        self.plan_label.setStyleSheet("color: gray;")
        lay.addWidget(self.plan_label)
        self._apply_platform_gate()

        # 250 ms single-shot debounce collapses refresh bursts into one scan; the last
        # result stays rendered while a fresh scan runs (button shows "Scanning…").
        self._debounce = QtCore.QTimer(self)
        self._debounce.setSingleShot(True)
        self._debounce.setInterval(250)
        self._debounce.timeout.connect(self._start_scan)
        self._render_plan()

    # ---- platform gate ---------------------------------------------------------------
    def _apply_platform_gate(self) -> None:
        """Refuse to enumerate flash targets where the answer could only mislead.

        The scan is ``lsblk`` + ``/proc/mounts``, which BOTH still succeed inside a WSL2
        VM — they just describe the VM. A WSL2 guest sees no USB device until Windows
        hands one over with usbipd-win, so an ungated table there lists the VM's own
        virtual disk and invites the operator to write a Pi image onto the root disk of
        the machine they are sitting at. Silence is not an option either: "no devices
        found" reads as "unplug/replug it", sending them round a loop that cannot
        succeed. So the row says WHAT is wrong and HOW to fix it (HostInfo.flash_blocker
        carries the exact usbipd invocation), and the Refresh button is disabled rather
        than offering a rescan that is guaranteed to find nothing new.
        """
        host = platform_info.detect()
        blocked = not host.can_flash_devices
        self._platform_blocked = blocked
        if blocked:
            self.platform_note.setText(host.flash_blocker())
        self.platform_note.setVisible(blocked)
        self.refresh_btn.setEnabled(not blocked)
        if blocked:
            self.refresh_btn.setText("Unavailable here")
            self.table.setRowCount(0)

    # ---- scanning (off-thread; read-only) ----------------------------------------
    def refresh(self) -> None:
        """Kick a debounced off-thread rescan; the cached table stays rendered."""
        if getattr(self, "_platform_blocked", False):
            return                      # nothing to find; the note already says why
        self._scan_gen += 1
        self.refresh_btn.setText("Scanning…")
        self.refresh_btn.setEnabled(False)
        self._debounce.start()

    def _start_scan(self) -> None:
        if getattr(self, "_platform_blocked", False):
            return
        if self._worker is not None and self._worker.isRunning():
            self._debounce.start()      # re-arm: never strand a pending refresh
            return
        self._worker = _ScanWorker(self._scan_gen)
        self._worker.done.connect(self._on_scan_done)
        self._worker.start()

    def _on_scan_done(self, targets, req_id: int) -> None:
        if req_id != self._scan_gen:
            self._debounce.start()      # superseded — rescan against the newest gen
            return
        self.refresh_btn.setText("Refresh")
        self.refresh_btn.setEnabled(True)
        self._targets = list(targets)
        self._repopulate()

    def join(self) -> None:
        """Never leave a scan thread running past the wizard (mirrors
        BuildPage._join_preflight_worker)."""
        self._debounce.stop()
        if self._worker is not None and self._worker.isRunning():
            self._worker.wait(3000)

    # ---- table rendering -----------------------------------------------------------
    def _repopulate(self) -> None:
        # prune assignments for unplugged devices, re-apply the rest keyed on path
        present = {t.path for t in self._targets}
        self._assign = {p: a for p, a in self._assign.items() if p in present}
        self.table.setRowCount(len(self._targets))
        for i, t in enumerate(self._targets):
            self.table.setItem(i, 0, QtWidgets.QTableWidgetItem(t.path))
            model = (t.model or "").strip()
            fs_label = (t.fs_label or "").strip()
            name = (f"{model} · {fs_label}" if model and fs_label
                    else model or fs_label or "(unknown)")
            hint = t.hint()
            if hint:
                name = f"{name} — {hint}" if name != "(unknown)" else hint
            self.table.setItem(i, 1, QtWidgets.QTableWidgetItem(name))
            self.table.setItem(i, 2, QtWidgets.QTableWidgetItem(
                f"{t.size / (1 << 30):.1f} GiB"))
            bus = (t.kind if not t.transport or t.transport == t.kind
                   else f"{t.kind} ({t.transport})")
            self.table.setItem(i, 3, QtWidgets.QTableWidgetItem(bus))
            self.table.setItem(i, 4, QtWidgets.QTableWidgetItem(
                "mounted: " + ", ".join(t.mountpoints) if t.mounted else "—"))
            self.table.setCellWidget(i, _COL_ROLE, self._role_combo(i, t))
            self._set_extra_cell(i, t)
        self.table.resizeColumnsToContents()
        self._render_plan()
        self._notify()

    def _role_combo(self, row: int, t) -> QtWidgets.QComboBox:
        combo = QtWidgets.QComboBox()
        combo.addItem("(none)", ROLE_NONE)
        combo.addItem("Flash target", ROLE_FLASH)
        combo.addItem("Keys USB", ROLE_KEYS)
        # fail CLOSED: if the gate itself errors we cannot prove --keys-usb would
        # emit, so the honest state is disabled-with-a-reason, never a silent maybe.
        try:
            allowed, reason = self._keys_gate()
        except Exception:
            allowed, reason = False, "keys gating unavailable — cannot verify --keys-usb applies"
        if allowed and not t.mounted:
            allowed = False
            reason = "not mounted — mount the stick first; --keys-usb needs a directory"
        if not allowed:
            # honesty: an assignment that would emit nothing is disabled WITH a reason
            item = combo.model().item(2)
            if item is not None:
                item.setEnabled(False)
            combo.setItemData(2, reason, QtCore.Qt.ItemDataRole.ToolTipRole)
        prev = self._assign.get(t.path, {}).get("role", ROLE_NONE)
        if prev == ROLE_KEYS and not allowed:
            self._assign.pop(t.path, None)      # a now-inapplicable keys pick can't linger
            prev = ROLE_NONE
        combo.setCurrentIndex(max(0, combo.findData(prev)))
        combo.currentIndexChanged.connect(lambda _=0, r=row: self._role_changed(r))
        return combo

    def _set_extra_cell(self, row: int, t) -> None:
        """The last column follows the row's role: a per-row Image combo (flash), a
        Dir… picker (keys), or empty (none)."""
        a = self._assign.get(t.path)
        role = a.get("role") if a else ROLE_NONE
        if role == ROLE_FLASH:
            combo = QtWidgets.QComboBox()
            combo.setToolTip("Which built image is flashed to this device after a "
                             "successful build (via scripts/flash-disk.sh).")
            for entry_id, _role, _platform, domains in self._image_choices():
                label = entry_id + (f"  ({', '.join(domains)})" if domains else "")
                combo.addItem(label, entry_id)
                if domains:
                    combo.setItemData(combo.count() - 1,
                                      "domains: " + ", ".join(domains),
                                      QtCore.Qt.ItemDataRole.ToolTipRole)
            i = combo.findData(a.get("entry_id", ""))
            if i >= 0:
                combo.setCurrentIndex(i)
            a["entry_id"] = combo.currentData() or ""
            combo.currentIndexChanged.connect(lambda _=0, r=row: self._image_changed(r))
            self.table.setCellWidget(row, _COL_EXTRA, combo)
        elif role == ROLE_KEYS:
            btn = QtWidgets.QPushButton(a.get("keys_dir") or "Dir…")
            btn.setToolTip("Directory on the keys USB providing Keys/kernel_key.{pem,der} "
                           "(--keys-usb). Defaults to the mountpoint; click to pick a "
                           "Keys/ subfolder.")
            btn.clicked.connect(lambda _=False, r=row: self._pick_keys_dir(r))
            self.table.setCellWidget(row, _COL_EXTRA, btn)
        else:
            self.table.removeCellWidget(row, _COL_EXTRA)
            self.table.setItem(row, _COL_EXTRA, QtWidgets.QTableWidgetItem(""))
        self._set_flavor_cell(row, t)

    def _image_choices(self) -> list[tuple]:
        """Normalized ``(entry_id, role, platform, domains)`` rows from the provider
        (3-tuples get an empty domains tail); [] on provider failure."""
        try:
            raw = list(self._images_provider())
        except Exception:
            return []
        out = []
        for c in raw:
            entry_id, role, platform = c[0], c[1], c[2]
            domains = tuple(c[3]) if len(c) > 3 and c[3] else ()
            out.append((entry_id, role, platform, domains))
        return out

    def _entry_platform(self, entry_id: str) -> str:
        for eid, _role, platform, _domains in self._image_choices():
            if eid == entry_id:
                return platform
        return ""

    def _set_flavor_cell(self, row: int, t) -> None:
        """The Artifact column: a flavour combo for a flash row with an assigned
        image (choices = what that image's platform can emit), else empty."""
        a = self._assign.get(t.path)
        if not (a and a.get("role") == ROLE_FLASH and a.get("entry_id")):
            self.table.removeCellWidget(row, _COL_FLAVOR)
            self.table.setItem(row, _COL_FLAVOR, QtWidgets.QTableWidgetItem(""))
            if a is not None:
                a.pop("flavor", None)   # no image, no flavour — nothing may linger
            return
        platform = self._entry_platform(a["entry_id"])
        combo = QtWidgets.QComboBox()
        combo.setToolTip(
            "WHICH built artifact is written: the OS .img, the live USB "
            "(.live.iso) or the install USB (.installer.iso). Only what this "
            "image's platform actually builds is offered; 'auto' takes the newest "
            "built (.img preferred). A flavour the finished build did not produce "
            "is skipped at flash time with the reason — never guessed.")
        for fl in flash_targets.flavors_for_platform(platform):
            combo.addItem(flash_targets.FLAVOR_LABELS.get(fl, fl), fl)
        prev = a.get("flavor", flash_targets.FLAVOR_AUTO)
        i = combo.findData(prev)
        combo.setCurrentIndex(i if i >= 0 else 0)
        a["flavor"] = combo.currentData() or flash_targets.FLAVOR_AUTO
        combo.currentIndexChanged.connect(lambda _=0, r=row: self._flavor_changed(r))
        self.table.setCellWidget(row, _COL_FLAVOR, combo)

    def _flavor_changed(self, row: int) -> None:
        if row >= len(self._targets):
            return
        t = self._targets[row]
        a = self._assign.get(t.path)
        combo = self.table.cellWidget(row, _COL_FLAVOR)
        if a is not None and a.get("role") == ROLE_FLASH and combo is not None:
            a["flavor"] = combo.currentData() or flash_targets.FLAVOR_AUTO
        self._render_plan()
        self._notify()

    # ---- assignment state ------------------------------------------------------------
    def _role_changed(self, row: int) -> None:
        if row >= len(self._targets):
            return
        t = self._targets[row]
        combo = self.table.cellWidget(row, _COL_ROLE)
        role = combo.currentData() if combo is not None else ROLE_NONE
        if role == ROLE_FLASH:
            keep = self._assign.get(t.path, {}).get("entry_id", "")
            self._assign[t.path] = {"role": ROLE_FLASH, "entry_id": keep, "keys_dir": ""}
        elif role == ROLE_KEYS:
            # exclusive across rows: cfg.keys_usb is a single axis — assigning it here
            # clears any other row's Keys assignment.
            for other in [p for p, a in self._assign.items()
                          if p != t.path and a.get("role") == ROLE_KEYS]:
                self._assign.pop(other, None)
                self._reset_role_combo(other)
            keep = self._assign.get(t.path, {}).get("keys_dir", "")
            default_dir = t.mountpoints[0] if t.mountpoints else ""
            self._assign[t.path] = {"role": ROLE_KEYS, "entry_id": "",
                                    "keys_dir": keep or default_dir}
        else:
            self._assign.pop(t.path, None)
        self._set_extra_cell(row, t)
        self.table.resizeColumnsToContents()
        self._render_plan()
        self._notify()

    def _reset_role_combo(self, path: str) -> None:
        for row, t in enumerate(self._targets):
            if t.path == path:
                combo = self.table.cellWidget(row, _COL_ROLE)
                if combo is not None:
                    combo.blockSignals(True)
                    combo.setCurrentIndex(0)
                    combo.blockSignals(False)
                self._set_extra_cell(row, t)
                return

    def _image_changed(self, row: int) -> None:
        if row >= len(self._targets):
            return
        t = self._targets[row]
        a = self._assign.get(t.path)
        combo = self.table.cellWidget(row, _COL_EXTRA)
        if a is not None and a.get("role") == ROLE_FLASH and combo is not None:
            a["entry_id"] = combo.currentData() or ""
        self._set_flavor_cell(row, t)   # the new image's platform bounds the flavours
        self._render_plan()
        self._notify()

    def _pick_keys_dir(self, row: int) -> None:
        if row >= len(self._targets):
            return
        t = self._targets[row]
        a = self._assign.get(t.path)
        if not a or a.get("role") != ROLE_KEYS:
            return
        start = a.get("keys_dir") or (t.mountpoints[0] if t.mountpoints else "")
        d = QtWidgets.QFileDialog.getExistingDirectory(self, "KEYS USB dir", start)
        if d:
            a["keys_dir"] = d
            self._set_extra_cell(row, t)
            self._render_plan()
            self._notify()

    def _notify(self) -> None:
        try:
            self._on_assignment_changed()
        except Exception:
            pass

    # ---- what the page reads -----------------------------------------------------
    def flash_assignments(self) -> list[tuple]:
        """[(FlashTarget, entry_id, flavor)] for every row assigned as a flash
        target (flavor is a flash_targets flavour token; "auto" = newest built)."""
        out = []
        for t in self._targets:
            a = self._assign.get(t.path)
            if a and a.get("role") == ROLE_FLASH and a.get("entry_id"):
                out.append((t, a["entry_id"], a.get("flavor",
                                                    flash_targets.FLAVOR_AUTO)))
        return out

    def keys_assignment(self):
        """(FlashTarget, dir) for the (single) Keys-USB row, or None."""
        for t in self._targets:
            a = self._assign.get(t.path)
            if a and a.get("role") == ROLE_KEYS and a.get("keys_dir"):
                return (t, a["keys_dir"])
        return None

    def _render_plan(self) -> None:
        """The read-only post-build plan summary — flash assignments never appear in
        the build command; this label is where they show instead."""
        parts = []
        for t, entry_id, flavor in self.flash_assignments():
            name = (t.model or t.fs_label or "").strip()
            gib = t.size / (1 << 30)
            desc = f"{name}, {gib:.0f} GiB" if name else f"{gib:.0f} GiB"
            flav = "" if flavor == flash_targets.FLAVOR_AUTO else f" [{flavor}]"
            parts.append(f"{entry_id}{flav} → {t.path} ({desc})")
        if parts:
            self.plan_label.setText(
                "Post-build plan — after a successful build (via scripts/flash-disk.sh): "
                + "; ".join(parts))
        else:
            self.plan_label.setText("Post-build plan: no post-build flashing (default).")
