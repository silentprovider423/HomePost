import SwiftUI
import UIKit

/// „Bewegen“: Postfach auswählen (zuerst das Konto der E-Mail).
struct BewegenAnsicht: View {
    let koepfe: [NachrichtKopf]
    let quelle: ListenQuelle?
    var fertig: () -> Void = {}
    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var schliessen
    @State private var kopieren = false

    private var konto: UUID? { koepfe.first?.kontoID }

    var body: some View {
        NavigationStack {
            List {
                if let k = koepfe.first {
                    Section {
                        HStack(spacing: 12) {
                            Monogramm(adresse: k.absender, groesse: 34)
                            VStack(alignment: .leading) {
                                Text(k.absender?.anzeige ?? "").font(.headline)
                                Text(koepfe.count > 1 ? String(localized: "\(koepfe.count) E‑Mails") : k.betreff)
                                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
                if let konto, let liste = store.postfaecher[konto] {
                    Section(store.konto(konto)?.name ?? "") {
                        ForEach(liste.filter(\.auswaehlbar)) { p in
                            let aktuell = koepfe.allSatisfy { $0.postfachIDs.contains(p.id) }
                            Button {
                                Task {
                                    await store.ausfuehren(kopieren ? .kopieren(p) : .bewegen(p), koepfe, in: quelle)
                                    fertig()
                                }
                                schliessen()
                            } label: {
                                Label(MailStore.anzeigeName(p), systemImage: p.symbol)
                                    .padding(.leading, CGFloat(p.tiefe) * 18)
                            }
                            .disabled(aktuell)
                            .accessibilityIdentifier("ziel-\(MailStore.anzeigeName(p))")
                        }
                    }
                }
            }
            .navigationTitle(kopieren ? "Kopieren" : "Bewegen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen", role: .cancel) { schliessen() } }
                ToolbarItem(placement: .primaryAction) {
                    Toggle("Kopieren", isOn: $kopieren).toggleStyle(.button)
                }
            }
        }
    }
}

/// Aktionskarte („Mehr“) wie Apple: Antworten, Weiterleiten, Markieren mit Farben, Bewegen, Spam, Drucken, Teilen …
struct AktionskarteAnsicht: View {
    let kopf: NachrichtKopf
    let quelle: ListenQuelle?
    var entfernt: () -> Void = {}
    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var schliessen
    @State private var bewegen = false
    @State private var teilen: TeilbareDatei?

    private var k: NachrichtKopf {
        for l in store.listen.values { if let f = l.first(where: { $0.id == kopf.id }) { return f } }
        return kopf
    }

    private var imSpam: Bool { k.postfachIDs.contains { store.postfach(k.kontoID, id: $0)?.rolle == .spam } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        Monogramm(adresse: k.absender, groesse: 40)
                        VStack(alignment: .leading) {
                            Text(k.absender?.anzeige ?? "").font(.headline)
                            Text(k.betreff).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
                Section {
                    zeile("Antworten", "arrowshape.turn.up.left") { store.verfassenAuftrag = .init(art: .antworten(k)) }
                    zeile("Allen antworten", "arrowshape.turn.up.left.2") { store.verfassenAuftrag = .init(art: .allenAntworten(k)) }
                    zeile("Weiterleiten", "arrowshape.turn.up.right") { store.verfassenAuftrag = .init(art: .weiterleiten(k)) }
                }
                Section {
                    HStack(spacing: 0) {
                        ForEach(FahnenFarbe.allCases, id: \.self) { f in
                            Button {
                                Task { await store.ausfuehren(.markieren(true, f), [k], in: quelle) }
                            } label: {
                                ZStack {
                                    Circle().fill(f.farbe).frame(width: 30, height: 30)
                                    if k.markiert && k.fahne == f {
                                        Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(f.titel))
                            .accessibilityIdentifier("farbe-\(f.rawValue)")
                        }
                    }
                    .padding(.vertical, 4)
                    if k.markiert {
                        zeile("Markierung entfernen", "flag.slash", schliesst: false) {
                            Task { await store.ausfuehren(.markieren(false, nil), [k], in: quelle) }
                        }
                    }
                }
                Section {
                    zeile(k.gelesen ? "Als ungelesen markieren" : "Als gelesen markieren",
                          k.gelesen ? "envelope.badge" : "envelope.open") {
                        Task { await store.ausfuehren(.gelesen(!k.gelesen), [k], in: quelle) }
                    }
                    zeile("E‑Mail bewegen …", "folder", schliesst: false) { bewegen = true }
                    zeile("Archivieren", "archivebox") {
                        Task { await store.ausfuehren(.archivieren, [k], in: quelle); entfernt() }
                    }
                    zeile(imSpam ? "In Eingang bewegen" : "In „Spam“ bewegen", imSpam ? "tray" : "xmark.bin") {
                        Task { await store.ausfuehren(imSpam ? .keinSpam : .spam, [k], in: quelle); entfernt() }
                    }
                    zeile("Löschen", "trash", rolle: .destructive) {
                        Task { await store.ausfuehren(.loeschen, [k], in: quelle); entfernt() }
                    }
                }
                Section {
                    if let a = k.absender {
                        zeile(store.vip.contains(a.email.lowercased()) ? "Aus VIP entfernen" : "Zu VIP hinzufügen", "star") {
                            store.vipUmschalten(a.email)
                        }
                    }
                    zeile("Drucken", "printer") { Task { await drucken() } }
                    zeile("Als .eml-Datei teilen", "square.and.arrow.up", schliesst: false) { Task { await emlTeilen() } }
                }
            }
            .navigationTitle("Aktionen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { schliessen() } }
            }
            .sheet(isPresented: $bewegen) {
                BewegenAnsicht(koepfe: [k], quelle: quelle) { entfernt(); schliessen() }
            }
            .sheet(item: $teilen) { t in TeilenBlatt(elemente: [t.url]).presentationDetents([.medium]) }
        }
    }

    private func zeile(_ titel: LocalizedStringKey, _ symbol: String, rolle: ButtonRole? = nil, schliesst: Bool = true,
                       _ aktion: @escaping () -> Void) -> some View {
        Button(role: rolle) {
            aktion()
            if schliesst { schliessen() }
        } label: {
            Label(titel, systemImage: symbol)
        }
    }

    private func emlTeilen() async {
        do {
            let d = try await store.rohdaten(k)
            let name = (k.betreff.isEmpty ? "E-Mail" : String(k.betreff.prefix(60))) + ".eml"
            teilen = TeilbareDatei(url: try TempDatei.schreiben(d, name: name))
        } catch { store.melde(error) }
    }

    private func drucken() async {
        do {
            let i = try await store.inhalt(k)
            let koerper = i.html ?? MailHTML.ausText(i.text ?? "")
            let kopf = "<h3>\(MailHTML.maskieren(k.betreff))</h3><p>\(MailHTML.maskieren(k.absender?.formatiert ?? ""))<br>\(MailDatum.lang(k.datum))</p><hr>"
            let ctrl = UIPrintInteractionController.shared
            ctrl.printFormatter = UIMarkupTextPrintFormatter(markupText: MailHTML.einbetten(kopf + koerper))
            ctrl.present(animated: true)
        } catch { store.melde(error) }
    }
}
