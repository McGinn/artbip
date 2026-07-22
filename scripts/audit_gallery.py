#!/usr/bin/env python3
"""Build a self-contained artbip review gallery: sampled manifest works with
local thumbnails embedded as base64 (downscaled via sips)."""
import json, os, base64, subprocess, tempfile, html, sys, hashlib
from collections import defaultdict

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(REPO, "work/audit-gallery.html")
SAMPLE = int(os.environ.get("SAMPLE", "96"))
PX = int(os.environ.get("PX", "440"))

man = json.load(open(os.path.join(REPO, "data/manifest.json")))
works = man["works"]
import glob as _glob
scored_total = len(_glob.glob(os.path.join(REPO, "work/scoring/results/*.json")))

# Deterministic stratified sample: bucket by source, round-robin by descending
# score within each source so the sample spans sources and the score range.
def src(w): return w["id"].split("-")[0]
bysrc = defaultdict(list)
for w in works:
    bysrc[src(w)].append(w)
for s in bysrc:
    bysrc[s].sort(key=lambda w: -(w.get("significance", {}).get("llmScore") or 0))

# interleave
order = []
idx = defaultdict(int)
srcs = sorted(bysrc, key=lambda s: -len(bysrc[s]))
while len(order) < len(works):
    progressed = False
    for s in srcs:
        i = idx[s]
        if i < len(bysrc[s]):
            order.append(bysrc[s][i]); idx[s] += 1; progressed = True
    if not progressed: break
# take an even stride across the interleaved order so we span high->low score
n = min(SAMPLE, len(order))
stride = max(1, len(order) // n)
sample = [order[i] for i in range(0, len(order), stride)][:n]

def thumb_b64(wid):
    src_path = os.path.join(REPO, f"work/scoring/thumbs/{wid}.jpg")
    if not os.path.exists(src_path):
        return None
    with tempfile.NamedTemporaryFile(suffix=".jpg", delete=False) as tf:
        tmp = tf.name
    try:
        subprocess.run(["sips", "-Z", str(PX), "-s", "formatOptions", "62",
                        src_path, "--out", tmp],
                       check=True, capture_output=True)
        data = open(tmp, "rb").read()
        return base64.b64encode(data).decode()
    except Exception:
        return None
    finally:
        try: os.remove(tmp)
        except OSError: pass

cards = []
missing = 0
for w in sample:
    b64 = thumb_b64(w["id"])
    if not b64:
        missing += 1
        continue
    sig = w.get("significance", {}) or {}
    lic = w.get("license", {}) or {}
    score = sig.get("llmScore")
    canon = sig.get("canonLists") or []
    sitelinks = sig.get("sitelinks")
    meta_bits = []
    if w.get("dateDisplay"): meta_bits.append(html.escape(str(w["dateDisplay"])))
    if w.get("medium"): meta_bits.append(html.escape(str(w["medium"])))
    chips = []
    if score is not None: chips.append(f'<span class="chip score">{score:g}</span>')
    if sitelinks: chips.append(f'<span class="chip">{sitelinks} sitelinks</span>')
    for c in canon: chips.append(f'<span class="chip canon">{html.escape(c)}</span>')
    cap = html.escape(w.get("caption") or "")
    title = html.escape(w.get("title") or "Untitled")
    artist = html.escape(w.get("artist") or "Unknown")
    coll = html.escape(w.get("collection") or "")
    src_url = html.escape(lic.get("sourceURL") or w.get("collectionURL") or "#")
    licline = html.escape(f'{lic.get("status","?")} · {lic.get("evidence","")}')
    cards.append(f"""
    <figure class="card">
      <a href="{src_url}" target="_blank" rel="noopener"><img loading="lazy" src="data:image/jpeg;base64,{b64}" alt=""></a>
      <figcaption>
        <div class="chips">{''.join(chips)}</div>
        <h3>{title}</h3>
        <p class="artist">{artist}</p>
        <p class="meta">{' · '.join(meta_bits)}</p>
        <p class="cap">{cap}</p>
        <p class="lic">{licline} · <a href="{src_url}" target="_blank" rel="noopener">source</a></p>
      </figcaption>
    </figure>""")

# score distribution across the FULL manifest (not just sample)
dist = defaultdict(int)
for w in works:
    s = (w.get("significance", {}) or {}).get("llmScore")
    if s is None: dist["n/a"] += 1
    else: dist["9-10" if s>=9 else "7-8.9" if s>=7 else "5-6.9" if s>=5 else "<5"] += 1
src_counts = defaultdict(int)
for w in works: src_counts[src(w)] += 1
dist_line = " · ".join(f"{k}: {dist[k]}" for k in ["9-10","7-8.9","5-6.9","<5","n/a"] if dist[k])
src_line = " · ".join(f"{k} {v}" for k,v in sorted(src_counts.items(), key=lambda x:-x[1]))

page = f"""<title>artbip — curation review</title>
<style>
  :root {{ --bg:#0d0e10; --card:#17181b; --fg:#eceded; --dim:#9a9ca1; --line:#2a2c31; --accent:#c9a15a; }}
  @media (prefers-color-scheme: light) {{
    :root {{ --bg:#f3f2ee; --card:#fff; --fg:#1a1a1a; --dim:#6a6a6a; --line:#e2e0d8; --accent:#9a7a34; }}
  }}
  :root[data-theme="dark"] {{ --bg:#0d0e10; --card:#17181b; --fg:#eceded; --dim:#9a9ca1; --line:#2a2c31; --accent:#c9a15a; }}
  :root[data-theme="light"] {{ --bg:#f3f2ee; --card:#fff; --fg:#1a1a1a; --dim:#6a6a6a; --line:#e2e0d8; --accent:#9a7a34; }}
  * {{ box-sizing:border-box; }}
  body {{ margin:0; background:var(--bg); color:var(--fg); font:15px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif; }}
  header {{ padding:28px 24px 18px; border-bottom:1px solid var(--line); position:sticky; top:0; background:var(--bg); z-index:2; }}
  header h1 {{ margin:0 0 6px; font-size:20px; letter-spacing:.02em; }}
  header p {{ margin:2px 0; color:var(--dim); font-size:13px; }}
  .grid {{ display:grid; grid-template-columns:repeat(auto-fill,minmax(280px,1fr)); gap:18px; padding:22px; max-width:1600px; margin:0 auto; }}
  .card {{ margin:0; background:var(--card); border:1px solid var(--line); border-radius:10px; overflow:hidden; display:flex; flex-direction:column; }}
  .card img {{ width:100%; height:300px; object-fit:contain; background:#000; display:block; }}
  figcaption {{ padding:12px 14px 14px; }}
  .chips {{ display:flex; flex-wrap:wrap; gap:5px; margin-bottom:8px; }}
  .chip {{ font-size:11px; padding:2px 8px; border-radius:99px; background:var(--line); color:var(--fg); }}
  .chip.score {{ background:var(--accent); color:#000; font-weight:600; }}
  .chip.canon {{ background:transparent; border:1px solid var(--accent); color:var(--accent); }}
  h3 {{ margin:0 0 2px; font-size:15px; font-weight:600; }}
  .artist {{ margin:0 0 6px; color:var(--fg); font-size:13px; }}
  .meta {{ margin:0 0 8px; color:var(--dim); font-size:12px; }}
  .cap {{ margin:0 0 10px; font-size:13px; color:var(--fg); }}
  .lic {{ margin:0; font-size:11px; color:var(--dim); }}
  .lic a, .artist a {{ color:var(--accent); text-decoration:none; }}
  a {{ color:var(--accent); }}
</style>
<header>
  <h1>artbip — curation preview <span style="color:var(--accent)">(Milestone 1)</span></h1>
  <p><b>{len(works)}</b> works in this manifest · sample of <b>{len(cards)}</b> shown below, interleaved across sources and spanning the score range.</p>
  <p>Sources: {src_line}</p>
  <p>Scores (full manifest): {dist_line}</p>
  <p style="color:var(--accent)">Scoring complete: all {scored_total} pool works scored on Sonnet. This manifest is the top {len(works)} after per-artist caps, score floor, and defect drops.</p>
</header>
<div class="grid">
{''.join(cards)}
</div>"""

with open(OUT, "w") as f:
    f.write(page)
print(f"wrote {OUT}  cards={len(cards)}  missing_thumbs={missing}  bytes={os.path.getsize(OUT)}")
