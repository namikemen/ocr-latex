#!/bin/bash
# Build OCRLaTeX and package it as a macOS .app bundle.
#   ./build_app.sh                    -> release build
#   ./build_app.sh debug              -> debug build
#   ./build_app.sh release universal  -> universal binary (arm64 + x86_64)
#   ./build_app.sh release run        -> build then launch
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
TARGET_MODE="${2:-}"
if [ "$CONFIG" = "run" ]; then CONFIG="release"; TARGET_MODE="run"; fi
APP="dist/OCR LaTeX.app"
BUNDLE_NAME="OCRLaTeX"

if [ "$TARGET_MODE" = "universal" ]; then
  echo "==> swift build -c $CONFIG (universal: arm64 + x86_64)"
  swift build -c "$CONFIG" --arch arm64 --arch x86_64 --product "$BUNDLE_NAME"
  BIN_DIR="$(swift build --show-bin-path -c "$CONFIG" --arch arm64 --arch x86_64)"
else
  echo "==> swift build -c $CONFIG"
  swift build -c "$CONFIG" --product "$BUNDLE_NAME"
  BIN_DIR="$(swift build --show-bin-path -c "$CONFIG")"
fi

BIN="$BIN_DIR/$BUNDLE_NAME"

if [ ! -x "$BIN" ]; then
  echo "error: binary not found at $BIN" >&2
  exit 1
fi

echo "==> packaging $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$BUNDLE_NAME"
cp Info.plist "$APP/Contents/Info.plist"

# Runtime resources (MathJax + HTML render template + icons)
cp Sources/OCRLaTeX/Resources/*.js   "$APP/Contents/Resources/"
cp Sources/OCRLaTeX/Resources/*.html "$APP/Contents/Resources/"
cp Sources/OCRLaTeX/Resources/*.icns "$APP/Contents/Resources/" 2>/dev/null || true
cp Sources/OCRLaTeX/Resources/*.png  "$APP/Contents/Resources/" 2>/dev/null || true

# Ad-hoc signature keeps TCC (screen recording) permission stable across launches.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "warning: codesign failed (app still runs unsigned)"

echo "==> done: $APP"
if [ "$TARGET_MODE" = "run" ] || [ "${1:-}" = "run" ]; then
  open "$APP"
fi
