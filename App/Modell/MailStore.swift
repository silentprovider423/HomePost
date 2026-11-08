import Foundation
import Network
import SwiftUI
import UserNotifications

/// Intelligente Postfächer (Grundausstattung wie Apple), über alle Posteingänge.
enum IntelligentesPostfach: String, CaseIterable, Codable, Sendable, Hashable {
    case vip, markiert, ungelesen, anKopie, anhaenge, heute

    var titel: LocalizedStringKey {
        switch self {
        case .vip: "VIP"
        case .markiert: "Markiert"
        case .ungelesen: "Ungelesen"
        case .anKopie: "An/Kopie"
        case .anhaenge: "Anhänge"
        case .heute: "Heute"
        }
    }

    var symbol: String {
        switch self {
        case .vip: "star"
        case .markiert: "flag"
        case .ungelesen: "envelope.badge"
        case .anKopie: "person.crop.circle"
        case .anhaenge: "paperclip"
        case .heute: "calendar"
        }
    }
}

/// Was eine Liste zeigt.
enum ListenQuelle: Hashable, Sendable {
    case postfach(UUID, String)
    case alleEingaenge
    case intelligent(IntelligentesPostfach)
}

/// Eine Aktion wirkt überall gleich (Wischgeste, Aktionskarte, Bearbeiten-Leiste) – wie Apples `MS…TriageAction`.
enum MailAktion: Sendable {
    case gelesen(Bool)
    case markieren(Bool, FahnenFarbe?)
    case loeschen
    case archivieren
    case bewegen(Postfach)
    case spam
    case keinSpam
    case kopieren(Postfach)
}

struct WiderrufEintrag: Identifiable {
    let id = UUID()
    let text: String
    let konto: UUID
    let koepfe: [NachrichtKopf]
    let von: Postfach
    let nach: Postfach
}

struct AusgangEintrag: Identifiable {
    let id = UUID()
    let konto: UUID
    let nachricht: AusgehendeNachricht
    let antwortAuf: NachrichtKopf?
    let weitergeleitet: Bool
    let entwurf: NachrichtKopf?
    var task: Task<Void, Never>?
}

@MainActor
@Observable
final class MailStore {
    static let shared = MailStore()

    private(set) var konten: [KontoKonfiguration] = []
    private var backends: [UUID: any MailBackend] = [:]
    private(set) var postfaecher: [UUID: [Postfach]] = [:]
    private(set) var listen: [ListenQuelle: [NachrichtKopf]] = [:]
    private(set) var laedt: Set<ListenQuelle> = []
    private(set) var letzteAktualisierung: Date?
    var fehler: String?
    var widerruf: WiderrufEintrag?
    private(set) var ausgang: [AusgangEintrag] = []
    /// zum erneuten Öffnen nach „Senden widerrufen“
    var wiederOeffnen: AusgangEintrag?
    var vip: Set<String> = []
    /// offenes Verfassen-Fenster
    var verfassenAuftrag: VerfassenAuftrag?
    /// Debug-Konten aus der Startumgebung (nie gespeichert)
    private var debugPasswoerter: [UUID: String] = [:]
    var debugKonten: Bool { !debugPasswoerter.isEmpty }

    private let cache = MailCache.shared

    init() {
        Einstellung.registrieren()
        vip = Set(Einstellung.d.stringArray(forKey: Einstellung.vip) ?? [])
        kontenLaden()
        pfadBeobachten()
    }

    // MARK: Konten

    private static let kontenSchluessel = "konten.v1"

    private func kontenLaden() {
        #if DEBUG
        if let debug = DebugAnmeldung.konten(), !debug.isEmpty {
            konten = debug.map(\.0)
            for (k, pw) in debug { debugPasswoerter[k.id] = pw }
            return
        }
        #endif
        if let d = Einstellung.d.data(forKey: Self.kontenSchluessel),
           let k = try? JSONDecoder().decode([KontoKonfiguration].self, from: d) {
            konten = k
        }
    }

    private func kontenSichern() {
        guard debugPasswoerter.isEmpty else { return }
        if let d = try? JSONEncoder().encode(konten) { Einstellung.d.set(d, forKey: Self.kontenSchluessel) }
    }

    func kontoHinzufuegen(_ k: KontoKonfiguration, passwort: String) throws {
        try Schluesselbund.sichern(passwort, fuer: k.id)
        konten.append(k)
        kontenSichern()
        Task { await aktualisierenAlles() }
    }

    func kontoAendern(_ k: KontoKonfiguration, passwort: String?) throws {
        if let passwort, !passwort.isEmpty { try Schluesselbund.sichern(passwort, fuer: k.id) }
        if let i = konten.firstIndex(where: { $0.id == k.id }) { konten[i] = k }
        if let b = backends.removeValue(forKey: k.id) { Task { await b.trennen() } }
        kontenSichern()
        Task { await aktualisierenAlles() }
    }

    func kontoEntfernen(_ k: KontoKonfiguration) {
        konten.removeAll { $0.id == k.id }
        Schluesselbund.loeschen(fuer: k.id)
        if let b = backends.removeValue(forKey: k.id) { Task { await b.trennen() } }
        postfaecher[k.id] = nil
        listen = listen.filter { key, _ in
            if case .postfach(let id, _) = key { return id != k.id }
            return true
        }
        kontenSichern()
        Task { await cache.kontoEntfernen(k.id) }
    }

    func konto(_ id: UUID) -> KontoKonfiguration? { konten.first { $0.id == id } }

    func backend(_ konto: UUID) throws -> any MailBackend {
        if let b = backends[konto] { return b }
        guard let k = self.konto(konto) else { throw MailFehler.nichtGefunden }
        guard let pw = debugPasswoerter[konto] ?? Schluesselbund.laden(fuer: konto) else { throw MailFehler.anmeldung }
        let b = try BackendFabrik.backend(fuer: k, passwort: pw)
        backends[konto] = b
        return b
    }

    var standardKonto: KontoKonfiguration? {
        let id = Einstellung.d.string(forKey: Einstellung.standardKonto).flatMap(UUID.init)
        return konten.first { $0.id == id } ?? konten.first
    }

    // MARK: Postfächer

    func postfach(_ konto: UUID, _ rolle: PostfachRolle) -> Postfach? {
        postfaecher[konto]?.first { $0.rolle == rolle }
    }

    func postfach(_ konto: UUID, id: String) -> Postfach? {
        postfaecher[konto]?.first { $0.id == id }
    }

    func postfaecherLaden(_ konto: UUID) async {
        do {
            let p = try await backend(konto).postfaecher()
            postfaecher[konto] = p
            verbindungOK()
        } catch {
            melde(error)
        }
    }

    var ungelesenGesamt: Int {
        konten.compactMap { postfach($0.id, .eingang)?.ungelesen }.reduce(0, +)
    }

    // MARK: Listen

    func titel(_ q: ListenQuelle) -> String {
        switch q {
        case .alleEingaenge: return String(localized: "Alle Posteingänge")
        case .intelligent(let i):
            switch i {
            case .vip: return "VIP"
            case .markiert: return String(localized: "Markiert")
            case .ungelesen: return String(localized: "Ungelesen")
            case .anKopie: return String(localized: "An/Kopie")
            case .anhaenge: return String(localized: "Anhänge")
            case .heute: return String(localized: "Heute")
            }
        case .postfach(let k, let id):
            guard let p = postfach(k, id: id) else { return "" }
            return Self.anzeigeName(p)
        }
    }

    static func anzeigeName(_ p: Postfach) -> String {
        switch p.rolle {
        case .eingang: String(localized: "Eingang")
        case .entwuerfe: String(localized: "Entwürfe")
        case .gesendet: String(localized: "Gesendet")
        case .spam: String(localized: "Spam")
        case .papierkorb: String(localized: "Papierkorb")
        case .archiv: String(localized: "Archiv")
        case .keine: p.name
        }
    }

    /// Lädt erst den lokalen Stand (sofort), dann den Server.
    func laden(_ q: ListenQuelle) async {
        if listen[q] == nil { listen[q] = await lokal(q) }
        laedt.insert(q)
        defer { laedt.remove(q) }
        do {
            try await wartendeNachholen()
            switch q {
            case .postfach(let k, let id):
                if postfaecher[k] == nil { await postfaecherLaden(k) }
                guard let p = postfach(k, id: id) else { return }
                let liste = try await backend(k).nachrichten(in: p, anzahl: 100)
                listen[q] = liste
                await cache.speichern(liste, konto: k, postfach: id)
            case .alleEingaenge, .intelligent:
                var alle: [NachrichtKopf] = []
                for k in konten {
                    if postfaecher[k.id] == nil { await postfaecherLaden(k.id) }
                    guard let e = postfach(k.id, .eingang) else { continue }
                    let liste = try await backend(k.id).nachrichten(in: e, anzahl: 100)
                    listen[.postfach(k.id, e.id)] = liste
                    await cache.speichern(liste, konto: k.id, postfach: e.id)
                    alle += liste
                }
                listen[.alleEingaenge] = alle.sorted { $0.datum > $1.datum }
                for i in IntelligentesPostfach.allCases { listen[.intelligent(i)] = filtern(alle, i) }
            }
            letzteAktualisierung = Date()
            verbindungOK()
        } catch {
            melde(error)
        }
    }

    private func lokal(_ q: ListenQuelle) async -> [NachrichtKopf] {
        switch q {
        case .postfach(let k, let id): return await cache.laden(konto: k, postfach: id)
        case .alleEingaenge, .intelligent:
            var alle: [NachrichtKopf] = []
            for k in konten {
                if let e = postfach(k.id, .eingang) { alle += await cache.laden(konto: k.id, postfach: e.id) }
            }
            alle.sort { $0.datum > $1.datum }
            if case .intelligent(let i) = q { return filtern(alle, i) }
            return alle
        }
    }

    func filtern(_ liste: [NachrichtKopf], _ i: IntelligentesPostfach) -> [NachrichtKopf] {
        let eigene = Set(konten.map { $0.adresse.lowercased() })
        return liste.filter { k in
            switch i {
            case .vip: return k.von.contains { vip.contains($0.email.lowercased()) }
            case .markiert: return k.markiert
            case .ungelesen: return !k.gelesen
            case .anKopie: return (k.an + k.kopie).contains { eigene.contains($0.email.lowercased()) }
            case .anhaenge: return k.hatAnhang
            case .heute: return Calendar.current.isDateInToday(k.datum)
            }
        }
    }

    func aktualisierenAlles() async {
        for k in konten { await postfaecherLaden(k.id) }
        await laden(.alleEingaenge)
    }

    /// Statuszeile wie Apple („Gerade aktualisiert“, „Um 14:02 aktualisiert“).
    var statusText: String {
        if offline && laedt.isEmpty { return String(localized: "Keine Verbindung") }
        if !laedt.isEmpty { return String(localized: "Nach E‑Mails suchen …") }
        if !ausgang.isEmpty { return String(localized: "Senden …") }
        guard let d = letzteAktualisierung else { return "" }
        if Date().timeIntervalSince(d) < 60 { return String(localized: "Gerade aktualisiert") }
        return String(localized: "Um \(d.formatted(date: .omitted, time: .shortened)) aktualisiert")
    }

    // MARK: Lokale Änderungen (sofort sichtbar)

    private func lokalAendern(_ ids: Set<String>, _ aendern: (inout NachrichtKopf) -> Void) {
        for (q, l) in listen {
            var neu = l
            var geaendert = false
            for i in neu.indices where ids.contains(neu[i].id) {
                aendern(&neu[i]); geaendert = true
            }
            if geaendert { listen[q] = neu }
        }
    }

    private func lokalEntfernen(_ ids: Set<String>) {
        for (q, l) in listen where l.contains(where: { ids.contains($0.id) }) {
            listen[q] = l.filter { !ids.contains($0.id) }
        }
    }

    private func ungelesenAnpassen(_ koepfe: [NachrichtKopf], _ delta: Int) {
        for k in koepfe {
            guard var liste = postfaecher[k.kontoID] else { continue }
            for i in liste.indices where k.postfachIDs.contains(liste[i].id) {
                liste[i].ungelesen = max(0, liste[i].ungelesen + delta)
            }
            postfaecher[k.kontoID] = liste
        }
    }

    // MARK: Aktionen

    /// Ausgangspostfach einer Nachricht in der aktuellen Ansicht.
    func quelle(_ k: NachrichtKopf, in q: ListenQuelle?) -> Postfach? {
        if case .postfach(let konto, let id)? = q, konto == k.kontoID, let p = postfach(konto, id: id),
           k.postfachIDs.contains(id) {
            return p
        }
        return k.postfachIDs.lazy.compactMap { self.postfach(k.kontoID, id: $0) }.first
    }

    /// Wendet eine Aktion an (gruppiert nach Konto), sofort sichtbar, Fehler ohne Netz → Warteschlange.
    func ausfuehren(_ aktion: MailAktion, _ koepfe: [NachrichtKopf], in q: ListenQuelle? = nil) async {
        for (konto, gruppe) in Dictionary(grouping: koepfe, by: \.kontoID) {
            await ausfuehren(aktion, gruppe, konto: konto, in: q)
        }
    }

    private func ausfuehren(_ aktion: MailAktion, _ koepfe: [NachrichtKopf], konto: UUID, in q: ListenQuelle?) async {
        guard let b = try? backend(konto) else { return }
        let ids = Set(koepfe.map(\.id))
        do {
            switch aktion {
            case .gelesen(let g):
                let betroffen = koepfe.filter { $0.gelesen != g }
                lokalAendern(ids) { $0.gelesen = g }
                ungelesenAnpassen(betroffen, g ? -1 : 1)
                do { try await b.setzeGelesen(koepfe, g) } catch let f as MailFehler {
                    if case .verbindung = f {
                        await cache.einreihen(WartendeAktion(konto: konto, art: g ? .gelesen : .ungelesen, koepfe: koepfe))
                    } else { throw f }
                }
            case .markieren(let m, let farbe):
                lokalAendern(ids) { $0.markiert = m; $0.fahne = farbe ?? .rot }
                do { try await b.setzeMarkierung(koepfe, m, farbe: farbe) } catch let f as MailFehler {
                    if case .verbindung = f {
                        await cache.einreihen(WartendeAktion(konto: konto, art: m ? .markieren : .entmarkieren,
                                                             koepfe: koepfe, farbe: farbe))
                    } else { throw f }
                }
            case .loeschen:
                guard let von = koepfe.first.flatMap({ quelle($0, in: q) }) else { return }
                if von.rolle == .papierkorb || von.rolle == .spam || von.rolle == .entwuerfe {
                    lokalEntfernen(ids)
                    try await b.endgueltigLoeschen(koepfe, in: von)
                } else if Einstellung.d.bool(forKey: Einstellung.archivStattLoeschen), let ziel = postfach(konto, .archiv) {
                    try await bewegen(koepfe, von: von, nach: ziel, b: b)
                } else {
                    guard let ziel = postfach(konto, .papierkorb) else { throw MailFehler.keinPostfach(.papierkorb) }
                    try await bewegen(koepfe, von: von, nach: ziel, b: b)
                }
            case .archivieren:
                guard let von = koepfe.first.flatMap({ quelle($0, in: q) }) else { return }
                if postfach(konto, .archiv) == nil {
                    // Archiv anlegen lassen (Backend legt „Archive“ an) und Liste neu holen
                    try await b.postfachAnlegen(name: "Archive", in: nil)
                    await postfaecherLaden(konto)
                }
                guard let ziel = postfach(konto, .archiv) else { throw MailFehler.keinPostfach(.archiv) }
                try await bewegen(koepfe, von: von, nach: ziel, b: b)
            case .bewegen(let ziel):
                guard let von = koepfe.first.flatMap({ quelle($0, in: q) }), von.id != ziel.id else { return }
                try await bewegen(koepfe, von: von, nach: ziel, b: b)
            case .spam:
                guard let von = koepfe.first.flatMap({ quelle($0, in: q) }), let ziel = postfach(konto, .spam) else { return }
                try await bewegen(koepfe, von: von, nach: ziel, b: b)
            case .keinSpam:
                guard let von = koepfe.first.flatMap({ quelle($0, in: q) }), let ziel = postfach(konto, .eingang) else { return }
                try await bewegen(koepfe, von: von, nach: ziel, b: b)
            case .kopieren(let ziel):
                guard let von = koepfe.first.flatMap({ quelle($0, in: q) }) else { return }
                try await b.kopieren(koepfe, von: von, nach: ziel)
                await postfaecherLaden(konto)
            }
        } catch {
            melde(error)
            if let q { await laden(q) }
        }
    }

    private func bewegen(_ koepfe: [NachrichtKopf], von: Postfach, nach: Postfach, b: any MailBackend) async throws {
        let ids = Set(koepfe.map(\.id))
        lokalEntfernen(ids)
        let ungelesen = koepfe.filter { !$0.gelesen }.count
        let konto = koepfe[0].kontoID
        if var liste = postfaecher[konto] {
            for i in liste.indices {
                if liste[i].id == von.id { liste[i].ungelesen = max(0, liste[i].ungelesen - ungelesen); liste[i].gesamt -= koepfe.count }
                if liste[i].id == nach.id { liste[i].ungelesen += ungelesen; liste[i].gesamt += koepfe.count }
            }
            postfaecher[konto] = liste
        }
        let neu = try await b.bewegen(koepfe, von: von, nach: nach)
        let anzahl = koepfe.count
        let text = anzahl == 1
            ? String(localized: "1 E‑Mail in „\(Self.anzeigeName(nach))“ bewegt")
            : String(localized: "\(anzahl) E‑Mails in „\(Self.anzeigeName(nach))“ bewegt")
        widerruf = WiderrufEintrag(text: text, konto: koepfe[0].kontoID, koepfe: neu, von: von, nach: nach)
        listen[.postfach(koepfe[0].kontoID, nach.id)] = nil
    }

    /// „Widerrufen“: Gegenoperation (zurückbewegen mit den neuen IDs/UIDs).
    func widerrufen() async {
        guard let w = widerruf else { return }
        widerruf = nil
        do {
            let b = try backend(w.konto)
            try await b.bewegen(w.koepfe, von: w.nach, nach: w.von)
            await postfaecherLaden(w.konto)
            await laden(.postfach(w.konto, w.von.id))
            if w.von.rolle == .eingang { await laden(.alleEingaenge) }
        } catch {
            melde(error)
        }
    }

    func vipUmschalten(_ adresse: String) {
        let a = adresse.lowercased()
        if vip.contains(a) { vip.remove(a) } else { vip.insert(a) }
        Einstellung.d.set(Array(vip), forKey: Einstellung.vip)
        if let alle = listen[.alleEingaenge] { listen[.intelligent(.vip)] = filtern(alle, .vip) }
    }

    func wartendeNachholen() async throws {
        for (nr, aktion) in await cache.wartende() {
            guard let b = try? backend(aktion.konto) else { await cache.erledigt(nr); continue }
            do {
                try await aktion.ausfuehren(mit: b)
                await cache.erledigt(nr)
            } catch MailFehler.verbindung(let t) {
                throw MailFehler.verbindung(t)
            } catch {
                await cache.erledigt(nr)
            }
        }
    }

    // MARK: Lesen

    func konversation(_ k: NachrichtKopf) async throws -> [NachrichtKopf] {
        try await backend(k.kontoID).konversation(zu: k)
    }

    func inhalt(_ k: NachrichtKopf) async throws -> NachrichtInhalt {
        do {
            let i = try await backend(k.kontoID).inhalt(von: k)
            await cache.inhaltSpeichern(i, konto: k.kontoID, id: k.id)
            return i
        } catch {
            if let i = await cache.inhalt(konto: k.kontoID, id: k.id) { return i }
            throw error
        }
    }

    func anhang(_ a: AnhangInfo, von k: NachrichtKopf) async throws -> Data {
        try await backend(k.kontoID).anhang(a, von: k)
    }

    func rohdaten(_ k: NachrichtKopf) async throws -> Data {
        try await backend(k.kontoID).rohdaten(von: k)
    }

    // MARK: Suche

    /// Lokale Treffer sofort, Server-Treffer danach (Ergebnis zusammengeführt, neueste zuerst).
    func suchenLokal(_ text: String, konto: UUID?) async -> [NachrichtKopf] {
        await cache.suchen(text, konto: konto)
    }

    func suchenServer(_ text: String, in q: ListenQuelle?) async -> [NachrichtKopf] {
        var treffer: [NachrichtKopf] = []
        let ziele: [(UUID, Postfach?)]
        if case .postfach(let k, let id)? = q { ziele = [(k, postfach(k, id: id))] } else { ziele = konten.map { ($0.id, nil) } }
        for (k, p) in ziele {
            do { treffer += try await backend(k).suchen(text, in: p) } catch { melde(error) }
        }
        return treffer.sorted { $0.datum > $1.datum }
    }

    // MARK: Postfächer verwalten

    func postfachAnlegen(_ konto: UUID, name: String, in eltern: Postfach?) async {
        do {
            try await backend(konto).postfachAnlegen(name: name, in: eltern)
            await postfaecherLaden(konto)
        } catch { melde(error) }
    }

    func postfachUmbenennen(_ konto: UUID, _ p: Postfach, in name: String) async {
        do {
            try await backend(konto).postfachUmbenennen(p, in: name)
            await postfaecherLaden(konto)
        } catch { melde(error) }
    }

    func postfachLoeschen(_ konto: UUID, _ p: Postfach) async {
        do {
            try await backend(konto).postfachLoeschen(p)
            listen[.postfach(konto, p.id)] = nil
            await postfaecherLaden(konto)
        } catch { melde(error) }
    }

    // MARK: Versand (mit „Senden widerrufen“)

    func senden(_ n: AusgehendeNachricht, konto: UUID, antwortAuf: NachrichtKopf?, weitergeleitet: Bool,
                entwurf: NachrichtKopf?) {
        let verzoegerung = Einstellung.d.integer(forKey: Einstellung.sendeVerzoegerung)
        var eintrag = AusgangEintrag(konto: konto, nachricht: n, antwortAuf: antwortAuf, weitergeleitet: weitergeleitet,
                                     entwurf: entwurf)
        let id = eintrag.id
        eintrag.task = Task { [weak self] in
            if verzoegerung > 0 {
                try? await Task.sleep(for: .seconds(verzoegerung))
                if Task.isCancelled { return }
            }
            await self?.wirklichSenden(id)
        }
        ausgang.append(eintrag)
    }

    func sendenWiderrufen(_ id: UUID) {
        guard let i = ausgang.firstIndex(where: { $0.id == id }) else { return }
        ausgang[i].task?.cancel()
        let e = ausgang.remove(at: i)
        wiederOeffnen = e
    }

    private func wirklichSenden(_ id: UUID) async {
        guard let e = ausgang.first(where: { $0.id == id }) else { return }
        defer { ausgang.removeAll { $0.id == id } }
        do {
            let b = try backend(e.konto)
            try await b.senden(e.nachricht)
            if let orig = e.antwortAuf {
                try? await b.setzeBeantwortet(orig, weitergeleitet: e.weitergeleitet)
                lokalAendern([orig.id]) { if e.weitergeleitet { $0.weitergeleitet = true } else { $0.beantwortet = true } }
            }
            if let alt = e.entwurf { try? await b.entwurfLoeschen(alt) }
            await postfaecherLaden(e.konto)
            if let g = postfach(e.konto, .gesendet) { listen[.postfach(e.konto, g.id)] = nil }
        } catch {
            // nichts verlieren: als Entwurf sichern
            _ = try? await backend(e.konto).entwurfSichern(e.nachricht, ersetzt: e.entwurf)
            fehler = String(localized: "Die E‑Mail konnte nicht gesendet werden und liegt jetzt in „Entwürfe“. \(error.localizedDescription)")
        }
    }

    func entwurfSichern(_ n: AusgehendeNachricht, konto: UUID, ersetzt: NachrichtKopf?) async {
        do {
            try await backend(konto).entwurfSichern(n, ersetzt: ersetzt)
            await postfaecherLaden(konto)
            if let p = postfach(konto, .entwuerfe) { await laden(.postfach(konto, p.id)) }
        } catch { melde(error) }
    }

    func entwurfLoeschen(_ k: NachrichtKopf) async {
        do {
            try await backend(k.kontoID).entwurfLoeschen(k)
            lokalEntfernen([k.id])
            await postfaecherLaden(k.kontoID)
        } catch { melde(error) }
    }

    /// Bekannte Adressen für Vorschläge beim Verfassen (aus dem eigenen Verlauf).
    func adressVorschlaege(_ text: String) -> [MailAdresse] {
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard t.count >= 1 else { return [] }
        var gesehen: Set<String> = []
        var ergebnis: [MailAdresse] = []
        for l in listen.values {
            for k in l {
                for a in k.von + k.an + k.kopie where gesehen.insert(a.email.lowercased()).inserted {
                    if a.email.lowercased().contains(t) || (a.name?.lowercased().contains(t) ?? false) { ergebnis.append(a) }
                }
            }
        }
        return Array(ergebnis.prefix(6))
    }

    // MARK: Hintergrundabruf

    /// Holt neue E-Mails aller Posteingänge, meldet neue ungelesene per Mitteilung, setzt das Kennzeichen am Symbol.
    func hintergrundAbruf() async {
        var neue: [NachrichtKopf] = []
        for k in konten {
            do {
                let b = try backend(k.id)
                let liste = try await b.postfaecher()
                postfaecher[k.id] = liste
                guard let e = liste.first(where: { $0.rolle == .eingang }) else { continue }
                let mails = try await b.nachrichten(in: e, anzahl: 30)
                await cache.speichern(mails, konto: k.id, postfach: e.id)
                listen[.postfach(k.id, e.id)] = mails
                let schluessel = "bekannt.\(k.id.uuidString)"
                let bekannt = Set(Einstellung.d.stringArray(forKey: schluessel) ?? [])
                if !bekannt.isEmpty {
                    neue += mails.filter { !$0.gelesen && !bekannt.contains($0.id) }
                }
                Einstellung.d.set(mails.map(\.id), forKey: schluessel)
            } catch {
                continue
            }
        }
        letzteAktualisierung = Date()
        let zentrale = UNUserNotificationCenter.current()
        if Einstellung.d.bool(forKey: Einstellung.mitteilungen) {
            for m in neue.prefix(5) {
                let inhalt = UNMutableNotificationContent()
                inhalt.title = m.absender?.anzeige ?? ""
                inhalt.subtitle = m.betreff
                inhalt.body = m.vorschau
                inhalt.sound = .default
                inhalt.threadIdentifier = m.threadID
                inhalt.userInfo = ["konto": m.kontoID.uuidString, "id": m.id]
                try? await zentrale.add(UNNotificationRequest(identifier: m.id, content: inhalt, trigger: nil))
            }
        }
        try? await zentrale.setBadgeCount(ungelesenGesamt)
    }

    // MARK: Fehler

    /// Netzwerkfehler erscheinen wie bei Apple nur als Status unten („Keine Verbindung“) und werden
    /// selbst erneut versucht; Anmelde-, Zertifikats- und Serverfehler weiter als Hinweis.
    func melde(_ error: Error) {
        if error is CancellationError { return }
        if Self.istVerbindungsfehler(error) {
            offlineMelden()
            return
        }
        fehler = error.localizedDescription
    }

    static func istVerbindungsfehler(_ error: Error) -> Bool {
        if case MailFehler.verbindung = error { return true }
        if let u = error as? URLError {
            switch u.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost,
                 .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
                return true
            default: return false
            }
        }
        return false
    }

    // MARK: Offline / erneut versuchen

    /// Kein Server erreichbar (Status „Keine Verbindung“ statt Fehlerdialog)
    private(set) var offline = false
    /// Abstände der automatischen Wiederholungen nach einem Verbindungsfehler
    var wiederholAbstaende: [Duration] = [.seconds(2), .seconds(5), .seconds(15)]
    /// Was beim Wiederholen passiert (Standard: alles neu laden; Tests setzen eigene Aktion)
    var wiederholAktion: (@MainActor () async -> Void)?
    private(set) var wiederholZaehler = 0
    private var wiederholTask: Task<Void, Never>?
    private let pfadMonitor = NWPathMonitor()

    func offlineMelden() {
        offline = true
        guard wiederholTask == nil else { return }
        let abstaende = wiederholAbstaende
        wiederholTask = Task { [weak self] in
            for a in abstaende {
                try? await Task.sleep(for: a)
                guard let self, !Task.isCancelled, self.offline else { break }
                self.wiederholZaehler += 1
                await self.erneutVersuchen()
            }
            self?.wiederholTask = nil
        }
    }

    func verbindungOK() {
        offline = false
        wiederholTask?.cancel()
        wiederholTask = nil
    }

    func erneutVersuchen() async {
        if let a = wiederholAktion { await a() } else { await aktualisierenAlles() }
    }

    /// Netz wieder da oder App wieder aktiv (z. B. nach der Abfrage „Lokales Netzwerk“): sofort neu versuchen.
    func verbindungVielleichtWieder() {
        guard offline else { return }
        Task { await erneutVersuchen() }
    }

    private func pfadBeobachten() {
        pfadMonitor.pathUpdateHandler = { [weak self] pfad in
            guard pfad.status == .satisfied else { return }
            Task { @MainActor in self?.verbindungVielleichtWieder() }
        }
        pfadMonitor.start(queue: DispatchQueue(label: "homepost.netzpfad"))
    }
}

#if DEBUG
/// Debug-Builds: Anmeldung über die Startumgebung (Simulator-/iPhone-Tests ohne Passwort-Tippen), nie in Release.
///   HOMEPOST_SERVER/USER/PASSWORD (siehe einzelKonto) oder mehrere Konten:
///   HOMEPOST_KONTO1="jmap;<url>;<benutzer>;<passwort>;<Name>"
///   HOMEPOST_KONTO2="imap;<host>;<benutzer>;<passwort>;<Name>;unverschluesselt"
enum DebugAnmeldung {
    static func konten() -> [(KontoKonfiguration, String)]? {
        let env = ProcessInfo.processInfo.environment
        var ergebnis: [(KontoKonfiguration, String)] = []
        if let k = einzelKonto(env) { ergebnis.append(k) }
        for i in 1...5 {
            guard let s = env["HOMEPOST_KONTO\(i)"] else { continue }
            let t = s.components(separatedBy: ";")
            guard t.count >= 5 else { continue }
            let name = t[4]
            var k = KontoKonfiguration(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(i)")!, name: name,
                                       vollerName: name, adresse: t[2], benutzer: t[2],
                                       protokoll: t[0] == "imap" ? .imap : .jmap)
            if k.protokoll == .jmap {
                k.jmapURL = t[1]
            } else {
                k.imapHost = t[1]; k.smtpHost = t[1]
                let offen = t.count > 5 && t[5] == "unverschluesselt"
                k.sicherheit = offen ? .unverschluesselt : .tls
                k.imapPort = offen ? 143 : 993; k.smtpPort = offen ? 587 : 465
            }
            ergebnis.append((k, t[3]))
        }
        return ergebnis.isEmpty ? nil : ergebnis
    }

    /// Einzelkonto wie bei den anderen Apps (iPhone-Test per devicectl, .test-account):
    ///   HOMEPOST_SERVER   JMAP-URL (http://host:8080 / https://host) oder IMAP/SMTP-Host
    ///   HOMEPOST_USER, HOMEPOST_PASSWORD, optional HOMEPOST_NAME
    ///   HOMEPOST_PROTOCOL jmap|imap (Standard: URL → jmap, reiner Host → imap)
    ///   HOMEPOST_INSECURE=1 unverschlüsselt (nur Heimnetz-Testserver), HOMEPOST_IMAP_PORT, HOMEPOST_SMTP_PORT
    /// Nichts davon wird gespeichert (kein Schlüsselbund, keine UserDefaults).
    static func einzelKonto(_ env: [String: String]) -> (KontoKonfiguration, String)? {
        guard let server = env["HOMEPOST_SERVER"], !server.isEmpty, let user = env["HOMEPOST_USER"], !user.isEmpty,
              let pw = env["HOMEPOST_PASSWORD"], !pw.isEmpty else { return nil }
        let unsicher = ["1", "true", "yes", "ja"].contains((env["HOMEPOST_INSECURE"] ?? "").lowercased())
        let name = env["HOMEPOST_NAME"].flatMap { $0.isEmpty ? nil : $0 } ?? user
        let istURL = server.contains("://")
        let proto: MailProtokoll = env["HOMEPOST_PROTOCOL"].map { $0.lowercased() == "imap" ? .imap : .jmap } ?? (istURL ? .jmap : .imap)
        var k = KontoKonfiguration(id: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, name: name,
                                   vollerName: name, adresse: user, benutzer: user, protokoll: proto)
        let host = istURL ? (URL(string: server)?.host ?? server) : server
        if proto == .jmap {
            k.jmapURL = istURL ? server : (unsicher ? "http://\(server):8080" : "https://\(server)")
        } else {
            k.imapHost = host; k.smtpHost = host
            k.sicherheit = unsicher ? .unverschluesselt : .tls
            k.imapPort = Int(env["HOMEPOST_IMAP_PORT"] ?? "") ?? (unsicher ? 143 : 993)
            k.smtpPort = Int(env["HOMEPOST_SMTP_PORT"] ?? "") ?? (unsicher ? 587 : 465)
        }
        return (k, pw)
    }
}
#endif
