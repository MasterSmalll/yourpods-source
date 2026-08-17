"""Record the English each translation was made from.

A translation is only correct with respect to the English it was translated
from. When someone edits the English copy, Xcode leaves the existing
translations in place and marks nothing — the German still renders, it is just
now a translation of a sentence the app no longer says. That failure is
invisible in English and invisible in review.

So every translated key records a hash of the English it was made from. When
the English changes, the hash stops matching and the guard names the key.

Usage:
    python3 Translations/tools/english_hashes.py            # report drift
    python3 Translations/tools/english_hashes.py --write    # accept current English

`--write` means "these translations have been re-checked against this English".
Running it to silence a failure without re-reading the translations is the one
way to make this file worse than useless.
"""
import argparse
import glob
import hashlib
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import xcstrings  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HASHES = os.path.join(ROOT, "Translations", "english-hashes.json")


def english_of(key, entry):
    """The English a translator would have worked from, in every catalog form.

    Returns None for a key with no English localization at all — an extracted
    key whose own name is the English, which cannot drift out of agreement with
    itself.
    """
    english = (entry.get("localizations") or {}).get("en")
    if not english:
        return None
    if "stringUnit" in english and "substitutions" not in english:
        return english["stringUnit"].get("value")
    parts = []
    if "stringUnit" in english:
        parts.append("template=" + str(english["stringUnit"].get("value")))
    for kind, cases in sorted((english.get("variations") or {}).items()):
        for case, body in sorted(cases.items()):
            parts.append(f"{kind}.{case}=" + str((body.get("stringUnit") or {}).get("value")))
    for name, body in sorted((english.get("substitutions") or {}).items()):
        for kind, cases in sorted((body.get("variations") or {}).items()):
            for case, inner in sorted(cases.items()):
                parts.append(f"sub.{name}.{kind}.{case}="
                             + str((inner.get("stringUnit") or {}).get("value")))
    return " ".join(parts) or None


def digest(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:16]


def translated_languages(entry):
    return sorted(lang for lang in (entry.get("localizations") or {}) if lang != "en")


def current():
    """catalog -> {key: {'english': digest, 'languages': [...]}} for translated keys."""
    out = {}
    for path in sorted(glob.glob(os.path.join(ROOT, "**", "*.xcstrings"), recursive=True)):
        relative = os.path.relpath(path, ROOT)
        catalog = xcstrings.load(path)
        rows = {}
        for key, entry in catalog["strings"].items():
            languages = translated_languages(entry)
            if not languages:
                continue
            english = english_of(key, entry)
            if english is None:
                continue
            rows[key] = {"english": digest(english), "languages": languages}
        if rows:
            out[relative] = rows
    return out


def drift(recorded, live):
    """(changed, untracked) — translations whose English moved, and new ones."""
    changed, untracked = [], []
    for catalog, rows in live.items():
        known = recorded.get(catalog, {})
        for key, row in rows.items():
            if key not in known:
                untracked.append(f"{catalog}: {key!r}")
            elif known[key]["english"] != row["english"]:
                changed.append(f"{catalog}: {key!r} — translated from different English")
    return sorted(changed), sorted(untracked)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write", action="store_true",
                        help="record the current English as what the translations were checked against")
    args = parser.parse_args()

    live = current()
    total = sum(len(v) for v in live.values())

    if args.write:
        with open(HASHES, "w") as handle:
            json.dump(live, handle, indent=1, sort_keys=True)
            handle.write("\n")
        print(f"recorded {total} translated keys across {len(live)} catalogs")
        return

    recorded = {}
    if os.path.exists(HASHES):
        with open(HASHES) as handle:
            recorded = json.load(handle)

    changed, untracked = drift(recorded, live)
    print(f"{total} translated keys; {len(changed)} drifted, {len(untracked)} untracked")
    for line in changed:
        print("  DRIFT    ", line)
    for line in untracked:
        print("  UNTRACKED", line)
    sys.exit(1 if changed or untracked else 0)


if __name__ == "__main__":
    main()
