#!/bin/bash
# Baut die App und startet sie im eigenen Simulator, angemeldet über die Startumgebung (nur Debug, kein Passwort-Tippen).
# Zugänge aus einer Datei außerhalb des Repos:
#   TEST_ENV=~/.config/rea-apps/test-accounts.env SIM_UDID=<udid> ./sim-run.sh [eingang|ordner:<Name>]
# Konto 1 per JMAP (MAIL_JMAP_URL), Konto 2 per IMAP/SMTP unverschlüsselt (Testserver im Heimnetz).
set -euo pipefail
cd "$(dirname "$0")"
set -a; source "${TEST_ENV:-$HOME/.config/rea-apps/test-accounts.env}"; set +a
UDID="${SIM_UDID:-$(cat .sim-udid)}"
xcodegen generate -q
xcodebuild -project HomePost.xcodeproj -scheme HomePost -destination "id=$UDID" -derivedDataPath build -quiet build 2>&1 \
  | grep -E "error:" || true
APP=build/Build/Products/Debug-iphonesimulator/HomePost.app
test -d "$APP"
xcrun simctl install "$UDID" "$APP"
SIMCTL_CHILD_HOMEPOST_KONTO1="jmap;$MAIL_JMAP_URL;$MAIL_USER1;$MAIL_PASSWORD1;Anna Berger" \
SIMCTL_CHILD_HOMEPOST_KONTO2="imap;$MAIL_HOST;$MAIL_USER2;$MAIL_PASSWORD2;Ben Okafor;unverschluesselt" \
SIMCTL_CHILD_HOMEPOST_START="${1:-}" \
  xcrun simctl launch --terminate-running-process "$UDID" org.homeroll.homepost >/dev/null
echo "gestartet"
