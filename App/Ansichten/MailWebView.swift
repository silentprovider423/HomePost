import SwiftUI
import WebKit

/// Sichere E-Mail-Anzeige: kein JavaScript, keine Cookies, Ferninhalte standardmäßig blockiert,
/// Links öffnen erst nach Antippen außerhalb der App. Höhe passt sich dem Inhalt an.
struct MailWebView: UIViewRepresentable {
    let html: String
    let ferninhalte: Bool
    @Binding var hoehe: CGFloat

    static let sperrRegel = """
    [{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]
    """

    func makeCoordinator() -> Koordinator { Koordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = false
        cfg.dataDetectorTypes = [.link, .phoneNumber, .address, .calendarEvent]
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.navigationDelegate = context.coordinator
        context.coordinator.beobachten(web)
        context.coordinator.laden(web, html: html, ferninhalte: ferninhalte)
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.eltern = self
        context.coordinator.laden(web, html: html, ferninhalte: ferninhalte)
    }

    final class Koordinator: NSObject, WKNavigationDelegate {
        var eltern: MailWebView
        private var geladen: (String, Bool)?
        private var beobachter: NSKeyValueObservation?

        init(_ e: MailWebView) { eltern = e }

        func beobachten(_ web: WKWebView) {
            beobachter = web.scrollView.observe(\.contentSize, options: [.new]) { [weak self] sv, _ in
                let h = sv.contentSize.height
                MainActor.assumeIsolated {
                    guard let self, h > 0, abs(self.eltern.hoehe - h) > 1 else { return }
                    self.eltern.hoehe = h
                }
            }
        }

        @MainActor
        func laden(_ web: WKWebView, html: String, ferninhalte: Bool) {
            if let g = geladen, g.0 == html, g.1 == ferninhalte { return }
            geladen = (html, ferninhalte)
            let inhalt = MailHTML.einbetten(html)
            if ferninhalte {
                web.configuration.userContentController.removeAllContentRuleLists()
                web.loadHTMLString(inhalt, baseURL: nil)
                return
            }
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "ferninhalte-sperren",
                                                                    encodedContentRuleList: MailWebView.sperrRegel) { liste, _ in
                MainActor.assumeIsolated {
                    if let liste { web.configuration.userContentController.add(liste) }
                    web.loadHTMLString(inhalt, baseURL: nil)
                }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                await UIApplication.shared.open(url)
                return .cancel
            }
            return navigationAction.navigationType == .other ? .allow : .cancel
        }
    }
}

enum MailHTML {
    /// Gemeinsames Stylesheet (Systemschrift, Dunkelmodus für Textmails, Bilder passend).
    static func einbetten(_ koerper: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <meta name="color-scheme" content="light dark">
        <style>
        html,body{margin:0;padding:0;-webkit-text-size-adjust:100%;}
        body{font:-apple-system-body;font-family:-apple-system,system-ui;word-wrap:break-word;overflow-wrap:anywhere;}
        img{max-width:100%!important;height:auto!important;}
        table{max-width:100%!important;}
        pre.hp{white-space:pre-wrap;font:-apple-system-body;font-family:-apple-system,system-ui;margin:0;}
        blockquote.hp{margin:6px 0;padding-left:10px;border-left:3px solid #0a84ff;color:#6e6e73;}
        a{color:#0a84ff;}
        </style></head><body>\(koerper)</body></html>
        """
    }

    /// Textmail → HTML mit Zitat-Balken wie Apple („>“-Zeilen eingerückt).
    static func ausText(_ text: String) -> String {
        var aus = ""
        var ebene = 0
        let sauber = text.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        for zeile in sauber.split(separator: "\n", omittingEmptySubsequences: false) {
            var z = Substring(zeile)
            var tiefe = 0
            while z.hasPrefix(">") { tiefe += 1; z = z.dropFirst(); if z.hasPrefix(" ") { z = z.dropFirst() } }
            while ebene < tiefe { aus += "<blockquote class=\"hp\">"; ebene += 1 }
            while ebene > tiefe { aus += "</blockquote>"; ebene -= 1 }
            aus += maskieren(String(z)) + "\n"
        }
        if aus.hasSuffix("\n") { aus.removeLast() }
        while ebene > 0 { aus += "</blockquote>"; ebene -= 1 }
        return "<pre class=\"hp\">" + aus + "</pre>"
    }

    static func maskieren(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Enthält die E-Mail Ferninhalte (Bilder/Stile von fremden Servern)?
    static func hatFerninhalte(_ html: String) -> Bool {
        html.range(of: "(src|background)\\s*=\\s*[\"']?https?://", options: [.regularExpression, .caseInsensitive]) != nil
            || html.range(of: "url\\(\\s*[\"']?https?://", options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// cid:-Verweise durch eingebettete Daten ersetzen.
    static func cidErsetzen(_ html: String, _ teile: [(cid: String, typ: String, daten: Data)]) -> String {
        var h = html
        for t in teile {
            h = h.replacingOccurrences(of: "cid:\(t.cid)", with: "data:\(t.typ);base64,\(t.daten.base64EncodedString())")
        }
        return h
    }
}
