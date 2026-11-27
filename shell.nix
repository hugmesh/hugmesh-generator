# FHS env to fix everything calling #!/bin/bash
{
  pkgs ? import <nixpkgs> { },
}:

(pkgs.buildFHSEnv {
  name = "hugmesh-FHSenv";
  targetPkgs =
let
pythonEnv = pkgs.python3.withPackages (ps: [ ps.pyside6 ]);
in
  pkgs:
    (with pkgs; [
    	pythonEnv	
	gnumake
	newt
	dialog
	qt6.qtwayland
	bashInteractive
	coreutils
	util-linux
	docker-client
    ]);
  runScript = "./env.sh";
}).env
