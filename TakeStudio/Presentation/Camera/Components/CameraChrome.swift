import SwiftUI

enum CameraChrome {
    static let accent = Color.yellow
    static let recordRed = Color(red: 1, green: 0.23, blue: 0.19)

    static let shutterOuter: CGFloat = 76
    static let shutterInnerPhoto: CGFloat = 64
    static let shutterInnerVideo: CGFloat = 58
    static let controlSize: CGFloat = 44
    static let bottomBarHeight: CGFloat = 132
}

struct CameraGlassButton: View {
    let systemName: String
    var label: String?
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemName)
                    .font(.system(size: 20, weight: .medium))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(isActive ? CameraChrome.accent : .white)
                    .frame(width: CameraChrome.controlSize, height: CameraChrome.controlSize)
                    .background(.ultraThinMaterial, in: Circle())

                if let label {
                    Text(label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isActive ? CameraChrome.accent : .white.opacity(0.9))
                }
            }
        }
        .buttonStyle(.plain)
    }
}

struct CameraTopBarBackground: View {
    var body: some View {
        LinearGradient(
            colors: [.black.opacity(0.55), .black.opacity(0.25), .clear],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
    }
}

struct CameraBottomBarBackground: View {
    var body: some View {
        LinearGradient(
            colors: [.clear, .black.opacity(0.35), .black.opacity(0.82)],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea(edges: .bottom)
        .allowsHitTesting(false)
    }
}
