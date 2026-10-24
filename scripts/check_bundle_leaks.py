#!/usr/bin/env python3
"""Fail if a built artbip.app carries anything it must not ship.

    python3 scripts/check_bundle_leaks.py dist/artbip.app [--channel appstore|direct] [--release]

Checks, over every file in the bundle:
  * no full editorial file (info.json); the only notes are Resources/notes.json,
    byte-identical to the committed data/education/starter.json;
  * no private keys, webhook secrets or signing material of any kind;
  * Mac App Store build: no sponsorship link and no bundled CLI.
--release is accepted for symmetry with make_app.sh; the checks are the same.
"""
import argparse
import re
import sys
from pathlib import Path

SECRET_PATTERNS = [
    rb'-----BEGIN [A-Z ]*PRIVATE KEY-----',
    rb'"privateKey"\s*:',
    rb'"(?:secret|webhookSecret|signingSecret|apiKey)"\s*:\s*"[^"]{8,}',
    rb'pdl_ntfset_[A-Za-z0-9]{8,}',   # payment-provider notification secret
    rb'pdl_(?:live|sdbx)_apikey_',     # payment-provider API key
    rb'ARTBIP_SIGNING_KEY=',
]
APPSTORE_FORBIDDEN = [rb'github.com/sponsors']


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('app', type=Path)
    ap.add_argument('--channel', choices=['direct', 'appstore'], default='direct')
    ap.add_argument('--release', action='store_true')
    args = ap.parse_args()
    root = Path(__file__).resolve().parent.parent
    notes = (root / 'data/education/starter.json').read_bytes()
    problems = []

    files = [p for p in args.app.rglob('*') if p.is_file()]
    for f in files:
        rel = f.relative_to(args.app)
        data = f.read_bytes()
        if f.name == 'info.json':
            problems.append(f'{rel}: full editorial file must not ship')
        if f.suffix in {'.pem', '.p8', '.p12', '.key'}:
            problems.append(f'{rel}: key material')
        for pat in SECRET_PATTERNS:
            if re.search(pat, data):
                problems.append(f'{rel}: matches secret pattern {pat.decode()}')
        if f.suffix == '.json' and b'"artbip-notes"' in data and f.name != 'notes.json':
            problems.append(f'{rel}: unexpected notes file')
        if args.channel == 'appstore':
            for pat in APPSTORE_FORBIDDEN:
                if re.search(pat, data):
                    problems.append(f'{rel}: App Store build contains {pat.decode()}')
    if args.channel == 'appstore' and (args.app / 'Contents/MacOS/artbip').exists():
        problems.append('Contents/MacOS/artbip: unsandboxed CLI must not ship in the App Store build')

    bundled = args.app / 'Contents/Resources/notes.json'
    if not bundled.exists():
        problems.append('Contents/Resources/notes.json: missing')
    elif bundled.read_bytes() != notes:
        problems.append('Contents/Resources/notes.json: differs from data/education/starter.json')

    if problems:
        print('\n'.join(problems), file=sys.stderr)
        sys.exit(1)
    print(f'{args.app}: {len(files)} files, no leaks ({args.channel})')


if __name__ == '__main__':
    main()
