import Foundation

/// Validates email format before sending to the auth provider.
///
/// Uses a simple structural check (not a full RFC 5322 regex) that
/// matches what Firebase Auth considers valid: `local@domain.tld`.
enum EmailValidator {
    /// Returns `true` if the email has a valid basic structure.
    ///
    /// Checks: no whitespace, exactly one `@`, non-empty local part,
    /// domain contains at least one `.` with content on both sides.
    static func isValid(_ email: String) -> Bool {
        guard !email.isEmpty,
              !email.contains(" "),
              !email.contains("\t"),
              !email.contains("\n") else {
            return false
        }

        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2,
              !parts[0].isEmpty,
              !parts[1].isEmpty else {
            return false
        }

        let domain = parts[1]
        guard let dotIndex = domain.lastIndex(of: ".") else {
            return false
        }

        let beforeDot = domain[domain.startIndex..<dotIndex]
        let afterDot = domain[domain.index(after: dotIndex)...]

        return !beforeDot.isEmpty && !afterDot.isEmpty
    }
}

