#!/usr/bin/env python3
"""Repair manifest rows that Wikidata already knows better.

Two faults, both from the same 2026-07-14 gather:

  * Artist "Unknown" on works whose creator Wikidata names. The band query in
    WikidataSource sampled the creator's label and death year independently, so
    a work could arrive carrying the death year and no name; the pipeline then
    wrote "Unknown". 173 candidates were affected, 22 reached the manifest —
    thirteen of them Poussins. The source is fixed (see fetchCreatorInfo); this
    repairs the rows already shipped.
  * collectionURL pointing at wikidata.org. "View at Museo del Prado" opening
    Wikidata is not what the label promises. P973 (described at URL) carries
    the museum's own object page for many works.

Only single-creator works are re-attributed: a collaboration or a disputed
attribution is left alone. Wikidata blank nodes (`.well-known/genid/...`) mean
*anonymous* and are treated as the "Unknown" they already are.

usage: python3 scripts/repair_from_wikidata.py [--apply]
"""
import argparse, json, os, re, sys, urllib.parse

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST = os.path.join(HERE, "data/manifest.json")


def encode(obj):
    """Match Swift's JSONEncoder output — see scripts/enrich_wikidata.py."""
    text = json.dumps(obj, ensure_ascii=False, indent=2,
                      sort_keys=True, separators=(",", " : "))
    return re.sub(r"^([ ]*)(\".*?\" : )\[\](,?)$",
                  lambda m: f"{m.group(1)}{m.group(2)}[\n\n{m.group(1)}]{m.group(3)}",
                  text, flags=re.M)


def host_of(url):
    return urllib.parse.urlparse(url).netloc.lower().removeprefix("www.")


# A link labelled "View at the Louvre" must open the Louvre. P973 is "described
# at URL", not "the museum's page", and it happily offers a BBC radio programme
# for an Art Institute work, a Sotheby's listing, an Instagram post, and
# tate.org.uk for a National Gallery painting. So each collection allows only
# its own domains; everything else keeps the Wikidata link, which is at least
# honest about where it goes.
CANONICAL_HOSTS = {
    "Department of Paintings of the Louvre": {"louvre.fr", "collections.louvre.fr"},
    "Van Gogh Museum":            {"vangoghmuseum.nl", "catalogues.vangoghmuseum.com"},
    "Musée d'Orsay":              {"musee-orsay.fr"},
    "Uffizi Gallery":             {"uffizi.it", "catalogo.uffizi.it"},
    "Gallerie dell'Accademia":    {"gallerieaccademia.it"},
    "Mauritshuis":                {"mauritshuis.nl"},
    "The Frick Collection":       {"collections.frick.org", "frick.org"},
    "Museo del Prado":            {"museodelprado.es"},
    "Royal Museums of Fine Arts of Belgium": {"fine-arts-museum.be"},
    "Thyssen-Bornemisza Museum":  {"museothyssen.org"},
    "Pinacoteca di Brera":        {"pinacotecabrera.org", "dipinti.galleriapinacotecabrera.it"},
    "Tate":                       {"tate.org.uk"},
    "Kröller-Müller Museum":      {"krollermuller.nl", "kmm.nl"},
    "Gemäldegalerie Berlin":      {"smb-digital.de", "smb.museum-digital.de"},
    "Groeningemuseum":            {"artinflanders.be", "erfgoedbrugge.be"},
    "Rijksmuseum":                {"rijksmuseum.nl"},
    "National Gallery of Art":    {"nga.gov"},
    "Metropolitan Museum of Art": {"metmuseum.org"},
    "Art Institute of Chicago":   {"artic.edu"},
    "Cleveland Museum of Art":    {"clevelandart.org"},
    "Museum of Fine Arts, Budapest": {"mfab.hu"},
    "Toledo Museum of Art":       {"emuseum.toledomuseum.org", "toledomuseum.org"},
    "Isabella Stewart Gardner Museum": {"gardnermuseum.org"},
    "Borghese Collection":        {"collezionegalleriaborghese.it"},
    "Russian Museum":             {"rusmuseumvrm.ru"},
    "Nationalmuseum":             {"nationalmuseum.se"},
    "Statens Museum for Kunst":   {"smk.dk"},
    "Museo Nacional de Arte":     {"munal.mx"},
    "Alte Pinakothek":            {"sammlung.pinakothek.de"},
    "Kunsthistorisches Museum":   {"khm.at"},
    "National Gallery of Denmark": {"smk.dk"},
    "Museum Boijmans Van Beuningen": {"boijmans.nl"},
    "Städel Museum":              {"staedelmuseum.de", "sammlung.staedelmuseum.de"},
}


def sort_name(name):
    """'Nicolas Poussin' -> 'Poussin, Nicolas', matching the manifest's key."""
    parts = name.split()
    if len(parts) < 2:
        return name
    return f"{parts[-1]}, {' '.join(parts[:-1])}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--gaps", default=None, help="gaps.json from the audit pass")
    a = ap.parse_args()

    gaps_path = a.gaps or os.path.join(HERE, "work/wikidata-gaps.json")
    if not os.path.exists(gaps_path):
        sys.exit(f"no gaps file at {gaps_path} — run the audit first")
    gaps = json.load(open(gaps_path, encoding="utf-8"))
    # Verified dead links, recorded by the link check. Nearly a fifth of the
    # museum URLs Wikidata offers are stale -- the Louvre moved its object
    # pages to collections.louvre.fr and left the old paths 404ing.
    dead_path = os.path.join(HERE, "work/dead-urls.json")
    dead_urls = set(json.load(open(dead_path, encoding="utf-8"))) if os.path.exists(dead_path) else set()
    if dead_urls:
        print(f"excluding {len(dead_urls)} URLs verified dead")

    original = open(MANIFEST, encoding="utf-8").read()
    manifest = json.loads(original)
    if encode(manifest) != original:
        sys.exit("encode() no longer round-trips the manifest — refusing to write")
    by_id = {w["id"]: w for w in manifest["works"]}

    fixed_artist = fixed_url = 0
    for g in gaps["artist"]:
        # Blank nodes are Wikidata for "anonymous"; they stay Unknown.
        if not g["creatorQid"].startswith("Q") or "genid" in g["creator"]:
            continue
        w = by_id.get(g["id"])
        if not w or w["artist"] != "Unknown":
            continue
        w["artist"] = g["creator"]
        w["artistSort"] = sort_name(g["creator"])
        fixed_artist += 1

    for g in gaps["url"]:
        w = by_id.get(g["id"])
        if not w or "wikidata.org" not in w.get("collectionURL", ""):
            continue
        allowed = CANONICAL_HOSTS.get(w["collection"])
        if not allowed:
            continue
        cands = [u for u in g["candidates"] if u.startswith("http")
                 and host_of(u) in allowed and u not in dead_urls
                 # Language-prefixed paths are the old Louvre CMS and mostly
                 # 404 now; a bare or /en/ path is the safer pick.
                 and not re.search(r"/(zh|jp|ja|ko|ar|pt)/", u)]
        if not cands:
            continue
        w["collectionURL"] = sorted(cands, key=len)[0]
        fixed_url += 1

    print(f"artists re-attributed : {fixed_artist}")
    print(f"collection links fixed: {fixed_url}")
    remaining = sum(1 for w in manifest["works"] if "wikidata.org" in w.get("collectionURL", ""))
    unknown = sum(1 for w in manifest["works"] if w["artist"] == "Unknown")
    print(f"\nstill wikidata.org    : {remaining}/{len(manifest['works'])}")
    print(f"still Unknown artist  : {unknown}")

    if a.apply:
        with open(MANIFEST, "w", encoding="utf-8") as fh:
            fh.write(encode(manifest))
        print(f"\nwrote {MANIFEST}")
    else:
        print("\n(dry run — pass --apply to write)")


if __name__ == "__main__":
    main()
