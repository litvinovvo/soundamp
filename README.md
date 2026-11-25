# SoundAmp

A native macOS SoundCloud player that wears classic Winamp 2.x skins.

- **Classic skins (.wsz)**: main window, equalizer, playlist editor and an artwork window (click the song title), drawn pixel-exact from the skin's bitmaps. The windows dock and snap together, and support double size, shade mode and region.txt window shapes. Any bitmap a skin lacks falls back to the Winamp 2.91 base skin, the way Winamp itself does it.
- **Bundled skins**: the Winamp 2.91 base skin, Winamp5 Classified v5.5 (from the Winamp Skin Museum), and 7 classic community skins (Green Dimension, Mac OS X Aqua, TopazAmp, Vizor, XMMS Turquoise, Internet Archive, Zaxon). To add more, drop a `.wsz` file *or a link to one* on any window (or paste it with ⌘V): links straight to a `.wsz` and Winamp Skin Museum pages (`skins.webamp.org/skin/…`) are downloaded, checked and installed. Skins › Open Skin… works too.
- **The llama intro**: the classic "DJ Mike Llama" intro plays on first launch (and from the options menu › Play the Llama Intro). Local files play through their own audio engine with the same EQ, balance and visualizer, so they don't need the audio permission.
- **Copy-paste SoundCloud links**: press ⌘V on any window, drag a link onto it, or use the eject button / ⌘L. Accepted forms:
  - tracks, including ones copied with `?si=…&utm_…` tracking parameters or from inside a playlist (`?in=…`)
  - playlists and albums (`/sets/…`)
  - public Daily Drops share links, full or shortened
  - private links (`/s-…` secret tokens)
  - artist pages and likes pages
  - `on.soundcloud.com` short links from the mobile share sheet
  - embed codes (`<iframe …w.soundcloud.com/player…>`)
  - `api.soundcloud.com/tracks/ID` and `soundcloud:tracks:ID` forms
  - several links at once, in any text
- **Classic visualizers**: spectrum analyzer (normal, fire or line coloring; thin or thick bands; peaks; 5 falloff speeds each for bars and peaks) and oscilloscope (dots, lines or solid), colored by the skin's viscolor.txt. Click the visualizer to cycle modes; right-click or the V clutter-bar button gives the full menu.
- **Real 10-band EQ, preamp and balance**, with Winamp's 17 built-in presets.
- **Slowed + reverb, live**: Effects panel (⇧⌘E), and all effect presets also sit in the EQ window's PRESETS menu (Slowed + Reverb, Slowed, Slowed Same Pitch, Daycore, Nightcore, Big Plate, Next Door Party, Next Door Slowed). The EQ window's **ON** button switches the whole chain (EQ, speed, pitch, reverb, next door) on/off.
  - **Speed** is applied at the source: SoundCloud's own player (`playbackRate`) and the local player. Default is varispeed (pitch follows, like a record — the classic "slowed" sound).
  - **Keep pitch** = varispeed at the source + a compensating pitch shift (−12·log2 speed) with [Signalsmith Stretch](https://github.com/Signalsmith-Audio/signalsmith-stretch) — the same engine (and 8 kHz tonality limit) as the audiostretch web app. Needs the audio tap for SoundCloud tracks; without it, it falls back to WebKit's basic time-stretch.
  - **Pitch** (independent, ±12 semitones, optional formant preservation for vocals): Signalsmith Stretch (MIT, vendored in `Sources/DSPKit/vendor`).
  - **Reverb**: Dattorro plate (1997 "Effect Design" paper) with mix, decay, tone, pre-delay and size.
  - **Next door**: a party behind a wall — after the reverb, a 24 dB/oct low-pass (cutoff ~20 kHz → ~180 Hz with wall thickness), a little bass thump, stereo collapsing toward mono.
  - Pitch and reverb run in the audio chain after the EQ, so on SoundCloud audio they need the audio permission (speed doesn't). The intro needs no permission.

## How it works

- **Playback**: the SoundCloud Widget API runs inside a hidden `WKWebView`. It needs no API key, no Artist Pro account, and has no daily stream cap.
- **Expanding links**: a second, silent widget turns playlists and artist pages into track lists. Single tracks get a quick title from SoundCloud's oEmbed endpoint.
- **EQ and visualizer**: a Core Audio process tap (macOS 14.2+) captures our own WebKit GPU process's audio and mutes the original. The audio then goes through the EQ, the balance and the visualizer before reaching the output device. On first play macOS asks for **System Audio Recording** permission. If it's denied, the app detaches the tap so you still hear audio, just without the EQ and visualizer.

## Build, test, run

```sh
scripts/fetch-skins.sh    # downloads the bundled skins into Skins/ and the intro into Media/ (git-ignored)
scripts/check.sh          # after changes (~25 s, silent, nothing on screen): unit tests + the real app in --headless
                          # mode vs real SoundCloud — paste → playlist → playback + bitrate, auto-advance, intro
scripts/smoke.sh          # final check (~10 s, visible UI + sound): intro plays, then a pasted SoundCloud track takes over
scripts/build.sh          # → build/SoundAmp.app
open build/SoundAmp.app   # log: ~/Library/Logs/SoundAmp.log
```

Optional extras:

```sh
SOUNDAMP_NETWORK_TESTS=1 swift test --filter testLiveOEmbed        # real oEmbed round-trip
SOUNDAMP_VIS_GALLERY=/tmp/vis.png swift test --filter VisualizerGallery   # PNG of every visualizer style
```

App switches for debugging: `--headless`, `--quit-when settled|finished|handover`, `--start-at <s>`, `--no-intro`, `--scale <1-4>`, `--data-dir <dir>` (isolated settings/playlist), `--paste <text>`, `--skin <name>`, `--volume N`, `--no-tap`, `--reset-playlist`, `--debug` (opens the debug console), `--quit-after N` and `--snapshot <dir>`.

## Keys

| Key | Action |
|---|---|
| Z / X / C / V / B | previous, play, pause, stop, next |
| S / R | shuffle, repeat |
| L or ⌘L | add a link |
| ⌘V | paste links |
| ← → / ↑ ↓ | seek 5 s / volume |
| ⌘= / ⌘- / ⌘0 | zoom in / out / 100% (also pinch on the trackpad; 100–400% in 50% steps) |
| ⌘D | double size (Winamp's "D") |
| ⌘T | always on top |
| ⌥E / ⌥G / ⌥A | playlist / equalizer / artwork window |
| ⇧⌘D | debug console |
| In the playlist | Return plays, Delete removes, ⌘A selects all, ⌘C copies links, drag to reorder |

## Layout

```
Sources/DSPKit/           C++ real-time effects: Signalsmith pitch shifter + Dattorro plate (C API)
Sources/SoundAmpCore/     pure, unit-tested
  SoundCloudLink.swift    link parsing/normalization + PasteParser
  LinkResolver.swift      oEmbed, short-link expansion (HTTP seam for tests)
  Playlist.swift          queue, shuffle/repeat, selection, totals
  ZipArchive.swift        .wsz reader (stored + deflate)
  Skin*.swift             skin model, sprite map + layout (ported from Webamp, MIT), viscolor/pledit/region parsers
  ClassicVisualizer.swift Winamp analyzer + oscilloscope (76×16 RGBA)
  Equalizer*.swift        biquad EQ, presets, EQ graph spline
Sources/SoundAmp/         the app
  PlayerController.swift  playback, paste handling, tap, EQ, visualizer feed
  CollectionResolver.swift playlist/artist expansion via a silent widget
  WidgetPage/WidgetPlayer SoundCloud widget host + JS bridge
  TapEngine.swift         process tap → aggregate device → real-time DSP (re-attaches on output device change)
  SkinView, Main/Equalizer/Playlist/ArtworkWindowView, WindowManager, MenuBuilder, SkinManager, DebugConsole
```

## Notes

- Personal-use project. The bundled skins come from the Webamp demo; check their licensing before redistributing a build that includes them.
- SoundCloud's API terms don't address hidden players or real-time audio taps. That's fine for personal use, but read the terms before publishing.
- Not affiliated with Winamp or SoundCloud. Skin sprite coordinates and visualizer behavior follow [Webamp](https://github.com/captbaritone/webamp) (MIT).

## License and third-party code

SoundAmp's own code is [MIT-licensed](LICENSE).

- [Signalsmith Stretch](https://github.com/Signalsmith-Audio/signalsmith-stretch) and [Signalsmith Linear](https://github.com/Signalsmith-Audio/linear) (MIT) are vendored unmodified in `Sources/DSPKit/vendor`, with their license files.
- Sprite coordinates, window layout, EQ presets and visualizer behavior are ported from [Webamp](https://github.com/captbaritone/webamp) (MIT, © Jordan Eldredge).
- **Not in this repository:** the Winamp skins and the "DJ Mike Llama" intro. `scripts/fetch-skins.sh` downloads them from Webamp's repository and the Winamp Skin Museum for local builds. They belong to their respective owners (the base skin and the intro to Winamp); don't redistribute builds that bundle them without checking their licensing.
