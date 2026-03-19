# Contributing to YourPods

Thank you for your interest in contributing to YourPods! We welcome contributions from the community to help make this the best self-hosted podcast player.

## Getting Started

1.  **Prerequisites**: Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
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
