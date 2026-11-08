import Foundation

/// Baut eine RFC-5322/MIME-Nachricht (CRLF, UTF-8, quoted-printable für Text, Base64 für Anhänge).
/// Gleiche Bytes gehen per SMTP raus und landen per IMAP APPEND / JMAP Email/import in „Gesendet“.
enum MIMEBauer {
    static func bauen(_ n: AusgehendeNachricht, datum: Date = Date(), entwurf: Bool = false) -> Data {
        var kopf: [String] = []
        kopf.append("From: " + adressen([n.von]))
        if !n.an.isEmpty { kopf.append("To: " + adressen(n.an)) }
        if !n.kopie.isEmpty { kopf.append("Cc: " + adressen(n.kopie)) }
        // Bcc steht nur in Entwürfen im Kopf, sonst nur im Umschlag
        if entwurf && !n.blindkopie.isEmpty { kopf.append("Bcc: " + adressen(n.blindkopie)) }
        kopf.append("Subject: " + kodiereWort(n.betreff))
        kopf.append("Date: " + datumText(datum))
        kopf.append("Message-ID: " + n.messageID)
        if let irt = n.inReplyTo { kopf.append("In-Reply-To: " + irt) }
        if !n.referenzen.isEmpty { kopf.append("References: " + n.referenzen.joined(separator: " ")) }
        kopf.append("MIME-Version: 1.0")
        kopf.append("User-Agent: HomePost")

        let koerper: (header: [String], body: String)
        let textTeil = teil(typ: "text/plain; charset=utf-8", kodierung: "quoted-printable",
                            inhalt: quotedPrintable(n.text))
        var alternativ = textTeil
        if let html = n.html {
            let htmlTeil = teil(typ: "text/html; charset=utf-8", kodierung: "quoted-printable",
                                inhalt: quotedPrintable(html))
            alternativ = multipart("alternative", [textTeil, htmlTeil])
        }
        if n.anhaenge.isEmpty {
            koerper = alternativ
        } else {
            var teile = [alternativ]
            for a in n.anhaenge {
                let name = dateiname(a.name)
                teile.append((header: ["Content-Type: \(a.mimeTyp); \(name.typ)",
                                       "Content-Disposition: attachment; \(name.disp)",
                                       "Content-Transfer-Encoding: base64"],
                              body: a.daten.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])))
            }
            koerper = multipart("mixed", teile)
        }
        let alles = (kopf + koerper.header).joined(separator: "\r\n") + "\r\n\r\n" + koerper.body + "\r\n"
        return Data(alles.utf8)
    }

    // MARK: Teile

    private static func teil(typ: String, kodierung: String, inhalt: String) -> (header: [String], body: String) {
        (["Content-Type: \(typ)", "Content-Transfer-Encoding: \(kodierung)"], inhalt)
    }

    private static func multipart(_ art: String, _ teile: [(header: [String], body: String)]) -> (header: [String], body: String) {
        let grenze = "hp-\(art)-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20)
        var body = ""
        for t in teile {
            body += "--\(grenze)\r\n" + t.header.joined(separator: "\r\n") + "\r\n\r\n" + t.body + "\r\n"
        }
        body += "--\(grenze)--"
        return (["Content-Type: multipart/\(art); boundary=\"\(grenze)\""], body)
    }

    // MARK: Kodierungen

    static func datumText(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f.string(from: d)
    }

    static func adressen(_ liste: [MailAdresse]) -> String {
        liste.map { a in
            guard let name = a.name, !name.isEmpty else { return a.email }
            if name.unicodeScalars.allSatisfy({ $0.isASCII }) {
                let besonders = CharacterSet(charactersIn: "()<>[]:;@\\,.\"")
                let n = name.rangeOfCharacter(from: besonders) != nil
                    ? "\"" + name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
                    : name
                return "\(n) <\(a.email)>"
            }
            return "\(kodiereWort(name)) <\(a.email)>"
        }.joined(separator: ", ")
    }

    /// RFC 2047 „encoded word“ (Base64), nur wenn nötig; lange Texte in mehrere Wörter teilen.
    static func kodiereWort(_ s: String) -> String {
        if s.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 32 }) { return s }
        var woerter: [String] = []
        var stueck = ""
        for ch in s {
            if (stueck + String(ch)).utf8.count > 45 {
                woerter.append(stueck); stueck = ""
            }
            stueck.append(ch)
        }
        if !stueck.isEmpty { woerter.append(stueck) }
        return woerter.map { "=?UTF-8?B?" + Data($0.utf8).base64EncodedString() + "?=" }.joined(separator: "\r\n ")
    }

    private static func dateiname(_ name: String) -> (typ: String, disp: String) {
        if name.unicodeScalars.allSatisfy({ $0.isASCII }) && !name.contains("\"") {
            return ("name=\"\(name)\"", "filename=\"\(name)\"")
        }
        let erlaubt = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let prozent = name.addingPercentEncoding(withAllowedCharacters: erlaubt) ?? "datei"
        return ("name=\"\(kodiereWort(name))\"", "filename*=utf-8''\(prozent)")
    }

    /// Quoted-printable (RFC 2045), Zeilen max. 76 Zeichen, CRLF.
    static func quotedPrintable(_ text: String) -> String {
        let normal = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var zeilen: [String] = []
        for zeile in normal.split(separator: "\n", omittingEmptySubsequences: false) {
            var aus = ""
            var laenge = 0
            let bytes = Array(String(zeile).utf8)
            for (i, b) in bytes.enumerated() {
                let letztes = i == bytes.count - 1
                var stueck: String
                if (b >= 33 && b <= 126 && b != 61) || ((b == 32 || b == 9) && !letztes) {
                    stueck = String(UnicodeScalar(b))
                } else {
                    stueck = String(format: "=%02X", b)
                }
                if laenge + stueck.count > 75 {
                    aus += "=\r\n"; laenge = 0
                }
                aus += stueck; laenge += stueck.count
            }
            zeilen.append(aus)
        }
        return zeilen.joined(separator: "\r\n")
    }
}

/// Hilfen zum Zitieren beim Antworten/Weiterleiten (Texte wie Apple).
enum Zitat {
    static func antwortBetreff(_ s: String) -> String {
        let l = s.lowercased()
        return (l.hasPrefix("re:") || l.hasPrefix("aw:")) ? s : "Re: " + s
    }

    static func weiterleitenBetreff(_ s: String) -> String {
        let l = s.lowercased()
        return (l.hasPrefix("fwd:") || l.hasPrefix("wg:")) ? s : "Fwd: " + s
    }

    static func antwortText(original: String, von: MailAdresse?, datum: Date) -> String {
        let wann = datum.formatted(date: .long, time: .shortened)
        let wer = von?.formatiert ?? ""
        let einleitung = String(localized: "Am \(wann) schrieb \(wer):")
        let zitiert = original.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix(">") ? ">" + $0 : "> " + $0 }.joined(separator: "\n")
        return "\n\n" + einleitung + "\n\n" + zitiert
    }

    static func weiterleitenText(original: String, kopf: NachrichtKopf) -> String {
        let von = kopf.von.map(\.formatiert).joined(separator: ", ")
        let an = kopf.an.map(\.formatiert).joined(separator: ", ")
        let datum = kopf.datum.formatted(date: .long, time: .shortened)
        return "\n\n" + String(localized: "Anfang der weitergeleiteten E‑Mail:") + "\n\n"
            + String(localized: "Von:") + " \(von)\n"
            + String(localized: "Betreff:") + " \(kopf.betreff)\n"
            + String(localized: "Datum:") + " \(datum)\n"
            + String(localized: "An:") + " \(an)\n\n" + original
    }

    /// Sehr einfacher HTML→Text-Wandler für Zitate und Vorschauen.
    static func textAusHTML(_ html: String) -> String {
        var t = html
        for (muster, ersatz) in [("(?is)<(script|style|head)[^>]*>.*?</\\1>", ""), ("(?i)<br\\s*/?>", "\n"),
                                 ("(?i)</(p|div|h[1-6]|li|tr)>", "\n"), ("(?i)<li[^>]*>", "• "), ("<[^>]+>", "")] {
            t = t.replacingOccurrences(of: muster, with: ersatz, options: .regularExpression)
        }
        for (e, z) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"),
                       ("&auml;", "ä"), ("&ouml;", "ö"), ("&uuml;", "ü"), ("&Auml;", "Ä"), ("&Ouml;", "Ö"),
                       ("&Uuml;", "Ü"), ("&szlig;", "ß")] {
            t = t.replacingOccurrences(of: e, with: z)
        }
        t = t.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\n\\s*\\n\\s*\\n+", with: "\n\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
