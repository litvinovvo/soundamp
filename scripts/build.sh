#!/usr/bin/env bash
# Builds SoundAmp with SwiftPM and wraps it into a signed .app bundle.
# A real bundle is required: the audio-capture permission (TCC) is tied to
# the bundle's Info.plist (NSAudioCaptureUsageDescription) and signature.
#
# Usage: scripts/build.sh [debug|release]   (default: release)
# Set CODESIGN_IDENTITY to use a certificate from Keychain.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
[[ -s Skins/base-2.91.wsz && -s Media/llama-intro.mp3 ]] || scripts/fetch-skins.sh
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="${APP:-build/SoundAmp.app}"   # override to build a separate copy (smoke tests)
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/SoundAmp" "$APP/Contents/MacOS/SoundAmp"
cp Support/Info.plist "$APP/Contents/Info.plist"
[[ -s Support/AppIcon.icns ]] || scripts/make-icon.sh
cp Support/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
mkdir -p "$APP/Contents/Resources/Skins"
cp Skins/*.wsz "$APP/Contents/Resources/Skins/"
if [[ -s Media/llama-intro.mp3 ]]; then cp Media/llama-intro.mp3 "$APP/Contents/Resources/llama-intro.mp3"; fi

# Ad-hoc signing remains the default for local development.
codesign --force --sign "${CODESIGN_IDENTITY:--}" --timestamp=none "$APP"

echo "Built $APP"
echo "Run:  open $APP            (log: ~/Library/Logs/SoundAmp.log)"
