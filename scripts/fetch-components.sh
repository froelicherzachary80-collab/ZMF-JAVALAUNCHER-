#!/usr/bin/env bash
# Downloads optional iOS runtime components into Native/Components so that
# embed-components.sh bundles them into the IPA.
#
# Inputs (space-separated lists; each entry is URL or URL#sha256=<hex>):
#   ZMF_RUNTIME_URLS   archives whose top-level folder is a Java home built for
#                      iOS arm64 (contains `release` and lib/server/libjvm.dylib)
#   ZMF_LWJGL_URLS     archives whose top-level folder is named after the LWJGL
#                      version (e.g. 3.3.3/) and contains liblwjgl.dylib etc.
#   ZMF_RENDERER_URLS  archives whose top-level folder contains renderer.json
#                      (see docs/RUNTIME.md) and the GL libraries it names
#
# Supported archive types: .zip, .tar.gz/.tgz, .tar.xz.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Native/Components"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fetch_into() {
  local kind="$1"; shift
  for spec in "$@"; do
    [ -n "$spec" ] || continue
    local url="${spec%%#*}" sum=""
    if [[ "$spec" == *"#sha256="* ]]; then sum="${spec##*#sha256=}"; fi
    local file="$WORK/$(basename "${url%%\?*}")"
    echo "fetch-components: $kind <- $url"
    curl -fL --retry 3 -o "$file" "$url"
    if [ -n "$sum" ]; then
      echo "$sum  $file" | shasum -a 256 -c -
    fi
    local out="$WORK/x-$kind-$RANDOM"
    mkdir -p "$out"
    case "$file" in
      *.zip) unzip -q "$file" -d "$out" ;;
      *.tar.gz|*.tgz) tar -xzf "$file" -C "$out" ;;
      *.tar.xz) tar -xJf "$file" -C "$out" ;;
      *) echo "Unsupported archive: $file" >&2; exit 1 ;;
    esac
    mkdir -p "$DEST/$kind"
    for top in "$out"/*; do
      cp -R "$top" "$DEST/$kind/"
      echo "fetch-components:   staged $kind/$(basename "$top")"
    done
  done
}

# shellcheck disable=SC2086
fetch_into runtimes ${ZMF_RUNTIME_URLS:-}
# shellcheck disable=SC2086
fetch_into lwjgl ${ZMF_LWJGL_URLS:-}
# shellcheck disable=SC2086
fetch_into renderers ${ZMF_RENDERER_URLS:-}

if [ -d "$DEST" ]; then
  echo "Staged components:"; find "$DEST" -maxdepth 2 -mindepth 2 | sed "s#$ROOT/##"
else
  echo "No runtime components requested (set ZMF_RUNTIME_URLS / ZMF_LWJGL_URLS / ZMF_RENDERER_URLS)."
fi
