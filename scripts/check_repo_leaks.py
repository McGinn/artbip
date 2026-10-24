#!/usr/bin/env python3
"""Fail if the public repository tracks anything that belongs in artbip-private.

    python3 scripts/check_repo_leaks.py

Checks every file git tracks (staged state, so it also catches a bad `git add`):
  * no private editorial file (scripts/content_paths.PRIVATE) or review
    workspace file (checkpoint, drafts, receipts) is tracked anywhere;
  * no personal email address — only example and noreply addresses;
  * no key material or service secret values;
  * no editorial bookkeeping in shipped data: published records carry no
    drafting-process fields, and no field holds long verbatim source text
    (evidence, basis or quote fields belong in the private ledgers);
  * none of the paid-content code removed before the first public release
    (store, purchase and entitlement code, the pack service and catalogue,
    StoreKit configuration) has come back. It lives in the private
    marketing repo under app-packs/.
"""
import json
import re
import subprocess
import sys
from pathlib import Path

from content_paths import PRIVATE

ROOT = Path(__file__).resolve().parent.parent
WORKSPACE_NAMES = {'checkpoint.json', 'RESUME.md', 'drop-ledger.json', 'pool.json'}
EMAIL = re.compile(rb'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}')
ALLOWED_EMAIL = re.compile(rb'@(example\.(com|org|net)|users\.noreply\.github\.com)$', re.I)
# Secret *values*, not code that names them: the bundle checker's patterns also
# match the key generator and the leak checkers themselves.
SECRET_PATTERNS = [
    rb'-----BEGIN [A-Z ]*PRIVATE KEY-----\s*[A-Za-z0-9+/]{20}',
    rb'"privateKey"\s*:\s*"[A-Za-z0-9+/=_-]{20,}',
    rb'pdl_ntfset_[A-Za-z0-9_]{20,}',
    rb'pdl_(?:live|sdbx)_apikey_[A-Za-z0-9_]{20,}',
    rb'ARTBIP_SIGNING_KEY=["\']?[A-Za-z0-9+/=_-]{20,}',
]
BOOKKEEPING_KEYS = {'generatedBy', 'generatedOn', 'revisedBy', 'reviewedBy'}
SOURCE_TEXT_KEYS = {'evidence', 'basis', 'quote', 'excerpt', 'sourceText'}
SOURCE_TEXT_LIMIT = 300  # licence-template lists run to ~150 characters
# Paths (relative, '/'-separated) that must not be tracked: a directory prefix
# ends in '/'. Plus file-name patterns for anything store-shaped elsewhere.
PRIVATE_PATHS = (
    'server/', 'StoreKit/', 'config/',
    'Sources/ArtbipDirect/', 'Sources/ArtbipStoreKit/', 'Sources/ArtbipCore/Education/',
    'Sources/ArtbipApp/LearnView.swift', 'Sources/artbip/PacksCommand.swift',
    'Sources/ArtbipCore/OpenRouterScorer.swift',
    'data/education/catalogue.json',
    'scripts/make_storekit_config.py', 'scripts/build_education_packs.py',
    'scripts/test_education_packs.py',
)
PRIVATE_NAME = re.compile(r'(storekit|purchase|entitlement|paywall|price|licen[cs]e.?key|pack.?(service|catalogue|store))', re.I)


def tracked():
    out = subprocess.run(['git', 'ls-files', '-z'], cwd=ROOT, check=True, capture_output=True).stdout
    return [ROOT / p for p in out.decode().split('\0') if p]


def json_problems(rel, value, path=''):
    if isinstance(value, dict):
        for k, v in value.items():
            here = f'{path}.{k}' if path else k
            if k in BOOKKEEPING_KEYS:
                yield f'{rel}: {here}: editorial bookkeeping field'
            elif k in SOURCE_TEXT_KEYS and isinstance(v, str) and len(v) > SOURCE_TEXT_LIMIT:
                yield f'{rel}: {here}: {len(v)} characters of source text'
            else:
                yield from json_problems(rel, v, here)
    elif isinstance(value, list):
        for v in value:
            yield from json_problems(rel, v, path)


def main():
    problems = []
    for f in tracked():
        if not f.is_file():
            continue  # deleted in the working tree but still staged
        rel = f.relative_to(ROOT)
        if f.name in PRIVATE or f.name in WORKSPACE_NAMES or rel.parts[0] == 'work':
            problems.append(f'{rel}: private file is tracked')
        posix = rel.as_posix()
        if any(posix == p or (p.endswith('/') and posix.startswith(p)) for p in PRIVATE_PATHS) \
                or (PRIVATE_NAME.search(f.name) and f.suffix != '.entitlements'):
            problems.append(f'{rel}: paid-content file is tracked (it belongs in marketing/app-packs)')
        data = f.read_bytes()
        for m in EMAIL.finditer(data):
            if not ALLOWED_EMAIL.search(m.group()):
                problems.append(f'{rel}: email address {m.group().decode(errors="replace")}')
        for pat in SECRET_PATTERNS:
            if re.search(pat, data):
                problems.append(f'{rel}: matches secret pattern {pat.decode()}')
        if rel.parts[0] == 'data' and f.suffix == '.json':
            problems.extend(json_problems(rel, json.loads(data)))
    if problems:
        print('\n'.join(problems), file=sys.stderr)
        sys.exit(1)
    print('Tracked files carry no private content, personal addresses or secrets.')


if __name__ == '__main__':
    main()
