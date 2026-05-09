> **STOP — do not read the source file yet.** Read every instruction below before
> taking any action. The source file path is provided by the user. You will be
> told exactly when and how to access it.

# Task: Convert a Markdown legal document → Quarto (.qmd)

This is a structural reformatting task. The goal is to produce a `.qmd` file
whose body content is **identical** to the source in wording, but whose heading
structure and layout are **uniform** — every clause at a given level looks the
same regardless of how the original author chose to write it.

The Lua filter (`legal-numbering.lua`) handles legal numbering, cross-references,
the table of contents, and the execution block at render time. Your job is only
to produce well-structured Markdown for it to consume.

The output file has the same base name as the source but a `.qmd` extension.

---

## Mental model — read this once, then keep it in mind

Three ideas drive the whole conversion:

**1. Find the document's parts before doing anything else.**
A legal document is a sequence of self-contained parts: the main contract body,
then one or more schedules. Each part resets numbering at H1. The first job is
to identify where each part starts and ends. If the boundary detection is wrong,
everything downstream is wrong. Detection is delegated to a scan sub-agent and
shown to the user before conversion begins.

**2. Read indentation, not numbers.**
The numbers and letters that appear in the source (`1.`, `1.1`, `(a)`, `(i)`)
are ornamental and may be wrong, missing, or out of order. The structure is
encoded in the **leading whitespace** of each line. Within each part, identify
the indent depth that means "clause" (H2), the depth that means "sub-clause"
(H3), and so on, then map every line to its level by indentation alone. Strip
the source's literal numbering — the Lua filter will renumber from the heading
hierarchy.

**3. Layout choices are the user's, not the author's.**
Lawyers write clause headings in several shapes:
- Title only: `1. Capacity and effect`
- Title with body inline: `1. **Title:** body text on the same line`
- Title with body paragraph below: title on one line, body on the next
- Body only with no title

Different lawyers do it differently, and the **same document often mixes
shapes** — the main contract uses one convention, a schedule uses another.
Your task is to normalise the document to one consistent layout per heading
level, chosen by the user at the start. Bold markers in the source are
typographical hints (*"this is a title"*) rather than literal formatting to be
preserved character-for-character — when normalising to a layout that does not
use bold titles, strip them.

---

## What is permitted to change

1. Add `#` markers to set each clause's heading level
2. Strip the leading numbering label (`1.`, `1.1`, `(a)`, `(i)`)
3. Strip or preserve `**` bold markers around clause titles per the chosen layout
4. Move body text from the heading line to a paragraph below (or vice versa) per the chosen layout
5. Convert title capitalisation per the user's chosen rules
6. Place the colon inside or outside the bold per the user's chosen rule
7. Join lines broken mid-sentence by Word/Google Docs export wrapping
8. Append `{#sec-sched-N}` to schedule H1 headings

## What is forbidden

- Do not change any wording within body text
- Do not reorder content
- Do not split or merge sentences
- Do not invent titles, labels, or content not in the source
- Do not assign `{#sec-*}` IDs to H2–H5 — the Lua filter does that automatically
- Do not write hyperlinks to schedules, clauses, or sections — the Phase 2.6 linker does that
- Do not preserve bold markers that appear *only* as title hints when the chosen layout does not use bold

---

## MANDATORY EXECUTION PROTOCOL

> **Anti-paralysis rule:** Creating the output stub is your **absolute first
> action** — before reading the source, before any analysis. Do NOT read the
> source document yourself at any point. You are the orchestrator: you delegate
> scanning to a sub-agent (Phase 1), consult the user (Phase 1.5), then fan out
> body transcription to sub-agents (Phase 2). After Phase 1.5 confirmation, your
> next action is an **immediate parallel fan-out** — one main-contract Agent
> call and one Agent call per included schedule, all dispatched in a single
> message.

> **Orchestrator contract:** Sub-agents return text strings only — they never
> call Write or Edit. The orchestrator makes exactly **two** Write calls: the
> empty stub in Phase 0, and the assembled document in Phase 2.5.
> If a sub-agent returns output that is malformed or contains commentary instead
> of clean markdown, do NOT use that output. Re-spawn it with an improved
> prompt (see Orchestrator recovery below). Maximum 2 retries per sub-agent;
> on third failure, do that section yourself using the serial method.

---

### Phase 0 — Pre-flight, output stub (do this before reading any file)

**Step 0a — Normalise source file line ending:**

Run the following command (replacing `SOURCE_FILE` with the actual path):
```bash
[ -z "$(tail -c 1 SOURCE_FILE)" ] || printf '\n' >> SOURCE_FILE
```
This appends a POSIX-standard trailing newline if the file lacks one, ensuring
that `wc -l` and the Read tool's line numbering agree throughout all subsequent
phases. If the file was modified, print:
> Source normalised: trailing newline added to [source filename]

Otherwise proceed silently.

**Step 0b — Create output stub:**

Derive the output filename from the source filename (same base name, `.qmd`
extension).

**Check whether the output file already exists** using Bash:
```bash
test -f <output-filename> && echo EXISTS || echo NEW
```

- **If NEW:** call `Write` immediately with a single newline at that path,
  then print:
  > Output stub created: [filename]

- **If EXISTS:** print the following and **wait for the user to reply before proceeding**:
  > ⚠ [filename] already exists. Choose:
  > - **replace** — the existing file will be emptied and overwritten
  > - **rename** — provide a new output filename to use instead

  Then handle the reply:
  - *replace* → run `bash -c "> <output-filename>"` to truncate the file to
    zero bytes (this is a clean empty, not a Write — avoids any merge with
    existing content), then print:
    > Existing file emptied. Proceeding with [filename]
  - *rename* → use the filename the user provides as the output path for all
    subsequent phases; call `Write` with a single newline at that new path,
    then print:
    > Output stub created: [new-filename]

---

### Phase 1 — Delegate scan to sub-agent

Spawn **one sub-agent** with model `haiku` using the scan prompt template
below. The sub-agent reads the source file as a typist — pattern-matching only,
no interpretation. It returns a structured JSON object and does NOT write to
any file.

**Print to chat before spawning:**
> Scanning [source filename] via sub-agent…

**Scan sub-agent prompt template:**

```
You are a typist, not a reader. Your only job is to extract structural patterns
from a markdown file. Do not read for understanding. Do not interpret legal
content.

## Source file to scan

Read this file: {{SOURCE_FILE_PATH}}

## What to extract

### A. Preamble

Identify all content before the first real numbered section. This includes:
- The document title (first non-blank line of the file)
- Any subtitle, company number, or reference on the following lines
- Table of contents blocks: lines containing markdown links `[text](#anchor)`,
  lines reading `**TABLE OF CONTENTS**`, `**Contents**`, etc.
- A bare `# ` line with no heading text (Google Docs page-break artefact)
- Any instructional notes for the reader

Record the 1-indexed line number of the last preamble line as `preamble_end_line`.
If there is no preamble, set `preamble_end_line` to 0.

### B. Major document parts

A "part" is a block that starts a new logical section. Identify each by scanning for:

1. A markdown H1 line `# Non-empty text` — this is already a proper part heading.
2. A bare text line matching `Schedule N` (where N is a digit) not preceded by
   `#` — look at the very next non-blank line: if it is `**bold text**`, that
   bold text is the subtitle. Combine them as `Schedule N: Bold subtitle text`
   (stripping the `**`).
3. A line starting with `Annexure`, `Appendix`, `Part`, `Exhibit` followed by a
   number or letter — treat it as a schedule-type part.

For each part record:
- `name`: the full heading text (e.g. `Schedule 1: Calls, forfeiture and liens`)
- `type`: `"main"` for the primary document body, `"schedule"` for schedules/annexures
- `n`: schedule number as an integer (for schedule-type parts only; omit for main)
- `start_line`: 1-indexed line number where this part begins
- `end_line`: 1-indexed line number of the last line before the next part
  (use `total_lines` for the last part)

### C. Indentation hierarchy per part

For each part, scan the first 60 lines of its body and identify the indentation
hierarchy. Look for lines that begin with one or more spaces followed by a
digit-and-period (`N.`), a parenthesised letter (`(a)`), or a parenthesised
roman numeral (`(i)`).

Record:
- `h2_indent`: leading-space count for the shallowest numbered items (these become H2)
- `indent_step`: additional spaces per nesting level (typically 3)

Note: the literal numbering (1, 2, 3) does not matter — use indentation alone.
A line with 3 leading spaces is at one level deeper than a line with 0 leading
spaces, regardless of whether it is numbered `1.`, `7.`, or `(a)`.

### D. Clause shape per part (H2 and H3)

For each part, classify clauses at the H2 and H3 indent level by their
**shape** — independent of capitalisation:

H2 shapes (count occurrences of each in the first 80 lines of the part body):
- `title_only`: line is `[indent]N. Title` — title only, no body, no bold
  (e.g. `1. Capacity and effect`)
- `bold_label_only`: line is `[indent]N. **Title**` — bold label only, no body
  (e.g. `1. **CALLS ON SHARES**`)
- `bold_inline_body`: line is `[indent]N. **Title:** body` or `[indent]N. **Title**: body`
  — bold label and body text on the same line
  (e.g. `1. **TRANSFER NOTICE**: A Shareholder proposing…`)
- `plain_body`: line has no clear title — just a numbered paragraph
  (e.g. `1. Subject to clauses 2.2 and 2.3, the Board may…`)

Same for H3 shapes (using the H3 indent level).

Record:
- `h2_shapes`: object with each shape as key and integer count as value
- `h3_shapes`: object with each shape as key and integer count as value
- `h2_dominant`: the most common shape ("title_only", "bold_label_only", "bold_inline_body", "plain_body")
- `h3_dominant`: the most common shape

### E. Title capitalisation observed (H2)

For each part, examine the H2 titles. Record `h2_caps` as one of:
- `"all_caps"` — most H2 titles are ALL CAPS (e.g. `CALLS ON SHARES`)
- `"mixed"` — H2 titles are mixed case (e.g. `Capacity and effect`)

Same for `h3_caps` at the H3 level (looking at the bold label content if bold,
otherwise the leading text).

### F. Total lines

Set `total_lines` to the exact count of lines in the file.

## Output format

Return ONLY a raw JSON object — no markdown fences, no code blocks, no
commentary. Start your response with `{` and end with `}`.

{
  "title": "Constitution of Peanut Butter Collective Limited",
  "subtitle": "Company number: 9423987",
  "preamble_end_line": 54,
  "parts": [
    {
      "name": "Constitution",
      "type": "main",
      "start_line": 55,
      "end_line": 455,
      "h2_indent": 0,
      "indent_step": 3,
      "h2_shapes": {"title_only": 18, "bold_inline_body": 0, "bold_label_only": 0, "plain_body": 0},
      "h3_shapes": {"title_only": 0, "bold_inline_body": 75, "bold_label_only": 0, "plain_body": 2},
      "h2_dominant": "title_only",
      "h3_dominant": "bold_inline_body",
      "h2_caps": "mixed",
      "h3_caps": "mixed"
    },
    {
      "name": "Schedule 1: Calls, forfeiture and liens",
      "type": "schedule",
      "n": 1,
      "start_line": 456,
      "end_line": 531,
      "h2_indent": 0,
      "indent_step": 3,
      "h2_shapes": {"title_only": 0, "bold_inline_body": 0, "bold_label_only": 3, "plain_body": 0},
      "h3_shapes": {"title_only": 0, "bold_inline_body": 22, "bold_label_only": 0, "plain_body": 0},
      "h2_dominant": "bold_label_only",
      "h3_dominant": "bold_inline_body",
      "h2_caps": "all_caps",
      "h3_caps": "mixed"
    },
    {
      "name": "Schedule 3: Pre-emptive rights on transfer",
      "type": "schedule",
      "n": 3,
      "start_line": 604,
      "end_line": 679,
      "h2_indent": 3,
      "indent_step": 3,
      "h2_shapes": {"title_only": 0, "bold_inline_body": 11, "bold_label_only": 1, "plain_body": 0},
      "h3_shapes": {"title_only": 0, "bold_inline_body": 0, "bold_label_only": 0, "plain_body": 12},
      "h2_dominant": "bold_inline_body",
      "h3_dominant": "plain_body",
      "h2_caps": "all_caps",
      "h3_caps": "mixed"
    }
  ],
  "total_lines": 832
}

Validate before replying:
- Every part must have a positive integer `start_line` and `end_line`
- Parts must be listed in document order with no gaps: for consecutive parts,
  `end_line` + 1 must equal the next part's `start_line`; the last part's
  `end_line` must equal `total_lines` exactly (not `total_lines` − 1)
- `preamble_end_line` must be less than the first part's `start_line` (or 0)
- Schedule parts must include `n`
- Every part must have all six shape/cap fields populated
```

**After the sub-agent replies, validate the output:**
- Strip any surrounding markdown code fences before parsing.
- Must be valid JSON with `title`, `parts` (non-empty array), and `total_lines`.
- Each part must have `name`, `type`, `start_line`, `end_line`, `h2_indent`,
  `indent_step`, `h2_dominant`, `h3_dominant`, `h2_caps`, `h3_caps`.

If validation fails → apply **Orchestrator recovery**, then re-run this phase.

---

### Phase 1.5 — User consultation

Before spawning any conversion agents, print a structured summary and wait for
the user to confirm. Do NOT proceed to Phase 2 until the user replies.

**Compute indent levels** from the scan JSON for each part:

```
H2_INDENT = h2_indent
H3_INDENT = h2_indent + indent_step
H4_INDENT = h2_indent + 2 × indent_step
H5_INDENT = h2_indent + 3 × indent_step
```

**Compute the defaults** before printing the menu. The capitalisation and colon
defaults are constant; the layout defaults depend on the scan's `h2_dominant`
and `h3_dominant`:

```
a_default = 'A4'   # H1 capitalisation: preserve as in source
b_default = 'B5'   # Schedule heading prefix: preserve as in source
c_default = 'C1'   # H2 capitalisation: Title Case
d_default = 'D2' if h2_dominant == 'bold_inline_body' else 'D1'
e_default = 'E1'   # H3 capitalisation: Title Case
f_default = 'F2' if h3_dominant == 'bold_inline_body' else 'F1'
g_default = 'G1'   # Colon outside bold
```

**When printing the menu**, mark each default option's line two ways:

1. Prefix the line with `✓ ` (a tick mark in the leading-space slot) instead of two spaces.
2. Wrap the whole line (after the tick) in `**...**` so it renders bold.

Every non-default line keeps its plain two-space prefix and no bold. The user
sees exactly one ticked + bolded option per question — that's what "defaults"
will apply.

**Print to chat:**

```
## Document structure detected

**Metadata** (will go in YAML front matter):
- Title: "[title from scan]"
- Subtitle/identifier: "[subtitle from scan, or "none"]"

**Parts found:**

| # | Name | Lines | H2 shape · case | H3 shape · case | Include? |
|---|------|-------|------|------|----------|
| — | Preamble | 1–[preamble_end_line] | — | — | YAML only |
| 1 | [part 1 name] | [start]–[end] | [h2_dominant] · [h2_caps] | [h3_dominant] · [h3_caps] | YES |
| 2 | [part 2 name] | [start]–[end] | [h2_dominant] · [h2_caps] | [h3_dominant] · [h3_caps] | YES |

**Indent → heading mapping** (per part — indentation may differ across parts):
  [H2_INDENT] spaces → ## Clause      `1.` `2.` `3.`
  [H3_INDENT] spaces → ### Sub-clause `1.1` `1.2` `1.3`
  [H4_INDENT] spaces → #### Item      `(a)` `(b)` `(c)`
  [H5_INDENT] spaces → ##### Sub-item `(i)` `(ii)` `(iii)`

---

## Style choices

Each question below uses the same option-number scheme:
- Capitalisation (A, C, E): 1 = Title Case, 2 = ALL CAPS, 3 = sentence case, 4 = preserve as in source
- Schedule prefix (B):      1 = colon, 2 = em-dash, 3 = closing paren, 4 = square brackets, 5 = preserve as in source
- Layout (D, F):            1 = split, 2 = inline
- Colon (G):                1 = outside bold, 2 = inside bold

**Capitalisation** sets the casing applied to every title at that heading level,
regardless of how the source author wrote it. *Preserve as in source* is the
only option that lets source casing flow through unchanged.

**Layout** is how a clause with both a title and body text is rendered:
- *Split* — title alone on the heading line, body as a paragraph below.
- *Inline* — bold title and body on the same heading line, separated by a colon.

**Colon position** applies inside inline layout — whether the colon sits
outside the closing `**` (`**Title**:`) or inside it (`**Title:**`).

Reply with **defaults** to accept the bolded option in each question. To override,
list overrides only (e.g. **A1 D2**) — the rest stay on defaults.

---

**A. H1 — document and part title capitalisation**

  A1  Title Case
  A2  ALL CAPS
  A3  sentence case
  A4  preserve as in source

**B. Schedule heading prefix style**

  B1  `Schedule 4: Pre-emptive rights on transfer`        (colon)
  B2  `Schedule 4 — Pre-emptive rights on transfer`       (em-dash, with surrounding spaces)
  B3  `Schedule 4) Pre-emptive rights on transfer`        (closing paren)
  B4  `[Schedule 4] Pre-emptive rights on transfer`       (square brackets, then space)
  B5  preserve as in source

**C. H2 — clause title capitalisation**

  C1  Title Case
  C2  ALL CAPS
  C3  sentence case
  C4  preserve as in source

**D. H2 — clause layout**

  D1  split
  D2  inline

**E. H3 — sub-clause label capitalisation**

  E1  Title Case
  E2  ALL CAPS
  E3  sentence case
  E4  preserve as in source

**F. H3 — sub-clause layout**

  F1  split
  F2  inline

**G. Colon position**

  G1  outside the bold
  G2  inside the bold

---

Reply with **defaults**, list overrides (e.g. **A1 D2**), then either:
- **ok** — proceed with all parts as listed
- **exclude N** — skip parts by row number (e.g. "exclude 4, 5")
- Any corrections to names or detected structure

I will not begin conversion until you confirm.
```

Wait for the user's reply. Parse it:

**Structure choices:**
- "ok" / "defaults" → proceed with all parts included
- "exclude N" → mark those parts as excluded; do not spawn sub-agents for them
- Any correction → adjust and confirm back before proceeding

**Style choices** — record the user's selections and translate them into the
explicit rule strings below. These are filled into the sub-agent prompts as
`{{H1_CASE_RULE}}`, `{{SCHEDULE_PREFIX_RULE}}`, `{{CLAUSE_CASE_RULE}}`,
`{{H2_LAYOUT_RULE}}`, `{{SUBCLAUSE_LABEL_RULE}}`, `{{H3_LAYOUT_RULE}}`,
`{{COLON_RULE}}`.

The capitalisation rules apply to **every** title at that level, regardless of
how the source author wrote it. The "preserve as in source" option (A4 / C4 /
E4) is the only one where source casing flows through unchanged — every other
option enforces a single end-goal style across the whole document.

| Choice | Rule text to use |
|--------|------------------|
| A1 | Render every H1 title in **Title Case** (capitalise every word). |
| A2 | Render every H1 title in **ALL CAPS**. |
| A3 | Render every H1 title in **sentence case** (first word capitalised, rest lowercase except proper nouns). |
| A4 | **Preserve as in source** — copy each H1 title's casing exactly from the source. |
| B1 | Separate `Schedule N` from the title with `: ` (colon-space). Apply the A case rule to the entire heading string. |
| B2 | Separate `Schedule N` from the title with ` — ` (space, em-dash U+2014, space). Apply the A case rule to the entire heading string. |
| B3 | Separate `Schedule N` from the title with `) ` (closing-paren-space). Apply the A case rule to the entire heading string. |
| B4 | Separate `Schedule N` from the title with `] ` (rendered as `[Schedule N] title`). Apply the A case rule to the entire heading string. |
| B5 | **Preserve as in source** — copy the separator between `Schedule N` and the title exactly from the source; then apply the A case rule. |
| C1 | Render every H2 clause title in **Title Case**. |
| C2 | Render every H2 clause title in **ALL CAPS**. |
| C3 | Render every H2 clause title in **sentence case**. |
| C4 | **Preserve as in source** — copy each H2 clause title's casing exactly from the source. |
| D1 | H2 split: for every H2 *that has a title in the source*, render the title alone on the heading line and body (if any) as a paragraph below. Strip leading numbering and wrapping `**` bold. Apply C to the title text. **For every H2 that has no title in the source, render the body as plain paragraph(s) under the parent heading — never invent a title.** |
| D2 | H2 inline: for every H2 *that has a title in the source*, render `## **Title**: body text` on a single heading line. Apply C to the title text. Apply G for colon position. Clauses without body remain `## **Title**`. **For every H2 that has no title in the source, render the body as plain paragraph(s) under the parent heading — never invent a title.** |
| E1 | Render every H3 sub-clause label in **Title Case**. |
| E2 | Render every H3 sub-clause label in **ALL CAPS**. |
| E3 | Render every H3 sub-clause label in **sentence case**. |
| E4 | **Preserve as in source** — copy each H3 sub-clause label's casing exactly from the source. |
| F1 | H3 split: for every H3 *that has a title in the source*, render the title alone on the heading line and body (if any) as a paragraph below. Strip leading numbering and wrapping `**` bold. Apply E to the title text. **For every H3 that has no title in the source, render `### body text` — never invent a title.** |
| F2 | H3 inline: for every H3 *that has a title in the source*, render `### **Title**: body text` on a single heading line. Apply E to the title text. Apply G for colon position. **For every H3 that has no title in the source, render `### body text` — never invent a title.** |
| G1 | Colon outside the bold: write `**Title**:` (colon after the closing `**`). |
| G2 | Colon inside the bold: write `**Title:**` (colon before the closing `**`). |

**Computing `{{SCHEDULE_HEADING}}` for each schedule sub-agent (Phase 2 pre-rendering):**

Parse each schedule's source heading into three components: the word `Schedule`,
the schedule number N, and the title text. Identify the separator used in the
source (colon, em-dash, closing paren, square brackets, or other).

Apply the chosen B rule:
- B1 → `Schedule N: Title text`
- B2 → `Schedule N — Title text`  (em-dash U+2014 with surrounding spaces)
- B3 → `Schedule N) Title text`
- B4 → `[Schedule N] Title text`
- B5 → Reconstruct using the separator found in the source

Then apply the chosen A case rule to the **entire resulting heading string**
(the `Schedule N` prefix and the title text are treated as one string for casing
purposes). The schedule sub-agent receives `{{SCHEDULE_HEADING}}` already fully
formatted and must preserve it verbatim in its H1 line.

If the user replies "defaults", apply the computed defaults: `a_default`,
`b_default`, `c_default`, `d_default`, `e_default`, `f_default`, `g_default`.

---

### Phase 2 — Fan-out conversion agents

After user confirmation, compute line ranges and spawn all conversion sub-agents
in a **single message** (one for the main contract + one per included schedule).

**Computing line ranges for each part:**
```
offset = start_line - 1   (Read tool uses 0-indexed offset)
limit  = end_line - start_line + 1
```

**Fill the sub-agent prompt placeholders** before dispatching:
- `{{SOURCE_FILE_PATH}}` — the source file path
- `{{OFFSET}}`, `{{LIMIT}}`, `{{FIRST_LINE}}`, `{{LAST_LINE}}` — computed above
- `{{DOCUMENT_TITLE}}`, `{{DOCUMENT_SUBTITLE}}` — from scan JSON
- `{{H1_TEXT}}` — the `name` field of the main part (or document title if `name` is empty)
- `{{SECTION_LIST}}` — list each top-level clause with its source line range
- `{{H2_INDENT}}`, `{{H3_INDENT}}`, `{{H4_INDENT}}`, `{{H5_INDENT}}` — computed
- `{{SCHEDULE_NUMBER}}`, `{{SCHEDULE_HEADING}}` — for schedule sub-agents; `{{SCHEDULE_HEADING}}` is pre-rendered by the orchestrator per the chosen B + A rules (see Phase 1.5 pre-rendering instructions above)
- `{{START_LINE}}`, `{{END_LINE}}` — for schedule sub-agents
- `{{H1_CASE_RULE}}` — A1, A2, A3, or A4 rule text
- `{{SCHEDULE_PREFIX_RULE}}` — B1–B5 rule text (used by orchestrator when computing `{{SCHEDULE_HEADING}}`; not sent directly to sub-agents)
- `{{CLAUSE_CASE_RULE}}` — C1, C2, C3, or C4 rule text
- `{{H2_LAYOUT_RULE}}` — D1 or D2 rule text
- `{{SUBCLAUSE_LABEL_RULE}}` — E1, E2, E3, or E4 rule text
- `{{H3_LAYOUT_RULE}}` — F1 or F2 rule text
- `{{COLON_RULE}}` — G1 or G2 rule text

**Print to chat before spawning:**
> Confirmed. Launching [N] conversion sub-agents…

---

### Phase 2.5 — Assemble the document

Once all sub-agents have replied, clean and validate each chunk, then call Write
directly to concatenate all validated chunks with one blank line between each.

**Step 1 — Pre-validation cleanup (do this before any validation check):**

For each chunk:
1. Strip any `<!-- agent-notes -->` marker and everything after it — sub-agents
   may append notes there; that content must never enter the assembled document.
2. Strip any lines that appear before the first `---` line (main contract) or
   before the first `# Schedule N:` line (schedule chunks).

If lines were stripped in step 2, log a soft warning to chat — this is NOT a retry:
> ⚠ Stripped [N] commentary line(s) from [section] — content valid, proceeding.

**Step 2 — Validate the main contract chunk:**
- Must start with `---` (YAML frontmatter opening)
- Must contain `# [title]` as the first body H1
- Must have `## [clause title]` for every top-level clause in order
- Must not contain `<!-- TODO -->` placeholders or `{{` / `}}`
- Must not contain bold-numbered paragraphs at any level — check for both
  `**N.N Title:**` (sub-clause) and `**N. TITLE:**` (clause) patterns; all
  numbered items must be headings
- If D1 (H2 split) was chosen: no `## **` heading should remain
- If F1 (H3 split) was chosen: no `### **` heading should remain
- The chosen capitalisation (A, C, E) must be applied uniformly — including
  inside any `**...**` markers that survive (e.g. if C1 was chosen, no
  ALL-CAPS H2 title should appear, including bolded ones)

**Step 3 — Validate each schedule chunk:**
- Must start with `# Schedule N:` including the full title text
- That H1 line must contain `{#sec-sched-N}` — **hard fail** if missing
- Must NOT have a self-link like `[Schedule N](#sec-sched-N)` in the H1 — **hard
  fail** if present; a self-link causes broken CSS rendering (underline, wrong
  font) in the output HTML
- Must NOT have a bold-text paragraph directly after the H1 (the subtitle
  belongs in the H1)
- Same layout/case checks as for the main contract

If a chunk fails validation after cleanup → apply **Orchestrator recovery**,
re-spawn that sub-agent only.

**Print to chat before writing:**
> All chunks received. Writing assembled document…

After the Write call:
> Done — [output filename] written.

---

### Phase 2.5.5 — Completeness verification (Bash)

**Print to chat before running:**
> Checking completeness…

```bash
python3 verify-counts.py ACTUAL_SOURCE_PATH ACTUAL_OUTPUT_FILE_PATH
```

The script (`verify-counts.py`) is a tracked file in the repo — DO NOT inline
its source here, and DO NOT regenerate it. Run it exactly as shown above.

**Interpreting results:**

- **FAIL** lines (exit code 1): H1 section count does not match. Stop and
  investigate — the assembled document is missing or has extra top-level
  sections. Apply **Orchestrator recovery** before proceeding.
- **WARN** lines (exit code 0): The output has fewer total headings than the
  source has numbered items in a section, OR the word-count ratio for a section
  is outside the expected range. Read each warning carefully:
  - A warning on a schedule section almost certainly indicates missing content
    — check the source and output side-by-side for that section and re-run the
    affected sub-agent.
  - A warning on the main contract body may reflect structural differences
    (e.g. definition tables that expand into multiple headings) or genuinely
    missing content — review the breakdown line to distinguish.
- **OK** lines: counts match; proceed.

After the command completes with exit code 0:
> Completeness check passed. Proceeding to cross-reference substitution.

If exit code is 1:
> Completeness check FAILED — [paste FAIL lines]. Investigating before continuing.

---

### Phase 2.6 — Cross-reference substitution (Bash)

**Print to chat before running:**
> Assembled. Running cross-reference linker…

```bash
python3 link-refs.py ACTUAL_OUTPUT_FILE_PATH
```

The linker is a tracked file in the repo (`link-refs.py`) — DO NOT inline its
source here, and DO NOT regenerate it from this prompt. Read its docstring if
you need to understand what it does, and run it as shown above. If you find
a bug, fix it in `link-refs.py` itself, not in a copy.

After the command completes:
> Cross-references substituted. Proceeding to render.

If Python is unavailable, fall back to a linker sub-agent (model `haiku`)
instructed to make a **single Write call** — read the file, apply all
substitutions in memory, write once.

---

### Phase 3 — Render and verify

Run `quarto render <output-file>` and check the HTML output.

**Print to chat:**
> Render complete. [Pass/Fail — and if fail, what to fix.]

Check the rendered HTML for:
- All numbered sections present and in order
- No raw `@sec-*` text visible in body paragraphs (all resolved to clickable links)
- Schedule H1 headings show the full title (the Lua filter naturally skips
  numbering on H1)
- No bold-numbered paragraphs visible at any level — neither `**1.1 Title:**`
  (sub-clause) nor `**1. TITLE:**` (clause) should appear as `<p><strong>`
  elements; all should be numbered headings; when writing the HTML check
  script use `re.findall(r'<p[^>]*>.*?<strong>\d+\.', html, re.DOTALL)` to
  catch both forms
- The chosen capitalisation is applied uniformly across H1 / H2 / H3 (per A,
  C, E) — including inside any surviving `**...**` markers
- No `## **`-prefixed headings if D1 was chosen; no `### **`-prefixed headings
  if F1 was chosen
- Clause cross-references in body paragraphs are clickable links; chained
  references like `clause 5.8, 5.9 and 5.12` are fully linked (all numbers
  in the chain); `paragraph N` references inside schedules are linked to the
  schedule's namespaced ID; `section N` references (statutory) are left
  plain; cross-references that appear inside H2–H5 heading text ARE linked
  (Variant C clauses get their inline cross-refs resolved just like body text)
- No self-links in schedule H1 content — extract each H1's inner content with
  a bounded, non-DOTALL pattern (e.g.
  `re.findall(r'<h1[^>]*id="sec-sched-\d+"[^>]*>(.*?)</h1>', html)`) then
  check whether that content contains `<a href=`. Do NOT use `re.DOTALL` or
  leave the pattern open-ended: a regex like
  `<h1[^>]*>.*?<a href="#sec-sched-\d+"` with DOTALL will span from the
  document-title `<h1>` all the way into the TOC `<nav>` that follows it,
  producing false positives. Quarto's own permalink anchors (which have a
  `class` attribute) are not self-links and must not be flagged
- No `<!-- TODO -->` placeholders remaining
- Tables have proportional column widths

---

## Main contract sub-agent prompt template

```
You are a precise markdown reformatter. Your job is to transform a slice of a
Markdown legal document into Quarto (.qmd) format, applying user-chosen layout
and capitalisation rules consistently.

## How to think about this task

The source document is a sequence of numbered clauses written by a human author.
The numbering and bullet labels in the source are ornamental — what matters is
the **indentation depth** of each line. The Lua filter at render time will
re-number everything based on heading hierarchy.

Your three steps for each line:

1. Look at the leading whitespace to decide the heading level (H2/H3/H4/H5).
2. Strip the leading numbering label.
3. Apply the chosen layout rule for that level (split or inline) and the chosen
   capitalisation rule.

Bold markers (`**...**`) wrapping a clause title are typographical hints from
the source author — they say "this is a title". When the chosen layout strips
the title onto its own heading line (split / Variant B), drop the wrapping
bold. When the chosen layout keeps the title inline with body text (inline /
Variant C), preserve the wrapping bold and place the colon per the colon rule.

Bold within body text (e.g. defined terms like `**Sale Shares**` mid-sentence)
is content — preserve it character-for-character.

## Source file and line range

Source file: {{SOURCE_FILE_PATH}}

Read the main contract body using the Read tool with:
  offset: {{OFFSET}}   (0-indexed; = first section start_line - 1)
  limit:  {{LIMIT}}

This covers source lines {{FIRST_LINE}}–{{LAST_LINE}} inclusive.

## Sections to convert

{{SECTION_LIST}}

## Indentation pattern for this part

Use these indent depths exactly. Do not infer other values.

| Leading spaces | Level | Heading |
|----------------|-------|---------|
| {{H2_INDENT}}  | Clause     | `##`    |
| {{H3_INDENT}}  | Sub-clause | `###`   |
| {{H4_INDENT}}  | Item       | `####`  |
| {{H5_INDENT}}  | Sub-item   | `#####` |

## Layout and capitalisation rules (chosen by the user — apply to every clause)

- **H2 layout:** {{H2_LAYOUT_RULE}}
- **H3 layout:** {{H3_LAYOUT_RULE}}
- **Colon position (inline variant only):** {{COLON_RULE}}
- **H1 title capitalisation:** {{H1_CASE_RULE}}
- **H2 clause title capitalisation:** {{CLAUSE_CASE_RULE}}
- **H3 sub-clause label capitalisation:** {{SUBCLAUSE_LABEL_RULE}}

These are not suggestions. Every H2 and H3 in your output must follow the
chosen layout and case rules — even if the source had a different shape.

## Detecting whether a clause has a title

Before applying any layout rule, decide for each H2 / H3 source line whether it
has a title. The test is **mechanical and binary**:

- The source line **has a title** if, after the leading number prefix
  (`1.`, `2.1`, `(a)`, etc.) and any whitespace, the next non-whitespace
  character begins a **`**…**` bold span** OR begins a **plain title phrase
  immediately followed by a newline** (i.e. body text, if any, lives on
  subsequent lines, not on the same line).
- The source line **has no title** if, after the leading number prefix, the
  next text is plain prose (running sentence — including parenthetical defined
  terms like `**Sale Shares**` mid-sentence) that flows directly into a
  paragraph or list item.

A `**bold span**` mid-sentence (e.g. `the proposed sale price (**Proposed Sale
Terms**)`) is a defined term, **not** a title. Titles live at the *start* of
the line, after the number prefix and before any other content.

When a source line has no title, you do not have permission to synthesise one
— not from the first words of the sentence, not from a defined term inside
parentheses, not from any pattern. Render it as plain `### body text`
(or `## body text`) regardless of the chosen layout rule. The layout rule
only governs how titled clauses are rendered.

## Per-level rules

**H1 (document title)** — write `# {{H1_TEXT}}` once, before all sections.
Apply {{H1_CASE_RULE}} to the title text. No section number. No `{#sec-*}` ID.

**H2 (clause)** — apply {{H2_LAYOUT_RULE}}. The chosen layout governs:
- whether the title appears alone or with body inline,
- whether bold markers around the title are kept,
- where body text goes (heading line vs paragraph below),
- where the colon goes (only relevant for inline variant).
Apply {{CLAUSE_CASE_RULE}} to the title text. Strip the leading `N. `.
No `{#sec-*}` ID.

**H3 (sub-clause)** — apply {{H3_LAYOUT_RULE}}. Same considerations as H2.
Apply {{SUBCLAUSE_LABEL_RULE}} to the title text. Strip the leading clause
number (e.g. `1. `, `2.1 `). No `{#sec-*}` ID.

**H4 (item)** — `#### text`. Strip the leading label `(a)`, `1.`, etc. No ID.
H4 items are typically plain text; do not invent bold titles.

**H5 (sub-item)** — `##### text`. Strip the leading label. No ID.

Section IDs are assigned automatically by the Lua filter. Never write `{#sec-*}`
on H2–H5.

## Flat or body-only clauses

If a clause has no title — only flat body text or a flat list:
- Render the body as one or more plain paragraphs directly under the H2 / H3.
- Do NOT invent a title.
- Do NOT promote the first sentence to a title.

## Continuation paragraphs

If a clause has a numbered list of items followed by additional body text that
is not itself a numbered item, include the trailing text as a plain paragraph
after the last item. Do not make it a heading.

## Cross-references

Leave all `clause N.M` and `Schedule N` references as plain text. The Phase 2.6
linker substitutes them after assembly.

## CRITICAL — copy body text verbatim

Every word in body paragraphs must appear in the same order as the source.
Do not paraphrase, simplify, or reorder. The only changes permitted to body
text are: (1) joining lines broken mid-sentence by Word/Google Docs wrapping,
and (2) the layout transformations defined by the rules above.

## CRITICAL — single curly braces

Write `{#sec-sched-1}` not `{{#sec-sched-1}}`. Never double the braces.
The `{{PLACEHOLDER}}` pattern in this prompt is the orchestrator's syntax —
it is not the syntax for heading IDs in your output.

## Worked examples — apply the chosen rules

Source (H2 at 0 spaces, H3 at 3 spaces, H4 at 6 spaces, H5 at 9 spaces):

```
1. Capacity and effect

   1. **Rights, powers and duties:**  The Company, the Board, each Director and
      each Shareholder have the rights, powers, duties and obligations set out
      in the Act.

2. Rights attaching to Shares

   1. **Shares:**  Subject to clauses 2.2 and 2.3, a Share is an ordinary share
      in the Company and confers on the holder:

      1. the right to one vote on a poll at a meeting:

         1. to appoint or remove a Director;

         2. to alter the constitution.
```

Output if {{H2_LAYOUT_RULE}} = D1 (split) and {{H3_LAYOUT_RULE}} = F2 (inline):

```markdown
## Capacity and effect

### **Rights, powers and duties**: The Company, the Board, each Director and each Shareholder have the rights, powers, duties and obligations set out in the Act.

## Rights attaching to Shares

### **Shares**: Subject to clauses 2.2 and 2.3, a Share is an ordinary share in the Company and confers on the holder:

#### the right to one vote on a poll at a meeting:

##### to appoint or remove a Director;

##### to alter the constitution.
```

Output if {{H2_LAYOUT_RULE}} = D2 (inline) and {{H3_LAYOUT_RULE}} = F1 (split):

```markdown
## Capacity and effect

### Rights, powers and duties

The Company, the Board, each Director and each Shareholder have the rights, powers, duties and obligations set out in the Act.

## Rights attaching to Shares

### Shares

Subject to clauses 2.2 and 2.3, a Share is an ordinary share in the Company and confers on the holder:

#### the right to one vote on a poll at a meeting:

##### to appoint or remove a Director;

##### to alter the constitution.
```

Note in both outputs: items at H4 / H5 are plain text (no bold), `clause 2.2`
remains unlinked (the linker handles it), body text is copied verbatim, and
the leading `1.`, `(a)`, etc. are stripped.

## Pre-output self-check

Before emitting your response, scan every `## **...**` and `### **...**` you
wrote and verify the bold-text content appears verbatim at the *start* of the
matching source line (after the number prefix). If the bold text was not at
the start of the source line — or did not appear in the source at all —
remove the bold span and re-render that clause as plain `## body text` or
`### body text`.

## Output format

Your response is the complete QMD content for the main contract:

```
---
title: "{{DOCUMENT_TITLE}}"
subtitle: "{{DOCUMENT_SUBTITLE}}"
---

# {{H1_TEXT}}

## [first clause — applying chosen rules]

[…]

## [last clause — applying chosen rules]
```

Start your response with `---`. No preamble, no explanation, no commentary.

If `{{DOCUMENT_SUBTITLE}}` is empty or "none", omit the `subtitle:` line.

## Passing warnings to the orchestrator

If you need to flag something (ambiguous source, an unclassifiable line, broken
numbering you cannot recover), append a single block at the very end of your
response after a line that reads exactly:

  <!-- agent-notes -->

Everything after that marker is stripped before assembly. Do NOT include any
notes, commentary, or explanation before the marker.
```

---

## Schedule sub-agent prompt template

```
You are a precise markdown reformatter. Your job is to transform a slice of a
Markdown legal schedule into Quarto (.qmd) format, applying user-chosen layout
and capitalisation rules consistently.

## How to think about this task

A schedule is a self-contained part of a legal document. Its body content
follows exactly the same heading-level rules as the main contract body — there
is no "schedule mode". Indentation determines heading level; the chosen layout
rules determine how each heading is rendered.

Bold markers (`**...**`) wrapping a clause title are typographical hints from
the source author. When the chosen layout strips the title onto its own
heading line (split / Variant B), drop the wrapping bold. When the chosen
layout keeps the title inline with body text (inline / Variant C), preserve
the wrapping bold and place the colon per the colon rule.

Bold within body text (e.g. defined terms like `**Sale Shares**` mid-sentence)
is content — preserve it character-for-character.

## Your schedule

You are converting Schedule {{SCHEDULE_NUMBER}}.
Full schedule heading: {{SCHEDULE_HEADING}}

## Source file and line range

Source file: {{SOURCE_FILE_PATH}}

Read ONLY your schedule using the Read tool with:
  offset: {{OFFSET}}   (0-indexed; = start_line - 1)
  limit:  {{LIMIT}}    (= end_line - start_line + 1)

Your schedule spans source lines {{START_LINE}}–{{END_LINE}} inclusive.
Do not read beyond line {{END_LINE}}.

## Schedule H1 heading

Your response MUST start with this exact line (substituting the full heading):

  # {{SCHEDULE_HEADING}} {#sec-sched-{{SCHEDULE_NUMBER}}}

Rules for the H1:
- **Preserve the full title text** — do NOT shorten to just `# Schedule N`; `{{SCHEDULE_HEADING}}` is already pre-rendered by the orchestrator with the chosen separator (B rule) and capitalisation (A rule) applied — copy it exactly
- **Do NOT add a self-link** — write `# Schedule 1: Full title {…}` not `# [Schedule 1](#…) {…}`
- **Do NOT place the subtitle as a separate bold paragraph** below the H1 —
  the subtitle belongs in the heading text
- The line immediately after the H1 must be an H2 heading, not a bold paragraph

## Indentation pattern for this schedule

Use these indent depths exactly. Do not infer other values.

| Leading spaces | Level | Heading |
|----------------|-------|---------|
| {{H2_INDENT}}  | Clause     | `##`    |
| {{H3_INDENT}}  | Sub-clause | `###`   |
| {{H4_INDENT}}  | Item       | `####`  |
| {{H5_INDENT}}  | Sub-item   | `#####` |

## Layout and capitalisation rules (chosen by the user — apply to every clause)

- **H2 layout:** {{H2_LAYOUT_RULE}}
- **H3 layout:** {{H3_LAYOUT_RULE}}
- **Colon position (inline variant only):** {{COLON_RULE}}
- **H1 title capitalisation:** {{H1_CASE_RULE}}
- **H2 clause title capitalisation:** {{CLAUSE_CASE_RULE}}
- **H3 sub-clause label capitalisation:** {{SUBCLAUSE_LABEL_RULE}}

These are not suggestions. Every H2 and H3 in your output must follow the
chosen layout and case rules — even if the source had a different shape.
Pay special attention: legal schedules often use ALL-CAPS bold titles
(`**TRANSFER NOTICE**`). Your case rule applies to the **contents inside the
bold markers**, not just unwrapped text. If the rule is title case, the
output title must be `Transfer Notice`, not `TRANSFER NOTICE`.

## Detecting whether a clause has a title

Before applying any layout rule, decide for each H2 / H3 source line whether it
has a title. The test is **mechanical and binary**:

- The source line **has a title** if, after the leading number prefix
  (`1.`, `2.1`, `(a)`, etc.) and any whitespace, the next non-whitespace
  character begins a **`**…**` bold span** OR begins a **plain title phrase
  immediately followed by a newline** (i.e. body text, if any, lives on
  subsequent lines, not on the same line).
- The source line **has no title** if, after the leading number prefix, the
  next text is plain prose (running sentence — including parenthetical defined
  terms like `**Sale Shares**` mid-sentence) that flows directly into a
  paragraph or list item.

A `**bold span**` mid-sentence (e.g. `the proposed sale price (**Proposed Sale
Terms**)`) is a defined term, **not** a title. Titles live at the *start* of
the line, after the number prefix and before any other content.

When a source line has no title, you do not have permission to synthesise one
— not from the first words of the sentence, not from a defined term inside
parentheses, not from any pattern. Render it as plain `### body text`
(or `## body text`) regardless of the chosen layout rule. The layout rule
only governs how titled clauses are rendered.

This failure mode is common with schedule sub-clauses, where every titled
neighbour tempts the agent to wrap a synthesised label around an untitled
sibling. Resist that pull.

## Per-level rules

**H2 (clause)** — apply {{H2_LAYOUT_RULE}}. Strip the leading `N. `. Apply
{{CLAUSE_CASE_RULE}} to the title text (including text inside `**...**`).
No `{#sec-*}` ID.

**H3 (sub-clause)** — apply {{H3_LAYOUT_RULE}}. Strip the leading clause
number. Apply {{SUBCLAUSE_LABEL_RULE}} to the title text (including text
inside `**...**`). No ID.

**H4 (item)** — `#### text`. Strip the leading label. No ID.

**H5 (sub-item)** — `##### text`. Strip the leading label. No ID.

## Flat or body-only clauses

If a clause has no title — only flat body text or a flat list:
- Render the body as one or more plain paragraphs directly under the H2 / H3.
- Do NOT invent a title.
- Do NOT promote the first sentence to a title.

## Cross-references

Leave all `clause N.M`, `paragraph N`, and `Schedule N` references as plain
text. The Phase 2.6 linker substitutes them after assembly.

## CRITICAL — copy body text verbatim

Every word in body paragraphs must appear in the same order as the source.
The only changes permitted to body text are: (1) joining lines broken
mid-sentence by Word/Google Docs wrapping, and (2) the layout transformations
defined by the rules above.

## CRITICAL — single curly braces

Write `{#sec-sched-1}` not `{{#sec-sched-1}}`. Never double the braces.

## Worked example — schedule with mixed source shapes

Source (H2 at 3 spaces, H3 at 6 spaces, H4 at 9 spaces):

```
# Schedule 3: Pre-emptive rights on transfer

   1. **TRANSFER NOTICE**: A Shareholder proposing to sell or transfer any
      Shares must give written notice to the Board.

   2. **CONTENTS OF TRANSFER NOTICE**: A Transfer Notice must specify:

      1. the number of Shares the Proposing Transferor intends to sell; and

      2. the proposed sale price.
```

Output if {{H2_LAYOUT_RULE}} = D1 (split), {{H3_LAYOUT_RULE}} = F2 (inline),
{{CLAUSE_CASE_RULE}} = C1 (title case), {{SUBCLAUSE_LABEL_RULE}} = E1 (title case):

```markdown
# Schedule 3: Pre-emptive rights on transfer {#sec-sched-3}

## Transfer Notice

A Shareholder proposing to sell or transfer any Shares must give written notice to the Board.

## Contents Of Transfer Notice

A Transfer Notice must specify:

### the number of Shares the Proposing Transferor intends to sell; and

### the proposed sale price.
```

Output if {{H2_LAYOUT_RULE}} = D2 (inline), other rules same:

```markdown
# Schedule 3: Pre-emptive rights on transfer {#sec-sched-3}

## **Transfer Notice**: A Shareholder proposing to sell or transfer any Shares must give written notice to the Board.

## **Contents Of Transfer Notice**: A Transfer Notice must specify:

### the number of Shares the Proposing Transferor intends to sell; and

### the proposed sale price.
```

Key points:
- Source `**TRANSFER NOTICE**` (ALL CAPS) → `Transfer Notice` (title case applied
  to the contents of the bold markers, not skipped)
- D1 split: bold dropped, body moved to paragraph below
- D2 inline: bold preserved, body kept on the heading line
- H3 sub-clauses with no source title → plain `### body text` regardless of
  H3 layout rule (no title to apply layout to)
- `{#sec-sched-3}` only on the H1 — never doubled

## Worked example — schedule with label-only H2

Source (H2 at 3 spaces, H3 at 6 spaces):

```
# Schedule 1: Calls, forfeiture and liens

   1. **CALLS ON SHARES**

      1. **Shareholders must pay calls:**  Every Shareholder on receiving
         notice must pay the amount called.

      2. **Calls to apply equally:**  Unless all holders agree, a call
         applies equally.
```

Output if {{H2_LAYOUT_RULE}} = D1 (split), {{H3_LAYOUT_RULE}} = F2 (inline),
{{CLAUSE_CASE_RULE}} = C1, {{SUBCLAUSE_LABEL_RULE}} = E1, {{COLON_RULE}} = G1:

```markdown
# Schedule 1: Calls, forfeiture and liens {#sec-sched-1}

## Calls On Shares

### **Shareholders must pay calls**: Every Shareholder on receiving notice must pay the amount called.

### **Calls to apply equally**: Unless all holders agree, a call applies equally.
```

Key points:
- H2 has no body in source → `## Calls On Shares` (just the title, no body
  paragraph — there's nothing to put there)
- H2 bold from source dropped because layout = D1 (split)
- H3 inline: bold preserved, body inline, colon outside per G1

## Worked example — schedule with body-only H3 sub-clauses

This example covers the failure mode where titled siblings tempt the agent
into inventing labels for body-only sub-clauses.

Source (H2 at 3 spaces, H3 at 6 spaces):

```
# Schedule 3: Pre-emptive rights on transfer

   1. **CONTENTS OF TRANSFER NOTICE**: A Transfer Notice must specify:

      1. the number of Shares the Proposing Transferor intends to sell or
         transfer (**Sale Shares**); and

      2. the proposed sale price and terms of sale including payment terms
         (**Proposed Sale Terms**).

   2. The Board must, within 10 working days, offer the Sale Shares to the
      other Shareholders pro rata to their existing holdings.
```

Output with {{H2_LAYOUT_RULE}} = D2 (inline), {{H3_LAYOUT_RULE}} = F2 (inline),
{{CLAUSE_CASE_RULE}} = C1, {{SUBCLAUSE_LABEL_RULE}} = E1, {{COLON_RULE}} = G1:

```markdown
# Schedule 3: Pre-emptive rights on transfer {#sec-sched-3}

## **Contents Of Transfer Notice**: A Transfer Notice must specify:

### the number of Shares the Proposing Transferor intends to sell or transfer (**Sale Shares**); and

### the proposed sale price and terms of sale including payment terms (**Proposed Sale Terms**).

## The Board must, within 10 working days, offer the Sale Shares to the other Shareholders pro rata to their existing holdings.
```

Key points:
- The two H3 sub-clauses begin with plain prose (`the number of…`, `the
  proposed sale price…`) — no `**...**` at the start of the line, so they
  have **no title**. They render as plain `### body text` despite the H3
  layout being inline.
- `**Sale Shares**` and `**Proposed Sale Terms**` are defined-term spans
  inside the body — preserved character-for-character, never lifted into a
  heading.
- The second H2 (`The Board must…`) also has no title — plain prose after
  the number prefix. It renders as `## body text`, not `## **Invented
  Label**: body text`, even though its sibling H2 is titled.
- Wrong outputs to avoid:
  - `### **The Number Of Sale Shares**: the number of Shares…` ← invented
  - `### **Sale Shares**: the number of Shares…` ← lifted from a defined term

## Pre-output self-check

Before emitting your response, scan every `## **...**` and `### **...**` you
wrote and verify the bold-text content appears verbatim at the *start* of the
matching source line (after the number prefix). If the bold text was not at
the start of the source line — or did not appear in the source at all —
remove the bold span and re-render that clause as plain `## body text` or
`### body text`.

## Output format

Your response is the complete QMD content for this schedule:

```
# {{SCHEDULE_HEADING}} {#sec-sched-{{SCHEDULE_NUMBER}}}

[H2 / H3 / H4 / H5 content per chosen rules]
```

Start your response with `# Schedule`. No preamble, no explanation, no commentary.

## Passing warnings to the orchestrator

If you need to flag something (ambiguous source, an unclassifiable line, broken
numbering you cannot recover), append a single block at the very end of your
response after a line that reads exactly:

  <!-- agent-notes -->

Everything after that marker is stripped before assembly. Do NOT include any
notes, commentary, or explanation before the marker.
```

---

## Orchestrator recovery — when a sub-agent misbehaves

Apply this procedure whenever a sub-agent response fails validation:

1. **Diagnose the failure.** Print to chat:
   > Sub-agent for [section/scan] failed: [one-line description].
   > Retry [1 or 2]/2 with corrected prompt.

2. **Identify the root cause** from this list and add the fix to the prompt:

| Symptom | Fix to add to prompt |
|---|---|
| Returned explanation text ("Here is…", "I've converted…") | Phase 2.5 cleanup strips leading commentary automatically — check if the stripped chunk passes before retrying. If still failing, add: "Your response MUST start immediately with `---` (main contract) or `# Schedule N:` (schedule). No explanation, no preamble." |
| Schedule H1 missing the full title (e.g. just `# Schedule 1 {…}`) | Add: "The H1 MUST include the full title text: `# {{SCHEDULE_HEADING}} {#sec-sched-N}`. Do NOT shorten to just `# Schedule N`." |
| Schedule H1 has a self-link | Add: "Do NOT add a hyperlink inside the H1. Write it plain: `# Schedule 1: Full title {#sec-sched-1}`." |
| Schedule subtitle is a separate bold paragraph below H1 | Add: "The subtitle belongs INSIDE the H1, not below it. Output: `# Schedule 1: Full title {…}`. The next line must be an H2 heading." |
| Bold-numbered paragraphs in body (`**1.1 Title:** text` not converted to heading) | Add: "CRITICAL: `**N.N Title:** body` is NEVER a paragraph — it must become an H3 heading. Strip the number; apply the chosen H3 layout rule. Every numbered item at every level becomes a heading." |
| H2 left as bold paragraph (`**1. TITLE**: text`) | Add: "CRITICAL: `**N. LABEL**: body` at H2 indent is ALWAYS an H2 heading. Apply the chosen H2 layout rule." |
| Main contract does not start with `---` | Add: "Your response must begin with `---`. No text before it." |
| Missing H2 for one or more sections | Add: "Every section in the section list must have its own `## Title` heading." |
| Left `<!-- TODO -->` placeholders | Add: "Every section must have real body content. No placeholders." |
| Double curly braces (`{{` or `}}`) | Add: "Use single curly braces only: `{#sec-2-1}` not `{{#sec-2-1}}`." |
| H2 layout not applied (split chosen but `## **Title**: body` in output) | Add: "CRITICAL — H2 layout is {{H2_LAYOUT_RULE}}. Re-render every H2 to match this rule. Drop the wrapping bold and move body to a paragraph below if split was chosen." |
| H3 layout not applied (split chosen but `### **Title**: body` in output) | Add: "CRITICAL — H3 layout is {{H3_LAYOUT_RULE}}. Re-render every H3 to match." |
| Sub-agent invented bold labels (source is plain `N. text`, output is `### **Invented Label**: text`) | Add: "CRITICAL — never invent a title where the source has none. Plain body lines stay plain." |
| H3 still has leading number prefix (e.g. `### 4.1 Title`) | Add: "Strip any leading clause number from H3 heading text." |
| H4/H5 still has leading label | Add: "Strip the leading label from H4 / H5 headings." |
| Body text changed or simplified | Add: "CRITICAL: Copy body text verbatim. Do not paraphrase or reorder words." |
| ALL-CAPS still present after C1/E1 chosen (e.g. `## **TRANSFER NOTICE**: …`) | Add: "CRITICAL — apply the case rule to the contents INSIDE `**...**`. `**TRANSFER NOTICE**` must become `**Transfer Notice**` (or be unwrapped per layout rule)." |
| Colon position wrong | Add: "CRITICAL — colon rule: {{COLON_RULE}}. Check every inline H3 (`### **...**`) and correct." |
| H1 title case wrong | Add: "CRITICAL — H1 rule: {{H1_CASE_RULE}}. Apply to the H1 text after `Schedule N:`." |
| Scan JSON malformed | Add: "Return ONLY a raw JSON object. Start with `{` and end with `}`. No fences, no prose." |
| Scan missed preamble (ToC links, blank `# `) | Add: "Preamble includes: `[text](#anchor)` link lines, `**TABLE OF CONTENTS**` / `**Contents**`, bare `# ` empty headings. Set `preamble_end_line` to the last such line." |
| Scan returned wrong line ranges | Add: "`start_line` is 1-indexed; `end_line` is the last line before the next part (or `total_lines` for the last part). Parts must cover the whole file with no gaps." |
| Sub-agent wrote to a file | Add: "You have NO permission to call Write or Edit. Return your output as the text of your reply only." |

3. Re-spawn with the corrected prompt. If retry 2 fails again, do that section
   yourself using the serial method and note the failure in chat.

---

## Serial fallback (runtimes without sub-agents)

If the Agent tool is unavailable, read and convert one section at a time using
`Edit` to replace each `<!-- TODO body -->` placeholder. Write a skeleton first
(one `Write` call with H2s and placeholders), then fill each section
top-to-bottom. Apply cross-reference substitutions inline as you go.

**Print to chat before each Edit:**
> Writing section N/N — [Section title]…

---

## Glossary of placeholders

For reference. The orchestrator fills these in before sending each prompt to a
sub-agent — they should never appear literally in any sub-agent's output.

| Placeholder | Filled with |
|-------------|-------------|
| `{{SOURCE_FILE_PATH}}` | path to the user-supplied source `.md` file |
| `{{OFFSET}}`, `{{LIMIT}}` | Read tool offset/limit (computed from `start_line` / `end_line`) |
| `{{FIRST_LINE}}`, `{{LAST_LINE}}` | source line range (1-indexed, inclusive) |
| `{{DOCUMENT_TITLE}}`, `{{DOCUMENT_SUBTITLE}}` | from scan JSON top-level |
| `{{H1_TEXT}}` | text of the main `# H1` (from scan `parts[0].name` or document title) |
| `{{SECTION_LIST}}` | list of top-level clauses with source line ranges |
| `{{H2_INDENT}}` … `{{H5_INDENT}}` | computed leading-space counts |
| `{{SCHEDULE_NUMBER}}`, `{{SCHEDULE_HEADING}}` | for schedule sub-agents; `{{SCHEDULE_HEADING}}` is pre-rendered by the orchestrator applying the B separator rule then the A case rule to the full heading string |
| `{{START_LINE}}`, `{{END_LINE}}` | for schedule sub-agents (alias of FIRST_LINE / LAST_LINE) |
| `{{H1_CASE_RULE}}` | A1, A2, A3, or A4 rule text from Phase 1.5 |
| `{{SCHEDULE_PREFIX_RULE}}` | B1–B5 rule text; consumed by orchestrator to build `{{SCHEDULE_HEADING}}`; not passed directly to sub-agents |
| `{{CLAUSE_CASE_RULE}}` | C1, C2, C3, or C4 rule text |
| `{{H2_LAYOUT_RULE}}` | D1 or D2 rule text |
| `{{SUBCLAUSE_LABEL_RULE}}` | E1, E2, E3, or E4 rule text |
| `{{H3_LAYOUT_RULE}}` | F1 or F2 rule text |
| `{{COLON_RULE}}` | G1 or G2 rule text |
