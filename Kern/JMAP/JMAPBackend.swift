import Foundation

/// MailBackend über JMAP (bevorzugt, wenn der Server es kann – z. B. Stalwart).
actor JMAPBackend: MailBackend {
    nonisolated let konto: KontoKonfiguration
    let client: JMAPClient
    private var postfachCache: [Postfach] = []
    private var identitaetID: String?

    static let kopfEigenschaften: [String] = [
        "id", "threadId", "mailboxIds", "keywords", "from", "to", "cc", "bcc", "replyTo", "subject",
        "receivedAt", "preview", "hasAttachment", "size", "messageId", "inReplyTo", "references",
        "header:List-Unsubscribe:asURLs",
    ]

    init(konto: KontoKonfiguration, passwort: String) throws {
        guard let url = URL(string: konto.jmapURL.trimmingCharacters(in: .whitespaces)) else {
            throw MailFehler.verbindung(String(localized: "Ungültige Serveradresse"))
        }
        self.konto = konto
        self.client = JMAPClient(basis: url, benutzer: konto.benutzer, passwort: passwort)
    }

    func pruefen() async throws {
        let s = try await client.holeSitzung(neu: true)
        guard s.faehigkeiten.contains("urn:ietf:params:jmap:mail") else {
            throw MailFehler.server(String(localized: "Der Server bietet kein JMAP Mail an."))
        }
    }

    func trennen() async {}

    // MARK: Postfächer

    func postfaecher() async throws -> [Postfach] {
        let r = try await client.einzeln("Mailbox/get", [
            "properties": .strings(["id", "name", "parentId", "role", "totalEmails", "unreadEmails", "sortOrder"]),
        ])
        let liste = r["list"].array.map { m in
            Postfach(id: m["id"].string ?? "", name: m["name"].string ?? "", elternID: m["parentId"].string,
                     rolle: PostfachRolle(jmap: m["role"].string), ungelesen: m["unreadEmails"].int ?? 0,
                     gesamt: m["totalEmails"].int ?? 0)
        }
        postfachCache = PostfachOrdnung.ordnen(liste)
        return postfachCache
    }

    private func rolle(_ r: PostfachRolle) async throws -> Postfach {
        if postfachCache.isEmpty { _ = try await postfaecher() }
        if let p = postfachCache.first(where: { $0.rolle == r }) { return p }
        if r == .archiv {
            // Fehlt „Archiv“, wie Apple ein Postfach „Archive“ anlegen
            _ = try await client.einzeln("Mailbox/set", ["create": ["a": ["name": "Archive", "role": "archive"]]])
            _ = try await postfaecher()
            if let p = postfachCache.first(where: { $0.rolle == r }) { return p }
        }
        throw MailFehler.keinPostfach(r)
    }

    // MARK: Nachrichten

    func nachrichten(in postfach: Postfach, anzahl: Int) async throws -> [NachrichtKopf] {
        try await abfragen(filter: ["inMailbox": .text(postfach.id)], anzahl: anzahl)
    }

    func suchen(_ text: String, in postfach: Postfach?) async throws -> [NachrichtKopf] {
        var filter: [String: JSONWert] = ["text": .text(text)]
        if let postfach { filter["inMailbox"] = .text(postfach.id) }
        return try await abfragen(filter: filter, anzahl: 100)
    }

    private func abfragen(filter: [String: JSONWert], anzahl: Int) async throws -> [NachrichtKopf] {
        let r = try await client.aufruf([
            ("Email/query", ["filter": .objekt(filter),
                             "sort": [["property": "receivedAt", "isAscending": false]],
                             "limit": .zahl(Double(anzahl))]),
            ("Email/get", ["#ids": ["resultOf": "c0", "name": "Email/query", "path": "/ids"],
                           "properties": .strings(Self.kopfEigenschaften)]),
        ])
        let koepfe = r[1]["list"].array.compactMap(kopfAus)
        // Reihenfolge der Abfrage beibehalten
        let reihenfolge = r[0]["ids"].array.compactMap(\.string)
        let index = Dictionary(uniqueKeysWithValues: koepfe.map { ($0.id, $0) })
        return reihenfolge.compactMap { index[$0] }
    }

    func konversation(zu kopf: NachrichtKopf) async throws -> [NachrichtKopf] {
        let r = try await client.aufruf([
            ("Thread/get", ["ids": .strings([kopf.threadID])]),
            ("Email/get", ["#ids": ["resultOf": "c0", "name": "Thread/get", "path": "/list/*/emailIds"],
                           "properties": .strings(Self.kopfEigenschaften)]),
        ])
        if postfachCache.isEmpty { _ = try await postfaecher() }
        let ausgeschlossen = Set(postfachCache.filter { $0.rolle == .papierkorb || $0.rolle == .spam }.map(\.id))
        let alle = r[1]["list"].array.compactMap(kopfAus)
        let gefiltert = alle.filter { k in
            k.id == kopf.id || !Set(k.postfachIDs).isSubset(of: ausgeschlossen)
        }
        return (gefiltert.isEmpty ? [kopf] : gefiltert).sorted { $0.datum < $1.datum }
    }

    func inhalt(von kopf: NachrichtKopf) async throws -> NachrichtInhalt {
        let r = try await client.einzeln("Email/get", [
            "ids": .strings([kopf.id]),
            "properties": .strings(["id", "bodyValues", "htmlBody", "textBody", "attachments",
                                    "header:List-Unsubscribe:asURLs", "header:Authentication-Results:asRaw"]),
            "fetchHTMLBodyValues": true, "fetchTextBodyValues": true, "maxBodyValueBytes": 2_000_000,
        ])
        guard let e = r["list"].array.first else { throw MailFehler.nichtGefunden }
        let werte = e["bodyValues"].dict
        func zusammen(_ teile: [JSONWert], typ: String) -> String? {
            let t = teile.filter { ($0["type"].string ?? "").lowercased() == typ }
                .compactMap { werte[$0["partId"].string ?? ""]?["value"].string }
            return t.isEmpty ? nil : t.joined(separator: typ == "text/html" ? "<hr>" : "\n\n")
        }
        let html = zusammen(e["htmlBody"].array, typ: "text/html")
        let text = zusammen(e["textBody"].array, typ: "text/plain") ?? html.map(Zitat.textAusHTML)
        let anhaenge = e["attachments"].array.map { a in
            AnhangInfo(id: a["blobId"].string ?? "", name: a["name"].string ?? String(localized: "Anhang"),
                       mimeTyp: a["type"].string ?? "application/octet-stream", groesse: a["size"].int ?? 0,
                       contentID: a["cid"].string,
                       eingebettet: (a["disposition"].string ?? "") == "inline" && a["cid"].string != nil)
        }
        var kopfzeilen: [String: String] = [:]
        let abmelden = e["header:List-Unsubscribe:asURLs"].array.compactMap(\.string)
        if !abmelden.isEmpty { kopfzeilen["List-Unsubscribe"] = abmelden.map { "<\($0)>" }.joined(separator: ", ") }
        if let s = e["header:Authentication-Results:asRaw"].string { kopfzeilen["Authentication-Results"] = s.trimmingCharacters(in: .whitespacesAndNewlines) }
        return NachrichtInhalt(html: html, text: text, anhaenge: anhaenge, kopfzeilen: kopfzeilen)
    }

    func anhang(_ anhang: AnhangInfo, von kopf: NachrichtKopf) async throws -> Data {
        try await client.herunterladen(blobID: anhang.id, name: anhang.name, typ: anhang.mimeTyp)
    }

    func rohdaten(von kopf: NachrichtKopf) async throws -> Data {
        let r = try await client.einzeln("Email/get", ["ids": .strings([kopf.id]), "properties": .strings(["blobId"])])
        guard let blob = r["list"][0]["blobId"].string else { throw MailFehler.nichtGefunden }
        return try await client.herunterladen(blobID: blob, name: "nachricht.eml", typ: "message/rfc822")
    }

    // MARK: Aktionen

    private func aendern(_ koepfe: [NachrichtKopf], _ patch: [String: JSONWert]) async throws {
        guard !koepfe.isEmpty else { return }
        var update: [String: JSONWert] = [:]
        for k in koepfe { update[k.id] = .objekt(patch) }
        let r = try await client.einzeln("Email/set", ["update": .objekt(update)])
        if let fehler = r["notUpdated"].dict.values.first {
            throw MailFehler.server(fehler["description"].string ?? fehler["type"].string ?? "Email/set")
        }
    }

    func setzeGelesen(_ koepfe: [NachrichtKopf], _ gelesen: Bool) async throws {
        try await aendern(koepfe, ["keywords/$seen": gelesen ? true : nil])
    }

    func setzeMarkierung(_ koepfe: [NachrichtKopf], _ markiert: Bool, farbe: FahnenFarbe?) async throws {
        var patch: [String: JSONWert] = ["keywords/$flagged": markiert ? true : nil]
        let bits = markiert ? Set((farbe ?? .rot).gesetzteBits) : []
        for b in FahnenFarbe.bitSchluessel { patch["keywords/\(b)"] = bits.contains(b) ? true : nil }
        try await aendern(koepfe, patch)
    }

    func setzeBeantwortet(_ kopf: NachrichtKopf, weitergeleitet: Bool) async throws {
        try await aendern([kopf], [weitergeleitet ? "keywords/$forwarded" : "keywords/$answered": true])
    }

    @discardableResult
    func bewegen(_ koepfe: [NachrichtKopf], von: Postfach, nach: Postfach) async throws -> [NachrichtKopf] {
        try await aendern(koepfe, ["mailboxIds/\(von.id)": nil, "mailboxIds/\(nach.id)": true])
        return koepfe.map { k in
            var k = k
            k.postfachIDs = k.postfachIDs.filter { $0 != von.id } + [nach.id]
            return k
        }
    }

    func kopieren(_ koepfe: [NachrichtKopf], von: Postfach, nach: Postfach) async throws {
        try await aendern(koepfe, ["mailboxIds/\(nach.id)": true])
    }

    func endgueltigLoeschen(_ koepfe: [NachrichtKopf], in postfach: Postfach) async throws {
        _ = try await client.einzeln("Email/set", ["destroy": .strings(koepfe.map(\.id))])
    }

    // MARK: Postfächer verwalten

    func postfachAnlegen(name: String, in eltern: Postfach?) async throws {
        var neu: [String: JSONWert] = ["name": .text(name)]
        if let eltern { neu["parentId"] = .text(eltern.id) }
        let r = try await client.einzeln("Mailbox/set", ["create": ["n": .objekt(neu)]])
        if let f = r["notCreated"]["n"].dict["description"]?.string { throw MailFehler.server(f) }
    }

    func postfachUmbenennen(_ postfach: Postfach, in name: String) async throws {
        let r = try await client.einzeln("Mailbox/set", ["update": [postfach.id: ["name": .text(name)]]])
        if let f = r["notUpdated"][postfach.id]["description"].string { throw MailFehler.server(f) }
    }

    func postfachLoeschen(_ postfach: Postfach) async throws {
        let r = try await client.einzeln("Mailbox/set", ["destroy": .strings([postfach.id]), "onDestroyRemoveEmails": true])
        if let f = r["notDestroyed"][postfach.id]["description"].string { throw MailFehler.server(f) }
    }

    // MARK: Versand

    private func identitaet(fuer adresse: String) async throws -> String {
        if let identitaetID { return identitaetID }
        let r = try await client.einzeln("Identity/get", [:])
        let liste = r["list"].array
        let passend = liste.first { ($0["email"].string ?? "").lowercased() == adresse.lowercased() } ?? liste.first
        guard let id = passend?["id"].string else { throw MailFehler.server(String(localized: "Keine Absenderidentität")) }
        identitaetID = id
        return id
    }

    private func importieren(_ roh: Data, in postfach: Postfach, schluessel: [String]) async throws -> String {
        let blob = try await client.hochladen(roh, typ: "message/rfc822")
        var kw: [String: JSONWert] = [:]
        for s in schluessel { kw[s] = true }
        let r = try await client.einzeln("Email/import", ["emails": ["e": [
            "blobId": .text(blob), "mailboxIds": [postfach.id: true], "keywords": .objekt(kw),
        ]]])
        guard let id = r["created"]["e"]["id"].string else {
            throw MailFehler.server(r["notCreated"]["e"]["description"].string ?? "Email/import")
        }
        return id
    }

    func senden(_ n: AusgehendeNachricht) async throws {
        let entwuerfe = try await rolle(.entwuerfe)
        let gesendet = try await rolle(.gesendet)
        let ident = try await identitaet(fuer: n.von.email)
        let id = try await importieren(MIMEBauer.bauen(n), in: entwuerfe, schluessel: ["$draft", "$seen"])
        let r = try await client.einzeln("EmailSubmission/set", [
            "create": ["s": [
                "identityId": .text(ident), "emailId": .text(id),
                "envelope": ["mailFrom": ["email": .text(n.von.email)],
                             "rcptTo": .liste(n.alleEmpfaenger.map { ["email": .text($0.email)] })],
            ]],
            "onSuccessUpdateEmail": ["#s": [
                "mailboxIds/\(entwuerfe.id)": nil, "mailboxIds/\(gesendet.id)": true, "keywords/$draft": nil,
            ]],
        ])
        let f = r["notCreated"]["s"]
        if !f.dict.isEmpty {
            // Entwurf wieder entfernen, damit nichts Halbes in „Entwürfe“ liegt
            _ = try? await client.einzeln("Email/set", ["destroy": .strings([id])])
            throw MailFehler.server(f["description"].string ?? f["type"].string ?? "EmailSubmission/set")
        }
    }

    @discardableResult
    func entwurfSichern(_ n: AusgehendeNachricht, ersetzt alt: NachrichtKopf?) async throws -> String? {
        let entwuerfe = try await rolle(.entwuerfe)
        let id = try await importieren(MIMEBauer.bauen(n, entwurf: true), in: entwuerfe, schluessel: ["$draft", "$seen"])
        if let alt { _ = try? await client.einzeln("Email/set", ["destroy": .strings([alt.id])]) }
        return id
    }

    func entwurfLoeschen(_ kopf: NachrichtKopf) async throws {
        _ = try await client.einzeln("Email/set", ["destroy": .strings([kopf.id])])
    }

    // MARK: Umwandlung

    private func kopfAus(_ e: JSONWert) -> NachrichtKopf? {
        guard let id = e["id"].string else { return nil }
        func adressen(_ w: JSONWert) -> [MailAdresse] {
            w.array.compactMap { a in a["email"].string.map { MailAdresse(name: a["name"].string, email: $0) } }
        }
        let kw = Set(e["keywords"].dict.filter { $0.value.boolWert == true }.keys.map { $0.lowercased() })
        let datum = e["receivedAt"].string.flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
        return NachrichtKopf(
            id: id, kontoID: konto.id, postfachIDs: Array(e["mailboxIds"].dict.keys),
            threadID: e["threadId"].string ?? id, von: adressen(e["from"]), an: adressen(e["to"]),
            kopie: adressen(e["cc"]), blindkopie: adressen(e["bcc"]), antwortAn: adressen(e["replyTo"]),
            betreff: e["subject"].string ?? "", vorschau: IMAPBackend.vorschauText(e["preview"].string ?? ""), datum: datum,
            gelesen: kw.contains("$seen"), markiert: kw.contains("$flagged"),
            fahne: FahnenFarbe(schluesselwoerter: kw), beantwortet: kw.contains("$answered"),
            weitergeleitet: kw.contains("$forwarded"), entwurf: kw.contains("$draft"),
            hatAnhang: e["hasAttachment"].boolWert ?? false, groesse: e["size"].int ?? 0,
            messageID: e["messageId"].array.first?.string.map { "<\($0)>" },
            inReplyTo: e["inReplyTo"].array.compactMap(\.string).map { "<\($0)>" },
            referenzen: e["references"].array.compactMap(\.string).map { "<\($0)>" },
            istListe: !e["header:List-Unsubscribe:asURLs"].array.isEmpty)
    }
}

/// Postfächer wie bei Apple sortieren: Sonderpostfächer zuerst, eigene darunter als Baum.
enum PostfachOrdnung {
    static func ordnen(_ liste: [Postfach]) -> [Postfach] {
        let kinder = Dictionary(grouping: liste, by: { $0.elternID ?? "" })
        let ids = Set(liste.map(\.id))
        var ergebnis: [Postfach] = []
        func einfuegen(_ p: Postfach, tiefe: Int) {
            var p = p
            p.tiefe = tiefe
            ergebnis.append(p)
            for k in (kinder[p.id] ?? []).sorted(by: vergleich) { einfuegen(k, tiefe: tiefe + 1) }
        }
        let wurzeln = liste.filter { $0.elternID == nil || !ids.contains($0.elternID!) }.sorted(by: vergleich)
        for w in wurzeln { einfuegen(w, tiefe: 0) }
        return ergebnis
    }

    private static func vergleich(_ a: Postfach, _ b: Postfach) -> Bool {
        if a.rolle.sortierung != b.rolle.sortierung { return a.rolle.sortierung < b.rolle.sortierung }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}
