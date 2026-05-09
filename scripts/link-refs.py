#!/usr/bin/env python3
"""Cross-reference linker for legal Quarto documents.

Given an assembled `.qmd` file, walks every body paragraph and converts
plain-text cross-references (e.g. *clause 5.8*, *paragraphs 2 and 8*) into
markdown hyperlinks pointing at the relevant heading anchor.

Number-only links — preserve author wording
-------------------------------------------
The linker wraps only the numeric portion of a reference, leaving the
surrounding prose verbatim. So *"in accordance with clause 5.8"* becomes
*"in accordance with clause [5.8](#sec-5-8)"* (the word *clause* is the
author's, not ours), and *"clauses 5.13 to 5.16"* becomes *"clauses
[5.13](#sec-5-13) to [5.16](#sec-5-16)"* — no rewriting of the connector
word, no risk of producing duplicates like *"clauses clause 5.13"*.

Design — connector-anchored chain substitution
----------------------------------------------
The linker scans each line for a connector word (clause/clauses,
paragraph/paragraphs, Schedule/Schedules) and consumes the entire ref chain
that immediately follows it: a sequence of N, N.M, or N.M[a] tokens separated
by `,`, `;`, ` and `, ` or `, or ` to `. Each numeric token is wrapped in a
markdown link; the connector word and all separators pass through untouched.

A second pass extends chains anchored on a manually-written `@sec-…` Cite
token — so author strings like `@sec-payment, 5.9 and 5.12` get the trailing
numbers linked too.

Existing markdown links (`[text](url)`) are protected during substitution so
the linker is idempotent: re-running it on an already-linked file does not
re-wrap or corrupt prior links.

Legacy `@sec-<positional>` migration
------------------------------------
Earlier versions of the linker emitted `@sec-N-M` Cite tokens instead of
markdown links. Those tokens are scope-blind — `@sec-2-1` could mean
main-body clause 2.1 or any schedule's paragraph 2.1, and the Lua filter's
bare-key fallback resolves them all to the main body. The migration pass
finds `(clause|paragraph) @sec-<positional>` runs and rewrites each token
to a scope-aware markdown link, so legacy `.qmd` files relink correctly
under the new namespacing scheme.

Active-schedule tracking
------------------------
The walker tracks `active_schedule_id` (a string like `"sec-sched-3"`, or
`None`). On every H1 line the tracker tries to extract a trailing `{#sec-…}`
attribute; if found that string becomes `active_schedule_id`, otherwise it is
reset to `None` (main body / unnumbered H1s).

Inside a namespaced schedule scope, `paragraph N[.M]` resolves to
`<active_schedule_id>-N[-M]` — matching the Lua filter's per-H1 namespacing
(e.g. `sec-sched-3-1-2`). Outside any schedule scope (main body),
`paragraph N` is left unchanged.

The pattern `paragraph(s) CHAIN of Schedule N` is recognised before the
generic paragraph pass. Each token in the chain is linked to
`sec-sched-K-<token>` (K = captured schedule number), then the trailing
`Schedule N` is linked by the normal schedule pass.

Heading handling
----------------
H1 lines are skipped entirely: they are part / schedule titles, where any
trailing number ("Schedule 1") would be misread as a clause reference and
where substitution could produce self-links. H2-H5 heading lines DO receive
substitution — Variant C clauses (`### **Bold label**: body with clause N`)
need their inline cross-refs linked just like body paragraphs. The Lua
filter assigns positional `sec-N-M` IDs that don't depend on heading text,
so substitution here is safe.

Usage
-----
    python3 link-refs.py path/to/document.qmd

The file is rewritten in place. Run after assembly and before
`quarto render`.
"""

import re
import sys


# ── Patterns ────────────────────────────────────────────────────────────────
TOKEN = r"\d+(?:\.\d+)?[a-z]?"
SEP = r"(?:\s*[,;]\s*|\s+and\s+|\s+or\s+|\s+to\s+)"


def make_chain_pattern(connector_regex):
    """Build a regex that matches `connector  TOKEN (SEP TOKEN)*`."""
    return re.compile(
        r"(\b" + connector_regex + r"\s+)"
        r"(" + TOKEN + r"(?:" + SEP + TOKEN + r")*)",
        re.IGNORECASE,
    )


CLAUSE_PAT = make_chain_pattern(r"clauses?")
PARAGRAPH_PAT = make_chain_pattern(r"paragraphs?")
SCHEDULE_PAT = make_chain_pattern(r"Schedules?")
# section(s) is intentionally omitted — it's used for statutory references
# (Companies Act etc.) that should not be linked into this document.

# `paragraph(s) CHAIN of Schedule N` — must be tested before PARAGRAPH_PAT so
# the generic pass doesn't consume "paragraph 1" and wrongly resolve it against
# the current scope rather than the explicit schedule number.
# The schedule number group matches either a bare digit or an already-linked
# `[N](#sec-sched-N)` — both yield the schedule number for building the target ID.
PARA_OF_SCHED_PAT = re.compile(
    r"(\bparagraphs?\s+)"
    r"(" + TOKEN + r"(?:" + SEP + TOKEN + r")*)"
    r"(\s+of\s+Schedule\s+)"
    r"(?:(\d+)\b|\[(\d+)\]\(#sec-sched-\d+\))",
    re.IGNORECASE,
)

# Friendly-ID attribute on an H1 line, e.g. `{#sec-sched-3}`.
H1_FRIENDLY_ID = re.compile(r"\{#(sec-[\w-]+)\}")

# Legacy positional Cite tokens (`@sec-N`, `@sec-N-M`, `@sec-N-M-letter`)
# emitted by an older linker run. These are scope-blind: the same `@sec-2-1`
# means main-body clause 2.1 in one place and schedule 1's paragraph 2.1 in
# another. Rewrite each to a markdown link, choosing the target from the
# preceding connector word + active scope. Friendly IDs (`@sec-payment`) start
# with a letter and don't match this pattern; they fall through to the Lua
# Cite handler unchanged.
LEGACY_TOKEN = r"@sec-\d+(?:-\d+)?(?:-[a-z])?"
LEGACY_CHAIN_PAT = re.compile(
    r"(\b(clauses?|paragraphs?)\s+)"
    r"(" + LEGACY_TOKEN + r"(?:" + SEP + LEGACY_TOKEN + r")*)",
    re.IGNORECASE,
)

# Match an existing @sec-… token followed by a chain of plain TOKENs.
# Used for the second pass that extends already-anchored chains.
SEC_ANCHOR_CHAIN = re.compile(
    r"(@sec-[\w-]+)"
    r"((?:" + SEP + TOKEN + r")+)"
)

# Existing markdown link span. Protected during substitution.
MD_LINK = re.compile(r"\[[^\]]*\]\([^)]*\)")


# ── Resolvers ───────────────────────────────────────────────────────────────
def pos_id(prefix, n1, n2="", letter=""):
    """Build a positional sec-* ID matching the Lua filter's scheme.

    The Lua filter numbers sub-items by position (1, 2, 3…) regardless of the
    list marker in the source (a, b, c or i, ii, iii…).  Convert any trailing
    letter to its 1-based ordinal so "paragraph 4c" → sec-…-4-3.
    """
    base = prefix + "-" + n1 + ("-" + n2 if n2 else "")
    if letter:
        ordinal = str(ord(letter) - ord("a") + 1)
        return base + "-" + ordinal
    return base


def resolve_clause(raw, active_schedule_id):
    m = re.fullmatch(r"(\d+)(?:\.(\d+))?([a-z])?", raw)
    if not m:
        return None
    return pos_id("sec", m.group(1), m.group(2) or "", m.group(3) or "")


def resolve_paragraph(raw, active_schedule_id):
    if active_schedule_id is None:
        return None  # outside any schedule — leave unchanged
    m = re.fullmatch(r"(\d+)(?:\.(\d+))?([a-z])?", raw)
    if not m:
        return None
    return pos_id(active_schedule_id, m.group(1), m.group(2) or "", m.group(3) or "")


# ── Chain rewriter ──────────────────────────────────────────────────────────
def rewrite_chain(chain_text, resolver, active_schedule):
    """Wrap each TOKEN in chain_text in a markdown link; preserve separators.

    Emits `[N.M](#sec-N-M)` rather than a `@sec-*` Cite token, so the connector
    word that the author actually wrote (`clause`, `clauses`, `paragraph`,
    `Despite clauses`, etc.) is preserved verbatim — only the numeric portion
    becomes a hyperlink.
    """
    parts = re.split(r"(" + SEP + r")", chain_text)
    out = []
    for part in parts:
        stripped = part.strip()
        if re.fullmatch(TOKEN, stripped):
            sec_id = resolver(stripped, active_schedule)
            if sec_id:
                out.append(part.replace(
                    stripped,
                    "[" + stripped + "](#" + sec_id + ")",
                    1,
                ))
            else:
                out.append(part)
        else:
            out.append(part)
    return "".join(out)


def rewrite_legacy_chain(chain_text, connector, active_schedule_id):
    """Rewrite each `@sec-<positional>` in chain_text to a markdown link.

    `connector` is the matched word ("clause(s)" or "paragraph(s)"); its lemma
    decides the prefix:
      • `clause` → main-body prefix `sec` (target `sec-N-M`)
      • `paragraph` inside a schedule scope → `<active_schedule_id>-N-M`
      • `paragraph` outside any schedule scope → leave unchanged
    """
    is_para = connector.lower().lstrip().startswith("paragraph")
    parts = re.split(r"(" + SEP + r")", chain_text)
    out = []
    for part in parts:
        stripped = part.strip()
        m = re.fullmatch(r"@sec-(\d+)(?:-(\d+))?(?:-([a-z]))?", stripped)
        if not m:
            out.append(part)
            continue
        n1, n2, letter = m.group(1), m.group(2) or "", m.group(3) or ""
        if is_para:
            if active_schedule_id is None:
                out.append(part)
                continue
            prefix = active_schedule_id
        else:
            prefix = "sec"
        sec_id = pos_id(prefix, n1, n2, letter)
        display_parts = [n1]
        if n2:
            display_parts.append(n2)
        if letter:
            display_parts.append(letter)
        display = ".".join(display_parts)
        out.append(part.replace(stripped, "[" + display + "](#" + sec_id + ")", 1))
    return "".join(out)


def rewrite_schedule_chain(chain_text):
    """Replace integer TOKENs in chain_text with markdown links to sec-sched-N."""
    parts = re.split(r"(" + SEP + r")", chain_text)
    out = []
    for part in parts:
        stripped = part.strip()
        if re.fullmatch(r"\d+", stripped):
            out.append(part.replace(
                stripped,
                "[" + stripped + "](#sec-sched-" + stripped + ")",
                1,
            ))
        else:
            out.append(part)
    return "".join(out)


# ── Per-line substitution ───────────────────────────────────────────────────
def sub_line(line, active_schedule_id):
    # Pass 0: `paragraph(s) CHAIN of Schedule K` — runs on the raw line before
    # MD link stashing so it fires correctly on first-run source (plain "Schedule 3")
    # and is naturally idempotent: once "paragraph 1" is already a link, the TOKEN
    # pattern won't match "[1](...)" so the sub is a no-op on re-runs.
    def para_of_sched_repl(m):
        connector, chain, of_sched = m.group(1), m.group(2), m.group(3)
        # group(4) = bare digit, group(5) = digit from already-linked [N](url)
        sched_num = m.group(4) or m.group(5)
        sched_prefix = "sec-sched-" + sched_num
        # Preserve the original schedule token text (bare number or existing link)
        sched_token = m.group(0)[len(connector) + len(chain) + len(of_sched):]
        def resolve_in_sched(raw, _):
            inner = re.fullmatch(r"(\d+)(?:\.(\d+))?([a-z])?", raw)
            if not inner:
                return None
            return pos_id(sched_prefix, inner.group(1), inner.group(2) or "", inner.group(3) or "")
        return connector + rewrite_chain(chain, resolve_in_sched, None) + of_sched + sched_token
    line = PARA_OF_SCHED_PAT.sub(para_of_sched_repl, line)

    # Pass 0.5: migrate legacy `(clause|paragraph) @sec-<positional>` tokens
    # left over from earlier linker runs. Must run before MD link stashing so
    # the markdown links it produces get protected by the next stash step.
    def legacy_repl(m):
        return m.group(1) + rewrite_legacy_chain(m.group(3), m.group(2), active_schedule_id)
    line = LEGACY_CHAIN_PAT.sub(legacy_repl, line)

    # Protect existing markdown links so we don't re-wrap them.
    placeholders = {}

    def stash(m):
        key = "\x00MD%d\x00" % len(placeholders)
        placeholders[key] = m.group(0)
        return key

    line = MD_LINK.sub(stash, line)

    # Pass 1a: clause(s) → sec-N-M chain (always targets main body)
    def clause_repl(m):
        return m.group(1) + rewrite_chain(m.group(2), resolve_clause, active_schedule_id)
    line = CLAUSE_PAT.sub(clause_repl, line)

    # Pass 1c: paragraph(s) → schedule-namespaced ID (only inside a named schedule scope)
    def para_repl(m):
        if active_schedule_id is None:
            return m.group(0)
        return m.group(1) + rewrite_chain(m.group(2), resolve_paragraph, active_schedule_id)
    line = PARAGRAPH_PAT.sub(para_repl, line)

    # Pass 1d: Schedule(s) N → markdown link, skipping "Schedule N to <something>"
    def sched_repl(m):
        tail = line[m.end():]
        if re.match(r"\s+to\b", tail):
            return m.group(0)
        return m.group(1) + rewrite_schedule_chain(m.group(2))
    line = SCHEDULE_PAT.sub(sched_repl, line)

    # Pass 2: extend chains that follow an existing @sec-… anchor.
    # Handles author-written strings like `@sec-payment, 5.9 and 5.12` where a
    # friendly-ID Cite token kicks off the chain — link the trailing TOKENs too.
    def sec_chain_repl(m):
        return m.group(1) + rewrite_chain(m.group(2), resolve_clause, active_schedule_id)
    line = SEC_ANCHOR_CHAIN.sub(sec_chain_repl, line)

    # Restore protected markdown links
    for key, original in placeholders.items():
        line = line.replace(key, original)

    return line


# Links where the display text contains a letter suffix, e.g. [4c](#sec-sched-3-4-3).
# These are correctly targeted but the display text is stale — the document now
# uses positional numbering (4.3) not the original letter notation (4c).
LETTER_REF = re.compile(r"\[(\d+(?:\.\d+)?[a-z])\]\(#(sec-[\w-]+)\)")


def _display_from_id(sec_id):
    """Derive the rendered number string from a sec-* ID.

    sec-5-8          → "5.8"
    sec-sched-3-4-3  → "4.3"
    """
    parts = sec_id.split("-")[1:]          # drop leading "sec"
    if parts and parts[0] == "sched":
        parts = parts[2:]                  # drop "sched" and schedule number
    return ".".join(parts)


def fix_letter_refs(text):
    """Rewrite stale letter-suffix display text to match positional numbering.

    [4c](#sec-sched-3-4-3) → [4.3](#sec-sched-3-4-3)

    Returns (new_text, count) where count is the number of substitutions made.
    """
    count = 0

    def repl(m):
        nonlocal count
        new_num = _display_from_id(m.group(2))
        count += 1
        return f"[{new_num}](#{m.group(2)})"

    new_text = LETTER_REF.sub(repl, text)
    return new_text, count


def warn_letter_refs(text):
    """Print a warning for every link whose display text uses a stale letter suffix."""
    found = []
    for lineno, line in enumerate(text.splitlines(), 1):
        for m in LETTER_REF.finditer(line):
            display, sec_id = m.group(1), m.group(2)
            new_num = _display_from_id(sec_id)
            found.append((lineno, display, new_num))
    if found:
        print("NOTE: stale letter-suffix references found (link targets are correct "
              "but display text uses the old notation):", file=sys.stderr)
        for lineno, old, new in found:
            print(f"  line {lineno}: \"{old}\" → document now numbers this {new!r} "
                  f"— consider updating the source", file=sys.stderr)
        print("  Run with --fix-refs to rewrite these automatically.", file=sys.stderr)


# ── Document walker ─────────────────────────────────────────────────────────
def link_refs(text, fix_refs=False):
    """Return the input text with cross-references substituted."""
    frontmatter, body = "", text
    if text.startswith("---\n"):
        end = text.find("\n---\n", 4)
        if end != -1:
            frontmatter = text[:end + 5]
            body = text[end + 5:]

    active_schedule_id = None
    out_lines = []
    for line in body.split("\n"):
        if line.startswith("# "):
            m = H1_FRIENDLY_ID.search(line)
            active_schedule_id = m.group(1) if m else None
            out_lines.append(line)
            continue
        out_lines.append(sub_line(line, active_schedule_id))

    result = frontmatter + "\n".join(out_lines)

    if fix_refs:
        result, count = fix_letter_refs(result)
        if count:
            print(f"Fixed {count} stale letter-suffix reference(s).", file=sys.stderr)
    else:
        warn_letter_refs(result)

    return result


# ── Entry point ─────────────────────────────────────────────────────────────
def main():
    args = sys.argv[1:]
    fix_refs = "--fix-refs" in args
    paths = [a for a in args if not a.startswith("-")]

    if not paths or len(paths) > 1:
        print("Usage: link-refs.py [--fix-refs] path/to/document.qmd", file=sys.stderr)
        sys.exit(2)

    path = paths[0]
    with open(path) as f:
        text = f.read()
    with open(path, "w") as f:
        f.write(link_refs(text, fix_refs=fix_refs))
    print("Linker done:", path)


if __name__ == "__main__":
    main()
