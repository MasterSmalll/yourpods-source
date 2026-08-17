import SwiftUI

/// Tells the user that this app's translations were made by AI.
///
/// Shown when the app resolves to a language other than English, once per
/// language rather than once ever — see `TranslationDisclosurePolicy` for why
/// the original once-ever rule was wrong.
///
/// These five strings are themselves AI-translated, which is unavoidable and
/// makes them the highest-risk copy in the project: they are the first thing a
/// non-English user reads, and they are the app admitting its own limitations.
/// They get the most review of any strings here.
struct TranslationDisclosureSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Called when the user asks to change the app's language. iOS routes this
    /// to Settings → YourPods, where the system's own Preferred Language row
    /// lives — the app deliberately builds no language picker of its own.
    var onChangeLanguage: (() -> Void)?

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "character.bubble")
                .font(.system(size: 48))
                .foregroundStyle(.purple)
                .accessibilityHidden(true)

            Text("About these translations")
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            VStack(spacing: 14) {
                Text("YourPods is written in English. We use AI as part of the development process to translate it into other languages, so some wording might be a bit off.")

                Text("You can change the app's language any time in Settings.")

                Text("If you spot something wrong, we'd like to know.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal)

            Link(destination: AppURLs.support) {
                Label("Report a translation issue", systemImage: "exclamationmark.bubble")
                    .font(.callout.weight(.medium))
            }
            .accessibilityHint("Opens the support page in your browser")

            Spacer(minLength: 0)

            VStack(spacing: 12) {
                #if os(iOS)
                if let onChangeLanguage {
                    Button {
                        onChangeLanguage()
                    } label: {
                        Text("Change Language")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.gray.opacity(0.15))
                            .foregroundStyle(.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .accessibilityHint("Opens this app's settings, where iOS lets you pick its language")
                }
                #endif

                Button {
                    dismiss()
                } label: {
                    Text("OK")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
            .padding(.horizontal, 8)
        }
        .padding(24)
        .presentationDetents([.medium, .large])
    }
}
