#!/usr/bin/env python3
"""Build the notes bundled with the app: data/education/starter.json.

The notes (work commentary, painter biographies, style context and symbol
notes) for 100 fully reviewed works, one work per painter, spread across
periods in proportion to the whole collection. This script is the only place
that decides which reviewed entries are bundled.

The selection is made once and then kept: later builds reuse the works listed
in the committed file and only refresh their text. A listed work that stops
qualifying fails the build rather than being swapped out silently;
--reselect chooses afresh (a deliberate, reviewed change).

Output:
  data/education/starter.json   {"format": "artbip-notes", "formatVersion": 1,
                                 "version": N, "works": [...], "info": {...}}
                                 Canonical JSON. Bundled as notes.json.

Inputs: info.json, the visual-review ledgers and holds.json from the private
content directory (scripts/content_paths.py), plus data/manifest.json. Without
the private content directory this script cannot run; the committed output is
what the app ships.

Run from the repo root: python3 scripts/build_notes.py [--check | --reselect]
--check rebuilds in memory and fails if the committed output is stale.
"""
import argparse
import collections
import hashlib
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import audit_visual_claims  # noqa: E402
from content_paths import content_file  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
NOTES_PATH = ROOT / 'data/education/starter.json'
FORMAT = 'artbip-notes'
FORMAT_VERSION = 1
NOTES_SIZE = 100
MIN_WORDS = 150          # below this an entry is too thin to bundle
MAX_BYTES = 8 * 1024 * 1024
# The drafting process whose entries may be bundled (researched from cited
# sources, then reviewed claim by claim). Recorded per entry in the private
# source as generatedBy; never shipped.
GROUNDED = 'source-grounded'

# Periods the selection is balanced across. Year ranges are inclusive, must
# not overlap, and together cover every year.
PERIODS = [
    dict(id='before-1500', years=(None, 1499)),
    dict(id='renaissance', years=(1500, 1599)),
    dict(id='baroque', years=(1600, 1699)),
    dict(id='rococo-romanticism', years=(1700, 1849)),
    dict(id='modern-life', years=(1850, None)),
]


def load(path):
    return json.loads(Path(path).read_text())


def canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(',', ':')).encode()


def sha256(data):
    return hashlib.sha256(data).hexdigest()


# --- lookups mirroring InfoFile.artist(forSort:) / school(forMovement:) -------

def _lookup(table, aliases, key):
    if not key:
        return None
    if key in table:
        return key
    lower = key.lower()
    for k in table:
        if k.lower() == lower:
            return k
    alias = aliases.get(key) or next((v for k, v in aliases.items() if k.lower() == lower), None)
    if alias is None:
        return None
    if alias in table:
        return alias
    return next((k for k in table if k.lower() == alias.lower()), None)


def artist_key(info, sort):
    if not sort or sort == 'Unknown':
        return None
    return _lookup(info.get('artists', {}), info.get('artistAliases', {}), sort)


def school_key(info, movement):
    return _lookup(info.get('schools', {}), info.get('schoolAliases', {}), movement)


def cite_sources(paragraphs):
    out = set()
    for p in paragraphs:
        for cite in p.get('cite', []):
            if cite.startswith('book:'):
                parts = cite.split(':')
                if len(parts) >= 2:
                    out.add(parts[1])
    return out


# --- eligibility ---------------------------------------------------------------

def review_rows(info, manifest, reviews, baseline):
    """Review status of every displayed item, with each review's date."""
    rows = audit_visual_claims.evaluate(audit_visual_claims.inventory(info, manifest), reviews, baseline)
    for row in rows:
        row['reviewedOn'] = reviews.get('reviews', {}).get(row['key'], {}).get('reviewedOn', '')
    return rows


def assess(info, manifest, rows_in, holds):
    """Per-work eligibility. Every item displayed for the work (caption, each
    context/details paragraph, each symbol binding) must carry a current,
    supported review; legacy-unreviewed text disqualifies the work."""
    works = {w['id']: w for w in manifest['works']}
    rows = collections.defaultdict(list)
    for row in rows_in:
        rows[row['workID']].append(row)
    out = {}
    for wid, entry in info.get('entries', {}).items():
        work = works.get(wid)
        context, details = entry.get('context') or [], entry.get('details') or []
        words = sum(len(p['text'].split()) for p in context + details)
        reasons = []
        if work is None:
            reasons.append('no manifest work')
        if any(r['status'] != 'reviewed' for r in rows[wid]):
            reasons.append('unreviewed or stale text')
        if not context or not details:
            reasons.append('missing context or details')
        if words < MIN_WORDS:
            reasons.append(f'under {MIN_WORDS} words')
        if wid in holds:
            reasons.append(holds[wid])
        if work is not None and work.get('year') is None:
            reasons.append('no year for period grouping')
        out[wid] = dict(id=wid, eligible=not reasons, reasons=reasons, words=words,
                        grounded=entry.get('generatedBy') == GROUNDED,
                        reviewedOn=max((r.get('reviewedOn', '') for r in rows[wid]), default=''))
    return out


def significance(work):
    s = work.get('significance') or {}
    return (s.get('curatorScore') or 0) + 2 * len(s.get('canonLists') or []) + (2 if s.get('museumHighlight') else 0)


def period_of(year):
    for period in PERIODS:
        lo, hi = period['years']
        if (lo is None or year >= lo) and (hi is None or year <= hi):
            return period['id']
    raise ValueError(year)


def select_notes(assessed, works, info, size=NOTES_SIZE):
    """Pick `size` works: one per painter, period quotas proportional to the
    number of works in each period across the whole collection (not the
    reviewed pool, which follows the review order), most significant first.
    Only source-grounded entries qualify, so the bundled notes are the
    best-checked writing."""
    pool = [a for a in assessed.values() if a['eligible'] and a['grounded']]
    by_period = collections.defaultdict(list)
    for a in pool:
        by_period[period_of(works[a['id']]['year'])].append(a)
    total = len(pool)
    if total < size:
        return [], dict(shortfall=size - total, pool=total)
    collection = collections.Counter(period_of(w['year']) for w in works.values() if w.get('year') is not None)
    # Largest-remainder apportionment of the quota across periods.
    raw = {p: size * n / sum(collection.values()) for p, n in collection.items()}
    quota = {p: int(r) for p, r in raw.items()}
    for p in sorted(raw, key=lambda p: (raw[p] - quota[p], p), reverse=True)[:size - sum(quota.values())]:
        quota[p] += 1
    chosen, artists = [], set()

    def key(a):
        w = works[a['id']]
        return (-significance(w), -a['words'], a['id'])

    def artist_of(a):
        # Both the resolved profile key and the display name: artistSort can
        # split one painter across keys that no alias joins.
        w = works[a['id']]
        names = {(w.get('artist') or '').lower(), (w.get('artistSort') or '').lower()}
        key = artist_key(info, w.get('artistSort'))
        return frozenset(names | ({key.lower()} if key else set())) - {'', 'unknown'}

    for period in PERIODS:
        picked = 0
        for a in sorted(by_period[period['id']], key=key):
            if picked == quota.get(period['id'], 0):
                break
            if artist_of(a) & artists:
                continue
            chosen.append(a['id'])
            artists |= artist_of(a)
            picked += 1
    # Fill any quota a period could not meet (too few distinct painters).
    for a in sorted(pool, key=key):
        if len(chosen) == size:
            break
        if a['id'] not in chosen and not artist_of(a) & artists:
            chosen.append(a['id'])
            artists |= artist_of(a)
    shortfall = size - len(chosen)
    return sorted(chosen), dict(shortfall=shortfall, pool=total, quota=quota)


def keep_notes(assessed, fixed):
    """The committed selection, unchanged, if every listed work still
    qualifies; otherwise no selection and the works that dropped out."""
    dropped = sorted(w for w in fixed if not (w in assessed and assessed[w]['eligible'] and assessed[w]['grounded']))
    if dropped:
        return [], dict(shortfall=len(dropped), dropped=dropped)
    return sorted(fixed), dict(shortfall=0, kept=True)


# --- the notes file ------------------------------------------------------------

# Editorial bookkeeping that stays in the private source: which drafting and
# review process produced a record and when. The app gets only displayed text.
PRIVATE_KEYS = ('generatedBy', 'generatedOn', 'revisedBy')


def public(record):
    return {k: v for k, v in record.items() if k not in PRIVATE_KEYS}


def info_subset(info, manifest, work_ids):
    """The InfoFile subset `work_ids` need: their entries plus every shared
    record (artist, school, symbol, source) those works display."""
    works = {w['id']: w for w in manifest['works']}
    entries = {wid: public(info['entries'][wid]) for wid in work_ids}
    artists, schools, symbols, sources = {}, {}, {}, set()
    artist_aliases, school_aliases, work_symbols = {}, {}, {}
    for wid in work_ids:
        work = works[wid]
        entry = entries[wid]
        sources |= cite_sources((entry.get('context') or []) + (entry.get('details') or []))
        a = artist_key(info, work.get('artistSort'))
        if a:
            artists[a] = public(info['artists'][a])
            sources |= cite_sources(info['artists'][a].get('context', []))
            if a != work.get('artistSort') and work.get('artistSort') in info.get('artistAliases', {}):
                artist_aliases[work['artistSort']] = info['artistAliases'][work['artistSort']]
        s = school_key(info, work.get('movement'))
        if s:
            schools[s] = public(info['schools'][s])
            sources |= cite_sources(info['schools'][s].get('context', []))
            if s != work.get('movement') and work.get('movement') in info.get('schoolAliases', {}):
                school_aliases[work['movement']] = info['schoolAliases'][work['movement']]
        for sym in info.get('workSymbols', {}).get(wid, []):
            work_symbols.setdefault(wid, []).append(sym)
            symbols[sym] = public(info['symbols'][sym])
            sources |= cite_sources([info['symbols'][sym]])
    return dict(schemaVersion=info.get('schemaVersion', 1),
                sources={k: info['sources'][k] for k in sorted(sources) if k in info.get('sources', {})},
                entries=entries, schools=schools, schoolAliases=school_aliases,
                artists=artists, artistAliases=artist_aliases,
                symbols=symbols, workSymbols=work_symbols)


def next_version(previous, content):
    """Same version while the content is unchanged; otherwise one more."""
    if previous is None:
        return 1
    if sha256(canonical(previous['info'])) == sha256(canonical(content)):
        return previous['version']
    return previous['version'] + 1


def build(info, manifest, rows, holds, previous=None, reselect=False):
    """Returns (notes file bytes or None on shortfall, assessed, report).
    Keeps the works of `previous` unless `reselect` or there is none."""
    works = {w['id']: w for w in manifest['works']}
    assessed = assess(info, manifest, rows, holds)
    if previous and not reselect:
        ids, report = keep_notes(assessed, previous['works'])
    else:
        ids, report = select_notes(assessed, works, info)
    if not ids:
        return None, assessed, report
    content = info_subset(info, manifest, ids)
    data = canonical(dict(format=FORMAT, formatVersion=FORMAT_VERSION,
                          version=next_version(previous, content), works=ids, info=content))
    return data, assessed, report


def validate(data, manifest):
    """Invariants the app also enforces (NotesFile.validate). Returns problems."""
    errors = []
    if data is None:
        return ['no notes file built']
    if len(data) > MAX_BYTES:
        errors.append(f'notes file exceeds {MAX_BYTES} bytes')
    body = json.loads(data)
    info = body['info']
    if body['format'] != FORMAT or body['formatVersion'] != FORMAT_VERSION:
        errors.append('format header mismatch')
    if len(set(body['works'])) != NOTES_SIZE or len(body['works']) != NOTES_SIZE:
        errors.append(f'notes must cover exactly {NOTES_SIZE} distinct works')
    if set(info['entries']) != set(body['works']):
        errors.append('entries differ from the works listed')
    library = {w['id'] for w in manifest['works']}
    errors += [f'{w} is not a library work' for w in body['works'] if w not in library]
    for w, syms in info['workSymbols'].items():
        errors += [f'{w}: symbol {s} missing' for s in syms if s not in info['symbols']]
    paragraphs = [q for e in info['entries'].values() for q in (e.get('context') or []) + (e.get('details') or [])]
    paragraphs += [q for r in list(info['artists'].values()) + list(info['schools'].values()) for q in r.get('context', [])]
    for slug in cite_sources(paragraphs + list(info['symbols'].values())):
        if slug not in info['sources']:
            errors.append(f'source {slug} missing')
    for key in PRIVATE_KEYS:
        if f'"{key}"'.encode() in data:
            errors.append(f'editorial key {key} leaked into the notes')
    return errors


def inputs():
    """(info, manifest, rows, holds) from the private content and data/."""
    info, manifest = load(content_file('info.json')), load(ROOT / 'data/manifest.json')
    rows = review_rows(info, manifest, load(content_file('visual-reviews.json')),
                       load(content_file('visual-review-baseline.json')))
    return info, manifest, rows, load(content_file('holds.json'))['holds']


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    group = parser.add_mutually_exclusive_group()
    group.add_argument('--check', action='store_true')
    group.add_argument('--reselect', action='store_true',
                       help='choose the works afresh instead of keeping the committed selection')
    args = parser.parse_args()
    info, manifest, rows, holds = inputs()
    previous = load(NOTES_PATH) if NOTES_PATH.exists() else None
    data, _, report = build(info, manifest, rows, holds, previous, args.reselect)
    if report.get('dropped'):
        print('selected works no longer qualify (fix them, or --reselect):',
              *report['dropped'], sep='\n  ', file=sys.stderr)
    elif report['shortfall']:
        print(f"notes short by {report['shortfall']} works", file=sys.stderr)
    problems = validate(data, manifest)
    if problems:
        print('invalid notes:', *problems, sep='\n  ', file=sys.stderr)
        return 1
    if args.check:
        if not NOTES_PATH.exists() or NOTES_PATH.read_bytes() != data:
            print('stale notes (run scripts/build_notes.py):', NOTES_PATH.relative_to(ROOT))
            return 1
        print('notes are current')
        return 0
    NOTES_PATH.parent.mkdir(parents=True, exist_ok=True)
    NOTES_PATH.write_bytes(data)
    body = json.loads(data)
    print(f"notes v{body['version']}: {len(body['works'])} works, {len(data):,} bytes")
    return 0


if __name__ == '__main__':
    sys.exit(main())
