# What's New in Version 2.0.4

**June 2026** — P3 strips trackers before playback. New episode alerts land on time. Background sync finally works. Plus 50+ fixes.

### ✨ New Features
*   **P3 (Privacy Preserving Playback)** — Blocks 30+ tracking and ad-insertion domains before your episode even starts playing. Enable globally or per-podcast. Your P3 preference syncs across all devices. Green shield icon on Now Playing when active.
*   **New Episode Notifications** — Local push notifications when background refresh discovers new episodes. Per-podcast controls: notify for all or pick your favorites. Stale episode delivery ensures you never miss an episode, even when iOS skips a background refresh. 100% local — nothing sent to any push notification server.*
*   **Hidden Episodes** — Hide episodes to declutter your feed without affecting listening stats. "Hide Older Episodes" for batch cleanup on large back catalogs. Hidden state syncs across devices via YourPods Sync.
*   **Clear Queue** — One-tap clear from the Up Next overflow menu. "Clear Up Next" keeps the current episode playing, "Clear Everything" stops playback. Respects your queue removal preference.
*   **Episode Activity** — Chronological list of your played episodes with progress, timestamp, and device. Sort by Recent or By Podcast. Available for YourPods Sync users.
*   **App Icon Badge** — Show unplayed episode count on the app icon. Independent from notifications — configure each separately.
*   **Custom gpodder.net Server Address** — Point at your own gpodder.net-compatible instance. Self-host your sync with any server that speaks the gPodder protocol.
*   **Download from Any Context Menu** — Long-press episodes anywhere in the app to download. No need to navigate to the episode detail screen first.
*   **watchOS: Recently Updated** — The 10 most recent unplayed episodes right on your Apple Watch home screen. Tap to play directly on your wrist.

\* *Due to iOS background limitations, notifications might not always fire. Data never leaves your device.*

### 🔄 Sync & Reliability
*   Background refresh actually works now — respects your toggle, uses your refresh interval, re-schedules on every background entry
*   Incremental sync — only fetches changes since your last sync, not the entire history
*   Batched per-podcast settings sync — one HTTP call instead of one per podcast
*   Fixed mark-as-played not syncing across devices
*   Fixed episodes showing wrong position after cross-device sync
*   Fixed subscription drift — podcasts deleted on another device are now properly removed
*   Fixed replayed episodes finishing instantly
*   AutoPilot global settings now sync to server
*   Per-podcast settings (speed, skip, privacy) sync bidirectionally

### 🚀 Performance
*   6× faster feed refresh (concurrent fetching with real-time progress display)
*   95% reduction in disk I/O during playback — progress, action map, and queue persistence all throttled and batched
*   Faster initial playback on slow networks (10s buffer)
*   Eliminated audio engine data races with compile-time MainActor isolation

### 🐛 Bug Fixes
*   Skip outro actually works during playback now
*   Per-podcast speed no longer leaks between episodes during auto-advance
*   Episode count now matches the actual RSS feed
*   Fixed watchOS freezing, background crashes, and watchdog kills
*   CarPlay: instant metadata display, offline artwork, network-aware recovery
*   Eliminated multiple crash vectors — data races, SwiftData corruption, WAL checkpoints
*   Stale episodes rotated out of RSS feeds are flagged and hidden from counts
*   50+ additional sync, stability, and crash fixes

---

# What's New in Version 2.0.3

**April 2026** — Podcast Groups, comprehensive VoiceOver support, true watch background audio, and 6× faster feed refresh.

### ✨ New Features
*   **Podcast Groups** — Organize your subscriptions into named folders (like "Tech" or "Comedy"), seamlessly bulk-move shows, and browse your groups right from your car dashboard in CarPlay.
*   **VoiceOver Excellence** — Comprehensive VoiceOver support across the entire app. Navigate episodes instantly using custom rotor actions, scrub through audio with adjustable seek bars, and hear dynamic, descriptive labels on all playback controls.
*   **True Watch Background Audio** — Play episodes directly from your Apple Watch and navigate the interface freely without your audio stopping. When an episode ends, your watch automatically advances to the next track.
*   **Enriched OPML Export** — When you export your subscriptions, your custom Podcast Groups and personalized Listening Profiles are now perfectly preserved.
*   **Smarter Chapters** — Expanded smart extraction engine recognizes even more timestamp formats from show notes, automatically generating chapters for you to navigate.
*   **Redesigned Now Playing Card** — The Now Playing card on your Home screen has been beautifully redesigned to feature larger artwork and clearer chapter displays.
*   **Streamlined Onboarding** — A brand-new welcome flow puts Vault Mode and gPodder Sync front and center, making it easier than ever for new users to get started.
*   **Download Network Setting** — Choose exactly when AutoPilot is allowed to download new episodes: Wi-Fi Only, Cellular Only, or both.
*   **Watch-Specific Data Saver** — Toggle Wi-Fi-only downloads specifically for your Apple Watch, independent of your iPhone, to help preserve your watch's battery.
*   **Intelligent Offline Feedback** — Beautiful new offline banners and one-tap retry buttons appear seamlessly when you lose your signal or a stream drops.
*   **Vault to Sync Upgrade** — Started local but ready for the cloud? Easily upgrade your local Vault Mode library to a gPodder sync server without losing a single subscription.
*   **Lightning Fast Sync** — Feed refreshing is now up to 6× faster, complete with a real-time progress display for massive libraries.

### 🐛 Polish & Performance
*   Added a preflight integrity check to gracefully recover from SQLite database corruption
*   Fixed an issue that could cause a gray screen when opening episode details
*   Fixed an issue where duplicate episodes could appear in your Up Next queue
*   Resolved crashes related to large-library syncing and watchOS launches

---

# What's New in Version 2.0.2

**February 2026** — Stability and reliability improvements built on the 2.0 foundation.

*   **SQLite corruption recovery** — Automatic detection and recovery from store corruption, including crash-sentinel protection for signal-level failures.
*   **Sleep timer: end of episode** — Stop playback automatically at the end of the current episode.
*   **Podlove chapter sync** — Chapters now refresh correctly for episodes synced before chapter support was added.
*   **Watch playback resolution** — Prioritizes local downloads for on-watch playback with streaming fallback.
*   **Battery optimizations** — Configurable watch sync intervals and reduced background timer overhead on iPhone.
*   **Improved download cleanup** — Time-based policies (1 week / 1 month) with per-podcast overrides.

---

# What's New in Version 2.0.1

**March 2026** — Quality-of-life improvements and 17 bug fixes.

### ✨ New Features
*   **Podcast Author on Bluetooth Displays** — The "Artist" field on car dashboards, Bluetooth speakers, and headphones with displays now shows the podcast creator name. The podcast name is shown as the "Album" field.
*   **Password-Protected Feed Badge** — Private feeds now show a padlock badge on their artwork in the Library and episode list, making protected feeds easy to identify at a glance.
*   **Editable Feed Credentials** — Feed credentials (username/password) can be edited from Podcast Settings for any protected feed. Credentials are stored securely on-device and never synced to any server.
*   **Queue Removal Preference** — Choose to just remove, remove and mark as played, or always ask when swiping to remove from Up Next.
*   **Long Press Context Menus** — Context menus on episodes in the library (Play, Play Next, Add to Queue, Download, Mark as Played, Details) and on Up Next queue items.
*   **Pull-to-Refresh** — Pull down on Library and Up Next views to refresh all podcast feeds for the latest episodes.
*   **Customizable Headphone Controls** — Choose what AirPods double-tap and triple-tap do: skip forward/back, jump to the next episode, or restart the current one.
*   **Download Cleanup Policy** — Choose when downloaded episodes are automatically deleted: once played, after 1 week, after 1 month, or never. Set a global default and override per-podcast.

### 🐛 Bug Fixes
*   Fix per-podcast AutoPilot setting silently overriding global default when opening Listening Profile sheet
*   Fix per-podcast download cleanup policy silently overriding global default when opening Listening Profile sheet
*   Fix downloads not being automatically removed when an episode finishes playing
*   Fix sync conflict popup appearing every time an episode finishes playing
*   Fix skip-outro putting the completed episode back in Up Next
*   Fix skip-outro draining the entire queue — periodic time observer could call skipToNext() multiple times
*   Migrate gPodder sync passwords from plain UserDefaults to iOS Keychain for secure storage
*   Fix playback position reverting to an earlier point when quitting the app
*   Wire the Conflict Resolution setting to actually control sync behavior
*   Fix sync conflict wizard reappearing on every app launch
*   Fix sync conflict wizard showing duplicate conflicts for the same episode
*   Fix completed episodes triggering spurious sync conflicts
*   Fix queue race condition where finishing an episode could mark all remaining queue episodes as "finished"
*   Fix password-protected podcast feeds failing to authenticate
*   Fix per-podcast skip intro/outro and playback speed settings (Listening Profile) not applying during auto-advance
*   Fix priority AutoPilot episodes not always appearing at the top of Up Next
*   Fix race condition where finishing one episode could auto-complete the entire Up Next queue

---

# What's New in Version 2.0

YourPods 2.0 is a **complete rewrite** in native Swift and SwiftUI.

### 🚀 Complete Native Rewrite
*   **100% Swift and SwiftUI** — Fully native app with faster launch times, smoother animations, and reduced memory usage.
*   **SwiftData** for local storage — Modern, Apple-native persistence layer replacing Hive/SQLite.
*   **Automatic migration** — Existing users seamlessly migrate subscriptions, queue, playback positions, profiles, and settings on first launch.

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
