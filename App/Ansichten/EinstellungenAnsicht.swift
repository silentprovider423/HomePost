import SwiftUI

/// Einstellungen (bei Apple in der Einstellungen-App; hier in der App selbst).
struct EinstellungenAnsicht: View {
    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var schliessen
    @AppStorage(Einstellung.vorschauZeilen) private var vorschauZeilen = 2
    @AppStorage(Einstellung.kontaktfotos) private var kontaktfotos = true
    @AppStorage(Einstellung.anKopieLabel) private var anKopieLabel = false
    @AppStorage(Einstellung.wischRechts) private var wischRechts = WischAktion.gelesen.rawValue
    @AppStorage(Einstellung.wischLinks) private var wischLinks = WischAktion.loeschen.rawValue
    @AppStorage(Einstellung.loeschenBestaetigen) private var loeschenBestaetigen = false
    @AppStorage(Einstellung.ferninhalteLaden) private var ferninhalteLaden = false
    @AppStorage(Einstellung.nachKonversation) private var nachKonversation = true
    @AppStorage(Einstellung.gelesenReduzieren) private var gelesenReduzieren = true
    @AppStorage(Einstellung.neuesteOben) private var neuesteOben = false
    @AppStorage(Einstellung.signatur) private var signatur = ""
    @AppStorage(Einstellung.sendeVerzoegerung) private var sendeVerzoegerung = 10
    @AppStorage(Einstellung.standardKonto) private var standardKonto = ""
    @AppStorage(Einstellung.archivStattLoeschen) private var archivStattLoeschen = false
    @AppStorage(Einstellung.mitteilungen) private var mitteilungen = true
    @State private var neuesKonto = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Accounts") {
                    ForEach(store.konten) { k in
                        NavigationLink {
                            KontoDetailAnsicht(konto: k)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(k.name)
                                Text("\(k.adresse) · \(k.protokoll == .jmap ? "JMAP" : "IMAP")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button("Account hinzufügen", systemImage: "plus") { neuesKonto = true }
                }
                Section("Nachrichtenliste") {
                    Picker("Vorschau", selection: $vorschauZeilen) {
                        Text("Keine").tag(0)
                        ForEach(1...5, id: \.self) { n in Text("\(n) Zeilen").tag(n) }
                    }
                    Toggle("An/Kopie-Etiketten zeigen", isOn: $anKopieLabel)
                    Toggle("Kontaktfotos zeigen", isOn: $kontaktfotos)
                }
                Section("Streichgesten") {
                    Picker("Nach links", selection: $wischLinks) {
                        ForEach(WischAktion.allCases) { a in Text(a.titel).tag(a.rawValue) }
                    }
                    Picker("Nach rechts", selection: $wischRechts) {
                        ForEach(WischAktion.allCases) { a in Text(a.titel).tag(a.rawValue) }
                    }
                }
                Section {
                    Toggle("Vor dem Löschen fragen", isOn: $loeschenBestaetigen)
                    Toggle("Archivieren statt Löschen", isOn: $archivStattLoeschen)
                    Toggle("Bilder aus dem Internet laden", isOn: $ferninhalteLaden)
                } header: { Text("Nachrichten") } footer: {
                    Text("Bilder aus dem Internet können verraten, wann du eine E‑Mail öffnest. Ohne diese Option lädst du sie je E‑Mail selbst.")
                }
                Section("Konversationen") {
                    Toggle("Nach Konversation ordnen", isOn: $nachKonversation)
                    Toggle("Gelesene Nachr. reduzieren", isOn: $gelesenReduzieren)
                    Toggle("Neueste Nachricht ganz oben", isOn: $neuesteOben)
                }
                Section("Verfassen") {
                    NavigationLink("Signatur") {
                        Form { TextEditor(text: $signatur).frame(minHeight: 140) }.navigationTitle("Signatur")
                    }
                    if store.konten.count > 1 {
                        Picker("Standardaccount", selection: $standardKonto) {
                            ForEach(store.konten) { k in Text(k.name).tag(k.id.uuidString) }
                        }
                    }
                    Picker("Senden widerrufen", selection: $sendeVerzoegerung) {
                        Text("Aus").tag(0)
                        Text("10 Sekunden").tag(10)
                        Text("20 Sekunden").tag(20)
                        Text("30 Sekunden").tag(30)
                    }
                }
                Section {
                    Toggle("Mitteilungen bei neuen E‑Mails", isOn: $mitteilungen)
                } header: { Text("Abruf") } footer: {
                    Text("iOS ruft im Hintergrund in unregelmäßigen Abständen neue E‑Mails ab. Sofortige Mitteilungen bräuchten einen eigenen Push-Dienst auf deinem Server.")
                }
                Section {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
                    NavigationLink("Lizenzen") { LizenzenAnsicht() }
                } footer: {
                    Text("HomePost spricht nur mit deinem eigenen Mailserver. Keine Analyse, keine Drittanbieter.")
                }
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { schliessen() } } }
            .sheet(isPresented: $neuesKonto) { KontoEinrichtenAnsicht(ersterStart: false) }
        }
    }
}

/// Account bearbeiten, Verbindung prüfen, entfernen.
struct KontoDetailAnsicht: View {
    @State var konto: KontoKonfiguration
    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var zurueck
    @State private var passwort = ""
    @State private var pruefung: String?
    @State private var prueft = false
    @State private var entfernenFrage = false

    var body: some View {
        Form {
            Section("Account") {
                TextField("Beschreibung", text: $konto.name)
                TextField("Name", text: $konto.vollerName)
                LabeledContent("E‑Mail", value: konto.adresse)
                SecureField("Neues Passwort (optional)", text: $passwort)
            }
            Section("Server") {
                LabeledContent("Protokoll", value: konto.protokoll == .jmap ? "JMAP" : "IMAP/SMTP")
                if konto.protokoll == .jmap {
                    TextField("Adresse", text: $konto.jmapURL).textInputAutocapitalization(.never).autocorrectionDisabled()
                } else {
                    TextField("IMAP-Server", text: $konto.imapHost).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("IMAP-Port", value: $konto.imapPort, format: .number.grouping(.never)).keyboardType(.numberPad)
                    TextField("SMTP-Server", text: $konto.smtpHost).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("SMTP-Port", value: $konto.smtpPort, format: .number.grouping(.never)).keyboardType(.numberPad)
                    Picker("Sicherheit", selection: $konto.sicherheit) {
                        Text("TLS").tag(Verschluesselung.tls)
                        Text("STARTTLS").tag(Verschluesselung.starttls)
                        Text("Unverschlüsselt (nur Heimnetz)").tag(Verschluesselung.unverschluesselt)
                    }
                }
                if konto.istUnverschluesselt {
                    Label("Unverschlüsselt: Passwort und E‑Mails gehen im Klartext durchs Netz. Nur für einen Testserver im eigenen Heimnetz.",
                          systemImage: "exclamationmark.shield").font(.footnote).foregroundStyle(.orange)
                }
            }
            Section {
                Button(prueft ? "Prüfe …" : "Verbindung prüfen") { Task { await pruefen() } }.disabled(prueft)
                if let pruefung { Text(pruefung).font(.footnote).foregroundStyle(.secondary) }
            }
            Section {
                Button("Sichern") {
                    do {
                        try store.kontoAendern(konto, passwort: passwort.isEmpty ? nil : passwort)
                        zurueck()
                    } catch { store.melde(error) }
                }
                Button("Account löschen", role: .destructive) { entfernenFrage = true }
            }
        }
        .navigationTitle(konto.name)
        .confirmationDialog("Account von diesem iPhone entfernen?", isPresented: $entfernenFrage, titleVisibility: .visible) {
            Button("Account löschen", role: .destructive) { store.kontoEntfernen(konto); zurueck() }
        } message: {
            Text("Die E‑Mails bleiben auf dem Server.")
        }
    }

    private func pruefen() async {
        prueft = true
        defer { prueft = false }
        do {
            let pw = passwort.isEmpty ? (Schluesselbund.laden(fuer: konto.id) ?? "") : passwort
            let b = try BackendFabrik.backend(fuer: konto, passwort: pw)
            try await b.pruefen()
            await b.trennen()
            pruefung = String(localized: "Verbindung und Anmeldung in Ordnung.")
        } catch {
            pruefung = error.localizedDescription
        }
    }
}

/// Hinweise zu Fremdbibliotheken (alle MIT/BSD/Apache).
struct LizenzenAnsicht: View {
    private let eintraege: [(String, String)] = [
        ("HomePost", "MIT License – HomeRoll contributors"),
        ("SwiftMail (Cocoanetics)", "BSD 2-Clause License – IMAP/SMTP"),
        ("swift-nio, swift-nio-imap, swift-nio-ssl, swift-log, swift-collections (Apple)", "Apache License 2.0"),
        ("SwiftCross (Cocoanetics)", "BSD 2-Clause License"),
    ]

    var body: some View {
        List(eintraege, id: \.0) { e in
            VStack(alignment: .leading, spacing: 4) {
                Text(e.0).font(.headline)
                Text(e.1).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Lizenzen")
    }
}
