# Setup guide: your own mail server for HomePost

HomePost is only the app. Your mail lives on your own **mail server**. Any server with IMAP + SMTP works; with **JMAP** (e.g. [Stalwart](https://stalw.art)) HomePost is faster and threads, search and sending are handled by the server. This guide sets up Stalwart with Docker.

## What you need

- An iPhone with **iOS 26 or newer**
- A computer that runs all the time (NAS, mini PC, home server) with **Docker**
- A domain if you want to send and receive mail on the internet. For a pure home/test setup a made-up domain such as `test.local` is enough (mail then only flows between your own accounts).

## 1. Start Stalwart

```bash
mkdir -p /srv/stalwart/{etc,data,logs}
chown -R 2000:2000 /srv/stalwart          # user id of the Stalwart image
docker run -d --name stalwart --restart unless-stopped \
  -e STALWART_RECOVERY_ADMIN=admin:<a-long-password> \
  -p 25:25 -p 143:143 -p 993:993 -p 587:587 -p 465:465 -p 443:443 -p 8080:8080 \
  -v /srv/stalwart/etc:/etc/stalwart \
  -v /srv/stalwart/data:/var/lib/stalwart \
  -v /srv/stalwart/logs:/var/log/stalwart \
  stalwartlabs/stalwart:latest
```

Both `/etc/stalwart` (the `config.json`) and `/var/lib/stalwart` (all mail) **must** be on persistent volumes, otherwise the server starts the setup wizard again after every container re-creation.

Port 25 is only needed to receive mail from the internet. Leave it out for a home-only setup.

## 2. Run the setup wizard

Open `http://<server-ip>:8080` and sign in with the recovery admin from above. Enter:

- **Hostname**: e.g. `mail.example.com` (home only: `mail.test.local`)
- **Domain**: e.g. `example.com` (home only: `test.local`)
- Request a TLS certificate: **yes** if the hostname is reachable from the internet (Let's Encrypt), otherwise no.

Restart the container afterwards (`docker restart stalwart`). Write down the permanent admin password the wizard shows, then remove `STALWART_RECOVERY_ADMIN` from the container (it is a full-access credential).

The same can be scripted: while in bootstrap mode, send `x:Bootstrap/set` to `http://<server>:8080/jmap/` (see the [Stalwart docs](https://stalw.art/docs/configuration/bootstrap-mode/)).

## 3. Create accounts

In the web admin: *Accounts → Create*, or via JMAP:

```bash
curl -u 'admin@example.com:<admin-password>' -H 'Content-Type: application/json' \
  http://<server>:8080/jmap/ -d '{
  "using": ["urn:ietf:params:jmap:core", "urn:stalwart:jmap"],
  "methodCalls": [["x:Account/set", {"create": {"a": {
    "@type": "User", "name": "anna", "domainId": "<domain id>", "description": "Anna",
    "credentials": {"0": {"@type": "Password", "secret": "<password>"}}}}}, "c1"]]}'
```

The domain id comes from `x:Domain/query`. Prefer **app passwords** per device so you can revoke the iPhone without changing your main password.

## 4. TLS – or a home-network test server

HomePost uses TLS by default (IMAP 993, SMTP 465, JMAP over HTTPS) and refuses invalid certificates. iOS does not trust self-signed certificates or a private home CA in third-party network code, so:

- **Recommended:** a real certificate (Let's Encrypt via Stalwart's ACME, or a reverse proxy) on a hostname the iPhone can resolve.
- **Test server at home only:** enable **"Unencrypted (home network only)"** when adding the account. HomePost then uses JMAP over `http://<server>:8080` or IMAP 143 / SMTP 587 without TLS. Stalwart only allows passwords on unencrypted ports after you enable it:
  - *Settings → Network → IMAP*: `allowPlainTextAuth = true`
  - *Settings → MTA → Session → AUTH Stage*: SASL mechanisms `[plain, login]` for `local_port != 25`
  - Stalwart 1.0 creates only the implicit-TLS listeners (993/465) by default; add plain `imap` (143) and `submission` (587) listeners and restart.

  Never do this on a server that is reachable from the internet.

## 5. Make the server reachable from the iPhone

| Where | Address in the app | Works away from home |
|---|---|---|
| Home Wi-Fi only | `192.168.x.y` (+ "Unencrypted" for a test server) | no |
| VPN (WireGuard, Tailscale) | the VPN address of the server | yes, with VPN on |
| Public with a certificate | `mail.example.com` | yes |

## 6. Add the account in HomePost

1. Open HomePost → **Add Account**.
2. Name, email address, password. Leave *Server* empty if the server is reachable under the domain of your address, otherwise enter host or URL.
3. HomePost tries JMAP first (`/.well-known/jmap`), then IMAP/SMTP on the standard ports. *Configure Manually* lets you pick protocol, host and ports yourself.

The password is stored only in the iPhone's keychain (this device only, never synced).

## 7. Demo mailboxes (optional)

`tools/seed-testmail.py` fills three **test** accounts with conversations, attachments, folders, flags, a draft, junk and trash – the data used for the screenshots:

```bash
export MAIL_HOST=<server-ip> MAIL_JMAP_URL=http://<server-ip>:8080 \
  MAIL_USER1=anna@test.local MAIL_PASSWORD1=… MAIL_USER2=ben@test.local MAIL_PASSWORD2=… \
  MAIL_USER3=clara@test.local MAIL_PASSWORD3=…
python3 -I tools/seed-testmail.py --reset   # --reset empties these three accounts first!
```

Only ever point it at test accounts.
