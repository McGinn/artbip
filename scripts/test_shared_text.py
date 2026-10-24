import copy
import unittest
from check_shared_text import fingerprint, validate


class SharedTextTests(unittest.TestCase):
    def setUp(self):
        self.entry = {'name': 'Example', 'span': '19th century', 'context': [
            {'text': 'An accurately sourced statement.', 'cite': ['book:example:42']}]}
        self.info = {'artists': {'Example': self.entry}, 'schools': {}, 'symbols': {}}
        self.ledger = {'reviews': {'artists/Example': {
            'fingerprint': fingerprint(self.entry), 'verdict': 'supported',
            'reviewer': 'Editor', 'reviewedOn': '2026-09-06',
            'evidence': [{'source': 'book:example:42', 'support': 'Verified statement.'}]}}}

    def test_text_dates_and_citations_invalidate_review(self):
        self.assertEqual(validate(self.info, self.ledger), [])
        for field, value in [('span', '20th century'), ('context', [{'text': 'Changed', 'cite': ['book:example:42']}]),
                             ('context', [{'text': 'An accurately sourced statement.', 'cite': ['book:example:99']}])]:
            changed = copy.deepcopy(self.info)
            changed['artists']['Example'][field] = value
            self.assertTrue(validate(changed, self.ledger))

    def test_new_entry_requires_review(self):
        self.info['artists']['Unreviewed'] = self.entry
        self.assertTrue(any('Unreviewed' in e for e in validate(self.info, self.ledger)))

    def test_artwork_citation_string_would_break_app_loading(self):
        self.info['entries'] = {'work': {'context': [
            {'text': 'Sourced context.', 'cite': 'url:https://example.org'}], 'details': []}}
        self.assertTrue(any('array of strings' in e for e in validate(self.info, self.ledger)))
        self.info['entries']['work']['context'][0]['cite'] = ['url:https://example.org']
        self.assertEqual(validate(self.info, self.ledger), [])

    def test_generated_metadata_uses_same_fingerprint_as_inventory(self):
        self.entry.update(generatedBy='Editorial revision', generatedOn='2026-09-06')
        self.ledger['reviews']['artists/Example']['fingerprint'] = fingerprint(self.entry)
        self.assertEqual(validate(self.info, self.ledger), [])

    def test_unrelated_evidence_does_not_pass(self):
        self.ledger['reviews']['artists/Example']['evidence'][0]['source'] = 'book:other:1'
        self.assertTrue(validate(self.info, self.ledger))


if __name__ == '__main__':
    unittest.main()
