import SwiftUI

struct LockOverlay: View {
    var body: some View {
        Color.black.opacity(0.001)
            .allowsHitTesting(true)
    }
}
