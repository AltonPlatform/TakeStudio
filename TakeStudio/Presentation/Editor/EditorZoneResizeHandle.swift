import SwiftUI
import UIKit

@MainActor
final class ZoneResizeSession: ObservableObject {
    /// Sparse events only — these drive SwiftUI `.sensoryFeedback` (few times per gesture).
    @Published var readyHapticTrigger = 0
    @Published var limitHapticTrigger = 0
    @Published var releaseHapticTrigger = 0
    /// Kept for callers that still observe resize activity; not used to swap the timeline away.
    @Published var isResizeActive = false

    var dragStartFraction: CGFloat?
    var lastHapticBucket: Int?
    var wasAtLimit = false
    /// Throttle UIKit selection ticks under the system ~32 Hz feedback rate limit.
    private var lastTickAt: CFTimeInterval = 0
    private let minTickInterval: CFTimeInterval = 1.0 / 20.0
    private let tickGenerator = UISelectionFeedbackGenerator()

    func begin(at fraction: CGFloat) {
        isResizeActive = true
        dragStartFraction = fraction
        lastHapticBucket = nil
        wasAtLimit = false
        lastTickAt = 0
        tickGenerator.prepare()
        TimelineScrollRegistry.disableScroll(owner: "zoneResize")
        readyHapticTrigger += 1
    }

    func end() {
        isResizeActive = false
        dragStartFraction = nil
        lastHapticBucket = nil
        wasAtLimit = false
        TimelineScrollRegistry.enableScroll(owner: "zoneResize")
    }

    /// Drag ticks go through UIKit directly — no `@Published` update, no SwiftUI re-render storm.
    func pulseDragTick() {
        let now = CACurrentMediaTime()
        guard now - lastTickAt >= minTickInterval else { return }
        lastTickAt = now
        tickGenerator.selectionChanged()
    }

    func pulseLimit() {
        limitHapticTrigger += 1
    }

    func pulseRelease() {
        releaseHapticTrigger += 1
    }
}

/// Drag handle between preview and timeline. Hold briefly, then drag up or down to resize zones.
struct EditorZoneResizeHandle: View {
    @Binding var timelineFraction: CGFloat
    @ObservedObject var session: ZoneResizeSession
    let workspaceHeight: CGFloat
    let minFraction: CGFloat
    let maxFraction: CGFloat

    @GestureState private var fingerDown = false
    @State private var isResizeMode = false
    @State private var pressStartedAt: Date?
    @State private var dragBaselineY: CGFloat = 0

    private let activeColor = Color.yellow
    private let inactiveColor = Color.secondary.opacity(0.45)
    private let holdDuration: TimeInterval = 0.28
    /// Coarser buckets → fewer ticks while dragging across the fraction range.
    private let hapticStep: CGFloat = 0.04

    var body: some View {
        ZStack {
            Capsule()
                .fill(isResizeMode ? activeColor : inactiveColor)
                .frame(width: isResizeMode ? 52 : 36, height: 5)
                .animation(.easeOut(duration: 0.12), value: isResizeMode)

            if isResizeMode {
                Text("Resize")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .offset(y: -14)
            }
        }
        .frame(height: 28)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityLabel("Resize preview and timeline")
        .accessibilityHint("Hold, then drag up or down")
        .highPriorityGesture(resizeGesture)
        .sensoryFeedback(.impact(weight: .heavy), trigger: session.readyHapticTrigger)
        .sensoryFeedback(.impact(weight: .medium), trigger: session.limitHapticTrigger)
        .sensoryFeedback(.impact(flexibility: .soft), trigger: session.releaseHapticTrigger)
        .onChange(of: fingerDown) { _, isDown in
            if !isDown {
                finishResizeGesture()
            }
        }
        .onDisappear {
            finishResizeGesture()
        }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .updating($fingerDown) { _, state, _ in
                state = true
            }
            .onChanged { value in
                if pressStartedAt == nil {
                    pressStartedAt = Date()
                }

                guard let startedAt = pressStartedAt else { return }
                guard Date().timeIntervalSince(startedAt) >= holdDuration else { return }

                if !isResizeMode {
                    isResizeMode = true
                    dragBaselineY = value.translation.height
                    session.begin(at: timelineFraction)
                    session.lastHapticBucket = hapticBucket(for: timelineFraction)
                    session.wasAtLimit = isAtLimit(timelineFraction)
                }

                applyDrag(translationY: value.translation.height - dragBaselineY)
            }
            .onEnded { _ in
                finishResizeGesture()
            }
    }

    private func applyDrag(translationY: CGFloat) {
        let start = session.dragStartFraction ?? timelineFraction
        guard workspaceHeight > 0 else { return }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            let delta = -translationY / workspaceHeight
            timelineFraction = min(max(start + delta, minFraction), maxFraction)
        }

        emitResizeHaptics(for: timelineFraction)
    }

    private func finishResizeGesture() {
        if isResizeMode {
            session.pulseRelease()
        }
        isResizeMode = false
        pressStartedAt = nil
        dragBaselineY = 0
        session.end()
    }

    private func hapticBucket(for fraction: CGFloat) -> Int {
        Int((fraction / hapticStep).rounded())
    }

    private func isAtLimit(_ fraction: CGFloat) -> Bool {
        fraction <= minFraction + 0.002 || fraction >= maxFraction - 0.002
    }

    private func emitResizeHaptics(for fraction: CGFloat) {
        let bucket = hapticBucket(for: fraction)
        if session.lastHapticBucket != bucket {
            session.lastHapticBucket = bucket
            session.pulseDragTick()
        }

        let atLimit = isAtLimit(fraction)
        if atLimit, !session.wasAtLimit {
            session.pulseLimit()
        }
        session.wasAtLimit = atLimit
    }
}
