import SwiftUI

struct CaptureButton: View {
    let captureMode: CaptureMode
    let isRecording: Bool
    let progress: Double
    let isCameraReady: Bool
    let isPreparing: Bool
    let action: () -> Void

    private var isEnabled: Bool { isCameraReady }
    private let ringSize = CameraChrome.shutterOuter + 10

    var body: some View {
        Button(action: action) {
            ZStack {
                if captureMode.isVideo, isRecording {
                    Circle()
                        .stroke(.white.opacity(0.35), lineWidth: 4)
                        .frame(width: ringSize, height: ringSize)

                    RecordingProgressRing(progress: progress)
                        .stroke(CameraChrome.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .frame(width: ringSize, height: ringSize)
                }

                Circle()
                    .strokeBorder(.white, lineWidth: 4)
                    .frame(width: CameraChrome.shutterOuter, height: CameraChrome.shutterOuter)

                Group {
                    if !isCameraReady && isPreparing {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(1.1)
                    } else if isRecording {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(CameraChrome.recordRed)
                            .frame(width: 30, height: 30)
                    } else {
                        Circle()
                            .fill(CameraChrome.recordRed)
                            .frame(width: CameraChrome.shutterInnerVideo, height: CameraChrome.shutterInnerVideo)
                    }
                }
                .animation(.spring(response: 0.28, dampingFraction: 0.82), value: isRecording)
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.55)
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
    }
}

private struct RecordingProgressRing: Shape {
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let clamped = min(max(progress, 0), 1)
        guard clamped > 0 else { return Path() }

        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        path.addArc(
            center: center,
            radius: radius,
            startAngle: .degrees(-90),
            endAngle: .degrees(-90 + 360 * clamped),
            clockwise: false
        )
        return path
    }
}
