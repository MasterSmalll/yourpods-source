import SwiftUI

/// Simple, static dialog shown after data migration from the Flutter app.
/// Tells the user their data is transferred and, if they have a server profile,
/// prompts them to re-enter their password.
struct MigrationWelcomeView: View {
    let hasServerProfile: Bool
    let onContinue: () -> Void
    
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.green)
            
            Text("Welcome to the New YourPods")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            
            Text("Your podcasts, queue, and settings have been transferred successfully.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            
            if hasServerProfile {
                Label {
                    Text("To continue syncing, please re-enter your password on the next screen.")
                        .font(.callout)
                } icon: {
                    Image(systemName: "key.fill")
                        .foregroundStyle(.orange)
                }
                .padding(.horizontal, 32)
            }
            
            Spacer()
            
            Button(action: onContinue) {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(.blue)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .background(Color(.systemBackground))
        .interactiveDismissDisabled()
    }
}
