"""Build blind back-translation inputs, and diff the results.

A translator asked "is this right?" says yes. So the critic never sees the
English: it gets only the target-language string and is asked what it means.
Its answer is then diffed against the English it never saw. A semantic inversion
— "hide" becoming "delete", "not in Free" becoming "in Free" — survives every
mechanical check in this repo and dies here.

Back-translating all 1,052 keys in five languages is 5,260 more units for a
check whose value is concentrated in a minority of strings, so `build` selects
by risk rather than sampling uniformly:

- the AI-translation disclosure, the app's first impression in every locale
- destructive actions, where an inversion loses the user's data
- strings whose comment flags an ambiguity or a grammatical role
- every plural and substitution, where a wrong category is invisible in English
- a deterministic spread of the rest, for coverage
"""
import argparse
import glob
import hashlib
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

DESTRUCTIVE = re.compile(
    r"\b(delete|remove|clear|erase|permanently|undo|reset|wipe|revoke|cancel|unsubscribe)\b", re.I)
#: Comment phrasings that mark a string a reader could reasonably invert.
AMBIGUITY = re.compile(
    r"\b(NOT|never|not the|rather than|as opposed to|VERB|ADJECTIVE|NOUN|STATE|"
    r"IMPERATIVE|do not translate|CAUTION|distinct from)\b")


def flatten(shape):
    if "value" in shape:
        return [shape["value"]]
    if "plural" in shape:
        return [v for v in shape["plural"].values()]
    out = [shape.get("template", "")]
    for body in (shape.get("substitutions") or {}).values():
        out += list((body or {}).values())
    return [s for s in out if s]


def risk(key, english, comment):
    """Why this key is worth back-translating, or None."""
    text = " ".join(flatten(english))
    if key.startswith(("account.delete", "a11y.account")) or "translation" in key.lower():
        return "disclosure"
    if "plural" in english or "template" in english:
        return "plural"
    if DESTRUCTIVE.search(text):
        return "destructive"
    if AMBIGUITY.search(comment or ""):
        return "ambiguous"
    return None


def stable_sample(keys, fraction):
    """Deterministic spread — same keys every run, no Date/random."""
    chosen = []
    for key in keys:
        digest = hashlib.sha256(key.encode("utf-8")).hexdigest()
        if int(digest[:8], 16) % 1000 < fraction * 1000:
            chosen.append(key)
    return chosen


def load_english(directory):
    english, comments = {}, {}
    for path in sorted(glob.glob(os.path.join(directory, "in", "chunk*.json"))):
        for row in json.load(open(path)):
            english[row["key"]] = row["english"]
            comments[row["key"]] = row.get("comment", "")
    return english, comments


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    b = sub.add_parser("build")
    b.add_argument("--dir", required=True)
    b.add_argument("--language", required=True)
    b.add_argument("--out", required=True)
    b.add_argument("--spread", type=float, default=0.08)

    d = sub.add_parser("diff")
    d.add_argument("--dir", required=True)
    d.add_argument("--language", required=True)
    d.add_argument("--back", required=True)

    args = parser.parse_args()
    english, comments = load_english(args.dir)

    if args.command == "build":
        path = os.path.join(args.dir, "final", f"trans-{args.language}.json")
        translations = json.load(open(path))

        selected, reasons = [], {}
        for key in english:
            why = risk(key, english[key], comments.get(key))
            if why:
                selected.append(key)
                reasons[key] = why
        for key in stable_sample(sorted(set(english) - set(selected)), args.spread):
            selected.append(key)
            reasons[key] = "spread"

        # Opaque ids, and this is not cosmetic. Most catalog keys ARE their
        # English string, so emitting the key would hand the critic the answer
        # and the "blind" back-translation would prove nothing at all.
        rows, mapping = [], {}
        for key in sorted(selected):
            if key not in translations:
                continue
            opaque = "s" + hashlib.sha256(key.encode("utf-8")).hexdigest()[:10]
            mapping[opaque] = key
            rows.append({"id": opaque, "text": flatten(translations[key])})

        with open(args.out, "w") as handle:
            json.dump(rows, handle, indent=1, ensure_ascii=False)
        with open(args.out.replace(".json", ".map.json"), "w") as handle:
            json.dump(mapping, handle, indent=1, ensure_ascii=False)

        counts = {}
        for key in selected:
            counts[reasons[key]] = counts.get(reasons[key], 0) + 1
        print(f"{len(rows)} keys selected for {args.language}: {counts}")
        return

    # diff — re-attach the English the critic never saw
    back = json.load(open(args.back))
    mapping = json.load(open(os.path.join(
        args.dir, "critic", f"blind-{args.language}.map.json")))
    path = os.path.join(args.dir, "final", f"trans-{args.language}.json")
    translations = json.load(open(path))

    print(f"{'=' * 70}\n{args.language}: {len(back)} back-translations\n{'=' * 70}")
    unknown = 0
    for opaque in sorted(back):
        key = mapping.get(opaque)
        if key is None:
            unknown += 1
            continue
        source = " / ".join(flatten(english.get(key, {"value": key})))
        theirs = back[opaque] if isinstance(back[opaque], str) else " / ".join(back[opaque])
        print(f"\n{key}")
        print(f"  english: {source}")
        print(f"  back:    {theirs}")
        print(f"  target:  {' / '.join(flatten(translations.get(key, {'value': '?'})))}")
    if unknown:
        print(f"\n{unknown} back-translations had no matching id — the critic invented ids")


if __name__ == "__main__":
    main()
