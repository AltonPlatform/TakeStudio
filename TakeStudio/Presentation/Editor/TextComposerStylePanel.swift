import AVFoundation
import UIKit

protocol TextComposerStylePanelDelegate: AnyObject {
    func stylePanel(_ panel: TextComposerStylePanel, didSelectTab tab: TextComposerStylePanel.Tab)
    func stylePanelDidRequestAddLayer(_ panel: TextComposerStylePanel)
    func stylePanelApply(_ mutate: (inout TextOverlay) -> Void)
    func stylePanelCommitStyle()
    func stylePanelCurrentOverlay() -> TextOverlay?
    func stylePanelTotalDuration() -> TimeInterval
}

/// Bottom style tray with CapCut-style tabs. Anchored above `keyboardLayoutGuide`.
final class TextComposerStylePanel: UIView {
    enum Tab: Int, CaseIterable {
        case font, color, effects, animation, alignment, timing

        var title: String {
            switch self {
            case .font: return "Font"
            case .color: return "Color"
            case .effects: return "Effects"
            case .animation: return "Anim"
            case .alignment: return "Align"
            case .timing: return "Timing"
            }
        }
    }

    weak var delegate: TextComposerStylePanelDelegate?

    private let tabStack = UIStackView()
    private let contentHost = UIView()
    private let addButton = UIButton(type: .system)
    private var tabButtons: [UIButton] = []
    private var selectedTab: Tab = .color
    private let haptic = UISelectionFeedbackGenerator()
    private var contentViews: [Tab: UIView] = [:]

    private static let palette: [(hex: String, color: UIColor)] = [
        ("#FFFFFF", .white),
        ("#000000", .black),
        ("#FFD60A", UIColor(red: 1, green: 0.84, blue: 0.04, alpha: 1)),
        ("#FF3B30", UIColor(red: 1, green: 0.23, blue: 0.19, alpha: 1)),
        ("#FF2D55", UIColor(red: 1, green: 0.18, blue: 0.33, alpha: 1)),
        ("#AF52DE", UIColor(red: 0.69, green: 0.32, blue: 0.87, alpha: 1)),
        ("#007AFF", UIColor(red: 0, green: 0.48, blue: 1, alpha: 1)),
        ("#32ADE6", UIColor(red: 0.20, green: 0.68, blue: 0.90, alpha: 1)),
        ("#34C759", UIColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1)),
        ("#FF9F0A", UIColor(red: 1, green: 0.62, blue: 0.04, alpha: 1)),
        ("#00FFCC", UIColor(red: 0, green: 1, blue: 0.8, alpha: 1)),
        ("#FF6B6B", UIColor(red: 1, green: 0.42, blue: 0.42, alpha: 1)),
        ("#C7C7CC", UIColor(red: 0.78, green: 0.78, blue: 0.8, alpha: 1)),
        ("#5E5CE6", UIColor(red: 0.37, green: 0.36, blue: 0.9, alpha: 1)),
        ("#FF9500", UIColor(red: 1, green: 0.58, blue: 0, alpha: 1)),
        ("#64D2FF", UIColor(red: 0.39, green: 0.82, blue: 1, alpha: 1))
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configure() {
        backgroundColor = UIColor(white: 0.08, alpha: 0.96)
        layer.cornerRadius = 16
        layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        clipsToBounds = true

        addButton.setImage(UIImage(systemName: "plus"), for: .normal)
        addButton.tintColor = .systemYellow
        addButton.accessibilityLabel = "Add Text"
        addButton.addTarget(self, action: #selector(addTapped), for: .touchUpInside)
        addButton.translatesAutoresizingMaskIntoConstraints = false

        tabStack.axis = .horizontal
        tabStack.distribution = .fillEqually
        tabStack.spacing = 0
        tabStack.translatesAutoresizingMaskIntoConstraints = false

        for tab in Tab.allCases {
            let button = UIButton(type: .system)
            button.setTitle(tab.title, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
            button.tag = tab.rawValue
            button.addTarget(self, action: #selector(tabTapped(_:)), for: .touchUpInside)
            tabStack.addArrangedSubview(button)
            tabButtons.append(button)
        }

        contentHost.translatesAutoresizingMaskIntoConstraints = false
        addSubview(addButton)
        addSubview(tabStack)
        addSubview(contentHost)

        NSLayoutConstraint.activate([
            addButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            addButton.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            addButton.widthAnchor.constraint(equalToConstant: 36),
            addButton.heightAnchor.constraint(equalToConstant: 36),

            tabStack.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 4),
            tabStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            tabStack.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            tabStack.heightAnchor.constraint(equalToConstant: 36),

            contentHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentHost.topAnchor.constraint(equalTo: addButton.bottomAnchor, constant: 4),
            contentHost.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            contentHost.heightAnchor.constraint(equalToConstant: 168)
        ])

        refreshTabAppearance()
        show(tab: .color)
        haptic.prepare()
    }

    func selectTab(_ tab: Tab) {
        show(tab: tab, force: true)
        delegate?.stylePanel(self, didSelectTab: tab)
    }

    func reloadFromOverlay() {
        // Do not rebuild the tab contents unless the selected tab is missing.
        // Force-rebuild from SwiftUI updates was spinning the main thread at 100% CPU.
        if contentViews[selectedTab] == nil {
            show(tab: selectedTab, force: true)
        } else {
            refreshTabAppearance()
        }
    }

    @objc private func addTapped() {
        haptic.selectionChanged()
        delegate?.stylePanelDidRequestAddLayer(self)
    }

    @objc private func tabTapped(_ sender: UIButton) {
        guard let tab = Tab(rawValue: sender.tag) else { return }
        haptic.selectionChanged()
        show(tab: tab)
        delegate?.stylePanel(self, didSelectTab: tab)
    }

    private func refreshTabAppearance() {
        for button in tabButtons {
            let selected = button.tag == selectedTab.rawValue
            button.setTitleColor(selected ? .systemYellow : .white.withAlphaComponent(0.55), for: .normal)
        }
    }

    private func show(tab: Tab, force: Bool = false) {
        if !force, tab == selectedTab, contentViews[tab] != nil {
            refreshTabAppearance()
            return
        }
        selectedTab = tab
        refreshTabAppearance()
        contentHost.subviews.forEach { $0.removeFromSuperview() }
        let view = makeContent(for: tab)
        contentViews[tab] = view
        view.translatesAutoresizingMaskIntoConstraints = false
        contentHost.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            view.topAnchor.constraint(equalTo: contentHost.topAnchor),
            view.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor)
        ])
        UIView.transition(with: contentHost, duration: 0.15, options: .transitionCrossDissolve, animations: nil)
    }

    private func makeContent(for tab: Tab) -> UIView {
        switch tab {
        case .font: return makeFontContent()
        case .color: return makeColorContent()
        case .effects: return makeEffectsContent()
        case .animation: return makeAnimationContent()
        case .alignment: return makeAlignmentContent()
        case .timing: return makeTimingContent()
        }
    }

    private func makeFontContent() -> UIView {
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        let current = delegate?.stylePanelCurrentOverlay()
        for name in OverlayRenderer.curatedFonts {
            let button = UIButton(type: .system)
            button.configuration = {
                var config = UIButton.Configuration.plain()
                config.title = name.replacingOccurrences(of: "-Bold", with: "").replacingOccurrences(of: "PS-BoldMT", with: "")
                config.baseForegroundColor = .white
                config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
                return config
            }()
            button.titleLabel?.font = OverlayRenderer.cachedFont(name: name == "System" ? nil : name, size: 14, weight: .semibold)
            button.backgroundColor = UIColor.white.withAlphaComponent(0.12)
            button.layer.cornerRadius = 10
            let selected = (current?.style.fontName ?? "System") == name
                || (current?.style.fontName == nil && name == "System")
            button.layer.borderWidth = selected ? 2 : 0
            button.layer.borderColor = UIColor.systemYellow.cgColor
            button.addAction(UIAction { [weak self] _ in
                self?.haptic.selectionChanged()
                self?.delegate?.stylePanelApply { overlay in
                    overlay.style.fontName = name == "System" ? nil : name
                }
                self?.delegate?.stylePanelCommitStyle()
                self?.show(tab: .font, force: true)
            }, for: .touchUpInside)
            stack.addArrangedSubview(button)
        }

        let sizeSlider = makeSlider(
            min: 14, max: 72,
            value: Float(current?.style.fontSize ?? 34),
            title: "Size"
        ) { [weak self] value in
            self?.delegate?.stylePanelApply { $0.style.fontSize = CGFloat(value) }
        }
        sizeSlider.translatesAutoresizingMaskIntoConstraints = false

        let host = UIView()
        host.addSubview(scroll)
        host.addSubview(sizeSlider)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: host.topAnchor, constant: 4),
            scroll.heightAnchor.constraint(equalToConstant: 44),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerYAnchor),
            sizeSlider.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 16),
            sizeSlider.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -16),
            sizeSlider.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12)
        ])
        return host
    }

    private func makeColorContent() -> UIView {
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let currentHex = delegate?.stylePanelCurrentOverlay()?.style.colorHex ?? "#FFFFFF"
        for (index, swatch) in Self.palette.enumerated() {
            let button = UIButton(type: .custom)
            button.backgroundColor = swatch.color
            button.layer.cornerRadius = 14
            button.tag = index
            let selected = swatch.hex.compare(currentHex, options: .caseInsensitive) == .orderedSame
            button.layer.borderWidth = selected ? 3 : (swatch.hex == "#000000" ? 1 : 0)
            button.layer.borderColor = selected
                ? UIColor.systemYellow.cgColor
                : UIColor.white.withAlphaComponent(0.35).cgColor
            button.addAction(UIAction { [weak self] _ in
                self?.haptic.selectionChanged()
                self?.delegate?.stylePanelApply { $0.style.colorHex = swatch.hex }
                self?.delegate?.stylePanelCommitStyle()
                self?.show(tab: .color, force: true)
            }, for: .touchUpInside)
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 28),
                button.heightAnchor.constraint(equalToConstant: 28)
            ])
            stack.addArrangedSubview(button)
        }

        let host = UIView()
        host.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            scroll.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 44),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerYAnchor)
        ])
        return host
    }

    private func makeEffectsContent() -> UIView {
        let current = delegate?.stylePanelCurrentOverlay()
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 10
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)

        stack.addArrangedSubview(makeToggle("Background", isOn: current?.style.hasBackground ?? false) { [weak self] on in
            self?.haptic.selectionChanged()
            self?.delegate?.stylePanelApply { $0.style.hasBackground = on }
            self?.delegate?.stylePanelCommitStyle()
        })
        stack.addArrangedSubview(makeToggle("Shadow", isOn: current?.style.hasShadow ?? true) { [weak self] on in
            self?.haptic.selectionChanged()
            self?.delegate?.stylePanelApply { $0.style.hasShadow = on }
            self?.delegate?.stylePanelCommitStyle()
        })
        stack.addArrangedSubview(makeSlider(
            min: 0, max: 8,
            value: Float(current?.style.strokeWidth ?? 0),
            title: "Outline"
        ) { [weak self] value in
            self?.delegate?.stylePanelApply { $0.style.strokeWidth = CGFloat(value) }
        })
        return stack
    }

    private func makeAnimationContent() -> UIView {
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let current = delegate?.stylePanelCurrentOverlay()?.animation
        for animation in TextAnimation.allCases {
            let button = UIButton(type: .system)
            button.configuration = {
                var config = UIButton.Configuration.plain()
                config.title = animation.title
                config.baseForegroundColor = .white
                config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
                return config
            }()
            button.backgroundColor = UIColor.white.withAlphaComponent(0.12)
            button.layer.cornerRadius = 12
            button.layer.borderWidth = current == animation ? 2 : 0
            button.layer.borderColor = UIColor.systemYellow.cgColor
            button.addAction(UIAction { [weak self] _ in
                self?.haptic.selectionChanged()
                self?.delegate?.stylePanelApply { $0.animation = animation }
                self?.delegate?.stylePanelCommitStyle()
                self?.show(tab: .animation, force: true)
            }, for: .touchUpInside)
            stack.addArrangedSubview(button)
        }

        let host = UIView()
        host.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            scroll.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 56),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerYAnchor)
        ])
        return host
    }

    private func makeAlignmentContent() -> UIView {
        let current = delegate?.stylePanelCurrentOverlay()?.style.alignment ?? .center
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 12
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)

        let items: [(NSTextAlignment, String)] = [
            (.left, "text.alignleft"),
            (.center, "text.aligncenter"),
            (.right, "text.alignright")
        ]
        for (alignment, icon) in items {
            let button = UIButton(type: .system)
            button.setImage(UIImage(systemName: icon), for: .normal)
            button.tintColor = alignment == current ? .systemYellow : .white
            button.backgroundColor = UIColor.white.withAlphaComponent(0.12)
            button.layer.cornerRadius = 12
            button.addAction(UIAction { [weak self] _ in
                self?.haptic.selectionChanged()
                self?.delegate?.stylePanelApply { $0.style.alignment = alignment }
                self?.delegate?.stylePanelCommitStyle()
                self?.show(tab: .alignment, force: true)
            }, for: .touchUpInside)
            stack.addArrangedSubview(button)
        }
        return stack
    }

    private func makeTimingContent() -> UIView {
        let overlay = delegate?.stylePanelCurrentOverlay()
        let total = max(delegate?.stylePanelTotalDuration() ?? 1, 0.5)
        let start = overlay?.timeRange.start.seconds ?? 0
        let duration = overlay?.timeRange.duration.seconds ?? 3

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 14
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)

        stack.addArrangedSubview(makeSlider(min: 0, max: Float(total), value: Float(start), title: "Start") { [weak self] value in
            self?.delegate?.stylePanelApply { overlay in
                let dur = overlay.timeRange.duration.seconds
                let startTime = min(Double(value), total - 0.5)
                overlay.timeRange = CMTimeRange(
                    start: CMTime(seconds: startTime, preferredTimescale: 600),
                    duration: CMTime(seconds: min(dur, total - startTime), preferredTimescale: 600)
                )
            }
        })
        stack.addArrangedSubview(makeSlider(min: 0.5, max: Float(total), value: Float(duration), title: "Duration") { [weak self] value in
            self?.delegate?.stylePanelApply { overlay in
                let startTime = overlay.timeRange.start.seconds
                overlay.timeRange = CMTimeRange(
                    start: CMTime(seconds: startTime, preferredTimescale: 600),
                    duration: CMTime(seconds: min(Double(value), total - startTime), preferredTimescale: 600)
                )
            }
        })
        return stack
    }

    private func makeToggle(_ title: String, isOn: Bool, onChange: @escaping (Bool) -> Void) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        let label = UILabel()
        label.text = title
        label.textColor = .white
        label.font = .systemFont(ofSize: 15, weight: .medium)
        let toggle = UISwitch()
        toggle.isOn = isOn
        toggle.onTintColor = .systemYellow
        toggle.addAction(UIAction { _ in onChange(toggle.isOn) }, for: .valueChanged)
        row.addArrangedSubview(label)
        row.addArrangedSubview(toggle)
        return row
    }

    private func makeSlider(min: Float, max: Float, value: Float, title: String, onChange: @escaping (Float) -> Void) -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 4
        let label = UILabel()
        label.text = title
        label.textColor = .white.withAlphaComponent(0.7)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        let slider = UISlider()
        slider.minimumValue = min
        slider.maximumValue = max
        slider.value = value
        slider.tintColor = .systemYellow
        slider.addAction(UIAction { [weak self] _ in
            self?.haptic.selectionChanged()
            onChange(slider.value)
        }, for: .valueChanged)
        slider.addAction(UIAction { [weak self] _ in
            self?.delegate?.stylePanelCommitStyle()
        }, for: .touchUpInside)
        slider.addAction(UIAction { [weak self] _ in
            self?.delegate?.stylePanelCommitStyle()
        }, for: .touchUpOutside)
        stack.addArrangedSubview(label)
        stack.addArrangedSubview(slider)
        return stack
    }
}

/// Compact TikTok-style bar that sits on the keyboard (`inputAccessoryView`).
final class TextComposerKeyboardAccessory: UIView {
    var onDone: (() -> Void)?
    var onPickColor: ((String) -> Void)?
    var onCycleFont: (() -> Void)?

    private let colors: [(hex: String, color: UIColor)] = [
        ("#FFFFFF", .white),
        ("#000000", .black),
        ("#FFD60A", UIColor(red: 1, green: 0.84, blue: 0.04, alpha: 1)),
        ("#FF3B30", UIColor(red: 1, green: 0.23, blue: 0.19, alpha: 1)),
        ("#AF52DE", UIColor(red: 0.69, green: 0.32, blue: 0.87, alpha: 1)),
        ("#007AFF", UIColor(red: 0, green: 0.48, blue: 1, alpha: 1)),
        ("#34C759", UIColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1)),
        ("#FF9F0A", UIColor(red: 1, green: 0.62, blue: 0.04, alpha: 1))
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 52)
    }

    private func configure() {
        backgroundColor = UIColor(white: 0.11, alpha: 0.98)
        let done = UIButton(type: .system)
        done.setTitle("Done", for: .normal)
        done.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        done.tintColor = .systemYellow
        done.addAction(UIAction { [weak self] _ in self?.onDone?() }, for: .touchUpInside)
        done.translatesAutoresizingMaskIntoConstraints = false

        let fontButton = UIButton(type: .system)
        fontButton.setImage(UIImage(systemName: "textformat"), for: .normal)
        fontButton.tintColor = .white
        fontButton.addAction(UIAction { [weak self] _ in self?.onCycleFont?() }, for: .touchUpInside)
        fontButton.translatesAutoresizingMaskIntoConstraints = false

        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        for swatch in colors {
            let button = UIButton(type: .custom)
            button.backgroundColor = swatch.color
            button.layer.cornerRadius = 12
            button.layer.borderWidth = swatch.hex == "#000000" ? 1 : 0
            button.layer.borderColor = UIColor.white.withAlphaComponent(0.35).cgColor
            button.addAction(UIAction { [weak self] _ in self?.onPickColor?(swatch.hex) }, for: .touchUpInside)
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 24),
                button.heightAnchor.constraint(equalToConstant: 24)
            ])
            stack.addArrangedSubview(button)
        }

        addSubview(fontButton)
        addSubview(scroll)
        addSubview(done)
        NSLayoutConstraint.activate([
            fontButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            fontButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            fontButton.widthAnchor.constraint(equalToConstant: 36),
            fontButton.heightAnchor.constraint(equalToConstant: 36),

            done.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            done.centerYAnchor.constraint(equalTo: centerYAnchor),

            scroll.leadingAnchor.constraint(equalTo: fontButton.trailingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: done.leadingAnchor, constant: -8),
            scroll.centerYAnchor.constraint(equalTo: centerYAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 36),

            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerYAnchor)
        ])
    }
}
