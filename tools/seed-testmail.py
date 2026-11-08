#!/usr/bin/env python3
"""Erzeugt englische Demo-Postfächer für HomePost auf einem Test-Mailserver (nur Testkonten!).

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
    ensure_folders("anna", [("Projects", None, None), ("Garden Shed", None, "Projects"), ("Invoices", None, None),
                            ("Book Club", None, None)])
    ensure_folders("ben", [("Workshop", None, None)])

    A, B, C = addr("anna"), addr("ben"), addr("clara")

    # T1 Barbecue – 4 messages, three people, PDF attachment
    t1 = Msg("anna", [B, C], "Barbecue on Saturday",
             "Hi both,\n\nwe're having a barbecue in my garden on Saturday from 5 pm. The shopping list is attached –"
             " please add what you'll bring.\n\nCheers,\nAnna", d(3, 6),
             attachments=[("Shopping-List.pdf", "application/pdf",
                           pdf(["Barbecue shopping list", "", "- Charcoal (Anna)", "- Bread", "- Salad",
                                "- Drinks", "- Dessert"]))])
    t1b = Msg("ben", [A], "Re: Barbecue on Saturday",
              "Count me in! I'll bring bread and drinks.\n\nBen\n\n" + "On Saturday, Anna wrote:\n" +
              quote("we're having a barbecue in my garden on Saturday from 5 pm."), d(3, 3), cc=[C], reply_to_msg=t1)
    t1c = Msg("clara", [A], "Re: Barbecue on Saturday",
              "I'll make my potato salad and bring a dessert.\n\nSee you Saturday!\nClara",
              d(2, 20), cc=[B], reply_to_msg=t1b)
    t1d = Msg("anna", [B, C], "Re: Barbecue on Saturday", "Great, then we have everything. See you on Saturday!\n\nAnna",
              d(1, 22), reply_to_msg=t1c)
    for m, frm, rcpts, seen in [(t1, "anna", ["ben", "clara"], ["ben", "clara"]),
                               (t1b, "ben", ["anna", "clara"], ["anna", "clara"]),
                               (t1c, "clara", ["anna", "ben"], ["ben"]),
                               (t1d, "anna", ["ben", "clara"], [])]:
        put(frm, SENT, m, "\\Seen")
        for r in rcpts:
            put(r, INBOX, m, "\\Seen" if r in seen else "")

    # T2 Photos – two images, reply, flagged orange
    t2 = Msg("clara", [A], "Photos from our day at the lake",
             "Hi Anna,\n\nhere are the two best pictures from Sunday. The weather was just perfect!\n\nClara",
             d(5, 4), attachments=[("Lake-Morning.png", "image/png", png(320, 220, (120, 170, 230), (20, 70, 120))),
                                   ("Lake-Evening.png", "image/png", png(320, 220, (250, 170, 110), (60, 40, 110)))])
    t2b = Msg("anna", [C], "Re: Photos from our day at the lake", "Beautiful! I'm going to frame the second one.\n\nAnna",
              d(4, 21), reply_to_msg=t2)
    put("clara", SENT, t2, "\\Seen")
    put("anna", INBOX, t2, "\\Seen \\Flagged \\Answered $MailFlagBit0")
    put("anna", SENT, t2b, "\\Seen")
    put("clara", INBOX, t2b, "")

    # T3 Garden shed – in a subfolder for Anna
    t3 = Msg("ben", [A], "Garden shed project – quote",
             "Hi Anna,\n\nattached is the quote from the carpenter. Delivery would be possible in three weeks.\n\nBen",
             d(10, 2), attachments=[("Quote-Garden-Shed.pdf", "application/pdf",
                                     pdf(["Quote: garden shed 3 x 4 m", "", "Timber, roof, assembly", "Total: EUR 4,380"]))])
    t3b = Msg("anna", [B], "Re: Garden shed project – quote", "Thanks! Is the foundation included in the price?\n\nAnna",
              d(9, 5), reply_to_msg=t3)
    t3c = Msg("ben", [A], "Re: Garden shed project – quote",
              "The foundation is extra, roughly EUR 600. I'll double-check.\n\nBen", d(8, 3), reply_to_msg=t3b)
    put("ben", SENT, t3, "\\Seen"); put("anna", "Projects/Garden Shed", t3, "\\Seen \\Answered")
    put("anna", SENT, t3b, "\\Seen"); put("ben", INBOX, t3b, "\\Seen")
    put("ben", SENT, t3c, "\\Seen"); put("anna", "Projects/Garden Shed", t3c, "")

    # T4 Invoice (external sender) → Invoices
    t4 = Msg(None, [A], "Your invoice for October 2026",
             "Dear Ms Berger,\n\nplease find attached your invoice for October 2026.\n"
             "The amount will be debited on 15 November.\n\nCity Utilities", d(12, 1),
             frm_raw="City Utilities <billing@utilities.test>",
             attachments=[("Invoice-2026-10.pdf", "application/pdf",
                           pdf(["City Utilities", "Invoice October 2026", "", "Electricity: EUR 61.20",
                                "Water: EUR 23.10", "Total: EUR 84.30"]))])
    put("anna", "Invoices", t4, "\\Seen")

    # T5 Newsletter (HTML with remote image → "images not loaded" banner)
    html = ("<html><body style='font-family:-apple-system,Helvetica'>"
            "<img src='https://example.org/library-banner.png' width='560' alt='Market Street Library'>"
            "<h2>New in November</h2><p>Dear readers,</p>"
            "<p>we have <b>40 new crime novels</b> and our reading circle meets every Tuesday at 7 pm.</p>"
            "<ul><li>Author reading: “Autumn Wind” – Fri, 20 Nov</li><li>Craft afternoon for kids – Sat, 21 Nov</li></ul>"
            "<p><a href='https://example.org/programme'>See the full programme</a></p></body></html>")
    t5 = Msg(None, [A], "New in November: crime novels, reading circle & author talk",
             "New in November: 40 new crime novels, reading circle on Tuesdays at 7 pm.", d(1, 3), html=html,
             frm_raw="Market Street Library <news@library.test>",
             extra={"List-Unsubscribe": "<mailto:unsubscribe@library.test>", "List-Id": "<news.library.test>"})
    put("anna", INBOX, t5, "")

    # T6 Quick question – unanswered, flagged red, unread
    t6 = Msg("clara", [A], "Quick question about book club",
             "Hi Anna,\n\nare we reading “The Lighthouse” in December or something funnier? Let me know by Friday."
             "\n\nClara", d(0, 2))
    put("clara", SENT, t6, "\\Seen"); put("anna", INBOX, t6, "\\Flagged")

    # T7 Archive
    t7 = Msg("ben", [A], "Dentist appointment moved?",
             "Did you already move the appointment on Wednesday? Otherwise I'll drive you there.\n\nBen", d(6, 1))
    put("ben", SENT, t7, "\\Seen"); put("anna", ARCHIVE, t7, "\\Seen")

    # T8 junk, T9 trash, T10 draft
    t8 = Msg(None, [A], "You have won!!! Claim your prize now",
             "Congratulations! Click here to claim your prize.", d(2, 8), frm_raw="Prize Draw <win@lottery.test>")
    put("anna", JUNK, t8, "")
    t9 = Msg("clara", [A], "Old reminder: return the books", "Don't forget the library books!", d(20))
    put("anna", TRASH, t9, "\\Seen")
    t10 = Msg("anna", [B], "Holiday plans 2027",
              "Hi Ben,\n\nwhat do you think about two weeks in Sweden in June? I've already", d(0, 5))
    put("anna", DRAFTS, t10, "\\Seen \\Draft")

    # More mail for a full list
    fill = [
        ("Express Parcels <info@parcels.test>", "Your parcel is on its way",
         "Your parcel 00340 4345 2210 will be delivered tomorrow between 10 am and 2 pm.", d(0, 7), "", INBOX),
        ("Sunny Hill Garden Club <board@gardenclub.test>", "Invitation to the annual meeting",
         "Dear members,\n\nthe annual meeting takes place on 28 November at 6 pm in the clubhouse.\n\nThe board",
         d(4, 2), "\\Seen", "Book Club"),
        ("Farmers Market <hello@market.test>", "Fresh this week: pumpkins & apples",
         "On Thursday we have fresh pumpkins, apples and new honey from the beekeeper.", d(2, 1), "\\Seen", INBOX),
        ("Spoke Bike Shop <workshop@spoke.test>", "Your bike is ready",
         "Your bike has been repaired and can be picked up from today. Opening hours: Mon–Fri 9 am – 6 pm.", d(7, 4),
         "\\Seen \\Flagged $MailFlagBit2", INBOX),
    ]
    for frm_raw, subj, body, when, flags, box in fill:
        put("anna", box, Msg(None, [A], subj, body, when, frm_raw=frm_raw), flags)

    put("ben", "Workshop", Msg(None, [B], "Service appointment confirmed",
                               "Your appointment on Monday at 8 am is confirmed.", d(3, 2),
                               frm_raw="North Garage <service@garage.test>"), "")

    # Live via SMTP: Ben → Anna (checks submission and delivery)
    mail, pw, _ = USERS["ben"]
    live = Msg("ben", [A], "Spare toolbox for the garden shed",
               "Hi Anna,\n\nI have a spare toolbox – shall I bring it on Saturday?\n\nBen", NOW)
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
