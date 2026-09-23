import CoreImage

final class FilterEngine {
    var activeFilter: (any CameraFilter)?

    func process(_ image: CIImage) -> CIImage {
        guard let activeFilter else { return image }
        return activeFilter.apply(to: image)
    }
}
