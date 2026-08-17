import Foundation
import FirebaseCore
import FirebaseAppCheck

/// Chooses the App Check attestation provider per platform:
/// App Attest on iOS, DeviceCheck on macOS, Debug on the Simulator.
/// Register via `AppCheck.setAppCheckProviderFactory(_:)` BEFORE `FirebaseApp.configure()`.
final class ShareAppCheckProviderFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
        #if targetEnvironment(simulator)
        return AppCheckDebugProvider(app: app)
        #elseif os(macOS)
        return DeviceCheckProvider(app: app)
        #else
        if #available(iOS 14.0, *) { return AppAttestProvider(app: app) }
        return DeviceCheckProvider(app: app)
        #endif
    }
}
