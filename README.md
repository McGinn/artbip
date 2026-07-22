# artbip

Great public-domain paintings on the macOS desktop. A native, offline-first
successor in spirit to the abandoned Artpip: a menu-bar app (plus a CLI) that
rotates a hand-curated collection of ~2,000 works — every one scored and
captioned, every one PD/CC0 with recorded licence evidence — as your wallpaper.

No accounts, no telemetry, no servers of ours. The app talks only to the
museum/Wikimedia image hosts already named in the manifest, and works offline
once images are cached.

## Install

Needs macOS 15+.

**Download**: grab `artbip-x.y.z.zip` from the
[latest release](https://github.com/mcginn/artbip/releases), unzip, and move
`artbip.app` to `/Applications`. The app is not notarized (no Apple Developer
account behind it), so the first launch is blocked: open System Settings →
Privacy & Security, scroll to the artbip message, and click **Open Anyway**.

**Or build from source** (Swift 6.1 toolchain — Xcode or Command Line Tools;
locally built apps aren't quarantined, so Gatekeeper stays quiet):

```sh
bash scripts/make_app.sh          # or: nix run .#build
cp -R dist/artbip.app /Applications/
open /Applications/artbip.app
```

An icon appears in the menu bar: Next Artwork, pause, favourite, block,
Restore Original Wallpaper (puts back whatever was on the desktop before
artbip first touched it, and pauses rotation), Launch at Login, and “Open
artbip…” for the full window — a searchable gallery of the whole collection,
rotation history, blocklist, and settings (interval from 15 minutes to a
month, blurred-art vs. palette background, wall label, margin, cache budget).
Closing the window hides it; the app lives in the menu bar.

### CLI

The same engine ships inside the bundle (symlink it onto your PATH):

```sh
ln -s /Applications/artbip.app/Contents/MacOS/artbip ~/.local/bin/artbip

artbip rotate next            # advance the wallpaper now
artbip rotate daemon          # rotate on a timer (foreground)
artbip rotate current         # what's on the desktop, with its wall label
artbip rotate fav / block     # favourite or never-show the current work
artbip rotate restore         # put back the pre-artbip wallpaper (pauses)
artbip rotate pause / resume
artbip rotate history/status
artbip compose --id met-436535 --background palette --label   # one-off PNG
```

App and CLI share state (`~/Library/Application Support/artbip/`), so
favourites made in one appear in the other. Run either the app's own timer
*or* the daemon, not both.

### nix-darwin

The flake exports a module that runs the rotation daemon as a launchd user
agent (an alternative to keeping the app running):

```nix
inputs.artbip.url = "github:mcginn/artbip";   # or path:/path/to/checkout

# in darwinConfigurations…
modules = [
  artbip.darwinModules.default
  { services.artbip.enable = true; }
];
```

## The collection

Curated offline by the pipeline in this repo (see `DESIGN.md` for the full
story): six museum/API sources (Art Institute of Chicago, Met, Cleveland,
National Gallery of Art, Rijksmuseum, Wikidata/Commons) → cross-source dedupe
→ licence and mechanical gates → an LLM vision pass that scored all 4,653
candidates for significance and wrote museum-wall-label captions → top 2,000
after per-artist caps and scan-defect drops.

- `data/manifest.json` — the versioned collection contract the app consumes.
- `data/scores.json` — every score/caption, so re-curation never re-scores.
- `data/overrides.json` — hand edits (exclusions, pins, corrections) that
  survive re-runs of the pipeline.

To tweak the collection: edit `data/overrides.json` (or selection parameters
in `data/curate.json`), run `artbip curate emit`, and rebuild the app bundle
so it carries the fresh manifest.

## License

Code is MIT. The curation data in `data/` is CC0. The artworks are public
domain or CC0, with licence evidence recorded per-work in the manifest —
see [LICENSE](LICENSE).
