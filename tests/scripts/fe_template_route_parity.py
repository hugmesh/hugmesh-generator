#!/usr/bin/env python3
"""fe_template_route_parity.py -- compare a RENDERED per-brand fe-gateway route
table with the primary table (hugmesh-generator#559).

Usage:
  fe_template_route_parity.py --primary specs/cluster/apps/20-gateway-fe.yaml \
      --exclusions tests/scripts/fe-template-route-exclusions.tsv \
      --brand example --domain example.test \
      RENDERED_APP.yaml [RENDERED_APP.yaml ...]

Every RENDERED_APP is one engine's rendering of templates/apps/20-gateway-fe.yaml.hbs
for the same brand profile. Each must:

  * parse (the Application, then its helm `values` block) and carry a routes list;
  * hold NO unrendered `{{` anywhere in its routes;
  * equal the primary table route by route, IN ORDER, after the primary is
    normalized to the brand (its cluster domain -> --domain, its `<prefix>-`
    service/namespace prefix -> `<brand>-`), minus the excluded route ids. Every
    key of every route is compared (id, path, header, host, uri, filters, vanity,
    and any key added later), so a uri or filter drift is caught too, not only a
    missing id;
  * have no shadowed route: a plain path route (no header/host predicate) whose
    `/x/**` pattern covers a LATER route's path makes that later route
    unreachable -- the carve-out-below-its-catch-all defect;
  * and every rendered table must equal every other (engine agreement on the
    routes, independent of the byte-level scripts/parity-gate.sh).

The exclusion list is TSV `<primary route id><TAB><reason>`, `#` comments. An
exclusion is checked, not trusted: its id must exist in the primary table, must
be ABSENT from every rendered table (an excluded route that is still rendered is
a stale entry), and must carry a non-empty reason.

Exit 0 = parity holds; 1 = parity broken (each problem printed); 2 = could not
evaluate (missing/unparseable input) -- never a pass.
"""
import argparse
import sys

try:
    import yaml
except ImportError:  # pragma: no cover
    print("FATAL: PyYAML missing (pip install pyyaml)", file=sys.stderr)
    sys.exit(2)

PRIMARY_DOMAIN = "hugmesh.net"
PRIMARY_PREFIX = "hugmesh-"


def die(msg):
    print(f"FATAL: {msg}", file=sys.stderr)
    sys.exit(2)


def load_routes(path):
    try:
        with open(path, encoding="utf-8") as fh:
            app = yaml.safe_load(fh)
    except (OSError, yaml.YAMLError) as e:
        die(f"cannot read/parse {path}: {e}")
    try:
        values = app["spec"]["source"]["helm"]["values"]
    except (KeyError, TypeError):
        die(f"{path}: no spec.source.helm.values block")
    try:
        parsed = yaml.safe_load(values)
    except yaml.YAMLError as e:
        die(f"{path}: helm values do not parse: {e}")
    routes = (parsed or {}).get("routes")
    if not isinstance(routes, list) or not routes:
        die(f"{path}: helm values carry no routes list (vacuous)")
    for i, r in enumerate(routes):
        if not isinstance(r, dict) or not r.get("id"):
            die(f"{path}: route #{i} has no id")
    return routes


def normalize(obj, brand, domain):
    if isinstance(obj, str):
        return obj.replace(PRIMARY_DOMAIN, domain).replace(PRIMARY_PREFIX, brand + "-")
    if isinstance(obj, list):
        return [normalize(x, brand, domain) for x in obj]
    if isinstance(obj, dict):
        return {k: normalize(v, brand, domain) for k, v in obj.items()}
    return obj


def has_unrendered(obj):
    if isinstance(obj, str):
        return "{{" in obj or "}}" in obj
    if isinstance(obj, list):
        return any(has_unrendered(x) for x in obj)
    if isinstance(obj, dict):
        return any(has_unrendered(v) for v in obj.values())
    return False


def load_exclusions(path):
    out = {}
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except OSError as e:
        die(f"cannot read exclusion list {path}: {e}")
    for n, line in enumerate(lines, 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        rid, _, reason = line.partition("\t")
        rid = rid.strip()
        out[rid] = (reason.strip(), n)
    return out


def paths_of(route):
    p = route.get("path")
    return [x.strip() for x in str(p).split(",")] if p else []


def covers(pattern, path):
    """True when SCG pattern `pattern` (only the `/x/**` and `/**` shapes are
    treated as subtree catch-alls) matches every request `path` could match."""
    if pattern == "/**":
        return True
    if pattern.endswith("/**"):
        base = pattern[:-3]
        return path == base or path.startswith(base + "/")
    return pattern == path


def shadowed(routes):
    """(earlier_id, later_id, later_path) for every later path a plain earlier
    route already swallows."""
    found = []
    for i, early in enumerate(routes):
        if early.get("header") or early.get("host"):
            continue  # a predicate-guarded route only takes part of the traffic
        for pat in paths_of(early):
            for late in routes[i + 1:]:
                for lp in paths_of(late):
                    if covers(pat, lp):
                        found.append((early["id"], late["id"], lp))
    return found


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--primary", required=True)
    ap.add_argument("--exclusions", required=True)
    ap.add_argument("--brand", required=True)
    ap.add_argument("--domain", required=True)
    ap.add_argument("rendered", nargs="+")
    a = ap.parse_args()

    problems = []
    primary_raw = load_routes(a.primary)
    primary = normalize(primary_raw, a.brand, a.domain)
    excl = load_exclusions(a.exclusions)

    # The primary itself must be shadow-free, or "parity" would copy a defect.
    for e, l, lp in shadowed(primary):
        problems.append(f"PRIMARY table shadows {l} ({lp}) under earlier {e}")

    primary_ids_raw = [r["id"] for r in primary_raw]
    primary_ids = [r["id"] for r in primary]
    norm_excl = {}
    for rid, (reason, n) in excl.items():
        if not reason:
            problems.append(f"exclusion line {n} ({rid}) carries no reason")
        if rid in primary_ids_raw:
            norm_excl[normalize(rid, a.brand, a.domain)] = rid
        elif rid in primary_ids:
            norm_excl[rid] = rid
        else:
            problems.append(f"exclusion line {n} names '{rid}', which is not a route in the primary table")
    expected = [r for r in primary if r["id"] not in norm_excl]

    tables = []
    for path in a.rendered:
        routes = load_routes(path)
        tables.append((path, routes))
        parts = path.replace("\\", "/").split("/")
        tag = "/".join(parts[-4:]) if len(parts) > 4 else path
        if has_unrendered(routes):
            problems.append(f"{tag}: unrendered '{{{{' token left in the routes")
        ids = [r["id"] for r in routes]
        for nid, rid in norm_excl.items():
            if nid in ids:
                problems.append(f"{tag}: excluded route '{rid}' is still rendered (stale exclusion)")
        exp_ids = [r["id"] for r in expected]
        missing = [i for i in exp_ids if i not in ids]
        extra = [i for i in ids if i not in exp_ids and i not in norm_excl]
        for i in missing:
            problems.append(f"{tag}: route '{i}' is in the primary table but MISSING here")
        for i in extra:
            problems.append(f"{tag}: route '{i}' is not in the primary table (unlisted extra)")
        common_exp = [i for i in exp_ids if i in ids]
        common_got = [i for i in ids if i in exp_ids]
        if common_exp != common_got:
            for pos, (x, y) in enumerate(zip(common_exp, common_got)):
                if x != y:
                    problems.append(f"{tag}: ORDER differs from the primary at shared position {pos}: "
                                    f"primary has '{x}', rendered has '{y}'")
                    break
        by_id = {r["id"]: r for r in routes}
        for r in expected:
            got = by_id.get(r["id"])
            if got is None:
                continue
            for k in sorted(set(r) | set(got)):
                if r.get(k) != got.get(k):
                    problems.append(f"{tag}: route '{r['id']}' field '{k}': primary {r.get(k)!r} "
                                    f"!= rendered {got.get(k)!r}")
        for e, l, lp in shadowed(routes):
            problems.append(f"{tag}: route '{l}' ({lp}) is SHADOWED by earlier '{e}' -- "
                            f"a carve-out sits below its catch-all")

    for (p0, t0), (p1, t1) in zip(tables, tables[1:]):
        if t0 != t1:
            problems.append(f"engines disagree: {p0} and {p1} render different route tables")

    if problems:
        for p in problems:
            print(f"  PARITY-FAIL {p}")
        return 1
    print(f"  parity OK: {len(expected)} route(s) match the primary in order "
          f"({len(primary)} primary, {len(norm_excl)} excluded) across {len(tables)} rendering(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
