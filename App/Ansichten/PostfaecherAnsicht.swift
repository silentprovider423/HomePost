import SwiftUI

/// „Postfächer“ wie Apple Mail: Posteingänge, intelligente Postfächer, darunter je Account die Server-Ordner.
struct PostfaecherAnsicht: View {
    @Environment(MailStore.self) private var store
    @State private var bearbeiten = false
    @State private var einstellungen = false
    @State private var neuesPostfach: UUID?
    @State private var neuesEltern: Postfach?
    @State private var neuerName = ""
    @State private var umbenennen: (UUID, Postfach)?
    @State private var loeschen: (UUID, Postfach)?
    @State private var zugeklappt: Set<UUID> = []
    @AppStorage("ausgeblendeteIntelligente") private var ausgeblendetRoh = "anKopie,heute"

    private var ausgeblendet: Set<String> { Set(ausgeblendetRoh.split(separator: ",").map(String.init)) }

    var body: some View {
        List {
            Section { eingangsZeilen; intelligenteZeilen }
            ForEach(store.konten) { k in kontoSektion(k) }
        }
        .listStyle(.sidebar)
        .navigationTitle("Postfächer")
        .refreshable { await store.aktualisierenAlles() }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Einstellungen", systemImage: "gearshape") { einstellungen = true }
                    .accessibilityIdentifier("einstellungen")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(bearbeiten ? "Fertig" : "Bearbeiten") { withAnimation { bearbeiten.toggle() } }
            }
            if !store.statusText.isEmpty {
                ToolbarItem(placement: .status) {
                    Text(store.statusText).font(.caption).foregroundStyle(.secondary).fixedSize()
                }
                .sharedBackgroundVisibility(.hidden)
            }
            if bearbeiten {
                // wie Apple: „Neues Postfach“ unten links im Bearbeiten-Modus
                ToolbarItem(placement: .bottomBar) {
                    Button("Neues Postfach") {
                        neuesEltern = nil
                        neuesPostfach = store.standardKonto?.id
                    }
                    .accessibilityIdentifier("neuesPostfachLeiste")
                }
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) { VerfassenKnopf() }
        }
        .sheet(isPresented: $einstellungen) { EinstellungenAnsicht() }
        .sheet(item: Binding(get: { neuesPostfach.map { NeuesPostfachAuftrag(konto: $0, eltern: neuesEltern) } },
                             set: { if $0 == nil { neuesPostfach = nil } })) { a in
            NeuesPostfachAnsicht(konto: a.konto, eltern: a.eltern)
        }
        .background {
            Color.clear.alert("Postfach umbenennen", isPresented: Binding(get: { umbenennen != nil }, set: { if !$0 { umbenennen = nil } })) {
                TextField("Name", text: $neuerName).accessibilityIdentifier("postfachName")
                Button("Abbrechen", role: .cancel) { neuerName = "" }
                Button("Sichern") {
                    let n = neuerName.trimmingCharacters(in: .whitespaces)
                    if let (k, p) = umbenennen, !n.isEmpty { Task { await store.postfachUmbenennen(k, p, in: n) } }
                    neuerName = ""
                }
            }
        }
        .confirmationDialog("Postfach löschen?", isPresented: Binding(get: { loeschen != nil }, set: { if !$0 { loeschen = nil } }),
                            titleVisibility: .visible, presenting: loeschen.map { LoeschZiel(konto: $0.0, postfach: $0.1) }) { z in
            Button("Postfach löschen", role: .destructive) {
                Task { await store.postfachLoeschen(z.konto, z.postfach) }
            }
        } message: { _ in
            Text("Alle E‑Mails in diesem Postfach werden auf dem Server gelöscht.")
        }
    }

    @ViewBuilder private var eingangsZeilen: some View {
        if store.konten.count > 1 {
            zeile(.alleEingaenge, titel: "Alle Posteingänge", symbol: "tray.2", zahl: store.ungelesenGesamt)
                .accessibilityIdentifier("alleEingaenge")
        }
        ForEach(store.konten) { k in eingangZeile(k) }
    }

    @ViewBuilder private func eingangZeile(_ k: KontoKonfiguration) -> some View {
        if let e = store.postfach(k.id, .eingang) {
            let titel = store.konten.count > 1 ? k.name : String(localized: "Eingang")
            zeile(.postfach(k.id, e.id), titelText: titel, symbol: "tray", zahl: e.ungelesen)
        }
    }

    private var intelligenteZeilen: some View {
        ForEach(IntelligentesPostfach.allCases, id: \.self) { i in intelligenteZeile(i) }
    }

    @ViewBuilder private func intelligenteZeile(_ i: IntelligentesPostfach) -> some View {
        let aus = ausgeblendet.contains(i.rawValue)
        if bearbeiten || !aus {
            HStack {
                if bearbeiten {
                    Button {
                        var a = ausgeblendet
                        if aus { a.remove(i.rawValue) } else { a.insert(i.rawValue) }
                        ausgeblendetRoh = a.sorted().joined(separator: ",")
                    } label: {
                        Image(systemName: aus ? "circle" : "checkmark.circle.fill")
                            .foregroundStyle(aus ? Color.secondary : Color.accentColor)
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                }
                zeile(.intelligent(i), titel: i.titel, symbol: i.symbol,
                      zahl: i == .ungelesen ? store.ungelesenGesamt : 0, farbe: i == .markiert ? .orange : nil)
            }
        }
    }

    private func kontoSektion(_ k: KontoKonfiguration) -> some View {
        let offen = Binding(get: { !zugeklappt.contains(k.id) },
                            set: { if $0 { zugeklappt.remove(k.id) } else { zugeklappt.insert(k.id) } })
        let ordner = (store.postfaecher[k.id] ?? []).filter { $0.rolle != .eingang || store.konten.count > 1 }
        return Section(isExpanded: offen) {
            ForEach(ordner) { p in ordnerOderGruppe(k, p) }
            if bearbeiten {
                Button("Neues Postfach …", systemImage: "folder.badge.plus") { neuesEltern = nil; neuesPostfach = k.id }
                    .accessibilityIdentifier("neuesPostfach")
            }
        } header: {
            Text(k.name)
        }
    }

    @ViewBuilder private func ordnerOderGruppe(_ k: KontoKonfiguration, _ p: Postfach) -> some View {
        if p.auswaehlbar {
            ordnerZeile(k, p)
        } else {
            Label(p.name, systemImage: "folder").foregroundStyle(.secondary).padding(.leading, CGFloat(p.tiefe) * 18)
        }
    }

    private func zeile(_ q: ListenQuelle, titel: LocalizedStringKey, symbol: String, zahl: Int, farbe: Color? = nil) -> some View {
        NavigationLink(value: q) {
            HStack {
                Label { Text(titel) } icon: { Image(systemName: symbol).foregroundStyle(farbe ?? .accentColor) }
                Spacer()
                if zahl > 0 { Text("\(zahl)").foregroundStyle(.secondary) }
            }
        }
        .disabled(bearbeiten)
    }

    private func zeile(_ q: ListenQuelle, titelText: String, symbol: String, zahl: Int) -> some View {
        NavigationLink(value: q) {
            HStack {
                Label(titelText, systemImage: symbol)
                Spacer()
                if zahl > 0 { Text("\(zahl)").foregroundStyle(.secondary) }
            }
        }
        .accessibilityIdentifier("postfach-\(titelText)")
    }

    @ViewBuilder
    private func ordnerZeile(_ k: KontoKonfiguration, _ p: Postfach) -> some View {
        let name = MailStore.anzeigeName(p)
        NavigationLink(value: ListenQuelle.postfach(k.id, p.id)) {
            HStack {
                Label(name, systemImage: p.symbol)
                Spacer()
                if p.ungelesen > 0 && p.rolle != .papierkorb && p.rolle != .gesendet {
                    Text("\(p.ungelesen)").foregroundStyle(.secondary)
                } else if p.rolle == .entwuerfe && p.gesamt > 0 {
                    Text("\(p.gesamt)").foregroundStyle(.secondary)
                }
            }
            .padding(.leading, CGFloat(p.tiefe) * 18)
        }
        // sprachunabhängige Kennung (Sonderpostfächer nach Rolle) für UI-Tests
        .accessibilityIdentifier("postfach-\(p.rolle == .keine ? p.name : p.rolle.rawValue)")
        .contextMenu {
            if p.rolle == .keine {
                Button("Umbenennen", systemImage: "pencil") { neuerName = p.name; umbenennen = (k.id, p) }
                Button("Neues Unterpostfach …", systemImage: "folder.badge.plus") { neuesEltern = p; neuesPostfach = k.id }
                Button("Postfach löschen", systemImage: "trash", role: .destructive) { loeschen = (k.id, p) }
            }
        }
        .swipeActions(edge: .trailing) {
            if p.rolle == .keine {
                Button("Löschen", systemImage: "trash", role: .destructive) { loeschen = (k.id, p) }
                Button("Umbenennen", systemImage: "pencil") { neuerName = p.name; umbenennen = (k.id, p) }.tint(.gray)
            }
        }
    }
}

/// Verfassen-Knopf unten rechts; langes Drücken zeigt die Entwürfe (wie Apple).
struct VerfassenKnopf: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        Menu {
            let entwuerfe = store.konten.flatMap { k -> [NachrichtKopf] in
                guard let p = store.postfach(k.id, .entwuerfe) else { return [] }
                return store.listen[.postfach(k.id, p.id)] ?? []
            }
            if !entwuerfe.isEmpty {
                Section("Entwürfe") {
                    ForEach(entwuerfe.prefix(8)) { e in
                        Button(e.betreff.isEmpty ? String(localized: "Kein Betreff") : e.betreff) {
                            store.verfassenAuftrag = VerfassenAuftrag(art: .entwurf(e))
                        }
                    }
                }
            }
            Button("Neue E‑Mail", systemImage: "square.and.pencil") {
                store.verfassenAuftrag = VerfassenAuftrag(art: .neu)
            }
        } label: {
            Label("Neue E‑Mail", systemImage: "square.and.pencil")
        } primaryAction: {
            store.verfassenAuftrag = VerfassenAuftrag(art: .neu)
        }
        .accessibilityIdentifier("verfassen")
        .task {
            for k in store.konten {
                if let p = store.postfach(k.id, .entwuerfe), store.listen[.postfach(k.id, p.id)] == nil {
                    await store.laden(.postfach(k.id, p.id))
                }
            }
        }
    }
}

private struct LoeschZiel {
    let konto: UUID
    let postfach: Postfach
}

private struct NeuesPostfachAuftrag: Identifiable {
    var id: String { konto.uuidString + (eltern?.id ?? "") }
    let konto: UUID
    let eltern: Postfach?
}

/// „Neues Postfach“ wie Apple: Name + „Ort des Postfachs“ (Account bzw. übergeordnetes Postfach).
struct NeuesPostfachAnsicht: View {
    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var schliessen
    @State var konto: UUID
    @State var eltern: Postfach?
    @State private var name = ""
    @FocusState private var fokus: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .focused($fokus)
                        .accessibilityIdentifier("postfachName")
                }
                Section("Ort des Postfachs") {
                    ForEach(store.konten) { k in
                        ortZeile(k.name, symbol: "person.crop.circle", gewaehlt: konto == k.id && eltern == nil, tiefe: 0) {
                            konto = k.id; eltern = nil
                        }
                        ForEach((store.postfaecher[k.id] ?? []).filter { $0.rolle == .keine }) { p in
                            ortZeile(p.name, symbol: "folder", gewaehlt: konto == k.id && eltern?.id == p.id, tiefe: p.tiefe + 1) {
                                konto = k.id; eltern = p
                            }
                        }
                    }
                }
            }
            .navigationTitle("Neues Postfach")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen", role: .cancel) { schliessen() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sichern") {
                        let n = name.trimmingCharacters(in: .whitespaces)
                        let k = konto, e = eltern
                        Task { await store.postfachAnlegen(k, name: n, in: e) }
                        schliessen()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("postfachSichern")
                }
            }
            .onAppear { fokus = true }
        }
    }

    private func ortZeile(_ titel: String, symbol: String, gewaehlt: Bool, tiefe: Int, _ aktion: @escaping () -> Void) -> some View {
        Button(action: aktion) {
            HStack {
                Label(titel, systemImage: symbol).padding(.leading, CGFloat(tiefe) * 16)
                Spacer()
                if gewaehlt { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
        }
        .foregroundStyle(.primary)
    }
}
