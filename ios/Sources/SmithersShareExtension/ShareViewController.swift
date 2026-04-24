import SwiftUI
import UIKit

final class ShareViewController: UIViewController {
    private var hostingController: UIHostingController<SmithersShareExtensionView>?

    override func viewDidLoad() {
        super.viewDidLoad()

        let tokenStore = KeychainTokenStore(
            service: "com.smithers.oauth2.ios",
            account: "default"
        )
        let client = ShareExtensionAPIClient(
            baseURL: ShareExtensionEndpoint.resolvedBaseURL(),
            bearerProvider: {
                (try? tokenStore.load()?.accessToken)?.shareTrimmedNonEmpty
            }
        )
        let model = ShareExtensionViewModel(
            contentLoader: ShareExtensionContentLoader(context: extensionContext),
            client: client
        )
        let rootView = SmithersShareExtensionView(
            model: model,
            onCancel: { [weak self] in self?.cancelShare() },
            onComplete: { [weak self] in self?.completeShare() }
        )
        let host = UIHostingController(rootView: rootView)

        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
        hostingController = host
    }

    private func completeShare() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    private func cancelShare() {
        let error = NSError(
            domain: "com.smithers.share-extension",
            code: NSUserCancelledError,
            userInfo: [NSLocalizedDescriptionKey: "Share cancelled"]
        )
        extensionContext?.cancelRequest(withError: error)
    }
}
