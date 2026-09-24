#!/usr/bin/env python3
"""tor_flip_wiring.py — the model behind tests/stack/test-tor-flip-wiring.sh.

Grades ONE repo root against the TOR=1 contract (hugmesh-generator#576, #581,
#586) and prints a PASS/FAIL line per check. The suite runs it against the real
tree (must be all PASS) and against staged mutants (each must fail exactly the
check it breaks), so every assertion here is exercised in both directions.

What TOR=1 has to mean, end to end:
  * the knob is DECLARED and selects the `tor` compose profile, and nothing else
    selects it (T1-T3);
  * it threads the client's host port, and with ANUBIS=1 points the onion's :80
    at the PoW gate unless the caller chose an upstream (T4);
  * the onion service serves :80 AND :443 from upstreams that exist, waits for
    both (tor resolves them once, at torrc parse), keeps its key in a declared
    volume and publishes its hostname where every reader looks (T5-T7);
  * HEALTHY means "this container's key is published and tor bootstrapped" (T8);
  * the SOCKS client the e2e dials is loopback-only, on the port the lane
    defaults to, and never an open proxy (T9);
  * the published hostname never outlives the container: removed before tor
    starts and again when it stops or dies (T10, #581);
  * teardown reaps the profile whatever the bring-up knobs were (T11);
  * `make stack-e2e-tor` reaches the onion THROUGH TOR without pointing the
    unproxied @env:docker probe at it (T12);
  * `make stack-onion` prints only a well-formed, currently-served onion (T13).

BEHAVIOUR, not source text, wherever it can be executed: STACK_ENV and the
profile are expanded by make itself; the entrypoint is RUN against a stub tor;
both healthchecks are EXECUTED against a sandbox; run.sh prints its own plan;
`make stack-onion` is run. Expectations are DERIVED from the tree (the anubis
gate's BIND, the TLS front's container port, the entrypoint's own paths, the
Studio's hostname path), never typed in here.

Exit 0 iff every check passed; 3 if a source file needed to grade is missing
(INCOMPLETE is never a pass). Offline: make, python3 + PyYAML, sh, cmp, grep.
"""
from __future__ import annotations

import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time

try:
    import yaml
except ImportError:  # pragma: no cover - the suite preflights this
    print("INCOMPLETE PyYAML is not importable", file=sys.stderr)
    sys.exit(3)

ROOT = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else ".")
MAKEFILE = os.path.join(ROOT, "Makefile")
COMPOSE = os.path.join(ROOT, "tests", "stack", "compose.local.yaml")
ENTRY = os.path.join(ROOT, "tests", "stack", "tor", "entrypoint.sh")
DOCKERFILE = os.path.join(ROOT, "tests", "stack", "tor", "Dockerfile")
RUNSH = os.path.join(ROOT, "tests", "e2e", "run.sh")
STUDIO_NODE = os.path.join(ROOT, "studio", "hugmesh_studio", "core", "local_stack_node.py")

ONION_SVC = "hugmesh-tor"
CLIENT_SVC = "hugmesh-tor-client"
GOOD_ONION = "a" * 52 + "bcdd.onion"          # 56 base32 chars + .onion
NEW_ONION = "b" * 52 + "cdee.onion"
STALE_ONION = "c" * 52 + "deff.onion"

RESULTS: list[tuple[str, bool, str]] = []


def check(cid: str, passed: bool, detail: str) -> None:
    RESULTS.append((cid, bool(passed), detail))


def incomplete(msg: str) -> None:
    print("INCOMPLETE %s" % msg, file=sys.stderr)
    sys.exit(3)


for path in (MAKEFILE, COMPOSE, ENTRY, DOCKERFILE, RUNSH, STUDIO_NODE):
    if not os.path.isfile(path):
        incomplete("%s is missing — nothing to grade" % path)
for tool in ("make", "sh", "cmp", "grep", "bash"):
    if shutil.which(tool) is None:
        incomplete("%s is not on PATH" % tool)

makefile_text = open(MAKEFILE, encoding="utf-8").read()
compose_model = yaml.safe_load(open(COMPOSE, encoding="utf-8")) or {}
services = compose_model.get("services") or {}
entry_text = open(ENTRY, encoding="utf-8").read()
WORK = tempfile.mkdtemp(prefix="tor-flip-")


def make_eval(expr: str, extra: list[str], env: dict | None = None) -> str:
    """Expand a make expression exactly as a bring-up would (BEHAVIOUR)."""
    cmd = ["make", "-C", ROOT, "--no-print-directory"] + extra + [
        "--eval=__tor_probe:; @echo \"%s\"" % expr, "__tor_probe"]
    proc = subprocess.run(cmd, capture_output=True, text=True,
                          env=env if env is not None else os.environ.copy())
    if proc.returncode != 0:
        incomplete("make could not expand %s: %s" % (expr, proc.stderr.strip()[:400]))
    return proc.stdout


def clean_env() -> dict:
    env = os.environ.copy()
    for k in ("TOR", "ANUBIS", "TOR_ONION_UPSTREAM", "TOR_ONION_TLS_UPSTREAM",
              "TOR_SOCKS_HOST_PORT", "SNAP_ONION_BASE_URL", "SNAP_PROXY", "E2E_VIA",
              "SNAP_BASE_URL", "SNAP_ENV_DOCKER_BASE_URL", "SNAP_ONION_HOSTNAME_FILE"):
        env.pop(k, None)
    return env


def entry_default(var: str) -> str:
    m = re.search(r'^%s="\$\{[A-Z_]+:-([^}]*)\}"' % re.escape(var), entry_text, re.M)
    if not m:
        incomplete("tests/stack/tor/entrypoint.sh has no `%s=\"${...:-default}\"` line" % var)
    return m.group(1)


def interp_default(value: str, var: str) -> str | None:
    m = re.match(r"^\$\{%s:-(.*)\}$" % re.escape(var), str(value))
    return m.group(1) if m else None


def container_ports(svc: dict) -> list[tuple[str, str, str]]:
    """(host_ip, host_port_expr, container_port) for every short-syntax publish."""
    out = []
    for spec in (svc or {}).get("ports") or []:
        text = str(spec).strip().strip('"')
        m = re.match(r"^(?:(\d+\.\d+\.\d+\.\d+):)?(\$\{[^}]+\}|\d+):(\d+)$", text)
        if m:
            out.append((m.group(1) or "", m.group(2), m.group(3)))
        else:
            out.append(("?", "?", text))
    return out


# ── T1: the knob is DECLARED, not merely consumed ─────────────────────────────
check("T1-declared",
      re.search(r"^TOR\s*\?=", makefile_text, re.M) is not None,
      "Makefile must declare `TOR ?=` beside the other stack knobs (it was consumed "
      "by STACK_TOR_PROFILE while never declared — #586)")

# ── T2: every bring-up selection of the profile is gated on $(TOR) ────────────
profile_lines = [l for l in makefile_text.splitlines()
                 if re.search(r"--profile tor(\s|,|\)|$)", l) and not l.startswith("\t")
                 and not l.lstrip().startswith("#")]
check("T2-profile-gated",
      len(profile_lines) >= 1 and all("$(TOR)" in l for l in profile_lines),
      "every non-teardown `--profile tor` must be gated on $(TOR); found %r" % profile_lines)

# ── T3: behaviour — TOR=1 selects the profile, a plain run does not ───────────
prof_on = make_eval("$(STACK_TOR_PROFILE)", ["TOR=1"], clean_env()).strip()
prof_off = make_eval("$(STACK_TOR_PROFILE)", [], clean_env()).strip()
up_block = makefile_text.split("\nstack-up:", 1)[1].split("\nstack-", 1)[0] \
    if "\nstack-up:" in makefile_text else ""
check("T3-profile-behaviour",
      prof_on == "--profile tor" and prof_off == "" and up_block.count("$(STACK_TOR_PROFILE)") >= 2,
      "make TOR=1 must expand STACK_TOR_PROFILE to `--profile tor` (got %r), a plain "
      "make to nothing (got %r), and stack-up must pass it to BOTH build and up "
      "(found %d)" % (prof_on, prof_off, up_block.count("$(STACK_TOR_PROFILE)")))

# ── T4: STACK_ENV — what TOR=1 (and ANUBIS=1 TOR=1) really export ─────────────
m_port = re.search(r"^TOR_SOCKS_HOST_PORT\s*\?=\s*(\d+)\s*$", makefile_text, re.M)
socks_default = m_port.group(1) if m_port else ""
anubis_target = ""
for name, svc in services.items():
    senv = (svc or {}).get("environment") or {}
    if isinstance(senv, dict) and "anubis" in ((svc or {}).get("profiles") or []) \
            and str(senv.get("BIND", "")).startswith(":"):
        anubis_target = "%s:%s" % (name, str(senv["BIND"])[1:])
if not anubis_target:
    incomplete("no `anubis`-profile compose service declares BIND — the gate cannot be derived")
env_plain = make_eval("$(STACK_ENV)", [], clean_env())
env_tor = make_eval("$(STACK_ENV)", ["TOR=1"], clean_env())
env_both = make_eval("$(STACK_ENV)", ["TOR=1", "ANUBIS=1"], clean_env())
env_anubis = make_eval("$(STACK_ENV)", ["ANUBIS=1"], clean_env())
env_caller = make_eval("$(STACK_ENV)", ["TOR=1", "ANUBIS=1", "TOR_ONION_UPSTREAM=caller:1"],
                       clean_env())
envvar_caller = clean_env()
envvar_caller["TOR_ONION_UPSTREAM"] = "callerenv:2"
env_caller2 = make_eval("$(STACK_ENV)", ["TOR=1", "ANUBIS=1"], envvar_caller)
problems = []
if not socks_default:
    problems.append("no `TOR_SOCKS_HOST_PORT ?= <port>` declaration")
if "TOR_SOCKS_HOST_PORT='%s'" % socks_default not in env_tor:
    problems.append("TOR=1 does not export TOR_SOCKS_HOST_PORT='%s'" % socks_default)
if re.search(r"\bTOR_[A-Z_]+=", env_plain):
    problems.append("a plain bring-up exports a TOR_* variable: %r"
                    % re.findall(r"\bTOR_[A-Z_]+='[^']*'", env_plain))
if "TOR_ONION_UPSTREAM='%s'" % anubis_target not in env_both:
    problems.append("ANUBIS=1 TOR=1 does not point TOR_ONION_UPSTREAM at the gate %s" % anubis_target)
if "TOR_ONION_UPSTREAM='%s'" % anubis_target in env_tor:
    problems.append("TOR=1 alone sends the onion through the Anubis gate")
if "TOR_ONION_UPSTREAM" in env_anubis:
    problems.append("ANUBIS=1 alone exports TOR_ONION_UPSTREAM")
if "TOR_ONION_UPSTREAM='%s'" % anubis_target in env_caller or \
        "TOR_ONION_UPSTREAM='%s'" % anubis_target in env_caller2:
    problems.append("a caller's own TOR_ONION_UPSTREAM (command line or environment) is overridden")
check("T4-env", not problems, "; ".join(problems))

# ── T5: the onion service block ────────────────────────────────────────────────
tor = services.get(ONION_SVC) or {}
tenv = tor.get("environment") or {}
build = tor.get("build") or {}
ctx = build.get("context") if isinstance(build, dict) else build
ctx_dir = os.path.normpath(os.path.join(os.path.dirname(COMPOSE), str(ctx or "")))
up80 = interp_default(tenv.get("TOR_ONION_UPSTREAM", ""), "TOR_ONION_UPSTREAM") \
    if isinstance(tenv, dict) else None
up443 = interp_default(tenv.get("TOR_ONION_TLS_UPSTREAM", ""), "TOR_ONION_TLS_UPSTREAM") \
    if isinstance(tenv, dict) else None
problems = []
if tor.get("profiles") != ["tor"]:
    problems.append("profiles must be exactly [\"tor\"] (OPT-IN), got %r" % tor.get("profiles"))
if not (os.path.isfile(os.path.join(ctx_dir, "Dockerfile"))
        and os.path.isfile(os.path.join(ctx_dir, "entrypoint.sh"))
        and os.path.samefile(ctx_dir, os.path.dirname(ENTRY))):
    problems.append("build context %r is not the tests/stack/tor image" % ctx)


def upstream_ok(default: str | None, name: str, want_tls: bool) -> str:
    if not default or ":" not in default:
        return "%s must be ${%s:-<service>:<port>} interpolation, got %r" % (name, name, default)
    host, port = default.rsplit(":", 1)
    svc = services.get(host)
    if svc is None:
        return "%s defaults to %r, which is not a compose service" % (name, host)
    if svc.get("profiles"):
        return "%s defaults to %r, a PROFILED service a TOR=1 stack may not run" % (name, host)
    if want_tls:
        published = [c for (_ip, _h, c) in container_ports(svc)]
        if port not in published:
            return ("%s defaults to %s:%s but that service publishes container ports %r — "
                    "not the TLS door" % (name, host, port, published))
    return ""


for msg in (upstream_ok(up80, "TOR_ONION_UPSTREAM", False),
            upstream_ok(up443, "TOR_ONION_TLS_UPSTREAM", True)):
    if msg:
        problems.append(msg)
if up80 and up80 != entry_default("UPSTREAM"):
    problems.append("compose's TOR_ONION_UPSTREAM default %r disagrees with the entrypoint's %r"
                    % (up80, entry_default("UPSTREAM")))
if up443 and up443 != entry_default("TLS_UPSTREAM"):
    problems.append("compose's TOR_ONION_TLS_UPSTREAM default %r disagrees with the entrypoint's %r"
                    % (up443, entry_default("TLS_UPSTREAM")))
check("T5-onion-service", not problems, "; ".join(problems))

# ── T6: both upstreams exist before tor parses its torrc ──────────────────────
deps = tor.get("depends_on") or {}
dep_names = set(deps) if isinstance(deps, (dict, list)) else set()
need = {u.rsplit(":", 1)[0] for u in (up80, up443) if u and ":" in u}
check("T6-depends-on-upstreams",
      bool(need) and need <= dep_names,
      "tor resolves HiddenServicePort hostnames ONCE, at torrc parse — %s must "
      "depends_on %s; has %s" % (ONION_SVC, sorted(need), sorted(dep_names)))

# ── T7: key custody + the published hostname's path ───────────────────────────
data_dir = entry_default("DATA_DIR")
out_dir = entry_default("OUT_DIR")
hs_dir = data_dir.rstrip("/") + "/hugmesh-onion"
vols = [str(v) for v in (tor.get("volumes") or [])]
named = [v for v in vols if not v.startswith(".") and not v.startswith("/")]
binds = [v for v in vols if v.startswith(".")]
top_vols = set((compose_model.get("volumes") or {}).keys())
studio_text = open(STUDIO_NODE, encoding="utf-8").read()
m_studio = re.search(r'_TOR_ONION_HOSTNAME_FILE\s*=\s*os\.path\.join\(([^)]*)\)', studio_text)
studio_parts = re.findall(r'"([^"]+)"', m_studio.group(1)) if m_studio else []
studio_rel = "/".join(studio_parts)
m_mk_file = re.search(r"^STACK_ONION_FILE\s*:?=\s*(\S+)\s*$", makefile_text, re.M)
problems = []
key_mounts = [v for v in named if v.split(":")[1:2] == [hs_dir]]
if not key_mounts:
    problems.append("no named volume is mounted at the HiddenServiceDir %s (the key would die "
                    "with the container and the onion change on every restart): %r" % (hs_dir, named))
elif key_mounts[0].split(":")[0] not in top_vols:
    problems.append("key volume %r is not declared under top-level volumes:" % key_mounts[0])
bind_out = [v for v in binds if v.split(":")[1:2] == [out_dir]]
if not bind_out:
    problems.append("nothing binds the entrypoint's OUT_DIR %s to the host: %r" % (out_dir, binds))
else:
    host_rel = os.path.normpath(os.path.join("tests/stack", bind_out[0].split(":")[0]))
    if not studio_rel or os.path.normpath(os.path.dirname(studio_rel)) != host_rel:
        problems.append("the host side %s is not where the Studio reads the onion (%s)"
                        % (host_rel, studio_rel or "<no _TOR_ONION_HOSTNAME_FILE>"))
    if not m_mk_file or os.path.normpath(m_mk_file.group(1)) != os.path.join(host_rel, "hostname"):
        problems.append("Makefile STACK_ONION_FILE %r is not %s/hostname"
                        % (m_mk_file.group(1) if m_mk_file else None, host_rel))
check("T7-custody-and-readout", not problems, "; ".join(problems))


# ── the entrypoint sandbox: a stub tor + a stub chown ─────────────────────────
def write_exe(path: str, body: str) -> None:
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(body)
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


STUB_TOR = r'''#!/bin/sh
# stub tor: honour -f, mint the configured onion, log bootstrap, then idle or die.
[ "$1" = "-f" ] || { echo "stub tor: expected -f <torrc>, got $*" >&2; exit 64; }
torrc="$2"
hs="$(sed -n 's/^HiddenServiceDir //p' "$torrc")"
log="$(sed -n 's/^Log notice file //p' "$torrc")"
if [ -n "${STUB_OUT:-}" ] && [ -f "$STUB_OUT/hostname" ]; then
  cp "$STUB_OUT/hostname" "$STUB_SEEN" 2>/dev/null || true
fi
if [ -n "$hs" ]; then sleep 0.3; echo "$STUB_ONION" > "$hs/hostname"; fi
[ -n "$log" ] && echo "[notice] Bootstrapped 100% (done): Done" >> "$log"
if [ -n "${STUB_DIE:-}" ]; then sleep 1.5; exit "$STUB_DIE"; fi
trap 'exit 0' TERM INT
while :; do sleep 0.1; done
'''


def sandbox(tag: str) -> dict:
    sb = os.path.join(WORK, tag)
    for d in ("bin", "data", "out"):
        os.makedirs(os.path.join(sb, d), exist_ok=True)
    write_exe(os.path.join(sb, "bin", "tor"), STUB_TOR)
    write_exe(os.path.join(sb, "bin", "chown"), "#!/bin/sh\nexit 0\n")
    env = clean_env()
    env.update({
        "PATH": os.path.join(sb, "bin") + os.pathsep + env.get("PATH", ""),
        "HUGMESH_TOR_DATA_DIR": os.path.join(sb, "data"),
        "HUGMESH_TOR_OUT_DIR": os.path.join(sb, "out"),
        "HUGMESH_TOR_TORRC": os.path.join(sb, "torrc"),
        "HUGMESH_TOR_BIN": os.path.join(sb, "bin", "tor"),
        "STUB_OUT": os.path.join(sb, "out"),
        "STUB_SEEN": os.path.join(sb, "seen-at-tor-start"),
        "STUB_ONION": NEW_ONION,
        "TOR_ONION_UPSTREAM": "up80.test:8080",
        "TOR_ONION_TLS_UPSTREAM": "up443.test:8443",
    })
    return {"dir": sb, "env": env}


def wait_for(pred, timeout: float) -> bool:
    end = time.time() + timeout
    while time.time() < end:
        if pred():
            return True
        time.sleep(0.05)
    return pred()


def read(path: str) -> str:
    try:
        return open(path, encoding="utf-8").read().strip()
    except OSError:
        return ""


# ── T10: the readout never outlives the container (#581) ─────────────────────
problems = []
sb = sandbox("t10-stop")
with open(os.path.join(sb["dir"], "out", "hostname"), "w") as fh:
    fh.write(STALE_ONION + "\n")
proc = subprocess.Popen(["sh", ENTRY], env=sb["env"], stdout=subprocess.PIPE,
                        stderr=subprocess.STDOUT, text=True)
out_file = os.path.join(sb["dir"], "out", "hostname")
published = wait_for(lambda: read(out_file) == NEW_ONION, 6.0)
seen = read(os.path.join(sb["dir"], "seen-at-tor-start"))
torrc = read(os.path.join(sb["dir"], "torrc"))
if seen:
    problems.append("a previous run's hostname (%s) was still published when tor started — "
                    "every reader in that window announces a dead onion" % seen)
if not published:
    problems.append("the minted hostname was never published to OUT_DIR (have %r)" % read(out_file))
for want in ("HiddenServicePort 80 up80.test:8080", "HiddenServicePort 443 up443.test:8443",
             "HiddenServiceVersion 3", "SocksPort 0"):
    if want not in torrc.splitlines():
        problems.append("onion torrc lacks `%s`" % want)
proc.terminate()
try:
    rc = proc.wait(timeout=8)
except subprocess.TimeoutExpired:
    proc.kill()
    rc = -999
if rc != 0:
    problems.append("SIGTERM (compose stop) exited %s, not 0" % rc)
if os.path.exists(out_file):
    problems.append("the hostname survived a stop — `stack-halt`/`stack-down` would leave "
                    "the Studio announcing an onion nobody serves")
sb2 = sandbox("t10-crash")
sb2["env"]["STUB_DIE"] = "7"
p2 = subprocess.run(["sh", ENTRY], env=sb2["env"], capture_output=True, text=True, timeout=30)
if p2.returncode != 7:
    problems.append("a tor that died rc=7 made the entrypoint exit %s (the status must pass "
                    "through so compose's restart policy sees the crash)" % p2.returncode)
if os.path.exists(os.path.join(sb2["dir"], "out", "hostname")):
    problems.append("the hostname survived tor dying on its own")
sb3 = sandbox("t10-role")
sb3["env"]["HUGMESH_TOR_ROLE"] = "relay"
p3 = subprocess.run(["sh", ENTRY], env=sb3["env"], capture_output=True, text=True, timeout=30)
if p3.returncode == 0:
    problems.append("an unknown HUGMESH_TOR_ROLE was accepted")
check("T10-readout-lifecycle", not problems, "; ".join(problems))


# ── T8: the healthchecks, EXECUTED against a sandbox ──────────────────────────
def run_health(svc_name: str, sbx: dict) -> int | None:
    test = ((services.get(svc_name) or {}).get("healthcheck") or {}).get("test")
    if not (isinstance(test, list) and len(test) == 2 and test[0] == "CMD-SHELL"):
        return None
    cmd = str(test[1])
    # Longest path first: /var/lib/tor/hugmesh-onion lives under /var/lib/tor.
    cmd = cmd.replace(out_dir, os.path.join(sbx["dir"], "out"))
    cmd = cmd.replace(data_dir, os.path.join(sbx["dir"], "data"))
    return subprocess.run(["sh", "-c", cmd], capture_output=True, timeout=10).returncode


def health_state(tag: str, hs_name: str | None, out_name: str | None, booted: bool) -> dict:
    sbx = sandbox(tag)
    os.makedirs(os.path.join(sbx["dir"], "data", "hugmesh-onion"), exist_ok=True)
    if hs_name:
        open(os.path.join(sbx["dir"], "data", "hugmesh-onion", "hostname"), "w").write(hs_name + "\n")
    if out_name:
        open(os.path.join(sbx["dir"], "out", "hostname"), "w").write(out_name + "\n")
    open(os.path.join(sbx["dir"], "data", "notice.log"), "w").write(
        "[notice] Bootstrapped 100% (done): Done\n" if booted else "[notice] Bootstrapped 45%\n")
    return sbx


problems = []
cases = [
    ("published+booted", GOOD_ONION, GOOD_ONION, True, True),
    ("nothing published", GOOD_ONION, None, True, False),
    ("a DIFFERENT onion published (stale file)", GOOD_ONION, STALE_ONION, True, False),
    ("tor not bootstrapped", GOOD_ONION, GOOD_ONION, False, False),
]
for i, (label, hs_name, out_name, booted, want_ok) in enumerate(cases):
    rc = run_health(ONION_SVC, health_state("t8-%d" % i, hs_name, out_name, booted))
    if rc is None:
        problems.append("%s has no CMD-SHELL healthcheck" % ONION_SVC)
        break
    if (rc == 0) != want_ok:
        problems.append("%s healthcheck with %s -> rc=%s (want %s)"
                        % (ONION_SVC, label, rc, "0" if want_ok else "non-zero"))
for i, (label, booted, want_ok) in enumerate([("bootstrapped", True, True),
                                               ("not bootstrapped", False, False)]):
    rc = run_health(CLIENT_SVC, health_state("t8c-%d" % i, None, None, booted))
    if rc is None:
        problems.append("%s has no CMD-SHELL healthcheck" % CLIENT_SVC)
        break
    if (rc == 0) != want_ok:
        problems.append("%s healthcheck %s -> rc=%s" % (CLIENT_SVC, label, rc))
check("T8-healthchecks", not problems, "; ".join(problems))

# ── T9: the SOCKS client is loopback-only, on the lane's port, not open ───────
client = services.get(CLIENT_SVC) or {}
cenv = client.get("environment") or {}
problems = []
if client.get("profiles") != ["tor"]:
    problems.append("%s profiles must be exactly [\"tor\"], got %r" % (CLIENT_SVC, client.get("profiles")))
cb = client.get("build") or {}
cctx = cb.get("context") if isinstance(cb, dict) else cb
if os.path.normpath(os.path.join(os.path.dirname(COMPOSE), str(cctx or ""))) != ctx_dir:
    problems.append("%s is not built from the same tests/stack/tor image" % CLIENT_SVC)
role = str(cenv.get("HUGMESH_TOR_ROLE", "")) if isinstance(cenv, dict) else ""
sbc = sandbox("t9-client")
sbc["env"]["HUGMESH_TOR_ROLE"] = role or "onion"
sbc["env"]["STUB_DIE"] = "0"    # the client role execs tor; the stub must return
pc = subprocess.run(["sh", ENTRY], env=sbc["env"], capture_output=True, text=True, timeout=30) \
    if role == "client" else None
if role != "client":
    problems.append("%s does not select the client role (HUGMESH_TOR_ROLE=%r)" % (CLIENT_SVC, role))
ctorrc = read(os.path.join(sbc["dir"], "torrc")).splitlines()
socks = [l.split()[1] for l in ctorrc if l.startswith("SocksPort ")]
policies = [l for l in ctorrc if l.startswith("SocksPolicy ")]
if role == "client":
    if not socks or socks[0] in ("0",) or ":" not in socks[0]:
        problems.append("client torrc SocksPort is %r" % socks)
    if not policies or policies[-1].strip() != "SocksPolicy reject *":
        problems.append("client torrc must END its SocksPolicy with `reject *` (else an open "
                        "proxy on every interface it listens on): %r" % policies)
    if any(l.startswith("HiddenService") for l in ctorrc):
        problems.append("the client role also serves an onion")
socks_port = socks[0].rsplit(":", 1)[1] if socks and ":" in socks[0] else ""
pubs = container_ports(client)
if not pubs:
    problems.append("%s publishes nothing — the e2e browser cannot reach it" % CLIENT_SVC)
for ip, host_expr, cport in pubs:
    if ip != "127.0.0.1":
        problems.append("%s publishes %s on %r — not loopback-only (an open Tor proxy for "
                        "the LAN)" % (CLIENT_SVC, cport, ip or "0.0.0.0"))
    if cport != socks_port:
        problems.append("%s publishes container port %s but tor listens on %s"
                        % (CLIENT_SVC, cport, socks_port))
    hd = interp_default(host_expr, "TOR_SOCKS_HOST_PORT")
    if hd != socks_default:
        problems.append("%s host port %r is not ${TOR_SOCKS_HOST_PORT:-%s} (the Makefile default)"
                        % (CLIENT_SVC, host_expr, socks_default))
check("T9-socks-client", not problems, "; ".join(problems))

# ── T11: teardown reaps the profile whatever the bring-up knobs were ──────────
problems = []
for target in ("stack-halt", "stack-down", "stack-clean"):
    blk = makefile_text.split("\n%s:" % target, 1)
    if len(blk) != 2:
        problems.append("no %s target" % target)
        continue
    body = blk[1].split("\n\n", 1)[0]
    recipe = [l for l in body.splitlines() if l.startswith("\t") and "down" in l
              and "$(COMPOSE_CMD)" in l]
    if not recipe or not all("--profile tor " in l for l in recipe):
        problems.append("%s's compose down does not carry `--profile tor` unconditionally" % target)
check("T11-teardown-reaps", not problems, "; ".join(problems))

# ── T12: `make stack-e2e-tor` -> run.sh --via onion, planned (nothing executed) ─
problems = []
e2e_blk = makefile_text.split("\nstack-e2e-tor:", 1)
e2e_recipe = e2e_blk[1].split("\n\n", 1)[0] if len(e2e_blk) == 2 else ""
if "tests/e2e/run.sh" not in e2e_recipe or "--via onion" not in e2e_recipe:
    problems.append("stack-e2e-tor does not run tests/e2e/run.sh --via onion")
sbr = sandbox("t12-runsh")
write_exe(os.path.join(sbr["dir"], "bin", "node"), "#!/bin/sh\ncat\n")   # plan lines verbatim
write_exe(os.path.join(sbr["dir"], "bin", "npx"), "#!/bin/sh\nexit 97\n")  # nothing runs
write_exe(os.path.join(sbr["dir"], "bin", "docker"), "#!/bin/sh\nexit 1\n")
hostfile = os.path.join(sbr["dir"], "hostname")
open(hostfile, "w").write(GOOD_ONION + "\n")
renv = dict(sbr["env"], SNAP_ONION_HOSTNAME_FILE=hostfile, E2E_PASSWORD="x")
pr = subprocess.run(["bash", RUNSH, "--via", "onion", "--print-command"], env=renv,
                    capture_output=True, text=True, timeout=60)
plan: dict[str, list[str]] = {}
for line in pr.stdout.splitlines():
    if "\t" in line:
        k, v = line.split("\t", 1)
        plan.setdefault(k, []).append(v)
first = lambda k: (plan.get(k) or [""])[0]  # noqa: E731
if pr.returncode != 0:
    problems.append("run.sh --via onion --print-command exited %s: %s"
                    % (pr.returncode, (pr.stderr or pr.stdout)[-300:]))
else:
    if first("ENV_ID") != "docker":
        problems.append("--via onion does not select --env docker (got %r)" % first("ENV_ID"))
    if ".onion" in first("BASE_URL"):
        problems.append("SNAP_BASE_URL was pointed at the onion (%s): the @env:docker probe is "
                        "an UNPROXIED Node request and would skip every scenario" % first("BASE_URL"))
    if first("ONION_BASE_URL") != "https://" + GOOD_ONION:
        problems.append("onion URL is %r, want https://<onion> (an http entry is upgraded by "
                        "the gateway CSP and boots nothing)" % first("ONION_BASE_URL"))
    if first("PROXY") != "socks5://127.0.0.1:%s" % socks_default:
        problems.append("default proxy %r is not the tor-client's socks5://127.0.0.1:%s"
                        % (first("PROXY"), socks_default))
    if "@via:onion" not in first("TAGS"):
        problems.append("tags %r do not restrict the run to @via:onion" % first("TAGS"))
    if "--project=bdd" not in (plan.get("ARGV") or []):
        problems.append("the run is not the Gherkin project")
ps_ = subprocess.run(["bash", RUNSH, "--via", "onion"], env=renv, capture_output=True,
                     text=True, timeout=60)
if ps_.returncode != 2 or "stale" not in ps_.stderr:
    problems.append("a RUN against a hostname no running hugmesh-tor serves (docker answers, "
                    "nothing running) exited %s, want 2 naming the stale readout: %s"
                    % (ps_.returncode, (ps_.stderr or ps_.stdout)[-200:]))
os.remove(hostfile)
pm = subprocess.run(["bash", RUNSH, "--via", "onion"], env=renv, capture_output=True,
                    text=True, timeout=60)
if pm.returncode != 2 or "make stack-up TOR=1" not in pm.stderr:
    problems.append("a RUN with no onion published exited %s (want 2 naming `make stack-up "
                    "TOR=1`): %s" % (pm.returncode, (pm.stderr or "")[-200:]))
check("T12-e2e-lane", not problems, "; ".join(problems))

# ── T13: `make stack-onion` prints only a well-formed, served onion ───────────
problems = []
sbo = sandbox("t13-onion")
write_exe(os.path.join(sbo["dir"], "bin", "docker"),
          '#!/bin/sh\n[ "${STUB_RUNNING:-}" = 1 ] && echo 0123456789ab\nexit 0\n')
ofile = os.path.join(sbo["dir"], "onion-hostname")


def stack_onion(content: str | None, running: str) -> tuple[int, str]:
    if content is None:
        if os.path.exists(ofile):
            os.remove(ofile)
    else:
        open(ofile, "w").write(content)
    env = dict(sbo["env"], STUB_RUNNING=running)
    p = subprocess.run(["make", "-C", ROOT, "--no-print-directory", "stack-onion",
                        "STACK_ONION_FILE=%s" % ofile], env=env, capture_output=True,
                       text=True, timeout=60)
    return p.returncode, p.stdout.strip()


for label, content, running, want in [
        ("served", GOOD_ONION + "\n", "1", "https://%s/" % GOOD_ONION),
        ("absent", None, "1", None),
        ("stale (container not running)", GOOD_ONION + "\n", "0", None),
        ("malformed", "evil$(id).onion\n", "1", None),
        ("short", GOOD_ONION[1:] + "\n", "1", None),
        ("not an onion", "example.com\n", "1", None)]:
    rc, out = stack_onion(content, running)
    if want is None and (rc == 0 or ".onion" in out):
        problems.append("stack-onion printed %r (rc=%s) for the %s case" % (out, rc, label))
    if want is not None and (rc != 0 or out.splitlines()[-1:] != [want]):
        problems.append("stack-onion for the %s case -> rc=%s %r, want %r" % (label, rc, out, want))
check("T13-stack-onion", not problems, "; ".join(problems))

shutil.rmtree(WORK, ignore_errors=True)

failed = 0
for cid, passed, detail in sorted(RESULTS, key=lambda r: int(re.match(r"T(\d+)", r[0]).group(1))):
    print("%s %s%s" % ("PASS" if passed else "FAIL", cid, "" if passed else " — " + detail))
    failed += 0 if passed else 1
print("-- %d check(s), %d failed" % (len(RESULTS), failed))
sys.exit(1 if failed else 0)
