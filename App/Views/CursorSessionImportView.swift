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
