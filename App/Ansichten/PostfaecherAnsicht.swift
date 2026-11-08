import SwiftUI

/// „Postfächer“ wie Apple Mail: Posteingänge, intelligente Postfächer, darunter je Account die Server-Ordner.
struct PostfaecherAnsicht: View {
    @Environment(MailStore.self) private var store
    @State private var bearbeiten = false
    @State private var einstellungen = false
    @State private var neuesPostfach: UUID?
    @State private var neuesEltern: Postfach?
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
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) { VerfassenKnopf() }
        }
        .sheet(isPresented: $einstellungen) { EinstellungenAnsicht() }
        .alert("Neues Postfach", isPresented: Binding(get: { neuesPostfach != nil }, set: { if !$0 { neuesPostfach = nil } })) {
            NamensEingabe(titel: "", aktionTitel: "Sichern") { name, eltern in
                if let k = neuesPostfach { let e = neuesEltern; Task { await store.postfachAnlegen(k, name: name, in: e) } }
            }
        } message: {
            Text("Gib einen Namen für das neue Postfach ein.")
        }
        .alert("Postfach umbenennen", isPresented: Binding(get: { umbenennen != nil }, set: { if !$0 { umbenennen = nil } })) {
            NamensEingabe(titel: umbenennen?.1.name ?? "", aktionTitel: "Sichern") { name, _ in
                if let (k, p) = umbenennen { Task { await store.postfachUmbenennen(k, p, in: name) } }
            }
        }
        .confirmationDialog("Postfach löschen?", isPresented: Binding(get: { loeschen != nil }, set: { if !$0 { loeschen = nil } }),
                            titleVisibility: .visible) {
            Button("Postfach löschen", role: .destructive) {
                if let (k, p) = loeschen { Task { await store.postfachLoeschen(k, p) } }
            }
        } message: {
            Text("Alle E‑Mails in diesem Postfach werden auf dem Server gelöscht.")
        }
    }

    @ViewBuilder private var eingangsZeilen: some View {
        if store.konten.count > 1 {
            zeile(.alleEingaenge, titel: "Alle Posteingänge", symbol: "tray.2", zahl: store.ungelesenGesamt)
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
        .accessibilityIdentifier("postfach-\(name)")
        .contextMenu {
            if p.rolle == .keine {
                Button("Umbenennen", systemImage: "pencil") { umbenennen = (k.id, p) }
                Button("Neues Unterpostfach …", systemImage: "folder.badge.plus") { neuesEltern = p; neuesPostfach = k.id }
                Button("Postfach löschen", systemImage: "trash", role: .destructive) { loeschen = (k.id, p) }
            }
        }
        .swipeActions(edge: .trailing) {
            if p.rolle == .keine {
                Button("Löschen", systemImage: "trash", role: .destructive) { loeschen = (k.id, p) }
                Button("Umbenennen", systemImage: "pencil") { umbenennen = (k.id, p) }.tint(.gray)
            }
        }
    }
}

/// Textfeld im Hinweisfenster (Name eines Postfachs).
private struct NamensEingabe: View {
    let titel: String
    let aktionTitel: LocalizedStringKey
    let fertig: (String, Postfach?) -> Void
    @State private var name = ""

    var body: some View {
        TextField("Name", text: $name)
            .onAppear { name = titel }
            .accessibilityIdentifier("postfachName")
        Button("Abbrechen", role: .cancel) {}
        Button(aktionTitel) {
            let n = name.trimmingCharacters(in: .whitespaces)
            if !n.isEmpty { fertig(n, nil) }
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
