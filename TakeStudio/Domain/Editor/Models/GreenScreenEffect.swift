import Foundation

struct GreenScreenEffect: Equatable, Sendable {
    var mode: GreenScreenMode
    var sensitivity: Double
    var feather: Double
    var backgroundSource: BackgroundSource

    init(
        mode: GreenScreenMode = .personSegmentation,
        sensitivity: Double = 0.35,
        feather: Double = 0.5,
        backgroundSource: BackgroundSource = .color(hex: "#1A2640")
    ) {
        self.mode = mode
        self.sensitivity = sensitivity
        self.feather = feather
        self.backgroundSource = backgroundSource
    }
}

enum BackgroundSource: Equatable, Sendable {
    case color(hex: String)
    case image(URL)
    case videoURL(URL)
}
