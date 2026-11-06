"""Record the SHA-256 of each work's image in the manifest, so the app shows only those bytes.

The hashes come from `archive_images.py --verify`, which downloads every image and
compares it with the archive; the app skips a work whose file no longer matches
(ImageCache.originalData). Run the check first, then this:

  same, unchecked  the archive's hash (unchecked: the Art Institute refuses the
                   check's scripted requests; seven re-fetched on 2026-11-06 were byte-identical)
  metadata         the new hash: the file's metadata changed, its pixels are identical
  picture          the new hash if these are the bytes the visual review saw (the archive
                   holds another rendering of the file) or the work is named with --accept
                   by a person who has looked; otherwise listed, keeping the archive's
                   hash, so the app skips it until someone has
  dead             listed, keeping the archive's hash
  new              listed; no archived file, so no hash, and the shipping-data test fails

Sets `image.sha256` in the manifest and in any override with the same image, so a
later `curate emit` keeps them.

usage: python3 scripts/pin_image_hashes.py ARCHIVE_DIR [--accept WORK ...]   (from app/; idempotent)
"""
import json, pathlib, sys
ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from content_paths import data_file  # noqa: E402
from enrich_wikidata import encode  # noqa: E402

dest = pathlib.Path(sys.argv[1])
accepted = set(sys.argv[3:]) if sys.argv[2:3] == ['--accept'] else set()
reviewed = {}
for key, review in json.loads(data_file('visual-reviews.json').read_text())['reviews'].items():
    if review.get('imageSHA256'): reviewed.setdefault(key.split('/')[0], set()).add(review['imageSHA256'])
index = json.loads((dest / 'index.json').read_text())
report = json.loads((dest / 'hash-report.json').read_text())['works']
MANIFEST, OVERRIDES = ROOT / 'data/manifest.json', ROOT / 'data/overrides.json'
manifest = json.loads(MANIFEST.read_text())
overrides = json.loads(OVERRIDES.read_text())

counts, look = {}, []
for w in manifest['works']:
    wid, url = w['id'], w['image']['url']
    rec = report.get(wid)
    assert rec and rec['url'] == url, f'{wid}: run archive_images.py --verify first'
    status = rec['status']
    counts[status] = counts.get(status, 0) + 1
    settled = status == 'picture' and (rec['sha256'] in reviewed.get(wid, ()) or wid in accepted)
    sha = rec['sha256'] if status == 'metadata' or settled else rec.get('expected')
    if status in ('new', 'picture', 'dead') and not settled: look.append((wid, status, url))
    if not sha: continue
    w['image']['sha256'] = sha
    over = overrides.get(wid, {}).get('image')
    if over and over.get('url') == url: over['sha256'] = sha

MANIFEST.write_text(encode(manifest) + '\n')
OVERRIDES.write_text(json.dumps(overrides, indent=2, ensure_ascii=False) + '\n')
print(counts)
for row in look: print(*row)
