#!/usr/bin/env bash
# The final smoke test — the one run with visible UI and sound. Use it before
# handing over a build; for everyday checks use scripts/check.sh (silent, headless).
#
# Launches a separate copy of the app with fresh settings/data (your SoundAmp and
# playlist are untouched): the llama intro plays on "first launch", a SoundCloud
# link is pasted meanwhile, and when the intro ends the SoundCloud track takes over —
# all with the "Slowed + Reverb" preset (intro: full chain; SoundCloud: slowed at the source).
# Quits once that track streams; prints what happened and where the snapshots are.
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/SoundAmp-smoke.app
APP="$APP" scripts/build.sh >/dev/null
TMP="$(mktemp -d)"
LOG="$TMP/smoke.log"
start=$(date +%s)
mkdir -p "$TMP/data"
open -n -W --env SOUNDAMP_LOG="$LOG" "$APP" --args --data-dir "$TMP/data" --no-tap --volume 35 --effects "Slowed + Reverb" \
  --paste "https://soundcloud.com/forss/flickermood?si=x" --quit-when handover --quit-after 30 --snapshot "$TMP/snapshots"

fail=0
check() { if grep -qE "$2" "$LOG"; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }
check "intro played"                               "■ Finished DJ Mike Llama"
check "SoundCloud track took over after the intro" "Loading 2\. .*Flickermood"
check "it streams (bitrate detected)"              "Stream: [a-z0-9_]+ → [0-9]+ kbps"
check "windows rendered"                           "snapshot: .*main-"
echo "Took $(( $(date +%s) - start )) s. Log + snapshots: $TMP"
exit $fail
