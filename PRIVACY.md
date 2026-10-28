# artbip privacy policy

**Last updated:** 28 October 2026. Applies from artbip 0.1.0.

artbip is a free, open-source Mac app made by Alexander McGinn. This policy
explains what it does with information about you. The short version: **artbip
does not collect, store or share any personal information.** There is no
artbip account, no artbip server, no analytics, no advertising, no crash
reporting and no tracking of any kind.

Everything below can be checked against the source code in this repository.

## What artbip collects

Nothing. artbip does not send the developer, or anyone else, any information
about you, your Mac, or how you use the app. It asks for no special
permissions: not your location, contacts, photos, camera, microphone or
files.

## Network connections

artbip connects to the internet for two things only.

### 1. Downloading artwork images

To show a painting, artbip downloads its image directly from the server that
hosts it:

- Wikimedia Commons (`commons.wikimedia.org` and its image servers)
- The Metropolitan Museum of Art (`images.metmuseum.org`)
- National Gallery of Art, Washington (`api.nga.gov`)
- Rijksmuseum, through its image service (`iiif.micr.io`)
- Art Institute of Chicago (`www.artic.edu`)
- Cleveland Museum of Art (`openaccess-cdn.clevelandart.org`)

It downloads the work being shown, the next three in the queue, and
thumbnails for the works you scroll past in the gallery. Requests identify
themselves as artbip with a link to this repository (the User-Agent header),
except for the Met and the Art Institute of Chicago, whose servers block
non-browser requests, so artbip sends a standard browser User-Agent there
(and, for the Art Institute, an extra header naming artbip, as that museum
asks). artbip keeps no cookies from these servers, and the requests contain
no information about you beyond what every internet request carries: your IP address and basic
request headers.

Like any web server, these hosts can see that IP address and which image was
requested. Their own privacy policies govern what they do with that.

### 2. Checking for a new version

When artbip starts, at most once every 24 hours, it asks GitHub's public API
(`api.github.com`) whether a newer release of artbip exists. The request
contains no information about you or your usage, only what any HTTPS request
carries (your IP address and a User-Agent naming artbip). If there is a new
version, artbip shows a link to its release page; it never downloads or
installs anything by itself.

You can turn this off in **Settings → Updates → Check for new versions**. It
is on by default so that corrections to the collection reach you.
**Check Now** checks immediately, and the command-line `artbip update`
checks whenever you run it, whatever the setting.

A version of artbip distributed through the Mac App Store would not perform
this check; updates there come through the App Store.

### Links you choose to open

Some menu items open a page in your web browser: the work's page at its
museum, the GitHub release page, GitHub Sponsors, and the GitHub issue forms
described below. Those pages are visited by your browser, under the
website's own privacy policy, just as if you had typed the address.

## Reporting a problem or requesting a feature

**Report a Problem…** and **Request a Feature…** open a GitHub issue form in
your browser, pre-filled with details to help fix the problem. For an artwork
report these are the work's id, title, artist, holding collection, source
link and Wikidata id, plus your artbip version and macOS version. A feature
request is pre-filled with your artbip version only.

**Nothing is sent when you choose the menu item.** You can read and edit the
form, and nothing leaves your Mac unless you submit it on GitHub. If you do,
the issue is posted publicly under your GitHub account, and GitHub's
[privacy statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement)
applies.

## Information stored on your Mac

artbip keeps its data in `~/Library/Application Support/artbip`. None of it
is sent anywhere.

| File | Contents |
|---|---|
| `settings.json` | Your settings: schedule, background, label, margin, shortcuts, storage limit and so on. |
| `state.json` | Your favourites, blocked works and collections, and the last 500 works shown with the time each appeared. |
| `original-wallpaper.json` | The file paths of the wallpaper you had before artbip, so it can be restored. These paths may include your macOS user name. |
| `scheduler.json` | Timings and errors from recent rotations, used for troubleshooting. |
| `cache/` | Downloaded images and thumbnails, limited to 2 GB by default. Clear it in **Settings → Clear Downloads**. |
| `wallpapers/` | The composed wallpaper images set on your desktop. |

artbip also writes routine diagnostic messages to macOS's own system log on
your Mac. These are not sent anywhere by artbip.

**Launch at Login** is off until you turn it on.

To remove everything, quit artbip, delete the app, and delete the folder
above.

## Sponsorship

The **Sponsor artbip** link opens
[GitHub Sponsors](https://github.com/sponsors/McGinn). Sponsorship is handled
entirely by GitHub under its own privacy statement, unlocks nothing in the
app, and is never linked to your copy of artbip.

## Children

artbip collects no information from anyone, including children.

## Security

The direct download is signed with a Developer ID, notarized by Apple and
runs with the hardened runtime.

## Changes to this policy

If artbip's handling of information changes, this file will be updated
before the release that makes the change, and the date at the top will
change. The history of this file is public in the repository.

## Contact

Questions about privacy can be sent privately to
[contact@artbip.app](mailto:contact@artbip.app), or asked in public by
[opening an issue](https://github.com/McGinn/artbip/issues/new) on GitHub.
Issues are public, so please don't include anything you want to keep private
there.
