import SwiftUI

/// Floating action bar shown above a clip after long-press (VN-style).
struct TimelineClipFloatingMenu: View {
    let clip: VideoClip
    let onSplit: () -> Void
    let onDetachAudio: () -> Void
    let onSpeed: () -> Void
    let onReverse: () -> Void
    let onDelete: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                menuButton(title: "Split", icon: "scissors", action: onSplit)
                if !clip.hasDetachedAudio {
                    menuButton(title: "Detach", icon: "speaker.wave.2", action: onDetachAudio)
                }
                menuButton(title: "Speed", icon: "speedometer", action: onSpeed)
                menuButton(title: "Reverse", icon: "arrow.uturn.backward", action: onReverse)
                menuButton(title: "Delete", icon: "trash", isDestructive: true, action: onDelete)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1))

            Capsule()
                .fill(Color.white.opacity(0.5))
                .frame(width: 2, height: 10)
        }
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
    }

    private func menuButton(
        title: String,
        icon: String,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
            onDismiss()
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                Text(title)
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundStyle(isDestructive ? Color.red : Color.white)
            .frame(minWidth: 48)
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}
