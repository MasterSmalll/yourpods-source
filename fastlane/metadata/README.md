# App Store metadata

One directory per App Store Connect locale, holding the listing text.

No fastlane runtime dependency — this is a layout `deliver` also reads, chosen
so the listing lives in the repo and is reviewed like any other user-facing copy.

## The locale codes do not match the binary's

The app localizes on ISO codes; App Store Connect uses its own set:

| Binary | App Store Connect |
|---|---|
| `en` | `en-US` |
| `de` | `de-DE` |
| `es` | `es-ES` |
| `fr` | `fr-FR` |
| `it` | **`it`** — no region |
| `nl` | `nl-NL` |

Two independent systems, so it is entirely possible to ship a fully German app
with an English-only German listing, and nothing in the build would say so.
`StoreMetadataGuardTests` asserts the two sets stay in lockstep.

## Character limits

App Store Connect rejects the upload — after the release is cut — if any of
these is over:

| File | Limit |
|---|---|
| `name.txt` | 30 |
| `subtitle.txt` | 30 |
| `keywords.txt` | 100, comma-separated, no spaces after commas |
| `promotional_text.txt` | 170 |
| `description.txt` | 4000 |
| `release_notes.txt` | 4000 |

German runs about 30% longer than English, so a 24-character English subtitle
lands near 31 in German. The guard checks every field in every locale.

## `name.txt` is the same in every locale, deliberately

App Store Connect lets the app name be localized. We do not localize it: every
locale carries `YourPods: Podcast Player`, which is the live name on the store.

Two reasons. The descriptor is the visible brand under the icon, and a name that
differs per market is a change worth making on purpose rather than as a side
effect of a translation pass. And the field is 30 characters — Spanish
"Reproductor de podcasts" alone overruns it once "YourPods: " is prepended, so
localizing the name means inventing a different descriptor for at least one
market, not translating one.

The localized pitch lives in `subtitle.txt`, which is per-locale and free.

## Status

Updated **2026-08-06 for 26.8.0** (build 80). The listing live on Apple at that
point was still **2.0.4** — none of the corrections below had been uploaded, so
the first 26.8.0 submission carries both them and this release's changes.

What 26.8.0 changed, beyond the release notes:

- `description.txt` advertised "YourPods Sync … free account, cross-device
  queue … listening stats". Queue sync and stats are **Pro** as of this release;
  a free YourPods Cloud account gets subscriptions and listening positions. The
  bullet now says so, and names the tier the app names (`YourPods Cloud`).
- Added what the app gained and the listing never mentioned: embedded chapters
  and chapter artwork, Notes, the Shortcuts catalog, transcript/episode search,
  silence trimming, hiding, and the Home Screen widget.
- `promotional_text.txt` leads on the five new languages. It is the one field
  that can change without a build, so it carries the release's news.
- Dropped the "Platform Integration" bullet — it restated the Apple-ecosystem
  section directly above it — and the "power listener" paragraph, to buy the
  space the new features needed. See the length note below.
- `keywords.txt` and `subtitle.txt` are **unchanged in every locale**. Both are
  ASO decisions, not accuracy fixes, and nothing in this release falsified them.

**The Romance-language descriptions are the binding constraint, not English.**
`es`, `fr` and `it` translate the description ~13% longer and the release notes
~20–25% longer, which puts all three within ~20 characters of the 4000 limit.
English has ~490 characters of visible headroom and roughly **none** in
practice: growing the English description by 100 characters overruns three
locales. Trim English first, then translate — not the other way round.

An earlier reconciliation against Apple on 2026-07-22
(`itunes.apple.com/lookup?id=6757721236`) corrected where the listing had
drifted from the app:

- The architecture bullet described a Flutter app (`provider`, `just_audio`).
  YourPods has been native Swift since long before this listing was written, and
  the next bullet said so, one line down.
- Universal Purchase named the Mac. There is no YourPods record in the Mac App
  Store, so the claim promised something a buyer could not get.
- "No subscriptions. Ever." was true of the shipped build and false of the next
  one: `YourPods Pro in-app subscription` is a v2.0.5 feature. The promotional
  text already said "Pro cloud service is optional" — the listing contradicted
  itself.

The five translations are made from that corrected English. Re-translate if the
English changes; do not edit a translation to match new English by hand.
