#!/usr/bin/env python3
"""issues.py pick N | render — read `gh ... --json` on stdin (no gh call here).

  pick N    `gh issue list --json number,title,body,labels` -> the N smallest open issues
            that a small local model could plausibly draft, as number<TAB>size<TAB>title.
            Left out: anything labelled manual, decision, roadmap or blocked (a person or
            a live system is the next step there) and anything with a long body (a small
            model loses the thread).
  render    `gh issue view --json title,body,comments` -> the issue as Markdown, comments
            included: a later comment often corrects the body.
"""
import json
import sys

SKIP_LABELS = ("manual", "decision", "roadmap", "blocked")
MAX_BODY = 2500


def pick(data, n):
    rows = []
    for it in data:
        names = " ".join((lb.get("name", "") if isinstance(lb, dict) else str(lb))
                         for lb in it.get("labels") or []).lower()
        if any(k in names for k in SKIP_LABELS):
            continue
        body = it.get("body") or ""
        if len(body) >= MAX_BODY:
            continue
        rows.append((len(body), it.get("number"), (it.get("title") or "")[:70]))
    rows.sort()
    for size, num, title in rows[:n]:
        print(f"{num}\t{size}\t{title.replace(chr(9), ' ')}")


def render(data):
    out = [f"# {data.get('title', '')}", "", data.get("body") or "(no description)"]
    for c in data.get("comments") or []:
        who = (c.get("author") or {}).get("login", "someone")
        out += ["", f"--- comment by {who} ---", c.get("body") or ""]
    print("\n".join(out))


def main(argv):
    if not argv or argv[0] not in ("pick", "render"):
        print(__doc__, file=sys.stderr)
        return 2
    try:
        data = json.load(sys.stdin)
    except ValueError:
        print("issues.py: no JSON on stdin", file=sys.stderr)
        return 1
    if argv[0] == "pick":
        pick(data if isinstance(data, list) else [], int(argv[1]) if len(argv) > 1 else 6)
        return 0
    if not isinstance(data, dict) or not data.get("title"):
        print("issues.py: not an issue", file=sys.stderr)
        return 1
    render(data)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
