import UIKit

/// Milestone 2b keyboard. Tests whether the extension can record audio in-process
/// and inject the transcription into the host text field.
///
/// Start → begins on-device SpeechAnalyzer transcription (mic permission must
/// already be granted via the host app, and Full Access must be enabled).
/// Finalized text is injected into the field incrementally; the in-progress
/// hypothesis is shown as a preview inside the keyboard.
final class KeyboardViewController: UIInputViewController {

    private let headerHeight: CGFloat = 44
    private let previewHeight: CGFloat = 52
    private let rowHeight: CGFloat = 52
    private let spacing: CGFloat = 6

    private var startButton: UIButton!
    private var previewLabel: UILabel!
    private var livePollTimer: Timer?
    private var activationStartedAt: Date?
    private var stopRequested = false
    private let activationGracePeriod: TimeInterval = 8

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.secondarySystemBackground
        buildUI()
        pinKeyboardHeight()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        resetStartButton()
        startLivePolling()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopLivePolling()
    }

    // MARK: - UI construction

    private func buildUI() {
        let header = makeHeader()
        let preview = makePreview()
        let systemRow = makeSystemRow()

        let stack = UIStackView(arrangedSubviews: [header, preview, systemRow])
        stack.axis = .vertical
        stack.spacing = spacing
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: spacing, left: spacing, bottom: spacing, right: spacing)
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            header.heightAnchor.constraint(equalToConstant: headerHeight),
            preview.heightAnchor.constraint(equalToConstant: previewHeight),
            systemRow.heightAnchor.constraint(equalToConstant: rowHeight),
        ])
    }

    private func makeHeader() -> UIView {
        let title = UILabel()
        title.text = "BOMB SQUAD"
        title.font = .systemFont(ofSize: 15, weight: .heavy)
        title.textColor = .label

        startButton = UIButton(type: .system)
        var config = UIButton.Configuration.filled()
        config.title = "Start"
        config.baseBackgroundColor = .label
        config.baseForegroundColor = .systemBackground
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)
        startButton.configuration = config
        startButton.addTarget(self, action: #selector(toggleStart), for: .touchUpInside)

        let header = UIStackView(arrangedSubviews: [title, UIView(), startButton])
        header.axis = .horizontal
        header.alignment = .center
        return header
    }

    private func makePreview() -> UIView {
        previewLabel = UILabel()
        previewLabel.text = "Start を押して話す"
        previewLabel.font = .systemFont(ofSize: 15)
        previewLabel.textColor = .secondaryLabel
        previewLabel.numberOfLines = 2
        previewLabel.adjustsFontSizeToFitWidth = true
        previewLabel.minimumScaleFactor = 0.7

        let container = UIView()
        container.backgroundColor = .tertiarySystemBackground
        container.layer.cornerRadius = 8
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(previewLabel)
        NSLayoutConstraint.activate([
            previewLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            previewLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            previewLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    private func makeSystemRow() -> UIView {
        let globe = makeKey(title: "🌐")
        globe.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)

        let space = makeKey(title: "space")
        space.addAction(UIAction { [weak self] _ in self?.textDocumentProxy.insertText(" ") }, for: .touchUpInside)

        let del = makeKey(title: "⌫")
        del.addAction(UIAction { [weak self] _ in self?.textDocumentProxy.deleteBackward() }, for: .touchUpInside)

        let ret = makeKey(title: "return")
        ret.addAction(UIAction { [weak self] _ in self?.textDocumentProxy.insertText("\n") }, for: .touchUpInside)

        let row = UIStackView(arrangedSubviews: [globe, space, del, ret])
        row.axis = .horizontal
        row.spacing = spacing
        row.distribution = .fillProportionally
        space.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    private func makeKey(title: String) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        b.setTitleColor(.label, for: .normal)
        b.backgroundColor = .tertiarySystemBackground
        b.layer.cornerRadius = 6
        b.contentEdgeInsets = UIEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        return b
    }

    private func pinKeyboardHeight() {
        let height = headerHeight + previewHeight + rowHeight + spacing * 4
        let c = view.heightAnchor.constraint(equalToConstant: height)
        c.priority = .defaultHigh
        c.isActive = true
    }

    // MARK: - Handoff

    /// In-extension audio recording is blocked by iOS, so recording happens in
    /// the host app. The app is opened only once (the activation/unlock); while a
    /// background session is alive, Start acts as Stop and no app switch occurs.
    @objc private func toggleStart() {
        if let live = SharedStore.readLive() {
            if live.phase == .recording {
                // Pause insertion while keeping the host app's audio session alive.
                stopRequested = true
                activationStartedAt = nil
                SharedStore.requestPause()
                setStartButton(recording: false)
                previewLabel.text = "一時停止中…"
            } else {
                // Resume the already-unlocked background session without app switch.
                stopRequested = false
                activationStartedAt = nil
                SharedStore.requestResume()
                setStartButton(recording: true)
                previewLabel.text = "再開中…"
            }
        } else if let activationStartedAt,
                  Date().timeIntervalSince(activationStartedAt) < activationGracePeriod {
            self.activationStartedAt = nil
            setStartButton(recording: false)
            previewLabel.text = "Start を押して話す"
        } else {
            // No session — open the app once to activate (cf. Wispr unlock).
            guard let url = URL(string: "bombsquad://record") else { return }
            stopRequested = false
            activationStartedAt = Date()
            setStartButton(recording: true)
            previewLabel.text = "BOMB SQUAD を起動中…"
            openContainerApp(url)
        }
    }

    private func setStartButton(recording: Bool) {
        startButton?.configuration?.title = recording ? "Stop" : "Start"
        startButton?.configuration?.baseBackgroundColor = recording ? .systemRed : .label
    }

    /// Keyboard extensions cannot use `UIApplication.shared`. Walk the responder
    /// chain to find an object that can open a URL (works with Full Access).
    private func openContainerApp(_ url: URL) {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(url, options: [:], completionHandler: nil)
                return
            }
            responder = current.next
        }
    }

    /// While the keyboard is visible, stream the app's live transcript into the
    /// focused field: inject newly finalized characters, preview the hypothesis.
    private func startLivePolling() {
        livePollTimer?.invalidate()
        // .common mode so the timer keeps firing while the keyboard is idle
        // (a .default-mode timer only fires on run-loop activity, which made
        // text appear only when the user returned/interacted).
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.pollLiveTranscript()
        }
        RunLoop.main.add(timer, forMode: .common)
        livePollTimer = timer
    }

    private func stopLivePolling() {
        livePollTimer?.invalidate()
        livePollTimer = nil
        // Remove the uncommitted hypothesis so it isn't orphaned in the field;
        // it will be re-injected (as finalized) on return.
        clearInjectedVolatile()
    }

    /// The in-progress hypothesis currently shown at the end of the field.
    /// Tracked locally so it can be replaced as recognition revises it.
    private var injectedVolatile = ""

    private func pollLiveTranscript() {
        guard let live = SharedStore.readLive() else {
            // Session ended: keep the shown text (commit it), don't delete.
            injectedVolatile = ""
            if let activationStartedAt,
               Date().timeIntervalSince(activationStartedAt) < activationGracePeriod {
                previewLabel?.text = "元のアプリに戻ると入力を開始します"
                setStartButton(recording: true)
            } else if stopRequested {
                previewLabel?.text = "停止しました"
                setStartButton(recording: false)
                stopRequested = false
                activationStartedAt = nil
            } else {
                previewLabel?.text = "Start を押して話す"
                setStartButton(recording: false)
                activationStartedAt = nil
            }
            return
        }
        activationStartedAt = nil

        if live.phase == .paused {
            clearInjectedVolatile()
            previewLabel?.text = "Start で再開"
            setStartButton(recording: false)
            stopRequested = false
            return
        }

        if stopRequested {
            clearInjectedVolatile()
            setStartButton(recording: false)
            previewLabel?.text = "一時停止中…"
            return
        }

        // 1. Commit any newly finalized text, replacing the volatile tail.
        if live.finalized.count > live.consumed {
            clearInjectedVolatile()
            let startIndex = live.finalized.index(live.finalized.startIndex, offsetBy: live.consumed)
            textDocumentProxy.insertText(String(live.finalized[startIndex...]))
            SharedStore.setConsumed(live.finalized.count)
        }

        // 2. Reconcile the volatile tail so text shows the instant it is spoken.
        if live.volatile != injectedVolatile {
            clearInjectedVolatile()
            textDocumentProxy.insertText(live.volatile)
            injectedVolatile = live.volatile
        }

        setStartButton(recording: true)
        previewLabel?.text = live.volatile.isEmpty ? "聞いています…（録音中）" : live.volatile
    }

    /// Delete the volatile hypothesis currently shown in the field.
    private func clearInjectedVolatile() {
        guard !injectedVolatile.isEmpty else { return }
        for _ in 0..<injectedVolatile.count { textDocumentProxy.deleteBackward() }
        injectedVolatile = ""
    }

    private func resetStartButton() {
        // Reflect whether a background session is currently alive.
        let isRecording = SharedStore.readLive()?.phase == .recording
        if isRecording {
            activationStartedAt = nil
            stopRequested = false
        }
        setStartButton(recording: isRecording)
    }
}
