-- F18: Sorgu gecmisi (codd) — baglanti + veritabani basina, zaman damgasi, SQL onizleme, Uygula (aktif
-- sekmenin metnini degistirir), Yeni sekmede ac, Kopyala, Temizle. Ayni SQL tekrar calisinca en uste tasinir.
local dom = require("dom")
local app = require("app")
local api = require("fetch")
local router = require("router")
local protocol = require("pg_shared.protocol")

local _M = {}
_M.title = "Sorgu Geçmişi"
_M.layout = true

local PER_PAGE = 50

local function filters()
  local q = (router.current() or {}).query or {}
  return { connection_id = q.connection_id ~= "" and q.connection_id or nil,
    database = q.database ~= "" and q.database or nil, page = tonumber(q.page) or 1 }
end

local function load(f)
  app.dispatch({ type = "QUERY_HISTORY_REQUESTED" })
  local data, err = api.get("/query/history", { connection_id = f.connection_id, database = f.database,
    page = f.page, per_page = PER_PAGE })
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
  local BTN = "px-2.5 py-1 text-xs rounded border border-[var(--border)] hover:bg-[var(--bg)]"
  return dom.li({ key = tostring(entry.id),
    class = "flex items-start gap-3 p-3 border border-[var(--border)] rounded-[var(--radius)] bg-[var(--bg-elev)]" },
    dom.div({ class = "flex-1 min-w-0 space-y-1" },
      dom.pre({ class = "text-xs font-mono whitespace-pre-wrap break-words max-h-24 overflow-hidden" }, sql),
      dom.div({ class = "flex flex-wrap gap-3 text-[11px] text-[var(--fg-muted)]" },
        dom.time({ datetime = entry.executed_at }, when(entry.executed_at)),
        dom.span({}, conn_name(state, entry.connection_id) .. " / " .. tostring(entry.database or "")),
        entry.row_count and dom.span({}, tostring(entry.row_count) .. " satır") or nil,
        entry.duration_ms and dom.span({}, tostring(entry.duration_ms) .. " ms") or nil,
        entry.truncated and dom.span({ class = "text-[var(--warning)]" }, "limit") or nil)),
    dom.div({ class = "flex flex-col gap-1 shrink-0" },
      dom.button({ type = "button", class = "px-2.5 py-1 text-xs rounded bg-[var(--primary)] text-[var(--primary-fg)]",
        onclick = function() _M.apply(entry) end }, "Uygula"),
      dom.button({ type = "button", class = BTN, onclick = function()
        require("views.query_editor").open_in_new_tab(sql, { connection_id = entry.connection_id, database = entry.database })
      end }, "Yeni sekmede aç"),
      dom.button({ type = "button", class = BTN, onclick = function()
        js.clipboard(sql); app.toast("success", "Kopyalandı")
      end }, "Kopyala")))
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
    dom.button({ type = "button", class = "text-xs px-2 py-1 border border-[var(--border)] rounded",
      onclick = function() app.spawn(load, filters()) end }, "Yenile"),
    f.connection_id and #items > 0 and dom.button({ type = "button",
      class = "text-xs px-2 py-1 border border-[var(--danger)] text-[var(--danger)] rounded ml-auto",
      onclick = function() _M.clear(f.connection_id, f.database, function() load(filters()) end) end },
      "Temizle") or nil)

  local body
  if hist.status == "loading" and #items == 0 then
    body = require("components.skeleton").lines(5)
  elseif #items == 0 then
    body = require("views.layout").empty_state({ icon = "🕘", title = "Geçmiş boş",
      text = "Çalıştırılan sorgular burada listelenir" })
  else
    local rows = {}
    for i, e in ipairs(items) do rows[i] = entry_row(state, e) end
    body = dom.ul({ class = "space-y-2" }, dom.list(rows))
  end
  local total_pages = tonumber(meta.total_pages) or 1
  local pager = total_pages > 1 and dom.nav({ ["aria-label"] = "Sayfalama", class = "flex items-center gap-2" },
    dom.button({ type = "button", class = sel, disabled = f.page <= 1 and "disabled" or nil,
      onclick = function() router.replace_query({ page = tostring(f.page - 1) }) end }, "‹ Önceki"),
    dom.span({ class = "text-sm" }, f.page .. " / " .. total_pages),
    dom.button({ type = "button", class = sel, disabled = f.page >= total_pages and "disabled" or nil,
      onclick = function() router.replace_query({ page = tostring(f.page + 1) }) end }, "Sonraki ›")) or nil

  return dom.div({ class = "space-y-3" },
    dom.h1({ class = "text-xl font-bold", tabindex = "-1" }, "Sorgu Geçmişi"),
    toolbar, body, pager)
end

-- Editor ici gecmis (codd popover): aktif sekmenin baglanti/DB'si icin son 20 kayit; Uygula metni degistirir
function _M.open_popover(tab)
  app.spawn(function()
    local data, err = api.get("/query/history", { connection_id = tab.connection_id, database = tab.database, per_page = 20 })
    if err then app.toast("error", err.message or protocol.message(err.code)); return end
    local items = data.items or {}
    local modal = require("components.modal")
    local rows = {}
    for i, e in ipairs(items) do
      rows[i] = dom.li({ key = tostring(e.id), class = "flex items-start gap-2 py-2 border-b border-[var(--border)]" },
        dom.div({ class = "flex-1 min-w-0" },
          dom.pre({ class = "text-xs font-mono whitespace-pre-wrap break-words max-h-16 overflow-hidden" }, e.sql or ""),
          dom.time({ class = "text-[11px] text-[var(--fg-muted)]", datetime = e.executed_at }, when(e.executed_at))),
        dom.button({ type = "button", class = "px-2.5 py-1 text-xs rounded bg-[var(--primary)] text-[var(--primary-fg)]",
          onclick = function() modal.close("history-popover"); _M.apply(e) end }, "Uygula"))
    end
    modal.show({ id = "history-popover", wide = true, title = "Geçmiş",
      content = #rows > 0 and dom.ul({ class = "max-h-[60vh] overflow-auto" }, dom.list(rows))
        or dom.p({ class = "text-sm text-[var(--fg-muted)]" }, "Bu bağlantı/veritabanı için geçmiş yok."),
      actions = {
        { label = "Tümünü gör", onclick = function()
          router.navigate("#/query/history?connection_id=" .. router.urlencode(tab.connection_id)
            .. (tab.database and ("&database=" .. router.urlencode(tab.database)) or ""))
        end },
        #rows > 0 and { label = "Temizle", onclick = function() _M.clear(tab.connection_id, tab.database) end } or nil,
      } })
  end)
end

return _M
