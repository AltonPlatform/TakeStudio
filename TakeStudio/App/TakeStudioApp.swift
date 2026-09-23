import SwiftUI

@main
struct TakeStudioApp: App {
    @State private var cameraViewModel = CameraViewModel()

    var body: some Scene {
        WindowGroup {
            CameraView(viewModel: cameraViewModel)
                .toolbar(.hidden, for: .navigationBar)
                .statusBarHidden(true)
                .preferredColorScheme(.dark)
        }
    }
}
