#!/usr/bin/env python3
"""Run the photo lookup again on items already in ARMORY (added.json).

  python3 tools/relookup.py                 every item with UNKNOWN in its maker or name
  python3 tools/relookup.py 2125 2133       just these items
  python3 tools/relookup.py --dry 2125      show what it would change, change nothing

Uses tools/lookup-item.py (museum collections first, then the web) on each
item's original photo, and fills in only what is UNKNOWN or empty: anything
already written stays. Changed items get "updated", so the Google Sheet and
ARMORY pick them up. Run from inventory-and-armor/; then commit added.json.
Needs what lookup-item.py needs (claude signed in).
"""
import glob, json, os, shutil, subprocess, sys, tempfile
sys.dont_write_bytecode = True
from datetime import datetime, timezone

FIELDS = ('section', 'maker', 'name', 'note', 'credit')
here = os.path.dirname(os.path.abspath(__file__))
os.chdir(os.path.dirname(here))
args = [a for a in sys.argv[1:] if not a.startswith('--')]
dry = '--dry' in sys.argv

items = json.load(open('added.json'))
todo = [i for i in items if not i.get('deleted') and (
    str(i['id']) in args if args else 'UNKNOWN' in ((i.get('maker') or '') + (i.get('name') or '')).upper())]
print(f'{len(todo)} item(s) to look up')


def blank(v):
    return not (v or '').strip() or (v or '').strip().upper() == 'UNKNOWN'


changed = 0
for it in todo:
    first = [p.strip() for p in (it.get('img') or '').split(',') if p.strip() and not p.strip().startswith('videos/')]
    if not first:
        continue
    base = os.path.splitext(os.path.basename(first[0]))[0]
    origs = glob.glob(f'originals/{base}.*')
    src = origs[0] if origs else first[0]
    if not os.path.exists(src):
        print(it['id'], 'no photo found'); continue
    d = tempfile.mkdtemp()
    shutil.copy(src, os.path.join(d, '1' + os.path.splitext(src)[1].lower()))
    entry = {k: ('' if blank(it.get(k)) else it.get(k)) for k in FIELDS}
    entry['section'] = it.get('section') or ''   # keep the section as a hint
    entry['lookup'] = True
    json.dump(entry, open(os.path.join(d, 'entry.json'), 'w'))
    r = subprocess.run([sys.executable, os.path.join(here, 'lookup-item.py'), d], capture_output=True, text=True)
    new = json.load(open(os.path.join(d, 'entry.json')))
    shutil.rmtree(d, ignore_errors=True)
    if r.returncode:
        print(it['id'], 'lookup failed:', r.stderr.strip()[-200:]); continue
    diff = {k: new[k] for k in FIELDS if blank(it.get(k)) and not blank(new.get(k)) and k != 'section'}
    if blank(it.get('maker')) and blank(it.get('name')) and new.get('section'):
        diff['section'] = new['section']
    lu = new.get('looked_up') or {}
    print(it['id'], ('-> ' + json.dumps(diff, ensure_ascii=False)[:300]) if diff else 'still unknown',
          '| sure' if lu.get('sure') else '', lu.get('how') or '')
    if diff and not dry:
        it.update({k: (v.upper() if k in ('maker', 'name', 'section') else v) for k, v in diff.items()})
        it['looked_up'] = lu
        it['updated'] = datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')
        changed += 1
        json.dump(items, open('added.json', 'w'), ensure_ascii=False, indent=1)
        open('added.json', 'a').write('\n')
print(f'{changed} item(s) updated' + (' (dry run)' if dry else ''))
