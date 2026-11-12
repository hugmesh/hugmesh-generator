#!/bin/sh
# collect.sh GUEST OUTDIR — host facts for one BSD or SunOS guest (hugmesh-generator#1048).
#
# Runs INSIDE a VM-action guest, from the root of the synced checkout, under the
# guest's own /bin/sh (the VM actions always run `run:` with sh; several of these
# guests have no bash). Driven only by .github/workflows/guest-host-facts.yml, which
# is workflow_dispatch only. It never changes Studio code and never builds anything.
#
# What it records, in this order, each probe as its own file under OUTDIR:
#   1. facts: uname -a/-o/-p/-m/-r/-s, isainfo -k, /etc/release, sysctl hw,
#      the installed package list, which Python interpreters exist;
#   2. the STOCK `--self-check` (before anything is installed);
#   3. every candidate install line for Python 3.11+, urwid, PySide6 and PyQt6,
#      with its return code and whether the module then imports;
#   4. a venv with --system-site-packages (the design's install path), pytest in it;
#   5. `--self-check` again with whatever got installed;
#   6. a scripted plain-text-UI session and a printed build command, with every
#      child argv the Studio spawned logged (tests/guest-facts/argv_session.py);
#   7. the named-file contract sizing run (tests/guest-facts/size_contract.py).
#
# A failing probe is DATA, never an abort: `uname -o` does not exist on OpenBSD,
# `isainfo` exists only on SunOS, `sysctl` does not exist on Solaris. Every probe
# records its command line, its output and `rc=N`, and one row in probes.tsv.
# The script always exits 0 so the VM action copies OUTDIR back to the runner.
#
# It reads no knob from the environment: the workflow sets no `envs:`, so nothing a
# person could set on the runner reaches this script (only GITHUB_* and CI do).
set -u

guest=${1:-} out=${2:-}
if [ -z "$guest" ] || [ -z "$out" ]; then
  echo "usage: collect.sh GUEST OUTDIR" >&2; exit 0
fi
repo=$(pwd)
mkdir -p "$out" || exit 0
out=$(cd "$out" && pwd)
work="${TMPDIR:-/tmp}/guest-facts.$$"
mkdir -p "$work"

case "$guest" in
  freebsd|openbsd|netbsd|dragonfly) family=bsd ;;
  solaris|omnios|openindiana) family=sunos ;;
  *) echo "collect.sh: unknown guest '$guest'" >&2; exit 0 ;;
esac

# Throwaway Studio state: nothing the Studio writes may land in OUTDIR or in the
# guest user's real home.
HUGMESH_STUDIO_STATE_DIR="$work/studio-state"
HUGMESH_LOCAL_AI_DIR="$work/local-ai"
HUGMESH_VIEW_STATE="$work/view-state"
HUGMESH_STUDIO_NO_ELEVATION=1
NO_TUI=1
ASSUME_ALWAYS_YES=yes          # FreeBSD/DragonFly pkg: bootstrap and install without asking
export HUGMESH_STUDIO_STATE_DIR HUGMESH_LOCAL_AI_DIR HUGMESH_VIEW_STATE \
       HUGMESH_STUDIO_NO_ELEVATION NO_TUI ASSUME_ALWAYS_YES
PATH="$PATH:/usr/local/bin:/usr/local/sbin:/usr/pkg/bin:/usr/pkg/sbin:/opt/ooce/bin:/usr/gnu/bin"
export PATH

printf 'probe\trc\tseconds\n' > "$out/probes.tsv"

# probe NAME CMD [ARG...] — run one command, never abort.
probe() {
  _name=$1; shift
  _f="$out/$_name.txt"
  { printf '$'; for _a in "$@"; do printf ' %s' "$_a"; done; printf '\n'; } > "$_f"
  _t0=$(date +%s)
  "$@" >> "$_f" 2>&1 < /dev/null
  _rc=$?
  _t1=$(date +%s)
  printf 'rc=%s\n' "$_rc" >> "$_f"
  printf '%s\t%s\t%s\n' "$_name" "$_rc" "$((_t1 - _t0))" >> "$out/probes.tsv"
  return "$_rc"
}

# as_root CMD... — the VM actions log in as root; record it if one does not.
as_root() {
  if [ "$(id -u)" = 0 ]; then "$@"
  elif command -v sudo >/dev/null 2>&1; then sudo -n "$@"
  elif command -v doas >/dev/null 2>&1; then doas -n "$@"
  elif command -v pfexec >/dev/null 2>&1; then pfexec "$@"
  else echo "collect.sh: not root and no sudo/doas/pfexec" >&2; return 126
  fi
}

# ── 1. facts ──────────────────────────────────────────────────────────────────
probe id id
probe uname-a uname -a
probe uname-o uname -o
probe uname-p uname -p
probe uname-m uname -m
probe uname-r uname -r
probe uname-s uname -s
probe uname-v uname -v
probe isainfo-k isainfo -k
probe etc-release cat /etc/release
probe os-release cat /etc/os-release
probe freebsd-version freebsd-version -ku
probe sysctl-hw sysctl hw
probe meminfo-path ls -l /proc/meminfo
probe pythons sh -c 'for d in /usr/local/bin /usr/pkg/bin /usr/bin /opt/ooce/bin /opt/local/bin; do ls -1 "$d"/python* 2>/dev/null; done; command -v python3 && python3 -V'
case "$guest" in
  freebsd|dragonfly)
    probe pkg-version as_root pkg -v
    probe packages-stock pkg info ;;
  openbsd)
    probe pkg-installurl cat /etc/installurl
    probe packages-stock pkg_info ;;
  netbsd)
    probe pkg-repositories cat /usr/pkg/etc/pkgin/repositories.conf
    probe packages-stock pkg_info ;;
  *)
    probe pkg-publishers pkg publisher
    probe packages-stock pkg list ;;
esac

# ── 2. the stock --self-check, before anything is installed ────────────────────
# Whatever `python3` the guest ships (none at all is a valid answer, rc 127).
probe selfcheck-stock sh -c 'cd studio && exec python3 -m hugmesh_studio --self-check --generator-dir ..'

# ── 3. install lines ──────────────────────────────────────────────────────────
# install.tsv: component, kind (static|search|pip), rc of the install line, whether
# the module then imports with the chosen interpreter (yes|no), the exact line.
printf 'component\tkind\tinstall_rc\timports\tline\n' > "$out/install.tsv"
n_try=0

# Catalog search terms, one per component. A term has to match the package names the
# static lines use. FreeBSD ports name PyQt6 py3NN-qt6-pyqt (devel/py-qt6-pyqt:
# PKGNAMEPREFIX py3NN-qt6-, PORTNAME pyqt), so `pyqt6` would miss it; DragonFly's
# DPorts derive from those ports. The OpenBSD and NetBSD terms are not yet checked
# against their catalogs; the recorded search output is what settles them.
case "$guest" in
  freebsd|dragonfly) t_urwid=urwid t_pyside=pyside6 t_pyqt=qt6-pyqt ;;
  openbsd|netbsd)    t_urwid=urwid t_pyside=pyside6 t_pyqt=qt6 ;;
  *)                 t_urwid=urwid t_pyside=pyside6 t_pyqt=pyqt6 ;;
esac

find_python() {
  # The newest python3.N with N >= 11 in the usual prefixes (ports, pkgsrc, IPS, ooce).
  # 3.11 is the floor issue #1048 asks about. The Studio itself declares >=3.10, but a
  # 3.10 floor would record a guest's stock 3.10 as "preinstalled" and its 3.11+ lines
  # would never run, so no 3.10 line is offered either: it could never count.
  _best="" _bm=0
  for _d in /usr/local/bin /usr/pkg/bin /usr/bin /opt/ooce/bin /opt/local/bin; do
    for _p in "$_d"/python3.[0-9] "$_d"/python3.[0-9][0-9]; do
      [ -x "$_p" ] || continue
      _m=${_p##*python3.}
      [ "$_m" -ge 11 ] 2>/dev/null || continue
      if [ "$_m" -gt "$_bm" ]; then _best=$_p _bm=$_m; fi
    done
  done
  [ -n "$_best" ] && echo "$_best"
}

# imports MODULE — does the chosen interpreter import it now?
imports() {
  [ -n "${py:-}" ] || return 1
  "$py" -c "import $1" > /dev/null 2>&1
}

# try_line COMPONENT KIND MODULE LINE — run one install line as root, record it.
# MODULE "" means "re-resolve the interpreter" (the python component itself).
try_line() {
  _comp=$1 _kind=$2 _mod=$3 _line=$4
  n_try=$((n_try + 1))
  probe "install-$n_try-$_comp" as_root sh -c "$_line"
  _irc=$?
  if [ -z "$_mod" ]; then
    py=$(find_python) || py=""
    if [ -n "$py" ]; then _ok=yes; else _ok=no; fi
  elif imports "$_mod"; then _ok=yes
  else _ok=no
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$_comp" "$_kind" "$_irc" "$_ok" "$_line" >> "$out/install.tsv"
  [ "$_ok" = yes ]
}

# search COMPONENT TERM — package names the OS catalog offers, recorded verbatim.
search() {
  _comp=$1 _term=$2
  case "$guest" in
    freebsd|dragonfly) probe "search-$_comp" pkg search -q "$_term" ;;
    openbsd) probe "search-$_comp" pkg_info -Q "$_term" ;;
    netbsd) probe "search-$_comp" pkgin search "$_term" ;;
    *) probe "search-$_comp" pkg search -H -o pkg.name "*$_term*" ;;
  esac
  [ $? -eq 0 ] || return 0      # a search that failed offers no package names
  # first column of each hit line, minus the recorded command line, the rc line and
  # pkgin's "=: package is installed" legend
  sed -n '2,$p' "$out/search-$_comp.txt" | grep -v '^rc=' | grep '^[A-Za-z0-9]' | awk '{print $1}' | head -n 6
}

# install COMPONENT MODULE TERM STATIC_LINE... — static lines first, then lines
# built from what the catalog search returned; stop at the first that imports.
install() {
  _c=$1 _m=$2 _t=$3; shift 3
  if [ -n "$_m" ] && imports "$_m"; then
    printf '%s\tpreinstalled\t0\tyes\t(already importable)\n' "$_c" >> "$out/install.tsv"
    return 0
  fi
  for _l in "$@"; do try_line "$_c" static "$_m" "$_l" && return 0; done
  for _p in $(search "$_c" "$_t"); do
    case "$guest" in
      freebsd|dragonfly) _l="pkg install -y $_p" ;;
      openbsd) _l="pkg_add -I $_p" ;;
      netbsd) _l="pkgin -y install $_p" ;;
      *) _l="pkg install --accept $_p" ;;
    esac
    try_line "$_c" search "$_m" "$_l" && return 0
  done
  return 1
}

py=$(find_python) || py=""
if [ -n "$py" ]; then
  printf 'python\tpreinstalled\t0\tyes\t%s\n' "$py" >> "$out/install.tsv"
else
  case "$guest" in
    freebsd)   install python "" python3 "pkg install -y python311" "pkg install -y python312" ;;
    dragonfly) install python "" python3 "pkg install -y python311" "pkg install -y python312" ;;
    openbsd)   install python "" python "pkg_add -I python%3.12" "pkg_add -I python%3.13" "pkg_add -I python%3.11" ;;
    netbsd)    install python "" python3 "pkgin -y install python312" "pkgin -y install python313" "pkgin -y install python311" ;;
    solaris)   install python "" python-31 "pkg install --accept runtime/python-311" "pkg install --accept runtime/python-313" ;;
    *)         install python "" python-31 "pkg install runtime/python-313" "pkg install runtime/python-312" "pkg install runtime/python-311" ;;
  esac
  py=$(find_python) || py=""
fi
if [ -n "$py" ]; then
  pyv=$("$py" -c 'import sys; print("%d%d" % sys.version_info[:2])')
  pydot=$("$py" -c 'import sys; print("%d.%d" % sys.version_info[:2])')
else
  pyv="" pydot=""
fi
probe python-chosen sh -c "echo '$py'; ${py:-false} -VV"

if [ -n "$py" ]; then
  case "$guest" in
    freebsd|dragonfly)
      install urwid urwid "$t_urwid" "pkg install -y py$pyv-urwid"
      install pyside6 PySide6 "$t_pyside" "pkg install -y py$pyv-pyside6"
      install pyqt6 PyQt6 "$t_pyqt" "pkg install -y py$pyv-qt6-pyqt" "pkg install -y py$pyv-pyqt6" ;;
    openbsd)
      install urwid urwid "$t_urwid" "pkg_add -I py3-urwid"
      install pyside6 PySide6 "$t_pyside" "pkg_add -I py3-pyside6"
      install pyqt6 PyQt6 "$t_pyqt" "pkg_add -I py3-qt6" "pkg_add -I py3-PyQt6" ;;
    netbsd)
      install urwid urwid "$t_urwid" "pkgin -y install py$pyv-urwid"
      install pyside6 PySide6 "$t_pyside" "pkgin -y install py$pyv-pyside6"
      install pyqt6 PyQt6 "$t_pyqt" "pkgin -y install py$pyv-qt6" "pkgin -y install py$pyv-PyQt6" ;;
    *)
      # SunOS: the design expects no Qt 6 binding and urwid from pip. The catalog
      # searches are what make "not packaged" a measured statement.
      install urwid urwid "$t_urwid" "pkg install library/python/urwid-$pyv"
      install pyside6 PySide6 "$t_pyside"
      install pyqt6 PyQt6 "$t_pyqt" ;;
  esac
else
  # No Python 3.11+: nothing could import a module, so no line is tried (install.tsv
  # has no urwid/PySide6/PyQt6 rows and the summary says NOT TRIED). The catalog
  # searches still run, so what the OS offers is on record, not assumed.
  search urwid "$t_urwid" > /dev/null
  search pyside6 "$t_pyside" > /dev/null
  search pyqt6 "$t_pyqt" > /dev/null
fi

# ── 4. the venv (--system-site-packages, so the OS packages above are visible) ──
venv="$work/venv"
vpy=""
if [ -n "$py" ]; then
  if probe venv "$py" -m venv --system-site-packages "$venv"; then
    vpy="$venv/bin/python"
  fi
fi
if [ -n "$vpy" ]; then
  # urwid from pip only when the OS line above did not provide it (the SunOS path).
  if ! "$vpy" -c 'import urwid' > /dev/null 2>&1; then
    probe pip-urwid "$vpy" -m pip install urwid
    if "$vpy" -c 'import urwid' > /dev/null 2>&1; then _ok=yes; else _ok=no; fi
    printf 'urwid\tpip\t%s\t%s\t%s\n' "$(sed -n 's/^rc=//p' "$out/pip-urwid.txt")" "$_ok" \
      "python$pydot -m venv --system-site-packages VENV && VENV/bin/python -m pip install urwid" >> "$out/install.tsv"
  fi
  # The Qt-free suite's own install line (studio-tests.yml), binary wheels first so a
  # missing wheel is a fast recorded failure, not a long native build.
  probe pip-test-deps "$vpy" -m pip install pytest PyYAML
  probe pip-jsonschema-binary "$vpy" -m pip install --only-binary=:all: jsonschema
  "$vpy" -c 'import jsonschema' > /dev/null 2>&1 || probe pip-jsonschema-pure "$vpy" -m pip install 'jsonschema<4.18'
  probe pip-cryptography-binary "$vpy" -m pip install --only-binary=:all: cryptography
  probe venv-freeze "$vpy" -m pip freeze
fi
spy=${vpy:-$py}
probe imports sh -c "for m in urwid PySide6 PyQt6 pytest yaml jsonschema cryptography; do if ${spy:-false} -c \"import \$m\" >/dev/null 2>&1; then echo \"\$m yes\"; else echo \"\$m no\"; fi; done"

# ── 5. --self-check with what got installed ───────────────────────────────────
if [ -n "$spy" ]; then
  probe selfcheck-installed sh -c "cd studio && exec '$spy' -m hugmesh_studio --self-check --generator-dir .."
fi

# ── 6. scripted plain-text-UI session + printed command, every child argv logged ─
if [ -n "$spy" ]; then
  probe argv-session "$spy" tests/guest-facts/argv_session.py --repo "$repo" --out "$out/session"
fi

# ── 7. contract sizing (the candidate list is computed on the runner) ──────────
if [ -n "$vpy" ] && [ -f "$out/contract-candidates.txt" ]; then
  probe contract-sizing "$vpy" tests/guest-facts/size_contract.py run \
    --repo "$repo" --list "$out/contract-candidates.txt" --out "$out/contract-sizing.tsv" \
    --budget 2400
fi

rm -rf "$work"
exit 0
