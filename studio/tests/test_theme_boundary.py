"""The generator<->UI THEME BOUNDARY — the one assertion that crosses repos.

WHY THIS FILE EXISTS. The runtime-theme contract has exactly two halves and they
live in different repositories:

  * the PRODUCER half, here: tests/stack/compose.local.yaml declares
    ``SNAP_THEME_CSS: ${SNAP_THEME_CSS:-}`` on every themed UI service (and the
    Studio derives the value, core/theme.py -> LocalStackNode._build_env()).
  * the CONSUMER half, in each UI checkout: a docker-entrypoint.d hook reads
    ``$SNAP_THEME_CSS`` and writes it verbatim to snap-theme.css, which the page
    <link>s.

Before this file, ``grep -rn snap-theme tests/`` matched only COMMENTS, and
studio/tests/test_login_theme_pipeline.py pinned only generator-local files (the
compose passthrough, the ConfigMap manifest, the CLI). Nothing executable crossed
the boundary in either direction, so a ONE-SIDED rename of the env var — compose
renamed without the hooks, or the hooks renamed without compose — passes both
repositories' CI and fails only at runtime, as a zero-byte stylesheet and a UI
silently wearing the shipped default brand. That is the quietest failure mode in
the fleet: nothing errors, nothing logs, the page just isn't themed.

WHAT IS ASSERTED, and why it is spelled this way:

  * The env-var NAME is NOT hard-coded. Both sides are discovered (compose: any
    ``*_THEME_CSS`` passthrough; hook: any ``$*_THEME_CSS`` reference in
    NON-COMMENT shell) and then compared. Renaming BOTH sides together stays
    green — that is the point, this gate is the enabler a future rename needs,
    not a freeze on the current spelling. Renaming ONE side goes red and names
    the repo.
  * Comments are STRIPPED from the hook before the name is read. Every hook's
    header prose mentions ``$SNAP_THEME_CSS``; matching that would make the gate
    vacuous against exactly the rename it exists to catch.
  * The hook FILENAME is discovered too (any docker-entrypoint.d/*.sh that reads
    a theme var), not pinned to ``50-snap-theme.sh``. A fleet-wide hook rename is
    a legitimate refactor; a hook that reads nothing is not.
  * The Dockerfile must COPY the hook it found. A hook present in the checkout
    but never copied into the image is the same silent zero-byte outcome.
  * The REVERSE direction: a checkout that ships a theme hook must have its
    compose service declare the env. "UI grew theming, compose never wired it"
    is the same defect with the halves swapped.

FALSE-RED DISCIPLINE (this test is READ-ONLY and never writes under STACK_SRC).
The clone tree is gitignored and no CI checkout has one, so an ABSENT checkout is
a SKIP with a message naming what to run — never a failure. ``REQUIRE_STACK_SRC=1``
turns those skips into failures for a lane that has just run
scripts/clone-all-repos.sh and wants the pin load-bearing; this is the same knob
and the same wording tests/stack/test-no-store-posture.sh already uses.

WHERE EACH HALF ACTUALLY BITES — stated plainly rather than implied:
  * the two PRODUCER tests read only compose.local.yaml, so they gate EVERY run,
    CI included. A compose-side rename or a service quietly losing its
    passthrough goes red in CI today.
  * the three BOUNDARY tests need a materialised ${STACK_SRC} tree, which CI
    does not have — there they SKIP, and they are load-bearing on a developer
    or build host that has run `make stack-clone`, and on any lane that opts in
    with REQUIRE_STACK_SRC=1. That is a real limit of a cross-repo static gate
    against gitignored checkouts, not an oversight.
"""
import os
import re

import pytest

_REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
_COMPOSE = os.path.join(_REPO, "tests", "stack", "compose.local.yaml")

# The count of themed services in compose.local.yaml today (host-shell, admin,
# mod, user, login, mastodon, matrix, forum, wiki, owncast, tube,
# character-studio, character-forge). A FLOOR, not an equality: services get
# added. Its job is to fail loudly if the compose parsing below ever stops
# matching, because a boundary test that silently checks zero services is worse
# than no test at all.
_THEMED_SERVICE_FLOOR = 13

# Any *_THEME_CSS spelling, so a rename is comparable rather than invisible.
_THEME_ENV_RE = re.compile(r"^[A-Z][A-Z0-9_]*_THEME_CSS$")


def _stack_src() -> str:
    """Same default the compose file and scripts/patch-stack-src.sh carry."""
    return os.environ.get("STACK_SRC") or os.path.join(_REPO, ".stack-src")


def _require_stack_src() -> bool:
    return os.environ.get("REQUIRE_STACK_SRC", "0") == "1"


def _compose_text() -> str:
    with open(_COMPOSE, encoding="utf-8") as fh:
        return fh.read()


def _themed_services():
    """service -> (build context RELATIVE to STACK_SRC, theme env var name).

    Parsed the way test_local_mesh_source_axis.py parses this file: a service is a
    2-space-indented key, and its ``context:`` keeps its SUBDIRS (character-forge's
    UI lives at <checkout>/frontend, so truncating to the checkout name would look
    at the wrong Dockerfile).
    """
    services, contexts, envs = [], {}, {}
    service = None
    for line in _compose_text().splitlines():
        m = re.match(r"^  ([A-Za-z0-9][\w.-]*):\s*$", line)
        if m:
            service = m.group(1)
            services.append(service)
            continue
        if not service:
            continue
        c = re.search(r"context:\s*\$\{STACK_SRC[^}]*\}/([\w./-]+)", line)
        if c:
            contexts[service] = c.group(1).rstrip("/")
            continue
        # `      SNAP_THEME_CSS: ${SNAP_THEME_CSS:-}` — a passthrough, not a literal.
        e = re.match(r"^\s+([A-Z][A-Z0-9_]*):\s*\$\{([A-Z][A-Z0-9_]*):-.*\}\s*$", line)
        if e and _THEME_ENV_RE.match(e.group(1)):
            envs[service] = (e.group(1), e.group(2))
    return services, contexts, envs


def _strip_shell_comments(text: str) -> str:
    """Drop whole-line comments AND trailing ` # ...` on code lines.

    Deliberately crude and deliberately conservative: it never strips a `#` that
    is not preceded by whitespace, so `${VAR#prefix}` survives. Over-stripping
    could only ever HIDE a variable reference, which this test treats as a
    failure, so the crude version cannot manufacture a false green.
    """
    out = []
    for line in text.splitlines():
        if line.lstrip().startswith("#"):
            continue
        out.append(re.sub(r"\s+#.*$", "", line))
    return "\n".join(out)


def _theme_vars_read_by(path: str):
    """The *_THEME_CSS env vars this shell script actually READS (comments out)."""
    with open(path, encoding="utf-8") as fh:
        code = _strip_shell_comments(fh.read())
    return {m for m in re.findall(r"\$\{?([A-Z][A-Z0-9_]*_THEME_CSS)\b", code)}


def _hooks_reading_theme(ctx_dir: str):
    """docker-entrypoint.d/*.sh in this build context that read a theme var.

    Returns {basename: {vars}}. Discovering the hook by BEHAVIOUR rather than by
    the ``50-snap-theme.sh`` filename keeps a fleet-wide hook rename green while
    still failing when no hook reads anything.
    """
    d = os.path.join(ctx_dir, "docker-entrypoint.d")
    if not os.path.isdir(d):
        return {}
    found = {}
    for name in sorted(os.listdir(d)):
        if not name.endswith(".sh"):
            continue
        got = _theme_vars_read_by(os.path.join(d, name))
        if got:
            found[name] = got
    return found


def _checkout_state(rel_ctx: str):
    """(absolute context dir, reason-to-skip or None).

    A context that is absent, or present but carrying no Dockerfile, is treated as
    "not materialised" — a partial/stale clone tree must not turn this gate red.
    """
    ctx = os.path.join(_stack_src(), rel_ctx)
    if not os.path.isdir(ctx):
        return ctx, f"{ctx} does not exist"
    if not os.path.isfile(os.path.join(ctx, "Dockerfile")):
        return ctx, f"{ctx} has no Dockerfile (not a materialised checkout)"
    return ctx, None


def _skip_or_fail(skipped):
    msg = (
        "no materialised checkout under {src} to check ({n} skipped: {why}). "
        "Run scripts/clone-all-repos.sh (or `make stack-clone`) to populate it; "
        "set REQUIRE_STACK_SRC=1 to make this pin load-bearing on a machine that "
        "has."
    ).format(src=_stack_src(), n=len(skipped), why="; ".join(skipped[:3]))
    if _require_stack_src():
        pytest.fail("REQUIRE_STACK_SRC=1 but " + msg)
    pytest.skip(msg)


# ── the producer half, on its own (runs with or without a clone tree) ──────────────

def test_the_compose_side_of_the_boundary_is_discoverable_and_not_vacuous():
    """If this ever fails, every other test in this file has silently stopped
    checking anything — that is the failure mode a static cross-repo gate dies of."""
    services, contexts, envs = _themed_services()
    assert len(envs) >= _THEMED_SERVICE_FLOOR, (
        f"only {len(envs)} themed services parsed out of {_COMPOSE} "
        f"(expected >= {_THEMED_SERVICE_FLOOR}): {sorted(envs)}. Either services "
        "lost their theme passthrough, or the parser above stopped matching the "
        "file — check both before lowering this floor.")
    # Cross-check the parse against a dumb grep of the same file: a themed service
    # the service-block parser missed would otherwise vanish without a sound.
    grepped = sum(
        1 for line in _compose_text().splitlines()
        if re.match(r"^\s+([A-Z][A-Z0-9_]*_THEME_CSS):\s*\$\{[A-Z][A-Z0-9_]*:-.*\}\s*$",
                    line))
    assert grepped == len(envs), (
        f"{grepped} theme passthrough lines in the file but {len(envs)} attributed "
        f"to a service — the service-block parser is dropping one: {sorted(envs)}")
    # Every themed service must be buildable from a checkout, or there is no
    # consumer half to check at all.
    orphans = sorted(s for s in envs if s not in contexts)
    assert not orphans, (
        f"{orphans} declare a theme env but have no ${{STACK_SRC}} build context, so "
        "no entrypoint hook can be located for them — the env is wired to nothing")


def test_all_themed_services_agree_on_one_env_var_spelling():
    """A split fleet (some services SNAP_*, some HUG_*) is a half-finished rename;
    it would leave the un-renamed half unthemed while both CIs stayed green."""
    _, _, envs = _themed_services()
    spellings = {}
    for svc, (key, ref) in sorted(envs.items()):
        assert key == ref, (
            f"{svc}: compose declares {key} but interpolates ${{{ref}}} — the "
            "container would get the value of a different host variable")
        spellings.setdefault(key, []).append(svc)
    assert len(spellings) == 1, (
        "compose.local.yaml uses more than one theme env spelling: "
        + "; ".join(f"{k} -> {v}" for k, v in sorted(spellings.items())))


# ── the boundary itself ────────────────────────────────────────────────────────────

def test_every_themed_compose_service_has_a_hook_reading_the_same_env_var(capsys):
    """THE assertion this file exists for.

    For every themed service: the checkout it builds from must ship an entrypoint
    hook that reads the SAME env var name compose passes. Rename both halves ->
    green. Rename one -> red, naming the repo.
    """
    _, contexts, envs = _themed_services()
    checked, skipped, problems = [], [], []

    for svc, (key, _ref) in sorted(envs.items()):
        rel = contexts[svc]
        ctx, why = _checkout_state(rel)
        if why:
            skipped.append(f"{svc} ({why})")
            continue
        hooks = _hooks_reading_theme(ctx)
        if not hooks:
            problems.append(
                f"{svc}: compose passes {key} but NO {rel}/docker-entrypoint.d/*.sh "
                f"reads any *_THEME_CSS var — the value reaches the container and is "
                f"dropped on the floor (zero-byte snap-theme.css, shipped brand)")
            continue
        read = set().union(*hooks.values())
        if read != {key}:
            problems.append(
                f"{svc}: compose passes {key} but {rel}/docker-entrypoint.d/"
                f"{{{','.join(sorted(hooks))}}} reads {sorted(read)} — a ONE-SIDED "
                f"rename; both halves must move together")
            continue
        checked.append(f"{svc} -> {rel}/docker-entrypoint.d/{sorted(hooks)[0]} [{key}]")

    with capsys.disabled():
        print(f"\n  theme boundary: {len(checked)} service(s) checked, "
              f"{len(skipped)} skipped (no checkout), under {_stack_src()}")
        for line in checked:
            print(f"    OK   {line}")
        for line in skipped:
            print(f"    SKIP {line}")

    assert not problems, "\n".join([""] + problems)
    if not checked:
        _skip_or_fail(skipped)


def test_every_theme_hook_is_actually_copied_into_the_image():
    """A hook that exists in the checkout but is never COPYed into the image is the
    same zero-byte stylesheet with a more convincing-looking repo."""
    _, contexts, envs = _themed_services()
    checked, skipped, problems = [], [], []

    for svc, _kv in sorted(envs.items()):
        rel = contexts[svc]
        ctx, why = _checkout_state(rel)
        if why:
            skipped.append(f"{svc} ({why})")
            continue
        hooks = _hooks_reading_theme(ctx)
        if not hooks:
            continue                      # the test above owns that failure
        with open(os.path.join(ctx, "Dockerfile"), encoding="utf-8") as fh:
            df = fh.read()
        for name in sorted(hooks):
            if not re.search(rf"^\s*COPY\b.*docker-entrypoint\.d/{re.escape(name)}\b",
                             df, re.MULTILINE):
                problems.append(
                    f"{svc}: {rel}/docker-entrypoint.d/{name} reads the theme env but "
                    f"{rel}/Dockerfile never COPYs it — it cannot run in the image")
            else:
                checked.append(f"{svc}/{name}")

    assert not problems, "\n".join([""] + problems)
    if not checked:
        _skip_or_fail(skipped)


def test_no_checkout_ships_a_theme_hook_that_compose_forgot_to_wire():
    """The boundary from the OTHER side: a UI that grew theming while
    compose.local.yaml never learned to pass the env is unthemed for the same
    reason, and neither repository's CI can see it alone.

    Scope is the checkouts compose ALREADY builds (including one level in, which is
    where character-forge's UI lives). A repo the local stack does not build is not
    part of this stack's boundary and is left alone.
    """
    _, contexts, envs = _themed_services()
    themed_ctx = {contexts[s] for s in envs}
    checked, skipped, problems = [], [], []

    for svc, rel in sorted(contexts.items()):
        if rel in themed_ctx:
            continue                      # already wired; the forward test covers it
        ctx, why = _checkout_state(rel)
        if why:
            skipped.append(f"{svc} ({why})")
            continue
        hooks = _hooks_reading_theme(ctx)
        if hooks:
            read = sorted(set().union(*hooks.values()))
            problems.append(
                f"{rel}/docker-entrypoint.d/{{{','.join(sorted(hooks))}}} reads "
                f"{read}, but compose service {svc!r} declares no theme env — the "
                f"hook runs every start and writes an empty stylesheet")
        checked.append(svc)

    assert not problems, "\n".join([""] + problems)
    if not checked:
        _skip_or_fail(skipped)
