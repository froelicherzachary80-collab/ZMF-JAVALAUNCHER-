#!/usr/bin/env bash
# Xcode build phase: copies optional native components staged in
# Native/Components/{runtimes,renderers,lwjgl} into the .app bundle.
#
# Every Mach-O file is checked to be an arm64 binary built for iOS
# (LC_BUILD_VERSION platform 2, or 7 for the simulator); macOS or Linux builds
# would only fail later at dlopen() on the device, so they fail the build here.
# When the build is code-signed, each embedded Mach-O is signed with the same
# identity as the app.
set -euo pipefail

SRC="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}/Native/Components"
APP="${TARGET_BUILD_DIR:?}/${WRAPPER_NAME:?}"

if [ ! -d "$SRC" ]; then
  echo "embed-components: no Native/Components directory — building without Java runtime, LWJGL natives or GL layers."
  exit 0
fi

expected_platform=2
if [ "${PLATFORM_NAME:-iphoneos}" = "iphonesimulator" ]; then expected_platform=7; fi

check_macho() {
  local f="$1"
  if ! file "$f" | grep -q "Mach-O"; then return 0; fi
  if ! lipo -archs "$f" 2>/dev/null | grep -qw arm64; then
    echo "error: $f is not an arm64 Mach-O" >&2; return 1
  fi
  local platform
  platform="$(otool -l "$f" | awk '/LC_BUILD_VERSION/{found=1} found && /platform/{print $2; exit}')"
  if [ -z "$platform" ]; then
    # Older binaries use LC_VERSION_MIN_IPHONEOS instead.
    if otool -l "$f" | grep -q LC_VERSION_MIN_IPHONEOS; then return 0; fi
    echo "error: $f has no iOS build version load command" >&2; return 1
  fi
  if [ "$platform" != "$expected_platform" ]; then
    echo "error: $f is built for platform $platform, expected $expected_platform (iOS)" >&2; return 1
  fi
}

for kind in runtimes renderers lwjgl; do
  [ -d "$SRC/$kind" ] || continue
  for item in "$SRC/$kind"/*; do
    [ -e "$item" ] || continue
    name="$(basename "$item")"
    echo "embed-components: $kind/$name"
    mkdir -p "$APP/$kind"
    rm -rf "$APP/$kind/$name"
    cp -R "$item" "$APP/$kind/$name"
  done
done

status=0
while IFS= read -r -d '' f; do
  check_macho "$f" || status=1
  if [ "$status" = 0 ] && [ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ] && [ "${CODE_SIGNING_ALLOWED:-YES}" = "YES" ] && file "$f" | grep -q "Mach-O"; then
    codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp=none "$f"
  fi
done < <(find "$APP/runtimes" "$APP/renderers" "$APP/lwjgl" -type f \( -name '*.dylib' -o -name '*.so' -o -perm -u+x \) -print0 2>/dev/null)
exit $status
