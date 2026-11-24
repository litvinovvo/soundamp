#!/usr/bin/env bash
# Downloads the bundled classic skins into Skins/ and the default intro audio
# into Media/ (both git-ignored).
#   - Skins: the Webamp demo set (github.com/captbaritone/webamp) and picks from
#     the Winamp Skin Museum (skins.webamp.org).
#   - Media/llama-intro.mp3: the classic "DJ Mike Llama" Winamp intro, as shipped
#     in Webamp's demo.
# base-2.91.wsz and the intro are Nullsoft/Winamp works; the others are community
# skins. Fine for personal use — check licensing before redistributing a build.
set -euo pipefail
cd "$(dirname "$0")/.."

WEBAMP="https://raw.githubusercontent.com/captbaritone/webamp/master/packages/webamp-demo"
MUSEUM="https://r2.webampskins.org/skins"

# name | url | optional md5
ASSETS=(
  "Skins/base-2.91.wsz|$WEBAMP/skins/base-2.91.wsz|"
  "Skins/Green-Dimension-V2.wsz|$WEBAMP/skins/Green-Dimension-V2.wsz|"
  "Skins/MacOSXAqua1-5.wsz|$WEBAMP/skins/MacOSXAqua1-5.wsz|"
  "Skins/TopazAmp1-2.wsz|$WEBAMP/skins/TopazAmp1-2.wsz|"
  "Skins/Vizor1-01.wsz|$WEBAMP/skins/Vizor1-01.wsz|"
  "Skins/XMMS-Turquoise.wsz|$WEBAMP/skins/XMMS-Turquoise.wsz|"
  "Skins/Internet-Archive.wsz|$WEBAMP/skins/Internet-Archive.wsz|"
  "Skins/ZaxonRemake1-0.wsz|$WEBAMP/skins/ZaxonRemake1-0.wsz|"
  "Skins/Winamp5_Classified_v5.5.wsz|$MUSEUM/b0fb83cc20af3abe264291bb17fb2a13.wsz|b0fb83cc20af3abe264291bb17fb2a13"
  "Media/llama-intro.mp3|$WEBAMP/mp3/llama-2.91.mp3|"
)

mkdir -p Skins Media
for entry in "${ASSETS[@]}"; do
  IFS='|' read -r dest url md5 <<<"$entry"
  if [[ -s "$dest" ]]; then echo "have  $dest"; continue; fi
  if ! curl -fsSL "$url" -o "$dest.part"; then echo "FAILED $dest"; rm -f "$dest.part"; continue; fi
  if [[ -n "$md5" ]] && [[ "$(md5 -q "$dest.part")" != "$md5" ]]; then
    echo "CHECKSUM MISMATCH $dest"; rm -f "$dest.part"; continue
  fi
  mv "$dest.part" "$dest"; echo "got   $dest"
done
