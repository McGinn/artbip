# artbip — design decisions

A macOS art rotator: great works of art on the desktop background, no dependency
on any server we don't control. Successor in spirit to the abandoned Artpip.

## Locked decisions

- **Name**: `artbip` — package, CLI, and app bundle.
- **Collection target**: ~2,000 works, curated offline into `data/manifest.json`
  (versioned, hand-editable; edits survive re-runs via `data/overrides.json`).
- **Language**: Swift end-to-end. Curation pipeline is `artbip curate …`
  subcommands; app is SwiftUI/AppKit.
- **App shape**: menu-bar item + hideable desktop window (gallery browser,
  history, favourites/blocklist, settings). Closing the window hides to the
  menu bar; it does not quit.
- **PD policy**: US rule. A museum's own PD/CC0 flag is authoritative;
  Commons-only works require extmetadata `Copyrighted == "False"`. Every
  manifest entry records its licence evidence and source URL.
- **LLM scoring**: runs on the user's Claude subscription *in Claude Code
  sessions* (score-prep emits `work/scoring/pending.json` + thumbnails; session
  agents write `work/scoring/results/<id>.json`). Headless fallback:
  `artbip curate score-openrouter` with `OPENROUTER_API_KEY` and a config model.
  **Never assume an Anthropic API key.**
- **Network policy**: runtime app talks only to museum/Wikimedia hosts listed in
  the manifest. Curation additionally may talk to openrouter.ai (opt-in).
  No telemetry, no accounts, works offline once cached.

## Curation pipeline (Milestone 1)

Stages, each a subcommand, each cached/idempotent:

1. `gather` — six source plugins (ARTIC, Met, Cleveland, NGA CSV dumps,
   Rijksmuseum Top-1000, Wikidata/Commons) + canon-list mining from Wikipedia
   list articles. All HTTP disk-cached under `work/cache/`.
2. `join` — dedupe across sources. Primary key Wikidata QID, fuzzy fallback
   artist|title|decade. Museum image preferred unless Commons scan is >1.5×.
3. `prefilter` — licence gate, mechanical gates (aspect ≤ 2.75; must fill
   2560×1664 without upscaling), then aggressive significance gate: museum
   highlight flag OR canon-list membership OR sitelinks ≥ 6 OR
   (creator sitelinks ≥ 30 AND museum presence signal).
4. `score-prep` / in-session scoring / `score-openrouter` — vision pass:
   significance score 0–10, wall-label caption, scan-defect flags. Cached by
   id + prompt hash.
5. `emit` — rank (LLM score, canon count, sitelinks), per-artist cap (3%),
   cut to 2,000, merge overrides, write `data/manifest.json`.
6. `audit` — `scripts/audit_gallery.py` builds `work/audit-gallery.html`, a
   self-contained stratified sample for the "does every one belong on a wall"
   review (thumbnails embedded as base64).

### Verified API facts the plugins rely on (checked live 2026-07-14)

- **ARTIC**: ES search POST `api.artic.edu/api/v1/artworks/search`;
  `is_public_domain`, `artwork_type_id=1`, `exists image_id` → 1,865 works;
  119 with `is_boosted`. IIIF `/full/max/` = native (9–12k px); `/full/full/`
  capped 3000. `thumbnail.width/height` = master dimensions. Cloudflare on
  www.artic.edu — browser-ish UA + retries. 60 req/min.
- **Met**: `isPublicDomain` is NOT a search param (broken) — hydrate objects and
  filter client-side. `isHighlight` search works (946 w/ images).
  `primaryImage` ≈ 4000px original. `GalleryNumber` (capital G) ⇒ on view.
- **Cleveland**: `cc0=1&type=Painting&has_image=1` → 3,953. `highlight=1` param
  (field `is_highlight` in records). Image tiers web/print/full; print ≈3400px
  JPEG. Unknown params silently ignored — check `info.parameters` echo.
- **NGA**: no REST metadata API. CSVs at github.com/NationalGalleryOfArt/opendata
  (`objects.csv`, `published_images.csv`, join `depictstmsobjectid`→`objectid`;
  filter `classification=Painting`, `isvirtual=0`, `viewtype=primary`,
  `openaccess=1`; has `wikidataid` and pixel dims). IIIF at api.nga.gov capped
  4096 via /full/ (use `!{w},{w}`).
- **Rijksmuseum**: old API is HTTP 410 (dead). New: keyless.
  `data.rijksmuseum.nl/search/collection?memberOfSetId=260214&type=painting&imageAvailable=true`
  = Top-1000 paintings (399). Results are bare URIs → resolve
  `id.rijksmuseum.nl/{id}` (Accept: application/ld+json, Linked Art) → image via
  shows→VisualItem→digitally_shown_by→access_point = `iiif.micr.io/{id}` full res.
  Set a real UA for iiif.micr.io.
- **Wikidata**: SPARQL only with sitelink-band FILTERs (unfiltered ORDER BY
  times out); ≥5 sitelinks ≈ 5,112 paintings. Mandatory descriptive UA; 60s/60s
  budget; back off on 429. Multi-valued P170/P195 duplicate rows — GROUP BY.
  Creator P570 death year well populated. P495 sparse — don't rely on it.
- **Commons**: `prop=imageinfo&iiprop=url|size|extmetadata` (batch ≤50 titles);
  PD test `extmetadata.Copyrighted == "False"`. Hotlink thumbs only at
  whitelisted widths (…960, 1280, 1920, 3840); `Special:FilePath/<name>?width=N`
  rounds up via PHP. `Artist` field is HTML — strip.

## Status — Milestone 1 COMPLETE (2026-07-15)

Curation is done and the manifest is user-approved at the "does every one belong
on a wall" gate.

- **All 4,653 prefiltered works scored** on Claude Sonnet, in-session (subscription,
  no API key), one model for a consistent ranking. Scoring ran in user-paced waves
  of ~10–13 subagents; each subagent viewed every thumbnail and wrote
  `work/scoring/results/<id>.json` (prompt hash `861971726d591e79`).
- **`data/scores.json`** (committed, ~1.3 MB) is the durable consolidation of all
  4,653 scores (`{id: {score, caption, defects, scored_by}}`). `work/scoring/` is
  gitignored scratch; this file is the source of truth. **Re-curation never needs
  re-scoring** as long as scores.json exists — only re-run `emit` with new params.
- **`data/manifest.json`** = 2,000 works, mean llmScore 8.42, all ≥ 7.5 (462 at
  9–10). Sources: wikidata 1,615 · met 143 · nga 74 · rijks 73 · artic 66 ·
  cleveland 29. `select()` drops any defect-flagged work (frame / not-a-painting /
  damage / color-card / skew / crop), so the manifest is clean of frames and
  non-paintings; every work is captioned.
- **`data/overrides.json`** holds hand-edits that survive re-runs. Currently
  excludes `wikidata-Q577248` (Caravaggio, only a B&W photo of a work lost 1945).
- Review gallery: `SAMPLE=150 PX=440 python3 scripts/audit_gallery.py work/audit-gallery.html`.

### Known review-quality watch-items (fold into overrides.json as found)
- B&W photographs of destroyed/lost works scored as if in colour (e.g. the excluded
  Q577248; also saw Q2395137, Q976354 — those didn't make the cut).
- Western works on paper (watercolour / pastel / oil-transfer) that some scoring
  agents accepted as paintings under the East-Asian-ink allowance.

## Milestone 2 — compositor (DONE 2026-07-16)

`Sources/ArtbipCore/Compositor.swift` + `artbip compose`. Manifest work +
screen geometry → wallpaper PNG. CoreGraphics/CoreImage/CoreText only, no new
dependencies.

- Art is fit inside a margin box (default 4.5% of the short edge) — **never
  cropped**; upscaled only as far as the fit requires.
- Backgrounds: `blur` (the artwork scaled to fill, gaussian-blurred at quarter
  res for speed, dimmed 34%) or `palette` (deep muted tone from the work's
  `paletteDominantHSL`, falling back to CIAreaAverage of the image).
- Optional drop shadow (on by default) and `--label` wall label (title /
  artist, date) drawn in the bottom margin strip, truncated with … if long.
- `artbip compose [--id <workId>] [--out p.png] [--width W --height H]
  [--background blur|palette] [--label] [--no-shadow] [--margin f]`.
  Defaults: random manifest work, main display's native pixels
  (CGDisplayCopyDisplayMode), `work/wallpapers/<id>.png`. Full-size images
  fetch through the cached `Http` client (honours per-host headers/pacing).

## Milestone 3 — rotation runtime (DONE 2026-07-16)

Shared by CLI and app; all state under `~/Library/Application Support/artbip/`.

- `RuntimeStore` — settings.json (interval, background, label, margin,
  favouritesOnly, cacheBudgetMB, prefetchCount; missing keys get defaults) +
  state.json (shuffle-bag queue, current, history≤500, favourites, blocklist,
  paused). Manifest resolution: `--manifest` > repo `data/manifest.json` (also
  refreshes the app-support copy) > app-support copy > app-bundled resource.
- `ImageCache` — originals + gallery thumbs under one LRU byte budget
  (mtime = last use, touched on hit; no index file). Prefetch never throws.
- `Rotator` — pure shuffle-bag logic: every eligible work shows once per cycle;
  reshuffle avoids immediate repeats; newly eligible ids deal into random slots.
- `WallpaperEngine` — fetch → compose per attached screen at native pixels →
  `NSWorkspace.setDesktopImageURL` → save state → prefetch ahead. (Note:
  applies to the current Space per screen — macOS limitation.)
- CLI: `artbip rotate next|daemon|current|status|history|fav|unfav|block|
  unblock|sync-manifest`. `emit` now reads committed `data/scores.json` first
  (verified: reproduces the identical 2,000 without `work/` scratch), and the
  manifest carries `image.urlTemplate` ({w} placeholder) for sized fetches.

## Milestone 4 — menu-bar app (DONE 2026-07-16)

`Sources/ArtbipApp` (SwiftUI, macOS 15+): `MenuBarExtra` (current work, next,
pause, favourite, block, source link, launch-at-login via SMAppService when
bundled, quit) + a hideable window (suppressed at launch): searchable gallery
of the full collection with disk-cached thumbnails, history, blocklist,
settings. Closing the window keeps the app in the menu bar (accessory
activation policy). App and CLI share runtime state on disk.

## Milestone 5 — packaging (DONE 2026-07-16)

- `scripts/make_app.sh` → `dist/artbip.app` (ad-hoc signed, LSUIElement,
  bundles the manifest at Contents/Resources and the CLI at Contents/MacOS).
- `flake.nix` — `nix run .#build` wrapper, devShell, and
  `darwinModules.default`: `services.artbip.enable` runs the rotation daemon
  as a launchd user agent (alternative to the app's own timer). A pure-Nix
  build is impractical (no Swift 6.1 toolchain in nixpkgs for darwin) — the
  system toolchain builds, Nix manages installation/launchd.
- `README.md` — install and usage.

### Requested future curation/UX features (not yet built)
- **Live list toggles** — filter the active rotation by style/movement, region,
  artist, date range, source, or score, switchable at runtime in the app (not a
  re-curation). Needs those facets carried into the manifest per work (movement,
  region, artistSort, year already exist; may want an explicit style/school tag).
- **Regional add/remove** — user may adjust which regional traditions are included.
  Both are cheap given `data/scores.json`: adjust `emit`/`select` params (per-artist
  cap, score floor, region weighting) and re-emit — no re-scoring, no re-gather.
