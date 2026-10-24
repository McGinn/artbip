#!/usr/bin/env python3
"""Require a source review for each exact shared artist, style and symbol entry.

These checks preserve review evidence; they cannot establish historical truth.
A symbol definition review does not approve its assignment to any artwork.
"""
import datetime
import hashlib
import json
import sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from content_paths import content_file  # noqa: E402


def inventory(info):
    return {f'{section}/{key}': {k: v for k, v in entry.items()
            if k not in ('generatedBy', 'generatedOn')}
            for section in ('artists', 'schools', 'symbols')
            for key, entry in info[section].items()}


def fingerprint(entry):
    entry = {k: v for k, v in entry.items()
             if k not in ('generatedBy', 'generatedOn')}
    return hashlib.sha256(json.dumps(entry, sort_keys=True, ensure_ascii=False,
                          separators=(',', ':')).encode()).hexdigest()


def validate(info, ledger):
    errors = []
    for wid, entry in info.get('entries', {}).items():
        for section in ('context', 'details'):
            for index, paragraph in enumerate(entry.get(section, [])):
                cites = paragraph.get('cite')
                if not isinstance(cites, list) or any(not isinstance(c, str) for c in cites):
                    errors.append(f'{wid}/{section}/{index}: citations must be an array of strings for the app decoder')
    items = inventory(info)
    records = ledger.get('reviews', {})
    for key, entry in items.items():
        record = records.get(key, {})
        if record.get('fingerprint') != fingerprint(entry):
            errors.append(f'{key}: source review missing or stale')
            continue
        if record.get('verdict') != 'supported' or not record.get('reviewer'):
            errors.append(f'{key}: source review is not approved')
        try:
            datetime.date.fromisoformat(record.get('reviewedOn', ''))
        except (ValueError, TypeError):
            errors.append(f'{key}: invalid review date')
        evidence = record.get('evidence', [])
        cited = set(entry.get('cite', []))
        for p in entry.get('context', []):
            cited.update(p.get('cite', []))
        if not evidence or any(not e.get('support') or e.get('source') not in cited for e in evidence):
            errors.append(f'{key}: supporting evidence must reference a displayed citation')
    for key in records.keys() - items.keys():
        errors.append(f'{key}: review has no corresponding shared entry')
    return errors


if __name__ == '__main__':
    info = json.loads(content_file('info.json').read_text())
    ledger = json.loads(content_file('shared-text-reviews.json').read_text())
    errors = validate(info, ledger)
    print('\n'.join(errors) if errors else 'All shared text has current source reviews.')
    sys.exit(bool(errors))
