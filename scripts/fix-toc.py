#!/usr/bin/env python3
"""Sync TOC link labels with the rendered heading text in an HTML file.

Quarto resolves {{< meta >}} shortcodes after Lua filters run, so heading
text containing shortcodes appears correctly in the document body but not
in the Lua-generated TOC (which was built from the still-unresolved AST).
This script rebuilds the TOC labels from the actual rendered headings.

Usage: fix-toc.py <html-file>
"""
import re
import sys


def strip_tags(s):
    return re.sub(r'<[^>]+>', '', s)


def build_heading_map(html):
    """Return {id: (section_num, body_text)} for every h1–h5 in the document.

    Mirrors the Lua filter's `toc_label` rule: when a heading starts with a
    <strong> span (Variant A or Variant C), use only the strong span's text as
    the TOC label, so a clause like
        ## **Title**: body text…
    appears in the TOC as just "Title" rather than the full sentence.
    """
    result = {}
    for m in re.finditer(
        r'<h[1-5][^>]*\bid="([^"]+)"[^>]*>(.*?)</h[1-5]>',
        html, re.DOTALL
    ):
        hid, inner = m.group(1), m.group(2)
        sn_m = re.search(
            r'<span[^>]*\bclass="header-section-number"[^>]*>(.*?)</span>',
            inner, re.DOTALL
        )
        if sn_m:
            sn = strip_tags(sn_m.group(1)).strip()
            inner = inner[:sn_m.start()] + inner[sn_m.end():]
        else:
            sn = ''
        strong_m = re.match(r'\s*<strong>(.*?)</strong>', inner, re.DOTALL)
        if strong_m:
            body = strip_tags(strong_m.group(1)).strip()
        else:
            body = strip_tags(inner).strip()
        result[hid] = (sn, body)
    return result


def fix_toc(html, heads):
    def rewrite_link(m):
        href, old_text = m.group(1), m.group(2)
        if href not in heads:
            return m.group(0)
        sn, body = heads[href]
        new_text = f'{sn} {body}'.strip() if sn else body
        if new_text == old_text:
            return m.group(0)
        return f'<a href="#{href}">{new_text}</a>'

    def rewrite_nav(m):
        return re.sub(r'<a href="#([^"]+)">([^<]*)</a>', rewrite_link, m.group(0))

    return re.sub(r'<nav id="toc">.*?</nav>', rewrite_nav, html, flags=re.DOTALL)


if __name__ == '__main__':
    if len(sys.argv) != 2:
        print(f'Usage: {sys.argv[0]} <html-file>', file=sys.stderr)
        sys.exit(1)
    path = sys.argv[1]
    with open(path, encoding='utf-8') as fh:
        html = fh.read()
    fixed = fix_toc(html, build_heading_map(html))
    if fixed != html:
        with open(path, 'w', encoding='utf-8') as fh:
            fh.write(fixed)
