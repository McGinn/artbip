import unittest
from check_tags import validate

class TagsTests(unittest.TestCase):
    def test_empty_and_unknown_tags_fail(self):
        for tags in [None, [], ['potraits']]:
            self.assertTrue(validate({'works':[{'id':'w','tags':tags}]},{},{}))

    def test_recuration_and_provenance_must_match(self):
        m={'works':[{'id':'w','tags':['portrait']}]}
        o={'w':{'tags':['portrait']}}
        s={'w':{'tags':['portrait'],'source':'https://example.com/work','basis':'museum subject'}}
        self.assertEqual(validate(m,o,s),[])
        self.assertTrue(validate(m,{},s))
        s['w']['tags']=['landscape']
        self.assertTrue(validate(m,o,s))
