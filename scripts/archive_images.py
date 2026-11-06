#!/usr/bin/env python3
"""Keep a private backup of every image artbip downloads, and check the live links.

    archive_images.py DEST [--push]   download new or changed images into DEST, a git
                                      clone; with --push, commit and push about every 400 MB
    archive_images.py DEST --check    re-request every live link and write DEST/link-report.json;
                                      exits 1 if any link is dead
    archive_images.py DEST --verify   before a release: download every live image and compare its
                                      bytes with what the manifest expects, writing
                                      DEST/hash-report.json; exits 1 if a picture changed or is gone

DEST holds images/<work id>.<ext> plus index.json, which records the source URL, licence,
holding collection, sha256 and fetch date of each image. The bytes are the ones the app
fetches (work.image.url), so a restored file is a drop-in replacement. Withheld works are
archived too, since they can return. Runs are resumable: an image is fetched again only if
its URL changed, it was never archived, or its file on disk is damaged. A file a sparse clone
leaves out is not missing.

--verify holds on to nothing but the report, and asks as artbip, never as a browser, so AIC
(which refuses scripts) is reported as unchecked rather than asked. A file whose bytes differ
is compared with the archived copy by its decoded pixels: `metadata` is the same picture in new
bytes (the Met has been stripping metadata), `picture` is a different one and needs a person.
"""
import argparse,datetime,hashlib,json,subprocess,sys,tempfile,time,urllib.error,urllib.parse,urllib.request
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
BROWSER_UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36'
POLITE_UA='artbip/0.1 (https://github.com/mcginn/artbip) image-archive'
IMAGE_ACCEPT='image/avif,image/webp,image/png,image/jpeg,*/*'
# Same per-host headers as Http.hostHeaders in ArtbipCore.
HOST_HEADERS={
    'www.artic.edu':{'User-Agent':BROWSER_UA,'AIC-User-Agent':'artbip/0.1 (https://github.com/mcginn/artbip)','Accept':IMAGE_ACCEPT,'Referer':'https://www.artic.edu/'},
    'images.metmuseum.org':{'User-Agent':BROWSER_UA,'Accept':IMAGE_ACCEPT},
}
INTERVAL=0.5
PUSH_BYTES=400_000_000
MAGIC={b'\xff\xd8\xff':'jpg',b'\x89PNG':'png',b'II*\x00':'tif',b'MM\x00*':'tif',b'GIF8':'gif'}

def kind(data):
    for magic,ext in MAGIC.items():
        if data.startswith(magic): return ext
    if data[:4]==b'RIFF' and data[8:12]==b'WEBP': return 'webp'

def works():
    shipped=json.loads((ROOT/'data/manifest.json').read_text())['works']
    withheld=json.loads((ROOT/'data/withheld-works.json').read_text())['works']
    return [(w,False) for w in shipped]+[(w,True) for w in withheld]

last={}
def get(url,head_only=False,polite=False):
    host=urllib.parse.urlsplit(url).hostname
    wait=INTERVAL-(time.monotonic()-last.get(host,0))
    if wait>0: time.sleep(wait)
    headers={'User-Agent':POLITE_UA,**({} if polite else HOST_HEADERS.get(host,{}))}
    if head_only: headers['Range']='bytes=0-1023'
    try:
        with urllib.request.urlopen(urllib.request.Request(url,headers=headers),timeout=120) as r:
            return r.status,r.read()
    except urllib.error.HTTPError as e:
        return e.code,b''
    except Exception as e:
        return None,repr(e).encode()
    finally:
        last[host]=time.monotonic()

def git(dest,*args):
    subprocess.run(['git','-C',str(dest),*args],check=True)

def save_index(dest,index):
    (dest/'index.json').write_text(json.dumps(dict(sorted(index.items())),indent=1,ensure_ascii=False)+'\n')

def commit(dest,index,message,push):
    save_index(dest,index)
    git(dest,'add','-A','--sparse','images','index.json')
    if subprocess.run(['git','-C',str(dest),'diff','--cached','--quiet']).returncode:
        git(dest,'commit','-q','-m',message)
        # A dropped push only delays the backup: the next push carries these commits.
        for attempt in range(3 if push else 0):
            if subprocess.run(['git','-C',str(dest),'-c','http.postBuffer=524288000','push','-q','origin','HEAD']).returncode==0: break
            print(f'push failed (attempt {attempt+1}/3)',flush=True);time.sleep(30)

def archive(dest,push):
    (dest/'images').mkdir(exist_ok=True)
    path=dest/'index.json'
    index=json.loads(path.read_text()) if path.exists() else {}
    pending=0;fetched=0;failed=[]
    tracked=set(subprocess.run(['git','-C',str(dest),'ls-files','images'],capture_output=True,text=True).stdout.splitlines())
    todo=[(w,h) for w,h in works()]
    for n,(w,withheld) in enumerate(todo,1):
        wid=w['id'];url=w['image']['url'];entry=index.get(wid)
        if entry and entry['url']==url:
            file=dest/entry['file']
            if not file.exists() and entry['file'] in tracked: continue
            if file.exists() and hashlib.sha256(file.read_bytes()).hexdigest()==entry['sha256']: continue
        status,data=get(url)
        ext=kind(data) if status==200 else None
        if not ext:
            failed.append((wid,status,url));print(f'[{n}/{len(todo)}] {wid}: FAILED ({status or data.decode()[:80]})',flush=True);continue
        if entry and entry['file']!=f'images/{wid}.{ext}': (dest/entry['file']).unlink(missing_ok=True)
        (dest/'images'/f'{wid}.{ext}').write_bytes(data)
        index[wid]={'file':f'images/{wid}.{ext}','url':url,'sha256':hashlib.sha256(data).hexdigest(),'bytes':len(data),
                    'fetched':datetime.date.today().isoformat(),'title':w.get('title'),'artist':w.get('artist'),
                    'collection':w.get('collection'),'collectionURL':w.get('collectionURL'),'license':w.get('license'),
                    'withheld':withheld}
        fetched+=1;pending+=len(data)
        print(f'[{n}/{len(todo)}] {wid}: {len(data)/1e6:.1f} MB',flush=True)
        if pending>=PUSH_BYTES:
            commit(dest,index,f'Archive {fetched} images (to {wid})',push);pending=0
    commit(dest,index,f'Archive images: {fetched} fetched this run, {len(index)} total',push)
    print(f'{fetched} fetched, {len(index)} archived, {len(failed)} failed')
    for wid,status,url in failed: print(f'  {wid} {status} {url}')
    return 1 if failed else 0

def check(dest):
    dead=[]
    for w,withheld in works():
        status,data=get(w['image']['url'],head_only=True)
        if status not in (200,206) or not kind(data):
            dead.append({'id':w['id'],'title':w.get('title'),'status':status,'url':w['image']['url'],'withheld':withheld})
            print(f"{w['id']}: {status} {w['image']['url']}",flush=True)
    report={'checked':datetime.datetime.now().isoformat(timespec='seconds'),'dead':dead}
    (dest/'link-report.json').write_text(json.dumps(report,indent=1,ensure_ascii=False)+'\n')
    print(f'{len(dead)} dead links' if dead else 'All image links are live.')
    return 1 if dead else 0

def pixels(path):
    return subprocess.run(['ffmpeg','-v','error','-i',str(path),'-f','md5','-'],capture_output=True,text=True).stdout.strip()

def same_picture(dest,entry,data):
    with tempfile.TemporaryDirectory() as tmp:
        old,new=Path(tmp)/'old',Path(tmp)/'new'
        old.write_bytes(subprocess.run(['git','-C',str(dest),'show','HEAD:'+entry['file']],capture_output=True,check=True).stdout)
        new.write_bytes(data)
        a,b=pixels(old),pixels(new)
        return bool(a) and a==b

def verify(dest):
    index=json.loads((dest/'index.json').read_text())
    path=dest/'hash-report.json'
    report=json.loads(path.read_text()) if path.exists() else None
    recent=report and datetime.datetime.now()-datetime.datetime.fromisoformat(report['checked'])<datetime.timedelta(days=1)
    seen=report['works'] if recent else {}  # a later run starts over, so an old result can't pass as current
    def save():
        counts={}
        for v in seen.values(): counts[v['status']]=counts.get(v['status'],0)+1
        path.write_text(json.dumps({'checked':datetime.datetime.now().isoformat(timespec='seconds'),'counts':counts,'works':seen},indent=1,ensure_ascii=False)+'\n')
        return counts
    todo=[w for w,withheld in works() if not withheld]
    for n,w in enumerate(todo,1):
        wid=w['id'];url=w['image']['url'];entry=index.get(wid)
        expected=w['image'].get('sha256') or (entry['sha256'] if entry and entry['url']==url else None)
        if seen.get(wid,{}).get('url')==url and seen[wid].get('expected')==expected: continue
        if urllib.parse.urlsplit(url).hostname=='www.artic.edu':
            seen[wid]={'status':'unchecked','url':url,'expected':expected};continue
        status,data=get(url,polite=True)
        rec={'url':url,'expected':expected}
        if status!=200 or not kind(data): rec.update(status='dead',http=status)
        else:
            sha=hashlib.sha256(data).hexdigest();rec['sha256']=sha
            if sha==expected: rec['status']='same'
            elif not expected: rec['status']='new'
            elif entry and entry['url']==url and same_picture(dest,entry,data): rec['status']='metadata'
            else: rec['status']='picture'
        seen[wid]=rec
        if rec['status'] not in ('same',): print(f"[{n}/{len(todo)}] {wid}: {rec['status']} {url}",flush=True)
        if n%25==0: save()
    counts=save()
    print(counts)
    return 1 if counts.get('picture') or counts.get('dead') else 0

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__,formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('dest',type=Path);p.add_argument('--push',action='store_true');p.add_argument('--check',action='store_true');p.add_argument('--verify',action='store_true')
    a=p.parse_args()
    sys.exit(check(a.dest) if a.check else verify(a.dest) if a.verify else archive(a.dest,a.push))
