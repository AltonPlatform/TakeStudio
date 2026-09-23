import SwiftUI

struct CameraPreviewInteractionOverlay: View {
    let onFocus: (CGPoint, Bool) -> Void
    let onExposure: (Float) -> Void
    let onZoom: (CGFloat) -> Void
    let onFlipCamera: () -> Void
    @Binding var focusIndicator: FocusIndicatorState?
    @Binding var zoomFactor: CGFloat

    @State private var baseZoom: CGFloat = 1.0
    @State private var dragStartBias: Float = 0
    @State private var isDraggingExposure = false
    @State private var exposureAnchorPoint: CGPoint?

    private let exposureDragSensitivity: Float = 0.015
    private let exposureSliderRange: Float = 2.0
    private let exposureDragActivation: CGFloat = 2

    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            let target = baseZoom * value
                            zoomFactor = target
                            onZoom(target)
                        }
                        .onEnded { value in
                            baseZoom = min(max(baseZoom * value, 1.0), 10.0)
                            zoomFactor = baseZoom
                            onZoom(baseZoom)
                        }
                )
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded {
                        onFlipCamera()
                    }
                )
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let vertical = abs(value.translation.height)
                            let horizontal = abs(value.translation.width)
                            let anchor = exposureAnchorPoint ?? value.startLocation

                            if !isDraggingExposure,
                               vertical > exposureDragActivation,
                               vertical > horizontal * 1.05 {
                                isDraggingExposure = true
                                exposureAnchorPoint = value.startLocation
                                dragStartBias = focusIndicator?.exposureBias ?? 0

                                let point = value.startLocation
                                if focusIndicator == nil {
                                    focusIndicator = FocusIndicatorState(
                                        point: point,
                                        isLocked: false,
                                        exposureBias: dragStartBias,
                                        exposureDragTranslation: 0,
                                        isAdjustingExposure: true
                                    )
                                    onFocus(normalized(point, in: geometry.size), false)
                                } else if var state = focusIndicator {
                                    state.isAdjustingExposure = true
                                    state.exposureDragTranslation = 0
                                    focusIndicator = state
                                }
                            }

                            guard isDraggingExposure else { return }

                            let delta = Float(-value.translation.height) * exposureDragSensitivity
                            let bias = max(-exposureSliderRange, min(exposureSliderRange, dragStartBias + delta))
                            let clampedTranslation = max(-40, min(40, value.translation.height))

                            onExposure(bias)

                            if var state = focusIndicator {
                                state.point = anchor
                                state.exposureBias = bias
                                state.exposureDragTranslation = clampedTranslation
                                state.isAdjustingExposure = true
                                focusIndicator = state
                            }
                        }
                        .onEnded { value in
                            defer {
                                isDraggingExposure = false
                                exposureAnchorPoint = nil
                            }

                            if isDraggingExposure {
                                if var state = focusIndicator {
                                    state.isAdjustingExposure = false
                                    state.exposureDragTranslation = 0
                                    focusIndicator = state
                                }
                                return
                            }

                            let distance = hypot(value.translation.width, value.translation.height)
                            guard distance < 12 else { return }

                            let point = value.startLocation
                            focusIndicator = FocusIndicatorState(
                                point: point,
                                isLocked: false,
                                exposureBias: 0,
                                exposureDragTranslation: 0,
                                isAdjustingExposure: false
                            )
                            onFocus(normalized(point, in: geometry.size), false)
                            onExposure(0)
                        }
                )
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.5)
                        .sequenced(before: DragGesture(minimumDistance: 0))
                        .onEnded { value in
                            switch value {
                            case .second(true, let drag?):
                                let point = drag.location
                                focusIndicator = FocusIndicatorState(
                                    point: point,
                                    isLocked: true,
                                    exposureBias: focusIndicator?.exposureBias ?? 0,
                                    exposureDragTranslation: 0,
                                    isAdjustingExposure: false
                                )
                                onFocus(normalized(point, in: geometry.size), true)
                            default:
                                break
                            }
                        }
                )
                .onAppear {
                    baseZoom = zoomFactor
                }
        }
    }

    private func normalized(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: point.x / max(size.width, 1),
            y: point.y / max(size.height, 1)
        )
    }
}

struct FocusIndicatorView: View {
    let state: FocusIndicatorState?

    private let sliderHeight: CGFloat = 80

    var body: some View {
        if let state {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .stroke(CameraChrome.accent, lineWidth: 1.5)
                        .frame(width: 75, height: 75)

                    if state.isLocked {
                        Text("AE/AF LOCK")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(CameraChrome.accent)
                            .offset(y: -52)
                    }
                }

                if state.isAdjustingExposure || abs(state.exposureBias) > 0.01 {
                    exposureSlider(for: state)
                }
            }
            .position(state.point)
            .animation(.none, value: state.exposureBias)
            .animation(.none, value: state.exposureDragTranslation)
            .animation(state.isAdjustingExposure ? nil : .easeOut(duration: 0.15), value: state.point)
            .transaction { transaction in
                if state.isAdjustingExposure {
                    transaction.disablesAnimations = true
                }
            }
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func exposureSlider(for state: FocusIndicatorState) -> some View {
        let knobOffset: CGFloat = {
            if state.isAdjustingExposure {
                return state.exposureDragTranslation
            }
            return CGFloat(-state.exposureBias / 2.0) * (sliderHeight / 2)
        }()

        ZStack(alignment: .center) {
            Capsule()
                .fill(CameraChrome.accent.opacity(0.35))
                .frame(width: 2, height: sliderHeight)

            Image(systemName: "sun.max.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(CameraChrome.accent)
                .offset(y: knobOffset)
        }
        .frame(width: 28, height: sliderHeight + 20)
    }
}

struct CameraZoomRailView: View {
    let stops: [ZoomStop]
    let selectedFactor: CGFloat
    let onSelect: (CGFloat) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(stops) { stop in
                Button {
                    onSelect(stop.factor)
                } label: {
                    Text(stop.label)
                        .font(.system(size: 13, weight: isSelected(stop) ? .semibold : .medium))
                        .foregroundStyle(isSelected(stop) ? CameraChrome.accent : .white)
                        .frame(minWidth: 44, minHeight: 44)
                        .background {
                            if isSelected(stop) {
                                Circle()
                                    .fill(.black.opacity(0.65))
                                    .frame(width: 36, height: 36)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func isSelected(_ stop: ZoomStop) -> Bool {
        abs(selectedFactor - stop.factor) < 0.15
    }
}

struct CameraRecordingIndicator: View {
    let duration: TimeInterval
    let isPaused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isPaused ? Color.orange : CameraChrome.recordRed)
                .frame(width: 8, height: 8)
            Text(formattedDuration)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var formattedDuration: String {
        let total = Int(duration)
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct CameraShutterControl: View {
    let mode: CaptureMode
    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(.white, lineWidth: 5)
                    .frame(width: CameraChrome.shutterOuter, height: CameraChrome.shutterOuter)

                Group {
                    if isRecording {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.red)
                            .frame(width: 28, height: 28)
                    } else {
                        Circle()
                            .fill(.red)
                            .frame(width: CameraChrome.shutterInnerVideo, height: CameraChrome.shutterInnerVideo)
                    }
                }
                .animation(.easeInOut(duration: 0.18), value: isRecording)
            }
        }
        .buttonStyle(.plain)
    }
}

struct CameraBottomBar: View {
    let onFlip: () -> Void
    let onShutter: () -> Void
    let onStop: (() -> Void)?
    let mode: CaptureMode
    let isRecording: Bool
    let isCameraReady: Bool

    var body: some View {
        HStack {
            Button(action: onFlip) {
                Image(systemName: "arrow.triangle.2.circlepath.camera")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .contentShape(Rectangle())
            }
            .disabled(!isCameraReady)

            Spacer()

            CameraShutterControl(mode: mode, isRecording: isRecording, action: onShutter)
                .disabled(!isCameraReady)

            Spacer()

            Group {
                if let onStop {
                    Button(action: onStop) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 52, height: 52)
                            .contentShape(Rectangle())
                    }
                } else {
                    Color.clear.frame(width: 52, height: 52)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 4)
    }
}

struct CameraTopBar: View {
    let onClose: () -> Void
    let showsRecordingIndicator: Bool
    let recordingDuration: TimeInterval
    let isPaused: Bool
    let showsFlash: Bool
    let flashIcon: String
    let timerLabel: String
    let videoQuality: VideoQuality
    let isQualityPickerEnabled: Bool
    let onFlash: () -> Void
    let onTimer: () -> Void
    let onShowQualityPicker: () -> Void

    var body: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .contentShape(Rectangle())
            }

            Spacer()

            if showsRecordingIndicator {
                CameraRecordingIndicator(duration: recordingDuration, isPaused: isPaused)
            } else {
                CameraQualityButton(
                    selectedQuality: videoQuality,
                    isEnabled: isQualityPickerEnabled,
                    action: onShowQualityPicker
                )
            }

            Spacer()

            HStack(spacing: 0) {
                if showsFlash {
                    Button(action: onFlash) {
                        Image(systemName: flashIcon)
                            .font(.system(size: 20, weight: .medium))
                            .frame(width: 48, height: 48)
                            .contentShape(Rectangle())
                    }
                }
                Button(action: onTimer) {
                    Text(timerLabel)
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 48, height: 48)
                        .contentShape(Rectangle())
                }
            }
            .foregroundStyle(.white)
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }
}

struct CameraQualityButton: View {
    let selectedQuality: VideoQuality
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "video.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text(selectedQuality.shortName)
                    .font(.system(size: 15, weight: .bold))
                Text("\(selectedQuality.frameRate)")
                    .font(.system(size: 15, weight: .bold))
                    .monospacedDigit()
            }
            .foregroundStyle(isEnabled ? .white : .white.opacity(0.45))
            .padding(.horizontal, 16)
            .frame(minWidth: 120, minHeight: 44)
            .background(.black.opacity(0.45), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

struct CameraQualitySheet: View {
    let selectedQuality: VideoQuality
    let onSelect: (VideoQuality) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(VideoQuality.allCases) { quality in
                Button {
                    onSelect(quality)
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(quality.shortName)
                                .font(.headline)
                            Text("\(quality.frameRate) fps")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if quality == selectedQuality {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(CameraChrome.accent)
                        }
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Format")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.height(280)])
        .presentationDragIndicator(.visible)
    }
}
