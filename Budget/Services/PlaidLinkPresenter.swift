import SwiftUI
import LinkKit

/// Bridges Plaid's LinkKit into SwiftUI. Present it (e.g. in a `fullScreenCover`)
/// with a `linkToken` obtained from the server; it opens Plaid Link and calls
/// back with the public token, which the caller exchanges via `/v1/plaid/exchange`.
struct PlaidLinkPresenter: UIViewControllerRepresentable {
    let linkToken: String
    let onSuccess: (_ publicToken: String) -> Void
    let onExit: () -> Void

    func makeUIViewController(context: Context) -> LinkHostController {
        LinkHostController(linkToken: linkToken, onSuccess: onSuccess, onExit: onExit)
    }

    func updateUIViewController(_ uiViewController: LinkHostController, context: Context) {}
}

/// Owns the Link session and opens it from `viewDidAppear`.
///
/// Opening from `makeUIViewController` (even deferred a runloop turn) presents
/// from a view controller that is not in the window hierarchy yet, which UIKit
/// drops on the floor — leaving this empty host filling the fullScreenCover as
/// a black screen with no Link and no way back.
final class LinkHostController: UIViewController {
    private let linkToken: String
    private let onSuccess: (_ publicToken: String) -> Void
    private let onExit: () -> Void

    private var session: PlaidLinkSession?
    private var hasOpened = false

    init(linkToken: String,
         onSuccess: @escaping (_ publicToken: String) -> Void,
         onExit: @escaping () -> Void) {
        self.linkToken = linkToken
        self.onSuccess = onSuccess
        self.onExit = onExit
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Link presents over this host. Without an opaque background the gap
        // before it appears reads as a rendering failure.
        view.backgroundColor = .systemBackground
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasOpened else { return }   // viewDidAppear runs again after Link dismisses
        hasOpened = true

        let configuration = LinkTokenConfiguration(
            token: linkToken,
            onSuccess: { [weak self] success in self?.onSuccess(success.publicToken) },
            onExit: { [weak self] _ in self?.onExit() },
            onEvent: nil,
            onLoad: nil)
        do {
            let session = try Plaid.createPlaidLinkSession(configuration: configuration)
            self.session = session
            session.open(using: .viewController(self))
        } catch {
            // Never strand the user on an empty host: hand the failure back so
            // the cover dismisses and the error surfaces.
            onExit()
        }
    }
}
