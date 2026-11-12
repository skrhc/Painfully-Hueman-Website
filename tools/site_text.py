#!/usr/bin/env python3
"""
SITE TEXT — edit the website's writing from a Google Sheet.

Every editable piece of text on the site carries a data-text="key" attribute.
The "Site Text" Google Sheet has one row per key. This script copies the sheet's
text into the pages. A GitHub Action runs it every hour (and on demand).

In the sheet's "text" column:
  *italic*          -> italic (album and book titles)
  **bold**          -> bold (the labels at the start of list items)
  [words](link)     -> a link

Commands (run from the repository root):
  python3 tools/site_text.py tag              add keys to new text (one time / after adding pages)
  python3 tools/site_text.py export out.csv   write the current text to a CSV (to fill the sheet)
  python3 tools/site_text.py apply SOURCE     copy text from a CSV file or a published-CSV URL into the pages
"""

import csv
import html
import io
import re
import sys
import urllib.request

# Pages whose writing can be edited from the sheet (interviews are left out:
# they are the artists' own words).
PAGES = {
    'index': 'index.html',
    'about': 'about/index.html',
    'editorial': 'editorial/index.html',
    'sex-change': 'sex-change/index.html',
    'castro-nyc': 'work/castro-nyc/index.html',
    'lee': 'work/lee/index.html',
    'saint-fleur': 'work/saint-fleur/index.html',
    'music-by-lee-v1': 'work/music-by-lee-v1/index.html',
    'music-by-lee-v2': 'work/music-by-lee-v2/index.html',
    'sotce-axel-arigato': 'work/sotce-axel-arigato/index.html',
}

PAGE_NAMES = {
    'index': 'INDEX', 'about': 'ABOUT', 'editorial': 'EDITORIAL', 'sex-change': 'SEX CHANGE',
    'castro-nyc': 'Castro NYC', 'lee': 'LEE.', 'saint-fleur': 'Saint Fleur', 'sotce-axel-arigato': 'Sotce at Axel Arigato',
    'music-by-lee-v1': 'MUSIC BY LEE. v1', 'music-by-lee-v2': 'Music by LEE. v2',
}

TAGS = ('h1', 'h2', 'p', 'li')
SKIP_CLASSES = ('stack-note', 'article-end')

OPEN_RE = re.compile(r'<(h1|h2|p|li)(\s[^>]*)?>')


def main_region(s):
    a = s.find('<main')
    b = s.find('</main>')
    return (a, b) if a >= 0 and b > a else (None, None)


def element_re(key):
    k = re.escape(key)
    return re.compile(r'<(h1|h2|p|li)((?:\s[^>]*?)?\sdata-text="' + k + r'"[^>]*)>(.*?)</\1>', re.S)


# ---------- html <-> sheet text ----------

def to_sheet(inner):
    t = inner
    t = re.sub(r'<a\s[^>]*?href="([^"]*)"[^>]*>(.*?)</a>', lambda m: '[' + m.group(2) + '](' + m.group(1) + ')', t, flags=re.S)
    t = re.sub(r'<strong>(.*?)</strong>', r'**\1**', t, flags=re.S)
    t = re.sub(r'<em>(.*?)</em>', r'*\1*', t, flags=re.S)
    t = re.sub(r'<[^>]+>', '', t)
    return html.unescape(t).strip()


def to_html(text):
    t = html.escape(text.strip(), quote=False)

    def link(m):
        words, url = m.group(1), m.group(2)
        if url.startswith('http'):
            return '<a href="' + url + '" target="_blank" rel="noopener">' + words + '</a>'
        return '<a href="' + url + '">' + words + '</a>'

    t = re.sub(r'\[([^\]]+)\]\(([^)\s]+)\)', link, t)
    t = re.sub(r'\*\*(.+?)\*\*', r'<strong>\1</strong>', t)
    t = re.sub(r'(?<![*\w])\*(?!\s)(.+?)(?<!\s)\*(?![*\w])', r'<em>\1</em>', t)
    return t


# ---------- commands ----------

def tag():
    for page, path in PAGES.items():
        s = open(path, encoding='utf-8').read()
        a, b = main_region(s)
        if a is None:
            continue
        used = set(re.findall(r'data-text="' + re.escape(page) + r'\.(\d+)"', s))
        n = max([int(x) for x in used] or [0])
        out, pos, added = [], a, 0
        region = s[a:b]
        for m in OPEN_RE.finditer(region):
            attrs = m.group(2) or ''
            if 'data-text=' in attrs or any(c in attrs for c in SKIP_CLASSES):
                continue
            n += 1
            added += 1
            end = a + m.end()
            out.append(s[pos:end - 1] + ' data-text="%s.%02d">' % (page, n))
            pos = end
        out.append(s[pos:])
        s = s[:a] + ''.join(out)
        open(path, 'w', encoding='utf-8').write(s)
        print('%-18s %d new keys' % (page, added))


def rows():
    """Every editable piece of text, in page order."""
    for page, path in PAGES.items():
        s = open(path, encoding='utf-8').read()
        section = 'Top'
        for m in re.finditer(r'<(h1|h2|p|li)((?:\s[^>]*?)?\sdata-text="([^"]+)"[^>]*)>(.*?)</\1>', s, re.S):
            tag_, attrs, key, inner = m.group(1), m.group(2), m.group(3), m.group(4)
            text = to_sheet(inner)
            in_card = page in ('index', 'editorial')
            if tag_ == 'h1':
                kind = 'Title'
            elif tag_ == 'h2':
                kind = 'Card title' if in_card else 'Heading'
                if not in_card:
                    section = text
            elif tag_ == 'li':
                kind = 'List item'
            elif 'case-tags' in attrs:
                kind = 'Tags'
            elif 'case-lede' in attrs:
                kind = 'Opening line'
            elif 'photo-credit' in attrs:
                kind = 'Photo credit'
            elif 'case-press' in attrs:
                kind = 'Press links'
            elif in_card:
                kind = 'Card tags'
            else:
                kind = 'Paragraph'
            where = text if kind == 'Card title' else section
            if kind == 'Card title':
                section = text
            yield key, PAGE_NAMES[page], where, kind, text


def export(dest):
    with open(dest, 'w', encoding='utf-8', newline='') as f:
        w = csv.writer(f)
        w.writerow(['page', 'section', 'type', 'text', 'key'])
        for key, page, where, kind, text in rows():
            w.writerow([page, where, kind, text, key])
    print('wrote', dest)


def read_source(src):
    if src.startswith('http'):
        req = urllib.request.Request(src, headers={'User-Agent': 'painfullyhueman-site-text'})
        data = urllib.request.urlopen(req, timeout=30).read().decode('utf-8')
    else:
        data = open(src, encoding='utf-8').read()
    return {r['key'].strip(): r['text'] for r in csv.DictReader(io.StringIO(data)) if r.get('key')}


def apply(src):
    texts = read_source(src)
    changed = 0
    for page, path in PAGES.items():
        s = open(path, encoding='utf-8').read()
        orig = s

        def repl(m):
            key = re.search(r'data-text="([^"]+)"', m.group(2)).group(1)
            if key not in texts or not texts[key].strip():
                return m.group(0)       # blank or missing in the sheet: leave the page as it is
            new = to_html(texts[key])
            if to_sheet(m.group(3)) == to_sheet(new):
                return m.group(0)       # same words: keep the exact HTML
            return '<%s%s>%s</%s>' % (m.group(1), m.group(2), new, m.group(1))

        s = re.sub(r'<(h1|h2|p|li)((?:\s[^>]*?)?\sdata-text="[^"]+"[^>]*)>(.*?)</\1>', repl, s, flags=re.S)
        if s != orig:
            open(path, 'w', encoding='utf-8').write(s)
            changed += 1
            print('updated', path)
    print('%d page(s) changed' % changed)


if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else ''
    if cmd == 'tag':
        tag()
    elif cmd == 'export' and len(sys.argv) > 2:
        export(sys.argv[2])
    elif cmd == 'apply' and len(sys.argv) > 2:
        apply(sys.argv[2])
    else:
        print(__doc__)
