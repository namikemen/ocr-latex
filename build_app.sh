#!/bin/bash
# Build OCRLaTeX and package it as a macOS .app bundle.
#   ./build_app.sh            -> release build
#   ./build_app.sh debug      -> debug build
#   ./build_app.sh release run -> build then launch
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
if [ "$CONFIG" = "run" ]; then CONFIG="release"; fi
APP="dist/OCR LaTeX.app"
BUNDLE_NAME="OCRLaTeX"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG" --product "$BUNDLE_NAME"

BIN=".build/$CONFIG/$BUNDLE_NAME"
if [ ! -x "$BIN" ]; then
  echo "error: binary not found at $BIN" >&2
  exit 1
fi

echo "==> packaging $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$BUNDLE_NAME"
cp Info.plist "$APP/Contents/Info.plist"

# Runtime resources (MathJax + HTML render template)
cp Sources/OCRLaTeX/Resources/*.js   "$APP/Contents/Resources/"
cp Sources/OCRLaTeX/Resources/*.html "$APP/Contents/Resources/"

# Ad-hoc signature keeps TCC (screen recording) permission stable across launches.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "warning: codesign failed (app still runs unsigned)"

echo "==> done: $APP"
if [ "${2:-}" = "run" ] || [ "${1:-}" = "run" ]; then
  open "$APP"
fi
