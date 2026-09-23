import CoreImage
import Metal
import MetalKit
import SwiftUI

final class MetalPreviewRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private static let deviceRGB = CGColorSpaceCreateDeviceRGB()
    private let commandQueue: MTLCommandQueue
    private let ciContext: CIContext
    private let lock = NSLock()
    private var latestImage: CIImage?

    init(device: MTLDevice, ciContext: CIContext) {
        self.device = device
        self.ciContext = ciContext
        guard let queue = device.makeCommandQueue() else {
            fatalError("Unable to create Metal command queue.")
        }
        commandQueue = queue
        super.init()
    }

    func submit(_ image: CIImage) {
        lock.lock()
        latestImage = image
        lock.unlock()
    }

    func clearLatestFrame() {
        lock.lock()
        latestImage = nil
        lock.unlock()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard
            let drawable = view.currentDrawable,
            let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }

        let drawableSize = view.drawableSize
        guard drawableSize.width > 0, drawableSize.height > 0 else {
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }

        lock.lock()
        let image = latestImage
        lock.unlock()

        guard let image else {
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }

        let sourceExtent = image.extent
        guard sourceExtent.width > 0, sourceExtent.height > 0 else {
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }

        let target = CGRect(origin: .zero, size: drawableSize)
        let scale = max(
            drawableSize.width / sourceExtent.width,
            drawableSize.height / sourceExtent.height
        )
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let originX = (drawableSize.width - scaled.extent.width) / 2 - scaled.extent.origin.x
        let originY = (drawableSize.height - scaled.extent.height) / 2 - scaled.extent.origin.y
        let positioned = scaled.transformed(by: CGAffineTransform(translationX: originX, y: originY))

        ciContext.render(
            positioned,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: target,
            colorSpace: Self.deviceRGB
        )

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

struct MetalPreviewView: UIViewRepresentable {
    let renderer: MetalPreviewRenderer
    var isActive: Bool = true

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        view.delegate = renderer
        view.framebufferOnly = false
        view.enableSetNeedsDisplay = false
        view.isPaused = !isActive
        view.preferredFramesPerSecond = 30
        view.colorPixelFormat = .bgra8Unorm
        view.contentMode = .scaleAspectFill
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        uiView.delegate = renderer
        uiView.preferredFramesPerSecond = 30
        uiView.isPaused = !isActive
        // Do not clearLatestFrame here — clearing on every isActive flip caused a black flash
        // that looked like the camera freezing when the gallery opened.
    }
}
