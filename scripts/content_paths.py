"""Where the private editorial source lives.

Educational prose (info.json) and its review ledgers are not in this
repository. They live in the private artbip-private repo, checked out beside
this one (../marketing), under content/. Override with ARTBIP_CONTENT_DIR.

    info.json                    every work entry, painter, style and symbol note
    visual-reviews.json          per-claim source/image reviews
    visual-review-baseline.json
    shared-text-reviews.json     reviews of shared painter/style/symbol notes
    holds.json                   entries held back from the notes, and why
    metadata-reviews.json        sourced evidence for reviewed title/artist/date corrections
    tag-sources.json             sourced basis for every work's subject tags

Editorial working notes (review checkpoint, coverage report, writing rules)
live beside it in ../docs; see private_doc().
"""
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def content_dir() -> Path:
    env = os.environ.get('ARTBIP_CONTENT_DIR')
    return Path(env) if env else ROOT.parent / 'marketing' / 'content'


def private_doc(name: str) -> Path:
    """An editorial working note in the private checkout (docs/ beside content/)."""
    return content_dir().parent / 'docs' / name


def content_path(name: str) -> Path:
    return content_dir() / name


PRIVATE = frozenset({'info.json', 'visual-reviews.json', 'visual-review-baseline.json',
                     'shared-text-reviews.json', 'holds.json',
                     'metadata-reviews.json', 'tag-sources.json'})


def data_file(name: str) -> Path:
    """A shipping data file by bare name: private ones from the content
    directory, the rest (manifest, overrides, scores) from data/."""
    return content_file(name) if name in PRIVATE else ROOT / 'data' / name


def content_file(name: str) -> Path:
    """The path, or exit with a clear message when the private checkout is absent."""
    path = content_path(name)
    if not path.exists():
        sys.exit(f'{path}: private editorial source not found. Check out artbip-private '
                 f'as ../marketing, or set ARTBIP_CONTENT_DIR.')
    return path
