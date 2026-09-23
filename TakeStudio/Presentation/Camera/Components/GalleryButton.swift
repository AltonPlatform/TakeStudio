import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct GalleryButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.ultraThinMaterial)
                .frame(width: 46, height: 46)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.white.opacity(0.35), lineWidth: 1.5)
                }
                .overlay {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Photo library")
    }
}

@MainActor
enum GalleryPickerPresenter {
    struct PickedMedia: Sendable {
        let url: URL
        let isVideo: Bool
    }

    private final class PickerDelegate: NSObject, PHPickerViewControllerDelegate {
        let onComplete: ([PickedMedia]) -> Void

        init(onComplete: @escaping ([PickedMedia]) -> Void) {
            self.onComplete = onComplete
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !results.isEmpty else {
                picker.dismiss(animated: true) {
                    Task { @MainActor in self.onComplete([]) }
                }
                return
            }

            Task {
                let media = await Self.loadAll(results: results)
                await MainActor.run {
                    picker.dismiss(animated: true) {
                        Task { @MainActor in self.onComplete(media) }
                    }
                }
            }
        }

        private static func loadAll(results: [PHPickerResult]) async -> [PickedMedia] {
            var collected: [PickedMedia] = []
            collected.reserveCapacity(min(results.count, 10))

            for result in results.prefix(10) {
                let provider = result.itemProvider
                if let videoType = preferredVideoType(for: provider),
                   let media = await loadFile(
                    provider: provider,
                    typeIdentifier: videoType.identifier,
                    destination: TemporaryCaptureStore.videoURL(),
                    isVideo: true
                   ) {
                    collected.append(media)
                    continue
                }

                if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
                   let media = await loadFile(
                    provider: provider,
                    typeIdentifier: UTType.image.identifier,
                    destination: TemporaryCaptureStore.photoURL(),
                    isVideo: false
                   ) {
                    collected.append(media)
                }
            }

            return collected
        }

        private static func loadFile(
            provider: NSItemProvider,
            typeIdentifier: String,
            destination: URL,
            isVideo: Bool
        ) async -> PickedMedia? {
            await withCheckedContinuation { continuation in
                provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
                    guard let url else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: copyImportedFile(from: url, to: destination, isVideo: isVideo))
                }
            }
        }

        private static func preferredVideoType(for provider: NSItemProvider) -> UTType? {
            let candidates: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie, .video]
            return candidates.first { provider.hasItemConformingToTypeIdentifier($0.identifier) }
        }

        private static func copyImportedFile(from source: URL, to destination: URL, isVideo: Bool) -> PickedMedia? {
            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: source, to: destination)
                return PickedMedia(url: destination, isVideo: isVideo)
            } catch {
                return nil
            }
        }
    }

    private static var activeDelegate: PickerDelegate?

    static func present(onComplete: @escaping ([PickedMedia]) -> Void) {
        guard let presenter = UIApplication.shared.topMostViewController else {
            onComplete([])
            return
        }

        let delegate = PickerDelegate { media in
            activeDelegate = nil
            onComplete(media)
        }
        activeDelegate = delegate

        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .any(of: [.images, .videos])
        configuration.selectionLimit = 10
        configuration.preferredAssetRepresentationMode = .current

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = delegate
        DispatchQueue.main.async {
            presenter.present(picker, animated: true)
        }
    }
}

private extension UIApplication {
    var topMostViewController: UIViewController? {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController?
            .topMostViewController
    }
}

private extension UIViewController {
    var topMostViewController: UIViewController {
        if let presentedViewController {
            return presentedViewController.topMostViewController
        }
        if let navigationController = self as? UINavigationController,
           let visibleViewController = navigationController.visibleViewController {
            return visibleViewController.topMostViewController
        }
        if let tabBarController = self as? UITabBarController,
           let selectedViewController = tabBarController.selectedViewController {
            return selectedViewController.topMostViewController
        }
        return self
    }
}
