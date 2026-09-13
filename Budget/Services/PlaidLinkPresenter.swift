import SwiftUI
import LinkKit
import os

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

        // The host is only ever visible when Link is NOT covering it — before
        // Link appears, or after Link went away without calling back (an OAuth
        // bank handing back to the app, a dropped presentation). Either way the
        // user must have a way out; a full-screen cover with no control is a
        // trap, and it happened on a real device after the viewDidAppear fix.
        var cancelConfig = UIButton.Configuration.bordered()
        cancelConfig.title = "Cancel"
        let cancel = UIButton(configuration: cancelConfig, primaryAction: UIAction { [weak self] _ in
            Self.log.notice("Link host cancelled by user (presented: \(self?.presentedViewController != nil))")
            self?.onExit()
        })
        cancel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cancel)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            cancel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            cancel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 24),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !hasOpened else {
            // Back on the host with Link gone. If Link dismissed itself
            // without onExit/onSuccess this is where the old black screen
            // lived; log it so a device console shows what happened.
            Self.log.notice("Link host reappeared (presented: \(self.presentedViewController != nil))")
            return
        }
        hasOpened = true

        let configuration = LinkTokenConfiguration(
            token: linkToken,
            onSuccess: { [weak self] success in
                Self.log.notice("Link success")
                self?.onSuccess(success.publicToken)
            },
            onExit: { [weak self] exit in
                Self.log.notice("Link exit: \(exit.error?.errorCode.description ?? "none", privacy: .public) \(exit.error?.errorMessage ?? "", privacy: .public)")
                self?.onExit()
            },
            onEvent: { event in
                Self.log.notice("Link event: \(event.eventName.description, privacy: .public) \(event.metadata.errorCode?.description ?? "", privacy: .public) \(event.metadata.institutionName ?? "", privacy: .public)")
            },
            onLoad: { Self.log.notice("Link loaded") })
        do {
            let session = try Plaid.createPlaidLinkSession(configuration: configuration)
            self.session = session
            session.open(using: .viewController(self))
            Self.log.notice("Link open requested (presented: \(self.presentedViewController != nil))")
        } catch {
            // Never strand the user on an empty host: hand the failure back so
            // the cover dismisses and the error surfaces.
            Self.log.error("Link session create failed: \(error.localizedDescription, privacy: .public)")
            onExit()
        }
    }

    private static let log = Logger(subsystem: "com.mbandhb.budget", category: "PlaidLink")
}
