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

YourPods is a clean, simple, and refreshing podcast experience. No app ads. Ever.  YourPods is a **gPodder-compatible**, privacy-first, self-hosted friendly podcast player. Sync your subscriptions and listening progress across all your devices using your own Nextcloud server, manage multiple profiles, and keep your data **100% yours**.

<p align="center">
  <a href="https://apps.apple.com/us/app/yourpods/id6757721236">
    <img src="https://tools.applemediaservices.com/api/badges/download-on-the-app-store/black/en-us?size=250x83&releaseDate=1708473600" alt="Download on the App Store" height="60">
  </a>
</p>

---

## 🍎 Apple Ecosystem Integration

- **CarPlay** — Full queue management, Recently Updated tab, chapter navigation, speed & silence controls
- **Apple Watch** — Standalone playback, offline episode transfer, complications, and configurable sync
- **Dynamic Island** — Real-time playback status on supported iPhones
- **Siri** — 10 native voice commands for hands-free playback
- **Shortcuts** — All Siri intents available as Shortcuts for automations
- **Universal Purchase** — Seamless experience across iPhone, iPad, Mac, and Watch

## 🎧 Player Experience

- **Live Transcripts** — Interactive, searchable transcripts with auto-scroll
- **Smart Chapters** — RSS and description-parsed chapter support for easy navigation
- **Smart Queue** — Manual drag-and-drop reordering with quick actions
- **Precision Control** — Granular playback speed (0.5×–3×), skip intro/outro, and sleep timers
- **Per-Podcast Settings** — Auto-queue, auto-download, remove after play, and archive per podcast
- **Mini Player** — Persistent playback controls across the app

## ☁️ Sync & Privacy

- **Self-Hosted** — Full compatibility with Nextcloud & gPodder
- **Privacy First** — No tracking, no analytics, no ads
- **Multi-Profile** — Switch between different servers or user accounts instantly

## 🔍 Discovery

- **Unified Search** — Defaults to Apple Podcasts for extensive coverage, with optional **PodcastIndex** support
- **Add to Server** — Discover new podcasts in-app and instantly sync subscriptions
- **Background Refresh** — Automatic episode fetching with configurable intervals

---

## What's New in 2.0

- **Complete Swift Rewrite** — 100% native Swift and SwiftUI, replacing the Flutter-based v1.x
- **CarPlay Recently Updated** — Browse new episodes directly from CarPlay
- **CarPlay Chapter Navigation** — Skip between chapters from the Now Playing screen
- **10 Siri Commands** — Play, pause, skip, set speed, and more — all hands-free
- **Per-Podcast Settings** — Auto-queue, auto-download, and more per podcast
- **Automatic Flutter Migration** — Existing users seamlessly migrate all data on first launch
- **Profile Deletion** — Fully delete profiles and associated data
- **Sleep Timer** — Configurable duration with automatic pause

---

## Get Started

| Method | Description |
|--------|-------------|
| **[App Store](https://apps.apple.com/us/app/yourpods/id6757721236)** | Automatic updates — purchasing directly funds development 🙏 |
| **[TestFlight](https://testflight.apple.com/join/jF18YknW)** | Beta access to test new features for free |
| **[Source](https://github.com/asecretcompany/yourpods-source)** | Build it yourself — see the README for developer instructions |

---

## Technical Overview

| | |
|---|---|
| **Language** | Swift 5.9 |
| **UI Framework** | SwiftUI |
| **Storage** | SwiftData (iOS 17+) |
| **Audio** | AVFoundation / AVAudioEngine |
| **Sync Backend** | Optimized for [gpodder-sync](https://apps.nextcloud.com/apps/gpoddersync) on Nextcloud |
| **Build System** | XcodeGen + Swift Package Manager |
| **Targets** | iOS 17.0, watchOS 10.0 |

---

<p align="center">
  Licensed under the <a href="LICENSE">GNU General Public License v3.0</a>
</p>
