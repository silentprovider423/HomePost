#!/usr/bin/env python3
"""Erzeugt Resources/Localizable.xcstrings (Quelle Deutsch, Übersetzung Englisch).

Die Schlüssel kommen aus den .stringsdata-Dateien, die der Compiler beim Bauen schreibt
(SWIFT_EMIT_LOC_STRINGS), die englischen Texte aus EN unten. Fehlende Übersetzungen werden gemeldet.
  xcodebuild … build && python3 -I tools/strings.py
"""
import glob
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EN = {
    "%@ · %@": "%@ · %@", "%lld": "%lld", "%lld E‑Mails": "%lld emails",
    "%lld E‑Mails in „%@“ bewegt": "Moved %lld emails to “%@”", "%lld Zeilen": "%lld lines",
    "%lld ausgewählt": "%lld selected", "%lld ungelesen": "%lld unread", "1 E‑Mail in „%@“ bewegt": "Moved 1 email to “%@”",
    "10 Sekunden": "10 seconds", "20 Sekunden": "20 seconds", "30 Sekunden": "30 seconds", "Abbrechen": "Cancel",
    "Abruf": "Fetch", "Account": "Account", "Account hinzufügen": "Add Account", "Account löschen": "Delete Account",
    "Account von diesem iPhone entfernen?": "Remove this account from this iPhone?", "Accounts": "Accounts",
    "Adresse": "Address", "Aktionen": "Actions", "Aktuelles Postfach": "Current Mailbox",
    "Alle E‑Mails archivieren?": "Archive all emails?",
    "Alle E‑Mails in diesem Postfach werden auf dem Server gelöscht.": "All emails in this mailbox will be deleted on the server.",
    "Alle E‑Mails löschen?": "Delete all emails?", "Alle Posteingänge": "All Inboxes", "Alle Postfächer": "All Mailboxes",
    "Alle archivieren": "Archive All", "Alle auswählen": "Select All", "Alle löschen": "Trash All",
    "Allen antworten": "Reply All", "Als .eml-Datei teilen": "Share as .eml File", "Als gelesen markieren": "Mark as Read",
    "Als ungelesen markieren": "Mark as Unread", "Am %@ schrieb %@:": "On %@, %@ wrote:",
    "Am besten ein App-Passwort deines Servers verwenden. Es bleibt nur im Schlüsselbund dieses iPhones.":
        "Preferably use an app password from your server. It stays in this iPhone's keychain only.",
    "An": "To", "An/Kopie": "To/Cc", "An/Kopie-Etiketten zeigen": "Show To/Cc Labels", "An:": "To:", "An: %@": "To: %@",
    "An: Mich": "To: Me", "Anfang der weitergeleiteten E‑Mail:": "Begin forwarded message:", "Anhang": "Attachment",
    "Anhänge": "Attachments", "Anhänge der Original-E‑Mail übernehmen": "Include Original Attachments",
    "Antwort an: %@": "Reply-To: %@", "Antworten": "Reply", "Archiv": "Archive", "Archivieren": "Archive",
    "Archivieren statt Löschen": "Archive Instead of Delete", "Auf dem Server fehlt das Postfach „%@“.": "The mailbox “%@” is missing on the server.",
    "Aus": "Off", "Aus VIP entfernen": "Remove from VIP", "Ausblenden": "Hide", "Bearbeiten": "Edit",
    "Benutzername (optional)": "User Name (optional)", "Benutzername oder Passwort ist falsch.": "The user name or password is incorrect.",
    "Beschreibung": "Description", "Betreff:": "Subject:", "Bewegen": "Move", "Bewegen …": "Move…",
    "Bilder aus dem Internet können verraten, wann du eine E‑Mail öffnest. Ohne diese Option lädst du sie je E‑Mail selbst.":
        "Images from the internet can reveal when you open an email. Without this option you load them per email yourself.",
    "Bilder aus dem Internet laden": "Load Remote Images", "Blau": "Blue", "Blindkopie:": "Bcc:", "Datei anhängen": "Attach File",
    "Datum:": "Date:", "Der Server bietet kein JMAP Mail an.": "The server does not offer JMAP Mail.",
    "Der Server meldet: %@": "The server reports: %@", "Details": "Details",
    "Die E‑Mail konnte nicht gesendet werden und liegt jetzt in „Entwürfe“. %@": "The email could not be sent and is now in “Drafts”. %@",
    "Die E‑Mail wurde nicht gefunden.": "The email was not found.", "Die E‑Mails bleiben auf dem Server.": "The emails stay on the server.",
    "Die Identität des Servers kann nicht überprüft werden. Für einen Testserver im Heimnetz „Unverschlüsselt (nur Heimnetz)“ wählen.":
        "Cannot verify the server's identity. For a test server on your home network choose “Unencrypted (home network only)”.",
    "Diese Aktion wirkt sich auf den Server und damit auf all deine Geräte aus.": "This affects the server and therefore all your devices.",
    "Diese E‑Mail enthält Bilder aus dem Internet, die nicht geladen wurden.": "This email contains remote images that were not loaded.",
    "Drucken": "Print", "Eingang": "Inbox", "Einstellungen": "Settings", "Endgültig löschen": "Delete Permanently",
    "Entwurf löschen": "Delete Draft", "Entwurf sichern": "Save Draft", "Entwürfe": "Drafts", "E‑Mail": "Email",
    "E‑Mail bewegen": "Move Message", "E‑Mail bewegen …": "Move Message…", "E‑Mail wird gesendet …": "Sending email…",
    "E‑Mails direkt von deinem eigenen Mailserver – ohne Umweg über fremde Server.": "Email straight from your own mail server – no third-party servers in between.",
    "E‑Mails löschen?": "Delete emails?", "Fehler": "Error", "Fertig": "Done", "Fett": "Bold", "Filter": "Filter",
    "Foto auswählen": "Choose Photo", "Gefiltert nach: %@": "Filtered by: %@", "Gelb": "Yellow", "Gelesen": "Read",
    "Gelesene Nachr. reduzieren": "Collapse Read Messages", "Gerade aktualisiert": "Updated Just Now", "Gesendet": "Sent",
    "Gestern": "Yesterday", "Gib einen Namen für das neue Postfach ein.": "Enter a name for the new mailbox.", "Grau": "Gray",
    "Grün": "Green", "Heute": "Today",
    "HomePost spricht nur mit deinem eigenen Mailserver. Keine Analyse, keine Drittanbieter.": "HomePost only talks to your own mail server. No analytics, no third parties.",
    "IMAP-Port": "IMAP Port", "IMAP-Server": "IMAP Server", "IMAP/SMTP": "IMAP/SMTP", "In Eingang bewegen": "Move to Inbox",
    "In den Papierkorb": "Move to Trash", "In „Spam“ bewegen": "Move to Junk", "JMAP": "JMAP", "Kein Betreff": "No Subject",
    "Kein Empfänger": "No Recipient", "Kein Spam": "Not Junk", "Keine": "None", "Keine Absenderidentität": "No sender identity",
    "Keine E‑Mails": "No Mail", "Keine JMAP-Sitzung": "No JMAP session", "Keine Verbindung zum Server: %@": "Cannot connect to the server: %@",
    "Keine gefilterten E‑Mails": "No Filtered Mail", "Kontaktfotos zeigen": "Show Contact Photos", "Konversationen": "Threading",
    "Kopie": "Cc", "Kopie/Blindkopie, Von:": "Cc/Bcc, From:", "Kopie:": "Cc:", "Kopie: %@": "Cc: %@", "Kopie: An mich": "Cc: Me",
    "Kopieren": "Copy", "Kursiv": "Italic", "Laden": "Load",
    "Leer lassen, wenn der Server unter der Domain deiner Adresse erreichbar ist.": "Leave empty if the server is reachable at your address's domain.",
    "Lila": "Purple", "Lizenzen": "Licenses", "Löschen": "Delete", "Manuell einrichten": "Configure Manually", "Markieren": "Flag",
    "Markiert": "Flagged", "Markierung entfernen": "Unflag", "Mehr": "More", "Mit Anhängen": "With Attachments",
    "Mitteilungen bei neuen E‑Mails": "Notify on New Mail", "Nach E‑Mails suchen …": "Checking for Mail…",
    "Nach Konversation ordnen": "Organize by Thread", "Nach links": "Swipe Left", "Nach rechts": "Swipe Right",
    "Nachrichten": "Messages", "Nachrichtenliste": "Message List", "Name": "Name", "Neue E‑Mail": "New Message",
    "Neues Passwort (optional)": "New Password (optional)", "Neues Postfach": "New Mailbox", "Neues Postfach …": "New Mailbox…",
    "Neues Unterpostfach …": "New Submailbox…", "Neueste Nachricht ganz oben": "Most Recent Message on Top",
    "Nicht markieren": "Unflag", "Nur E‑Mails mit Anhängen": "Only Mail with Attachments", "Nur heute gesendet": "Only Mail Sent Today",
    "Nur von VIP": "Only from VIP", "OK": "OK", "Orange": "Orange", "Papierkorb": "Trash", "Passwort": "Password",
    "Passwort und E‑Mails gehen dann im Klartext durchs Netz. Nur für einen Testserver im eigenen Heimnetz verwenden, sonst immer TLS.":
        "Password and emails then travel the network in plain text. Use only for a test server on your own home network, otherwise always TLS.",
    "Postfach löschen": "Delete Mailbox", "Postfach löschen?": "Delete mailbox?", "Postfach umbenennen": "Rename Mailbox",
    "Postfächer": "Mailboxes", "Protokoll": "Protocol", "Prüfe …": "Checking…", "Rot": "Red", "SMTP-Port": "SMTP Port",
    "SMTP-Server": "SMTP Server", "STARTTLS": "STARTTLS", "Schlüsselbund-Fehler %d": "Keychain error %d", "Senden": "Send",
    "Senden widerrufen": "Undo Send", "Senden …": "Sending…", "Server": "Server", "Server (optional)": "Server (optional)",
    "Sicherheit": "Security", "Sichern": "Save", "Sichern oder teilen": "Save or Share", "Signatur": "Signature", "Spam": "Junk",
    "Standardaccount": "Default Account", "Streichgesten": "Swipe Options", "Suchen": "Search", "TLS": "TLS",
    "Um %@ aktualisiert": "Updated at %@", "Umbenennen": "Rename", "Unbekannt": "Unknown", "Ungelesen": "Unread",
    "Ungültige Serveradresse": "Invalid server address", "Unterstrichen": "Underline",
    "Unverschlüsselt (nur Heimnetz)": "Unencrypted (home network only)",
    "Unverschlüsselt: Passwort und E‑Mails gehen im Klartext durchs Netz. Nur für einen Testserver im eigenen Heimnetz.":
        "Unencrypted: password and emails travel the network in plain text. Only for a test server on your own home network.",
    "VIP": "VIP", "Verbindung prüfen": "Check Connection", "Verbindung und Anmeldung in Ordnung.": "Connection and sign-in OK.",
    "Verfassen": "Compose", "Version": "Version", "Von meinem iPhone gesendet": "Sent from my iPhone", "Von:": "From:",
    "Von: %@": "From: %@", "Vor dem Löschen fragen": "Ask Before Deleting", "Vorschau": "Preview", "Weiter": "Next",
    "Weiterleiten": "Forward", "Widerrufen": "Undo", "Willkommen bei HomePost": "Welcome to HomePost",
    "Zu VIP hinzufügen": "Add to VIP", "https://mail.example.com": "https://mail.example.com",
    "iOS ruft im Hintergrund in unregelmäßigen Abständen neue E‑Mails ab. Sofortige Mitteilungen bräuchten einen eigenen Push-Dienst auf deinem Server.":
        "iOS fetches new mail in the background at irregular intervals. Instant notifications would need your own push service on your server.",
    "Übersicht": "Quick Look", "Dokument scannen": "Scan Document", "Gescanntes Dokument": "Scanned Document",
    "Ort des Postfachs": "Mailbox Location", "Keine Verbindung": "No Connection", "%lld ausgewählt ": "%lld selected",
}


def main():
    keys = set()
    muster = os.path.join(ROOT, "build/Build/Intermediates.noindex/HomePost.build/*/HomePost.build/Objects-normal/*/*.stringsdata")
    for f in glob.glob(muster):
        for liste in json.load(open(f))["tables"].values():
            keys.update(e["key"] for e in liste)
    keys.discard("")
    if not keys:
        sys.exit("Keine .stringsdata gefunden – erst bauen.")
    fehlend = sorted(k for k in keys if k not in EN)
    strings = {}
    for k in sorted(keys):
        e = {"extractionState": "manual"}
        if k in EN:
            e["localizations"] = {"en": {"stringUnit": {"state": "translated", "value": EN[k]}}}
        strings[k] = e
    ziel = os.path.join(ROOT, "Resources/Localizable.xcstrings")
    json.dump({"sourceLanguage": "de", "strings": strings, "version": "1.0"}, open(ziel, "w"), ensure_ascii=False, indent=2,
              sort_keys=True)
    print(f"{len(keys)} Schlüssel, {len(fehlend)} ohne Übersetzung")
    for k in fehlend:
        print("  FEHLT:", repr(k))


if __name__ == "__main__":
    main()
