# What's New in Version 2.0

YourPods 2.0 is a **complete rewrite** in native Swift and SwiftUI — replacing the Flutter-based v1.x entirely.

### 🚀 Complete Native Rewrite
*   **100% Swift and SwiftUI** — Fully native app with faster launch times, smoother animations, and reduced memory usage.
*   **SwiftData** for local storage — Modern, Apple-native persistence layer replacing Hive/SQLite.
*   **Automatic Flutter migration** — Existing users seamlessly migrate subscriptions, queue, playback positions, profiles, and settings on first launch.

### 🚗 CarPlay Enhancements
*   **Recently Updated tab** — Browse new, unplayed episodes directly from CarPlay.
*   **Chapter navigation** — Prev/Next Chapter buttons on the Now Playing screen.
*   **Speed & silence controls** — Adjust playback speed and toggle trim-silence from CarPlay.
*   **Artwork placeholders** — Artwork always displays immediately with a placeholder while full images load.

### 🗣️ Siri & App Intents
*   **10 native Siri commands** — Play, pause, stop, resume, skip forward/backward, next episode, play latest, play specific podcast, set playback speed.
*   **Shortcuts integration** — All intents work as Shortcuts and can be added to automations.

### ⏱️ Per-Podcast Settings
*   **Auto-queue mode** (off / normal / priority), **auto-download**, **remove after playing**, and **archive on complete** — configurable per podcast and as global defaults.

### 🔐 Account & Sync
*   **Profile deletion** — Fully delete profiles and all associated data.
*   **Per-profile sync timestamps** — Switching profiles no longer causes stale syncs.
*   **Episode Activity view** — Inspect recent sync actions in Settings.

### ⌚ Apple Watch
*   **Standalone playback** with offline episode transfer.
*   **Watch complications** showing playback status.
*   **Configurable sync** — Choose how many podcasts sync to the watch.

### 🎵 Playback
*   **Native AVFoundation audio engine** — Rebuilt for Bluetooth reliability, Siri interruption recovery, and background auto-advance.
*   **Sleep timer** with configurable durations.
*   **Skip intro/outro** with per-second precision (0–120s).
*   **Trim silence** toggle.

### 🎨 Appearance
*   **Theme support** — System, light, or dark mode.
*   **Tab bar customization** — Text only, icon only, or both.
*   **Configurable start page** — Choose Home, Library, or Up Next as your default tab.

### Core Carried Forward from 1.x.x
*   Cross-Device Queue Sync via gPodder server
*   OPML Import & Export
*   Password-Protected Feeds (Patreon, premium)
*   Local Accounts (no server required)
*   Live Transcripts
*   Smart Chapters (RSS + ID3)
*   Dynamic Island & Live Activities
*   Listening Stats dashboard
*   Background Refresh
*   Unified Search (iTunes / PodcastIndex)
*   Bluetooth & Car Display Metadata

---

# What's New in Version 1.3.1

This update brings major new features, sync improvements, and playback reliability fixes.

### New Features
*   **Cross-Device Queue Sync:** Your queue now syncs across devices via your gPodder server. Pick up right where you left off on any device — no extra setup needed.
*   **OPML Import & Export:** Easily migrate your podcast subscriptions to or from other apps, or back up your library.
*   **Password-Protected Feeds:** Subscribe to private RSS feeds (Patreon, premium podcasts). Credentials are stored securely on-device and never sent to your sync server.
*   **Local Accounts:** Use YourPods without a sync server for fully offline, on-device podcast management. Convert between Local and Sync accounts at any time.
*   **Last Synced Indicator:** Settings now shows when your last sync occurred so you can quickly confirm your data is up-to-date.

### Improvements
*   **Bluetooth & Car Display Metadata:** Podcast author name now appears on Bluetooth car dashboards, speakers, and headphones (including Tesla). Previously the "Artist" line was blank.
*   **Background Auto-Advance:** Episodes now reliably advance to the next queued episode while the app is backgrounded.
*   **Streaming Resilience:** Playback recovers gracefully from network drops instead of silently stopping. Improved handling for tunnels, subway, and low-connectivity areas.
*   **User-Visible Error Messages:** Clear feedback when network issues occur — no more silent failures.

### Bug Fixes
*   Fixed playback position loss when restarting the app.
*   Fixed mini player showing the wrong episode after relaunch.
*   Fixed account switcher briefly showing the "add account" screen on launch.
*   Fixed issues with marking episodes as read.
*   Fixed Apple Watch library sync and download problems.
*   Fixed excessive battery and CPU usage.
*   Fixed data leaking between account profiles (queue, settings, positions).

---

# What's New in Version 1.3.0

This update focuses on polishing the CarPlay experience:

*   **CarPlay Progress Bar:** Fixed an issue where the progress bar would freeze or fail to update.
*   **Playback Stability:** Resolved crashes and UI glitches when opening the Now Playing screen.
*   **Reliable Resuming:** Tapping an episode now consistently resumes playback exactly where you left off.

*   **Listening Stats:** Gain insights into your listening habits with our new stats dashboard. Track your listening time, streaks, and favorite shows.
*   **Podcast Search:** Discover new content easily! You can now search for podcasts using either iTunes or the open-source PodcastIndex directory.
*   **Enhanced Privacy:** Securely store your API keys and manage your data preferences.
*   **Performance & Stability:** Various bug fixes and performance improvements for a smoother experience.

# What's New in Version 1.2.1

YourPods is now available in your car and on your wrist!

*   **CarPlay Support:** Browse your library, see what's playing, and control playback safely while you drive.
*   **Apple Watch App:** Keep track of your podcasts and control playback directly from your wrist.
*   **Dynamic Island & Live Activities:** See episode progress and controls at a glance on your Lock Screen or Dynamic Island.
*   **Chapters:** Easily skip to the parts you want with full chapter support.
*   **Priority Queue:** Use the new "Queue New" options to prioritize episodes and play them next.
*   **Smarter Sync:** Improved background downloads and sync reliability for a seamless experience across devices.
