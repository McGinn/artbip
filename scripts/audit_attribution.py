#!/usr/bin/env python3
"""Flag works whose date is impossible for the artist they are attributed to.

A painting cannot predate its painter's birth or long postdate their death, so
comparing the manifest's own `year` against its own `artistBirthYear` /
`artistDeathYear` catches misattribution without consulting anything external.

This found Monet's The Magpie (1868) filed under Pablo Picasso, who was born in
1881 — the info panel was showing Picasso's biography beside a Monet landscape.

usage: python3 scripts/audit_attribution.py
"""
import json, os, sys

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST = os.path.join(HERE, "data/manifest.json")
# Posthumous dating is normal for undated works and for casts/prints issued
# after death, so allow a margin before calling a death date impossible.
POSTHUMOUS_GRACE = 5


def main():
    with open(MANIFEST, encoding="utf-8") as fh:
        works = json.load(fh)["works"]

    problems = []
    for w in works:
        year, born = w.get("year"), w.get("artistBirthYear")
        died = w.get("artistDeathYear")
        if year is None:
            continue
        # A painter is not producing work as an infant either; a work dated
        # within a few years of the birth is as wrong as one predating it.
        if born is not None and year < born + 10:
            problems.append((w, f"dated {year} but {w['artist']} was born {born}"))
        elif died is not None and year > died + POSTHUMOUS_GRACE:
            problems.append((w, f"dated {year} but {w['artist']} died {died}"))

    print(f"checked {len(works)} works")
    if not problems:
        print("no impossible attributions")
        return 0
    print(f"\n{len(problems)} impossible:")
    for w, why in problems:
        print(f"  {w['id']:24} {w['title'][:40]:42} {why}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
