import SwiftUI

/// Account hinzufügen: E-Mail + Passwort, Server wird erkannt (JMAP zuerst, sonst IMAP/SMTP).
/// „Manuell“ für eigene Ports; „Unverschlüsselt (nur Heimnetz)“ nur für Testserver.
struct KontoEinrichtenAnsicht: View {
    let ersterStart: Bool
    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var schliessen

    @State private var name = ""
    @State private var adresse = ""
    @State private var passwort = ""
    @State private var server = ""
    @State private var benutzer = ""
    @State private var unverschluesselt = false
    @State private var manuell = false
    @State private var protokoll = MailProtokoll.jmap
    @State private var jmapURL = ""
    @State private var imapHost = ""
    @State private var imapPort = 993
    @State private var smtpHost = ""
    @State private var smtpPort = 465
    @State private var sicherheit = Verschluesselung.tls
    @State private var prueft = false
    @State private var fehler: String?

    private var vollstaendig: Bool { adresse.contains("@") && !passwort.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                if ersterStart {
                    Section {
                        VStack(spacing: 10) {
                            Image(systemName: "envelope.fill").font(.system(size: 52)).foregroundStyle(.tint)
                            Text("Willkommen bei HomePost").font(.title2.bold())
                            Text("E‑Mails direkt von deinem eigenen Mailserver – ohne Umweg über fremde Server.")
                                .multilineTextAlignment(.center).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .listRowBackground(Color.clear)
                }
                Section {
                    TextField("Name", text: $name).textContentType(.name)
                    TextField("E‑Mail", text: $adresse)
                        .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .textContentType(.emailAddress).accessibilityIdentifier("adresse")
                    SecureField("Passwort", text: $passwort).textContentType(.password).accessibilityIdentifier("passwort")
                } footer: {
                    Text("Am besten ein App-Passwort deines Servers verwenden. Es bleibt nur im Schlüsselbund dieses iPhones.")
                }
                Section {
                    TextField("Server (optional)", text: $server)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("Benutzername (optional)", text: $benutzer)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Toggle("Unverschlüsselt (nur Heimnetz)", isOn: $unverschluesselt)
                    Toggle("Manuell einrichten", isOn: $manuell)
                } footer: {
                    if unverschluesselt {
                        Label("Passwort und E‑Mails gehen dann im Klartext durchs Netz. Nur für einen Testserver im eigenen Heimnetz verwenden, sonst immer TLS.",
                              systemImage: "exclamationmark.shield").foregroundStyle(.orange)
                    } else {
                        Text("Leer lassen, wenn der Server unter der Domain deiner Adresse erreichbar ist.")
                    }
                }
                if manuell {
                    Section("Server") {
                        Picker("Protokoll", selection: $protokoll) {
                            Text("JMAP").tag(MailProtokoll.jmap)
                            Text("IMAP/SMTP").tag(MailProtokoll.imap)
                        }
                        .pickerStyle(.segmented)
                        if protokoll == .jmap {
                            TextField("https://mail.example.com", text: $jmapURL)
                                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        } else {
                            TextField("IMAP-Server", text: $imapHost).textInputAutocapitalization(.never).autocorrectionDisabled()
                            TextField("IMAP-Port", value: $imapPort, format: .number.grouping(.never)).keyboardType(.numberPad)
                            TextField("SMTP-Server", text: $smtpHost).textInputAutocapitalization(.never).autocorrectionDisabled()
                            TextField("SMTP-Port", value: $smtpPort, format: .number.grouping(.never)).keyboardType(.numberPad)
                            Picker("Sicherheit", selection: $sicherheit) {
                                Text("TLS").tag(Verschluesselung.tls)
                                Text("STARTTLS").tag(Verschluesselung.starttls)
                                Text("Unverschlüsselt (nur Heimnetz)").tag(Verschluesselung.unverschluesselt)
                            }
                        }
                    }
                }
                if let fehler {
                    Section { Label(fehler, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .navigationTitle("Account hinzufügen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !ersterStart {
                    ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { schliessen() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if prueft { ProgressView() } else {
                        Button("Weiter") { Task { await einrichten() } }.disabled(!vollstaendig)
                            .accessibilityIdentifier("weiter")
                    }
                }
            }
            .disabled(prueft)
        }
    }

    private func einrichten() async {
        prueft = true
        fehler = nil
        defer { prueft = false }
        do {
            var k: KontoKonfiguration
            if manuell {
                k = KontoKonfiguration(name: "", vollerName: name, adresse: adresse,
                                       benutzer: benutzer.isEmpty ? adresse : benutzer, protokoll: protokoll)
                k.jmapURL = jmapURL
                k.imapHost = imapHost; k.imapPort = imapPort
                k.smtpHost = smtpHost.isEmpty ? imapHost : smtpHost; k.smtpPort = smtpPort
                k.sicherheit = sicherheit
                let b = try BackendFabrik.backend(fuer: k, passwort: passwort)
                try await b.pruefen()
                await b.trennen()
            } else {
                k = try await Einrichtung.erkennen(.init(adresse: adresse, passwort: passwort, vollerName: name,
                                                         server: server, benutzer: benutzer, unverschluesselt: unverschluesselt))
            }
            k.name = adresse.split(separator: "@").last.map(String.init) ?? adresse
            if store.konten.contains(where: { $0.name == k.name }) { k.name = adresse }
            k.vollerName = name
            try store.kontoHinzufuegen(k, passwort: passwort)
            if !ersterStart { schliessen() }
        } catch {
            fehler = error.localizedDescription
        }
    }
}
