# YourPods — Spec Compliance Tracker

> **Last Updated**: 2026-03-24  
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
| `podcast:transcript` | Item | ✅ | `RSSService.swift`, `TranscriptService.swift`, `TranscriptListSheet.swift` |
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

---

## gPodder Sync API v2

### P0 — [Nextcloud gPodder Sync](https://github.com/thrillfall/nextcloud-gpodder)

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

### P1 — [RePod](https://git.crystalyx.net/Xefir/repod) (GPodderSync-compatible)

Same API surface as P0. RePod uses identical Nextcloud GPodderSync endpoints.

| Feature | Status |
|---------|--------|
| All P0 endpoints | ✅ |
| RePod-specific extensions | N/A (none currently) |

**P1 Score: 10/10** ✅

### P2 — [gpodder.net](https://github.com/gpodder/mygpo) Full API

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

## Overall Summary

| Spec | Supported | Total | Coverage |
|------|-----------|-------|----------|
| RSS 2.0 Core | 9 | 12 | 75% |
| Apple itunes: 1.x | 11 | 15 | 73% |
| Podcasting 2.0 | 10 | 27 | 37% |
| gPodder P0 (NC) | 10 | 10 | **100%** ✅ |
| gPodder P1 (RePod) | 10 | 10 | **100%** ✅ |
| gPodder P2 (full) | 5 | ~18 | ~28% |

---

## Changelog

| Date | Change |
|------|--------|
| 2026-03-24 | gPodder sync: session auth (login/logout + NC Basic auth fallback), `update_urls` handling with conflict resolution UI, `getSubscriptions` full import, `registerDevice`/`listDevices` |
|| UI: explicit, category, complete, serial, publisher, funding, V4V, live, and season/episode badges on podcast detail, episode rows, and library views |
|| RSS parsing: `itunes:explicit`, `type`, `season`/`episode`, `episodeType`, `category`, `new-feed-url`, `complete` + `podcast:guid`, `funding`, `publisher`, `value`, `liveItem`, `language`, `copyright` |
|| Initial audit against RSS 2.0, Apple itunes: 1.x, Podcasting 2.0, gPodder API v2 |
