import XCTest
@testable import HomePost

/// Zugänge kommen nur aus der Umgebung (tools/run-tests.sh setzt TEST_RUNNER_MAIL_*), nie aus dem Repo.
enum TestZugang {
    static let env = ProcessInfo.processInfo.environment

    static func wert(_ k: String) throws -> String {
        guard let v = env[k], !v.isEmpty else { throw XCTSkip("\(k) fehlt – Tests gegen den Testserver übersprungen") }
        return v
    }

    /// Konto 1 per JMAP (http, nur Heimnetz-Testserver)
    static func jmap(_ nr: Int) throws -> (KontoKonfiguration, String) {
        var k = KontoKonfiguration(name: "Test", vollerName: "Test \(nr)", adresse: try wert("MAIL_USER\(nr)"),
                                   benutzer: try wert("MAIL_USER\(nr)"), protokoll: .jmap)
        k.jmapURL = try wert("MAIL_JMAP_URL")
        return (k, try wert("MAIL_PASSWORD\(nr)"))
    }

    /// Konto per IMAP/SMTP, Option „Unverschlüsselt (nur Heimnetz)“ (143/587)
    static func imap(_ nr: Int) throws -> (KontoKonfiguration, String) {
        var k = KontoKonfiguration(name: "Test", vollerName: "Test \(nr)", adresse: try wert("MAIL_USER\(nr)"),
                                   benutzer: try wert("MAIL_USER\(nr)"), protokoll: .imap)
        k.imapHost = try wert("MAIL_HOST"); k.smtpHost = k.imapHost
        k.imapPort = 143; k.smtpPort = 587; k.sicherheit = .unverschluesselt
        return (k, try wert("MAIL_PASSWORD\(nr)"))
    }
}

/// Gleiche Prüfungen für beide Protokolle – die Oberfläche merkt keinen Unterschied.
class BackendGemeinsam: XCTestCase {
    func backend(_ nr: Int) throws -> any MailBackend { throw XCTSkip("Basisklasse") }
    var istJMAP: Bool { false }

    func postfach(_ b: any MailBackend, _ r: PostfachRolle) async throws -> Postfach {
        let p = try await b.postfaecher()
        return try XCTUnwrap(p.first { $0.rolle == r }, "Postfach \(r) fehlt")
    }

    func testPostfaecherUndListe() async throws {
        let b = try backend(1)
        try await b.pruefen()
        let liste = try await b.postfaecher()
        for r in [PostfachRolle.eingang, .entwuerfe, .gesendet, .papierkorb, .spam, .archiv] {
            XCTAssertTrue(liste.contains { $0.rolle == r }, "Rolle \(r) fehlt")
        }
        XCTAssertEqual(liste.first?.rolle, .eingang, "Eingang zuerst")
        let eingang = try await postfach(b, .eingang)
        let mails = try await b.nachrichten(in: eingang, anzahl: 50)
        XCTAssertFalse(mails.isEmpty)
        XCTAssertTrue(mails.contains { !$0.vorschau.isEmpty }, "Vorschau fehlt")
        XCTAssertEqual(mails.map(\.datum), mails.map(\.datum).sorted(by: >), "neueste zuerst")
        if istJMAP {
            XCTAssertEqual(eingang.ungelesen, mails.filter { !$0.gelesen }.count)
        }
    }

    func testKonversationUndAnhang() async throws {
        let b = try backend(1)
        let eingang = try await postfach(b, .eingang)
        let mails = try await b.nachrichten(in: eingang, anzahl: 50)
        let grill = try XCTUnwrap(mails.first { $0.betreff.contains("Barbecue") })
        let konv = try await b.konversation(zu: grill)
        XCTAssertGreaterThanOrEqual(konv.count, 3, "Konversation über Eingang + Gesendet")
        XCTAssertEqual(konv.map(\.datum), konv.map(\.datum).sorted())
        let erste = try XCTUnwrap(konv.first)
        let inhalt = try await b.inhalt(von: erste)
        let pdf = try XCTUnwrap(inhalt.anhaenge.first { $0.name == "Shopping-List.pdf" })
        let daten = try await b.anhang(pdf, von: erste)
        XCTAssertTrue(daten.starts(with: Data("%PDF".utf8)))
        XCTAssertNotNil(inhalt.text)
    }

    func testMarkierenGelesenBewegen() async throws {
        let b = try backend(1)
        let eingang = try await postfach(b, .eingang)
        let archiv = try await postfach(b, .archiv)
        let erste = try await b.nachrichten(in: eingang, anzahl: 50)
        var mail = try XCTUnwrap(erste.first)
        let warGelesen = mail.gelesen
        try await b.setzeMarkierung([mail], true, farbe: .blau)
        try await b.setzeGelesen([mail], !warGelesen)
        let zweite = try await b.nachrichten(in: eingang, anzahl: 50)
        let mid = mail.id
        mail = try XCTUnwrap(zweite.first { $0.id == mid })
        XCTAssertTrue(mail.markiert)
        XCTAssertEqual(mail.fahne, .blau)
        XCTAssertEqual(mail.gelesen, !warGelesen)
        try await b.setzeMarkierung([mail], false, farbe: nil)
        try await b.setzeGelesen([mail], warGelesen)
        // Bewegen + Widerrufen (zurückbewegen mit den neuen IDs)
        let bewegt = try await b.bewegen([mail], von: eingang, nach: archiv)
        let imArchiv = try await b.nachrichten(in: archiv, anzahl: 50)
        XCTAssertTrue(imArchiv.contains { $0.messageID == mail.messageID })
        try await b.bewegen(bewegt, von: archiv, nach: eingang)
        let zurueck = try await b.nachrichten(in: eingang, anzahl: 50)
        let wieder = try XCTUnwrap(zurueck.first { $0.messageID == mail.messageID })
        XCTAssertFalse(wieder.markiert)
    }

    func testSuche() async throws {
        let b = try backend(1)
        let treffer = try await b.suchen("toolbox", in: nil)
        XCTAssertTrue(treffer.contains { $0.betreff.contains("toolbox") })
    }

    func testSendenMitAnhang() async throws {
        let sender = try backend(1)
        let empfaenger = try backend(3)
        let (k3, _) = istJMAP ? try TestZugang.jmap(3) : try TestZugang.imap(3)
        let betreff = "HomePost-Test \(istJMAP ? "JMAP" : "IMAP") \(UUID().uuidString.prefix(8)) – Grüße"
        var n = AusgehendeNachricht(von: MailAdresse(name: "Täst Sender", email: sender.konto.adresse),
                                    an: [MailAdresse(name: "Clara", email: k3.adresse)], betreff: betreff,
                                    text: "Hallo Clara,\nein Test mit Umlauten: äöüß – und einem Anhang.\n")
        n.anhaenge = [AusgehenderAnhang(name: "Notiz ü.txt", mimeTyp: "text/plain", daten: Data("Inhalt äöü".utf8))]
        try await sender.senden(n)
        // in „Gesendet“ des Absenders
        let gesendet = try await postfach(sender, .gesendet)
        let s = try await sender.nachrichten(in: gesendet, anzahl: 20)
        XCTAssertTrue(s.contains { $0.betreff == betreff }, "nicht in Gesendet")
        // beim Empfänger angekommen (Zustellung kann kurz dauern)
        let eingang = try await postfach(empfaenger, .eingang)
        var angekommen: NachrichtKopf?
        for _ in 0..<20 where angekommen == nil {
            angekommen = try await empfaenger.nachrichten(in: eingang, anzahl: 20).first { $0.betreff == betreff }
            if angekommen == nil { try await Task.sleep(for: .milliseconds(500)) }
        }
        let a = try XCTUnwrap(angekommen, "nicht zugestellt")
        XCTAssertTrue(a.hatAnhang)
        let inhalt = try await empfaenger.inhalt(von: a)
        XCTAssertTrue(inhalt.text?.contains("äöüß") ?? false)
        let anh = try XCTUnwrap(inhalt.anhaenge.first)
        XCTAssertEqual(anh.name, "Notiz ü.txt")
        let d = try await empfaenger.anhang(anh, von: a)
        XCTAssertEqual(String(data: d, encoding: .utf8), "Inhalt äöü")
        // aufräumen
        let papierkorb = try await postfach(empfaenger, .papierkorb)
        let imKorb = try await empfaenger.bewegen([a], von: eingang, nach: papierkorb)
        try await empfaenger.endgueltigLoeschen(imKorb, in: papierkorb)
    }

    func testEntwurf() async throws {
        let b = try backend(1)
        let n = AusgehendeNachricht(von: MailAdresse(name: nil, email: b.konto.adresse),
                                    an: [MailAdresse(name: nil, email: "jemand@test.local")],
                                    betreff: "Entwurf \(UUID().uuidString.prefix(6))", text: "erste Fassung")
        try await b.entwurfSichern(n, ersetzt: nil)
        let entwuerfe = try await postfach(b, .entwuerfe)
        var liste = try await b.nachrichten(in: entwuerfe, anzahl: 20)
        let alt = try XCTUnwrap(liste.first { $0.betreff == n.betreff })
        XCTAssertTrue(alt.entwurf)
        var zweite = n
        zweite.text = "zweite Fassung"
        try await b.entwurfSichern(zweite, ersetzt: alt)
        liste = try await b.nachrichten(in: entwuerfe, anzahl: 20)
        let neu = liste.filter { $0.betreff == n.betreff }
        XCTAssertEqual(neu.count, 1, "alter Entwurf ersetzt")
        try await b.entwurfLoeschen(try XCTUnwrap(neu.first))
        liste = try await b.nachrichten(in: entwuerfe, anzahl: 20)
        XCTAssertFalse(liste.contains { $0.betreff == n.betreff })
    }

    func testPostfachVerwalten() async throws {
        let b = try backend(1)
        let name = "Test\(Int.random(in: 1000...9999))"
        try await b.postfachAnlegen(name: name, in: nil)
        let l1 = try await b.postfaecher()
        var p = try XCTUnwrap(l1.first { $0.name == name })
        try await b.postfachUmbenennen(p, in: name + "x")
        let l2 = try await b.postfaecher()
        p = try XCTUnwrap(l2.first { $0.name == name + "x" })
        try await b.postfachLoeschen(p)
        let rest = try await b.postfaecher()
        XCTAssertFalse(rest.contains { $0.name.hasPrefix(name) })
    }
}

final class JMAPBackendTests: BackendGemeinsam {
    override var istJMAP: Bool { true }
    override func backend(_ nr: Int) throws -> any MailBackend {
        let (k, pw) = try TestZugang.jmap(nr)
        return try JMAPBackend(konto: k, passwort: pw)
    }

    func testFalschesPasswort() async throws {
        let (k, _) = try TestZugang.jmap(1)
        let b = try JMAPBackend(konto: k, passwort: "falsch")
        do {
            try await b.pruefen()
            XCTFail("Anmeldung hätte scheitern müssen")
        } catch MailFehler.anmeldung {}
    }

    func testEinrichtungErkenntJMAP() async throws {
        let (k, pw) = try TestZugang.jmap(1)
        let host = try TestZugang.wert("MAIL_HOST")
        let erkannt = try await Einrichtung.erkennen(.init(adresse: k.adresse, passwort: pw, vollerName: "Anna",
                                                           server: host, unverschluesselt: true))
        XCTAssertEqual(erkannt.protokoll, .jmap)
    }
}

final class IMAPBackendTests: BackendGemeinsam {
    override func backend(_ nr: Int) throws -> any MailBackend {
        // Konto 2 (Ben) per IMAP; Konto 3 (Clara) als Empfänger
        let (k, pw) = try TestZugang.imap(nr == 1 ? 2 : nr)
        return IMAPBackend(konto: k, passwort: pw)
    }

    override func testKonversationUndAnhang() async throws {
        try await super.testKonversationUndAnhang()
    }

    override func testSuche() async throws {
        let b = try backend(1)
        let treffer = try await b.suchen("Garden", in: nil)
        XCTAssertTrue(treffer.contains { $0.betreff.contains("Garden shed") })
    }

    func testTLSMitSelbstsigniertemZertifikatWirdAbgelehnt() async throws {
        var (k, pw) = try TestZugang.imap(2)
        k.imapPort = 993; k.smtpPort = 465; k.sicherheit = .tls
        let b = IMAPBackend(konto: k, passwort: pw)
        do {
            try await b.pruefen()
            XCTFail("selbstsigniertes Zertifikat hätte abgelehnt werden müssen")
        } catch {
            // erwartet: Zertifikats- oder Verbindungsfehler, nie stilles Weitermachen
        }
        await b.trennen()
    }
}
