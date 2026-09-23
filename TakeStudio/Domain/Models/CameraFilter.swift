import CoreImage

enum GreenScreenMode: String, CaseIterable, Identifiable, Sendable {
    case personSegmentation
    case chromaKey

    var id: String { rawValue }

    var title: String {
        switch self {
        case .personSegmentation: return "Auto Person"
        case .chromaKey: return "Chroma"
        }
    }
}

enum CaptureSpeed: Double, CaseIterable, Identifiable, Sendable {
    case quarter = 0.25
    case half = 0.5
    case normal = 1.0
    case double = 2.0
    case quadruple = 4.0

    var id: Double { rawValue }

    var label: String {
        switch self {
        case .quarter: return "0.25×"
        case .half: return "0.5×"
        case .normal: return "1×"
        case .double: return "2×"
        case .quadruple: return "4×"
        }
    }

    /// Slow-motion modes capture at higher FPS and need lighter per-frame processing.
    var requiresHighFrameProcessing: Bool {
        self == .quarter || self == .half
    }
}

protocol CameraFilter: Identifiable, Sendable {
    var id: String { get }
    var name: String { get }
    func apply(to image: CIImage) -> CIImage
}

struct OriginalFilter: CameraFilter {
    let id = "original"
    let name = "Original"

    func apply(to image: CIImage) -> CIImage { image }
}

struct VividFilter: CameraFilter {
    let id = "vivid"
    let name = "Vivid"

    func apply(to image: CIImage) -> CIImage {
        guard let filter = CIFilter(name: "CIColorControls") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(0.4, forKey: kCIInputSaturationKey)
        filter.setValue(0.2, forKey: kCIInputContrastKey)
        return filter.outputImage ?? image
    }
}

struct FadeFilter: CameraFilter {
    let id = "fade"
    let name = "Fade"

    func apply(to image: CIImage) -> CIImage {
        guard let controls = CIFilter(name: "CIColorControls") else { return image }
        controls.setValue(image, forKey: kCIInputImageKey)
        controls.setValue(0.85, forKey: kCIInputSaturationKey)
        controls.setValue(-0.1, forKey: kCIInputContrastKey)
        let muted = controls.outputImage ?? image

        guard let matrix = CIFilter(name: "CIColorMatrix") else { return muted }
        matrix.setValue(muted, forKey: kCIInputImageKey)
        matrix.setValue(CIVector(x: 0.9, y: 0, z: 0, w: 0), forKey: "inputRVector")
        matrix.setValue(CIVector(x: 0, y: 0.9, z: 0, w: 0), forKey: "inputGVector")
        matrix.setValue(CIVector(x: 0, y: 0, z: 0.9, w: 0), forKey: "inputBVector")
        return matrix.outputImage ?? muted
    }
}

struct NoirFilter: CameraFilter {
    let id = "noir"
    let name = "Noir"

    func apply(to image: CIImage) -> CIImage {
        guard let filter = CIFilter(name: "CIPhotoEffectNoir") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        return filter.outputImage ?? image
    }
}

struct WarmFilter: CameraFilter {
    let id = "warm"
    let name = "Warm"

    func apply(to image: CIImage) -> CIImage {
        guard let filter = CIFilter(name: "CITemperatureAndTint") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
        filter.setValue(CIVector(x: 7500, y: 0), forKey: "inputTargetNeutral")
        return filter.outputImage ?? image
    }
}

struct CoolFilter: CameraFilter {
    let id = "cool"
    let name = "Cool"

    func apply(to image: CIImage) -> CIImage {
        guard let filter = CIFilter(name: "CITemperatureAndTint") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
        filter.setValue(CIVector(x: 5500, y: 0), forKey: "inputTargetNeutral")
        return filter.outputImage ?? image
    }
}

struct VignetteFilter: CameraFilter {
    let id = "vignette"
    let name = "Vignette"

    func apply(to image: CIImage) -> CIImage {
        guard let filter = CIFilter(name: "CIVignette") else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(1.5, forKey: kCIInputIntensityKey)
        filter.setValue(1.0, forKey: kCIInputRadiusKey)
        return filter.outputImage ?? image
    }
}

enum BuiltInCameraFilter: CaseIterable {
    case original
    case vivid
    case fade
    case noir
    case warm
    case cool
    case vignette

    var filter: any CameraFilter {
        switch self {
        case .original: return OriginalFilter()
        case .vivid: return VividFilter()
        case .fade: return FadeFilter()
        case .noir: return NoirFilter()
        case .warm: return WarmFilter()
        case .cool: return CoolFilter()
        case .vignette: return VignetteFilter()
        }
    }

    static var allFilters: [any CameraFilter] {
        allCases.map(\.filter)
    }
}
