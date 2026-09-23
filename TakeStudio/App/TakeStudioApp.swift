import SwiftUI

@main
struct TakeStudioApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var cameraViewModel = CameraViewModel()

    var body: some Scene {
        WindowGroup {
            CameraView(viewModel: cameraViewModel)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        TemporaryCaptureStore.purgeStale()
        return true
    }
}
