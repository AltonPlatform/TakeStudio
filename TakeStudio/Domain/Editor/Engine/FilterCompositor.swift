import CoreImage

enum FilterCompositor {
    private static let filterEngine = FilterEngine()

    static func applyFilters(to image: CIImage, filterIDs: [String]) -> CIImage {
        var result = image
        for filterID in filterIDs {
            guard let filter = BuiltInCameraFilter.allFilters.first(where: { $0.id == filterID }) else { continue }
            filterEngine.activeFilter = filter
            result = filterEngine.process(result)
        }
        return result
    }

    static func applyGlobalAndClipFilters(to image: CIImage, globalFilterIDs: [String], clipFilterIDs: [String]) -> CIImage {
        applyFilters(to: applyFilters(to: image, filterIDs: globalFilterIDs), filterIDs: clipFilterIDs)
    }
}
