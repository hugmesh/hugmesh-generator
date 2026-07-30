#!/usr/bin/env python3
"""Enumerate EVERY USE-flag display state portage can render, by calling
portage's own _emerge.resolver.output_helpers._create_use_string.

This is a pure formatting function: no depgraph, no ebuild, no merge, no network.
Output is the ground truth for the badge design.
"""
import json
import portage
import portage.output as po
from _emerge.resolver.output_helpers import _create_use_string


class Conf:
    print_use_string = True
    alphabetical = False
    all_flags = True          # == emerge --verbose (verbosity 3); False == default verbosity 2


def render(conf, **kw):
    return _create_use_string(
        conf, "USE",
        kw["cur_iuse"], kw["iuse_forced"], kw["cur_use"],
        kw["old_iuse"], kw["old_use"], kw["is_new"], kw.get("reinst"),
    ).strip()


# Each case is (label, kwargs). Flag name is always "f" so only the decoration varies.
CASES = [
    # ---- package is NEW (no previous install): is_new=True ----
    ("new-pkg / enabled",
     dict(cur_iuse=["f"], cur_use=["f"], old_iuse=[], old_use=[], is_new=True, iuse_forced=set())),
    ("new-pkg / disabled",
     dict(cur_iuse=["f"], cur_use=[], old_iuse=[], old_use=[], is_new=True, iuse_forced=set())),
    ("new-pkg / enabled + profile-forced",
     dict(cur_iuse=["f"], cur_use=["f"], old_iuse=[], old_use=[], is_new=True, iuse_forced={"f"})),
    ("new-pkg / disabled + profile-masked",
     dict(cur_iuse=["f"], cur_use=[], old_iuse=[], old_use=[], is_new=True, iuse_forced={"f"})),

    # ---- package already installed: is_new=False ----
    ("reinstall / enabled, unchanged",
     dict(cur_iuse=["f"], cur_use=["f"], old_iuse=["f"], old_use=["f"], is_new=False, iuse_forced=set())),
    ("reinstall / disabled, unchanged",
     dict(cur_iuse=["f"], cur_use=[], old_iuse=["f"], old_use=[], is_new=False, iuse_forced=set())),
    ("reinstall / turning ON (was off last merge)",
     dict(cur_iuse=["f"], cur_use=["f"], old_iuse=["f"], old_use=[], is_new=False, iuse_forced=set())),
    ("reinstall / turning OFF (was on last merge)",
     dict(cur_iuse=["f"], cur_use=[], old_iuse=["f"], old_use=["f"], is_new=False, iuse_forced=set())),
    ("reinstall / newly in IUSE, enabled",
     dict(cur_iuse=["f"], cur_use=["f"], old_iuse=[], old_use=[], is_new=False, iuse_forced=set())),
    ("reinstall / newly in IUSE, disabled",
     dict(cur_iuse=["f"], cur_use=[], old_iuse=[], old_use=[], is_new=False, iuse_forced=set())),
    ("reinstall / newly in IUSE, disabled + forced/masked",
     dict(cur_iuse=["f"], cur_use=[], old_iuse=[], old_use=[], is_new=False, iuse_forced={"f"})),
    # The iuse_forced paren wraps whatever the enabled/disabled branch produced,
    # INCLUDING its %/* suffixes — so "(f%*)", "(f*)" and "(-f*)" are all
    # reachable. They were missing here, which is why nothing downstream covered
    # them; "(f%*)" in particular has a '%' that means NEWLY ADDED, not removed.
    ("reinstall / newly in IUSE, ENABLED + forced",
     dict(cur_iuse=["f"], cur_use=["f"], old_iuse=[], old_use=[], is_new=False, iuse_forced={"f"})),
    ("reinstall / turning ON + forced",
     dict(cur_iuse=["f"], cur_use=["f"], old_iuse=["f"], old_use=[], is_new=False, iuse_forced={"f"})),
    ("reinstall / turning OFF + masked",
     dict(cur_iuse=["f"], cur_use=[], old_iuse=["f"], old_use=["f"], is_new=False, iuse_forced={"f"})),
    ("reinstall / REMOVED from IUSE (was off)",
     dict(cur_iuse=[], cur_use=[], old_iuse=["f"], old_use=[], is_new=False, iuse_forced=set())),
    ("reinstall / REMOVED from IUSE (was on)",
     dict(cur_iuse=[], cur_use=[], old_iuse=["f"], old_use=["f"], is_new=False, iuse_forced=set())),
    ("reinstall / enabled unchanged + forced",
     dict(cur_iuse=["f"], cur_use=["f"], old_iuse=["f"], old_use=["f"], is_new=False, iuse_forced={"f"})),
    ("reinstall / disabled unchanged + masked",
     dict(cur_iuse=["f"], cur_use=[], old_iuse=["f"], old_use=[], is_new=False, iuse_forced={"f"})),
]

out = {"portage_version": portage.VERSION, "cases": []}
for all_flags in (True, False):
    conf = Conf()
    conf.all_flags = all_flags
    for label, kw in CASES:
        po.havecolor = 1
        coloured = render(conf, **{k: (list(v) if isinstance(v, list) else v) for k, v in kw.items()})
        po.havecolor = 0
        plain = render(conf, **{k: (list(v) if isinstance(v, list) else v) for k, v in kw.items()})
        out["cases"].append({
            "verbosity": "--verbose (all_flags=True)" if all_flags else "default (all_flags=False)",
            "state": label,
            "plain": plain,
            "ansi": coloured.encode("unicode_escape").decode(),
        })
po.havecolor = 0
print(json.dumps(out, indent=2))
