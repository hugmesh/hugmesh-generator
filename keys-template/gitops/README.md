# KEYS/gitops — ArgoCD repository credential

This directory carries the **ArgoCD git credential** for the **private**
`hugmesh-generator` GitOps repo, on the offline KEYS stick. The real cluster's
`bootstrap.sh` registers it before ArgoCD tries to clone.

## Layout

```
KEYS/gitops/
└── repo-token   a fine-grained, READ-ONLY GitHub PAT (repo:read on
                 hugmesh-generator only) — one line, no trailing newline
                 needed (whitespace is stripped on read)
```

## Why it exists

`hugmesh-generator` is a **private** GitHub repo. Without a repository
credential, **every** git-path ArgoCD `Application` (vault, casdoor,
harbor-provision, forgejo, and the root app-of-apps itself) fails to sync with
`authentication required ... Repository not found`.

`keys-provision` (`specs/etc/keys-provision/provision.sh`, `provision_hugmesh()`)
reads this file and hands it to `specs/cluster/bootstrap/bootstrap.sh` as
`ARGOCD_REPO_TOKEN` for that one run. It is not exported to later steps. This
runs only on a control-plane node with `hugmesh.gitops.enabled` true. The script
creates the `hugmesh-generator-repo` k8s Secret (labeled
`argocd.argoproj.io/secret-type=repository`, `username=x-access-token`,
`password=<token>`, `url=<repo>`) in the `devops` namespace **before** it applies
the app-of-apps. The token is **never printed** and **never committed**.

The KEYS-relative path defaults to `gitops/repo-token`. Override it with
`hugmesh.gitops.repo_token_file` in `provision.json`.

## Custody (NEVER git)

Same offline custody as `vault/token`, `certs/cluster-ca.key`, and `luks.key`.
The token file lives **only** on the physical KEYS USB stick, written there by the
operator. **Do not commit a real token.** Only this README (the wiring
documentation) belongs in the repo.

- Prefer a **fine-grained PAT** scoped read-only to just `hugmesh-generator` over
  a broad personal token in long-lived cluster storage.
- **Rotation** = overwrite `KEYS/gitops/repo-token` with a new PAT and re-run
  provisioning (`bootstrap.sh` re-applies the Secret idempotently). A finished
  node skips provisioning unless `KEYS_FORCE=1` is set or a `.provision-force`
  file is on the stick.
- Absent / empty ⇒ `bootstrap.sh` **fails closed** with a clear error naming this
  file. A `PUBLIC` fork that needs no credential opts out with
  `ARGOCD_REPO_PUBLIC=1`. keys-provision logs a warning and carries on. Only
  `bootstrap.sh` exits non-zero.
