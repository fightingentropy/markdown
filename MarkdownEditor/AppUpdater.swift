import Combine
import Foundation
import Sparkle

@Observable
@MainActor
final class AppUpdater {
    private(set) var canCheckForUpdates = false
    private(set) var isConfigured = false

    private let updaterController: SPUStandardUpdaterController?
    private var updateCheckObserver: AnyCancellable?

    init(bundle: Bundle = .main) {
        let feedURL = Self.stringValue(for: "SUFeedURL", in: bundle)
        let publicKey = Self.stringValue(for: "SUPublicEDKey", in: bundle)
        let configured = feedURL != nil && publicKey != nil

        isConfigured = configured

        guard configured else {
            updaterController = nil
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        updaterController = controller
        updateCheckObserver = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: \.canCheckForUpdates, on: self)
    }

    func checkForUpdates() {
        updaterController?.checkForUpdates(nil)
    }

    private static func stringValue(for key: String, in bundle: Bundle) -> String? {
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
