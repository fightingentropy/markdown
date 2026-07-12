import Foundation

enum VaultFileChange: Sendable, Equatable {
    case changed(URL)
    case moved(from: URL, to: URL)

    var affectedURLs: [URL] {
        switch self {
        case .changed(let url):
            [url]
        case .moved(let oldURL, let newURL):
            [oldURL, newURL]
        }
    }
}

final class VaultFilePresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    private let onChange: @Sendable (VaultFileChange) -> Void
    private var isRegistered = false

    init(vaultURL: URL, onChange: @escaping @Sendable (VaultFileChange) -> Void) {
        self.presentedItemURL = vaultURL.standardizedFileURL
        self.onChange = onChange
        let queue = OperationQueue()
        queue.name = "com.md.MarkdownEditor.file-presenter"
        queue.maxConcurrentOperationCount = 1
        self.presentedItemOperationQueue = queue
        super.init()
    }

    func start() {
        guard !isRegistered else { return }
        NSFileCoordinator.addFilePresenter(self)
        isRegistered = true
    }

    func stop() {
        guard isRegistered else { return }
        NSFileCoordinator.removeFilePresenter(self)
        isRegistered = false
    }

    func presentedItemDidChange() {
        if let presentedItemURL { onChange(.changed(presentedItemURL)) }
    }

    func presentedSubitemDidChange(at url: URL) {
        onChange(.changed(url))
    }

    func presentedSubitem(at oldURL: URL, didMoveTo newURL: URL) {
        onChange(.moved(from: oldURL, to: newURL))
    }
}
