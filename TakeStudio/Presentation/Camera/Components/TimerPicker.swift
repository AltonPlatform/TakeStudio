import SwiftUI

struct TimerPickerLabel: View {
    let delay: TimerDelay
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(delay.label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(delay == .none ? .white : CameraChrome.accent)
                .frame(width: CameraChrome.controlSize, height: CameraChrome.controlSize)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Timer")
    }
}
