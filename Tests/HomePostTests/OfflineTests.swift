import XCTest
@testable import HomePost

/// Netzwerkfehler → Status „Keine Verbindung“ + automatische Wiederholung, kein Dialog;
/// Anmelde- und Zertifikatsfehler bleiben deutliche Hinweise.
@MainActor
final class OfflineTests: XCTestCase {
    private func store() -> MailStore {
        let s = MailStore()
        s.wiederholAbstaende = [.milliseconds(30), .milliseconds(30), .milliseconds(30)]
        s.wiederholAktion = {}
        return s
    }

    func testVerbindungsfehlerOhneDialogMitDreiWiederholungen() async throws {
        let s = store()
        s.melde(MailFehler.verbindung("Es besteht anscheinend keine Verbindung zum Internet."))
        XCTAssertNil(s.fehler, "kein Fehlerdialog bei Netzwerkfehlern")
        XCTAssertTrue(s.offline)
        XCTAssertEqual(s.statusText, String(localized: "Keine Verbindung"))
        // weitere Netzwerkfehler starten keine zweite Wiederholungsreihe
        s.melde(URLError(.notConnectedToInternet))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(s.wiederholZaehler, 3, "nach 2, 5 und 15 s (hier verkürzt) erneut versucht")
        XCTAssertNil(s.fehler)
    }

    func testErfolgBeendetOfflineUndWiederholungen() async throws {
        let s = store()
        s.wiederholAktion = { [weak s] in s?.verbindungOK() }
        s.melde(URLError(.networkConnectionLost))
        XCTAssertTrue(s.offline)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(s.offline)
        // der erste Versuch (Zeitplan oder Netzpfad-Meldung) klappt, danach keine weiteren
        XCTAssertLessThanOrEqual(s.wiederholZaehler, 1, "nach Erfolg keine weiteren Versuche")
        XCTAssertNotEqual(s.statusText, String(localized: "Keine Verbindung"))
    }

    func testNetzWiederDaVersuchtSofort() async throws {
        let s = store()
        s.wiederholAbstaende = [.seconds(60)]
        var versucht = false
        s.wiederholAktion = { versucht = true }
        s.melde(MailFehler.verbindung("x"))
        s.verbindungVielleichtWieder()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(versucht, "App aktiv / Netzpfad da → sofort neu versuchen")
        s.verbindungOK()
    }

    func testAnmeldungUndZertifikatBleibenDialog() {
        let s = store()
        s.melde(MailFehler.anmeldung)
        XCTAssertNotNil(s.fehler)
        XCTAssertFalse(s.offline)
        s.fehler = nil
        s.melde(MailFehler.zertifikat)
        XCTAssertNotNil(s.fehler)
        XCTAssertFalse(MailStore.istVerbindungsfehler(MailFehler.server("x")))
        XCTAssertTrue(MailStore.istVerbindungsfehler(URLError(.timedOut)))
    }
}
