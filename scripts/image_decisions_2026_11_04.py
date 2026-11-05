"""Your image decisions of 2026-11-04 in the Mac app's data.

- Klimt, Girlfriends (Water Serpents I) (wikidata-Q2551417): withheld. The only
  file at its size has a NAVER watermark, and a watermarked image is never
  acceptable.
- Goya, Majas on a Balcony (wikidata-Q109442292): withheld. The only file is a
  phone photo of a catalogue page, not a photograph of the painting.
- Grünewald, Temptation of Saint Anthony (wikidata-Q3983802): trimmed to the
  panel. The own-work composite sits on a flat dark ground (39,39,39); the panel
  spans x 215-2655 and y 187-4871 of the 2917x5053 file, and the trim keeps
  x 218-2652, y 190-4868. The dark corner beside the notched top is the panel's
  own shape, so it stays.

Withheld works keep their other overrides for a possible return. As overrides,
so a later `curate emit` keeps them.

usage: python3 scripts/image_decisions_2026_11_04.py   (from app/; idempotent)
"""
import json, pathlib, re

ROOT = pathlib.Path(__file__).resolve().parents[1]
MANIFEST = ROOT / 'data/manifest.json'
OVERRIDES = ROOT / 'data/overrides.json'

WITHHELD = ['wikidata-Q2551417', 'wikidata-Q109442292']
TRIMS = {'wikidata-Q3983802': [0.0747, 0.0376, 0.0905, 0.0364]}

manifest = json.loads(MANIFEST.read_text())
overrides = json.loads(OVERRIDES.read_text())
works = {w['id']: w for w in manifest['works']}

for i, trim in TRIMS.items():
    im = dict(overrides.get(i, {}).get('image') or works[i]['image'])
    im['trim'] = trim
    overrides.setdefault(i, {})['image'] = im
    works[i]['image'] = im
for i in WITHHELD:
    overrides.setdefault(i, {})['exclude'] = True
manifest['works'] = [w for w in manifest['works'] if w['id'] not in WITHHELD]

out = json.dumps(manifest, indent=2, ensure_ascii=False, sort_keys=True, separators=(',', ' : ')) + '\n'
for empty in ('[]', '{}'):
    out = re.sub(r'\n( *)(.*)' + re.escape(empty),
                 lambda m: f'\n{m.group(1)}{m.group(2)}{empty[0]}\n\n{m.group(1)}{empty[1]}', out)
MANIFEST.write_text(out)
OVERRIDES.write_text(json.dumps(overrides, indent=2, ensure_ascii=False) + '\n')
print('trimmed', ', '.join(TRIMS), '| withheld', ', '.join(WITHHELD))
