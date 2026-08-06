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
            bad(f"{label}: the Deployment mounts no init_data.json — the declarative "
                f"seed is not delivered at all")
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
    (secrets / "superadmin" / "username").write_text("e2e-superadmin")
    (secrets / "superadmin" / "password").write_text("SUPERADMIN-FIXTURE-PW")
    seed = out / "scripts" / f"{entry['dir']}__init_data.json"
    script_path = out / "scripts" / entry["script"]
    add, prune = _sync_seeds(script_path.read_text(), out)
    print(f"SCRIPT={script_path}")
    print(f"SECRETS={secrets}")
    print(f"SEED={seed if seed.exists() else ''}")
    print(f"STUB_SEED_ADD={add}")
    print(f"STUB_SEED_PRUNE={prune}")


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
    else:
        sys.exit(f"unknown subcommand {cmd!r}")
    print(f"  ({P} passed, {F} failed)")
    return 1 if F else 0


if __name__ == "__main__":
    sys.exit(main())
