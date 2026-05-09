#!/usr/bin/env python3
"""Post-assembly completeness check for md2qmd conversions.

Compares clause/item counts and body word counts between a Markdown source
file and its assembled Quarto output, section by section.

Usage
-----
    python3 verify-counts.py <source.md> <output.qmd>

Exit codes
----------
0 — all hard checks pass (warnings may have been printed)
1 — one or more hard failures (H1 section count mismatch)

Matching strategy
-----------------
Sections are matched by index position (first H1 in source ↔ first H1 in
output, etc.), not by name — because H1 titles are reformatted (case,
punctuation) between source and output.

Clause-count logic
------------------
Source:  numbered list items detected by indent + label pattern.
         ALL matching items across all indent levels are summed per section.

Output:  ALL subheadings (## through #####) are summed per section.

A warning is raised if the output has fewer total headings than the source has
total numbered items in the same section. The output legitimately having MORE
headings than the source (e.g. when tables or definition lists are converted
to headings) is expected and does not trigger a warning.

Level-by-level breakdown is printed as information only: the indent-to-level
mapping in the source is inherently heuristic (inconsistent indentation in the
source can shift the mapping), so per-level counts are not used for pass/fail.

Word-count logic
----------------
Source:  words on item lines after stripping the numbered label prefix;
         non-item lines (blank lines, continuation prose) are also included.
Output:  words on all non-blank lines after stripping leading # markers and
         Quarto attribute blocks ({#…}).
A warning is raised if the ratio falls outside 70%–130%.
"""

import re
import sys
from collections import Counter

# --- patterns -----------------------------------------------------------

ITEM_START = re.compile(
    r'^(\s*)(\d+\.|[a-zA-Z]\.|[ivxlcIVXLC]+\.|'
    r'\([0-9]+\)|\([a-zA-Z]+\)|\([ivxlcIVXLC]+\))\s'
)
HEADING_RE = re.compile(r'^(#{2,5})\s')
H1_RE      = re.compile(r'^#\s')
ATTR_RE    = re.compile(r'\{[^}]*\}')

LEVEL_NAME = {0: '##', 1: '###', 2: '####', 3: '#####'}


# --- section splitting --------------------------------------------------

def split_by_h1(text: str) -> list[tuple[str, str]]:
    """Return list of (title, body) for each H1 section.

    Lines before the first H1 (YAML frontmatter, preamble) are discarded.
    """
    sections: list[tuple[str, str]] = []
    current_title = None
    current_lines: list[str] = []

    for line in text.splitlines():
        if H1_RE.match(line):
            if current_title is not None:
                sections.append((current_title, '\n'.join(current_lines)))
            current_title = ATTR_RE.sub('', line[2:]).strip()
            current_lines = []
        elif current_title is not None:
            current_lines.append(line)

    if current_title is not None:
        sections.append((current_title, '\n'.join(current_lines)))

    return sections


# --- source counting ----------------------------------------------------

def source_item_counts(body: str) -> tuple[int, Counter]:
    """Count numbered items per indent depth → ordinal level (0 = shallowest).

    Returns (total, Counter keyed by ordinal level 0–3).
    """
    counts: Counter = Counter()
    indent_to_level: dict[int, int] = {}
    total = 0

    for line in body.splitlines():
        m = ITEM_START.match(line)
        if not m:
            continue
        indent = len(m.group(1))
        if indent not in indent_to_level:
            known = sorted(indent_to_level)
            indent_to_level[indent] = len(known)
        level = indent_to_level[indent]
        total += 1
        if level <= 3:
            counts[level] += 1

    return total, counts


def source_word_count(body: str) -> int:
    words = 0
    for line in body.splitlines():
        m = ITEM_START.match(line)
        if m:
            content = line[m.end():]
        else:
            content = line
        words += len(content.split())
    return words


# --- output counting ----------------------------------------------------

def output_heading_counts(body: str) -> tuple[int, Counter]:
    """Count ##/###/####/##### headings → ordinal level (0 = ##).

    Returns (total, Counter keyed by ordinal level 0–3).
    """
    counts: Counter = Counter()
    total = 0
    for line in body.splitlines():
        m = HEADING_RE.match(line)
        if m:
            level = len(m.group(1)) - 2
            total += 1
            if level <= 3:
                counts[level] += 1
    return total, counts


def output_word_count(body: str) -> int:
    words = 0
    for line in body.splitlines():
        if not line.strip():
            continue
        content = re.sub(r'^#+\s*', '', line)
        content = ATTR_RE.sub('', content)
        words += len(content.split())
    return words


# --- main ---------------------------------------------------------------

def run(source_path: str, qmd_path: str) -> int:
    with open(source_path, encoding='utf-8') as f:
        source_text = f.read()
    with open(qmd_path, encoding='utf-8') as f:
        qmd_text = f.read()

    source_sections = split_by_h1(source_text)
    output_sections = split_by_h1(qmd_text)

    failures = 0
    warnings = 0

    # Hard check: section count
    if len(source_sections) != len(output_sections):
        print(
            f'FAIL  section count: source has {len(source_sections)} H1 '
            f'sections, output has {len(output_sections)}'
        )
        failures += 1
    else:
        print(f'OK    section count: {len(source_sections)} H1 sections')

    n_sections = min(len(source_sections), len(output_sections))

    for i in range(n_sections):
        src_title, src_body = source_sections[i]
        out_title, out_body = output_sections[i]
        label = f'section {i + 1} ("{src_title[:40]}")'

        src_total, src_counts = source_item_counts(src_body)
        out_total, out_counts = output_heading_counts(out_body)

        # Only compare items at heading levels 0–3 (## through #####).
        # Items deeper than level 3 in the source are folded into prose in
        # the output and do not become discrete headings, so they are excluded
        # from the comparison to avoid false positives.
        src_comparable = sum(src_counts.values())

        # Warn if output has fewer total headings than source has items at
        # heading-equivalent levels. Output legitimately having MORE headings
        # than the source (e.g. tables / definition lists that expand into
        # headings) is expected and does not trigger a warning.
        if src_comparable > 0 and out_total < src_comparable:
            print(
                f'WARN  {label}: output has {out_total} headings but source '
                f'has {src_comparable} numbered items — possible missing content'
            )
            warnings += 1
        else:
            status = 'OK   ' if src_comparable > 0 else 'INFO '
            print(
                f'{status} {label}: source {src_comparable} items → '
                f'output {out_total} headings'
            )

        # Informational level breakdown
        all_levels = sorted(set(src_counts) | set(out_counts))
        if all_levels:
            parts = []
            for level in all_levels:
                lname = LEVEL_NAME.get(level, f'L{level}')
                sc = src_counts.get(level, 0)
                oc = out_counts.get(level, 0)
                parts.append(f'{lname}: src={sc}/out={oc}')
            print(f'      breakdown: {", ".join(parts)}')

        # Word count ratio check
        sw = source_word_count(src_body)
        ow = output_word_count(out_body)
        if sw > 0:
            ratio = ow / sw
            if ratio < 0.70 or ratio > 1.30:
                print(
                    f'WARN  {label} word count: '
                    f'source {sw} words, output {ow} words '
                    f'(ratio {ratio:.2f}, expected 0.70–1.30)'
                )
                warnings += 1

    print()
    if failures:
        print(f'RESULT  {failures} failure(s), {warnings} warning(s) — FAILED')
    else:
        print(f'RESULT  0 failures, {warnings} warning(s) — PASSED')

    return 1 if failures else 0


if __name__ == '__main__':
    if len(sys.argv) != 3:
        print(f'Usage: {sys.argv[0]} <source.md> <output.qmd>', file=sys.stderr)
        sys.exit(2)
    sys.exit(run(sys.argv[1], sys.argv[2]))
