import SwiftUI

struct TransitionPickerSheet: View {
    let clip: VideoClip?
    let onSelect: (ClipTransition, Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var duration: Double

    private let options: [ClipTransition] = [
        .cut, .fade, .slideLeft, .slideRight, .slideUp, .slideDown, .zoomIn, .zoomOut
    ]

    init(clip: VideoClip?, onSelect: @escaping (ClipTransition, Double) -> Void) {
        self.clip = clip
        self.onSelect = onSelect
        _duration = State(initialValue: clip?.transitionDuration ?? 0.3)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Duration")
                        .font(.subheadline.weight(.semibold))
                    HStack {
                        Slider(value: $duration, in: 0.1...1.0, step: 0.05)
                        Text("\(duration, format: .number.precision(.fractionLength(1)))s")
                            .font(.caption.monospacedDigit())
                            .frame(width: 36)
                    }
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                    ForEach(options) { option in
                        Button {
                            onSelect(option, duration)
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: icon(for: option))
                                    .font(.title3)
                                Text(option.title)
                                    .font(.caption2)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                (clip?.transition == option ? Color.yellow.opacity(0.25) : Color.white.opacity(0.08)),
                                in: RoundedRectangle(cornerRadius: 10)
                            )
                            .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer()
            }
            .padding(20)
            .background(Color.black)
            .navigationTitle("Transition")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func icon(for transition: ClipTransition) -> String {
        switch transition {
        case .cut: return "scissors"
        case .fade: return "circle.lefthalf.filled"
        case .slideLeft: return "arrow.left"
        case .slideRight: return "arrow.right"
        case .slideUp: return "arrow.up"
        case .slideDown: return "arrow.down"
        case .zoomIn: return "plus.magnifyingglass"
        case .zoomOut: return "minus.magnifyingglass"
        }
    }
}
