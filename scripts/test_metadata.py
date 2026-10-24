import copy
import unittest

from check_metadata import validate


class MetadataReviewTests(unittest.TestCase):
    def setUp(self):
        self.manifest = {'works': [{'id': 'example', 'artist': 'Claude Monet'}]}
        self.overrides = {'example': {'artist': 'Claude Monet'}}
        self.ledger = {'reviews': {'example': {
            'fields': {'artist': 'Claude Monet'}, 'reviewedOn': '2026-09-06',
            'source': 'https://museum.example/work/1', 'evidence': 'Museum attribution.'}}}

    def test_upstream_rebuild_cannot_undo_correction(self):
        self.assertEqual(validate(self.manifest, self.overrides, self.ledger), [])
        rebuilt = copy.deepcopy(self.manifest)
        rebuilt['works'][0]['artist'] = 'Pablo Picasso'
        self.assertTrue(any('differs from manifest' in e for e in validate(rebuilt, self.overrides, self.ledger)))

    def test_manifest_only_fix_is_not_durable(self):
        self.assertTrue(any('lost on re-curation' in e for e in validate(self.manifest, {}, self.ledger)))

    def test_review_requires_evidence(self):
        self.ledger['reviews']['example']['evidence'] = ''
        self.assertTrue(validate(self.manifest, self.overrides, self.ledger))

    def test_collection_correction_is_durable(self):
        self.manifest['works'][0]['collection'] = 'Mauritshuis'
        self.overrides['example']['collection'] = 'Mauritshuis'
        self.ledger['reviews']['example']['fields'] = {'collection': 'Mauritshuis'}
        self.assertEqual(validate(self.manifest, self.overrides, self.ledger), [])

    def test_reviewed_tag_correction_is_durable(self):
        self.manifest['works'][0]['tags'] = ['landscape']
        self.overrides['example']['tags'] = ['landscape']
        self.ledger['reviews']['example']['fields'] = {'tags': ['landscape']}
        self.assertEqual(validate(self.manifest, self.overrides, self.ledger), [])

    def test_quarantined_image_cannot_return(self):
        ledger = {'exclusions': {'wrong-image': {
            'source': 'https://museum.example/work/2', 'reason': 'Different work.'}}}
        overrides = {'wrong-image': {'exclude': True}}
        self.assertEqual(validate({'works': []}, overrides, ledger), [])
        self.assertTrue(validate({'works': [{'id': 'wrong-image'}]}, overrides, ledger))
        self.assertTrue(validate({'works': []}, {}, ledger))

    def test_removed_canon_membership_cannot_return_on_rebuild(self):
        self.manifest['works'][0]['significance'] = {'canonLists': []}
        self.overrides['example']['canonLists'] = []
        self.ledger['reviews']['example']['fields'] = {'canonLists': []}
        self.assertEqual(validate(self.manifest, self.overrides, self.ledger), [])
        self.manifest['works'][0]['significance']['canonLists'] = ['most-expensive']
        self.assertTrue(any('differs from manifest' in e for e in validate(self.manifest, self.overrides, self.ledger)))
        self.manifest['works'][0]['significance']['canonLists'] = []
        self.overrides['example'].pop('canonLists')
        self.assertTrue(any('lost on re-curation' in e for e in validate(self.manifest, self.overrides, self.ledger)))


if __name__ == '__main__':
    unittest.main()
