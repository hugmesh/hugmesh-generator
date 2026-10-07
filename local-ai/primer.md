# HugMesh primer

You are a local model helping on HugMesh, a self-hosted mesh of services (gateways, back-end services, web apps, identity, chat) that one person can run on their own machine. Use only facts from this primer or from files you have read. When you do not know, say so and name the file or command that would tell you.

## Repositories
- hugmesh-generator is the hub: Makefile, scripts/, tests/, docs/, specs/ (cluster manifests), studio/ (the desktop wizard, Python and Qt) and the image builders build-*-stage4.sh.
- Every app is its own repo named hugmesh-<name>. Java: hugmesh-gateway, hugmesh-user-bff-api, hugmesh-admin-bff-api, hugmesh-federation-api. Angular: hugmesh-host-shell, hugmesh-login-ui, hugmesh-admin-ui, hugmesh-user-ui.
- scripts/clone-all-repos.sh (run by make stack-clone) clones them into .stack-src/hugmesh-<name>. The compose stack and make kind-images both build from there.
- Do not edit .stack-src. make stack-clone runs git reset --hard on each checkout, so uncommitted edits there vanish (a checkout with local commits is kept, not updated). Work in a scratch clone with no remote.
- The Studio "Repo source" setting is either download and update into .stack-src (the default) or your own folder of hugmesh-<name> checkouts. The second sets STACK_NO_CLONE=1, so your checkouts are never fetched or reset.

## Ways to run the mesh
1. Docker compose stack (every service on one machine). make stack-up builds and starts it. make stack-seed is required afterwards: sign-in fails until it has run. Front door http://localhost:8088. make stack-ps lists containers, make stack-logs follows them, make stack-e2e runs the browser tests. make stack-halt stops and keeps the data; make stack-down deletes the volumes. Rebuild ONE service: no Makefile target does this; run docker compose -f tests/stack/compose.local.yaml up -d --build hugmesh-user-bff-api (use the service name). Java services also need the Maven registry flags the Makefile adds, so when unsure use make stack-up. Only the fe-gateway is published to the host (https://localhost:8488 is its TLS twin); every other service is reached by its compose name. make view LANE=compose or LANE=kind serves the front doors in a browser.
2. kind cluster (a slice of the real GitOps cluster). Order: make kind-up, then make kind-images, then make kind-doctor to check it, then make kind-e2e for the sign-in test. make kind-tor publishes a .onion and runs after make kind-up. Rebuild ONE image: make kind-images ONLY=hugmesh-host-shell (a comma list is accepted; an unknown name fails). make kind-images runs make stack-clone first. make kind-halt stops without deleting; make kind-down deletes the cluster.
3. Studio (Python, in studio/): the wizard that builds images and starts a local mesh. It wraps the two lanes above and starts nothing until a button is pressed. scripts/studio-launch.sh --detect only reports what the host has.
4. Node images (Gentoo): build-x86-host-stage4.sh, build-rpi5-stage4.sh, make local. They take hours and need privileges. Do not run them.

## Tests by repo kind (run in that repo's root)
- Java: ./mvnw -B verify (some repos add -s settings.xml).
- Angular: npm ci && npm run build && npm test -- --watch=false
- Studio: cd studio && HUGMESH_STUDIO_NO_ELEVATION=1 QT_QPA_PLATFORM=offscreen python -m pytest -q tests/<file>.py (one test file at a time).
- Guards in hugmesh-generator: bash tests/scripts/test-<name>.sh. They print PASS or FAIL lines and exit non-zero on failure.
- Gherkin end-to-end scenarios live in tests/e2e/features and run with make stack-e2e-bdd against a live stack. make stack-e2e-bdd-check is the offline check to run before committing a .feature file.
- tests/stack/up.sh starts only a mock lane with fake back-ends, so a pass there says nothing about the real gateways or their route tables.

## House rules for a change
- A new guard must be shown failing: give it negative controls (a doctored input it must catch) and mutation-check it by breaking the production file and watching it go red.
- Never hand-edit a repo under .stack-src to get the local stack to build. Add an idempotent patch function to scripts/patch-stack-src.sh instead.
- Every command under scripts/ must be named in docs/ (tests/scripts/test-docs-command-coverage.sh fails otherwise).
- No modal dialogs in Studio page logic (validatePage, initializePage, itemChanged): a QMessageBox there hangs the headless tests. Use an inline label and an explicit second click.
- Secrets never go in a prompt, a commit or a doc. Do not read .e2e-credentials, vault files or .env files.
- No git push, no sudo, no force. Do not run make stack-down, make kind-down, make kind-up or make stack-up unless you were told to.
- End every task with what you changed, what you ran and its result, and what you did NOT verify.

## Traps that are documented
- Builds stall with npm ETIMEDOUT after about 80 seconds when the host default route is a tunnel with a smaller MTU than docker's bridge (WireGuard is 1420). IPv6 is not the cause. Set BUILD_NETWORK=host for make kind-images.
- A cold Java build needs make stack-m2-bootstrap once, because the org-private Maven artifacts come from a local registry container. Its address changes when Docker restarts; make stack-m2-check refreshes it.
- A Maven build that dies after about 11 minutes with "Could not find artifact net.hugmesh:... in central" means a git update reverted the local patches in .stack-src. Repair with bash scripts/patch-stack-src.sh.
- make kind-up needs read access to the GitOps repo. By default it serves the checkout to ArgoCD with no token, but a linked git worktree (its .git is a file) cannot be served: run from a full clone or export ARGOCD_REPO_TOKEN.
- kind loads images straight into its node and never pulls from Harbor. The kind slice deploys only part of the platform, so other routes answer 503 behind a live route.
- A kind cluster can list as Ready while pods sit in ImagePullBackOff because make kind-images never ran. make kind-doctor reports this and never repairs.

<!-- SOURCES (everything from this line to the end of the file is stripped before use; each fact names the repository file that backs it)
Repositories
- hub layout, specs/, studio/, build-*-stage4.sh: README.md, docs/ARCHITECTURE.md, ls of the tree.
- repo names: REPOS array in scripts/clone-all-repos.sh ("the full first-party repo set"); hugmesh-generator is "intentionally absent" from it.
- .stack-src reset: scripts/clone-all-repos.sh, checkout_is_disposable and the loop below it (checkout --force then reset --hard origin/ref; "KEPT: ... has local work not in" when ahead).
- Repo source modes and STACK_NO_CLONE=1: docs/STUDIO-WALKTHROUGH.md ("Repo source"); Makefile stack-clone ("STACK_NO_CLONE=1 skips").
Ways to run the mesh
- compose: docs/LOCAL-STACK.md ("make stack-up ... make stack-seed # REQUIRED for real SSO login", "http://localhost:8088"); Makefile targets stack-up, stack-seed, stack-ps, stack-logs, stack-e2e, stack-halt ("KEEP its data"), stack-down ("DROP ITS VOLUMES").
- one compose service: the up -d --build line in the header of tests/stack/compose.local.yaml; service name hugmesh-user-bff-api is a key of that file; Makefile STACK_M2_FLAGS adds the m2 env file and tests/stack/compose.m2-local.yaml. There is no stack-rebuild target (the Makefile's rebuild target wipes the work dir and builds the whole fleet).
- kind order: specs/cluster/bootstrap/kind-local/README.md ("documented order above is kind-up THEN kind-images", kind-doctor, kind-e2e); Makefile kind-tor comment ("make kind-up && make kind-images && make kind-tor && make kind-e2e-tor"); ONLY= and "Unknown names FAIL": Makefile comment above kind-images and scripts/kind-load-images.sh ("ONLY: unknown image"); kind-images depends on stack-clone: Makefile; kind-halt / kind-down: Makefile help text.
- Studio: studio/README.md; docs/STUDIO-WALKTHROUGH.md ("Nothing runs until you press a button"); scripts/studio-launch.sh --detect.
- node images: docs/LOCAL-TESTING.md ("make local", build-x86-host-stage4.sh), build-rpi5-stage4.sh in the tree.
Tests by repo kind
- Java, Angular, Studio, guards: docs/LOCAL-AI-ASSISTANT.md section 6.6; studio/pytest.ini; Gherkin: Makefile stack-e2e-bdd (BDD_RUN uses tests/e2e/run.sh --bdd), tests/e2e/features.
House rules
- negative controls and mutation checks: header of tests/scripts/test-kind-doctor.sh ("THE MUTATION BATTERY"); tests/scripts/test-guard-integrity.sh.
- docs coverage: tests/scripts/test-docs-command-coverage.sh header.
- no modals: studio/tests/test_devops_halt_controls.py docstring ("NO MODALS IN PAGE LOGIC").
- secrets, no push, no sudo, report what was not verified: docs/LOCAL-AI-ASSISTANT.md sections 6.5 and 8.
Traps
- MTU stall and BUILD_NETWORK=host, "IPv6 ... is not the culprit": comment block above BUILD_NET_ARGS in scripts/kind-load-images.sh.
- stack-m2-bootstrap and the changing registry address: docs/LOCAL-STACK.md ("Cold builds"); Makefile stack-m2-check comment.
- 11-minute Maven failure and the repair command: assert_maven_wired in scripts/kind-load-images.sh ("bash scripts/patch-stack-src.sh").
- ARGOCD_REPO_TOKEN and the linked worktree: specs/cluster/bootstrap/kind-local/bootstrap-kind.sh ("A linked worktree's .git is a FILE").
- kind never pulls from Harbor; slice answers 503: docs/KIND-SSO-E2E-FINDINGS.md finding 17; kind-local README ("Those paths answer 503 behind a live route").
- ImagePullBackOff while Ready, doctor never repairs: kind-local README and the Makefile kind-doctor comment.
- Only the fe-gateway published, TLS twin 8488, make view LANE=: docs/LOCAL-STACK.md ("Service URLs"); Makefile view target help text.
- never hand-edit a sibling checkout, add a patch function: header of scripts/patch-stack-src.sh.
- stack-e2e-bdd-check "the one to run before committing a feature": Makefile comment above it; mock lane: docs/LOCAL-STACK.md ("The mock lane is untouched, because it runs no gateway at all", tests/stack/up.sh).
-->
