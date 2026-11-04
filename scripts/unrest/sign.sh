#!/bin/bash
set -euo pipefail
umask 077
cd "$RUNNER_TEMP/launcher"
private=$(mktemp -d "$RUNNER_TEMP/unrest-sign.XXXXXXXX")
kc="$private/signing.keychain-db"
trap 'security delete-keychain "$kc" 2>/dev/null || true; rm -rf -- "$private"' EXIT
printf %s "${P12_B64:?}" | base64 -D > "$private/signing.p12"
printf %s "${ASC_KEY_B64:?}" | base64 -D > "$private/notary.p8"
pw=$(openssl rand -hex 32)
security create-keychain -p "$pw" "$kc"
security set-keychain-settings -lut 3600 "$kc"
security unlock-keychain -p "$pw" "$kc"
security import "$private/signing.p12" -k "$kc" -P "${P12_PASSWORD:?}" -T /usr/bin/codesign >/dev/null
unset P12_B64 P12_PASSWORD ASC_KEY_B64
security set-key-partition-list -S apple-tool:,apple: -s -k "$pw" "$kc" >/dev/null
security list-keychains -d user -s "$kc" "$HOME/Library/Keychains/login.keychain-db"
app='unpacked/Unrest Founder Chat.app'
identity='Developer ID Application: Trygentic, Inc. (R782S8JA76)'
/usr/bin/python3 -I -B sign_runtime.py "$app/Contents/Resources/history-runtime" "$identity" 2>"$private/native.log" || { echo 'Runtime signing failed'; exit 1; }
codesign --force --options runtime --timestamp --keychain "$kc" --sign "$identity" "$app"
codesign --verify --deep --strict "$app"
ditto -c -k --keepParent "$app" "$private/submission.zip"
xcrun notarytool submit "$private/submission.zip" --key "$private/notary.p8" \
  --key-id "${ASC_KEY_ID:?}" --issuer "${ASC_ISSUER:?}" --wait --timeout 40m --output-format json > "$private/result.json"
jq -er '.status' "$private/result.json"
jq -e '.status == "Accepted"' "$private/result.json" >/dev/null
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute "$app"
ditto -c -k --keepParent "$app" Unrest-Founder-Chat-arm64.zip
shasum -a 256 Unrest-Founder-Chat-arm64.zip > SHA256SUMS
