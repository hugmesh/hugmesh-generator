# Manual-test evidence (cloud container run, 2026-09-30, commit 2017882)

Scope: the 38 open issues labelled `Manual`/`manual-test`. This container has no docker
daemon by default (dockerd binary exists and starts, but the compose stack needs the
org-private repos + GitLab maven registry, unreachable without credentials), no kind/kubectl/helm,
no QEMU/KVM, no Tor, no `gh`. Screenshots below are Studio (Qt, offscreen platform) grabs.
Nothing here is a substitute for the live/manual step the issue asks for; "passed" means
only what the Evidence column states.

| issue | status | evidence | blocker / not run |
|---|---|---|---|
| 334 | passed (GUI structure); live bring-up not run | 334/*.png (choice cards, wizard steps), 334/studio-pytest.txt (283 passed) | bring-up itself needs docker stack |
| 335 | passed (GUI structure) | 335/*.png (Vault + base CA + domains), studio-pytest.txt (174 passed) | no live Vault |
| 336 | partial | 336/*.png, 336/studio-pytest.txt (275 passed, 1 skipped); Replicas column shown on a SYNTHETIC snapshot | emulation screen refuses without docker daemon (screenshot shows it); real pod scaling needs a running mesh |
| 337 | partial | 337/*.png (OK/Cancel confirm rendered via the `confirm_flash` seam with a fake device), 337/studio-pytest-flash-nonroot.txt (106 passed) | as root 1 test fails (root-gate assumption, see studio-pytest.txt); real 3 GB artifact `out/sessions/20260907-...` not present; no block device |
| 341 | passed (code + GUI) | 341/*.png (synthetic snapshot), pytest 83 passed | live scale needs a cluster |
| 528 | blocked | 528/kind-halt-status.txt: `make kind-halt-status` refuses (no kind); offline stub guard 159 passed | real kind cluster |
| 581 | blocked (live); offline guards pass | 581/offline-guards.txt (Tor mechanism test SKIPPED-LOUDLY, exit 2 semantics; pins 6 passed) | public Tor network |
| 583 | blocked (live); offline contract passes | 583/offline-guards.txt (164 passed, 0 failed; kind-tor guard: helm required, refused) | helm / kind |
| 614 | blocked | 614/offline-guards.txt: guard FAILs "helm is required" | helm, ingress-nginx cluster |
| 627 | blocked (needs Chromium + Tor onion) | 627/offline-guards.txt: wiring only; cookie flip present for ANUBIS=1 TOR=1 only | Tor, running stack |
| 392 | not run | | plan-body doc corrections; not a runnable test |
| 538, 576, 589, 592, 498, 499, 506, 45, 46, 48 | not run | | need live stack / cluster / Tor Browser / QEMU |
| persona plans 290-314 (17 issues) | blocked | | need a running seeded stack (`make stack-up && make stack-seed`): private repo clones + docker |

Screenshot harness (`tests/e2e`, `npm run shots`) not run: it requires a running seeded stack.
