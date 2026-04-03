---
layout: default
---

<p align="center">
  <a href="https://yourpods.app">
    <img src="https://img.shields.io/badge/Platform-iOS-000000.svg?style=flat&logo=apple" alt="iOS">
  </a>
  <a href="https://yourpods.app">
    <img src="https://img.shields.io/badge/Platform-macOS-000000.svg?style=flat&logo=apple" alt="macOS">
  </a>
  <a href="https://yourpods.app">
    <img src="https://img.shields.io/badge/Platform-watchOS-000000.svg?style=flat&logo=apple" alt="watchOS">
  </a>
  <a href="LICENSE">
    <img src="https://img.shields.io/badge/License-GPLv3-blue.svg" alt="License: GPL v3">
  </a>
</p>

# The podcast player that respects your data.

YourPods is a **100% native**, privacy-first podcast player built entirely in **Swift and SwiftUI**. No tracking. No analytics. No ads. Just podcasts — synced across every Apple device you own, powered by your own server.

Pair it with **Nextcloud** and the [gPodder Sync](https://apps.nextcloud.com/apps/gpoddersync) plugin, and your subscriptions, queue, and listening progress stay perfectly in sync — without ever leaving your infrastructure.

<p align="center">
  <br/>
  <a href="https://yourpods.app">
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
**10 native voice commands** — play, pause, skip, resume, set speed, play a specific show, and more. Every command doubles as a **Shortcut** for your automations.

### 📱 Dynamic Island & Live Activities
Real-time playback status on your Lock Screen and Dynamic Island — always visible, never intrusive.

---

## A player built for how you listen.

- **Live Transcripts** — Interactive, searchable, auto-scrolling transcripts for supported episodes
- **Smart Chapters** — RSS 2.0, Podcasting 2.0, and description-parsed chapter support for quick navigation
- **Precision Playback** — Granular speed control (0.5×–3×), configurable skip intro/outro (0–120s), and trim silence
- **Smart Queue** — Drag-and-drop reordering, quick actions, and visible episode lengths
- **Per-Podcast Settings** — Auto-queue mode, auto-download, remove after play, and archive — configurable per show or as global defaults
- **Sleep Timer** — Set a duration or stop at the end of the current episode
- **Listening Stats** — Track your listening time, streaks, and favorite shows

---

## Your data. Your server. Your rules.

- **Self-Hosted Sync** — Full [gPodder API](https://gpoddernet.readthedocs.io/) compatibility. Optimized for Nextcloud + [gpodder-sync](https://apps.nextcloud.com/apps/gpoddersync), but works with any gPodder-compatible server
- **Multi-Profile** — Switch between different servers or accounts instantly
- **Local-Only Mode** — No server required. All data stays on your device
- **Password-Protected Feeds** — Subscribe to Patreon and premium feeds. Credentials stored securely in the Keychain — never sent to your sync server
- **OPML Import & Export** — Migrate subscriptions to or from any podcast app
- **Cross-Device Queue Sync** — Your queue follows you across iPhone, iPad, Mac, and Watch

---

## What's New in 2.0.2

The latest release includes stability and reliability improvements built on the 2.0 foundation:

- **SQLite corruption recovery** — Automatic detection and recovery from store corruption, including crash-sentinel protection for signal-level failures
- **Sleep timer: end of episode** — Stop playback automatically at the end of the current episode
- **Podlove chapter sync** — Chapters now refresh correctly for episodes synced before chapter support was added
- **Watch playback resolution** — Prioritizes local downloads for on-watch playback with streaming fallback
- **Battery optimizations** — Configurable watch sync intervals and reduced background timer overhead on iPhone
- **Improved download cleanup** — Time-based policies (1 week / 1 month) with per-podcast overrides

### 2.0 — Complete Native Rewrite

YourPods 2.0 was a ground-up rewrite from Flutter/Dart to **100% native Swift and SwiftUI**. Faster launch times, smoother animations, reduced memory, and automatic migration from v1.x — no data loss.

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
| **Language** | Swift 5.9 |
| **UI Framework** | SwiftUI |
| **Storage** | SwiftData (iOS 17+) |
| **Audio** | AVFoundation / AVAudioEngine |
| **Sync** | gPodder API v2 — optimized for [gpodder-sync](https://apps.nextcloud.com/apps/gpoddersync) on Nextcloud |
| **Build System** | XcodeGen (`project.yml`) + Swift Package Manager |
| **Targets** | iOS 17.0, watchOS 10.0 |

### Architecture

| Module | Description |
|--------|-------------|
| `YourPods/Audio/` | AVAudioEngine-based playback engine |
| `YourPods/Models/` | SwiftData models — Podcast, Episode, ServerProfile, Chapter, EpisodeAction |
| `YourPods/Networking/` | gPodder API client, RSS parser, URL resolver |
| `YourPods/Services/` | CarPlay, Siri, Live Activities, Chapters, Transcripts, Watch, Downloads, Background Refresh, Listening Stats, OPML, Flutter migration |
| `YourPods/State/` | Observable state managers — Player, Podcast, Settings, Navigation, Sleep Timer |
| `YourPods/Views/` | SwiftUI views and reusable components |
| `YourPodsWatch/` | watchOS app with standalone playback |
| `YourPodsWidgets/` | Live Activity and widget extensions |
| `YourPodsComplication/` | watchOS complication widgets |

### Getting Started

1. **Prerequisites**: Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
2. **Clone**: `git clone https://github.com/asecretcompany/yourpods-source.git`
3. **Generate**: `xcodegen generate`
4. **Open**: `open YourPods.xcodeproj`
5. **Run**: Select the `YourPods` scheme → build for iOS Simulator or device

> The project uses `project.yml` (XcodeGen) to generate the Xcode project. Make changes in `project.yml` and re-run `xcodegen generate` — don't edit the `.xcodeproj` directly.

---

<p align="center">
  Open source under the <a href="LICENSE">GNU General Public License v3.0</a> · Built by <a href="https://yourpods.app">A Secret Company</a>
</p>
