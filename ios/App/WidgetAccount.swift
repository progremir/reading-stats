import UIKit
import WebKit
import WidgetKit

/// Keeps the widgets' token in step with whoever is signed in to the web view: after sign-in it asks
/// the server for a widget token for this phone; after sign-out it forgets it.
@MainActor
enum WidgetAccount {
    private struct Me: Decodable { let name: String }
    private struct Issued: Decodable { let token: String; let name: String }

    private static var running = false

    static func sync(from store: WKHTTPCookieStore) async {
        guard !running else { return }
        running = true
        defer { running = false }

        let host = ReadingAPI.baseURL.host() ?? ""
        let cookies = await store.allCookies().filter { cookie in
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            return host == domain || host.hasSuffix("." + domain)
        }
        guard let cookieHeader = HTTPCookie.requestHeaderFields(with: cookies)["Cookie"] else {
            forget()
            return
        }

        guard let (data, status) = await request("api/me", cookie: cookieHeader) else { return }
        if status == 401 {
            forget()
            return
        }
        guard status == 200, let me = try? JSONDecoder().decode(Me.self, from: data) else { return }
        if TokenStore.token != nil, TokenStore.account == me.name { return }

        let body: [String: String] = [
            "label": UIDevice.current.name,
            "client_id": UIDevice.current.identifierForVendor?.uuidString ?? "",
        ]
        guard let (issuedData, issuedStatus) = await request("api/account/widget-token", cookie: cookieHeader, body: body),
              issuedStatus == 200,
              let issued = try? JSONDecoder().decode(Issued.self, from: issuedData) else { return }
        TokenStore.save(token: issued.token, account: issued.name)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private static func forget() {
        guard TokenStore.token != nil else { return }
        TokenStore.clear()
        WidgetCenter.shared.reloadAllTimelines()
    }

    private static func request(_ path: String, cookie: String, body: [String: String]? = nil) async -> (Data, Int)? {
        var request = URLRequest(url: ReadingAPI.baseURL.appending(path: path))
        request.httpShouldHandleCookies = false
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONEncoder().encode(body)
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        return (data, http.statusCode)
    }
}
