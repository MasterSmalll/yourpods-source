import Foundation

/// Every String Catalog in the repo, with a key-count floor, plus the JSON
/// loading every localization guard needs.
///
/// A floor is the only thing standing between "this catalog is clean" and
/// "this path stopped resolving three months ago" — both report zero
/// violations. Shared rather than private to one class so that a catalog added
/// to the project cannot be guarded by one test and silently missed by the
/// others.
enum LocalizationCatalogFixture {

    static let catalogs: [(path: String, floor: Int)] = [
        ("YourPods/YourPods/Localizable.xcstrings", 800),
        ("YourPods/YourPods/InfoPlist.xcstrings", 3),
        ("YourPods/YourPods/AppShortcuts.xcstrings", 10),
        ("YourPodsWatch/Localizable.xcstrings", 55),
        ("YourPodsWatch/InfoPlist.xcstrings", 2),
        ("YourPodsWidgets/Localizable.xcstrings", 18),
        ("YourPodsWidgets/InfoPlist.xcstrings", 2),
        ("YourPodsComplication/Localizable.xcstrings", 3),
        ("YourPodsComplication/InfoPlist.xcstrings", 2),
    ]

    /// The repo root, derived from this file's own location so the tests do not
    /// depend on the simulator's working directory.
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // YourPodsTests
            .deletingLastPathComponent()   // repo root
    }

    static func load(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: repositoryRoot.appendingPathComponent(path))
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    static func strings(in catalog: [String: Any]) -> [String: Any] {
        catalog["strings"] as? [String: Any] ?? [:]
    }
}
