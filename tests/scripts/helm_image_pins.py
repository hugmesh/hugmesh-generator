#!/usr/bin/env python3
"""Collect container images written in the HELM SPLIT FORM.

tests/scripts/test-container-image-tags.sh scans for a one-line `image: VALUE`.
A chart's values express the same thing as a repository/tag PAIR under an `image:`
key that has nothing after the colon:

    image:
      repository: bitnamilegacy/kubectl
      tag: '1.28.5'

so EVERY Helm override in this repo was invisible to that gate. Found the hard way:
kyverno-3.2.8 pins its cleanup CronJobs to the retired bitnami/kubectl:1.28.5, four
of them sat in ImagePullBackOff on a live cluster, and adding our own override did
not move the suite's probe count by one -- which is how a "now it is covered" claim
gets falsified.

Indentation-aware on purpose: repository/tag are collected ONLY inside an `image:`
block (strictly deeper than it), so an unrelated `repository:` -- a chart repoURL,
say -- is never mistaken for an image. Comment lines are dropped first, so prose
naming an image cannot pin one.

Prints `repo:tag`, one per line. Silent on files it cannot read: this is an ADDITIVE
scan and its own emptiness is asserted by the caller, not here.
"""
import os
import re
import sys

IMAGE_KEY = re.compile(r'^(\s*)image:\s*$')
REPO_KEY = re.compile(r'^(\s*)repository:\s*(\S.*)$')
TAG_KEY = re.compile(r'^(\s*)tag:\s*(\S.*)$')
INDENT = re.compile(r'^(\s*)')


def _clean(v):
    return v.strip().strip('"').strip("'").strip()


def pins_in(path):
    out = []
    try:
        with open(path, encoding='utf-8', errors='replace') as fh:
            lines = fh.read().splitlines()
    except OSError:
        return out
    depth = None
    repo = tag = None

    def flush():
        nonlocal repo, tag
        if repo and tag:
            out.append('%s:%s' % (repo, tag))
        repo = tag = None

    for raw in lines:
        if raw.lstrip().startswith('#'):
            continue
        m = IMAGE_KEY.match(raw)
        if m:
            flush()
            depth = len(m.group(1))
            continue
        if depth is None:
            continue
        if not raw.strip():
            continue
        ind = len(INDENT.match(raw).group(1))
        if ind <= depth:
            flush()
            depth = None
            continue
        m = REPO_KEY.match(raw)
        if m:
            repo = _clean(m.group(2))
        m = TAG_KEY.match(raw)
        if m:
            tag = _clean(m.group(2))
    flush()
    return out


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else '.'
    seen = set()
    for dirpath, _dirs, files in os.walk(root):
        for fn in files:
            if not fn.endswith(('.yaml', '.yml')):
                continue
            for pin in pins_in(os.path.join(dirpath, fn)):
                seen.add(pin)
    for pin in sorted(seen):
        print(pin)


if __name__ == '__main__':
    main()
