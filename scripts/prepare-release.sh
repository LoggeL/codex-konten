#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
source "$project_dir/config/release.env"
release_dir="${1:-$project_dir/dist/release}"
app_source="${2:-$project_dir/dist/Codex Konten.app}"
mkdir -p "$release_dir"
release_dir="$(cd "$release_dir" && pwd)"
app_source="$(cd "$(dirname "$app_source")" && pwd)/$(basename "$app_source")"
tools_dir="$project_dir/.build/artifacts/sparkle/Sparkle/bin"
[[ -x "$tools_dir/generate_appcast" ]] || { echo "Zuerst scripts/package-app.sh ausführen." >&2; exit 1; }
/usr/bin/python3 - "$app_source/Contents/Info.plist" "$APP_VERSION" "$APP_BUILD" "$SPARKLE_PUBLIC_KEY" "$UPDATE_FEED_URL" <<'PY'
import plistlib, sys
path, version, build, key, feed = sys.argv[1:]
with open(path, 'rb') as f: info = plistlib.load(f)
expected = dict(CFBundleIdentifier='de.logge.codex-konten', CFBundleShortVersionString=version,
                CFBundleVersion=build, SUPublicEDKey=key, SUFeedURL=feed)
for k, v in expected.items():
    if info.get(k) != v: raise SystemExit(f'Falscher Bundle-Wert: {k}')
if info.get('CodexAccountsDemoMode') or info.get('CodexAccountsHeadlessTestMode'):
    raise SystemExit('Demo-App darf nicht veröffentlicht werden.')
PY
codesign --verify --deep --strict "$app_source"
architectures="$(xcrun lipo "$app_source/Contents/MacOS/CodexAccounts" -archs)"
[[ " $architectures " == *" arm64 "* && " $architectures " == *" x86_64 "* ]]
archive="Codex-Konten-$APP_VERSION-universal.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app_source" "$release_dir/$archive"
if [[ -f "$project_dir/appcast.xml" ]]; then cp "$project_dir/appcast.xml" "$release_dir/appcast.xml"; fi
"$tools_dir/generate_appcast" --account "$SPARKLE_KEY_ACCOUNT" --maximum-deltas 0 \
  --versions "$APP_BUILD" --download-url-prefix "https://github.com/$RELEASE_REPOSITORY/releases/download/v$APP_VERSION/" \
  --link "https://github.com/$RELEASE_REPOSITORY/releases/latest" "$release_dir"
signature="$(/usr/bin/python3 - "$release_dir/appcast.xml" "$APP_BUILD" <<'PY'
import sys, xml.etree.ElementTree as E
root = E.parse(sys.argv[1]).getroot()
ns = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
for item in root.findall('./channel/item'):
    if item.findtext(ns+'version') == sys.argv[2]:
        print(item.find('enclosure').attrib[ns+'edSignature'])
        break
else: raise SystemExit('Neue Version fehlt im Feed')
PY
)"
"$tools_dir/sign_update" --account "$SPARKLE_KEY_ACCOUNT" --verify "$release_dir/$archive" "$signature"
(cd "$release_dir" && shasum -a 256 "$archive" > SHA256SUMS)
printf 'Signiertes Release vorbereitet: %s\n' "$release_dir"
printf 'Nach Upload des ZIPs appcast.xml aus diesem Verzeichnis ins Repository übernehmen.\n'
