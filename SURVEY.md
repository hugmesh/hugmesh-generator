# SURVEY — Studio wizard redo (asks 1-13). SURVEY ONLY: no behaviour changed.

Base: `origin/main` @ `a923819c`, worktree `.wt/session-scratch/ae563401/wt/SWR-survey`,
branch `feat/studio-wizard-redo`. Builds/docker/qemu PATH-shadowed by `.nobuild-bin/`
(exit 127). Every claim below carries file:line and, where behaviour is asserted, a
verbatim probe result.

Baseline suite (before any change), verbatim:
`4 failed, 3788 passed, 25 skipped, 1 warning in 202.12s` — the 4 failures are all
pre-existing in `studio/tests/test_package_catalog.py` (raw atom totals / roles
invariants / essential-boundary / catalog-json currency) and touch nothing in scope.

---

## 0. THE ONE FINDING THAT REFRAMES ASKS 1, 2 AND 4

The tri-state legend on both pages promises the unchecked box "forces it OFF"
(`network.py:59-73`, `build.py:94-101`) and the tests pin that promise
(`test_pages_identity.py:319` `test_tri_state_force_off_reaches_the_argv`).
**For four of the six service tri-states, the x86 builder does not honour it that way.**

`build-x86-host-stage4.sh` only ever acts on the `true` arm:

```
1103  WANT_TOR="${WANT_TOR:-}"
1104  if [ "${WANT_TOR}" = "true" ] && ${ROLE_CLIENT}; then ... WANT_TOR=false; fi
1108  if [ "${WANT_TOR}" = "true" ]; then    # fold 'tor' into OPTIONAL_SERVICES
```

There is no `WANT_TOR = false` arm anywhere. Same shape for
`WANT_CHARACTER_STUDIO` (:1114-1125), `WANT_CHARACTER_FORGE` (:1131-1141),
`WANT_EDGE_AI_TTS` (:1168-1178) and their rpi5 twins (`build-rpi5-stage4.sh:1088`,
`:1099`, `:1111` — all `= "true"` only). So:

* `--no-tor` **does** override a `brand.conf` that set `WANT_TOR=true`
  (brand.conf is sourced at `build-x86-host-stage4.sh:841`, before the arg loop);
* `--no-tor` **does not** remove `tor` from a `brand.conf` that put the slug into
  `OPTIONAL_SERVICES` — only `EXCLUDE_SERVICES` does, applied last
  (`build-x86-host-stage4.sh:1181-1199`), and `docs/TOR-HIDDEN-SERVICE.md:64` says so
  in as many words: *"Disable (default): omit it; `--exclude-services tor`
  force-removes it."*

Two flags are genuinely different and must not be lumped in:
* `--no-aide` is real subtraction — `WANT_AIDE` is consumed as a plain boolean at
  `:4245` and `:4574`, so false really strips `app-forensics/aide`;
* `--no-edge-ai` is real — `:1081-1082` reads
  `${EDGE_AI} && [ "${WANT_EDGE_AI}" != "false" ] && EDGE_AI_WANT=true`, i.e. it is
  the only way to suppress the `edge_ai` ROLE's auto-selection.

**Consequence for the redo:** for tor / character-studio / character-forge /
edge-ai-tts the operator's "definite unchecked = off" is best served by emitting
NOTHING (the builder default is already off — `OPTIONAL_SERVICES` default is
`akkoma tuwunel phpbb`, `build-x86-host-stage4.sh:134`, and none of those four is in
it). Emitting `--no-*` there is theatre: it changes the argv and nothing else. For
aide and edge-ai the `--no-*` is load-bearing and must be kept reachable.

The ncurses menu already agrees: `scripts/build-menu.sh` carries these as plain
yes/no (`OPT_TOR_ONION="no"` :98, `OPT_CHARACTER_STUDIO="no"` :109,
`OPT_CHARACTER_FORGE="no"` :111, `OPT_EDGE_AI_TTS="no"` :96) and emits only the
positive flag (`:801`, `:823`, `:824`, `:828`). It has **no** `--no-*` and **no**
exclude-services knob at all.

---

## 1. SERVICES — every service toggle

All on `NetworkPage` (`studio/hugmesh_studio/gui/pages/network.py`) unless noted.
"Default today" is the state a fresh wizard shows, confirmed by probe.

| # | control | file:line | widget | state model | emits | default today | builder |
|---|---|---|---|---|---|---|---|
| 1 | Tor v3 onion | `network.py:407-410` (tristate `:409`) | QCheckBox tristate | `''`/`on`/`off` | `` / `--with-tor` / `--no-tor` (`config.py:2675-2679`) | **PartiallyChecked** | folds `tor` into `OPTIONAL_SERVICES` only on true (`x86:1103-1118`); false arm = no-op |
| 2 | Character Studio | `network.py:413-416` (`:415`) | QCheckBox tristate | same | `_character_studio_args` `config.py:2054-2061` | **PartiallyChecked** | `x86:1114-1125`, `rpi5:1088`; false = no-op |
| 3 | Character Forge | `network.py:421-424` (`:423`) | QCheckBox tristate | same | `config.py:2063-2072` | **PartiallyChecked** | `x86:1131-1141`, `rpi5:1099`; false = no-op |
| 4 | Edge-AI TTS | `network.py:431-434` (`:433`) | QCheckBox tristate | same | `config.py:2074-2083` | **PartiallyChecked** | `x86:1168-1178`, `rpi5:1111`; false = no-op |
| 5 | Edge-AI service | `network.py:371-374` (`:373`) | QCheckBox tristate | same | `config.py:2651-2656` | **PartiallyChecked** | `x86:1077-1092`; **false IS honoured** (suppresses the `edge_ai` role auto-select) |
| 6 | Edge-AI analysis API | `network.py:384-386` | plain QCheckBox | bool | `--with-edge-ai-analysis` only (`config.py:2665-2666`) | unchecked | `x86:1143-1150`; folds `edge-ai` too |
| 7 | AIDE IDS | `network.py:354-355` | QCheckBox tristate | same | `--with-aide`/`--no-aide` (`config.py:2637-2641`) | **PartiallyChecked** | `WANT_AIDE=false` `x86:454`, consumed `:4245`,`:4574` — **false honoured** |
| 8 | Snort IDS | `network.py:351` | plain QCheckBox | bool | **always** `--snort` or `--no-snort` (`config.py:2636`) | **checked** (`snort: bool = True` `config.py:1493`) | — |
| 9 | Proxy stack | `network.py:347-350` | QComboBox auto/on/off | 3 values | ``/`--proxy-stack`/`--no-proxy-stack` (`config.py:2632-2635`) | `auto` | — |
| 10 | Optional-services checklist | `network.py:465-472` | QListWidget, per-item checkable | list of slugs | `--optional-services "a b"` (`config.py:2020-2023`) | all unchecked | `x86:134` default `akkoma tuwunel phpbb` |
| 11 | NO optional services (sentinel) | `network.py:456-458` | plain QCheckBox | bool | `--optional-services ""` (`config.py:2016-2017`) | unchecked | explicit none |
| 12 | ALL user-level services | `network.py:459-460` | plain QCheckBox | bool | `--all-services` (`config.py:2018-2019`) | unchecked | expands `USER_LEVEL_SERVICES` `x86:120` |
| 13 | Exclude services | `network.py:475-478` | QLineEdit free text | space/comma list | `--exclude-services "…"` (`config.py:2024-2025`) | empty | subtractive, applied LAST `x86:1181-1199` |
| 14 | Enable games | `network.py:479-481` | plain QCheckBox | bool | `--enable-games` only (`config.py:2700-2701`) | unchecked | `ENABLE_GAMES=false` `x86:158`, folds `games` `:1070-1076` |
| 15 | Egress VPN + lock | `network.py:319-336` | QLineEdit+Browse, QCheckBox | path/bool | `--egress-vpn`, `--egress-vpn-locked` (`config.py:2626-2629`) | empty/unchecked | `x86:3061-3064` role-gated staging only |
| 16 | Managed backing services | `network.py:495-522` | per-id QCheckBox + endpoint QLineEdit | id→endpoint dict | repeatable `--managed-service id=ep` (`config.py:2028-2038`) | none checked | `MANAGED_SERVICES` `x86:155` |
| 17 | Tailnet / SSO | `network.py:253-256` | two plain QCheckBoxes | mode-aware tri (`config.py:1432-1433`) | `--with/--no-tailscale`, `--with/--no-sso` (`config.py:2520-2521`) | seeded from mode (`network.py:581-582`) | — |
| 18 | **Per-node** infra services (mesh worklist) | `gui/pages/worklist.py:373-384`, catalog `:44-51` | per-row QComboBox, `currentData()` = tuple | `()`/`("tor",)`/… | x86 → `tor_onion_service=True`; rpi5 → appends the slug (`core/worklist.py:285-300`) | `—` (empty tuple) | `WORKLIST_INFRA_SERVICES` `core/worklist.py:57` |

Note the contradiction to carry into the redo: `network.py:22-23` and
`_SERVICES_SCOPE_NOTE` (`network.py:88-94`) state "there is deliberately no per-node
service table", but row 18 **is** one (added later, `core/worklist.py:101-104`). The
NetworkPage's own caveat at `network.py:101-104` still says Studio applies tor
mesh-wide. Whatever the redo does with tor must reconcile these three texts.

Platform capability (`config.py:532-546`): `aide`/`edge_ai_*`/`tor_onion_service` are
x86-only; `character_studio`/`character_forge`/`edge_ai_tts`/`optional_services`/
`exclude_services`/`enable_games` are x86+rpi5. Mode gating: `tor_onion` is hidden
outside cloud/mesh (`network.py:634`); the edge-AI SECTION likewise (`network.py:629`);
character-studio/forge/tts are deliberately **not** mode-gated (`network.py:671-673`).

---

## 2. TRISTATE INVENTORY

Probe (`QT_QPA_PLATFORM=offscreen`, fresh mesh x86 `pki` config), verbatim:

```
NET tri aide             state=PartiallyChecked tristate=True
NET tri edge_ai          state=PartiallyChecked tristate=True
NET tri tor_onion        state=PartiallyChecked tristate=True
NET tri character_studio state=PartiallyChecked tristate=True
NET tri character_forge  state=PartiallyChecked tristate=True
NET tri edge_ai_tts      state=PartiallyChecked tristate=True
BLD tri build_img        state=PartiallyChecked
BLD tri live_iso         state=PartiallyChecked
BLD tri build_tar        state=PartiallyChecked
BLD tri secure_boot      state=PartiallyChecked
```

| field | widget | unchecked emits | builder's own default | is `--no-*` load-bearing? | recommendation for "reads as off" |
|---|---|---|---|---|---|
| `tor_onion_service` | `network.py:409` | `--no-tor` | off (`x86:134` set excludes tor) | only vs `brand.conf WANT_TOR=true`; **not** vs `OPTIONAL_SERVICES` | **emit nothing**; two-state, default unchecked (ask 4) |
| `character_studio` | `network.py:415` | `--no-character-studio` | off | same partial | emit nothing |
| `character_forge` | `network.py:423` | `--no-character-forge` | off | same partial | emit nothing |
| `edge_ai_tts` | `network.py:433` | `--no-edge-ai-tts` | off | same partial | emit nothing |
| `edge_ai_service` | `network.py:373` | `--no-edge-ai` | off, **but auto-on for `--role edge_ai`** | **YES** (`x86:1082`) | keep a reachable force-off (unchecked ⇒ `--no-edge-ai` is correct here) |
| `aide` | `network.py:355` | `--no-aide` | `WANT_AIDE=false` `x86:454`, brand.conf can flip | **YES** | keep force-off |
| `build_img` | `build.py:395` | `--no-img` | `BUILD_IMG=true` `x86:231` | **YES** (the only way to skip the .img) | keep |
| `live_iso` | `build.py:397` | `--no-live-iso` | `LIVE_ISO=true` `x86:236` | **YES** | keep; ask 13's "default on" = the box shows checked, which means emitting `--live-iso` (see §9) |
| `build_tar` | `build.py:408` | `--no-tar` | `BUILD_TAR=true` `x86:238` | **YES** | keep |
| `secure_boot` | `build.py:463` | `--no-secure-boot` | `SECURE_BOOT=true` `x86:484` | **YES** | keep |
| `media_data` | `home.py:131-132` (a COMBO, not a checkbox) | `--no-media-data` | on | **YES** | out of the asks; note the idiom inconsistency |
| `sunshine` | not fielded on any page (config-only, `config.py:1541`) | `--no-sunshine` | off | partial | — |

Recorded trap confirmed: `_tri_check` (`build.py:113-129`) calls
`setTristate(True)` **then** `setCheckState(PartiallyChecked)`; `network.py` calls
`setTristate(True)` explicitly at each site. Flipping a default therefore means
changing `_tri_state`/`_TRI_STATES` **and** the `ImageConfig` field default — a widget
edit alone is a no-op because `initializePage` re-seeds from `cfg` every visit
(`network.py:630-643`, `build.py:723-731`).

---

## 3. `exclude_services` — every reference, repo-wide

| surface | ref |
|---|---|
| GUI widget | `studio/hugmesh_studio/gui/pages/network.py:475-478` (create), `:664` (load), `:865` (collect), `:886` (clear list), `:473` (comment) |
| config field | `core/config.py:1518`; capability `:546` (x86+rpi5); emission `:2024-2025` inside `_services_args` `:2010` |
| studio tests | `tests/test_cli_args.py:984-989`, `:1485`; `tests/test_pages_identity.py:201-213` |
| build-matrix | `tests/build-matrix/check.sh:1110-1112` (GUITHR probe `g14-exclude-services`); `tests/build-matrix/flag-coverage.sh:234` (SAMPLES entry) |
| builders | `build-x86-host-stage4.sh:136,564,567,575,872,1181-1199`; `build-rpi5-stage4.sh:220,715,724,734,740,972` |
| stack tests | `tests/stack/test-optional-services-exclude.sh:247,301` (assert the BUILDER accepts the flag) |
| docs | `docs/OPTIONAL-SERVICES.md:29,132,147,148,156`; `docs/TOR-HIDDEN-SERVICE.md:64`; `specs/cluster/optional-services.yaml:32` |
| ncurses menu | **none** — `scripts/build-menu.sh` has no exclude knob (`grep -n "EXCLUDE\|exclude"` → no hits) |
| worklist schema | **none** — `docs/schemas/worklist.v1.schema.json` has no `exclude_services` (it is a base-`imageConfig` field, not a per-entry axis) |

**Recommendation: GUI-only removal. Keep the field, the emission and the flag.**
Evidence:
1. It is the **only** subtractive knob that actually works (§0). `brand.conf`
   `EXCLUDE_SERVICES` is documented as the way to build "forum-less + Matrix-less"
   (`build-x86-host-stage4.sh:142`), and the whole `--all-services` + subtract recipe
   (`docs/OPTIONAL-SERVICES.md:132,148`) depends on it. Deleting the field breaks a
   documented builder recipe the GUI is not the only consumer of.
2. `tests/build-matrix/flag-coverage.sh` FORWARD check (`:17-19`) fails any builder-
   parsed flag arm that no Studio field can emit, unless allowlisted. Dropping the
   field would need TWO new allowlist entries (x86 + rpi5) reading "no longer a GUI
   knob" — which is a claim about the GUI, not about the builder, and weakens the
   differ.
3. The operator's complaint is about the **field on the screen** ("it makes no
   sense" — a free-text slug list next to a checklist that already has none/all).
   Removing the widget satisfies the ask; the flag stays reachable via `-C brand.conf`
   and `extra_flags` (`config.py:1610`).

If the GUI widget goes, `network.py:865` must stop writing `c.exclude_services` (or a
loaded config's list would be silently blanked on every Next) and
`test_pages_identity.py:201` must be rewritten as a config/emission test.
`tests/build-matrix/check.sh:1110` GUITHR probe still passes — it drives the config
JSON directly, not the GUI.

---

## 4. LEAKAGE (ask 3 + ask 11)

### Mesh page sequence, precisely

`WIZARD_PAGE_SLUGS` (`core/config.py:103-106`) is the registration order; page
constructors are pinned 1:1 (`gui/wizard.py:150-158`, assert `:156`).
`MODE_SKIPPED_PAGES["mesh"] = ("role", "hardware")` (`core/config.py:123`).
Dynamic skips via `applies_to` (`gui/wizard.py:229-241`).

Effective mesh order:

1. `welcome`
2. `mode`
3. `localmesh` — skipped (`applies_to` reads `wiz.localmesh_selected`)
4. `phone` — skipped
5. `quest` — skipped
6. `deploy` — skipped
7. `idp`
8. **`role` — statically skipped**
9. `worklist`
10. **`hardware` — statically skipped**
11. `branding`
12. `network`
13. `keyzip`
14. `domains` (`applies_to` → `superadmin_plane_applies` → **always True in mesh**, `config.py:963-964`)
15. `users` (same)
16. `system`
17. `home`
18. `build`
19. `progress`

### The gating bug

`WorklistPage.validatePage` sets the shared base to
`cfg.role = entries[0].role; cfg.platform = "x86"` (`gui/pages/worklist.py:599-600`).
Every desktop-class gate downstream keys on `image_class(cfg.mode, cfg.role)`
(`config.py:647-655`). `ROLE_CHOICES["mesh"]` (`config.py:202-217`) contains two
**desktop-class** roles — `rpi5-desktop` (`:211`) and `jetson-desktop` (`:216`). So a
mesh worklist whose first checked row is one of those makes the whole base
"desktop-class", and every desktop surface unlocks on a mesh flow.

Probe, verbatim (same two runs, only `entries[0].role` differs):

```
=== MESH, base role='pki' (node-first) ===
  HOME login group 'Your login & standalone account'   visibleTo=True  enabled=True
  HOME   standalone checkbox                           visibleTo=False
  HOME   local_user                                    visibleTo=True
  HOME   local_pass                                    visibleTo=True
  HOME media_data combo                                visibleTo=True
  HOME   media_label / no_vaults                       visibleTo=True
  NET  egress_row                                      visibleTo=False
  SYS  creds group                                     visibleTo=True

=== MESH, base role='rpi5-desktop' (DESKTOP-first) ===
  HOME   standalone checkbox                           visibleTo=True   <-- LEAK
  HOME   home mode combo                               visibleTo=True   <-- LEAK
  NET  egress_row                                      visibleTo=True   <-- LEAK
  NET  egress_section                                  visibleTo=True   <-- LEAK
  SYS  creds group                                     visibleTo=False
```

### Standalone-desktop-only fields reachable in the mesh sequence

| # | field | file:line | current gating | why it fails |
|---|---|---|---|---|
| L1 | **`login` group "Your login & standalone account"** (ask 11) | `home.py:145-174` | **NONE on the group.** Only the inner `standalone` checkbox is gated (`home.py:323-325` via `scope_allows`) | The group is a bare `QGroupBox` added to the layout at `:174`; nothing ever calls `setVisible` on it. Its title literally says "standalone account" and it is on screen for **every** mesh node. |
| L2 | `local_user` / `local_pass` | `home.py:168-173`, collected `:364-365` | none | `local_user` defaults to `"magus"` (`config.py:1415`) and `_arm_common_args`/`_x86_args` emit `--local-user` **unconditionally on x86** (`config.py:2507`). Probe: a bare mesh x86 pki argv contains `--local-user`. So the field is not merely visible, it is live. |
| L3 | `standalone` checkbox | `home.py:156-161` | `scope_allows("standalone", cfg)` hide (`home.py:323-325`); scope `classes=("desktop",)`, `class_platforms=("x86","rpi5")` (`config.py:842-843`) | Correct for node-first; **opens** when `entries[0]` is `rpi5-desktop`/`jetson-desktop` because the base platform is forced to `x86` (`worklist.py:600`) so the class rule applies and the role is desktop-class. |
| L4 | Home provisioning group (`home_box`) | `home.py:58-119`, gated `:301-309` | `home_options_allowed` = `image_class == "desktop"` (`config.py:942-945`) — **no mode axis** | Same desktop-first hole. `home_options_allowed` deliberately has no mode axis ("desktop-class images in any mode"), so a mesh flow with a desktop base role gets home mode/device/backup/eCryptfs/seed. |
| L5 | **External media-data device** group (Steam library + gocryptfs Vaults) | `home.py:127-139` | **platform only** (`gate_widgets` `home.py:288-290`, `media_data`/`media_label`/`no_vaults` are `_X86`) | Base platform is forced `x86` in mesh, so the platform gate always passes. There is **no** role-class or mode gate — visible on every mesh node regardless of base role (probe: `visibleTo=True` in BOTH runs). `FIELD_SCOPE` has no entry for `media_data`. |
| L6 | Egress VPN row + lock | `network.py:319-336`, gated `:753-762` | `scope_allows("egress_vpn")`, `classes=("desktop",)` (`config.py:855-857`) | Correct for node-first; opens on desktop-first. |
| L7 | `bundle_source` "Bundle the generator source — self-hosting image (standalone default)" | `build.py:346-347`, gated `:715` | **platform + unaffiliated only** | `FIELD_SCOPE["bundle_source"]` declares `classes=("desktop",)` (`config.py:867-868`) with policy `override` and **no enforcement anywhere** — stated as a known gap at `config.py:800-803`. Default `True` (`config.py:1569`) ⇒ every mesh node argv carries `--bundle-source` (probe confirms) ⇒ 33MB of generator tree on a headless node. |
| L8 | Cached ISO / Live-ISO copy-to-RAM | `build.py:342-345`, gated `:705,:707` | platform only | ISO/desktop-media knobs on a headless node; no role-class axis. |
| L9 | Installer UI combo | `build.py:317-323`, gated `:683-697` | role-class **disable-with-reason** (deliberate, `build.py:679-682`) | Not a leak — documented choice. Listed so the redo does not "fix" it. |
| L10 | Branding desktop half | `branding.py:62-128`, gated `:196-237` | `branding_allowed` = desktop **and** `mode != "mesh"` (`config.py:929-931`) | **Correct** — probe shows `BRAND form enabled=False` in both mesh runs. It is *greyed*, not hidden, which is a presentation choice ask 6 may revisit. |

**Fix location, not widget hiding:** L1/L2/L5 have no scope declaration at all. The
principled fix is `_FIELD_SCOPE_OVERRIDES` entries (`config.py:807-869`) for
`local_user`/`local_pass` and the media-data trio, plus a group-level
`gate_widgets_role_class(..., hide=True)` driven by them — the same idiom `home.py`
already uses for `_home_widgets`. L3/L4/L6 need the *base-role* question answered
differently in mesh: the honest predicate is "does ANY worklist entry want this",
exactly what `SystemPage._node_creds_apply` already does (`system.py:77-95`) — that
is the only page in the flow that reads `wiz.worklist.entries` instead of the base,
and it is the only one that got the mesh answer right in both probe runs.

---

## 5. BRANDING (ask 6)

`studio/hugmesh_studio/gui/pages/branding.py`

* Page skip: `applies_to` (`:164-187`) returns False only for the unaffiliated role.
* Role/platform gate: `:196-198` `enabled = not unaffiliated and branding_allowed(c)
  and platform_supports("theme", c.platform)`; applied as **grey**, not hide,
  `:236-237`.
* **Premade-vs-custom radio**: `QButtonGroup` `:69`, `rb_preset` `:70`, `rb_custom`
  `:71`; default `rb_preset.setChecked(True)` `:142`. Mutual exclusion +
  blanking in `_mode_toggled` `:151-162`: choosing *preset* clears all eight custom
  line edits **and** the accent (`:159-160`); choosing *custom* resets the theme combo
  to index 0 (`:161-162`). `validatePage` re-applies the same split (`:271-286`).
* **Theme combo**: `:78-83`, non-editable (`:79`), items = `""` + `_themes()`;
  rebuilt per-visit `:202-212` with the brand name and any loaded value appended.
  `_themes()` `:144-149` lists `specs-x86/branding/themes/*/` and falls back to
  `["boogiepop"]` on OSError.
* **What exists on disk**: `specs-x86/branding/themes/boogiepop/wallpaper.png` — that
  is the entire theme tree. Probe: `BRAND themes offered = ['', 'boogiepop', 'hugmesh']`
  (`hugmesh` is the brand-derived entry, not a directory).
* **Eight custom fields** `_CUSTOM_FIELDS` `:35-36` = branding_dir, wallpaper,
  grub_background, grub_theme, login_background, brand_logo, color_scheme,
  accent_color. Built `:91-112`. `brand_locked` sits **outside** the either/or `:126`.
* Both-set reconciliation note `:117-123`, applied `:228-234` (custom wins).
* **Web login theme group** — `LoginThemeGroup` (`_logintheme.py:51`), added OUTSIDE
  `self.form` (`branding.py:135-138`) so the desktop gate never touches it; collapsible
  `"Web login theme"`, auto-expanded in mesh (`:243`). Fields: `primary` `:66`,
  `secondary` `:68`, `font_preset` combo `:82-91` (`core_fonts.FONT_PRESETS`),
  `font_file` `:93` + `font_licence` `:114` + `font_source` `:117`, swatch board
  `:128-129`, preview button `:156`. These are `NON_ARGV_FIELDS` (`config.py:604-606`)
  — they theme the login-ui the mesh SERVES; they are NOT the `--theme` name.

### Every consumer of the premade theme NAME

| consumer | ref |
|---|---|
| config field | `core/config.py:1466` `theme: str = ""` → `--theme NAME`; capability x86-only; `THEME_FIELDS` `:640-641`; scope `:808-810` (desktop-class, never mesh) |
| GUI | `branding.py:78-83,144-149,202-215,273` |
| builder | `build-x86-host-stage4.sh:417-423` (`BRANDING_THEME`), resolution `:3872-3898` — **hard error** `:3898` `unknown --theme '<name>' (looked in ${SPECS_DIR}/branding/themes/<name>)`; optional logo `:3766-3767` `themes/<name>/logo.png` |
| ncurses menu | `scripts/build-menu.sh:194` `OPT_SA_THEME="boogiepop"`, emitted `:781`, picker enumerates the theme dirs live `:1799`, unaffiliated suppression `:779-781` |
| docs | `docs/STANDALONE-DESKTOP.md:129,416,432-433,437,440` |
| tests (menu) | `tests/menu/build_menu_cmd_test.sh:67,231,234,241,257` — `:257` asserts `--theme boogiepop` is emitted for the thick sibling |
| tests (matrix) | `tests/build-matrix/check.sh:478-482,1390,1467-1476`; `flag-coverage.sh:191` |
| tests (studio) | `test_cli_args.py:170,1451,1895-1952`; `test_unaffiliated_wizard_surface.py:138,158,161`; `test_wizard.py:726`; `test_pages_home.py:164-177`; `test_headless.py:139` |

**Cost of "remove existing themes, leave light/dark/purple/grey":** `boogiepop` is a
literal in 9 files across 4 test suites and is the ncurses menu's persisted default.
Deleting the directory without touching `scripts/build-menu.sh:194` makes the menu's
default emit `--theme boogiepop` into a builder that hard-errors at
`build-x86-host-stage4.sh:3898`. The four new theme dirs must be **generated by a
committed deterministic script** (no downloaded art) and each needs at least the
`wallpaper.png` that `boogiepop` has, or the resolver stages nothing.

---

## 6. THE FIELD ASKS (7-10)

### Ask 7 — "this devices person role is completely unclear"

* Control: `gui/pages/users.py:86-93` — `QComboBox`, items
  `("derive", *PERSON_ROLE_CHOICES)` = derive/user/mod/admin/superadmin
  (`config.py:380`).
* **Current label, verbatim** (`users.py:92`): `"This device's person role"`.
* **Current help**: there is **no on-page help label**. The only explanation is a
  tooltip (`users.py:88-91`), verbatim:
  `"The person-role this CLIENT image is tied to at build time (--person-role). 'derive' = users[0]'s role in cloud mode, superadmin in mesh mode. Ignored by the builder on cluster NODE roles."`
  This is exactly the failure mode `network.py:62-67` already documented for the
  tri-states ("the meaning existed only as a hover tooltip, which nobody hovers").
* Placement is the deeper problem: a **per-image** build-time identity control sits at
  the bottom of the **superadmin users table** page, under an "Add user / Remove
  selected" button row, with no visual separation (`users.py:72-93`).
* Semantics: emitted only for non-node roles (`config.py:2541-2564`); the builder
  warns and ignores it otherwise (`build-x86-host-stage4.sh:1588`); it defaults to
  `user` in the builder (`:1561-1568`). Platform-gated x86 (`users.py:200`,
  `config.py:506`).

### Ask 8 — users & domains steps

* What decides they show today: `DomainsPage.applies_to` (`domains.py:147-151`) and
  `UsersPage.applies_to` (`users.py:176-180`), both delegating to
  `superadmin_plane_applies` (`config.py:948-967`): **mesh → always True**; cloud →
  True unless the role is an `X86_NODE_ROLES` node; standalone → statically skipped
  via `MODE_SKIPPED_PAGES` (`config.py:117`).
* There is **no "start with additional domains" control anywhere** — `ModePage`
  (`mode.py:66-90`) offers seven build kinds and nothing about domains; grep for
  "additional domain" over the repo returns nothing. Ask 8 needs a **new** opt-in.
* Closest existing prose: `DomainsPage` subtitle (`domains.py:67-71`) — *"Beyond the
  superadmin apex, define the OTHER domains this mesh hosts…"*, and the cloud-only
  prefill of row 0 with the cluster domain (`domains.py:173-174`).
* **Skip must stay emission-neutral** (the documented `applies_to` precondition,
  `wizard.py:214-219`). With both pages skipped, `cfg.domains`/`cfg.users` stay `[]`;
  the mesh manifest then carries empty `domains`/`users` arrays
  (`worklist_driver.py:201-205`). That is a manifest content change for anyone who
  currently relies on the mesh flow always visiting these pages — call it out rather
  than assume it is neutral.

### Ask 9 — hostname / timezone / default user

All on `SystemPage` (`gui/pages/system.py`). Probe: `SYS hostname='' timezone
widget=QLineEdit text='' user=''`.

| field | file:line | widget today | default today |
|---|---|---|---|
| Hostname | `system.py:39-42` | `QLineEdit`, placeholder `"Leave blank to use the role-derived hostname"` | **empty**; `hostname: str = ""` (emits nothing → builder derives, e.g. `${BRAND}-pki` `x86:1213`) |
| Timezone | `system.py:43-46` | **`QLineEdit` — free text**, placeholder `"Area/Location, e.g. Europe/Berlin (leave blank for UTC)"` | **empty** → builder UTC |
| Default user | `system.py:47-51` | `QLineEdit`, placeholder `"Default account name (leave blank for the builder default)"` | **empty** |

Emission: `_identity_args` (`config.py:1963-1973`) — each emits `-H/-T/-u` only when
non-empty, on **every** platform (`config.py:505` all-platform). So preselecting any
of the three **changes the argv of every existing flow** from "omit" to "explicit".
Guarding test: `test_public_polish.py:160-172` asserts the raw flag strings stay out
of the placeholders and inside the tooltips — a dropdown must keep that property.

### Ask 10 — node-fallback baked user + root password

* Group: `system.py:56-74` — `QGroupBox("Node fallback login (mesh nodes)")`, an
  always-present explanatory `QLabel` (`:58-64`), then `user_password` (`:66-69`) and
  `root_password` (`:70-73`), both `EchoMode.Password`, both **always rendered inside
  the group** — there is no opt-in.
* What gates the group today: `gate_widgets_role_class(self.creds,
  self._node_creds_apply(c), _NODE_CREDS_REASON, hide=True)` (`system.py:117-118`).
  `_node_creds_apply` (`:77-95`) is the **only** predicate in the flow that reads
  `wiz.worklist.entries` rather than the base config — deliberately, `:84-88`. Probe
  confirms: visible on a node-first mesh worklist, hidden on a `rpi5-desktop`-first
  one.
* Platform gate: x86-only (`system.py:107-110`, `config.py` `user_password` `_X86`);
  cleared in `validatePage` `:130` and role-class-cleared `:138-140`.
* Secrets: both in `SECRET_FIELDS` (`config.py:464`) — never saved.
* Ask 10 is therefore an **inner opt-in checkbox** inside `self.creds`, not a new
  page-level gate. The existing outer gate is correct and must be preserved.

---

## 7. TESTS THAT WILL BREAK

Names are verbatim. Suite baseline is `4 failed, 3788 passed, 25 skipped`.

**Ask 1/4 (tri-state defaults / definite-off):**
* `tests/test_pages_network_sections.py:109 test_tri_state_boxes_keep_all_three_states`
  — asserts `isTristate()` for aide/edge_ai/tor_onion/character_studio/edge_ai_tts
  AND `tor_onion.checkState() == PartiallyChecked` AND
  `character_studio.checkState() == PartiallyChecked`. **Hard break.**
* `tests/test_pages_network_sections.py:97 test_tri_state_legend_is_visible_not_just_a_tooltip`
  — requires the legend text to contain "part-checked"/"partly", "default", "square".
* `tests/test_pages_identity.py:319 test_tri_state_force_off_reaches_the_argv` —
  requires `--no-tor`, `--no-character-studio`, `--no-edge-ai-tts` in the argv.
* `tests/test_pages_identity.py:345 test_tri_state_part_checked_leaves_the_builder_default`
  — requires the boxes to START part-checked and emit neither flag.
* `tests/build-matrix/check.sh:1126 guithr g34-force-off-tristates` — asserts
  `--no-tor --no-character-studio --no-character-forge` reach the builder. If the
  fields stay tri-state in config (recommended) this probe survives untouched; if any
  field loses its `off` value it must be edited **and** `GUITHR_EXPECTED=73`
  (`check.sh:963`) adjusted.
* `tests/build-matrix/flag-coverage.sh:213,217,222,212` samples `{"…":"off"}` — same
  rule: config-level, survives a GUI-only change.

**Ask 2 (exclude field):**
* `tests/test_pages_identity.py:201 test_exclude_services_subtractive_list` — drives
  `net.exclude.setText(...)`. **Hard break** (attribute gone).

**Ask 3/11 (leakage):**
* `tests/test_pages_home.py` — the whole `_home_widgets`/`standalone`/`encrypt_root`
  visibility family (e.g. `:164-177` theme round-trip, `:291-298` jetson no-encrypt).
* `tests/test_field_scope.py:116,126,133,181,206,233,255,281,301,322,353` — any new
  `_FIELD_SCOPE_OVERRIDES` entry must satisfy
  `test_the_declared_narrowings_actually_narrow` (`:133`) and
  `test_no_class_narrowing_reaches_a_builder_that_has_no_roles` (`:255`), and any
  scope declared without an enforcing predicate trips
  `test_theme_field_scope_matches_branding_allowed` / `…home_options_allowed`
  patterns (`:116`,`:126`).
* `tests/test_scope_violations.py:116 test_bundle_source_default_is_a_leak_not_a_violation`
  — pins the L7 gap **open**. Closing L7 breaks this test by design.
* `tests/test_pages_network_sections.py:237,246 test_out_of_scope_egress_section_leaves_no_orphan_header` / `test_in_scope_egress_section_is_shown_and_usable`.
* `tests/test_wizard.py:118,314` — the slug→page map and the `__all__` order assert.

**Ask 5/13 (services + build page rebuild):**
* `tests/test_pages_network_sections.py:158,177,188,198,206,220,227,237,246,253,265,296,316,327,337,348,367,380,391` — 19 tests keyed on the exact section
  set, their default expansion, and "collapsing changes no argv".
* `tests/test_pages_build_sections.py:108,121,139,151,163,184,203,222,231,246,262,276,302,315,325,339,349,360,371` — 19 tests keyed on the Artifacts/Image-options
  split, "no dropdowns left", tri-state round-trip, and section membership.
  `:108 test_artifact_and_sb_toggles_are_all_checkboxes_no_dropdowns_left` and
  `:203 test_every_section_is_collapsible` will need updating if Artifacts and Image
  options merge (ask 13).
* `tests/test_pages_identity.py:174,189,216,226,251,272,282,306` — the sentinel /
  catalog / client-note family.

**Ask 6 (branding):**
* `tests/test_pages_home.py:164,177` (theme-vs-custom either/or via the branding page).
* `tests/test_unaffiliated_wizard_surface.py:138,158,161`.
* `tests/menu/build_menu_cmd_test.sh:231-241,257` — the `OPT_SA_THEME=boogiepop`
  persisted default and `assert_has "thick sibling: theme intact" "--theme boogiepop"`.
  **This is the one that bites hardest if the directory is deleted.**
* `tests/build-matrix/check.sh:478-482,1390,1467-1476` and
  `flag-coverage.sh:191` — all carry the literal `boogiepop`.
* `studio/tests/test_cli_args.py:170,1451,1895,1903,1918,1939,1950-1952`,
  `test_wizard.py:726`, `test_headless.py:139`.

**Ask 7/8/9/10:**
* `tests/test_pages_identity.py:369,379,391,398` — person-role derive/override/choices/
  ARM-clear. `:391 test_person_role_offers_exactly_the_builder_accepted_roles` pins the
  combo contents.
* `tests/test_pages_identity.py:478,496,506,514` (domains) and `:412,430,444,460`
  (users) — all assume the pages are reachable in the current flows.
* `tests/test_public_polish.py:160 test_system_and_network_placeholders_humanized` —
  reads `sysp.timezone.placeholderText()`; a `QComboBox` has no `placeholderText()`
  unless editable. **Hard break** on a naive dropdown swap.
* `tests/test_wizard.py` mode-flow tests (`test_standalone_flow_skips_admin_pages`
  and the mesh-flow walk) — any new dynamic skip changes the visited-page set;
  `wizard.collect_all` only reads visited pages (`wizard.py:243-256`).
* `tests/build-matrix/check.sh:1069 guithr g27-node-fallback-creds` and
  `:1066 g26-identity-x86` — config-level, survive a GUI opt-in, but must be re-read
  if any default becomes non-empty.

---

## 8. PARITY CONTRACTS (may not change unless an ask removes the option)

1. **`tests/build-matrix/flag-coverage.sh`** — FORWARD: every builder-parsed `--flag)`
   arm must be emittable by Studio for that platform or explicitly allowlisted with a
   reason (`:17-19`, allowlist `:44-70`). REVERSE: every Studio-emitted flag must be
   parsed (`:20-21`). Plus `:296-300`: **every** `PLATFORM_FIELD_SUPPORT` key must have
   a SAMPLES entry or the script exits 2.
2. **`tests/build-matrix/check.sh` GUITHR** — `GUITHR_EXPECTED=73` (`:963`) is
   fail-closed; the probe list `:1027-…` runs each config through
   `hugmesh_studio --print-command` and then the REAL builder with `--print-plan`.
   In-scope probes: `g13-explicit-none-services` `:1104`,
   `g14-all-services` `:1107`, `g14-exclude-services` `:1110`,
   `g23-x86-artifacts` `:1113` (pins `PLAN_ARTIFACTS=stage4.tar.xz,live.iso,installer.iso,fs.tar.xz`),
   `g34-force-off-tristates` `:1126`, `g34-with-character-forge` `:1135`,
   `g13-character-forge-slug-in-services` `:1138`, `g18-person-role-and-domains` `:1042`,
   `g26-identity-x86` `:1066`, `g27-node-fallback-creds` `:1069`,
   `g32-media-data-set` `:1123`.
3. **Flag strings** (contract, not presentation): `--optional-services` (incl. the
   empty-string form), `--all-services`, `--exclude-services`, `--enable-games`,
   `--with-tor`/`--no-tor`, `--with-character-studio`/`--no-…`,
   `--with-character-forge`/`--no-…`, `--with-edge-ai-tts`/`--no-…`,
   `--with-edge-ai`/`--no-edge-ai`, `--with-edge-ai-analysis`,
   `--with-aide`/`--no-aide`, `--snort`/`--no-snort`, `--proxy-stack`/`--no-proxy-stack`,
   `--managed-service id=ep`, `--theme`, `--person-role`, `-H/-T/-u`,
   `--user-password`/`--root-password`, `--encrypt-root`, `--cached`/`--uncached`,
   `--live-toram`/`--no-live-toram`, `--bundle-source`/`--no-bundle-source`,
   `--img`/`--no-img`, `--live-iso`/`--no-live-iso`, `--tar`/`--no-tar`,
   `--installer-iso`, `--compress`, `--resume`.
4. **Option ids**: `SERVICES_NONE="none"` / `SERVICES_ALL="all"` (`config.py:373-374`);
   `OPTIONAL_SERVICES_CHOICES` (`:350-351`); `INFRA_SERVICES_CHOICES` (`:358`);
   `OPTIONAL_SERVICES_BY_PLATFORM` (`:363-366`); `PERSON_ROLE_CHOICES` (`:380`);
   `USER_ROLE_CHOICES` (`users.py:24`); `USER_REGISTRATION_CHOICES` (`users.py:30`);
   `WORKLIST_INFRA_SERVICES` (`core/worklist.py:57`).
5. **ncurses menu** (`scripts/build-menu.sh`): `OPT_TOR_ONION` `:98`,
   `OPT_CHARACTER_STUDIO` `:109`, `OPT_CHARACTER_FORGE` `:111`, `OPT_EDGE_AI_TTS` `:96`,
   `OPT_SERVICES` `:118`, `OPT_MANAGED_SERVICES` `:126`, `OPT_SA_THEME` `:194`,
   `OPT_RESUME` `:79`. Persisted to a state file (`:227-250`) — renaming a var
   silently drops a saved operator preference.
6. **Worklist schema** `docs/schemas/worklist.v1.schema.json`: per-entry keys
   `id/role/platform/board/flavor/desktop/encrypt_root/packages_add/packages_drop`,
   `encrypt_root` enum `["default","on","off"]` default `"default"` (`:43-47`).
   `infra_services` is in `WorklistEntry.to_dict` (`core/worklist.py:125`) but is
   **absent from the published schema** — a pre-existing drift worth flagging.
7. **`WIZARD_PAGE_SLUGS` ↔ page-ctor 1:1 assert** (`wizard.py:156-158`) — adding or
   removing a page requires both lists **and** `MODE_SKIPPED_PAGES`.

---

## 9. ASKS 12 & 13 — what the evidence actually says

### Ask 12 — "rot encryption should be a mesh device default"

**The premise that "the session manifest already carries encrypt_root true per image"
is not what the code does.** Chain, verbatim:

* `ImageConfig.encrypt_root: bool = False` (`config.py:1552`).
* `WorklistEntry.encrypt_root: str = "default"` (`core/worklist.py:98`), schema default
  `"default"` (`worklist.v1.schema.json:43-47`).
* `WorklistConfig._resolve_encrypt_root` (`core/worklist.py:302-312`): jetson → False;
  `"on"`/`"off"` → literal; `"default"` → `bool(self.base.encrypt_root)`.
* Manifest v2 (`core/worklist_driver.py:190-195`) writes
  `"encrypt_root": bool(cfg.encrypt_root)` — it **reports** the resolved value, it does
  not force it.
* Probe on a fresh mesh flow: `HOME encrypt_root.isChecked()=False  cfg.encrypt_root=False`
  in **both** the node-first and desktop-first runs.

So the manifest carries `true` only when the operator ticked the Home-step box
(`home.py:180-182`) or set a per-row combo to `on` (`gui/pages/worklist.py:355-362`).
The GUI is not failing to reflect a true default; **there is no true default**.

Builder defaults agree: `ENCRYPT_ROOT=false` in x86 (`:322`), rpi5 (`:283`), frite
(`:208`), jetson (`:194`); only `--standalone` forces it true
(`x86:1368`, `rpi5:1252`, `frite:546`, `jetson:516`).

**Turning it on by default DOES change what a build produces — state this loudly:**

* x86 `--encrypt-root` sets `INSTALLER_ISO=true` (`build-x86-host-stage4.sh:1465`).
  So a mesh node that today yields `stage4.tar.xz, live.iso, fs.tar.xz` would also
  yield an **installer ISO**. The `g23-x86-artifacts` GUITHR probe
  (`check.sh:1113-1116`) pins `PLAN_ARTIFACTS` exactly.
* rpi5 `--encrypt-root` is the installer path only (`build-rpi5-stage4.sh:283`).
* jetson **hard-blocks** it — `Studio._check_jetson_conflicts` raises
  (`config.py:2408-2426`) and `_resolve_encrypt_root` already forces jetson off
  (`core/worklist.py:308`). A flat default-true on the base config would make
  `to_cli_args()` raise for any jetson single-image flow; the worklist path is safe.
* An encrypted root without `--luks-pass` means the **installer prompts** for a
  passphrase at install time (`config.py:2196-2205`, `home.py:194`) — an unattended
  fleet install would stall. `luks_pass` is a `SECRET_FIELD` (`config.py:464`), never
  saved, so a saved worklist cannot carry it.

Recommended shape: default the **worklist/mesh** posture on (per-entry `encrypt_root`
resolving to on for node-class entries), not the flat `ImageConfig` default, so the
jetson raise and the single-image standalone flows stay untouched.

### Ask 13 — "cached iso, live iso, bundle, compress and resume default on, presented with their artifacts"

Current state (probe on a mesh x86 flow, verbatim):

```
BLD 2-state cached        checked=False    BLD tri live_iso  state=PartiallyChecked
BLD 2-state live_toram    checked=True     BLD tri build_img state=PartiallyChecked
BLD 2-state bundle_source checked=True     BLD tri build_tar state=PartiallyChecked
BLD 2-state compress      checked=False
BLD 2-state resume        checked=False
```

Placement: `cached`/`live_toram`/`bundle_source`/`compress`/`resume` are in the
**"Image options"** section (`build.py:342-362`, section `:380`); the artifacts they
produce are in the separate **"Artifacts"** section (`build.py:390-416`). That split is
exactly the "side by side" the operator is asking for.

Per-flag consequence of defaulting ON:

| flag | today | default-on emits | what changes in the build |
|---|---|---|---|
| `cached` | False → **`--uncached`** always (`config.py:2774`) | `--cached` | `ISO_CACHED=true` (`x86:396`) — the binpkg cache **and** distfiles get embedded in the ISO. Materially larger artifact. Real change. |
| `live_iso` | tri `""` → nothing | `--live-iso` | `LIVE_ISO=true` is already the builder default (`x86:236`), so the **image is identical**; only the argv changes. Goldens/GUITHR see a new token. |
| `bundle_source` | already `True` (`config.py:1569`) → `--bundle-source` always | unchanged | **already on.** But see leak L7: `FIELD_SCOPE` declares it desktop-class with no enforcement (`config.py:800-803`, `:867-868`) — "default on" for a mesh node is the documented 33MB-of-generator-tree gap. Asks 12/13 and leak L7 collide here; resolve explicitly. |
| `compress` | False → nothing | `--compress` | `xz -9` every finished image (`x86:235 COMPRESS_IMG`). Long build tail; artifact names gain `.xz`. Real change. |
| `resume` | False → nothing | `--resume` | `RESUME=true` — **reuses an existing sysroot instead of wiping it** (`x86:200`; `scripts/build-menu.sh:644-649` documents that a run WITHOUT `--resume` deliberately wipes). Defaulting this on silently makes every build incremental over whatever tree was left behind. This is the highest-risk item in the whole ask list; recommend surfacing it as an explicit "reuse the previous build tree" choice rather than a silent default. |

Also note `live_toram` (`build.py:344-345`, default True) is a **live-ISO boot entry**,
not an artifact — it belongs with `live_iso` if the sections merge, and its
unconditional emission (`config.py:2775`) is the same shape as `cached`.

---

## 10. RISKS

1. **The `--no-*` promise is partly false** (§0). Any redo that keeps the current
   legend text keeps shipping a claim the x86 builder does not honour for four flags.
2. **Widget-state edits are no-ops.** `initializePage` re-seeds every control from
   `cfg` on every visit (`network.py:552-643`, `build.py:664-731`). A default change
   must land in `ImageConfig` (or the `_tri_state`/`_TRI_STATES` maps) and be proven
   by an argv assertion, not a `checkState()` assertion.
3. **Base-role gating in mesh is structurally wrong** (`worklist.py:599-600`).
   `SystemPage._node_creds_apply` (`system.py:77-95`) is the only correct precedent.
   Fixing L1/L4/L6 by copying the base-role predicate would re-ship the bug.
4. **Emission-neutrality of new skips.** `applies_to` → False is only legal when every
   field the page emits is already at its mode-correct default (`wizard.py:214-219`).
   Ask 8's domains/users skip changes the mesh **manifest**, not the argv — a different
   channel with no such guard.
5. **`boogiepop` deletion breaks the ncurses menu default** (`scripts/build-menu.sh:194`)
   into a builder hard-error (`build-x86-host-stage4.sh:3898`). Theme rename must be a
   cross-surface change: builder docs, menu default, 4 test suites.
6. **No-network / no-downloaded-assets rule** applies to the four new themes: each
   `wallpaper.png` (and any `logo.png`) must come from a committed deterministic
   generator script.
7. **PyQt6 qFatal.** Every new slot (a "start with additional domains" toggle, an
   opt-in creds checkbox, a timezone combo's `currentTextChanged`) must be
   exception-guarded — `test_qt_enum_scoping.py` and the tray/choice-card precedent
   exist because an escaping exception kills the Studio under PyQt6, not under PySide6.
8. **`GUITHR_EXPECTED=73`** (`check.sh:963`) and the `flag-coverage.sh` SAMPLES
   completeness check (`:296-300`) are fail-closed counters; both must be updated in
   the same commit as any field addition/removal or the matrix goes red for the wrong
   reason.
9. **`--resume` default-on** (ask 13) can silently reuse a stale sysroot. Treat as the
   single most dangerous default in the list.
10. **`exclude_services` is the only working subtraction** (§0/§3). Removing the GUI
    field is fine; removing the field/flag would leave no way to turn off an
    on-by-default service.
