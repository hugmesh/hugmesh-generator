# Go-Live: export a domain's repositories to a GitHub organisation

An **optional** step of the Go-Live wizard. The step is hidden until a domain names a
GitHub organisation; every mesh built before the field existed sees exactly the pages it
always did.

The ask it answers: *"export the needed repositories in a domain to a given github org
that can be configured as part of the domain in studio; the github org will have a
github site repo called `<yourdomain>.github.io` and it will clone all the repos and
build actions from the hugmesh project; copy over the existing code in the repos and
rename as needed."*

Everything here is generic. The names below — `mesh.example`, `exampleorg`, `example`
— are placeholders; the real values come from the Domains step, a config file, or
command-line arguments. No organisation or domain is built in.

## 1. Tell a domain its organisation

On the **Domains** step (image flow, or the generate-a-local-mesh route) every row —
the mesh's own domain included — has a **GitHub org** cell. Type the organisation's
slug (letters, digits, single hyphens, at most 39 characters; e.g. `exampleorg`).
It is a slug, never a token: when the export runs it signs in as **you**, with your
own `gh auth login` and git credential helper.

The text-mode front end has the same control: `o NUMBER ORG` on an added row,
`o own ORG` for the mesh's own domain (`o 1 ORG` on the local-mesh step, where row 1 is
the own domain), `o NUMBER -` to clear.

Where the value lives:

| Flow | Field | Saved shape |
| --- | --- | --- |
| image flow, added row | `Domain.github_org` | `domains[].github_org`, omitted when empty |
| image flow, own domain | `ImageConfig.cluster_domain_github_org` | omitted when empty; also in the mesh manifest (both the per-image v1 shim and the format-2 envelope a fleet build writes, byte for byte) |
| local mesh | the own `Domain` row and every added row | the saved mesh's `config.domains[].github_org`, omitted when empty |

An untouched configuration therefore keeps its bytes: no key appears anywhere until an
org is typed. A saved mesh re-opened in the Studio (Saved meshes -> Load) shows every
org in its cells again, and the next save or bring-up records them again; a non-slug in
a hand-edited record is dropped on load, like a `tor` that is not `true`.

A GitHub org that is not a slug is refused on **Next**, inline and never in a dialog,
on both routes (image flow and local mesh) with one sentence; the typed text stays in
the cell for you to fix, and never reaches the state or a record.

## 2. Plan

Open the Go-Live wizard (`python -m hugmesh_studio --go-live`, or the Studio's menu).
After **Generate** the step **Export to GitHub org** appears when at least one saved
mesh on this machine names an org, or when you add a config file on the step itself
(an export config, an image config or a saved-mesh record).

**Plan** is the default and the only thing that runs without a confirmation. It:

1. computes the repository set of the domain — the same map the Repo-source step's
   *Code folders* block shows (`core/code_folders.py`): every first-party compose
   build context the mesh builds (the platform apps), plus what the domain's selected
   optional services add — for the mesh's own domain that is its row's selection AND
   the mesh-wide *Services* step's list, because the per-row selection is recorded and
   the Services step is what the mesh actually runs — minus stock images; then the Java build chain
   (`hugmesh-build-config`, `hugmesh-parent`, `hugmesh-commons`, `hugmesh-auth-core`)
   and the generator itself, both of which the config can drop;
2. snapshots each repository's **default branch** (`origin/HEAD`, else `origin/main`,
   else `HEAD`) with `git archive` — no history — into `<out>/work/<new name>/`. It
   reads the checkout as it is on this machine and **never fetches or pulls it**:
   update your checkouts first if the export should hold newer work;
3. drops `CLAUDE.md`, `.claude/`, `.stack-src`, `node_modules`, build output and
   secret-shaped files and lists each one. The names dropped are `*.pem`, `*.key`,
   `*.p12`, `*.pfx`, `*.jks`, `*.keystore`, `*.p8`, `.env` and `.env.*`, `id_rsa*`,
   `id_ed25519*`, `id_ecdsa*`, `.netrc`, `.pypirc`, `.git-credentials`, `.htpasswd`,
   `.yarnrc.yml`, `*.secret`, `*credentials*.json`, `*.kubeconfig`, `*.tfstate`,
   `*.tfstate.backup`, `*.tfvars` and `.docker/config.json` (only at that path: a
   `config.json` anywhere else is ordinary configuration). `*.asc` is decided by its
   first line: a PGP public key block stays (the generator's build scripts read the
   distribution's release key from one), any other `.asc` is dropped. The list is
   names only — a secret kept in a file with an ordinary name is found, if at all, by
   the banned-marker scan below.
   Two names are decided by content: an `.npmrc` is dropped only when it holds a
   login (`_authToken`, `_auth=`, `_password`, or a user part written into a URL such
   as `registry=https://user:token@host/` or `proxy=http://user:pass@host:3128`), so a
   token-free one such as
   `legacy-peer-deps=true`, which a Dockerfile may `COPY`, stays; and `.env.example`,
   `.env.sample` and `.env.template` stay (every other `.env.*` is dropped). An
   `.npmrc` that holds only a placeholder such as `${NPM_TOKEN}` still counts as a
   login and is dropped, and one the export cannot read is dropped too, named in the
   plan as `unreadable .npmrc (could hold a login)`. A Dockerfile that `COPY`s a
   dropped `.npmrc` then breaks: the plan lists the drop, not the dangling `COPY`;
4. **refuses** a repository, naming the file, when a banned marker is found in what
   would be published: a co-author trailer, a tool footer, an assistant session link,
   an API key (a GitHub token of 36 or more characters after its `ghp_` / `gho_` /
   `ghu_` / `ghs_` / `ghr_` prefix, a `github_pat_` token, an AWS access key, a Slack
   token), a PEM private-key header followed by a key body (the tests cover `BEGIN RSA
   PRIVATE KEY`, `BEGIN OPENSSH PRIVATE KEY`, an encrypted PKCS#8 key and a PGP
   `PRIVATE KEY BLOCK`, and the tests also run openssl and gpg to write real ones). The header may sit
   anywhere in a line, so an indented YAML block or a quoted value is found; the line
   break after it may be the two characters backslash and `n`, which is how a
   service-account JSON file or a one-line environment value spells a key; header
   lines such as `Proc-Type: 4,ENCRYPTED` and `DEK-Info:` (a passphrase-protected
   OpenSSL key) or `Version:` (PGP) may come between the header and the body; and
   quotes, `+`, `#`, `//`, `*` and backticks may sit in front of the lines (a key split
   across Java or JavaScript string pieces, or written as a comment). The body must
   run to at least 32 base64 characters, so a test's stand-in such as
   `...KEY-----\nQUJD` is not a key (a real first body line is 64 to 76 characters).
   The bare header strings a compiled program such as an engine's `.wasm` carries are
   not a key. A key whose body is split into pieces shorter than 32 characters, or
   one with something other than the characters above between its lines, is NOT
   recognised, so look for such a file yourself before the real export), a URL with a
   literal password of 16 or more characters (`https://user:<long secret>@host`; placeholders such as
   `user:$(PASSWORD)@host` and short test logins are left alone, because the
   platform's own manifests are full of them). EVERY kept file is scanned as bytes:
   one that is not valid UTF-8 is scanned with replacement characters, one with NUL
   bytes is scanned a second time with the NULs removed (UTF-16 text), and one that
   cannot be read or is over 128 MiB is itself a finding, so nothing is skipped
   silently. A file that is not UTF-8 text is published byte for byte, never rewritten;
   the plan says so when such a file names a renamed token;
5. renames: `hugmesh-<name>` becomes `<brand>-<name>` (`exampleorg -> example`, so
   `hugmesh-gateway -> example-gateway`); inside files the org path segment
   (`ghcr.io/hugmesh/`, `github.com/hugmesh/`, `maven.pkg.github.com/hugmesh/`,
   `hugmesh/hugmesh-<name>` owner/repo references) and every exported repository's
   name are rewritten, exact-token and idempotent (a second run changes nothing);
6. generates the site repository `<domain>.github.io` (below);
7. writes `<out>/org-export-plan.txt` and `.json` and shows the table: source,
   target `<org>/<name>`, create / update / exists / refused, kind, files, how many
   files were rewritten, how many excluded. The action column comes from asking `gh`
   whether each target exists. A plan made with `--no-probe`, or one where `gh` gave
   no answer (not installed, not signed in, no network), prints **`not looked at`**
   for that row: it has not checked, so it says neither `create` nor `exists`, and
   apply looks at the repository itself.

Two repositories that would be exported to the **same** target name (two entries of the
rename map's `repos` table with one value, an `extra_repos` name equal to a branded
target such as `example-parent`, or a name equal to the site repository's) are refused
as a problem before anything is written; GitHub names are not case-sensitive, so
`dup` and `DUP` count as one.

Deliberately **not** renamed, and said so in every plan: Java packages and Maven
groupIds (`net.hugmesh`), Angular package scopes (`@hugmesh/*`), Kubernetes label
keys and API groups (`hugmesh.net/*`), compose service / systemd unit / script names
that are not a repository name, file and directory names, the cluster domain. Maven
*artifactIds* that equal a repository name are renamed with it, so the exported chain
is consistent — and the exported Java apps build only after that chain has been
published from the new organisation (each library carries its release workflow).

The plan also lists, per repository, the ref and commit it snapshots (the checkout's
default branch — `origin/HEAD`, else `origin/main`, else `HEAD` — never the branch that
happens to be checked out) and who the snapshot commits are authored as.

### Extending the rename map

`--rename-map FILE` (CLI), the **Rename map** field of the GUI step, or `r FILE` on the
text-mode step (`r -` drops it) merge a JSON file over the defaults — and over the
`rename_map` of a config file the step was pointed at, so both apply:

```json
{
  "repos":        { "hugmesh-generator": "example-platform" },
  "tokens":       [ { "pattern": "\\bOld Brand\\b", "replace": "Example", "note": "prose" } ],
  "skip_rewrite": [ "LICENSE", "docs/history/*" ],
  "exclude":      [ "hugmesh-generator:tests/scripts/test-with-an-example-token.sh" ]
}
```

`repos` overrides a target name; `tokens` are extra regex rewrites run after the
defaults; `skip_rewrite` globs name files whose contents are left alone (they are still
scanned for banned markers; only `exclude` keeps a file out of the scan); `exclude`
globs drop files from the snapshot altogether — what a banned-marker refusal points
at when the marker is an example token in a test script. A glob written
`<repo>:<glob>` applies to one source repository; a bare glob to every one.

### The generator's own tree needs two exclusions

The generator is exported by default (`include_generator`), and its own tree holds two
test fixtures the banned-marker scan refuses — correctly, they look exactly like
secrets: a fake AWS key in `tests/cloud-deploy/test-cloud-deploy-driver.sh` and, in
`tests/scripts/test-stack-clone-credential.sh`, a fake fine-grained token and a fake
`gho_` token. Without an
exclusion every plan that includes the generator is `refused: banned marker` for it.
The ready-made map `studio/tests/fixtures/org_export/generator-rename-map.json` drops
exactly those two files:

```json
{ "exclude": [ "hugmesh-generator:tests/cloud-deploy/test-cloud-deploy-driver.sh",
               "hugmesh-generator:tests/scripts/test-stack-clone-credential.sh" ] }
```

Point the Rename map field (GUI), `r FILE` (TUI) or `--rename-map` (CLI) at it, or
merge its `exclude` list into your own map. `test_org_export.py` scans this checkout's
own tree with that map on every run, so a new fixture carrying a marker turns a test
red here before it blocks an export.

### Pointing the step at a config file

Every value has one type, and a wrong one is a message, never a crash or a silent
misreading: text for `domain`, `org`, `brand`, `visibility`, `update`, the folders,
`author_*`, `remote_base`, `ref` and `site_title`; a list of text for `optional_services`,
`extra_repos` and `skip_repos`; `true` or `false` for `include_generator` and
`include_build_libraries` (a `"no"` would be truthy); an object for `rename_map`, whose
`tokens` need text `pattern` and `replace` that compile. From a terminal that is exit 2
naming the key; in the GUI and the text-mode step the file is refused inline and not
added.

The GUI step's **Config file -> Add** and the TUI's `c FILE` accept an export config, an
image config or a saved-mesh record. A generic export config is taken WHOLE: its
`skip_repos`, `include_generator`, `include_build_libraries`, `extra_repos`, `brand`,
`rename_map`, `out_dir`, `visibility` and `update` all reach the plan (the visibility and
existing-repository pickers are seeded from it and stay editable).

### The *Terminal* line

The step's *Terminal* field (the TUI's "The same from a terminal:" line) is the same
export as a command: EVERY candidate's file — a saved-mesh record, an image config or an
export config — is handed over as `--config FILE --domain <domain>`, because the
domain's selected services and a file's rules live only there (a line spelling just
`--domain D --org O` plans without them). Every picker you change over the file (source
folder, visibility, existing repositories, plan folder, rename map) is added as a flag
only where it differs from what the file alone would give, so the line parses back to
exactly the configuration the step plans — a test pins that field for field, and an
end-to-end scenario runs the line and compares its repositories with the table. Before
Plan the field shows the PLAN form; after Plan the same words plus `--apply`.

## 3. Apply

In the GUI, **Apply** is armed only by typing the organisation's name into the
confirmation field (inline; no dialog; letter case does not matter, as GitHub slugs
are case-insensitive). Apply runs exactly the plan on screen, so changing anything that
shapes the plan after Plan (the domain, visibility, existing-repository choice, source
folder, plan folder or rename map, or adding a config file) clears that plan and
disarms Apply until you press Plan again, and the typed name is cleared with it, so
a name typed for one plan (a private one, say) never arms a later one (the same
repositories, made public): type it again for each plan. The text-mode step does the
same: `apply <org>` carries the name in the command. In the
text-mode step it is `apply <org>`.
From a terminal it is `--org-export APPLY --apply`.

A plan is applied **once**. In the GUI Apply stays off after a run, and retyping the
name does not arm it again; in the text-mode step a second `apply <org>` on the same
plan answers `this plan was applied; plan again (p) to run again`. To run again, plan
again (which also asks for the name again). A re-run of the same export is safe and
reports `unchanged` for every repository whose `main` already holds the snapshot.

For every repository that is not blocked, apply:

* creates the target with `gh repo create <org>/<name> --private` when it does not
  exist (visibility is a plan field: private by default, `public` or `internal` on
  request; an existing repository's visibility is never changed);
* stages the snapshot folder with `git add --force`, so no ignore rule (the
  snapshot's own `.gitignore`, your global `core.excludesFile`) can leave a tracked
  file out, and checks that the commit holds exactly the files the plan counted: a
  commit that holds fewer is reported skipped and never pushed. This is the only
  `--force` the export uses, it is local, and it touches no remote;
* commits the snapshot once, authored as **you** — the git identity of the person
  running the export (`git config user.name` / `user.email`), unless the config names
  `author_name` / `author_email`. No person is built in. With neither, apply refuses
  BEFORE creating anything: every repository is reported skipped with git's own
  "Author identity unknown" reason and the organisation is left untouched;
* pushes it to `main` with a plain `git push` — **never** `--force`, never a delete,
  never a mirror. The commit is named by its sha as soon as it is made, and the
  file count, the scan of the commit's objects, the tree and the push all use that
  sha, never `HEAD`: the work folder is an ordinary directory, and a commit added to
  it after the scan is not what gets pushed. The push sends that one refspec with
  `--no-follow-tags` and `--no-verify`, so a tag or a pre-push hook added to the work
  folder's own git config after the scan sends nothing with it. Every ref of the
  remote is listed right before the push and read back with `git ls-remote` after it;
  a branch that holds anything but that sha, a branch that cannot be read, or any
  other ref that changed in between is reported as skipped (the remote may then
  already hold it: check by hand);
* on an existing non-empty repository: reports **unchanged** when `main` already
  holds exactly the snapshot tree, otherwise **refuses** — also when the content lives
  on another branch (`master`, say) and there is no `main` at all: apply lists every
  branch of the target and takes `gh`'s own "not empty" answer into account, so it
  never pushes a new `main` into a repository that already holds something — unless
  the plan chose *update via branch*, in which case it pushes `export/<stamp>` and
  opens nothing;
* writes `<out>/org-export-result-<stamp>.json`: every repository, its URL, the commit
  and what was skipped, so a run can be audited and re-run.

## 4. The site repository `<domain>.github.io`

Generated, not copied — `hugmesh.github.io` is this org's documentation site; the
export creates a small new repository:

| File | What it is |
| --- | --- |
| `repos.json` | every exported repository: name, source, build kind (`java` / `angular` / `none`), visibility, URL |
| `index.html` | a page listing them, read from `repos.json` |
| `.github/workflows/build-all.yml` | one matrix job per repository: `actions/checkout` of `<org>/<name>` (the `EXPORT_READ_TOKEN` secret for private repositories), then, for Java, `./mvnw -B verify` (plain `mvn -B verify` for a repository that ships no `mvnw`, such as the shared build-config jar; `repos.json` records which) with the settings file `repos.json` records for that repository (`-s .github/maven-ci-settings.xml` for the CI settings file) and the package-registry login in `UPSTREAM_PACKAGES_ACTOR` / `UPSTREAM_PACKAGES_TOKEN` (from the `PACKAGES_READ_ACTOR` / `PACKAGES_READ_TOKEN` secrets), and for Angular `npm ci` / `npm run build` / `npm test` (Karma, ChromeHeadlessCI) |
| `.github/workflows/pages.yml` | publishes the site with GitHub Pages (`configure-pages` / `upload-pages-artifact` / `deploy-pages`) |

Both workflows run on `${{ fromJSON(vars.RUNS_ON || '"ubuntu-latest"') }}`, the way
the org's release workflows do. The org holds no composite GitHub Actions
(`hugmesh-actions` is a Java service; no `action.yml` or `workflow_call` exists on any
default branch), so the build steps are spelled inline, following the repositories'
`release.yml` files. For a Java repository the build passes the settings file that can
work from GitHub: `.github/maven-ci-settings.xml` when the repository has one; else
the repository-root `settings.xml` when it is not the GitLab registry file (the GitLab
one reads `CI_API_V4_URL` and cannot work from GitHub); else none. The export records
the choice per repository in `repos.json` (`.github/maven-ci-settings.xml`,
`settings.xml`, or empty), and the plan notes a repository whose only settings file is
the GitLab one, because its private parent POMs will not resolve; a Java repository
with no settings file at all gets no note. Only the CI settings file needs the read
token: the build stops early, naming `PACKAGES_READ_TOKEN`, when it is empty. Third-party actions are pinned at the same level the existing
workflows pin them (`@v4`, `@v5`).

## 5. From a terminal

```sh
# plan from the domain/org directly (checkouts under ~/src/hugmesh-*)
python -m hugmesh_studio --org-export PLAN --domain mesh.example --org exampleorg \
    --source-dir ~/src --out /tmp/export-mesh.example

# plan from a config file (an export config, an image config or a saved-mesh record);
# any flag overrides the file: --source-dir/--source-mode, --out, --visibility,
# --update refuse|branch (= --update-via-branch), --brand, --remote-base
python -m hugmesh_studio --org-export PLAN --config export.json --rename-map extra.json

# apply: the explicit flag is the confirmation; without it APPLY prints the plan and refuses
python -m hugmesh_studio --org-export APPLY --config export.json --apply
```

A generic config file:

```json
{
  "domain": "mesh.example",
  "org": "exampleorg",
  "brand": "",
  "visibility": "private",
  "update": "refuse",
  "source_mode": "existing",
  "source_dir": "/home/someone/src",
  "optional_services": [],
  "extra_repos": [],
  "skip_repos": [],
  "include_generator": true,
  "include_build_libraries": true,
  "rename_map": { "repos": {}, "tokens": [], "skip_rewrite": [] },
  "out_dir": ""
}
```

Exit codes: 0 clean; 1 the plan is blocked or a repository was skipped; 2 bad input.

## 6. Rehearsing offline

The whole flow is proven without the network: `studio/tests/test_org_export.py` runs
the engine against bare git repositories in a temp folder standing in for GitHub and a
fake `gh` on PATH that records its calls; `test_org_export_gui.py` and
`test_org_export_tui.py` drive both front ends over the same stand-ins, and
`test_org_export_neutrality.py` is the guard that keeps this feature free of any real
organisation's name. To rehearse your own export the same way, point `--remote-base`
at a `file:///…/` folder of bare repositories and put a fake `gh` first on `PATH`.

The end-to-end record of the design choices is the Gherkin feature
`tests/e2e/features/studio-org-export/studio-org-export.feature` (steps in
`tests/e2e/steps/studio-org-export.steps.ts`), driven by
`tests/e2e/studio-org-export-driver.py`: the REAL Studio wizards offscreen — the
local-mesh Domains step for typing, saving and re-opening an org, the Go-Live wizard
for the export step — with a folder of bare repositories as GitHub, a fake `gh` and a
logging `git` shim first on PATH, so every assertion reads what was created, pushed and
logged rather than the Studio's own say-so. Run them with
`cd tests/e2e && SNAP_STUDIO_PYTHON=<python with PySide6 or PyQt6> npx bddgen test &&
QT_QPA_PLATFORM=offscreen npx playwright test --project=bdd -g "exports a domain's repositories"`
(the `-g` filter is a case-sensitive regex over the generated titles; this one matches
the feature's title and selects every scenario in it). They need no mesh, no network and
start nothing.

## 7. What a person must still do

* The first real run needs `gh auth login` with an account that can create
  repositories in the organisation, and the organisation's settings must allow it.
  Creating a repository goes through `gh`, but the snapshot is pushed with a plain
  `git push` over https, which needs a credential helper: run `gh auth setup-git`
  once (it adds gh as git's credential helper for github.com in your global git
  config), or put the helper line `credential.helper = !gh auth git-credential` in
  your git config yourself.
* Repository secrets on `<domain>.github.io`: `EXPORT_READ_TOKEN` (reads the private
  exported repositories), `PACKAGES_READ_TOKEN` (a classic token with
  `read:packages`; Maven reads the exported library chain from the org's package
  registry, and the Java jobs stop with a clear message when it is missing),
  `PACKAGES_READ_ACTOR` (its user name, optional) and, if wanted, the `RUNS_ON` variable.
* Publish the exported Java library chain from the new organisation (each library's
  `release.yml`) before the site's build job can verify the Java apps.
* Enable Pages on the site repository (Settings -> Pages -> Source: GitHub Actions).
  GitHub serves an **organisation** Pages site only from a repository named exactly
  `<org>.github.io`; `<domain>.github.io` is any other name, so it is served as a
  **project** site under the organisation's path
  (`https://<org>.github.io/<domain>.github.io/`), not at the domain's own name. The
  generated page reads `repos.json` by a relative path, so it works from that
  sub-path.
