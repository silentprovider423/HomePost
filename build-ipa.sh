#!/bin/bash
# Baut eine unsignierte .ipa zum Sideloaden (AltStore/SideStore signieren sie mit deiner Apple-ID neu).
# Ergebnis: build-ipa/HomePost.ipa
set -euo pipefail
cd "$(dirname "$0")"
xcodegen generate -q
rm -rf build-ipa
xcodebuild -project HomePost.xcodeproj -scheme HomePost -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build-ipa \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  OTHER_SWIFT_FLAGS="-file-prefix-map $PWD=." OTHER_CFLAGS="-ffile-prefix-map=$PWD=." \
  STRIP_INSTALLED_PRODUCT=YES DEPLOYMENT_POSTPROCESSING=YES STRIP_STYLE=non-global -quiet build
APP="build-ipa/Build/Products/Release-iphoneos/HomePost.app"
[ -d "$APP" ] || { echo "FEHLER: $APP nicht gefunden"; exit 1; }
rm -rf Payload; mkdir Payload; cp -R "$APP" Payload/
codesign -f -s - "Payload/HomePost.app"
# Keine Spuren des Bau-Rechners veröffentlichen (Baupfade enthalten sonst den Mac-Benutzernamen)
if grep -raqiF -e "$USER" -e "$HOME" Payload; then
  echo "FEHLER: Benutzername oder Home-Pfad in der App – aus einem neutralen Ordner bauen (z. B. git clone nach /tmp/build)."
  rm -rf Payload; exit 1
fi
# Debug-Anmeldung über die Startumgebung darf in Release nicht enthalten sein
if grep -raqF "HOMEPOST_KONTO" Payload; then
  echo "FEHLER: Debug-Anmeldung in der Release-App gefunden."; rm -rf Payload; exit 1
fi
zip -qr build-ipa/HomePost.ipa Payload; rm -rf Payload
echo "Fertig: build-ipa/HomePost.ipa"
