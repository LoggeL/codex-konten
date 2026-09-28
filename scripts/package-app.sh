#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
source "$project_dir/config/release.env"
output_dir="${1:-$project_dir/dist}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
app_dir="$output_dir/Codex Konten.app"
cd "$project_dir"

xcrun swift build -c release --triple arm64-apple-macosx14.0
arm_dir="$(xcrun swift build -c release --triple arm64-apple-macosx14.0 --show-bin-path)"
xcrun swift build -c release --triple x86_64-apple-macosx14.0 --scratch-path .build-x86_64
intel_dir="$(xcrun swift build -c release --triple x86_64-apple-macosx14.0 --scratch-path .build-x86_64 --show-bin-path)"
framework="$project_dir/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[[ -d "$framework" ]] || { echo "Sparkle.framework fehlt." >&2; exit 1; }

# Stage a new bundle so a failed build never damages an existing package.
staging_dir="$(mktemp -d "$output_dir/.package.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
staged_app="$staging_dir/Codex Konten.app"
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Frameworks" "$staged_app/Contents/Resources"
xcrun lipo -create "$arm_dir/CodexAccounts" "$intel_dir/CodexAccounts" -output "$staged_app/Contents/MacOS/CodexAccounts"
xcrun strip -S "$staged_app/Contents/MacOS/CodexAccounts"
/usr/bin/ditto "$framework" "$staged_app/Contents/Frameworks/Sparkle.framework"
cp LICENSE "$staged_app/Contents/Resources/LICENSE.txt"
cp .build/artifacts/sparkle/Sparkle/LICENSE "$staged_app/Contents/Resources/Sparkle-LICENSE.txt"
/usr/bin/python3 - "$staged_app/Contents/Info.plist" "$APP_VERSION" "$APP_BUILD" "$SPARKLE_PUBLIC_KEY" "$UPDATE_FEED_URL" <<'PY'
import plistlib, sys
target, version, build, public_key, feed = sys.argv[1:]
with open(target, 'wb') as f:
    plistlib.dump({
        'CFBundleName': 'Codex Konten', 'CFBundleDisplayName': 'Codex Konten',
        'CFBundleIdentifier': 'de.logge.codex-konten', 'CFBundleExecutable': 'CodexAccounts',
        'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': version,
        'CFBundleVersion': build, 'LSMinimumSystemVersion': '14.0', 'LSUIElement': True,
        'NSHighResolutionCapable': True, 'LSMultipleInstancesProhibited': True,
        'CFBundleDevelopmentRegion': 'de', 'CFBundleLocalizations': ['de', 'en'],
        'SUFeedURL': feed, 'SUPublicEDKey': public_key,
        'SUEnableAutomaticChecks': False, 'SUAllowsAutomaticUpdates': False,
        'SUAutomaticallyUpdate': False, 'SUSendProfileInfo': False,
    }, f)
PY
embedded="$staged_app/Contents/Frameworks/Sparkle.framework/Versions/B"
for service in "$embedded"/XPCServices/*.xpc; do
    codesign --force --sign - "$service"
done
codesign --force --sign - "$embedded/Autoupdate"
codesign --force --sign - "$embedded/Updater.app"
codesign --force --sign - "$staged_app/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - "$staged_app"
plutil -lint "$staged_app/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$staged_app"
architectures="$(xcrun lipo "$staged_app/Contents/MacOS/CodexAccounts" -archs)"
[[ " $architectures " == *" arm64 "* && " $architectures " == *" x86_64 "* ]]
# Only replace the app owned by this packaging script, after successful checks.
if [[ -e "$app_dir" ]]; then
    identifier="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app_dir/Contents/Info.plist")"
    [[ "$identifier" == "de.logge.codex-konten" ]] || { echo "Unbekanntes App-Bundle am Ziel." >&2; exit 1; }
    mv "$app_dir" "$staging_dir/previous.app"
fi
mv "$staged_app" "$app_dir"
printf 'App erstellt: %s (%s, Build %s, Universal)\n' "$app_dir" "$APP_VERSION" "$APP_BUILD"
