import SwiftUI
import WebKit
import WidgetKit

/// The app is the reading site in a web view; it also hosts the widget. It asks which server to use
/// the first time, so one build fits every Readstreak server.
@main
struct ReadingApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var server = ServerStore.url
    @State private var route = ""
    @State private var onLoginPage = false

    var body: some Scene {
        WindowGroup {
            Group {
                if let server {
                    WebView(server: server, route: route, onLoginPage: $onLoginPage)
                        .ignoresSafeArea()
                        .overlay(alignment: .bottom) {
                            if onLoginPage {
                                Button("Change server", action: changeServer)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .padding(.bottom, 24)
                            }
                        }
                } else {
                    ServerView { server = $0 }
                }
            }
            .background(Theme.page)
            .preferredColorScheme(.dark)
            // reading://book/<id> from the widget opens that book's page.
            .onOpenURL { url in
                route = "#/" + [url.host() ?? "", url.path()].joined().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { WidgetCenter.shared.reloadAllTimelines() }
        }
    }

    private func changeServer() {
        ServerStore.clear()
        TokenStore.clear()
        WidgetCenter.shared.reloadAllTimelines()
        onLoginPage = false
        server = nil
    }
}

/// First launch: the address of the Readstreak server, checked against its /healthz.
struct ServerView: View {
    let done: (URL) -> Void
    @State private var address = ""
    @State private var checking = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            // the owl as a sewn on badge: tan ring, cream running stitch
            Image("Owl")
                .resizable()
                .scaledToFill()
                .frame(width: 64, height: 64)
                .clipShape(Circle())
                .padding(4)
                .background(Theme.tan, in: Circle())
                .overlay(Circle().inset(by: 7).stroke(Theme.cream.opacity(0.75), style: Theme.runningStitch))
            Text("Readstreak")
                .font(.system(size: 36, weight: .semibold, design: .serif))
                .foregroundStyle(Theme.text)
                .padding(.top, 24)
            Text("Enter the address of your Readstreak server.")
                .foregroundStyle(Theme.muted)
                .padding(.top, 8)
            Text("SERVER ADDRESS")
                .font(.footnote.weight(.semibold))
                .tracking(1)
                .foregroundStyle(Theme.tan)
                .padding(.top, 32)
            TextField("read.example.com", text: $address)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit(connect)
                .padding(16)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).inset(by: 4).stroke(Theme.stitch, style: Theme.runningStitch))
                .padding(.top, 8)
            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(Color(hex: 0xF08A7E))
                    .padding(.top, 8)
            }
            Button(action: connect) {
                Group {
                    if checking { ProgressView().tint(Theme.ink) } else { Text("Continue") }
                }
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 52)
                .foregroundStyle(Theme.ink)
                .background(Theme.tan, in: Capsule())
                .overlay(Capsule().inset(by: 4).stroke(Theme.ink.opacity(0.45), style: Theme.runningStitch))
            }
            .disabled(checking || address.isEmpty)
            .padding(.top, 24)
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.page)
    }

    private func connect() {
        let urls = ServerStore.candidates(address)
        guard let first = urls.first else {
            error = "That doesn't look like a web address."
            return
        }
        checking = true
        error = nil
        Task {
            for url in urls where await ServerStore.check(url) {
                checking = false
                ServerStore.save(url)
                done(url)
                return
            }
            checking = false
            error = "No Readstreak server answered at \(first.host() ?? address)."
        }
    }
}

struct WebView: UIViewRepresentable {
    let server: URL
    let route: String
    @Binding var onLoginPage: Bool

    func makeCoordinator() -> Coordinator { Coordinator(server: server, onLoginPage: $onLoginPage) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()  // keeps the sign-in cookie between launches
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = UIColor(Theme.page)
        web.scrollView.backgroundColor = UIColor(Theme.page)
        web.scrollView.contentInsetAdjustmentBehavior = .never  // the page pads for the safe area itself
        web.allowsBackForwardNavigationGestures = true
        web.navigationDelegate = context.coordinator

        let refresh = UIRefreshControl()
        refresh.tintColor = UIColor(Theme.tan)
        refresh.addTarget(context.coordinator, action: #selector(Coordinator.reload(_:)), for: .valueChanged)
        web.scrollView.refreshControl = refresh
        context.coordinator.web = web

        web.load(URLRequest(url: server))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        guard !route.isEmpty, route != context.coordinator.lastRoute else { return }
        context.coordinator.lastRoute = route
        web.load(URLRequest(url: URL(string: route, relativeTo: server)!))
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKDownloadDelegate {
        let server: URL
        @Binding var onLoginPage: Bool
        weak var web: WKWebView?
        var lastRoute = ""
        var downloadURL: URL?

        init(server: URL, onLoginPage: Binding<Bool>) {
            self.server = server
            _onLoginPage = onLoginPage
        }

        @objc func reload(_ sender: UIRefreshControl) {
            web?.reload()
            WidgetCenter.shared.reloadAllTimelines()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.scrollView.refreshControl?.endRefreshing()
            onLoginPage = webView.url?.path() == "/login"
            // Signed in, out, or as someone else: give the widgets the matching token.
            let store = webView.configuration.websiteDataStore.httpCookieStore
            Task { @MainActor in await WidgetAccount.sync(from: store, server: server) }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            webView.scrollView.refreshControl?.endRefreshing()
        }

        // Anything off the reading site opens in Safari.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if let url = action.request.url, let host = url.host(), host != server.host() {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        // Files the site sends as attachments (the highlights export) download, then open the share sheet.
        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                     decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
            let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")
            decisionHandler(disposition?.hasPrefix("attachment") == true ? .download : .allow)
        }

        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            download.delegate = self
        }

        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                      suggestedFilename: String) async -> URL? {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            downloadURL = dir.appendingPathComponent(suggestedFilename)
            return downloadURL
        }

        func downloadDidFinish(_ download: WKDownload) {
            guard let url = downloadURL, let web, var top = web.window?.rootViewController else { return }
            while let presented = top.presentedViewController { top = presented }
            let share = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            share.popoverPresentationController?.sourceView = web
            top.present(share, animated: true)
        }
    }
}
