import Foundation

// MARK: - Konto

/// Welches Protokoll ein Konto spricht. JMAP wird bevorzugt, wenn der Server es anbietet.
enum MailProtokoll: String, Codable, Sendable, CaseIterable {
    case jmap, imap
}

/// Transportsicherheit für IMAP/SMTP. `.unverschluesselt` nur für Testserver im Heimnetz.
enum Verschluesselung: String, Codable, Sendable, CaseIterable {
    case tls          // implizites TLS (993/465)
    case starttls     // STARTTLS (143/587)
    case unverschluesselt
}

/// Nicht geheime Einstellungen eines Kontos. Das Passwort liegt im Schlüsselbund.
struct KontoKonfiguration: Codable, Sendable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String               // Anzeigename des Kontos („Privat“)
    var vollerName: String         // Absendername
    var adresse: String            // E-Mail-Adresse
    var benutzer: String           // Anmeldename
    var protokoll: MailProtokoll
    /// JMAP: Basis-URL (z. B. https://mail.example.com)
    var jmapURL: String = ""
    var imapHost: String = ""
    var imapPort: Int = 993
    var smtpHost: String = ""
    var smtpPort: Int = 465
    var sicherheit: Verschluesselung = .tls
    var signatur: String? = nil

    var istUnverschluesselt: Bool {
        switch protokoll {
        case .jmap: return jmapURL.lowercased().hasPrefix("http://")
        case .imap: return sicherheit == .unverschluesselt
        }
    }
}

// MARK: - Postfächer

/// Sonderrolle eines Postfachs (RFC 6154 / RFC 8621).
enum PostfachRolle: String, Codable, Sendable, CaseIterable {
    case eingang, entwuerfe, gesendet, spam, papierkorb, archiv, keine

    /// Reihenfolge wie bei Apple: Eingang, Entwürfe, Gesendet, Spam, Papierkorb, Archiv, dann eigene.
    var sortierung: Int {
        switch self {
        case .eingang: 0
        case .entwuerfe: 1
        case .gesendet: 2
        case .spam: 3
        case .papierkorb: 4
        case .archiv: 5
        case .keine: 10
        }
    }

    init(jmap: String?) {
        switch jmap?.lowercased() {
        case "inbox": self = .eingang
        case "drafts": self = .entwuerfe
        case "sent": self = .gesendet
        case "junk": self = .spam
        case "trash": self = .papierkorb
        case "archive": self = .archiv
        default: self = .keine
        }
    }

    var jmapName: String? {
        switch self {
        case .eingang: "inbox"
        case .entwuerfe: "drafts"
        case .gesendet: "sent"
        case .spam: "junk"
        case .papierkorb: "trash"
        case .archiv: "archive"
        case .keine: nil
        }
    }
}

struct Postfach: Codable, Sendable, Identifiable, Hashable {
    /// JMAP: Mailbox-ID; IMAP: voller Pfad
    var id: String
    var name: String
    var elternID: String?
    var rolle: PostfachRolle
    var ungelesen: Int
    var gesamt: Int
    /// Verschachtelungstiefe (0 = oberste Ebene)
    var tiefe: Int = 0
    var auswaehlbar: Bool = true
}

// MARK: - Adressen

struct MailAdresse: Codable, Sendable, Hashable {
    var name: String?
    var email: String

    var anzeige: String {
        if let name, !name.isEmpty { return name }
        return email
    }

    /// „Name <adresse>“ für Header (RFC 5322); MIME-Kodierung macht der MIME-Bauer.
    var formatiert: String {
        if let name, !name.isEmpty { return "\(name) <\(email)>" }
        return email
    }

    /// Liest „Name <a@b>“, „a@b“ oder „"Name" <a@b>“.
    static func lesen(_ text: String) -> MailAdresse? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if let lt = t.lastIndex(of: "<"), let gt = t.lastIndex(of: ">"), lt < gt {
            let mail = String(t[t.index(after: lt)..<gt]).trimmingCharacters(in: .whitespaces)
            var name = String(t[..<lt]).trimmingCharacters(in: .whitespaces)
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return mail.contains("@") ? MailAdresse(name: name.isEmpty ? nil : name, email: mail) : nil
        }
        return t.contains("@") ? MailAdresse(name: nil, email: t) : nil
    }

    /// Liste aus „a@b, Name <c@d>; e@f“
    static func liste(_ text: String) -> [MailAdresse] {
        var teile: [String] = []
        var aktuell = ""
        var inAnf = false, inSpitz = false
        for ch in text {
            if ch == "\"" { inAnf.toggle() }
            if ch == "<" { inSpitz = true }
            if ch == ">" { inSpitz = false }
            if (ch == "," || ch == ";") && !inAnf && !inSpitz {
                teile.append(aktuell); aktuell = ""
            } else {
                aktuell.append(ch)
            }
        }
        teile.append(aktuell)
        return teile.compactMap(lesen)
    }
}

// MARK: - Fahnenfarben

/// Apples sieben Fahnenfarben, gespeichert als Schlüsselwörter $MailFlagBit0–2 neben \Flagged.
enum FahnenFarbe: Int, Codable, Sendable, CaseIterable {
    case rot = 0, orange, gelb, gruen, blau, lila, grau

    static let bitSchluessel = ["$MailFlagBit0", "$MailFlagBit1", "$MailFlagBit2"]

    /// Farbe aus vorhandenen Schlüsselwörtern (Groß-/Kleinschreibung egal).
    init(schluesselwoerter: Set<String>) {
        let klein = Set(schluesselwoerter.map { $0.lowercased() })
        var wert = 0
        for (i, s) in Self.bitSchluessel.enumerated() where klein.contains(s.lowercased()) {
            wert |= 1 << i
        }
        self = FahnenFarbe(rawValue: wert) ?? .rot
    }

    /// Schlüsselwörter, die für diese Farbe gesetzt sein müssen.
    var gesetzteBits: [String] {
        Self.bitSchluessel.enumerated().filter { rawValue & (1 << $0.offset) != 0 }.map(\.element)
    }
}

// MARK: - Nachrichten

struct NachrichtKopf: Codable, Sendable, Identifiable, Hashable {
    /// Eindeutig im Konto. JMAP: Email-ID; IMAP: „Pfad\u{1F}UID“
    var id: String
    var kontoID: UUID
    var postfachIDs: [String]
    var threadID: String
    var von: [MailAdresse]
    var an: [MailAdresse]
    var kopie: [MailAdresse]
    var blindkopie: [MailAdresse] = []
    var antwortAn: [MailAdresse] = []
    var betreff: String
    var vorschau: String
    var datum: Date
    var gelesen: Bool
    var markiert: Bool
    var fahne: FahnenFarbe = .rot
    var beantwortet: Bool = false
    var weitergeleitet: Bool = false
    var entwurf: Bool = false
    var hatAnhang: Bool
    var groesse: Int = 0
    var messageID: String?
    var inReplyTo: [String] = []
    var referenzen: [String] = []
    /// List-Unsubscribe vorhanden (Newsletter)
    var istListe: Bool = false

    var absender: MailAdresse? { von.first }
}

struct AnhangInfo: Codable, Sendable, Identifiable, Hashable {
    /// JMAP: blobId; IMAP: Abschnitt (z. B. „2“) – beim IMAP-Laden sind die Daten schon da
    var id: String
    var name: String
    var mimeTyp: String
    var groesse: Int
    var contentID: String?
    var eingebettet: Bool
}

struct NachrichtInhalt: Codable, Sendable {
    var html: String?
    var text: String?
    var anhaenge: [AnhangInfo]
    /// Bereits geladene Daten (IMAP lädt die ganze Nachricht auf einmal)
    var anhangDaten: [String: Data] = [:]
    var kopfzeilen: [String: String] = [:]
}

/// Datei, die beim Verfassen angehängt wird.
struct AusgehenderAnhang: Codable, Sendable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var mimeTyp: String
    var daten: Data
}

struct AusgehendeNachricht: Codable, Sendable {
    var von: MailAdresse
    var an: [MailAdresse]
    var kopie: [MailAdresse] = []
    var blindkopie: [MailAdresse] = []
    var betreff: String
    var text: String
    var html: String? = nil
    var anhaenge: [AusgehenderAnhang] = []
    var inReplyTo: String? = nil
    var referenzen: [String] = []
    var messageID: String = AusgehendeNachricht.neueMessageID(domain: "homepost.invalid")

    var alleEmpfaenger: [MailAdresse] { an + kopie + blindkopie }

    static func neueMessageID(domain: String) -> String {
        "<\(UUID().uuidString.lowercased())@\(domain)>"
    }
}

// MARK: - Fehler

enum MailFehler: LocalizedError, Sendable {
    case anmeldung
    case verbindung(String)
    case server(String)
    case zertifikat
    case nichtGefunden
    case keinPostfach(PostfachRolle)

    var errorDescription: String? {
        switch self {
        case .anmeldung:
            String(localized: "Benutzername oder Passwort ist falsch.")
        case .verbindung(let t):
            String(localized: "Keine Verbindung zum Server: \(t)")
        case .server(let t):
            String(localized: "Der Server meldet: \(t)")
        case .zertifikat:
            String(localized: "Die Identität des Servers kann nicht überprüft werden. Für einen Testserver im Heimnetz „Unverschlüsselt (nur Heimnetz)“ wählen.")
        case .nichtGefunden:
            String(localized: "Die E‑Mail wurde nicht gefunden.")
        case .keinPostfach(let r):
            String(localized: "Auf dem Server fehlt das Postfach „\(r.rawValue)“.")
        }
    }
}
