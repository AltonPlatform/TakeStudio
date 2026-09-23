import AVFoundation
import AVKit
import SwiftUI
import UIKit

/// Still-only preview — no `AVPlayerLayer`, safe next to a dismissing keyboard.
struct EditorHoldFrameView: UIViewRepresentable {
    var image: UIImage?

    func makeUIView(context: Context) -> HoldView {
        let view = HoldView()
        view.setImage(image)
        return view
    }

    func updateUIView(_ uiView: HoldView, context: Context) {
        uiView.setImage(image)
    }

    final class HoldView: UIView {
        private let imageView: UIImageView = {
            let imageView = UIImageView()
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.backgroundColor = .black
            return imageView
        }()

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .black
            clipsToBounds = true
            addSubview(imageView)
            setContentHuggingPriority(.defaultLow, for: .horizontal)
            setContentHuggingPriority(.defaultLow, for: .vertical)
            setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            imageView.frame = bounds
        }

        func setImage(_ image: UIImage?) {
            if imageView.image !== image {
                imageView.image = image
            }
        }
    }
}

/// Inline preview surface backed by `AVPlayerLayer` (reliable composition playback without system chrome).
struct EditorPreviewPlayer: UIViewRepresentable {
    let player: AVPlayer
    var holdFrame: UIImage?
    var videoGravity: AVLayerVideoGravity = .resizeAspect
    /// When false the layer has no `AVPlayer` — safe to remount while the keyboard tears down.
    var isAttached: Bool = true

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.playerLayer.player = isAttached ? player : nil
        view.playerLayer.videoGravity = videoGravity
        view.backgroundColor = .black
        EditorPreviewSnapshotStore.playerView = view
        return view
    }

    func updateUIView(_ uiView: PlayerView, context: Context) {
        let nextPlayer: AVPlayer? = isAttached ? player : nil
        if uiView.playerLayer.player !== nextPlayer {
            uiView.playerLayer.player = nextPlayer
        }
        uiView.playerLayer.videoGravity = videoGravity
        uiView.setHoldFrame(holdFrame)
    }

    static func dismantleUIView(_ uiView: PlayerView, coordinator: ()) {
        uiView.playerLayer.player = nil
        if EditorPreviewSnapshotStore.playerView === uiView {
            EditorPreviewSnapshotStore.playerView = nil
        }
    }

    final class PlayerView: UIView {
        private let holdImageView: UIImageView = {
            let imageView = UIImageView()
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.isHidden = true
            imageView.backgroundColor = .black
            return imageView
        }()

        override class var layerClass: AnyClass { AVPlayerLayer.self }

        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

        override init(frame: CGRect) {
            super.init(frame: frame)
            addSubview(holdImageView)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            playerLayer.frame = bounds
            holdImageView.frame = bounds
        }

        func setHoldFrame(_ image: UIImage?) {
            if holdImageView.image !== image {
                holdImageView.image = image
            }
            holdImageView.isHidden = image == nil
        }

        func snapshot() -> UIImage? {
            guard bounds.width > 2, bounds.height > 2 else { return nil }
            let format = UIGraphicsImageRendererFormat()
            format.scale = UIScreen.main.scale
            format.opaque = true
            let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)
            return renderer.image { _ in
                drawHierarchy(in: bounds, afterScreenUpdates: false)
            }
        }
    }
}

enum EditorPreviewSnapshotStore {
    static weak var playerView: EditorPreviewPlayer.PlayerView?
    static var image: UIImage?

    static func capture() {
        image = playerView?.snapshot() ?? image
    }
}

extension UIImage {
    var isVisuallyBlack: Bool {
        guard let cgImage else { return true }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return true }
        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2]) < 24
    }
}

struct EditorFullscreenDismissibleView: View {
    let player: AVPlayer
    @Bindable var viewModel: EditorViewModel
    @Binding var isPresented: Bool

    @State private var dragOffset: CGFloat = 0
    @State private var isDismissing = false

    private func dragProgress(for height: CGFloat) -> CGFloat {
        min(abs(dragOffset) / max(height * 0.38, 220), 1)
    }

    var body: some View {
        GeometryReader { geo in
            let progress = dragProgress(for: geo.size.height)
            let scale = max(0.88, 1.0 - progress * 0.12)
            let cornerRadius = progress * 18.0
            let backgroundOpacity = Double(1.0 - progress * 0.55)
            let transportHeight: CGFloat = 72
            let bottomInset = geo.safeAreaInsets.bottom

            ZStack {
                Color.black
                    .opacity(backgroundOpacity)
                    .ignoresSafeArea()

                Group {
                    if viewModel.isPreviewDetached {
                        EditorHoldFrameView(image: viewModel.previewHoldFrame)
                    } else {
                        EditorPreviewPlayer(
                            player: player,
                            holdFrame: viewModel.previewHoldFrame,
                            videoGravity: .resizeAspectFill
                        )
                    }
                }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .scaleEffect(scale)
                    .offset(y: dragOffset)
                    .contentShape(Rectangle())
                    .gesture(dismissGesture(screenHeight: geo.size.height))
                    .onTapGesture {
                        viewModel.togglePlayback()
                    }

                VStack {
                    Spacer()

                    EditorPreviewTransportBar(
                        viewModel: viewModel,
                        showsFullscreenButton: false,
                        style: .fullscreen
                    )
                    .padding(.horizontal, 12)
                    .padding(.bottom, max(bottomInset, 12))
                    .opacity(1.0 - Double(progress) * 0.6)
                }

                if progress > 0.08 {
                    VStack {
                        Spacer()
                        Text("Release to close")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.75))
                            .padding(.bottom, transportHeight + bottomInset + 24)
                    }
                    .allowsHitTesting(false)
                }
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .onAppear {
            dragOffset = 0
            isDismissing = false
        }
    }

    private func dismissGesture(screenHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                guard !isDismissing else { return }
                dragOffset = value.translation.height
            }
            .onEnded { value in
                guard !isDismissing else { return }

                let shouldDismiss =
                    abs(value.translation.height) > 90
                    || abs(value.predictedEndTranslation.height) > 180

                if shouldDismiss {
                    isDismissing = true
                    let direction: CGFloat = value.translation.height >= 0 ? 1 : -1
                    withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.9)) {
                        dragOffset = direction * screenHeight * 0.35
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                        isPresented = false
                        dragOffset = 0
                        isDismissing = false
                    }
                } else {
                    withAnimation(.interactiveSpring(response: 0.34, dampingFraction: 0.86)) {
                        dragOffset = 0
                    }
                }
            }
    }
}

struct EditorPreviewTransportBar: View {
    @Bindable var viewModel: EditorViewModel
    var showsFullscreenButton: Bool = true
    var style: TransportBarStyle = .inline
    var onFullscreen: (() -> Void)?

    enum TransportBarStyle {
        case inline
        case fullscreen
    }

    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0

    private var sliderValue: Binding<Double> {
        Binding(
            get: {
                isScrubbing ? scrubTime : viewModel.displayCurrentTime
            },
            set: { newValue in
                scrubTime = newValue
                if isScrubbing {
                    viewModel.seek(to: newValue)
                }
            }
        )
    }

    private var foregroundStyle: Color {
        style == .fullscreen ? .white : .primary
    }

    private var secondaryStyle: Color {
        style == .fullscreen ? .white.opacity(0.72) : .secondary
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: viewModel.togglePlayback) {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(viewModel.isPlaying ? "Pause" : "Play")

            VStack(spacing: 4) {
                Slider(
                    value: sliderValue,
                    in: 0...max(viewModel.displayTotalDuration, 0.01)
                ) { editing in
                    isScrubbing = editing
                    if editing {
                        scrubTime = viewModel.displayCurrentTime
                        viewModel.pausePlayback()
                    } else {
                        viewModel.seek(to: scrubTime)
                    }
                }
                .tint(.yellow)

                HStack {
                    Text(formatTime(isScrubbing ? scrubTime : viewModel.displayCurrentTime))
                    Spacer()
                    Text(formatTime(viewModel.displayTotalDuration))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(secondaryStyle)
            }

            if showsFullscreenButton, let onFullscreen {
                Button(action: onFullscreen) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.body.weight(.semibold))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Full screen")
            }
        }
        .foregroundStyle(foregroundStyle)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            if style == .inline {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let totalSeconds = max(0, Int(time.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

struct EditorLoadingOverlay: View {
    let progress: Double
    let message: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()

            VStack(spacing: 14) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.white)
                    .frame(width: 240)

                Text(message)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)

                Text("\(Int(progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}
