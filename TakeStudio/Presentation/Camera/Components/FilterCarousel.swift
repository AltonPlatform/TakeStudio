import SwiftUI

struct FilterCarousel: View {
    let filters: [any CameraFilter]
    let selectedFilterID: String?
    let onSelect: (any CameraFilter) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(filters, id: \.id) { filter in
                    Button {
                        onSelect(filter)
                    } label: {
                        VStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(.thinMaterial)
                                .frame(width: 58, height: 58)
                                .overlay {
                                    Text(String(filter.name.prefix(1)))
                                        .font(.headline.weight(.bold))
                                        .foregroundStyle(.white)
                                }
                                .overlay {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(
                                            selectedFilterID == filter.id ? CameraChrome.accent : .white.opacity(0.2),
                                            lineWidth: selectedFilterID == filter.id ? 2 : 1
                                        )
                                }

                            Text(filter.name)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(selectedFilterID == filter.id ? CameraChrome.accent : .white.opacity(0.85))
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
        .frame(height: 88)
    }
}
