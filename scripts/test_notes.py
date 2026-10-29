import copy
import json
import unittest
from pathlib import Path

import build_notes as b

ROOT = Path(__file__).resolve().parents[1]


def reviewed_rows(info, manifest):
    """Synthetic review rows: every item reviewed."""
    import audit_visual_claims as a
    return [dict(r, status='reviewed', reviewedOn='2026-10-01') for r in a.inventory(info, manifest)]


def para(words, cite='book:src:1'):
    return {'text': ' '.join(['word'] * words), 'cite': [cite]}


def synthetic(n_works=120, artists=None, years=None):
    works, entries = [], {}
    for i in range(n_works):
        wid = f'w{i}'
        works.append({'id': wid, 'title': f'T{i}', 'artist': f'Artist {i if artists is None else artists(i)}',
                      'artistSort': f'A{i if artists is None else artists(i)}', 'movement': 'Baroque',
                      'year': (years or (lambda i: 1400 + (i * 5) % 600))(i), 'image': {'url': f'u{i}'},
                      'significance': {'curatorScore': i % 10}})
        entries[wid] = {'context': [para(100)], 'details': [para(100)], 'generatedBy': b.GROUNDED}
    info = {'schemaVersion': 1, 'sources': {'src': {'title': 'S', 'author': 'X', 'kind': 'book'}},
            'entries': entries, 'schools': {'Baroque': {'name': 'Baroque', 'context': [para(20)]}},
            'schoolAliases': {}, 'artists': {f'A{i}': {'name': f'Artist {i}', 'context': [para(20)]} for i in range(n_works)},
            'artistAliases': {}, 'symbols': {'skull': {'name': 'Skull', 'text': 'x', 'cite': ['book:src:2']}},
            'workSymbols': {'w0': ['skull'], 'w119': ['skull']}}
    return info, {'works': works}


class SyntheticBuildTests(unittest.TestCase):
    def build(self, info, manifest, holds=None, previous=None, reselect=False):
        return b.build(info, manifest, reviewed_rows(info, manifest), holds or {}, previous, reselect)

    def test_exactly_100_distinct_works(self):
        info, manifest = synthetic()
        data, _, report = self.build(info, manifest)
        self.assertEqual(b.validate(data, manifest), [])
        body = json.loads(data)
        self.assertEqual((body['format'], len(body['works']), report['shortfall']), ('artbip-notes', 100, 0))
        self.assertEqual(set(body['info']['entries']), set(body['works']))

    def test_notes_carry_no_editorial_bookkeeping(self):
        info, manifest = synthetic()
        for a in info['artists'].values():
            a.update(generatedBy='x', generatedOn='2026-01-01')
        data, _, _ = self.build(info, manifest)
        for key in b.PRIVATE_KEYS:
            self.assertNotIn(f'"{key}"', data.decode())

    def test_shortfall_is_reported_not_padded(self):
        info, manifest = synthetic(n_works=90)
        data, _, report = self.build(info, manifest)
        self.assertIsNone(data)
        self.assertEqual(report['shortfall'], 10)
        self.assertTrue(b.validate(data, manifest))

    def test_one_work_per_painter_limits_selection(self):
        info, manifest = synthetic(n_works=150, artists=lambda i: i % 95)
        _, _, report = self.build(info, manifest)
        self.assertEqual(report['shortfall'], 5)

    def test_only_source_grounded_entries_qualify(self):
        info, manifest = synthetic(n_works=101)
        for wid in ('w1', 'w2'):
            info['entries'][wid]['generatedBy'] = 'other'
        _, _, report = self.build(info, manifest)
        self.assertEqual(report['shortfall'], 1)

    def test_thin_unreviewed_and_held_entries_are_excluded(self):
        info, manifest = synthetic(n_works=103)
        info['entries']['w1']['details'] = []
        info['entries']['w2']['context'] = [para(10)]
        info['entries']['w2']['details'] = [para(10)]
        rows = reviewed_rows(info, manifest)
        for r in rows:
            if r['workID'] == 'w3' and r['section'] == 'details':
                r['status'] = 'legacy-unreviewed'
        _, assessed, report = b.build(info, manifest, rows, {'w4': 'pending source-checked rewrite'})
        self.assertFalse(any(assessed[w]['eligible'] for w in ('w1', 'w2', 'w3', 'w4')))
        self.assertEqual(report['shortfall'], 1)

    def test_shared_records_travel_with_the_works_that_show_them(self):
        info, manifest = synthetic()
        body = json.loads(self.build(info, manifest)[0])
        self.assertIn('Baroque', body['info']['schools'])
        for w in body['works']:
            for sym in body['info']['workSymbols'].get(w, []):
                self.assertIn(sym, body['info']['symbols'])

    def test_version_bumps_only_when_content_changes(self):
        info, manifest = synthetic()
        first = json.loads(self.build(info, manifest)[0])
        same = json.loads(self.build(info, manifest, previous=first)[0])
        self.assertEqual(same['version'], 1)
        changed = copy.deepcopy(info)
        changed['entries'][first['works'][0]]['context'][0]['text'] += ' more'
        self.assertEqual(json.loads(self.build(changed, manifest, previous=first)[0])['version'], 2)

    def test_quotas_follow_the_collection_not_the_reviewed_pool(self):
        # 200 works, half before 1500 and half after 1850; only 5 of the
        # later half have notes, so the reviewed pool is mostly early.
        info, manifest = synthetic(n_works=200, years=lambda i: 1400 if i < 100 else 1900)
        for i in range(105, 200):
            del info['entries'][f'w{i}']
        _, _, report = self.build(info, manifest)
        self.assertEqual(report['quota'], {'before-1500': 50, 'modern-life': 50})

    def test_selection_is_kept_once_made(self):
        info, manifest = synthetic(n_works=150)
        first = json.loads(self.build(info, manifest)[0])
        for w in manifest['works']:          # rankings change after review
            w['significance']['curatorScore'] = 9 - w['significance']['curatorScore']
        again = json.loads(self.build(info, manifest, previous=first)[0])
        self.assertEqual(again['works'], first['works'])
        fresh = json.loads(self.build(info, manifest, previous=first, reselect=True)[0])
        self.assertNotEqual(fresh['works'], first['works'])

    def test_kept_work_that_stops_qualifying_fails_the_build(self):
        info, manifest = synthetic(n_works=150)
        first = json.loads(self.build(info, manifest)[0])
        info['entries'][first['works'][0]]['details'] = []
        data, _, report = self.build(info, manifest, previous=first)
        self.assertIsNone(data)
        self.assertEqual(report['dropped'], [first['works'][0]])

    def test_validate_catches_broken_files(self):
        info, manifest = synthetic()
        body = json.loads(self.build(info, manifest)[0])
        missing = copy.deepcopy(body)
        missing['info']['sources'] = {}
        self.assertTrue(any('source' in e for e in b.validate(b.canonical(missing), manifest)))
        short = copy.deepcopy(body)
        short['works'] = short['works'][1:]
        self.assertTrue(b.validate(b.canonical(short), manifest))


class CommittedNotesTests(unittest.TestCase):
    """The committed notes file: exactly 100 works, one per painter, complete."""

    @classmethod
    def setUpClass(cls):
        cls.data = b.NOTES_PATH.read_bytes()
        cls.manifest = json.loads((ROOT / 'data/manifest.json').read_text())

    def test_committed_notes_are_valid(self):
        self.assertEqual(b.validate(self.data, self.manifest), [])

    def test_one_work_per_painter(self):
        works = set(json.loads(self.data)['works'])
        names = [w['artist'] for w in self.manifest['works'] if w['id'] in works]
        named = [a for a in names if a != 'Unknown']
        self.assertEqual(len(set(named)), len(named))


if __name__ == '__main__':
    unittest.main()
