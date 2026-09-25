import Combine
import SwiftUI
import WebKit

/// The embedded browser behind every web-session importer.
///
/// "Continue with Google" and its kin either redirect the page or open a popup
/// that hands the sign-in back through `window.opener`, so a popup has to be a
/// real WebKit child of the page that opened it. Each one is shown as a nested
/// window over that page, at the size the page asked for, and goes away when
/// the page calls `window.close()`. Loading a popup's URL into the importer
/// instead cut `window.opener`, so the sign-in never reached the page waiting
/// for it.
@MainActor
final class SignInBrowser: NSObject, ObservableObject {
    let webView: WKWebView

    /// Open popups, oldest first; the last is frontmost.
    @Published private(set) var popups: [SignInPopup] = []

    /// `dataStore` is the cookie jar the sign-in lands in, `nil` for WebKit's
    /// default. With one store for everything, a provider's second account
    /// signed in over its first: the importer showed whoever signed in last,
    /// and signing out there to switch ended the other account's session on
    /// the server.
    init(dataStore: WKWebsiteDataStore? = nil) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore ?? .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    /// Closes a popup the way its own `window.close()` would, so a page polling
    /// `popup.closed` stops waiting for a sign-in that is not coming.
    func close(_ popup: SignInPopup) {
        popup.webView.evaluateJavaScript("window.close()")
        remove(popup.webView)
    }

    /// Drops this store's cookies and site data for `domains`, then loads
    /// `startURL` so the site asks for a sign-in again. Nothing is sent to the
    /// site: its own "Log out" ends the session on the server, and with it the
    /// copy of that session an account already imported.
    func forgetSignIn(forDomains domains: [String], thenLoad startURL: URL) async {
        let store = webView.configuration.websiteDataStore
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types).filter {
            SignInSiteData.belongs($0.displayName, to: domains)
        }
        if !records.isEmpty {
            await store.removeData(ofTypes: types, for: records)
        }
        for popup in popups {
            close(popup)
        }
        webView.load(URLRequest(url: startURL))
    }

    private func remove(_ webView: WKWebView) {
        popups.removeAll { $0.webView === webView }
    }
}

extension SignInBrowser: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // Built from the configuration WebKit passes in: that is what keeps
        // `window.opener` and the importer's cookie store.
        let popupView = WKWebView(frame: .zero, configuration: configuration)
        popupView.uiDelegate = self
        popupView.navigationDelegate = self
        popupView.allowsBackForwardNavigationGestures = true
        popups.append(SignInPopup(
            webView: popupView,
            requestedSize: SignInPopupLayout.requestedSize(
                width: windowFeatures.width,
                height: windowFeatures.height
            )
        ))
        return popupView
    }

    func webViewDidClose(_ webView: WKWebView) {
        remove(webView)
    }
}

extension SignInBrowser: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        // The committed page, not `webView.url`: partway through a server
        // redirect that already names the redirect's target.
        let leaving = webView.backForwardList.currentItem?.url
        guard navigationAction.targetFrame?.isMainFrame == true,
              (navigationAction.request.httpMethod ?? "GET") == "GET",
              let url = navigationAction.request.url,
              let chooserURL = SignInAccountChooser.url(forcingChoiceIn: url, leaving: leaving) else {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        // Re-issued by the page, not with `load(_:)`: an app-initiated load
        // takes a popup out of its opener's browsing context, and the opener
        // then sees it as closed and never gets the sign-in back.
        webView.callAsyncJavaScript(
            "location.assign(url)",
            arguments: ["url": chooserURL.absoluteString],
            in: nil,
            in: .defaultClient
        ) { result in
            // A page that cannot navigate itself would leave the sign-in
            // stalled; the chooser without `window.opener` beats nothing.
            if case .failure = result {
                webView.load(URLRequest(url: chooserURL))
            }
        }
    }
}

/// A popup a sign-in page opened, and the site it is showing.
@MainActor
final class SignInPopup: ObservableObject, Identifiable {
    let webView: WKWebView
    /// The content size the page asked `window.open` for, if it asked.
    let requestedSize: CGSize?

    /// Shown in the popup's title bar, so a sign-in page reads plainly as
    /// accounts.google.com or github.com rather than as part of the importer.
    @Published private(set) var host: String?
    @Published private(set) var isSecure = true

    private var urlObservation: NSKeyValueObservation?

    init(webView: WKWebView, requestedSize: CGSize?) {
        self.webView = webView
        self.requestedSize = requestedSize
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
            MainActor.assumeIsolated {
                self?.show(webView.url)
            }
        }
    }

    private func show(_ url: URL?) {
        // A popup starts on about:blank; keep the last real site meanwhile.
        guard let url, let host = url.host, !host.isEmpty else { return }
        self.host = host
        isSecure = url.scheme == "https"
    }
}

/// Makes Google and GitHub show their account chooser on every sign-in.
///
/// Both skip the chooser when the browser holds a single signed-in account that
/// has used the app before, and the importer's WebKit store usually holds just
/// one: whichever signed in first. With no chooser there is no "Use another
/// account", so every later sign-in quietly reused it. Sites that already ask
/// for a prompt of their own are left alone.
nonisolated enum SignInAccountChooser {
    /// The authorization request with the account chooser forced, or `nil` when
    /// the request should load as it is.
    ///
    /// `currentURL` is the page the request leaves, `nil` for a new popup. A
    /// request made from the provider's own pages belongs to a flow already
    /// under way — GitHub goes back to its authorize endpoint once an account
    /// is picked — and forcing the chooser again there would loop.
    static func url(forcingChoiceIn url: URL, leaving currentURL: URL?) -> URL? {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              authorizationPaths[host]?.contains(url.path) == true,
              currentURL?.host?.lowercased() != host,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let names = Set((components.queryItems ?? []).map(\.name))
        // Google rejects `prompt` next to the legacy `approval_prompt`.
        guard !names.contains("prompt"), !names.contains("approval_prompt") else { return nil }
        // Appended rather than rebuilt: re-encoding the query can alter a state
        // or nonce the provider has to echo back byte for byte.
        let query = components.percentEncodedQuery ?? ""
        components.percentEncodedQuery = (query.isEmpty ? "" : query + "&") + "prompt=select_account"
        return components.url
    }

    private static let authorizationPaths: [String: Set<String>] = [
        "accounts.google.com": ["/o/oauth2/auth", "/o/oauth2/v2/auth"],
        "github.com": ["/login/oauth/authorize"]
    ]
}

/// Which of a data store's records belong to a site, by the registrable
/// domain WebKit names each record after ("mistral.ai" for every
/// *.mistral.ai cookie and storage area).
nonisolated enum SignInSiteData {
    static func belongs(_ recordName: String, to domains: [String]) -> Bool {
        let name = recordName.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !name.isEmpty else { return false }
        return domains.contains { domain in
            let domain = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return !domain.isEmpty && (name == domain || name.hasSuffix("." + domain))
        }
    }
}

/// Where a popup sits over the page that opened it.
nonisolated enum SignInPopupLayout {
    static let titleBarHeight: CGFloat = 28
    /// Kept clear around a popup, so the page underneath still reads as the
    /// window it came from.
    static let margin: CGFloat = 16
    /// How far each nested popup steps down and right from the one below it.
    static let cascade: CGFloat = 24

    /// The content size `window.open` asked for; `nil` when the page left it to
    /// the browser, which would open a full-size tab.
    static func requestedSize(width: NSNumber?, height: NSNumber?) -> CGSize? {
        guard let width = width?.doubleValue, let height = height?.doubleValue,
              width > 0, height > 0 else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    /// The popup's frame, title bar included, in a container of `size`.
    /// `depth` is its place in the stack, 0 for the first popup.
    static func frame(requested: CGSize?, depth: Int, in size: CGSize) -> CGRect {
        let step = CGFloat(depth) * cascade
        let available = CGSize(
            width: max(size.width - 2 * margin - step, 0),
            height: max(size.height - 2 * margin - step, 0)
        )
        let wanted = requested.map {
            CGSize(width: $0.width, height: $0.height + titleBarHeight)
        } ?? available
        let popup = CGSize(
            width: min(wanted.width, available.width),
            height: min(wanted.height, available.height)
        )
        // Centred, stepped by depth, and held inside the margins.
        let x = min((size.width - popup.width) / 2 + step, size.width - margin - popup.width)
        let y = min((size.height - popup.height) / 2 + step, size.height - margin - popup.height)
        return CGRect(x: max(x, margin), y: max(y, margin), width: popup.width, height: popup.height)
    }
}

/// The importer's page, with any popups it opened floating over it.
struct SignInBrowserView: View {
    @ObservedObject var browser: SignInBrowser

    var body: some View {
        SignInWebView(webView: browser.webView)
            .overlay {
                if !browser.popups.isEmpty {
                    GeometryReader { proxy in
                        ZStack(alignment: .topLeading) {
                            // The page is waiting on its popup, so it dims and
                            // stops taking clicks, like a window behind a sheet.
                            Color.black.opacity(0.3)
                            ForEach(Array(browser.popups.enumerated()), id: \.element.id) { depth, popup in
                                let frame = SignInPopupLayout.frame(
                                    requested: popup.requestedSize,
                                    depth: depth,
                                    in: proxy.size
                                )
                                SignInPopupWindow(popup: popup) { browser.close(popup) }
                                    .frame(width: frame.width, height: frame.height)
                                    .offset(x: frame.minX, y: frame.minY)
                            }
                        }
                    }
                }
            }
    }
}

/// One popup drawn as a small window: a title bar naming the site it is on,
/// and a close button for flows that never close themselves.
private struct SignInPopupWindow: View {
    @ObservedObject var popup: SignInPopup
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: popup.isSecure ? "lock.fill" : "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(popup.host ?? "Opening…")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .help("Close this window")
                .accessibilityLabel("Close")
            }
            .padding(.horizontal, 10)
            .frame(height: SignInPopupLayout.titleBarHeight)
            .background(.bar)

            Divider()

            SignInWebView(webView: popup.webView)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.15))
        }
        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
    }
}

#if os(iOS)
private struct SignInWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#else
private struct SignInWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#endif
