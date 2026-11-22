import SwiftUI
import UIKit
import WebKit

/// what the sign-in pages tell swift
enum WebSignal {
    case credential(String, auto: Bool)
    case loginResponse(String)
    case ready
    case noAuto(String)
    case failed(String)
}

/// google refuses to sign in inside anything it recognises as a web view, and
/// the portal's client id only trusts the portal's origin. so: look like
/// safari, and serve our own tiny page from the portal's origin.
enum PortalWeb {
    static let host = "webportal.jiit.ac.in"
    static let port = 6011
    static let origin = "https://\(host):\(port)"
    static let signinPath = "/studentportal/jportal-signin"
    static let portalURL = URL(string: origin + "/studentportal/")!

    /// window.jportal.postMessage, the name the shared sign-in page already calls
    private static let bridge = """
    (function () {
      if (window.jportal) return;
      window.jportal = { postMessage: function (m) { try { window.webkit.messageHandlers.jportal.postMessage(String(m)); } catch (e) {} } };
    })();
    """

    // wraps xhr and fetch so the portal's own login response reaches us
    private static let hook = """
    (function () {
      if (window.__jp) return; window.__jp = true;
      var hit = function (u) { return String(u).indexOf('generate-token-google-signin') >= 0; };
      var post = function (b) { try { jportal.postMessage(JSON.stringify({ type: 'login', body: b })); } catch (e) {} };
      var open = XMLHttpRequest.prototype.open, send = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function (m, u) { this.__jpu = u; return open.apply(this, arguments); };
      XMLHttpRequest.prototype.send = function () {
        if (hit(this.__jpu)) { var x = this; x.addEventListener('load', function () { post(x.responseText); }); }
        return send.apply(this, arguments);
      };
      var f = window.fetch;
      if (f) window.fetch = function (u) {
        var p = f.apply(this, arguments);
        if (hit(u && u.url || u)) p.then(function (r) { r.clone().text().then(post); });
        return p;
      };
    })();
    """

    /// safari's tail on the user agent, the part google looks for
    static var safariSuffix: String {
        let major = UIDevice.current.systemVersion.split(separator: ".").first.map(String.init) ?? "18"
        return "Version/\(major).0 Mobile/15E148 Safari/604.1"
    }

    static func configuration(_ handler: WKScriptMessageHandler) -> WKWebViewConfiguration {
        let c = WKWebViewConfiguration()
        // google's session cookie is what makes silent re-auth possible later, so the default persistent store
        c.websiteDataStore = .default()
        c.applicationNameForUserAgent = safariSuffix
        c.preferences.javaScriptCanOpenWindowsAutomatically = true
        c.defaultWebpagePreferences.allowsContentJavaScript = true
        let ucc = WKUserContentController()
        ucc.add(WeakHandler(handler), name: "jportal")
        ucc.addUserScript(WKUserScript(source: bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        ucc.addUserScript(WKUserScript(source: hook, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        c.userContentController = ucc
        return c
    }

    /// the shared sign-in page with its query baked in, so it doesn't matter how the base url's query is surfaced
    static func signinHTML(clientId: String, dark: Bool, width: Int) -> String? {
        guard let url = Bundle.main.url(forResource: "signin", withExtension: "html"),
              var html = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var q = URLComponents()
        q.queryItems = [
            URLQueryItem(name: "cid", value: clientId), URLQueryItem(name: "mode", value: "button"),
            URLQueryItem(name: "theme", value: dark ? "dark" : "light"), URLQueryItem(name: "w", value: String(width)),
        ]
        let query = (q.percentEncodedQuery ?? "").replacingOccurrences(of: "'", with: "%27")
        html = html.replacingOccurrences(of: "new URLSearchParams(location.search)", with: "new URLSearchParams('?\(query)')")
        return html
    }

    static func signinBase(_ clientId: String) -> URL {
        URL(string: origin + signinPath + "?cid=" + (clientId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""))!
    }

    static func parse(_ body: Any) -> WebSignal? {
        guard let text = body as? String, let j = try? JSON(parsing: text) else { return nil }
        switch j["type"].str {
        case "credential": return .credential(j["credential"].str, auto: j["by"].str.hasPrefix("auto"))
        case "login": return .loginResponse(j["body"].str)
        case "ready": return .ready
        case "no_auto": return .noAuto(j["why"].str)
        case "fail": return .failed(j["why"].str)
        default: return nil
        }
    }

    /// signals only count when they come from a page on the portal's origin
    static func trusted(_ m: WKScriptMessage) -> Bool {
        let o = m.frameInfo.securityOrigin
        return m.frameInfo.isMainFrame && o.protocol == "https" && o.host == host && o.port == port
    }
}

/// WKUserContentController holds its handlers strongly, this breaks the cycle
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ t: WKScriptMessageHandler) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { target?.userContentController(c, didReceive: m) }
}

/// google's popup window, shown full screen until it closes itself
struct PopupBox: Identifiable {
    let id = UUID()
    let web: WKWebView
}

enum PortalPage {
    case signin(clientId: String, dark: Bool, width: Int)
    case portal
    /// google's oauth endpoint as the top-level page, see GoogleSilentAuth
    case silentGoogle(clientId: String, loginHint: String?, nonce: String)
}

/// a web view wired for sign-in. onPopup gets google's popup window (or nil when it closes)
struct PortalWebView: UIViewRepresentable {
    let page: PortalPage
    let onSignal: (WebSignal) -> Void
    let onPopup: (WKWebView?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let web = WKWebView(frame: .zero, configuration: PortalWeb.configuration(context.coordinator))
        web.uiDelegate = context.coordinator
        web.navigationDelegate = context.coordinator
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        #if DEBUG
        if #available(iOS 16.4, *) { web.isInspectable = true }
        #endif
        switch page {
        case .signin(let cid, let dark, let width):
            web.scrollView.isScrollEnabled = false
            if let html = PortalWeb.signinHTML(clientId: cid, dark: dark, width: width) {
                web.loadHTMLString(html, baseURL: PortalWeb.signinBase(cid))
            } else {
                onSignal(.failed("no_page"))
            }
        case .portal:
            web.load(URLRequest(url: PortalWeb.portalURL))
        case .silentGoogle(let cid, let hint, let nonce):
            web.load(URLRequest(url: GoogleSilentAuth.url(clientId: cid, nonce: nonce, loginHint: hint)))
        }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        web.stopLoading()
        web.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate {
        var parent: PortalWebView

        init(_ parent: PortalWebView) { self.parent = parent }

        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            guard PortalWeb.trusted(m), let signal = PortalWeb.parse(m.body) else { return }
            parent.onSignal(signal)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            let popup = WKWebView(frame: webView.bounds, configuration: configuration)
            popup.uiDelegate = self
            #if DEBUG
            if #available(iOS 16.4, *) { popup.isInspectable = true }
            #endif
            parent.onPopup(popup)
            return popup
        }

        func webViewDidClose(_ webView: WKWebView) {
            parent.onPopup(nil)
        }

        /// silent google: catch google's redirect back to the portal and read the
        /// token out of it, the portal page itself is never loaded. prompt=none
        /// always ends in that redirect, the session manager's timeout covers the rest.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            guard case .silentGoogle(_, _, let nonce) = parent.page, let url = action.request.url,
                  action.targetFrame?.isMainFrame == true, GoogleSilentAuth.isRedirect(url) else {
                return decisionHandler(.allow)
            }
            decisionHandler(.cancel)
            switch GoogleSilentAuth.outcome(url, nonce: nonce) {
            case .token(let t): parent.onSignal(.credential(t, auto: true))
            case .refused(let why): parent.onSignal(.noAuto(why))
            case nil: parent.onSignal(.noAuto("no_answer"))
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }

        private func failed(_ error: Error) {
            if (error as NSError).code == NSURLErrorCancelled { return }
            // a cancelled policy decision shows up as frame load interrupted, that's us
            if (error as NSError).domain == "WebKitErrorDomain" && (error as NSError).code == 102 { return }
            parent.onSignal(.failed("load"))
        }
    }
}

/// hosts a web view that already exists, google's popup
struct ExistingWebView: UIViewRepresentable {
    let web: WKWebView
    func makeUIView(context: Context) -> WKWebView { web }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct PopupHost: View {
    let box: PopupBox
    let onClose: () -> Void
    @Environment(\.palette) private var p

    var body: some View {
        NavigationStack {
            ExistingWebView(web: box.web)
                .ignoresSafeArea(edges: .bottom)
                .background(p.surface)
                .navigationTitle("Sign in with Google")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onClose) } }
        }
    }
}
