#!/usr/bin/env python3
"""Replace the manifest's generic PD evidence with the actual Commons rationale.

Every Commons-sourced work shipped with `license.evidence = "commons:Public
domain"`, because that is what Commons' `LicenseShortName` returns for all of
them. It is the same string for a 1642 Rembrandt and a 1942 Hopper, so it
records nothing: you cannot tell from the manifest whether a work is free
because its author died in 1669 or because a 1942 copyright was never renewed.
Both are true, but only one of them is checkable, and only the specific one
survives contact with someone who disagrees.

This fetches the licence templates each file page actually carries and stores
them instead, e.g. "commons:PD-Art+PD-old-auto-expired". The rule mirrors
`WikidataSource.rationaleTemplates` in Swift so a full pipeline re-run produces
the same strings — change one, change the other.

Works whose file carries no rationale template at all are reported and left
alone: that is a finding, not something to paper over.

usage:
  python3 capture_license_evidence.py --dry-run
  python3 capture_license_evidence.py
"""
import argparse
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
MANIFEST = os.path.join(HERE, "..", "data", "manifest.json")
API = "https://commons.wikimedia.org/w/api.php"
UA = "artbip-license-audit/1.0 (https://github.com/McGinn/artbip)"
BATCH = 50

# Layout wrappers and category markers that appear on nearly every file page.
NOISE = {
    "PD-Layout", "PD-art-category", "Cc-pd-mark-footer", "Cc-by-layout",
    "PD-old-warning-text", "Licensed-PD-Art", "Licensed-PD-art",
}


def encode(obj):
    """Re-encode the manifest byte-for-byte the way Swift's JSONEncoder wrote it.

    `.prettyPrinted, .sortedKeys` uses `"key" : value` (space before the colon)
    and spreads an empty array over three lines. Matching both keeps the diff to
    the fields actually changed instead of reformatting all 2,000 works.
    """
    text = json.dumps(obj, ensure_ascii=False, indent=2,
                      sort_keys=True, separators=(",", " : "))
    return re.sub(r"^([ ]*)(\".*?\" : )\[\](,?)$",
                  lambda m: f"{m.group(1)}{m.group(2)}[\n\n{m.group(1)}]{m.group(3)}",
                  text, flags=re.M)


def rationale_templates(names):
    """Reduce a file page's templates to those stating a PD rationale."""
    seen, out = set(), []
    for raw in names:
        n = raw.removeprefix("Template:")
        if "/" in n or n.endswith("-text") or n in NOISE:
            continue
        low = n.lower()
        if not (low.startswith("pd-") or low.startswith("cc") or low == "cc0"
                or low.startswith("anonymous")):
            continue
        if low not in seen:            # Commons mixes "PD-art" and "PD-Art"
            seen.add(low)
            out.append(n)
    return sorted(out)


def commons_file(work):
    m = re.search(r"Special:FilePath/([^?]+)", work["image"]["url"])
    return urllib.parse.unquote(m.group(1)) if m else None


def fetch_templates(files):
    """{file name: [template titles]} for a batch, following tlcontinue.

    The template list is capped per *response*, not per page, so a 50-file batch
    routinely truncates mid-file. Dropping the continuation would return an
    empty list for everything after the cut — indistinguishable from a file that
    genuinely has no licence template.
    """
    titles = "|".join("File:" + f for f in files)
    out, cont, guard = {}, None, 0
    while guard < 20:
        q = {"action": "query", "format": "json", "formatversion": "2",
             "prop": "templates", "tlnamespace": "10", "tllimit": "max",
             "titles": titles}
        if cont:
            q["tlcontinue"] = cont
        req = urllib.request.Request(API + "?" + urllib.parse.urlencode(q),
                                     headers={"User-Agent": UA})
        data = json.load(urllib.request.urlopen(req, timeout=90))
        for page in data.get("query", {}).get("pages", []):
            title = page.get("title", "")
            f = title.removeprefix("File:")
            out.setdefault(f, []).extend(
                t["title"] for t in page.get("templates", []))
        cont = data.get("continue", {}).get("tlcontinue")
        guard += 1
        if not cont:
            break
        time.sleep(0.2)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    with open(MANIFEST, encoding="utf-8") as fh:
        raw = fh.read()
    manifest = json.loads(raw)

    if encode(manifest) != raw:
        sys.exit("encode() no longer round-trips the manifest — refusing to write")

    works = manifest["works"]
    targets = {}
    for w in works:
        if not w["license"]["evidence"].startswith("commons:"):
            continue                      # museum PD flags carry their own field
        f = commons_file(w)
        if f:
            targets.setdefault(f, []).append(w)
    print(f"commons-sourced works: {sum(len(v) for v in targets.values())} "
          f"across {len(targets)} files")

    files = sorted(targets)
    templates = {}
    for i in range(0, len(files), BATCH):
        batch = files[i:i + BATCH]
        try:
            templates.update(fetch_templates(batch))
        except Exception as e:                                    # noqa: BLE001
            print(f"  ! batch {i}: {e}", file=sys.stderr)
        print(f"\r  {min(i + BATCH, len(files))}/{len(files)} files", end="")
    print()

    changed, missing = 0, []
    for f, ws in targets.items():
        rat = rationale_templates(templates.get(f, []))
        if not rat:
            missing.extend(ws)
            continue
        ev = "commons:" + "+".join(rat)
        for w in ws:
            if w["license"]["evidence"] != ev:
                w["license"]["evidence"] = ev
                changed += 1

    print(f"\nevidence rewritten: {changed}")
    if missing:
        print(f"\nNO RATIONALE TEMPLATE ({len(missing)}) — these claim PD with "
              f"nothing behind it:")
        for w in sorted(missing, key=lambda x: -(x.get("year") or 0))[:40]:
            print(f"  {w.get('year')}  {w['artist'][:24]:<25} {w['title'][:44]}")

    if args.dry_run:
        print("\n(dry run, nothing written)")
        return
    with open(MANIFEST, "w", encoding="utf-8") as fh:
        fh.write(encode(manifest))
    print(f"wrote {MANIFEST}")


if __name__ == "__main__":
    main()
