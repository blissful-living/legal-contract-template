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

-- Extract the TOC label from a heading's inline content.
-- When a heading starts with a Strong (bold) inline — Variant C clauses like
-- "**Committees**: A committee of directors must…" — use only the bold text so
-- the TOC entry reads "Committees" rather than the full clause sentence.
local function toc_label(inlines)
  if inlines[1] and inlines[1].t == "Strong" then
    return pandoc.utils.stringify(inlines[1].content)
  end
  return pandoc.utils.stringify(inlines)
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
--     signatories:
--       - name: "Alice Smith"
--         organisation: "Smith & Co Ltd"    # omit for personal (non-org) signatories
--         role: "Director"                  # omit for personal signatories
--         date: "2026-04-26"               # ISO 8601 dates are reformatted to long form
--         auto-sign: true                   # render name in handwriting font
--
-- B2B vs personal detection: presence of `organisation` (and optionally
-- `role`) indicates the signatory acts for and on behalf of an entity.
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

local function build_execution_html(meta)
  local exec = meta.execution
  if not exec then return nil end

  local sigs = exec.signatories
  if not sigs or #sigs == 0 then return nil end

  local title = exec.title and pandoc.utils.stringify(exec.title) or "EXECUTION"
  local intro = exec.intro and pandoc.utils.stringify(exec.intro) or nil

  local out = {
    '<section id="execution">',
    string.format('<h1 id="sec-execution">%s</h1>', html_escape(title)),
  }
  if intro then
    out[#out+1] = string.format('<p>%s</p>', html_escape(intro))
  end
  out[#out+1] = '<div class="execution-grid">'

  for _, sig in ipairs(sigs) do
    local name     = sig.name         and pandoc.utils.stringify(sig.name)         or ""
    local org      = sig.organisation and pandoc.utils.stringify(sig.organisation) or nil
    local role     = sig.role         and pandoc.utils.stringify(sig.role)         or nil
    local date_raw = sig.date         and pandoc.utils.stringify(sig.date)         or nil
    local date_str = date_raw and format_date(date_raw) or nil
    local auto     = meta_bool(sig['auto-sign'])

    out[#out+1] = '<div class="signatory">'

    -- "For and on behalf of [Org] by" — only for org signatories
    if org then
      out[#out+1] = string.format(
        '<p class="signatory-behalf">For and on behalf of %s by</p>',
        html_escape(org)
      )
    end

    -- Signature field: handwriting font when auto-sign, blank space otherwise
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

    -- Position field — only for org signatories (role present)
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
  end

  out[#out+1] = '</div>'   -- .execution-grid
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

      id_map["#" .. pos_id] = {num = full, level = num_level, href = "#" .. anchor}
      if has_friendly then
        id_map["#" .. el.identifier] = {num = full, level = num_level, href = "#" .. anchor}
      end
      -- Inside a schedule scope, also register the bare sec-N-M key so that
      -- author-written @sec-N-M Cite tokens (schedule-local refs) resolve correctly.
      if current_prefix ~= "sec" then
        local bare_id = "sec-" .. full:gsub("%.", "-")
        if not id_map["#" .. bare_id] then
          id_map["#" .. bare_id] = {num = full, level = num_level, href = "#" .. anchor}
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
