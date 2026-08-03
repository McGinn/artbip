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
  wording in `info.json` is original.
- **The text stands on its own.** No scholar's name and no book title in the
  body — this is a wall label, not an essay, and a reader who wants the
  provenance has the Sources list two inches below. Attribution lives in the
  `cite` array, which is what makes a claim checkable; putting it in the prose
  as well only makes the label about the literature instead of the picture.
  Historical actors stay (Vasari coining *maniera*, Leroy coining
  'Impressionism') — they are the fact being reported, not an authority being
  leaned on.
- **Signal interpretation without a name.** Dropping the attribution must not
  quietly promote one scholar's reading into settled fact. Where a claim is
  genuinely contested or is one person's argument, mark it in the prose —
  "commonly read as", "now generally read against", "may be" — and let the
  citation carry the rest. Uncontested fact is stated plainly.
- **Per-claim citations in data.** Each context/details paragraph carries
  `cite` entries — `book:<slug>:<page>` (page = PDF page of the edition in
  the corpus index) or `url:<https://…>`. The UI shows a Sources line;
  the citation trail is also what makes entries checkable and fixable.
- **Thin sources → shorter entry.** A work with no usable sources gets no
  tier-2/3 text at all (titleplate always renders from the manifest).
  Silence over plausible invention, always.

## Writing rules (how it has to read)

Accuracy is necessary and not sufficient: a sourced sentence nobody can
parse has failed. The model here is Gombrich's preface — plain language
"even at the risk of sounding casual or unprofessional", because the vices
that make people distrust art writing for life are "pretentious jargon or
bogus sentiment" — and the National Gallery's own companion guide, whose
entries are self-contained and meant to work while you stand in front of
the picture.

- **Difficulty of thought yes, difficulty of language no.** Gombrich's
  distinction, and the one that matters. Do not simplify the idea; simplify
  the sentence carrying it. Anyone using scholarly register to sound
  authoritative is talking down to the reader from the clouds.
- **Say the thing, not the thing about the thing.** State what is true of
  the pictures. A claim that can only be phrased as a comment on other
  people's criteria — "the standards by which such painting looks static
  are Italian ones" — is a remark about the literature wearing a wall
  label's clothes. Rephrase it as a fact about the painting, or cut it.
- **One idea per sentence.** If the reader has to hold three clauses open
  to reach the point, split it. If a sentence needs a second reading to
  parse, it is not finished.
- **No instructions to the reader.** "Worth carrying around the room", "The
  question to put to them is…", "What makes it worth watching is…". The
  reader decides what is worth their attention; the label's job is to give
  them something to decide with.
- **Concrete before abstract.** The painter, the year, the city, the object
  come before the tendency they illustrate. Prefer a named person doing
  something to an abstract noun having a property: "critics called these
  pictures static" beats "the ordinary standards by which such painting
  looks static".
- **Plain word if one exists.** Keep a term only where the term *is* the
  subject (Mannerism, pointillism, *maniera*) — then define it in the same
  breath, as the Mannerism entry does.
- **It sits next to the picture.** Gombrich would not write about a work he
  could not show. Only one work is on screen here, so keep other paintings
  to brief orientation and never build a point on something the reader
  cannot see.

The test is mechanical: read the paragraph aloud once, at speed. Any
sentence you stumble on or have to restart gets rewritten.

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
