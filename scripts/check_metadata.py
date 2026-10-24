#!/usr/bin/env python3
"""Prevent reviewed identity corrections from being lost during catalogue rebuilds."""
import datetime
import json
import sys
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]
FIELDS = {'title', 'artist', 'artistSort', 'artistDeathYear', 'dateDisplay',
          'year', 'collection', 'collectionURL', 'tags', 'canonLists', 'movement'}


def validate(manifest, overrides, ledger):
    errors = []
    works = {w['id']: w for w in manifest['works']}
    for wid, record in ledger.get('exclusions', {}).items():
        if wid in works or overrides.get(wid, {}).get('exclude') is not True:
            errors.append(f'{wid}: quarantined image must remain excluded')
        source = urlparse(record.get('source', ''))
        if source.scheme != 'https' or not source.netloc or not record.get('reason'):
            errors.append(f'{wid}: exclusion requires source and reason')
    for wid, record in ledger.get('reviews', {}).items():
        if wid not in works:
            errors.append(f'{wid}: reviewed work is absent')
            continue
        source = urlparse(record.get('source', ''))
        if source.scheme != 'https' or not source.netloc or not record.get('evidence', '').strip():
            errors.append(f'{wid}: source and evidence are required')
        try:
            datetime.date.fromisoformat(record.get('reviewedOn', ''))
        except (ValueError, TypeError):
            errors.append(f'{wid}: invalid review date')
        fields = record.get('fields', {})
        if not fields or set(fields) - FIELDS:
            errors.append(f'{wid}: missing or unsupported reviewed fields')
        for field, expected in fields.items():
            actual = (works[wid].get('significance', {}).get('canonLists')
                      if field == 'canonLists' else works[wid].get(field))
            if actual != expected:
                errors.append(f'{wid}: reviewed {field} differs from manifest')
            if overrides.get(wid, {}).get(field) != expected:
                errors.append(f'{wid}: reviewed {field} will be lost on re-curation')
    return errors


if __name__ == '__main__':
    from content_paths import data_file

    def read(name):
        return json.loads(data_file(name).read_text())
    errors = validate(read('manifest.json'), read('overrides.json'), read('metadata-reviews.json'))
    print('\n'.join(errors) if errors else 'Reviewed metadata corrections are present and durable.')
    sys.exit(bool(errors))
