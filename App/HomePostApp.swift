import BackgroundTasks
import SwiftUI
import UserNotifications

@main
struct HomePostApp: App {
    @State private var store = MailStore.shared
    @Environment(\.scenePhase) private var phase

    static let abrufID = "org.homeroll.homepost.abruf"

    var body: some Scene {
        WindowGroup {
            RootAnsicht()
                .environment(store)
                .onOpenURL { url in
                    if url.scheme == "mailto" { store.verfassenAuftrag = VerfassenAuftrag(art: .mailto(url)) }
                }
        }
        .onChange(of: phase) { _, neu in
            if neu == .background { Self.abrufPlanen() }
            if neu == .active {
                Task { try? await UNUserNotificationCenter.current().setBadgeCount(store.ungelesenGesamt) }
            }
        }
        .backgroundTask(.appRefresh(Self.abrufID)) {
            await MailStore.shared.hintergrundAbruf()
            await MainActor.run { Self.abrufPlanen() }
        }
    }

    /// iOS weckt die App unregelmäßig (frühestens nach 15 min) – echtes Push bräuchte einen eigenen Relay (P2).
    static func abrufPlanen() {
        let anfrage = BGAppRefreshTaskRequest(identifier: abrufID)
        anfrage.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(anfrage)
    }
}

/// Was im Verfassen-Fenster geöffnet werden soll.
struct VerfassenAuftrag: Identifiable {
    enum Art {
        case neu
        case antworten(NachrichtKopf)
        case allenAntworten(NachrichtKopf)
        case weiterleiten(NachrichtKopf)
        case entwurf(NachrichtKopf)
        case wiederaufnehmen(AusgangEintrag)
        case mailto(URL)
    }
    let id = UUID()
    let art: Art
}

struct RootAnsicht: View {
    @Environment(MailStore.self) private var store
    @State private var pfad = NavigationPath()

    var body: some View {
        @Bindable var store = store
        Group {
            if store.konten.isEmpty {
                KontoEinrichtenAnsicht(ersterStart: true)
            } else {
                NavigationStack(path: $pfad) {
                    PostfaecherAnsicht()
                        .navigationDestination(for: ListenQuelle.self) { q in
                            NachrichtenListeAnsicht(quelle: q)
                        }
                        .navigationDestination(for: KonversationsZiel.self) { z in
                            KonversationAnsicht(kopf: z.kopf, quelle: z.quelle)
                        }
                }
                .task {
                    #if DEBUG
                    if let start = ProcessInfo.processInfo.environment["HOMEPOST_START"] { debugStart(start) }
                    #endif
                    await store.aktualisierenAlles()
                    if !store.debugKonten {
                        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
                    }
                }
            }
        }
        .sheet(item: $store.verfassenAuftrag) { auftrag in
            VerfassenAnsicht(auftrag: auftrag)
        }
        .overlay(alignment: .bottom) { hinweise }
        .onChange(of: store.wiederOeffnen?.id) { _, id in
            guard id != nil, let e = store.wiederOeffnen else { return }
            store.wiederOeffnen = nil
            store.verfassenAuftrag = VerfassenAuftrag(art: .wiederaufnehmen(e))
        }
        .fehlerAnzeige(store)
    }

    @ViewBuilder private var hinweise: some View {
        VStack(spacing: 8) {
            ForEach(store.ausgang) { e in
                GlasHinweis(text: String(localized: "E‑Mail wird gesendet …"), knopf: "Senden widerrufen") {
                    store.sendenWiderrufen(e.id)
                }
                .accessibilityIdentifier("sendenWiderrufen")
            }
            if let w = store.widerruf {
                GlasHinweis(text: w.text, knopf: "Widerrufen") { Task { await store.widerrufen() } }
                    .task(id: w.id) {
                        try? await Task.sleep(for: .seconds(6))
                        if store.widerruf?.id == w.id { store.widerruf = nil }
                    }
                    .accessibilityIdentifier("widerrufen")
            }
        }
        .padding(.bottom, 70)
        .animation(.spring(duration: 0.35), value: store.ausgang.count)
        .animation(.spring(duration: 0.35), value: store.widerruf?.id)
    }

    #if DEBUG
    /// Für Screenshots/UI-Tests direkt in eine Ansicht springen: „eingang“, „konto2“, „ordner:<Name>“
    private func debugStart(_ s: String) {
        guard let k = store.konten.first else { return }
        Task {
            await store.postfaecherLaden(k.id)
            if s == "eingang", let e = store.postfach(k.id, .eingang) {
                pfad.append(ListenQuelle.postfach(k.id, e.id))
            } else if s.hasPrefix("ordner:"), let p = store.postfaecher[k.id]?.first(where: { $0.name == s.dropFirst(7) }) {
                pfad.append(ListenQuelle.postfach(k.id, p.id))
            }
        }
    }
    #endif
}

struct KonversationsZiel: Hashable {
    let kopf: NachrichtKopf
    let quelle: ListenQuelle?
}
