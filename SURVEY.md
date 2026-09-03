# SURVEY — Studio wizard redo (asks 1-23). SURVEY ONLY: no behaviour changed.

Base: `origin/main` @ `c7ca9003` (rebased from `a923819c` — every line number below
RE-VERIFIED against `c7ca9003`; `core/config.py` drifted ~+44 lines in the
`ImageConfig` region and the x86 builder ~+45, so any line cited from the earlier
pass has been re-anchored by symbol grep). Worktree
`.wt/session-scratch/ae563401/wt/SWR-survey`, branch `feat/studio-wizard-redo`.
Builds/docker/qemu/emerge PATH-shadowed by `.nobuild-bin/` (exit 127). Every claim
carries file:line and, where behaviour is asserted, a verbatim probe result.

Probe harness: `SURVEY-probe.py` (committed alongside this file; `out/` is gitignored), run as
`QT_QPA_PLATFORM=offscreen HUGMESH_STUDIO_STATE_DIR=$(mktemp -d) .venv-studio/bin/python3`.

---

## 0. THE FINDING THAT REFRAMES ASKS 1, 2, 4 AND 23

The tri-state legend on both pages promises the unchecked box "forces it OFF"
(`network.py:68-73`, `build.py:94-101`) and the tests pin that promise
(`test_pages_identity.py:319 test_tri_state_force_off_reaches_the_argv`).
**For four of the six service tri-states, the x86 builder does not honour it that way.**

`build-x86-host-stage4.sh` only ever acts on the `true` arm:

```
1106  WANT_TOR="${WANT_TOR:-}"
1107  if [ "${WANT_TOR}" = "true" ] && ${ROLE_CLIENT}; then ... WANT_TOR=false; fi
1111  if [ "${WANT_TOR}" = "true" ]; then    # fold 'tor' into OPTIONAL_SERVICES
```

There is no `WANT_TOR = false` arm anywhere. Same shape for
`WANT_CHARACTER_STUDIO` (`:1122-1127`), `WANT_CHARACTER_FORGE` (`:1138-1143`),
`WANT_EDGE_AI_TTS` (`:1174-1179`), and their rpi5 twins. So:

* `--no-tor` **does** override a `brand.conf` that set `WANT_TOR=true`
  (brand.conf is sourced before the arg loop);
* `--no-tor` **does not** remove `tor` from a `brand.conf` that put the slug into
  `OPTIONAL_SERVICES` — only `EXCLUDE_SERVICES` does, applied last
  (`build-x86-host-stage4.sh:1186-1205`), and `docs/TOR-HIDDEN-SERVICE.md:64` says so
  in as many words: *"Disable (default): omit it; `--exclude-services tor`
  force-removes it."*

Two flags are genuinely different and must not be lumped in:
* `--no-aide` is real subtraction — `WANT_AIDE=false` (`x86:461`) is consumed as a
  plain boolean, so false really strips `app-forensics/aide`;
* `--no-edge-ai` is real — `x86:1089-1090` reads
  `${EDGE_AI} && [ "${WANT_EDGE_AI}" != "false" ] && EDGE_AI_WANT=true`, i.e. it is
  the only way to suppress the `edge_ai` ROLE's auto-selection.

**Consequence for the redo:** for tor / character-studio / character-forge /
edge-ai-tts the operator's "definite unchecked = off" is best served by emitting
NOTHING (the builder default is already off — `OPTIONAL_SERVICES` default is
`akkoma tuwunel phpbb`, `build-x86-host-stage4.sh:141`, and none of those four is in
it). Emitting `--no-*` there is theatre: it changes the argv and nothing else. For
aide and edge-ai the `--no-*` is load-bearing and must stay reachable.

The ncurses menu already agrees: `scripts/build-menu.sh` carries these as plain
yes/no (`OPT_TOR_ONION="no"` `:98`, `OPT_CHARACTER_STUDIO="no"` `:109`,
`OPT_CHARACTER_FORGE="no"` `:111`, `OPT_EDGE_AI_TTS="no"` `:96`) and emits only the
positive flag (`:801`, `:823`, `:824`, `:828`). It has **no** `--no-*` and **no**
exclude-services knob at all.

---

## 1. SERVICES — every service toggle (asks 1, 4, 5, 23)

All on `NetworkPage` (`studio/hugmesh_studio/gui/pages/network.py`) unless noted.
"Default today" is the state a fresh wizard shows, confirmed by probe.

| # | control | file:line | widget | state model | emits | default today | builder |
|---|---|---|---|---|---|---|---|
| 1 | Tor v3 onion | `network.py:407-410` (tristate `:409`) | QCheckBox tristate | `''`/`on`/`off` | `` / `--with-tor` / `--no-tor` (`config.py:2718-2723`) | **PartiallyChecked** | folds `tor` into `OPTIONAL_SERVICES` only on true (`x86:1106-1118`); false arm = no-op |
| 2 | Character Studio | `network.py:413-416` (`:415`) | QCheckBox tristate | same | `_character_studio_args` `config.py:2099-2104` | **PartiallyChecked** | `x86:1122-1127`; false = no-op |
| 3 | Character Forge | `network.py:421-424` (`:423`) | QCheckBox tristate | same | `config.py:2108-2115` | **PartiallyChecked** | `x86:1138-1143`; false = no-op |
| 4 | Edge-AI TTS | `network.py:431-434` (`:433`) | QCheckBox tristate | same | `config.py:2119-2126` | **PartiallyChecked** | `x86:1174-1179`; false = no-op |
| 5 | Edge-AI service | `network.py:371-374` (`:373`) | QCheckBox tristate | same | `config.py:2691-2700` | **PartiallyChecked** | `x86:1089-1090`; **false IS honoured** (suppresses the `edge_ai` role auto-select) |
| 6 | Edge-AI analysis API | `network.py:384-386` | plain QCheckBox | bool | `--with-edge-ai-analysis` only (`config.py:2710`) | unchecked | folds `edge-ai` too |
| 7 | AIDE IDS | `network.py:354-355` | QCheckBox tristate | same | `--with-aide`/`--no-aide` (`config.py:2683-2685`) | **PartiallyChecked** | `WANT_AIDE=false` `x86:461` — **false honoured** |
| 8 | Snort IDS | `network.py:351` | plain QCheckBox | bool | **always** `--snort` or `--no-snort` (`config.py:2680`) | **checked** (`snort: bool = True` `config.py:1537`) | — |
| 9 | Proxy stack | `network.py:347-350` | QComboBox auto/on/off | 3 values | ``/`--proxy-stack`/`--no-proxy-stack` (`config.py:2677-2679`) | `auto` | — |
| 10 | Optional-services checklist | `network.py:465-472` | QListWidget, per-item checkable | list of slugs | `--optional-services "a b"` (`config.py:2064-2067`) | all unchecked | `x86:141` default `akkoma tuwunel phpbb` |
| 11 | NO optional services (sentinel) | `network.py:456-458` | plain QCheckBox | bool | `--optional-services ""` (`config.py:2060-2061`) | unchecked | explicit none |
| 12 | ALL user-level services | `network.py:459-460` | plain QCheckBox | bool | `--all-services` (`config.py:2062-2063`) | unchecked | expands `USER_LEVEL_SERVICES` `x86:127` |
| 13 | **Exclude services** (ask 2) | `network.py:475-478` | QLineEdit free text | space/comma list | `--exclude-services "…"` (`config.py:2068-2069`) | empty | subtractive, applied LAST `x86:1186-1205` |
| 14 | Enable games | `network.py:479-481` | plain QCheckBox | bool | `--enable-games` only (`config.py:2745`) | unchecked | `ENABLE_GAMES=false` `x86:165`, folds `games` `:1078` |
| 15 | Egress VPN + lock | `network.py:319-336` | QLineEdit+Browse, QCheckBox | path/bool | `--egress-vpn`, `--egress-vpn-locked` (`config.py:2671-2673`) | empty/unchecked | role-gated staging + package leg (`x86:3962`, `:4569`) |
| 16 | Managed backing services | `network.py:495-522` | per-id QCheckBox + endpoint QLineEdit | id→endpoint dict | repeatable `--managed-service id=ep` (`config.py:2073-2081`) | none checked | `MANAGED_SERVICES` `x86:162` |
| 17 | Tailnet / SSO | `network.py:253-256` | two plain QCheckBoxes | mode-aware tri | `--with/--no-tailscale`, `--with/--no-sso` | seeded from mode | — |
| 18 | **Per-node** infra services (mesh worklist) | `gui/pages/worklist.py:373-384`, option builder `:44-61` | per-row QComboBox, `currentData()` = tuple | `()`/`("tor",)`/… | x86 → `tor_onion_service=True`; rpi5 → appends the slug (`core/worklist.py:288-303`) | `—` (empty tuple) | `WORKLIST_INFRA_SERVICES` `core/worklist.py:58` |

Probe (fresh mesh x86 flow), verbatim:

```
NET tri aide               PartiallyChecked  tristate=True
NET tri edge_ai            PartiallyChecked  tristate=True
NET tri tor_onion          PartiallyChecked  tristate=True
NET tri character_studio   PartiallyChecked  tristate=True
NET tri character_forge    PartiallyChecked  tristate=True
NET tri edge_ai_tts        PartiallyChecked  tristate=True
NET 2st snort              checked=True
NET 2st edge_ai_analysis   checked=False
NET 2st services_none      checked=False
NET 2st services_all       checked=False
NET 2st games              checked=False
NET 2st egress_locked      checked=False
NET proxy_stack='auto' exclude='' svc_checked=[]
```

Carry-forward contradiction for ask 23: `network.py:22-23` and `_SERVICES_SCOPE_NOTE`
(`network.py:88-95`) state "chosen ONCE for the whole mesh — not per node", and
`_SERVICES_NODE_SCOPE_CAVEAT` (`network.py:101-104`) admits tor/egress-vpn really are
node-scoped in the registry — but row 18 **is** a per-node service table, added later.
`test_pages_network_sections.py:126,135,144` pins all three texts, including
`test_no_per_node_service_table_was_invented`. Any "services as a table" rebuild must
reconcile the three texts and that test, not just move widgets.

Platform capability (`config.py:545-549`): `aide`/`edge_ai_*`/`tor_onion_service` are
x86-only; `character_studio`/`character_forge`/`edge_ai_tts`/`optional_services`/
`exclude_services`/`enable_games` are x86+rpi5. Mode gating: `tor_onion` and the
edge-AI SECTION are hidden outside cloud/mesh; character-studio/forge/tts are
deliberately **not** mode-gated.

---

## 2. TRISTATE INVENTORY (ask 1, inverted for ask 13)

Probe, verbatim:

```
BLD tri build_img          PartiallyChecked
BLD tri live_iso           PartiallyChecked
BLD tri build_tar          PartiallyChecked
BLD tri secure_boot        PartiallyChecked
```

| field | widget | unchecked emits | builder's own default | is `--no-*` load-bearing? | recommendation for "reads as off" |
|---|---|---|---|---|---|
| `tor_onion_service` | `network.py:409` | `--no-tor` | off (`x86:141`) | only vs `brand.conf WANT_TOR=true`; **not** vs `OPTIONAL_SERVICES` | **emit nothing**; two-state, default unchecked (ask 4) |
| `character_studio` | `network.py:415` | `--no-character-studio` | off | same partial | emit nothing |
| `character_forge` | `network.py:423` | `--no-character-forge` | off | same partial | emit nothing |
| `edge_ai_tts` | `network.py:433` | `--no-edge-ai-tts` | off | same partial | emit nothing |
| `edge_ai_service` | `network.py:373` | `--no-edge-ai` | off, **but auto-on for `--role edge-ai`** | **YES** (`x86:1089`) | keep a reachable force-off (unchecked ⇒ `--no-edge-ai` is correct here) |
| `aide` | `network.py:355` | `--no-aide` | `WANT_AIDE=false` `x86:461`, brand.conf can flip | **YES** | keep force-off |
| `build_img` | `build.py:395` | `--no-img` | `BUILD_IMG=true` `x86:238` | **YES** (only way to skip the .img) | keep |
| `live_iso` | `build.py:397` | `--no-live-iso` | `LIVE_ISO=true` `x86:243` | **YES** | keep; ask 13's "default on" = checked ⇒ emit `--live-iso` (see §9) |
| `build_tar` | `build.py:408` | `--no-tar` | `BUILD_TAR=true` `x86:245` | **YES** | keep |
| `secure_boot` | `build.py:463` | `--no-secure-boot` | `SECURE_BOOT=true` `x86:491` | **YES** | keep |
| `media_data` | `home.py:131` (a COMBO, not a checkbox) | `--no-media-data` | on | **YES** | idiom inconsistency; ask 23 may absorb it |
| `sunshine` | not fielded on any page (config-only, `config.py:1585`) | `--no-sunshine` | off | partial | — |

Recorded trap CONFIRMED: `_tri_check` (`build.py:113-129`) calls `setTristate(True)`
**then** `setCheckState(PartiallyChecked)`; `network.py` calls `setTristate(True)`
explicitly at each site. Flipping a default therefore means changing `_TRI_STATES`
(`build.py:106-110`) **and** the `ImageConfig` field default — a widget edit alone is
a no-op because `initializePage` re-seeds every control from `cfg` on every visit.

---

## 3. `exclude_services` — every reference, repo-wide (ask 2)

| surface | ref |
|---|---|
| GUI widget | `network.py:475-478` (create), `:664` (load), `:865` (collect), `:886` (clear list), `:473` (comment), `:219` (brand-profile note) |
| config | field `core/config.py:1562`; capability `:548` (x86+rpi5); emission `:2068-2069` inside `_services_args` `:2055` |
| studio tests | `tests/test_cli_args.py:984-989`, `:1485`; `tests/test_pages_identity.py:201-209` |
| build-matrix | `tests/build-matrix/check.sh:1110-1112` (GUITHR probe `g14-exclude-services`); `tests/build-matrix/flag-coverage.sh:234` (SAMPLES entry) |
| builders | `build-x86-host-stage4.sh:142-151,570,574,583,879,1186-1205`; `build-rpi5-stage4.sh:226-236,721,731,741,747,979,1125-1143` |
| stack tests | `tests/stack/test-optional-services-exclude.sh:222-247,290-307,366-376` (asserts the BUILDER accepts + applies the flag) |
| docs | `docs/OPTIONAL-SERVICES.md:29,100,133-137,147-158`; `docs/TOR-HIDDEN-SERVICE.md:64`; `specs/cluster/optional-services.yaml:32` |
| ncurses menu | **none** — `scripts/build-menu.sh` has no exclude knob |
| worklist schema | **none** — it is a base-`imageConfig` field, not a per-entry axis |

**Recommendation: GUI-only removal. Keep the field, the emission and the flag.**
Evidence:
1. It is the **only** subtractive knob that actually works (§0). `brand.conf`
   `EXCLUDE_SERVICES` is the documented way to build "forum-less + Matrix-less"
   (`build-x86-host-stage4.sh:150`), and the `--all-services` + subtract recipe
   (`docs/OPTIONAL-SERVICES.md:150`) depends on it.
2. `tests/build-matrix/flag-coverage.sh` FORWARD check (`:16-19`) fails any
   builder-parsed flag arm no Studio field can emit unless allowlisted. Dropping the
   field would need TWO new allowlist entries (x86 + rpi5) whose stated reason is a
   claim about the GUI, not the builder — that weakens the differ.
3. The operator's complaint is about the **field on the screen** (a free-text slug
   list next to a checklist that already has none/all sentinels). Removing the widget
   satisfies the ask; the flag stays reachable via `-C brand.conf` and `extra_flags`.

If the GUI widget goes, `network.py:865` must stop writing `c.exclude_services` (or a
loaded config's list is silently blanked on every Next) and
`test_pages_identity.py:201` must be rewritten as a config/emission test.
The `check.sh:1110` GUITHR probe still passes — it drives the config JSON, not the GUI.

---

## 4. LEAKAGE (asks 3, 11, 18)

### Mesh page sequence, precisely

`WIZARD_PAGE_SLUGS` (`core/config.py:105-108`) is the registration order; page
constructors are pinned 1:1 (`gui/wizard.py:150-158`, assert `:156`).
`MODE_SKIPPED_PAGES["mesh"] = ("role", "hardware")` (`core/config.py:125`).
Dynamic skips via `applies_to` (`gui/wizard.py:229-241`).

Effective mesh order:

1. `welcome` 2. `mode` 3. `localmesh` *(skipped — applies_to)* 4. `phone` *(skipped)*
5. `quest` *(skipped)* 6. `deploy` *(skipped)* 7. **`idp`** 8. `role` *(statically skipped)*
9. `worklist` 10. `hardware` *(statically skipped)* 11. `branding` 12. `network`
13. `keyzip` 14. `domains` *(applies_to → `superadmin_plane_applies` → always True in
mesh, `config.py:955-967`)* 15. `users` *(same)* 16. `system` 17. `home` 18. `build`
19. `progress`

**Doc drift to fix in the same PR:** `docs/STUDIO-WIZARD-FLOW.md:80-81` still says mesh
"skips role/hardware/branding" and lists
`welcome → mode → worklist → network → keyzip → domains → users → system → home → build`
— branding is no longer skipped (`config.py:121-125`) and `idp` is missing entirely.
`:84-85` likewise omits that cloud statically skips `idp` (`config.py:120`).

### The gating bug

`WorklistPage.validatePage` sets the shared base to
`cfg.role = entries[0].role; cfg.platform = "x86"` (`gui/pages/worklist.py:598-600`).
Every desktop-class gate downstream keys on `image_class(cfg.mode, cfg.role)`
(`config.py:649-656`). `ROLE_CHOICES["mesh"]` (`config.py:204-219`) contains two
**desktop-class** roles — `rpi5-desktop` (`:213`) and `jetson-desktop` (`:218`), both
members of `DESKTOP_ROLES` (`config.py:628-629`). So a mesh worklist whose first
checked row is one of those makes the whole base "desktop-class", and every desktop
surface unlocks on a mesh flow. **That same pair is exactly ask 18's "roles that can't
be a mesh".**

Probe, verbatim (identical runs, only `entries[0].role` differs):

```
=== NODE-FIRST  (mesh, base role='pki') ===
  HOME login group visible=True title='Your login & standalone account'
  HOME standalone visible=False local_user visible=True text='magus'
  HOME media_data visible=True no_vaults visible=True
  HOME home_box mode enabled=True visible=False
  NET  egress_row visible=False egress_section visible=False
  BLD bundle_source visible=True installer_ui enabled=False

=== DESKTOP-FIRST  (mesh, base role='rpi5-desktop') ===
  HOME standalone visible=True                       <-- LEAK
  HOME home_box mode enabled=True visible=True       <-- LEAK
  NET  egress_row visible=True egress_section=True   <-- LEAK
  BLD  installer_ui enabled=True                     <-- unlocked
```

### Standalone-desktop-only fields reachable in the mesh sequence

| # | field | file:line | current gating | why it fails |
|---|---|---|---|---|
| L1 | **`login` group "Your login & standalone account"** (ask 11) | `home.py:145-174` | **NONE on the group.** Only the inner `standalone` checkbox is gated (`home.py:323-325`) | The group is a bare `QGroupBox`; nothing ever calls `setVisible` on it. Its title literally says "standalone account" and it is on screen for **every** mesh node — probe `visible=True` in BOTH runs. |
| L2 | `local_user` / `local_pass` | `home.py:168-173` | none | `local_user` defaults to `"magus"` (`config.py:1459`) and x86 emits `--local-user` **unconditionally**. Probe: bare mesh x86 pki argv = `--role pki --env test --local-user magus --with-tailscale --with-sso --superdomain hugmesh.internal --snort --installer-ui all --uncached --live-toram --bundle-source`. Not merely visible — live. |
| L3 | `standalone` checkbox (ask 21 removes it here) | `home.py:156-161` | `scope_allows("standalone", cfg)` hide (`home.py:323-325`); scope `classes=("desktop",)` + `class_platforms` (`config.py:843-844`) | Correct for node-first; **opens** when `entries[0]` is `rpi5-desktop`/`jetson-desktop`. |
| L4 | Home provisioning group (`home_box`) | `home.py:58-119`, gated `:301-309` | `home_options_allowed` = `image_class == "desktop"` (`config.py:949-952`) — **no mode axis** | Deliberate ("desktop-class images in any mode"), so a mesh flow with a desktop base role gets home mode/device/backup/eCryptfs/seed. |
| L5 | **External media-data device** (Steam library + gocryptfs Vaults) | `home.py:127-139` | **platform only** (`home.py:279+`; `media_data`/`media_label`/`no_vaults` are `_X86`) | Base platform is forced `x86` in mesh, so the platform gate always passes. There is **no** role-class or mode gate — `visible=True` in BOTH probe runs. `_FIELD_SCOPE_OVERRIDES` has no entry for `media_data`. |
| L6 | Egress VPN row + lock | `network.py:319-336` | `scope_allows("egress_vpn")`, `classes=("desktop",)` (`config.py:860-863`) | Correct for node-first; opens on desktop-first. |
| L7 | `bundle_source` | `build.py:346-347` | **platform + unaffiliated only** | `_FIELD_SCOPE_OVERRIDES["bundle_source"]` declares `classes=("desktop",)` (`config.py:872-873`) with **no enforcement anywhere**. Default `True` (`config.py:1613`) ⇒ every mesh node argv carries `--bundle-source` (probe PRESENT) ⇒ 33MB of generator tree on a headless node. `test_scope_violations.py:116` pins this gap OPEN by name. |
| L8 | Cached ISO / Live-ISO copy-to-RAM | `build.py:342-345` | platform only | ISO/desktop-media knobs on a headless node; no role-class axis. |
| L9 | Installer UI combo | `build.py:317-323` | role-class **disable-with-reason** (deliberate) | Not a leak — documented choice. Listed so the redo does not "fix" it. |
| L10 | Branding desktop half | `branding.py:62-135`, gated `:196-198,236-237` | `branding_allowed` = desktop **and** `mode != "mesh"` (`config.py:936-938`) | **Correct** — probe `BRAND form enabled=False` in both mesh runs. It is *greyed*, not hidden — a presentation choice ask 6 may revisit. |

**Fix location, not widget hiding:** L1/L2/L5 have no scope declaration at all. The
principled fix is `_FIELD_SCOPE_OVERRIDES` entries (`config.py:809-877`) for
`local_user`/`local_pass` and the media-data trio, plus a group-level
`gate_widgets_role_class(..., hide=True)` driven by them — the idiom `home.py` already
uses for `_home_widgets`. L3/L4/L6 need the *base-role* question answered differently
in mesh: the honest predicate is "does ANY worklist entry want this", exactly what
`SystemPage._node_creds_apply` (`system.py:77-95`) already does. It is the **only**
page in the flow that reads `wiz.worklist.entries` instead of the base, and the only
one that got the mesh answer right in both probe runs.

**Ask 18 specifically:** removing `rpi5-desktop`/`jetson-desktop` from
`ROLE_CHOICES["mesh"]` (`config.py:213`, `:218`) closes the root of L3/L4/L6 — but it
is a **catalog contract change**: `ROLE_CHOICES` drives the WorklistPage rows, the
RolePage, and `test_pages_role.py`. It also contradicts the role's own description
("compose with `--standalone` for FDE, no mesh", `config.py:214`) — which is precisely
the operator's point. Decide it as a catalog change, not as a hide.

---

## 5. BRANDING (ask 6)

`studio/hugmesh_studio/gui/pages/branding.py`

* Page skip: `applies_to` returns False only for the unaffiliated role.
* Role/platform gate: `:196-198` `enabled = not unaffiliated and branding_allowed(c)
  and platform_supports("theme", c.platform)`; applied as **grey**, not hide (`:236-237`).
* **Premade-vs-custom radio**: `QButtonGroup` `:69`, `rb_preset` `:70`, `rb_custom`
  `:71`; default `rb_preset.setChecked(True)` `:142`. Mutual exclusion + blanking in
  `_mode_toggled` `:151-162`: choosing *preset* clears all eight custom line edits
  **and** the accent; choosing *custom* resets the theme combo to index 0.
  `validatePage` re-applies the same split (`:271-286`).
* **Theme combo**: `:78-83`, non-editable (`:79`), items = `""` + `_themes()`; rebuilt
  per-visit with the brand name and any loaded value appended. `_themes()` `:144-149`
  lists `specs-x86/branding/themes/*/` and falls back to `["boogiepop"]` on OSError
  (`:149`).
* **What exists on disk**: `specs-x86/branding/themes/boogiepop/wallpaper.png` — that
  is the ENTIRE theme tree (verified: `find . -type d -name themes` → one hit).
  Probe: `BRAND themes = ['', 'boogiepop', 'hugmesh']` (`hugmesh` is brand-derived,
  not a directory).
* **Eight custom fields** `_CUSTOM_FIELDS` `:35-36` = branding_dir, wallpaper,
  grub_background, grub_theme, login_background, brand_logo, color_scheme,
  accent_color. Built `:91-112`. `brand_locked` sits **outside** the either/or `:126-127`.
* Both-set reconciliation note `:117-123`, applied `:228-234` (custom wins).
* **Web login theme group** — `LoginThemeGroup` (`_logintheme.py:51`), added OUTSIDE
  `self.form` (`branding.py:135-138`) so the desktop gate never touches it; collapsible
  `"Web login theme"`, auto-expanded in mesh. Its fields are `NON_ARGV_FIELDS`
  (`config.py:606`) — they theme the login-ui the mesh SERVES; they are NOT `--theme`.

### Every consumer of the premade theme NAME

| consumer | ref |
|---|---|
| config field | `core/config.py:1510` `theme: str = ""` → `--theme NAME`; `THEME_FIELDS` `:642`; scope `:810-812` (desktop-class, never mesh) |
| GUI | `branding.py:78-83,144-149,202-215,273` |
| builder | `build-x86-host-stage4.sh:425-430` (`BRANDING_THEME`), parse `:992`, resolution `:3940-3943` — **hard error** `:3943` `unknown --theme '<name>' (looked in ${SPECS_DIR}/branding/themes/<name>)`; optional logo `:3811-3812` `themes/<name>/logo.png` |
| ncurses menu | `scripts/build-menu.sh:194` `OPT_SA_THEME="boogiepop"`, persisted `:285`, emitted `:781`, picker enumerates the theme dirs live `:1798`, unaffiliated suppression `:779-781` |
| docs | `docs/STANDALONE-DESKTOP.md:129,416,432-433,437,440` |
| tests (menu) | `tests/menu/build_menu_cmd_test.sh:67,231,234,241,257` — `:257` asserts `--theme boogiepop` is emitted for the thick sibling |
| tests (matrix) | `tests/build-matrix/check.sh:478-482,1390,1467-1476`; `flag-coverage.sh:191` |
| tests (studio) | `test_cli_args.py:170,1451,1895-1952`; `test_unaffiliated_wizard_surface.py:138,158,161`; `test_wizard.py:726`; `test_worklist.py:211`; `test_pages_home.py:164-177`; `test_headless.py:139` |

**Cost of "remove existing themes, leave light/dark/purple/grey":** `boogiepop` is a
literal in 12 files across 5 test suites and is the ncurses menu's persisted default.
Deleting the directory without touching `scripts/build-menu.sh:194` makes the menu's
default emit `--theme boogiepop` into a builder that hard-errors at
`build-x86-host-stage4.sh:3943`. The four new theme dirs must be **generated by a
committed deterministic script** (no downloaded art, no hand-pasted binaries) and each
needs at least the `wallpaper.png` that `boogiepop` has, or the resolver stages nothing.

---

## 6. THE FIELD ASKS (7-10)

### Ask 7 — "this devices person role is completely unclear"

* Control: `gui/pages/users.py:86-93` — `QComboBox`, items `("derive",
  *PERSON_ROLE_CHOICES)` = derive/user/mod/admin/superadmin (`config.py:382`).
* **Current label, verbatim** (`users.py:92`): `"This device's person role"`.
* **Current help**: there is **no on-page help label**. The only explanation is a
  tooltip (`users.py:88-91`), verbatim:
  `"The person-role this CLIENT image is tied to at build time (--person-role). 'derive' = users[0]'s role in cloud mode, superadmin in mesh mode. Ignored by the builder on cluster NODE roles."`
  This is exactly the failure mode `network.py:63-67` already documents for the
  tri-states ("the meaning existed only as a hover tooltip, which nobody hovers").
* Placement is the deeper problem: a **per-image** build-time identity control sits at
  the bottom of the **superadmin users table** page, under an "Add user / Remove
  selected" button row, with no visual separation (`users.py:72-93`).
* Semantics: emitted only for non-node roles (`config.py:2602-2603` region); the
  builder warns and ignores it otherwise; platform-gated x86 (`users.py:200`,
  `config.py:508`).
* Probe: `USR person_role='derive' row_visible=True` on a mesh x86 flow.

### Ask 8 — users & domains steps

* What decides they show today: `DomainsPage.applies_to` (`domains.py:147-151`) and
  `UsersPage.applies_to` (`users.py:176-180`), both delegating to
  `superadmin_plane_applies` (`config.py:955-975`): **mesh → always True**; cloud →
  True unless the role is an `X86_NODE_ROLES` node (`config.py:387`); standalone →
  statically skipped (`config.py:119`).
* There is **no "start with additional domains" control anywhere** — `ModePage`
  (`mode.py:66-90`) offers the build kinds and nothing about domains; a repo-wide grep
  for "additional domain" returns nothing. Ask 8 needs a **new** opt-in (ask 19
  specifies its shape: a choice-card screen).
* Closest existing prose: `DomainsPage` subtitle (`domains.py:67-71`) — *"Beyond the
  superadmin apex, define the OTHER domains this mesh hosts…"*, and the cloud-only
  prefill of row 0 with the cluster domain (`domains.py:173-174`).
* **Skip must stay emission-neutral** (the documented `applies_to` precondition,
  `wizard.py:214-219`). With both pages skipped, `cfg.domains`/`cfg.users` stay `[]`;
  the mesh manifest then carries empty `domains`/`users` arrays
  (`worklist_driver.py:201-205`). That is a **manifest** content change, on a channel
  with no emission guard — call it out rather than assume it is neutral.

### Ask 9 — hostname / timezone / default user

All on `SystemPage` (`gui/pages/system.py`). Probe:
`SYS hostname='' tz_widget=QLineEdit tz='' user=''`.

| field | file:line | widget today | default today |
|---|---|---|---|
| Hostname | `system.py:39-42` | `QLineEdit`, placeholder `"Leave blank to use the role-derived hostname"` | **empty**; `hostname: str = ""` (`config.py:1456`) → emits nothing, builder derives |
| Timezone | `system.py:43-46` | **`QLineEdit` — free text**, placeholder `"Area/Location, e.g. Europe/Berlin (leave blank for UTC)"` | **empty** (`config.py:1457`) → builder UTC |
| Default user | `system.py:47-51` | `QLineEdit`, placeholder `"Default account name (leave blank for the builder default)"` | **empty** |

Emission: `_identity_args` — each emits `-H/-T/-u` only when non-empty, on **every**
platform (`config.py:505` all-platform). So preselecting any of the three **changes
the argv of every existing flow** from "omit" to "explicit". Guarding test:
`test_public_polish.py:160 test_system_and_network_placeholders_humanized` reads
`sysp.timezone.placeholderText()` — a non-editable `QComboBox` has no
`placeholderText()`. **Hard break on a naive dropdown swap.**

### Ask 10 — node-fallback baked user + root password

* Group: `system.py:56-74` — `QGroupBox("Node fallback login (mesh nodes)")`, an
  always-present explanatory `QLabel` (`:58-65`), then `user_password` (`:66-69`) and
  `root_password` (`:70-73`), both `EchoMode.Password`, both **always rendered inside
  the group** — there is no opt-in.
* What gates the group today: `gate_widgets_role_class(self.creds,
  self._node_creds_apply(c), _NODE_CREDS_REASON, hide=True)` (`system.py:117-118`).
  `_node_creds_apply` (`:77-95`) is the **only** predicate in the flow that reads
  `wiz.worklist.entries` rather than the base config — deliberately, `:82-88`.
* Platform gate x86-only (`system.py:107-110`); cleared in `validatePage` `:130` and
  role-class-cleared `:138-140`. Both are `SECRET_FIELDS` (`config.py:466`) — never saved.
* Ask 10 is therefore an **inner opt-in checkbox** inside `self.creds`, not a new
  page-level gate. The existing outer gate is correct and must be preserved.

---

## 7. THE SECOND-BATCH ASKS (14-23) — where each one lands

### Ask 14 — pick-one surfaces become BUTTONS

The choice-card layer already exists: `gui/choice_cards.py` (`ChoiceCard`
`QAbstractButton` + `ChoiceCardGroup` `QButtonGroup`) and `gui/choice_icons.py`
(memoised palette-derived vector icons, registry `choice_icons.py:586+`).
**Already converted:** `mode.py:59,95`, `idp.py:86-102`, `golive.py:137-144`.
**Still radios / checkmark-then-Next:**

| surface | file:line | today |
|---|---|---|
| Branding premade-vs-custom | `branding.py:70-71` | two `QRadioButton` (ask 6 rebuilds this anyway) |
| LocalMesh environment | `localmesh.py:240-241` | `test`/`prod` radios |
| LocalMesh repo source | `localmesh.py:273,283,305` | three radios (one permanently disabled) |
| RolePage architecture | `role.py:87-97` | one `QRadioButton` per arch, built from `device_catalog` |
| Domains "how to start" | **does not exist** (ask 19 creates it) | — |
| Users "minimal vs table" | **does not exist** (ask 20 creates it) | — |

`ChoiceCardGroup` keeps the exact `QButtonGroup` API (`button(i)`, `buttons()`,
`checkedButton()`, `property(...)`), so a conversion is drop-in for the pages whose
tests read the group. Guard: `test_choice_cards.py` has 23 tests including
`test_every_registered_icon_paints_non_blank` (`:194`),
`test_no_two_icons_render_identically` (`:203`) and
`test_modules_import_no_network_machinery` (`:281`) — every NEW icon must paint
non-blank AND be pixel-distinct from every existing one.

### Ask 15 — build list, click opens a window with resume / artifacts / edit / delete

Already largely built, but as an in-place button row, not a new window:
`gui/pages/sessions_widget.py` `PreviousBuildsWidget` (a `QGroupBox`, `:176`) placed on
the Welcome page (`welcome.py:7,49`). Buttons: `restart_btn` `:210`, `redo_btn`
("Redo (edit as new)") `:212`, `open_btn` ("Open artifacts") `:214`, `log_btn`
("View errors/log") `:216`, `delete_btn` `:223`, `delete_all_btn` `:225`. There IS a
dialog already — `_SessionDetailDialog` (`:98-129`) — but it is log-only and reached
via `log_btn`, never by clicking a row. `can_restart` `:318-328`, restart refusal while
running `:360`. Wizard side: `load_session` (REDO) `wizard.py:269-279`,
`start_build_from_session` (RESTART, jumps straight to `progress`) `wizard.py:281-305`.
The ask is a **presentation change**: route row-activation to a per-build window that
offers the four existing actions. Tests: `test_pages_sessions.py` (20 tests,
`:228-430`) drive the buttons directly and will need the new entry point added, not
the old one removed.

### Ask 16 — multi-window + tray "running builds" submenu

* **There is no single-instance mechanism at all**: repo-wide grep for
  `QLocalServer|QLocalSocket|QSharedMemory` over `app.py`, `gui/wizard.py`,
  `gui/tray.py` returns **zero hits**. A second `python -m hugmesh_studio` launch
  creates a second `QApplication` and a second tray icon.
* **Within one process** there is a one-window cap: `app.py:271-281 open_studio()`
  holds `nonlocal wizard` and does `if wizard is None: create` else `show(); raise_()`
  — so "open a NEW studio window" has no code path today. Same shape for
  `open_golive` `:283-289` and `open_fleet` `:291-297`.
* Tray: `gui/tray.py` `_ControlTray.__init__` builds a FLAT menu (`:207-217`) — section
  actions, `"Open Image Studio…"` `:214`, `"Go Live…"` `:216`, `"Quit"` `:217`. There
  is **no submenu anywhere** (`addMenu` has no call site) and no per-build item.
* The only build-state channel the tray has is aggregate: `write_build_status`
  (`tray.py:106-116`) writes one JSON `{state, percent, running, total}`;
  `read_build_status` `:122`; polled by `_poll_build_status` `:245`. A per-build
  submenu needs a per-build record — which `core/build_sessions.py` already models
  (the same records `PreviousBuildsWidget` reads). **Recommendation: drive the tray
  submenu off `build_sessions`, not off a second status file.**
* Guard: `test_tray.py` (8 tests) pins the current menu shape.

### Ask 17 — IdP screen: cards → per-provider configuration window

`gui/pages/idp.py` already uses `ChoiceCard` (`:86-102`), one per `IDP_CHOICES`, with
`casdoor` checked by id at `:104`. The external fields are an INLINE `QGroupBox`
`ext_box` (`:106-127`) enabled iff `selected_idp() != "casdoor"` (`_sync` `:165-167`).
So the ask is: keep the cards, move `ext_box` into a modal per-provider dialog opened
by the card, and keep Casdoor's "proceed with nothing to configure" path. `_candidate`
(`:151-158`) already builds a throwaway `ImageConfig` for `validate_identity()` — the
dialog can reuse it verbatim so the fail-closed rule is not duplicated. Guard:
`test_choice_cards.py:107 test_idp_page_renders_one_card_per_idp_choice`.

### Ask 19 — domains at launch: a choice-icon screen

`DomainsPage` (`gui/pages/domains.py`, 192 lines) is a pure table: header `:75-78`,
help `:81-87`, `QTableWidget(0, 4)` `:93-101` with columns
`Domain | Title | Optional services | Applies to` (`_COL_* = range(4)` `:21`), Add/Remove
`:103-107`, admin note `:111-117`. The per-row "Applies to" cell is an
`_AppliesToButton` (`:27-58`) — a checkable-menu `QToolButton`. Nothing today asks
"one internal domain or several"; the internal apex is the read-only superdomain header
(`:155-158`, `c.effective_superdomain()`). The default-path button must therefore
assert *"proceed with `<superdomain>` only"*.

### Ask 20 — users: a "minimal users" button that names the users AND the credential location

Evidence needed for the button's own text, and the honest answer is uncomfortable:

* **Nothing in the Studio generates a default user set today.** `ImageConfig.users`
  starts `[]`; `WorklistConfig._materialize_one` only deep-copies whatever the base
  carries (`core/worklist.py:243`). The mesh manifest writes `"users": [asdict(u) for
  u in base.users]` (`worklist_driver.py:205`) — an empty list on the default path.
* The only *claim* about generated accounts is prose on the Domains page
  (`domains.py:111-114`): *"Each domain automatically gets a default admin account. Its
  random password is generated and shown at provisioning time"* — that is a statement
  about the **cluster provisioning** stage, not about anything the Studio emits.
* The credential channel that does exist is the KEYS/key-zip one:
  `core/keyzip.py:280` maps `("superadmin", "Platform Superadmin", "pki",
  "casdoor-superadmin")`, i.e. the platform superadmin login rides the `<brand>-pki`
  node's key-zip under the `casdoor-superadmin` secret (`docs/SUPERADMIN-MESH-CLIENT.md:13`),
  and `:40` documents the honest failure ("if no `casdoor-superadmin` Secret was
  generated"). The mesh manifest itself lands at
  `hugmesh-mesh-manifest.json` in the session output dir (`worklist_driver.py:67,209-213`).
* **So ask 20's button cannot truthfully name generated users until something
  generates them.** Either (a) the Studio starts seeding a minimal `users` list (a
  manifest content change), or (b) the button states the *provisioning* contract
  (superadmin via the pki key-zip; one auto-admin per domain) and cites where — which
  is what the existing prose already half-says. Pick one deliberately; do not let the
  button assert accounts nothing creates.

### Ask 21 — root encryption ALWAYS on; drop "standalone" from the Home step

Supersedes ask 12's "default on". See §9 for what turning it on actually changes.
The "standalone" removal is L3 above (`home.py:156-161`), and it is coherent: the
checkbox is `scope_allows`-gated to desktop-class already, so on the mesh flow it is
dead weight; on the standalone flow the MODE already implies it.
**Caution:** `c.standalone` is written at `home.py:363` and gates real builder
behaviour; removing the widget must keep the standalone MODE setting the flag, or the
standalone flow silently loses FDE + local-password login. `test_scope_violations.py`
(`:95-215`) sweeps `--standalone` against the builder's real `ROLE_CLIENT` arms in
every mode and will catch a wrong narrowing.

### Ask 22 — split "Review" from "Build"

They are **one page today**: `BuildPage.setTitle("Review & Build")` (`build.py:243`),
subtitle `:244`, and it is a Qt **commit page** (`setCommitPage(True)`), so Qt disables
Back on the page after it. `ProgressPage` is the running-build screen
(`progress.py:359 setTitle("Building")`, `:360` subtitle). `ProgressPage._sync_back_button`
(`progress.py:2185-2211`) already re-arms Back once every row is terminal, precisely so
a failed build is not a dead end — read that docstring before touching the split; it
records a real 2026-07-17 report. `isComplete` `:2214-2216` gates Finish on
`_all_terminal`. "Go back to the main menu" has no existing affordance:
`StudioWizard.restart()` is called from `load_config` `:267`, `load_session` `:279`
and `start_build_from_session` `:303`, never from a user-facing "main menu" button.

### Ask 23 — services + apps as ONE table

Consolidation targets, all listed in §1: the six tri-state boxes (rows 1-5, 7), the
checklist + two sentinels (rows 10-12), games (14), managed services (16), and the
per-node worklist combo (18). Existing table idioms to reuse rather than invent:
`gui/pages/_device_table.py` (`DeviceTable`, per-row combos), `domains.py:27-58`
(`_AppliesToButton`, a checkable-menu cell), `users.py:139-154` (per-row combo cells),
`worklist.py:373-384` (per-row services combo). Blocking test:
`test_pages_network_sections.py:144 test_no_per_node_service_table_was_invented` — a
table that spans nodes will trip it unless the note texts move with it.

---

## 8. TESTS THAT WILL BREAK

Baseline suite on this base (`c7ca9003`, before any change), verbatim:
`4 failed, 3807 passed, 25 skipped, 1 warning in 190.39s (0:03:10)`. The 4 failures are
all pre-existing and all in `studio/tests/test_package_catalog.py` — verbatim names:
`test_raw_atom_totals_match_tree[x86-149]`,
`test_roles_invariants_hold_against_fresh_derivation`,
`test_validator_rejects_essential_removable_boundary_shift`,
`test_packages_catalog_json_is_current`. None touches anything in scope.

**Asks 1/4 (tri-state defaults / definite-off):**
* `tests/test_pages_network_sections.py:109 test_tri_state_boxes_keep_all_three_states`
  — asserts `isTristate()` for aide/edge_ai/tor_onion/character_studio/edge_ai_tts AND
  `tor_onion.checkState() == PartiallyChecked` AND `character_studio.checkState() ==
  PartiallyChecked`. **Hard break.**
* `tests/test_pages_network_sections.py:97 test_tri_state_legend_is_visible_not_just_a_tooltip`
  — requires the legend text to contain "part-checked"/"partly", "default", "square".
* `tests/test_pages_identity.py:319 test_tri_state_force_off_reaches_the_argv` —
  requires `--no-tor`, `--no-character-studio`, `--no-edge-ai-tts` in the argv.
* `tests/test_pages_identity.py:345 test_tri_state_part_checked_leaves_the_builder_default`
  — requires the boxes to START part-checked and emit neither flag.
* `tests/test_pages_build_sections.py:121 test_tri_state_pairs_keep_all_three_states`,
  `:151 test_tri_state_legend_is_visible_not_just_a_tooltip`,
  `:163 test_tri_checkbox_emission_is_byte_identical_to_the_old_dropdowns`,
  `:184 test_a_loaded_tri_state_value_round_trips_onto_the_checkbox`.
* `tests/build-matrix/check.sh:1126 guithr g34-force-off-tristates` — asserts
  `--no-tor --no-character-studio --no-character-forge` reach the builder. If the fields
  stay tri-state IN CONFIG (recommended) this survives untouched; if any field loses its
  `off` value it must be edited **and** `GUITHR_EXPECTED=73` (`check.sh:963`) adjusted.
* `tests/build-matrix/flag-coverage.sh` `{"…":"off"}` samples — config-level, survive a
  GUI-only change.

**Ask 2 (exclude field):**
* `tests/test_pages_identity.py:201 test_exclude_services_subtractive_list` — drives
  `net.exclude.setText(...)`. **Hard break** (attribute gone).

**Asks 3/11/18 (leakage):**
* `tests/test_pages_home.py` — the whole `_home_widgets`/`standalone`/`encrypt_root`
  visibility family (29 tests; `:164-177` theme round-trip, `:291-298` jetson no-encrypt).
* `tests/test_field_scope.py:116,126,133,181,206,233,255,281,301,322,353` — any new
  `_FIELD_SCOPE_OVERRIDES` entry must satisfy
  `test_the_declared_narrowings_actually_narrow` (`:133`) and
  `test_no_class_narrowing_reaches_a_builder_that_has_no_roles` (`:255`).
* `tests/test_scope_violations.py:116 test_bundle_source_default_is_a_leak_not_a_violation`
  — pins the L7 gap **open**. Closing L7 breaks this test **by design**.
* `tests/test_scope_violations.py:172 test_block_tier_matches_rpi5_role_client_for_every_role`
  and `:215 test_gui_gate_matches_rpi5_role_client_in_every_mode` — any `standalone`
  narrowing (ask 21) is swept against the real builder here.
* `tests/test_pages_network_sections.py:237,246` (egress section orphan-header pair).
* `tests/test_wizard.py:118,314` — the slug→page map and `__all__` order asserts.
* `tests/test_pages_role.py` — `ROLE_CHOICES` catalog contents (ask 18).

**Asks 5/13/23 (services + build page rebuild):**
* `tests/test_pages_network_sections.py` — 24 tests keyed on the exact section set,
  default expansion, and "collapsing changes no argv" (`:158,177,188,198,206,220,227,
  237,246,253,265,296,316,327,337,348,367,380,391`), plus the three scope-note tests
  `:126,135,144`.
* `tests/test_pages_build_sections.py` — 19 tests keyed on the Artifacts/Image-options
  split (`:108 test_artifact_and_sb_toggles_are_all_checkboxes_no_dropdowns_left`,
  `:139 test_value_enumerations_stay_dropdowns_and_actions_stay_buttons`,
  `:203 test_every_section_is_collapsible`, `:231 test_default_expansion_keeps_the_review_surfaces_open`).
  Merging Artifacts into Image options (ask 13) rewrites most of these.
* `tests/test_pages_identity.py:174,189,216,226,251,272,282,306` — sentinel / catalog /
  client-note family.

**Ask 6 (branding):**
* `tests/test_pages_home.py:164,177`; `tests/test_unaffiliated_wizard_surface.py:138,158,161`;
  `studio/tests/test_cli_args.py:170,1451,1895-1952`; `test_wizard.py:726`;
  `test_worklist.py:211`; `test_headless.py:139`.
* `tests/menu/build_menu_cmd_test.sh:231-241,257` — the `OPT_SA_THEME=boogiepop`
  persisted default and `assert_has "thick sibling: theme intact" "--theme boogiepop"`.
  **This is the one that bites hardest if the directory is deleted.**
* `tests/build-matrix/check.sh:478-482,1390,1467-1476`; `flag-coverage.sh:191`.

**Asks 7/8/9/10/19/20:**
* `tests/test_pages_identity.py:369,379,391,398` — person-role derive/override/choices/
  ARM-clear; `:391 test_person_role_offers_exactly_the_builder_accepted_roles` pins the
  combo contents.
* `tests/test_pages_identity.py:478,496,506,514` (domains) and `:412,430,444,460`
  (users) — all assume the pages are reachable in the current flows.
* `tests/test_public_polish.py:160 test_system_and_network_placeholders_humanized` —
  reads `sysp.timezone.placeholderText()`. **Hard break** on a non-editable combo.
* `tests/test_wizard.py` mode-flow tests — any new dynamic skip changes the visited-page
  set, and `wizard.collect_all` only reads visited pages (`wizard.py:243-256`).
* `tests/build-matrix/check.sh:1069 guithr g27-node-fallback-creds` and `:1066
  g26-identity-x86` — config-level, survive a GUI opt-in, but must be re-read if any
  default becomes non-empty.

**Asks 14/15/16/17/22:**
* `tests/test_choice_cards.py` (23 tests) — `:94` mode cards, `:107` idp cards, `:116`
  golive cards, `:194` every icon paints non-blank, `:203` no two icons identical,
  `:281` no network machinery imported, `:314` accessible name+description,
  `:469` role-row icons.
* `tests/test_pages_sessions.py` (20 tests, `:228-430`) — the whole PreviousBuildsWidget
  button/gating/delete family.
* `tests/test_tray.py` (8 tests) — the current flat tray menu.
* `tests/test_pages_progress.py`, `test_pages_progress_expand_gate.py`,
  `test_progress_uniformity.py`, `test_pages_build.py` — the Review/Build/Progress split.
* `tests/test_qt_enum_scoping.py` — every new slot must use scoped enum spellings.

---

## 9. ASKS 12/21 & 13 — what the evidence actually says

### Asks 12 + 21 — root encryption default-on / always-on

**The premise that "the session manifest already carries `encrypt_root` true per image"
is not what the code does.** Chain, verbatim:

* `ImageConfig.encrypt_root: bool = False` (`config.py:1596`).
* `WorklistEntry.encrypt_root: str = "default"` (`core/worklist.py:98`), schema default
  `"default"` (`docs/schemas/worklist.v1.schema.json`, `worklistEntry.encrypt_root`
  enum `["default","on","off"]`).
* `WorklistConfig._resolve_encrypt_root` (`core/worklist.py:305-315`): jetson → False;
  `"on"`/`"off"` → literal; `"default"` → `bool(self.base.encrypt_root)`.
* Manifest v2 (`core/worklist_driver.py:190-195`) writes
  `"encrypt_root": bool(cfg.encrypt_root)` — it **reports** the resolved value.
* Probe on a fresh mesh flow, verbatim:
  `HOME encrypt_root checked=False visible=True  cfg.encrypt_root=False` in **both**
  the node-first and desktop-first runs.

So the manifest carries `true` only when the operator ticked the Home-step box
(`home.py:180-182`) or set a per-row combo to `on` (`gui/pages/worklist.py:355-362`).
The GUI is not failing to reflect a true default; **there is no true default.**

Builder defaults agree: `ENCRYPT_ROOT=false` in x86 (`:329`) and rpi5 (`:290`); only
`--standalone` forces it true.

**Turning it on by default DOES change what a build produces — state this loudly:**

* x86 `--encrypt-root` sets `INSTALLER_ISO=true` (`build-x86-host-stage4.sh:1472`).
  A mesh node that today yields `stage4.tar.xz, live.iso, fs.tar.xz` would also yield an
  **installer ISO**. The `g23-x86-artifacts` GUITHR probe (`check.sh:1113-1116`) pins
  `PLAN_ARTIFACTS` exactly.
* rpi5 `--encrypt-root` is the installer path only (`build-rpi5-stage4.sh:290`).
* jetson **hard-blocks** it — `_check_jetson_conflicts` raises, and
  `_resolve_encrypt_root` already forces jetson off (`core/worklist.py:307-308`). A flat
  default-true on the base config would make `to_cli_args()` raise for any jetson
  single-image flow; the worklist path is safe.
* An encrypted root without `--luks-pass` means the **installer prompts** for a
  passphrase at install time — an unattended fleet install would stall. `luks_pass` is a
  `SECRET_FIELD` (`config.py:466`), never saved, so a saved worklist cannot carry it.

Recommended shape for ask 21's "ALWAYS": force it at the **worklist/mesh** layer
(per-entry `encrypt_root` resolving to on for node-class entries), not as a flat
`ImageConfig` default, so the jetson raise and the single-image standalone flows stay
untouched. If it becomes truly unconditional, the Home-page checkbox becomes a
read-only statement — and `test_pages_home.py:291-298` (jetson no-encrypt) still has to
pass.

### Ask 13 — cached / live-iso / bundle / compress / resume default ON, shown with their artifacts

Current state (probe on a mesh x86 flow, verbatim):

```
BLD 2st cached             checked=False
BLD 2st live_toram         checked=True
BLD 2st bundle_source      checked=True
BLD 2st compress           checked=False
BLD 2st resume             checked=False
BLD tri live_iso           PartiallyChecked
BLD tri build_img          PartiallyChecked
BLD tri build_tar          PartiallyChecked
```

Placement: `cached` `build.py:342`, `live_toram` `:344`, `bundle_source` `:346`,
`compress` `:355`, `resume` `:356` are all in the **"Image options"** section
(`build.py:380`); the artifacts they produce are in the separate **"Artifacts"** section
(`build.py:395-415`). That split is exactly the "side by side" the operator objects to.

| flag | today | default-on emits | what changes in the build |
|---|---|---|---|
| `cached` | False → **`--uncached`** always (probe: `--uncached` PRESENT) | `--cached` | `ISO_CACHED=true` (`x86:403`) — binpkg cache **and** distfiles get embedded in the ISO. Materially larger artifact. **Real change.** |
| `live_iso` | tri `""` → nothing | `--live-iso` | `LIVE_ISO=true` is already the builder default (`x86:243`), so the **image is identical**; only the argv changes. Goldens/GUITHR see a new token. |
| `bundle_source` | already `True` (`config.py:1613`) → `--bundle-source` always (probe PRESENT) | unchanged | **already on.** But see leak L7: scope declares it desktop-class with no enforcement (`config.py:872-873`) — "default on" for a mesh node IS the documented 33MB gap. Asks 13 and 21/L7 collide here; resolve explicitly. |
| `compress` | False → nothing | `--compress` | `xz` over the artifacts THAT builder compresses — the `.img` on x86/rpi5/jetson, the live + installer ISOs on the seven flavor builders (`COMPRESS_IMG` `x86:242`), at preset `--compress-level` (default 9, issue #233). Long build tail; the compressed artifact names gain `.xz`. **Real change.** |
| `resume` | False → nothing | `--resume` | `RESUME=true` (`x86:207`) — **reuses an existing sysroot instead of wiping it**; `scripts/build-menu.sh:644-649` documents that a run WITHOUT `--resume` deliberately wipes. Defaulting this on silently makes every build incremental over whatever tree was left behind. **Highest-risk item in the entire ask list** — surface it as an explicit "reuse the previous build tree" choice, not a silent default. |

`live_toram` (`build.py:344-345`, default True) is a **live-ISO boot entry**, not an
artifact — it belongs with `live_iso` if the sections merge.

---

## 10. PARITY CONTRACTS (may not change unless an ask explicitly removes the option)

1. **`tests/build-matrix/flag-coverage.sh`** — FORWARD (`:16-19`): every builder-parsed
   `--flag)` arm must be emittable by Studio for that platform or explicitly allowlisted
   with a reason. REVERSE (`:20-21`): every Studio-emitted flag must be parsed. Plus
   `:292-296`: **every** `PLATFORM_FIELD_SUPPORT` key must have a SAMPLES entry or the
   script exits 2.
2. **`tests/build-matrix/check.sh` GUITHR** — `GUITHR_EXPECTED=73` (`:963`) is
   fail-closed (`:1293-1294`); each probe runs the config through
   `hugmesh_studio --print-command` and then the REAL builder with `--print-plan`.
   In-scope probes: `g13-explicit-none-services` `:1104`, `g14-all-services` `:1107`,
   `g14-exclude-services` `:1110`, `g23-x86-artifacts` `:1113`,
   `g34-force-off-tristates` `:1126`, `g34-with-character-forge` `:1138`,
   `g13-character-forge-slug-in-services` `:1141`, `g18-person-role-and-domains` `:1042`,
   `g26-identity-x86` `:1066`, `g27-node-fallback-creds` `:1069`, `g32-media-data-set`
   `:1123`, `g15-infra-slugs-rpi5` `:1178`, `g34-no-character-forge-rpi5` `:1185`,
   `g28-local-user-without-standalone` `:1201`.
3. **Flag strings** (contract, not presentation): `--optional-services` (incl. the
   empty-string form), `--all-services`, `--exclude-services`, `--enable-games`,
   `--with-tor`/`--no-tor`, `--with-character-studio`/`--no-…`,
   `--with-character-forge`/`--no-…`, `--with-edge-ai-tts`/`--no-…`,
   `--with-edge-ai`/`--no-edge-ai`, `--with-edge-ai-analysis`, `--with-aide`/`--no-aide`,
   `--snort`/`--no-snort`, `--proxy-stack`/`--no-proxy-stack`, `--managed-service id=ep`,
   `--theme`, `--person-role`, `-H`/`-T`/`-u`, `--user-password`/`--root-password`,
   `--encrypt-root`, `--cached`/`--uncached`, `--live-toram`/`--no-live-toram`,
   `--bundle-source`/`--no-bundle-source`, `--img`/`--no-img`,
   `--live-iso`/`--no-live-iso`, `--tar`/`--no-tar`, `--installer-iso`, `--compress`,
   `--resume`, `--idp-issuer`/`--idp-client-id`/`--idp-jwks`.
4. **Option ids**: `SERVICES_NONE="none"` / `SERVICES_ALL="all"` (`config.py:375-376`);
   `OPTIONAL_SERVICES_CHOICES` (`:352-353`); `INFRA_SERVICES_CHOICES` (`:360`);
   `OPTIONAL_SERVICES_BY_PLATFORM` (`:365-368`); `PERSON_ROLE_CHOICES` (`:382`);
   `X86_NODE_ROLES` (`:387`); `DESKTOP_ROLES` (`:629`); `USER_ROLE_CHOICES`
   (`users.py:24`); `USER_REGISTRATION_CHOICES` (`users.py:30`);
   `WORKLIST_INFRA_SERVICES` (`core/worklist.py:58`); `WIZARD_PAGE_SLUGS`
   (`config.py:105-108`) with the 1:1 ctor assert (`wizard.py:156-158`).
5. **ncurses menu** (`scripts/build-menu.sh`): `OPT_RESUME` `:79`, `OPT_EDGE_AI_TTS`
   `:96`, `OPT_TOR_ONION` `:98`, `OPT_CHARACTER_STUDIO` `:109`, `OPT_CHARACTER_FORGE`
   `:111`, `OPT_SERVICES` `:118`, `OPT_MANAGED_SERVICES` `:126`, `OPT_SA_THEME` `:194`.
   All persisted to a state file (`:227-285`) — renaming a var silently drops a saved
   operator preference.
6. **Worklist schema** `docs/schemas/worklist.v1.schema.json`: per-entry keys
   `id/role/platform/board/flavor/desktop/encrypt_root/packages_add/packages_drop`,
   `encrypt_root` enum `["default","on","off"]` default `"default"`.
   **PRE-EXISTING DRIFT, now proven, not merely suspected:** `WorklistEntry.to_dict`
   (`core/worklist.py:118-127`) ALWAYS writes `infra_services`, and the schema's
   `worklistEntry` sets `"additionalProperties": false` without declaring it. Probe:

   ```
   entry keys:          [... 'infra_services' ...]
   schema entry props:  ['board','desktop','encrypt_root','flavor','id',
                         'packages_add','packages_drop','platform','role']
   additionalProperties: False
   ```

   The only guard, `test_worklist.py:340 test_envelope_conforms_to_frozen_schema`, is
   `pytest.importorskip("jsonschema")` — and `studio/requirements.txt` does not list
   jsonschema, nor does the CI job (`.gitlab-ci.yml:1057` `pip install --quiet pytest
   PySide6`). So it is skipped locally **and in CI**. Every envelope the Studio writes
   today would be rejected by a strict validator (e.g. the admin-bff bean validator the
   schema docstring names). Fix the schema in this track or file it — do not let a
   services/worklist rebuild land on top of it silently.
7. **`docs/STUDIO-WIZARD-FLOW.md:80-86`** is stale (§4) — it is the document a reviewer
   will check the new flow against.

---

## 11. RISKS

1. **The `--no-*` promise is partly false** (§0). Any redo that keeps the current legend
   text keeps shipping a claim the x86 builder does not honour for four flags.
2. **Widget-state edits are no-ops.** `initializePage` re-seeds every control from `cfg`
   on every visit (`network.py:552-643`, `build.py:664-731`). A default change must land
   in `ImageConfig` (or `_TRI_STATES`) and be proven by an **argv** assertion, not a
   `checkState()` assertion.
3. **Base-role gating in mesh is structurally wrong** (`worklist.py:598-600`).
   `SystemPage._node_creds_apply` (`system.py:77-95`) is the only correct precedent.
   Fixing L1/L4/L6 by copying the base-role predicate would re-ship the bug.
4. **Emission-neutrality of new skips.** `applies_to` → False is legal only when every
   field the page emits is already at its mode-correct default (`wizard.py:214-219`).
   Ask 8/19's domains-users skip changes the mesh **manifest**, not the argv — a
   different channel with no such guard.
5. **`boogiepop` deletion breaks the ncurses menu default** (`scripts/build-menu.sh:194`)
   into a builder hard-error (`build-x86-host-stage4.sh:3943`). The theme change must be
   cross-surface: builder docs, menu default, 5 test suites.
6. **No-network / no-downloaded-assets rule** applies to the four new themes AND to any
   new choice-card icon: each `wallpaper.png` / `logo.png` must come from a committed
   deterministic generator script, and icons must be `choice_icons` painter functions.
7. **PyQt6 qFatal.** Every new slot (a domains/users choice-card handler, an opt-in creds
   checkbox, a timezone combo's `currentTextChanged`, a tray submenu action, a
   per-build window) must be exception-guarded and use scoped enum spellings —
   `test_qt_enum_scoping.py` and `progress.py:2200-2210` exist because an escaping
   exception killed the Studio under PyQt6 on Build.
8. **`GUITHR_EXPECTED=73`** (`check.sh:963`) and the `flag-coverage.sh` SAMPLES
   completeness check (`:292-296`) are fail-closed counters; both must be updated in the
   same commit as any field addition/removal.
9. **`--resume` default-on** (ask 13) can silently reuse a stale sysroot. The single most
   dangerous default in the list.
10. **`exclude_services` is the only working subtraction** (§0/§3). Removing the GUI field
    is fine; removing the field/flag would leave no way to turn off an on-by-default
    service.
11. **Ask 20's button would assert accounts nothing creates** (§7). The Studio seeds no
    default users today; either seed them (a manifest change) or have the button state
    the provisioning contract and its key-zip location.
12. **Ask 16 has no single-instance mechanism to build on** (§7). "A Studio is already
    open" is currently undetectable across processes — the dialog the ask describes needs
    a new IPC primitive (`QLocalServer`), which is new attack surface on a machine that
    builds root images. Keep it loopback-only and authenticate it, or scope ask 16 to
    in-process multi-window plus a tray submenu fed from `build_sessions`.
13. **The worklist wire format is already off-schema** (§10.6) and nothing catches it.
    Any change to `WorklistEntry` lands on a broken contract.
