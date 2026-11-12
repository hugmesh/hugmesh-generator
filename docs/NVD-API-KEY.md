# NVD API key for OWASP Dependency-Check

The SCA step of the pen-test harness and every repository's CI `sca` job run OWASP
Dependency-Check. Dependency-Check downloads the NVD CVE feed from the US National
Vulnerability Database, and it needs a free **NVD API key** to do that. A new key works
only after you click the activation link in NVD's email.

This page covers why the key is needed, how to request and activate one, how to verify it,
where it is stored, how to set it as an organisation secret safely, and what each
failure looks like.

## 1. Why the key is needed

Dependency-Check downloads the NVD CVE feed, which holds about 420,000 records (421,929 on
2026-11-10). Without a key, NVD allows a client **5 requests per 30 seconds**. With a key
the limit is 50. Dependency-Check 13's own defaults are
`nvd.api.requestsperthirtysecondswithoutapikey=5` and `...withapikey=50`.

In practice a keyless run does not finish. It ends in exit 13 with only
`[ERROR] Unable to continue dependency-check analysis.` in the log. The exact reason has
not been measured: it may be throttling, retry exhaustion, or NVD now demanding a key. Every
lane below has been seen failing that way. **Treat the key as required.**

The lanes that need it:

| Lane | Where | How the key reaches Dependency-Check |
| --- | --- | --- |
| GitLab `sca:dependency-check` (20-repo matrix) | generator `.gitlab-ci.yml` | `NVD_API_KEY` CI variable -> a private `--propertyfile` |
| GitLab `.pentest-sca` / every repo's `pentest:sca` | `tests/pentest/ci/pentest-stage.gitlab-ci.yml` | the same |
| GitHub Actions `sca (OWASP Dependency-Check)` | `hugmesh-forum-bff-api/.github/workflows/ci.yml` | `NVD_API_KEY` org secret |
| Studio Fleet window, pen-test ticked | Studio -> Fleet build -> Pen-test harness | the stored key -> a per-run 0600 copy -> `NVD_API_KEY_FILE` |
| `make pentest` / `make build-all PENTEST=1` | generator `Makefile` | `NVD_API_KEY_FILE=/path/to/file` |
| `tests/pentest/dependency-check/run-sca.sh` | the shared wrapper | `NVD_API_KEY_FILE` (preferred) or `NVD_API_KEY` |
| GitLab `sca` stage in `hugmesh-games` | `hugmesh-games/.gitlab-ci.yml` -> its own `tests/pentest/dependency-check/run-sca.sh` | `NVD_API_KEY` CI variable -> a private `--propertyfile` once hugmesh/hugmesh-games#68 lands (before it: `--nvdApiKey` on argv, and the key is called optional) |
| each repository's `make pentest-sca` | per-repo `Makefile` | not wired yet (follow-up): runs keyless and its failure is swallowed |

## 2. Request a key

Request a key at <https://nvd.nist.gov/developers/request-an-api-key>. It is free, and NVD
emails it to the address you give.

## 3. Activate it

**A new key does not work until you click the activation link in NVD's email.** After you
click, allow a few minutes before it is accepted.

Until then NVD refuses the key exactly as it refuses a wrong one:

- the API answers `HTTP 404` with a response header `message: Invalid apiKey.`;
- Dependency-Check logs `NvdApiException: Invalid API Key: XXXXX-*****-XXXXX` and exits 13.

**An invalid key and a key that is not activated yet look identical.** If you requested
the key only minutes ago, activate it and wait. If it has been longer than that, request a
new one.

## 4. Verify it

The easiest way is the Studio's **Verify** button, in the Fleet window's Pen-test harness
box. The same check is available from the TUI (`nvd verify`) and the CLI:

```sh
python -m hugmesh_studio.core.nvd_key verify
```

Verify sends the key **once** to `services.nvd.nist.gov` and asks for one CVE record. This
is the only outside call the key box makes. Verify follows no redirect (a redirect could
carry the key to another host), and its result names one of these verdicts:

| Verdict | NVD's answer | What to do |
| --- | --- | --- |
| accepted (`OK`) | `200` with the CVE JSON (`totalResults`) | nothing. The key works. |
| not accepted yet (`NOT_ACCEPTED`) | `404` + `message: Invalid apiKey.` | If you just requested the key, click the activation link in NVD's email and retry in a few minutes. If it has been longer, request a new key. |
| rate-limited (`RATE_LIMITED`) | `403` or `429` | Retry in 30 seconds. The key was not judged. This shape is assumed, not measured. |
| NVD unavailable (`NVD_UNAVAILABLE`) | `5xx`, a redirect, a `404` without the `message` header (an HTML page), or a `200` that is not the CVE JSON | NVD has an endpoint problem. This is not a verdict on the key. Retry later. |
| offline (`OFFLINE`) | no answer: DNS, timeout, refused, TLS | Check the network or VPN. The key was not tested. |
| empty / not a key | refused locally, nothing sent | A key is 8-4-4-4-12 hexadecimal digits (a UUID). NVD itself answers a malformed key exactly like an unknown one. |

To verify **by hand** without putting the key in your shell history:

```sh
read -rs K
curl -s -o /dev/null -w '%{http_code}\n' -H "apiKey: $K" \
  'https://services.nvd.nist.gov/rest/json/cves/2.0?resultsPerPage=1'
unset K
```

`200` means the key is accepted. `404` means it is not accepted yet.

Two traps when checking by hand:

- If `$K` is empty, `-H "apiKey: "` makes curl **drop the header entirely**, and you get
  `200`, as if an empty key were fine. Check that `$K` is not empty first.
- A key with a trailing space is refused (`404`). Strip pasted whitespace.

## 5. Where the key is stored

- **Studio:** in `~/.hugmesh/studio/secrets/nvd_api_key` (`$HUGMESH_STUDIO_STATE_DIR/secrets/` when that is
  set). The directory is 0700 and the file is 0600, written atomically. The file holds the
  key with no newline. Beside it, `nvd_api_key.meta.json` keeps only a 12-hex PBKDF2 fingerprint, when
  the key was saved, and the last Verify verdict.

  The key is never written into a saved fleet or image config, a session record, a log,
  argv, the command preview, or the Local AI assistant's context. The assistant's
  deny-list names the file.

  When a fleet run includes the pen-test, the Studio copies the key to a private 0600 file
  for that run only. It passes the **path** to the script as `NVD_API_KEY_FILE`; on the
  Docker leg that path is a read-only mount at `/run/secrets/nvd_api_key`. The copy is
  deleted when the run ends. Its directory (`$TMPDIR/hugmesh-nvd-*`, 0700) holds an
  owner lock for the run's whole life, so a copy a crash or a `kill -9` left behind is
  removed the next time the Studio starts, the same sweep the held-key, domain-CA and
  login-password copies get. A live run's copy is never touched, and a directory younger
  than two minutes is left alone.
- **GitHub:** the organisation secret `NVD_API_KEY`, with visibility **all**. The
  release/CI templates read this name.
- **GitLab:** a group CI/CD variable `NVD_API_KEY`, **masked** and **protected**. There is
  no Studio action for GitLab: set it in the group's Settings -> CI/CD -> Variables.

The Studio has a box for the key in three places:

- **GUI:** the Fleet window, Pen-test harness group, shown once a pen-test is ticked. The
  same box appears on the Go-Live "Export to GitHub org" step.
- **TUI:** `python -m hugmesh_studio.tui --fleet`, then `nvd`. Use `nvd set`, then type the
  key on the hidden line that follows. It is masked, never echoed, and never added to any
  history. The same `nvd` commands work on the Go-Live export step.
- **CLI:**

  ```sh
  python -m hugmesh_studio.core.nvd_key status
  python -m hugmesh_studio.core.nvd_key set            # hidden prompt (terminal only)
  python -m hugmesh_studio.core.nvd_key set --key-file - < keyfile
  python -m hugmesh_studio.core.nvd_key verify         # exit 0 OK, 3 not accepted, 4 offline/unavailable, 5 rate-limited
  python -m hugmesh_studio.core.nvd_key forget
  python -m hugmesh_studio.core.nvd_key push-org-secret --org ORG [--yes]
  ```

  There is no flag that takes the key on the command line. With no terminal and no
  `--key-file`, `set` refuses with exit 2.

The Single image Build page's "OWASP pen-test" box does **not** run a pen-test: only the
fleet lane reads `PENTEST=1`. That page says so and points at the Fleet window.

## 6. Set the GitHub organisation secret safely

`gh secret set NVD_API_KEY --org <org> --visibility all` reads the value from **stdin**
when stdin is not a terminal. An **empty** stdin stores an **empty** secret, and gh reports
no error. On 2026-11-10 this happened twice when the command was run from a non-interactive
shell. The CI job then ran keyless and failed with exit 13.

To set it safely, use one of these:

- run the command in a **real terminal** and let gh prompt you for the value; or
- feed it from a file you checked is not empty:

  ```sh
  test -s keyfile && gh secret set NVD_API_KEY --org <org> --visibility all < keyfile
  ```

  The file should be 0600. Make sure it has no trailing newline, or strip it first. `--body-file`
  (newer gh) works the same way; or
- use the Studio's **Also set as GitHub org secret NVD_API_KEY** row, or
  `python -m hugmesh_studio.core.nvd_key push-org-secret --org <org>`. These refuse an
  empty or malformed key before running gh, and they pass the value only on gh's stdin.
  They also refuse a key whose last Verify was not accepted, unless you tick
  "set anyway" (`--yes`). They always send the **stored** key: the GUI refuses while
  the key box still holds a different key (press Save first, or clear the box), and the
  success line names the key it sent by its fingerprint (`from the stored key
  (fingerprint 534d…657a)`, four and four characters of the PBKDF2 hash, never of the
  key).

Then confirm the secret was written. The value itself cannot be read back:

```sh
gh api /orgs/<org>/actions/secrets/NVD_API_KEY --jq '.updated_at,.visibility'
```

This proves that a write happened, not that the value is non-empty. The client-side
refusal above is what guards against an empty value. Setting an organisation secret needs
a token with `admin:org`: run `gh auth refresh -s admin:org` if gh answers 403.

## 7. What failure looks like

| Situation | Dependency-Check log | Exit |
| --- | --- | --- |
| no key, or an empty secret | `[ERROR] Error updating the NVD Data` ... `NvdApiRetryExceededException: NVD Update Failed: attempted to retrieve data from the NVD unsuccessfully five times.` ... `[ERROR] Unable to continue dependency-check analysis.` | 13 |
| key wrong or not activated yet | `NvdApiException: Invalid API Key: XXXXX-*****-XXXXX` then `[ERROR] Unable to continue dependency-check analysis.` / `[ERROR] No documents exist` | 13 |
| key accepted | `NVD API has 421,929 records in this update` (the number grows) | 0, unless there is a finding |

The wrappers now say which case you are in:

- `run-sca.sh` refuses an unset, empty or malformed key before it starts Dependency-Check.
  On exit 13 it prints the activation sentence or the key/feed sentence.
- `run-pentest.sh` logs `SCA: DID NOT RUN / FAILED (exit N) — <reason>`, and the
  scorecard shows that as a row. It used to drop the SCA step silently.
- The GitLab jobs fail early with `the NVD_API_KEY CI variable is empty or unset`.

## 8. CI logs show part of the key

Dependency-Check prints the key's **first and last five characters** when NVD refuses it
(`Invalid API Key: 33333-*****-77777`).

- `run-sca.sh` passes everything Dependency-Check prints through a filter that blanks that
  pattern (`Invalid API Key: [NVD key redacted]`) before it reaches the terminal **or**
  `<out>/dependency-check.log`, the copy that stays on disk after a local or Studio run.
  Every other line, and the `Invalid API Key` cause, is kept.
- The Studio also blanks that pattern, and the stored key, from every fleet log line,
  `fleet.log`, the session's error tail and the assistant's context.
- CI jobs that call Dependency-Check directly (the GitLab `sca:dependency-check` and
  `.pentest-sca` jobs, and the GitHub Actions `sca` job) are **not** redacted that way. If
  you share a CI log, treat those ten characters as part of the key.

The wrappers no longer put the key on a command line. It used to be passed as
`--nvdApiKey KEY`, which is readable by every user in `/proc/<pid>/cmdline` and in
`docker inspect`. It now goes in a private Dependency-Check property file
(`nvd.api.key=...`) that is deleted when the run ends. On the Docker leg that file is
mounted read-only. It is 0644 inside a 0700 directory, because the
`owasp/dependency-check` image runs as uid 1000, which cannot read a 0600 file owned by
another user (measured).
