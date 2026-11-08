import SwiftUI
import UIKit

// MARK: - Farben und Symbole

extension FahnenFarbe {
    var farbe: Color {
        switch self {
        case .rot: .red
        case .orange: .orange
        case .gelb: .yellow
        case .gruen: .green
        case .blau: .blue
        case .lila: .purple
        case .grau: .gray
        }
    }

    var titel: LocalizedStringKey {
        switch self {
        case .rot: "Rot"
        case .orange: "Orange"
        case .gelb: "Gelb"
        case .gruen: "Grün"
        case .blau: "Blau"
        case .lila: "Lila"
        case .grau: "Grau"
        }
    }
}

extension Postfach {
    var symbol: String {
        switch rolle {
        case .eingang: "tray"
        case .entwuerfe: "doc"
        case .gesendet: "paperplane"
        case .spam: "xmark.bin"
        case .papierkorb: "trash"
        case .archiv: "archivebox"
        case .keine: "folder"
        }
    }
}

// MARK: - Kontaktbild (Monogramm)

struct Monogramm: View {
    let adresse: MailAdresse?
    var groesse: CGFloat = 40

    private var initialen: String {
        let name = adresse?.name ?? adresse?.email ?? "?"
        let teile = name.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "@" }).prefix(2)
        return teile.compactMap { $0.first.map { String($0).uppercased() } }.joined()
    }

    /// stabile Farbe je Adresse
    private var farbe: Color {
        let palette: [Color] = [.blue, .indigo, .purple, .pink, .orange, .teal, .green, .brown]
        let h = (adresse?.email ?? "").unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[h % palette.count]
    }

    var body: some View {
        Circle()
            .fill(LinearGradient(colors: [farbe.opacity(0.75), farbe], startPoint: .top, endPoint: .bottom))
            .frame(width: groesse, height: groesse)
            .overlay(Text(initialen).font(.system(size: groesse * 0.4, weight: .semibold, design: .rounded))
                .foregroundStyle(.white))
            .accessibilityHidden(true)
    }
}

// MARK: - Datum wie Apple Mail (heute: Uhrzeit, gestern, Wochentag, sonst Datum)

enum MailDatum {
    static func kurz(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
        if cal.isDateInYesterday(d) { return String(localized: "Gestern") }
        if let tage = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: Date())).day, tage < 7 {
            return d.formatted(.dateTime.weekday(.wide))
        }
        return d.formatted(date: .numeric, time: .omitted)
    }

    static func lang(_ d: Date) -> String {
        d.formatted(date: .long, time: .shortened)
    }
}

// MARK: - Glas-Hinweis (Widerrufen / Senden widerrufen)

struct GlasHinweis: View {
    let text: String
    let knopf: LocalizedStringKey
    var kennung: String = ""
    let aktion: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(text).font(.subheadline).lineLimit(2)
            Spacer(minLength: 4)
            Button(knopf, action: aktion).font(.subheadline.weight(.semibold))
                .accessibilityIdentifier(kennung)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 16)
    }
}

// MARK: - Teilen-Blatt

struct TeilenBlatt: UIViewControllerRepresentable {
    let elemente: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: elemente, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct TeilbareDatei: Identifiable {
    let id = UUID()
    let url: URL
}

/// Legt Daten als Datei im Zwischenspeicher ab (Anhänge ansehen, .eml teilen).
enum TempDatei {
    static func schreiben(_ daten: Data, name: String) throws -> URL {
        let ordner = FileManager.default.temporaryDirectory.appending(path: "Anhaenge/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
        let sauber = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let url = ordner.appending(path: sauber.isEmpty ? "Anhang" : sauber)
        try daten.write(to: url, options: [.completeFileProtection])
        return url
    }
}

extension View {
    /// Fehlermeldung des Stores als Hinweis.
    func fehlerAnzeige(_ store: MailStore) -> some View {
        alert("Fehler", isPresented: Binding(get: { store.fehler != nil }, set: { if !$0 { store.fehler = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.fehler ?? "")
        }
    }
}

extension Int {
    var dateiGroesse: String { ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .file) }
}
