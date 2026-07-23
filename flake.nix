{
  description = "HugMesh Image Studio + ncurses build menu — a dev shell and launchers for NixOS, SteamOS/Steam Deck and other non-FHS / gaming distros where python3 + make are often absent.";

  inputs = {
    # Pin a recent stable channel — its python3Packages.pyside6 satisfies
    # studio/requirements.txt (PySide6>=6.5). `nix flake update` moves the pin.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # PySide6 satisfies studio/requirements.txt (PySide6>=6.5). The gui/qt.py shim also
        # accepts PyQt6 as a fallback — swap `ps.pyside6` for `ps.pyqt6` here if a channel's
        # pyside6 is ever broken.
        pythonEnv = pkgs.python3.withPackages (ps: [ ps.pyside6 ]);

        # Everything BOTH front doors need: the Studio wizard (python + Qt) AND the ncurses
        # build menu (make + whiptail/newt); docker-client for the optional docker backend.
        commonInputs = [
          pythonEnv
          pkgs.gnumake
          pkgs.newt # provides `whiptail` for scripts/build-menu.sh
          pkgs.dialog
          pkgs.qt6.qtwayland # Qt6 Wayland platform plugin (KDE/GNOME Wayland, gamescope)
          pkgs.bashInteractive
          pkgs.coreutils
          pkgs.util-linux
          pkgs.docker-client
        ];

        # `nix run .#studio` — launch the wizard without entering a dev shell first.
        studioApp = pkgs.writeShellApplication {
          name = "hugmesh-studio";
          runtimeInputs = commonInputs;
          text = ''
            cd "''${HUGMESH_GENERATOR_DIR:-$PWD}" || exit 1
            export PYTHONPATH="$PWD/studio''${PYTHONPATH:+:$PYTHONPATH}"
            exec ${pythonEnv}/bin/python3 -m hugmesh_studio "$@"
          '';
        };

        # `nix run .#menu` — the ncurses build menu (inherits gnumake from runtimeInputs, so
        # its REAL `make` build targets work; the python-driven local-mesh submenus too).
        menuApp = pkgs.writeShellApplication {
          name = "hugmesh-menu";
          runtimeInputs = commonInputs;
          text = ''
            cd "''${HUGMESH_GENERATOR_DIR:-$PWD}" || exit 1
            export PYTHONPATH="$PWD/studio''${PYTHONPATH:+:$PYTHONPATH}"
            exec bash scripts/build-menu.sh "$@"
          '';
        };
      in
      {
        # `nix develop` — a shell where ./scripts/studio-launch.sh AND `make menu` both work.
        devShells.default = pkgs.mkShell {
          buildInputs = commonInputs;
          shellHook = ''
            export PYTHONPATH="$PWD/studio''${PYTHONPATH:+:$PYTHONPATH}"
            echo "HugMesh dev shell — Studio + ncurses menu ready."
            echo "  ./scripts/studio-launch.sh      # launch the Studio wizard"
            echo "  make menu                       # ncurses build menu (or ./scripts/build-menu.sh)"
            echo "  python3 -m hugmesh_studio    # direct wizard launch (PYTHONPATH is set)"
          '';
        };

        apps.studio = {
          type = "app";
          program = "${studioApp}/bin/hugmesh-studio";
        };
        apps.menu = {
          type = "app";
          program = "${menuApp}/bin/hugmesh-menu";
        };
        apps.default = self.apps.${system}.studio;

        packages.studio = studioApp;
        packages.menu = menuApp;
      });
}
