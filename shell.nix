# shell.nix — `nix-shell` (non-flake) parity with flake.nix's devShells.default.
#
# Operators without flakes enabled get the SAME toolchain — python3 + PySide6, make,
# whiptail/newt, dialog, the Qt6 Wayland plugin — and the SAME PYTHONPATH=$PWD/studio
# shellHook, so ./scripts/studio-launch.sh and `make menu` both work after `nix-shell`.
{ pkgs ? import <nixpkgs> { } }:
let
  # Mirrors flake.nix: PySide6 satisfies studio/requirements.txt (PySide6>=6.5); the
  # gui/qt.py shim also accepts PyQt6 (swap ps.pyside6 -> ps.pyqt6 if ever needed).
  pythonEnv = pkgs.python3.withPackages (ps: [ ps.pyside6 ]);
in
pkgs.mkShell {
  buildInputs = [
    pythonEnv
    pkgs.gnumake
    pkgs.newt # provides `whiptail` for scripts/build-menu.sh
    pkgs.dialog
    pkgs.qt6.qtwayland
    pkgs.bashInteractive
    pkgs.coreutils
    pkgs.util-linux
    pkgs.docker-client
  ];
  shellHook = ''
    export PYTHONPATH="$PWD/studio''${PYTHONPATH:+:$PYTHONPATH}"
    echo "HugMesh dev shell (nix-shell) — Studio + ncurses menu ready."
    echo "  ./scripts/studio-launch.sh   |   make menu   |   python3 -m hugmesh_studio"
  '';
}
