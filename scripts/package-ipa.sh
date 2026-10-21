#!/usr/bin/env bash
# Wraps a built .app into an IPA (Payload/<App>.app zipped) after checking it
# holds a real arm64 iOS executable. Usage: package-ipa.sh <path/to/App.app> <out.ipa>
set -euo pipefail
APP="$1"
OUT="$2"
EXE="$APP/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP/Info.plist")"

echo "Executable: $EXE"
file "$EXE"
lipo -info "$EXE"
lipo -archs "$EXE" | grep -qw arm64 || { echo "error: executable is not arm64" >&2; exit 1; }
otool -l "$EXE" | grep -A4 LC_BUILD_VERSION | head -5
[ -d "$APP/Frameworks/ZMFGLFW.framework" ] || { echo "error: ZMFGLFW.framework not embedded" >&2; exit 1; }
nm -gU "$APP/Frameworks/ZMFGLFW.framework/ZMFGLFW" | grep -c ' _glfw' | xargs echo "Exported glfw symbols:"
[ -f "$APP/java/zmf-support.jar" ] || { echo "error: java/zmf-support.jar missing" >&2; exit 1; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
(cd "$STAGE" && zip -qry -X "out.ipa" Payload)
mv "$STAGE/out.ipa" "$OUT"
echo "Created $OUT ($(du -h "$OUT" | cut -f1))"
unzip -l "$OUT" | tail -1
