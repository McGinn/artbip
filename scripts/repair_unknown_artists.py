#!/usr/bin/env python3
"""Fill in artists the manifest still records as "Unknown", and bad inceptions.

Tail of the same 2026-07-14 gather bug that `repair_from_wikidata.py` fixed for
22 works: the band query sampled the creator's label separately from the rest of
the creator's data, so a work could arrive with a death year and no name. 38
rows survived that pass. Eleven of them are Sargents — one painter lost across a
whole cluster is the bug's signature.

Not every "Unknown" is wrong. A Tibetan mandala, a Fayum portrait and the Wilton
Diptych have no recorded author, and Wikidata says so. Those keep the honest
"Unknown"; only works whose creator Wikidata actually names are touched, and
only when it names exactly one (a collaboration or a disputed attribution is a
judgement call, not a repair).

Also corrects `year`/`dateDisplay` where the manifest disagrees with Wikidata's
inception by more than a century — Bruegel's *Landscape with the Fall of Icarus*
shipped dated 2000.

Uses the Action API rather than SPARQL: the query service returns the bare QID
as the "label" for a variable bound inside OPTIONAL, which made every Sargent
here look anonymous, and it spends a fair amount of time rate-limited to one
request a minute during outages.

usage: python3 scripts/repair_unknown_artists.py [--apply]
"""
import argparse
import json
import os
import re
import sys
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST = os.path.join(HERE, "data/manifest.json")
WD_API = "https://www.wikidata.org/w/api.php"
UA = "artbip-repair/1.0 (https://github.com/McGinn/artbip)"


def encode(obj):
    """Match Swift's JSONEncoder output — see scripts/enrich_wikidata.py."""
    text = json.dumps(obj, ensure_ascii=False, indent=2,
                      sort_keys=True, separators=(",", " : "))
    return re.sub(r"^([ ]*)(\".*?\" : )\[\](,?)$",
                  lambda m: f"{m.group(1)}{m.group(2)}[\n\n{m.group(1)}]{m.group(3)}",
                  text, flags=re.M)


def sort_name(name):
    """'John Singer Sargent' -> 'Sargent, John Singer', matching the manifest."""
    parts = name.split()
    return name if len(parts) < 2 else f"{parts[-1]}, {' '.join(parts[:-1])}"


def year_of(iso):
    """Wikidata times are '+1892-01-01T00:00:00Z'; BCE carries a leading '-'."""
    if not iso:
        return None
    m = re.match(r"([+-])(\d{1,4})-", iso)
    if not m:
        return None
    return -int(m.group(2)) if m.group(1) == "-" else int(m.group(2))


def entities(qids, props, want_sitelinks=None):
    """wbgetentities for any number of ids, 50 per request."""
    out = {}
    for i in range(0, len(qids), 50):
        q = {"action": "wbgetentities", "format": "json", "props": props,
             "languages": "en", "ids": "|".join(qids[i:i + 50])}
        if want_sitelinks:
            q["sitefilter"] = "enwiki"
        req = urllib.request.Request(WD_API + "?" + urllib.parse.urlencode(q),
                                     headers={"User-Agent": UA})
        out.update(json.load(urllib.request.urlopen(req, timeout=90)).get("entities", {}))
    return out


def best_claims(entity, prop):
    """Claims for `prop`, deprecated dropped and preferred rank winning.

    Reading claims[0] blindly is how the info panel once had Canaletto dying in
    1758 — that value was tagged deprecated and sitting first.
    """
    claims = [c for c in entity.get("claims", {}).get(prop, [])
              if c.get("rank") != "deprecated"]
    return [c for c in claims if c.get("rank") == "preferred"] or claims


def snak_value(claim):
    """None when the snak is 'somevalue'/'novalue' — Wikidata for anonymous."""
    snak = claim.get("mainsnak", {})
    if snak.get("snaktype") != "value":
        return None
    return snak.get("datavalue", {}).get("value")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true")
    a = ap.parse_args()

    with open(MANIFEST, encoding="utf-8") as fh:
        raw = fh.read()
    manifest = json.loads(raw)
    if encode(manifest) != raw:
        sys.exit("encode() no longer round-trips the manifest — refusing to write")

    works = manifest["works"]
    unknown = [w for w in works if w["artist"] == "Unknown" and w.get("wikidata")]
    print(f"Unknown artists with a QID: {len(unknown)} "
          f"(of {sum(1 for w in works if w['artist'] == 'Unknown')} total)")

    # Pass 1: every work in the manifest, for creator + inception.
    all_qids = sorted({w["wikidata"] for w in works if w.get("wikidata")})
    print(f"fetching {len(all_qids)} work items…")
    work_ents = entities(all_qids, "claims")

    # Anonymity is tracked in its own set rather than as a sentinel string in
    # creator_of: a str sentinel is iterable, so building the creator list with
    # a set comprehension silently spread "__anon__" into '_','a','n','o' and
    # poisoned the whole API batch.
    creator_of, anonymous_of, inception_of, span_of = {}, set(), {}, {}
    # Year implied by a *millennium*-precision P571 (precision 6) — 1000, 2000.
    # Not a date at all, so a manifest year equal to it is a leaked precision
    # code rather than a disagreement about dating.
    #
    # Deliberately millennium only. Extending this to century and decade
    # precision matched 105 works, because a decade value like +1470 is a
    # perfectly serviceable approximation that the manifest already uses — and
    # "correcting" those against some other claim moved Madonna of Chancellor
    # Rolin from 1500 to 1400. Second-guessing a rough date is not this
    # script's job; catching a number that cannot be a date is.
    vague_of = {}
    for qid, ent in work_ents.items():
        creators = []
        for c in best_claims(ent, "P170"):
            v = snak_value(c)
            if v is None:
                anonymous_of.add(qid)      # "unknown value" — no author on record
            elif isinstance(v, dict) and v.get("id"):
                creators.append(v["id"])
        creator_of[qid] = sorted(set(creators))
        # Precision 9 is "year"; 6/7/8 are millennium/century/decade. Wikidata
        # encodes "2nd millennium" as +2000-00-00 at precision 6, so a naive
        # read turns Bruegel into a work of the year 2000 — which is how the
        # manifest got there. Ranks alone are not enough to dodge this:
        # Carracci's Triumph has the useless millennium at *preferred* rank and
        # the real 1586 at normal.
        p571 = best_claims(ent, "P571") + [c for c in ent.get("claims", {}).get("P571", [])
                                          if c.get("rank") == "normal"]
        for c in p571:
            v = snak_value(c)
            if isinstance(v, dict) and v.get("time") and (v.get("precision") or 99) <= 6:
                vague_of[qid] = year_of(v["time"])
                break
        for c in p571:
            v = snak_value(c)
            if isinstance(v, dict) and v.get("time") and (v.get("precision") or 0) >= 9:
                inception_of[qid] = year_of(v["time"])
                break
        else:
            # No year-precise main value, but a vague inception often carries
            # P580/P582 (start/end time) qualifiers that are year-precise —
            # Bruegel's Icarus is "+1500 (millennium)" qualified 1582–1625.
            for c in p571:
                quals = c.get("qualifiers", {})
                span = []
                for prop in ("P580", "P582"):
                    for q in quals.get(prop, []):
                        v = q.get("datavalue", {}).get("value", {})
                        if isinstance(v, dict) and (v.get("precision") or 0) >= 9:
                            span.append(year_of(v["time"]))
                if span:
                    inception_of[qid] = min(span)
                    span_of[qid] = (min(span), max(span))
                    break

    # Pass 2: names and life dates for the creators we need to name.
    need = sorted({c for w in unknown for c in creator_of.get(w["wikidata"], [])})
    print(f"fetching {len(need)} creator items…")
    people = entities(need, "labels|claims|sitelinks/urls", need) if need else {}

    def person(qid):
        e = people.get(qid, {})
        label = e.get("labels", {}).get("en", {}).get("value")
        if not label:
            # Wikidata items can carry thirty labels and no English one —
            # Q155626 is John Singer Sargent in Arabic, Hebrew and Hindi but
            # nothing in en. That gap is the whole reason these rows shipped as
            # "Unknown". The English Wikipedia article title is the same name,
            # minus the odd " (painter)" disambiguator.
            title = e.get("sitelinks", {}).get("enwiki", {}).get("title")
            label = re.sub(r"\s*\([^)]*\)$", "", title) if title else None
        def yr(prop):
            for c in best_claims(e, prop):
                v = snak_value(c)
                if isinstance(v, dict) and v.get("time"):
                    return year_of(v["time"])
            return None
        return label, yr("P569"), yr("P570")

    named, anon, unresolved, ambiguous = [], [], [], []
    for w in unknown:
        cs = creator_of.get(w["wikidata"])
        if not cs:
            anon.append(w)
        elif len(cs) > 1:
            ambiguous.append((w, [person(c)[0] or c for c in cs]))
        else:
            label, birth, death = person(cs[0])
            (named.append((w, (label, birth, death))) if label
             else unresolved.append(w))

    # Inception sanity across the whole manifest: a year a century off its
    # Wikidata inception is a data fault, not a dating dispute.
    # Correct a year when it is wildly out, *or* when it exactly equals the
    # year a vague P571 would produce — the second test is what catches a
    # leaked precision code that happens to land close to the real date. Monet's
    # Waterloo Bridge shipped as "2000" against a real 1903: a 97-year gap, just
    # inside any sane "wildly out" threshold, and invisible to it.
    def needs_date_fix(w):
        qid = w.get("wikidata")
        inc = inception_of.get(qid)
        if inc is None or w.get("year") is None:
            return False
        return abs(w["year"] - inc) > 100 or w["year"] == vague_of.get(qid)

    dates = [(w, inception_of[w["wikidata"]]) for w in works if needs_date_fix(w)]

    # A year on a millennium boundary that nothing year-precise corroborates is
    # almost certainly a precision code that leaked through as a date.
    suspect = [w for w in works
               if w.get("year") and w["year"] % 1000 == 0
               and inception_of.get(w.get("wikidata")) is None]

    print(f"\nnamed creator ({len(named)}):")
    for w, (name, birth, death) in sorted(named, key=lambda x: (x[1][0], x[0]["title"])):
        print(f"  {name:<26} {str(w.get('year')):>5}  {w['title'][:44]}")
    print(f"\nno author on record, left as Unknown ({len(anon)}):")
    for w in anon:
        print(f"  {str(w.get('year')):>5}  {w['title'][:52]}")
    if unresolved:
        print(f"\ncreator item with no English label, left alone ({len(unresolved)}):")
        for w in unresolved:
            print(f"  {str(w.get('year')):>5}  {w['title'][:52]}")
    if ambiguous:
        print(f"\nmultiple creators, left alone ({len(ambiguous)}):")
        for w, names in ambiguous:
            print(f"  {w['title'][:38]:<39} {', '.join(names)}")
    if dates:
        print(f"\nyear disagrees with Wikidata inception by >100 ({len(dates)}):")
        for w, inc in dates:
            print(f"  {w['title'][:42]:<43} {w['artist'][:18]:<19} {w['year']} -> {inc}")
    if suspect:
        print(f"\nyear on a millennium boundary with no year-precise source "
              f"({len(suspect)}) — needs a human date, not left as-is:")
        for w in suspect:
            print(f"  {w['year']}  {w['artist'][:20]:<21} {w['title'][:44]}")

    for w, (name, birth, death) in named:
        w["artist"] = name
        w["artistSort"] = sort_name(name)
        if birth is not None:
            w["artistBirthYear"] = birth
        if death is not None:
            w["artistDeathYear"] = death
    for w, inc in dates:
        w["year"] = inc
        span = span_of.get(w.get("wikidata"))
        # An en dash, matching how the manifest already renders date ranges.
        w["dateDisplay"] = (f"{span[0]}–{span[1]}" if span and span[0] != span[1]
                            else str(inc))

    if not a.apply:
        print("\n(dry run — pass --apply to write)")
        return
    with open(MANIFEST, "w", encoding="utf-8") as fh:
        fh.write(encode(manifest))
    print(f"\nwrote {MANIFEST}")


if __name__ == "__main__":
    main()
