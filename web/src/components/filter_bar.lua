-- F19: Filtre paneli (codd Filters popover) — kolon + operator + deger satırlari (AND), Custom SQL,
-- Filtre ekle / Temizle / Uygula. Değişiklikler taslakta tutulur; yalnizca Uygula URL'ye yazar (her tusta sorgu yok).
local dom = require("dom")
local types = require("pg_shared.types")
local icons = require("icons")

local filter_bar = {}

local NO_VALUE = { ["IS NULL"] = true, ["IS NOT NULL"] = true }

-- kolon tip grubuna gore operatorler: backend dogrulamasiyla ayni tablo
function filter_bar.allowed_ops(group)
  return types.FILTER_OPS_BY_GROUP[group or "other"] or types.FILTER_OPS_BY_GROUP.other
end

local draft = nil -- { filters = {...}, custom_where = "" } panel acikken

function filter_bar.open(filters, custom_where)
  local copy = {}
  for i, f in ipairs(filters or {}) do
    copy[i] = { column = f.column, operator = f.operator, value = f.value }
  end
  draft = { filters = copy, custom_where = custom_where or "" }
end

function filter_bar.close() draft = nil end
function filter_bar.is_open() return draft ~= nil end

local function group_of(columns, name)
  for _, c in ipairs(columns) do if c.name == name then return c.type_group end end
  return "other"
end

-- opts: { columns, on_apply(filters, custom_where), on_close() }
function filter_bar.render(opts)
  if not draft then return nil end
  local columns = opts.columns or {}
  local rerender = require("app").schedule_render
  local sel = "px-2 py-1 text-sm border border-[var(--border)] rounded bg-[var(--bg)]"

  local rows = {}
  for i, f in ipairs(draft.filters) do
    local ops = filter_bar.allowed_ops(group_of(columns, f.column))
    local col_opts, op_opts = {}, {}
    for _, c in ipairs(columns) do
      col_opts[#col_opts + 1] = dom.option({ value = c.name, selected = f.column == c.name and "selected" or nil }, c.name)
    end
    for _, o in ipairs(ops) do
      op_opts[#op_opts + 1] = dom.option({ value = o, selected = f.operator == o and "selected" or nil }, o)
    end
    rows[i] = dom.div({ key = i, class = "flex flex-col sm:flex-row sm:items-center gap-1.5 sm:gap-1 p-2 sm:p-0 border sm:border-0 border-[var(--border)] rounded sm:rounded-none bg-[var(--bg)] sm:bg-transparent" },
      dom.div({ class = "flex gap-1 flex-1" },
        dom.select({ class = sel .. " flex-1 min-w-0", ["aria-label"] = "Filtre " .. i .. " kolon",
          onchange = function(e)
            f.column = e.value
            local allowed = filter_bar.allowed_ops(group_of(columns, f.column))
            local ok = false
            for _, o in ipairs(allowed) do if o == f.operator then ok = true end end
            if not ok then f.operator = allowed[1] end
            rerender()
          end }, dom.list(col_opts)),
        dom.select({ class = sel .. " flex-1 min-w-0", ["aria-label"] = "Filtre " .. i .. " operatör",
          onchange = function(e) f.operator = e.value; rerender() end }, dom.list(op_opts))),
      dom.div({ class = "flex gap-1 items-center" },
        not NO_VALUE[f.operator] and dom.input({ type = "text", value = f.value or "", placeholder = "değer",
          ["aria-label"] = "Filtre " .. i .. " değer", class = sel .. " flex-1 min-w-0",
          oninput = function(e) f.value = e.value end }) or dom.span({ class = "flex-1 text-xs text-[var(--fg-muted)] sm:hidden" }, NO_VALUE[f.operator] and "değer gerekmez" or ""),
        dom.button({ type = "button", ["aria-label"] = "Filtre " .. i .. " kaldır", title = "Filtreyi kaldır",
          class = "btn btn-ghost btn-icon btn-sm shrink-0",
          onclick = function() table.remove(draft.filters, i); rerender() end }, icons.get("x", "w-3 h-3"))))
  end

  local function apply()
    local out = {}
    for _, f in ipairs(draft.filters) do
      if f.column and f.operator then
        out[#out + 1] = { column = f.column, operator = f.operator, value = not NO_VALUE[f.operator] and (f.value or "") or nil }
      end
    end
    local cw = draft.custom_where:match("^%s*(.-)%s*$")
    draft = nil
    opts.on_apply(out, cw)
  end

  return dom.div({ role = "region", ["aria-label"] = "Filtreler",
    class = "space-y-2 p-3 border border-[var(--border)] rounded-[var(--radius)] bg-[var(--bg-elev)]" },
    #rows > 0 and dom.div({ class = "space-y-1" }, dom.list(rows))
      or dom.p({ class = "text-xs text-[var(--fg-muted)]" }, "Filtre yok. Filtreler AND ile birleşir."),
    dom.div({ class = "flex items-center gap-2" },
      dom.label({ ["for"] = "custom-where", class = "text-xs text-[var(--fg-muted)] whitespace-nowrap" }, "Custom SQL"),
      dom.input({ id = "custom-where", type = "text", value = draft.custom_where, placeholder = "total_amount > 100",
        class = "flex-1 px-2 py-1 text-sm border border-[var(--border)] rounded bg-[var(--bg)] font-mono",
        oninput = function(e) draft.custom_where = e.value or "" end,
        onkeydown = function(e) if e.key == "Enter" then apply(); return true end end })),
    dom.div({ class = "flex gap-2 flex-wrap" },
      icons.button({ icon = "plus", label = "+ Filtre ekle", variant = "secondary", class = "btn-sm !border-dashed",
        disabled = #columns == 0, title = "Yeni filtre ekle",
        onclick = function()
          local c = columns[1]
          draft.filters[#draft.filters + 1] = { column = c.name, operator = filter_bar.allowed_ops(c.type_group)[1], value = "" }
          rerender()
        end }),
      icons.button({ icon = "eraser", label = "Temizle", variant = "ghost", class = "btn-sm",
        onclick = function() draft.filters = {}; draft.custom_where = ""; rerender() end }),
      icons.button({ icon = "check", label = "Uygula", variant = "accent", class = "btn-sm", onclick = apply }),
      icons.button({ icon = "x", label = "Kapat", variant = "ghost", class = "btn-sm",
        onclick = function() draft = nil; if opts.on_close then opts.on_close() end; rerender() end })))
end

return filter_bar
