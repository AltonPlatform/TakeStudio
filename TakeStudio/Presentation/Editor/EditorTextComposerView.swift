import SwiftUI
import UIKit

struct EditorTextComposerResult {
    var text: String
    var colorHex: String
    var normalizedCenter: CGPoint
    var layers: [TextOverlay]
}

/// TikTok-style caption composer. The editor (player + timeline) is unmounted
/// first so the system keyboard never shares a window with `AVPlayer`.
struct EditorTextComposerHost: UIViewControllerRepresentable {
    @Bindable var viewModel: EditorViewModel
    let onCommit: (EditorTextComposerResult?) -> Void
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCommit: onCommit, onClose: onClose)
    }

    func makeUIViewController(context: Context) -> EditorTextComposerViewController {
        let vc = EditorTextComposerViewController(viewModel: viewModel)
        vc.onCommit = { result in
            context.coordinator.onCommit(result)
        }
        vc.onClose = {
            context.coordinator.onClose()
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: EditorTextComposerViewController, context: Context) {
        context.coordinator.onCommit = onCommit
        context.coordinator.onClose = onClose
        uiViewController.onCommit = { result in
            context.coordinator.onCommit(result)
        }
        uiViewController.onClose = {
            context.coordinator.onClose()
        }
        // Snapshot-only. A full reload here + @Observable ViewModel
        // produces an infinite SwiftUI/layout loop (100% CPU).
        uiViewController.updateSnapshotIfNeeded()
    }

    static func dismantleUIViewController(
        _ uiViewController: EditorTextComposerViewController,
        coordinator: Coordinator
    ) {
        uiViewController.prepareForDismantle()
    }

    final class Coordinator {
        var onCommit: (EditorTextComposerResult?) -> Void
        var onClose: () -> Void
        init(
            onCommit: @escaping (EditorTextComposerResult?) -> Void,
            onClose: @escaping () -> Void
        ) {
            self.onCommit = onCommit
            self.onClose = onClose
        }
    }
}

/// CapCut / TikTok-style multi-layer text editor over the paused preview.
final class EditorTextComposerViewController: UIViewController, UITextViewDelegate, UIGestureRecognizerDelegate {
    private weak var viewModel: EditorViewModel?
    var onCommit: ((EditorTextComposerResult?) -> Void)?
    var onClose: (() -> Void)?

    private let canvas = TextComposerCanvasView()
    private let stylePanel = TextComposerStylePanel()
    private let sharedTextView = UITextView()
    private let placeholder = UILabel()
    private let keyboardAccessory = TextComposerKeyboardAccessory()

    private var closeButton: UIButton!
    private var saveButton: UIButton!
    private var didFinish = false
    private var isWaitingForKeyboardHide = false
    private var pendingFinishCommit = false
    private var savedNormalizedCenter: CGPoint = CGPoint(x: 0.5, y: 0.5)
    private var stylePanelBottomConstraint: NSLayoutConstraint?
    private var resignActiveObserver: NSObjectProtocol?
    private var becomeActiveObserver: NSObjectProtocol?
    private var memoryWarningObserver: NSObjectProtocol?
    private var keyboardHideObserver: NSObjectProtocol?
    private let selectionHaptic = UISelectionFeedbackGenerator()
    private var lastCanvasSize: CGSize = .zero
    private var lastFittedWidth: CGFloat = -1
    private var lastFittedHeight: CGFloat = -1
    private var isMutatingLayout = false

    init(viewModel: EditorViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let resignActiveObserver { NotificationCenter.default.removeObserver(resignActiveObserver) }
        if let becomeActiveObserver { NotificationCenter.default.removeObserver(becomeActiveObserver) }
        if let memoryWarningObserver { NotificationCenter.default.removeObserver(memoryWarningObserver) }
        if let keyboardHideObserver { NotificationCenter.default.removeObserver(keyboardHideObserver) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureChrome()
        configureCanvas()
        configureSharedTextView()
        configureStylePanel()
        observeLifecycle()
        canvas.delegate = self
        stylePanel.delegate = self
        selectionHaptic.prepare()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didFinish else { return }
        reloadFromViewModel()
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.didFinish else { return }
            if self.viewModel?.composerMode == .editing {
                self.beginEditingActiveLayer(liftToSafeZone: true)
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !didFinish, !isMutatingLayout else { return }
        let size = canvas.canvasBounds.size
        let sizeChanged = abs(size.width - lastCanvasSize.width) > 0.5
            || abs(size.height - lastCanvasSize.height) > 0.5
        if sizeChanged {
            lastCanvasSize = size
            reloadLayers()
        }
        if viewModel?.composerMode == .editing {
            positionSharedTextOnCanvas()
        }
    }

    func updateSnapshotIfNeeded() {
        guard !didFinish, let viewModel else { return }
        let next = viewModel.textComposerSnapshot ?? viewModel.previewHoldFrame
        if canvas.snapshotImage !== next {
            canvas.snapshotImage = next
        }
    }

    func reloadFromViewModel() {
        guard !didFinish, !isMutatingLayout, let viewModel else { return }
        isMutatingLayout = true
        defer { isMutatingLayout = false }
        updateSnapshotIfNeeded()
        reloadLayers()
        if viewModel.composerMode == .editing, let id = viewModel.composerEditingID {
            attachSharedText(to: id)
        } else {
            detachSharedTextVisually()
        }
        stylePanel.reloadFromOverlay()
        updateGestureMode()
    }

    func prepareForDismantle() {
        sharedTextView.delegate = nil
        sharedTextView.resignFirstResponder()
        sharedTextView.isEditable = false
    }

    // MARK: - Layout

    private func configureChrome() {
        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark"), for: .normal)
        close.tintColor = .white
        close.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        close.translatesAutoresizingMaskIntoConstraints = false
        closeButton = close

        let done = UIButton(type: .system)
        done.setImage(UIImage(systemName: "checkmark"), for: .normal)
        done.tintColor = .systemYellow
        done.accessibilityLabel = "Done"
        done.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)
        done.translatesAutoresizingMaskIntoConstraints = false
        saveButton = done

        view.addSubview(close)
        view.addSubview(done)
        NSLayoutConstraint.activate([
            close.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
            close.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            close.widthAnchor.constraint(equalToConstant: 44),
            close.heightAnchor.constraint(equalToConstant: 44),
            done.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            done.centerYAnchor.constraint(equalTo: close.centerYAnchor),
            done.widthAnchor.constraint(equalToConstant: 44),
            done.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    private func configureCanvas() {
        canvas.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(canvas)
        // Full-bleed preview — keyboard must not crush the video (TikTok).
        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: view.topAnchor),
            canvas.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func configureSharedTextView() {
        placeholder.text = "Tap to type"
        placeholder.font = .systemFont(ofSize: 34, weight: .semibold)
        placeholder.textColor = UIColor.white.withAlphaComponent(0.35)
        placeholder.textAlignment = .center
        placeholder.isUserInteractionEnabled = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false

        sharedTextView.backgroundColor = .clear
        sharedTextView.textAlignment = .center
        sharedTextView.font = .systemFont(ofSize: 34, weight: .semibold)
        sharedTextView.textColor = .white
        sharedTextView.tintColor = .systemYellow
        sharedTextView.keyboardAppearance = .dark
        sharedTextView.returnKeyType = .default
        sharedTextView.autocapitalizationType = .sentences
        sharedTextView.autocorrectionType = .no
        sharedTextView.spellCheckingType = .no
        sharedTextView.smartDashesType = .no
        sharedTextView.smartQuotesType = .no
        sharedTextView.smartInsertDeleteType = .no
        sharedTextView.inlinePredictionType = .no
        sharedTextView.allowsEditingTextAttributes = false
        sharedTextView.delegate = self
        sharedTextView.translatesAutoresizingMaskIntoConstraints = true
        sharedTextView.textContainerInset = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        sharedTextView.textContainer.lineFragmentPadding = 0
        sharedTextView.isScrollEnabled = false
        sharedTextView.layer.shadowColor = UIColor.black.cgColor
        sharedTextView.layer.shadowOpacity = 0.55
        sharedTextView.layer.shadowRadius = 4
        sharedTextView.layer.shadowOffset = CGSize(width: 0, height: 1)
        sharedTextView.inputAssistantItem.leadingBarButtonGroups = []
        sharedTextView.inputAssistantItem.trailingBarButtonGroups = []
        sharedTextView.isHidden = true

        keyboardAccessory.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 52)
        keyboardAccessory.autoresizingMask = [.flexibleWidth]
        keyboardAccessory.onDone = { [weak self] in self?.keyboardDoneTapped() }
        keyboardAccessory.onPickColor = { [weak self] hex in self?.applyLiveColor(hex) }
        keyboardAccessory.onCycleFont = { [weak self] in self?.cycleLiveFont() }
        sharedTextView.inputAccessoryView = keyboardAccessory

        sharedTextView.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: sharedTextView.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: sharedTextView.centerYAnchor)
        ])

        canvas.installEditingView(sharedTextView)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleDismissSwipe(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)
    }

    private func configureStylePanel() {
        stylePanel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stylePanel)
        view.bringSubviewToFront(closeButton)
        view.bringSubviewToFront(saveButton)
        let bottom = stylePanel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        stylePanelBottomConstraint = bottom
        NSLayoutConstraint.activate([
            stylePanel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stylePanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottom,
            stylePanel.heightAnchor.constraint(equalToConstant: 220)
        ])
        stylePanel.isHidden = true
    }

    private func observeLifecycle() {
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.didFinish else { return }
                self.sharedTextView.resignFirstResponder()
                self.viewModel?.setComposerMode(.manipulating)
                self.updateGestureMode()
            }
        }
        becomeActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.didFinish else { return }
                // Do not auto-raise keyboard after returning from background.
                self.viewModel?.setComposerMode(.manipulating)
                self.detachSharedTextVisually()
                self.updateGestureMode()
                self.reloadLayers()
            }
        }
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            OverlayRenderer.clearFontCache()
        }
        keyboardHideObserver = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardDidHideNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.isWaitingForKeyboardHide {
                self.isWaitingForKeyboardHide = false
                self.completeFinish(commit: self.pendingFinishCommit)
            }
        }
    }

    // MARK: - Layer / editing

    private func reloadLayers() {
        guard let viewModel else { return }
        let gesturesEnabled = viewModel.composerMode != .editing
        canvas.syncLayers(
            viewModel.composerLayers,
            selectedID: viewModel.composerSelectedID,
            editingID: viewModel.composerEditingID,
            gesturesEnabled: gesturesEnabled
        )
    }

    private func updateGestureMode() {
        let editing = viewModel?.composerMode == .editing
        stylePanel.isHidden = editing
        reloadLayers()
    }

    private func beginEditingActiveLayer(liftToSafeZone: Bool) {
        guard let viewModel, let id = viewModel.composerEditingID ?? viewModel.composerSelectedID else {
            viewModel?.addComposerLayer()
            reloadFromViewModel()
            if let id = viewModel?.composerEditingID {
                attachSharedText(to: id)
                focusSharedText()
            }
            return
        }
        viewModel.switchComposerEditing(to: id)
        attachSharedText(to: id)
        updateGestureMode()
        focusSharedText()
    }

    private func focusSharedText() {
        view.layoutIfNeeded()
        positionSharedTextOnCanvas()
        // First responder only after the field has a real frame on the preview.
        // A hidden/zero-frame UITextView makes iOS 18 show a docked keyboard field.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.didFinish else { return }
            _ = self.sharedTextView.becomeFirstResponder()
        }
    }

    private func attachSharedText(to id: UUID) {
        guard let viewModel,
              let overlay = viewModel.project.textOverlays.first(where: { $0.id == id })
        else { return }
        savedNormalizedCenter = overlay.normalizedCenter
        sharedTextView.isHidden = false
        canvas.installEditingView(sharedTextView)
        sharedTextView.text = overlay.text
        sharedTextView.textColor = UIColor(hex: overlay.style.colorHex) ?? .white
        sharedTextView.textAlignment = overlay.style.alignment
        sharedTextView.font = OverlayRenderer.cachedFont(
            name: overlay.style.fontName,
            size: overlay.style.fontSize * overlay.scale,
            weight: overlay.style.fontWeight
        )
        placeholder.isHidden = !overlay.text.isEmpty
        placeholder.textColor = (UIColor(hex: overlay.style.colorHex) ?? .white).withAlphaComponent(0.35)
        lastFittedWidth = -1
        lastFittedHeight = -1
        positionSharedTextOnCanvas()
    }

    private func detachSharedTextVisually() {
        sharedTextView.isHidden = true
        if sharedTextView.isFirstResponder {
            sharedTextView.resignFirstResponder()
        }
    }

    private func positionSharedTextOnCanvas() {
        let maxWidth = max(canvas.canvasBounds.width - 32, 80)
        let font = sharedTextView.font ?? .systemFont(ofSize: 34, weight: .semibold)
        let text = (sharedTextView.text?.isEmpty == false ? sharedTextView.text! : "Tap to type") as NSString
        let fitted = text.boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        ).integral.size
        let size = CGSize(
            width: min(max(fitted.width + 28, 96), maxWidth),
            height: max(fitted.height + 20, 52)
        )
        canvas.positionEditingView(sharedTextView, normalizedCenter: savedNormalizedCenter, size: size)
    }

    private func applyLiveColor(_ hex: String) {
        sharedTextView.textColor = UIColor(hex: hex) ?? .white
        placeholder.textColor = (UIColor(hex: hex) ?? .white).withAlphaComponent(0.35)
        viewModel?.applyComposerStyle({ $0.style.colorHex = hex })
        viewModel?.commitComposerStyleChange()
    }

    private func cycleLiveFont() {
        let fonts = OverlayRenderer.curatedFonts
        let current = viewModel?.project.textOverlays
            .first(where: { $0.id == viewModel?.composerEditingID })?.style.fontName ?? "System"
        let index = fonts.firstIndex(of: current) ?? 0
        let next = fonts[(index + 1) % fonts.count]
        let name = next == "System" ? nil : next
        viewModel?.applyComposerStyle({ $0.style.fontName = name })
        viewModel?.commitComposerStyleChange()
        if let overlay = viewModel?.project.textOverlays.first(where: { $0.id == viewModel?.composerEditingID }) {
            sharedTextView.font = OverlayRenderer.cachedFont(
                name: overlay.style.fontName,
                size: overlay.style.fontSize * overlay.scale,
                weight: overlay.style.fontWeight
            )
            positionSharedTextOnCanvas()
        }
    }

    private func commitSharedTextToModel() {
        guard let viewModel, let id = viewModel.composerEditingID else { return }
        let text = sharedTextView.text ?? ""
        viewModel.applyComposerStyle({ overlay in
            overlay.text = text
        }, for: id)
        viewModel.applyOverlayText(id, text, colorHex: viewModel.textComposerColorHex)
    }

    private func endEditingMode() {
        commitSharedTextToModel()
        let keepSelected = viewModel?.composerEditingID ?? viewModel?.composerSelectedID
        sharedTextView.resignFirstResponder()
        viewModel?.composerSelectedID = keepSelected
        viewModel?.composerEditingID = nil
        viewModel?.composerMode = .manipulating
        detachSharedTextVisually()
        updateGestureMode()
        reloadLayers()
    }

    // MARK: - Actions

    @objc private func cancelTapped() {
        finish(commit: false)
    }

    @objc private func doneTapped() {
        if viewModel?.composerMode == .editing {
            endEditingMode()
            return
        }
        finish(commit: true)
    }

    @objc private func keyboardDoneTapped() {
        endEditingMode()
    }

    @objc private func handleDismissSwipe(_ gesture: UIPanGestureRecognizer) {
        guard viewModel?.composerMode == .editing else { return }
        let translation = gesture.translation(in: view)
        let velocity = gesture.velocity(in: view)
        if gesture.state == .ended, translation.y > 80 || velocity.y > 900 {
            endEditingMode()
        }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        guard viewModel?.composerMode == .editing else { return false }
        let velocity = pan.velocity(in: view)
        return velocity.y > abs(velocity.x)
    }

    private func finish(commit: Bool) {
        guard !didFinish else { return }
        commitSharedTextToModel()
        sharedTextView.delegate = nil
        sharedTextView.isEditable = false
        sharedTextView.isUserInteractionEnabled = false

        if sharedTextView.isFirstResponder || EditorKeyboardPresence.isVisible {
            isWaitingForKeyboardHide = true
            pendingFinishCommit = commit
            sharedTextView.resignFirstResponder()
            view.endEditing(true)
            // Fallback if keyboardDidHide never fires.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self, self.isWaitingForKeyboardHide else { return }
                self.isWaitingForKeyboardHide = false
                self.completeFinish(commit: commit)
            }
            return
        }
        completeFinish(commit: commit)
    }

    private func completeFinish(commit: Bool) {
        guard !didFinish else { return }
        didFinish = true
        var result: EditorTextComposerResult?
        if commit, let viewModel {
            let layers = viewModel.project.textOverlays
            viewModel.commitComposerSession(layers: layers)
            let active = viewModel.project.textOverlays.first(where: { $0.id == viewModel.selectedTextID })
                ?? viewModel.project.textOverlays.last
            if let active {
                result = EditorTextComposerResult(
                    text: active.text,
                    colorHex: active.style.colorHex,
                    normalizedCenter: active.normalizedCenter,
                    layers: viewModel.project.textOverlays
                )
            } else {
                result = nil
            }
        } else if !commit {
            // Cancel: drop empty draft layers created this session.
            viewModel?.cancelTextComposerIfEmpty()
            result = nil
        }
        onCommit?(result)
        onClose?()
    }

    // MARK: - UITextViewDelegate

    func textViewDidChange(_ textView: UITextView) {
        placeholder.isHidden = !textView.text.isEmpty
        positionSharedTextOnCanvas()
        // Keep copy local until Done — writing `@Observable` project on every
        // keystroke re-renders EditorView and was a main-thread hotspot.
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        guard viewModel?.composerMode == .editing,
              let touch = touches.first
        else { return }
        let point = touch.location(in: sharedTextView)
        if !sharedTextView.bounds.contains(point) {
            endEditingMode()
        }
    }
}

// MARK: - Canvas delegate

extension EditorTextComposerViewController: TextComposerCanvasDelegate {
    func canvasDidTapEmpty(_ canvas: TextComposerCanvasView) {
        if viewModel?.composerMode == .editing {
            endEditingMode()
        } else {
            viewModel?.composerSelectedID = nil
            reloadLayers()
        }
    }

    func canvas(_ canvas: TextComposerCanvasView, didSelectLayer id: UUID) {
        viewModel?.selectTextOverlay(id)
        viewModel?.composerSelectedID = id
        viewModel?.setComposerMode(.manipulating)
        stylePanel.reloadFromOverlay()
        updateGestureMode()
        selectionHaptic.selectionChanged()
    }

    func canvas(_ canvas: TextComposerCanvasView, didRequestEditLayer id: UUID) {
        viewModel?.switchComposerEditing(to: id)
        beginEditingActiveLayer(liftToSafeZone: true)
    }

    func canvas(
        _ canvas: TextComposerCanvasView,
        didUpdateTransform id: UUID,
        center: CGPoint,
        scale: CGFloat,
        rotation: CGFloat
    ) {
        viewModel?.applyComposerStyle({ overlay in
            overlay.normalizedCenter = center
            overlay.scale = scale
            overlay.rotation = rotation
        }, for: id)
    }

    func canvas(_ canvas: TextComposerCanvasView, didCommitTransform id: UUID) {
        viewModel?.commitComposerStyleChange()
    }

    func canvas(_ canvas: TextComposerCanvasView, didDuplicateLayer id: UUID) {
        viewModel?.duplicateComposerLayer(id)
        reloadFromViewModel()
    }

    func canvas(_ canvas: TextComposerCanvasView, didDeleteLayer id: UUID) {
        viewModel?.deleteComposerLayer(id)
        reloadFromViewModel()
    }

    func canvas(_ canvas: TextComposerCanvasView, didRequestAnimationFor id: UUID) {
        viewModel?.composerSelectedID = id
        viewModel?.composerMode = .stylePanel
        stylePanel.reloadFromOverlay()
        stylePanel.selectTab(.animation)
        updateGestureMode()
    }

    func canvas(_ canvas: TextComposerCanvasView, didRequestTimingFor id: UUID) {
        viewModel?.composerSelectedID = id
        viewModel?.composerMode = .stylePanel
        stylePanel.reloadFromOverlay()
        stylePanel.selectTab(.timing)
        updateGestureMode()
    }

    func canvasGesturesEnabled(_ canvas: TextComposerCanvasView) -> Bool {
        viewModel?.composerMode != .editing
    }
}

// MARK: - Style panel delegate

extension EditorTextComposerViewController: TextComposerStylePanelDelegate {
    func stylePanel(_ panel: TextComposerStylePanel, didSelectTab tab: TextComposerStylePanel.Tab) {
        viewModel?.setComposerMode(.stylePanel)
        // Keep keyboard if the user is still editing; styles apply live.
        if viewModel?.composerEditingID == nil {
            sharedTextView.resignFirstResponder()
        }
        updateGestureMode()
    }

    func stylePanelDidRequestAddLayer(_ panel: TextComposerStylePanel) {
        if viewModel?.composerMode == .editing {
            endEditingMode()
        }
        viewModel?.addComposerLayer()
        reloadFromViewModel()
        beginEditingActiveLayer(liftToSafeZone: true)
    }

    func stylePanelApply(_ mutate: (inout TextOverlay) -> Void) {
        viewModel?.applyComposerStyle(mutate)
        if let id = viewModel?.composerSelectedID ?? viewModel?.composerEditingID,
           viewModel?.composerEditingID == id {
            attachSharedText(to: id)
        }
        reloadLayers()
        selectionHaptic.selectionChanged()
    }

    func stylePanelCommitStyle() {
        viewModel?.commitComposerStyleChange()
    }

    func stylePanelCurrentOverlay() -> TextOverlay? {
        guard let viewModel else { return nil }
        let id = viewModel.composerSelectedID ?? viewModel.composerEditingID ?? viewModel.selectedTextID
        return viewModel.project.textOverlays.first(where: { $0.id == id })
    }

    func stylePanelTotalDuration() -> TimeInterval {
        viewModel?.totalDuration ?? 1
    }
}

// MARK: - Keyboard helpers (kept for reattach gating)

enum EditorKeyboardDismiss {
    /// Runs after the composer is gone so `reloadInputViews` / IME resign
    /// cannot block the checkmark or keep the still on screen.
    static func scheduleAfterComposerClosed() {
        DispatchQueue.main.async {
            dismissOrphanedKeyboard()
        }
    }

    static func dismissOrphanedKeyboard() {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .forEach { $0.endEditing(true) }
    }
}

enum EditorTextDismissGate {
    static let requiredIdleTicks = 4

    static func canDestroyComposer(
        keyboardVisible: Bool,
        inputRetired: Bool,
        stableIdleTicks: Int
    ) -> Bool {
        inputRetired && !keyboardVisible && stableIdleTicks >= requiredIdleTicks
    }
}

enum EditorKeyboardPresence {
    static var isVisible: Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .contains { containsKeyboardView($0) }
    }

    static func isKeyboardClassName(_ name: String) -> Bool {
        name.contains("UIKeyboard")
            || name.contains("UIRemoteKeyboard")
            || name.contains("KeyboardLayoutStar")
    }

    private static func containsKeyboardView(_ view: UIView) -> Bool {
        if isKeyboardClassName(NSStringFromClass(type(of: view))) {
            return true
        }
        return view.subviews.contains { containsKeyboardView($0) }
    }
}

private extension UIColor {
    convenience init?(hex: String) {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        guard cleaned.count == 6, let value = Int(cleaned, radix: 16) else { return nil }
        self.init(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}
