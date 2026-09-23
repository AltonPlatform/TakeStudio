import SwiftUI

struct FlashToggle: View {
    let flashMode: FlashMode
    let isVisible: Bool
    let action: () -> Void

    var body: some View {
        if isVisible {
            Button(action: action) {
                Image(systemName: flashMode.iconName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: CameraChrome.controlSize, height: CameraChrome.controlSize)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Flash")
        }
    }
}
