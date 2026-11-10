# Encore

A native macOS player for Stremio addons — built for an AIOStreams manifest — with an
Apple TV / Fusion-style interface and an mpv playback engine.

## Build & run

Requirements: Apple Silicon Mac, Command Line Tools, and `brew install mpv`.

```sh
./scripts/build.sh          # release build → build/Encore.app
./scripts/build.sh debug    # unoptimized, with symbols
open build/Encore.app
```

Build output lives in `build.nosync/` (iCloud Drive skips `.nosync` folders; it was making
"Encore 2.app" copies), with `build` as a link to it.

## Sharing

```sh
./scripts/package.sh        # → build/Encore.zip (~28 MB)
```

This copies libmpv and its ~50 Homebrew libraries into the app and re-signs it, so the
recipient doesn't need Homebrew. They do need an **Apple Silicon Mac on macOS 27 or later**
(Homebrew built those libraries for this macOS). The app is signed only ad hoc, so the first
launch is blocked: they open it once, then go to System Settings → Privacy & Security →
"Open Anyway" (or run `xattr -dr com.apple.quarantine /Applications/Encore.app`). They
paste their own manifest URL on the welcome screen; yours stays in your settings.

On first launch, paste your AIOStreams manifest URL (`https://…/manifest.json`; a
`stremio://` link works too). It can be changed later in Settings.

The build calls `swiftc` directly instead of SwiftPM. The SwiftPM bundled with these
Command Line Tools can't link package manifests, and the macOS 27 SDK's SwiftUI macros
need a plugin that only ships with Xcode, so the build targets the macOS 26 SDK. With Xcode
installed, either workaround can be dropped.

## What it does

- **Home**: hero carousel (logo, rating, cast), Continue Watching, and every catalog in
  your manifest as a row. There is no library cap. Reorder or hide rows in Settings.
- **Detail pages**: backdrop, logo, metadata, trailer (YouTube), seasons and episodes with
  watched progress (specials/OVAs in their own tab), clickable cast and crew, related titles,
  and an About section (rating, status, language, country, directors, writers, IMDb/MAL links).
- **People**: click any cast member, director or writer for their movies and shows
  (Wikidata) and, for voice actors, their anime roles with character names (AniList).
- **Related**: anime sequels/prequels and recommendations (AniList); for movies and shows,
  franchise entries and more from the director/creator (Wikidata).
- **Play** walks the addon's streams in AIOStreams' order and **checks each before playing**:
  it follows the debrid redirect and skips anything that lands on an AIOStreams/Torrentio
  error video (download failed, not cached, no matching file, limits…), an HTTP error, or a
  web page. It also ranks down files that belong to a different season or entry (e.g. "Kaguya
  2 - 01" or a sequel movie numbered S01E01 when you asked for season 1), OVAs/specials, and
  Dolby Vision-only releases, and re-checks the file a season pack actually opened.
  (The ranking is `Sources/Encore/Addon/StreamRanking.swift`.)
  A panel at the bottom shows progress ("Checking stream 2 of 8…"), can cancel,
  and explains failures. Right-click an episode or use **Streams** to choose one yourself.
- **Search** uses IMDb's suggestion API (movies, shows) and AniList (anime, opened by MAL
  id), both free and keyless, so results come back in well under a second. Your addon's own
  catalogs can still be searched from the results page.
- **Player** (libmpv): MKV/HEVC/AV1/etc. with VideoToolbox hardware decoding; audio and
  subtitle track menus, including subtitles from your addon; audio/subtitle offset;
  speed; source switching; an info panel showing the real decoder and audio output path;
  resume; Up Next and auto-advance (keeping the same release group); keyboard control.
- **Skip Intro / Recap / Credits**: from the file's chapters when it has them, otherwise
  IntroDB (shows, movies) or AniSkip (anime, via ARM id mapping). Optional auto-skip.
- **Scrubbing thumbnails**: hover the timeline for a frame preview, decoded straight from
  the stream with FFmpeg (one keyframe per spot; a click lands on the frame shown). The
  preview connection is dropped when idle. Can be turned off in Settings.
- **Languages**: audio defaults to the title's original language (from Wikidata; Japanese
  for anime) with English subtitles, preferring full-dialogue tracks over "Signs & Songs".
- **Audio**: multichannel PCM up to 7.1 (follows the output device by default, or force
  5.1/7.1), optional passthrough (AC3/E-AC3/DTS/TrueHD) and exclusive device mode.
  macOS can't usually bitstream TrueHD/DTS-HD MA; they play as lossless multichannel PCM.
- **Library**: My List, Continue Watching (including new episodes of shows you're caught
  up on), history, ratings, dropped shows, and watch-time stats.
- **Upcoming** and **Recommended for You**: the next unaired episode of shows you follow,
  and titles related to what you've watched and rated (AniList, Wikidata).
- **Sync**: watch progress shared with AIOStreams' built-in Jellyfin profile (so apps like
  Odin pick up where Encore left off, and the other way round) and with Simkl. Both are
  off until you sign in under Settings.
- **Downloads**: right-click a stream to save it to `~/Downloads`; it's checked first, like
  before playing.
- **Updates**: Encore checks GitHub releases on launch (and from Encore ▸ Check for
  Updates…), downloads the new version, checks it against the release's SHA-256 and its
  signature, swaps itself and relaunches. If the new copy won't open, the old one is put back.

Keyboard shortcuts in the player: Space/K play-pause · ←/→ skip (Shift = 1 min) · ↑/↓ volume ·
F full screen · M mute · I info · N next episode · Esc exit full screen / close.

## Not yet

Dolby Vision: profile 7/8 files play as their HDR10 base; profile 5 (DV-only, common in
streaming WEB-DLs) shows wrong colors because libmpv's embeddable renderer can't apply
Dolby Vision, so such streams are tried last and the player offers to switch. HDR is
shown only on screens that report HDR headroom (the built-in XDR display; most external
monitors don't). Torrent-only streams need a debrid service configured in AIOStreams.
Trakt and AniList sync aren't there (Simkl and AIOStreams are).

The app icon (sunset gradient, white play-forward mark) is drawn in code by
`scripts/make-icon.swift` and built into the bundle; tweak colors or shapes there.

## Your data

Everything is in `~/Library/Application Support/Encore/`:

- `library.json`: progress, My List, remembered streams and languages.
- `stats.json`: history, ratings, dropped shows, watch time.
- `credentials.json`: sync tokens and the saved AIOStreams password, readable only by your
  account (not the Keychain: an ad hoc signed app looks like a new app to the Keychain
  after every update, which then asks for permission again).

If one of the first two can't be read, or has entries that can't, Encore copies it to
`<name>.unreadable-<date>.json` before saving anything, and loads whatever entries are
intact. Progress is also saved when you quit with something playing.

## Releasing

```sh
./scripts/release.sh "Notes"        # patch bump; also: minor, major, or an exact version
```

Needs a clean working tree on `main`. It runs the tests, bumps `VERSION`, packages, commits
just the version bump, tags, pushes and creates the GitHub release. The packaged app's
minimum macOS is set to the major version the bundled libraries were built for.

## Testing

```sh
./scripts/test.sh
```

builds every source file except the app's entry point together with `Tests/main.swift` and
runs it: stream ranking, reading season/episode out of file names, error-clip detection,
the on-disk stores (write order, damaged files), and the updater's version and checksum
logic. No network, and the stores are pointed at a temporary folder.

For the app itself:

`scripts/test-addon.py <media dir>` runs a local addon on `127.0.0.1:8765`. It proxies
Cinemeta's catalogs and metadata and answers every stream request with `test.mkv` from that
directory. The app also has test hooks that only activate through environment variables
(see `Sources/Encore/DebugHooks.swift`): window snapshots, jumping straight to a route,
and logging player state.
