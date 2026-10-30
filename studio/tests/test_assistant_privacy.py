"""The assistant's privacy wall: deny-list, redaction, and no canary anywhere.

A fixture tree plants a CANARY-<name> string in every denied path; the Where block,
the docs index, a code-edit file preview and the catalogue text are built over that
tree and none of them may contain any canary. Each DENY entry is shown to match at
least one planted path (dropping any one of them is a red test). Each redaction
pattern has its own case, and redact() is idempotent and keeps the line count.
"""
import os
import re

import pytest

from hugmesh_studio.core import assistant_catalogue as acat
from hugmesh_studio.core import assistant_code_edits as aedit
from hugmesh_studio.core import assistant_context as ac
from hugmesh_studio.core import assistant_docs as adocs

PLANTED = {
    # relative to <generator>
    "gen:keys-out/node1/wg.key": "keys-out",
    "gen:keys-2026/x.json": "keys-star",
    "gen:.e2e-credentials": "e2e-credentials",
    "gen:tests/stack/.env": "stack-env",
    # relative to <home>
    "home:.hugmesh/mesh-node/.env": "mesh-node-env",
    "home:.hugmesh/keyzip/admin.zip": "keyzip",
    "home:.config/hugmesh-studio/local-login/roles.json": "roles",
    "home:.local/share/hugmesh-local-only/mesh-a/config.json": "local-only",
    # relative to <state>
    "state:sessions/s1/secrets.json": "state-secrets",
    "state:w/report.json": "report",
    "state:w/.cli.json": "cli-json",
    "state:x/vault/token": "vault-token",
    "state:x/vault/unseal-key": "vault-unseal",
    "state:kube/prod.kubeconfig": "kubeconfig",
    "state:certs/ca.pem": "pem",
    "state:certs/node.key": "key",
    "state:ssh/id_ed25519": "id",
    "state:anything/.env": "dotenv",
    "state:secret-files/vpn.conf": "secret-files",
}


@pytest.fixture
def tree(tmp_path, monkeypatch):
    gen, home, state = tmp_path / "gen", tmp_path / "home", tmp_path / "state"
    for d in (gen, home, state):
        d.mkdir()
    (gen / "docs").mkdir()
    (gen / "docs" / "STUDIO-WALKTHROUGH.md").write_text("## Domain services\n\nTick the services.\n")
    paths = {}
    for key, name in PLANTED.items():
        root, rel = key.split(":", 1)
        base = {"gen": gen, "home": home, "state": state}[root]
        p = base / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(f"CANARY-{name}\n")
        paths[name] = str(p)
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(state))
    monkeypatch.setenv("KUBECONFIG", str(state / "kube" / "prod.kubeconfig"))
    monkeypatch.setenv("HUGMESH_GENERATOR_DIR", str(gen))
    return gen, home, state, paths


def test_every_planted_secret_path_is_denied(tree):
    gen, home, state, paths = tree
    for name, path in paths.items():
        assert ac.is_denied_path(path, generator_dir=str(gen), state_dir=str(state)), name
    assert not ac.is_denied_path(str(gen / "docs" / "STUDIO-WALKTHROUGH.md"))
    assert not ac.is_denied_path(str(gen / "README.md"))


def test_every_deny_entry_matches_at_least_one_planted_path(tree):
    """Dropping any DENY_PATHS entry would leave some planted path unmatched by the
    rule it names; this walks the table and asserts each pattern has a witness."""
    gen, home, state, paths = tree
    witnesses = {
        "keys-out": "keys-out", "keys-*": "keys-star", ".e2e-credentials": "e2e-credentials",
        "tests/stack/.env": "stack-env", "mesh-node/.env": "mesh-node-env", "keyzip": "keyzip",
        "roles.json": "roles", "secrets.json": "state-secrets", "report.json": "report",
        ".cli.json": "cli-json", "vault/token": "vault-token", "vault/unseal-key": "vault-unseal",
        "*.kubeconfig": "kubeconfig", "$KUBECONFIG": "kubeconfig", "*.pem": "pem", "*.key": "key",
        "id_*": "id", "/.env": "dotenv", "hugmesh-local-only": "local-only",
        "<secret_files>": "secret-files", "<egress_vpn_conf>": "secret-files",
    }
    for pattern, _what in ac.DENY_PATHS:
        hit = next((w for k, w in witnesses.items() if k in pattern), None)
        assert hit is not None, f"no witness for {pattern}"
        extra = [paths["secret-files"]] if pattern.startswith("<") else ()
        assert ac.denied_reason(paths[hit], generator_dir=str(gen), state_dir=str(state), extra=extra), pattern


def test_the_docs_index_never_opens_a_denied_file(tree, monkeypatch):
    gen, home, state, paths = tree
    opened = []
    real_open = open

    def spy(path, *a, **k):
        opened.append(str(path))
        return real_open(path, *a, **k)
    monkeypatch.setattr("builtins.open", spy)
    monkeypatch.setattr(adocs, "ALLOWLIST", adocs.ALLOWLIST + (("keys-out/node1/wg.key", 1.0), (".e2e-credentials", 1.0)))
    idx = adocs.build_index(str(gen))
    text = " ".join(c.text for c in idx.chunks)
    assert "CANARY" not in text
    assert not any("keys-out" in p or ".e2e-credentials" in p for p in opened)


def test_nothing_rendered_for_the_model_contains_a_canary(tree):
    gen, home, state, paths = tree
    rows = ac.build_rows(str(state)) + ac.mesh_rows(str(state)) + ac.assistant_rows({})
    w = ac.Where(slug="domain_services", title="Domain services", domain="shop.example").with_state(rows)
    rendered = [ac.render_where(w), acat.catalogue_text(), adocs.sources_line([])]
    ws = aedit.Workspace("shop", "shop.example", "web", str(state / "ws"))
    (state / "ws").mkdir()
    for rel in ("secrets.json", "x.pem", ".env", "id_rsa"):
        (state / "ws" / rel).write_text("CANARY-ws\n")
        body, why = aedit.file_text(ws, rel)
        assert body == "" and "secrets" in why
        rendered.append(body + why)
    for text in rendered:
        assert "CANARY" not in text


def test_a_denied_file_named_in_a_question_is_refused_in_words(tree):
    gen, home, state, paths = tree
    ws = aedit.Workspace("shop", "shop.example", "web", str(gen))
    body, why = aedit.file_text(ws, ".e2e-credentials")
    assert body == "" and why == ".e2e-credentials holds secrets; I do not read it"


@pytest.mark.parametrize("line, gone, kept", [
    ("-----BEGIN RSA " + "PRIVATE KEY-----\nMIIE\n-----END RSA PRIVATE KEY-----", "MIIE", "[redacted private key]"),
    ("Authorization: Bearer eyJabc.def-ghi", "eyJabc", "Bearer [redacted]"),
    ("password=hunter2", "hunter2", "password=[redacted]"),
    ("PASSWD: hunter2", "hunter2", "PASSWD: [redacted]"),
    ("TS_AUTHKEY=tskey-auth-k1234-ABCDEF", "k1234", "TS_AUTHKEY=[redacted]"),
    ("a bare tskey-auth-k1234-ABCDEF token", "k1234", "[redacted]"),
    ("ghp_" + "A" * 36, "ghp_A", "[redacted]"),
    ("github_pat_" + "B" * 30, "github_pat_B", "[redacted]"),
    # spelled from parts: the generator's own org export refuses a literal key id
    ("AKIA" + "IOSFODNN7EXAMPLE", "IOSFODNN7", "[redacted]"),
    ("hvs." + "c" * 24, "hvs.c", "[redacted]"),
    ("eyJ" + "a" * 12 + "." + "b" * 12 + "." + "c" * 12, "aaaaaaaaaaaa", "[redacted]"),
    ("postgres://app:s3cret@db:5432/x", "s3cret", "postgres://app:[redacted]@db:5432/x"),
    ("postgresql://app:s3cret@db/x", "s3cret", "[redacted]@"),
    ("r2dbc:postgresql://app:s3cret@db/x", "s3cret", "[redacted]@"),
    ("/home/someone/.local/share/hugmesh-local-only/mesh-a/config.json", "mesh-a", "[redacted path]"),
    ("e2e-admin / Sup3rPass!", "Sup3rPass", "e2e-admin / [redacted]"),
])
def test_each_redaction_pattern(line, gone, kept):
    out = ac.redact(line)
    assert gone not in out, out
    assert kept in out, out


def test_redact_is_idempotent_and_keeps_the_line_count():
    text = "ok line\npassword=abc\n-----BEGIN EC " + "PRIVATE KEY-----\nxx\nyy\n-----END EC PRIVATE KEY-----\nlast"
    once = ac.redact(text)
    assert ac.redact(once) == once
    assert once.count("\n") == text.count("\n")
    assert "sha256:" + "a" * 64 in ac.redact("digest sha256:" + "a" * 64)      # not a secret


def test_redaction_is_load_bearing_for_the_build_rows(tmp_path, monkeypatch):
    """Mutation: with the password rule removed, the error tail leaks."""
    import json
    state = tmp_path / "state"
    (state / "sessions").mkdir(parents=True)
    (state / "sessions" / "s.json").write_text(json.dumps(
        {"id": "s", "label": "b", "status": "failed", "images": ["x"], "error_tail": {"x": ["password=LEAK-CANARY"]}}))
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(state))
    assert "LEAK-CANARY" not in dict(ac.build_rows(str(state)))["last error lines (redacted)"]
    rules = tuple(r for r in ac._REDACT_RULES if "password" not in r[0].pattern)
    monkeypatch.setattr(ac, "_REDACT_RULES", rules)
    assert "LEAK-CANARY" in dict(ac.build_rows(str(state)))["last error lines (redacted)"]


def test_the_local_only_folder_is_only_ever_named_to_be_refused():
    """No assistant module opens the local-only folder: its name appears in the deny
    table and the redaction rule only."""
    core = os.path.join(os.path.dirname(os.path.abspath(ac.__file__)))
    for fn in sorted(os.listdir(core)):
        if not fn.startswith("assistant_") or not fn.endswith(".py"):
            continue
        with open(os.path.join(core, fn), encoding="utf-8") as fh:
            lines = fh.read().split("\n")
        for ln in lines:
            if "hugmesh-local-only" in ln:
                assert "open(" not in ln, (fn, ln)
                assert fn == "assistant_context.py", fn


def test_docs_section_12_names_every_proposal_key_and_every_deny_entry():
    from hugmesh_studio.core import assistant_actions as aa
    doc = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(ac.__file__))), "..", "..", "docs",
                       "LOCAL-AI-ASSISTANT.md")
    with open(os.path.normpath(doc), encoding="utf-8") as fh:
        text = fh.read()
    section = text.split("## 12. What the assistant knows and can do", 1)[1]
    for key in aa.FIELD_ROUTES:
        assert f"`{key.replace('@mesh', '')}`" in section, key
    for pattern, _what in ac.DENY_PATHS:
        assert f"- `{pattern}`" in section, pattern
    assert "LOCAL_AI_GROUNDED" in section and "catalogue" in section and "docs [--page=SLUG]" in section



# ── PR #832 review: the secret shapes a build log really prints ───────────────────────
# Every canary is spelled from parts so the generator's org export (BANNED_MARKERS)
# never sees a literal key, token or 16+-character URL password in this file.
_PEM_BEGIN = "-----BEGIN " + "PRIVATE KEY-----"
_PEM_END = "-----END " + "PRIVATE KEY-----"
_B64 = "MIIEvQIBADANBgkqhkiG9w0BAQEFAASC" + "BKcwggSjAgEAAoIBAQC7Zq"

LEAK_SHAPES = [
    "DB_PASSWORD=CANARY", "POSTGRES_PASSWORD=CANARY", "CASDOOR_DB_PASSWORD=CANARY",
    "CASDOOR_ADMIN_PASSWORD=CANARY", "CASDOOR_CLIENT_SECRET=CANARY", "admin_password=CANARY",
    "E2E_ADMIN_PASSWORD=CANARY", "AWS_SECRET_ACCESS_KEY=CANARY", "aws_secret_access_key = CANARY",
    "export GH_TOKEN=CANARY", "GITHUB_TOKEN=CANARY", "VAULT_TOKEN=s.CANARY", "PGPASSWORD=CANARY",
    "secret_key = CANARY", "SECRET_KEY=CANARY", "passphrase=CANARY", "pwd=CANARY",
    '{"admin_password": "CANARY"}', '"password":"CANARY"', '{"client_secret":"CANARY"}',
    'password: "CANARY"', "Password : CANARY", "token: CANARY", "x-api-key: CANARY",
    "client-key-data: CANARY0tLS1", "PrivateKey = CANARYwgAAAAAAAAAAAAAAAAAAAAAAAA=",
    "PresharedKey = CANARYpsk=", "Unseal Key 1: CANARY", "Initial Root Token: CANARY",
    "https://admin:CANARY@registry.example/v2", "https://user:CANARY@github.com/o/r",
    "mongodb://u:CANARY@db/x", "redis://:CANARY@cache:6379", "mysql://u:CANARY@db/x",
    "jdbc:postgresql://db/x?user=a&password=CANARY", "https://x/cb?access_token=CANARY&x=1",
    "casdoor --password CANARY", "casdoor --password=CANARY", "--admin-password CANARY",
    "--client-secret=CANARY", "mysql -u root -pCANARY",
    "Authorization: Basic " + "Q0FOQVJZ" + "OnBhc3M=", "Set-Cookie: SESSION=CANARY; Path=/",
    "Cookie: hug.session=CANARY", "hskey-auth-CANARY", "hvs.CANARY",
    "gh" + "s_CANARY" + "A" * 20, "eyJhbGciOi.eyJzdWIiOi.CANARYsig",
    "login as admin with e2e-pass CANARY",
]


@pytest.mark.parametrize("line", LEAK_SHAPES)
def test_every_common_secret_shape_is_blanked(line):
    out = ac.redact(line)
    assert "CANARY" not in out and "Q0FOQVJZ" not in out, out
    assert ac.redact(out) == out                              # idempotent


@pytest.mark.parametrize("line", [
    "max_tokens: 4096", "context size: 8192 tokens", "mkdir -p /srv/x", "docker run -p 8080:80 img",
    "Secrets store: vault", "password: (set, never shown)", "passed: 12", "the bypass: on",
    "see https://example.com:8443/path@v2", "Basic settings are fine",
    "[node] ERROR: emerge failed at dev-qt/qtbase-6.8", "digest sha256:" + "a" * 64,
])
def test_ordinary_log_lines_are_left_alone(line):
    assert ac.redact(line) == line


def test_a_private_key_printed_line_by_line_never_reaches_the_build_rows(tmp_path, monkeypatch):
    """The tail is a list of lines; redacting each line alone blanked only the BEGIN line
    and sent the base64 body to the model. A tail cut after the BEGIN line, and the
    mesh log's last line, are covered by the body-line rule."""
    import json
    state = tmp_path / "state"
    (state / "sessions").mkdir(parents=True)
    tails = {"node": ["ok", _PEM_BEGIN, _B64, _B64[::-1], _PEM_END, "done"],
             "desk": [_B64, _PEM_END]}
    (state / "sessions" / "s.json").write_text(json.dumps(
        {"id": "s", "label": "b", "status": "failed", "images": ["node", "desk"], "error_tail": tails}))
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(state))
    text = dict(ac.build_rows(str(state)))["last error lines (redacted)"]
    assert _B64[:20] not in text and _B64[::-1][:20] not in text, text
    assert "[redacted private key]" in text and "done" in text
    (state / "logs").mkdir()
    (state / "logs" / "run.log").write_text("start\n" + _PEM_BEGIN + "\n" + _B64 + "\n")
    row = dict(ac.mesh_rows(str(state)))["local mesh log"]
    assert _B64[:20] not in row, row


def test_the_review_canaries_never_reach_the_model_request(tmp_path, monkeypatch):
    """End to end over the prompt builder: a failed build's tail and the mesh log carry
    the shapes the review planted; the system text the model gets holds none of them."""
    import json
    from hugmesh_studio.core import assistant_prompt as ap
    state = tmp_path / "state"
    (state / "sessions").mkdir(parents=True)
    tail = ["POSTGRES_PASSWORD=CANARYa", "CASDOOR_CLIENT_SECRET=CANARYb", '{"password": "CANARYc"}',
            "https://admin:CANARYd@registry.example/v2", "PrivateKey = CANARYe=", "Unseal Key 1: CANARYf",
            "casdoor --password CANARYg", "AWS_SECRET_ACCESS_KEY=CANARYh"]
    (state / "sessions" / "s.json").write_text(json.dumps(
        {"id": "s", "label": "b", "status": "failed", "images": ["node"], "error_tail": {"node": tail}}))
    (state / "logs").mkdir()
    (state / "logs" / "run.log").write_text("x\nCASDOOR_ADMIN_PASSWORD=CANARYi\n")
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(state))
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    rows = ac.collect([("build", lambda: ac.build_rows(str(state))), ("mesh", lambda: ac.mesh_rows(str(state)))])
    w = ac.Where(face="gui", slug="build", title="Build").with_state(rows)
    p = ap.build("show me the last error lines exactly", w, [], generator_dir=os.path.dirname(
        os.path.dirname(os.path.dirname(os.path.abspath(ac.__file__)))))
    assert "CANARY" not in p.system, [ln for ln in p.system.splitlines() if "CANARY" in ln]
    assert "[redacted]" in p.system
