local id_map = {}

local function to_roman(n)
  local numerals = {"i", "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x"}
  return numerals[n] or tostring(n)
end

local function compute_labels(counters, level)
  local display, full = "", ""
  if level == 1 then
    full = tostring(counters[1])
    display = full .. "."
  elseif level == 2 then
    full = string.format("%d.%d", counters[1], counters[2])
    display = full
  elseif level == 3 then
    local letter = string.char(96 + counters[3])
    display = string.format("(%s)", letter)
    full = string.format("%d.%d.%s", counters[1], counters[2], letter)
  elseif level == 4 then
    local letter = string.char(96 + counters[3])
    local roman = to_roman(counters[4])
    display = string.format("(%s)", roman)
    full = string.format("%d.%d.%s.%s", counters[1], counters[2], letter, roman)
  end
  return display, full
end

function Pandoc(doc)
  local counters = {0, 0, 0, 0}

  -- First pass: build id_map from all headers
  doc:walk({
    Header = function(el)
      if el.level > 4 or el.classes:includes('unnumbered') then return end
      counters[el.level] = counters[el.level] + 1
      for i = el.level + 1, 4 do counters[i] = 0 end
      if el.identifier ~= "" then
        local _, full = compute_labels(counters, el.level)
        id_map["#" .. el.identifier] = { num = full, level = el.level }
      end
    end
  })

  -- Reset for second pass
  counters = {0, 0, 0, 0}

  -- Second pass: add section number spans and replace @sec-* Cite nodes with links
  return doc:walk({
    Header = function(el)
      if el.level > 4 or el.classes:includes('unnumbered') then return end
      counters[el.level] = counters[el.level] + 1
      for i = el.level + 1, 4 do counters[i] = 0 end
      local display, _ = compute_labels(counters, el.level)
      table.insert(el.content, 1, pandoc.Span(display, {class = "header-section-number"}))
      return el
    end,
    Cite = function(el)
      -- Quarto cross-references (@sec-*) appear as Cite nodes before Quarto resolves them
      if #el.citations == 1 then
        local id = el.citations[1].id
        if id:match("^sec%-") then
          local target = id_map["#" .. id]
          if target then
            local prefix = (target.level == 1) and "section " or "clause "
            return pandoc.Link(prefix .. target.num, "#" .. id)
          end
        end
      end
    end
  })
end
