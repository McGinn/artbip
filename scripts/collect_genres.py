#!/usr/bin/env python3
"""Cache source genre statements for editorial tag assignment (does not approve text)."""
import json,time,urllib.request,urllib.parse
from pathlib import Path
root=Path(__file__).resolve().parents[1]
works=json.loads((root/'data/manifest.json').read_text())['works']
p=root/'work/genre-sources.json'
cache=json.loads(p.read_text()) if p.exists() else {}
qids=sorted({w['wikidata'].rsplit('/',1)[-1] for w in works if w.get('wikidata')}-cache.keys())
for start in range(0,len(qids),100):
 batch=qids[start:start+100]
 query='SELECT ?w ?genre ?genreLabel WHERE { VALUES ?w { '+' '.join('wd:'+q for q in batch)+' } ?w wdt:P136 ?genre . SERVICE wikibase:label { bd:serviceParam wikibase:language "en". } }'
 url='https://query.wikidata.org/sparql?'+urllib.parse.urlencode({'query':query,'format':'json'})
 request=urllib.request.Request(url,headers={'User-Agent':'artbip/0.1 (https://github.com/McGinn/artbip)','Accept':'application/sparql-results+json'})
 try:
  with urllib.request.urlopen(request,timeout=45) as f: rows=json.load(f)['results']['bindings']
 except Exception as e:
  print('Failed batch',start,str(e),flush=True);break
 for q in batch: cache[q]=[]
 for r in rows: cache[r['w']['value'].rsplit('/',1)[-1]].append({'id':r['genre']['value'].rsplit('/',1)[-1],'label':r['genreLabel']['value']})
 p.write_text(json.dumps(cache,ensure_ascii=False,indent=2)+'\n')
 print('Cached',len(cache),flush=True)
 time.sleep(1)
