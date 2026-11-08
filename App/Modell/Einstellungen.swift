import Foundation
import SwiftUI

/// Was eine Wischgeste auslöst (einstellbar wie bei Apple: „Nach links“ / „Nach rechts“).
enum WischAktion: String, CaseIterable, Identifiable, Sendable {
    case keine, gelesen, markieren, bewegen, archivieren, loeschen, spam
    var id: String { rawValue }

    var titel: LocalizedStringKey {
        switch self {
        case .keine: "Keine"
        case .gelesen: "Als gelesen markieren"
        case .markieren: "Markieren"
        case .bewegen: "E‑Mail bewegen"
        case .archivieren: "Archivieren"
        case .loeschen: "Löschen"
        case .spam: "In „Spam“ bewegen"
        }
    }
}

/// Schlüssel und Standardwerte der Einstellungen (UserDefaults, nichts Geheimes).
enum Einstellung {
    static let vorschauZeilen = "vorschauZeilen"          // 0…5, Standard 2
    static let kontaktfotos = "kontaktfotos"              // Bool, Standard an
    static let anKopieLabel = "anKopieLabel"              // Bool, Standard aus
    static let wischRechts = "wischRechts"                // führende Seite (nach rechts wischen)
    static let wischLinks = "wischLinks"                  // hintere Seite (nach links wischen)
    static let loeschenBestaetigen = "loeschenBestaetigen"
    static let ferninhalteLaden = "ferninhalteLaden"      // Standard aus (Tracking-Schutz)
    static let nachKonversation = "nachKonversation"      // Standard an
    static let gelesenReduzieren = "gelesenReduzieren"    // Standard an
    static let neuesteOben = "neuesteOben"                // Standard aus
    static let signatur = "signatur"
    static let sendeVerzoegerung = "sendeVerzoegerung"    // 0, 10, 20, 30 s; Standard 10
    static let standardKonto = "standardKonto"
    static let archivStattLoeschen = "archivStattLoeschen"
    static let mitteilungen = "mitteilungen"
    static let vip = "vipAdressen"

    static func registrieren() {
        UserDefaults.standard.register(defaults: [
            vorschauZeilen: 2, kontaktfotos: true, anKopieLabel: false,
            wischRechts: WischAktion.gelesen.rawValue, wischLinks: WischAktion.loeschen.rawValue,
            loeschenBestaetigen: false, ferninhalteLaden: false, nachKonversation: true, gelesenReduzieren: true,
            neuesteOben: false, signatur: String(localized: "Von meinem iPhone gesendet"), sendeVerzoegerung: 10,
            archivStattLoeschen: false, mitteilungen: true,
        ])
    }

    static var d: UserDefaults { .standard }
}
