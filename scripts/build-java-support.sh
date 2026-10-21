#!/usr/bin/env bash
# Compiles the launcher's Java-side support classes (Bootstrap, SelfTest) into
# App/Resources/java/zmf-support.jar. Targets Java 8 bytecode so the same jar
# runs on every embedded runtime (8, 17, 21).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/App/Resources/java"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

JAVAC="${JAVAC:-javac}"
JAR="${JAR:-jar}"
mkdir -p "$OUT" "$WORK/classes"
"$JAVAC" --release 8 -Xlint:-options -d "$WORK/classes" $(find "$ROOT/Java/src" -name '*.java')
"$JAR" --create --file "$OUT/zmf-support.jar" -C "$WORK/classes" .
echo "Built $OUT/zmf-support.jar"
"$JAR" --list --file "$OUT/zmf-support.jar"
