"""Report terminology that was rendered two ways inside one language.

Translation was parallelised across chunks, and a chunk is an arbitrary slice of
the catalog rather than a surface. So "Queue" can appear in chunk 1 and chunk 3
and come back as two different words, each defensible on its own and wrong
together — the user sees one app, not four chunks.

Two checks, because they catch different things:

*Glossary drift* — for each term in TRANSLATION.md's glossary, collect every
translation of a string containing it and show the distinct renderings. Noisy by
nature (a term inside a longer sentence legitimately inflects), so it reports
rather than fails.

*Identical English, different translation* — the same English string translated
two ways in one language. Much sharper: there is no good reason for it.
"""
import argparse
import collections
import glob
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

#: English glossary terms whose rendering must not drift, from TRANSLATION.md §3.
GLOSSARY = [
    "Queue", "Up Next", "episode", "podcast", "chapter", "group", "library",
    "download", "stream", "sync", "feed", "transcript", "sleep timer",
    "hide", "unhide", "unplayed", "played", "profile", "account", "subscription",
]


def flatten(shape):
    """Every human-readable string inside a translated shape."""
    if not isinstance(shape, dict):
        return []
    if "value" in shape:
        return [shape["value"]]
    if "plural" in shape:
        return [v for v in shape["plural"].values() if isinstance(v, str)]
    out = [shape.get("template", "")]
    for body in (shape.get("substitutions") or {}).values():
        out += [v for v in (body or {}).values() if isinstance(v, str)]
    return [s for s in out if s]


def english_text(shape):
    return " ".join(flatten(shape))


def load(directory):
    """language -> {key: shape}, and the English side by key."""
    english = {}
    for path in sorted(glob.glob(os.path.join(directory, "in", "chunk*.json"))):
        for row in json.load(open(path)):
            english[row["key"]] = row["english"]

    by_language = collections.defaultdict(dict)
    for path in sorted(glob.glob(os.path.join(directory, "out", "trans-*.json"))):
        language = os.path.basename(path).split("-")[1]
        by_language[language].update(json.load(open(path)))
    return english, by_language


def identical_english_conflicts(english, rows):
    """Same English string, two different translations, in one language."""
    by_source = collections.defaultdict(set)
    for key, shape in rows.items():
        source = english.get(key)
        if source is None:
            continue
        by_source[english_text(source).strip().lower()].add(english_text(shape).strip())
    return {source: sorted(v) for source, v in by_source.items()
            if len(v) > 1 and source}


def glossary_drift(english, rows, term):
    """Distinct translations of strings containing `term`, shortest first.

    Only short strings — under six English words — where the term IS the string
    rather than a word inside a sentence. Sentences inflect legitimately and
    swamp the signal.
    """
    pattern = re.compile(rf"\b{re.escape(term)}\b", re.IGNORECASE)
    renderings = collections.defaultdict(list)
    for key, shape in rows.items():
        source = english.get(key)
        if source is None:
            continue
        text = english_text(source)
        if not pattern.search(text) or len(text.split()) > 5:
            continue
        renderings[english_text(shape)].append(text)
    return renderings


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dir", required=True)
    parser.add_argument("--language")
    args = parser.parse_args()

    english, by_language = load(args.dir)
    languages = [args.language] if args.language else sorted(by_language)

    total_conflicts = 0
    for language in languages:
        rows = by_language.get(language, {})
        print(f"\n{'=' * 60}\n{language}: {len(rows)} translated\n{'=' * 60}")

        conflicts = identical_english_conflicts(english, rows)
        total_conflicts += len(conflicts)
        print(f"\nSame English, different translation: {len(conflicts)}")
        for source, variants in sorted(conflicts.items())[:25]:
            print(f"  {source!r}")
            for variant in variants:
                print(f"      {variant!r}")

        print("\nGlossary renderings (short strings only):")
        for term in GLOSSARY:
            renderings = glossary_drift(english, rows, term)
            if len(renderings) > 1:
                print(f"  {term}: {len(renderings)} renderings")
                for translated, sources in sorted(renderings.items())[:6]:
                    print(f"      {translated!r}  <- {sorted(set(sources))[:3]}")

    print(f"\n{total_conflicts} identical-English conflicts across {len(languages)} languages")


if __name__ == "__main__":
    main()
