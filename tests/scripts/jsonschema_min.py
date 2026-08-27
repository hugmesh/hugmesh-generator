#!/usr/bin/env python3
"""jsonschema_min.py — a deliberately small JSON Schema checker.

    python3 jsonschema_min.py <schema.json> <document.json>

WHY NOT THE REAL LIBRARY. `jsonschema` is not installed here and is not in the
CI images (python:3.12-slim + pyyaml, alpine:3 + a handful of apks), so a guard
that imports it would SKIP wherever it matters. The subset below is what
tests/e2e/reporters/summary.schema.json actually uses.

REFUSES TO BE PERMISSIVE. Any keyword this checker does not implement is a hard
ERROR, not a shrug. A schema that says `oneOf` and is validated by something that
silently ignores `oneOf` is worse than no schema: it reports green having checked
less than the author believes. tests/scripts/test-e2e-reporter-shape.sh proves
this by feeding it documents that must FAIL.

Exit 0 = valid, 1 = invalid (errors on stdout), 2 = the schema itself is
unusable.
"""

from __future__ import annotations

import json
import re
import sys

# Keywords with no effect on validation. Listed so they are IGNORED KNOWINGLY.
ANNOTATIONS = {"$schema", "$id", "title", "description", "$comment", "examples",
               "default", "deprecated"}
SUPPORTED = {"type", "required", "properties", "additionalProperties", "items",
             "enum", "minimum", "maximum", "minLength", "minItems", "pattern",
             "const"}

TYPES = {
    "object": dict,
    "array": list,
    "string": str,
    "boolean": bool,
    "number": (int, float),
    "integer": int,
    "null": type(None),
}


class SchemaError(Exception):
    pass


def _type_ok(value, name: str) -> bool:
    py = TYPES.get(name)
    if py is None:
        raise SchemaError(f"unknown type name: {name!r}")
    # bool is a subclass of int in python; JSON says they are different types.
    if name in ("integer", "number") and isinstance(value, bool):
        return False
    if name == "boolean":
        return isinstance(value, bool)
    return isinstance(value, py)


def validate(doc, schema, path: str = "$") -> list[str]:
    if not isinstance(schema, dict):
        raise SchemaError(f"{path}: schema node is not an object")
    for kw in schema:
        if kw in ANNOTATIONS or kw in SUPPORTED:
            continue
        raise SchemaError(
            f"{path}: schema uses {kw!r}, which this checker does NOT implement. "
            f"Implement it or stop using it - silently ignoring it would make the "
            f"schema weaker than it reads.")

    errs: list[str] = []

    if "type" in schema:
        names = schema["type"]
        names = names if isinstance(names, list) else [names]
        if not any(_type_ok(doc, n) for n in names):
            errs.append(f"{path}: expected type {'|'.join(names)}, got "
                        f"{type(doc).__name__}")
            return errs  # further keywords would be nonsense against a wrong type

    if "const" in schema and doc != schema["const"]:
        errs.append(f"{path}: expected const {schema['const']!r}, got {doc!r}")

    if "enum" in schema and doc not in schema["enum"]:
        errs.append(f"{path}: {doc!r} is not one of {schema['enum']!r}")

    if isinstance(doc, str):
        if "minLength" in schema and len(doc) < schema["minLength"]:
            errs.append(f"{path}: string shorter than minLength "
                        f"{schema['minLength']} ({doc!r})")
        if "pattern" in schema and not re.search(schema["pattern"], doc):
            errs.append(f"{path}: {doc!r} does not match /{schema['pattern']}/")

    if isinstance(doc, (int, float)) and not isinstance(doc, bool):
        if "minimum" in schema and doc < schema["minimum"]:
            errs.append(f"{path}: {doc} < minimum {schema['minimum']}")
        if "maximum" in schema and doc > schema["maximum"]:
            errs.append(f"{path}: {doc} > maximum {schema['maximum']}")

    if isinstance(doc, dict):
        for key in schema.get("required", []):
            if key not in doc:
                errs.append(f"{path}: MISSING required key {key!r}")
        props = schema.get("properties", {})
        for key, value in doc.items():
            if key in props:
                errs.extend(validate(value, props[key], f"{path}.{key}"))
            elif schema.get("additionalProperties", True) is False:
                errs.append(f"{path}: unexpected key {key!r} "
                            f"(additionalProperties is false)")

    if isinstance(doc, list):
        if "minItems" in schema and len(doc) < schema["minItems"]:
            errs.append(f"{path}: {len(doc)} item(s) < minItems {schema['minItems']}")
        if "items" in schema:
            for i, item in enumerate(doc):
                errs.extend(validate(item, schema["items"], f"{path}[{i}]"))

    return errs


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__.strip().split("\n")[2].strip(), file=sys.stderr)
        return 2
    try:
        with open(argv[1], encoding="utf-8") as fh:
            schema = json.load(fh)
    except (OSError, ValueError) as e:
        print(f"cannot read schema {argv[1]}: {e}", file=sys.stderr)
        return 2
    try:
        with open(argv[2], encoding="utf-8") as fh:
            doc = json.load(fh)
    except (OSError, ValueError) as e:
        print(f"cannot read document {argv[2]}: {e}", file=sys.stderr)
        return 1
    try:
        errs = validate(doc, schema)
    except SchemaError as e:
        print(f"SCHEMA UNUSABLE: {e}", file=sys.stderr)
        return 2
    for e in errs:
        print(e)
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
