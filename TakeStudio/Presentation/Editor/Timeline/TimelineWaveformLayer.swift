import UIKit

final class TimelineWaveformLayer: CALayer {
    var samples: [Float] = [] {
        didSet { setNeedsDisplay() }
    }

    var waveformColor: UIColor = .systemTeal {
        didSet { setNeedsDisplay() }
    }

    var waveformOpacity: CGFloat = 0.85 {
        didSet { setNeedsDisplay() }
    }

    override init() {
        super.init()
        contentsScale = UIScreen.main.scale
        drawsAsynchronously = true
    }

    override init(layer: Any) {
        super.init(layer: layer)
        if let source = layer as? TimelineWaveformLayer {
            samples = source.samples
            waveformColor = source.waveformColor
            waveformOpacity = source.waveformOpacity
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(in ctx: CGContext) {
        guard !samples.isEmpty else { return }

        let width = bounds.width
        let height = bounds.height
        guard width > 0, height > 0 else { return }

        let barCount = max(1, min(samples.count, Int(width)))
        let bucketSize = Float(samples.count) / Float(barCount)
        let barWidth = width / CGFloat(barCount)
        let midY = height / 2

        ctx.setFillColor(waveformColor.withAlphaComponent(waveformOpacity).cgColor)

        for index in 0..<barCount {
            let start = Int(Float(index) * bucketSize)
            let end = min(Int(Float(index + 1) * bucketSize), samples.count)
            guard start < end else { continue }
            let slice = samples[start..<end]
            let value = slice.max() ?? 0
            let barHeight = CGFloat(value) * midY
            let rect = CGRect(
                x: CGFloat(index) * barWidth,
                y: midY - barHeight,
                width: max(barWidth - 0.5, 1),
                height: barHeight * 2
            )
            ctx.fill(rect)
        }
    }
}
