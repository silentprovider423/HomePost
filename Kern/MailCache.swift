import Foundation
import SQLite3

/// Lokaler Speicher (SQLite im App-Container, Volltextindex FTS5): Liste sofort offline sichtbar,
/// lokale Suche ohne Server, Warteschlange für Aktionen ohne Netz.
actor MailCache {
    static let shared = MailCache()

    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let kodierer = JSONEncoder()
    private let dekodierer = JSONDecoder()

    init(pfad: URL? = nil) {
        let url = pfad ?? {
            let ordner = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appending(path: "HomePost", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true,
                                                     attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            return ordner.appending(path: "cache.sqlite")
        }()
        var handle: OpaquePointer?
        if sqlite3_open(url.path, &handle) == SQLITE_OK {
            db = handle
            for sql in [
                "PRAGMA journal_mode=WAL",
                "CREATE TABLE IF NOT EXISTS koepfe(konto TEXT, postfach TEXT, id TEXT, datum REAL, json BLOB, PRIMARY KEY(konto, postfach, id))",
                "CREATE VIRTUAL TABLE IF NOT EXISTS suche USING fts5(konto UNINDEXED, id UNINDEXED, betreff, von, vorschau, tokenize='unicode61 remove_diacritics 2')",
                "CREATE TABLE IF NOT EXISTS inhalte(konto TEXT, id TEXT, json BLOB, PRIMARY KEY(konto, id))",
                "CREATE TABLE IF NOT EXISTS warteschlange(nr INTEGER PRIMARY KEY AUTOINCREMENT, konto TEXT, json BLOB)",
            ] { sqlite3_exec(handle, sql, nil, nil, nil) }
        }
    }

    // MARK: Hilfen

    private func ausfuehren(_ sql: String, _ werte: [Any?] = [], zeile: (OpaquePointer) -> Void = { _ in }) {
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        for (i, w) in werte.enumerated() {
            let idx = Int32(i + 1)
            switch w {
            case let s as String: sqlite3_bind_text(stmt, idx, s, -1, transient)
            case let d as Double: sqlite3_bind_double(stmt, idx, d)
            case let n as Int: sqlite3_bind_int64(stmt, idx, Int64(n))
            case let data as Data: sqlite3_bind_blob(stmt, idx, (data as NSData).bytes, Int32(data.count), transient)
            default: sqlite3_bind_null(stmt, idx)
            }
        }
        while sqlite3_step(stmt) == SQLITE_ROW { zeile(stmt) }
    }

    private func blob(_ stmt: OpaquePointer, _ spalte: Int32) -> Data {
        guard let p = sqlite3_column_blob(stmt, spalte) else { return Data() }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, spalte)))
    }

    private func text(_ stmt: OpaquePointer, _ spalte: Int32) -> String {
        sqlite3_column_text(stmt, spalte).map { String(cString: $0) } ?? ""
    }

    // MARK: Köpfe

    /// Ersetzt den gespeicherten Stand eines Postfachs.
    func speichern(_ koepfe: [NachrichtKopf], konto: UUID, postfach: String) {
        let k = konto.uuidString
        ausfuehren("BEGIN")
        ausfuehren("DELETE FROM suche WHERE id IN (SELECT id FROM koepfe WHERE konto=? AND postfach=?) AND konto=?", [k, postfach, k])
        ausfuehren("DELETE FROM koepfe WHERE konto=? AND postfach=?", [k, postfach])
        for kopf in koepfe {
            guard let json = try? kodierer.encode(kopf) else { continue }
            ausfuehren("INSERT OR REPLACE INTO koepfe VALUES(?,?,?,?,?)", [k, postfach, kopf.id, kopf.datum.timeIntervalSince1970, json])
            ausfuehren("INSERT INTO suche VALUES(?,?,?,?,?)",
                       [k, kopf.id, kopf.betreff, kopf.von.map { "\($0.name ?? "") \($0.email)" }.joined(separator: " "), kopf.vorschau])
        }
        ausfuehren("COMMIT")
    }

    func laden(konto: UUID, postfach: String) -> [NachrichtKopf] {
        var liste: [NachrichtKopf] = []
        ausfuehren("SELECT json FROM koepfe WHERE konto=? AND postfach=? ORDER BY datum DESC", [konto.uuidString, postfach]) { s in
            if let k = try? self.dekodierer.decode(NachrichtKopf.self, from: self.blob(s, 0)) { liste.append(k) }
        }
        return liste
    }

    /// Lokale Volltextsuche (Betreff, Absender, Vorschau) – Präfixsuche je Wort.
    func suchen(_ text: String, konto: UUID?) -> [NachrichtKopf] {
        let woerter = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { "\"\($0)\"*" }
        guard !woerter.isEmpty else { return [] }
        let ausdruck = woerter.joined(separator: " ")
        var ids: [(String, String)] = []
        var sql = "SELECT konto, id FROM suche WHERE suche MATCH ?"
        var werte: [Any?] = [ausdruck]
        if let konto { sql += " AND konto=?"; werte.append(konto.uuidString) }
        ausfuehren(sql + " LIMIT 200", werte) { s in ids.append((self.text(s, 0), self.text(s, 1))) }
        var gefunden: [String: NachrichtKopf] = [:]
        for (k, id) in ids {
            ausfuehren("SELECT json FROM koepfe WHERE konto=? AND id=? LIMIT 1", [k, id]) { s in
                if let kopf = try? self.dekodierer.decode(NachrichtKopf.self, from: self.blob(s, 0)) { gefunden[kopf.id] = kopf }
            }
        }
        return gefunden.values.sorted { $0.datum > $1.datum }
    }

    // MARK: Inhalte

    func inhaltSpeichern(_ inhalt: NachrichtInhalt, konto: UUID, id: String) {
        var i = inhalt
        // große Anhänge nicht doppelt speichern
        i.anhangDaten = i.anhangDaten.filter { $0.value.count < 2_000_000 }
        guard let json = try? kodierer.encode(i) else { return }
        ausfuehren("INSERT OR REPLACE INTO inhalte VALUES(?,?,?)", [konto.uuidString, id, json])
    }

    func inhalt(konto: UUID, id: String) -> NachrichtInhalt? {
        var ergebnis: NachrichtInhalt?
        ausfuehren("SELECT json FROM inhalte WHERE konto=? AND id=?", [konto.uuidString, id]) { s in
            ergebnis = try? self.dekodierer.decode(NachrichtInhalt.self, from: self.blob(s, 0))
        }
        return ergebnis
    }

    // MARK: Warteschlange

    func einreihen(_ aktion: WartendeAktion) {
        guard let json = try? kodierer.encode(aktion) else { return }
        ausfuehren("INSERT INTO warteschlange(konto, json) VALUES(?,?)", [aktion.konto.uuidString, json])
    }

    func wartende() -> [(Int, WartendeAktion)] {
        var liste: [(Int, WartendeAktion)] = []
        ausfuehren("SELECT nr, json FROM warteschlange ORDER BY nr") { s in
            if let a = try? self.dekodierer.decode(WartendeAktion.self, from: self.blob(s, 1)) {
                liste.append((Int(sqlite3_column_int64(s, 0)), a))
            }
        }
        return liste
    }

    func erledigt(_ nr: Int) {
        ausfuehren("DELETE FROM warteschlange WHERE nr=?", [nr])
    }

    func kontoEntfernen(_ konto: UUID) {
        let k = konto.uuidString
        for t in ["koepfe", "suche", "inhalte", "warteschlange"] { ausfuehren("DELETE FROM \(t) WHERE konto=?", [k]) }
    }
}

/// Aktion, die ohne Netz nicht ausgeführt werden konnte und beim nächsten Abruf nachgeholt wird.
struct WartendeAktion: Codable, Sendable {
    enum Art: String, Codable, Sendable { case gelesen, ungelesen, markieren, entmarkieren, bewegen }
    var konto: UUID
    var art: Art
    var koepfe: [NachrichtKopf]
    var farbe: FahnenFarbe?
    var von: Postfach?
    var nach: Postfach?

    func ausfuehren(mit b: any MailBackend) async throws {
        switch art {
        case .gelesen: try await b.setzeGelesen(koepfe, true)
        case .ungelesen: try await b.setzeGelesen(koepfe, false)
        case .markieren: try await b.setzeMarkierung(koepfe, true, farbe: farbe)
        case .entmarkieren: try await b.setzeMarkierung(koepfe, false, farbe: nil)
        case .bewegen:
            if let von, let nach { try await b.bewegen(koepfe, von: von, nach: nach) }
        }
    }
}
