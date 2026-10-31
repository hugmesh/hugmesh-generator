"""core/assistant_tips: a curated tip for every page, wording rules, state-aware picks,
and the model tip's refusals (dropped on a slug change, a timeout, an unverified
command, a forbidden word) plus the hidden flag's persistence.
"""
import pytest

from hugmesh_studio.core import assistant_context as ac
from hugmesh_studio.core import assistant_settings
from hugmesh_studio.core import assistant_tips as at
from hugmesh_studio.core import local_ai_status as lai
from hugmesh_studio.core import plain_words
from hugmesh_studio.core.config import WIZARD_PAGE_SLUGS


def expanded_slugs():
    out = []
    for s in WIZARD_PAGE_SLUGS:
        out += list(at.LOCALMESH_SLUGS) if s == "localmesh" else [s]
    return out


def test_every_wizard_slug_and_every_journey_screen_has_a_tip():
    for slug in expanded_slugs():
        assert slug in at.TIPS and at.TIPS[slug], slug
    from hugmesh_studio.tui import journey
    j = journey.Journey(".")
    for slug in j._screens:
        assert slug in at.TIPS, f"journey screen {slug} has no tip"


def test_tips_are_short_plain_and_free_of_forbidden_words():
    for slug, tips in at.TIPS.items():
        assert 1 <= len(tips) <= 3, slug
        for tip in tips:
            assert len(tip) <= at.TIP_MAX_CHARS, (slug, len(tip), tip)
            low = tip.lower()
            for word in plain_words.FORBIDDEN_ON_SCREENS:
                assert word not in low, (slug, word, tip)
            assert "superbrand" not in low and "--superdomain" not in low, (slug, tip)


def test_tip_for_rotates_on_a_returning_visit_and_by_step():
    rot = at.TipRotation()
    w = ac.Where(slug="domain_services", step_index=0)
    first = at.tip_for(w, rotation=rot)
    second = at.tip_for(w, rotation=rot)
    assert first != second and {first, second} <= set(at.TIPS["domain_services"])


def test_tab_and_state_aware_picks():
    assert at.tip_for(ac.Where(slug="domain_services", tab="look")).startswith("Look:")
    assert at.tip_for(ac.Where(slug="localmesh_domain_services", tab="ways")).startswith("Ways:")
    failed = ac.Where(slug="progress", state=(("last failed build", "mesh x86; images backend.x86; log /x"),))
    assert at.tip_for(failed) == "Your last build failed at backend.x86; the Image builds tab has the log."
    up = ac.Where(slug="localmesh", activity=(("local mesh", "up (https://localhost:9080)"),))
    assert at.tip_for(up).startswith("The mesh is up: https://localhost:9080")
    assert at.tip_for(ac.Where(slug="nonexistent_page")) in at.TIPS["welcome"]


def test_hidden_is_persisted_in_the_settings_file(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "s"))
    assert not at.tips_hidden()
    assert at.set_tips_hidden(True)
    assert at.tips_hidden() and assistant_settings.get("tips_hidden") is True
    at.set_tips_hidden(False)
    assert not at.tips_hidden()


def test_clean_model_tip_refuses_long_unverified_or_forbidden_text():
    from hugmesh_studio.core import assistant_docs as ad
    chunk = ad.Chunk("x", "docs/X.md", "X", "run  make stack-up  to start", 1.0, 5)
    assert at.clean_model_tip("Tick the services first.", [chunk]) == "Tick the services first."
    assert at.clean_model_tip("x" * 200, [chunk]) == ""
    assert at.clean_model_tip("Run make stack-reset now.", [chunk]) == ""
    assert at.clean_model_tip("Run make stack-up now.", [chunk]) == "Run make stack-up now."
    assert at.clean_model_tip("Set the issuer on the tenant.", [chunk]) == ""


def test_model_tip_uses_a_small_capped_request_and_drops_on_stop(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "s"))
    calls = []

    def fake(text, model=None, *, env=None, system=None, options=None, timeout=None,
             total_timeout=None, should_stop=None, **k):
        calls.append((text, system, options, timeout, total_timeout))
        return "Tick the services this domain runs first."
    monkeypatch.setattr(lai, "send_prompt", fake)
    w = ac.Where(slug="domain_services", title="Domain services")
    assert at.model_tip(w, {}, generator_dir=".") == "Tick the services this domain runs first."
    text, system, options, timeout, total = calls[0]
    assert text == at.MODEL_TIP_PROMPT and options == {"num_predict": 60}
    assert timeout == 10 and total == 20
    assert "# Where the person is" in system and "Domain services" in system
    assert at.model_tip(w, {}, should_stop=lambda: True, generator_dir=".") == ""
    monkeypatch.setattr(lai, "send_prompt", lambda *a, **k: (_ for _ in ()).throw(lai.LocalAIError("down")))
    assert at.model_tip(w, {}, generator_dir=".") == ""
