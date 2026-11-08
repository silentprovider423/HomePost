import XCTest
@testable import HomePost

/// Offline-Tests für MIME, Adressen, Fahnenfarben und Konversationen.
final class KernTests: XCTestCase {
    func testQuotedPrintable() {
        XCTAssertEqual(MIMEBauer.quotedPrintable("Grüße"), "Gr=C3=BC=C3=9Fe")
        XCTAssertEqual(MIMEBauer.quotedPrintable("a = b"), "a =3D b")
        XCTAssertEqual(MIMEBauer.quotedPrintable("Ende "), "Ende=20")
        let lang = String(repeating: "x", count: 200)
        XCTAssertTrue(MIMEBauer.quotedPrintable(lang).split(separator: "\r\n").allSatisfy { $0.count <= 76 })
    }

    func testKodiertesWort() {
        XCTAssertEqual(MIMEBauer.kodiereWort("Hallo"), "Hallo")
        let k = MIMEBauer.kodiereWort("Grüße")
        XCTAssertTrue(k.hasPrefix("=?UTF-8?B?"))
        XCTAssertEqual(MIMEBauer.adressen([MailAdresse(name: "Berger, Anna", email: "a@b.c")]), "\"Berger, Anna\" <a@b.c>")
    }

    func testAdressenLesen() {
        let l = MailAdresse.liste("Anna <anna@test.local>, ben@test.local; \"Lindqvist, Clara\" <clara@test.local>")
        XCTAssertEqual(l.map(\.email), ["anna@test.local", "ben@test.local", "clara@test.local"])
        XCTAssertEqual(l[2].name, "Lindqvist, Clara")
        XCTAssertNil(MailAdresse.lesen("kein-at"))
    }

    func testFahnenFarbenBits() {
        // Apple: rot 0, orange 1, gelb 2, grün 3, blau 4, lila 5, grau 6 (3 Bits)
        XCTAssertEqual(FahnenFarbe(schluesselwoerter: []), .rot)
        XCTAssertEqual(FahnenFarbe(schluesselwoerter: ["$MailFlagBit0"]), .orange)
        XCTAssertEqual(FahnenFarbe(schluesselwoerter: ["$mailflagbit2"]), .blau)
        XCTAssertEqual(FahnenFarbe(schluesselwoerter: ["$MailFlagBit1", "$MailFlagBit2"]), .grau)
        for f in FahnenFarbe.allCases {
            XCTAssertEqual(FahnenFarbe(schluesselwoerter: Set(f.gesetzteBits)), f)
        }
    }

    func testMIMEMitAnhangIstParsebar() throws {
        var n = AusgehendeNachricht(von: MailAdresse(name: "Änne", email: "a@test.local"),
                                    an: [MailAdresse(name: nil, email: "b@test.local")], betreff: "Prüfung ✓",
                                    text: "Zeile 1\nZeile 2 äöü")
        n.blindkopie = [MailAdresse(name: nil, email: "geheim@test.local")]
        n.anhaenge = [AusgehenderAnhang(name: "bild.png", mimeTyp: "image/png", daten: Data(repeating: 7, count: 3000))]
        let roh = MIMEBauer.bauen(n)
        let text = String(decoding: roh, as: UTF8.self)
        XCTAssertFalse(text.contains("geheim@test.local"), "Bcc nie im Kopf gesendeter E‑Mails")
        XCTAssertTrue(roh.allSatisfy { $0 < 128 }, "7-Bit-sicher")
        XCTAssertTrue(text.contains("multipart/mixed"))
        XCTAssertTrue(MIMEBauer.bauen(n, entwurf: true).count > roh.count, "Entwurf behält Bcc")
    }

    func testKonversationenBilden() {
        func k(_ id: String, _ mid: String, _ refs: [String], _ betreff: String, _ t: TimeInterval) -> NachrichtKopf {
            NachrichtKopf(id: id, kontoID: UUID(), postfachIDs: ["INBOX"], threadID: "", von: [], an: [], kopie: [],
                          betreff: betreff, vorschau: "", datum: Date(timeIntervalSince1970: t), gelesen: true,
                          markiert: false, hatAnhang: false, messageID: mid, inReplyTo: refs.suffix(1), referenzen: refs)
        }
        let liste = KonversationsBauer.zuordnen([
            k("1", "<a>", [], "Grillen", 1), k("2", "<b>", ["<a>"], "Re: Grillen", 2),
            k("3", "<c>", ["<a>", "<b>"], "Re: Grillen", 3), k("4", "<d>", [], "Anderes", 4),
            k("5", "<e>", [], "AW: Anderes", 5),
        ])
        let t = Dictionary(uniqueKeysWithValues: liste.map { ($0.id, $0.threadID) })
        XCTAssertEqual(t["1"], t["2"]); XCTAssertEqual(t["2"], t["3"])
        XCTAssertNotEqual(t["1"], t["4"])
        XCTAssertEqual(t["4"], t["5"], "Betreff-Fallback für Antwort ohne References")
    }

    func testZitat() {
        XCTAssertEqual(Zitat.antwortBetreff("Hallo"), "Re: Hallo")
        XCTAssertEqual(Zitat.antwortBetreff("AW: Hallo"), "AW: Hallo")
        XCTAssertEqual(Zitat.weiterleitenBetreff("Hallo"), "Fwd: Hallo")
        XCTAssertEqual(Zitat.textAusHTML("<p>Hallo&nbsp;<b>Welt</b></p><br>Ende"), "Hallo Welt\n\nEnde")
    }

    func testCacheSucheOffline() async throws {
        let pfad = FileManager.default.temporaryDirectory.appending(path: "cache-\(UUID().uuidString).sqlite")
        let cache = MailCache(pfad: pfad)
        let konto = UUID()
        let kopf = NachrichtKopf(id: "x1", kontoID: konto, postfachIDs: ["INBOX"], threadID: "t",
                                 von: [MailAdresse(name: "Clara Lindqvist", email: "clara@test.local")], an: [],
                                 kopie: [], betreff: "Fotos vom Ausflug", vorschau: "Das Wetter war perfekt",
                                 datum: Date(), gelesen: false, markiert: false, hatAnhang: true)
        await cache.speichern([kopf], konto: konto, postfach: "INBOX")
        let geladen = await cache.laden(konto: konto, postfach: "INBOX")
        XCTAssertEqual(geladen.first?.id, "x1")
        let t1 = await cache.suchen("ausfl", konto: konto)
        XCTAssertEqual(t1.count, 1, "Präfixsuche")
        let t2 = await cache.suchen("lindqvist wetter", konto: nil)
        XCTAssertEqual(t2.count, 1)
        let t3 = await cache.suchen("Rechnung", konto: konto)
        XCTAssertTrue(t3.isEmpty)
        try? FileManager.default.removeItem(at: pfad)
    }
}
