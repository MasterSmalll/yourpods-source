---
layout: default
---

<p align="center">
  <a href="https://apps.apple.com/us/app/yourpods/id6757721236">
    <img src="https://img.shields.io/badge/Platform-iOS-000000.svg?style=flat&logo=apple" alt="iOS">
  </a>
  <a href="https://apps.apple.com/us/app/yourpods/id6757721236">
    <img src="https://img.shields.io/badge/Platform-macOS-000000.svg?style=flat&logo=apple" alt="macOS">
  </a>
  <a href="https://apps.apple.com/us/app/yourpods/id6757721236">
    <img src="https://img.shields.io/badge/Platform-watchOS-000000.svg?style=flat&logo=apple" alt="watchOS">
  </a>
  <a href="LICENSE">
    <img src="https://img.shields.io/badge/License-GPLv3-blue.svg" alt="License: GPL v3">
  </a>
</p>

# The podcast player that respects your data.

YourPods is a **100% native**, privacy-first podcast player built entirely in **Swift and SwiftUI**. No tracking. No analytics. No ads. Just podcasts — synced across every Apple device you own, powered by your own server.

Pair it with **Nextcloud** and the [gPodder Sync](https://apps.nextcloud.com/apps/gpoddersync) plugin, and your subscriptions and listening progress stay in sync — without ever leaving your infrastructure.

> **gPodder and Nextcloud sync are subscription-free — and always will be.** So is local Vault Mode. Everything YourPods does with your own server is free, in this release and in every release after it. No account, no trial, no paywall on that path.

<p align="center">
  <br/>
  <a href="https://apps.apple.com/us/app/yourpods/id6757721236">
    <img src="https://tools.applemediaservices.com/api/badges/download-on-the-app-store/black/en-us?size=250x83&releaseDate=1708473600" alt="Download on the App Store" height="60">
  </a>
  <br/>
  <br/>
</p>

---

## Built for the entire Apple ecosystem.

### 🚗 CarPlay
Full queue management, a **Recently Updated** tab for new episodes, **chapter navigation** on the Now Playing screen, and in-drive controls for **playback speed** and **trim silence** — all without touching your phone.

### ⌚ Apple Watch
**Standalone playback** with offline episode transfer. Download episodes directly to your wrist, configure how many podcasts sync, and track playback status with **watch complications**.

### 🗣️ Siri & Shortcuts
**32 Shortcuts actions** — chapters, downloads, bookmarks, share links, queue control, and listening stats. Ten of them carry **"Hey Siri" voice phrases**, and actions like Get Current Episode and Get Queue return real values you can chain into your own automations.

### 📱 Widgets, Dynamic Island & Live Activities
A **Now Playing widget** in three sizes with play/pause and skip controls, your Up Next queue on the large size, and real-time playback status on your Lock Screen and Dynamic Island.

---

## A player built for how you listen.

- **Episode Notes** — Timestamped notes on any moment, with colours and tags, anchored to a chapter or a transcript line. Export as Markdown, hand off to an **Obsidian** vault, or file them in your own **Nextcloud Notes**
- **Live Transcripts** — Interactive, auto-scrolling transcripts with in-transcript search and match navigation. SRT, VTT, JSON, HTML, plain text, Markdown, and RTF
- **Smart Chapters** — Chapters embedded in the audio file itself (ID3 in MP3, chapter atoms in MP4/M4A), plus Podcasting 2.0, RSS, and description-parsed chapters — with chapter artwork following playback on the player, lock screen, and CarPlay
- **Precision Playback** — Granular speed control (0.5×–3×), configurable skip intro/outro (0–120s), and trim silence
- **Smart Queue** — Drag-and-drop reordering, quick actions, and visible episode lengths
- **A Library That Scales** — Switch between Podcasts and Episodes, search episode titles and descriptions across every show, swipe rows to queue or hide, and auto-hide unplayed episodes you'll never get to
- **Per-Podcast Settings** — Auto-queue mode, auto-download, remove after play, and archive — configurable per show or as global defaults
- **Sleep Timer** — Set a duration or stop at the end of the current episode
- **Listening Stats** — Track your listening time, streaks, and favorite shows

---

## Your data. Your server. Your rules.

**Free, forever.** gPodder sync, Nextcloud sync, and local Vault Mode carry no subscription and never will.

- **Self-Hosted Sync** — Full [gPodder API](https://gpoddernet.readthedocs.io/) compatibility. Optimized for Nextcloud + [gpodder-sync](https://apps.nextcloud.com/apps/gpoddersync), but works with any gPodder-compatible server
- **Sign in with Nextcloud** — Browser-based Login Flow v2 instead of hand-made app passwords, with one-tap re-authentication when access expires. Manual app-password entry still works for servers that don't support it
- **Nextcloud Notes** — Your episode notes can file themselves into your Nextcloud, as Markdown in a folder you choose or as real notes in the Nextcloud Notes app
- **Multi-Profile** — Switch between different servers or accounts instantly, with listening positions and pending actions kept strictly per profile
- **Local-Only Mode** — No server required. All data stays on your device
- **Password-Protected Feeds** — Subscribe to Patreon and premium feeds. Credentials stored securely in the Keychain — never sent to your sync server
- **OPML Import & Export** — Migrate subscriptions to or from any podcast app
- **Cross-Device Sync** — Subscriptions, listening positions, played state, and hidden episodes follow you across iPhone, iPad, Mac, and Watch. (The gPodder protocol doesn't carry a queue, so Up Next stays per-device on a self-hosted server)

---

## What's New in 26.8.0

*Version numbers now follow a calendar scheme — `yy.mm.vv`, for the year, the month, and the release's index within that month. 26.8.0 is what 2.0.5 would have been.*

- **Episode Notes** — Timestamped notes on any moment, with colours and tags, plus a Notes browser in the Library. Long-press a chapter or a transcript line to anchor a note to it. Free for everyone, on every device.
- **Notes go where you do** — Export as Markdown with YAML frontmatter, hand off to an Obsidian vault, or sync to your own Nextcloud as files or real Nextcloud Notes.
- **Now Playing widget** — Small, medium, and large. Artwork, progress, and a live elapsed clock, with play/pause and skip controls, plus your Up Next queue on the large size.
- **Chapters from the audio file** — ID3 and MP4 chapters embedded in the episode itself, preferred over feed chapters because they stay aligned after dynamic ad insertion. Chapter artwork follows playback on the player, lock screen, and CarPlay.
- **Five new languages** — German, Spanish, French, Italian, and Dutch, across the app, the Watch, widgets, Siri, and VoiceOver. Over 1,080 strings in each.
- **Liquid Glass on iOS 26** — With a Glass Style setting: Classic, Clear, Glass, or High Contrast. Reduce Transparency and Increase Contrast override it automatically.
- **A rebuilt Library** — Switch between Podcasts and Episodes, search episode titles and descriptions across every show, swipe rows to queue or hide, and auto-hide unplayed episodes you'll never get to.
- **Share links** — Share an episode, a show, or the exact second you're listening to, as a share.yourpods.app link minted with Apple device attestation — no account required. Open one and you land on the episode, or on a preview with Play, Add to Queue, and Follow Show.
- **32 Shortcuts actions, up from 13** — Chapters, downloads, bookmarks, share links, and stats, with Siri answering using real data instead of a canned line.
- **Sign in with Nextcloud** — Browser-based login instead of hand-made app passwords, with one-tap re-authentication when it expires.
- **Apple Watch grows up** — Sleep timer, playback speed, your iPhone's skip intervals, the system Now Playing page, and complications that finally show what's playing. Library browsing and background refresh, both broken before, now work.
- **Sync you can trust** — Per-episode version checks so two devices can't overwrite each other's position, a durable outbox so Mark as Played never gets lost, and clearer conflict resolution that actually sticks.
- **P3 catches more trackers** — 39 tracking prefixes across 25 analytics services, from the OPAWG registry plus a curated supplement, matched by host so a tracker changing its URL shape no longer defeats it. Dynamic ad-insertion URLs are now deliberately passed through untouched: P3 is a privacy tool, not an ad blocker.
- **Requires iOS 18** — macOS 14 and watchOS 10 unchanged.

### 2.0.4 — P3, New Episode Notifications & 50+ Fixes

P3 privacy mode blocked trackers before playback, local notifications landed when background refresh found new episodes, hidden episodes decluttered feeds, and feed refresh got 6× faster with a 95% cut in disk I/O during playback.

### 2.0.3 — Podcast Groups, VoiceOver & Watch Background Audio

Organize your library into **Podcast Groups** (named folders with CarPlay browsing), enjoy comprehensive **VoiceOver** support, and use **true background audio on Apple Watch** with automatic auto-advance. Plus enriched OPML export, smarter chapters, and streamlined onboarding.

### 2.0 — Complete Native Rewrite

YourPods 2.0 was a ground-up rewrite — **100% native Swift and SwiftUI**. Faster launch times, smoother animations, reduced memory, and automatic migration from v1.x — no data loss.

---

## A note on YourPods Cloud

YourPods also offers an optional hosted account for people who don't want to run a server. **YourPods Free Sync** is free and keeps subscriptions and listening positions in sync. **YourPods Pro** is a paid tier that adds a web player, cross-device Up Next handoff, and notes sync; pricing lives on the App Store listing.

None of that changes anything above. gPodder, Nextcloud, and Vault Mode are complete, free, and always will be — and episode notes, notes export, P3, transcripts, chapters, CarPlay, and the Apple Watch app all work with no YourPods account at all.

---

## Get YourPods

| | |
|---|---|
| **[yourpods.app](https://yourpods.app)** | Official home — App Store download, feature details, and support |
| **[App Store](https://apps.apple.com/us/app/yourpods/id6757721236)** | Automatic updates — purchasing directly funds development 🙏 |
| **[TestFlight](https://testflight.apple.com/join/jF18YknW)** | Beta access to test upcoming features for free |
| **[Source Code](https://github.com/asecretcompany/yourpods-source)** | Build it yourself — see the README for developer instructions |

---

## Technical Overview

| | |
|---|---|
| **Language** | Swift 5.10 |
| **UI Framework** | SwiftUI |
| **Storage** | SwiftData |
| **Audio** | AVFoundation / AVAudioEngine |
| **Sync** | gPodder API v2 — optimized for [gpodder-sync](https://apps.nextcloud.com/apps/gpoddersync) on Nextcloud, with Nextcloud Login Flow v2 for browser sign-in. Optional YourPods Cloud backend |
| **Localization** | String Catalogs — English source, translated to German, Spanish, French, Italian, and Dutch |
| **Build System** | XcodeGen (`project.yml`) + Swift Package Manager |
| **Dependencies** | Firebase (Auth + App Check), RevenueCat — both for the optional YourPods Cloud account only |
| **Minimum Targets** | iOS 18.0, macOS 14.0, watchOS 10.0 |

### Architecture

| Module | Description |
|--------|-------------|
| `YourPods/Audio/` | AVAudioEngine-based playback engine |
| `YourPods/Models/` | SwiftData models — Podcast, Episode, ServerProfile, Chapter, EpisodeAction, Annotation |
| `YourPods/Networking/` | gPodder API client, RSS parser, URL resolver, P3 tracker stripper |
| `YourPods/Networking/Resources/` | Bundled OPAWG tracker-prefix snapshot + curated supplement |
| `YourPods/Services/` | CarPlay, Live Activities, Transcripts, Watch, Downloads, Background Refresh, Listening Stats, OPML, notes export, share links |
| `YourPods/Services/Chapters/` | Embedded ID3 and MP4 chapter extraction, chapter artwork |
| `YourPods/Services/Intents/` | App Intents, entities, and the Siri handler |
| `YourPods/Services/Sync/` | Sync orchestrators, playback reconciler, baseline store |
| `YourPods/State/` | Observable state managers — Player, Podcast, Settings, Navigation, Sleep Timer |
| `YourPods/Views/` | SwiftUI views and reusable components |
| `YourPods/Utilities/`, `YourPods/Utils/` | Shared helpers and extensions |
| `YourPodsWatch/` | watchOS app with standalone playback |
| `YourPodsWidgets/` | Now Playing widget, Live Activity, and Lock Screen widgets |
| `YourPodsComplication/` | watchOS complication widgets |
| `YourPodsTests/` | Unit tests |
| `TestPlans/` | `Full.xctestplan` (merge gate) and `Smoke.xctestplan` (faster inner loop) |
| `Translations/` | Localization data and the Python tooling that maintains it |
| `fastlane/metadata/` | App Store listing copy, one directory per locale |

### Getting Started

1. **Prerequisites**: Xcode 26+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
2. **Clone**: `git clone https://github.com/asecretcompany/yourpods-source.git`
3. **Generate**: `xcodegen generate`
4. **Open**: `open YourPods.xcodeproj`
5. **Run**: Select the `YourPods` scheme → build for iOS Simulator or device

> The project uses `project.yml` (XcodeGen) to generate the Xcode project. Make changes in `project.yml` and re-run `xcodegen generate` — don't edit the `.xcodeproj` directly.

---

<p align="center">
  Open source under the <a href="LICENSE">GNU General Public License v3.0</a> · Bundled third-party files are credited in <a href="NOTICE.md">NOTICE.md</a> · Built by <a href="https://yourpods.app">A Secret Company</a>
</p>
