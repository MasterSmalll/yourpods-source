# Contributing to YourPods

Thank you for your interest in contributing to YourPods! We welcome contributions from the community to help make this the best self-hosted podcast player.

## Getting Started

1.  **Prerequisites**: Xcode 26+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
2.  **Fork the repository** on GitHub.
3.  **Clone your fork** locally:
    ```bash
    git clone https://github.com/YOUR-USERNAME/yourpods-source.git
    cd yourpods-source
    ```
4.  **Generate the Xcode project**:
    ```bash
    xcodegen generate
    ```
5.  **Open the project**:
    ```bash
    open YourPods.xcodeproj
    ```
6.  **Run**: Select the `YourPods` scheme and build for an iOS Simulator or device.

> **Note**: The project uses `project.yml` (XcodeGen) to generate the Xcode project. Do not edit `YourPods.xcodeproj` directly — make changes in `project.yml` and re-run `xcodegen generate`.

### Credentials are placeholders

This repository ships placeholders where the official build has real credentials:

| Where | Placeholder |
|---|---|
| `YourPods/GoogleService-Info.plist` | `YOUR_API_KEY`, `YOUR_PROJECT_ID`, `YOUR_GCM_SENDER_ID`, `YOUR_GOOGLE_APP_ID` |
| `project.yml` → `DEVELOPMENT_TEAM` | `YOUR_TEAM_ID` |
| `SubscriptionManager.swift` → `apiKey` | `YOUR_REVENUECAT_API_KEY` |

**You do not need to replace any of them.** Everything this project is actually about —
local playback, gPodder sync, Nextcloud sync and Vault Mode — works with the placeholders
untouched. `FirebaseBootstrap` detects them and skips Firebase entirely, so the app builds
and runs; only the optional hosted YourPods Cloud account is unavailable.

Set `DEVELOPMENT_TEAM` to your own team ID if you want to run on a physical device. Supply
your own Firebase and RevenueCat credentials only if you are standing up your own hosted
backend.

### Running the tests

Two test plans, both defined in `TestPlans/`:

```bash
xcodebuild test -scheme YourPods -destination 'platform=iOS Simulator,name=iPhone 17'                 # Full
xcodebuild test -scheme YourPods -destination 'platform=iOS Simulator,name=iPhone 17' -testPlan Smoke # Smoke
```

`Full` is the merge gate. `Smoke` is `Full` minus the classes that wait on real time, for a
faster inner loop. Coverage is off by default in both — add `-enableCodeCoverage YES` when
you need it.

### Localization

User-facing copy lives in String Catalogs (`.xcstrings`), shipped in English, German,
Spanish, French, Italian and Dutch. A set of guard tests enforces the rules — every key
carries a translator comment, counted keys have real plural rules, no translation drifts
away from the English it was made from, and no localization API is called on the sync wire.

The supporting tooling is in `Translations/tools/`:

| Script | Does |
|---|---|
| `inventory.py` | classifies every key into a triage bucket |
| `sync_catalogs.py` | syncs source strings into the catalogs (dry run by default, `--apply` to write) |
| `english_hashes.py` | records a digest of the English each translation was made from |
| `translation_io.py` | exports catalogs for translation and imports the results back |
| `consistency.py`, `critic.py` | terminology checks and blind back-translation review |

If you change an English string that already has translations, re-read the translations
against the new English, fix whatever no longer matches, then run
`python3 Translations/tools/english_hashes.py --write`. The staleness guard fails until
you do — that is the point of it.

App Store listing copy lives in `fastlane/metadata/`, one directory per App Store Connect
locale. It is reviewed like any other user-facing copy, and `StoreMetadataGuardTests`
checks every shipped language has a complete set.

## Code Style

We follow the standard [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/).
*   Use `swift-format` or Xcode's built-in formatting to keep code consistent.
*   Prefer SwiftUI and SwiftData patterns used throughout the codebase.

## Submitting a Pull Request

1.  Create a new branch for your feature or bug fix: `git checkout -b my-new-feature`
2.  Commit your changes: `git commit -am 'Add some feature'`
3.  Push to the branch: `git push origin my-new-feature`
4.  Submit a Pull Request on the main repository.

## License

By contributing, you agree that your contributions will be licensed under the [GNU General Public License v3.0](LICENSE).
