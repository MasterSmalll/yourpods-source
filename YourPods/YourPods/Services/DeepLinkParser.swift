import Foundation

/// A parsed `yourpods://` share deep link. `feed` is required for both kinds.
enum SharedLink: Equatable, Sendable {
    case episode(feed: String, guid: String?, audioUrl: String?, startSec: Int?)
    case podcast(feed: String)
}

/// Pure parser for share deep links. The `action` host is reserved for Live Activities.
enum DeepLinkParser {
    static func parse(_ url: URL) -> SharedLink? {
        guard url.scheme == "yourpods" else { return nil }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = comps.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let feed = value("feed") else { return nil }   // required for both kinds

        switch comps.host {
        case "episode":
            let t = value("t").flatMap(Int.init)
            return .episode(feed: feed, guid: value("guid"), audioUrl: value("url"), startSec: t)
        case "podcast":
            return .podcast(feed: feed)
        default:
            return nil   // "action" (Live Activities) and anything else
        }
    }
}
