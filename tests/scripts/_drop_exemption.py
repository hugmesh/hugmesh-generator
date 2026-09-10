#!/usr/bin/env python3
"""Write a copy of kind_secret_closure.py with ONE EXEMPT entry deleted.

Used only by test-kind-secret-closure.sh. It exists because the obvious
alternative — renaming the key with sed — leaves the entry in the dict, so the
checker's ANTI-ROT rule fires and the test passes for the wrong reason. That
masked a real mutation survivor once already.
"""
import io, re, sys

src, key, out = sys.argv[1], sys.argv[2], sys.argv[3]
text = io.open(src, encoding="utf-8").read()
pattern = re.compile(r'\n    "' + re.escape(key) + r'": \(.*?\n    \),', re.S)
new, n = pattern.subn("", text, count=1)
if n != 1:
    print(f"could not delete EXEMPT[{key}] from {src}", file=sys.stderr)
    raise SystemExit(3)
io.open(out, "w", encoding="utf-8").write(new)
