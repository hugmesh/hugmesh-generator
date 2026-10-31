"""core/assistant_context: the "where the person is" facts and their collectors.

Pins: a Where from page facts renders every row in plain words and under its token
cap; the state half is collected off the page under a one-second budget, a slow or
raising collector yields "(unavailable)"; build rows carry a failed build's error tail
REDACTED; every value is redacted before it is rendered (mutation: a value that would
survive without ``redact`` does not survive with it).
"""
import json
import os
import time

import pytest

from hugmesh_studio.core import assistant_context as ac
from hugmesh_studio.core.config import Domain


def test_tokens_is_generous_for_paths_and_json():
    assert ac.tokens("") == 0
    assert ac.tokens("a" * 32) == 10
    assert ac.tokens("/home/x/.hugmesh/studio/sessions/abc.json") > len("/home/x/.hugmesh/studio/sessions/abc.json") // 4


def test_a_where_renders_page_domain_tab_brand_and_domains():
    rows = ac.domain_rows_from([Domain(name="shop.example", optional_services=["tuwunel", "phpbb"]),
                                Domain(name="blog.example", optional_services=["akkoma"], tor=True,
                                       idp="own", idp_settings={"provider": "entra",
                                                                "client_secret": "NEVER"})],
                               own_name="shop.example")
    w = ac.Where(face="gui", slug="domain_services", title="Domain services", subtitle="Domain 1 of 2",
                 mode="mesh", step_index=3, step_total=9, domain="shop.example", own_domain=True,
                 tab="services", route="image",
                 brand=ac.brand_rows_from({"title": "Shop", "id": "shop", "org": "Acme"}),
                 domains=rows)
    text = ac.render_where(w)
    assert "- face: Studio window (gui)" in text
    assert "- page: Domain services (step 3 of 9 for mesh) — Domain 1 of 2" in text
    assert "- domain on screen: shop.example (the mesh's own domain) — tab: Services" in text
    assert "- brand: Shop (shop, Acme)" in text
    assert "domain shop.example (the mesh's own domain): services tuwunel, phpbb; through the mesh's sign-in; Tor off" in text
    assert "domain blog.example: services akkoma; its own entra sign-in; Tor on" in text
    assert "NEVER" not in text and "client_secret" not in text
    assert ac.tokens(text) <= ac.WHERE_TOKEN_CAP


def test_an_empty_where_still_renders_and_says_what_is_missing():
    text = ac.render_where(ac.Where())
    assert "- page: unknown page" in text
    assert "- brand: not set yet" in text and "- domains: none yet" in text


def test_the_where_block_is_capped_by_dropping_domain_detail_first():
    rows = ac.domain_rows_from([Domain(name=f"d{i}.example", optional_services=["akkoma", "tuwunel", "phpbb"])
                                for i in range(60)])
    w = ac.Where(slug="domains", title="Domains", domains=rows, state=(("build", "none running"),))
    text = ac.render_where(w)
    assert ac.tokens(text) <= ac.WHERE_TOKEN_CAP
    assert "- domains: 60" in text and "- build: none running" in text


def test_state_rows_are_scrubbed_and_secret_keys_never_show_their_value():
    w = ac.Where().with_state([("auth_key", "tskey-auth-ABC"), ("build", "ok"),
                               ("vault_token", "hvs.xxxxxxxxxxxxxxxxxxxxxxxx")])
    assert w.state == (("auth_key", "(set, never shown)"), ("build", "ok"),
                       ("vault_token", "(set, never shown)"))
    text = ac.render_where(w)
    assert "tskey" not in text and "hvs." not in text and "- auth_key: (set, never shown)" in text


def test_build_rows_read_a_failed_sessions_error_tail_redacted(tmp_path, monkeypatch):
    state = tmp_path / "state"
    (state / "sessions").mkdir(parents=True)
    rec = {"id": "s1", "label": "mesh backend x86", "status": "failed", "images": ["backend.x86"],
           "log_path": str(tmp_path / "build.log"), "workdir": str(tmp_path / "w"),
           "error_tail": {"backend.x86": ["emerge failed", "TS_AUTHKEY=tskey-auth-CANARY123",
                                          "password=CANARY-PW", "see build.log"]}}
    (state / "sessions" / "s1.json").write_text(json.dumps(rec))
    (tmp_path / "w").mkdir()
    (tmp_path / "w" / "build-status.json").write_text(json.dumps({"percent": 42, "stage": "emerge"}))
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(state))
    rows = dict(ac.build_rows(str(state)))
    assert rows["build"] == "none running"
    assert rows["last failed build"].startswith("mesh backend x86; images backend.x86")
    tail = rows["last error lines (redacted)"]
    assert "emerge failed" in tail and "see build.log" in tail
    assert "CANARY123" not in tail and "CANARY-PW" not in tail and "tskey-auth" not in tail
    assert "TS_AUTHKEY=[redacted]" in tail and "password=[redacted]" in tail


def test_build_rows_show_a_running_build_with_its_percent(tmp_path, monkeypatch):
    state = tmp_path / "state"
    (state / "sessions").mkdir(parents=True)
    (tmp_path / "w").mkdir()
    (tmp_path / "w" / "build-status.json").write_text(json.dumps({"percent": 42, "stage": "emerge"}))
    (state / "sessions" / "r.json").write_text(json.dumps(
        {"id": "r", "label": "pki rpi5", "status": "running", "images": ["pki.rpi5"], "workdir": str(tmp_path / "w")}))
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(state))
    rows = dict(ac.build_rows(str(state)))
    assert rows["build"].startswith("pki rpi5 running; images pki.rpi5")
    assert rows["build progress"] == "42% (emerge)"


def test_mesh_rows_name_the_last_run_log_and_redact_its_last_line(tmp_path):
    logs = tmp_path / "logs"
    logs.mkdir()
    (logs / "2026-10-01-stack-up.log").write_text("starting\nPOSTGRES_PASSWORD=sekret done\n")
    (logs / "2026-10-02-stack-down.log").write_text("bye\nBearer abc.def.ghi\n")
    rows = dict(ac.mesh_rows(str(tmp_path)))
    assert rows["local mesh log"].startswith("2026-10-02-stack-down.log — last line: Bearer [redacted]")
    assert dict(ac.mesh_rows(str(tmp_path / "none")))["local mesh log"] == "none yet"


def test_assistant_rows_name_the_model_host_and_context_without_a_request(monkeypatch):
    rows = dict(ac.assistant_rows({"LOCAL_AI_MODEL": "qwen3:8b", "LOCAL_AI_CTX": "8192"}))
    assert rows["assistant"].startswith("qwen3:8b on the")
    assert "127.0.0.1:11434, context 8192 tokens; everything stays on this machine" in rows["assistant"]


def test_collect_runs_every_collector_under_a_wall_budget_and_names_the_slow_one():
    def slow():
        time.sleep(3)
        return [("slow", "late")]

    def boom():
        raise OSError("disk on fire")

    t0 = time.monotonic()
    rows = ac.collect([("fast", lambda: [("fast", "ok")]), ("slow", slow), ("boom", boom)], budget=0.5)
    assert time.monotonic() - t0 < 1.5
    assert rows == [("fast", "ok"), ("slow", "(unavailable)"), ("boom", "(unavailable) (OSError)")]


def test_collect_scrubs_what_a_collector_returns():
    rows = ac.collect([("x", lambda: [("password", "hunter2"), ("log", "token=abc123")])])
    assert rows == [("password", "(set, never shown)"), ("log", "token=[redacted]")]


def test_code_rows_list_each_domain_workspace_present_or_missing(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    rows = ac.code_rows(str(tmp_path / "gen"), "clone", "", [Domain(name="shop.example", optional_services=["phpbb"])],
                        "shop", state_root=str(tmp_path / "state"))
    assert rows and all(k.startswith("code folder") or k == "code folders" for k, _v in rows)
    assert any("missing" in v or "none" in v or "(unavailable)" in v for _k, v in rows)


# ── mutation: the redaction is load-bearing ──────────────────────────────────────────
def test_render_where_would_leak_without_redact(monkeypatch):
    """Break production: with redact() a no-op the token survives into the block; the
    assertion inside render_where then fires. Restored by monkeypatch."""
    w = ac.Where(domains=(("domain x", "token=SECRET-CANARY"),))
    assert "SECRET-CANARY" not in ac.render_where(w)
    monkeypatch.setattr(ac, "redact", lambda t: t)
    assert "SECRET-CANARY" in ac.render_where(w)


def test_scrub_rows_would_leak_without_the_secret_key_rule(monkeypatch):
    import re
    assert ac.scrub_rows([("auth_key", "ABC")]) == (("auth_key", "(set, never shown)"),)
    monkeypatch.setattr(ac, "SECRET_KEY_RE", re.compile(r"(?!x)x"))
    monkeypatch.setattr(ac, "SECRET_FIELD_NAMES", ())
    assert ac.scrub_rows([("auth_key", "ABC")]) == (("auth_key", "ABC"),)
