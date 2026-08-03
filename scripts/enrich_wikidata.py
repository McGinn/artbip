#!/usr/bin/env python3
"""Tier-1 titleplate enrichment from Wikidata — the `curate enrich` pass that
docs/artwork-info.md defers. Mechanical, no LLM.

Fills the gaps a gallery wall label needs and the manifest lacks:
  * dimensions      (0/2000 before this)
  * artist birth years (0/2000; only death years were carried)

Both come from Wikidata, which 1,914 of the 2,000 works carry a QID for.
Dimensions are read through `psn:` (normalized) rather than `wdt:`, because the
raw statement value is in whatever unit the editor used — centimetres for most
paintings, but metres and inches both occur. Normalized values are always
metres, so there is one conversion and no guessing.

Medium is deliberately NOT taken from here: Wikidata's P186 gives a bag of
materials ("oil paint", "canvas") rather than the museum's phrasing ("Oil on
cradled panel"), and mixing the two registers in one titleplate line reads
worse than leaving the field empty. That gap needs the museum APIs.

Results are cached in work/enrich-cache.json so re-runs are incremental and
cost the endpoint nothing.

usage: python3 scripts/enrich_wikidata.py [--apply] [--limit N]
       (without --apply it reports what it would change and writes nothing)
"""
import argparse, json, os, re, sys, time, urllib.parse, urllib.request

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST = os.path.join(HERE, "data/manifest.json")
CACHE = os.path.join(HERE, "work/enrich-cache.json")
ENDPOINT = "https://query.wikidata.org/sparql"
UA = "artbip/0.1 (https://github.com/McGinn/artbip)"
BATCH = 150

QUERY = """
SELECT ?w ?hm ?wm ?birth ?death WHERE {
  VALUES ?w { %s }
  OPTIONAL { ?w p:P2048/psn:P2048/wikibase:quantityAmount ?hm }
  OPTIONAL { ?w p:P2049/psn:P2049/wikibase:quantityAmount ?wm }
  OPTIONAL {
    ?w wdt:P170 ?a .
    OPTIONAL { ?a wdt:P569 ?birth }
    OPTIONAL { ?a wdt:P570 ?death }
  }
}
"""


def encode(obj):
    """Re-encode the manifest the way Swift's JSONEncoder wrote it.

    The manifest is a Swift artifact (`.prettyPrinted, .sortedKeys`), which uses
    `"key" : value` with a space before the colon, and renders an empty array
    across three lines rather than as `[]`. Matching both means the enrichment
    diff shows only the fields it added instead of reformatting all 2,000 works.
    """
    text = json.dumps(obj, ensure_ascii=False, indent=2,
                      sort_keys=True, separators=(",", " : "))
    # "key" : [],  ->  "key" : [\n\n<indent>],   (the trailing comma is kept:
    # most of these arrays are not the last entry in their object)
    return re.sub(r"^([ ]*)(\".*?\" : )\[\](,?)$",
                  lambda m: f"{m.group(1)}{m.group(2)}[\n\n{m.group(1)}]{m.group(3)}",
                  text, flags=re.M)


def year(iso):
    """Wikidata dates are ISO datetimes; BCE years carry a leading '-'."""
    if not iso:
        return None
    neg = iso.startswith("-")
    try:
        y = int(iso.lstrip("-").split("-")[0])
    except ValueError:
        return None
    return -y if neg else y


def fetch(qids):
    values = " ".join(f"wd:{q}" for q in qids)
    body = urllib.parse.urlencode({"query": QUERY % values}).encode()
    req = urllib.request.Request(
        ENDPOINT, data=body,
        headers={"Accept": "application/sparql-results+json", "User-Agent": UA})
    with urllib.request.urlopen(req, timeout=90) as fh:
        rows = json.load(fh)["results"]["bindings"]

    out = {}
    for r in rows:
        qid = r["w"]["value"].rsplit("/", 1)[-1]
        rec = out.setdefault(qid, {})
        # A work with two creators yields two rows; keep the first value seen
        # for each field rather than letting the last one win.
        for key, src in (("heightCm", "hm"), ("widthCm", "wm")):
            if key not in rec and src in r:
                cm = round(float(r[src]["value"]) * 100, 1)
                if 0 < cm < 200_000:          # guard against unit errors
                    rec[key] = cm
        for key, src in (("artistBirthYear", "birth"), ("artistDeathYear", "death")):
            if key not in rec and src in r:
                y = year(r[src]["value"])
                if y is not None:
                    rec[key] = y
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true", help="write the manifest")
    ap.add_argument("--limit", type=int, help="only query this many new QIDs")
    a = ap.parse_args()

    with open(MANIFEST, encoding="utf-8") as fh:
        original = fh.read()
    manifest = json.loads(original)
    works = manifest["works"]

    # Refuse to touch the manifest unless we can reproduce it byte for byte
    # first. If Swift's formatting ever drifts from what encode() emits, this
    # fails loudly instead of silently rewriting a 2,000-work curation artifact.
    if encode(manifest) != original:
        sys.exit("encode() no longer round-trips the manifest — refusing to write")

    cache = {}
    if os.path.exists(CACHE):
        with open(CACHE, encoding="utf-8") as fh:
            cache = json.load(fh)

    qids = [w["wikidata"] for w in works if w.get("wikidata")]
    todo = [q for q in dict.fromkeys(qids) if q not in cache]
    if a.limit:
        todo = todo[:a.limit]
    print(f"{len(qids)} works with a QID; {len(todo)} not yet cached")

    for i in range(0, len(todo), BATCH):
        chunk = todo[i:i + BATCH]
        try:
            got = fetch(chunk)
        except Exception as e:                       # noqa: BLE001
            print(f"  batch {i // BATCH + 1}: FAILED ({e}) — keeping what we have")
            break
        for q in chunk:
            cache[q] = got.get(q, {})                # cache misses too
        print(f"  batch {i // BATCH + 1}/{(len(todo) + BATCH - 1) // BATCH}: "
              f"+{len(got)} with data")
        time.sleep(1)                                # be polite to the endpoint

    os.makedirs(os.path.dirname(CACHE), exist_ok=True)
    with open(CACHE, "w", encoding="utf-8") as fh:
        json.dump(cache, fh, ensure_ascii=False, indent=2, sort_keys=True)

    # Merge. Only ever fills a blank — never overwrites what curation recorded,
    # since the museum is a better authority on its own object than Wikidata.
    filled = {"dimensions": 0, "artistBirthYear": 0, "artistDeathYear": 0}
    for w in works:
        rec = cache.get(w.get("wikidata") or "", {})
        if not rec:
            continue
        if "dimensions" not in w and "heightCm" in rec and "widthCm" in rec:
            w["dimensions"] = {"heightCm": rec["heightCm"], "widthCm": rec["widthCm"]}
            filled["dimensions"] += 1
        for key in ("artistBirthYear", "artistDeathYear"):
            if w.get(key) is None and rec.get(key) is not None:
                w[key] = rec[key]
                filled[key] += 1

    def have(key):
        return sum(1 for w in works if w.get(key) is not None)

    print(f"\nwould fill: {filled}" if not a.apply else f"\nfilled: {filled}")
    print(f"  dimensions      {have('dimensions')}/{len(works)}")
    print(f"  artistBirthYear {have('artistBirthYear')}/{len(works)}")
    print(f"  artistDeathYear {have('artistDeathYear')}/{len(works)}")
    print(f"  medium          {have('medium')}/{len(works)}  (needs museum APIs)")

    if a.apply:
        with open(MANIFEST, "w", encoding="utf-8") as fh:
            fh.write(encode(manifest))
        print(f"\nwrote {MANIFEST}")
    else:
        print("\n(dry run — pass --apply to write)")


if __name__ == "__main__":
    main()
