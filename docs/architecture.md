# How artbip is built

artbip is Swift end to end: one Swift package holds the curation pipeline, the
wallpaper compositor, the rotation runtime, the CLI and the menu-bar app. There
is no artbip server in the wallpaper path. The app reads a versioned manifest,
fetches images straight from the museums and Wikimedia, and composes each
wallpaper on your Mac.

```
museum APIs ─┐
Wikidata ────┼─ artbip curate … ─► data/manifest.json ─► app bundle
Commons ─────┘   (offline, cached)        │
                                          ▼
          image hosts ─► ImageCache ─► Compositor ─► NSWorkspace wallpaper
```

## Package layout

| Target | What it is |
|---|---|
| `ArtbipCore` | Everything shared: models, manifest and runtime store, HTTP client, image cache, compositor, rotation scheduler, gallery search and filters, artwork info and notes, and the six curation source plugins. |
| `artbip` | The CLI (swift-argument-parser): `curate`, `compose`, `rotate`, `info`, `settings`, `update`. |
| `ArtbipApp` | The SwiftUI/AppKit menu-bar app. `ARTBIP_CHANNEL=direct\|appstore` (default `direct`) picks the distribution channel: the App Store build has no update check, sponsor link or bundled CLI. |
| `ArtbipShots` | A development tool that renders static images of the UI with SwiftUI `ImageRenderer`. It is not shipped. |
| `ArtbipCoreTests` | Swift Testing suite. It uses temporary runtime directories and simulated network and wallpaper calls, so it never touches your desktop. |

The only dependency is `swift-argument-parser`. Images are drawn with
CoreGraphics, CoreImage and CoreText.

## Curation pipeline

`artbip curate` runs offline, in stages. Each stage is a subcommand, cached on
disk under `work/`, and safe to re-run.

1. **gather.** Six source plugins: the Art Institute of Chicago, the Met,
   the Cleveland Museum of Art, the National Gallery of Art (from its open-data
   CSVs), the Rijksmuseum (Linked Art), and Wikidata/Commons (SPARQL plus
   `extmetadata`). They are combined with "canon" lists mined from Wikipedia.
2. **join.** Deduplicates across sources by Wikidata QID, falling back to a fuzzy
   artist|title|decade key. The museum's image wins unless the Commons scan is
   more than 1.5× larger.
3. **prefilter.** Applies three gates:
   - licence;
   - mechanical: aspect ratio ≤ 2.75, and the image must fill a 2560×1664
     screen without upscaling;
   - significance: a museum highlight flag, canon-list membership, or enough
     Wikidata sitelinks.
4. **score.** A curator pass over every candidate image. It gives a significance
   score from 0 to 10, a one-line wall-label caption, and flags scan defects
   such as visible frames, colour cards, damage, skew or non-paintings. Results
   are cached by work id and prompt hash.
5. **emit.** Ranks the candidates, caps any one artist at 3%, drops
   defect-flagged works, merges hand overrides and writes
   `data/manifest.json`.

All 4,653 candidates were scored once. The results are committed in
`data/scores.json`, so re-curating never needs to score again.

The committed manifest is no longer a plain emit output: it carries targeted,
reviewed corrections (metadata, dates, attributions, withheld works) that a
rebuild would discard. `artbip curate emit` therefore refuses to run unless
given `--discard-reviewed-corrections`. Change the manifest with targeted,
reviewed edits instead, and keep durable corrections in
`data/overrides.json`.

### Public-domain policy

artbip applies the US rule. A museum's own public-domain or CC0 flag is taken as
authoritative. A work known only from Commons must have
`extmetadata.Copyrighted == "False"`. Every manifest entry records its licence
evidence and a link to the holding collection. A work whose US status is in
doubt is excluded in `data/overrides.json` and its last manifest entry is kept
in `data/withheld-works.json`, with the sourced reason in the private metadata
review ledger, so it can return when its copyright expires. Several audit scripts in
`scripts/` re-check the result:

- `audit_us_copyright.py` flags works that are public domain abroad but not
  clearly so in the US.
- `audit_attribution.py` flags dates that are impossible for the named painter.
- `check_metadata.py` and `check_tags.py` keep reviewed corrections and subject
  tags from being lost when the catalogue is rebuilt.

## Compositor

`Compositor` takes a manifest work and the screen geometry and produces a
wallpaper at the display's native pixels.

- The art fits inside a margin box (4.5% of the short edge by default). It is
  **never cropped**, and it is only upscaled as far as the fit requires.
- There are two backgrounds:
  - `blur`: the work itself scaled to fill, blurred and dimmed.
  - `palette`: a deep tone taken from the work's dominant colour.
- A drop shadow is optional, as is a wall label (title, artist and date) in the
  bottom margin.

`artbip compose` exposes it directly for one-off PNGs.

## Rotation runtime

The app and the CLI share one runtime directory:
`~/Library/Application Support/artbip/`, or `ARTBIP_RUNTIME_DIR` when set.

- **`RuntimeStore`** holds `settings.json` and `state.json`. State covers the
  queue, current work, history, favourites, blocks, collections and pause.
  Writes are locked and atomic, so the CLI and the app can safely run at the
  same time.
- **`Rotator`** is a shuffle bag. Every eligible work is shown once per cycle,
  a reshuffle never repeats the last work immediately, and newly eligible works
  are dealt into random slots.
- **`RotationScheduler`** makes the timing decisions as pure functions, so tests
  can check them without real timers. It catches up after sleep and retries
  failures after three minutes, backing off to thirty minutes. A heartbeat stops
  a stopped app's last timer from looking live.
- **`ImageCache`** keeps originals and thumbnails under one least-recently-used
  byte budget (2 GB by default) and prefetches the next few works. It caches
  only data that decodes as an image. A 4xx other than 408 or 429, or a page
  in place of an image, is `ImageUnavailable`. A damaged cached file is fetched
  again.
- **`WallpaperEngine`** fetches the image, composes one wallpaper per screen,
  sets it with `NSWorkspace`, saves state and prefetches ahead. An unavailable
  image drops that work from the current cycle and rotation moves on, up to
  five skips per advance, so one dead link never stalls rotation. The work
  returns next cycle, so a restored link recovers by itself. Temporary failures
  (offline, timeouts, 5xx) keep the work and retry it.

## The app

`ArtbipApp` is a `MenuBarExtra` with no Dock icon, plus a main window you can
hide. Closing the window leaves the app running in the menu bar.

- **Gallery.** Search and filters over the whole collection: artist, movement,
  subject, period, museum, and whether notes are available. It also has
  favourites and saved collections. See
  [library and storage](library-and-storage.md).
- **Info panel.** The wall label, plus educational notes where they exist.
- **Global shortcuts.** Bound with Carbon hot keys. Only "About This Artwork"
  (⌥⌘A) is bound by default.
- **Update check.** Asks GitHub's releases API at most once a day, and can be
  turned off in Settings. The App Store build has none.
- **Rating prompt (App Store build only).** After a week of use and with at
  least 3 favourites, favouriting a work or opening the info panel offers
  Apple's own rating prompt, once per app version and never while an error
  is showing (`ReviewPrompt` in ArtbipCore). macOS decides whether it
  appears. There is no custom star picker and no sentiment filter, which
  App Review 5.6.1 disallows. "Rate artbip on the App Store…" in the
  Feedback menu and Settings stays hidden until `Feedback.appStoreID` holds
  the App Store Connect Apple ID.

### Launch arguments for UI work

These arguments select views only. They never change state. Combine them with
`ARTBIP_RUNTIME_DIR` to work against a throwaway runtime:

```sh
ARTBIP_RUNTIME_DIR=$(mktemp -d) dist/artbip.app/Contents/MacOS/ArtbipApp \
  --show-gallery --show-collection Masterpieces   # or --show-tab settings, --show-info
```

## Notes

Every work shows its wall label: title, painter, date, the manifest's
caption, a museum link and the rights record. For 100 works, one per painter
and spread across periods in proportion to the whole collection, the About
This Artwork panel also shows notes:

- a commentary on the work;
- things to look for in it;
- a short biography of the painter;
- the period or style;
- what its symbols traditionally mean.

The notes are original writing. Each paragraph carries citations to published
sources, and every paragraph and symbol binding has a current, supported
review. A work without notes shows only its wall label; artbip never invents
filler. The gallery's Notes filter and a small book badge show which works
have them.

The notes are one data-only JSON file, `data/education/starter.json`
(`"format": "artbip-notes"`), decoded into typed structs (`NotesFile`) and
never executed. `scripts/build_notes.py` selects the works and writes the
file; `--check` fails if it is stale. The selection is made once and kept:
later builds only refresh the text, a selected work that stops qualifying
fails the build, and `--reselect` is the deliberate way to change the list. The app bundles it as
`Resources/notes.json`.

`scripts/check_bundle_leaks.py` runs on every build. It fails the build if the
bundle contains the full editorial source, notes that differ from the
committed file, secrets or signing material, or, in an App Store build, the
sponsor link or the CLI.

The full editorial source and its review ledgers live outside this repository.
Without them, a clone still builds and runs from the committed notes file (see
`scripts/content_paths.py`).

## Packaging

- `scripts/make_app.sh` validates the data, builds in release mode and
  assembles `dist/artbip.app`. The bundle contains the manifest, the notes
  and, in the direct build, the CLI at
  `Contents/MacOS/artbip`. It is ad-hoc signed for local use.
- `scripts/make_release.sh` produces a Developer ID signed, notarized and
  stapled DMG.
- `scripts/swift_build.sh` wraps `swift build`. It keeps build products out of
  synced folders and copes with a Command Line Tools compiler that has updated
  ahead of its SDK.
- `flake.nix` provides `nix run .#build` and a dev shell. The Swift toolchain
  itself comes from Xcode or the Command Line Tools.
