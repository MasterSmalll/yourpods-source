# YourPods — Spec Compliance Tracker

> **Last Updated**: 2026-05-19 (Stats events v2 schema — id, timestamp, segment tracking, raw array format)  
> **Purpose**: Living document tracking YourPods support across podcast specs and sync protocols. Update when implementing features or when upstream specs change.

---

## RSS 2.0 Core

| Tag | Scope | Status | Impl File(s) |
|-----|-------|--------|-------------|
| `<title>` | Channel + Item | ✅ | `RSSService.swift` |
| `<description>` | Channel + Item | ✅ | `RSSService.swift` |
| `<link>` | Channel + Item | ✅ | `RSSService.swift` |
| `<pubDate>` | Item | ✅ | `RSSService.swift` |
| `<guid>` | Item | ✅ | `RSSService.swift` |
| `<enclosure>` | Item | ✅ | `RSSService.swift` |
| `content:encoded` | Item | ✅ | `RSSService.swift` |
| `<language>` | Channel | ✅ | `RSSService.swift` |
| `<copyright>` | Channel | ✅ | `RSSService.swift` |
| `<managingEditor>` | Channel | ❌ | — |
| `<image>` (RSS native) | Channel | ❌ | — |
| `<category>` | Channel | ❌ | — |

**Score: 9/12**

---

## Apple itunes: 1.x Namespace

| Tag | Scope | Status | Impl File(s) |
|-----|-------|--------|-------------|
| `itunes:image` | Channel + Item | ✅ | `RSSService.swift` |
| `itunes:author` | Channel | ✅ | `RSSService.swift` |
| `itunes:duration` | Item | ✅ | `RSSService.swift` |
| `itunes:explicit` | Channel + Item | ✅ | `RSSService.swift` |
| `itunes:type` | Channel | ✅ | `RSSService.swift` |
| `itunes:season` | Item | ✅ | `RSSService.swift` |
| `itunes:episode` | Item | ✅ | `RSSService.swift` |
| `itunes:episodeType` | Item | ✅ | `RSSService.swift` |
| `itunes:category` | Channel | ✅ | `RSSService.swift` |
| `itunes:new-feed-url` | Channel | ✅ | `RSSService.swift`, `PodcastManager.swift` |
| `itunes:owner` | Channel | ❌ | — |
| `itunes:summary` | Channel + Item | ❌ | — |
| `itunes:subtitle` | Channel + Item | ❌ | — |
| `itunes:title` | Item | ❌ | — |
| `itunes:complete` | Channel | ✅ | `RSSService.swift` |
| `itunes:block` | Channel + Item | ➖ | Publisher-only |

**Score: 11/15** (excluding publisher-only)

---

## Podcasting 2.0 Namespace

| Tag | Scope | Status | Impl File(s) |
|-----|-------|--------|-------------|
| `podcast:transcript` | Item | ✅ | `RSSService.swift`, `TranscriptService.swift`, `TranscriptListSheet.swift` — SRT, VTT, JSON, `text/plain`, `text/html` |
| `podcast:chapters` | Item | ✅ | `RSSService.swift`, `ChapterService.swift`, `ChapterListSheet.swift` |
| `podcast:guid` | Channel | ✅ | `RSSService.swift` |
| `podcast:funding` | Channel + Item | ✅ | `RSSService.swift` |
| `podcast:season` | Item | ✅ | `RSSService.swift` |
| `podcast:episode` | Item | ✅ | `RSSService.swift` |
| `podcast:person` | Channel + Item | ❌ | — |
| `podcast:image` | Channel + Item | ❌ | — |
| `podcast:publisher` | Channel | ✅ | `RSSService.swift` |
| `podcast:trailer` | Channel | ❌ | — |
| `podcast:soundbite` | Item | ❌ | — |
| `podcast:location` | Channel + Item | ❌ | — |
| `podcast:license` | Channel + Item | ❌ | — |
| `podcast:contentLink` | Item | ✅ | `RSSService.swift` (inside liveItem) |
| `podcast:podroll` | Channel | ❌ | — |
| `podcast:remoteItem` | Child of podroll | ❌ | — |
| `podcast:updateFrequency` | Channel | ❌ | — |
| `podcast:socialInteract` | Item | ❌ | — |
| `podcast:chat` | Channel + Item | ❌ | — |
| `podcast:alternateEnclosure` | Item | ❌ | — |
| `podcast:source` | Child of altEnc | ❌ | — |
| `podcast:integrity` | Child of altEnc | ❌ | — |
| `podcast:medium` | Channel | ❌ | — |
| `podcast:value` | Channel + Item | ✅ | `RSSService.swift` (presence flag) |
| `podcast:valueRecipient` | Child of value | ❌ | — |
| `podcast:valueTimeSplit` | Child of value | ❌ | — |
| `podcast:liveItem` | Channel | ✅ | `RSSService.swift` (display data) |
| `podcast:locked` | Channel | ➖ | Publisher-only |
| `podcast:block` | Channel | ➖ | Publisher-only |
| `podcast:txt` | Channel | ➖ | Publisher-only |
| `podcast:podping` | Channel | ➖ | Server-side |

**Score: 10/27** (excluding publisher/server-only)

> **Web API availability**: `podcast:person`, `podcast:soundbite`, `podcast:medium`, `podcast:trailer`, `podcast:podroll`, and `podcast:remoteItem` are parsed server-side (Build 130) and available via `GET /api/yourpods/library` and `GET /api/yourpods/podcast?feedUrl=`. iOS can display these from the API without adding them to `RSSService.swift`.

---

## gPodder Sync API v2

### P0 — Nextcloud gPodder Sync

| Endpoint | Status | Impl File(s) |
|----------|--------|-------------|
| HTTP Basic Auth | ✅ | `GPodderClient.swift` |
| `GET subscriptions?since=` (delta) | ✅ | `GPodderClient.swift` |
| `POST subscription_change/create` (delta) | ✅ | `GPodderClient.swift` |
| `POST episode_action/create` | ✅ | `GPodderClient.swift`, `EpisodeAction.swift` |
| `GET episode_action?since=` | ✅ | `GPodderClient.swift`, `EpisodeAction.swift` |
| Episode action: play | ✅ | `EpisodeAction.swift` |
| Episode action: new | ✅ | `EpisodeAction.swift` |
| Episode action: download | ✅ | `EpisodeAction.swift` |
| Episode action: delete | ✅ | `EpisodeAction.swift` |
| Handle `update_urls` response | ✅ | `GPodderClient.swift`, `PodcastManager.swift`, `SyncConflictSheet.swift` |

**P0 Score: 10/10** ✅

### P1 — Self-Hosted gPodder (GPodderSync-compatible)

Same API surface as P0. Any self-hosted gPodder-compatible server uses identical Nextcloud GPodderSync endpoints.

| Feature | Status |
|---------|--------|
| All P0 endpoints | ✅ |
| Server-specific extensions | N/A (none currently) |

**P1 Score: 10/10** ✅

### P2 — gpodder.net Full API

| API Group | Endpoint | Status | Impl File(s) |
|-----------|----------|--------|-------------|
| **Auth** | Session login | ✅ | `GPodderClient.swift` |
| | Session logout | ✅ | `GPodderClient.swift` |
| **Subscriptions** | Get subs of device (full) | ✅ | `GPodderClient.swift` |
| | Get all subs (no device) | ❌ | — |
| | Upload subs (full PUT) | ❌ | — |
| **Episode Actions** | `aggregated` param | ❌ | — |
| **Devices** | Register/update device | ✅ | `GPodderClient.swift` |
| | List devices | ✅ | `GPodderClient.swift` |
| | Get device updates | ❌ | — |
| **Settings** | Get settings | ❌ | — |
| | Save settings | ❌ | — |
| **Favorites** | Get favorites | ❌ | — |
| **Device Sync** | Get sync status | ❌ | — |
| | Start/stop sync | ❌ | — |
| **Directory** | All endpoints | ❌ | — |
| **Suggestions** | Get suggestions | ❌ | — |
| **Podcast Lists** | All endpoints | ❌ | — |
| **Client Config** | Get config | ❌ | — |

**P2 Score: 5/~18**

---

## YourPods Pro API

YourPods Pro is an optional enhanced sync backend. Firebase is used for authentication only; the sync API is a REST protocol defined at [opensource.yourpods.app](https://opensource.yourpods.app).

### Authentication

| Endpoint | Status | Impl File(s) |
|----------|--------|-------------|
| Firebase email/password sign-in | ✅ | `FirebaseAuthProvider.swift` |
| Firebase email/password account creation | ✅ | `FirebaseAuthProvider.swift` |
| JWT bearer token refresh | ✅ | `FirebaseAuthProvider.swift` |
| Sign in with Apple | ⏳ Planned | — |
| Sign in with Google | ⏳ Planned | — |

### Sync Endpoints

| Endpoint | Status | Impl File(s) |
|----------|--------|-------------|
| `POST /auth/session` | ✅ | `YourPodsProClient.swift` |
| `GET /api/yourpods/subscriptions` | ✅ | `YourPodsProClient.swift` |
| `POST /api/yourpods/subscriptions/add` | ✅ | `YourPodsProClient.swift` |
| `POST /api/yourpods/subscriptions/remove` | ✅ | `YourPodsProClient.swift` (v2: POST body, replaces DELETE) |
| `POST /api/yourpods/playback/sync` (batch) | ✅ | `YourPodsProClient.swift` |
| `GET /api/yourpods/playback/recent?since=` | ✅ | `YourPodsProClient.swift` |
| `GET /api/yourpods/playback/current` | ✅ | `YourPodsProClient.swift` |
| `GET /api/yourpods/queue` | ✅ | `YourPodsProClient.swift` |
| `POST /api/yourpods/queue/sync` | ✅ | `YourPodsProClient.swift` |
| `POST /api/yourpods/queue/add` | ✅ | `YourPodsProClient.swift` |
| `DELETE /api/yourpods/queue?episodeUrl=` | ✅ | `YourPodsProClient.swift`, `PlayerManager.swift` (queue tombstone) |
| `GET /api/yourpods/settings/profile?profileName=` | ✅ | `YourPodsProClient.swift` (v2 — replaces v1 `/settings/global`) |
| `PATCH /api/yourpods/settings/profile` | ✅ | `YourPodsProClient.swift` (v2 — replaces v1 `/settings/global`) |
| `GET /api/yourpods/settings/profile/podcasts?profileName=` | ✅ | `YourPodsProClient.swift` (v2 — replaces v1 `/settings/podcasts`) |
| `PATCH /api/yourpods/settings/profile/podcasts` | ✅ | `YourPodsProClient.swift` (v2 — replaces v1 `/settings/podcasts`) |
| `GET /api/yourpods/settings/profiles` | ✅ | `YourPodsProClient.swift` |
| `POST /api/yourpods/settings/profile/fork` | ✅ | `YourPodsProClient.swift` |
| `POST /api/yourpods/stats/events` (batch) | ✅ | `YourPodsProClient.swift`, `StatsEventBuffer.swift`, `PlayerManager.swift` — raw JSON array, segment-based events with `id` (UUID dedup) + `timestamp` (ISO 8601), auto-flush at 50 events / 30s / pause / episode-end, min segment filter (contentSec > 1s, durationSec > 0.5s) |
| `GET /api/yourpods/stats?since=ISO8601` | ✅ | `YourPodsProClient.swift`, `ProStatsView.swift` — tiered response: `tier=sync` (basic), `tier=pro` (full dashboard) |
| `GET /api/yourpods/groups` | ✅ | `YourPodsProClient.swift` |
| `POST /api/yourpods/groups/sync` | ✅ | `YourPodsProClient.swift`, `PodcastManager.swift` (push-first invariant) |
| `GET /api/yourpods/groups/assignments` | ✅ | `YourPodsProClient.swift` |
| `POST /api/yourpods/groups/assignments/sync` | ✅ | `YourPodsProClient.swift` |
| `POST /api/yourpods/episodes/hide` | ✅ | `YourPodsProClient.swift`, `EpisodeActionSyncService.swift` (hidden set), `PodcastDetailView.swift`, `EpisodeDetailSheet.swift` |
| `POST /api/yourpods/episodes/unhide` | ✅ | `YourPodsProClient.swift`, `EpisodeActionSyncService.swift` (hidden set), `PodcastDetailView.swift`, `EpisodeDetailSheet.swift` |

### Account Management

| Endpoint | Status | Impl File(s) |
|----------|--------|-------------|
| `POST /account/delete` | ✅ | `YourPodsProClient.swift`, `EditProfileView.swift` (typed DELETE confirmation) |

**Pro Score: 26/26 endpoints** ✅

> **v1→v2 Migration Status**: Complete. All settings sync uses v2 profile-scoped endpoints exclusively. v1 handlers (`/settings/global`, `/settings/podcasts`) are dead code on the iOS side — server team confirmed v1 endpoint removal and `podcast_settings` table deprecation is proceeding (2026-05-11).

---

## Overall Summary

| Spec | Supported | Total | Coverage |
|------|-----------|-------|----------|
| RSS 2.0 Core | 9 | 12 | 75% |
| Apple itunes: 1.x | 11 | 15 | 73% |
| Podcasting 2.0 | 10 | 27 | 37% |
| gPodder P0 (NC) | 10 | 10 | **100%** ✅ |
| gPodder P1 (Self-Hosted) | 10 | 10 | **100%** ✅ |
| gPodder P2 (full) | 5 | ~18 | ~28% |
| YourPods Pro API | 26 | 26 | **100%** ✅ |

---

## Changelog

_See `spec_compliance_changelog.md` for full history._
