#!/usr/bin/env python3
"""Inventory image-dependent prose and enforce recorded source/image review.

This is a review gate, NOT a computer-vision truth detector. Heuristics only
prioritize the backlog. Every new/changed item requires a review, even when no
keyword matches. Legacy hashes record debt, never approval.
"""
import argparse
import collections
import datetime
import hashlib
import html
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from content_paths import content_path  # noqa: E402
SIGNALS = {
    'location': r'\b(foreground|background|middle ground|lower|upper|left|right|behind|beneath|above|below|rooftop|balcony)\b',
    'identity/action': r'\b(figures?|woman|women|man|men|child|children|holds?|holding|carries|carrying|stands?|sitting|kneels?)\b',
    'count/scale': r'\b(two|three|four|five|six|seven|tiny|small|large|largest|smallest|crowds?)\b',
    'visibility/absence': r'\b(hidden|invisible|missing|absent|blurred|barely|only|no trace|look for|look at)\b',
    'interpretation': r'\b(symboli[sz]es?|represents?|signifies|emblem|symbol|means that)\b',
}


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False,
                                     separators=(',', ':')).encode()).hexdigest()


def inventory(info, manifest, excluded=frozenset()):
    """Excluded works (overrides.json `exclude`) are withheld from the app, so
    their editorial text is kept for a possible return but not audited."""
    if not isinstance(info.get('entries'), dict) or not isinstance(manifest.get('works'), list):
        raise ValueError('Expected complete info.json (entries object) and manifest.json (works array), not a raw draft wave')
    works = {w['id']: w for w in manifest['works']}
    if len(works) != len(manifest['works']):
        raise ValueError('Duplicate manifest IDs')
    items = []
    def add(work_id, section, index, text, cite):
        work = works.get(work_id, {'id': work_id})
        image = work.get('image', {})
        identity = {key: work.get(key) for key in ('id', 'title', 'artist', 'image')}
        key = f'{work_id}/{section}/{index}'
        flags = [name for name, pattern in SIGNALS.items() if re.search(pattern, text, re.I)]
        if section == 'symbol': flags.append('symbol binding')
        item = dict(key=key, workID=work_id, title=work.get('title', work_id),
                    artist=work.get('artist', ''), section=section, text=text, cite=cite,
                    imageURL=image.get('url', ''), imageTemplate=image.get('urlTemplate'),
                    flags=flags, orphan=work_id not in works)
        item['fingerprint'] = digest(dict(identity=identity, section=section, text=text, cite=cite))
        items.append(item)
    for w in works.values():
        if w.get('caption'): add(w['id'], 'caption', 0, w['caption'], [])
    for work_id, entry in info.get('entries', {}).items():
        if work_id in excluded: continue
        for section in ('context', 'details'):
            for index, paragraph in enumerate(entry.get(section) or []):
                add(work_id, section, index, paragraph['text'], paragraph.get('cite', []))
    for work_id, symbols in info.get('workSymbols', {}).items():
        if work_id in excluded: continue
        for symbol in symbols:
            definition = info.get('symbols', {}).get(symbol, {})
            add(work_id, 'symbol', symbol,
                definition.get('name', symbol) + ': ' + definition.get('text', ''), definition.get('cite', []))
    return items


def review_errors(item, record):
    errors = []
    if record.get('fingerprint') != item['fingerprint']: errors.append('text, citation or image reference changed')
    if record.get('verdict') != 'supported': errors.append('not supported (cut, correct, or investigate)')
    for key in ('reviewer', 'coverage'):
        if not isinstance(record.get(key), str) or not record[key].strip(): errors.append(f'missing {key}')
    try: datetime.date.fromisoformat(record.get('reviewedOn', ''))
    except (ValueError, TypeError): errors.append('missing/invalid review date')
    classification = record.get('classification')
    if classification not in ('visual', 'nonvisual'): errors.append('missing visual/nonvisual classification')
    if classification == 'nonvisual':
        if item['section'] == 'symbol': errors.append('symbol assignments require image review')
        if not record.get('classificationReason'): errors.append('missing reason image inspection is unnecessary')
        evidence = record.get('sourceChecks', [])
        if not evidence: errors.append('no factual source checks')
        for check in evidence:
            if not check.get('claim') or check['claim'] not in item['text']:
                errors.append('factual claim not present in reviewed text')
            if check.get('source') not in item['cite'] or not check.get('sourceSupport'):
                errors.append('factual review needs cited supporting evidence')
            if check.get('verdict') != 'supported': errors.append('unresolved factual claim')
    if classification == 'visual':
        if not re.fullmatch(r'[0-9a-f]{64}', record.get('imageSHA256', '')): errors.append('missing inspected-image SHA256')
        checks = record.get('checks', [])
        if not checks: errors.append('no claim checks')
        for check in checks:
            if check.get('kind') not in ('appearance', 'location', 'count', 'identity', 'interpretation'):
                errors.append('invalid claim kind')
            if not check.get('claim') or check['claim'] not in item['text']: errors.append('claim not present in reviewed text')
            if check.get('verdict') != 'supported': errors.append('unresolved visual claim')
            if not check.get('region') or not check.get('observation'): errors.append('missing image region/observation')
            if check.get('kind') in ('identity', 'interpretation'):
                if check.get('sourceScope') != 'work-specific' or not check.get('source', '').startswith(('url:https://', 'book:')):
                    errors.append('identity/interpretation needs work-specific source evidence')
                if not check.get('sourceSupport'): errors.append('missing explanation of what source establishes')
    return errors


def evaluate(items, reviews, baseline):
    result = []
    for item in items:
        row = dict(item)
        record = reviews.get('reviews', {}).get(item['key'])
        rejected = item['fingerprint'] in reviews.get('rejectedFingerprints', {})
        if rejected:
            row.update(status='rejected', errors=['known incorrect version'], blocking=True)
        elif record:
            errors = review_errors(item, record)
            row.update(status='needs-review' if errors else 'reviewed', errors=errors, blocking=bool(errors))
        elif item['fingerprint'] in reviews.get('flaggedFingerprints', {}):
            finding = reviews['flaggedFingerprints'][item['fingerprint']]
            row.update(status='needs-review', errors=[finding['reason']], blocking=True)
        elif baseline.get('items', {}).get(item['key']) == item['fingerprint']:
            row.update(status='legacy-unreviewed', errors=[], blocking=False)
        else:
            row.update(status='new-or-changed', errors=['source/image review required'], blocking=True)
        if item['orphan']:
            row['errors'].append('no matching manifest image')
            row['blocking'] = True
        result.append(row)
    return result


def write_report(rows, destination):
    esc = html.escape
    grouped = collections.defaultdict(list)
    for row in rows: grouped[row['workID']].append(row)
    ordered = sorted(grouped.values(), key=lambda group: (
        -any(r['blocking'] for r in group),
        -sum(len(r['flags']) for r in group if r['section'] in ('details', 'symbol')),
        group[0]['title']))
    out = ['''<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Artbip visual claim review</title><style>
body{font:16px/1.5 system-ui;margin:0;background:#f4f2ed;color:#232323}header{padding:24px;background:#fff;position:sticky;top:0;z-index:1;border-bottom:1px solid #ccc}h1{margin:0}input,select{font:inherit;padding:6px}main{max-width:1450px;margin:auto;padding:20px}article{display:grid;grid-template-columns:1fr 1fr;gap:24px;background:white;margin:24px 0;padding:24px;border-radius:8px}figure{margin:0;position:sticky;top:190px;align-self:start}img{max-width:100%;max-height:70vh;object-fit:contain}section{border-top:1px solid #ccc;padding:12px 0}.status{font-size:13px;font-weight:600}code{font-size:12px;overflow-wrap:anywhere}.rejected,.new-or-changed,.needs-review{color:#a42112}.legacy-unreviewed{color:#805800}button{font:inherit}article[hidden]{display:none}@media(max-width:800px){article{display:block}figure{position:static}}a{color:#165aa5}
</style><header><h1>Visual claim review</h1><p>Queue, not a list of proven errors. No keyword match does not mean safe. Legacy text is unreviewed, not approved.</p>
<label>Search <input id="search" type="search" placeholder="Title, artist, claim, ID"></label>
<label>Status <select id="status"><option value="">All</option><option>legacy-unreviewed</option><option>new-or-changed</option><option>needs-review</option><option>rejected</option><option>reviewed</option></select></label>
<span id="count"></span></header><main>''']
    for group in ordered:
        first = group[0]
        image_url = first['imageURL']
        thumb = (first['imageTemplate'] or image_url).replace('{w}', '1280')
        out.append(f'<article data-status="{esc(" ".join(sorted(set(r["status"] for r in group))))}"><figure><h2>{esc(first["title"])}</h2><p>{esc(first["artist"])} · {esc(first["workID"])}</p><a href="{esc(image_url, quote=True)}"><img loading="lazy" src="{esc(thumb, quote=True)}" alt="{esc(first["title"], quote=True)}"></a><p><a href="{esc(image_url, quote=True)}">Open full-resolution asset</a></p></figure><div>')
        for row in group:
            citations = ' · '.join(f'<a href="{esc(c[4:], quote=True)}">{esc(c)}</a>' if c.startswith('url:https://') else esc(c) for c in row['cite'])
            out.append(f'<section><code>{esc(row["key"])}</code><div class="status {row["status"]}">{row["status"]}</div><p>{esc(row["text"])}</p><p>{citations}</p><small>Review prompts: {esc(", ".join(row["flags"]) or "No keyword flags; still requires review")}</small><p>{esc("; ".join(row["errors"]))}</p></section>')
        out.append('</div></article>')
    out.append('''</main><script>
const search=document.querySelector('#search'),status=document.querySelector('#status');
function filter(){let count=0;document.querySelectorAll('article').forEach(a=>{a.hidden=!(a.textContent.toLowerCase().includes(search.value.toLowerCase())&&(!status.value||a.dataset.status.split(' ').includes(status.value)));if(!a.hidden)count++});document.querySelector('#count').textContent=`${count} artworks`;}search.addEventListener('input',filter);status.addEventListener('change',filter);filter();</script></html>''')
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text('\n'.join(out))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--info', type=Path, default=content_path('info.json'))
    parser.add_argument('--manifest', type=Path, default=ROOT/'data/manifest.json')
    parser.add_argument('--overrides', type=Path, default=ROOT/'data/overrides.json')
    parser.add_argument('--reviews', type=Path, default=content_path('visual-reviews.json'))
    parser.add_argument('--baseline', type=Path, default=content_path('visual-review-baseline.json'))
    parser.add_argument('--report', type=Path)
    parser.add_argument('--json', type=Path)
    parser.add_argument('--check', action='store_true', help='Fail new/changed/rejected or stale-review items')
    parser.add_argument('--strict', action='store_true', help='Also fail all legacy review debt')
    args = parser.parse_args()
    load = lambda p: json.loads(p.read_text())
    excluded = {k for k, v in load(args.overrides).items() if v.get('exclude') is True}
    rows = evaluate(inventory(load(args.info), load(args.manifest), excluded),
                    load(args.reviews), load(args.baseline))
    counts = dict(collections.Counter(r['status'] for r in rows))
    print(json.dumps({'items': len(rows), 'artworks': len(set(r['workID'] for r in rows)), 'statuses': counts}, indent=2))
    if args.report: write_report(rows, args.report)
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps({'summary': counts, 'items': rows}, ensure_ascii=False, indent=2)+'\n')
    failures = [r for r in rows if r['blocking'] or (args.strict and r['status'] != 'reviewed')]
    if args.check or args.strict:
        for row in failures[:20]: print(row['key'] + ': ' + '; '.join(row['errors'] or ['legacy review outstanding']), file=sys.stderr)
        if failures: print(f'{len(failures)} items require review', file=sys.stderr)
        return int(bool(failures))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
