-- ================================================================
-- HELPERS: Roman numerals and legal section label computation
-- ================================================================

local function to_roman(n)
  local numerals = {"i", "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x"}
  return numerals[n] or tostring(n)
end

-- Returns both the inline display label and the full cross-reference label
-- for a numbered heading.  num_level maps heading depth: H2→1, H3→2, H4→3, H5→4.
local function compute_labels(counters, num_level)
  local display, full = "", ""
  if num_level == 1 then
    full    = tostring(counters[1])
    display = full .. "."
  elseif num_level == 2 then
    full    = string.format("%d.%d", counters[1], counters[2])
    display = full
  elseif num_level == 3 then
    local letter = string.char(96 + counters[3])
    display = string.format("(%s)", letter)
    -- Skip the H3 segment when an H4 sits directly under an H2 (counters[2] == 0).
    -- This keeps `full` (and thus pos_id) authored-friendly: `4.c` rather than `4.0.c`,
    -- so plain-text refs like "paragraph 4c" link correctly.
    if counters[2] > 0 then
      full = string.format("%d.%d.%s", counters[1], counters[2], letter)
    else
      full = string.format("%d.%s", counters[1], letter)
    end
  elseif num_level == 4 then
    local letter = string.char(96 + counters[3])
    local roman  = to_roman(counters[4])
    display = string.format("(%s)", roman)
    if counters[2] > 0 and counters[3] > 0 then
      full = string.format("%d.%d.%s.%s", counters[1], counters[2], letter, roman)
    elseif counters[2] > 0 then
      full = string.format("%d.%d.%s", counters[1], counters[2], roman)
    elseif counters[3] > 0 then
      full = string.format("%d.%s.%s", counters[1], letter, roman)
    else
      full = string.format("%d.%s", counters[1], roman)
    end
  end
  return display, full
end

-- ================================================================
-- TABLE: strip explicit column widths
-- Pandoc emits <col style="width: N%"> by default; setting all
-- widths to ColWidthDefault removes those inline styles so the
-- browser auto-sizes columns under the `table-layout: auto` CSS rule.
-- ================================================================

function Table(el)
  for i, spec in ipairs(el.colspecs) do
    el.colspecs[i] = {spec[1], pandoc.ColWidthDefault}
  end
  return el
end

-- ================================================================
-- TOC: table of contents generation
--
-- Controlled by the `toc-max-depth` metadata key (default: 2).
-- Accepts a plain integer ("3"), hash notation ("###" = depth 3),
-- or 0 to suppress the TOC entirely.
-- Override per document in the YAML front matter or on the CLI:
--   quarto render doc.qmd -M toc-max-depth:3
--   quarto render doc.qmd -M toc-max-depth:0   # no TOC
-- ================================================================

-- Parse toc-max-depth from document metadata; returns an integer.
local function parse_toc_depth(meta)
  local raw = meta['toc-max-depth']
  if raw == nil then return 2 end               -- default depth
  local str = pandoc.utils.stringify(raw)
  if str:match('^#+$') then return #str end     -- "##" → 2
  return tonumber(str) or 2
end

-- Like pandoc.utils.stringify but also captures RawInline content.
-- pandoc.utils.stringify silently drops RawInline nodes; Quarto represents
-- {{< meta >}} shortcode output as RawInline "html", so those values would
-- otherwise vanish from TOC labels even though they render fine in the body.
local function stringify_with_raw(inlines)
  local parts = {}
  for _, el in ipairs(inlines) do
    if     el.t == "Str"       then parts[#parts+1] = el.text
    elseif el.t == "Space"
        or el.t == "SoftBreak" then parts[#parts+1] = " "
    elseif el.t == "LineBreak" then parts[#parts+1] = "\n"
    elseif el.t == "Code"      then parts[#parts+1] = el.text
    elseif el.t == "RawInline" then
      -- Strip any HTML tags; keep only the text content (e.g. "85%").
      parts[#parts+1] = el.text:gsub("<[^>]*>", "")
    elseif el.content          then
      -- Handles Strong, Emph, Span, Link, etc. by recursing into content.
      parts[#parts+1] = stringify_with_raw(el.content)
    end
  end
  return table.concat(parts)
end

-- Extract the TOC label from a heading's inline content.
-- When a heading starts with a Strong (bold) inline — Variant C clauses like
-- "**Committees**: A committee of directors must…" — use only the bold text so
-- the TOC entry reads "Committees" rather than the full clause sentence.
local function toc_label(inlines)
  if inlines[1] and inlines[1].t == "Strong" then
    return stringify_with_raw(inlines[1].content)
  end
  return stringify_with_raw(inlines)
end

-- Extract a parenthetical title for cross-reference rendering.
-- Returns a string title, or nil for body-as-heading clauses that have no title.
--
-- Rules, in order:
--   1. First inline is Strong (Variants A and C) → title is the Strong's text
--      with any trailing ":" stripped. Covers both "**Title**: body" and
--      "**Title:** body" — and bold-only headings like "**Definitions**".
--   2. Plain-text heading ending in sentence-final or list-intro punctuation
--      (. ! ? : ;) → no title. The heading is a body clause.
--   3. Plain-text heading ending in a list-item connector (", and", "; and",
--      ", or", "; or") → no title. The heading is a sentence-fragment item
--      in an enumerated list.
--   4. Otherwise (plain text with no terminal punctuation) → the entire heading
--      text is the title (Variant A without bold, e.g. "## Purpose and Objectives").
local function extract_title(inlines)
  if inlines[1] and inlines[1].t == "Strong" then
    local t = stringify_with_raw(inlines[1].content)
    return (t:gsub("[:%s]+$", ""))
  end
  local s = stringify_with_raw(inlines)
  s = s:gsub("%s+$", "")
  if s == "" then return nil end
  if s:match("[,;]%s*[Aa]nd$") or s:match("[,;]%s*[Oo]r$") then
    return nil
  end
  local last = s:sub(-1)
  if last == "." or last == "!" or last == "?" or last == ":" or last == ";" then
    return nil
  end
  return s
end

-- Classify a heading's structural shape for CSS styling.  Returned class is
-- attached to the heading by Pass 2 so style.css can apply font-weight rules
-- without baking heading level assumptions (e.g. "all H2s are titles").
--
-- One of three values is returned:
--   "clause-title"  — Variant A. Heading is wholly a title (bold or plain
--                     Title Case). Whole heading renders bold at H2 level.
--   "clause-inline" — Variant C. Bold lead-in label followed by body text.
--                     Only the bold span and the section number are bold;
--                     the body text is regular weight.
--   "clause-body"   — Body-as-heading. The heading is itself a sentence with
--                     no title. Only the section number is bold.
local function clause_shape(inlines)
  if inlines[1] and inlines[1].t == "Strong" then
    -- Variant A if nothing meaningful follows the Strong; Variant C otherwise.
    for i = 2, #inlines do
      local el = inlines[i]
      if el.t ~= "Space" and el.t ~= "SoftBreak" then
        return "clause-inline"
      end
    end
    return "clause-title"
  end
  -- Plain text: reuse extract_title's classification (nil ⇒ body sentence).
  if extract_title(inlines) then return "clause-title" end
  return "clause-body"
end

-- Render collected TOC entries as an HTML <nav> block.
-- Each entry: { level=N, id="...", display="1.", text="HEADING TEXT" }
local function build_toc_html(entries, toc_title)
  local lines = {
    '<nav id="toc">',
    '<p class="toc-title">' .. (toc_title or 'Contents') .. '</p>',
    '<ul>',
  }
  for _, e in ipairs(entries) do
    local label = (e.display ~= "") and (e.display .. " " .. e.text) or e.text
    lines[#lines + 1] = string.format(
      '<li class="toc-h%d"><a href="#%s">%s</a></li>',
      e.level, e.id, label
    )
  end
  lines[#lines + 1] = '</ul>'
  lines[#lines + 1] = '</nav>'
  return table.concat(lines, '\n')
end

-- ================================================================
-- EXECUTION BLOCK: signature / execution section generator
--
-- Reads `execution` from document metadata.  If the key is absent
-- or `signatories` is empty, no section is appended.
--
-- YAML structure:
--   execution:
--     title: "EXECUTION"                    # optional; default "EXECUTION"
--     intro: "Signed as an Agreement..."    # optional preamble sentence
--     agreement-date: "21 May 2026"         # optional; used as the default date
--                                           # for any signatory without their own
--                                           # `date`. Long-form or ISO 8601.
--     signatories:
--       - name: "Alice Smith"
--         organisation: "Smith & Co Ltd"    # omit for personal signatories;
--                                           # presence triggers org grouping
--         role: "Director"                  # optional; renders as Position field
--         date: "2026-04-26"               # optional; ISO 8601 dates are reformatted
--                                          # to long form. Omit to fall back to
--                                          # execution.agreement-date.
--         auto-sign: true                   # render name in handwriting font
--         witness: true                     # optional; group as witness. Also
--                                           # auto-detected when role begins with
--                                           # the word "Witness".
--
-- Signatories are grouped automatically:
--   1. Personal parties (no organisation, not a witness) — rendered first
--   2. Corporate signatories — one group per organisation, each prefaced by
--      "For and on behalf of [Organisation] by" outside the signature grid
--   3. Witnesses — rendered last in their own grid
--
-- Because each grid contains only one signatory type, all cells share the
-- same field structure and horizontal alignment is preserved naturally.
-- ================================================================

local function html_escape(s)
  return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

local months_long = {
  "January", "February", "March",     "April",   "May",      "June",
  "July",    "August",   "September", "October", "November", "December",
}

local function format_date(s)
  local y, m, d = s:match("^(%d%d%d%d)-(%d%d)-(%d%d)$")
  if y then
    return string.format("%d %s %s", tonumber(d), months_long[tonumber(m)], y)
  end
  return s
end

-- Safely coerce a Pandoc metadata value to a boolean.
local function meta_bool(val)
  if type(val) == "boolean" then return val end
  if val == nil then return false end
  return pandoc.utils.stringify(val) == "true"
end

-- Render a single signatory block (no "on behalf of" text — handled at group level).
local function render_signatory(sig, default_date)
  local name     = sig.name         and pandoc.utils.stringify(sig.name)         or ""
  local role     = sig.role         and pandoc.utils.stringify(sig.role)         or nil
  local date_raw = (sig.date and pandoc.utils.stringify(sig.date)) or default_date
  local date_str = date_raw and format_date(date_raw) or nil
  local auto     = meta_bool(sig['auto-sign'])

  local out = {'<div class="signatory">'}

  -- Signature field
  out[#out+1] = '<div class="sig-field">'
  if auto and name ~= "" then
    out[#out+1] = string.format('<p class="sig-handwriting">%s</p>', html_escape(name))
  else
    out[#out+1] = '<p class="sig-handwriting sig-handwriting--blank"></p>'
  end
  out[#out+1] = '<div class="sig-line"></div>'
  out[#out+1] = '<p class="sig-label">Signature</p>'
  out[#out+1] = '</div>'

  -- Name field
  out[#out+1] = '<div class="sig-field">'
  out[#out+1] = string.format('<p class="sig-value">%s</p>', html_escape(name))
  out[#out+1] = '<div class="sig-line"></div>'
  out[#out+1] = '<p class="sig-label">Name</p>'
  out[#out+1] = '</div>'

  -- Position field — only when role is supplied
  if role then
    out[#out+1] = '<div class="sig-field">'
    out[#out+1] = string.format('<p class="sig-value">%s</p>', html_escape(role))
    out[#out+1] = '<div class="sig-line"></div>'
    out[#out+1] = '<p class="sig-label">Position</p>'
    out[#out+1] = '</div>'
  end

  -- Date field — only when date is supplied
  if date_str then
    out[#out+1] = '<div class="sig-field">'
    out[#out+1] = string.format('<p class="sig-value">%s</p>', html_escape(date_str))
    out[#out+1] = '<div class="sig-line"></div>'
    out[#out+1] = '<p class="sig-label">Date</p>'
    out[#out+1] = '</div>'
  end

  out[#out+1] = '</div>'  -- .signatory
  return table.concat(out, '\n')
end

-- Wrap a list of signatories in an execution-grid div.
local function render_grid(sigs_list, default_date)
  local out = {'<div class="execution-grid">'}
  for _, sig in ipairs(sigs_list) do
    out[#out+1] = render_signatory(sig, default_date)
  end
  out[#out+1] = '</div>'
  return table.concat(out, '\n')
end

local function build_execution_html(meta)
  local exec = meta.execution
  if not exec then return nil end

  local sigs = exec.signatories
  if not sigs or #sigs == 0 then return nil end

  local title = exec.title and pandoc.utils.stringify(exec.title) or "EXECUTION"
  local intro = exec.intro and pandoc.utils.stringify(exec.intro) or nil
  local default_date = exec['agreement-date']
                       and pandoc.utils.stringify(exec['agreement-date']) or nil

  -- Categorise signatories into three groups, preserving document order within each.
  -- Witness detection: explicit `witness: true` flag, or role beginning with "Witness".
  local parties   = {}
  local org_order = {}  -- org names in first-seen order
  local org_sigs  = {}  -- org_name → ordered list of signatories
  local witnesses = {}

  for _, sig in ipairs(sigs) do
    local org      = sig.organisation and pandoc.utils.stringify(sig.organisation) or nil
    local role_str = sig.role and pandoc.utils.stringify(sig.role) or ""
    local is_witness = meta_bool(sig.witness)
                       or role_str:lower():match("^witness") ~= nil

    if is_witness then
      witnesses[#witnesses+1] = sig
    elseif org then
      if not org_sigs[org] then
        org_order[#org_order+1] = org
        org_sigs[org] = {}
      end
      local g = org_sigs[org]
      g[#g+1] = sig
    else
      parties[#parties+1] = sig
    end
  end

  local out = {
    '<section id="execution">',
    string.format('<h1 id="sec-execution">%s</h1>', html_escape(title)),
  }
  if intro then
    out[#out+1] = string.format('<p>%s</p>', html_escape(intro))
  end

  -- Personal parties grid
  if #parties > 0 then
    out[#out+1] = render_grid(parties, default_date)
  end

  -- Corporate signatories — each organisation gets its own "For and on behalf of"
  -- intro paragraph (outside the grid) followed by its own grid.
  for _, org_name in ipairs(org_order) do
    out[#out+1] = string.format(
      '<p class="signatory-behalf">For and on behalf of %s by</p>',
      html_escape(org_name)
    )
    out[#out+1] = render_grid(org_sigs[org_name], default_date)
  end

  -- Witnesses grid
  if #witnesses > 0 then
    out[#out+1] = render_grid(witnesses, default_date)
  end

  out[#out+1] = '</section>'
  return table.concat(out, '\n')
end

-- ================================================================
-- MAIN: two-pass document walk
--
-- Pass 1 – build the id→label map and collect TOC entries while
--           running through headers in document order.
-- Pass 2 – prepend section-number <span>s to headings and resolve
--           @sec-* cross-references into readable "clause N" links.
-- After both passes, inject the TOC block at the top of the body
-- and the execution block at the end.
-- ================================================================

function Pandoc(doc)
  local id_map      = {}
  local toc_entries = {}
  local counters    = {0, 0, 0, 0}
  local toc_depth   = parse_toc_depth(doc.meta)
  local first_h1_text = nil

  -- Pass 1: assign numbers, populate id_map and toc_entries ----------

  local h1_count       = 0
  local current_prefix = "sec"   -- main-body: prefix produces sec-1, sec-1-2 …

  doc:walk({
    Header = function(el)
      -- H1 = document/part title: reset numbering, never gets a section number
      if el.level == 1 then
        counters = {0, 0, 0, 0}
        h1_count = h1_count + 1
        if h1_count == 1 then
          first_h1_text = pandoc.utils.stringify(el.content)  -- see title block suppression at end of Pandoc()
          current_prefix = "sec"
        else
          -- Each subsequent H1 opens a namespaced scope for its sub-headings.
          local has_friendly = el.identifier:match("^sec%-") ~= nil
          current_prefix = has_friendly and el.identifier or ("sec-part-" .. h1_count)
        end
        -- Honour user-supplied friendly IDs (project convention: must start with `sec-`).
        -- Otherwise treat el.identifier as a Pandoc auto-slug and replace it.
        local has_friendly = el.identifier:match("^sec%-") ~= nil
        local gen_h1_id = has_friendly and el.identifier or ("sec-part-" .. h1_count)
        if toc_depth >= 1 then
          table.insert(toc_entries, {
            level   = 1,
            id      = gen_h1_id,
            display = "",
            text    = pandoc.utils.stringify(el.content),
          })
        end
        return
      end

      if el.level > 5 then return end

      local num_level = el.level - 1  -- H2→1, H3→2, H4→3, H5→4
      counters[num_level] = counters[num_level] + 1
      for i = num_level + 1, 4 do counters[i] = 0 end

      local display, full = compute_labels(counters, num_level)

      local pos_id = current_prefix .. "-" .. full:gsub("%.", "-")
      -- Pandoc's auto_identifiers extension populates el.identifier with a slug
      -- derived from heading text. We treat anything that doesn't start with
      -- `sec-` as an auto-slug to discard, leaving pos_id (or a sec-* friendly ID)
      -- as the final anchor. The README documents the `sec-*` convention.
      local has_friendly = el.identifier:match("^sec%-") ~= nil and el.identifier ~= pos_id
      local anchor = has_friendly and el.identifier or pos_id

      local title = extract_title(el.content)
      id_map["#" .. pos_id] = {num = full, level = num_level, href = "#" .. anchor, title = title}
      if has_friendly then
        id_map["#" .. el.identifier] = {num = full, level = num_level, href = "#" .. anchor, title = title}
      end
      -- Inside a schedule scope, also register the bare sec-N-M key so that
      -- author-written @sec-N-M Cite tokens (schedule-local refs) resolve correctly.
      if current_prefix ~= "sec" then
        local bare_id = "sec-" .. full:gsub("%.", "-")
        if not id_map["#" .. bare_id] then
          id_map["#" .. bare_id] = {num = full, level = num_level, href = "#" .. anchor, title = title}
        end
      end

      if el.level <= toc_depth then
        table.insert(toc_entries, {
          level   = el.level,
          id      = anchor,
          display = display,
          text    = toc_label(el.content),
        })
      end
    end,
  })

  -- Pass 2: transform headings and resolve cross-references ----------

  counters        = {0, 0, 0, 0}
  h1_count        = 0
  current_prefix  = "sec"

  local result = doc:walk({
    Header = function(el)
      if el.level == 1 then
        counters = {0, 0, 0, 0}
        h1_count = h1_count + 1
        local has_friendly = el.identifier:match("^sec%-") ~= nil
        if not has_friendly then
          el.identifier = "sec-part-" .. h1_count
        end
        if h1_count == 1 then
          current_prefix = "sec"
          table.insert(el.classes, "doc-title")  -- CSS hook for document-title styling (see title block suppression at end)
        else
          current_prefix = el.identifier
        end
        return el
      end
      if el.level > 5 then return end

      local num_level = el.level - 1
      counters[num_level] = counters[num_level] + 1
      for i = num_level + 1, 4 do counters[i] = 0 end

      local display, full = compute_labels(counters, num_level)
      local pos_id = current_prefix .. "-" .. full:gsub("%.", "-")
      -- Replace Pandoc's auto-slug with pos_id; keep sec-* friendly IDs as-is.
      local has_friendly = el.identifier:match("^sec%-") ~= nil and el.identifier ~= pos_id
      if not has_friendly then
        el.identifier = pos_id
      end
      -- Tag the heading with its structural shape so style.css can choose
      -- font-weight per-clause rather than per-level.  Must run BEFORE the
      -- section-number Span is inserted so clause_shape sees the original
      -- author content.
      table.insert(el.classes, clause_shape(el.content))
      table.insert(el.content, 1, pandoc.Span(display, {class = "header-section-number"}))
      return el
    end,

    -- @sec-* Cite tokens render as a number-only Link.  The author keeps
    -- whatever connector word they wrote ("clause", "section", "paragraph",
    -- "Despite clauses", etc.); we never inject one.  The linker's normal path
    -- emits markdown links directly, so this handler primarily resolves
    -- author-written friendly IDs like `@sec-payment`.
    Cite = function(el)
      if #el.citations == 1 then
        local id = el.citations[1].id
        if id:match("^sec%-") then
          local target = id_map["#" .. id]
          if target then
            return pandoc.Link(target.num, target.href)
          end
        end
      end
    end,
  })

  -- Pass 3: append "(Title)" to cross-reference links whose display text is
  -- just the clause number.  Controlled by the `ref-titles` metadata key
  -- (default: true).  Set `ref-titles: false` in the YAML front matter to
  -- restore number-only references.
  --
  -- Matches both:
  --   - Markdown links emitted by link-refs.py:  [5.8](#sec-5-8)
  --   - Links produced by the Cite handler above for @sec-* tokens.
  --
  -- An author-supplied display text (e.g. `[the payment terms](#sec-payment)`)
  -- is left untouched because its content does not equal the target's number.
  -- Headings whose extract_title() returned nil (body-as-heading clauses) are
  -- also skipped, so number-only references survive where no title exists.
  local ref_titles_meta = doc.meta["ref-titles"]
  local ref_titles_on = true
  if ref_titles_meta ~= nil then
    if type(ref_titles_meta) == "boolean" then
      ref_titles_on = ref_titles_meta
    else
      ref_titles_on = pandoc.utils.stringify(ref_titles_meta) ~= "false"
    end
  end

  if ref_titles_on then
    result = result:walk({
      Link = function(el)
        local target = id_map[el.target]
        if not target or not target.title then return end
        if pandoc.utils.stringify(el.content) == target.num then
          table.insert(el.content, pandoc.Str(" ("))
          table.insert(el.content, pandoc.Str(target.title))
          table.insert(el.content, pandoc.Str(")"))
          return el
        end
      end,
    })
  end

  -- Tag intro paragraphs: a Para that sits directly between an H3 and an H4
  -- is the lead-in sentence for the lettered items below it.  Wrap it in a
  -- <div class="intro-para"> so CSS can indent it to align with the (a)/(b)/(c)
  -- label column without affecting other paragraphs that follow an H3.
  local blocks = result.blocks
  for i = 2, #blocks - 1 do
    local prev = blocks[i - 1]
    local curr = blocks[i]
    local next = blocks[i + 1]
    if curr.t == "Para"
    and prev.t == "Header" and prev.level == 3
    and next.t == "Header" and next.level == 4 then
      blocks[i] = pandoc.Div({curr}, pandoc.Attr("", {"intro-para"}, {}))
    end
  end

  -- If an execution block will be appended, give it a TOC entry so the
  -- signature section is reachable from the table of contents.
  if toc_depth >= 1
     and doc.meta.execution
     and doc.meta.execution.signatories
     and #doc.meta.execution.signatories > 0 then
    local exec_title = doc.meta.execution.title
      and pandoc.utils.stringify(doc.meta.execution.title) or "EXECUTION"
    table.insert(toc_entries, {
      level   = 1,
      id      = "sec-execution",
      display = "",
      text    = exec_title,
    })
  end

  -- Insert TOC immediately after the first H1 (document title) so the title
  -- appears above the TOC, not below it.  Fall back to position 1 if no H1 exists.
  if toc_depth > 0 and #toc_entries > 0 then
    local insert_pos = 1
    for i, block in ipairs(result.blocks) do
      if block.t == "Header" and block.level == 1 then
        insert_pos = i + 1
        break
      end
    end
    local toc_title = doc.meta["toc-title"] and pandoc.utils.stringify(doc.meta["toc-title"]) or nil
    table.insert(result.blocks, insert_pos, pandoc.RawBlock("html", build_toc_html(toc_entries, toc_title)))
  end

  -- Append execution block at end of document (omitted when no signatories) --

  local exec_html = build_execution_html(doc.meta)
  if exec_html then
    result.blocks[#result.blocks + 1] = pandoc.RawBlock("html", exec_html)
  end

  -- Inject link-color override into <head> if the metadata key is set.
  -- Without it, links inherit the body text colour (black) from style.css.
  local link_color_val = result.meta["link-color"]
  if link_color_val then
    local color = html_escape(pandoc.utils.stringify(link_color_val))
    local css = string.format('<style>a, a.quarto-xref { color: %s !important; }</style>', color)
    local include = pandoc.MetaBlocks({pandoc.RawBlock("html", css)})
    local hi = result.meta["header-includes"]
    if hi and hi.t == "MetaList" then
      hi[#hi + 1] = include
    else
      result.meta["header-includes"] = pandoc.MetaList({include})
    end
  end

  -- Title block suppression: the first H1 in the document body is the canonical
  -- document title.  Quarto also renders a title block from the YAML `title:` key,
  -- which would duplicate it.  To prevent that:
  --   1. `meta.title` is cleared so the template's $if(title)$ guard fails and the
  --      <header id="title-block-header"> element is never emitted.
  --   2. `meta.pagetitle` is set so the HTML <title> element (browser tab / print
  --      header) is populated.  Preference order: YAML `title:` if present, else
  --      the first H1 text from the document body.
  -- For multi-document files (main contract + schedules) only the first H1 is
  -- affected; subsequent H1s (schedules) remain visible section separators.
  local yaml_title = result.meta.title
  if yaml_title then
    result.meta.pagetitle = yaml_title
  elseif first_h1_text then
    result.meta.pagetitle = pandoc.MetaInlines({pandoc.Str(first_h1_text)})
  end
  result.meta.title = nil

  return result
end
