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

YourPods is a gPodder-compatible, privacy-first, and self-hosted podcast player. Sync your subscriptions and listening progress across all your devices using your own Nextcloud server, manage multiple profiles, and keep your data 100% yours.

> [!NOTE]
> **Platform Support**: While built with Flutter, this project is heavily optimized for the **Apple Ecosystem** (iOS, macOS, watchOS, CarPlay). 
> Android, Linux, Windows, and Web builds are available in the codebase but are currently **lightly tested and may be unsupported**.

<div align="center">
  <br/>
  <a href="https://apps.apple.com/us/app/yourpods/id6757721236">
    <img src="https://tools.applemediaservices.com/api/badges/download-on-the-app-store/black/en-us?size=250x83&releaseDate=1708473600" alt="Download on the App Store" height="60">
  </a>
  <br/>
  <br/>
</div>

## Installation

The current codebase corresponds to the 1.3.1 release in the [Apple App Store](https://apps.apple.com/us/app/yourpods/id6757721236).

- **App Store**: Get automatic updates and hassle-free installation. Purchasing the App Store version directly funds YourPods development! 🙏
- **TestFlight**: Join the [TestFlight Beta](https://testflight.apple.com/join/jF18YknW) to test new features for free.
- **Source**: Build it yourself from this repository using the [developer instructions](#getting-started-for-developers).

For the most up-to-date features, check our [website](https://asecretcompany.com/yourpods/).

## Feature Highlights

YourPods seamlessly integrates with gPodder-compatible servers (such as Nextcloud & NextPod) to keep your library in sync without relying on third-party clouds.

## New Features in 1.3.1

## 🔐 Account Isolation & Multi-Profile Fixes
- **Per-account data scoping** — Queue, auto-queue settings, playback position, groups, and sync timestamps are now fully isolated between profiles. Switching accounts no longer leaks data from another profile.
- **Local-to-Sync conversion** — You can now switch a Local Account to a Sync Account (and vice versa) directly from the account settings toggle without having to delete and recreate.
- **Settings tab fix** — The "Sync Account" tab in settings is now properly tappable (previously the tap handler was missing).

---

## 🔑 Password-Protected Feeds

- You can now subscribe to RSS feeds that require authentication (e.g. Patreon private feeds, premium podcasts).
- When adding a podcast, toggle **"Authentication Required"** to enter a username and password.
- Credentials are stored securely on-device using the platform keychain — they are **never sent** to your gPodder server.
- Feeds with `user:pass@host` URL-embedded credentials are also supported automatically.

---

## 🎵 Bluetooth & Tesla Metadata (AVRCP)

- **Podcast author now shows on Bluetooth displays** — Previously, the "Artist" line was blank on car dashboards, Bluetooth speakers, and headphones with displays. It now shows the podcast creator name (parsed from `itunes:author` in the RSS feed).
- This benefits **all Bluetooth devices**, including Tesla, which does not support CarPlay.

### What you'll see on your car/speaker display

| Field | Before | Now |
|---|---|---|
| Title | Episode title | Episode title |
| Artist | *(blank)* | Podcast author ✅ |
| Album | Podcast name | Podcast name |
| Artwork | Episode art | Episode art |

---

## 🕐 Last Synced Indicator

- **Settings now shows when your last sync occurred** — A "Last synced: X minutes ago" label appears above the Push/Pull buttons (sync accounts only).
- This helps you quickly confirm whether your data is up-to-date without digging into logs.

---

## 📋 Known Limitations

- The "Last synced" timestamp is **session-only** — it resets when you restart the app. This is intentional to avoid extra storage writes; it answers "has the app synced since I opened it?"
- Password-protected feed credentials are stored **locally only** and are not synced to your gPodder server. If you set up the same feed on another device, you'll need to enter credentials again.

## Experimental: Linux Support

### Dependencies
To build and run on Linux, you need the following dependencies:
```bash
sudo apt-get install libsecret-1-dev libjsoncpp-dev
```

### Snap Package
To build the Snap package:
```bash
snapcraft
```

## Getting Started for Developers

1.  **Prerequisites**: Ensure you have Flutter installed (`flutter doctor`).
2.  **Clone**: `git clone https://github.com/asecretcompany/yourpods-source.git`
3.  **Install**: `flutter pub get`
4.  **Run**: `flutter run`

## License

This project is licensed under the [GNU General Public License v3.0](LICENSE).

## Trademark Policy

"YourPods", the YourPods logo, and the YourPods design are trademarks of A Secret Company, LLC. You may modify and redistribute this software under the terms of the GNU General Public License v3.0, but you may **not** use the "YourPods" name, logo, or assets in any derivative works, modified versions, or commercial products without explicit written permission.

If you fork this project or build it for public distribution, you **must** remove all references to "YourPods" and replace the logo with your own. This ensures that users do not confuse your version with the official release.
