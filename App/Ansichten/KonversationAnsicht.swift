import QuickLook
import SwiftUI

/// Konversationsansicht wie Apple: alle E-Mails untereinander, gelesene zugeklappt, Kopf mit „Details“,
/// Inhalt sicher in einer WebView, Banner für blockierte Bilder, Anhänge mit Übersicht.
struct KonversationAnsicht: View {
    let kopf: NachrichtKopf
    let quelle: ListenQuelle?
    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var schliessen
    @AppStorage(Einstellung.gelesenReduzieren) private var gelesenReduzieren = true
    @AppStorage(Einstellung.neuesteOben) private var neuesteOben = false
    @AppStorage(Einstellung.archivStattLoeschen) private var archivStattLoeschen = false

    @State private var nachrichten: [NachrichtKopf] = []
    @State private var aufgeklappt: Set<String> = []
    @State private var bewegen: [NachrichtKopf]?
    @State private var aktionskarte: NachrichtKopf?

    private var reihenfolge: [NachrichtKopf] {
        let n = nachrichten.isEmpty ? [kopf] : nachrichten
        return neuesteOben ? n.reversed() : n
    }

    /// aktuelle Fassung (Flags) aus den Listen des Stores
    private func aktuell(_ k: NachrichtKopf) -> NachrichtKopf {
        for l in store.listen.values { if let f = l.first(where: { $0.id == k.id }) { return f } }
        return k
    }

    /// Betreff der Konversation (erste E-Mail, ohne „Re:“), wie Apple
    private var titel: String {
        let b = (nachrichten.first ?? kopf).betreff
        return b.isEmpty ? String(localized: "Kein Betreff") : b
    }

    private var letzte: NachrichtKopf { aktuell(nachrichten.last ?? kopf) }

    var body: some View {
        ScrollViewReader { leser in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(titel)
                        .font(.title2.weight(.bold))
                        .padding(.horizontal)
                        .padding(.top, 4)
                        .accessibilityIdentifier("betreff")
                    if nachrichten.count > 1 {
                        Text("\(nachrichten.count) E‑Mails").font(.subheadline).foregroundStyle(.secondary).padding(.horizontal)
                    }
                    ForEach(reihenfolge) { k in
                        NachrichtKarte(kopf: aktuell(k), aufgeklappt: aufgeklappt.contains(k.id), quelle: quelle,
                                       umschalten: { withAnimation { umschalten(k) } },
                                       bewegen: { bewegen = [aktuell(k)] },
                                       mehr: { aktionskarte = aktuell(k) },
                                       entfernt: { entfernt(k) })
                        .id(k.id)
                    }
                }
                .padding(.bottom, 24)
            }
            .task {
                await laden()
                if let ziel = neuesteOben ? reihenfolge.first : reihenfolge.last { leser.scrollTo(ziel.id, anchor: .top) }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(FahnenFarbe.allCases, id: \.self) { f in
                        Button { Task { await store.ausfuehren(.markieren(true, f), [letzte], in: quelle) } } label: {
                            Label { Text(f.titel) } icon: { Image(systemName: "flag.fill") }
                        }
                    }
                    if letzte.markiert {
                        Button("Markierung entfernen", systemImage: "flag.slash") {
                            Task { await store.ausfuehren(.markieren(false, nil), [letzte], in: quelle) }
                        }
                    }
                } label: {
                    Label("Markieren", systemImage: letzte.markiert ? "flag.fill" : "flag")
                        .foregroundStyle(letzte.markiert ? letzte.fahne.farbe : Color.primary)
                } primaryAction: {
                    let m = !letzte.markiert
                    Task { await store.ausfuehren(.markieren(m, m ? .orange : nil), [letzte], in: quelle) }
                }
                .accessibilityIdentifier("markieren")
            }
            ToolbarItem(placement: .bottomBar) {
                Button(archivStattLoeschen ? "Archivieren" : "Löschen", systemImage: archivStattLoeschen ? "archivebox" : "trash") {
                    let k = letzte
                    Task {
                        await store.ausfuehren(archivStattLoeschen ? .archivieren : .loeschen, [k], in: quelle)
                        entfernt(k)
                    }
                }
                .accessibilityIdentifier("loeschen")
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button("Bewegen", systemImage: "folder") { bewegen = [letzte] }
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) { AntwortenMenue(kopf: letzte) }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) { VerfassenKnopf() }
        }
        .sheet(item: Binding(get: { bewegen.map { BewegenAuftrag(koepfe: $0) } }, set: { bewegen = $0?.koepfe })) { a in
            BewegenAnsicht(koepfe: a.koepfe, quelle: quelle) { a.koepfe.forEach(entfernt) }
        }
        .sheet(item: $aktionskarte) { k in
            AktionskarteAnsicht(kopf: k, quelle: quelle, entfernt: { entfernt(k) })
                .presentationDetents([.medium, .large])
        }
    }

    private func umschalten(_ k: NachrichtKopf) {
        if aufgeklappt.contains(k.id) { aufgeklappt.remove(k.id) } else { aufgeklappt.insert(k.id) }
    }

    private func entfernt(_ k: NachrichtKopf) {
        nachrichten.removeAll { $0.id == k.id }
        if nachrichten.isEmpty { schliessen() }
    }

    private func laden() async {
        do {
            let liste = try await store.konversation(kopf)
            nachrichten = liste
        } catch {
            nachrichten = [kopf]
        }
        // Aufklappen: geöffnete + ungelesene; ohne „Gelesene reduzieren“ alle
        var auf: Set<String> = [kopf.id]
        if let neueste = nachrichten.last { auf.insert(neueste.id) }
        for k in nachrichten where !k.gelesen || !gelesenReduzieren { auf.insert(k.id) }
        aufgeklappt = auf
        // als gelesen markieren (wie Apple beim Öffnen)
        let ungelesen = nachrichten.filter { !aktuell($0).gelesen }
        if !ungelesen.isEmpty {
            await store.ausfuehren(.gelesen(true), ungelesen, in: quelle)
            nachrichten = nachrichten.map { var k = $0; k.gelesen = true; return k }
        }
    }
}

/// Antworten / Allen antworten / Weiterleiten.
struct AntwortenMenue: View {
    let kopf: NachrichtKopf
    @Environment(MailStore.self) private var store

    var body: some View {
        Menu {
            Button("Antworten", systemImage: "arrowshape.turn.up.left") { store.verfassenAuftrag = .init(art: .antworten(kopf)) }
            Button("Allen antworten", systemImage: "arrowshape.turn.up.left.2") { store.verfassenAuftrag = .init(art: .allenAntworten(kopf)) }
            Button("Weiterleiten", systemImage: "arrowshape.turn.up.right") { store.verfassenAuftrag = .init(art: .weiterleiten(kopf)) }
        } label: {
            Label("Antworten", systemImage: "arrowshape.turn.up.left")
        }
        .accessibilityIdentifier("antworten")
    }
}

/// Eine E-Mail in der Konversation.
struct NachrichtKarte: View {
    let kopf: NachrichtKopf
    let aufgeklappt: Bool
    let quelle: ListenQuelle?
    let umschalten: () -> Void
    let bewegen: () -> Void
    let mehr: () -> Void
    let entfernt: () -> Void

    @Environment(MailStore.self) private var store
    @AppStorage(Einstellung.ferninhalteLaden) private var ferninhalteImmer = false
    @State private var inhalt: NachrichtInhalt?
    @State private var html: String?
    @State private var hoehe: CGFloat = 60
    @State private var ferninhalteJetzt = false
    @State private var details = false
    @State private var vorschauURL: URL?
    @State private var ladeFehler: String?

    private var hatFerninhalte: Bool { html.map(MailHTML.hatFerninhalte) ?? false }
    private var ferninhalte: Bool { ferninhalteImmer || ferninhalteJetzt }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            kopfbereich
            if aufgeklappt {
                if hatFerninhalte && !ferninhalte {
                    banner
                }
                if let html {
                    MailWebView(html: html, ferninhalte: ferninhalte, hoehe: $hoehe)
                        .frame(height: hoehe)
                        .accessibilityIdentifier("inhalt")
                } else if let ladeFehler {
                    Label(ladeFehler, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.secondary)
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 60)
                }
                anhaenge
                fussleiste
            }
        }
        .padding(14)
        .background(.background.secondary, in: .rect(cornerRadius: 18))
        .padding(.horizontal, 10)
        .task(id: aufgeklappt) { if aufgeklappt && inhalt == nil { await laden() } }
        .quickLookPreview($vorschauURL)
    }

    private var kopfbereich: some View {
        Button(action: umschalten) {
            HStack(alignment: .top, spacing: 10) {
                Monogramm(adresse: kopf.absender, groesse: 40)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(kopf.absender?.anzeige ?? String(localized: "Unbekannt")).font(.headline)
                        Spacer()
                        Text(MailDatum.kurz(kopf.datum)).font(.subheadline).foregroundStyle(.secondary)
                    }
                    if aufgeklappt {
                        empfaengerZeile
                    } else {
                        Text(kopf.vorschau).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var empfaengerZeile: some View {
        if details {
            VStack(alignment: .leading, spacing: 2) {
                if let von = kopf.absender { Text("Von: \(von.formatiert)") }
                if !kopf.an.isEmpty { Text("An: \(kopf.an.map(\.formatiert).joined(separator: ", "))") }
                if !kopf.kopie.isEmpty { Text("Kopie: \(kopf.kopie.map(\.formatiert).joined(separator: ", "))") }
                if !kopf.antwortAn.isEmpty, kopf.antwortAn.map(\.email) != kopf.von.map(\.email) {
                    Text("Antwort an: \(kopf.antwortAn.map(\.formatiert).joined(separator: ", "))")
                        .foregroundStyle(.orange)
                }
                Text(MailDatum.lang(kopf.datum))
                Button("Ausblenden") { details = false }.font(.subheadline)
            }
            .font(.subheadline).foregroundStyle(.secondary)
            .textSelection(.enabled)
        } else {
            HStack(spacing: 4) {
                Text("An: \((kopf.an + kopf.kopie).map(\.anzeige).joined(separator: ", "))").lineLimit(1)
                Button("Details") { details = true }
            }
            .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var banner: some View {
        HStack {
            Image(systemName: "photo.badge.exclamationmark")
            Text("Diese E‑Mail enthält Bilder aus dem Internet, die nicht geladen wurden.").font(.footnote)
            Spacer(minLength: 4)
            Button("Laden") { ferninhalteJetzt = true }.font(.footnote.weight(.semibold))
                .accessibilityIdentifier("bilderLaden")
        }
        .padding(10)
        .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 12))
    }

    @ViewBuilder private var anhaenge: some View {
        let liste = (inhalt?.anhaenge ?? []).filter { !$0.eingebettet || !(html ?? "").contains("cid:\($0.contentID ?? "-")") }
        if !liste.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(liste) { a in
                        AnhangKachel(anhang: a, kopf: kopf) { url in vorschauURL = url }
                    }
                }
            }
        }
    }

    private var fussleiste: some View {
        HStack(spacing: 22) {
            AntwortenMenue(kopf: kopf).labelStyle(.iconOnly)
            Button("Löschen", systemImage: "trash") {
                Task { await store.ausfuehren(.loeschen, [kopf], in: quelle); entfernt() }
            }
            .labelStyle(.iconOnly)
            Button("Bewegen", systemImage: "folder", action: bewegen).labelStyle(.iconOnly)
            Spacer()
            Button("Mehr", systemImage: "ellipsis.circle", action: mehr).labelStyle(.iconOnly)
                .accessibilityIdentifier("mehr")
        }
        .font(.title3)
        .padding(.top, 2)
    }

    private func laden() async {
        do {
            let i = try await store.inhalt(kopf)
            inhalt = i
            var h: String
            if let roh = i.html {
                h = roh
                // eingebettete Bilder (cid:) direkt einsetzen
                var teile: [(cid: String, typ: String, daten: Data)] = []
                for a in i.anhaenge where a.contentID != nil && roh.contains("cid:\(a.contentID!)") {
                    var d = i.anhangDaten[a.id]
                    if d == nil { d = try? await store.anhang(a, von: kopf) }
                    if let d { teile.append((a.contentID!, a.mimeTyp, d)) }
                }
                h = MailHTML.cidErsetzen(h, teile)
            } else {
                h = MailHTML.ausText(i.text ?? "")
            }
            html = h
        } catch {
            ladeFehler = error.localizedDescription
        }
    }
}

/// Kachel für einen Anhang (Bildvorschau oder Symbol, Name, Größe); Tippen = Übersicht (QuickLook).
struct AnhangKachel: View {
    let anhang: AnhangInfo
    let kopf: NachrichtKopf
    let oeffnen: (URL) -> Void
    @Environment(MailStore.self) private var store
    @State private var bild: UIImage?
    @State private var datei: URL?
    @State private var laedt = false

    var body: some View {
        Button {
            Task { if let u = await holen() { oeffnen(u) } }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                    if let bild {
                        Image(uiImage: bild).resizable().scaledToFill()
                    } else if laedt {
                        ProgressView()
                    } else {
                        Image(systemName: symbol).font(.largeTitle).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 120, height: 84)
                .clipShape(.rect(cornerRadius: 10))
                Text(anhang.name).font(.caption).lineLimit(1).frame(width: 120, alignment: .leading)
                Text(anhang.groesse.dateiGroesse).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Übersicht", systemImage: "eye") { Task { if let u = await holen() { oeffnen(u) } } }
            if let datei { ShareLink(item: datei) { Label("Sichern oder teilen", systemImage: "square.and.arrow.up") } }
        }
        .task {
            if anhang.mimeTyp.lowercased().hasPrefix("image/") && anhang.groesse < 8_000_000, let u = await holen(),
               let d = try? Data(contentsOf: u) {
                bild = UIImage(data: d)?.preparingThumbnail(of: CGSize(width: 240, height: 168))
            }
        }
        .accessibilityIdentifier("anhang-\(anhang.name)")
    }

    private var symbol: String {
        let t = anhang.mimeTyp.lowercased()
        if t.contains("pdf") { return "doc.richtext" }
        if t.hasPrefix("image/") { return "photo" }
        if t.hasPrefix("video/") { return "film" }
        if t.hasPrefix("audio/") { return "waveform" }
        if t.contains("zip") { return "doc.zipper" }
        if t.hasPrefix("text/") { return "doc.text" }
        return "doc"
    }

    private func holen() async -> URL? {
        if let datei { return datei }
        laedt = true
        defer { laedt = false }
        do {
            let d = try await store.anhang(anhang, von: kopf)
            let u = try TempDatei.schreiben(d, name: anhang.name)
            datei = u
            return u
        } catch {
            store.melde(error)
            return nil
        }
    }
}
