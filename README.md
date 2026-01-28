<div align="center">

<img src="assets/images/logo.png" width="128" height="128" alt="YourPods Logo" />

<h1>YourPods</h1>

<p><strong>Privacy-first, self-hosted podcast player for iOS, macOS, and Apple Watch.</strong></p>

<p>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-GPLv3-blue.svg" alt="License: GPL v3"></a>
  <a href="https://apps.apple.com/us/app/yourpods/id6757721236"><img src="https://img.shields.io/badge/Platform-iOS-000000.svg?style=flat&logo=apple" alt="Platform: iOS"></a>
  <a href="https://apps.apple.com/us/app/yourpods/id6757721236"><img src="https://img.shields.io/badge/Platform-macOS-000000.svg?style=flat&logo=apple" alt="Platform: macOS"></a>
  <a href="https://apps.apple.com/us/app/yourpods/id6757721236"><img src="https://img.shields.io/badge/Platform-watchOS-000000.svg?style=flat&logo=apple" alt="Platform: watchOS"></a>
</p>

<p>
  <a href="#feature-highlights">Feature Highlights</a> •
  <a href="#installation">Installation</a> •
  <a href="#technical">Technical Details</a> •
  <a href="#getting-started-for-developers">Contributing</a>
</p>

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

The current codebase corresponds to the 1.2 release in the [Apple App Store](https://apps.apple.com/us/app/yourpods/id6757721236).

- **App Store**: Get automatic updates and hassle-free installation. Purchasing the App Store version directly funds YourPods development! 🙏
- **TestFlight**: Join the [TestFlight Beta](https://testflight.apple.com/join/jF18YknW) to test new features for free.
- **Source**: Build it yourself from this repository using the [developer instructions](#getting-started-for-developers).

For the most up-to-date features, check our [website](https://asecretcompany.com/yourpods/).

## Feature Highlights

YourPods seamlessly integrates with gPodder-compatible servers (such as Nextcloud & NextPod) to keep your library in sync without relying on third-party clouds.

### 🍎 Apple Ecosystem Integration
- **CarPlay**: Full queue management and playback control with native UI.
- **Apple Watch**: Standalone playback, offline episode transfer, and haptic controls.
- **Siri Support**: Voice commands for hands-free playback.
- **Universal Purchase**: Seamless experience across iPhone, iPad, and Mac.

### 🎧 Player Experience
- **Smart Queue**: Manual drag-and-drop reordering with "Move to Top/Bottom" quick actions.
- **Precision Control**: Granular playback speed slider and custom sleep timers.
- **Mini Player**: Persistent playback controls across the app.
- **Metadata Caching**: Configurable cache duration for faster load times and reduced server strain.

### ☁️ Sync & Privacy
- **Self-Hosted**: Full compatibility with Nextcloud/gPodder.
- **Privacy First**: No tracking, no analytics, no ads.
- **Multi-Profile**: Switch between different servers or user accounts instantly.

## Technical

- **Sync Backend**: Optimized for the [gpodder-sync](https://apps.nextcloud.com/apps/gpoddersync) Nextcloud app. Standard `gpodder` services may work but are not the primary focus.
- **Protocol**: Implements the Open Podcast Sync protocol for subscriptions (`SubscriptionDelta`) and actions (`EpisodeAction`).
- **Architecture**: Built with `provider` for state management and `just_audio` for robust playback.
- **Storage**: Uses `flutter_secure_storage` for credentials and local database for offline capability.

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
2.  **Clone**: `git clone https://github.com/asecretcompany/yourpods.git`
3.  **Install**: `flutter pub get`
4.  **Run**: `flutter run`

## License

This project is licensed under the [GNU General Public License v3.0](LICENSE).

## Trademark Policy

"YourPods", the YourPods logo, and the YourPods design are trademarks of A Secret Company, LLC. You may modify and redistribute this software under the terms of the GNU General Public License v3.0, but you may **not** use the "YourPods" name, logo, or assets in any derivative works, modified versions, or commercial products without explicit written permission.

If you fork this project or build it for public distribution, you **must** remove all references to "YourPods" and replace the logo with your own. This ensures that users do not confuse your version with the official release.
