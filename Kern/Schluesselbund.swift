import Foundation
import Security

/// Passwörter nur im Schlüsselbund: nur dieses Gerät, nach dem ersten Entsperren (für den
/// Hintergrundabruf), nie synchronisiert, nie in UserDefaults/Dateien/Logs.
enum Schluesselbund {
    static let dienst = "org.homeroll.homepost.konto"

    static func sichern(_ passwort: String, fuer konto: UUID) throws {
        let basis: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: dienst,
            kSecAttrAccount as String: konto.uuidString,
        ]
        SecItemDelete(basis as CFDictionary)
        var neu = basis
        neu[kSecValueData as String] = Data(passwort.utf8)
        neu[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        neu[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(neu as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw MailFehler.server(String(localized: "Schlüsselbund-Fehler \(status)"))
        }
    }

    static func laden(fuer konto: UUID) -> String? {
        let abfrage: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: dienst,
            kSecAttrAccount as String: konto.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var ergebnis: CFTypeRef?
        guard SecItemCopyMatching(abfrage as CFDictionary, &ergebnis) == errSecSuccess,
              let d = ergebnis as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func loeschen(fuer konto: UUID) {
        let abfrage: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: dienst,
            kSecAttrAccount as String: konto.uuidString,
        ]
        SecItemDelete(abfrage as CFDictionary)
    }
}

/// Erzeugt das passende Backend für ein Konto.
enum BackendFabrik {
    static func backend(fuer konto: KontoKonfiguration, passwort: String) throws -> any MailBackend {
        switch konto.protokoll {
        case .jmap: try JMAPBackend(konto: konto, passwort: passwort)
        case .imap: IMAPBackend(konto: konto, passwort: passwort)
        }
    }
}

/// Account-Einrichtung mit Autodiscover: erst JMAP (/.well-known/jmap), sonst IMAP/SMTP mit Standardports.
enum Einrichtung {
    struct Eingabe: Sendable {
        var adresse: String
        var passwort: String
        var vollerName: String
        var server: String          // Host oder URL; leer = Domain der Adresse
        var benutzer: String = ""   // leer = Adresse
        var unverschluesselt: Bool  // nur Heimnetz-Testserver
    }

    /// Versucht JMAP und IMAP; liefert die erste funktionierende Konfiguration.
    static func erkennen(_ e: Eingabe) async throws -> KontoKonfiguration {
        let benutzer = e.benutzer.isEmpty ? e.adresse : e.benutzer
        let domain = e.adresse.split(separator: "@").last.map(String.init) ?? ""
        var host = e.server.trimmingCharacters(in: .whitespaces)
        if host.isEmpty { host = domain }
        let istURL = host.contains("://")
        let reinerHost = istURL ? (URL(string: host)?.host ?? host) : host.split(separator: "/").first.map(String.init) ?? host
        let name = e.adresse.split(separator: "@").last.map { String($0) } ?? e.adresse

        // 1. JMAP
        var kandidaten: [String] = []
        if istURL { kandidaten.append(host) }
        if e.unverschluesselt {
            kandidaten += ["http://\(reinerHost):8080", "http://\(reinerHost)"]
        } else {
            kandidaten += ["https://\(reinerHost)", "https://\(reinerHost):8443"]
        }
        var letzterFehler: Error = MailFehler.verbindung(reinerHost)
        for url in kandidaten {
            var k = KontoKonfiguration(name: name, vollerName: e.vollerName, adresse: e.adresse, benutzer: benutzer,
                                       protokoll: .jmap)
            k.jmapURL = url
            do {
                let b = try JMAPBackend(konto: k, passwort: e.passwort)
                try await b.pruefen()
                return k
            } catch MailFehler.anmeldung {
                throw MailFehler.anmeldung
            } catch {
                letzterFehler = error
            }
        }
        // 2. IMAP/SMTP
        let varianten: [(Verschluesselung, Int, Int)] = e.unverschluesselt
            ? [(.unverschluesselt, 143, 587)]
            : [(.tls, 993, 465), (.starttls, 143, 587)]
        for (sicherheit, imap, smtp) in varianten {
            var k = KontoKonfiguration(name: name, vollerName: e.vollerName, adresse: e.adresse, benutzer: benutzer,
                                       protokoll: .imap)
            k.imapHost = reinerHost; k.smtpHost = reinerHost
            k.imapPort = imap; k.smtpPort = smtp; k.sicherheit = sicherheit
            let b = IMAPBackend(konto: k, passwort: e.passwort)
            do {
                try await b.pruefen()
                await b.trennen()
                return k
            } catch MailFehler.anmeldung {
                await b.trennen()
                throw MailFehler.anmeldung
            } catch {
                await b.trennen()
                letzterFehler = error
            }
        }
        throw letzterFehler
    }
}
