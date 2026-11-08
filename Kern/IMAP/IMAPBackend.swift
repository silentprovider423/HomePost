import Foundation
import SwiftMail

/// MailBackend über IMAP (Lesen/Ordner) + SMTP (Versand) mit SwiftMail (BSD-2).
/// Ein Actor = eine IMAP-Verbindung; Befehle laufen nacheinander (SELECT ist zustandsbehaftet).
actor IMAPBackend: MailBackend {
    nonisolated let konto: KontoKonfiguration
    private let passwort: String
    private var server: IMAPServer?
    private var postfachCache: [Postfach] = []
    private var trenner: String = "/"
    /// zuletzt geladene Köpfe je Postfach (für Konversationen über mehrere Ordner)
    private var kopfCache: [String: [NachrichtKopf]] = [:]
    /// Inhalte (IMAP lädt die ganze Nachricht einmal, Anhänge sind dann schon da)
    private var inhaltCache: [String: NachrichtInhalt] = [:]

    private static let trennzeichen: Character = "\u{1F}"

    init(konto: KontoKonfiguration, passwort: String) {
        self.konto = konto
        self.passwort = passwort
    }

    // MARK: Verbindung

    private var sicherheitIMAP: MailTransportSecurity {
        switch konto.sicherheit {
        case .tls: .implicitTLS
        case .starttls: .startTLS
        case .unverschluesselt: .plainText
        }
    }

    private func verbunden() async throws -> IMAPServer {
        if let server, await server.isConnected { return server }
        let s = IMAPServer(host: konto.imapHost, port: konto.imapPort, transportSecurity: sicherheitIMAP)
        do {
            try await s.connect()
            try await s.login(username: konto.benutzer, password: passwort)
        } catch {
            try? await s.disconnect()
            throw uebersetzen(error)
        }
        server = s
        return s
    }

    /// Führt einen Block aus; bei Verbindungsabbruch einmal neu verbinden.
    private func mit<T: Sendable>(_ block: (IMAPServer) async throws -> T) async throws -> T {
        do {
            return try await block(try await verbunden())
        } catch let f as MailFehler {
            throw f
        } catch {
            try? await server?.disconnect()
            server = nil
            do {
                return try await block(try await verbunden())
            } catch {
                throw uebersetzen(error)
            }
        }
    }

    private func uebersetzen(_ error: Error) -> Error {
        if error is MailFehler { return error }
        let text = String(describing: error)
        let klein = text.lowercased()
        if klein.contains("login") || klein.contains("auth") || klein.contains("credentials") { return MailFehler.anmeldung }
        if klein.contains("certificate") || klein.contains("handshake") || klein.contains("ssl") { return MailFehler.zertifikat }
        if klein.contains("connect") || klein.contains("timeout") || klein.contains("refused") {
            return MailFehler.verbindung(text)
        }
        return MailFehler.server(text)
    }

    func pruefen() async throws {
        try? await server?.disconnect()
        server = nil
        _ = try await verbunden()
        // SMTP ebenfalls prüfen
        let smtp = try await smtpVerbinden()
        try? await smtp.disconnect()
    }

    func trennen() async {
        try? await server?.disconnect()
        server = nil
    }

    // MARK: Postfächer

    func postfaecher() async throws -> [Postfach] {
        let infos = try await mit { try await $0.listMailboxes() }
        if let t = infos.compactMap(\.hierarchyDelimiter).first { trenner = t }
        var liste: [Postfach] = []
        for info in infos {
            var status: Mailbox.Status?
            if info.isSelectable {
                status = try? await mit { try await $0.mailboxStatus(info.name) }
            }
            let teile = info.name.components(separatedBy: info.hierarchyDelimiter ?? trenner)
            let eltern = teile.count > 1 ? teile.dropLast().joined(separator: info.hierarchyDelimiter ?? trenner) : nil
            liste.append(Postfach(id: info.name, name: teile.last ?? info.name, elternID: eltern,
                                  rolle: rolle(info), ungelesen: status?.unseenCount ?? 0,
                                  gesamt: status?.messageCount ?? 0, auswaehlbar: info.isSelectable))
        }
        postfachCache = PostfachOrdnung.ordnen(liste)
        return postfachCache
    }

    private func rolle(_ info: Mailbox.Info) -> PostfachRolle {
        let a = info.attributes
        if info.name.uppercased() == "INBOX" || a.contains(.inbox) { return .eingang }
        if a.contains(.drafts) { return .entwuerfe }
        if a.contains(.sent) { return .gesendet }
        if a.contains(.junk) { return .spam }
        if a.contains(.trash) { return .papierkorb }
        if a.contains(.archive) { return .archiv }
        // Server ohne SPECIAL-USE: übliche Namen
        switch info.name.lowercased() {
        case "drafts", "entwürfe": return .entwuerfe
        case "sent", "sent items", "sent messages", "gesendet": return .gesendet
        case "junk", "spam", "junk mail": return .spam
        case "trash", "deleted items", "papierkorb": return .papierkorb
        case "archive", "archiv": return .archiv
        default: return .keine
        }
    }

    private func rolle(_ r: PostfachRolle) async throws -> Postfach {
        if postfachCache.isEmpty { _ = try await postfaecher() }
        if let p = postfachCache.first(where: { $0.rolle == r }) { return p }
        if r == .archiv {
            try await mit { try await $0.createMailbox("Archive") }
            _ = try await postfaecher()
            if let p = postfachCache.first(where: { $0.rolle == r }) { return p }
        }
        throw MailFehler.keinPostfach(r)
    }

    // MARK: IDs

    static func id(pfad: String, uid: UInt32) -> String { "\(pfad)\(trennzeichen)\(uid)" }

    static func zerlegen(_ id: String) -> (pfad: String, uid: UID)? {
        guard let i = id.lastIndex(of: trennzeichen), let n = UInt32(id[id.index(after: i)...]) else { return nil }
        return (String(id[..<i]), UID(n))
    }

    private func gruppiert(_ koepfe: [NachrichtKopf]) -> [String: UIDSet] {
        var g: [String: [UID]] = [:]
        for k in koepfe {
            if let (p, u) = Self.zerlegen(k.id) { g[p, default: []].append(u) }
        }
        return g.mapValues { UIDSet($0) }
    }

    // MARK: Nachrichten

    func nachrichten(in postfach: Postfach, anzahl: Int) async throws -> [NachrichtKopf] {
        let koepfe = try await mit { s -> [NachrichtKopf] in
            let auswahl = try await s.selectMailbox(postfach.id)
            guard let menge = auswahl.latest(anzahl) else { return [] }
            let infos = try await s.fetchMessageInfosBulk(using: menge, options: .default)
            return try await self.umwandeln(infos, pfad: postfach.id, server: s)
        }
        let sortiert = KonversationsBauer.zuordnen(koepfe).sorted { $0.datum > $1.datum }
        kopfCache[postfach.id] = sortiert
        return sortiert
    }

    func suchen(_ text: String, in postfach: Postfach?) async throws -> [NachrichtKopf] {
        if postfachCache.isEmpty { _ = try await postfaecher() }
        let ziele = postfach.map { [$0] } ?? postfachCache.filter {
            $0.auswaehlbar && $0.rolle != .papierkorb && $0.rolle != .spam
        }
        var treffer: [NachrichtKopf] = []
        for p in ziele {
            let gefunden = try await mit { s -> [NachrichtKopf] in
                _ = try await s.selectMailbox(p.id)
                let r: ExtendedSearchResult<UID> = try await s.extendedSearch(criteria: [.text(text)])
                guard let alle = r.all, !alle.isEmpty else { return [] }
                let uids = Array(alle.toArray().suffix(50))
                let infos = try await s.fetchMessageInfosBulk(using: UIDSet(uids), options: .default)
                return try await self.umwandeln(infos, pfad: p.id, server: s)
            }
            treffer += gefunden
        }
        return KonversationsBauer.zuordnen(treffer).sorted { $0.datum > $1.datum }
    }

    func konversation(zu kopf: NachrichtKopf) async throws -> [NachrichtKopf] {
        if postfachCache.isEmpty { _ = try await postfaecher() }
        // Kandidaten: Ordner der Nachricht, Eingang, Gesendet, Archiv
        var pfade = Set([Self.zerlegen(kopf.id)?.pfad].compactMap { $0 })
        for r in [PostfachRolle.eingang, .gesendet, .archiv] {
            if let p = postfachCache.first(where: { $0.rolle == r }) { pfade.insert(p.id) }
        }
        var alle: [NachrichtKopf] = []
        for pfad in pfade {
            if let c = kopfCache[pfad] { alle += c; continue }
            if let p = postfachCache.first(where: { $0.id == pfad }) {
                alle += (try? await nachrichten(in: p, anzahl: 100)) ?? []
            }
        }
        if !alle.contains(where: { $0.id == kopf.id }) { alle.append(kopf) }
        // Doppelte (gleiche Message-ID in mehreren Ordnern) zusammenfassen, Original bevorzugen
        var gesehen: Set<String> = []
        var eindeutig: [NachrichtKopf] = []
        for k in alle.sorted(by: { a, _ in a.id == kopf.id }) {
            let schluessel = k.messageID ?? k.id
            if gesehen.insert(schluessel).inserted { eindeutig.append(k) }
        }
        let zugeordnet = KonversationsBauer.zuordnen(eindeutig)
        guard let ziel = zugeordnet.first(where: { $0.id == kopf.id })?.threadID else { return [kopf] }
        return zugeordnet.filter { $0.threadID == ziel }.sorted { $0.datum < $1.datum }
    }

    func inhalt(von kopf: NachrichtKopf) async throws -> NachrichtInhalt {
        if let c = inhaltCache[kopf.id] { return c }
        let roh = try await rohdaten(von: kopf)
        let m = try EMLParser.parse(roh)
        var anhaenge: [AnhangInfo] = []
        var daten: [String: Data] = [:]
        let cidTeile = m.cids
        let alle = m.attachments + cidTeile.filter { c in !m.attachments.contains { $0.section == c.section } }
        for teil in alle {
            let id = teil.section.description
            let d = teil.decodedData() ?? Data()
            daten[id] = d
            let cid = teil.contentId?.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            anhaenge.append(AnhangInfo(id: id, name: teil.suggestedFilename, mimeTyp: teil.contentType,
                                       groesse: d.count, contentID: cid,
                                       eingebettet: cid != nil && (teil.disposition?.lowercased() != "attachment")))
        }
        var kopfzeilen: [String: String] = [:]
        for (k, v) in m.header.additionalFields ?? [:] {
            switch k.lowercased() {
            case "list-unsubscribe": kopfzeilen["List-Unsubscribe"] = v
            case "authentication-results": kopfzeilen["Authentication-Results"] = v
            default: break
            }
        }
        var text = m.textBody
        if text == nil, let h = m.htmlBody { text = Zitat.textAusHTML(h) }
        let ergebnis = NachrichtInhalt(html: m.htmlBody, text: text, anhaenge: anhaenge, anhangDaten: daten,
                                       kopfzeilen: kopfzeilen)
        inhaltCache[kopf.id] = ergebnis
        if inhaltCache.count > 60 { inhaltCache.removeAll() }
        return ergebnis
    }

    func anhang(_ anhang: AnhangInfo, von kopf: NachrichtKopf) async throws -> Data {
        let i = try await inhalt(von: kopf)
        guard let d = i.anhangDaten[anhang.id] else { throw MailFehler.nichtGefunden }
        return d
    }

    func rohdaten(von kopf: NachrichtKopf) async throws -> Data {
        guard let (pfad, uid) = Self.zerlegen(kopf.id) else { throw MailFehler.nichtGefunden }
        return try await mit { s in
            _ = try await s.selectMailbox(pfad)
            return try await s.fetchRawMessage(identifier: uid)
        }
    }

    // MARK: Umwandlung

    private func umwandeln(_ infos: [MessageInfo], pfad: String, server s: IMAPServer) async throws -> [NachrichtKopf] {
        // Vorschau: ersten Textteil jeder Nachricht in einem Rutsch holen
        var vorschauTeile: [(uid: UID, section: Section)] = []
        var teilFuerUID: [UInt32: MessagePart] = [:]
        for info in infos {
            guard let uid = info.uid else { continue }
            let text = info.parts.first { p in
                let t = p.contentType.lowercased()
                return (t.hasPrefix("text/plain") || t.hasPrefix("text/html")) && p.disposition?.lowercased() != "attachment"
            }
            if let text, (text.size ?? 0) < 400_000 {
                vorschauTeile.append((uid, text.section))
                teilFuerUID[uid.value] = text
            }
        }
        var vorschau: [UInt32: String] = [:]
        if !vorschauTeile.isEmpty, let geholt = try? await s.fetchPartsPipelined(parts: vorschauTeile) {
            for (uid, liste) in geholt {
                guard var teil = teilFuerUID[uid.value], let d = liste.first?.data else { continue }
                teil.data = d
                var t = teil.textContent ?? ""
                if teil.contentType.lowercased().hasPrefix("text/html") { t = Zitat.textAusHTML(t) }
                vorschau[uid.value] = Self.vorschauText(t)
            }
        }
        return infos.compactMap { info in
            guard let uid = info.uid else { return nil }
            let flags = info.flags
            var schluessel: Set<String> = []
            var gelesen = false, markiert = false, beantwortet = false, entwurf = false
            for f in flags {
                switch f {
                case .seen: gelesen = true
                case .flagged: markiert = true
                case .answered: beantwortet = true
                case .draft: entwurf = true
                case .custom(let n): schluessel.insert(n)
                default: break
                }
            }
            func adressen(_ e: [AddressListEntry]) -> [MailAdresse] {
                e.flatMap { eintrag -> [MailAdresse] in
                    switch eintrag {
                    case .mailbox(let a): return [MailAdresse(name: a.name, email: a.address)]
                    case .group(_, let m): return m.map { MailAdresse(name: $0.name, email: $0.address) }
                    case .invalid: return []
                    }
                }
            }
            let felder = Dictionary((info.additionalFields ?? [:]).map { ($0.key.lowercased(), $0.value) },
                                    uniquingKeysWith: { a, _ in a })
            let referenzen = (info.references?.map(\.description))
                ?? (felder["references"].map { $0.split(whereSeparator: \.isWhitespace).map(String.init) } ?? [])
            let anhang = info.parts.contains { p in
                p.disposition?.lowercased() == "attachment" || (!(p.filename ?? "").isEmpty && p.contentId == nil)
            }
            return NachrichtKopf(
                id: Self.id(pfad: pfad, uid: uid.value), kontoID: konto.id, postfachIDs: [pfad],
                threadID: info.messageId?.description ?? "\(uid.value)", von: adressen(info.fromAddresses),
                an: adressen(info.toAddresses), kopie: adressen(info.ccAddresses), blindkopie: adressen(info.bccAddresses),
                antwortAn: adressen(info.replyToAddresses), betreff: info.subject ?? "",
                vorschau: vorschau[uid.value] ?? "", datum: info.internalDate ?? info.date ?? Date(),
                gelesen: gelesen, markiert: markiert, fahne: FahnenFarbe(schluesselwoerter: schluessel),
                beantwortet: beantwortet, weitergeleitet: schluessel.contains { $0.lowercased() == "$forwarded" },
                entwurf: entwurf, hatAnhang: anhang, groesse: info.size ?? 0,
                messageID: info.messageId?.description, inReplyTo: info.inReplyTo.map { [$0.description] } ?? [],
                referenzen: referenzen, istListe: felder["list-unsubscribe"] != nil)
        }
    }

    static func vorschauText(_ t: String) -> String {
        // zitierte Zeilen und Leerraum entfernen, wie Apples Vorschau
        let zeilen = t.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix(">") && !$0.isEmpty }
        return String(zeilen.joined(separator: " ").prefix(220))
    }

    // MARK: Aktionen

    private enum Op: Sendable { case add, remove }

    private func flags(_ koepfe: [NachrichtKopf], _ f: [Flag], _ op: Op) async throws {
        for (pfad, menge) in gruppiert(koepfe) where !f.isEmpty {
            try await mit { s in
                _ = try await s.selectMailbox(pfad)
                try await s.store(flags: f, on: menge, operation: op == .add ? .add : .remove)
            }
        }
        inhaltCache.removeAll()
    }

    func setzeGelesen(_ koepfe: [NachrichtKopf], _ gelesen: Bool) async throws {
        try await flags(koepfe, [.seen], gelesen ? .add : .remove)
    }

    func setzeMarkierung(_ koepfe: [NachrichtKopf], _ markiert: Bool, farbe: FahnenFarbe?) async throws {
        let bits = FahnenFarbe.bitSchluessel.map { Flag.custom($0) }
        if markiert {
            let setzen = Set((farbe ?? .rot).gesetzteBits)
            try await flags(koepfe, [.flagged] + FahnenFarbe.bitSchluessel.filter { setzen.contains($0) }.map { .custom($0) }, .add)
            try await flags(koepfe, FahnenFarbe.bitSchluessel.filter { !setzen.contains($0) }.map { .custom($0) }, .remove)
        } else {
            try await flags(koepfe, [.flagged] + bits, .remove)
        }
    }

    func setzeBeantwortet(_ kopf: NachrichtKopf, weitergeleitet: Bool) async throws {
        try await flags([kopf], [weitergeleitet ? .custom("$Forwarded") : .answered], .add)
    }

    @discardableResult
    func bewegen(_ koepfe: [NachrichtKopf], von: Postfach, nach: Postfach) async throws -> [NachrichtKopf] {
        var neu: [NachrichtKopf] = []
        for (pfad, menge) in gruppiert(koepfe) {
            let abbildung = try await mit { s -> [UInt32: UInt32] in
                _ = try await s.selectMailbox(pfad)
                let c = try await s.move(messages: menge, to: nach.id)
                return Dictionary(uniqueKeysWithValues: (c?.mapping ?? []).map { ($0.source.value, $0.destination.value) })
            }
            for k in koepfe {
                guard let (p, u) = Self.zerlegen(k.id), p == pfad else { continue }
                var n = k
                if let ziel = abbildung[u.value] { n.id = Self.id(pfad: nach.id, uid: ziel) }
                n.postfachIDs = [nach.id]
                neu.append(n)
            }
        }
        kopfCache[von.id]?.removeAll { k in koepfe.contains { $0.id == k.id } }
        kopfCache[nach.id] = nil
        return neu
    }

    func kopieren(_ koepfe: [NachrichtKopf], von: Postfach, nach: Postfach) async throws {
        for (pfad, menge) in gruppiert(koepfe) {
            try await mit { s in
                _ = try await s.selectMailbox(pfad)
                _ = try await s.copy(messages: menge, to: nach.id)
            }
        }
        kopfCache[nach.id] = nil
    }

    func endgueltigLoeschen(_ koepfe: [NachrichtKopf], in postfach: Postfach) async throws {
        for (pfad, menge) in gruppiert(koepfe) {
            try await mit { s in
                _ = try await s.selectMailbox(pfad)
                try await s.store(flags: [.deleted], on: menge, operation: .add)
                if await s.supportsUIDPlus { try await s.expunge(messages: menge) } else { try await s.expunge() }
            }
        }
        kopfCache[postfach.id]?.removeAll { k in koepfe.contains { $0.id == k.id } }
    }

    // MARK: Postfächer verwalten

    func postfachAnlegen(name: String, in eltern: Postfach?) async throws {
        let pfad = eltern.map { $0.id + trenner + name } ?? name
        try await mit { try await $0.createMailbox(pfad) }
    }

    func postfachUmbenennen(_ postfach: Postfach, in name: String) async throws {
        let neu = postfach.elternID.map { $0 + trenner + name } ?? name
        try await mit { s in
            try? await s.unselectMailbox()
            try await s.renameMailbox(postfach.id, to: neu)
        }
    }

    func postfachLoeschen(_ postfach: Postfach) async throws {
        try await mit { s in
            try? await s.unselectMailbox()
            try await s.deleteMailbox(postfach.id)
        }
    }

    // MARK: Versand

    private func smtpVerbinden() async throws -> SMTPServer {
        let sicherheit: MailTransportSecurity = switch konto.sicherheit {
        case .tls: .implicitTLS
        case .starttls: .startTLS
        case .unverschluesselt: .plainText
        }
        let smtp = SMTPServer(host: konto.smtpHost, port: konto.smtpPort, transportSecurity: sicherheit)
        do {
            try await smtp.connect()
            try await smtp.login(username: konto.benutzer, password: passwort)
        } catch {
            try? await smtp.disconnect()
            throw uebersetzen(error)
        }
        return smtp
    }

    func senden(_ n: AusgehendeNachricht) async throws {
        let roh = MIMEBauer.bauen(n)
        let smtp = try await smtpVerbinden()
        do {
            _ = try await smtp.sendRawMessage(roh, from: EmailAddress(name: n.von.name, address: n.von.email),
                                              to: n.alleEmpfaenger.map { EmailAddress(name: $0.name, address: $0.email) })
            try? await smtp.disconnect()
        } catch {
            try? await smtp.disconnect()
            throw uebersetzen(error)
        }
        // Kopie in „Gesendet“ (normales IMAP legt sie nicht selbst ab)
        if let gesendet = try? await rolle(.gesendet) {
            _ = try? await mit { try await $0.append(rawMessage: String(decoding: roh, as: UTF8.self), to: gesendet.id, flags: [.seen], internalDate: Date()) }
            kopfCache[gesendet.id] = nil
        }
    }

    @discardableResult
    func entwurfSichern(_ n: AusgehendeNachricht, ersetzt alt: NachrichtKopf?) async throws -> String? {
        let entwuerfe = try await rolle(.entwuerfe)
        let r = try await mit {
            try await $0.append(rawMessage: String(decoding: MIMEBauer.bauen(n, entwurf: true), as: UTF8.self), to: entwuerfe.id,
                                flags: [.draft, .seen], internalDate: Date())
        }
        if let alt { try? await endgueltigLoeschen([alt], in: entwuerfe) }
        kopfCache[entwuerfe.id] = nil
        return r.firstUID.map { Self.id(pfad: entwuerfe.id, uid: $0.value) }
    }

    func entwurfLoeschen(_ kopf: NachrichtKopf) async throws {
        let entwuerfe = try await rolle(.entwuerfe)
        try await endgueltigLoeschen([kopf], in: entwuerfe)
    }
}
