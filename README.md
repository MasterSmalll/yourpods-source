<div align="center">

# YourPods

<img src="assets/images/logo.png" width="128" height="128" alt="YourPods Logo" />

**Privacy-first, self-hosted podcast player for iOS, macOS, and Apple Watch.**

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Platform: iOS](https://img.shields.io/badge/Platform-iOS-000000.svg?style=flat&logo=apple)](https://apps.apple.com/us/app/yourpods/id6757721236)
[![Platform: macOS](https://img.shields.io/badge/Platform-macOS-000000.svg?style=flat&logo=apple)](https://apps.apple.com/us/app/yourpods/id6757721236)
[![Platform: watchOS](https://img.shields.io/badge/Platform-watchOS-000000.svg?style=flat&logo=apple)](https://apps.apple.com/us/app/yourpods/id6757721236)

[Feature Highlights](#feature-highlights) • [Installation](#installation) • [Technical Details](#technical) • [Contributing](#getting-started-for-developers)

</div>

---

> [!IMPORTANT]
> **YourPods 2.0.4 — Latest Release**
>
> YourPods is built natively in **Swift and SwiftUI**.

YourPods is a gPodder-compatible [Nextcloud-gpodder](https://github.com/thrillfall/nextcloud-gpodder) or [Nextcloud-Nextpod](https://github.com/pbek/nextcloud-nextpod), privacy-first, and self-hosted podcast player. Sync your subscriptions and listening progress across all your devices using your own Nextcloud server, manage multiple profiles, and keep your data 100% yours. Check out [Repod](https://git.crystalyx.net/Xefir/repod/) for podcast listening via your Nextcloud install.

<div align="center">
  <br/>
  <a href="https://apps.apple.com/us/app/yourpods/id6757721236">
    <img src="https://tools.applemediaservices.com/api/badges/download-on-the-app-store/black/en-us?size=250x83&releaseDate=1708473600" alt="Download on the App Store" height="60">
  </a>
  <br/>
  <br/>
</div>

## Installation

The current codebase corresponds to the 2.0.4 release in the [Apple App Store](https://apps.apple.com/us/app/yourpods/id6757721236).

- **App Store**: Get automatic updates and hassle-free installation. Purchasing the App Store version directly funds YourPods development! 🙏
- **TestFlight**: Join the [TestFlight Beta](https://testflight.apple.com/join/jF18YknW) to test new features for free.
- **Source**: Build it yourself from this repository using the [developer instructions](#getting-started-for-developers).

For the most up-to-date features, check our [website](https://yourpods.app).

## Feature Highlights

YourPods seamlessly integrates with gPodder-compatible servers (such as Nextcloud & NextPod) to keep your library in sync without relying on third-party clouds.

### What's New in 2.0.4

#### 🛡️ P3 Privacy Mode
- **Privacy Preserving Playback** — blocks 30+ tracking and ad-insertion domains from episode URLs before playback. Enable globally or per-podcast. Green shield icon on Now Playing when active.

#### 🔔 New Episode Notifications
- **Local push notifications** when background refresh discovers new episodes. Per-podcast controls. Stale episode delivery ensures you never miss an update. 100% local — no push servers.

#### 🙈 Hidden Episodes & Clear Queue
- **Hidden Episodes** — declutter your feed without affecting listening stats. Batch-hide old episodes. Hidden state syncs across devices.
- **Clear Queue** — one-tap clear from the Up Next overflow menu.

#### ⚡ Performance & Reliability
- **6× faster feed refresh** with concurrent fetching and real-time progress display.
- **95% reduction in disk I/O** during playback — progress, action map, and queue persistence all throttled and batched.
- **Incremental sync** — only fetches changes since your last sync, not the entire history.
- **Background sync fixed** — the toggle, interval, and re-scheduling all work reliably now.
- Eliminated audio engine data races with compile-time MainActor isolation.
- 50+ additional sync, stability, and crash fixes.

#### 🆕 Also New in 2.0.4
- **Episode Activity** — chronological played-episode list with progress, timestamp, and device.
- **App Icon Badge** — unplayed episode count on the app icon.
- **Custom gpodder.net server address** — point at your own gpodder.net-compatible instance.
- **Download from any context menu** — long-press episodes anywhere to download.
- **watchOS: Recently Updated** — 10 most recent unplayed episodes on your wrist.

---

### What's New in 2.0.3

#### 📁 Podcast Groups
- **Named folders** — organize your library into groups like "Tech" or "Comedy". Bulk-move shows and browse groups in CarPlay.

#### ♿ VoiceOver Excellence
- Comprehensive VoiceOver support across the entire app — custom rotor actions, adjustable seek bars, and descriptive labels on every control.

#### ⌚ Watch Background Audio
- True background playback on Apple Watch — navigate freely while listening, with automatic episode auto-advance on your wrist.

#### 🆕 Also New in 2.0.3
- **Enriched OPML export** preserves custom groups and Listening Profiles.
- **Smarter chapters** — expanded timestamp format recognition from show notes.
- **Redesigned Now Playing card** with larger artwork and clearer chapter display.
- **Download network setting** — Wi-Fi Only, Cellular Only, or both.
- **Vault to Sync upgrade** — migrate a local Vault Mode library to a gPodder server without losing subscriptions.
- **Streamlined onboarding** — new welcome flow for Vault Mode and gPodder Sync.

---

### What's New in 2.0

#### 🚀 Complete Native Rewrite
- **100% Swift and SwiftUI** — fully native app with fast launch times, smooth animations, and low memory usage.
- **SwiftData** for local storage — Modern, Apple-native persistence layer.

---

#### 🚗 CarPlay Enhancements
- **Recently Updated tab** — browse new, unplayed episodes directly from CarPlay without reaching for your phone.
- **Chapter navigation** — skip between chapters using dedicated Prev/Next Chapter buttons on the Now Playing screen.
- **Speed & silence controls** — adjust playback speed and toggle trim-silence directly from CarPlay.
- **Artwork placeholders** — podcast and episode artwork always displays immediately with a placeholder while full artwork loads.

---

#### 🗣️ Siri & App Intents
- **10 native Siri commands** — play, pause, stop, resume, skip forward/backward, next episode, play latest, play a specific podcast, and set playback speed — all hands-free.
- **Shortcuts integration** — all intents work as Shortcuts and can be added to automations.

---

#### ⏱️ Per-Podcast Settings
- **Auto-queue mode** (off / normal / priority), **auto-download**, **remove after playing**, and **archive on complete** — configurable per podcast and as global defaults for new subscriptions.

---

#### 🔐 Account & Sync
- **Profile deletion** — fully delete profiles and all associated data.
- **Per-profile sync timestamps** — switching profiles no longer causes stale syncs.
- **Episode Activity view** — inspect recent sync actions in Settings.

---

#### ⌚ Apple Watch
- **Standalone playback** with offline episode transfer.
- **Watch complications** showing playback status.
- **Configurable sync** — choose how many podcasts sync to the watch.

---

#### 🎵 Playback
- **Native AVAudioEngine** — rebuilt audio pipeline for Bluetooth reliability, Siri interruption recovery, and background auto-advance.
- **Sleep timer** with configurable durations.
- **Skip intro/outro** with per-second precision (0–120s).

---

### Carried Forward from 1.x

- **Cross-Device Queue Sync** via gPodder server
- **OPML Import & Export** for subscription migration
- **Password-Protected Feeds** (Patreon, premium feeds) — credentials stored securely on-device
- **Local Accounts** — no server required
- **Live Transcripts** — interactive, searchable, auto-scrolling
- **Smart Chapters** — RSS and ID3 tag support
- **P3 Privacy Mode** — tracker stripping before playback
- **Podcast Groups** — named folders with CarPlay browsing
- **Hidden Episodes** — declutter feeds without affecting stats
- **New Episode Notifications** — local push alerts
- **Dynamic Island & Live Activities** on supported iPhones
- **Listening Stats** dashboard
- **Background Refresh** with configurable intervals
- **Unified Search** — iTunes or PodcastIndex
- **Appearance** — system, light, or dark theme; configurable tab bar style and start page

## Getting Started for Developers

1.  **Prerequisites**: Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
2.  **Clone**: `git clone https://github.com/asecretcompany/yourpods-source.git`
3.  **Generate project**: `xcodegen generate`
4.  **Open**: `open YourPods.xcodeproj`
5.  **Run**: Select the `YourPods` scheme and build for an iOS Simulator or device.

> [!NOTE]
> The project uses `project.yml` (XcodeGen) to generate the Xcode project. Do not edit `YourPods.xcodeproj` directly — make changes in `project.yml` and re-run `xcodegen generate`.

## Technical

| | |
|---|---|
| **Language** | Swift 5.9 |
| **UI** | SwiftUI |
| **Storage** | SwiftData (iOS 17+) |
| **Audio** | AVFoundation / AVAudioEngine |
| **Sync** | gPodder-compatible (Nextcloud gpodder-sync) |
| **Minimum Targets** | iOS 17.0, watchOS 10.0 |
| **Build System** | XcodeGen (`project.yml`) + Swift Package Manager |

### Architecture

- `YourPods/YourPods/Audio/` — Audio playback engine (AVAudioEngine-based)
- `YourPods/YourPods/Models/` — SwiftData models (Podcast, Episode, ServerProfile, etc.)
- `YourPods/YourPods/Networking/` — gPodder API client, RSS parser, URL resolver
- `YourPods/YourPods/Services/` — CarPlay, Siri, Live Activities, Chapters, Transcripts, Watch, Downloads, Background Refresh, Listening Stats, OPML
- `YourPods/YourPods/State/` — State managers (Player, Podcast, Settings, Navigation, Sleep Timer)
- `YourPods/YourPods/Views/` — SwiftUI views and reusable components
- `YourPodsWatch/` — watchOS app with standalone playback
- `YourPodsWidgets/` — Live Activities and widget extensions
- `YourPodsComplication/` — watchOS complications



## License

This project is licensed under the [GNU General Public License v3.0](LICENSE).

## Trademark Policy

"YourPods", the YourPods logo, and the YourPods design are trademarks of A Secret Company, LLC. You may modify and redistribute this software under the terms of the GNU General Public License v3.0, but you may **not** use the "YourPods" name, logo, or assets in any derivative works, modified versions, or commercial products without explicit written permission.

If you fork this project or build it for public distribution, you **must** remove all references to "YourPods" and replace the logo with your own. This ensures that users do not confuse your version with the official release.
