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

YourPods is a clean, simple, and refreshing podcast experience. No app ads. Ever.  YourPodsis a **gPodder-compatible**, privacy-first, self-hosted friendly podcast player. Sync your subscriptions and listening progress across all your devices using your own Nextcloud server, manage multiple profiles, and keep your data **100% yours**.

<p align="center">
  <a href="https://apps.apple.com/us/app/yourpods/id6757721236">
    <img src="https://tools.applemediaservices.com/api/badges/download-on-the-app-store/black/en-us?size=250x83&releaseDate=1708473600" alt="Download on the App Store" height="60">
  </a>
</p>

---

## 🍎 Apple Ecosystem Integration

- **CarPlay** — Full queue management and playback control with native UI
- **Apple Watch** — Standalone playback, offline episode transfer, and haptic controls
- **Dynamic Island** — Real-time playback status on supported iPhones
- **Siri** — Voice commands for hands-free playback
- **Universal Purchase** — Seamless experience across iPhone, iPad, Mac, Watch, and Apple TV

## 🎧 Player Experience

- **Live Transcripts** — Interactive, searchable transcripts with auto-scroll
- **Smart Chapters** — Embedded chapter support for easy navigation
- **Smart Queue** — Manual drag-and-drop reordering with quick actions
- **Precision Control** — Granular playback speed slider and custom sleep timers
- **Mini Player** — Persistent playback controls across the app

## ☁️ Sync & Privacy

- **Self-Hosted** — Full compatibility with Nextcloud & gPodder
- **Privacy First** — No tracking, no analytics, no ads
- **Multi-Profile** — Switch between different servers or user accounts instantly

## 🔍 Discovery

- **Unified Search** — Defaults to iTunes for extensive coverage, with optional **PodcastIndex** support
- **Add to Server** — Discover new podcasts in-app and instantly sync subscriptions

---

## What's New in 1.3.0

- **Audio Engine 2.0** — Rewritten audio handling to resolve Bluetooth dropouts and improve stability
- **Queue Redesign** — Distinguished "Now Playing" and "Up Next" sections with visible episode lengths
- **Sync Conflict Management** — Smart conflict resolution with options to keep local or server state
- **CarPlay & WatchOS Polish** — Smoother UI updates, reliable progress bars, and performance optimizations

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
| **Sync Backend** | Optimized for [gpodder-sync](https://apps.nextcloud.com/apps/gpoddersync) on Nextcloud |
| **Protocol** | Open Podcast Sync (subscriptions + episode actions) |
| **Architecture** | Flutter with `provider` state management and `just_audio` playback |
| **Native Integrations** | CarPlay (Swift), WatchOS (SwiftUI), tvOS (SwiftUI), iOS Live Activities |
| **Security** | `flutter_secure_storage` for credentials, local DB for offline capability |

---

<p align="center">
  Licensed under the <a href="LICENSE">GNU General Public License v3.0</a>
</p>
