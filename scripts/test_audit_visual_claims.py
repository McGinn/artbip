import copy
import tempfile
import unittest
from pathlib import Path
import audit_visual_claims as audit


class VisualReviewTests(unittest.TestCase):
    def setUp(self):
        self.manifest = {'works': [{'id': 'turner', 'title': 'Example', 'artist': 'Turner',
            'image': {'url': 'https://example.invalid/original.jpg'}, 'caption': 'Two figures stand at lower right.'}]}
        self.info = {'entries': {'turner': {'details': [{'text': 'Juliet stands at lower right.', 'cite': ['book:example:1']}]}},
                     'symbols': {}, 'workSymbols': {}}
        self.items = audit.inventory(self.info, self.manifest)
        self.baseline = {'items': {i['key']: i['fingerprint'] for i in self.items}}
        self.reviews = {'reviews': {}, 'rejectedFingerprints': {}}

    def reviewed(self, item):
        return {'fingerprint': item['fingerprint'], 'reviewer': 'test reviewer', 'reviewedOn': '2026-09-05',
                'classification': 'visual', 'verdict': 'supported', 'imageSHA256': 'a'*64,
                'coverage': 'Every visual assertion checked.', 'checks': [
                    {'kind': 'appearance', 'claim': item['text'], 'region': 'lower right',
                     'observation': 'Two figures are visible here.', 'verdict': 'supported'}]}

    def test_raw_draft_cannot_silently_skip_review(self):
        with self.assertRaises(ValueError):
            audit.inventory({"turner": {"details": []}}, self.manifest)

    def test_excluded_work_text_is_kept_but_not_audited(self):
        info = copy.deepcopy(self.info)
        info['entries']['withheld'] = {'details': [{'text': 'A diner at night.', 'cite': []}]}
        rows = audit.evaluate(audit.inventory(info, self.manifest), self.reviews, self.baseline)
        self.assertTrue(any(r['workID'] == 'withheld' and r['blocking'] for r in rows))
        keys = [i['workID'] for i in audit.inventory(info, self.manifest, excluded={'withheld'})]
        self.assertNotIn('withheld', keys)

    def test_legacy_is_debt_not_approval(self):
        rows = audit.evaluate(self.items, self.reviews, self.baseline)
        self.assertTrue(all(r['status'] == 'legacy-unreviewed' for r in rows))
        self.assertFalse(any(r['blocking'] for r in rows))

    def test_changed_text_without_keywords_still_requires_review(self):
        self.manifest['works'][0]['caption'] = 'Atmosphere.'
        rows = audit.evaluate(audit.inventory(self.info, self.manifest), self.reviews, self.baseline)
        self.assertEqual(rows[0]['flags'], [])
        self.assertTrue(rows[0]['blocking'])

    def test_flagged_legacy_requires_resolution(self):
        item = self.items[0]
        self.reviews['flaggedFingerprints'] = {item['fingerprint']: {'reason': 'Check figure location'}}
        row = audit.evaluate(self.items, self.reviews, self.baseline)[0]
        self.assertEqual(row['status'], 'needs-review')
        self.assertTrue(row['blocking'])
        self.reviews['reviews'][item['key']] = self.reviewed(item)
        self.assertFalse(audit.evaluate(self.items, self.reviews, self.baseline)[0]['blocking'])
        self.manifest['works'][0]['caption'] = 'Different description.'
        changed = audit.inventory(self.info, self.manifest)
        self.assertTrue(audit.evaluate(changed, self.reviews, self.baseline)[0]['blocking'])

    def test_text_citation_and_image_change_invalidate_review(self):
        for field in ('text', 'citation', 'image'):
            with self.subTest(field=field):
                info, manifest = copy.deepcopy(self.info), copy.deepcopy(self.manifest)
                item = self.items[1]
                reviews = {'reviews': {item['key']: self.reviewed(item)}}
                if field == 'text': info['entries']['turner']['details'][0]['text'] += ' Elsewhere.'
                if field == 'citation': info['entries']['turner']['details'][0]['cite'] = ['book:other:2']
                if field == 'image': manifest['works'][0]['image']['url'] += '?different-scan'
                row = audit.evaluate(audit.inventory(info, manifest), reviews, self.baseline)[1]
                self.assertTrue(row['blocking'])

    def test_incomplete_visual_record_cannot_pass(self):
        record = self.reviewed(self.items[0])
        del record['imageSHA256']
        record['checks'] = []
        self.assertTrue(audit.review_errors(self.items[0], record))

    def test_identity_requires_work_specific_evidence(self):
        record = self.reviewed(self.items[1])
        record['checks'][0].update(kind='identity', source='book:example:1', sourceScope='artist-general', sourceSupport='General style discussion')
        self.assertTrue(audit.review_errors(self.items[1], record))
        record['checks'][0]['sourceScope'] = 'work-specific'
        self.assertEqual(audit.review_errors(self.items[1], record), [])

    def test_nonvisual_is_not_an_evidence_bypass(self):
        item = dict(self.items[1], text='The painting was exhibited in 1834.')
        record = self.reviewed(item)
        record['classification'] = 'nonvisual'
        self.assertTrue(audit.review_errors(item, record))
        record.update(classificationReason='Exhibition history, with no image-dependent assertion.',
                      sourceChecks=[{'claim': item['text'], 'source': 'book:example:1',
                                     'sourceSupport': 'Catalogue records exhibition date.', 'verdict': 'supported'}])
        self.assertEqual(audit.review_errors(item, record), [])
        item['section'] = 'symbol'
        self.assertTrue(audit.review_errors(item, record))

    def test_known_bad_legacy_text_cannot_be_reintroduced(self):
        self.reviews['rejectedFingerprints'][self.items[1]['fingerprint']] = 'Wrong figure location'
        row = audit.evaluate(self.items, self.reviews, self.baseline)[1]
        self.assertEqual(row['status'], 'rejected')
        self.assertTrue(row['blocking'])

    def test_contradicted_and_uncertain_reviews_fail(self):
        for verdict in ('contradicted', 'uncertain'):
            record = self.reviewed(self.items[0])
            record['checks'][0]['verdict'] = verdict
            self.assertTrue(audit.review_errors(self.items[0], record))

    def test_symbol_assignments_are_reviewed_and_report_escapes_text(self):
        self.info['symbols'] = {'skull': {'name': 'Skull', 'text': '<script>not code</script>', 'cite': []}}
        self.info['workSymbols'] = {'turner': ['skull']}
        items = audit.inventory(self.info, self.manifest)
        rows = audit.evaluate(items, self.reviews, self.baseline)
        self.assertEqual(rows[-1]['section'], 'symbol')
        self.assertTrue(rows[-1]['blocking'])
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)/'report.html'
            audit.write_report(rows, output)
            self.assertIn('&lt;script&gt;not code&lt;/script&gt;', output.read_text())
            self.assertNotIn('<script>not code</script>', output.read_text())


if __name__ == '__main__':
    unittest.main()
