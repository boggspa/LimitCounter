import SwiftUI
import WebKit

struct CursorSessionImportView: View {
    let onImport: (Result<CredentialImportService.ImportedCredential, Error>) -> Void

    @Environment(\.dismiss) private var dismiss
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
                dismiss()
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
            dismiss()
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

// MARK: - Ollama Session Import View

struct OllamaSessionImportView: View {
    let onImport: (Result<CredentialImportService.ImportedCredential, Error>) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model = OllamaSessionImportModel()
    @State private var isImporting = false
    @State private var importError: String?
    @State private var showImportError = false

    private let startURL = URL(string: "https://ollama.com/login")!

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

            Text("We only capture cookies from this embedded Ollama session. The session is saved to macOS Keychain to read your 5-hour and Weekly usage meters.")
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
                dismiss()
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
            dismiss()
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

    @Environment(\.dismiss) private var dismiss
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
                dismiss()
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
            dismiss()
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
