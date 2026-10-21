#!/usr/bin/env bash
# Compiles the Java support code plus test fixtures and runs the telemetry tests.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
javac --release 8 -Xlint:-options -d "$WORK" $(find "$ROOT/Java/src" "$ROOT/Java/test" -name '*.java')
java -cp "$WORK" dev.zmf.support.telemetry.TelemetryTest "$ROOT/Java/test/resources"
