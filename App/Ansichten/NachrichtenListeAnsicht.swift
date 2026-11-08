import SwiftUI

/// Filter wie Apple (Knopf unten links).
enum ListenFilter: String, CaseIterable, Identifiable {
    case ungelesen, markiert, anMich, kopieAnMich, anhaenge, vip, heute
    var id: String { rawValue }

    var titel: LocalizedStringKey {
        switch self {
        case .ungelesen: "Ungelesen"
        case .markiert: "Markiert"
        case .anMich: "An: Mich"
        case .kopieAnMich: "Kopie: An mich"
        case .anhaenge: "Nur E‑Mails mit Anhängen"
        case .vip: "Nur von VIP"
        case .heute: "Nur heute gesendet"
        }
    }

    var kurz: String {
        switch self {
        case .ungelesen: String(localized: "Ungelesen")
        case .markiert: String(localized: "Markiert")
        case .anMich: String(localized: "An: Mich")
        case .kopieAnMich: String(localized: "Kopie: An mich")
        case .anhaenge: String(localized: "Mit Anhängen")
        case .vip: "VIP"
        case .heute: String(localized: "Heute")
        }
    }
}

/// Ein Listeneintrag: Konversation (neueste Nachricht + Anzahl) oder einzelne E-Mail.
struct ListenEintrag: Identifiable, Hashable {
    var id: String { kopf.id }
    var kopf: NachrichtKopf
    var alle: [NachrichtKopf]
    var anzahl: Int { alle.count }
    var ungelesen: Bool { alle.contains { !$0.gelesen } }
    var markiert: NachrichtKopf? { alle.first { $0.markiert } }
}

struct NachrichtenListeAnsicht: View {
    let quelle: ListenQuelle
    @Environment(MailStore.self) private var store
    @Environment(\.editMode) private var editModeUmgebung

    @AppStorage(Einstellung.nachKonversation) private var nachKonversation = true
    @AppStorage(Einstellung.wischRechts) private var wischRechts = WischAktion.gelesen.rawValue
    @AppStorage(Einstellung.wischLinks) private var wischLinks = WischAktion.loeschen.rawValue
    @AppStorage(Einstellung.loeschenBestaetigen) private var loeschenBestaetigen = false
    @AppStorage(Einstellung.archivStattLoeschen) private var archivStattLoeschen = false

    @State private var bearbeitet: EditMode = .inactive
    @State private var auswahl: Set<String> = []
    @State private var filterAktiv = false
    @State private var filter: Set<ListenFilter> = [.ungelesen]
    @State private var suchText = ""
    @State private var suchBereich = SuchBereich.alle
    @State private var suchErgebnisse: [NachrichtKopf]?
    @State private var bewegen: [NachrichtKopf]?
    @State private var aktionskarte: NachrichtKopf?
    @State private var bestaetigen: [NachrichtKopf]?
    @State private var alleBestaetigen = false

    enum SuchBereich: Hashable { case alle, aktuell }

    private var postfach: Postfach? {
        if case .postfach(let k, let id) = quelle { return store.postfach(k, id: id) }
        return nil
    }

    private var eintraege: [ListenEintrag] {
        var liste = store.listen[quelle] ?? []
        if filterAktiv { liste = liste.filter(passtFilter) }
        guard nachKonversation, postfach?.rolle != .entwuerfe else {
            return liste.map { ListenEintrag(kopf: $0, alle: [$0]) }
        }
        var reihenfolge: [String] = []
        var gruppen: [String: [NachrichtKopf]] = [:]
        for k in liste {
            let s = "\(k.kontoID.uuidString)|\(k.threadID)"
            if gruppen[s] == nil { reihenfolge.append(s) }
            gruppen[s, default: []].append(k)
        }
        return reihenfolge.compactMap { s in
            guard let g = gruppen[s], let neueste = g.max(by: { $0.datum < $1.datum }) else { return nil }
            return ListenEintrag(kopf: neueste, alle: g)
        }
    }

    private func passtFilter(_ k: NachrichtKopf) -> Bool {
        let eigene = Set(store.konten.map { $0.adresse.lowercased() })
        for f in filter {
            let ok: Bool = switch f {
            case .ungelesen: !k.gelesen
            case .markiert: k.markiert
            case .anMich: k.an.contains { eigene.contains($0.email.lowercased()) }
            case .kopieAnMich: k.kopie.contains { eigene.contains($0.email.lowercased()) }
            case .anhaenge: k.hatAnhang
            case .vip: k.von.contains { store.vip.contains($0.email.lowercased()) }
            case .heute: Calendar.current.isDateInToday(k.datum)
            }
            if ok { return true }
        }
        return filter.isEmpty
    }

    private var untertitel: String {
        if bearbeitet.isEditing { return auswahl.isEmpty ? "" : String(localized: "\(auswahl.count) ausgewählt") }
        if filterAktiv {
            return String(localized: "Gefiltert nach: \(ListenFilter.allCases.filter(filter.contains).map(\.kurz).joined(separator: ", "))")
        }
        let ungelesen = (store.listen[quelle] ?? []).filter { !$0.gelesen }.count
        if store.offline || store.laedt.contains(quelle) || ungelesen == 0 { return store.statusText }
        return String(localized: "\(ungelesen) ungelesen")
    }

    var body: some View {
        Group {
            if let ergebnisse = suchErgebnisse, !suchText.isEmpty {
                List(ergebnisse) { k in
                    NavigationLink(value: KonversationsZiel(kopf: k, quelle: nil)) {
                        ZeileAnsicht(eintrag: ListenEintrag(kopf: k, alle: [k]), zeigeKonto: store.konten.count > 1,
                                     hervorheben: suchText)
                    }
                }
                .listStyle(.plain)
                .overlay { if ergebnisse.isEmpty { ContentUnavailableView.search(text: suchText) } }
            } else {
                liste
            }
        }
        .navigationTitle(store.titel(quelle))
        .navigationSubtitle(untertitel)
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $suchText, placement: .toolbar, prompt: "Suchen")
        .searchScopes($suchBereich, activation: .onSearchPresentation) {
            Text("Alle Postfächer").tag(SuchBereich.alle)
            Text("Aktuelles Postfach").tag(SuchBereich.aktuell)
        }
        .task(id: "\(suchText)|\(suchBereich)") { await suchen() }
        .environment(\.editMode, $bearbeitet)
        .toolbar { werkzeuge }
        .task { await store.laden(quelle) }
        .refreshable { await store.laden(quelle) }
        .sheet(item: Binding(get: { bewegen.map { BewegenAuftrag(koepfe: $0) } }, set: { bewegen = $0?.koepfe })) { a in
            BewegenAnsicht(koepfe: a.koepfe, quelle: quelle) { auswahl.removeAll(); bearbeitet = .inactive }
        }
        .sheet(item: $aktionskarte) { k in
            AktionskarteAnsicht(kopf: k, quelle: quelle)
                .presentationDetents([.medium, .large])
        }
        .confirmationDialog("E‑Mails löschen?", isPresented: Binding(get: { bestaetigen != nil }, set: { if !$0 { bestaetigen = nil } }),
                            titleVisibility: .visible) {
            Button(loeschTitel, role: .destructive) {
                if let k = bestaetigen { Task { await store.ausfuehren(.loeschen, k, in: quelle) } }
            }
        }
        .confirmationDialog(alleTitel, isPresented: $alleBestaetigen, titleVisibility: .visible) {
            Button(alleKnopf, role: .destructive) {
                let alle = store.listen[quelle] ?? []
                Task {
                    await store.ausfuehren(archivStattLoeschen ? .archivieren : .loeschen, alle, in: quelle)
                    bearbeitet = .inactive
                }
            }
        } message: {
            Text("Diese Aktion wirkt sich auf den Server und damit auf all deine Geräte aus.")
        }
    }

    private var loeschTitel: LocalizedStringKey {
        postfach?.rolle == .papierkorb ? "Endgültig löschen" : "In den Papierkorb"
    }

    private var alleTitel: LocalizedStringKey { archivStattLoeschen ? "Alle E‑Mails archivieren?" : "Alle E‑Mails löschen?" }
    private var alleKnopf: LocalizedStringKey { archivStattLoeschen ? "Alle archivieren" : "Alle löschen" }

    // MARK: Liste

    private var liste: some View {
        List(selection: $auswahl) {
            ForEach(eintraege) { e in
                NavigationLink(value: KonversationsZiel(kopf: e.kopf, quelle: quelle)) {
                    ZeileAnsicht(eintrag: e, zeigeKonto: quelleZeigtKonten)
                }
                .tag(e.id)
                .swipeActions(edge: .leading, allowsFullSwipe: true) { wischKnoepfe(WischAktion(rawValue: wischRechts) ?? .gelesen, e, voll: true) }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    wischKnoepfe(WischAktion(rawValue: wischLinks) ?? .loeschen, e, voll: true)
                    if WischAktion(rawValue: wischLinks) != .markieren { wischKnoepfe(.markieren, e, voll: false) }
                    Button { aktionskarte = e.kopf } label: { Label("Mehr", systemImage: "ellipsis.circle") }
                        .tint(.gray)
                }
                .contextMenu { kontextMenue(e) } preview: { VorschauKarte(kopf: e.kopf) }
            }
        }
        .listStyle(.plain)
        .overlay {
            if eintraege.isEmpty && !store.laedt.contains(quelle) {
                ContentUnavailableView(filterAktiv ? "Keine gefilterten E‑Mails" : "Keine E‑Mails", systemImage: "tray")
            }
        }
        .accessibilityIdentifier("nachrichtenListe")
    }

    private var quelleZeigtKonten: Bool {
        if case .postfach = quelle { return false }
        return store.konten.count > 1
    }

    @ViewBuilder
    private func wischKnoepfe(_ a: WischAktion, _ e: ListenEintrag, voll: Bool) -> some View {
        let koepfe = e.alle
        switch a {
        case .keine: EmptyView()
        case .gelesen:
            Button {
                Task { await store.ausfuehren(.gelesen(e.ungelesen), koepfe, in: quelle) }
            } label: {
                e.ungelesen ? Label("Gelesen", systemImage: "envelope.open") : Label("Ungelesen", systemImage: "envelope.badge")
            }
            .tint(.blue)
        case .markieren:
            Button {
                let m = e.markiert == nil
                Task { await store.ausfuehren(.markieren(m, m ? .orange : nil), koepfe, in: quelle) }
            } label: {
                e.markiert == nil ? Label("Markieren", systemImage: "flag") : Label("Nicht markieren", systemImage: "flag.slash")
            }
            .tint(.orange)
        case .bewegen:
            Button { bewegen = koepfe } label: { Label("Bewegen", systemImage: "folder") }.tint(.indigo)
        case .archivieren:
            Button(role: .destructive) {
                Task { await store.ausfuehren(.archivieren, koepfe, in: quelle) }
            } label: { Label("Archivieren", systemImage: "archivebox") }
            .tint(.purple)
        case .loeschen:
            if archivStattLoeschen && postfach?.rolle != .papierkorb {
                Button(role: .destructive) {
                    Task { await store.ausfuehren(.archivieren, koepfe, in: quelle) }
                } label: { Label("Archivieren", systemImage: "archivebox") }
                .tint(.purple)
            } else {
                Button(role: .destructive) {
                    if loeschenBestaetigen { bestaetigen = koepfe } else {
                        Task { await store.ausfuehren(.loeschen, koepfe, in: quelle) }
                    }
                } label: { Label("Löschen", systemImage: "trash") }
            }
        case .spam:
            Button(role: .destructive) {
                Task { await store.ausfuehren(postfach?.rolle == .spam ? .keinSpam : .spam, koepfe, in: quelle) }
            } label: {
                postfach?.rolle == .spam ? Label("Kein Spam", systemImage: "tray") : Label("Spam", systemImage: "xmark.bin")
            }
            .tint(.brown)
        }
    }

    @ViewBuilder
    private func kontextMenue(_ e: ListenEintrag) -> some View {
        let k = e.kopf
        Button("Antworten", systemImage: "arrowshape.turn.up.left") { store.verfassenAuftrag = .init(art: .antworten(k)) }
        Button("Allen antworten", systemImage: "arrowshape.turn.up.left.2") { store.verfassenAuftrag = .init(art: .allenAntworten(k)) }
        Button("Weiterleiten", systemImage: "arrowshape.turn.up.right") { store.verfassenAuftrag = .init(art: .weiterleiten(k)) }
        Divider()
        Button(e.ungelesen ? "Als gelesen markieren" : "Als ungelesen markieren",
               systemImage: e.ungelesen ? "envelope.open" : "envelope.badge") {
            Task { await store.ausfuehren(.gelesen(e.ungelesen), e.alle, in: quelle) }
        }
        Menu {
            ForEach(FahnenFarbe.allCases, id: \.self) { f in
                Button { Task { await store.ausfuehren(.markieren(true, f), e.alle, in: quelle) } } label: {
                    Label { Text(f.titel) } icon: { Image(systemName: "flag.fill").tint(f.farbe) }
                }
            }
            if e.markiert != nil {
                Button("Markierung entfernen", systemImage: "flag.slash") {
                    Task { await store.ausfuehren(.markieren(false, nil), e.alle, in: quelle) }
                }
            }
        } label: { Label("Markieren", systemImage: "flag") }
        Button("Bewegen …", systemImage: "folder") { bewegen = e.alle }
        Button("Archivieren", systemImage: "archivebox") { Task { await store.ausfuehren(.archivieren, e.alle, in: quelle) } }
        Button(postfach?.rolle == .spam ? "In Eingang bewegen" : "In „Spam“ bewegen", systemImage: "xmark.bin") {
            Task { await store.ausfuehren(postfach?.rolle == .spam ? .keinSpam : .spam, e.alle, in: quelle) }
        }
        Button("Löschen", systemImage: "trash", role: .destructive) {
            Task { await store.ausfuehren(.loeschen, e.alle, in: quelle) }
        }
    }

    // MARK: Werkzeugleisten

    @ToolbarContentBuilder
    private var werkzeuge: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(bearbeitet.isEditing ? "Fertig" : "Bearbeiten") {
                withAnimation {
                    bearbeitet = bearbeitet.isEditing ? .inactive : .active
                    auswahl.removeAll()
                }
            }
            .accessibilityIdentifier("bearbeiten")
        }
        if bearbeitet.isEditing {
            ToolbarItem(placement: .topBarLeading) {
                Button(auswahl.count == eintraege.count && !eintraege.isEmpty ? "Keine" : "Alle auswählen") {
                    if auswahl.count == eintraege.count { auswahl.removeAll() } else { auswahl = Set(eintraege.map(\.id)) }
                }
            }
            ToolbarItem(placement: .bottomBar) {
                Menu("Markieren") {
                    Button("Als gelesen markieren", systemImage: "envelope.open") { aufAuswahl(.gelesen(true)) }
                    Button("Als ungelesen markieren", systemImage: "envelope.badge") { aufAuswahl(.gelesen(false)) }
                    Button("Markieren", systemImage: "flag") { aufAuswahl(.markieren(true, .orange)) }
                    Button("Markierung entfernen", systemImage: "flag.slash") { aufAuswahl(.markieren(false, nil)) }
                    Button("In „Spam“ bewegen", systemImage: "xmark.bin") { aufAuswahl(.spam) }
                }
                .disabled(auswahl.isEmpty)
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Button("Bewegen") { bewegen = ausgewaehlteKoepfe }.disabled(auswahl.isEmpty)
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                if auswahl.isEmpty {
                    Button(archivStattLoeschen ? "Alle archivieren" : "Alle löschen") { alleBestaetigen = true }
                        .disabled(eintraege.isEmpty)
                } else {
                    Button(archivStattLoeschen ? "Archivieren" : "Löschen", role: .destructive) {
                        aufAuswahl(archivStattLoeschen ? .archivieren : .loeschen)
                    }
                }
            }
        } else {
            ToolbarItem(placement: .bottomBar) {
                Menu {
                    Section("Filter") {
                        ForEach(ListenFilter.allCases) { f in
                            Toggle(isOn: Binding(get: { filter.contains(f) }, set: { an in
                                if an { filter.insert(f) } else { filter.remove(f) }
                                filterAktiv = !filter.isEmpty
                            })) { Text(f.titel) }
                        }
                    }
                } label: {
                    Label("Filter", systemImage: filterAktiv ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                } primaryAction: {
                    withAnimation { filterAktiv.toggle() }
                }
                .accessibilityIdentifier("filter")
            }
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) { VerfassenKnopf() }
        }
    }

    private var ausgewaehlteKoepfe: [NachrichtKopf] {
        eintraege.filter { auswahl.contains($0.id) }.flatMap(\.alle)
    }

    private func aufAuswahl(_ a: MailAktion) {
        let koepfe = ausgewaehlteKoepfe
        Task {
            await store.ausfuehren(a, koepfe, in: quelle)
            auswahl.removeAll()
            withAnimation { bearbeitet = .inactive }
        }
    }

    // MARK: Suche

    private func suchen() async {
        let t = suchText.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { suchErgebnisse = nil; return }
        let bereich: ListenQuelle? = suchBereich == .aktuell ? quelle : nil
        var konto: UUID?
        if suchBereich == .aktuell, case .postfach(let k, _) = quelle { konto = k }
        var lokal = await store.suchenLokal(t, konto: konto)
        if suchBereich == .aktuell, case .postfach(_, let id) = quelle { lokal = lokal.filter { $0.postfachIDs.contains(id) } }
        suchErgebnisse = lokal
        // Serversuche kurz verzögert (Tippen abwarten)
        try? await Task.sleep(for: .milliseconds(450))
        if Task.isCancelled { return }
        let server = await store.suchenServer(t, in: bereich)
        if Task.isCancelled { return }
        var ids = Set(lokal.map(\.id))
        var zusammen = lokal
        for k in server where ids.insert(k.id).inserted { zusammen.append(k) }
        suchErgebnisse = zusammen.sorted { $0.datum > $1.datum }
    }
}

struct BewegenAuftrag: Identifiable {
    let id = UUID()
    let koepfe: [NachrichtKopf]
}

/// Zeile der E-Mail-Liste (Absender, Datum, Betreff, Vorschau, Symbole).
struct ZeileAnsicht: View {
    let eintrag: ListenEintrag
    var zeigeKonto = false
    var hervorheben: String? = nil
    @Environment(MailStore.self) private var store
    @AppStorage(Einstellung.vorschauZeilen) private var vorschauZeilen = 2
    @AppStorage(Einstellung.kontaktfotos) private var kontaktfotos = true
    @AppStorage(Einstellung.anKopieLabel) private var anKopieLabel = false

    private var k: NachrichtKopf { eintrag.kopf }

    private var absender: String {
        if k.postfachIDs.contains(where: { store.postfach(k.kontoID, id: $0)?.rolle == .gesendet || store.postfach(k.kontoID, id: $0)?.rolle == .entwuerfe }) {
            let an = k.an.map(\.anzeige).joined(separator: ", ")
            return an.isEmpty ? String(localized: "Kein Empfänger") : an
        }
        return k.absender?.anzeige ?? String(localized: "Unbekannt")
    }

    private var anKopie: String? {
        guard anKopieLabel, let konto = store.konto(k.kontoID) else { return nil }
        if k.an.contains(where: { $0.email.lowercased() == konto.adresse.lowercased() }) { return String(localized: "An") }
        if k.kopie.contains(where: { $0.email.lowercased() == konto.adresse.lowercased() }) { return String(localized: "Kopie") }
        return nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 6) {
                Circle().fill(eintrag.ungelesen ? Color.accentColor : .clear).frame(width: 10, height: 10)
                if k.beantwortet { Image(systemName: "arrowshape.turn.up.left.fill").font(.caption2).foregroundStyle(.secondary) }
                else if k.weitergeleitet { Image(systemName: "arrowshape.turn.up.right.fill").font(.caption2).foregroundStyle(.secondary) }
                if k.von.contains(where: { store.vip.contains($0.email.lowercased()) }) {
                    Image(systemName: "star.fill").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.top, kontaktfotos ? 14 : 5)
            .frame(width: 12)

            if kontaktfotos { Monogramm(adresse: k.absender, groesse: 38).padding(.top, 2) }

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let anKopie {
                        Text(anKopie).font(.caption2.weight(.semibold)).padding(.horizontal, 4)
                            .background(.quaternary, in: .rect(cornerRadius: 3))
                    }
                    Text(absender).font(.headline.weight(eintrag.ungelesen ? .bold : .semibold)).lineLimit(1)
                    if eintrag.anzahl > 1 {
                        Text("\(eintrag.anzahl)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).background(.quaternary, in: .capsule)
                    }
                    Spacer(minLength: 4)
                    if k.hatAnhang { Image(systemName: "paperclip").font(.caption).foregroundStyle(.secondary) }
                    Text(MailDatum.kurz(k.datum)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(k.betreff.isEmpty ? String(localized: "Kein Betreff") : k.betreff).font(.subheadline).lineLimit(1)
                    Spacer(minLength: 4)
                    if let m = eintrag.markiert {
                        Image(systemName: "flag.fill").font(.caption).foregroundStyle(m.fahne.farbe)
                    }
                }
                if vorschauZeilen > 0 {
                    Text(k.vorschau).font(.subheadline).foregroundStyle(.secondary).lineLimit(vorschauZeilen)
                }
                if zeigeKonto, let konto = store.konto(k.kontoID) {
                    Text(konto.name).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("zeile-\(k.betreff)")
    }
}

/// Vorschau beim langen Drücken (Kontextmenü).
struct VorschauKarte: View {
    let kopf: NachrichtKopf
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Monogramm(adresse: kopf.absender, groesse: 36)
                VStack(alignment: .leading) {
                    Text(kopf.absender?.anzeige ?? "").font(.headline)
                    Text(MailDatum.lang(kopf.datum)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(kopf.betreff).font(.title3.weight(.semibold))
            Text(kopf.vorschau).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding()
        .frame(width: 340, height: 260, alignment: .topLeading)
    }
}
