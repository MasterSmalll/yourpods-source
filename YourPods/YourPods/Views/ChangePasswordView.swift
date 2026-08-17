import SwiftUI
import os

/// In-app password change for YourPods Sync accounts.
///
/// Sends `POST /account/change-password` with `currentPassword` + `newPassword`.
/// The server verifies the current password and revokes all refresh tokens on success.
/// After a successful change, the user is signed out locally and must re-authenticate.
struct ChangePasswordView: View {
    @Environment(PodcastManager.self) private var podcastManager
    @Environment(\.dismiss) private var dismiss
    
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var isChanging = false
    @State private var errorMessage: String?
    @State private var showSuccess = false
    
    private let logger = Logger(subsystem: "com.yourpods", category: "ChangePassword")
    
    /// Called after a successful password change so the parent can handle sign-out.
    private let onPasswordChanged: (() -> Void)?
    
    init(onPasswordChanged: (() -> Void)? = nil) {
        self.onPasswordChanged = onPasswordChanged
    }
    
    private var passwordsMatch: Bool {
        !newPassword.isEmpty && newPassword == confirmPassword
    }
    
    private var newPasswordTooShort: Bool {
        !newPassword.isEmpty && newPassword.count < 6
    }
    
    private var canSubmit: Bool {
        !currentPassword.isEmpty &&
        !newPassword.isEmpty &&
        passwordsMatch &&
        !newPasswordTooShort &&
        !isChanging
    }
    
    var body: some View {
        Form {
            Section {
                RevealableSecureField(label: "Current Password", text: $currentPassword)
                    .textContentType(.password)
                    .accessibilityLabel("Current Password")
            } header: {
                Text("Current Password")
            }
            
            Section {
                RevealableSecureField(label: "New Password", text: $newPassword)
                    .textContentType(.newPassword)
                    .accessibilityLabel("New Password")
                
                RevealableSecureField(label: "Confirm New Password", text: $confirmPassword)
                    .textContentType(.newPassword)
                    .accessibilityLabel("Confirm New Password")
            } header: {
                Text("New Password")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if newPasswordTooShort {
                        Label("Password must be at least 6 characters", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    if !confirmPassword.isEmpty && !passwordsMatch {
                        Label("Passwords do not match", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.subheadline)
                }
            }
            
            Section {
                Button {
                    Task { await changePassword() }
                } label: {
                    HStack {
                        Spacer()
                        if isChanging {
                            ProgressView()
                                .controlSize(.small)
                            Text("Updating…")
                                .fontWeight(.semibold)
                        } else {
                            Label("Update Password", systemImage: "lock.rotation")
                                .fontWeight(.semibold)
                        }
                        Spacer()
                    }
                }
                .disabled(!canSubmit)
                .accessibilityLabel("Update Password")
                .accessibilityHint(canSubmit ? "Double-tap to change your password" : "Fill in all fields to enable")
            }
        }
        .navigationTitle("Change Password")
        #if os(iOS)
        .inlineNavigationBarTitle()
        .scrollDismissesKeyboard(.interactively)
        #endif
        .alert("Password Updated", isPresented: $showSuccess) {
            Button("OK") {
                onPasswordChanged?()
                dismiss()
            }
        } message: {
            Text("Your password has been changed. Please sign in again with your new password.")
        }
    }
    
    private func changePassword() async {
        isChanging = true
        errorMessage = nil
        
        do {
            guard let proClient = podcastManager.currentSyncClient as? YourPodsProClient else {
                errorMessage = "Not connected to YourPods Sync. Please try again."
                isChanging = false
                return
            }
            
            try await proClient.changePassword(
                currentPassword: currentPassword,
                newPassword: newPassword
            )
            
            logger.info("Password change succeeded — showing confirmation")
            
            // Sign out locally — the server has already revoked all tokens
            await FirebaseAuthProvider().signOut()
            
            showSuccess = true
        } catch let error as YourPodsProError {
            switch error {
            case .forbidden:
                errorMessage = "Current password is incorrect."
            case .unauthorized:
                errorMessage = "Your session has expired. Please sign in again."
            case .httpError(400):
                errorMessage = "Password must be at least 6 characters."
            default:
                errorMessage = error.errorDescription ?? "An unexpected error occurred."
            }
            logger.error("Password change failed: \(error.localizedDescription)")
        } catch {
            errorMessage = "An unexpected error occurred: \(error.localizedDescription)"
            logger.error("Password change failed: \(error.localizedDescription)")
        }
        
        isChanging = false
    }
}
