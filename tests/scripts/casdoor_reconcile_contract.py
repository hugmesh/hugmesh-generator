#!/usr/bin/env python3
"""Static half of tests/scripts/test-casdoor-init-honesty.sh.

Discovers EVERY Casdoor-API reconcile script embedded in specs/cluster (they live
as `.py` values inside ConfigMaps) and holds each to the contract that the first
real cluster run showed was missing. It is discovery-driven on purpose: a sixth
Casdoor Job added next month is covered the day it lands, with no edit here.

Subcommands
  discover <specs/cluster>            list the scripts (name<TAB>kind<TAB>manifest)
  extract  <specs/cluster> <outdir>   write each script + its seed + meta.json
  fixture  <specs/cluster> <workdir> <configmap> <admin-password>
                                      stage one script + the files it opens, and
                                      print SCRIPT=/SECRETS=/SEED= for the shell
  static   <specs/cluster>            the source contract (below)
  conf     <specs/cluster>            the init_data.json wiring contract (below)
  seed     <specs/cluster>            the init_data.json OBJECT-GRAPH contract (below)

THE SOURCE CONTRACT — every discovered script must:
  (1) parse;
  (2) reach Casdoor through exactly ONE helper. `urllib.request.Request`,
      `opener.open` and `urlopen` may appear only inside `call()`. A second
      egress point is a call site that can ignore its response;
  (3) have that helper ENFORCE the response envelope: no path through `call()`
      may hand the parsed response back to a caller unless a comparison of its
      "status" field against "ok" has been passed, and the failing side of that
      comparison must raise or exit. This is checked by ANALYSING the control
      flow of call() (see check_envelope below), never by looking for the word
      "status" in the source: a helper that logs a bad status and carries on
      mentions every one of those words and enforces nothing. Casdoor answers
      denials with HTTP 200 + {"status":"error"} (controllers ResponseError ->
      ServeJSON), so this is the only thing standing between a denied run and a
      green one. The behavioural half re-proves the same property by running the
      real script against a stub that answers 200 + {"status":"error"};
  (3b) re-read after every write. casdoor's wrapActionResponse() answers
      {"status":"ok","data":"Affected"|"Unaffected"} for EVERY write that reached
      the handler — including ones that stored nothing (LIVE-VERIFIED on
      update-group) — so an ok envelope is not evidence of persistence. Every
      /api/{add,update,delete}-<noun> call site must therefore be followed, in
      the same function, by a read of that same <noun>;
  (4) verify the login by reading the session back (/api/get-account). A 200 from
      /api/login is not a session — the live failure ran an entire reconcile
      anonymously behind one;
  (5) contain no `except: pass` — a swallowed error is an unchecked response by
      another name;
  (6) be able to exit non-zero.
An INIT script (the ones that own an admin credential) must additionally:
  (7) apply the admin password through /api/set-password (update-user cannot
      change one), and
  (8) know the casdoor bootstrap default so it can take the account over once and
      prove the default is dead afterwards.

THE WIRING CONTRACT (`conf`) — for each casdoor Deployment:
  (a) the app.conf it mounts must set `initDataFile`, because
      object/init_data.go's InitFromFile() returns immediately when that key is
      empty; without it the mounted seed is inert and NOTHING says so;
  (b) that value must equal the path the Deployment actually mounts the seed at;
  (c) `initDataNewOnly` must be true, or every restart deletes and re-adds every
      declared object, resetting each role's membership to the seed's empty list;
  (d) the init Job must mount the SAME seed ConfigMap at the directory its script
      reads, so its verification pass reads what Casdoor was given.

THE OBJECT-GRAPH CONTRACT (`seed`) — a seed must be able to import ITSELF. The
wiring contract above proves the file is READ; this proves the file is VIABLE.
Reproduced statically from the pinned casbin/casdoor:3.80.0 source:

  (s1) VIABILITY. A user may not be created in an organization that has no
       application. object/init_data.go:81 -> initDefinedUser -> AddUser
       (object/user.go:969), which at :1000-1007 does
           if user.Owner != "built-in" {
               applicationCount, _ := GetOrganizationApplicationCount(
                   organization.Owner, organization.Name, "", "")
               if applicationCount == 0 { return …"The organization: %s should have
                   one application at least"… } }
       and AddUser's error is panicked at init_data.go:368 — the container
       CrashLoopBackOffs, the whole IdP never starts. The organization is resolved
       as getOrganization("admin", user.Owner) (object/organization.go:305-311) and
       the count is
           SELECT count(*) FROM application
           WHERE owner = <org.Owner> AND (organization = <org.Name> OR is_shared)
       (object/application.go:194-197 + ormer_session.go:25-32), so the application
       must be owned by the ORGANIZATION'S owner ("admin"), not by the org.
       NOTE the message interpolates organization.OWNER, so it names "admin" for a
       user in org "hugmesh" — the panic text does not identify the real org.
  (s2) OWNERSHIP. Every declared application whose organization is declared here
       must carry that organization's owner, or it does not count for (s1) and
       cannot be reached as "<owner>/<name>" by the init Job's ensure_seed().
  (s3) ORDERING. InitFromFile() applies kinds in a HARDCODED order
       (object/init_data.go:71-156) — key order in the JSON is irrelevant. A
       reference to an object this same file declares under a LATER kind is
       created against something that does not exist yet: certs (84) and groups
       (114) come AFTER applications (78) and users (81) respectively.
  (s4) PHANTOM MEMBERSHIP. AddRole/AddPermission are bare inserts with no
       referential check (object/role.go:151-158), so a role or permission naming
       a user/role this file never creates is stored happily and grants nothing —
       no error, anywhere, ever. A bootstrap seed must create everything it names.
Every rule is applied to EVERY manifests/casdoor*/init-data-configmap.yaml, and
REQUIRED_SEEDS below stops a rename from turning the sweep vacuous.

PyYAML + the stdlib only: no cluster, no kubectl, no network.
"""
import ast
import json
import os
import pathlib
import re
import sys

import yaml

P = 0
F = 0


def ok(msg):
    global P
    P += 1
    print(f"  PASS {msg}")


def bad(msg):
    global F
    F += 1
    print(f"  FAIL {msg}")


# ── discovery ────────────────────────────────────────────────────────────────
# The two scripts that MUST be found. If discovery silently returned nothing the
# whole gate would pass vacuously, which is the failure mode this repo has been
# burned by before (a skipped code-copy assertion reading as green).
REQUIRED = {
    "casdoor-init-script/reconcile.py",
    "casdoor-games-init-script/reconcile.py",
    # The three derived-role sync Jobs. They are named here, and not left to
    # discovery alone, because they are the Jobs whose write path (update-role on
    # an authorization source) is the one the whole contract exists for: if a
    # rename or a moved ConfigMap dropped one out of discovery, the gate would go
    # green having checked nothing about it.
    "games-admin-sync-script/sync.py",
    "games-services-admin-sync-script/sync.py",
    "games-services-runner-sync-script/sync.py",
}


def discover(cluster):
    """[(configmap-name, script-key, source, manifest-path)] for every embedded
    Casdoor-API script under specs/cluster/manifests/casdoor*/."""
    found = []
    for manifest in sorted(pathlib.Path(cluster, "manifests").glob("casdoor*/*.yaml")):
        try:
            docs = list(yaml.safe_load_all(manifest.read_text()))
        except yaml.YAMLError as e:
            bad(f"{manifest}: not parseable YAML: {e}")
            continue
        for doc in docs:
            if not isinstance(doc, dict) or doc.get("kind") != "ConfigMap":
                continue
            name = (doc.get("metadata") or {}).get("name", "?")
            for key, src in (doc.get("data") or {}).items():
                if key.endswith(".py") and "/api/login" in src:
                    found.append((name, key, src, manifest))
    return found


def is_init(cm_name):
    """An INIT script owns an admin credential; a sync script only reads/writes
    role membership with one."""
    return cm_name.endswith("-init-script")


# ── the source contract ──────────────────────────────────────────────────────
EGRESS = {"Request", "urlopen"}


def _attr_chain(node):
    parts = []
    while isinstance(node, ast.Attribute):
        parts.append(node.attr)
        node = node.value
    if isinstance(node, ast.Name):
        parts.append(node.id)
    return ".".join(reversed(parts))


# ── (3) the envelope check, ANALYSED — not grepped ───────────────────────────
# The question this answers is a control-flow one: "can call() return the parsed
# response to its caller on a path where nobody compared status to 'ok'?" It is
# deliberately not a search for a word. The shape it must reject is the one that
# reads exactly like a check and is not one:
#
#     resp = json.loads(body)
#     if resp.get("status") != "ok":
#         print(f"casdoor: {path} said {resp.get('msg')}")   # mentions everything
#     return resp                                            # ... enforces nothing


def _status_read(node, resp_names, status_names):
    """True when `node` reads the "status" member of the parsed response, either
    directly (resp.get("status") / resp["status"]) or through a name bound to it."""
    if isinstance(node, ast.Name):
        return node.id in status_names
    if isinstance(node, ast.Call):
        f = node.func
        return (isinstance(f, ast.Attribute) and f.attr == "get"
                and isinstance(f.value, ast.Name) and f.value.id in resp_names
                and bool(node.args) and isinstance(node.args[0], ast.Constant)
                and node.args[0].value == "status")
    if isinstance(node, ast.Subscript):
        return (isinstance(node.value, ast.Name) and node.value.id in resp_names
                and isinstance(node.slice, ast.Constant)
                and node.slice.value == "status")
    return False


def _classify(test, resp_names, status_names):
    """'notok' when `test` is true whenever the envelope is NOT ok (a guard whose
    body must terminate), 'ok' when it is true only when the envelope IS ok (a
    gate whose body may proceed), None when it says nothing about the envelope."""
    if isinstance(test, ast.Compare) and len(test.ops) == 1:
        left, right, op = test.left, test.comparators[0], test.ops[0]
        # accept both `resp.get("status") != "ok"` and `"ok" != resp.get("status")`
        if isinstance(right, ast.Constant) and right.value == "ok" and \
                _status_read(left, resp_names, status_names):
            pass
        elif isinstance(left, ast.Constant) and left.value == "ok" and \
                _status_read(right, resp_names, status_names):
            pass
        else:
            return None
        if isinstance(op, ast.NotEq):
            return "notok"
        if isinstance(op, ast.Eq):
            return "ok"
        return None
    if isinstance(test, ast.UnaryOp) and isinstance(test.op, ast.Not):
        return {"ok": "notok", "notok": "ok"}.get(
            _classify(test.operand, resp_names, status_names))
    if isinstance(test, ast.BoolOp):
        kinds = [_classify(v, resp_names, status_names) for v in test.values]
        # `A or status != "ok"` is still true whenever the status is not ok, so it
        # is a sound guard; `A and status != "ok"` is not.
        if isinstance(test.op, ast.Or) and "notok" in kinds:
            return "notok"
        # `status == "ok" and A` is true only when the status is ok, so it is a
        # sound gate; `or` is not.
        if isinstance(test.op, ast.And) and "ok" in kinds:
            return "ok"
    return None


def _terminates(stmts):
    """The statement list cannot fall through: it ends in a raise or an exit."""
    if not stmts:
        return False
    last = stmts[-1]
    if isinstance(last, ast.Raise):
        return True
    if isinstance(last, ast.Expr) and isinstance(last.value, ast.Call):
        if _attr_chain(last.value.func) in ("sys.exit", "exit", "os._exit"):
            return True
    if isinstance(last, ast.If):
        return _terminates(last.body) and _terminates(last.orelse)
    return False


def _mentions(expr, names):
    return any(isinstance(n, ast.Name) and n.id in names for n in ast.walk(expr))


def _delegates_check(fn, argnames, funcs, depth=0):
    """True when calling `fn` with the parsed response raises on a non-ok envelope.
    One level of indirection is allowed so that a script may factor the check into
    its own `_require_ok(resp)` helper — the property is "nothing gets past an
    unchecked envelope", not "the comparison is written inline"."""
    if depth > 2 or fn is None:
        return False
    params = {a.arg for a in fn.args.args} | argnames
    for node in ast.walk(fn):
        if isinstance(node, ast.If) and _classify(node.test, params, set()) == "notok" \
                and _terminates(node.body):
            return True
        if isinstance(node, ast.Expr) and isinstance(node.value, ast.Call) \
                and isinstance(node.value.func, ast.Name):
            callee = funcs.get(node.value.func.id)
            if callee is not None and callee is not fn and \
                    any(_mentions(a, params) for a in node.value.args) and \
                    _delegates_check(callee, set(), funcs, depth + 1):
                return True
    return False


def check_envelope(label, call_fn, funcs=None):
    """Report on the ONE property: call() cannot return an unchecked envelope."""
    funcs = funcs or {}
    resp_names, status_names = set(), set()
    for node in ast.walk(call_fn):
        if not isinstance(node, ast.Assign):
            continue
        targets = [t.id for t in node.targets if isinstance(t, ast.Name)]
        if isinstance(node.value, ast.Call) and \
                _attr_chain(node.value.func) in ("json.loads", "loads"):
            resp_names.update(targets)
    for node in ast.walk(call_fn):               # second pass: status aliases
        if isinstance(node, ast.Assign) and _status_read(node.value, resp_names, set()):
            status_names.update(t.id for t in node.targets if isinstance(t, ast.Name))

    if not resp_names:
        bad(f"{label}: call() never parses the response body, so it cannot inspect "
            f"the envelope at all — Casdoor's denials are HTTP 200")
        return

    state = {"unguarded": [], "kinds": set(), "enforced": False, "conditional": []}

    def scan(stmts, verified):
        for st in stmts:
            if isinstance(st, ast.If):
                kind = _classify(st.test, resp_names, status_names)
                if kind:
                    state["kinds"].add(kind)
                elif any(_status_read(n, resp_names, status_names)
                         for n in ast.walk(st.test)):
                    # the envelope IS read in a test, but the test is not one that
                    # fires on every denial (e.g. `STRICT and status != "ok"`)
                    state["conditional"].append(st.lineno)
                if kind == "notok" and _terminates(st.body):
                    scan(st.orelse, verified)
                    state["enforced"] = True
                    verified = True          # everything after it has been checked
                    continue
                if kind == "ok":
                    state["enforced"] = True
                    scan(st.body, True)      # inside the gate the envelope is ok
                    scan(st.orelse, verified)
                    continue
                scan(st.body, verified)
                scan(st.orelse, verified)
            elif isinstance(st, ast.Expr) and isinstance(st.value, ast.Call) \
                    and isinstance(st.value.func, ast.Name) \
                    and any(_mentions(a, resp_names) for a in st.value.args) \
                    and _delegates_check(funcs.get(st.value.func.id), set(), funcs):
                # the envelope check is factored into a helper this line calls
                state["enforced"] = True
                verified = True
            elif isinstance(st, ast.Return):
                if st.value is not None and _mentions(st.value, resp_names) \
                        and not verified:
                    state["unguarded"].append(st.lineno)
            elif isinstance(st, ast.Try):
                scan(st.body, verified)
                for h in st.handlers:
                    # a handler can catch the guard's own raise, so inside one the
                    # envelope is unproven again
                    scan(h.body, False)
                scan(st.orelse, verified)
                scan(st.finalbody, verified)
            elif isinstance(st, (ast.For, ast.While, ast.With, ast.AsyncWith)):
                scan(st.body, verified)
                scan(getattr(st, "orelse", []) or [], verified)
        return verified

    scan(call_fn.body, False)

    if state["unguarded"]:
        lines = ", ".join(str(n) for n in state["unguarded"])
        bad(f"{label}: call() returns the parsed response at line(s) {lines} on a path "
            f"where the status comparison did not raise — the comparison is there but "
            f"it does not stop anything, so a denied call is handed back as a result")
    elif state["enforced"]:
        ok(f"{label}: no path through call() returns a response whose status was not "
           f"proved to be \"ok\" (control-flow checked, not word-matched)")
        return
    elif state["conditional"]:
        lines = ", ".join(str(n) for n in state["conditional"])
        bad(f"{label}: call() reads the envelope at line(s) {lines} but only inside a "
            f"test that does not fire on every denial — a Casdoor denial (HTTP 200 + "
            f"{{\"status\":\"error\"}}) can still be returned as a result")
    elif not state["kinds"]:
        bad(f"{label}: call() never compares the response envelope against \"ok\", and "
            f"no helper it calls raises on one — every Casdoor denial (HTTP 200 + "
            f"{{\"status\":\"error\"}}) is returned to the caller as a result")
    else:
        bad(f"{label}: call() compares the envelope but no branch of that comparison "
            f"terminates the run")


# ── (3b) a write must be re-read ─────────────────────────────────────────────
# wrapActionResponse() (casdoor controllers/base.go) answers
# {"status":"ok","data":"Affected"} or {"status":"ok","data":"Unaffected"} for
# every write that reached the handler, whether or not anything was stored — and
# /api/update-group is LIVE-VERIFIED to answer "Affected" while persisting no
# membership at all. So the envelope check of (3) is necessary and NOT sufficient:
# the only evidence a write landed is reading the object back.
WRITE_RE = re.compile(r"/api/(add|update|delete|set)-([a-z-]*)")
READ_RE = re.compile(r"/api/get-([a-z-]*)")
# /api/set-password has no matching read endpoint — casdoor exposes no way to read
# a password back. Its verification is a re-login with the new value, required
# separately by contract item (8) and exercised by scenario (4d) of the harness.
NO_READBACK = {"password"}


def _path_text(node, consts):
    """The literal part of a call() path argument. f-string placeholders collapse
    to nothing, so f"/api/add-{noun}" yields "/api/add-" and is treated as a write
    to an unknown noun (matched by any later read)."""
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    if isinstance(node, ast.JoinedStr):
        return "".join(v.value for v in node.values
                       if isinstance(v, ast.Constant) and isinstance(v.value, str))
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add):
        return _path_text(node.left, consts) + _path_text(node.right, consts)
    if isinstance(node, ast.Name):
        return consts.get(node.id, "")
    return ""


def _owner_map(tree):
    """node-id -> enclosing FunctionDef name (or "<module>")."""
    owner = {}

    def walk(node, name):
        for child in ast.iter_child_nodes(node):
            child_name = child.name if isinstance(child, ast.FunctionDef) else name
            owner[id(child)] = child_name
            walk(child, child_name)
    owner[id(tree)] = "<module>"
    walk(tree, "<module>")
    return owner


def check_write_readback(label, tree):
    owner = _owner_map(tree)
    # Names bound to a path-looking string (user_path = f"/api/get-user?…"), kept
    # PER FUNCTION: several of these scripts reuse the name `path` in three
    # different reconcilers, and a single flat map would resolve one function's
    # readback against another function's endpoint.
    consts_by_fn = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign):
            text = _path_text(node.value, {})
            if "/api/" in text:
                for t in node.targets:
                    if isinstance(t, ast.Name):
                        consts_by_fn.setdefault(owner.get(id(node), "<module>"),
                                                {})[t.id] = text

    calls = []           # (fn, lineno, kind, noun) for every path-bearing call
    helper_reads = {}    # fn -> [(noun)] read anywhere inside it
    helper_calls = []    # (fn, lineno, callee) for local-helper invocations
    local_fns = {n.name for n in ast.walk(tree) if isinstance(n, ast.FunctionDef)}

    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        fn = owner.get(id(node), "<module>")
        callee = _attr_chain(node.func)
        if callee in local_fns:
            helper_calls.append((fn, node.lineno, callee))
        if not node.args:
            continue
        consts = dict(consts_by_fn.get("<module>", {}))
        consts.update(consts_by_fn.get(fn, {}))
        text = _path_text(node.args[0], consts)
        if "/api/" not in text:
            continue
        w = WRITE_RE.search(text)
        r = READ_RE.search(text)
        if w:
            calls.append((fn, node.lineno, "write", w.group(2) or "*"))
        elif r:
            calls.append((fn, node.lineno, "read", r.group(1) or "*"))
            helper_reads.setdefault(fn, []).append(r.group(1) or "*")

    writes = [c for c in calls if c[2] == "write" and c[3] not in NO_READBACK]
    if not writes:
        ok(f"{label}: performs no Casdoor write, so there is nothing to re-read")
        return

    unverified = []
    for fn, lineno, _, noun in writes:
        later_reads = [n for f, l, k, n in calls
                       if k == "read" and f == fn and l > lineno]
        for f, l, callee in helper_calls:
            if f == fn and l > lineno:
                later_reads += helper_reads.get(callee, [])
        if not any(n == noun or n == "*" or noun == "*" for n in later_reads):
            unverified.append(f"line {lineno}: /api/*-{noun} in {fn}()")
    if unverified:
        bad(f"{label}: write(s) never re-read — {'; '.join(unverified)}. casdoor's "
            f"wrapActionResponse answers status ok for a write that stored nothing "
            f"(\"Unaffected\", and update-group answers \"Affected\" while persisting "
            f"none of it), so announcing off the envelope announces a change that "
            f"may not exist")
    else:
        ok(f"{label}: every write is followed by a read of the same object in the "
           f"same function — an ok envelope is never the evidence a write landed")


def check_source(label, src, init):
    try:
        tree = ast.parse(src)
    except SyntaxError as e:
        bad(f"{label}: does not parse: {e}")
        return

    funcs = {n.name: n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef)}
    if "call" not in funcs:
        bad(f"{label}: no call() transport helper — cannot reason about its API calls")
        return
    call_fn = funcs["call"]
    call_nodes = set(map(id, ast.walk(call_fn)))

    # (2) one egress point
    leaks = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        target = _attr_chain(node.func)
        egress = (target.endswith(".open") and "opener" in target) or \
                 target.split(".")[-1] in EGRESS and "urllib" in target
        if egress and id(node) not in call_nodes:
            leaks.append(f"line {node.lineno}: {target}")
    if leaks:
        bad(f"{label}: HTTP egress outside call(): {'; '.join(leaks)}")
    else:
        ok(f"{label}: every Casdoor request goes through the single call() helper")

    # (3) the helper ENFORCES the envelope — analysed, not word-matched
    check_envelope(label, call_fn, funcs)

    # (3b) and an "ok" envelope is never taken as proof a write persisted
    check_write_readback(label, tree)

    # (4) the login is verified against the session — in the login helper itself or
    # in a helper it calls (require_admin_session()), one level of indirection.
    login_fns = [f for n, f in funcs.items() if n in ("login", "try_login")]
    reachable = list(login_fns)
    for f in login_fns:
        for node in ast.walk(f):
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
                callee = funcs.get(node.func.id)
                if callee is not None:
                    reachable.append(callee)
    if not login_fns:
        bad(f"{label}: no login()/try_login() helper")
    elif any("get-account" in ast.dump(f) for f in reachable):
        ok(f"{label}: the login is verified by reading the session back (/api/get-account)")
    else:
        bad(f"{label}: login() never reads the session back — a 200 from /api/login "
            f"is not proof of an admin session (the live run reconciled anonymously)")

    # (5) nothing swallowed
    swallowed = [h.lineno for h in ast.walk(tree)
                 if isinstance(h, ast.ExceptHandler)
                 and len(h.body) == 1 and isinstance(h.body[0], ast.Pass)]
    if swallowed:
        bad(f"{label}: `except: pass` at line(s) {swallowed} — an unchecked response")
    else:
        ok(f"{label}: no exception handler silently swallows a failure")

    # (6) can fail
    if "SystemExit" in src or re.search(r"\bsys\.exit\(", src):
        ok(f"{label}: can terminate non-zero")
    else:
        bad(f"{label}: has no non-zero exit path at all")

    # (7) exercisable offline. Hardcoded absolute /secrets paths mean the script
    # can only ever be run inside its own Pod — i.e. it can only be validated by
    # deploying it, which is exactly how it stayed broken. The Job sets neither
    # override, so this costs the cluster nothing.
    if "CASDOOR_SECRETS_DIR" in src:
        ok(f"{label}: reads its secrets through an overridable root, so its real "
           f"behaviour can be exercised without a cluster")
    else:
        bad(f"{label}: hardcodes /secrets, so the only way to exercise it is to "
            f"deploy it — no offline test can ever run this script")

    if not init:
        return
    # (7)+(8) the admin-credential legs
    if "/api/set-password" in src:
        ok(f"{label}: applies the admin password through /api/set-password")
    else:
        bad(f"{label}: never calls /api/set-password — update-user does NOT change a "
            f"password, so the Vault-provisioned value is never applied and the IdP "
            f"keeps casdoor's default")
    if "CASDOOR_BOOTSTRAP_PASSWORD" in src:
        ok(f"{label}: handles the first run where the account still has casdoor's default")
    else:
        bad(f"{label}: does not know casdoor's bootstrap default, so it cannot take "
            f"the account over on a fresh cluster nor prove the default is dead")


# ── the wiring contract ──────────────────────────────────────────────────────
# ── (5) THE HOOK-ORDERING / LOGIN-BUDGET CONTRACT ────────────────────────────
# Every check above reads ONE script at a time. This one reads the DEPLOYMENT,
# because the property it defends cannot be seen from inside a single file.
#
# WHAT WENT WRONG (hugmesh-generator#396, measured on kind 2026-09-16).
# manifests/casdoor ships four ArgoCD PostSync hook Jobs. All four log in as the
# SAME built-in/admin account. Exactly one of them — casdoor-init — knows
# casdoor's bootstrap default and is the only thing that can take the account
# over from it; the other three know ONLY the Vault-provisioned password, so on a
# fresh cluster their login is guaranteed wrong until casdoor-init has run. There
# was no sync-wave on any of them, so ArgoCD started all four at once: the three
# wrong logins spent the account's wrong-password budget, casdoor's sign-in
# throttle banned the admin for fifteen minutes, and casdoor-init's CORRECT login
# was refused inside the ban. `make kind-up` exited 1 at 17:21:55Z on a cluster
# that converged by itself at 17:29:32Z, and the Job's failure text blamed a Vault
# secret that was byte-for-byte correct.
#
# reconcile_admin_password()'s own docstring asserted the invariant this broke —
# "at most two wrong-password attempts are ever made, well under casdoor's
# 5-attempt sign-in lockout". That was true of the FILE and false of the
# DEPLOYMENT: the budget is spent against one shared account by every Job here
# and by the pod backoff. The measured spend on that run was 104 attempts.
#
# So the contract is about the set, not the file:
#   * the Jobs that share an admin Secret are ORDERED by argocd.argoproj.io/
#     sync-wave, with the one that owns the takeover strictly first — ArgoCD runs
#     a phase's hooks wave by wave and waits for each wave, so this is what makes
#     "casdoor-init goes first" true of the deployment;
#   * and the owner's own pod backoff cannot replay a lockout: it exits with a
#     DISTINCT status for "casdoor's throttle is refusing every login", and the
#     Job turns that status into FailJob instead of six more attempts.
# Directories with a single admin-login Job have nothing to order; they are
# reported as such (with the count MEASURED, not assumed) so the rule arms itself
# the day a sibling lands rather than silently exempting one.


def _admin_secret(job, secrets_dir="/secrets"):
    """The Secret this Job opens its admin session with, or None.

    Identified by the MOUNT PATH the reconcile scripts actually read
    (f"{SECRETS}/admin/username"), not by the secret's name: every one of these
    Jobs mounts several Secrets and only one of them is the credential.
    """
    pod = (job.get("spec") or {}).get("template", {}).get("spec", {}) or {}
    want = f"{secrets_dir.rstrip('/')}/admin"
    vol = None
    for c in pod.get("containers") or []:
        for m in c.get("volumeMounts") or []:
            if (m.get("mountPath") or "").rstrip("/") == want:
                vol = m.get("name")
    if not vol:
        return None
    for v in pod.get("volumes") or []:
        if v.get("name") == vol:
            return (v.get("secret") or {}).get("secretName")
    return None


def _script_cms(job):
    """ConfigMap names this Job mounts — how a Job is tied to its reconcile script."""
    pod = (job.get("spec") or {}).get("template", {}).get("spec", {}) or {}
    return {(v.get("configMap") or {}).get("name")
            for v in pod.get("volumes") or [] if v.get("configMap")}


def _const(src, name):
    """A module-level literal out of the script itself, or None. Read from the AST
    so the guard cannot pin a number the script no longer uses."""
    try:
        tree = ast.parse(src)
    except SyntaxError:
        return None
    found = None
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(
                getattr(t, "id", None) == name for t in node.targets):
            try:
                found = ast.literal_eval(node.value)
            except ValueError:
                return None
    return found


def check_hooks(cluster):
    scripts = {cm: src for cm, key, src, _ in discover(cluster)}
    inits = {cm for cm in scripts if is_init(cm)}
    seen_scripts = set()
    groups = {}
    for d in sorted(pathlib.Path(cluster, "manifests").glob("casdoor*")):
        for manifest in sorted(d.glob("*.yaml")):
            for job in _load(manifest):
                if job.get("kind") != "Job":
                    continue
                cms = _script_cms(job) & set(scripts)
                if not cms:
                    continue          # not an admin-session Job
                seen_scripts |= cms
                secret = _admin_secret(job)
                if not secret:
                    bad(f"{d.name}/{manifest.name}: Job "
                        f"{(job.get('metadata') or {}).get('name')} runs a Casdoor "
                        f"login script but mounts no admin credential at /secrets/admin "
                        f"— the guard cannot tell which account it spends")
                    continue
                groups.setdefault((d.name, secret), []).append((manifest, job, cms))

    missing = set(scripts) - seen_scripts
    if missing:
        bad(f"hooks: {sorted(missing)} is a Casdoor login script that no Job in "
            f"specs/cluster mounts — refusing to report an ordering pass off a "
            f"sweep that did not find every consumer")
        return
    if not groups:
        bad("hooks: found no admin-session Job at all — the ordering contract "
            "would pass vacuously")
        return

    for (dirname, secret), members in sorted(groups.items()):
        owners = [m for m in members if m[2] & inits]
        label = f"{dirname}: Secret {secret}"
        if len(owners) != 1:
            bad(f"{label}: {len(owners)} of the {len(members)} Job(s) that share this "
                f"admin credential own the takeover from casdoor's bootstrap default "
                f"— exactly one must, or nothing defines which goes first")
            continue
        owner_manifest, owner_job, owner_cms = owners[0]
        owner_name = (owner_job.get("metadata") or {}).get("name")

        # ── ordering ─────────────────────────────────────────────────────────
        if len(members) == 1:
            ok(f"{label}: {owner_name} is the only Job that logs in with it "
               f"(nothing to order; this rule arms itself if a sibling lands)")
        else:
            waves = {}
            broken = False
            for manifest, job, _cms in members:
                name = (job.get("metadata") or {}).get("name")
                ann = (job.get("metadata") or {}).get("annotations") or {}
                raw = ann.get("argocd.argoproj.io/sync-wave")
                if raw is None:
                    bad(f"{label}: hook Job {name} ({manifest.name}) carries no "
                        f"argocd.argoproj.io/sync-wave — {len(members)} Jobs share this "
                        f"admin account and ArgoCD starts un-waved hooks of a phase "
                        f"together, which is what banned the account (#396)")
                    broken = True
                    continue
                try:
                    waves[name] = int(str(raw))
                except ValueError:
                    bad(f"{label}: hook Job {name} has a non-numeric sync-wave {raw!r}")
                    broken = True
            if not broken:
                others = {n: w for n, w in waves.items() if n != owner_name}
                late = {n: w for n, w in others.items() if w <= waves[owner_name]}
                if late:
                    bad(f"{label}: {owner_name} is wave {waves[owner_name]} but "
                        f"{sorted(late)} are at {sorted(set(late.values()))} — a Job "
                        f"that only knows the provisioned password must not run in or "
                        f"before the wave that installs it")
                else:
                    ok(f"{label}: {owner_name} is wave {waves[owner_name]}, the "
                       f"{len(others)} Job(s) that only know the provisioned password "
                       f"are at {sorted(set(others.values()))}")

        # ── the owner's own retry budget ─────────────────────────────────────
        # Only demanded where a takeover actually races a sibling: that is the
        # measured defect, and the count above is what decides it.
        if len(members) == 1:
            continue
        src = scripts[sorted(owner_cms)[0]]
        exit_code = _const(src, "LOCKOUT_EXIT")
        marker = _const(src, "LOCKOUT_MARKER")
        if not isinstance(exit_code, int) or not isinstance(marker, str) or not marker:
            bad(f"{label}: {owner_name}'s script defines no LOCKOUT_EXIT/"
                f"LOCKOUT_MARKER — it cannot tell casdoor's sign-in throttle "
                f"(which refuses the CORRECT password too) from a wrong one, and "
                f"reports 'reconcile the secret' for an account that is merely banned")
            continue
        spec = owner_job.get("spec") or {}
        pod = (spec.get("template") or {}).get("spec") or {}
        restart = pod.get("restartPolicy")
        containers = [c.get("name") for c in pod.get("containers") or []]
        rules = ((spec.get("podFailurePolicy") or {}).get("rules")) or []
        matched = [r for r in rules
                   if r.get("action") == "FailJob"
                   and exit_code in ((r.get("onExitCodes") or {}).get("values") or [])
                   and ((r.get("onExitCodes") or {}).get("containerName") in containers
                        or (r.get("onExitCodes") or {}).get("containerName") is None)]
        if not matched:
            bad(f"{label}: {owner_name} has no podFailurePolicy FailJob rule for exit "
                f"{exit_code} on a container it actually runs {containers} — "
                f"backoffLimit {spec.get('backoffLimit')} would replay the login "
                f"{(spec.get('backoffLimit') or 0) + 1} times into a ban only time clears")
        elif restart != "Never":
            bad(f"{label}: {owner_name} sets restartPolicy {restart!r}; a "
                f"podFailurePolicy is only valid with 'Never', so the FailJob rule "
                f"above would be rejected by the apiserver and silently buy nothing")
        else:
            ok(f"{label}: {owner_name} exits {exit_code} for 'casdoor's throttle is "
               f"refusing every login' and a podFailurePolicy FailJob rule ends the "
               f"Job there instead of replaying it")


def _load(path):
    return [d for d in yaml.safe_load_all(pathlib.Path(path).read_text())
            if isinstance(d, dict)]


def _conf_value(text, key):
    m = re.search(rf"^\s*{re.escape(key)}\s*=\s*(.*?)\s*$", text, re.M)
    if not m:
        return None
    # beego strips surrounding double quotes (core/config/ini.go), single quotes
    # are NOT special there — so only "…" is unwrapped, exactly like the server.
    val = m.group(1)
    return val[1:-1] if len(val) > 1 and val.startswith('"') and val.endswith('"') else val


def _conf_reconcile_job(d):
    """The env-driven alternative to a static init_data.json, or None.

    Requires all four, so a stray file cannot excuse a missing seed:
      (1) init-job.yaml exists AND is listed in kustomization.yaml's RESOURCES
          (an unreferenced manifest is never applied -- and a substring test on
          the file text is not enough: a comment there names it too);
      (2) it really carries a Job;
      (3) the Job ships a reconcile script that talks to Casdoor -- checked by
          looking for the seeded object kinds, not for a filename.
    """
    job_file = d / "init-job.yaml"
    if not job_file.exists():
        return None
    kust = d / "kustomization.yaml"
    if not kust.exists():
        return None
    # The RESOURCES LIST, not the file text: this same kustomization explains the
    # divergence in a comment that names init-job.yaml, so a substring test passes
    # even after the resource is unlisted -- i.e. after it stops being applied.
    kdoc = next((o for o in _load(kust) if isinstance(o, dict)), None) or {}
    if "init-job.yaml" not in (kdoc.get("resources") or []):
        return None
    objs = _load(job_file)
    if not any(o.get("kind") == "Job" for o in objs):
        return None
    text = job_file.read_text(encoding="utf-8")
    if not all(tok in text for tok in ("organization", "application")):
        return None
    # (4) and the directory must ship NO seed at all. casdoor and casdoor-games
    #     BOTH have an init-job.yaml too -- theirs is a verification pass that
    #     mounts the same init-data ConfigMap the Deployment does. Without this
    #     condition, either of them could quietly stop mounting its seed and be
    #     excused by the presence of a Job that only ever READS one. A directory
    #     that still carries a seed ConfigMap must still deliver it.
    # STRUCTURAL, not textual: a seed is a ConfigMap carrying an init_data.json
    # KEY. Scanning the file text instead would match the prose in
    # casdoor-domain's own app.conf explaining why it has no seed -- the same way
    # a substring test on kustomization.yaml matched its explanatory comment.
    for f in sorted(d.glob("*.yaml")):
        for o in _load(f):
            if o.get("kind") == "ConfigMap" and "init_data.json" in (o.get("data") or {}):
                return None
    return job_file.name


def check_conf(cluster):
    dirs = sorted(pathlib.Path(cluster, "manifests").glob("casdoor*"))
    dirs = [d for d in dirs if (d / "deployment.yaml").exists()]
    if not dirs:
        bad("conf: found no casdoor deployment directory at all")
        return
    for d in dirs:
        label = d.name
        deployment = next((o for o in _load(d / "deployment.yaml")
                           if o.get("kind") == "Deployment"), None)
        if not deployment:
            bad(f"{label}: no Deployment in deployment.yaml")
            continue
        pod = deployment["spec"]["template"]["spec"]
        mount = None
        for c in pod.get("containers", []):
            for m in c.get("volumeMounts", []):
                if m.get("subPath") == "init_data.json":
                    mount = m
        if not mount:
            # TWO DELIVERY MECHANISMS, and a directory must use exactly one.
            # casdoor/casdoor-games mount a static init_data.json. casdoor-domain
            # deliberately does not (a domain's org/app/admin-password are
            # env-driven and not knowable at build time) and delivers the same
            # seed through an init Job running reconcile.py instead.
            #
            # This is NOT an exemption by name. A name list would be a standing
            # amnesty that keeps passing after the divergence is undone -- which
            # is how the guard came to fail here in the first place: it was
            # written 2026-08-06, the divergence landed 2026-08-19, and neither
            # side could see the other. The alternative is DERIVED from the tree,
            # so a directory that stops delivering the seed by EITHER route still
            # goes red, and a directory that quietly grows a second route does too.
            reconciler = _conf_reconcile_job(d)
            if reconciler:
                ok(f"{label}: no static init_data.json, and the seed is delivered by "
                   f"the env-driven init Job instead ({reconciler})")
                continue
            bad(f"{label}: the Deployment mounts no init_data.json AND there is no "
                f"env-driven init Job to deliver the seed either — it is not "
                f"delivered at all")
            continue
        seed_volume = next((v for v in pod.get("volumes", [])
                            if v.get("name") == mount["name"]), None)
        seed_cm = ((seed_volume or {}).get("configMap") or {}).get("name")

        # (a)+(b)+(c) the app.conf that Casdoor actually reads
        conf_file = d / "app-conf-configmap.yaml"
        cm = next((o for o in _load(conf_file) if o.get("kind") == "ConfigMap"), None)
        text = ""
        for key in ("app.conf", "app.conf.template"):
            text = ((cm or {}).get("data") or {}).get(key) or text
        if not text:
            bad(f"{label}: no app.conf/app.conf.template in {conf_file.name}")
            continue
        init_data_file = _conf_value(text, "initDataFile")
        if not init_data_file:
            bad(f"{label}: app.conf sets no initDataFile — object/init_data.go's "
                f"InitFromFile() returns immediately when it is empty, so the seed "
                f"mounted at {mount['mountPath']} is NEVER read and nothing says so")
        elif init_data_file != mount["mountPath"]:
            bad(f"{label}: initDataFile={init_data_file!r} but the seed is mounted at "
                f"{mount['mountPath']!r} — Casdoor would read nothing")
        else:
            ok(f"{label}: initDataFile points at the path the seed is mounted at "
               f"({init_data_file})")
        new_only = _conf_value(text, "initDataNewOnly")
        if new_only == "true":
            ok(f"{label}: initDataNewOnly=true (the import creates missing objects "
               f"instead of deleting and re-adding every one on each restart)")
        else:
            bad(f"{label}: initDataNewOnly={new_only!r} — with anything but true, "
                f"initDefinedOrganization/Role/User DELETE and re-add every declared "
                f"object on EVERY restart, resetting role membership to the seed's "
                f"empty lists")

        # (d) the init Job verifies the same ConfigMap it was given
        job_file = d / "init-job.yaml"
        if not job_file.exists():
            bad(f"{label}: no init-job.yaml")
            continue
        docs = _load(job_file)
        job = next((o for o in docs if o.get("kind") == "Job"), None)
        script = None
        for o in docs:
            if o.get("kind") == "ConfigMap":
                for k, v in (o.get("data") or {}).items():
                    if k.endswith(".py"):
                        script = v
        m = re.search(r'CASDOOR_INIT_DATA["\']?\s*,\s*["\']([^"\']+)["\']', script or "")
        if not m:
            bad(f"{label}: the init script reads no seed file (no CASDOOR_INIT_DATA "
                f"default) — a boot-time import that quietly did nothing would again "
                f"be invisible")
            continue
        want_dir = os.path.dirname(m.group(1))
        jpod = job["spec"]["template"]["spec"]
        jm = None
        for c in jpod.get("containers", []):
            for mnt in c.get("volumeMounts", []):
                if mnt.get("mountPath") == want_dir:
                    jm = mnt
        jv = next((v for v in jpod.get("volumes", []) if jm and v["name"] == jm["name"]), None)
        job_cm = ((jv or {}).get("configMap") or {}).get("name")
        if job_cm and job_cm == seed_cm:
            ok(f"{label}: the init Job mounts the same seed ConfigMap ({seed_cm}) at "
               f"{want_dir}, so its verification pass reads what Casdoor was given")
        else:
            bad(f"{label}: the init script reads {m.group(1)} but the Job mounts "
                f"{job_cm!r} there while the Deployment is seeded from {seed_cm!r}")


# ── the object-graph contract ────────────────────────────────────────────────
# The seeds that MUST be found, for the same reason as REQUIRED above: a renamed
# directory that dropped one out of the sweep would report a pass having checked
# nothing about it.
REQUIRED_SEEDS = {"casdoor", "casdoor-games"}

# object/init_data.go:71-156 — the HARDCODED sequence InitFromFile() creates kinds
# in. Key order inside the JSON has no effect whatsoever; this list is the only
# thing that decides what exists when.
INIT_ORDER = [
    "organizations", "providers", "applications", "users", "certs", "ldaps",
    "models", "payments", "products", "resources", "roles", "syncers", "tokens",
    "webhooks", "groups", "adapters", "enforcers", "permissions", "plans",
    "pricings", "invitations", "records", "sessions", "subscriptions",
    "transactions", "rules", "sites", "third_party_links",
]

# (from-kind, field, to-kind, shape). "id" fields hold a list of "<owner>/<name>"
# strings; "name" fields hold a single bare name owned by "admin".
SEED_REFS = [
    ("applications", "cert",        "certs",  "name"),
    ("applications", "signingCert", "certs",  "name"),
    ("users",        "groups",      "groups", "id"),
    ("roles",        "users",       "users",  "id"),
    ("roles",        "roles",       "roles",  "id"),
    ("permissions",  "users",       "users",  "id"),
    ("permissions",  "roles",       "roles",  "id"),
]
# Where a dangling reference is silently accepted by casdoor and produces an
# authority that does not exist (AddRole/AddPermission are bare inserts,
# object/role.go:151-158) rather than an error anyone would ever see.
SEED_MUST_DECLARE = {("roles", "users"), ("roles", "roles"),
                     ("permissions", "users"), ("permissions", "roles")}

# The owner every organization must carry. This is PINNED to the literal upstream
# hardcodes, NOT derived from the seed: AddUser resolves the user's organization
# through GetOrganizationByUser, which is
#     return getOrganization("admin", user.Owner)
# (object/organization.go:305-311), and getOrganization does an exact primary-key
# Get on (owner, name) (object/organization.go:159-175). Casdoor's own bootstrap
# writes the same literal (object/init.go:120-127). An organization row carrying
# any other owner is therefore invisible to every user creation in the product,
# and deriving the expectation from the seed's own organization block would let
# an internally-consistent-but-unimportable file pass.
ORG_OWNER = "admin"

# object/init.go:115-152 creates this organization unconditionally from
# object.InitDb() (main.go:59), which runs BEFORE object.InitFromFile()
# (main.go:78). It is never declared by a seed and always exists by the time the
# import runs, with HasPrivilegeConsent left at its zero value, false.
BUILTIN_ORG = "built-in"
# object/user.go:1010-1011 — the only user name the built-in organization accepts
# while HasPrivilegeConsent is false.
BUILTIN_ONLY_USER = "admin"


def _seed_files(cluster):
    """{directory-name: (path, parsed init_data.json)} for every seed in the tree."""
    seeds = {}
    for path in sorted(pathlib.Path(cluster, "manifests").glob(
            "casdoor*/init-data-configmap.yaml")):
        label = path.parent.name
        cm = next((o for o in _load(path) if o.get("kind") == "ConfigMap"), None)
        raw = ((cm or {}).get("data") or {}).get("init_data.json")
        if raw is None:
            bad(f"{label}: init-data-configmap.yaml carries no init_data.json key")
            continue
        try:
            seeds[label] = (path, json.loads(raw))
        except ValueError as e:
            bad(f"{label}: init_data.json is not valid JSON ({e}) — casdoor panics "
                f"on it at boot (object/init_data.go:66-69)")
    return seeds


def _ids(objs):
    return {f"{o.get('owner')}/{o.get('name')}" for o in objs}


def check_one_seed(label, seed):
    orgs = {o.get("name"): o for o in seed.get("organizations") or []}
    apps = seed.get("applications") or []

    # (s0) THE OWNER IS NOT NEGOTIABLE. AddUser reaches the organization only
    # through getOrganization("admin", user.Owner) — a primary-key Get with the
    # owner written into the call site. An organization row with any other owner
    # is not found, and AddUser returns "the organization: <name> is not found"
    # (object/user.go:992-998) which initDefinedUser panics on at
    # object/init_data.go:366-368, exactly like the missing-application case. The
    # comparison below is against the literal, never against the seed's own idea
    # of who owns the organization: an owner drift applied consistently across
    # organization AND application is internally consistent and still unbootable.
    for org in seed.get("organizations") or []:
        if org.get("owner") != ORG_OWNER:
            bad(f"{label}: organization {org.get('name')!r} declares "
                f"owner={org.get('owner')!r}, but every organization casdoor can "
                f"resolve is owned by the literal {ORG_OWNER!r} — "
                f"GetOrganizationByUser hardcodes "
                f"getOrganization({ORG_OWNER!r}, user.Owner) "
                f"(object/organization.go:305-311) and casdoor's own bootstrap "
                f"writes the same literal (object/init.go:120-127). This row is "
                f"never found, so AddUser returns \"the organization: "
                f"{org.get('name')} is not found\" (object/user.go:992-998) and "
                f"initDefinedUser panics on it (object/init_data.go:366-368). "
                f"Declaring the application under the same wrong owner does not "
                f"help: the lookup never gets that far")

    # (s2) an application owned by its own organization does not satisfy (s1):
    # the count filters owner = <organization.Owner>, and (s0) has just pinned
    # that to "admin", so this is pinned to "admin" too rather than re-derived.
    for app in apps:
        if app.get("organization") not in orgs:
            continue
        if app.get("owner") != ORG_OWNER:
            bad(f"{label}: application {app.get('name')!r} is owned by "
                f"{app.get('owner')!r}, not {ORG_OWNER!r} — AddUser calls "
                f"GetOrganizationApplicationCount(organization.Owner, …) and the "
                f"organization it resolved can only ever be the {ORG_OWNER!r}-owned "
                f"row, so the count "
                f"(SELECT count(*) … WHERE owner = {ORG_OWNER!r}, "
                f"object/application.go:194-197) does not see this application: it "
                f"does not make the organization viable and is not addressable as "
                f"'{ORG_OWNER}/{app.get('name')}' by the init Job either")

    def viable(org_name):
        return [a for a in apps
                if a.get("owner") == ORG_OWNER
                and (a.get("organization") == org_name or a.get("isShared"))]

    # (s1) THE LIVE PANIC. Every organization this file puts users (or roles) in
    # must be made viable BY THIS FILE.
    dependents = {}
    for kind in ("users", "roles"):
        for obj in seed.get(kind) or []:
            dependents.setdefault(obj.get("owner"),
                                  {"users": [], "roles": []})[kind].append(
                                      obj.get("name"))
    for owner, members in sorted(dependents.items(),
                                 key=lambda kv: (kv[0] is None, kv[0])):
        what = ", ".join(f"{len(v)} {k}" for k, v in members.items() if v)
        users = members["users"]

        # object/user.go:983-987 rejects an empty owner outright, before any
        # organization is looked up at all.
        if not owner:
            if users:
                bad(f"{label}: declares {len(users)} user(s) {sorted(users)!r} with "
                    f"no owner — AddUser returns \"the user's owner and name should "
                    f"not be empty\" (object/user.go:983-987) and initDefinedUser "
                    f"panics on it (object/init_data.go:366-368)")
            else:
                bad(f"{label}: declares {what} with no owner — the object is not "
                    f"addressable as '<owner>/<name>' by anything")
            continue

        # THE BUILT-IN ORGANIZATION. object/user.go:999 exempts it from the
        # application-count check and from NOTHING ELSE. Two lines later,
        # object/user.go:1010-1011 rejects
        #     organization.Name == "built-in" && !organization.HasPrivilegeConsent
        #                                     && user.Name != "admin"
        # and that error is panicked at object/init_data.go:366-368 just the same.
        # The organization is not the seed's to configure: object/init.go:115-152
        # creates it from InitDb() (main.go:59) before InitFromFile() (main.go:78)
        # ever runs, with HasPrivilegeConsent false — and a seed that re-declares
        # it with hasPrivilegeConsent:true changes nothing, because
        # initDefinedOrganization returns early on an existing row under the
        # initDataNewOnly=true that section (2c) requires (init_data.go:291-299).
        if owner == BUILTIN_ORG:
            offenders = sorted(n for n in users if n != BUILTIN_ONLY_USER)
            if offenders:
                bad(f"{label}: declares user(s) {offenders!r} in the "
                    f"{BUILTIN_ORG!r} organization — casdoor accepts no user there "
                    f"but {BUILTIN_ONLY_USER!r} while HasPrivilegeConsent is false "
                    f"(object/user.go:1010-1011), and initDefinedUser panics on the "
                    f"refusal (object/init_data.go:366-368). The built-in "
                    f"organization's users are global Casdoor administrators; put "
                    f"service accounts in their own organization. Declaring "
                    f"hasPrivilegeConsent here does not help — the row already "
                    f"exists from InitDb() (object/init.go:115-152) and "
                    f"initDataNewOnly=true makes the seed's copy a no-op "
                    f"(object/init_data.go:291-299)")
            elif users:
                ok(f"{label}: the only user declared in {BUILTIN_ORG!r} is "
                   f"{BUILTIN_ONLY_USER!r} — the one name "
                   f"object/user.go:1010-1011 lets through")
            continue

        if owner not in orgs:
            bad(f"{label}: declares {what} in organization {owner!r} that this file "
                f"does not create — the seed cannot satisfy its own preconditions "
                f"(object/init_data.go:72 creates organizations, :81 the users)")
            continue
        have = viable(owner)
        if have:
            ok(f"{label}: organization {owner!r} ({what}) is made viable by this "
               f"file — application(s) {sorted(a.get('name') for a in have)} owned by "
               f"{ORG_OWNER!r}, so AddUser's application-count precondition "
               f"(object/user.go:999-1007) is satisfied at import time")
        elif users:
            bad(f"{label}: declares {what} in organization {owner!r} but NO "
                f"application owned by {ORG_OWNER!r} for it — AddUser "
                f"(object/user.go:999-1007) returns \"The organization: "
                f"{ORG_OWNER} should have one application at least\" and "
                f"initDefinedUser panics on it "
                f"(object/init_data.go:366-368): casdoor CrashLoopBackOffs at boot "
                f"and the init Job's /api/add-user is rejected the same way. "
                f"Declare an application with owner={ORG_OWNER!r}, "
                f"organization={owner!r} (no clientSecret — casdoor generates one, "
                f"the Job injects the Vault value)")
        else:
            bad(f"{label}: declares {what} in organization {owner!r} but NO "
                f"application owned by {ORG_OWNER!r} for it — the organization can "
                f"never hold a user (object/user.go:999-1007), so those roles can "
                f"never be granted to anyone")

    # (s3)+(s4) references, against the fixed creation order.
    for from_kind, field, to_kind, shape in SEED_REFS:
        if from_kind not in seed:
            continue
        declared = seed.get(to_kind) or []
        known = _ids(declared) if shape == "id" else {o.get("name") for o in declared}
        later = INIT_ORDER.index(to_kind) > INIT_ORDER.index(from_kind)
        for obj in seed[from_kind]:
            value = obj.get(field)
            refs = value if isinstance(value, list) else ([value] if value else [])
            for ref in refs:
                oid = f"{obj.get('owner')}/{obj.get('name')}"
                if ref in known and later:
                    bad(f"{label}: {from_kind[:-1]} {oid!r} references {to_kind[:-1]} "
                        f"{ref!r}, which this file declares under a kind "
                        f"InitFromFile() creates LATER ({to_kind} at position "
                        f"{INIT_ORDER.index(to_kind)}, {from_kind} at "
                        f"{INIT_ORDER.index(from_kind)} — object/init_data.go:71-156). "
                        f"The reference is written against an object that does not "
                        f"exist yet; JSON key order does not change this")
                elif ref not in known and (from_kind, field) in SEED_MUST_DECLARE:
                    bad(f"{label}: {from_kind[:-1]} {oid!r} names {to_kind[:-1]} "
                        f"{ref!r}, which this file never creates — AddRole/"
                        f"AddPermission are bare inserts with no referential check "
                        f"(object/role.go:151-158), so this is stored as a phantom "
                        f"membership: nothing errors and the authority never exists")
    ok(f"{label}: {sum(len(v) for v in seed.values() if isinstance(v, list))} declared "
       f"object(s), every cross-reference resolves to something an earlier kind "
       f"creates")


def check_seed(cluster):
    seeds = _seed_files(cluster)
    missing = REQUIRED_SEEDS - set(seeds)
    if missing:
        bad(f"seed: found {sorted(seeds)} but not {sorted(missing)} — refusing to "
            f"report a pass off an incomplete sweep")
    elif seeds:
        ok(f"seed: {len(seeds)} declarative seed(s) found ({', '.join(sorted(seeds))})")
    else:
        bad("seed: found no init-data-configmap.yaml at all")
    for label, (_, seed) in sorted(seeds.items()):
        check_one_seed(label, seed)


# ── extraction (for the behavioural half) ────────────────────────────────────
def extract(cluster, outdir):
    out = pathlib.Path(outdir)
    out.mkdir(parents=True, exist_ok=True)
    meta = []
    for cm_name, key, src, manifest in discover(cluster):
        stem = f"{cm_name}__{key}"
        (out / stem).write_text(src)
        entry = {"configmap": cm_name, "script": stem, "init": is_init(cm_name),
                 "manifest": str(manifest), "dir": manifest.parent.name}
        # The per-app client-secret files the script will open. Read from the
        # script's own APPS dict so the fixture cannot drift from the real list.
        apps = None
        for node in ast.walk(ast.parse(src)):
            if isinstance(node, ast.Assign) and any(
                    getattr(t, "id", None) == "APPS" for t in node.targets):
                apps = sorted(ast.literal_eval(node.value))
        entry["apps"] = apps or []
        m = re.search(r'CASDOOR_INIT_DATA["\']?\s*,\s*["\']([^"\']+)["\']', src)
        entry["seed_path"] = m.group(1) if m else ""
        meta.append(entry)
        # The declarative seed that lives beside it.
        seed_yaml = manifest.parent / "init-data-configmap.yaml"
        if seed_yaml.exists():
            for doc in _load(seed_yaml):
                if doc.get("kind") == "ConfigMap":
                    (out / f"{manifest.parent.name}__init_data.json").write_text(
                        doc["data"]["init_data.json"])
    (out / "meta.json").write_text(json.dumps(meta, indent=1))
    return meta


def _env_defaults(src):
    """{NAME: default} for every os.environ.get("NAME", "default") in the script,
    plus module-level list literals (PRIV_ROLES = ["ROLE_ADMIN", "ROLE_MOD"]). The
    stub seed below is built from THESE, never from a copy of the role names, so a
    renamed role cannot leave the behavioural scenarios silently exercising an
    empty store."""
    env = {}
    tree = ast.parse(src)
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and _attr_chain(node.func) == "os.environ.get" \
                and len(node.args) == 2 and isinstance(node.args[0], ast.Constant) \
                and isinstance(node.args[1], ast.Constant):
            env[node.args[0].value] = node.args[1].value
        if isinstance(node, ast.Assign) and isinstance(node.value, (ast.List, ast.Tuple)):
            try:
                value = ast.literal_eval(node.value)
            except ValueError:
                continue
            for t in node.targets:
                if isinstance(t, ast.Name) and all(isinstance(v, str) for v in value):
                    env.setdefault(f"#{t.id}", list(value))
    return env


def _sync_seeds(src, outdir):
    """Write the two stub-Casdoor stores a derived-role sync Job needs to reach its
    write path, and return (add_seed, prune_seed) — ("", "") for a script that is
    not one. The two differ in DIRECTION, and that matters:

      add   — the derived role gains a member. A write that stores nothing leaves
              the readback short of the expected set, so even a sloppy comparison
              notices.
      prune — the derived role loses its last member, so the expected set is
              EMPTY. Now a readback that failed and was turned into "no members"
              by an error-swallowing helper compares EQUAL to the expected set,
              and the run announces a removal that never happened. This is the
              direction the property actually needs testing in.
    """
    env = _env_defaults(src)
    org = env.get("CASDOOR_ORG", "hugmesh")
    derived = env.get("DERIVED_ROLE") or env.get("GAMES_ADMIN_ROLE")
    base = env.get("BASE_ROLE") or env.get("GAMES_ROLE")
    priv = env.get("#PRIV_ROLES")
    if priv is None and "PRIV_ROLES" in env:
        priv = [r for r in env["PRIV_ROLES"].split(",") if r]
    if not (derived and base and priv):
        return "", ""
    alice, bob = f"{org}/fixture-alice", f"{org}/fixture-bob"

    def role(name, users):
        return (f"role:{org}/{name}",
                {"owner": org, "name": name, "displayName": name, "users": users})

    add = dict([role(base, [alice, bob]), role(derived, [])] +
               [role(p, [alice] if i == 0 else []) for i, p in enumerate(priv)])
    prune = dict([role(base, [bob]), role(derived, [alice])] +
                 [role(p, [alice] if i == 0 else []) for i, p in enumerate(priv)])
    paths = []
    for name, store in (("stub-seed-add.json", add), ("stub-seed-prune.json", prune)):
        p = pathlib.Path(outdir, name)
        p.write_text(json.dumps(store, indent=1))
        paths.append(str(p))
    return paths[0], paths[1]


# The superadmin fixture credentials, in one place so the secrets directory, the
# stale-cluster stub store and the harness's secret sweep cannot drift apart.
# Deliberately distinctive so the sweep can grep for them verbatim.
SUPERADMIN_USER = "e2e-superadmin"
SUPERADMIN_PW = "SUPERADMIN-FIXTURE-PW"
SUPERADMIN_STALE_PW = "SUPERADMIN-PW-FROM-BEFORE-THE-ROTATION"


def _stale_superadmin_seed(src, outdir):
    """A stub store in which the superadmin account ALREADY EXISTS holding a
    password that is not the one Vault now has — i.e. a rotation that has happened
    in Vault and not yet in the IdP. Returns "" for a script with no superadmin
    leg, so a harness scenario cannot silently pass by never running one.

    This is the state no amount of re-running the Job could previously repair:
    the update branch re-sent every field EXCEPT the password (update-user cannot
    carry one), so the account kept the old credential forever."""
    if "/superadmin/password" not in src:
        return ""
    org = _env_defaults(src).get("CASDOOR_ORG", "hugmesh")
    store = {f"user:{org}/{SUPERADMIN_USER}": {
        "owner": org, "name": SUPERADMIN_USER, "id": "stub-uuid-preexisting",
        "displayName": "Platform Superadmin", "type": "normal-user",
        "password": SUPERADMIN_STALE_PW}}
    p = pathlib.Path(outdir, "stub-seed-stale-superadmin.json")
    p.write_text(json.dumps(store, indent=1))
    return str(p)


def fixture(cluster, workdir, cm_name, admin_password):
    """Stage everything one script opens from disk, so the REAL script can be run
    offline. The per-app client-secret names come from the script's own APPS dict
    and the seed from the ConfigMap next to it — nothing here is a copy that can
    drift from what ships. Prints SCRIPT/SECRETS/SEED for the shell harness."""
    out = pathlib.Path(workdir, cm_name)
    out.mkdir(parents=True, exist_ok=True)
    entry = next(e for e in extract(cluster, out / "scripts") if e["configmap"] == cm_name)
    secrets = out / "secrets"
    (secrets / "admin").mkdir(parents=True, exist_ok=True)
    (secrets / "admin" / "username").write_text("admin")
    (secrets / "admin" / "password").write_text(admin_password)
    (secrets / "apps").mkdir(exist_ok=True)
    for app in entry["apps"]:
        (secrets / "apps" / app).write_text(f"client-secret-for-{app}")
    # casdoor-games' single application secret (its analogue of /secrets/apps/*).
    (secrets / "app").mkdir(exist_ok=True)
    (secrets / "app" / "clientSecret").write_text("client-secret-for-threewizards-app")
    (secrets / "superadmin").mkdir(exist_ok=True)
    (secrets / "superadmin" / "username").write_text(SUPERADMIN_USER)
    (secrets / "superadmin" / "password").write_text(SUPERADMIN_PW)
    seed = out / "scripts" / f"{entry['dir']}__init_data.json"
    script_path = out / "scripts" / entry["script"]
    src = script_path.read_text()
    add, prune = _sync_seeds(src, out)
    print(f"SCRIPT={script_path}")
    print(f"SECRETS={secrets}")
    print(f"SEED={seed if seed.exists() else ''}")
    print(f"STUB_SEED_ADD={add}")
    print(f"STUB_SEED_PRUNE={prune}")
    print(f"STUB_SEED_STALE_SUPERADMIN={_stale_superadmin_seed(src, out)}")
    print(f"SUPERADMIN_PW={SUPERADMIN_PW}")


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    cmd, cluster = sys.argv[1], sys.argv[2]
    if cmd == "fixture":
        fixture(cluster, sys.argv[3], sys.argv[4], sys.argv[5])
        return 0
    scripts = discover(cluster)
    names = {f"{c}/{k}" for c, k, _, _ in scripts}
    if cmd == "discover":
        for c, k, _, m in scripts:
            print(f"{c}/{k}\t{'init' if is_init(c) else 'sync'}\t{m}")
        return 0
    if cmd == "extract":
        extract(cluster, sys.argv[3])
        return 0
    missing = REQUIRED - names
    if missing:
        bad(f"discovery found {len(scripts)} script(s) but not {sorted(missing)} — "
            f"refusing to report a pass off an incomplete sweep")
    else:
        ok(f"discovered {len(scripts)} embedded Casdoor reconcile script(s)")
    if cmd == "static":
        for cm_name, key, src, _ in scripts:
            check_source(f"{cm_name}/{key}", src, is_init(cm_name))
    elif cmd == "conf":
        check_conf(cluster)
    elif cmd == "seed":
        check_seed(cluster)
    elif cmd == "hooks":
        check_hooks(cluster)
    else:
        sys.exit(f"unknown subcommand {cmd!r}")
    print(f"  ({P} passed, {F} failed)")
    return 1 if F else 0


if __name__ == "__main__":
    sys.exit(main())
