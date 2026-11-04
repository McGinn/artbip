"""Bring seven Commons images in the manifest up to date, 2026-11-04.

A size check of every Commons file against the manifest (B14) found seven
re-uploaded since the manifest was built. The manifest gets each file's current
size, so the crop policy's no-upscaling limit and the requested width are right.

- Gauguin, Vision After the Sermon; Arcimboldo, Summer and Spring; Raphael,
  Garvagh Madonna; Matsys, An Old Woman: new versions of the same file, checked
  by eye (no watermark, no frame).
- Van Gogh, The Night Café: the file was renamed to a higher-resolution upload;
  the manifest names the new file, because the apps build upload.wikimedia.org
  paths from the name and a redirect's name has no file there.
- Goya, Self-Portrait with Dr. Arrieta: the 2026 upload crops off the
  dedication along the bottom, which the caption and notes describe. The Google
  Art Project file of the same Minneapolis image keeps it; an override, so a
  later `curate emit` does not go back to the cropped file.

usage: python3 scripts/commons_size_fixes.py   (from app/; idempotent)
"""
import json, pathlib, re
from urllib.parse import quote

ROOT = pathlib.Path(__file__).resolve().parents[1]
MANIFEST = ROOT / 'data/manifest.json'
OVERRIDES = ROOT / 'data/overrides.json'


def commons(name, w, h):
    t = f"https://commons.wikimedia.org/wiki/Special:FilePath/{quote(name, safe='')}?width={{w}}"
    return {'format': 'jpeg', 'sourceMaxHeight': h, 'sourceMaxWidth': w,
            'url': t.replace('{w}', str(min(w, 3840))), 'urlTemplate': t}


SIZES = {
    'wikidata-Q1764395': commons('La vision après le sermon (Paul Gauguin).jpg', 6617, 5285),
    'wikidata-Q18572318': commons("Arcimboldo - Les saisons - L'été.jpg", 3635, 4448),
    'wikidata-Q18572283': commons('Arcimboldo - Les saisons - Le printemps - Sans cadre.jpg', 3749, 4625),
    'wikidata-Q2503581': commons('The Aldobrandini Madonna.jpg', 7476, 8711),
    'wikidata-Q2706250': commons('Quentin Matsys - A Grotesque old woman.jpg', 3212, 4226),
    'wikidata-Q674846': commons('Van Gogh - The Night Café (1888).jpg', 7408, 5848),
}
OVERRIDDEN = {
    'wikidata-Q2736720': commons('Francisco de Goya - Self-Portrait with Dr. Arrieta - Google Art Project.jpg',
                                 3307, 4876),
}

manifest = json.loads(MANIFEST.read_text())
overrides = json.loads(OVERRIDES.read_text())
works = {w['id']: w for w in manifest['works']}

for i, im in SIZES.items():
    assert not overrides.get(i, {}).get('image'), i
    works[i]['image'] = im
for i, im in OVERRIDDEN.items():
    overrides.setdefault(i, {})['image'] = im
    works[i]['image'] = im

out = json.dumps(manifest, indent=2, ensure_ascii=False, sort_keys=True, separators=(',', ' : ')) + '\n'
for empty in ('[]', '{}'):
    out = re.sub(r'\n( *)(.*)' + re.escape(empty),
                 lambda m: f'\n{m.group(1)}{m.group(2)}{empty[0]}\n\n{m.group(1)}{empty[1]}', out)
MANIFEST.write_text(out)
OVERRIDES.write_text(json.dumps(overrides, indent=2, ensure_ascii=False) + '\n')
print('sizes', ', '.join(SIZES), '| overridden', ', '.join(OVERRIDDEN))
