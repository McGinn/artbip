"""Replace or trim watermarked images in the Mac app's data, 2026-11-04.

Your rule (2026-11-04): a watermarked image is never acceptable. The watermark
review's decisions, applied as overrides (so a later `curate emit` keeps them)
and to the current manifest:

- Andrea del Sarto, Madonna of the Harpies (wikidata-Q1235695): the Google Art
  Project scan, trimmed of its border.
- Ingres, The Valpinçon Bather (wikidata-Q3080509): pixelsniper's Flickr photo
  (CC BY 2.0), full-bleed, no trim; the signature at bottom left is Ingres's own.
- Fra Angelico, Perugia Altarpiece (wikidata-Q934458): Sailko's gallery photo
  (CC BY 3.0), trimmed to the altarpiece's edges.
- Cézanne (met-437990): the Met's image, trimmed inside the frame.
- Raphael, Maddalena Doni; Hals, Portrait of a Man and Married Couple; Munch,
  Vampire: the same image as before, with the trim the iOS app already uses.
- Velázquez, Immaculate Conception (wikidata-Q3149023): withheld until a clean
  image is found.

usage: python3 scripts/watermark_fixes.py   (from app/; idempotent)
"""
import json, pathlib, re
from urllib.parse import quote

ROOT = pathlib.Path(__file__).resolve().parents[1]
MANIFEST = ROOT / 'data/manifest.json'
OVERRIDES = ROOT / 'data/overrides.json'


def commons(name, w, h, trim):
    t = f"https://commons.wikimedia.org/wiki/Special:FilePath/{quote(name, safe='')}?width={{w}}"
    return {'format': 'jpeg', 'sourceMaxHeight': h, 'sourceMaxWidth': w,
            'trim': trim, 'url': t.replace('{w}', str(min(w, 3840))), 'urlTemplate': t}


IMAGES = {
    'wikidata-Q1235695': commons('Andrea del Sarto - Madonna delle Arpie - Google Art Project.jpg',
                                 2532, 3008, [0.012, 0.008, 0.012, 0.008]),
    'wikidata-Q3080509': commons('Jean Auguste Dominique Ingres, 1780-1867. Купальщица. 1808. '
                                 '146 х 97.5 см. Париж, Лувр (47580712361).jpg', 2638, 4000, None),
    'wikidata-Q934458': commons('Beato angelico, polittico guidalotti, 1447-48, da s. domenico a perugia, 00.jpg',
                                4052, 3438, [0.009, 0.010, 0.007, 0.030]),
}
# Same image as the manifest, plus a trim.
TRIMS = {
    'met-437990': [0.036, 0.033, 0.041, 0.035],
    'wikidata-Q2607055': [0, 0, 0, 0.012],
    'rijks-200109344': [0, 0, 0, 0.016],
    'rijks-200109346': [0, 0, 0, 0.004],
    'wikidata-Q1683743': [0.009, 0.012, 0.01, 0.013],
}
LICENSES = {
    'wikidata-Q3080509': {'credit': 'Photo: pixelsniper (Flickr), CC BY 2.0',
                          'evidence': 'commons:CC-BY-2.0+Cc-by-layout',
                          'sourceURL': 'https://www.wikidata.org/wiki/Q3080509', 'status': 'PD'},
    'wikidata-Q934458': {'credit': 'Photo: Sailko, CC BY 3.0',
                         'evidence': 'commons:CC-BY-3.0+Cc-by-layout+Italy-MiBAC-disclaimer',
                         'sourceURL': 'https://www.wikidata.org/wiki/Q934458', 'status': 'PD'},
}
WITHHELD = ['wikidata-Q3149023']

manifest = json.loads(MANIFEST.read_text())
overrides = json.loads(OVERRIDES.read_text())
works = {w['id']: w for w in manifest['works']}

for i, trim in TRIMS.items():
    im = dict(overrides.get(i, {}).get('image') or works[i]['image'])
    im['trim'] = trim
    IMAGES[i] = im
for i, im in IMAGES.items():
    im = {k: v for k, v in im.items() if v is not None}
    overrides.setdefault(i, {})['image'] = im
    works[i]['image'] = im
for i, lic in LICENSES.items():
    overrides.setdefault(i, {})['license'] = lic
    works[i]['license'] = lic
for i in WITHHELD:
    overrides[i] = {'exclude': True}
manifest['works'] = [w for w in manifest['works'] if w['id'] not in WITHHELD]

out = json.dumps(manifest, indent=2, ensure_ascii=False, sort_keys=True, separators=(',', ' : ')) + '\n'
for empty in ('[]', '{}'):
    out = re.sub(r'\n( *)(.*)' + re.escape(empty),
                 lambda m: f'\n{m.group(1)}{m.group(2)}{empty[0]}\n\n{m.group(1)}{empty[1]}', out)
MANIFEST.write_text(out)
OVERRIDES.write_text(json.dumps(overrides, indent=2, ensure_ascii=False) + '\n')
print('images', ', '.join(IMAGES), '| licences', ', '.join(LICENSES), '| withheld', ', '.join(WITHHELD))
