#!/usr/bin/env python3
"""Look up what an ARMORY submission is from its photo, and fill in the blanks.

  python3 lookup-item.py INBOX_DIR     (INBOX_DIR holds entry.json + 1.jpg, 2.png...)

Claude Code (the `claude` command, signed in with your Claude plan) fills in
whatever was left empty in entry.json: section, maker, name, note, credit.
Anything you typed on the ADD page is kept.

How it looks:
  1. A quick look at the photo (small model): what is it, and what would a
     museum call it? -> a few search words.
  2. Museum collections: the Met, the Art Institute of Chicago and the
     Cleveland Museum of Art publish their collections with photos. Their
     closest matches are downloaded and compared with your photo; when one is
     the same object, its museum record fills the entry (sure).
  3. Otherwise a web search (small model, then the bigger one if needed).
The answer is marked in entry.json as "looked_up" ({sure, source, how}) so the
item can be checked later. If it can't tell what it is, maker and name become
UNKNOWN. Needs: claude, and ffmpeg when the only file is a video.
"""
import concurrent.futures, glob, json, os, re, shutil, subprocess, sys, tempfile, urllib.parse, urllib.request
sys.dont_write_bytecode = True

SECTIONS = ('FOOTWEAR TOP BOTTOMS OUTERWEAR HEADWEAR HOOD UNIFORM EYEWEAR JEWELRY BAG PAINTING SCULPTURE '
            'PHOTO PRINT RENDERING BOOK OBJECT FURNITURE LIGHTING HARDWARE ARCHITECTURE FILM PERFORMANCE')
FIELDS = ('section', 'maker', 'name', 'note', 'credit')
# the small, quick model for most steps (uses little of the Claude plan's
# allowance); the bigger one compares photos and takes a second try.
MODEL = 'haiku'
BACKUP_MODEL = 'sonnet'
UA = {'User-Agent': 'ArmoryLookup/1.0'}


def claude_json(prompt, model, tools, cwd, timeout=420):
    claude = shutil.which('claude') or os.path.expanduser('~/.local/bin/claude')
    r = subprocess.run([claude, '-p', prompt, '--output-format', 'json', '--model', model,
                        '--allowedTools'] + tools, capture_output=True, text=True, timeout=timeout, cwd=cwd)
    out = json.loads(r.stdout or '{}')
    text = out.get('result') or ''
    if r.returncode or out.get('is_error'):
        raise RuntimeError((text or r.stderr or 'claude failed').strip()[-400:])
    m = re.search(r'\{.*\}', text, re.S)
    return json.loads(m.group(0)) if m else {}


def get_json(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=20) as r:
        return json.load(r)


# ---------- museum collections (free, no key) ----------
def met(q, n=6):
    ids = get_json('https://collectionapi.metmuseum.org/public/collection/v1.1/search?hasImages=true&limit=%d&q=%s'
                   % (n, urllib.parse.quote(q))).get('objectIDs') or []
    out = []
    for i in ids[:n]:
        try:
            d = get_json('https://collectionapi.metmuseum.org/public/collection/v1/objects/%d' % i)
        except Exception:
            continue
        if not d.get('primaryImageSmall'):
            continue
        out.append({'museum': 'The Metropolitan Museum of Art', 'title': d.get('title') or '',
                    'maker': d.get('artistDisplayName') or (d.get('culture') and d['culture'] + ' culture') or '',
                    'date': d.get('objectDate') or '', 'medium': d.get('medium') or '',
                    'size': d.get('dimensions') or '', 'credit': d.get('creditLine') or '',
                    'number': d.get('accessionNumber') or '', 'url': d.get('objectURL') or '',
                    'img': d['primaryImageSmall'], 'kind': d.get('classification') or d.get('objectName') or ''})
    return out


def aic(q, n=3):
    d = get_json('https://api.artic.edu/api/v1/artworks/search?limit=%d&q=%s&fields=id,title,artist_display,'
                 'date_display,medium_display,dimensions,credit_line,main_reference_number,image_id,'
                 'classification_title' % (n, urllib.parse.quote(q)))
    return [{'museum': 'The Art Institute of Chicago', 'title': a.get('title') or '',
             'maker': (a.get('artist_display') or '').split('\n')[0], 'date': a.get('date_display') or '',
             'medium': a.get('medium_display') or '', 'size': a.get('dimensions') or '',
             'credit': a.get('credit_line') or '', 'number': a.get('main_reference_number') or '',
             'url': 'https://www.artic.edu/artworks/%s' % a['id'], 'kind': a.get('classification_title') or '',
             'img': 'https://www.artic.edu/iiif/2/%s/full/400,/0/default.jpg' % a['image_id']}
            for a in d.get('data') or [] if a.get('image_id')]


def cleveland(q, n=3):
    d = get_json('https://openaccess-api.clevelandart.org/api/artworks/?has_image=1&limit=%d&q=%s'
                 % (n, urllib.parse.quote(q)))
    out = []
    for a in d.get('data') or []:
        img = ((a.get('images') or {}).get('web') or {}).get('url')
        if not img:
            continue
        who = (a.get('creators') or [{}])[0].get('description') or (a.get('culture') or [''])[0] or ''
        out.append({'museum': 'The Cleveland Museum of Art', 'title': a.get('title') or '', 'maker': who,
                    'date': a.get('creation_date') or '', 'medium': a.get('technique') or '',
                    'size': (a.get('measurements') or ''), 'credit': a.get('creditline') or '',
                    'number': a.get('accession_number') or '', 'url': a.get('url') or '', 'img': img,
                    'kind': a.get('type') or ''})
    return out


def museum_candidates(queries, tmp, cap=24):
    found, seen = [], set()
    jobs = [(f, q) for q in queries[:4] for f in (met, aic, cleveland)]
    with concurrent.futures.ThreadPoolExecutor(8) as ex:
        results = list(ex.map(lambda fq: _safe(fq[0], fq[1]), jobs))
    # interleave so every query gets a turn before the cap
    for rnd in range(6):
        for res in results:
            if rnd < len(res) and res[rnd]['url'] not in seen and len(found) < cap:
                seen.add(res[rnd]['url']); found.append(res[rnd])

    def fetch(i_c):
        i, c = i_c
        path = os.path.join(tmp, 'c%02d.jpg' % (i + 1))
        try:
            with urllib.request.urlopen(urllib.request.Request(c['img'], headers=UA), timeout=20) as r, \
                    open(path, 'wb') as f:
                f.write(r.read())
            c['file'] = path
        except Exception:
            pass
    with concurrent.futures.ThreadPoolExecutor(8) as ex:
        list(ex.map(fetch, enumerate(found)))
    return [c for c in found if c.get('file')]


def _safe(f, q):
    try:
        return f(q)
    except Exception:
        return []


def main():
    sub = sys.argv[1]
    entry_path = os.path.join(sub, 'entry.json')
    entry = json.load(open(entry_path))
    files = sorted((f for f in glob.glob(os.path.join(sub, '*')) if not re.search(r'\.(json|start|txt)$', f)),
                   key=lambda f: os.path.basename(f))
    tmp = tempfile.mkdtemp()
    photo = next((f for f in files if not re.search(r'\.(mp4|mov|m4v|webm|mkv)$', f, re.I)), None)
    if not photo and files:   # only a video: look at a frame from it
        photo = os.path.join(tmp, 'frame.jpg')
        subprocess.run(['ffmpeg', '-v', 'error', '-y', '-ss', '3', '-i', files[0], '-frames:v', '1', photo])
    if photo and not re.search(r'\.(jpe?g|png|gif|webp)$', photo, re.I):   # HEIC etc: make a JPEG it can read
        jpg = os.path.join(tmp, 'photo.jpg')
        subprocess.run(['sips', '-s', 'format', 'jpeg', photo, '--out', jpg], capture_output=True)
        photo = jpg
    if not photo or not os.path.exists(photo):
        sys.exit('No photo to look at.')
    # work on a copy outside the repo (a converted HEIC or a video frame is already in tmp)
    if os.path.dirname(os.path.abspath(photo)) != os.path.abspath(tmp):
        copy = os.path.join(tmp, 'photo' + os.path.splitext(photo)[1].lower())
        shutil.copy(photo, copy)
        photo = copy

    given = {k: (entry.get(k) or '').strip() for k in FIELDS}
    given = {k: ('' if v.upper() == 'UNKNOWN' else v) for k, v in given.items()}
    names = [n for n in entry.get('orig_names') or [] if n]
    hint = ('\nThe photo\'s original file name: %s. Camera names like IMG_1234 mean nothing, but a museum '
            'image number or a descriptive name is a strong clue.' % ', '.join(names[:3])) if names else ''

    found, how = {}, ''
    try:
        # 1. what is it, in a museum's words?
        first = claude_json(f"""Read the image file {photo}. It is a photo for ARMORY, an archive of clothing, art, design and objects.
What the person typed (may be empty): {json.dumps(given, ensure_ascii=False)}{hint}
Reply with ONLY one JSON object:
{{"what": a short plain description,
 "visible_text": any caption, credit, label or handle readable in the image, word for word (screenshots often carry the
   real credit, like "Collection & Credit: The Getty"), or "",
 "section": one of [{SECTIONS}],
 "museum_like": true if this could be in a museum collection (artwork, antiquity, decorative art, historic object, design classic),
 "queries": 2 to 4 short searches a museum collection database would match, using museum vocabulary
   (culture, object type, material, period, artist if you recognise them), e.g. "Xochipala female figure", "Yoruba ceremonial axe", "Agnes Pelton"}}""",
                            MODEL, ['Read'], tmp, timeout=180)

        # 2. museum collections: compare photos
        if first.get('museum_like') and first.get('queries'):
            cands = museum_candidates([str(q) for q in first['queries']], tmp)
            if cands:
                listing = '\n'.join('%d. %s — %s, %s (%s) [%s] file: %s' % (
                    i + 1, c['title'], c['maker'], c['date'], c['kind'], c['museum'], c['file'])
                    for i, c in enumerate(cands))
                pick = claude_json(f"""Read the photo {photo}. Then read each candidate image below: museum records found by searching.
Is any candidate THE SAME OBJECT as the photo: the same individual piece, not another one of its type?
Museums often own several near-identical pieces, so compare distinctive details: pose and arm position, chips and
breaks, wear, pigment, ornaments, proportions. Lighting, angle and crop may differ. If you are not certain, answer null.
Text seen in the photo: {json.dumps(first.get('visible_text') or '', ensure_ascii=False)}
{listing}
Reply with ONLY one JSON object: {{"match": the candidate number or null, "certain": true or false, "why": a few words}}""",
                                   BACKUP_MODEL, ['Read'], tmp, timeout=420)
                n = pick.get('match')
                if isinstance(n, int) and 1 <= n <= len(cands) and pick.get('certain') is True:
                    c = cands[n - 1]
                    found = {'section': first.get('section') or '',
                             'maker': c['maker'],
                             'name': ', '.join(x for x in (c['title'], c['date']) if x),
                             'note': '. '.join(x for x in (c['medium'], c['size']) if x),
                             'credit': ', '.join(x for x in (c['museum'], c['credit'], c['number']) if x),
                             'source': c['url'], 'sure': True}
                    how = 'museum: ' + c['museum']

        # 3. the open web
        if not found:
            web_prompt = f"""You are cataloguing an item for ARMORY, a visual archive of clothing, art, design and objects.
Read the image file {photo} and work out exactly what it is.{hint}
If the image is a screenshot with a caption or credit (Instagram etc.), use it: it often names the museum or
collection that holds the piece. Then find that collection's own page for it.
A first look said: {json.dumps(first, ensure_ascii=False)}
Use web search to confirm it (museum collection pages, the maker's site, a gallery, a retailer, a press article).
For museum pieces, search the museum's own collection pages. Don't guess wildly.

What the person already typed (keep these; empty means unknown): {json.dumps(given, ensure_ascii=False)}

Reply with ONLY one JSON object, no other text:
{{"section": one of [{SECTIONS}],
 "maker": the designer, brand, artist, workshop or culture (as the source writes it),
 "name": the item or work's title; for artworks add the year, like "CLAVO, 1978"; for fashion include the season or model if known,
 "note": one or two plain factual sentences (medium, size, year, collection), or "",
 "credit": the credit line as the source publishes it (museum/collection and accession number, gallery and photographer, or the brand), or "",
 "source": the URL that confirms it, or "",
 "sure": true if a source confirms it, false if it's your best guess}}
If you can't tell what it is, use "" for maker and name and false for sure."""
            found = claude_json(web_prompt, MODEL, ['Read', 'WebSearch', 'WebFetch'], tmp)
            how = 'web'

            def unknown(f):
                return not ((f.get('maker') or given['maker']).strip() and (f.get('name') or given['name']).strip())
            if unknown(found):   # the small model couldn't place it: one try with the bigger one
                better = claude_json(web_prompt, BACKUP_MODEL, ['Read', 'WebSearch', 'WebFetch'], tmp)
                if not unknown(better) or len([v for v in better.values() if v]) > len([v for v in found.values() if v]):
                    found = better
            if not found.get('note') and first.get('what'):
                found['note'] = first['what']
            if not found.get('section'):
                found['section'] = first.get('section') or ''
    except Exception as err:   # still add the item; it just stays unknown
        sys.stderr.write(f'lookup failed: {err}\n')
        found = dict(found or {}, sure=False, error=str(err)[-300:])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    for k in FIELDS:
        if not given[k] and isinstance(found.get(k), str) and found[k].strip():
            entry[k] = found[k].strip()
    for k in ('maker', 'name'):
        if not (entry.get(k) or '').strip() or entry[k].strip().upper() == 'UNKNOWN':
            entry[k] = 'UNKNOWN'
    if not (entry.get('section') or '').strip():
        entry['section'] = 'OBJECT'
    entry['looked_up'] = {'sure': bool(found.get('sure')), 'source': found.get('source') or '', 'how': how}
    if found.get('error'):
        entry['looked_up']['error'] = found['error']
    json.dump(entry, open(entry_path, 'w'), ensure_ascii=False, indent=1)
    print(json.dumps({k: entry.get(k) for k in FIELDS + ('looked_up',)}, ensure_ascii=False))


if __name__ == '__main__':
    main()
