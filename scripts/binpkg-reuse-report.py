#!/usr/bin/env python3
"""binpkg-reuse-report.py -- record the compile-once speedup from TWO build logs.

WHY THIS EXISTS
    docs/SHARED-BINPKG.md ships the binpkg-pool mechanism and the fingerprint guard
    but says, in "Honest limits", that the compile-once speedup is UNPROVEN: nothing
    has ever compared a build that filled a pool with a build that reused it. This is
    the instrument for that comparison. It reads two ordinary builder logs (a COLD run
    that started from an empty pool, a WARM run of the same board and role afterwards),
    counts what portage compiled versus merged from the pool in each, and reports the
    reuse rate and, when wall-clock seconds are supplied, the speedup.

    The protocol that produces the two logs is docs/BINPKG-MEASUREMENT-PLAN.md. This
    script only measures; it never touches a pool, a build tree or the network.

WHAT IT COUNTS (portage's own markers, the same lines the Studio parser reads)
    ">>> Emerging (N of M) cat/pkg-ver::repo [for|to <root>]"          compiled
    ">>> Emerging binary (N of M) cat/pkg-ver::repo [for|to <root>]"   from the pool
    "==> Emerge group: <g>"                                            group banner
    "==> Emerge plan: <g> total=M binary=B ebuild=E"                   the pretend plan
    A package is keyed (group, atom, root-tail): the same atom merged "to /" (a host
    tool) and "for /sysroot/" (the target) is two merges, and a repeated line (a
    --resume re-announcing a package) is one.

WHAT IT REFUSES TO CALL A MEASUREMENT (exit 2, report still printed)
    * a log with no Emerging line at all (wrong file, or a build that never reached
      portage);
    * a "cold" log that was not cold: more than --cold-max-binary-pct (default 10) of
      its merges came from a pool, or the fingerprint guard adopted an UNSTAMPED
      non-empty pool, so something was already in it;
    * a fingerprint-guard refusal ("binpkg pool ABI MISMATCH") in either log;
    * a ">>> Failed to emerge" in either log (a partial run proves nothing);
    * a warm run that compiled nothing AND merged nothing from the pool.

WALL CLOCK
    Builder logs carry no per-line timestamps (and the build tools that do print them
    would mislead an auto-detector), so wall time is SUPPLIED: --cold-wall / --warm-wall
    take seconds, h:mm:ss, 1h2m3s, or @FILE holding one of those. It is whole-run wall
    time (stage3, kernel, image packing included), so the speedup it yields is a
    lower bound on the emerge-only speedup. The compile COUNTS are exact and need no
    clock; the speedup is reported as "unknown" when either wall is absent.

A LOG MAY HOLD SEVERAL BUILDS
    The session-shared build.log appends one build after another, each opened by a
    "==== <name> (<subdir>) start <UTC stamp> ..." header. --cold-segment /
    --warm-segment pick one (1-based, or "last", the default); --list-segments prints
    them. A file with no such header is one segment.

EXIT STATUS
    0  measurement valid, and every requested gate passed (or none requested)
    1  measurement valid, a requested gate (--min-reuse, --min-compile-reduction,
       --min-speedup) was not met
    2  the measurement is invalid or the input is unusable (see above), or a usage error
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from collections import OrderedDict

ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
SEGMENT_RE = re.compile(r"^={4}\s+.*\bstart\s+\d{8}T\d{6}Z\b")
GROUP_RE = re.compile(r"^==>\s*Emerge group:\s*(\S+)\s*$")
PLAN_TOTAL_RE = re.compile(
    r"^==>\s*Emerge plan:\s*(\S+)\s+total=(\d+)(?:\s+binary=(\d+)\s+ebuild=(\d+))?\s*$")
# The root tail (" for /out/x/sysroot/", " to /") is kept as part of the key; the
# atom is everything up to "::repo". Mirrors studio/.../emerge_packages.py _COUNTER_RE.
EMERGING_RE = re.compile(
    r"^>>>\s+Emerging(\s+binary)?\s+\((\d+) of (\d+)\)\s+(\S+?)(?:::\S+)?"
    r"(?:\s+(?:for|to)\s+(\S+))?\s*$")
FAILED_RE = re.compile(r"^>>>\s+Failed to emerge\b")
MISMATCH_RE = re.compile(r"binpkg pool ABI MISMATCH")
UNSTAMPED_RE = re.compile(r"adopting an UNSTAMPED binpkg pool")
MIGRATE_RE = re.compile(r"MIGRATING binpkg pool stamp")

NO_GROUP = "(before-first-group)"


def clean(line: str) -> str:
    return ANSI_RE.sub("", line.replace("\r", "")).rstrip("\n").strip()


def split_segments(lines):
    """Return [(header_or_None, [lines])]. No header at all -> one segment."""
    segs, cur_head, cur = [], None, []
    for raw in lines:
        if SEGMENT_RE.match(clean(raw)):
            if cur_head is not None or cur:
                segs.append((cur_head, cur))
            cur_head, cur = clean(raw), []
        else:
            cur.append(raw)
    segs.append((cur_head, cur))
    # Whatever precedes the first header is not a build: drop it so segment numbers
    # count builds (a file with no header at all stays one segment).
    if len(segs) > 1 and segs[0][0] is None:
        segs = segs[1:]
    return segs


def parse_wall(text):
    """seconds | h:mm:ss | m:ss (minutes may exceed 59) | 1h2m3s | @file -> float seconds, or raise ValueError."""
    t = str(text).strip()
    if t.startswith("@"):
        with open(t[1:], encoding="utf-8") as fh:
            t = fh.read().strip()
    if re.fullmatch(r"\d+(\.\d+)?", t):
        return float(t)
    m = re.fullmatch(r"(\d+):(\d{2}):(\d{2})", t)          # h:mm:ss
    if m:
        h, mi, s = (int(g) for g in m.groups())
        return float(h * 3600 + mi * 60 + s)
    m = re.fullmatch(r"(\d+):(\d{2})", t)                   # m:ss (minutes may exceed 59)
    if m:
        return float(int(m.group(1)) * 60 + int(m.group(2)))
    m = re.fullmatch(r"(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?", t)
    if m and any(m.groups()):
        h, mi, s = (int(g or 0) for g in m.groups())
        return float(h * 3600 + mi * 60 + s)
    raise ValueError("cannot read a duration from %r" % text)


class Run:
    def __init__(self, label, path, header):
        self.label, self.path, self.header = label, path, header
        self.groups = OrderedDict()      # group -> {"compiled": set, "binary": set}
        self.plans = {}                  # group -> (total, binary|None, ebuild|None), last wins
        self.failed = 0
        self.mismatch = 0
        self.unstamped = 0
        self.migrated = 0
        self.wall = None

    def _g(self, name):
        return self.groups.setdefault(name, {"compiled": set(), "binary": set()})

    def feed(self, lines):
        group = NO_GROUP
        for raw in lines:
            ln = clean(raw)
            if not ln:
                continue
            m = GROUP_RE.match(ln)
            if m:
                group = m.group(1)
                self._g(group)
                continue
            m = PLAN_TOTAL_RE.match(ln)
            if m:
                self.plans[m.group(1)] = (
                    int(m.group(2)),
                    int(m.group(3)) if m.group(3) is not None else None,
                    int(m.group(4)) if m.group(4) is not None else None)
                continue
            m = EMERGING_RE.match(ln)
            if m:
                kind = "binary" if m.group(1) else "compiled"
                self._g(group)[kind].add((m.group(4), m.group(5) or ""))
                continue
            if FAILED_RE.match(ln):
                self.failed += 1
            if MISMATCH_RE.search(ln):
                self.mismatch += 1
            if UNSTAMPED_RE.search(ln):
                self.unstamped += 1
            if MIGRATE_RE.search(ln):
                self.migrated += 1

    # -- derived numbers -------------------------------------------------------------
    def count(self, kind, group=None):
        gs = [group] if group else list(self.groups)
        return sum(len(self.groups[g][kind]) for g in gs if g in self.groups)

    @property
    def compiled(self):
        return self.count("compiled")

    @property
    def binary(self):
        return self.count("binary")

    @property
    def merges(self):
        return self.compiled + self.binary

    def atoms(self, kind):
        """{(group, atom, tail)} for a kind, across groups."""
        return {(g, a, t) for g, d in self.groups.items() for (a, t) in d[kind]}


def pct(num, den):
    return None if not den else round(100.0 * num / den, 1)


def fmt_pct(v):
    return "n/a" if v is None else "%.1f%%" % v


def fmt_dur(s):
    if s is None:
        return "unknown"
    s = int(round(s))
    return "%dh%02dm%02ds" % (s // 3600, (s % 3600) // 60, s % 60)


def load(path, label, segment):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            lines = fh.readlines()
    except OSError as e:
        raise SystemExit("binpkg-reuse-report: cannot read %s log %s: %s" % (label, path, e))
    segs = split_segments(lines)
    if segment == "last":
        idx = len(segs)
    else:
        try:
            idx = int(segment)
        except ValueError:
            raise SystemExit("binpkg-reuse-report: --%s-segment must be a number or 'last'" % label)
        if not 1 <= idx <= len(segs):
            raise SystemExit("binpkg-reuse-report: %s log has %d segment(s); asked for %d"
                             % (label, len(segs), idx))
    head, body = segs[idx - 1]
    run = Run(label, path, head)
    run.feed(body)
    run.segment_index, run.segment_count = idx, len(segs)
    return run


def analyse(cold, warm, cold_max_binary_pct):
    problems, notes = [], []

    for r in (cold, warm):
        if r.merges == 0:
            problems.append("%s log has no '>>> Emerging' line: wrong file, wrong segment, or "
                            "a build that never reached portage" % r.label)
        if r.failed:
            problems.append("%s log contains %d '>>> Failed to emerge' line(s): a partial run "
                            "proves nothing" % (r.label, r.failed))
        if r.mismatch:
            problems.append("%s log contains a fingerprint-guard refusal ('binpkg pool ABI "
                            "MISMATCH'): the pool was refused, not reused" % r.label)
        if r.migrated:
            notes.append("%s log migrated a pool stamp (pre-profile keying); expected once per "
                         "pool, not a problem" % r.label)

    cold_bin_pct = pct(cold.binary, cold.merges)
    if cold.merges and cold_bin_pct is not None and cold_bin_pct > cold_max_binary_pct:
        problems.append("cold run is not cold: %s of its merges came from a pool (limit %s%%); "
                        "start it from an empty pool" % (fmt_pct(cold_bin_pct), cold_max_binary_pct))
    if cold.unstamped:
        problems.append("cold run adopted an UNSTAMPED non-empty pool (guard warning present): "
                        "the pool was not empty at the start")
    if warm.merges == 0 and not any("warm log has no" in p for p in problems):
        problems.append("warm log merged nothing")

    cold_compiled = cold.atoms("compiled")
    warm_compiled = warm.atoms("compiled")
    warm_binary = warm.atoms("binary")
    common_hit = cold_compiled & warm_binary
    common_miss = cold_compiled & warm_compiled
    common_absent = cold_compiled - warm_binary - warm_compiled
    new_in_warm = warm_compiled - cold_compiled - cold.atoms("binary")
    common_den = len(common_hit) + len(common_miss)

    cold_groups, warm_groups = set(cold.groups), set(warm.groups)
    if cold.merges and warm.merges and cold_groups != warm_groups:
        notes.append("emerge groups differ (cold only: %s; warm only: %s): not the same "
                     "board+role, or one run stopped early"
                     % (sorted(cold_groups - warm_groups) or "-",
                        sorted(warm_groups - cold_groups) or "-"))
    for g in sorted(warm.plans):
        tot, b, _e = warm.plans[g]
        if b is not None and g in warm.groups and b != warm.count("binary", g):
            notes.append("warm plan said %d binary for group %s but the log shows %d binary "
                         "merges (resume, or the plan drifted from the merge)"
                         % (b, g, warm.count("binary", g)))
    if cold.compiled and warm.compiled and cold.merges and warm.merges \
            and cold.merges != warm.merges:
        notes.append("total merges differ (cold %d, warm %d): reuse rate is still valid, "
                     "package sets are not identical" % (cold.merges, warm.merges))

    speedup = None
    if cold.wall and warm.wall:
        speedup = round(cold.wall / warm.wall, 2)
    reduction = pct(cold.compiled - warm.compiled, cold.compiled) if cold.compiled else None

    # Host tools merged "to /" (the builder's own root) versus the target image: the
    # arm host-bdep pool (#72 section 4) is judged on the first, the per-board pool on
    # the second, and one number for both would hide which leg missed.
    def split(run):
        d = {"host": {"compiled": 0, "binary": 0}, "target": {"compiled": 0, "binary": 0}}
        for kind in ("compiled", "binary"):
            for _g, _a, tail in run.atoms(kind):
                d["host" if tail == "/" else "target"][kind] += 1
        return d
    cs_, ws_ = split(cold), split(warm)
    by_root = {k: {"cold_compiled": cs_[k]["compiled"], "cold_binary": cs_[k]["binary"],
                   "warm_compiled": ws_[k]["compiled"], "warm_binary": ws_[k]["binary"],
                   "warm_reuse_pct": pct(ws_[k]["binary"], ws_[k]["binary"] + ws_[k]["compiled"])}
               for k in ("host", "target")}

    per_group = OrderedDict()
    for g in list(cold.groups) + [g for g in warm.groups if g not in cold.groups]:
        per_group[g] = {
            "cold_compiled": cold.count("compiled", g), "cold_binary": cold.count("binary", g),
            "warm_compiled": warm.count("compiled", g), "warm_binary": warm.count("binary", g),
            "warm_reuse_pct": pct(warm.count("binary", g),
                                  warm.count("binary", g) + warm.count("compiled", g)),
        }

    return {
        "valid": not problems,
        "problems": problems,
        "notes": notes,
        "cold": {"compiled": cold.compiled, "binary": cold.binary, "wall_s": cold.wall},
        "warm": {"compiled": warm.compiled, "binary": warm.binary, "wall_s": warm.wall},
        "warm_reuse_pct": pct(warm.binary, warm.merges),
        "compile_reduction_pct": reduction,
        "compiles_avoided": cold.compiled - warm.compiled,
        "wall_speedup": speedup,
        "wall_saved_s": (cold.wall - warm.wall) if cold.wall and warm.wall else None,
        "common_set": {
            "cold_compiled_atoms": len(cold_compiled),
            "reused_in_warm": len(common_hit),
            "recompiled_in_warm": len(common_miss),
            "absent_from_warm": len(common_absent),
            "hit_rate_pct": pct(len(common_hit), common_den),
        },
        "recompiled_despite_pool": sorted("%s [%s]%s" % (a, g, (" " + t) if t else "")
                                          for g, a, t in common_miss),
        "new_compiles_in_warm": sorted("%s [%s]%s" % (a, g, (" " + t) if t else "")
                                       for g, a, t in new_in_warm),
        "per_group": per_group,
        "by_root": by_root,
    }


def render(res, cold, warm):
    out = []
    w = out.append
    w("binpkg reuse report")
    for r in (cold, warm):
        seg = ("segment %d of %d" % (r.segment_index, r.segment_count)) \
            if r.segment_count > 1 else "whole file"
        w("  %-4s %s (%s)" % (r.label, r.path, seg))
        if r.header:
            w("       %s" % r.header)
    w("")
    w("  %-24s %8s %8s" % ("", "cold", "warm"))
    w("  %-24s %8d %8d" % ("compiled from source", res["cold"]["compiled"], res["warm"]["compiled"]))
    w("  %-24s %8d %8d" % ("merged from the pool", res["cold"]["binary"], res["warm"]["binary"]))
    w("  %-24s %8s %8s" % ("whole-run wall", fmt_dur(res["cold"]["wall_s"]), fmt_dur(res["warm"]["wall_s"])))
    w("")
    w("  warm reuse rate            %s of the warm run's merges came from the pool"
      % fmt_pct(res["warm_reuse_pct"]))
    w("  compile reduction          %s (%d fewer source compiles)"
      % (fmt_pct(res["compile_reduction_pct"]), res["compiles_avoided"])
      if res["compile_reduction_pct"] is not None else
      "  compile reduction          n/a (cold compiled nothing)")
    cs = res["common_set"]
    w("  hit rate on cold's set     %s (%d of the %d atoms cold compiled were reused; "
      "%d recompiled; %d not merged in warm)"
      % (fmt_pct(cs["hit_rate_pct"]), cs["reused_in_warm"], cs["cold_compiled_atoms"],
         cs["recompiled_in_warm"], cs["absent_from_warm"]))
    if res["wall_speedup"] is None:
        w("  wall speedup               unknown (supply --cold-wall and --warm-wall)")
    else:
        w("  wall speedup               %.2fx whole-run (%s saved); a lower bound on the "
          "emerge-only speedup" % (res["wall_speedup"], fmt_dur(res["wall_saved_s"])))
    w("")
    w("  per group (compiled/binary):")
    for g, d in res["per_group"].items():
        w("    %-14s cold %4d/%-4d warm %4d/%-4d warm reuse %s"
          % (g, d["cold_compiled"], d["cold_binary"], d["warm_compiled"], d["warm_binary"],
             fmt_pct(d["warm_reuse_pct"])))
    w("")
    w("  by root (compiled/binary; host = merged 'to /', target = into the image):")
    for k, d in res["by_root"].items():
        w("    %-14s cold %4d/%-4d warm %4d/%-4d warm reuse %s"
          % (k, d["cold_compiled"], d["cold_binary"], d["warm_compiled"], d["warm_binary"],
             fmt_pct(d["warm_reuse_pct"])))
    for title, key in (("recompiled in warm although cold compiled them (pool MISS)",
                        "recompiled_despite_pool"),
                       ("compiled in warm, never seen in cold (new work)", "new_compiles_in_warm")):
        items = res[key]
        if items:
            w("")
            w("  %s: %d" % (title, len(items)))
            for it in items[:25]:
                w("    " + it)
            if len(items) > 25:
                w("    ... and %d more (use --json)" % (len(items) - 25))
    if res["notes"]:
        w("")
        for n in res["notes"]:
            w("  NOTE: " + n)
    w("")
    if res["valid"]:
        w("  MEASUREMENT VALID")
    else:
        w("  MEASUREMENT INVALID:")
        for p in res["problems"]:
            w("    - " + p)
    return "\n".join(out)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--cold", required=True, help="build log of the run that started from an empty pool")
    ap.add_argument("--warm", required=True, help="build log of the later run of the same board+role")
    ap.add_argument("--cold-wall", help="cold run wall time: seconds, h:mm:ss, 1h2m3s or @FILE")
    ap.add_argument("--warm-wall", help="warm run wall time, same spellings")
    ap.add_argument("--cold-segment", default="last", help="1-based segment of --cold, or 'last'")
    ap.add_argument("--warm-segment", default="last", help="1-based segment of --warm, or 'last'")
    ap.add_argument("--list-segments", action="store_true", help="list the builds in each log and exit")
    ap.add_argument("--cold-max-binary-pct", type=float, default=10.0,
                    help="a cold run with more than this %% of pool merges is not cold (default 10)")
    ap.add_argument("--min-reuse", type=float, help="gate: warm reuse rate must be >= this %%")
    ap.add_argument("--min-compile-reduction", type=float, help="gate: compile reduction must be >= this %%")
    ap.add_argument("--min-speedup", type=float, help="gate: whole-run wall speedup must be >= this factor")
    ap.add_argument("--json", action="store_true", help="print the result as JSON instead of text")
    a = ap.parse_args(argv)

    if a.list_segments:
        for label, path in (("cold", a.cold), ("warm", a.warm)):
            try:
                with open(path, encoding="utf-8", errors="replace") as fh:
                    segs = split_segments(fh.readlines())
            except OSError as e:
                print("binpkg-reuse-report: cannot read %s: %s" % (path, e), file=sys.stderr)
                return 2
            for i, (head, body) in enumerate(segs, 1):
                print("%s %d: %s" % (label, i, head or "(no header; whole file)"))
        return 0

    cold = load(a.cold, "cold", a.cold_segment)
    warm = load(a.warm, "warm", a.warm_segment)
    for run, val in ((cold, a.cold_wall), (warm, a.warm_wall)):
        if val is not None:
            try:
                run.wall = parse_wall(val)
            except (ValueError, OSError) as e:
                print("binpkg-reuse-report: --%s-wall: %s" % (run.label, e), file=sys.stderr)
                return 2
            if run.wall <= 0:
                print("binpkg-reuse-report: --%s-wall must be positive" % run.label, file=sys.stderr)
                return 2

    res = analyse(cold, warm, a.cold_max_binary_pct)

    gates = []
    for name, want, got in (("--min-reuse", a.min_reuse, res["warm_reuse_pct"]),
                            ("--min-compile-reduction", a.min_compile_reduction,
                             res["compile_reduction_pct"]),
                            ("--min-speedup", a.min_speedup, res["wall_speedup"])):
        if want is None:
            continue
        # An unknown figure never passes a gate: absence of evidence is a failure here.
        passed = got is not None and got >= want
        gates.append({"gate": name, "want": want, "got": got, "passed": passed})
    res["gates"] = gates

    if a.json:
        print(json.dumps(res, indent=2, default=list))
    else:
        print(render(res, cold, warm))
        for g in gates:
            print("  GATE %-24s want >= %-6s got %-8s %s"
                  % (g["gate"], g["want"], "n/a" if g["got"] is None else g["got"],
                     "PASS" if g["passed"] else "FAIL"))
    if not res["valid"]:
        return 2
    return 0 if all(g["passed"] for g in gates) else 1


if __name__ == "__main__":
    sys.exit(main())
