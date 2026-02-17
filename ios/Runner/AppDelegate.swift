import Flutter
import UIKit
import Intents

@main
@objc class AppDelegate: FlutterAppDelegate {
  lazy var flutterEngine = FlutterEngine(name: "my flutter engine")

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Runs the default FlutterEngine.
    flutterEngine.run();
    // Used to connect plugins (com.example.my_app).
    GeneratedPluginRegistrant.register(with: self.flutterEngine);
    return super.application(application, didFinishLaunchingWithOptions: launchOptions);
  }

  override func application(_ application: UIApplication, handlerFor intent: INIntent) -> Any? {
      return self
  }
}

extension AppDelegate: INPlayMediaIntentHandling {
    func handle(intent: INPlayMediaIntent, completion: @escaping (INPlayMediaIntentResponse) -> Void) {
        let response = INPlayMediaIntentResponse(code: .handleInApp, userActivity: nil)
        
        var searchTerm = ""
        if let mediaSearch = intent.mediaSearch {
            // Prioritize media name (title)
            if let title = mediaSearch.mediaName {
                searchTerm = title
            } else if let artist = mediaSearch.artistName { // Podcast author/artist
                searchTerm = artist
            }
        }
        
        if !searchTerm.isEmpty {
             DispatchQueue.main.async {
                 let channel = FlutterMethodChannel(name: "com.asecretcompany.yourpods/siri", binaryMessenger: self.flutterEngine.binaryMessenger)
                 channel.invokeMethod("playMedia", arguments: searchTerm)
             }
        }
        
        completion(response)
    }
    
    // Basic resolving to ensure we accept the intent
    func resolveMediaItems(for intent: INPlayMediaIntent, with completion: @escaping ([INPlayMediaMediaItemResolutionResult]) -> Void) {
        completion([])
    }
}

@available(iOS 13.0, *)
class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = (scene as? UIWindowScene) else { return }

        window = UIWindow(windowScene: windowScene)
        let appDelegate = UIApplication.shared.delegate as! AppDelegate
        let flutterViewController = FlutterViewController(engine: appDelegate.flutterEngine, nibName: nil, bundle: nil)
        
        window?.rootViewController = flutterViewController
        window?.makeKeyAndVisible()
    }
}
