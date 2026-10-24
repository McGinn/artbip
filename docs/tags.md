# Gallery subject tags

Every work in `data/manifest.json` has a nonempty `tags` array. The same array is stored in `data/overrides.json`, so re-curation preserves editorial assignments. Older manifests without tags remain readable.

The initial catalogue combines Wikidata P136 genre statements with editorial classifications where those statements are missing or describe a technique instead of a subject. A private ledger (`tag-sources.json` in the editorial checkout; see `scripts/content_paths.py`) records the source, method and original genre labels for every work. Source statements are evidence for classification, not visual verification of the artwork text.

Use specific, overlapping terms where justified: a religious scene can also be a landscape; a family portrait can also be a group portrait. Do not infer a subject from an artist's usual practice or mistake an object mentioned in commentary for the painting's genre. Tags describe depicted subjects, not the identity or beliefs of a sitter.

Do not automatically turn a floral genre statement into `still-life`: flowers may be growing in a garden, as in Van Gogh's Getty *Irises*. Preserve later editorial corrections in the checked-in overrides and provenance; the initial batch importer is not a refresh command.

`nsfw` is a filter tag, not a subject: the app's **Hide NSFW artworks** setting (on by default) keeps these works out of rotation and the gallery. Give it to works whose image prominently shows adult nudity (bare breasts or genitals), sexual activity or sexual assault, or graphic violence: visible gore, severed heads or limbs, flaying or torture. Do not give it for infants and putti, a bare male chest, a loincloth Christ or ordinary Crucifixion and Lamentation imagery, small distant figures, a modestly draped figure, battles without close-up gore, or violence that is only implied. Decide from the pinned image, not the title, and record the reason in the tag ledger like any other tag.

The controlled vocabulary is in `scripts/check_tags.py`. Add new terms deliberately, with useful distinctions for browsing. Run `python3 scripts/check_tags.py` after changing the catalogue; packaging requires all works to have valid tags, matching durable overrides and provenance.

Gallery search accepts multiple words across fields, so `Monet landscape` combines artist and subject. Names are case- and accent-insensitive. Common plural queries such as `portraits`, `landscapes` and `flowers` work, as do `still life` and `still-life`. Existing title, artist, movement, region and collection searches remain available.
