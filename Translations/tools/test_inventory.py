"""Self-checks for the triage classifier.

Every one of these exists because the classifier could otherwise return a
plausible-looking empty answer. An earlier scan shipped a wrong claim by
testing `"" in entries` against a list of dicts — always False, always "clean".
A classifier that cannot report a hit is not a classifier.
"""
import inventory


def test_degenerate_detects_number_only_keys():
    assert inventory.is_degenerate("15")
    assert inventory.is_degenerate("%llds")
    assert not inventory.is_degenerate("15 minutes")


def test_degenerate_ignores_letters_inside_specifiers():
    # %lld is a specifier, not the letters l-l-d.
    assert inventory.is_degenerate("%lld")
    assert not inventory.is_degenerate("%lld episodes")


def test_case_variant_groups_collapse_case_and_trailing_punctuation():
    groups = inventory.case_variant_groups(["Sleep Timer", "Sleep timer", "Done"])
    assert groups == {"sleep timer": ["Sleep Timer", "Sleep timer"]}


def test_case_variant_groups_ignore_singletons():
    assert inventory.case_variant_groups(["Done", "Cancel"]) == {}


def test_handrolled_plural_detects_specifier_glued_pluraliser():
    assert inventory.is_handrolled_plural("%lld podcast%@")
    assert inventory.is_handrolled_plural("%lld podcast%@ selected")
    assert not inventory.is_handrolled_plural("%lld episodes")


def test_numeric_specifier_distinguishes_counts_from_strings():
    assert inventory.has_numeric_specifier("%lld episodes")
    assert not inventory.has_numeric_specifier("Play %@")


if __name__ == "__main__":
    import sys
    import traceback

    cases = [(n, f) for n, f in sorted(globals().items()) if n.startswith("test_")]
    failures = 0
    for name, case in cases:
        try:
            case()
            print(f"  ok    {name}")
        except Exception:
            failures += 1
            print(f"  FAIL  {name}")
            traceback.print_exc()
    print(f"\n{len(cases) - failures}/{len(cases)} passed")
    sys.exit(1 if failures else 0)
