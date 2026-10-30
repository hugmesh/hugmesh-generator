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
    # the key shapes are spelled from parts: a literal one trips the host's secret scanner
    ("TS_AUTHKEY=" + "tskey" + "-auth-k1234-ABCDEF", "k1234", "TS_AUTHKEY=[redacted]"),
    ("a bare " + "tskey" + "-auth-k1234-ABCDEF token", "k1234", "[redacted]"),
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
_SHORT = "q9ZxTm4w" + "Lk2PvR8s=="
_SHORT2 = "Hn3cYw" + "Qe7uJb=="

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
    "statement: CREATE ROLE casdoor WITH LOGIN PASSWORD 'CANARY'",
    "ALTER USER app WITH PASSWORD \"CANARY\";", "CREATE USER 'a'@'%' IDENTIFIED BY 'CANARY';",
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
    "passthrough=1", "--bypass-cache yes", "compass: north", "passes=3", "unsealed: true",
    "Sealed: false", "password: \"\"",
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
    # _SHORT is a key's last body line: under the 40-character body-line rule, so only
    # redacting the tail as one text (BEGIN..END together) or the run-up-to-END rule
    # blanks it
    tails = {"node": ["ok", _PEM_BEGIN, _B64, _B64[::-1], _SHORT, _PEM_END, "done"],
             "desk": [_B64, _SHORT2, _PEM_END]}
    (state / "sessions" / "s.json").write_text(json.dumps(
        {"id": "s", "label": "b", "status": "failed", "images": ["node", "desk"], "error_tail": tails}))
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(state))
    text = dict(ac.build_rows(str(state)))["last error lines (redacted)"]
    assert _B64[:20] not in text and _B64[::-1][:20] not in text, text
    assert _SHORT not in text and _SHORT2 not in text, text
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


# ── PR #832 round 2: a quoted value is blanked to its closing quote ─────────────────
# The key=value rule stopped at the first space, so {"admin_password": "horse CANARY
# staple"} sent "CANARY staple" to the model. Every case puts the canary AFTER a space.
QUOTED_SHAPES = [
    '{"admin_password": "horse CANARY staple"}',          # 2nd word, JSON
    '{"admin_password": "horse battery CANARY"}',         # 3rd word
    '{"secret": "two CANARY"}',                           # the mesh run log's shape
    "password: 'horse CANARY staple'",                    # single quotes
    'DB_PASSWORD="horse CANARY"',                         # an env file
    "export LUKS_PASS='horse battery CANARY'",
    r'{"password": "a \" CANARY b"}',                    # an escaped quote inside
    r"password: 'it\'s CANARY'",
    "casdoor --admin-password 'horse CANARY staple'",    # a quoted flag value
    '--client-secret="horse CANARY"',
    'password: "a line the tail cut CANARY',             # no closing quote: to the line end
]


@pytest.mark.parametrize("line", QUOTED_SHAPES)
def test_a_quoted_secret_with_spaces_is_blanked_to_its_closing_quote(line):
    out = ac.redact(line)
    assert "CANARY" not in out, out
    assert "[redacted]" in out and ac.redact(out) == out, out


def test_a_quoted_secret_stops_at_its_own_quote_and_its_line():
    assert ac.redact('{"password": "a b", "name": "KEEP me"}') == '{"password": "[redacted]", "name": "KEEP me"}'
    assert ac.redact("password: 'a b' and KEEP") == "password: '[redacted]' and KEEP"
    assert ac.redact('{"password": "it\'s", "name": "KEEP"}') == '{"password": "[redacted]", "name": "KEEP"}'
    text = 'password: "never closed\nKEEP this line\nlast'
    out = ac.redact(text)
    assert out == 'password: "[redacted]\nKEEP this line\nlast' and out.count("\n") == 2
    assert ac.redact('password: ""') == 'password: ""'              # nothing to hide


def test_an_unquoted_value_still_stops_at_the_first_space():
    """Pinned, not endorsed: a bare value is one word (``a=b c=d`` is two pairs), so an
    unquoted ``secret = two words`` keeps its second word. Logs quote multi-word
    secrets; a YAML plain scalar with spaces is the known gap."""
    assert ac.redact("secret = horse KEEP") == "secret = [redacted] KEEP"
    assert ac.redact("user=a pass=b next=KEEP") == "user=a pass=[redacted] next=KEEP"


@pytest.mark.parametrize("line", [
    "LUKS_PASS=CANARY", "luks_pass=CANARY", "local_pass: CANARY", "CASDOOR_ADMIN_PASS=CANARY",
    "DB_PASS=CANARY", "--luks-pass CANARY", "--local-pass=CANARY", "unseal_key=CANARY",
    "VAULT_UNSEAL_KEY=CANARY", '{"unseal_keys_b64": ["CANARY"]}'.replace('["CANARY"]', '"CANARY"'),
])
def test_the_studios_own_pass_and_unseal_spellings_are_blanked(line):
    out = ac.redact(line)
    assert "CANARY" not in out and "[redacted]" in out, out


# ── PR #832 round 3: a backslash, an escaped quote and the other spellings ──────────
# Round 3 found the quoted rule falling through to "nothing blanked" when the value's
# last character before the line end was a backslash ('"password": "CANARY\' as a
# log line cut there): the whole secret was sent. Every case below leaked on e3127adb.
TRAILING_BACKSLASH = [
    '"password": "CANARY\\',                       # at the end of the text
    '"password": "horse CANARY\\\nKEEP',            # at the end of a line
    '--password "CANARY\\',
    "LUKS_PASS='CANARY\\",
    '"password": "CANARY\\\\\\',                   # a pair, then a lone one
    "password: 'never closed CANARY",              # an unclosed single quote
    "password: 'never closed CANARY\nKEEP",
]


@pytest.mark.parametrize("text", TRAILING_BACKSLASH)
def test_a_trailing_backslash_or_open_quote_never_ends_a_secret(text):
    out = ac.redact(text)
    assert "CANARY" not in out and "[redacted]" in out, out
    assert out.count("\n") == text.count("\n") and ac.redact(out) == out, out
    if "KEEP" in text:
        assert out.endswith("\nKEEP"), out                  # never past its line


def test_a_backslash_pair_is_one_character_and_the_quote_after_it_closes():
    assert ac.redact('"password": "a\\\\" KEEP') == '"password": "[redacted]" KEEP'
    assert ac.redact("password: 'a\\\\' KEEP") == "password: '[redacted]' KEEP"
    assert ac.redact('"password": "a\\\\\\" CANARY" KEEP') == '"password": "[redacted]" KEEP'


@pytest.mark.parametrize("line, want", [
    ('msg="{\\"password\\": \\"horse CANARY\\", \\"user\\": \\"KEEP\\"}"',
     'msg="{\\"password\\": \\"[redacted]\\", \\"user\\": \\"KEEP\\"}"'),
    ('{\\"data\\":{\\"DB_PASSWORD\\":\\"CANARY x\\",\\"user\\":\\"KEEP\\"}}',
     '{\\"data\\":{\\"DB_PASSWORD\\":\\"[redacted]\\",\\"user\\":\\"KEEP\\"}}'),
    # two levels deep, and a quote inside the value (a longer run before it)
    ('"{\\\\\\"password\\\\\\": \\\\\\"a \\\\\\\\\\\\\\" CANARY\\\\\\", \\\\\\"u\\\\\\": 1}"',
     '"{\\\\\\"password\\\\\\": \\\\\\"[redacted]\\\\\\", \\\\\\"u\\\\\\": 1}"'),
    ('password=\\"a CANARY\\" KEEP=1', 'password=\\"[redacted]\\" KEEP=1'),       # logfmt
])
def test_a_json_escaped_key_and_value_are_blanked(line, want):
    """Round 3: a key quoted with \\" was invisible to the key rule, so the WHOLE value
    of msg="{\\"password\\": ...}" and of kubectl's escaped JSON reached the model.
    seed-e2e.sh, seed-accounts.sh and verify-seeded-identities.sh build that shape."""
    out = ac.redact(line)
    assert out == want and ac.redact(out) == out, out


@pytest.mark.parametrize("text, want", [
    ("password=$'horse CANARY'", "password=$'[redacted]'"),                      # bash $'..'
    ("password=horse\\ CANARY next=KEEP", "password=[redacted] next=KEEP"),        # printf %q
    ('password=abc"CANARY" KEEP', "password=[redacted] KEEP"),                    # a quote mid-word
    ("secret: |\n  CANARY one\n  CANARY two\nKEEP: 1",
     "secret: [redacted]\n  [redacted]\n  [redacted]\nKEEP: 1"),                  # YAML block scalar
    ("  - client_secret: >-\n      CANARY\n  - name: KEEP", "  - client_secret: [redacted]\n      [redacted]\n  - name: KEEP"),
    ("Unseal Key (will be hidden): CANARY", "Unseal Key (will be hidden): [redacted]"),
    ("vault operator unseal CANARY", "vault operator unseal [redacted]"),
    ("vault operator unseal -address=https://v:8200 CANARY", "vault operator unseal -address=https://v:8200 [redacted]"),
    ("CREATE ROLE x PASSWORD 'a\"CANARY'", "CREATE ROLE x PASSWORD '[redacted]'"),   # the other quote inside
    ("CREATE ROLE x PASSWORD 'it''s CANARY';", "CREATE ROLE x PASSWORD '[redacted]';"),  # SQL's doubled quote
])
def test_the_other_round_3_spellings_are_blanked(text, want):
    out = ac.redact(text)
    assert out == want and ac.redact(out) == out, out


# The fuzz: a secret key, then a value in every quote and backslash spelling, with the
# canary INSIDE the value by that spelling's own rules (an escape takes the next
# character; an unclosed quote runs to the line end; a bare word stops at whitespace
# and at , ; & }). Seeded, so a failure names a reproducible case.
_FUZZ_CAN = "CNRY" + "q7Zx"
_FUZZ_PRINT = "".join(c for c in __import__("string").printable if c not in "\n\r\x0b\x0c")
_FUZZ_KEYS = ["password", "admin_password", "DB_PASSWORD", "CASDOOR_CLIENT_SECRET", "LUKS_PASS",
              "luks_pass", "unseal_key", "VAULT_UNSEAL_KEY", "api_key", "token", "passphrase", "secret"]
_FUZZ_FORMS = ["{k}={v}", "{k}: {v}", '"{k}": {v}', "'{k}': {v}", "export {k}={v}", "  {k} = {v}",
               '{{"{k}":{v}', "--password {v}", "--admin-password={v}", "--luks-pass {v}",
               "--client-secret={v}", "-pass {v}"]
_FUZZ_LEADS = ["", "auth failed ", "[node] ERROR: ", "msg=", "  ", "x | "]


def _fz_char(rng, exclude=""):
    while True:
        c = rng.choice(_FUZZ_PRINT + "\"'\\ \t$" * 6)          # quotes and backslashes, often
        if c not in exclude:
            return c


def _fz_quoted(rng):
    q = rng.choice("\"'")
    pre = "$" if q == "'" and rng.random() < 0.2 else ""
    toks = [("\\" + _fz_char(rng)) if rng.random() < 0.35 else _fz_char(rng, q + "\\")
            for _ in range(rng.randint(0, 7))]
    toks.insert(rng.randint(0, len(toks)), _FUZZ_CAN)
    tail = rng.choice([q + "".join(_fz_char(rng) for _ in range(rng.randint(0, 6))), q,
                       "\nKEEP", "", "\\\nKEEP", "\\"])
    return pre + q + "".join(toks) + tail


def _fz_bare(rng):
    import string
    toks = [rng.choice(string.ascii_letters + string.digits)]
    toks += [("\\" + _fz_char(rng)) if rng.random() < 0.25 else _fz_char(rng, " \t,;&}\\")
             for _ in range(rng.randint(0, 6))]
    toks.insert(rng.randint(1, len(toks)), _FUZZ_CAN)
    return "".join(toks) + rng.choice(["", "\\", " KEEP", "\nKEEP"])


def _fz_escaped(rng):
    import json
    pw = "".join(_fz_char(rng) for _ in range(rng.randint(0, 6)))
    i = rng.randint(0, len(pw))
    pw = pw[:i] + _FUZZ_CAN + pw[i:]
    obj = rng.choice([{"password": pw, "user": "KEEP"}, {"data": {"DB_PASSWORD": pw}},
                      {"admin_password": pw}, {"luks_pass": pw, "n": 1}])
    if rng.random() < 0.25:
        s = repr(obj) if rng.random() < 0.5 else repr(repr(obj))
    else:
        s = json.dumps(obj, ensure_ascii=rng.random() < 0.5)
        for _ in range(rng.randint(0, 3)):                    # JSON in a string, up to 3 deep
            s = json.dumps(s)
    return rng.choice(["msg=", "body: ", "level=error msg=", "", "kubectl: "]) + s


def _fz_case(rng):
    kind = rng.choice(["quoted", "quoted", "bare", "escaped"])
    if kind == "escaped":
        line = _fz_escaped(rng)
    else:
        v = _fz_quoted(rng) if kind == "quoted" else _fz_bare(rng)
        line = rng.choice(_FUZZ_LEADS) + rng.choice(_FUZZ_FORMS).format(k=rng.choice(_FUZZ_KEYS), v=v)
    return rng.choice(["", "ok line\n", "first\nsecond\n"]) + line


@pytest.mark.parametrize("seed", range(8))
def test_fuzz_no_quote_or_backslash_spelling_lets_the_canary_through(seed):
    """3,000 cases per seed. On e3127adb this battery leaked about 40 % of its cases
    (a trailing backslash, $'..', JSON in a string, a quote or escape inside a bare
    word); none may leak now, through redact or redact_lines, and the output is
    idempotent and keeps the line count."""
    import random
    rng = random.Random(832_000 + seed)
    for _ in range(3000):
        text = _fz_case(rng)
        out = ac.redact(text)
        assert _FUZZ_CAN not in out, (text, out)
        assert ac.redact(out) == out and out.count("\n") == text.count("\n"), (text, out)
        assert _FUZZ_CAN not in "\n".join(ac.redact_lines(text.split("\n"))), text


def test_a_trailing_backslash_secret_never_reaches_the_build_or_mesh_rows(tmp_path, monkeypatch):
    """Round 3's end-to-end witnesses: the canary after a trailing backslash as the LAST
    error-tail line (the line a ' | ' join puts nothing after) and as the mesh log's
    last line. An unclosed quote earlier in the tail no longer swallows the lines after
    it (the tail is redacted line by line before the join)."""
    import json
    state = tmp_path / "state"
    (state / "sessions").mkdir(parents=True)
    tail = ["step one", 'auth failed "password": "horse CANARYa \\', "MARK-after-open",
            'auth failed "password": "horse CANARYb\\']
    (state / "sessions" / "s.json").write_text(json.dumps(
        {"id": "s", "label": "b", "status": "failed", "images": ["node"], "error_tail": {"node": tail}}))
    (state / "logs").mkdir()
    (state / "logs" / "run.log").write_text('start\n"password": "CANARYc\\')
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(state))
    text = dict(ac.build_rows(str(state)))["last error lines (redacted)"]
    assert "CANARY" not in text and "MARK-after-open" in text, text
    row = dict(ac.mesh_rows(str(state)))["local mesh log"]
    assert "CANARY" not in row and "[redacted]" in row, row
