import SwiftUI

struct CaptureModeSelector: View {
    @Binding var selectedMode: CaptureMode
    let onModeChanged: (CaptureMode) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    ForEach(CaptureMode.allCases) { mode in
                        modeButton(for: mode)
                            .id(mode.id)
                    }
                }
                .padding(.horizontal, 20)
            }
            .frame(height: 40)
            .background(.ultraThinMaterial.opacity(0.35), in: Capsule())
            .padding(.horizontal, 8)
            .onChange(of: selectedMode) { _, mode in
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(mode.id, anchor: .center)
                }
            }
            .onAppear {
                proxy.scrollTo(selectedMode.id, anchor: .center)
            }
        }
    }

    @ViewBuilder
    private func modeButton(for mode: CaptureMode) -> some View {
        let isSelected = selectedMode == mode

        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                selectedMode = mode
                onModeChanged(mode)
            }
        } label: {
            Text(mode.shortTitle.uppercased())
                .font(.system(size: 13, weight: isSelected ? .bold : .semibold))
                .tracking(0.4)
                .foregroundStyle(isSelected ? CameraChrome.accent : .white.opacity(0.55))
                .scaleEffect(isSelected ? 1.05 : 1)
                .animation(.spring(response: 0.28, dampingFraction: 0.86), value: isSelected)
        }
        .buttonStyle(.plain)
    }
}
