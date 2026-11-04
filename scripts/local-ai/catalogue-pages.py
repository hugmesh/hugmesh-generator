#!/usr/bin/env python3
"""Write studio/hugmesh_studio/core/assistant_catalogue_pages.py: which wizard page
reads which ImageConfig field (``cfg.<field>`` in gui/pages/<page>.py), so the local
assistant's option catalogue can say where a setting is edited.

    scripts/local-ai/catalogue-pages.py            write the file
    scripts/local-ai/catalogue-pages.py --check    exit 1 when the file is stale

Stdlib only; a test regenerates and compares the file, so a page that starts editing
a new field fails the test, not the person.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
STUDIO = os.path.join(os.path.dirname(os.path.dirname(HERE)), "studio")
sys.path.insert(0, STUDIO)

from hugmesh_studio.core import assistant_catalogue as cat  # noqa: E402


def main(argv):
    computed = cat.compute_pages()
    text = cat.pages_module_text(computed)
    if "--check" in argv:
        try:
            with open(cat.PAGES_FILE, encoding="utf-8") as fh:
                have = fh.read()
        except OSError:
            have = ""
        if have != text:
            print(f"{cat.PAGES_FILE} is stale; run {sys.argv[0]} to rewrite it", file=sys.stderr)
            return 1
        print("catalogue pages up to date")
        return 0
    with open(cat.PAGES_FILE, "w", encoding="utf-8") as fh:
        fh.write(text)
    print(f"wrote {cat.PAGES_FILE} ({len(computed)} fields)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
