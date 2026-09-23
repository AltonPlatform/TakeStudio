import SwiftUI

struct ExposureSlider: View {
    @Binding var bias: Float
    let range: ClosedRange<Float>
    let onChange: (Float) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Exposure", systemImage: "sun.max")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
            Slider(
                value: Binding(
                    get: { Double(bias) },
                    set: { newValue in
                        bias = Float(newValue)
                        onChange(bias)
                    }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound)
            )
            .tint(CameraChrome.accent)
        }
    }
}
