"""Export catalogs for translation, and import translations back.

The unit a translator works on is not "a string" — a third of the catalog is
plural rules or substitutions, and a translation that returns only a flat
string for one of those silently drops the grammar the English carries. So the
export states the *shape* of each entry and the import refuses any answer whose
shape does not match.
"""
import argparse
import collections
import glob
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import xcstrings  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LANGUAGES = ["de", "es", "fr", "it", "nl"]


def english_shape(key, entry):
    """The English side of a key, in one of three shapes.

    `{"value": str}`                          — a plain string
    `{"plural": {category: str}}`             — one count governing a noun
    `{"template": str, "substitutions": {...}}` — two counts, each with its own
    """
    english = (entry.get("localizations") or {}).get("en") or {}

    if "substitutions" in english:
        subs = {}
        for name, body in english["substitutions"].items():
            cases = (body.get("variations") or {}).get("plural") or {}
            subs[name] = {c: (v.get("stringUnit") or {}).get("value") for c, v in cases.items()}
        return {"template": (english.get("stringUnit") or {}).get("value"),
                "substitutions": subs}

    if "variations" in english:
        cases = (english["variations"].get("plural")) or {}
        return {"plural": {c: (v.get("stringUnit") or {}).get("value") for c, v in cases.items()}}

    unit = english.get("stringUnit") or {}
    # A key with no English localization *is* its own English — that is how an
    # auto-extracted key works.
    return {"value": unit.get("value", key)}


def export(chunks):
    """Every distinct key once, with its comment and English shape."""
    rows = collections.OrderedDict()
    for path in sorted(glob.glob(os.path.join(ROOT, "**", "*.xcstrings"), recursive=True)):
        catalog = xcstrings.load(path)
        for key, entry in catalog["strings"].items():
            if key in rows:
                continue
            rows[key] = {"key": key,
                         "comment": entry.get("comment", ""),
                         "english": english_shape(key, entry)}
    items = list(rows.values())
    size = (len(items) + chunks - 1) // chunks
    return [items[i:i + size] for i in range(0, len(items), size)]


def shapes_match(english, translated):
    """Reasons a translation's shape does not answer the English's."""
    if "value" in english:
        if not isinstance(translated, dict) or "value" not in translated:
            return ["English is a plain string; expected {\"value\": ...}"]
        return [] if isinstance(translated["value"], str) else ["value is not a string"]

    if "plural" in english:
        cases = translated.get("plural") if isinstance(translated, dict) else None
        if not isinstance(cases, dict):
            return ["English has plural rules; expected {\"plural\": {category: ...}}"]
        if "other" not in cases:
            return ["plural is missing the required 'other' category"]
        bad = [c for c, v in cases.items() if not isinstance(v, str)]
        return [f"plural.{c} is not a string" for c in bad]

    out = []
    if not isinstance(translated, dict) or not isinstance(translated.get("template"), str):
        return ["English uses substitutions; expected {\"template\": ..., \"substitutions\": {...}}"]
    subs = translated.get("substitutions")
    if not isinstance(subs, dict):
        return ["substitutions missing"]
    for name in english["substitutions"]:
        if name not in subs:
            out.append(f"substitution '{name}' missing")
        elif "other" not in (subs[name] or {}):
            out.append(f"substitution '{name}' is missing the required 'other' category")
        if f"%#@{name}@" not in translated["template"]:
            out.append(f"template never references %#@{name}@")
    return out


def to_localization(shape):
    """A translated shape as the catalog's own JSON."""
    if "value" in shape:
        return {"stringUnit": {"state": "translated", "value": shape["value"]}}
    if "plural" in shape:
        return {"variations": {"plural": {
            c: {"stringUnit": {"state": "translated", "value": v}}
            for c, v in shape["plural"].items()}}}
    return {
        "stringUnit": {"state": "translated", "value": shape["template"]},
        "substitutions": {
            name: {"argNum": index + 1, "formatSpecifier": "lld",
                   "variations": {"plural": {
                       c: {"stringUnit": {"state": "translated", "value": v}}
                       for c, v in cases.items()}}}
            for index, (name, cases) in enumerate(shape["substitutions"].items())},
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    e = sub.add_parser("export", help="write per-chunk translation input files")
    e.add_argument("--out", required=True)
    e.add_argument("--chunks", type=int, default=4)

    i = sub.add_parser("import", help="apply translation files to the catalogs")
    i.add_argument("--dir", required=True)
    i.add_argument("--apply", action="store_true")

    args = parser.parse_args()

    if args.command == "export":
        os.makedirs(args.out, exist_ok=True)
        for index, chunk in enumerate(export(args.chunks), start=1):
            path = os.path.join(args.out, f"chunk{index}.json")
            with open(path, "w") as handle:
                json.dump(chunk, handle, indent=1, ensure_ascii=False)
            print(f"{len(chunk):5d} keys  {path}")
        return

    # import
    english = {}
    for chunk in export(1):
        for row in chunk:
            english[row["key"]] = row["english"]

    by_language = collections.defaultdict(dict)
    for path in sorted(glob.glob(os.path.join(args.dir, "trans-*.json"))):
        # `trans-de.json` splits to ["trans", "de.json"] — strip the extension,
        # or the language reads as "de.json", matches nothing in LANGUAGES, and
        # the apply silently writes zero localizations while reporting success.
        language = os.path.splitext(os.path.basename(path))[0].split("-")[1]
        for key, shape in json.load(open(path)).items():
            by_language[language][key] = shape

    problems = []
    for language, rows in sorted(by_language.items()):
        missing = set(english) - set(rows)
        for key, shape in rows.items():
            if key not in english:
                problems.append(f"{language}: {key!r} is not a catalog key")
                continue
            for reason in shapes_match(english[key], shape):
                problems.append(f"{language}: {key!r} — {reason}")
        print(f"{language}: {len(rows)} translated, {len(missing)} missing")
        for key in sorted(missing)[:5]:
            problems.append(f"{language}: {key!r} missing")

    print(f"\n{len(problems)} problems")
    for problem in problems[:40]:
        print("  ", problem)
    if problems or not args.apply:
        sys.exit(1 if problems else 0)

    written = 0
    for path in sorted(glob.glob(os.path.join(ROOT, "**", "*.xcstrings"), recursive=True)):
        catalog = xcstrings.load(path)
        touched = 0
        for key, entry in catalog["strings"].items():
            localizations = entry.setdefault("localizations", {})
            for language in LANGUAGES:
                shape = by_language.get(language, {}).get(key)
                if shape is None:
                    continue
                localizations[language] = to_localization(shape)
                touched += 1
            if not localizations:
                del entry["localizations"]
        if touched:
            xcstrings.write(path, catalog)
            print(f"wrote {os.path.relpath(path, ROOT)} ({touched} localizations)")
            written += touched
    print(f"\n{written} localizations applied")


if __name__ == "__main__":
    main()
