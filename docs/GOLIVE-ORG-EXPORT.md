# Go-Live: export a domain's repositories to a GitHub organisation

An **optional** step of the Go-Live wizard. It is dark until a domain names a GitHub
organisation; every mesh built before the field existed sees exactly the pages it
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
| image flow, own domain | `ImageConfig.cluster_domain_github_org` | omitted when empty; also in the mesh manifest |
| local mesh | the own `Domain` row and every added row | the saved mesh's `config.domains[].github_org`, omitted when empty |

An untouched configuration therefore keeps its bytes: no key appears anywhere until an
org is typed.

## 2. Plan

Open the Go-Live wizard (`python -m hugmesh_studio --go-live`, or the Studio's menu).
After **Generate** the step **Export to GitHub org** appears when at least one saved
mesh on this machine names an org, or when you add a config file on the step itself
(an export config, an image config or a saved-mesh record).

**Plan** is the default and the only thing that runs without a confirmation. It:

1. computes the repository set of the domain — the same map the Repo-source step's
   *Code folders* block shows (`core/code_folders.py`): every first-party compose
   build context the mesh builds (the platform apps), plus what the domain's selected
   optional services add, minus stock images; then the Java build chain
   (`hugmesh-build-config`, `hugmesh-parent`, `hugmesh-commons`, `hugmesh-auth-core`)
   and the generator itself, both of which the config can drop;
2. snapshots each repository's **default branch** (`origin/HEAD`, else `origin/main`,
   else `HEAD`) with `git archive` — no history — into `<out>/work/<new name>/`;
3. drops `CLAUDE.md`, `.claude/`, `.stack-src`, `node_modules`, build output and
   secret-shaped files (`*.pem`, `*.key`, `.env`, `id_rsa*`, …) and lists each one;
4. **refuses** a repository, naming the file, when a banned marker is found in what
   would be published: a co-author trailer, a tool footer, an assistant session link,
   an API key, a private-key header;
5. renames: `hugmesh-<name>` becomes `<brand>-<name>` (`exampleorg -> example`, so
   `hugmesh-gateway -> example-gateway`); inside files the org path segment
   (`ghcr.io/hugmesh/`, `github.com/hugmesh/`, `maven.pkg.github.com/hugmesh/`,
   `hugmesh/hugmesh-<name>` owner/repo references) and every exported repository's
   name are rewritten, exact-token and idempotent (a second run changes nothing);
6. generates the site repository `<domain>.github.io` (below);
7. writes `<out>/org-export-plan.txt` and `.json` and shows the table: source,
   target `<org>/<name>`, create / update / exists / refused, kind, files, how many
   files were rewritten, how many excluded.

Deliberately **not** renamed, and said so in every plan: Java packages and Maven
groupIds (`net.hugmesh`), Angular package scopes (`@hugmesh/*`), Kubernetes label
keys and API groups (`hugmesh.net/*`), compose service / systemd unit / script names
that are not a repository name, file and directory names, the cluster domain. Maven
*artifactIds* that equal a repository name are renamed with it, so the exported chain
is consistent — and the exported Java apps build only after that chain has been
published from the new organisation (each library carries its release workflow).

### Extending the rename map

`--rename-map FILE` (CLI) merges a JSON file over the defaults:

```json
{
  "repos":        { "hugmesh-generator": "example-platform" },
  "tokens":       [ { "pattern": "\\bOld Brand\\b", "replace": "Example", "note": "prose" } ],
  "skip_rewrite": [ "LICENSE", "docs/history/*" ],
  "exclude":      [ "hugmesh-generator:tests/scripts/test-with-an-example-token.sh" ]
}
```

`repos` overrides a target name; `tokens` are extra regex rewrites run after the
defaults; `skip_rewrite` globs name files whose contents are left alone; `exclude`
globs drop files from the snapshot altogether — what a banned-marker refusal points
at when the marker is an example token in a test script. A glob written
`<repo>:<glob>` applies to one source repository; a bare glob to every one.

## 3. Apply

In the GUI, **Apply** is armed only by typing the organisation's name into the
confirmation field (inline; no dialog). In the text-mode step it is `apply <org>`.
From a terminal it is `--org-export APPLY --apply`.

For every repository that is not blocked, apply:

* creates the target with `gh repo create <org>/<name> --private` when it does not
  exist (visibility is a plan field: private by default, `public` or `internal` on
  request; an existing repository's visibility is never changed);
* commits the snapshot once, authored as the operator (`Usi Diamond
  <28960829+UsiDiamond@users.noreply.github.com>` by default; `author_name` /
  `author_email` in the config);
* pushes it to `main` with a plain `git push` — **never** `--force`, never a delete,
  never a mirror;
* on an existing non-empty repository: reports **unchanged** when `main` already
  holds exactly the snapshot tree, otherwise **refuses** — unless the plan chose
  *update via branch*, in which case it pushes `export/<stamp>` and opens nothing;
* writes `<out>/org-export-result-<stamp>.json`: every repository, its URL, the commit
  and what was skipped, so a run can be audited and re-run.

## 4. The site repository `<domain>.github.io`

Generated, not copied — `hugmesh.github.io` is this org's documentation site; the
export creates a small new repository:

| File | What it is |
| --- | --- |
| `repos.json` | every exported repository: name, source, build kind (`java` / `angular` / `none`), visibility, URL |
| `index.html` | a page listing them, read from `repos.json` |
| `.github/workflows/build-all.yml` | one matrix job per repository: `actions/checkout` of `<org>/<name>` (the `EXPORT_READ_TOKEN` secret for private repositories), then what the repository's own CI runs — `./mvnw -B -s settings.xml verify` for Java, `npm ci` / `npm run build` / `npm test` (Karma, ChromeHeadlessCI) for Angular |
| `.github/workflows/pages.yml` | publishes the site with GitHub Pages (`configure-pages` / `upload-pages-artifact` / `deploy-pages`) |

Both workflows run on `${{ fromJSON(vars.RUNS_ON || '"ubuntu-latest"') }}`, the way
the org's release workflows do. The org holds no composite GitHub Actions
(`hugmesh-actions` is a Java service; no `action.yml` or `workflow_call` exists on any
default branch), so the build steps are spelled inline, taken from the repositories'
own `ci.yml` files. Third-party actions are pinned at the same level the existing
workflows pin them (`@v4`, `@v5`).

## 5. From a terminal

```sh
# plan from the domain/org directly (checkouts under ~/src/hugmesh-*)
python -m hugmesh_studio --org-export PLAN --domain mesh.example --org exampleorg \
    --source-dir ~/src --out /tmp/export-mesh.example

# plan from a config file (an export config, an image config or a saved-mesh record)
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

## 7. What a person must still do

* The first real run needs `gh auth login` with an account that can create
  repositories in the organisation, and the organisation's settings must allow it.
* Repository secrets on `<domain>.github.io`: `EXPORT_READ_TOKEN` (reads the private
  exported repositories), `PACKAGES_READ_TOKEN` (Maven reads the exported library
  chain from the org's package registry) and, if wanted, the `RUNS_ON` variable.
* Publish the exported Java library chain from the new organisation (each library's
  `release.yml`) before the site's build job can verify the Java apps.
* Enable Pages on the site repository (Settings -> Pages -> Source: GitHub Actions).
