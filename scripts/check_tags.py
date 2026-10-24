#!/usr/bin/env python3
"""Require every shipped work to have durable, sourced subject tags."""
import json,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
TAGS=set('portrait self-portrait group-portrait landscape seascape cityscape religious mythological historical allegorical everyday-life still-life flowers animals nude figure abstract architecture interior night literary military battle sport pastoral narrative satirical art music dance work family transport hunting supernatural theatre nsfw'.split())

def validate(manifest,overrides,sources):
    errors=[]
    for work in manifest['works']:
        wid=work['id'];tags=work.get('tags')
        if not isinstance(tags,list) or not tags or any(not isinstance(t,str) or t not in TAGS for t in tags):
            errors.append(f'{wid}: missing or unknown tags');continue
        if tags!=sorted(set(tags)): errors.append(f'{wid}: tags must be sorted and unique')
        if overrides.get(wid,{}).get('tags')!=tags:errors.append(f'{wid}: tags will be lost on re-curation')
        record=sources.get(wid,{})
        if record.get('tags')!=tags or not record.get('source','').startswith('https://') or not record.get('basis'):
            errors.append(f'{wid}: missing or stale provenance')
    return errors

if __name__=='__main__':
    from content_paths import data_file
    read=lambda name:json.loads(data_file(name).read_text())
    errors=validate(read('manifest.json'),read('overrides.json'),read('tag-sources.json'))
    print('\n'.join(errors) if errors else 'All works have valid, durable subject tags and provenance.')
    sys.exit(bool(errors))
