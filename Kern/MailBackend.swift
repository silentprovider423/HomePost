import Foundation

/// Gemeinsame Schnittstelle für JMAP und IMAP/SMTP. Die Oberfläche kennt nur dieses Protokoll
/// (wie bei Apple: Liste, Wischgeste, Aktionskarte und Hintergrundabruf rufen dieselben Aktionen auf).
protocol MailBackend: Sendable {
    var konto: KontoKonfiguration { get }

    /// Verbindung + Anmeldung prüfen (Account-Einrichtung, „Verbindung prüfen“).
    func pruefen() async throws

    func postfaecher() async throws -> [Postfach]
    /// Neueste Nachrichten eines Postfachs, neueste zuerst.
    func nachrichten(in postfach: Postfach, anzahl: Int) async throws -> [NachrichtKopf]
    /// Alle Nachrichten der Konversation (alle Postfächer), älteste zuerst.
    func konversation(zu kopf: NachrichtKopf) async throws -> [NachrichtKopf]
    func inhalt(von kopf: NachrichtKopf) async throws -> NachrichtInhalt
    func anhang(_ anhang: AnhangInfo, von kopf: NachrichtKopf) async throws -> Data
    /// Komplette Nachricht im RFC-5322-Format (Teilen als .eml, Weiterleiten als Anhang)
    func rohdaten(von kopf: NachrichtKopf) async throws -> Data
    func suchen(_ text: String, in postfach: Postfach?) async throws -> [NachrichtKopf]

    // Aktionen
    func setzeGelesen(_ koepfe: [NachrichtKopf], _ gelesen: Bool) async throws
    func setzeMarkierung(_ koepfe: [NachrichtKopf], _ markiert: Bool, farbe: FahnenFarbe?) async throws
    func setzeBeantwortet(_ kopf: NachrichtKopf, weitergeleitet: Bool) async throws
    /// Bewegen; liefert die neuen Köpfe (IMAP: neue UIDs) für „Widerrufen“.
    @discardableResult
    func bewegen(_ koepfe: [NachrichtKopf], von: Postfach, nach: Postfach) async throws -> [NachrichtKopf]
    func kopieren(_ koepfe: [NachrichtKopf], von: Postfach, nach: Postfach) async throws
    /// Endgültig löschen (im Papierkorb/Spam)
    func endgueltigLoeschen(_ koepfe: [NachrichtKopf], in postfach: Postfach) async throws

    // Postfächer verwalten
    func postfachAnlegen(name: String, in eltern: Postfach?) async throws
    func postfachUmbenennen(_ postfach: Postfach, in name: String) async throws
    func postfachLoeschen(_ postfach: Postfach) async throws

    // Versand
    func senden(_ nachricht: AusgehendeNachricht) async throws
    /// Entwurf sichern; ersetzt einen alten Entwurf. Liefert dessen neue ID (falls bekannt).
    @discardableResult
    func entwurfSichern(_ nachricht: AusgehendeNachricht, ersetzt alt: NachrichtKopf?) async throws -> String?
    func entwurfLoeschen(_ kopf: NachrichtKopf) async throws

    func trennen() async
}

extension MailBackend {
    /// Postfach mit Rolle suchen.
    func postfach(_ rolle: PostfachRolle, in liste: [Postfach]) -> Postfach? {
        liste.first { $0.rolle == rolle }
    }
}

/// Bildet für IMAP Konversationen aus Message-ID / In-Reply-To / References
/// (JMAP liefert threadId selbst). Fallback: gleicher Betreff ohne „Re:/AW:/Fwd:“.
enum KonversationsBauer {
    static func normalisierterBetreff(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        let praefixe = ["re:", "aw:", "fwd:", "fw:", "wg:", "antw:", "sv:", "vs:"]
        var geaendert = true
        while geaendert {
            geaendert = false
            for p in praefixe where t.lowercased().hasPrefix(p) {
                t = String(t.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
                geaendert = true
            }
        }
        return t.lowercased()
    }

    /// Weist jedem Kopf eine threadID zu: Wurzel = erste Referenz bzw. eigene Message-ID.
    static func zuordnen(_ koepfe: [NachrichtKopf]) -> [NachrichtKopf] {
        // Union-Find über Message-IDs
        var eltern: [String: String] = [:]
        func finde(_ x: String) -> String {
            var x = x
            while let p = eltern[x], p != x { x = p }
            return x
        }
        func vereine(_ a: String, _ b: String) {
            let ra = finde(a), rb = finde(b)
            if ra != rb { eltern[rb] = ra }
        }
        for k in koepfe {
            let eigene = k.messageID ?? "id:\(k.id)"
            if eltern[eigene] == nil { eltern[eigene] = eigene }
            for r in k.referenzen + k.inReplyTo {
                if eltern[r] == nil { eltern[r] = r }
                vereine(r, eigene)
            }
        }
        // Betreff-Fallback nur für Antworten ohne Referenzen
        var nachBetreff: [String: String] = [:]
        for k in koepfe.sorted(by: { $0.datum < $1.datum }) {
            let eigene = k.messageID ?? "id:\(k.id)"
            let b = normalisierterBetreff(k.betreff)
            guard !b.isEmpty else { continue }
            if let vorhanden = nachBetreff[b] {
                let istAntwort = k.betreff.lowercased() != b
                if istAntwort && k.referenzen.isEmpty && k.inReplyTo.isEmpty { vereine(vorhanden, eigene) }
            } else {
                nachBetreff[b] = eigene
            }
        }
        return koepfe.map { k in
            var k = k
            k.threadID = "t:" + finde(k.messageID ?? "id:\(k.id)")
            return k
        }
    }
}
