import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Verfassen / Antworten / Weiterleiten wie Apple Mail: An, Kopie/Blindkopie, Von, Betreff, Text mit Format,
/// Anhänge (Fotos, Dateien), Entwurf sichern/löschen beim Abbrechen, „Senden widerrufen“ danach.
struct VerfassenAnsicht: View {
    let auftrag: VerfassenAuftrag
    @Environment(MailStore.self) private var store
    @Environment(\.dismiss) private var schliessen
    @AppStorage(Einstellung.signatur) private var signatur = ""

    @State private var an = ""
    @State private var kopie = ""
    @State private var blindkopie = ""
    @State private var betreff = ""
    @State private var text = AttributedString("")
    @State private var auswahl = AttributedTextSelection()
    @State private var kontoID: UUID?
    @State private var anhaenge: [AusgehenderAnhang] = []
    @State private var kopieOffen = false
    @State private var abbrechenFrage = false
    @State private var fotoAuswahl: [PhotosPickerItem] = []
    @State private var fotosZeigen = false
    @State private var dateienZeigen = false
    @State private var vorbereitet = false
    @State private var anfang = ""
    @State private var inReplyTo: String?
    @State private var referenzen: [String] = []
    @State private var antwortAuf: NachrichtKopf?
    @State private var weitergeleitet = false
    @State private var alterEntwurf: NachrichtKopf?
    @State private var originalAnhaenge: [AnhangInfo] = []
    @State private var originalKopf: NachrichtKopf?
    @FocusState private var fokus: Feld?

    enum Feld: Hashable { case an, kopie, blindkopie, betreff, text }

    private var konto: KontoKonfiguration? { kontoID.flatMap(store.konto) ?? store.standardKonto }

    private var empfaenger: [MailAdresse] { MailAdresse.liste(an) + MailAdresse.liste(kopie) + MailAdresse.liste(blindkopie) }

    private var geaendert: Bool { zusammenfassung != anfang }
    private var zusammenfassung: String { "\(an)|\(kopie)|\(blindkopie)|\(betreff)|\(String(text.characters))|\(anhaenge.count)" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    adressFeld("An:", $an, .an)
                    if kopieOffen || !kopie.isEmpty || !blindkopie.isEmpty {
                        adressFeld("Kopie:", $kopie, .kopie)
                        adressFeld("Blindkopie:", $blindkopie, .blindkopie)
                        vonFeld
                    } else {
                        Button { kopieOffen = true; fokus = .kopie } label: {
                            feldZeile("Kopie/Blindkopie, Von:") { Text(konto?.adresse ?? "").foregroundStyle(.secondary).lineLimit(1) }
                        }
                        .buttonStyle(.plain)
                    }
                    feldZeile("Betreff:") {
                        TextField("", text: $betreff).focused($fokus, equals: .betreff)
                            .accessibilityIdentifier("feldBetreff")
                    }
                    if !anhaenge.isEmpty { anhangLeiste }
                    TextEditor(text: $text, selection: $auswahl)
                        .focused($fokus, equals: .text)
                        .frame(minHeight: 320)
                        .scrollDisabled(true)
                        .padding(.horizontal, 12)
                        .accessibilityIdentifier("feldText")
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(betreff.isEmpty ? String(localized: "Neue E‑Mail") : betreff)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen", systemImage: "xmark") {
                        if geaendert { abbrechenFrage = true } else { schliessen() }
                    }
                    .accessibilityIdentifier("abbrechen")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Senden", systemImage: "arrow.up") { senden() }
                        .buttonStyle(.glassProminent)
                        .disabled(empfaenger.isEmpty || konto == nil)
                        .accessibilityIdentifier("senden")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Button("Fett", systemImage: "bold") { formatieren(.fett) }
                    Button("Kursiv", systemImage: "italic") { formatieren(.kursiv) }
                    Button("Unterstrichen", systemImage: "underline") { formatieren(.unterstrichen) }
                    Spacer()
                    Button("Foto auswählen", systemImage: "photo.on.rectangle") { fotosZeigen = true }
                    Button("Datei anhängen", systemImage: "paperclip") { dateienZeigen = true }
                }
                ToolbarItem(placement: .bottomBar) {
                    Menu {
                        Button("Foto auswählen", systemImage: "photo.on.rectangle") { fotosZeigen = true }
                        Button("Datei anhängen", systemImage: "doc") { dateienZeigen = true }
                        if !originalAnhaenge.isEmpty {
                            Button("Anhänge der Original-E‑Mail übernehmen", systemImage: "paperclip") {
                                Task { await originalAnhaengeHolen() }
                            }
                        }
                    } label: { Label("Anhang", systemImage: "paperclip") }
                }
            }
            .confirmationDialog("", isPresented: $abbrechenFrage) {
                Button("Entwurf löschen", role: .destructive) {
                    if let alt = alterEntwurf { Task { await store.entwurfLoeschen(alt) } }
                    schliessen()
                }
                Button("Entwurf sichern") {
                    if let k = konto, let n = nachricht() {
                        let alt = alterEntwurf
                        Task { await store.entwurfSichern(n, konto: k.id, ersetzt: alt) }
                    }
                    schliessen()
                }
                .accessibilityIdentifier("entwurfSichern")
                Button("Abbrechen", role: .cancel) {}
            }
            .photosPicker(isPresented: $fotosZeigen, selection: $fotoAuswahl, maxSelectionCount: 10, matching: .images)
            .onChange(of: fotoAuswahl) { _, neu in Task { await fotosUebernehmen(neu) } }
            .fileImporter(isPresented: $dateienZeigen, allowedContentTypes: [.item], allowsMultipleSelection: true) { r in
                if case .success(let urls) = r { dateienUebernehmen(urls) }
            }
            .task { if !vorbereitet { await vorbereiten() } }
        }
        .interactiveDismissDisabled(geaendert)
    }

    // MARK: Felder

    private func feldZeile<Inhalt: View>(_ titel: LocalizedStringKey, @ViewBuilder _ inhalt: () -> Inhalt) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(titel).foregroundStyle(.secondary)
                inhalt()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            Divider().padding(.leading, 16)
        }
    }

    private func adressFeld(_ titel: LocalizedStringKey, _ wert: Binding<String>, _ f: Feld) -> some View {
        VStack(spacing: 0) {
            feldZeile(titel) {
                TextField("", text: wert)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($fokus, equals: f)
                    .accessibilityIdentifier(f == .an ? "feldAn" : f == .kopie ? "feldKopie" : "feldBlindkopie")
            }
            if fokus == f {
                let letztes = wert.wrappedValue.split(separator: ",").last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
                let vorschlaege = store.adressVorschlaege(letztes).filter { v in !MailAdresse.liste(wert.wrappedValue).contains { $0.email == v.email } }
                if !letztes.isEmpty && !vorschlaege.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(vorschlaege, id: \.email) { v in
                            Button {
                                var teile = wert.wrappedValue.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                                if !teile.isEmpty { teile.removeLast() }
                                teile.append(v.formatiert)
                                wert.wrappedValue = teile.joined(separator: ", ") + ", "
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(v.anzeige).font(.subheadline.weight(.semibold))
                                    Text(v.email).font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16).padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .background(.background.secondary)
                }
            }
        }
    }

    private var vonFeld: some View {
        feldZeile("Von:") {
            Picker("", selection: Binding(get: { konto?.id }, set: { kontoID = $0 })) {
                ForEach(store.konten) { k in Text(k.adresse).tag(Optional(k.id)) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
    }

    private var anhangLeiste: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(anhaenge) { a in
                    HStack(spacing: 6) {
                        Image(systemName: a.mimeTyp.hasPrefix("image/") ? "photo" : "doc")
                        VStack(alignment: .leading) {
                            Text(a.name).font(.caption).lineLimit(1)
                            Text(a.daten.count.dateiGroesse).font(.caption2).foregroundStyle(.secondary)
                        }
                        Button { anhaenge.removeAll { $0.id == a.id } } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .background(.quaternary, in: .rect(cornerRadius: 10))
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
    }

    // MARK: Format

    enum Format { case fett, kursiv, unterstrichen }

    private func formatieren(_ f: Format) {
        text.transformAttributes(in: &auswahl) { c in
            switch f {
            case .unterstrichen:
                c.underlineStyle = c.underlineStyle == nil ? .single : nil
            case .fett, .kursiv:
                var stil = TextStil(font: c.font)
                if f == .fett { stil.fett.toggle() } else { stil.kursiv.toggle() }
                c.font = stil.font
            }
        }
    }

    // MARK: Vorbereiten

    private func vorbereiten() async {
        vorbereitet = true
        let sig = signatur.isEmpty ? "" : "\n\n" + signatur
        switch auftrag.art {
        case .neu:
            text = AttributedString(sig)
            fokus = .an
        case .mailto(let url):
            let k = URLComponents(url: url, resolvingAgainstBaseURL: false)
            an = k?.path ?? ""
            for q in k?.queryItems ?? [] {
                switch q.name.lowercased() {
                case "subject": betreff = q.value ?? ""
                case "cc": kopie = q.value ?? ""
                case "bcc": blindkopie = q.value ?? ""
                case "body": text = AttributedString((q.value ?? "") + sig)
                default: break
                }
            }
            if text.characters.isEmpty { text = AttributedString(sig) }
        case .antworten(let k), .allenAntworten(let k):
            kontoID = k.kontoID
            antwortAuf = k
            originalKopf = k
            let eigene = store.konto(k.kontoID)?.adresse.lowercased()
            let ziel = k.antwortAn.isEmpty ? k.von : k.antwortAn
            var liste = ziel
            var cc: [MailAdresse] = []
            if case .allenAntworten = auftrag.art {
                liste += k.an.filter { $0.email.lowercased() != eigene }
                cc = k.kopie.filter { $0.email.lowercased() != eigene }
            }
            an = eindeutig(liste).map(\.formatiert).joined(separator: ", ")
            kopie = cc.map(\.formatiert).joined(separator: ", ")
            betreff = Zitat.antwortBetreff(k.betreff)
            inReplyTo = k.messageID
            referenzen = k.referenzen + [k.messageID].compactMap { $0 }
            let original = (try? await store.inhalt(k))
            originalAnhaenge = original?.anhaenge.filter { !$0.eingebettet } ?? []
            text = AttributedString(sig + Zitat.antwortText(original: original?.text ?? k.vorschau, von: k.absender, datum: k.datum))
            fokus = .text
            auswahl = AttributedTextSelection(insertionPoint: text.startIndex)
        case .weiterleiten(let k):
            kontoID = k.kontoID
            antwortAuf = k
            weitergeleitet = true
            originalKopf = k
            betreff = Zitat.weiterleitenBetreff(k.betreff)
            referenzen = k.referenzen + [k.messageID].compactMap { $0 }
            let original = (try? await store.inhalt(k))
            text = AttributedString(sig + Zitat.weiterleitenText(original: original?.text ?? k.vorschau, kopf: k))
            originalAnhaenge = original?.anhaenge.filter { !$0.eingebettet } ?? []
            await originalAnhaengeHolen()
            fokus = .an
        case .entwurf(let k):
            kontoID = k.kontoID
            alterEntwurf = k
            an = k.an.map(\.formatiert).joined(separator: ", ")
            kopie = k.kopie.map(\.formatiert).joined(separator: ", ")
            blindkopie = k.blindkopie.map(\.formatiert).joined(separator: ", ")
            betreff = k.betreff
            inReplyTo = k.inReplyTo.first
            referenzen = k.referenzen
            if let i = try? await store.inhalt(k) {
                text = AttributedString(i.text ?? "")
                for a in i.anhaenge where !a.eingebettet {
                    if let d = try? await store.anhang(a, von: k) {
                        anhaenge.append(AusgehenderAnhang(name: a.name, mimeTyp: a.mimeTyp, daten: d))
                    }
                }
            }
        case .wiederaufnehmen(let e):
            let n = e.nachricht
            kontoID = e.konto
            antwortAuf = e.antwortAuf
            weitergeleitet = e.weitergeleitet
            alterEntwurf = e.entwurf
            an = n.an.map(\.formatiert).joined(separator: ", ")
            kopie = n.kopie.map(\.formatiert).joined(separator: ", ")
            blindkopie = n.blindkopie.map(\.formatiert).joined(separator: ", ")
            betreff = n.betreff
            text = AttributedString(n.text)
            anhaenge = n.anhaenge
            inReplyTo = n.inReplyTo
            referenzen = n.referenzen
        }
        anfang = zusammenfassung
    }

    private func eindeutig(_ l: [MailAdresse]) -> [MailAdresse] {
        var s: Set<String> = []
        return l.filter { s.insert($0.email.lowercased()).inserted }
    }

    private func originalAnhaengeHolen() async {
        guard let k = originalKopf else { return }
        for a in originalAnhaenge where !anhaenge.contains(where: { $0.name == a.name && $0.daten.count == a.groesse }) {
            if let d = try? await store.anhang(a, von: k) {
                anhaenge.append(AusgehenderAnhang(name: a.name, mimeTyp: a.mimeTyp, daten: d))
            }
        }
        originalAnhaenge = []
    }

    private func fotosUebernehmen(_ items: [PhotosPickerItem]) async {
        for (i, item) in items.enumerated() {
            guard let d = try? await item.loadTransferable(type: Data.self) else { continue }
            // als JPEG verkleinert senden (wie Apples „Groß“), Originaltyp bleibt bei kleinen Bildern
            var daten = d
            if let bild = UIImage(data: d), d.count > 2_500_000,
               let klein = bild.preparingThumbnail(of: CGSize(width: bild.size.width / 2, height: bild.size.height / 2))?
                .jpegData(compressionQuality: 0.8) {
                daten = klein
            }
            let endung = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
            let typ = item.supportedContentTypes.first?.preferredMIMEType ?? "image/jpeg"
            anhaenge.append(AusgehenderAnhang(name: "Foto-\(i + 1).\(endung)", mimeTyp: daten == d ? typ : "image/jpeg",
                                              daten: daten))
        }
        fotoAuswahl = []
    }

    private func dateienUebernehmen(_ urls: [URL]) {
        for u in urls {
            let zugriff = u.startAccessingSecurityScopedResource()
            defer { if zugriff { u.stopAccessingSecurityScopedResource() } }
            guard let d = try? Data(contentsOf: u) else { continue }
            let typ = UTType(filenameExtension: u.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            anhaenge.append(AusgehenderAnhang(name: u.lastPathComponent, mimeTyp: typ, daten: d))
        }
    }

    // MARK: Senden

    private func nachricht() -> AusgehendeNachricht? {
        guard let k = konto else { return nil }
        let domain = k.adresse.split(separator: "@").last.map(String.init) ?? "homepost.invalid"
        var n = AusgehendeNachricht(von: MailAdresse(name: k.vollerName.isEmpty ? nil : k.vollerName, email: k.adresse),
                                    an: MailAdresse.liste(an), kopie: MailAdresse.liste(kopie),
                                    blindkopie: MailAdresse.liste(blindkopie), betreff: betreff,
                                    text: String(text.characters))
        n.html = RichText.html(text)
        n.anhaenge = anhaenge
        n.inReplyTo = inReplyTo
        n.referenzen = referenzen
        n.messageID = AusgehendeNachricht.neueMessageID(domain: domain)
        return n
    }

    private func senden() {
        guard let k = konto, let n = nachricht() else { return }
        store.senden(n, konto: k.id, antwortAuf: antwortAuf, weitergeleitet: weitergeleitet, entwurf: alterEntwurf)
        schliessen()
    }
}

/// Fett/kursiv als feste Schriftvarianten, damit sie sich beim Senden sicher in HTML übersetzen lassen.
struct TextStil {
    var fett = false
    var kursiv = false

    init(font: Font?) {
        fett = font == .body.bold() || font == .body.bold().italic()
        kursiv = font == .body.italic() || font == .body.bold().italic()
    }

    var font: Font? {
        switch (fett, kursiv) {
        case (true, true): .body.bold().italic()
        case (true, false): .body.bold()
        case (false, true): .body.italic()
        case (false, false): nil
        }
    }
}

enum RichText {
    /// HTML-Teil nur, wenn wirklich formatiert wurde (sonst reiner Text wie Apple bei Textmails).
    static func html(_ a: AttributedString) -> String? {
        var formatiert = false
        var aus = ""
        for lauf in a.runs {
            let stil = TextStil(font: lauf.font)
            let unter = lauf.underlineStyle != nil
            if stil.fett || stil.kursiv || unter { formatiert = true }
            var t = MailHTML.maskieren(String(a[lauf.range].characters)).replacingOccurrences(of: "\n", with: "<br>")
            if unter { t = "<u>\(t)</u>" }
            if stil.kursiv { t = "<i>\(t)</i>" }
            if stil.fett { t = "<b>\(t)</b>" }
            aus += t
        }
        guard formatiert else { return nil }
        return "<html><body style=\"font-family:-apple-system,Helvetica,sans-serif\">\(aus)</body></html>"
    }
}
