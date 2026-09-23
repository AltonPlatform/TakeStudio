import SwiftUI

struct PlayheadView: View {
    var currentTime: TimeInterval = 0
    var totalDuration: TimeInterval = 0
    var rulerHeight: CGFloat = 20

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(Color.yellow)
                .frame(width: 2)
                .frame(maxHeight: .infinity)
                .padding(.top, 6)

            VStack(spacing: 2) {
                Image(systemName: "triangle.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(Color.yellow)
                    .rotationEffect(.degrees(180))

                Text("\(formatTime(currentTime))  \(formatTime(totalDuration))")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.yellow, in: Capsule())
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let totalSeconds = max(0, Int(time.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

struct TrackLabelView: View {
    let icon: String
    let title: String
    var systemImage: String?
    var contentHeight: CGFloat = 44
    var isDraggable: Bool = false
    var isDragging: Bool = false
    var onLift: (() -> Void)?
    var onDrag: ((CGFloat) -> Void)?
    var onRelease: (() -> Void)?

    @State private var liftHapticTrigger = 0

    var body: some View {
        VStack(spacing: 2) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text(icon)
                    .font(.caption2)
            }
            Text(title)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 40, height: contentHeight)
        .scaleEffect(isDragging ? 1.05 : 1)
        .overlay {
            if isDraggable {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(layerReorderGesture)
            }
        }
        .opacity(isDragging ? 0.92 : 1)
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: isDragging)
        .sensoryFeedback(.impact(weight: .medium), trigger: liftHapticTrigger)
    }

    private var layerReorderGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.45)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .onChanged { value in
                switch value {
                case .first(true):
                    liftHapticTrigger += 1
                    TimelineScrollRegistry.disableScroll(owner: "layerReorder")
                    onLift?()
                case .second(true, let drag?):
                    onDrag?(drag.translation.height)
                default:
                    break
                }
            }
            .onEnded { _ in
                TimelineScrollRegistry.enableScroll(owner: "layerReorder")
                onRelease?()
            }
    }
}

struct TrackRowView<Content: View>: View {
    let icon: String
    let title: String
    var systemImage: String?
    var contentHeight: CGFloat = 44
    var isDraggable: Bool = false
    var isDragging: Bool = false
    var onLift: (() -> Void)?
    var onDrag: ((CGFloat) -> Void)?
    var onRelease: (() -> Void)?
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 6) {
            TrackLabelView(
                icon: icon,
                title: title,
                systemImage: systemImage,
                contentHeight: contentHeight,
                isDraggable: isDraggable,
                isDragging: isDragging,
                onLift: onLift,
                onDrag: onDrag,
                onRelease: onRelease
            )

            content
                .frame(height: contentHeight)
        }
    }
}
