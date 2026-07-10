# KEYS/gitops — ArgoCD repository credential

This directory carries the **ArgoCD git credential** for the **private**
`snapdragon-generator` GitOps repo onto the offline KEYS stick, so the real
cluster's `bootstrap.sh` can register it before ArgoCD tries to clone.

## Layout

```
KEYS/gitops/
└── repo-token   a fine-grained, READ-ONLY GitHub PAT (repo:read on
                 snapdragon-generator only) — one line, no trailing newline
                 needed (whitespace is stripped on read)
```

## Why it exists

`snapdragon-generator` is a **private** GitHub repo. Without a repository
credential, **every** git-path ArgoCD `Application` (vault, casdoor,
harbor-provision, forgejo, and the root app-of-apps itself) fails to sync with
`authentication required ... Repository not found`.

`keys-provision` (`specs/etc/keys-provision/provision.sh`, `provision_snapdragon()`)
reads this file, exports it as `ARGOCD_REPO_TOKEN`, and hands it to
`specs/cluster/bootstrap/bootstrap.sh`, which creates the
`snapdragon-generator-repo` k8s Secret (labeled
`argocd.argoproj.io/secret-type=repository`, `username=x-access-token`,
`password=<token>`, `url=<repo>`) in the `devops` namespace **before** applying
the app-of-apps. The token is **never printed** and **never committed**.

The KEYS-relative path defaults to `gitops/repo-token`; override it with
`snapdragon.gitops.repo_token_file` in `provision.json`.

## Custody (NEVER git)

Same offline custody as `vault/token`, `certs/cluster-ca.key`, and `luks.key`:
the token file lives **only** on the physical KEYS USB stick, written there by
the operator. **Do not commit a real token** — only this README (wiring
documentation) belongs in the repo.

- Prefer a **fine-grained PAT** scoped read-only to just `snapdragon-generator`
  over a broad personal token in long-lived cluster storage.
- **Rotation** = overwrite `KEYS/gitops/repo-token` with a new PAT and re-run
  provisioning (`bootstrap.sh` re-applies the Secret idempotently).
- Absent / empty ⇒ `bootstrap.sh` **fails closed** with a clear error naming
  this file (a `PUBLIC` fork that needs no credential opts out with
  `ARGOCD_REPO_PUBLIC=1`).
