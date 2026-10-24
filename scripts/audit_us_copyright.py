#!/usr/bin/env python3
"""Flag works that are public domain abroad but possibly not in the US.

Commons policy asks for PD in both the US and the source country, but the tags
do drift, and the drift is invisible until you read the rationale. Now that
`license.evidence` records the actual templates (see
capture_license_evidence.py), the gap is checkable: a work whose only rationale
is `PD-old-70` is a statement about the author's country, not about the US.

For anything published before 1929 this does not matter — US copyright on those
has expired outright, whatever else is true. From 1929 on it matters a lot, and
those are exactly the works whose estates still have lawyers.

This reports; it does not delete. Removing a work changes the collection size,
which is a claim on the landing page, so that stays a human decision.

usage: python3 scripts/audit_us_copyright.py
"""
import datetime
import json
import os

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST = os.path.join(HERE, "data/manifest.json")

# US copyright expires 95 years after publication, so anything published before
# this year is unambiguously free in the US regardless of source-country terms.
US_EXPIRY_CUTOFF = 1929

# Templates that say something about *US* status specifically.
US_RATIONALES = (
    "pd-us",              # PD-US, PD-US-expired, PD-US-no notice, PD-US-not renewed
    "pd-1996",            # not restored by the URAA
    "pd-old-x-1964", "pd-old-auto-1964", "pd-1964",   # renewal not filed
    "pd-old-x-1996", "pd-old-auto-1996",
    "pd-russia-1996",
    "pd-old-100-1923", "pd-art-old-100-1923",
    "cc0", "cc-zero",
)


def us_tags(evidence, year, this_year):
    """US-specific rationales in `evidence`, with "-expired" claims checked.

    Commons' `-expired` variants (PD-old-auto-expired, PD-old-X-expired) assert
    that US copyright has run out as well as the source country's. That is an
    arithmetic claim, so verify it instead of trusting it: US term is 95 years
    from publication. Matisse's *La Blouse Roumaine* (1940) carries the expired
    tag and does not reach US expiry until 2035 — the tag is simply wrong, and
    template-name matching alone would have waved it through.
    """
    body = evidence.split(":", 1)[-1]
    out = []
    for t in body.split("+"):
        low = t.lower()
        if low.endswith("-expired"):
            if year is not None and year + 95 < this_year:
                out.append(t)
        elif any(low.startswith(p) for p in US_RATIONALES):
            out.append(t)
    return out


def main():
    this_year = datetime.date.today().year
    works = json.load(open(MANIFEST, encoding="utf-8"))["works"]
    late = [w for w in works if (w.get("year") or 0) >= US_EXPIRY_CUTOFF]

    ok, exposed = [], []
    for w in late:
        ev = w["license"]["evidence"]
        # A museum's own PD/CC0 flag is a US institution's own determination
        # about its own holding — that is the strongest evidence available.
        if not ev.startswith("commons:"):
            ok.append((w, ev))
            continue
        tags = us_tags(ev, w.get("year"), this_year)
        (ok.append((w, "+".join(tags))) if tags else exposed.append((w, ev)))

    print(f"works dated {US_EXPIRY_CUTOFF}+: {len(late)} of {len(works)}")
    print(f"  carrying a US-specific rationale: {len(ok)}")
    print(f"  source-country rationale only:    {len(exposed)}\n")

    if exposed:
        print("EXPOSED — public domain where the artist died, not demonstrably in the US:")
        for w, ev in sorted(exposed, key=lambda x: x[0]["year"]):
            death = w.get("artistDeathYear")
            print(f"  {w['year']}  {w['artist'][:22]:<23} {w['title'][:34]:<35} "
                  f"d.{death or '?'}  {ev.split(':', 1)[-1]}")
        print("\n  US copyright on a work published in these years runs 95 years from"
              f"\n  publication — to {min(w['year'] for w, _ in exposed) + 95} at the earliest for this set.")

    print("\nCLEARED (US rationale on record):")
    for w, tags in sorted(ok, key=lambda x: x[0]["year"]):
        print(f"  {w['year']}  {w['artist'][:22]:<23} {w['title'][:34]:<35} {tags}")


if __name__ == "__main__":
    main()
