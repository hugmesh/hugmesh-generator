"""The Desktop step's command-line face (``hugmesh_studio --desktop-options`` and
``--desktop-pretend CONFIG``) — Qt-free, the third face of core/desktop_spec.py beside
the GUI page (gui/pages/desktop.py) and the text UI (tui/desktop_step.py).

``--desktop-pretend`` runs the same builder check the GUI's "Check with emerge --pretend"
button runs (core/desktop_pretend.py), gated the same way (one build / QEMU at a time on
this machine, memory and disk floors), records it under ``<out>/pretend/<key>/`` and
prints the result. It never edits the config unless ``--apply-portage-fixes`` is given,
and then only with portage's own suggestions, recorded in the spec's history.
Exit status: 0 clean, 3 needs changes, 1 error, 2 bad input or the gate said wait.
"""
from __future__ import annotations

import json
import os
import sys

from . import desktop_pretend as dp
from . import desktop_spec as ds


def options(*, as_json: bool = False, out=None) -> int:
    out = out or sys.stdout
    data = {
        "platforms": list(ds.DESKTOP_PLATFORMS),
        "environments": {k: {"label": v[0], "session": v[1]} for k, v in ds.ENVIRONMENTS.items()},
        "login_manager": ds.LOGIN_MANAGER_NOTE,
        "sessions": [{"name": s.name, "atom": s.atom, "session": s.session, "kind": s.kind,
                      "label": s.label} for s in ds.SESSION_CATALOG],
        "always_on_sessions": list(ds.ALWAYS_ON_SESSIONS),
        "video_cards": {t: ds.VIDEO_CARD_LABELS.get(t, t) for t in ds.VIDEO_CARD_TOKENS},
        "x86_gpu_driver_cards": dict(ds.X86_GPU_VIDEO_CARDS),
        "arm_fixed_video_cards": dict(ds.ARM_FIXED_VIDEO_CARDS),
        "apps": ds.app_catalog(),
        "python_targets": list(ds.PYTHON_TARGET_CHOICES),
        "governed_remote": ds.GOVERNED_REMOTE,
        "rules": [
            "picom composites for an X11 window manager without its own compositor "
            "(LXDE/openbox or i3); not with Plasma alone",
            "a Wayland compositor (sway, wayfire, labwc) adds USE=wayland and needs a Mesa "
            "video card; not with the proprietary NVIDIA driver yet",
            "the default session must be one the image installs",
            "extra local accounts are not administrators unless marked :admin; each must "
            "change its password at first login",
            "a governed (SSO + KEYS) mesh desktop keeps only the hugmesh-discover Flatpak remote",
            "an app delivery with *_arches is refused on an image of another arch (it does "
            "not exist there: a binary package, or a Flathub app built for x86_64 only)",
            "Python extra targets only widen the stage3 seed's set",
            "overlay lines: no wildcards, no video_cards_*/python_* flags, only the image's "
            "testing keyword, never a mask or licence change",
        ],
    }
    if as_json:
        print(json.dumps(data, indent=2), file=out)
        return 0
    print("Desktop step options", file=out)
    print("  environments: " + ", ".join(f"{k} ({v['label']})" for k, v in data["environments"].items()), file=out)
    print("  " + ds.LOGIN_MANAGER_NOTE, file=out)
    print("  sessions: " + ", ".join(f"{s['name']} [{s['kind']}]" for s in data["sessions"]), file=out)
    print("  video cards (x86): " + " ".join(ds.VIDEO_CARD_TOKENS), file=out)
    print("  apps: " + ", ".join(
        f"{a['id']} ({'/'.join(x for x, k in (('native', 'atom'), ('flatpak', 'flatpak')) if a.get(k))})"
        for a in data["apps"]), file=out)
    for a in data["apps"]:
        for how, key in (("native", "atom"), ("flatpak", "flatpak")):
            if a.get(key) and a.get(f"{how}_arches"):
                print(f"    {a['id']} {how}: {'/'.join(a[f'{how}_arches'])} only "
                      f"({a.get(f'{how}_why', '')})", file=out)
    print("  python targets: " + " ".join(ds.PYTHON_TARGET_CHOICES), file=out)
    print("  rules:", file=out)
    for r in data["rules"]:
        print(f"    - {r}", file=out)
    return 0


def _image_cfg(path: str, image: int | None):
    """(config to run, how to save it back) for a flat config or a worklist envelope."""
    from .worklist import load_any
    base, wl = load_any(path)
    if wl is None:
        return base, (lambda: base.save(path)), base
    entries = wl.materialize()
    idx = image
    if idx is None:
        desk = [i for i, (_, c) in enumerate(entries) if ds.applies(c)]
        if len(desk) != 1:
            raise ValueError("this worklist has %d desktop images; pick one with --image N"
                             % len(desk))
        idx = desk[0]
    if not 0 <= idx < len(entries):
        raise ValueError(f"--image {idx}: the worklist has {len(entries)} image(s)")
    entry, cfg = entries[idx]

    def save():
        entry.desktop_spec = ds.spec_of(cfg).to_dict()
        wl.save(path)
    return cfg, save, cfg


def pretend(path: str, *, generator_dir: str, image: int | None = None, as_json: bool = False,
            apply_fixes: bool = False, backend: str | None = None, driver=None,
            out=None, err=None) -> int:
    out, err = out or sys.stdout, err or sys.stderr
    try:
        cfg, save, view = _image_cfg(path, image)
    except (ValueError, OSError) as exc:
        print(f"error: {exc}", file=err)
        return 2
    why = dp.supported(cfg)
    if why:
        print(f"error: {why}", file=err)
        return 2
    bad = ds.grammar_errors(cfg)
    if bad:
        print(f"error: {bad[0]}", file=err)
        return 2
    out_dir = cfg.output_dir or os.path.join(generator_dir, "out")
    if driver is None:
        gate = dp.gate(out_dir)
        if gate:
            print(f"waiting is not done here: {gate}", file=err)
            return 2
        from .build_driver import BuildDriver
        driver = BuildDriver(generator_dir, workdir=out_dir)
    res = dp.run(cfg, driver, out_dir=out_dir, backend=backend,
                 on_line=None if as_json else (lambda s: print(s, file=err)))
    dp.record(view, res)
    applied: list = []
    if apply_fixes and res.status == "needs":
        applied = ds.apply_changes(view, res.applicable_needs(), source="autounmask",
                                   pretend_run=res.run_id)
    save()
    if as_json:
        d = res.to_dict()
        d["applied"] = [f"{c.kind} {c.line}" for c in applied]
        print(json.dumps(d, indent=2), file=out)
    else:
        print(f"emerge --pretend: {res.status}" + (f" — {res.reason}" if res.status == "error" else ""),
              file=out)
        for k, line in res.needs:
            print(f"  needs: {k} {line}", file=out)
        for c in applied:
            print(f"  applied to {path}: {c.kind} {c.line}", file=out)
        if res.status == "needs" and not applied:
            print("  (run again with --apply-portage-fixes to record portage's suggestion)", file=out)
        print(f"  log: {res.log_path}", file=out)
        print("  " + dp.HONESTY_NOTE, file=out)
    return {"clean": 0, "needs": 3}.get(res.status, 1)
