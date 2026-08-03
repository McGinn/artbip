# Artwork info feature — design

Give every work an optional "About this work" body: accurate, insightful,
and sourced. Three tiers, degrading gracefully when sources are thin.

## Tiers

1. **Titleplate** — what a gallery wall label states: artist (with dates),
   title, date, medium, dimensions, collection. Mostly already in the
   manifest; the gaps (medium 385/2000, dimensions 0/2000, artist birth
   years 0/2000) are fillable mechanically from Wikidata/museum APIs — a
   future `curate enrich` pass, no LLM involved.
2. **Context** — why the work matters: commission and audience, what was
   happening around it, how it was and is read.
3. **Details** — specific things to look at in the picture. The highest
   misinterpretation risk, so the strictest sourcing bar.

## Accuracy rules (the point of the feature)

- **No claim from model memory.** Every tier-2/3 statement must be
  traceable to a source consulted at writing time: the local reference
  corpus (a curated shelf of art-history books, kept outside the repo at
  `../reference/`), a museum's own object page / catalogue, or a
  scholarly web source (e.g. Smarthistory, NGA Online Editions).
- **Facts and ideas, never prose.** Source texts ground and check claims;
  wording in `info.json` is original. Attribution of *interpretive* claims
  is by name in the text ("Schama reads the…") when the idea is one
  scholar's, silent for uncontested fact.
- **Per-claim citations in data.** Each context/details paragraph carries
  `cite` entries — `book:<slug>:<page>` (page = PDF page of the edition in
  the corpus index) or `url:<https://…>`. The UI shows a Sources line;
  the citation trail is also what makes entries checkable and fixable.
- **Thin sources → shorter entry.** A work with no usable sources gets no
  tier-2/3 text at all (titleplate always renders from the manifest).
  Silence over plausible invention, always.

## Data model — `data/info.json`

```json
{
  "schemaVersion": 1,
  "sources": {
    "hagen-what-great-paintings-say-2": {
      "title": "What Great Paintings Say, Vol. 2",
      "author": "Rose-Marie & Rainer Hagen", "year": 2003, "kind": "book"
    }
  },
  "entries": {
    "wikidata-Q45585": {
      "context": [
        {"text": "…", "cite": ["book:gombrich-story-of-art:436"]}
      ],
      "details": [
        {"text": "…", "cite": ["book:hagen-what-great-paintings-say-2:212",
                                "url:https://www.rijksmuseum.nl/en/collection/SK-C-5"]}
      ],
      "generated": {"model": "claude-fable-5", "date": "2026-08-02"}
    }
  }
}
```

Separate file, not manifest fields: the manifest stays the curation
artifact; info.json is a content artifact with its own lifecycle, merged
by id at load. Missing file or missing entry are both fine.

## Generation pipeline

Per the project's locked LLM policy, generation runs **in Claude Code
sessions on the user's subscription** (like the 4,653-work scoring run),
in user-paced waves:

1. Retrieval: `reference/tools/refsearch.py` (FTS5 over the corpus)
   plus the work's museum page and Wikipedia article.
2. Writing: agent drafts entry from retrieved passages only; anything it
   cannot ground, it drops.
3. Verification: a second pass re-opens each citation and checks the
   claim against it; failed claims are cut or re-cited.

`data/info.json` is committed after each wave — durable like
`scores.json`; re-runs are incremental (skip ids already present).

## Surfaces

- **App**: "About this work" — detail pane in the gallery window
  (selected work) and a menu-bar item for the current wallpaper. Tier 1
  from the manifest always; context/details when an entry exists;
  sources listed at the bottom.
- **CLI**: `artbip info [--id <workId>]` — current work by default.

## Non-goals

- Reproducing source text (copyright; also just not the register we want).
- Shipping the reference corpus or its tooling in this repo.
- Blocking the feature on tier-1 enrichment; it lands separately.
