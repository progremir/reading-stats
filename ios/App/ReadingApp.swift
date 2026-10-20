import SwiftUI
import WebKit
import WidgetKit

/// The app is the reading site in a web view; it also hosts the widget.
@main
struct ReadingApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var route = ""

    var body: some Scene {
        WindowGroup {
            WebView(route: route)
                .ignoresSafeArea()
                .background(Color.black)
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
}

struct WebView: UIViewRepresentable {
    let route: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()  // keeps the sign-in cookie between launches
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.backgroundColor = .black
        web.scrollView.contentInsetAdjustmentBehavior = .never  // the page pads for the safe area itself
        web.allowsBackForwardNavigationGestures = true
        web.navigationDelegate = context.coordinator

        let refresh = UIRefreshControl()
        refresh.tintColor = .lightGray
        refresh.addTarget(context.coordinator, action: #selector(Coordinator.reload(_:)), for: .valueChanged)
        web.scrollView.refreshControl = refresh
        context.coordinator.web = web

        web.load(URLRequest(url: ReadingAPI.baseURL))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        guard !route.isEmpty, route != context.coordinator.lastRoute else { return }
        context.coordinator.lastRoute = route
        web.load(URLRequest(url: URL(string: route, relativeTo: ReadingAPI.baseURL)!))
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var web: WKWebView?
        var lastRoute = ""

        @objc func reload(_ sender: UIRefreshControl) {
            web?.reload()
            WidgetCenter.shared.reloadAllTimelines()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.scrollView.refreshControl?.endRefreshing()
            // Signed in, out, or as someone else: give the widgets the matching token.
            let store = webView.configuration.websiteDataStore.httpCookieStore
            Task { @MainActor in await WidgetAccount.sync(from: store) }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            webView.scrollView.refreshControl?.endRefreshing()
        }

        // Anything off the reading site opens in Safari.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if let url = action.request.url, let host = url.host(), host != ReadingAPI.baseURL.host() {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}
