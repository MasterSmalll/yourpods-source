# What's New in Version 26.8.0

**August 2026** — Timestamped episode notes you can export anywhere, chapters read straight from the audio file, a Now Playing widget with real controls, five new languages, and sync that stops losing your place.

> **gPodder and Nextcloud sync are subscription-free — and always will be.** So is local Vault Mode. Everything YourPods does with your own server is free, in this release and in every release after it. There is no account to create, no trial, and no feature behind a paywall on that path.

**Version numbers changed.** YourPods now uses calendar versioning — `yy.mm.vv`, for the year, the month, and the release's index within that month. This release is 26.8.0; it's what 2.0.5 would have been.

### ✨ New Features
*   **Episode Notes** — Save a timestamped note at any point in an episode, from the player, the mini player, or episode detail. Give a note a colour and comma-separated tags, then browse everything you've written from the Notes button in the Library toolbar, grouped by episode and filterable by tag. Free for everyone, on iPhone, iPad, and Mac.
*   **Notes from Chapters and Transcripts** — Long-press a chapter or a transcript line and choose Add Note. The note is stamped at that exact position and keeps the chapter title, or the quoted transcript line, as context.
*   **Markdown Export** — Export your notes as a single Markdown file with YAML frontmatter, grouped by episode, with timestamps, chapter titles, quoted transcript lines, and hashtags. Send it anywhere through the share sheet.
*   **Obsidian Export** — Send notes straight into an Obsidian vault. Set your vault name and mode in Settings → Notes: write a note under "YourPods Notes/&lt;Podcast&gt;", append to today's daily note (needs the Advanced URI plugin), or hand a `.md` file to the share sheet. iPhone and iPad.
*   **Nextcloud Notes** — If you sync with your own Nextcloud server, your notes can go there too: as Markdown files in a folder you choose, or as real notes in the Nextcloud Notes app, filed under a YourPods category per podcast. Sync on demand or automatically on every sync, using the credentials you already saved.
*   **Now Playing Widget** — A Home Screen widget in small, medium, and large. Artwork, episode and show title, and a progress bar with a live-counting elapsed time. Medium and large add play/pause, skip back, and skip forward buttons; large also lists the next four episodes in your Up Next queue.
*   **Liquid Glass** — On iOS 26 the mini player, player controls, Home cards, search cards, and stat cards render with Apple's Liquid Glass material. A new Glass Style setting (Settings → Appearance) picks between Classic, Clear Glass, Glass, and High Contrast Glass. Reduce Transparency and Increase Contrast override the choice automatically, and before iOS 26 the app keeps its classic materials.
*   **Library Episodes View** — The Library's overflow menu now switches between Podcasts and Episodes. Episodes is one flat list across every show that honours the All, Downloaded, Unplayed, and In Progress filters, arranged Newest First, By Date (Today / This Week / Earlier), or By Show. Each row gets an add-or-remove-from-queue button.
*   **Episode Search** — Library search now searches episode titles across every subscription, not just show names. Matches appear in their own Episodes section, and a Search Details pill extends the search to episode descriptions with the matching text shown as a snippet.
*   **Auto-Hide Unplayed Episodes** — Optionally hide unplayed episodes published more than 7 to 90 days ago, on launch and on every refresh. Downloaded and part-listened episodes are left alone, and a per-podcast override can raise or disable the threshold. Settings keeps a per-podcast log with Undo All for 30 days.
*   **Episode Swipe Actions** — Swipe an episode row to run an action. Settings → Episode Swipe Actions assigns Add to Queue, Play Next, Mark as Played, Hide, or Play Now to the left and right swipe (defaults: right is Play Next, left is Add to Queue). Works in podcast detail, the Library Episodes view, and the full Recently Updated list.
*   **Share Links** — Share Episode, Share Podcast, and Share Position now produce a share.yourpods.app link instead of pasting the show's website or the raw audio URL. Share Position bakes in your current timestamp, and the caption reads "Episode at 5:42 — Podcast". Links are minted with Apple's device attestation (App Attest on iPhone and iPad, DeviceCheck on Mac), so no account is required — and if a link can't be created, the share still goes out as plain text.
*   **Opening a Share** — A YourPods episode or podcast link now opens in the app. If you already follow the show you land on the episode sheet, or on the show in your Library. If you don't, a preview sheet shows the artwork, title, and description with Play, Play from the shared timestamp, Add to Queue, and Follow Show.
*   **Sign in with Nextcloud** — Connect a Nextcloud server by logging in through your browser instead of hand-creating an app password. Your credentials stay in the browser, and a "Re-authenticate with Nextcloud" button in the profile editor refreshes access when it expires. Manual app-password entry is still there for servers that don't support it.
*   **AirPlay in the Mini Player** — An output picker now sits beside the skip-forward button. Tap it to send audio to AirPlay speakers or a Bluetooth device; the icon highlights while an external route is active.
*   **Pause on Disconnect** — Playback pauses when your headphones are unplugged or a Bluetooth or AirPlay device drops, instead of continuing on the speaker. Switching from headphones to another output doesn't pause.
*   **Control Center Media Suggestions** — Episodes you play are donated to the system, so YourPods can appear in Control Center and Lock Screen media suggestions with the episode's title, show, and artwork.

### 🎧 Chapters & Transcripts
*   **Embedded Chapters** — YourPods now reads chapters embedded in the audio file itself — ID3 chapters in MP3, chapter atoms in MP4 and M4A — so mainstream shows that ship chapters in the file finally show them. Embedded chapters win over feed chapters because they stay aligned with the audio actually playing, including after dynamic ad insertion.
*   **Chapter Artwork** — Chapter images now show while you listen. The full player and mini-player artwork switch to the current chapter's image, and the lock screen, Control Center, and CarPlay Now Playing image update at every chapter boundary. Chapter thumbnails appear in the chapter list too.
*   **One Chapter List Everywhere** — Chapters are resolved once for the playing episode and shared by the full player, mini player, Home now-playing card, chapter list, CarPlay chapter buttons, and Siri, instead of each screen fetching its own copy. Chapters for a restored episode load at launch, before you press play.
*   **Transcript Search** — Search inside a transcript from the transcript sheet. Matches are highlighted, the toolbar shows "3 of 12" with up and down buttons to jump between them, and auto-scroll pauses while you're searching. Tapping a match still seeks there.
*   **More Transcript Formats** — Transcripts published as Markdown or RTF now render as readable text, alongside SRT, VTT, JSON, plain text, and HTML. Format is decided from the type the feed declares, then the URL, then the file's contents — and a mislabeled transcript falls back to plain text instead of the Transcript button quietly disappearing.
*   **Late-Published Transcripts** — An episode queued before its transcript was published now shows the transcript once the feed has it.
*   **Cleaner HTML Transcripts** — HTML transcripts no longer leak page titles, stylesheet, or script text into the body, and curly quotes, dashes, and numeric character codes decode correctly instead of showing as raw entities.

### 🗣️ Siri & Shortcuts
*   **32 Shortcuts Actions** — Up from 13. New ones include next and previous chapter, restart episode, extend the sleep timer, check for new episodes, download your queue or a show's latest episode, mark played and play next, clear the queue with a confirmation prompt, open a show or your queue, and bookmark the moment you're listening to. Ten of them carry "Hey Siri" voice phrases — Apple's cap.
*   **Actions That Return Values** — Get Current Episode, Get Queue, Get Podcasts, What's Next, Get Listening Stats, and Get Share Link hand back real values you can chain into your own automations. Episodes carry title, show, position, remaining time, played state, and a deep link.
*   **Pick a Show, Don't Type It** — Play Podcast and Play Latest Episode now take a real show from your library instead of typed text, with a picker showing each show's artwork and author, and match what you say against your subscriptions.
*   **Siri That Actually Answers** — Every voice command runs the real action and waits for it to finish before Siri replies, so playback controls work even when the app was suspended. Siri reads back what actually happened: the episode and show it started, how many episodes are in your queue, "Up next is …", your listening minutes, or an honest reason when it can't help. "What's playing?" now names the episode instead of telling you to open the app.
*   **Bookmark This Moment** — Ask Siri or run a shortcut to save a timestamped note on whatever is playing, with optional dictated text. It works without opening the app, so it can hang off a Back Tap or an automation.
*   **Get Share Link** — Ask Siri or run a Shortcut to get a link to what you're playing, stamped at the current moment, without opening the app.
*   **Siri & Shortcuts Settings** — A new Settings screen lists every voice phrase with an example of what to say, shows tips for bookmarking, playing your queue, and checking for new episodes, and opens the Shortcuts app straight to YourPods' actions.

### 🌍 Localization
*   **Five New Languages** — YourPods is now available in German, Spanish, French, Italian, and Dutch alongside English, with over 1,080 strings translated in each. The app follows the language you set for it in iOS Settings or macOS System Settings.
*   **Every Surface Translated** — The Apple Watch app is translated too, including its player, queue, chapter list, sleep timer, and download screens, as are the Home Screen widgets, the Lock Screen Live Activity, and the watch complication.
*   **Siri in Your Language** — The voice phrases for playback, your queue, skipping, playback speed, and the sleep timer are translated, and everything Siri says back is translated too.
*   **Localized VoiceOver** — VoiceOver labels, hints, and actions are translated as well, so screen-reader users hear the app in their own language on iPhone, iPad, Mac, Apple Watch, and in widgets.
*   **Grammar and Formatting That Fits** — Episode counts and durations use each language's own plural rules, so you get "1 Folge" and "12 Folgen" rather than one shape for both, and durations read naturally per language — a two-and-a-half-hour episode shows as "2 Std. 30 Min." in German instead of "2h 30m".
*   **Translation Notice** — The first time YourPods opens in a language other than English, it explains that the translations are AI-assisted and may read a little off, and links to support so you can report anything wrong. Settings gains a Language & Translation section with the resolved language, a shortcut to where iOS or macOS lets you change it, and a link to report a problem.

### ⌚ Apple Watch & CarPlay
*   **Sleep Timer on Apple Watch** — 15 minutes, 30 minutes, an hour, or end of episode, from the watch player. The button shows the time remaining, and the timer still stops playback if the episode is buffering when it expires.
*   **Playback Speed on Apple Watch** — Tap the speed button to cycle 0.75× through 2×. The choice is remembered on the watch; long-press to go back to matching your iPhone.
*   **Now Playing Page on the Watch** — The watch app now includes the system Now Playing page alongside the player, for Digital Crown volume, transport controls, and the output-device picker.
*   **Watch Skip Buttons Match Your iPhone** — Skip back and skip forward use your configured intervals instead of a fixed 15 and 30 seconds, on the watch player, the iPhone remote screen, and the watch's Now Playing controls.
*   **Watch Library Browsing** — Opening a podcast on the watch returned a list that spun on "Loading episodes…" forever, because the iPhone and the watch disagreed on the payload field names. Episode lists load now, and the screen shows a real "No Episodes", "Couldn't Load Episodes" (tap to retry), or "iPhone Not Reachable" state instead of spinning.
*   **Watch Complications** — Complications now show what's playing, what's up next, and your queue count. Nothing ever wrote that data before, so they were always empty. Playing, pausing, or a queue change on your phone updates them, and identical state is skipped so the watch's refresh budget isn't wasted.
*   **Watch Background Refresh** — The watch's scheduled refresh never ran: the task was scheduled without the identifier the handler matches on, and any fresh queue the iPhone replied with was discarded. The watch queue updates in the background now.
*   **Watch Progress Survives an Unreachable iPhone** — Position updates, mark-as-played, and queue removals from the watch are queued and delivered when the iPhone comes back, instead of being dropped when it was asleep or out of range.
*   **Watch Downloads** — Re-downloading an episode after relaunching the watch app created a second copy of the same file; filenames are deterministic now, so it doesn't. Audio no episode references anymore is cleaned up automatically, while episodes you downloaded yourself are kept until you delete them. Downloads started from Recently Updated or a podcast's episode list correctly show as downloaded.
*   **Watch Battery** — Auto-advancing with the screen off no longer restarts the once-per-second progress timer for the rest of the session. Artwork is decoded at a bounded size, downloads no longer hold the radio open indefinitely, and the iPhone stops re-sending the whole queue on every position tick.
*   **Watch Playback Errors** — Starting playback with no headphones connected says "Connect Bluetooth headphones and try again" instead of a raw error, and a failed stream releases the player instead of leaving the watch stuck. Chapter times past an hour show as 1:05:00 rather than 65:00.
*   **Watch Accessibility** — Queue rows, Now Playing on iPhone, Library, chapters, and the speed and sleep-timer buttons on the watch have spoken VoiceOver labels and values, with times read as durations rather than digits.
*   **CarPlay Chapters** — The CarPlay chapter-skip buttons only recognized chapters from a separate chapters file or the episode description, so shows with chapters embedded in the audio or inline in the feed did nothing. CarPlay uses the same chapter list as the rest of the app now.
*   **CarPlay Offline Now Playing** — Tapping an episode in the car with no signal used to show a black Now Playing screen with a creeping progress bar. It now shows the title, your saved position, the episode length, cover art (cached, or a YourPods placeholder instead of the system grey note), and a paused state with an honest "No connection" message.

### 🛡️ P3 Privacy Preserving Playback
*   **More Trackers Blocked** — P3 now removes 39 tracking prefixes covering 25 analytics services, up from 31 hardcoded patterns. The list ships with the app as a snapshot of the OPAWG public prefix registry plus a curated supplement, adding Blubrry, Podkite, Podder, Podcards, Glystn, Voxalyze, and Médiamétrie, plus extra hosts for services already covered.
*   **P3 Keeps Working When Trackers Change Their URLs** — Instead of one hardcoded path pattern per service, P3 recognises a tracker by its host and then finds the real audio URL by scanning the path. URLs that were silently missed because a service used a different path shape are stripped now, and any subdomain of gum.fm or proxycast.org is covered rather than just one.
*   **More Tracking Parameters Removed** — Alongside `utm_*`, P3 strips AdsWizz attribution parameters (`awCollectionId`, `awEpisodeId`), while signed playback parameters such as `token` and `expires` are left untouched so playback still works.
*   **P3 No Longer Rewrites Dynamic Ad-Insertion URLs** — Hosts such as Megaphone and AdsWizz serve the audio themselves with ads stitched in, so there is no inner URL to reveal, and rewriting them risked pointing playback at something that isn't the episode. P3 passes those URLs through untouched. P3 is a privacy tool, not an ad blocker.

### 🔄 Sync & Reliability
*   **Cross-Device Played State** — Finishing or marking an episode played on one device marks it played on the others, and un-marking it somewhere else clears the played state here instead of it coming back on the next sync.
*   **Mark as Played Survives Everything** — Marking an episode played goes into a durable outbox that retries on every sync until the server confirms it, so a dropped connection, a background kill, or an expired token no longer silently loses it. It also no longer produces a sync conflict against your own action moments later.
*   **Positions Can't Overwrite Each Other** — Playback positions are pushed with a per-episode version check, so two devices can't quietly overwrite each other's place in an episode. If both are playing it, each keeps its own position; if only one is, that one wins; if neither is, your conflict setting decides — and you're only asked when there's a real standoff.
*   **Clearer Sync Conflicts** — The conflict sheet says whose position each side is, and shows "Played" instead of a bogus end-of-episode timestamp when the server holds the episode as finished. Buttons read "All Local" and "All from Server", a recurring conflict says how many times it has come back, an "Always use this choice" toggle saves the side you pick, and every row and button has a full VoiceOver description.
*   **Conflict Resolutions That Stick** — Choosing a position writes it authoritatively to the server, so picking the earlier of two positions is no longer quietly refused and re-offered on the next sync. A conflict the server has already retired refreshes the list instead of leaving a dead prompt, and resolving while offline still applies on this device.
*   **Duplicate Conflicts After Re-Sync** — Re-syncing after dismissing a conflict no longer invents a second one with the device and server positions swapped.
*   **Positions When Switching Episodes** — Switching episodes records the exact position you left the previous one at. Before, the position reported was the one it had when it started playing, so anything you listened to in that session could be lost to other devices.
*   **Positions from Apple Watch** — Positions sent from Apple Watch are saved even when that episode isn't loaded on the phone, so resuming on iPhone picks up where the watch left off and never rewinds.
*   **Feed Address Changes** — When a show moves to a new feed address, your Accept or Keep decision is confirmed with the server before the library changes, so a failure leaves the prompt in place to retry instead of losing the decision. Declining stops the prompt reappearing on every sync.
*   **Positions Stay in Their Profile** — Listening positions, pending actions, and sync baselines are stored per sync profile, so switching between accounts — a gPodder server and a YourPods account, say — can't carry one profile's positions into another's conflict detection or push them to the wrong server. Existing data is migrated to the active profile on first launch.
*   **Export My Data** — Download everything a YourPods Cloud account has synced — subscriptions, playback history, settings — as a JSON file from the profile editor, and share or save it anywhere. Free and Pro accounts alike. (gPodder, Nextcloud, and Vault Mode libraries already export as OPML.)

### 🚀 Performance
*   **Faster, Lighter Sync** — YourPods Cloud accounts pull only what changed since the last sync instead of re-fetching the whole listening history; hidden and played state arrive in the same request as positions, one fewer call per sync; and independent steps run in parallel. A sync with nothing new writes almost nothing to the database instead of rewriting every unchanged episode, and the heavy writes moved off the main thread.
*   **Background Sync Priorities** — Background refresh now syncs playback positions, played state, and the queue before refreshing feeds, so the roughly 30 seconds iOS allows are spent on what you notice first. It stops cleanly at step boundaries when time runs out, and a window of changes is only marked received once it has actually been applied, so an interrupted sync re-delivers instead of dropping.
*   **Refresh Skips Feeds That Haven't Changed** — YourPods sends ETag and If-Modified-Since with each feed request and understands a 304 Not Modified reply, so a refresh only re-downloads feeds that actually published something.
*   **iPad App on a Mac** — Switching back to the window pulls the latest state after about two seconds instead of waiting out a five-minute debounce, and an in-progress sync is no longer cancelled every time the window loses focus — which is why it could sit on stale now-playing and queue state.
*   **Stability** — Database writes are held open by a background-task assertion so iOS can't kill the app mid-write when it suspends, and a save is skipped rather than risked when the system grants no background time. A corrupt WAL index file left by an earlier crash is cleared at launch, breaking the crash-on-launch loop it caused.

### 🐛 Bug Fixes
*   Downloaded episodes play in airplane mode — a downloaded episode could still try to stream and stall when the queue advanced with no network
*   Marking the episode you're listening to as played from Home or an episode list now advances to the next episode in Up Next, or stops when Up Next is empty
*   A new date parser handles date-only pubDates, timestamps without seconds, asctime, full month names, "Sept", slash-separated dates, European time zone names, trailing zone comments, and fractional seconds — episodes from those feeds now show the correct date, sort correctly, and are no longer skipped by Recently Updated
*   Episode lists no longer reshuffle when episodes share a publish timestamp or have none — ties break by season, episode number, and the feed's own document order, consistently on the podcast screen, in CarPlay, and when picking the next episode
*   Recently Updated gives every show a slot before a prolific show fills the rest; the window widened from two to three months, a "+N more" card opens a full All Recent Episodes list, and how many episodes it shows is now a setting (9 to 36, default 27, up from a fixed 12)
*   Hide and Unhide are now in the context menus and VoiceOver actions of Home's episode cards, the mini player, Up Next rows including the currently playing episode, and the podcast preview sheet
*   Episode rows show a Queued badge when the episode is already in Up Next, and offer Remove from Queue instead of Add to Queue
*   The sleep timer sheet scrolls and can be dragged to full height, so its controls stay reachable at large text sizes
*   The watch complication and Lock Screen widgets no longer paint a solid blue block behind their content
*   The Your Data & Privacy screen lists episode notes among the data stored for a YourPods Cloud account

### ☁️ YourPods Cloud (optional)
*   **Free Sync and Pro** — The optional YourPods Cloud account is now two tiers. **YourPods Free Sync stays free** and keeps your subscriptions and listen positions in sync. **YourPods Pro** adds the web player, cross-device Up Next handoff, and notes sync. Pro is tied to your account rather than the device you bought it on, so a subscription started on the web unlocks the app and the other way round; Restore Purchase brings it back on a new device. Pricing lives on the App Store listing.
*   **This changes nothing for self-hosters** — gPodder, Nextcloud, and Vault Mode are free, complete, and always will be. Episode notes, notes export to Markdown and Obsidian, notes sync to your own Nextcloud, P3, transcripts, chapters, CarPlay, and the Apple Watch app all work without any YourPods account at all.
*   **Up Next handoff is the one Pro-only sync** — gPodder and Nextcloud servers sync your subscriptions and listening positions, which is what the gPodder protocol carries; they don't carry a queue. If you want Up Next to follow you between devices, that's what Pro adds.

### 📱 Platform & Requirements
*   **iOS 18 or later** — This release raises the minimum iPhone and iPad requirement from iOS 17 to iOS 18. macOS 14 and watchOS 10 are unchanged.
*   **Liquid Glass needs iOS 26** — Before that the app keeps its previous materials.
*   **Calendar versioning** — Version numbers move from the 2.0.x semver line to `yy.mm.vv`.

---

# What's New in Version 2.0.4

**June 2026** — P3 strips trackers before playback. New episode alerts land on time. Background sync finally works. Plus 50+ fixes.

### ✨ New Features
*   **P3 (Privacy Preserving Playback)** — Strips known tracking redirects from episode URLs before playback even starts, so your device never contacts them. Enable globally or per-podcast. Your P3 preference syncs across all devices. Green shield icon on Now Playing when active.
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
