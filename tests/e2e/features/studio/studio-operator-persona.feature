# THE STUDIO OPERATOR — issue #303, the manual test plan for the persona whose
# role value is n/a: no Casdoor identity, no gateway_route_access row, whose
# only gate is local privilege on their own machine (sudo + SUDO_ASKPASS).
#
# WHAT IS AUTOMATED HERE: every step and negative check of that plan that is
# CLI-only and needs no mesh — the ones the plan itself marks "CLI only" or
# "no mesh needed" — plus the wizard pages its `page` shot producer grabs.
# Each scenario names the plan step it executes. The GUI-click steps (5-10,
# 12-22), the mesh-lifecycle steps (14-19) and NC1/NC2/NC6-NC8/NC13/NC14 stay
# manual, exactly as the plan's "Manual + manual-test" labels say.
#
# THE ONE KNOWN GAP the plan records as "expected to fail today" is pinned as
# @fixme so it turns green, unmodified, the day the launcher is fixed.
@layer:ui
Feature: The Studio operator persona — the plan's CLI-only checks, executed

  # ── step 2: launching ──────────────────────────────────────────────────────
  # `./studio/hugmesh-studio` from the checkout root exits 1 with
  # "No module named hugmesh_studio": its `exec python3 -m hugmesh_studio` only
  # resolves from studio/ (measured on origin/main 9f4d6d30, 2026-09-23).
  @interface:cli @issue:generator-303 @fixme
  Scenario: step 2 — the checked-in launcher runs from the checkout root @interface:cli
    When I run the shell command "./studio/hugmesh-studio --print-command --backend native"
    Then the command succeeded
    And the command output does not contain "No module named"

  @interface:cli @issue:generator-303
  Scenario: step 2 — the documented launcher detects the toolchain, installs nothing and prompts for nothing @interface:cli
    When I run the shell command "bash scripts/studio-launch.sh --detect </dev/null"
    Then the command succeeded
    And the command output contains "DETECT os="
    And the command output contains "DETECT python="
    And the command output contains "DETECT qt="
    And the command output contains "DETECT venv="
    And the command output contains "DETECT make="
    And the command output contains "DETECT whiptail="
    And the command output contains "DETECT nix="

  @interface:studio @issue:generator-303
  Scenario: step 2 — the Welcome screen carries exactly the two entry cards, and no local-mesh card @interface:studio
    When I grab the Studio wizard page "welcome"
    Then the Studio grab is a non-empty PNG
    And the Studio grab shows the wizard page "welcome"
    And the Studio control "Start building" is enabled
    And the Studio control "Review prior sessions" is enabled
    And the Studio page does not say "Start a local mesh"

  # ── step 3: the mode menu ──────────────────────────────────────────────────
  @interface:studio @issue:generator-303
  Scenario: step 3 — the mode menu offers the ten cards in journey order, and no QEMU card @interface:studio
    When I grab the Studio wizard page "mode"
    Then the Studio grab shows the wizard page "mode"
    And the Studio control "Local Docker mesh" is enabled
    And the Studio control "Create nodes for local cloud" is enabled
    And the Studio control "Mesh node" is enabled
    And the Studio control "Run e2e tests" is enabled
    And the Studio control "Mesh emulation" is enabled
    And the Studio control "Cloud deploy" is enabled
    And the Studio control "MDM phone" is enabled
    And the Studio control "MDM Quest headset" is enabled
    And the Studio control "Mesh desktop client" is enabled
    And the Studio control "Standalone Gentoo desktop" is enabled
    And the Studio page does not say "QEMU device tests"

  # ── step 4: the hardware scan, headless and Qt-free ────────────────────────
  @interface:cli @issue:generator-303
  Scenario: step 4 — the headless hardware scan answers with the documented table rows @interface:cli
    When I run the shell command "make -s scan-hardware"
    Then the command succeeded
    And the command output contains "recommended --gpu-driver"
    And the command output contains "hw profile guess"
    And the command output contains "cpu vendor"

  @interface:cli @issue:generator-303
  Scenario: step 4 — the JSON form of the scan carries exactly the documented keys @interface:cli
    When I run the shell command "make -s scan-hardware JSON=1"
    Then the command succeeded
    And the command output JSON object has exactly the keys "bluetooth, cpu, cpu_vendor, gpus, hw_profile_guess, notes, os, recommend_bluetooth, recommend_wifi, recommended_gpu_driver, wifi"

  # ── steps 6 and 7: the tables where the persona set is authored ────────────
  @interface:studio @issue:generator-303
  Scenario: step 7 — the Users table is the multi-role version with the five documented columns @interface:studio
    When I grab the Studio wizard page "users"
    Then the Studio grab shows the wizard page "users"
    And the Studio page says "Username"
    And the Studio page says "Domain"
    And the Studio page says "Roles"
    And the Studio page says "Email"
    And the Studio page says "Registration"
    And the Studio page says "The highest tier (superadmin > admin > mod > user) is the account's primary role"

  @interface:studio @issue:generator-303
  Scenario Outline: the plan's page shots still grab clean: <page> @interface:studio
    When I grab the Studio wizard page "<page>"
    Then the Studio grab is a non-empty PNG
    And the Studio grab shows the wizard page "<page>"

    Examples:
      | page    |
      | role    |
      | domains |
      | e2e     |
      | qemu    |

  # ── step 11: the headless channel derives --person-role by TIER ────────────
  @interface:cli @issue:generator-303
  Scenario: step 11 — a cloud client with admin+games ticked derives --person-role admin, never games @interface:cli
    Given a Studio config JSON fixture:
      """
      {"mode": "cloud", "role": "laptop", "platform": "x86",
       "users": [{"username": "bob", "roles": ["admin", "games"]},
                 {"username": "alice", "role": "superadmin"}]}
      """
    When I run the Studio CLI print-command on that config fixture
    Then the command succeeded
    And the command output contains "--person-role admin"
    And the command output does not contain "--person-role games"

  @interface:cli @issue:generator-303
  Scenario: step 11 — grants alone map to the floor: games only derives --person-role user @interface:cli
    Given a Studio config JSON fixture:
      """
      {"mode": "cloud", "role": "laptop", "platform": "x86",
       "users": [{"username": "carol", "roles": ["games"]}]}
      """
    When I run the Studio CLI print-command on that config fixture
    Then the command succeeded
    And the command output contains "--person-role user"

  @interface:cli @issue:generator-303
  Scenario: step 11 — a mesh-mode client image derives --person-role superadmin regardless of the table @interface:cli
    Given a Studio config JSON fixture:
      """
      {"mode": "mesh", "role": "laptop", "platform": "x86",
       "cluster_domain": "mesh.hugmesh.test",
       "users": [{"username": "bob", "roles": ["admin", "games"]}]}
      """
    When I run the Studio CLI print-command on that config fixture
    Then the command succeeded
    And the command output contains "--person-role superadmin"

  @interface:cli @issue:generator-303
  Scenario: step 11 — the spec channel keeps bob's multi-role set and omits `roles` on a single-role row @interface:cli
    Given a Studio config JSON fixture:
      """
      {"mode": "cloud", "role": "laptop", "platform": "x86",
       "users": [{"username": "bob", "roles": ["admin", "games"]},
                 {"username": "alice", "role": "superadmin"}]}
      """
    When I run the Studio CLI print-specs on that config fixture
    Then the command succeeded
    And the command output is valid JSON
    And the command output contains "\"roles\": [\"admin\", \"games\"]"
    And the command output contains "\"role\": \"superadmin\""
    And the command output does not contain "\"roles\": [\"superadmin\"]"

  # ── step 23 and NC12: the persona's actual gate, SUDO_ASKPASS ──────────────
  # stdout is the password channel, consumed verbatim by sudo: a supplied
  # password is the ONLY bytes on it, and nothing reaches stderr (a GUI-launched
  # native build folds stderr into the build log).
  @interface:cli @issue:generator-303
  Scenario: step 23 — a supplied password is the only thing on stdout, and nothing is on stderr @interface:cli
    When I run the shell command "HUGMESH_STUDIO_SUDO_PASSWORD='probe123' PYTHONPATH=studio python3 -m hugmesh_studio --askpass-no-gui"
    Then the command succeeded
    And the command stdout is exactly the line "probe123"
    And the command stderr is empty

  # Exit 0 on an empty password would let `sudo -A` proceed and the build run
  # unelevated in silence (issue #222). The denial is exit 1, zero bytes on
  # stdout, one sentence on stderr.
  @interface:cli @issue:generator-303
  Scenario: NC12 — elevation aborts when no password source answers @interface:cli
    When I run the shell command "env -u HUGMESH_STUDIO_SUDO_PASSWORD -u HUGMESH_STUDIO_ASKPASS_COMMAND PYTHONPATH=studio python3 -m hugmesh_studio --askpass-no-gui </dev/null"
    Then the command exit code was 1
    And the command stdout is empty
    And the command stderr is exactly the line "hugmesh-studio askpass: no password provided (elevation cancelled)"

  # ── NC3: a standalone-unaffiliated image may not carry a brand ─────────────
  @interface:cli @issue:generator-303
  Scenario: NC3 — an unaffiliated image with a brand identity is refused, and no command is printed @interface:cli
    Given a Studio config JSON fixture:
      """
      {"mode": "standalone", "role": "standalone-unaffiliated", "platform": "x86",
       "brand": "acme", "brand_title": "Acme", "org": "acme"}
      """
    When I run the Studio CLI print-command on that config fixture
    Then the command exit code was 2
    And the command stdout is empty
    And the command output contains "ZERO HugMesh affiliation"

  @interface:cli @issue:generator-303
  Scenario: NC3 control — a wallpaper, an accent colour and a theme are a look, not an affiliation @interface:cli
    Given a Studio config JSON fixture:
      """
      {"mode": "standalone", "role": "standalone-unaffiliated", "platform": "x86",
       "wallpaper": "/tmp/x.png", "accent_color": "#336699", "theme": "dark"}
      """
    When I run the Studio CLI print-command on that config fixture
    Then the command succeeded
    And the command output contains "--theme dark"
    And the command output contains "--accent-color"
    And the command output contains "--wallpaper /tmp/x.png"

  # ── NC5: plaintext secrets never reach the spec channel ────────────────────
  @interface:cli @issue:generator-303
  Scenario: NC5 — the spec channel blanks every plaintext secret @interface:cli
    Given a Studio config JSON fixture:
      """
      {"mode": "standalone", "role": "standalone-thick", "platform": "x86",
       "local_pass": "Sekret123", "luks_pass": "Sekret456"}
      """
    When I run the Studio CLI print-specs on that config fixture
    Then the command succeeded
    And the command output is valid JSON
    And the command output does not contain "Sekret123"
    And the command output does not contain "Sekret456"
    And the command output contains "\"local_pass\": \"\""
    And the command output contains "\"luks_pass\": \"\""

  # ── NC9: the disk backing / is never a flash target ────────────────────────
  @interface:cli @issue:generator-303
  Scenario: NC9 — the flash-target scan needs no root and never lists the disk backing / @interface:cli
    Then the Studio flash-target scan lists no disk backing the root filesystem

  # ── NC11: the from-scratch bootstrap refuses to run inside a cluster pod ───
  # A pure guard call — never the `up` verb, which would mint credentials and
  # start a stack if the guard failed.
  @interface:cli @issue:generator-303
  Scenario: NC11 — the bootstrap's host-local guard refuses inside a cluster pod @interface:cli
    When I run the shell command "KUBERNETES_SERVICE_HOST=1 PYTHONPATH=studio python3 -c 'from hugmesh_studio.core.local_mesh_bootstrap import LocalMeshBootstrap, LocalMeshBootstrapConfig; print(LocalMeshBootstrap(\".\", LocalMeshBootstrapConfig()).guard_host_local())'"
    Then the command succeeded
    And the command output contains "(False, "
    And the command output contains "Refusing to bootstrap a from-scratch mesh inside a cluster pod"

  @interface:cli @issue:generator-303
  Scenario: NC11 control — outside a pod the host-local guard passes @interface:cli
    When I run the shell command "env -u KUBERNETES_SERVICE_HOST PYTHONPATH=studio python3 -c 'from hugmesh_studio.core.local_mesh_bootstrap import LocalMeshBootstrap, LocalMeshBootstrapConfig; print(LocalMeshBootstrap(\".\", LocalMeshBootstrapConfig()).guard_host_local())'"
    Then the command succeeded
    And the command output contains "(True, '')"
