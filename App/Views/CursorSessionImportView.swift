import SwiftUI
import WebKit

struct CursorSessionImportView: View {
    let onImport: (Result<CredentialImportService.ImportedCredential, Error>) -> Void

    /// Set when this view is hosted as a page inside the setup sheet. There,
    /// `dismiss` would tear down the whole sheet instead of returning to the
    /// provider's form, so the host supplies its own way back.
    var onClose: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }
    @State private var model = CursorSessionImportModel()
    @State private var isImporting = false
    @State private var importError: String?
    @State private var showImportError = false

    private let startURL = URL(string: "https://cursor.com/login")!

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            CursorSessionWebView(webView: model.webView)
                .frame(minWidth: 720, minHeight: 560)

            Divider()

            footer
        }
        .frame(minWidth: 760, minHeight: 720)
        .onAppear {
            model.load(startURL: startURL)
        }
        .alert("Could Not Import Session", isPresented: $showImportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "No Cursor session cookies were found in the embedded browser.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "cursorarrow.rays")
                    .foregroundStyle(Color(hex: ProviderID.cursor.accentColorHex))
                    .font(.title2)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Cursor web session")
                        .font(.headline.weight(.semibold))

                    Text("Sign in inside the embedded browser, then import the active cursor.com session cookie into Keychain.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)

            Text("We only capture cookies from this embedded Cursor session. The session is kept in this app's WebKit store so you can refresh it later without signing in again.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
        }
        .padding(.bottom, 14)
    }

    private var footer: some View {
        HStack {
            Text("After signing in, click Import Session to store a normalized cookie header in Keychain.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Cancel") {
                close()
            }
            .buttonStyle(.bordered)

            Button {
                Task {
                    await importCurrentSession()
                }
            } label: {
                if isImporting {
                    ProgressView()
                        .progressViewStyle(.circular)
                } else {
                    Text("Import Session")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(hex: ProviderID.cursor.accentColorHex))
            .disabled(isImporting)
        }
        .padding(20)
    }

    private func importCurrentSession() async {
        isImporting = true
        defer { isImporting = false }

        do {
            let cookieHeader = try await model.captureCookieHeader()
            let imported = CredentialImportService.ImportedCredential(
                accessToken: nil,
                accountIdentifier: nil,
                customEndpoint: nil,
                extraFields: [
                    "cursorAuthMode": "cookie",
                    "cursorCookieHeader": cookieHeader
                ],
                bookmarkData: nil
            )
            onImport(.success(imported))
            close()
        } catch {
            importError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            showImportError = true
        }
    }
}

@MainActor
final class CursorSessionImportModel: NSObject, WKUIDelegate {
    let webView: WKWebView

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    func load(startURL: URL) {
        guard webView.url == nil else { return }
        webView.load(URLRequest(url: startURL))
    }

    func captureCookieHeader() async throws -> String {
        let cookies = try await webView.allCookies()
        let relevantCookies = cookies.filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return domain == "cursor.com"
                || domain.hasSuffix(".cursor.com")
                || domain == "cursor.sh"
                || domain.hasSuffix(".cursor.sh")
        }

        guard !relevantCookies.isEmpty else {
            throw CursorSessionImportError.noCookiesFound
        }

        let header = relevantCookies
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")

        guard !header.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CursorSessionImportError.noCookiesFound
        }

        return header
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    static func clearStoredWebsiteData() {
        let store = WKWebsiteDataStore.default()
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: dataTypes) { records in
            let cursorRecords = records.filter { record in
                let name = record.displayName.lowercased()
                return name == "cursor.com"
                    || name.hasSuffix(".cursor.com")
                    || name == "cursor.sh"
                    || name.hasSuffix(".cursor.sh")
                    || name.contains("cursor")
            }
            guard !cursorRecords.isEmpty else { return }
            store.removeData(ofTypes: dataTypes, for: cursorRecords) {}
        }
    }
}

private enum CursorSessionImportError: LocalizedError {
    case noCookiesFound

    var errorDescription: String? {
        switch self {
        case .noCookiesFound:
            return "No Cursor session cookies were found. Make sure you signed in to cursor.com in the embedded browser first."
        }
    }
}

private extension WKWebView {
    func allCookies() async throws -> [HTTPCookie] {
        try await withCheckedThrowingContinuation { continuation in
            configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    @MainActor
    func renderedBodyText() async -> String? {
        await withCheckedContinuation { continuation in
            evaluateJavaScript("document.body ? document.body.innerText : ''") { value, error in
                guard error == nil else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: value as? String)
            }
        }
    }
}

#if os(iOS)
private struct CursorSessionWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#else
private struct CursorSessionWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#endif

// MARK: - Kimi Session Import View

struct KimiWebSessionImportView: View {
    let onImport: (Result<CredentialImportService.ImportedCredential, Error>) -> Void

    /// Set when this view is hosted as a page inside the setup sheet. There,
    /// `dismiss` would tear down the whole sheet instead of returning to the
    /// provider's form, so the host supplies its own way back.
    var onClose: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }
    @State private var model = KimiWebSessionImportModel()
    @State private var isImporting = false
    @State private var importError: String?
    @State private var showImportError = false

    private let startURL = URL(string: "https://www.kimi.ai/membership/subscription?tab=quota")!

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ProviderBrandIconView(providerID: .kimi, size: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Kimi web session")
                            .font(.headline.weight(.semibold))
                        Text("Sign in inside the embedded browser, then import the active kimi.ai session into Keychain.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                Text("Limit Counter stores only the web session tokens needed to read your shared monthly membership-credit percentage and reset date.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

            CursorSessionWebView(webView: model.webView)
                .frame(minWidth: 720, minHeight: 560)

            Divider()

            HStack {
                Text("After the My Quota page appears, import the session.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { close() }
                    .buttonStyle(.bordered)
                Button {
                    Task { await importCurrentSession() }
                } label: {
                    if isImporting {
                        ProgressView()
                            .progressViewStyle(.circular)
                    } else {
                        Text("Import Session")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(hex: ProviderID.kimi.accentColorHex))
                .disabled(isImporting)
            }
            .padding(20)
        }
        .frame(minWidth: 760, minHeight: 720)
        .onAppear { model.load(startURL: startURL) }
        .alert("Could Not Import Session", isPresented: $showImportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "No signed-in Kimi web session was found.")
        }
    }

    private func importCurrentSession() async {
        isImporting = true
        defer { isImporting = false }

        do {
            let tokens = try await model.captureSessionTokens()
            var fields = ["kimiWebAccessToken": tokens.accessToken]
            if let refreshToken = tokens.refreshToken {
                fields["kimiWebRefreshToken"] = refreshToken
            }
            onImport(
                .success(
                    CredentialImportService.ImportedCredential(
                        accessToken: nil,
                        accountIdentifier: nil,
                        customEndpoint: nil,
                        extraFields: fields,
                        bookmarkData: nil
                    )
                )
            )
            close()
        } catch {
            importError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            showImportError = true
        }
    }
}

@MainActor
final class KimiWebSessionImportModel: NSObject, WKUIDelegate {
    let webView: WKWebView
    private var popupWebView: WKWebView?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    func load(startURL: URL) {
        guard webView.url == nil else { return }
        webView.load(URLRequest(url: startURL))
    }

    func captureSessionTokens() async throws -> KimiWebSessionTokens {
        let script = """
        JSON.stringify({
          accessToken: window.localStorage.getItem('access_token'),
          refreshToken: window.localStorage.getItem('refresh_token')
        })
        """
        guard let result = try await webView.evaluateJavaScript(script) as? String,
              let data = result.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = (payload["accessToken"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty else {
            throw KimiWebSessionImportError.noSessionFound
        }
        let refreshToken = (payload["refreshToken"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return KimiWebSessionTokens(
            accessToken: accessToken,
            refreshToken: refreshToken?.isEmpty == false ? refreshToken : nil
        )
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }

        if let popupWebView {
            popupWebView.load(navigationAction.request)
            return nil
        }

        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.uiDelegate = self
        popup.allowsBackForwardNavigationGestures = true
        popup.translatesAutoresizingMaskIntoConstraints = false
        webView.addSubview(popup)
        NSLayoutConstraint.activate([
            popup.leadingAnchor.constraint(equalTo: webView.leadingAnchor),
            popup.trailingAnchor.constraint(equalTo: webView.trailingAnchor),
            popup.topAnchor.constraint(equalTo: webView.topAnchor),
            popup.bottomAnchor.constraint(equalTo: webView.bottomAnchor)
        ])
        popupWebView = popup
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard webView === popupWebView else { return }
        webView.removeFromSuperview()
        popupWebView = nil
    }
}

private enum KimiWebSessionImportError: LocalizedError {
    case noSessionFound

    var errorDescription: String? {
        "No Kimi web session was found. Sign in and wait for the My Quota page to finish loading before importing."
    }
}

// MARK: - Ollama Session Import View

struct OllamaSessionImportView: View {
    let onImport: (Result<CredentialImportService.ImportedCredential, Error>) -> Void

    /// Set when this view is hosted as a page inside the setup sheet. There,
    /// `dismiss` would tear down the whole sheet instead of returning to the
    /// provider's form, so the host supplies its own way back.
    var onClose: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }
    @State private var model = OllamaSessionImportModel()
    @State private var isImporting = false
    @State private var importError: String?
    @State private var showImportError = false

    private let startURL = URL(string: "https://ollama.com/settings")!

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            CursorSessionWebView(webView: model.webView)
                .frame(minWidth: 720, minHeight: 560)

            Divider()

            footer
        }
        .frame(minWidth: 760, minHeight: 720)
        .onAppear {
            model.load(startURL: startURL)
        }
        .alert("Could Not Import Session", isPresented: $showImportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "No Ollama session cookies were found in the embedded browser.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "circle.grid.2x2.fill")
                    .foregroundStyle(Color(hex: ProviderID.ollama.accentColorHex))
                    .font(.title2)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Ollama web session")
                        .font(.headline.weight(.semibold))

                    Text("Sign in inside the embedded browser, then import the active ollama.com session into Keychain.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)

            Text("We only capture cookies from this embedded Ollama session. The session is saved to macOS Keychain to read your 5-hour, Weekly, or monthly included-usage budget.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
        }
        .padding(.bottom, 14)
    }

    private var footer: some View {
        HStack {
            Text("After signing in, click Import Session to securely save the session cookie in Keychain.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Cancel") {
                close()
            }
            .buttonStyle(.bordered)

            Button {
                Task {
                    await importCurrentSession()
                }
            } label: {
                if isImporting {
                    ProgressView()
                        .progressViewStyle(.circular)
                } else {
                    Text("Import Session")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(hex: ProviderID.ollama.accentColorHex))
            .disabled(isImporting)
        }
        .padding(20)
    }

    private func importCurrentSession() async {
        isImporting = true
        defer { isImporting = false }

        do {
            let sessionToken = try await model.captureSessionCookie()
            let imported = CredentialImportService.ImportedCredential(
                accessToken: sessionToken,
                accountIdentifier: nil,
                customEndpoint: nil,
                extraFields: [
                    "ollamaCookie": sessionToken
                ],
                bookmarkData: nil
            )
            onImport(.success(imported))
            close()
        } catch {
            importError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            showImportError = true
        }
    }
}

@MainActor
final class OllamaSessionImportModel: NSObject, WKUIDelegate {
    let webView: WKWebView

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    func load(startURL: URL) {
        guard webView.url == nil else { return }
        webView.load(URLRequest(url: startURL))
    }

    func captureSessionCookie() async throws -> String {
        let cookies = try await webView.allCookies()
        let relevantCookies = cookies.filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return domain == "ollama.com" || domain.hasSuffix(".ollama.com") || domain == "ollama.ai" || domain.hasSuffix(".ollama.ai")
        }

        if let secureSession = relevantCookies.first(where: { $0.name == "__Secure-session" }) {
            return secureSession.value
        }

        if let anySession = relevantCookies.first(where: { $0.name.lowercased().contains("session") }) {
            return anySession.value
        }

        guard !relevantCookies.isEmpty else {
            throw OllamaSessionImportError.noCookiesFound
        }

        let header = relevantCookies
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")

        return header
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }
}

private enum OllamaSessionImportError: LocalizedError {
    case noCookiesFound

    var errorDescription: String? {
        switch self {
        case .noCookiesFound:
            return "No Ollama session cookies were found. Make sure you signed in to ollama.com in the embedded browser first."
        }
    }
}

// MARK: - Mistral Session Import View

struct MistralSessionImportView: View {
    let onImport: (Result<CredentialImportService.ImportedCredential, Error>) -> Void

    /// Set when this view is hosted as a page inside the setup sheet. There,
    /// `dismiss` would tear down the whole sheet instead of returning to the
    /// provider's form, so the host supplies its own way back.
    var onClose: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }
    @State private var model = MistralSessionImportModel()
    @State private var isImporting = false
    @State private var importError: String?
    @State private var showImportError = false

    private let startURL = URL(string: "https://admin.mistral.ai/subscription")!

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            CursorSessionWebView(webView: model.webView)
                .frame(minWidth: 720, minHeight: 560)

            Divider()

            footer
        }
        .frame(minWidth: 760, minHeight: 720)
        .onAppear {
            model.load(startURL: startURL)
        }
        .alert("Could Not Import Session", isPresented: $showImportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "No Mistral session cookies were found in the embedded browser.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "m.square.fill")
                    .foregroundStyle(Color(hex: ProviderID.mistral.accentColorHex))
                    .font(.title2)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Mistral web session")
                        .font(.headline.weight(.semibold))

                    Text("Sign in inside the embedded browser, then import the active admin.mistral.ai session into Keychain.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)

            Text("We only capture cookies from this embedded Mistral session to read your live API usage and Vibe Code usage quotas from admin.mistral.ai/subscription.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
        }
        .padding(.bottom, 14)
    }

    private var footer: some View {
        HStack {
            Text("After signing in, click Import Session to securely save the session cookie in Keychain.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Cancel") {
                close()
            }
            .buttonStyle(.bordered)

            Button {
                Task {
                    await importCurrentSession()
                }
            } label: {
                if isImporting {
                    ProgressView()
                        .progressViewStyle(.circular)
                } else {
                    Text("Import Session")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(hex: ProviderID.mistral.accentColorHex))
            .disabled(isImporting)
        }
        .padding(20)
    }

    private func importCurrentSession() async {
        isImporting = true
        defer { isImporting = false }

        do {
            let cookieHeader = try await model.captureCookieHeader()
            let imported = CredentialImportService.ImportedCredential(
                accessToken: nil,
                accountIdentifier: nil,
                customEndpoint: nil,
                extraFields: [
                    "mistralCookieHeader": cookieHeader
                ],
                bookmarkData: nil
            )
            onImport(.success(imported))
            close()
        } catch {
            importError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            showImportError = true
        }
    }
}

@MainActor
final class MistralSessionImportModel: NSObject, WKUIDelegate {
    let webView: WKWebView

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
    }

    func load(startURL: URL) {
        guard webView.url == nil else { return }
        webView.load(URLRequest(url: startURL))
    }

    func captureCookieHeader() async throws -> String {
        let cookies = try await webView.allCookies()
        let relevantCookies = cookies.filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return domain == "mistral.ai" || domain.hasSuffix(".mistral.ai")
        }

        guard !relevantCookies.isEmpty else {
            throw MistralSessionImportError.noCookiesFound
        }

        let header = relevantCookies
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")

        guard !header.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MistralSessionImportError.noCookiesFound
        }

        return header
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }
}

private enum MistralSessionImportError: LocalizedError {
    case noCookiesFound

    var errorDescription: String? {
        switch self {
        case .noCookiesFound:
            return "No Mistral session cookies were found. Make sure you signed in to admin.mistral.ai in the embedded browser first."
         }
     }
}

// MARK: - Meta Web Session Import View

struct MetaWebSessionImportView: View {
    let onImport: (Result<CredentialImportService.ImportedCredential, Error>) -> Void

    /// Set when this view is hosted as a page inside the setup sheet. There,
    /// `dismiss` would tear down the whole sheet instead of returning to the
    /// provider's form, so the host supplies its own way back.
    var onClose: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }
    @State private var model = MetaWebSessionImportModel()
    @State private var isImporting = false
    @State private var importError: String?
    @State private var showImportError = false

    /// The user's Meta billing page. The project/team query params are
     /// preserved so the embedded browser lands on the right billing context.
    private let startURL = URL(string: "https://dev.meta.ai/billing/?project_id=1514228250391823&team_id=1760015591684812")!

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            CursorSessionWebView(webView: model.webView)
                .frame(minWidth: 720, minHeight: 560)

            Divider()

            footer
         }
         .frame(minWidth: 760, minHeight: 720)
         .onAppear {
            model.load(startURL: startURL)
         }
         .alert("Could Not Import Session", isPresented: $showImportError) {
            Button("OK", role: .cancel) {}
         } message: {
            Text(importError ?? "No Meta session cookies were found in the embedded browser.")
         }
     }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProviderBrandIconView(providerID: .meta, size: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Meta API web session")
                         .font(.headline.weight(.semibold))

                    Text("Sign in inside the embedded browser, then import the active dev.meta.ai session into Keychain.")
                         .font(.subheadline)
                         .foregroundStyle(.secondary)
                 }

                Spacer()
             }
             .padding(.horizontal, 20)
             .padding(.top, 18)

            Text("We only capture cookies from this embedded Meta session. The session is saved to macOS Keychain to read your Meta API current balance and billing-period spend from dev.meta.ai/billing.")
                 .font(.footnote)
                 .foregroundStyle(.secondary)
                 .padding(.horizontal, 20)
         }
         .padding(.bottom, 14)
     }

    private var footer: some View {
        HStack {
            Text("After signing in, click Import Session to securely save the session cookie in Keychain.")
                 .font(.footnote)
                 .foregroundStyle(.secondary)

            Spacer()

            Button("Cancel") {
                close()
             }
             .buttonStyle(.bordered)

            Button {
                Task {
                    await importCurrentSession()
                 }
             } label: {
                if isImporting {
                    ProgressView()
                         .progressViewStyle(.circular)
                 } else {
                    Text("Import Session")
                 }
             }
             .buttonStyle(.borderedProminent)
             .tint(Color(hex: ProviderID.meta.accentColorHex))
             .disabled(isImporting)
         }
         .padding(20)
     }

    private func importCurrentSession() async {
        isImporting = true
        defer { isImporting = false }

        do {
            let cookieHeader = try await model.captureCookieHeader()
            let imported = CredentialImportService.ImportedCredential(
                accessToken: nil,
                accountIdentifier: nil,
                customEndpoint: nil,
                extraFields: [
                     "metaCookieHeader": cookieHeader
                 ],
                bookmarkData: nil
             )
            onImport(.success(imported))
            close()
         } catch {
            importError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            showImportError = true
         }
     }
}

@MainActor
final class MetaWebSessionImportModel: NSObject, WKUIDelegate {
    let webView: WKWebView

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
     }

    func load(startURL: URL) {
        guard webView.url == nil else { return }
        webView.load(URLRequest(url: startURL))
     }

    func captureCookieHeader() async throws -> String {
        let cookies = try await webView.allCookies()
        let relevantCookies = cookies.filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return domain == "meta.ai" || domain.hasSuffix(".meta.ai")
                 || domain == "meta.com" || domain.hasSuffix(".meta.com")
         }

        guard !relevantCookies.isEmpty else {
            throw MetaWebSessionImportError.noCookiesFound
         }

        let header = relevantCookies
             .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
             .map { "\($0.name)=\($0.value)" }
             .joined(separator: "; ")

        guard !header.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MetaWebSessionImportError.noCookiesFound
         }

        return header
     }

    func webView(
         _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
     ) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
         }
        return nil
     }

    static func clearStoredWebsiteData() {
        let store = WKWebsiteDataStore.default()
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: dataTypes) { records in
            let metaRecords = records.filter { record in
                let name = record.displayName.lowercased()
                return name == "meta.ai" || name.hasSuffix(".meta.ai")
                     || name == "meta.com" || name.hasSuffix(".meta.com")
             }
            guard !metaRecords.isEmpty else { return }
            store.removeData(ofTypes: dataTypes, for: metaRecords) {}
         }
     }
}

private enum MetaWebSessionImportError: LocalizedError {
    case noCookiesFound

    var errorDescription: String? {
        switch self {
        case .noCookiesFound:
            return "No Meta session cookies were found. Make sure you signed in to dev.meta.ai in the embedded browser first."
         }
     }
}

// MARK: - Muse Code Subscription Import View

struct MuseSubscriptionImportView: View {
    let onImport: (Result<CredentialImportService.ImportedCredential, Error>) -> Void

    /// Set when this view is hosted as a page inside the setup sheet. There,
    /// `dismiss` would tear down the whole sheet instead of returning to the
    /// provider's form, so the host supplies its own way back.
    var onClose: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }
    @State private var model = MuseSubscriptionImportModel()
    @State private var isImporting = false
    @State private var importError: String?
    @State private var showImportError = false

    /// The user's Meta usage page. The project/team query params are
     /// preserved so the embedded browser lands on the right usage context.
    private let startURL = URL(string: "https://dev.meta.ai/usage/?project_id=1514228250391823&team_id=1760015591684812")!

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            CursorSessionWebView(webView: model.webView)
                .frame(minWidth: 720, minHeight: 560)

            Divider()

            footer
         }
         .frame(minWidth: 760, minHeight: 720)
         .onAppear {
            model.load(startURL: startURL)
         }
         .alert("Could Not Import Session", isPresented: $showImportError) {
            Button("OK", role: .cancel) {}
         } message: {
            Text(importError ?? "No Muse Code subscription meters were found in the embedded browser.")
         }
     }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProviderBrandIconView(providerID: .meta, size: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Muse Code subscription session")
                         .font(.headline.weight(.semibold))

                    Text("Sign in inside the embedded browser, wait for the subscription meters, then import the active dev.meta.ai session into Keychain.")
                         .font(.subheadline)
                         .foregroundStyle(.secondary)
                 }

                Spacer()
             }
             .padding(.horizontal, 20)
             .padding(.top, 18)

            Text("Uses this browser session to read Muse Code Current usage and Weekly limit, at most hourly. If Meta blocks a request, automatic checks pause for six hours.")
                 .font(.footnote)
                 .foregroundStyle(.secondary)
                 .padding(.horizontal, 20)
         }
         .padding(.bottom, 14)
     }

    private var footer: some View {
        HStack {
            Text("After the Current usage and Weekly limit meters appear, import the session.")
                 .font(.footnote)
                 .foregroundStyle(.secondary)

            Spacer()

            Button("Cancel") {
                close()
             }
             .buttonStyle(.bordered)

            Button {
                Task {
                    await importCurrentSession()
                 }
             } label: {
                if isImporting {
                    ProgressView()
                         .progressViewStyle(.circular)
                 } else {
                    Text("Import Session")
                 }
             }
             .buttonStyle(.borderedProminent)
             .tint(Color(hex: ProviderID.meta.accentColorHex))
             .disabled(isImporting)
         }
         .padding(20)
     }

    private func importCurrentSession() async {
        isImporting = true
        defer { isImporting = false }

        do {
            let session = try await model.captureSession()
            let imported = CredentialImportService.ImportedCredential(
                accessToken: nil,
                accountIdentifier: nil,
                customEndpoint: nil,
extraFields: museSubscriptionImportExtraFields(
                    cookieHeader: session.cookieHeader,
                    reading: session.reading,
                    url: model.webView.url
                ),
                bookmarkData: nil
             )
            onImport(.success(imported))
            close()
         } catch {
            importError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            showImportError = true
         }
     }
}

@MainActor
final class MuseSubscriptionImportModel: NSObject, WKUIDelegate {
    let webView: WKWebView
    private let popupHost = BrowserSessionPopupHost()

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
     }

    func load(startURL: URL) {
        guard webView.url == nil else { return }
        let savedURL = KeychainService.shared.credential(for: .meta)?.extraFields?[SpendProviderCredentialField.browserSessionURL]
        webView.load(URLRequest(url: BrowserSessionRefreshPolicy.validatedURL(savedURL, fallback: startURL)))
     }

    func captureSession() async throws -> (cookieHeader: String, reading: MuseSubscriptionWebReading) {
        let cookieHeader = try await captureCookieHeader()
        guard let renderedText = await webView.renderedBodyText(),
              let reading = MuseSubscriptionWebClient.parse(renderedText: renderedText, now: Date()) else {
            throw MuseSubscriptionImportError.noSubscriptionReading
        }
        return (cookieHeader, reading)
    }

    private func captureCookieHeader() async throws -> String {
        let cookies = try await webView.allCookies()
        let relevantCookies = cookies.filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return domain == "meta.ai" || domain.hasSuffix(".meta.ai")
                 || domain == "meta.com" || domain.hasSuffix(".meta.com")
         }

        guard !relevantCookies.isEmpty else {
            throw MuseSubscriptionImportError.noCookiesFound
         }

        let header = relevantCookies
             .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
             .map { "\($0.name)=\($0.value)" }
             .joined(separator: "; ")

        guard !header.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MuseSubscriptionImportError.noCookiesFound
         }

        return header
     }

    func webView(
         _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
     ) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }
        return popupHost.open(in: webView, configuration: configuration)
     }
}

private enum MuseSubscriptionImportError: LocalizedError {
    case noCookiesFound
    case noSubscriptionReading

    var errorDescription: String? {
        switch self {
        case .noCookiesFound:
            return "No Meta session cookies were found. Make sure you signed in to dev.meta.ai in the embedded browser first."
        case .noSubscriptionReading:
            return "The Meta usage page is signed in, but no Muse Code subscription meters were found. Wait for the Current usage and Weekly limit cards to load, then import again."
         }
     }
}

private func museSubscriptionImportExtraFields(
    cookieHeader: String,
    reading: MuseSubscriptionWebReading,
    url: URL?
) -> [String: String] {
    var fields = browserSessionImportFields(url: url).merging([
        SpendProviderCredentialField.metaCookieHeader: cookieHeader,
        SpendProviderCredentialField.museCachedAt: ISO8601DateFormatter().string(from: Date())
    ], uniquingKeysWith: { _, new in new })
    if let currentPercent = reading.currentUsedPercent {
        fields[SpendProviderCredentialField.museCachedCurrentPercent] = String(currentPercent)
    }
    if let weeklyPercent = reading.weeklyUsedPercent {
        fields[SpendProviderCredentialField.museCachedWeeklyPercent] = String(weeklyPercent)
    }
    if let planName = reading.planName?.trimmingCharacters(in: .whitespacesAndNewlines),
       !planName.isEmpty {
        fields[SpendProviderCredentialField.museCachedPlanName] = planName
    }
    if let weeklyResetAt = reading.weeklyResetAt {
        fields[SpendProviderCredentialField.museCachedWeeklyResetAt] = ISO8601DateFormatter().string(from: weeklyResetAt)
    }
    // The current window rolls in hours, so this only stays useful until it
    // lapses; the meter drops the reset rather than showing a past time.
    if let currentResetAt = reading.currentResetAt {
        fields[SpendProviderCredentialField.museCachedCurrentResetAt] = ISO8601DateFormatter().string(from: currentResetAt)
    }
    return fields
}

// MARK: - Cerebras Web Session Import View

struct CerebrasWebSessionImportView: View {
    let onImport: (Result<CredentialImportService.ImportedCredential, Error>) -> Void

    /// Set when this view is hosted as a page inside the setup sheet. There,
    /// `dismiss` would tear down the whole sheet instead of returning to the
    /// provider's form, so the host supplies its own way back.
    var onClose: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }
    @State private var model = CerebrasWebSessionImportModel()
    @State private var isImporting = false
    @State private var importError: String?
    @State private var showImportError = false

    /// The user's Cerebras billing page. The org id is preserved so the
     /// embedded browser lands on the right billing context.
    private let startURL = URL(string: "https://cloud.cerebras.ai/platform/org_eep8yff8mhr6k42k3v23fmy3/billing")!

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            CursorSessionWebView(webView: model.webView)
                 .frame(minWidth: 720, minHeight: 560)

            Divider()

            footer
         }
         .frame(minWidth: 760, minHeight: 720)
         .onAppear {
            model.load(startURL: startURL)
         }
         .alert("Could Not Import Session", isPresented: $showImportError) {
            Button("OK", role: .cancel) {}
         } message: {
            Text(importError ?? "No Cerebras session cookies were found in the embedded browser.")
         }
     }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProviderBrandIconView(providerID: .cerebras, size: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cerebras web session")
                         .font(.headline.weight(.semibold))

                    Text("Sign in inside the embedded browser, then import the active cloud.cerebras.ai session into Keychain.")
                         .font(.subheadline)
                         .foregroundStyle(.secondary)
                 }

                Spacer()
             }
             .padding(.horizontal, 20)
             .padding(.top, 18)

            Text("We only capture cookies from this embedded Cerebras session. The session is saved to macOS Keychain to read your Cerebras current balance and billing-period spend from cloud.cerebras.ai/billing.")
                 .font(.footnote)
                 .foregroundStyle(.secondary)
                 .padding(.horizontal, 20)
         }
         .padding(.bottom, 14)
     }

    private var footer: some View {
        HStack {
            Text("After signing in, click Import Session to securely save the session cookie in Keychain.")
                 .font(.footnote)
                 .foregroundStyle(.secondary)

            Spacer()

            Button("Cancel") {
                close()
             }
             .buttonStyle(.bordered)

            Button {
                Task {
                    await importCurrentSession()
                 }
             } label: {
                if isImporting {
                    ProgressView()
                         .progressViewStyle(.circular)
                 } else {
                    Text("Import Session")
                 }
             }
             .buttonStyle(.borderedProminent)
             .tint(Color(hex: ProviderID.cerebras.accentColorHex))
             .disabled(isImporting)
         }
         .padding(20)
     }

    private func importCurrentSession() async {
        isImporting = true
        defer { isImporting = false }

        do {
            let session = try await model.captureSession()
            let imported = CredentialImportService.ImportedCredential(
                accessToken: nil,
                accountIdentifier: nil,
                customEndpoint: nil,
extraFields: cerebrasWebSessionExtraFields(
                    cookieHeader: session.cookieHeader,
                    reading: session.reading,
                    url: model.webView.url
                ),
                bookmarkData: nil
             )
            onImport(.success(imported))
            close()
         } catch {
            importError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            showImportError = true
         }
     }
}

@MainActor
final class CerebrasWebSessionImportModel: NSObject, WKUIDelegate {
    let webView: WKWebView
    private let popupHost = BrowserSessionPopupHost()

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
     }

    func load(startURL: URL) {
        guard webView.url == nil else { return }
        let savedURL = KeychainService.shared.credential(for: .cerebras)?.extraFields?[SpendProviderCredentialField.browserSessionURL]
        webView.load(URLRequest(url: BrowserSessionRefreshPolicy.validatedURL(savedURL, fallback: startURL)))
     }

    func captureSession() async throws -> (cookieHeader: String, reading: WebBillingReading) {
        let cookieHeader = try await captureCookieHeader()
        guard let renderedText = await webView.renderedBodyText(),
              let reading = WebBillingClient.parse(html: renderedText, now: Date()) else {
            throw CerebrasWebSessionImportError.noBillingReading
        }
        return (cookieHeader, reading)
    }

    private func captureCookieHeader() async throws -> String {
        let cookies = try await webView.allCookies()
        let relevantCookies = cookies.filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return domain == "cerebras.ai" || domain.hasSuffix(".cerebras.ai")
         }

        guard !relevantCookies.isEmpty else {
            throw CerebrasWebSessionImportError.noCookiesFound
         }

        let header = relevantCookies
             .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
             .map { "\($0.name)=\($0.value)" }
             .joined(separator: "; ")

        guard !header.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CerebrasWebSessionImportError.noCookiesFound
         }

        return header
     }

    func webView(
         _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
     ) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }
        return popupHost.open(in: webView, configuration: configuration)
     }

    static func clearStoredWebsiteData() {
        let store = WKWebsiteDataStore.default()
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: dataTypes) { records in
            let cerebrasRecords = records.filter { record in
                let name = record.displayName.lowercased()
                return name == "cerebras.ai" || name.hasSuffix(".cerebras.ai")
             }
            guard !cerebrasRecords.isEmpty else { return }
            store.removeData(ofTypes: dataTypes, for: cerebrasRecords) {}
         }
     }
}

private enum CerebrasWebSessionImportError: LocalizedError {
    case noCookiesFound
    case noBillingReading

    var errorDescription: String? {
        switch self {
        case .noCookiesFound:
            return "No Cerebras session cookies were found. Make sure you signed in to cloud.cerebras.ai in the embedded browser first."
        case .noBillingReading:
            return "The Cerebras billing page is signed in, but its current balance has not finished loading. Wait for the balance, then import again."
          }
      }
}

private func cerebrasWebSessionExtraFields(
    cookieHeader: String,
    reading: WebBillingReading,
    url: URL?
) -> [String: String] {
    var fields = browserSessionImportFields(url: url)
    fields[SpendProviderCredentialField.cerebrasCookieHeader] = cookieHeader
    fields[SpendProviderCredentialField.cerebrasCachedAt] = ISO8601DateFormatter().string(from: Date())
    if let balance = reading.balance {
        fields[SpendProviderCredentialField.cerebrasCachedBalance] = String(balance)
    }
    if let spend = reading.spend {
        fields[SpendProviderCredentialField.cerebrasCachedSpend] = String(spend)
    }
    fields[SpendProviderCredentialField.cerebrasCachedCurrency] = reading.currency
    if let periodEnd = reading.periodEnd {
        fields[SpendProviderCredentialField.cerebrasCachedResetAt] = ISO8601DateFormatter().string(from: periodEnd)
    }
    return fields
}

private func tokenPlanImportExtraFields(
    cookieField: String,
    cookieHeader: String,
    reading: TokenPlanWebReading,
    url: URL?
) -> [String: String] {
    var fields = browserSessionImportFields(url: url).merging([
        cookieField: cookieHeader,
        SpendProviderCredentialField.tokenPlanCachedAt: ISO8601DateFormatter().string(from: Date())
    ], uniquingKeysWith: { _, new in new })
    if let usedPercent = reading.quotaUsedPercent {
        fields[SpendProviderCredentialField.tokenPlanCachedUsedPercent] = String(usedPercent)
    }
    if let planName = reading.planName?.trimmingCharacters(in: .whitespacesAndNewlines),
       !planName.isEmpty {
        fields[SpendProviderCredentialField.tokenPlanCachedPlanName] = planName
    }
    if let periodEnd = reading.periodEnd {
        fields[SpendProviderCredentialField.tokenPlanCachedResetAt] = ISO8601DateFormatter().string(from: periodEnd)
    }
    return fields
}

/// OAuth popup callbacks need their original opener and WebKit configuration.
@MainActor
private final class BrowserSessionPopupHost: NSObject, WKUIDelegate {
    private var popups: [WKWebView] = []

    func open(in parent: WKWebView, configuration: WKWebViewConfiguration) -> WKWebView {
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.uiDelegate = self
        popup.translatesAutoresizingMaskIntoConstraints = false
        parent.addSubview(popup)
        NSLayoutConstraint.activate([
            popup.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            popup.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            popup.topAnchor.constraint(equalTo: parent.topAnchor),
            popup.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        ])
        popups.append(popup)
        return popup
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }
        return open(in: webView, configuration: configuration)
    }

    func webViewDidClose(_ webView: WKWebView) {
        webView.removeFromSuperview()
        popups.removeAll { $0 === webView }
    }
}

private func browserSessionImportFields(url: URL?) -> [String: String] {
    var fields = [SpendProviderCredentialField.browserSessionID: UUID().uuidString]
    if let url, url.scheme == "https" {
        fields[SpendProviderCredentialField.browserSessionURL] = url.absoluteString
    }
    return fields
}

// MARK: - Qwen Token Plan Web Session Import View

struct QwenWebSessionImportView: View {
    let onImport: (Result<CredentialImportService.ImportedCredential, Error>) -> Void

    /// Set when this view is hosted as a page inside the setup sheet. There,
    /// `dismiss` would tear down the whole sheet instead of returning to the
    /// provider's form, so the host supplies its own way back.
    var onClose: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }
    @State private var model = QwenWebSessionImportModel()
    @State private var isImporting = false
    @State private var importError: String?
    @State private var showImportError = false

    private let startURL = URL(string: "https://modelstudio.console.alibabacloud.com/ap-southeast-1?tab=plan&productCode=p_efm#/efm/subscription/token-plan/personal")!

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            CursorSessionWebView(webView: model.webView)
                  .frame(minWidth: 720, minHeight: 560)

            Divider()

            footer
          }
          .frame(minWidth: 760, minHeight: 720)
          .onAppear {
            model.load(startURL: startURL)
          }
          .alert("Could Not Import Session", isPresented: $showImportError) {
            Button("OK", role: .cancel) {}
          } message: {
            Text(importError ?? "No Qwen session cookies were found in the embedded browser.")
          }
      }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProviderBrandIconView(providerID: .qwen, size: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Qwen token plan web session")
                          .font(.headline.weight(.semibold))

                    Text("Sign in inside the embedded browser, then import the active Alibaba Cloud Model Studio session into Keychain.")
                          .font(.subheadline)
                          .foregroundStyle(.secondary)
                  }

                Spacer()
              }
              .padding(.horizontal, 20)
              .padding(.top, 18)

            Text("We only capture cookies from this embedded Qwen session. The session is saved to macOS Keychain to read your token plan 7-day quota meter from the Model Studio console.")
                  .font(.footnote)
                  .foregroundStyle(.secondary)
                  .padding(.horizontal, 20)
          }
          .padding(.bottom, 14)
      }

    private var footer: some View {
        HStack {
            Text("After signing in, click Import Session to securely save the session cookie in Keychain.")
                  .font(.footnote)
                  .foregroundStyle(.secondary)

            Spacer()

            Button("Cancel") {
                close()
              }
              .buttonStyle(.bordered)

            Button {
                Task {
                    await importCurrentSession()
                  }
              } label: {
                if isImporting {
                    ProgressView()
                          .progressViewStyle(.circular)
                  } else {
                    Text("Import Session")
                  }
              }
              .buttonStyle(.borderedProminent)
              .tint(Color(hex: ProviderID.qwen.accentColorHex))
              .disabled(isImporting)
          }
          .padding(20)
      }

    private func importCurrentSession() async {
        isImporting = true
        defer { isImporting = false }

        do {
            let session = try await model.captureSession()
            let imported = CredentialImportService.ImportedCredential(
                accessToken: nil,
                accountIdentifier: nil,
                customEndpoint: nil,
extraFields: tokenPlanImportExtraFields(
                    cookieField: SpendProviderCredentialField.qwenCookieHeader,
                    cookieHeader: session.cookieHeader,
                    reading: session.reading,
                    url: model.webView.url
                ),
                bookmarkData: nil
              )
            onImport(.success(imported))
            close()
          } catch {
            importError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            showImportError = true
          }
      }
}

@MainActor
final class QwenWebSessionImportModel: NSObject, WKUIDelegate {
    let webView: WKWebView
    private let popupHost = BrowserSessionPopupHost()

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
      }

    func load(startURL: URL) {
        guard webView.url == nil else { return }
        let savedURL = KeychainService.shared.credential(for: .qwen)?.extraFields?[SpendProviderCredentialField.browserSessionURL]
        webView.load(URLRequest(url: BrowserSessionRefreshPolicy.validatedURL(savedURL, fallback: startURL)))
      }

    func captureSession() async throws -> (cookieHeader: String, reading: TokenPlanWebReading) {
        let cookieHeader = try await captureCookieHeader()
        guard let renderedText = await webView.renderedBodyText(),
              let reading = TokenPlanWebClient.parseQwen(renderedText: renderedText),
              reading.quotaUsedPercent != nil else {
            throw QwenWebSessionImportError.noQuotaReading
        }
        return (cookieHeader, reading)
    }

    func captureCookieHeader() async throws -> String {
        let cookies = try await webView.allCookies()
        let relevantCookies = cookies.filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return domain == "alibabacloud.com" || domain.hasSuffix(".alibabacloud.com")
                  || domain == "aliyun.com" || domain.hasSuffix(".aliyun.com")
          }

        guard !relevantCookies.isEmpty else {
            throw QwenWebSessionImportError.noCookiesFound
          }

        let header = relevantCookies
              .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
              .map { "\($0.name)=\($0.value)" }
              .joined(separator: "; ")

        guard !header.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw QwenWebSessionImportError.noCookiesFound
          }

        return header
      }

    func webView(
          _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
      ) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }
        return popupHost.open(in: webView, configuration: configuration)
      }

    static func clearStoredWebsiteData() {
        let store = WKWebsiteDataStore.default()
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: dataTypes) { records in
            let qwenRecords = records.filter { record in
                let name = record.displayName.lowercased()
                return name == "alibabacloud.com" || name.hasSuffix(".alibabacloud.com")
                      || name == "aliyun.com" || name.hasSuffix(".aliyun.com")
              }
            guard !qwenRecords.isEmpty else { return }
            store.removeData(ofTypes: dataTypes, for: qwenRecords) {}
          }
      }
}

private enum QwenWebSessionImportError: LocalizedError {
    case noCookiesFound
    case noQuotaReading

    var errorDescription: String? {
        switch self {
        case .noCookiesFound:
            return "No Qwen session cookies were found. Make sure you signed in to the Model Studio console in the embedded browser first."
        case .noQuotaReading:
            return "The Qwen page is signed in, but its 7-day quota has not finished loading. Wait for the quota meter, then import again."
          }
      }
}

// MARK: - Xiaomi MiMo Web Session Import View

struct MimoWebSessionImportView: View {
    let onImport: (Result<CredentialImportService.ImportedCredential, Error>) -> Void

    /// Set when this view is hosted as a page inside the setup sheet. There,
    /// `dismiss` would tear down the whole sheet instead of returning to the
    /// provider's form, so the host supplies its own way back.
    var onClose: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }
    @State private var model = MimoWebSessionImportModel()
    @State private var isImporting = false
    @State private var importError: String?
    @State private var showImportError = false

    private let startURL = URL(string: "https://platform.xiaomimimo.com/console/plan-manage")!

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            CursorSessionWebView(webView: model.webView)
                  .frame(minWidth: 720, minHeight: 560)

            Divider()

            footer
          }
          .frame(minWidth: 760, minHeight: 720)
          .onAppear {
            model.load(startURL: startURL)
          }
          .alert("Could Not Import Session", isPresented: $showImportError) {
            Button("OK", role: .cancel) {}
          } message: {
            Text(importError ?? "No MiMo session cookies were found in the embedded browser.")
          }
      }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProviderBrandIconView(providerID: .mimo, size: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Xiaomi MiMo web session")
                          .font(.headline.weight(.semibold))

                    Text("Sign in inside the embedded browser, then import the active platform.xiaomimimo.com session into Keychain.")
                          .font(.subheadline)
                          .foregroundStyle(.secondary)
                  }

                Spacer()
              }
              .padding(.horizontal, 20)
              .padding(.top, 18)

            Text("We only capture cookies from this embedded MiMo session. The session is saved to macOS Keychain to read your plan quota meter from the Xiaomi MiMo console.")
                  .font(.footnote)
                  .foregroundStyle(.secondary)
                  .padding(.horizontal, 20)
          }
          .padding(.bottom, 14)
      }

    private var footer: some View {
        HStack {
            Text("After signing in, click Import Session to securely save the session cookie in Keychain.")
                  .font(.footnote)
                  .foregroundStyle(.secondary)

            Spacer()

            Button("Cancel") {
                close()
              }
              .buttonStyle(.bordered)

            Button {
                Task {
                    await importCurrentSession()
                  }
              } label: {
                if isImporting {
                    ProgressView()
                          .progressViewStyle(.circular)
                  } else {
                    Text("Import Session")
                  }
              }
              .buttonStyle(.borderedProminent)
              .tint(Color(hex: ProviderID.mimo.accentColorHex))
              .disabled(isImporting)
          }
          .padding(20)
      }

    private func importCurrentSession() async {
        isImporting = true
        defer { isImporting = false }

        do {
            let session = try await model.captureSession()
            let imported = CredentialImportService.ImportedCredential(
                accessToken: nil,
                accountIdentifier: nil,
                customEndpoint: nil,
extraFields: tokenPlanImportExtraFields(
                    cookieField: SpendProviderCredentialField.mimoCookieHeader,
                    cookieHeader: session.cookieHeader,
                    reading: session.reading,
                    url: model.webView.url
                ),
                bookmarkData: nil
              )
            onImport(.success(imported))
            close()
          } catch {
            importError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            showImportError = true
          }
      }
}

@MainActor
final class MimoWebSessionImportModel: NSObject, WKUIDelegate {
    let webView: WKWebView
    private let popupHost = BrowserSessionPopupHost()

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
      }

    func load(startURL: URL) {
        guard webView.url == nil else { return }
        let savedURL = KeychainService.shared.credential(for: .mimo)?.extraFields?[SpendProviderCredentialField.browserSessionURL]
        webView.load(URLRequest(url: BrowserSessionRefreshPolicy.validatedURL(savedURL, fallback: startURL)))
      }

    func captureSession() async throws -> (cookieHeader: String, reading: TokenPlanWebReading) {
        let cookieHeader = try await captureCookieHeader()
        guard let renderedText = await webView.renderedBodyText(),
              let reading = TokenPlanWebClient.parse(renderedText: renderedText),
              reading.quotaUsedPercent != nil else {
            throw MimoWebSessionImportError.noQuotaReading
        }
        return (cookieHeader, reading)
    }

    func captureCookieHeader() async throws -> String {
        let cookies = try await webView.allCookies()
        let relevantCookies = cookies.filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return domain == "xiaomimimo.com" || domain.hasSuffix(".xiaomimimo.com")
          }

        guard !relevantCookies.isEmpty else {
            throw MimoWebSessionImportError.noCookiesFound
          }

        let header = relevantCookies
              .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
              .map { "\($0.name)=\($0.value)" }
              .joined(separator: "; ")

        guard !header.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MimoWebSessionImportError.noCookiesFound
          }

        return header
      }

    func webView(
          _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
      ) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }
        return popupHost.open(in: webView, configuration: configuration)
      }

    static func clearStoredWebsiteData() {
        let store = WKWebsiteDataStore.default()
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: dataTypes) { records in
            let mimoRecords = records.filter { record in
                let name = record.displayName.lowercased()
                return name == "xiaomimimo.com" || name.hasSuffix(".xiaomimimo.com")
              }
            guard !mimoRecords.isEmpty else { return }
            store.removeData(ofTypes: dataTypes, for: mimoRecords) {}
          }
      }
}

private enum MimoWebSessionImportError: LocalizedError {
    case noCookiesFound
    case noQuotaReading

    var errorDescription: String? {
        switch self {
        case .noCookiesFound:
            return "No MiMo session cookies were found. Make sure you signed in to platform.xiaomimimo.com in the embedded browser first."
        case .noQuotaReading:
            return "The MiMo page is signed in, but its plan quota has not finished loading. Wait for the usage meter, then import again."
          }
      }
}
