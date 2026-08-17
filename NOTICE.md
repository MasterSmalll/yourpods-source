# Third-Party Notices

YourPods is licensed under the [GNU General Public License v3.0](LICENSE). A few files in
this repository come from elsewhere and carry their own terms. They are listed here in full.

---

## Tracker prefix data — OPAWG

**Files:** `YourPods/YourPods/Networking/Resources/opawg-prefixes.snapshot.json`

A point-in-time snapshot of the podcast prefix/analytics provider list published by the
Open Podcast Analytics Working Group (OPAWG).

- **Source:** <https://github.com/opawg/podcast-prefixes> (`src/prefixes.json`)
- **License:** MIT
- **Copyright:** © the OPAWG contributors

P3 (Privacy Preserving Playback) reads this snapshot to recognise tracking-redirect hosts
locally, on device. The `notes` fields inside the snapshot are the upstream maintainers'
own commentary about the services they describe — they are reproduced verbatim and are
**not** assessments made by YourPods.

`trackers-supplemental.json`, in the same directory, is written and maintained by the
YourPods project and is covered by the GPLv3 like the rest of this repository.

---

## Chapter test fixtures — Auphonic

**Files:**
- `YourPodsTests/Fixtures/chapters-id3.mp3`
- `YourPodsTests/Fixtures/chapters-mp4.m4a`

Auphonic's public "Enhanced Chapter Marks" demo files, used as fixtures for the embedded
chapter parsers. They carry real ID3v2 `CHAP`/`CTOC` frames and MP4 chapter tracks with
per-chapter artwork, which is exactly what the parsers need to be tested against.

- **Source:** <https://auphonic.com/blog/5/> — <https://auphonic.com/>
- **Author:** Auphonic
- **License:** [Creative Commons Attribution 3.0 Austria](http://creativecommons.org/licenses/by/3.0/at/) (CC BY 3.0 AT)

These files are unmodified. The attribution above is provided in fulfilment of the
CC BY licence; it applies to the audio fixtures only, not to any YourPods source code.

---

## Swift package dependencies

These are fetched by Swift Package Manager at build time and are **not** vendored into this
repository. They are pulled in only for the optional YourPods Cloud account — the local,
gPodder, Nextcloud and Vault paths never touch them.

| Package | License |
|---|---|
| [firebase-ios-sdk](https://github.com/firebase/firebase-ios-sdk) (Auth, App Check) | Apache-2.0 |
| [purchases-ios](https://github.com/RevenueCat/purchases-ios) (RevenueCat) | MIT |

---

If you believe something in this repository is misattributed or missing from this file,
please open an issue — we would rather fix it than argue about it.
