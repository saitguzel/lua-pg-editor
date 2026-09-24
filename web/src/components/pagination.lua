-- F19: Sayfalama (codd) — ilk/onceki/sonraki/son, sayfa boyutu 50/100/250/500, "{ilk}-{son} / toplam satir".
local dom = require("dom")
local types = require("pg_shared.types")
local icons = require("icons")

local pagination = {}

local SIZE_OPTIONS = types.PAGE_SIZE_OPTIONS or { 50, 100, 250, 500 }

-- meta: { page, per_page, total, has_next }; on_change({ page, per_page })
function pagination.render(meta, on_change)
  meta = meta or {}
  local page = tonumber(meta.page) or 1
  local per_page = tonumber(meta.per_page) or 100
  local total = tonumber(meta.total) or 0
  local last = math.max(1, math.ceil(total / per_page))
  local first_row = total == 0 and 0 or (page - 1) * per_page + 1
  local last_row = math.min(page * per_page, total)

  local size_opts = {}
  for _, sz in ipairs(SIZE_OPTIONS) do
    size_opts[#size_opts + 1] = dom.option({ value = tostring(sz), selected = per_page == sz and "selected" or nil }, tostring(sz))
  end
  local function go(p) return function() on_change({ page = p, per_page = per_page }) end end

  return dom.nav({ ["aria-label"] = "Sayfalama", class = "flex items-center justify-between gap-2 flex-wrap py-2" },
    dom.div({ class = "flex items-center gap-1" },
      dom.button({ type = "button", class = "btn btn-ghost btn-icon btn-sm", disabled = page <= 1 and "disabled" or nil,
        ["aria-label"] = "İlk sayfa", title = "İlk sayfa", onclick = go(1) }, icons.get("chevron-left", "w-4 h-4"), icons.get("chevron-left", "w-4 h-4 -ml-2")),
      dom.button({ type = "button", class = "btn btn-ghost btn-icon btn-sm", disabled = page <= 1 and "disabled" or nil,
        ["aria-label"] = "Önceki sayfa", title = "Önceki sayfa", onclick = go(page - 1) }, icons.get("chevron-left", "w-4 h-4")),
      dom.span({ class = "text-sm text-[var(--fg-muted)] px-2", ["aria-current"] = "page" },
        "Sayfa " .. page .. " / " .. last),
      dom.button({ type = "button", class = "btn btn-ghost btn-icon btn-sm", disabled = page >= last and "disabled" or nil,
        ["aria-label"] = "Sonraki sayfa", title = "Sonraki sayfa", onclick = go(page + 1) }, icons.get("chevron-right", "w-4 h-4")),
      dom.button({ type = "button", class = "btn btn-ghost btn-icon btn-sm", disabled = page >= last and "disabled" or nil,
        ["aria-label"] = "Son sayfa", title = "Son sayfa", onclick = go(last) }, icons.get("chevron-right", "w-4 h-4"), icons.get("chevron-right", "w-4 h-4 -ml-2"))),
    dom.div({ class = "flex items-center gap-2" },
      dom.span({ class = "text-xs text-[var(--fg-muted)]", role = "status" },
        first_row .. "-" .. last_row .. " / " .. total .. " satır"),
      dom.label({ class = "text-xs text-[var(--fg-muted)] flex items-center gap-1" }, "Satır/sayfa",
        dom.select({ class = "px-2 py-1 text-sm border border-[var(--border)] rounded bg-[var(--bg)]",
          onchange = function(e) on_change({ page = 1, per_page = tonumber(e.value) or per_page }) end,
        }, dom.list(size_opts)))))
end

return pagination
