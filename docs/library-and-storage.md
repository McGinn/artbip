# Browse, save and rotate your library

The Gallery sidebar contains **All artworks**, **Favourites**, and **My
collections**. Blocked works are hidden from each view.

Search and filters combine. Open **Filters** to narrow by artist, movement,
subject, period, museum / owner, or available detailed commentary. The header
shows the matching count; **Clear filters** clears both search and filters.
Switching library views starts a fresh search. Period filters use the
catalogue's stored artwork year; works without one appear under Any period.

Use **Save results…** to give the current selection a name. This saves those
specific artworks, not a search that changes with future catalogue updates.
Alternatively, **New collection** starts an empty collection. Each artwork's
**Collections** menu adds or removes it from a named collection; a checkmark
means it is included. Collections can overlap. Select a collection and open
its options menu to rename or delete it.

**Use for rotation** makes the selected collection the source of the next
scheduled rotation. It does not immediately replace the current wallpaper.
The sidebar shows the active source; **Use all artworks** resets it. Settings
also has a **Rotate from** picker for all artworks, favourites or a collection.
Empty or fully blocked selections never silently rotate unrelated artwork.
Deleting the active collection returns rotation to all artworks. Deleting a
collection keeps its artworks, downloads and favourites.

# Download storage

Your library selections and downloaded images are separate. Collections are
saved artwork IDs in personal runtime state; they do not pin images for offline
use. Favourites and history also survive automatic download eviction.

Settings → Storage provides:

- **Downloaded images**: current disk use by full-size originals and thumbnails.
- **Maximum download storage**: the shared cache limit (2 GB by default), with
  automatic removal of the least recently used downloads. Lowering the limit
  applies immediately.
- **Clear downloaded images…**: a confirmed one-time reset of those downloads.
  Collections, favourites, history, settings and composed desktop wallpapers
  are kept. Images download again when needed and require an internet connection.
- **Refresh usage**: refreshes the usage snapshot after browsing/downloads.

Clearing cancels prefetch and prevents already-running requests from writing
their completed downloads back into the cleared cache. Fresh requests may cache
images normally. This limit covers downloaded images, not the entire runtime
directory or the separately composed wallpaper files.

Personal data uses the existing locked, atomic state transactions. Existing
installations decode missing collection fields as an empty collection list.
For UI verification, `ARTBIP_RUNTIME_DIR` explicitly selects a separate runtime,
and launch arguments open specific views (see
[architecture](architecture.md#launch-arguments-for-ui-work)). Test runtimes
should disable shortcuts and update checks and pause rotation to preserve the
real desktop.
