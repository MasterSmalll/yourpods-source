"""Sync String Catalogs to what the compiler actually extracted.

`xcodebuild build` does not touch a `.xcstrings`; only Xcode's IDE and
`-exportLocalizations` do, and the latter builds every target in the project
(including the descoped macOS one) just to harvest strings. But the compiler
already wrote the answer: every `.stringsdata` under

    DerivedData/<proj>/Build/Intermediates.noindex/**/<Target>.build/Objects-normal/

carries, per source file, each extracted key with its `comment` and — for the
`String(localized:defaultValue:)` form — its `value`. That is everything a
catalog entry needs, so this reads them directly.

Run with no arguments for a dry run. `--apply` writes through
`xcstrings.write`, which refuses to emit anything that does not re-parse.

Deliberately conservative in one place: a key already in the catalog keeps its
comment unless the source supplies a non-empty one. Comments authored directly
in the catalog are a supported workflow and the triage tooling depends on them surviving
— roughly 890 keys carry no source comment at all.
"""
import argparse
import collections
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import xcstrings  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

#: Build target -> catalog, for the targets that own a Localizable catalog.
#: YourPodsMac is descoped and has none; YourPodsTests must never emit strings
#: (asserted by LocalizationCatalogGuardTests.test_testTargetDoesNotEmitLocalizedStrings).
TARGET_CATALOGS = {
    "YourPods": "YourPods/YourPods/Localizable.xcstrings",
    "YourPodsWatch": "YourPodsWatch/Localizable.xcstrings",
    "YourPodsWidgets": "YourPodsWidgets/Localizable.xcstrings",
    "YourPodsComplication": "YourPodsComplication/Localizable.xcstrings",
}

#: Real copy that an iOS build cannot extract, so a sync run always proposes
#: dropping it. Each entry needs a reason.
KEEP_UNEXTRACTED = {
    "Export saved to: %@":
        "SettingsView.swift:953, inside the #else of `#if os(iOS)` — macOS-only "
        "copy harvested earlier, when -exportLocalizations built every target. "
        "The macOS target is descoped, not deleted, so the string stays.",
}


def target_of(objects_normal_dir):
    """The build target owning a .../<Target>.build/Objects-normal/<arch> path.

    Matching on `"/<Target>.build/" in path` is wrong: intermediates nest as
    `<Project>.build/<Config>-<sdk>/<Target>.build/...`, so every watch and
    widget path contains `/YourPods.build/` too and their strings get
    attributed to the app. The target is the `.build` component immediately
    above `Objects-normal`, and nothing else.
    """
    parts = objects_normal_dir.split(os.sep)
    if "Objects-normal" not in parts:
        return None
    index = parts.index("Objects-normal")
    if index == 0 or not parts[index - 1].endswith(".build"):
        return None
    return parts[index - 1][: -len(".build")]


def extracted(derived_data, target, table="Localizable"):
    """key -> {"comment": str, "value": str|None} for one build target.

    A target is built once per SDK, so intermediates hold parallel trees —
    `Debug-iphonesimulator` beside `Debug-iphoneos`, `Debug-watchsimulator`
    beside `Debug-watchos` — and old ones are never pruned. Reading the union
    resurrects keys that were deleted from the source hours ago: the first
    version of this tool reported the numeric picker keys as still extracted,
    citing line numbers from before they were edited.

    So the newest `.stringsdata` wins per *producer*, whichever SDK made it.

    Producer, not source file: two different extraction products can declare
    the same `source`. `ExtractedAppShortcutsMetadata.stringsdata` names
    `YourPodsShortcuts.swift` just as `YourPodsShortcuts.stringsdata` does, and
    being newer it shadowed the real one — silently dropping `Play Latest`,
    `Play Queue`, `Set Speed` and `Stop`, all four of which are still in the
    source. Keying on (file name, source) keeps them apart while still
    collapsing the per-SDK duplicates.
    """
    newest = {}
    for base, _dirs, files in os.walk(derived_data):
        if target_of(base) != target:
            continue
        for name in files:
            if not name.endswith(".stringsdata"):
                continue
            path = os.path.join(base, name)
            try:
                stamp = os.path.getmtime(path)
                with open(path) as handle:
                    data = json.load(handle)
            except (ValueError, OSError):
                continue
            producer = (name, data.get("source") or path)
            if producer not in newest or stamp > newest[producer][0]:
                newest[producer] = (stamp, data)

    found = {}
    for _stamp, data in newest.values():
        entries = (data.get("tables") or {}).get(table)
        if not isinstance(entries, list):
            continue
        for entry in entries:
            if not isinstance(entry, dict) or entry.get("key") is None:
                continue
            key = entry["key"]
            record = found.setdefault(key, {"comment": "", "value": None})
            if entry.get("comment"):
                record["comment"] = entry["comment"]
            if entry.get("value") is not None:
                record["value"] = entry["value"]
    return found


def collate(key):
    """Approximates Xcode's `localizedStandardCompare` — case-insensitive and
    numeric-aware, so `"9"` sorts before `"10"`."""
    out, digits = [], ""
    for char in key.casefold():
        if char.isdigit():
            digits += char
            continue
        if digits:
            out.append(digits.rjust(20, "0"))
            digits = ""
        out.append(char)
    if digits:
        out.append(digits.rjust(20, "0"))
    return out


def insert_in_place(existing, new_keys):
    """Place new keys among the existing ones without reordering any of them.

    Re-sorting the whole catalog looks harmless and is not: `collate` is only
    an approximation of `localizedStandardCompare`, and it disagrees with Xcode
    on at least the middot in `"%lld episodes · %@"` and on a leading emoji.
    A full sort therefore shuffles untouched entries, producing a diff that
    hides the real change and that Xcode will shuffle back the next time it
    writes the file.

    The existing order is Xcode's own and is taken as ground truth; each new
    key goes before the first existing key that sorts after it.
    """
    # The caller has already stored the new entries, which appends them at the
    # end; drop them from the running order before finding their real homes.
    order = [k for k in existing if k not in set(new_keys)]
    for key in new_keys:
        position = next((i for i, other in enumerate(order) if collate(other) > collate(key)),
                        len(order))
        order.insert(position, key)
    return {k: existing[k] for k in order}


def entry_for(record):
    """A fresh catalog entry in the shape Xcode writes."""
    entry = {}
    if record["comment"]:
        entry["comment"] = record["comment"]
    if record["value"] is not None:
        entry["extractionState"] = "extracted_with_value"
        entry["localizations"] = {
            "en": {"stringUnit": {"state": "new", "value": record["value"]}}
        }
    return entry


def plan(derived_data):
    """Per catalog: keys to add, keys to drop, comments to refresh."""
    actions = collections.OrderedDict()
    for target, relative in TARGET_CATALOGS.items():
        source = extracted(derived_data, target)
        if not source:
            raise SystemExit(
                f"{target}: no .stringsdata found — build the scheme before syncing, "
                "otherwise this would report every key as removed")
        catalog = xcstrings.load(os.path.join(ROOT, relative))
        existing = catalog["strings"]
        add = sorted(set(source) - set(existing))
        drop = sorted(set(existing) - set(source) - set(KEEP_UNEXTRACTED))
        recomment = sorted(
            k for k in set(source) & set(existing)
            if source[k]["comment"] and source[k]["comment"] != existing[k].get("comment"))
        actions[relative] = {"target": target, "source": source, "catalog": catalog,
                             "add": add, "drop": drop, "recomment": recomment}
    return actions


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true",
                        help="add new keys and refresh source-supplied comments")
    parser.add_argument("--prune", action="store_true",
                        help="also delete keys the build no longer extracts. Off by "
                             "default: a key wrongly judged absent takes its five "
                             "translations with it, and an incremental build or a "
                             "shadowed producer can make a live string look gone.")
    parser.add_argument("--derived-data", default=os.path.expanduser(
        "~/Library/Developer/Xcode/DerivedData/YourPods-devyuiegwxxldgfywjdansucxkub"))
    args = parser.parse_args()

    actions = plan(args.derived_data)
    for relative, action in actions.items():
        print(f"\n{relative}  ({action['target']}: {len(action['source'])} extracted)")
        for key in action["add"]:
            print(f"  + {key!r}")
        for key in action["drop"]:
            print(f"  - {key!r}")
        for key in action["recomment"]:
            print(f"  ~ {key!r} (comment)")
        if not (action["add"] or action["drop"] or action["recomment"]):
            print("  (in sync)")

    if not args.apply:
        print("\ndry run — pass --apply to write")
        return

    for relative, action in actions.items():
        catalog, source = action["catalog"], action["source"]
        if args.prune:
            for key in action["drop"]:
                del catalog["strings"][key]
        for key in action["add"]:
            catalog["strings"][key] = entry_for(source[key])
        for key in action["recomment"]:
            catalog["strings"][key]["comment"] = source[key]["comment"]
        catalog["strings"] = insert_in_place(catalog["strings"], action["add"])
        xcstrings.write(os.path.join(ROOT, relative), catalog)
        print(f"wrote {relative}")


if __name__ == "__main__":
    main()
