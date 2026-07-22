import SwiftUI
import LinkKit

/// Bridges Plaid's LinkKit into SwiftUI. Present it (e.g. in a `fullScreenCover`)
/// with a `linkToken` obtained from the server; it opens Plaid Link and calls
/// back with the public token, which the caller exchanges via `/v1/plaid/exchange`.
struct PlaidLinkPresenter: UIViewControllerRepresentable {
    let linkToken: String
    let onSuccess: (_ publicToken: String) -> Void
    let onExit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController {
        let host = UIViewController()
        let configuration = LinkTokenConfiguration(
            token: linkToken,
            onSuccess: { success in onSuccess(success.publicToken) },
            onExit: { _ in onExit() },
            onEvent: nil,
            onLoad: nil)
        do {
            let session = try Plaid.createPlaidLinkSession(configuration: configuration)
            context.coordinator.session = session
            // Present after the host is in the hierarchy.
            DispatchQueue.main.async { session.open(using: LinkKit.PresentationMethod.viewController(host)) }
        } catch {
            DispatchQueue.main.async { onExit() }
        }
        return host
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    final class Coordinator { var session: PlaidLinkSession? }
}
