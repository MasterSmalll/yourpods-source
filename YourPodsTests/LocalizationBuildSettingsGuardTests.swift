import XCTest

/// Guards the four build settings that make String Catalog extraction work.
///
/// Every one of them defaults to NO. With any of them off, the catalogs stay
/// permanently empty and the app ships English in every locale — with a green
/// build, a green test suite, and no warning anywhere. That silence is the
/// whole reason this test exists.
///
/// `project.yml` is asserted rather than the generated `.pbxproj` because
/// XcodeGen is the source of truth: a correct `.pbxproj` with a reverted
/// `project.yml` is one `xcodegen generate` away from being wrong.
final class LocalizationBuildSettingsGuardTests: XCTestCase {

    /// Settings that must be `true` in `project.yml` `settings.base`.
    private static let requiredSettings = [
        "SWIFT_EMIT_LOC_STRINGS",
        "LOCALIZATION_PREFERS_STRING_CATALOGS",
        "LOCALIZED_STRING_CODE_COMMENTS",
        "STRING_CATALOG_GENERATE_SYMBOLS",
    ]

    private func projectYML() throws -> String {
        var repoRoot = URL(fileURLWithPath: #filePath)   // …/YourPodsTests/ThisFile.swift
        repoRoot.deleteLastPathComponent()               // …/YourPodsTests
        repoRoot.deleteLastPathComponent()               // repo root
        let url = repoRoot.appendingPathComponent("project.yml")
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertGreaterThan(contents.count, 1000,
            "project.yml is implausibly small (\(contents.count) bytes) — the path walk is likely wrong")
        return contents
    }

    // MARK: - Invariant: extraction settings are on

    func test_localizationBuildSettings_areEnabled() throws {
        let yml = try projectYML()
        var missing: [String] = []

        for setting in Self.requiredSettings {
            // Match `  SETTING: true` with any leading indent, tolerating
            // trailing whitespace and comments.
            let pattern = "^\\s*\(setting)\\s*:\\s*true\\s*(#.*)?$"
            let found = yml.split(separator: "\n", omittingEmptySubsequences: false).contains {
                String($0).range(of: pattern, options: [.regularExpression]) != nil
            }
            if !found { missing.append(setting) }
        }

        XCTAssertTrue(missing.isEmpty, """
        project.yml is missing (or has disabled) these localization build settings:
          \(missing.joined(separator: "\n  "))

        Each must appear under settings.base as `NAME: true`. With any of them
        off, every .xcstrings catalog stays empty and the app ships English in
        every locale, silently.
        """)
    }

    func test_developmentLanguage_isDeclared() throws {
        let yml = try projectYML()
        let found = yml.split(separator: "\n", omittingEmptySubsequences: false).contains {
            String($0).range(of: "^\\s*developmentLanguage\\s*:\\s*en\\s*(#.*)?$",
                             options: [.regularExpression]) != nil
        }
        XCTAssertTrue(found,
            "project.yml options is missing `developmentLanguage: en` — the source language must be declared explicitly, not inherited from a default")
    }

    // MARK: - Self-check: the matcher can actually fail

    /// A guard whose assertion cannot fail is not evidence. This proves the
    /// regex rejects the shapes it is supposed to reject.
    func test_settingMatcher_rejectsDisabledAndAbsentForms() {
        let pattern = "^\\s*SWIFT_EMIT_LOC_STRINGS\\s*:\\s*true\\s*(#.*)?$"

        let shouldMatch = [
            "SWIFT_EMIT_LOC_STRINGS: true",
            "    SWIFT_EMIT_LOC_STRINGS: true",
            "    SWIFT_EMIT_LOC_STRINGS:  true   # extraction",
        ]
        for line in shouldMatch {
            XCTAssertNotNil(line.range(of: pattern, options: [.regularExpression]),
                "matcher failed to accept a valid enabled form: \(line)")
        }

        let shouldNotMatch = [
            "    SWIFT_EMIT_LOC_STRINGS: false",
            "    SWIFT_EMIT_LOC_STRINGS: NO",
            "    # SWIFT_EMIT_LOC_STRINGS: true",
            "    SWIFT_EMIT_LOC_STRINGS_OTHER: true",
            "    OTHER_SWIFT_EMIT_LOC_STRINGS: true",
        ]
        for line in shouldNotMatch {
            XCTAssertNil(line.range(of: pattern, options: [.regularExpression]),
                "matcher wrongly accepted: \(line)")
        }
    }
}
