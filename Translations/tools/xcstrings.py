"""Read and write `.xcstrings` byte-for-byte the way Xcode does.

`json.dump` is not usable here, for two separate reasons.

**Formatting.** Xcode writes `" : "` between key and value, and renders an
empty object as an *expanded* two-line block:

    "Some key" : {

    },

A `json.dumps` round-trip collapses those to `{}`. On the app catalog that
rewrites every one of ~950 entries — a three-string change becomes a
whole-file diff nobody can review, and the real change hides inside it.

**Ordering.** Xcode sorts keys with a case-insensitive, numeric-aware
collation (`localizedStandardCompare`), not by code point: `"%lld
auto-hidden"` sorts before `"%lld Episodes"`, and `"10"` after `"9"`.
Reproducing that exactly is a rabbit hole, and we do not try. `dump` emits
keys in the order they were read, which is the order Xcode last wrote them —
so adding a localization to an existing entry touches only that entry.

Both properties are asserted rather than assumed: `verify()` round-trips
every catalog in the repo, and a guard test fails if any of them stops
matching.
"""
import json


def dump(obj, indent=0):
    """Serialize exactly as Xcode does, preserving key order."""
    pad, pad2 = ' ' * indent, ' ' * (indent + 2)
    if isinstance(obj, dict):
        if not obj:
            return '{\n\n' + pad + '}'
        items = [f'{pad2}{json.dumps(k, ensure_ascii=False)} : {dump(v, indent + 2)}'
                 for k, v in obj.items()]
        return '{\n' + ',\n'.join(items) + '\n' + pad + '}'
    if isinstance(obj, list):
        if not obj:
            return '[\n\n' + pad + ']'
        items = [f'{pad2}{dump(v, indent + 2)}' for v in obj]
        return '[\n' + ',\n'.join(items) + '\n' + pad + ']'
    return json.dumps(obj, ensure_ascii=False)


def load(path):
    """Parse a catalog. `json.loads` preserves insertion order, which is what
    lets `dump` reproduce the file it came from."""
    with open(path, encoding='utf-8') as f:
        return json.loads(f.read())


def write(path, catalog):
    """Write a catalog, refusing to emit anything that does not re-parse to
    the object it was handed."""
    text = dump(catalog)
    if json.loads(text) != catalog:
        raise ValueError(f'{path}: serializer lost data — refusing to write')
    with open(path, 'w', encoding='utf-8') as f:
        f.write(text)


def verify(paths):
    """Paths whose read/write cycle is not byte-identical. Empty means safe."""
    out = []
    for p in paths:
        with open(p, encoding='utf-8') as f:
            raw = f.read()
        if dump(json.loads(raw)) != raw:
            out.append(p)
    return out
