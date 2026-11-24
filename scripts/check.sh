#!/usr/bin/env bash
# Quick checks to run after changes — silent and invisible (~10 s):
#   1. unit tests (swift test)
#   2. the real app in --headless mode (no windows, no Dock icon, volume 0) against
#      real SoundCloud, three phases in parallel, each quitting as soon as it's done:
#        paste    links copied the usual ways → expected playlist, playback, bitrate
#        advance  start 5 s before the end of a short track → the next one starts
#        intro    first launch: the llama intro plays to the end; Classified skin renders
#        skin     a pasted/dropped Winamp Skin Museum link downloads, installs, selects
#        slowed   "Slowed + Reverb": SoundCloud's own player runs at 0.85× (varispeed)
# Safe while you're using SoundAmp: separate app copy, in-memory settings, own data + logs.
# For the one run with visible UI and sound, see scripts/smoke.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
start=$(date +%s)

echo "Unit tests…"
if ! out="$(swift test 2>&1)"; then echo "$out" | grep -E "error|failed" | head -20; exit 1; fi
echo "  ✅ $(echo "$out" | grep -E "Executed .* tests" | tail -1 | sed 's/^[[:space:]]*//')"

APP=build/SoundAmp-check.app
APP="$APP" scripts/build.sh >/dev/null
TMP="$(mktemp -d)"

phase() { # name, timeout seconds, paste text ("" = none), extra args…  (DATA=<name> shares a data dir)
  local name="$1" secs="$2" paste="$3"; shift 3
  local data="$TMP/data-${DATA:-$name}"
  local args=(--headless --data-dir "$data" --no-tap --quit-after "$secs" --snapshot "$TMP/snap-$name" "$@")
  [[ -n "$paste" ]] && args+=(--paste "$paste")
  mkdir -p "$data"
  open -n -g -W --env SOUNDAMP_LOG="$TMP/$name.log" "$APP" --args "${args[@]}"
}

echo "Headless app checks…"
phase paste 30 $'Hey listen: https://soundcloud.com/forss/flickermood?si=8f2a1c0b&utm_source=clipboard&utm_medium=text\nhttps://soundcloud.com/forss/sets/soulhack?si=x\n<iframe src="https://w.soundcloud.com/player/?url=https%3A//api.soundcloud.com/tracks/294&amp;auto_play=false"></iframe><div><a href="https://soundcloud.com/forss">Forss</a> · <a href="https://soundcloud.com/forss/using-splashes">Using Splashes</a></div>' \
  --no-intro --quit-when settled &
# "Lost Through Inversion" is 0:40 → start at 0:35; then "Characteristics".
phase advance 30 $'https://api.soundcloud.com/tracks/298\nhttps://api.soundcloud.com/tracks/297' \
  --no-intro --start-at 35 --quit-when finished &
# intro also runs through the local effects chain: slowed (0.85×) + plate reverb
phase intro 15 "" --skin Winamp5_Classified_v5.5 --effects "Slowed + Reverb" --quit-when finished &
# keep-pitch through the Signalsmith chain (local intro: varispeed + compensating shift)
phase keeppitch 15 "" --effects "Slowed, Same Pitch" --quit-when finished &
# EQ "ON" off bypasses the whole chain: "Slowed + Reverb" set, yet the intro plays at 1×
phase bypass 15 "" --effects "Slowed + Reverb" --eq-off --quit-when finished &
# the Effects panel's controls really change the effect settings
phase fxpanel 10 "" --no-intro --fx-selftest --quit-after 1 &
# slowed + reverb on SoundCloud: speed is applied inside SoundCloud's own player
phase slowed 25 "https://soundcloud.com/forss/flickermood" --no-intro --effects "Slowed + Reverb" --quit-when rate &
# dropping/pasting a Winamp Skin Museum link downloads + installs the skin
# …and it's still there and selected after quitting and relaunching.
(
  DATA=skin phase skin 20 "https://skins.webamp.org/skin/b0fb83cc20af3abe264291bb17fb2a13/Winamp5_Classified_v5.5.wsz" \
    --no-intro --quit-when skin
  DATA=skin phase relaunch 5 "" --no-intro --quit-after 2
) &
wait

fail=0
check() { # log name, description, grep pattern
  if grep -qE "$3" "$TMP/$1.log"; then echo "  ✅ $2"; else echo "  ❌ $2 ($TMP/$1.log)"; fail=1; fi
}
check paste "paste: found 3 links (track, playlist, embed; attribution ignored)" "Adding 3 link\(s\)"
check paste "paste: tracking params stripped" "Adding 3 link\(s\): https://soundcloud.com/forss/flickermood,"
check paste "paste: playlist expanded to 11 tracks" "soulhack → 11 sound"
check paste "paste: embed code resolved to track 294" "tracks/294 → 1 sound"
check paste "paste: playlist complete (13 entries, metadata)" "   13\. Forss - Using Splashes"
check paste "paste: playback started" "state=playing"
check paste "paste: stream bitrate detected" "Stream: [a-z0-9_]+ → [0-9]+ kbps"
check paste "paste: windows render" "snapshot: .*playlist-"
check advance "advance: first track finished" "■ Finished Forss - Lost Through Inversion"
check advance "advance: next track loaded automatically" "Loading 2\. Forss - Characteristics"
check intro "intro: plays on first launch, to the end" "■ Finished DJ Mike Llama"
check intro "intro: Classified skin renders" "snapshot: .*main-Winamp5_Classified_v5.5"
check intro "intro: slowed (0.85×) through the local chain" "Local playback: 5\.[0-9]+ s of audio in 6\.[0-9]+ s of output → speed 0\.8[4-6]×"
check keeppitch "keep pitch: intro at 0.85× (pitch restored by Signalsmith, unit-tested) plays to the end" "Local playback: .* → speed 0\.8[4-6]×"
check bypass "EQ ON off bypasses the chain (intro at 1.00× despite a slowed preset)" "Local playback: .* → speed 1\.00×"
check fxpanel "effects panel: sliders/switch change speed, pitch, reverb, mix" "FX self-test: speed 0.70, pitch \+3.0, reverb on, mix 0.50"
check fxpanel "effects panel renders" "snapshot: .*effects-panel.png"
check slowed "slowed: SoundCloud's <audio> set to 0.85×, pitch follows (varispeed)" "Media rate 0.85 \(keepPitch false, elements 1\)"
check slowed "slowed: measured playback speed ≈ 0.85×" "Measured playback rate 0\.8[2-8]"
check skin "skin link: downloaded and installed" "Installed skin Winamp5_Classified_v5.5.wsz"
check skin "skin link: selected" "Skin: Winamp5_Classified_v5.5"
check relaunch "skin link: still installed and selected after relaunch" "Skin: Winamp5_Classified_v5.5 \(installed: .*/data-skin/Skins/Winamp5_Classified_v5.5.wsz\)"

echo "Took $(( $(date +%s) - start )) s."
exit $fail
