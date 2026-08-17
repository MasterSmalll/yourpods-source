"""Classify every String Catalog key into a triage bucket.

Locations come from Xcode's .stringsdata, which are JSON (NOT plists) shaped

    {"source": "<abs .swift path>",
     "tables": {"Localizable": [{"key": ..., "location": {"startingLine": ...}}]}}

`tables[name]` is a LIST OF DICTS. Testing `"" in entries` against it is always
False and silently reports zero hits — that exact mistake once produced a wrong
claim that reached a commit and a code comment before it was caught. Anything added here that walks .stringsdata gets a self-check in
test_inventory.py proving it can still report a hit.

The `__PotentialKeys` table is Xcode-internal and never reaches a catalog.
"""
import collections
import glob
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import xcstrings  # noqa: E402

SPECIFIER = re.compile(r"%(\d+\$)?[@a-zA-Z.0-9]*[@dfusxX]|%lld|%%")
SYMBOLIC = re.compile(r"^[a-z][A-Za-z0-9]*(\.[A-Za-z0-9]+)+")

#: Sample values, URLs and product names. Copy that must survive translation
#: unchanged, per the spec's do-not-translate list (§3.6).
DO_NOT_TRANSLATE = {
    "YourPods", "gPodder", "Nextcloud", "CarPlay", "AirPlay", "Siri",
    "Obsidian", "YourPods Notes", "WebDAV", "P3", "yourpods-ios",
    "https://gpodder.net", "https://cloud.example.com", "you@example.com",
}


def is_degenerate(key):
    """True when nothing but specifiers and punctuation — never translatable."""
    return not any(c.isalpha() for c in SPECIFIER.sub("", key))


def is_handrolled_plural(key):
    """`%lld podcast%@` — a count glued to a `count == 1 ? "" : "s"` suffix."""
    return bool(re.search(r"%(lld|d)\b.*\w%@", key))


def has_numeric_specifier(key):
    return bool(re.search(r"%(\d+\$)?(lld|d|u|zd)", key))


def case_variant_groups(keys):
    """Keys differing only by capitalization or trailing punctuation."""
    groups = collections.defaultdict(list)
    for key in keys:
        groups[key.lower().rstrip(".…?!")].append(key)
    return {g: sorted(v) for g, v in groups.items() if len(v) > 1}


def stringsdata_files(derived_data):
    """Every .stringsdata under a DerivedData tree.

    `os.walk` rather than `glob("**/*.stringsdata")`: over a real DerivedData
    directory the glob takes minutes and the walk takes half a second.
    """
    found = []
    for base, _dirs, files in os.walk(derived_data):
        found += [os.path.join(base, f) for f in files if f.endswith(".stringsdata")]
    return found


def key_sites(derived_data, root):
    """key -> sorted [(repo-relative source, line)] for the Localizable table.

    Only the newest `.stringsdata` per producer counts. A target is built once
    per SDK and old trees are never pruned, so reading the union mixes line
    numbers from before and after an edit — which is how a comment-authoring
    worklist ended up pointing at `.padding(...)` instead of the string's real
    call site. Keyed on (file name, source) rather than source alone, because
    `ExtractedAppShortcutsMetadata.stringsdata` declares the same `source` as
    the file it was extracted from and would otherwise shadow it.
    """
    newest = {}
    for path in stringsdata_files(derived_data):
        try:
            stamp = os.path.getmtime(path)
            with open(path) as handle:
                data = json.load(handle)
        except (ValueError, OSError):
            continue
        source = data.get("source") or ""
        if not source.startswith(root):
            continue
        producer = (os.path.basename(path), source)
        if producer not in newest or stamp > newest[producer][0]:
            newest[producer] = (stamp, data)

    sites = collections.defaultdict(set)
    for _stamp, data in newest.values():
        rel = os.path.relpath(data["source"], root)
        entries = (data.get("tables") or {}).get("Localizable")
        if not isinstance(entries, list):
            continue
        for entry in entries:
            if isinstance(entry, dict) and entry.get("key") is not None:
                line = (entry.get("location") or {}).get("startingLine")
                sites[entry["key"]].add((rel, line))
    return {k: sorted(v, key=lambda s: (s[0], s[1] or 0)) for k, v in sites.items()}


def catalog_keys(root):
    keys = set()
    for path in glob.glob(root + "/**/Localizable.xcstrings", recursive=True):
        keys |= set(xcstrings.load(path)["strings"])
    return keys


def logic_coupled(root, keys):
    """Localizable strings a comparison in Swift depends on being English.

    Translating one of these breaks behaviour rather than wording, and only in
    the languages nobody on the team reads.
    """
    pattern = re.compile(
        r'(==|!=|\.contains\(|\.hasPrefix\(|\.hasSuffix\(|case\s+)\s*"([^"\\]{1,60})"')
    hits = []
    for target in ("YourPods", "YourPodsWatch", "YourPodsWidgets", "YourPodsComplication"):
        for path in glob.glob(f"{root}/{target}/**/*.swift", recursive=True):
            if "/YourPodsTests/" in path:
                continue
            with open(path) as handle:
                for number, line in enumerate(handle.read().splitlines(), 1):
                    for match in pattern.finditer(line):
                        if match.group(2) in keys:
                            hits.append((os.path.relpath(path, root), number, match.group(2)))
    return sorted(hits)


def classify(root, derived_data):
    """Every raw-English key, in exactly one bucket."""
    keys = catalog_keys(root)
    raw = sorted(k for k in keys if not SYMBOLIC.match(k))
    variants = case_variant_groups(raw)
    in_variant = {k for v in variants.values() for k in v}
    coupled = {k for _, _, k in logic_coupled(root, keys)}
    buckets = collections.defaultdict(list)
    for key in raw:
        if key in coupled:
            buckets["logic_coupled"].append(key)
        elif is_degenerate(key):
            buckets["degenerate"].append(key)
        elif key in DO_NOT_TRANSLATE:
            buckets["donottranslate"].append(key)
        elif is_handrolled_plural(key):
            buckets["handrolled_plural"].append(key)
        elif has_numeric_specifier(key):
            buckets["plural"].append(key)
        elif key in in_variant:
            buckets["case_variant"].append(key)
        else:
            buckets["plain"].append(key)
    buckets["_case_variant_groups"] = variants
    buckets["_sites"] = key_sites(derived_data, root)
    return dict(buckets)
