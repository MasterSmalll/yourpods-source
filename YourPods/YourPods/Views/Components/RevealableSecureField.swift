import SwiftUI

/// A password field with an eye icon toggle to reveal/hide the entered text.
///
/// Drop-in replacement for `SecureField`. The toggle state is local (`@State`) so
/// it resets whenever the view disappears — passwords are never persistently revealed
/// across navigation.
///
/// Works in both `Form` and plain `VStack` contexts. The caller is responsible for
/// applying `.textFieldStyle(...)` and other modifiers, keeping this component minimal
/// and composable.
///
/// Usage:
/// ```swift
/// RevealableSecureField("Password", text: $password)
///     .textContentType(.password)
///     .textFieldStyle(.roundedBorder)
/// ```
struct RevealableSecureField: View {
    /// `LocalizedStringKey`, not `String`.
    ///
    /// As a `String` this took the non-localizing overload of `TextField` and
    /// `SecureField`, so every visible placeholder passed in here — "Current
    /// Password", "New Password", "Confirm New Password", "App Password" —
    /// was never extracted and stayed English in every language. The
    /// `.accessibilityLabel` copies at those call sites *were* in the catalog,
    /// so the fields read correctly to VoiceOver while showing English on
    /// screen, which is why nothing looked wrong.
    let label: LocalizedStringKey
    @Binding var text: String

    @State private var isRevealed = false

    var body: some View {
        HStack {
            if isRevealed {
                TextField(label, text: $text)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
            } else {
                SecureField(label, text: $text)
            }

            Button {
                isRevealed.toggle()
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .foregroundStyle(.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isRevealed ? "Hide password" : "Show password")
        }
    }
}
