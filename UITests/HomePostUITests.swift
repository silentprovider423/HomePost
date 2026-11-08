import XCTest

/// Bedienung wie ein Mensch gegen die Testkonten (Konto 1 JMAP, Konto 2 IMAP unverschlüsselt im Heimnetz).
/// Zugänge kommen über TEST_RUNNER_MAIL_* (tools/run-tests.sh), nie aus dem Repo.
final class HomePostUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let url = env["MAIL_JMAP_URL"], let u1 = env["MAIL_USER1"], let p1 = env["MAIL_PASSWORD1"],
              let host = env["MAIL_HOST"], let u2 = env["MAIL_USER2"], let p2 = env["MAIL_PASSWORD2"] else {
            throw XCTSkip("Testzugänge fehlen")
        }
        app = XCUIApplication()
        app.launchEnvironment["HOMEPOST_KONTO1"] = "jmap;\(url);\(u1);\(p1);Anna Berger"
        app.launchEnvironment["HOMEPOST_KONTO2"] = "imap;\(host);\(u2);\(p2);Ben Okafor;unverschluesselt"
        // Bildschirmfotos fürs README auf Englisch (Oberfläche folgt sonst der Simulator-Sprache)
        if let sprache = env["SCREENSHOT_LANG"], !sprache.isEmpty {
            app.launchArguments += ["-AppleLanguages", "(\(sprache))", "-AppleLocale", sprache == "en" ? "en_US" : sprache]
        }
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func zeile(_ betreff: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "zeile-\(betreff)")).firstMatch
    }

    private func bild(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        if let ordner = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: ordner).appendingPathComponent("\(name).png"))
        }
    }

    func testPostfaecherListeUndKonversation() throws {
        app.launch()
        let anna = element("postfach-Anna Berger")
        XCTAssertTrue(anna.waitForExistence(timeout: 60), "Posteingang von Konto 1 fehlt")
        XCTAssertTrue(element("postfach-Ben Okafor").exists, "IMAP-Konto fehlt")
        XCTAssertTrue(element("alleEingaenge").exists)
        bild("1-mailboxes")
        anna.tap()
        let grill = zeile("Re: Barbecue")
        XCTAssertTrue(grill.waitForExistence(timeout: 60))
        bild("2-inbox")
        grill.tap()
        let betreff = element("betreff")
        XCTAssertTrue(betreff.waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["Clara Lindqvist"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.webViews.staticTexts.containing(NSPredicate(format: "label CONTAINS 'potato salad'")).firstMatch
            .waitForExistence(timeout: 30), "Inhalt nicht geladen")
        bild("3-conversation")
    }

    func testAnhangUndBilderBanner() throws {
        app.launch()
        let anna = element("postfach-Anna Berger")
        XCTAssertTrue(anna.waitForExistence(timeout: 60))
        anna.tap()
        let fotos = zeile("Photos from our day")
        XCTAssertTrue(fotos.waitForExistence(timeout: 60))
        fotos.tap()
        XCTAssertTrue(element("anhang-Lake-Morning.png").waitForExistence(timeout: 30), "Anhang fehlt")
        _ = app.webViews.staticTexts.containing(NSPredicate(format: "label CONTAINS 'weather'")).firstMatch.waitForExistence(timeout: 20)
        sleep(2)
        bild("4-attachments")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let news = zeile("New in November")
        XCTAssertTrue(news.waitForExistence(timeout: 30))
        news.tap()
        XCTAssertTrue(element("bilderLaden").waitForExistence(timeout: 30), "Banner für blockierte Bilder fehlt")
    }

    func testWischenMarkierenUndGelesen() throws {
        app.launch()
        let anna = element("postfach-Anna Berger")
        XCTAssertTrue(anna.waitForExistence(timeout: 60))
        anna.tap()
        let paket = zeile("Your parcel")
        XCTAssertTrue(paket.waitForExistence(timeout: 60))
        // nach links: Löschen · Markieren · Mehr
        paket.swipeLeft()
        let markieren = app.buttons["Markieren"]
        XCTAssertTrue(markieren.waitForExistence(timeout: 10))
        markieren.tap()
        // zurücknehmen
        paket.swipeLeft()
        let nicht = app.buttons["Nicht markieren"]
        XCTAssertTrue(nicht.waitForExistence(timeout: 10))
        nicht.tap()
        // nach rechts: gelesen/ungelesen umschalten und zurück
        paket.swipeRight()
        let gelesen = app.buttons["Gelesen"].exists ? app.buttons["Gelesen"] : app.buttons["Ungelesen"]
        XCTAssertTrue(gelesen.waitForExistence(timeout: 10))
        gelesen.tap()
        paket.swipeRight()
        let zurueck = app.buttons["Gelesen"].exists ? app.buttons["Gelesen"] : app.buttons["Ungelesen"]
        XCTAssertTrue(zurueck.waitForExistence(timeout: 10))
        zurueck.tap()
    }

    func testVerfassenUndSenden() throws {
        app.launch()
        let verfassen = element("verfassen")
        XCTAssertTrue(verfassen.waitForExistence(timeout: 60))
        verfassen.tap()
        let an = element("feldAn")
        XCTAssertTrue(an.waitForExistence(timeout: 20))
        an.tap()
        an.typeText(ProcessInfo.processInfo.environment["MAIL_USER3"] ?? "")
        let betreff = "Lunch on Friday? \(Int.random(in: 10...99))"
        let feldBetreff = element("feldBetreff")
        feldBetreff.tap()
        feldBetreff.typeText(betreff)
        let text = element("feldText")
        text.tap()
        text.typeText("Hello from the UI test. ")
        bild("5-compose")
        element("senden").tap()
        XCTAssertTrue(element("sendenWiderrufen").waitForExistence(timeout: 10), "„Senden widerrufen“ fehlt")
        // nach der Verzögerung in „Gesendet“
        XCTAssertTrue(element("sendenWiderrufen").waitForNonExistence(timeout: 60))
        let gesendet = element("postfach-gesendet")
        XCTAssertTrue(gesendet.waitForExistence(timeout: 20))
        gesendet.tap()
        XCTAssertTrue(zeile(betreff).waitForExistence(timeout: 60), "gesendete E‑Mail nicht in Gesendet")
    }

    func testSendenWiderrufen() throws {
        app.launch()
        let verfassen = element("verfassen")
        XCTAssertTrue(verfassen.waitForExistence(timeout: 60))
        verfassen.tap()
        let an = element("feldAn")
        XCTAssertTrue(an.waitForExistence(timeout: 20))
        an.tap()
        an.typeText("niemand@test.local")
        element("feldBetreff").tap()
        element("feldBetreff").typeText("Widerrufen")
        element("senden").tap()
        let knopf = element("sendenWiderrufen")
        XCTAssertTrue(knopf.waitForExistence(timeout: 10))
        knopf.tap()
        // Verfassen-Fenster ist wieder offen, mit dem Betreff
        XCTAssertTrue(element("feldBetreff").waitForExistence(timeout: 10))
        XCTAssertEqual(element("feldBetreff").value as? String, "Widerrufen")
        element("abbrechen").tap()
        let loeschen = app.buttons["Entwurf löschen"]
        XCTAssertTrue(loeschen.waitForExistence(timeout: 10))
        loeschen.tap()
    }

    func testPostfachAnlegenUndLoeschen() throws {
        app.launch()
        XCTAssertTrue(element("postfach-Anna Berger").waitForExistence(timeout: 60))
        app.buttons["Bearbeiten"].firstMatch.tap()
        let neu = element("neuesPostfachLeiste")
        XCTAssertTrue(neu.waitForExistence(timeout: 10))
        neu.tap()
        let feld = element("postfachName")
        XCTAssertTrue(feld.waitForExistence(timeout: 10))
        let name = "UITest\(Int.random(in: 100...999))"
        feld.tap()
        feld.typeText(name)
        element("postfachSichern").tap()
        app.buttons["Fertig"].firstMatch.tap()
        let ordner = element("postfach-\(name)")
        for _ in 0..<6 where !ordner.waitForExistence(timeout: 5) { app.swipeUp() }
        XCTAssertTrue(ordner.waitForExistence(timeout: 20), "neues Postfach fehlt")
        ordner.swipeLeft()
        app.buttons["Löschen"].firstMatch.tap()
        let bestaetigen = app.buttons["Postfach löschen"]
        XCTAssertTrue(bestaetigen.waitForExistence(timeout: 10))
        bestaetigen.tap()
        XCTAssertTrue(ordner.waitForNonExistence(timeout: 30))
    }
}
