#!/usr/bin/env python3
"""Erzeugt Demo-Postfächer für HomePost auf einem Test-Mailserver (nur Testkonten!).

Liest die Zugänge aus der Umgebung (nie aus dem Repo):
  MAIL_HOST, MAIL_JMAP_URL, MAIL_USER1..3, MAIL_PASSWORD1..3

  python3 -I tools/seed-testmail.py --reset   # leert die 3 Testkonten und legt alles neu an

Ablauf: Ordner per JMAP (mit Rolle „archive“), Verlauf per IMAP APPEND mit echten
Message-ID/References (Konversationen) und Datum in der Vergangenheit, dazu eine
E-Mail live per SMTP, damit auch der Versandweg geprüft ist.
"""
import base64
import imaplib
import json
import os
import smtplib
import ssl
import struct
import sys
import time
import urllib.request
import zlib
from datetime import datetime, timedelta, timezone
from email.message import EmailMessage
from email.utils import format_datetime, make_msgid

HOST = os.environ["MAIL_HOST"]
JMAP = os.environ["MAIL_JMAP_URL"].rstrip("/")
USERS = {
    "anna": (os.environ["MAIL_USER1"], os.environ["MAIL_PASSWORD1"], "Anna Berger"),
    "ben": (os.environ["MAIL_USER2"], os.environ["MAIL_PASSWORD2"], "Ben Okafor"),
    "clara": (os.environ["MAIL_USER3"], os.environ["MAIL_PASSWORD3"], "Clara Lindqvist"),
}
CTX = ssl._create_unverified_context()  # Testserver hat nur ein selbstsigniertes Zertifikat
NOW = datetime.now(timezone.utc).replace(second=0, microsecond=0)


def addr(key):
    mail, _, name = USERS[key]
    return f"{name} <{mail}>"


# ---------- Anhänge ohne Fremdbibliotheken ----------

def png(w, h, c1, c2):
    """Einfaches Verlaufsbild (Himmel/See) als PNG."""
    rows = []
    for y in range(h):
        t = y / (h - 1)
        r, g, b = (int(c1[i] + (c2[i] - c1[i]) * t) for i in range(3))
        row = bytearray([0])
        for x in range(w):
            wave = 18 if (y > h * 0.62 and (x // 9 + y // 5) % 7 == 0) else 0
            row += bytes([min(255, r + wave), min(255, g + wave), min(255, b + wave)])
        rows.append(bytes(row))
    raw = zlib.compress(b"".join(rows), 9)

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", raw) + chunk(b"IEND", b"")


def pdf(lines):
    """Minimales, gültiges PDF mit ein paar Textzeilen."""
    text = "BT /F1 14 Tf 60 780 Td 18 TL " + " ".join(f"({l}) '" for l in lines) + " ET"
    objs = [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
        f"<< /Length {len(text)} >>\nstream\n{text}\nendstream",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    out = "%PDF-1.4\n"
    offs = []
    for i, o in enumerate(objs, 1):
        offs.append(len(out.encode("latin-1")))
        out += f"{i} 0 obj\n{o}\nendobj\n"
    xref = len(out.encode("latin-1"))
    out += f"xref\n0 {len(objs) + 1}\n0000000000 65535 f \n" + "".join(f"{o:010d} 00000 n \n" for o in offs)
    out += f"trailer\n<< /Size {len(objs) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n"
    return out.encode("latin-1")


# ---------- Nachrichten ----------

class Msg:
    def __init__(self, frm, to, subject, body, when, cc=(), reply_to_msg=None, attachments=(), html=None, extra=None,
                 frm_raw=None):
        self.id = make_msgid(domain="test.local")
        self.when = when
        m = EmailMessage()
        m["From"] = frm_raw or addr(frm)
        m["To"] = ", ".join(to)
        if cc:
            m["Cc"] = ", ".join(cc)
        m["Subject"] = subject
        m["Date"] = format_datetime(when)
        m["Message-ID"] = self.id
        if reply_to_msg:
            m["In-Reply-To"] = reply_to_msg.id
            m["References"] = " ".join(reply_to_msg.refs + [reply_to_msg.id])
            self.refs = reply_to_msg.refs + [reply_to_msg.id]
        else:
            self.refs = []
        for k, v in (extra or {}).items():
            m[k] = v
        m.set_content(body)
        if html:
            m.add_alternative(html, subtype="html")
        for name, mime, data in attachments:
            maintype, subtype = mime.split("/")
            m.add_attachment(data, maintype=maintype, subtype=subtype, filename=name)
        self.raw = m.as_bytes()


def quote(text):
    return "\n".join("> " + l for l in text.splitlines())


# ---------- Server-Zugriff ----------

def imap(key):
    mail, pw, _ = USERS[key]
    c = imaplib.IMAP4_SSL(HOST, 993, ssl_context=CTX)
    c.login(mail, pw)
    return c


def jmap(key, calls):
    mail, pw, _ = USERS[key]
    req = urllib.request.Request(JMAP + "/jmap/", method="POST", data=json.dumps({
        "using": ["urn:ietf:params:jmap:core", "urn:ietf:params:jmap:mail"], "methodCalls": calls}).encode())
    req.add_header("Content-Type", "application/json")
    req.add_header("Authorization", "Basic " + base64.b64encode(f"{mail}:{pw}".encode()).decode())
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)["methodResponses"]


def account_id(key):
    mail, pw, _ = USERS[key]
    req = urllib.request.Request(JMAP + "/jmap/session")
    req.add_header("Authorization", "Basic " + base64.b64encode(f"{mail}:{pw}".encode()).decode())
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)["primaryAccounts"]["urn:ietf:params:jmap:mail"]


def get_boxes(key):
    acc = account_id(key)
    r = jmap(key, [["Mailbox/get", {"accountId": acc, "properties": ["name", "role", "parentId"]}, "m"]])
    return acc, r[0][1]["list"]


def reset(key):
    acc, boxes = get_boxes(key)
    # alle E-Mails löschen
    q = jmap(key, [["Email/query", {"accountId": acc, "limit": 1000}, "q"]])
    ids = q[0][1]["ids"]
    if ids:
        jmap(key, [["Email/set", {"accountId": acc, "destroy": ids}, "d"]])
    # eigene Ordner entfernen (Kinder zuerst)
    custom = [b for b in boxes if not b.get("role")]
    while custom:
        parents = {b.get("parentId") for b in custom}
        leaves = [b for b in custom if b["id"] not in parents]
        jmap(key, [["Mailbox/set", {"accountId": acc, "destroy": [b["id"] for b in leaves],
                                     "onDestroyRemoveEmails": True}, "x"]])
        custom = [b for b in custom if b not in leaves]


def ensure_folders(key, spec):
    """spec: Liste von (Name, Rolle|None, Elternname|None) → {Name: IMAP-Pfad}"""
    acc, boxes = get_boxes(key)
    by_name = {b["name"]: b for b in boxes}
    for name, role, parent in spec:
        if name in by_name:
            continue
        create = {"name": name}
        if role:
            create["role"] = role
        if parent:
            create["parentId"] = by_name[parent]["id"]
        r = jmap(key, [["Mailbox/set", {"accountId": acc, "create": {"n": create}}, "c"]])
        res = r[0][1]
        if "created" not in res or "n" not in res["created"]:
            sys.exit(f"Ordner {name} für {key} nicht angelegt: {res}")
        acc, boxes = get_boxes(key)
        by_name = {b["name"]: b for b in boxes}


def put(key, box, msg, flags=""):
    c = imap(key)
    t = imaplib.Time2Internaldate(msg.when.timestamp())
    typ, data = c.append(f'"{box}"', f"({flags})" if flags else None, t, msg.raw)
    if typ != "OK":
        sys.exit(f"APPEND {key}/{box} fehlgeschlagen: {data}")
    c.logout()


INBOX, SENT, DRAFTS, TRASH, JUNK, ARCHIVE = "INBOX", "Sent Items", "Drafts", "Deleted Items", "Junk Mail", "Archive"


def seed():
    d = lambda days=0, hours=0, minutes=0: NOW - timedelta(days=days, hours=hours, minutes=minutes)
    for key in USERS:
        ensure_folders(key, [("Archive", "archive", None)])
    ensure_folders("anna", [("Projekte", None, None), ("Gartenhaus", None, "Projekte"), ("Rechnungen", None, None),
                            ("Verein", None, None)])
    ensure_folders("ben", [("Werkstatt", None, None)])

    A, B, C = addr("anna"), addr("ben"), addr("clara")

    # T1 Grillfest – 4 Nachrichten, drei Teilnehmer, PDF-Anhang
    t1 = Msg("anna", [B, C], "Grillfest am Samstag",
             "Hallo ihr beiden,\n\nam Samstag ab 17 Uhr grillen wir bei mir im Garten. Die Einkaufsliste hängt an –"
             " tragt euch bitte ein, was ihr mitbringt.\n\nLiebe Grüße\nAnna", d(3, 6),
             attachments=[("Einkaufsliste.pdf", "application/pdf",
                           pdf(["Einkaufsliste Grillfest", "", "- Grillkohle (Anna)", "- Brot", "- Salat",
                                "- Getraenke", "- Nachtisch"]))])
    t1b = Msg("ben", [A], "Re: Grillfest am Samstag",
              "Bin dabei! Ich bringe Brot und Getränke mit.\n\nBen\n\n" + "Am Samstag schrieb Anna:\n" +
              quote("am Samstag ab 17 Uhr grillen wir bei mir im Garten."), d(3, 3), cc=[C], reply_to_msg=t1)
    t1c = Msg("clara", [A], "Re: Grillfest am Samstag",
              "Ich mache meinen Kartoffelsalat und bringe einen Nachtisch mit.\n\nBis Samstag!\nClara",
              d(2, 20), cc=[B], reply_to_msg=t1b)
    t1d = Msg("anna", [B, C], "Re: Grillfest am Samstag", "Super, dann haben wir alles. Bis Samstag!\n\nAnna",
              d(1, 22), reply_to_msg=t1c)
    for m, frm, rcpts, seen in [(t1, "anna", ["ben", "clara"], ["ben", "clara"]),
                               (t1b, "ben", ["anna", "clara"], ["anna", "clara"]),
                               (t1c, "clara", ["anna", "ben"], ["ben"]),
                               (t1d, "anna", ["ben", "clara"], [])]:
        put(frm, SENT, m, "\\Seen")
        for r in rcpts:
            put(r, INBOX, m, "\\Seen" if r in seen else "")

    # T2 Fotos – zwei Bilder, Antwort, orange markiert
    t2 = Msg("clara", [A], "Fotos vom Ausflug an den See",
             "Hallo Anna,\n\nhier die zwei schönsten Bilder vom Sonntag. Das Wetter war einfach perfekt!\n\nClara",
             d(5, 4), attachments=[("See-Morgen.png", "image/png", png(320, 220, (120, 170, 230), (20, 70, 120))),
                                   ("See-Abend.png", "image/png", png(320, 220, (250, 170, 110), (60, 40, 110)))])
    t2b = Msg("anna", [C], "Re: Fotos vom Ausflug an den See", "Wunderschön! Das zweite hänge ich mir auf.\n\nAnna",
              d(4, 21), reply_to_msg=t2)
    put("clara", SENT, t2, "\\Seen")
    put("anna", INBOX, t2, "\\Seen \\Flagged \\Answered $MailFlagBit0")
    put("anna", SENT, t2b, "\\Seen")
    put("clara", INBOX, t2b, "")

    # T3 Gartenhaus – im eigenen Unterordner bei Anna
    t3 = Msg("ben", [A], "Projekt Gartenhaus – Angebot",
             "Hallo Anna,\n\nanbei das Angebot der Zimmerei. Lieferung wäre in drei Wochen möglich.\n\nGruß\nBen",
             d(10, 2), attachments=[("Angebot-Gartenhaus.pdf", "application/pdf",
                                     pdf(["Angebot Gartenhaus 3 x 4 m", "", "Holz, Dach, Montage", "Summe: 4.380 EUR"]))])
    t3b = Msg("anna", [B], "Re: Projekt Gartenhaus – Angebot", "Danke! Passt das Fundament noch in den Preis?\n\nAnna",
              d(9, 5), reply_to_msg=t3)
    t3c = Msg("ben", [A], "Re: Projekt Gartenhaus – Angebot",
              "Das Fundament kommt extra, ungefähr 600 €. Ich frage noch nach.\n\nBen", d(8, 3), reply_to_msg=t3b)
    put("ben", SENT, t3, "\\Seen"); put("anna", "Projekte/Gartenhaus", t3, "\\Seen \\Answered")
    put("anna", SENT, t3b, "\\Seen"); put("ben", INBOX, t3b, "\\Seen")
    put("ben", SENT, t3c, "\\Seen"); put("anna", "Projekte/Gartenhaus", t3c, "")

    # T4 Rechnung (externer Absender) → Ordner Rechnungen
    t4 = Msg(None, [A], "Ihre Rechnung Oktober 2026",
             "Guten Tag Frau Berger,\n\nim Anhang finden Sie Ihre Rechnung für Oktober 2026.\n"
             "Der Betrag wird am 15.11. abgebucht.\n\nIhre Stadtwerke Musterstadt", d(12, 1),
             frm_raw="Stadtwerke Musterstadt <rechnung@stadtwerke.test>",
             attachments=[("Rechnung-2026-10.pdf", "application/pdf",
                           pdf(["Stadtwerke Musterstadt", "Rechnung Oktober 2026", "", "Strom: 61,20 EUR",
                                "Wasser: 23,10 EUR", "Summe: 84,30 EUR"]))])
    put("anna", "Rechnungen", t4, "\\Seen")

    # T5 Newsletter (HTML mit Fernbild → Banner „Bilder nicht geladen“)
    html = ("<html><body style='font-family:-apple-system,Helvetica'>"
            "<img src='https://example.org/banner-buecherei.png' width='560' alt='Bücherei am Markt'>"
            "<h2>Neu im November</h2><p>Liebe Leserinnen und Leser,</p>"
            "<p>ab sofort gibt es <b>40 neue Krimis</b> und unseren Lesekreis jeden Dienstag um 19 Uhr.</p>"
            "<ul><li>Lesung: „Herbstwind“ – Fr., 20. Nov.</li><li>Bastelnachmittag für Kinder – Sa., 21. Nov.</li></ul>"
            "<p><a href='https://example.org/programm'>Ganzes Programm ansehen</a></p></body></html>")
    t5 = Msg(None, [A], "Neu im November: Krimis, Lesekreis & Lesung",
             "Neu im November: 40 neue Krimis, Lesekreis dienstags 19 Uhr.", d(1, 3), html=html,
             frm_raw="Bücherei am Markt <newsletter@buecherei.test>",
             extra={"List-Unsubscribe": "<mailto:abmelden@buecherei.test>", "List-Id": "<news.buecherei.test>"})
    put("anna", INBOX, t5, "")

    # T6 Kurze Frage – unbeantwortet, rot markiert, ungelesen
    t6 = Msg("clara", [A], "Kurze Frage zum Buchclub",
             "Hi Anna,\n\nlesen wir im Dezember „Der Leuchtturm“ oder doch etwas Lustiges? Sag mir bis Freitag"
             " Bescheid.\n\nClara", d(0, 2))
    put("clara", SENT, t6, "\\Seen"); put("anna", INBOX, t6, "\\Flagged")

    # T7 Archiv
    t7 = Msg("ben", [A], "Termin Zahnarzt verschoben?",
             "Hast du den Termin am Mittwoch schon verschoben? Sonst fahre ich dich hin.\n\nBen", d(6, 1))
    put("ben", SENT, t7, "\\Seen"); put("anna", ARCHIVE, t7, "\\Seen")

    # T8 Spam, T9 Papierkorb, T10 Entwurf
    t8 = Msg(None, [A], "Sie haben gewonnen!!! Jetzt Preis abholen",
             "Herzlichen Glückwunsch! Klicken Sie hier, um Ihren Preis abzuholen.", d(2, 8),
             frm_raw="Gewinnspiel <gewinn@lotterie.test>")
    put("anna", JUNK, t8, "")
    t9 = Msg("clara", [A], "Alte Erinnerung: Bücher zurückgeben", "Denk an die Bücher!", d(20))
    put("anna", TRASH, t9, "\\Seen")
    t10 = Msg("anna", [B], "Urlaubsplanung 2027",
              "Hallo Ben,\n\nwas hältst du von zwei Wochen Schweden im Juni? Ich habe schon", d(0, 5))
    put("anna", DRAFTS, t10, "\\Seen \\Draft")

    # Weitere E-Mails für eine volle Liste
    fill = [
        ("Paketdienst Express <info@paket.test>", "Ihr Paket ist unterwegs",
         "Ihre Sendung 00340 4345 2210 wird morgen zwischen 10 und 14 Uhr zugestellt.", d(0, 7), "", INBOX),
        ("Gartenverein Sonnenhang <vorstand@gartenverein.test>", "Einladung zur Jahresversammlung",
         "Liebe Mitglieder,\n\ndie Jahresversammlung findet am 28. November um 18 Uhr im Vereinsheim statt.\n\n"
         "Der Vorstand", d(4, 2), "\\Seen", "Verein"),
        ("Wochenmarkt Musterstadt <hallo@wochenmarkt.test>", "Diese Woche frisch: Kürbisse & Äpfel",
         "Am Donnerstag gibt es frische Kürbisse, Äpfel und neuen Honig vom Imker.", d(2, 1), "\\Seen", INBOX),
        ("Fahrradladen Speiche <werkstatt@speiche.test>", "Ihr Rad ist fertig",
         "Ihr Fahrrad ist repariert und kann ab heute abgeholt werden. Öffnungszeiten: Mo–Fr 9–18 Uhr.", d(7, 4),
         "\\Seen \\Flagged $MailFlagBit2", INBOX),
    ]
    for frm_raw, subj, body, when, flags, box in fill:
        put("anna", box, Msg(None, [A], subj, body, when, frm_raw=frm_raw), flags)

    put("ben", "Werkstatt", Msg(None, [B], "Werkstatt-Termin bestätigt",
                                 "Ihr Termin am Montag um 8 Uhr ist bestätigt.", d(3, 2),
                                 frm_raw="Autohaus Nord <service@autohaus.test>"), "")

    # Live über SMTP: Ben → Anna (prüft Versandweg und Zustellung)
    mail, pw, _ = USERS["ben"]
    live = Msg("ben", [A], "Neue Werkzeugkiste für das Gartenhaus",
               "Hi Anna,\n\nich habe noch eine Werkzeugkiste übrig – soll ich sie am Samstag mitbringen?\n\nBen",
               NOW)
    s = smtplib.SMTP_SSL(HOST, 465, context=CTX, timeout=20)
    s.login(mail, pw)
    s.sendmail(mail, [USERS["anna"][0]], live.raw)
    s.quit()
    put("ben", SENT, live, "\\Seen")


if __name__ == "__main__":
    if "--reset" in sys.argv:
        for k in USERS:
            reset(k)
    seed()
    time.sleep(2)
    for k in USERS:
        acc, boxes = get_boxes(k)
        r = jmap(k, [["Mailbox/get", {"accountId": acc, "properties": ["name", "totalEmails", "unreadEmails"]}, "m"]])
        print(k, ", ".join(f"{b['name']}={b['totalEmails']}/{b['unreadEmails']}" for b in r[0][1]["list"]))
