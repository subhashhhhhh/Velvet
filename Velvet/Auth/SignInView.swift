import SwiftUI
import WebKit
import OSLog

/// Google's real sign-in page in an isolated web view. When the flow lands back
/// on youtube.com with auth cookies set, those cookies become a `YouTubeSession`.
struct SignInView: View {
    var onComplete: ([StoredCookie]) -> Void
    var onCancel: () -> Void

    @State private var isLoading = true
    @State private var hasLoaded = false
    @State private var signedIn = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(signedIn ? "Signed in" : "Sign in to YouTube")
                        .font(.headline)
                    Text("On Google's own page. Velvet keeps the session only on this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isLoading && hasLoaded { ProgressView().controlSize(.small) }
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            SignInWebView(
                onLoading: { loading in
                    isLoading = loading
                    if !loading { hasLoaded = true }
                },
                onCaptured: { cookies in
                    signedIn = true
                    onComplete(cookies)
                }
            )
            // Until Google's page first appears, a blank white page looks broken.
            .overlay {
                if !hasLoaded || signedIn {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(signedIn ? "Signing in…" : "Opening Google sign-in…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
                }
            }
        }
        .frame(width: 520, height: 700)
    }
}

private struct SignInWebView: NSViewRepresentable {
    var onLoading: (Bool) -> Void
    var onCaptured: ([StoredCookie]) -> Void

    static let signInURL = URL(string:
        "https://accounts.google.com/ServiceLogin?service=youtube&uilel=3&passive=true"
        + "&continue=https%3A%2F%2Fwww.youtube.com%2Fsignin%3Faction_handle_signin%3Dtrue%26app%3Ddesktop%26next%3D%252F"
    )!

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Throwaway store: nothing from this login lingers in WebKit afterwards.
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        // Google refuses sign-in from user agents that look embedded.
        web.customUserAgent = InnerTubeClient.userAgent
        web.navigationDelegate = context.coordinator
        web.load(URLRequest(url: Self.signInURL))
        return web
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: SignInWebView
        private var captured = false
        private let log = Logger(subsystem: "com.subhash.Velvet", category: "SignIn")

        init(_ parent: SignInWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.onLoading(true)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.onLoading(false)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.onLoading(false)
            guard !captured, let host = webView.url?.host(), host.hasSuffix("youtube.com") else { return }
            Task { await captureIfSignedIn(webView) }
        }

        @MainActor
        private func captureIfSignedIn(_ webView: WKWebView) async {
            let all = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            let youtube = all.filter { $0.domain.hasSuffix("youtube.com") }
            let names = Set(youtube.map(\.name))
            // SAPISID (or its secure twin) is what authenticates InnerTube requests.
            guard !captured, names.contains("SAPISID") || names.contains("__Secure-3PAPISID"),
                  names.contains("LOGIN_INFO") || names.contains("SID") else {
                log.debug("On YouTube but not signed in yet (\(youtube.count) cookies)")
                return
            }
            captured = true
            // Keep YouTube and Google cookies; yt-dlp and rotation can need both.
            let keep = all.filter { $0.domain.hasSuffix("youtube.com") || $0.domain.hasSuffix("google.com") }
            log.info("Captured \(keep.count) cookies")
            parent.onCaptured(keep.map(StoredCookie.init))
        }
    }
}
