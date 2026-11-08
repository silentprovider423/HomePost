import Foundation

/// Schlanker JMAP-Client (RFC 8620/8621) über URLSession – nur die Methoden, die HomePost braucht.
actor JMAPClient {
    struct Sitzung: Sendable {
        var apiURL: URL
        var downloadVorlage: String
        var uploadVorlage: String
        var kontoID: String
        var benutzer: String
        var faehigkeiten: Set<String>
    }

    let basis: URL
    private let benutzer: String
    private let passwort: String
    private let session: URLSession
    private var sitzung: Sitzung?

    static let using: [String] = ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail",
                                   "urn:ietf:params:jmap:submission"]

    init(basis: URL, benutzer: String, passwort: String) {
        self.basis = basis
        self.benutzer = benutzer
        self.passwort = passwort
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.httpCookieStorage = nil
        cfg.urlCache = nil
        self.session = URLSession(configuration: cfg, delegate: AuthWeiterleitung(), delegateQueue: nil)
    }

    private var authKopf: String {
        "Basic " + Data("\(benutzer):\(passwort)".utf8).base64EncodedString()
    }

    /// Session laden (/.well-known/jmap); URLs aus der Session auf die eingegebene Adresse umschreiben,
    /// damit ein Server mit internem Hostnamen (z. B. mail.test.local) trotzdem per IP erreichbar ist.
    func holeSitzung(neu: Bool = false) async throws -> Sitzung {
        if let sitzung, !neu { return sitzung }
        var anfrage = URLRequest(url: basis.appending(path: ".well-known/jmap"))
        anfrage.setValue(authKopf, forHTTPHeaderField: "Authorization")
        let (daten, antwort) = try await laden(anfrage)
        try pruefeStatus(antwort, daten)
        let json = try JSONDecoder().decode(JSONWert.self, from: daten)
        guard let api = json["apiUrl"].string,
              let konto = json["primaryAccounts"]["urn:ietf:params:jmap:mail"].string else {
            throw MailFehler.server(String(localized: "Keine JMAP-Sitzung"))
        }
        let s = Sitzung(apiURL: URL(string: umschreiben(api))!,
                        downloadVorlage: umschreiben(json["downloadUrl"].string ?? ""),
                        uploadVorlage: umschreiben(json["uploadUrl"].string ?? ""),
                        kontoID: konto,
                        benutzer: json["username"].string ?? benutzer,
                        faehigkeiten: Set(json["capabilities"].dict.keys))
        sitzung = s
        return s
    }

    func umschreiben(_ url: String) -> String {
        guard var teile = URLComponents(string: url), let b = URLComponents(url: basis, resolvingAgainstBaseURL: false) else {
            return url
        }
        teile.scheme = b.scheme
        teile.host = b.host
        teile.port = b.port
        // Vorlagen enthalten {…}; URLComponents kodiert sie – zurückwandeln
        return (teile.string ?? url).replacingOccurrences(of: "%7B", with: "{").replacingOccurrences(of: "%7D", with: "}")
    }

    /// Mehrere Methodenaufrufe in einer Anfrage. Liefert die Antworten in Reihenfolge; Fehler einer Methode werfen.
    func aufruf(_ aufrufe: [(String, [String: JSONWert])]) async throws -> [JSONWert] {
        let s = try await holeSitzung()
        var calls: [JSONWert] = []
        for (i, (name, argumente)) in aufrufe.enumerated() {
            var a = argumente
            if a["accountId"] == nil { a["accountId"] = .text(s.kontoID) }
            calls.append(.liste([.text(name), .objekt(a), .text("c\(i)")]))
        }
        let koerper: JSONWert = ["using": .strings(Self.using), "methodCalls": .liste(calls)]
        var anfrage = URLRequest(url: s.apiURL)
        anfrage.httpMethod = "POST"
        anfrage.setValue(authKopf, forHTTPHeaderField: "Authorization")
        anfrage.setValue("application/json", forHTTPHeaderField: "Content-Type")
        anfrage.httpBody = try JSONEncoder().encode(koerper)
        let (daten, antwort) = try await laden(anfrage)
        try pruefeStatus(antwort, daten)
        let json = try JSONDecoder().decode(JSONWert.self, from: daten)
        let antworten = json["methodResponses"].array
        var ergebnis: [JSONWert] = []
        for a in antworten {
            if a[0].string == "error" {
                let typ = a[1]["type"].string ?? "error"
                let text = a[1]["description"].string ?? ""
                throw MailFehler.server("\(typ) \(text)".trimmingCharacters(in: .whitespaces))
            }
            ergebnis.append(a[1])
        }
        return ergebnis
    }

    func einzeln(_ name: String, _ argumente: [String: JSONWert]) async throws -> JSONWert {
        try await aufruf([(name, argumente)])[0]
    }

    func hochladen(_ daten: Data, typ: String) async throws -> String {
        let s = try await holeSitzung()
        let url = URL(string: s.uploadVorlage.replacingOccurrences(of: "{accountId}", with: s.kontoID))!
        var anfrage = URLRequest(url: url)
        anfrage.httpMethod = "POST"
        anfrage.setValue(authKopf, forHTTPHeaderField: "Authorization")
        anfrage.setValue(typ, forHTTPHeaderField: "Content-Type")
        let (antwortDaten, antwort) = try await session.upload(for: anfrage, from: daten)
        try pruefeStatus(antwort, antwortDaten)
        let json = try JSONDecoder().decode(JSONWert.self, from: antwortDaten)
        guard let blob = json["blobId"].string else { throw MailFehler.server("upload") }
        return blob
    }

    func herunterladen(blobID: String, name: String, typ: String) async throws -> Data {
        let s = try await holeSitzung()
        let nameKodiert = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "datei"
        let typKodiert = typ.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "application/octet-stream"
        let text = s.downloadVorlage
            .replacingOccurrences(of: "{accountId}", with: s.kontoID)
            .replacingOccurrences(of: "{blobId}", with: blobID)
            .replacingOccurrences(of: "{name}", with: nameKodiert)
            .replacingOccurrences(of: "{type}", with: typKodiert)
        guard let url = URL(string: text) else { throw MailFehler.nichtGefunden }
        var anfrage = URLRequest(url: url)
        anfrage.setValue(authKopf, forHTTPHeaderField: "Authorization")
        let (daten, antwort) = try await laden(anfrage)
        try pruefeStatus(antwort, daten)
        return daten
    }

    private func laden(_ anfrage: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: anfrage)
        } catch let f as URLError {
            switch f.code {
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid, .secureConnectionFailed:
                throw MailFehler.zertifikat
            default:
                throw MailFehler.verbindung(f.localizedDescription)
            }
        }
    }

    private func pruefeStatus(_ antwort: URLResponse, _ daten: Data) throws {
        guard let h = antwort as? HTTPURLResponse else { return }
        if h.statusCode == 401 || h.statusCode == 403 { throw MailFehler.anmeldung }
        if !(200..<300).contains(h.statusCode) {
            let text = String(data: daten.prefix(300), encoding: .utf8) ?? ""
            throw MailFehler.server("HTTP \(h.statusCode) \(text)")
        }
    }
}

/// Behält den Authorization-Kopf bei Weiterleitungen auf demselben Host (/.well-known/jmap → /jmap/session).
private final class AuthWeiterleitung: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        var neu = request
        if let alt = task.originalRequest, alt.url?.host == request.url?.host,
           let auth = alt.value(forHTTPHeaderField: "Authorization") {
            neu.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        return neu
    }
}
