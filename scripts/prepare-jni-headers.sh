#!/usr/bin/env bash
# Copies the standard JNI headers (jni.h, jni_md.h) from a host JDK into
# Native/Generated/jni so the JVM bridge compiles. The JNI interface is
# identical across platforms; jni_md.h from the macOS (darwin) JDK matches
# iOS arm64's LP64 ABI.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Native/Generated/jni"
JDK="${JAVA_HOME:-$(/usr/libexec/java_home 2>/dev/null || dirname "$(dirname "$(readlink -f "$(command -v javac)")")")}"
mkdir -p "$DEST"
cp "$JDK/include/jni.h" "$DEST/jni.h"
if [ -f "$JDK/include/darwin/jni_md.h" ]; then
  cp "$JDK/include/darwin/jni_md.h" "$DEST/jni_md.h"
else
  cp "$JDK/include/linux/jni_md.h" "$DEST/jni_md.h"
fi
echo "JNI headers copied from $JDK"
