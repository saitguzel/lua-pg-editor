-- F18: Sorgu gecmisi (codd) — baglanti + veritabani basina, zaman damgasi, SQL onizleme, Uygula (aktif
-- sekmenin metnini degistirir), Yeni sekmede ac, Kopyala, Temizle. Ayni SQL tekrar calisinca en uste tasinir.
local dom = require("dom")
local app = require("app")
local api = require("fetch")
local router = require("router")
local protocol = require("pg_shared.protocol")
local icons = require("icons")

local _M = {}
_M.title = "Sorgu Geçmişi"
_M.layout = true

local PER_PAGE = 50

-- SQL metninde arama: modülde tutulur (URL'e yazılmaz; her tuşta rota değişip odak kaybolmasın)
local search = ""
local search_seq = 0

-- debounce: son tuştan 300 ms sonra fn çalışır
local function debounced(fn)
  search_seq = search_seq + 1
  local my = search_seq
  js.timer.after(300, function() if my == search_seq then app.spawn(fn) end end)
end

-- eşleşen parçalar <mark> ile vurgulanır (büyük/küçük harf duyarsız, ASCII)
function _M.highlight(text, needle)
  if not needle or needle == "" then return text end
  local out, pos, lt, ln = {}, 1, text:lower(), needle:lower()
  while true do
    local a, b = lt:find(ln, pos, true)
    if not a then break end
    if a > pos then out[#out + 1] = text:sub(pos, a - 1) end
    out[#out + 1] = dom.h("mark",
      { class = "bg-[color-mix(in_srgb,var(--warning)_30%,transparent)] text-inherit rounded-sm" }, text:sub(a, b))
    pos = b + 1
  end
  out[#out + 1] = text:sub(pos)
  return out
end

local function search_input(id, on_change)
  return dom.input({ id = id, type = "search", value = search, placeholder = "SQL içinde ara…",
    ["aria-label"] = "Geçmişte ara", autocomplete = "off",
    class = "px-2 py-1 border border-[var(--border)] rounded bg-[var(--bg)] text-sm w-56",
    oninput = function(e) search = e.value or ""; debounced(on_change) end })
end

local function filters()
  local q = (router.current() or {}).query or {}
  return { connection_id = q.connection_id ~= "" and q.connection_id or nil,
    database = q.database ~= "" and q.database or nil, page = tonumber(q.page) or 1 }
end

local function load(f)
  app.dispatch({ type = "QUERY_HISTORY_REQUESTED" })
  local data, err = api.get("/query/history", { connection_id = f.connection_id, database = f.database,
    page = f.page, per_page = PER_PAGE, q = search ~= "" and search or nil })
  if err then
    app.dispatch({ type = "QUERY_HISTORY_FAILED" })
    app.toast("error", err.message or protocol.message(err.code))
    return
  end
  app.dispatch({ type = "QUERY_HISTORY_LOADED", items = data.items or {}, meta = data.meta })
end

function _M.enter()
  local st = app.get_state()
  if st.connections.status == "idle" then
    local data = api.get("/connections", { per_page = 100 })
    if data and data.items then app.dispatch({ type = "CONNECTIONS_LOADED", items = data.items }) end
  end
  load(filters())
end

local function when(iso)
  if not iso then return "" end
  return tostring(js.format_date and js.format_date(iso) or iso)
end

-- codd Apply: aktif sekmenin metnini degistirir, sekmenin baglanti/DB'sini kayda esitler
function _M.apply(entry)
  local qe = require("views.query_editor")
  local st = app.get_state()
  local tab = st.query.tabs[st.query.active_tab]
  if not tab then
    qe.open_in_new_tab(entry.sql, { connection_id = entry.connection_id, database = entry.database })
    return
  end
  app.dispatch({ type = "QUERY_TAB_UPDATED", id = tab.id,
    patch = { connection_id = entry.connection_id, database = entry.database or false } })
  qe.set_sql(tab.id, entry.sql)
  if st.route.name ~= "query" then router.navigate("#/query") end
end

-- F27: tek tıkla çalıştır — Uygula + çalıştır (yıkıcı onay akışı aynen uygulanır)
function _M.run(entry)
  _M.apply(entry)
  require("views.query_editor").trigger_run()
end

function _M.clear(connection_id, database, after)
  app.spawn(function()
    if not require("components.modal").confirm({ title = "Geçmiş temizlensin mi?", danger = true, confirm_label = "Temizle",
      message = "Bu bağlantı" .. (database and (" / " .. database) or "") .. " için sorgu geçmişi silinecek." }) then return end
    local qs = "?connection_id=" .. router.urlencode(connection_id)
      .. (database and ("&database=" .. router.urlencode(database)) or "")
    local _, err = api.delete("/query/history" .. qs)
    if err then app.toast("error", err.message or protocol.message(err.code)); return end
    app.toast("success", "Geçmiş temizlendi")
    if after then after() end
  end)
end

local function conn_name(state, id)
  for _, c in ipairs(state.connections.items or {}) do if c.id == id then return c.name end end
  return "?"
end

local function entry_row(state, entry)
  local sql = entry.sql or ""
  return dom.li({ key = tostring(entry.id),
    class = "flex items-start gap-3 p-3 border border-[var(--border)] rounded-[var(--radius)] bg-[var(--bg-elev)] hover:shadow-sm transition-shadow" },
    dom.div({ class = "flex-1 min-w-0 space-y-1" },
      dom.pre({ class = "text-xs font-mono whitespace-pre-wrap break-words max-h-24 overflow-hidden" },
        _M.highlight(sql, search)),
      dom.div({ class = "flex flex-wrap gap-3 text-[11px] text-[var(--fg-muted)] items-center" },
        dom.span({ class = "inline-flex items-center gap-1" }, icons.get("clock", "w-3 h-3"), when(entry.executed_at)),
        dom.span({ class = "inline-flex items-center gap-1" }, icons.get("plug", "w-3 h-3"), conn_name(state, entry.connection_id) .. " / " .. tostring(entry.database or "")),
        entry.row_count and dom.span({}, tostring(entry.row_count) .. " satır") or nil,
        entry.duration_ms and dom.span({}, tostring(entry.duration_ms) .. " ms") or nil,
        entry.truncated and dom.span({ class = "text-[var(--warning)] inline-flex items-center gap-0.5" }, icons.get("alert-circle", "w-3 h-3"), "limit") or nil)),
    dom.div({ class = "flex flex-col gap-1 shrink-0" },
      icons.button({ icon = "play", label = "Çalıştır", variant = "primary", class = "btn-sm",
        title = "Aktif sekmeye uygula ve çalıştır", onclick = function() _M.run(entry) end }),
      icons.button({ icon = "check", label = "Uygula", variant = "accent", class = "btn-sm", title = "Aktif sekmeye uygula",
        onclick = function() _M.apply(entry) end }),
      icons.button({ icon = "external-link", label = "Yeni sekmede aç", variant = "secondary", class = "btn-sm",
        onclick = function()
          require("views.query_editor").open_in_new_tab(sql, { connection_id = entry.connection_id, database = entry.database })
        end }),
      icons.button({ icon = "copy", label = "Kopyala", variant = "ghost", class = "btn-sm",
        onclick = function() js.clipboard(sql); app.toast("success", "Kopyalandı") end })))
end

function _M.render(state)
  local hist = state.query.history or {}
  local items, meta = hist.items or {}, hist.meta or {}
  local f = filters()
  local sel = "px-2 py-1 border border-[var(--border)] rounded bg-[var(--bg)] text-sm"

  local opts = { dom.option({ value = "" }, "Tüm bağlantılar") }
  for _, c in ipairs(state.connections.items or {}) do
    opts[#opts + 1] = dom.option({ value = c.id, selected = f.connection_id == c.id and "selected" or nil }, c.name)
  end
  local toolbar = dom.div({ class = "flex flex-wrap items-center gap-2" },
    dom.label({ class = "text-sm flex items-center gap-1" }, "Bağlantı",
      dom.select({ class = sel, onchange = function(e)
        router.replace_query({ connection_id = e.value, database = "", page = "" })
      end }, dom.list(opts))),
    dom.label({ class = "text-sm flex items-center gap-1" }, "Veritabanı",
      dom.input({ type = "text", class = sel .. " w-36", value = f.database or "", placeholder = "tümü",
        onchange = function(e) router.replace_query({ database = e.value or "", page = "" }) end })),
    search_input("history-search", function()
      local f2 = filters()
      if f2.page > 1 then router.replace_query({ page = "" }) else load(f2) end
    end),
    dom.button({ type = "button", class = "btn btn-secondary btn-sm",
      onclick = function() app.spawn(load, filters()) end }, require("icons").get("refresh"), dom.span({}, "Yenile")),
    f.connection_id and #items > 0 and icons.button({ icon = "trash", label = "Temizle", variant = "danger",
      class = "btn-sm ml-auto", title = "Geçmişi temizle",
      onclick = function() _M.clear(f.connection_id, f.database, function() load(filters()) end) end }) or nil)

  local body
  if hist.status == "loading" and #items == 0 then
    body = require("components.skeleton").lines(5)
  elseif #items == 0 then
    body = search ~= "" and require("views.layout").empty_state({ icon_svg = "search", title = "Eşleşme yok",
      text = "\"" .. search .. "\" içeren sorgu bulunamadı" })
      or require("views.layout").empty_state({ icon_svg = "history", title = "Geçmiş boş",
      text = "Çalıştırılan sorgular burada listelenir" })
  else
    local rows = {}
    for i, e in ipairs(items) do rows[i] = entry_row(state, e) end
    body = dom.ul({ class = "space-y-2" }, dom.list(rows))
  end
  local total_pages = tonumber(meta.total_pages) or 1
  local pager = total_pages > 1 and dom.nav({ ["aria-label"] = "Sayfalama", class = "flex items-center gap-2 justify-center mt-4" },
    icons.button({ icon = "chevron-left", label = "Önceki", variant = "secondary", disabled = f.page <= 1,
      onclick = function() router.replace_query({ page = tostring(f.page - 1) }) end }),
    dom.span({ class = "text-sm text-[var(--fg-muted)] px-2", ["aria-current"] = "page" }, f.page .. " / " .. total_pages),
    icons.button({ icon = "chevron-right", label = "Sonraki", variant = "secondary", disabled = f.page >= total_pages,
      onclick = function() router.replace_query({ page = tostring(f.page + 1) }) end })) or nil

  return dom.div({ class = "space-y-3" },
    dom.h1({ class = "text-xl font-bold flex items-center gap-2", tabindex = "-1" },
      icons.get("history", "w-6 h-6 text-[var(--primary)]"), "Sorgu Geçmişi"),
    toolbar, body, pager)
end

-- Editor ici gecmis (codd popover): aktif sekmenin baglanti/DB'si icin son 20 kayit (aranabilir);
-- Uygula metni degistirir
local pop = { items = {}, tab = nil }

local function load_popover()
  local tab = pop.tab
  local data, err = api.get("/query/history", { connection_id = tab.connection_id, database = tab.database,
    per_page = 20, q = search ~= "" and search or nil })
  if err then app.toast("error", err.message or protocol.message(err.code)); return false end
  pop.items = data.items or {}
  app.schedule_render()
  return true
end

function _M.open_popover(tab)
  app.spawn(function()
    pop.tab = tab
    if not load_popover() then return end
    local modal = require("components.modal")
    modal.show({ id = "history-popover", wide = true, title = "Geçmiş",
      content = function()
        local rows = {}
        for i, e in ipairs(pop.items) do
          rows[i] = dom.li({ key = tostring(e.id),
            class = "flex items-start gap-2 py-2 border-b border-[var(--border)]" },
            dom.div({ class = "flex-1 min-w-0" },
              dom.pre({ class = "text-xs font-mono whitespace-pre-wrap break-words max-h-16 overflow-hidden" },
                _M.highlight(e.sql or "", search)),
              dom.time({ class = "text-[11px] text-[var(--fg-muted)]", datetime = e.executed_at },
                when(e.executed_at))),
            dom.div({ class = "flex flex-col gap-1 shrink-0" },
              icons.button({ icon = "play", label = "Çalıştır", variant = "primary", class = "btn-sm",
                title = "Aktif sekmeye uygula ve çalıştır",
                onclick = function() modal.close("history-popover"); _M.run(e) end }),
              icons.button({ icon = "check", label = "Uygula", variant = "accent", class = "btn-sm",
                onclick = function() modal.close("history-popover"); _M.apply(e) end })))
        end
        return dom.div({ class = "space-y-2" },
          search_input("history-popover-search", load_popover),
          #rows > 0 and dom.ul({ class = "max-h-[60vh] overflow-auto" }, dom.list(rows))
            or dom.p({ class = "text-sm text-[var(--fg-muted)]" },
              search ~= "" and "Eşleşen sorgu yok." or "Bu bağlantı/veritabanı için geçmiş yok."))
      end,
      actions = {
        { label = "Tümünü gör", class = "btn btn-secondary", onclick = function()
          router.navigate("#/query/history?connection_id=" .. router.urlencode(tab.connection_id)
            .. (tab.database and ("&database=" .. router.urlencode(tab.database)) or ""))
        end },
        { label = "Temizle", class = "btn btn-danger", onclick = function() _M.clear(tab.connection_id, tab.database) end },
      } })
  end)
end

return _M
