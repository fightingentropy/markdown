import AppKit
@preconcurrency import WebKit

enum EmbedLoadState: Equatable {
    case idle
    case loading
    case ready
    case failed(String)
}

@MainActor
final class CachedEmbedWebView: NSView {
    let webView: WKWebView
    private(set) var loadState: EmbedLoadState = .idle
    private(set) var loadToken = ""
    private(set) var isMediaActive = false
    var openOriginal: (() -> Void)?
    var pausePlayer: (() -> Void)?

    private let loadTimeout: Duration
    private var contentKey: String?
    private var snapshotKey: String?
    private var load: ((String) -> Void)?
    private var timeoutTask: Task<Void, Never>?
    private var snapshotTask: Task<Void, Never>?
    private var presented = true
    private var scrollForwarder: EmbedScrollForwarder?
    private let snapshotView = NSImageView()
    private let statusView = NSView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "Loading…")
    private let progress = NSProgressIndicator()
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private let openButton = NSButton(title: "Open original", target: nil, action: nil)

    init(webView: WKWebView, loadTimeout: Duration = .seconds(20)) {
        self.webView = webView
        self.loadTimeout = loadTimeout
        super.init(frame: .zero)
        addSubview(webView)
        scrollForwarder = EmbedScrollForwarder(host: self)
        snapshotView.imageScaling = .scaleProportionallyUpOrDown
        snapshotView.setAccessibilityElement(false)
        snapshotView.isHidden = true
        addSubview(snapshotView)
        statusView.wantsLayer = true
        statusView.layer?.cornerRadius = 12
        addSubview(statusView)
        statusLabel.alignment = .center
        statusLabel.textColor = .secondaryLabelColor
        progress.style = .spinning
        progress.controlSize = .small
        progress.isIndeterminate = true
        retryButton.target = self
        retryButton.action = #selector(retry)
        openButton.target = self
        openButton.action = #selector(openSource)
        let buttons = NSStackView(views: [retryButton, openButton])
        buttons.spacing = 12
        let stack = NSStackView(views: [progress, statusLabel, buttons])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        statusView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: statusView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: statusView.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: statusView.widthAnchor, constant: -32)
        ])
        updateStatus()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        webView.frame = bounds
        snapshotView.frame = bounds
        statusView.frame = bounds
        refreshSnapshotKey()
        updateMediaActivity()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateMediaActivity()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refreshSnapshotKey()
    }

    func configure(contentKey: String, load: @escaping (String) -> Void) {
        self.load = load
        guard self.contentKey != contentKey else { return }
        self.contentKey = contentKey
        snapshotKey = nil
        retry()
    }

    @objc func retry() {
        guard let load else { return }
        timeoutTask?.cancel()
        snapshotTask?.cancel()
        webView.stopLoading()
        loadToken = UUID().uuidString
        loadState = .loading
        snapshotView.image = nil
        snapshotView.isHidden = true
        updateStatus()
        refreshSnapshotKey(force: true)
        let token = loadToken
        let timeout = loadTimeout
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, self.loadToken == token else { return }
            self.fail("This embed took too long to load. Check your connection and try again.")
        }
        load(token)
    }

    @objc private func openSource() { openOriginal?() }

    func markReady() {
        guard loadState == .loading else { return }
        timeoutTask?.cancel()
        loadState = .ready
        snapshotView.isHidden = true
        updateStatus()
        // Readiness can arrive after this card has already scrolled away.
        updateMediaActivity(force: true)
        scheduleSnapshot()
    }

    func fail(_ message: String) {
        guard loadState != .idle else { return }
        timeoutTask?.cancel()
        snapshotTask?.cancel()
        loadState = .failed(message)
        snapshotView.isHidden = true
        webView.stopLoading()
        pausePlayer?()
        webView.pauseAllMediaPlayback(completionHandler: nil)
        updateStatus()
    }

    func setPresented(_ presented: Bool) {
        self.presented = presented
        updateMediaActivity()
    }

    private func updateMediaActivity(force: Bool = false) {
        let active = presented && window != nil && !isHiddenOrHasHiddenAncestor
        guard force || active != isMediaActive else { return }
        isMediaActive = active
        if active {
            // WebKit may resume suspended media when suspension is lifted.
            // Pause after lifting it, so returning to a note never autoplays.
            webView.setAllMediaPlaybackSuspended(false) { [weak self] in
                guard let self, self.isMediaActive else { return }
                self.pausePlayer?()
                self.webView.pauseAllMediaPlayback(completionHandler: nil)
            }
        } else {
            pausePlayer?()
            webView.pauseAllMediaPlayback { [weak self] in
                guard let self, !self.isMediaActive else { return }
                self.webView.setAllMediaPlaybackSuspended(true, completionHandler: nil)
            }
        }
    }

    func tearDown() {
        setPresented(false)
        timeoutTask?.cancel()
        snapshotTask?.cancel()
        loadToken = ""
        loadState = .idle
        load = nil
        scrollForwarder = nil
        openOriginal = nil
        pausePlayer = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    private func updateStatus() {
        statusView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        statusView.isHidden = loadState == .ready || loadState == .idle
        webView.isHidden = loadState != .ready
        if case .failed(let message) = loadState {
            statusLabel.stringValue = message
            retryButton.isHidden = false
            progress.stopAnimation(nil)
            progress.isHidden = true
        } else {
            statusLabel.stringValue = "Loading embed…"
            retryButton.isHidden = true
            progress.isHidden = false
            progress.startAnimation(nil)
        }
    }

    private func refreshSnapshotKey(force: Bool = false) {
        guard let contentKey, bounds.width > 1 else { return }
        let key = EmbedSnapshotKey.make(content: contentKey, width: bounds.width, scale: window?.backingScaleFactor ?? 2)
        guard force || key != snapshotKey else { return }
        snapshotKey = key
        snapshotTask?.cancel()
        if loadState == .ready {
            scheduleSnapshot()
        } else if loadState == .loading {
            let token = loadToken
            snapshotTask = Task { [weak self] in
                let image = await EditorEmbedCache.shared.snapshot(for: key)
                guard let self, !Task.isCancelled, self.loadToken == token,
                      self.snapshotKey == key, self.loadState == .loading else { return }
                self.snapshotView.image = image
                self.snapshotView.isHidden = image == nil
                // Loading controls remain reachable even with a cached card.
                self.statusView.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(image == nil ? 1 : 0.92).cgColor
            }
        }
    }

    private func scheduleSnapshot() {
        snapshotTask?.cancel()
        guard let key = snapshotKey, bounds.width > 1, bounds.height > 1 else { return }
        let token = loadToken
        snapshotTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard let self, self.loadToken == token, self.loadState == .ready else { return }
            // Avoid allocating an enormous bitmap for very tall posts.
            guard self.bounds.height <= 8_192 else { return }
            self.webView.takeSnapshot(with: nil) { [weak self] image, _ in
                guard let self, self.loadToken == token, self.snapshotKey == key,
                      self.loadState == .ready, let image else { return }
                Task { await EditorEmbedCache.shared.saveSnapshot(image, for: key) }
            }
        }
    }
}

@MainActor
enum EmbedViewLifecycle {
    static func setPresented(_ presented: Bool, in view: NSView) {
        if let embed = view as? CachedEmbedWebView { embed.setPresented(presented) }
        else { view.subviews.forEach { setPresented(presented, in: $0) } }
    }
}

private final class EmbedScrollMonitorToken: @unchecked Sendable {
    let value: Any
    init(_ value: Any) { self.value = value }
}

/// WKWebView consumes wheel events even when its document has no overflow.
/// Route vertical scrolling to the containing note, leaving player clicks alone.
@MainActor
final class EmbedScrollForwarder {
    private var token: EmbedScrollMonitorToken?

    init(host: NSView) {
        if let value = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { [weak host] event in
            guard let host, host.window != nil, event.window === host.window,
                  !host.isHiddenOrHasHiddenAncestor, abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX),
                  host.visibleRect.contains(host.convert(event.locationInWindow, from: nil)),
                  let scrollView = host.enclosingScrollView else { return event }
            scrollView.scrollWheel(with: event)
            return nil
        }) { token = EmbedScrollMonitorToken(value) }
    }

    deinit { if let token { NSEvent.removeMonitor(token.value) } }
}
