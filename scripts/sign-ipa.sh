#!/usr/bin/env bash
# Signs an unsigned ZMF IPA with a development/ad-hoc certificate and
# provisioning profile (used by CI when IOS_CERT_P12_BASE64, IOS_CERT_PASSWORD
# and IOS_PROFILE_BASE64 secrets exist). Sideloading services such as
# Signulous re-sign the unsigned IPA themselves and do not need this.
# Usage: sign-ipa.sh <in.ipa> <out.ipa>
set -euo pipefail
IN="$1"; OUT="$2"
WORK="$(mktemp -d)"
trap 'security delete-keychain "$WORK/sign.keychain-db" >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT

echo "$IOS_CERT_P12_BASE64" | base64 --decode > "$WORK/cert.p12"
echo "$IOS_PROFILE_BASE64" | base64 --decode > "$WORK/profile.mobileprovision"
security create-keychain -p zmf "$WORK/sign.keychain-db"
security set-keychain-settings "$WORK/sign.keychain-db"
security unlock-keychain -p zmf "$WORK/sign.keychain-db"
security import "$WORK/cert.p12" -k "$WORK/sign.keychain-db" -P "${IOS_CERT_PASSWORD:-}" -T /usr/bin/codesign
security list-keychains -d user -s "$WORK/sign.keychain-db" $(security list-keychains -d user | tr -d '"')
security set-key-partition-list -S apple-tool:,apple: -s -k zmf "$WORK/sign.keychain-db" >/dev/null
IDENTITY="$(security find-identity -v -p codesigning "$WORK/sign.keychain-db" | awk 'NR==1{print $2}')"

security cms -D -i "$WORK/profile.mobileprovision" > "$WORK/profile.plist"
/usr/libexec/PlistBuddy -x -c 'Print :Entitlements' "$WORK/profile.plist" > "$WORK/entitlements.plist"

unzip -q "$IN" -d "$WORK/x"
APP="$(ls -d "$WORK"/x/Payload/*.app)"
cp "$WORK/profile.mobileprovision" "$APP/embedded.mobileprovision"
# Inner code first: dylibs, frameworks, then the app.
find "$APP" -type f \( -name '*.dylib' -o -name '*.so' \) -exec codesign --force --sign "$IDENTITY" --timestamp=none {} \;
for fw in "$APP"/Frameworks/*.framework; do codesign --force --sign "$IDENTITY" --timestamp=none "$fw"; done
codesign --force --sign "$IDENTITY" --entitlements "$WORK/entitlements.plist" --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"
(cd "$WORK/x" && zip -qry "$WORK/out.ipa" Payload)
mv "$WORK/out.ipa" "$OUT"
echo "Signed $OUT with $IDENTITY"
