-- F20: Denetim kayıtları — 7 filtre, tablo + detay modal, stats, export, maskeleme.
local dom = require("dom")
local app = require("app")
local api = require("fetch")
local router = require("router")
local types = require("pg_shared.types")
local protocol = require("pg_shared.protocol")
local json = require("json")
local icons = require("icons")

local _M = {}
_M.title = "Denetim Kayıtları"
_M.layout = true

local debounce_id = nil

local FILTER_KEYS = { "action", "entity_type", "user_id", "from", "to", "search", "page" }

local function load_logs(filters)
  app.dispatch({ type = "AUDIT_REQUESTED", filters = filters })
  local q = {}
  for k, v in pairs(filters or {}) do
    if v ~= nil and v ~= "" then q[k] = v end
  end
  local data, err = api.get("/audit/logs", q)
  if err then
    app.dispatch({ type = "AUDIT_FAILED" })
    app.toast("error", protocol.message(err.code))
    return
  end
  app.dispatch({ type = "AUDIT_LOADED", items = data.items, meta = data.meta })
  -- istatistik
  local q2 = {}
  for k, v in pairs(filters or {}) do if k ~= "page" and k ~= "per_page" and v ~= nil and v ~= "" then q2[k] = v end end
  local stats, serr = api.get("/audit/stats", q2)
  if not serr and stats then
    -- stats may be {by_action, by_user, by_day} or single object
    local s = stats.data or stats
    app.dispatch({ type = "AUDIT_STATS_LOADED", stats = s })
  end
end

function _M.valid_range(from, to)
  if not from or from == "" or not to or to == "" then return true end
  return from <= to
end

local function set_filters(patch)
  local st = app.get_state().audit
  local f = app._assign(st.filters or {}, patch)
  if not _M.valid_range(f.from, f.to) then
    app.toast("error", "Bitiş tarihi başlangıçtan önce olamaz")
    return
  end
  if patch.page == nil then patch.page = "" end
  router.replace_query(patch)
end

function _M.enter(route)
  local q = route.query or {}
  local filters = {
    action = q.action,
    entity_type = q.entity_type,
    user_id = q.user_id,
    from = q.from,
    to = q.to,
    search = q.search or q.q,
    page = tonumber(q.page) or 1,
    per_page = 20,
  }
  load_logs(filters)
end

function _M.mounted(dispatch)
  local cur = router.current()
  if cur then _M.enter(cur) end
end

local function close_detail()
  app.dispatch({ type = "AUDIT_DESELECTED" })
end

local function open_detail(log)
  app.dispatch({ type = "AUDIT_SELECTED", id = log.id })
  app.spawn(function()
    local data, err = api.get("/audit/logs/" .. tostring(log.id))
    if data then
      local detail = data.data or data
      app.dispatch({ type = "AUDIT_DETAIL_LOADED", log = detail })
    elseif err then
      app.toast("error", protocol.message(err.code))
      close_detail()
    end
  end)
end

local function json_encode(v)
  local ok, str = pcall(json.encode, v)
  return ok and str or tostring(v)
end

local function diff_fields(old, new)
  old, new = type(old) == "table" and old or {}, type(new) == "table" and new or {}
  local keys, seen = {}, {}
  for k in pairs(old) do if not seen[k] then seen[k] = true; keys[#keys + 1] = k end end
  for k in pairs(new) do if not seen[k] then seen[k] = true; keys[#keys + 1] = k end end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local rows = {}
  for _, k in ipairs(keys) do
    local a, b = old[k], new[k]
    rows[#rows + 1] = { field = k, old = a, new = b, changed = json_encode(a) ~= json_encode(b) }
  end
  return rows
end
_M._diff_fields = diff_fields

local function masked_style(field, value)
  if tostring(field):lower():find("password") or json_encode(value) == '"***"' then
    return "font-style:italic;color:var(--fg-muted)"
  end
end

local function detail_drawer(state)
  local log = state.audit.detail
  local modal = require("components.modal")
  local drawer_class = "drawer bg-[var(--bg-elev)] text-[var(--fg)] border-l border-[var(--border)] p-6 max-w-lg w-full"
  if not log then
    return modal.dialog("audit-detail", "Kayıt yükleniyor…",
      require("components.skeleton").lines(4), close_detail, { class = drawer_class })
  end
  local old = log.old_value
  local new = log.new_value
  if type(old) == "string" then
    local ok, d = pcall(json.decode, old)
    if ok then old = d end
  end
  if type(new) == "string" then
    local ok, d = pcall(json.decode, new)
    if ok then new = d end
  end
  local diff_rows = {}
  for _, r in ipairs(diff_fields(old, new)) do
    diff_rows[#diff_rows + 1] = dom.tr({
      class = r.changed and "bg-[color-mix(in_srgb,var(--warning)_10%,transparent)]" or "",
    },
      dom.td({ class = "py-1 pr-3 font-medium" }, tostring(r.field),
        r.changed and dom.span({ class = "sr-only" }, " (değişti)") or nil),
      dom.td({ class = "py-1 pr-3 text-[var(--fg-muted)]", style = masked_style(r.field, r.old) }, json_encode(r.old)),
      dom.td({ class = "py-1", style = masked_style(r.field, r.new) }, json_encode(r.new)))
  end
  return modal.dialog("audit-detail", (log.action or "?") .. " · #" .. tostring(log.id or "?"), dom.div({},
    dom.dl({ class = "grid grid-cols-[8rem_1fr] gap-y-2 text-sm mb-4" },
      dom.dt({ class = "text-[var(--fg-muted)]" }, "Zaman"),
      dom.dd({}, type(log.created_at) == "string" and js.format_date(log.created_at) or "—"),
      dom.dt({ class = "text-[var(--fg-muted)]" }, "Kullanıcı"),
      dom.dd({}, log.user_email or log.user_id or "—"),
      dom.dt({ class = "text-[var(--fg-muted)]" }, "IP"),
      dom.dd({}, log.ip or "—"),
      type(log.user_agent) == "string" and dom.dt({ class = "text-[var(--fg-muted)]" }, "User-Agent") or nil,
      type(log.user_agent) == "string" and dom.dd({ class = "break-all text-xs" }, log.user_agent) or nil,
      dom.dt({ class = "text-[var(--fg-muted)]" }, "Durum"),
      dom.dd({}, log.status or "—"),
      type(log.error_message) == "string" and dom.dt({ class = "text-[var(--fg-muted)]" }, "Hata") or nil,
      type(log.error_message) == "string" and dom.dd({ class = "text-[var(--danger)]" }, log.error_message) or nil,
      dom.dt({ class = "text-[var(--fg-muted)]" }, "Request Id"),
      dom.dd({}, dom.span({ class = "font-mono text-xs" }, log.request_id or log.req_id or "—"),
        log.request_id and dom.button({
          type = "button", class = "ml-2 text-xs underline",
          onclick = function() js.clipboard(log.request_id); app.toast("info", "Kopyalandı") end }, "kopyala") or nil)),
    #diff_rows > 0 and dom.div({ class = "my-4" },
      dom.h3({ class = "font-semibold mb-2" }, "Değişiklikler"),
      dom.table({ class = "w-full text-xs diff" },
        dom.caption({ class = "sr-only" }, "Değişen alanlar vurgulu"),
        dom.thead({}, dom.tr({ class = "text-left text-[var(--fg-muted)]" },
          dom.th({ scope = "col", class = "py-1" }, "Alan"),
          dom.th({ scope = "col", class = "py-1" }, "Eski"),
          dom.th({ scope = "col", class = "py-1" }, "Yeni"))),
        dom.tbody({}, dom.list(diff_rows)))) or nil,
    dom.details({},
      dom.summary({ class = "text-sm text-[var(--fg-muted)] cursor-pointer" }, "Ham JSON"),
      dom.pre({ class = "text-xs mt-2 p-2 bg-[var(--bg)] rounded overflow-x-auto" },
        json_encode(log)))), close_detail, { class = drawer_class })
end

local function stat_li(label, value, danger, icon)
  return dom.li({ class = "bg-[var(--bg-elev)] border border-[var(--border)] rounded-[var(--radius)] p-3 flex items-start gap-2" },
    icon and dom.div({ class = danger and "p-1.5 rounded bg-[color-mix(in_srgb,var(--danger)_12%,transparent)] text-[var(--danger)]" or "p-1.5 rounded bg-[var(--bg)] text-[var(--fg-muted)]" },
      icons.get(icon, "w-4 h-4")) or nil,
    dom.div({},
      dom.p({ class = "text-sm text-[var(--fg-muted)]" }, label),
      dom.p({ class = danger and "text-xl font-bold text-[var(--danger)]" or "text-xl font-bold truncate" },
        tostring(value or "—"))))
end

local function export_csv(filters)
  app.dispatch({ type = "AUDIT_EXPORT_STARTED" })
  app.spawn(function()
    local q = {}
    for k, v in pairs(filters) do
      if v ~= nil and v ~= "" and k ~= "page" and k ~= "per_page" then q[k] = v end
    end
    local ok, err = api.download("/audit/export", "audit.csv", q)
    app.dispatch({ type = "AUDIT_EXPORT_FINISHED" })
    if ok then app.toast("success", "CSV indirildi") else app.toast("error", "CSV indirilemedi: " .. tostring(err and err.message or err)) end
  end)
end

function _M.render(state, dispatch)
  local st = state.audit
  local meta = st.meta or {}
  local f = st.filters or {}
  local layout = require("views.layout")
  local field_cls = "px-3 py-2 min-h-11 border border-[var(--border)] rounded-[var(--radius)] bg-[var(--bg)] text-sm text-[var(--fg)]"

  local action_opts = { dom.option({ value = "" }, "Tüm eylemler") }
  for _, a in ipairs(types.AUDIT_ACTIONS) do
    action_opts[#action_opts + 1] = dom.option({ value = a, selected = f.action == a and "selected" or nil }, a)
  end
  local entity_opts = { dom.option({ value = "" }, "Tüm varlıklar") }
  for _, e in ipairs({ "user", "connection", "query", "table", "table_row", "rbac", "page" }) do
    entity_opts[#entity_opts + 1] = dom.option({ value = e, selected = f.entity_type == e and "selected" or nil }, e)
  end

  -- user_id select: users listinden doldur (eğer yüklüyse)
  local user_opts = { dom.option({ value = "" }, "Tüm kullanıcılar") }
  for _, u in ipairs(state.users.items or {}) do
    user_opts[#user_opts + 1] = dom.option({ value = u.id, selected = f.user_id == u.id and "selected" or nil }, u.email or u.id)
  end

  local body
  if st.status == "loading" and #st.items == 0 then
    body = require("components.skeleton").rows(5, 6)
  else
    local rows = {}
    for _, log in ipairs(st.items) do
      rows[#rows + 1] = dom.tr({
        key = tostring(log.id),
        class = "border-b border-[var(--border)] cursor-pointer hover:bg-[var(--bg-elev)]",
        tabindex = "0", ["aria-haspopup"] = "dialog",
        ["aria-label"] = (log.action or "") .. ", " .. (log.user_email or log.user_id or "anonim") .. ", ayrıntıyı aç",
        onclick = function() open_detail(log) end,
        onkeydown = function(e) if e.key == "Enter" or e.key == " " then open_detail(log) end end,
      },
        dom.td({ class = "py-2 pr-3", ["data-label"] = "Zaman" },
          type(log.created_at) == "string" and js.format_date(log.created_at) or "—"),
        dom.td({ class = "py-2 pr-3", ["data-label"] = "Kullanıcı" }, log.user_email or log.user_id or "—"),
        dom.td({ class = "py-2 pr-3", ["data-label"] = "Eylem" }, log.action or "—"),
        dom.td({ class = "py-2 pr-3", ["data-label"] = "Varlık" }, (log.entity_type or "—")
          .. (type(log.entity_id) == "string" and (" · " .. log.entity_id:sub(1, 8)) or "")),
        dom.td({ class = "py-2 pr-3", ["data-label"] = "IP" }, log.ip or "—"),
        dom.td({ class = "py-2 pr-3", ["data-label"] = "Durum" },
          dom.span({ class = log.status == "failure" and "text-[var(--danger)]" or "text-[var(--success)]" },
            log.status == "failure" and "Başarısız" or "Başarılı")))
    end
    body = dom.tbody({ ["aria-busy"] = tostring(st.status == "loading") }, dom.list(rows))
  end

  local stats = st.stats or {}
  -- API şekli: by_action = [ { action, count }, ... ], by_status = { success, failure }, by_day = [ { day, count } ]
  local by_action = type(stats.by_action) == "table" and stats.by_action or {}
  local by_day = type(stats.by_day) == "table" and stats.by_day or {}
  -- basit istatistik kartları: toplam, başarısız, en çok eylem, günlük kayıt
  local top_action, top_count = nil, 0
  if by_action[1] ~= nil then
    for _, row in ipairs(by_action) do
      local k, v = row.action, tonumber(row.count) or 0
      if v > top_count then top_action, top_count = k, v end
    end
  else
    for k, v in pairs(by_action) do
      local n = tonumber(v) or 0
      if n > top_count then top_action, top_count = k, n end
    end
  end
  local failure_count = type(stats.by_status) == "table" and tonumber(stats.by_status.failure) or nil

  return dom.section({ ["aria-labelledby"] = "audit-title" },
    dom.header({ class = "flex items-center justify-between gap-2 mb-4" },
      dom.h1({ id = "audit-title", class = "text-2xl font-bold flex items-center gap-2", tabindex = "-1" },
        icons.get("list", "w-6 h-6 text-[var(--primary)]"), "Denetim Kayıtları"),
      icons.button({ icon = st.exporting and "clock" or "download",
        label = st.exporting and "Hazırlanıyor…" or "CSV indir",
        variant = "secondary", disabled = st.exporting and true or nil,
        title = "Denetim kayıtlarını CSV olarak indir",
        onclick = function() export_csv(f) end })),
    dom.ul({ class = "grid grid-cols-2 lg:grid-cols-4 gap-3 mb-4", role = "list", ["aria-label"] = "Özet" },
      stat_li("Toplam", stats.total or meta.total, false, "list"),
      stat_li("Başarısız", failure_count, true, "alert-triangle"),
      stat_li("En çok eylem", top_action and (top_action .. " (" .. top_count .. ")") or nil, false, "zap"),
      stat_li("Günlük kayıt", type(by_day) == "table" and by_day[1] and
        (tonumber(by_day[1].count) or tonumber(by_day[1].total)) or nil, false, "clock")),
    dom.form({ role = "search", ["aria-label"] = "Audit filtreleri", class = "flex flex-wrap items-end gap-2 mb-4" },
      dom.div({ class = "flex flex-col" },
        dom.label({ ["for"] = "audit-filter-1", class = "text-xs text-[var(--fg-muted)]" }, "Eylem"),
        dom.select({ id = "audit-filter-1", value = f.action or "", class = field_cls,
          onchange = function(e) set_filters({ action = e.value or "" }) end }, dom.list(action_opts))),
      dom.div({ class = "flex flex-col" },
        dom.label({ ["for"] = "audit-filter-2", class = "text-xs text-[var(--fg-muted)]" }, "Varlık türü"),
        dom.select({ id = "audit-filter-2", value = f.entity_type or "", class = field_cls,
          onchange = function(e) set_filters({ entity_type = e.value or "" }) end }, dom.list(entity_opts))),
      dom.div({ class = "flex flex-col" },
        dom.label({ ["for"] = "audit-filter-3", class = "text-xs text-[var(--fg-muted)]" }, "Kullanıcı"),
        dom.select({ id = "audit-filter-3", value = f.user_id or "", class = field_cls,
          onchange = function(e) set_filters({ user_id = e.value or "" }) end }, dom.list(user_opts))),
      dom.label({ class = "flex flex-col text-xs text-[var(--fg-muted)] flex-1 min-w-40" }, "Arama",
        dom.input({
          type = "search", class = field_cls, value = f.search or "", placeholder = "Eylem/varlık/ip…",
          oninput = function(e)
            if debounce_id then js.timer.cancel(debounce_id) end
            local v = e.value or ""
            debounce_id = js.timer.after(300, function() set_filters({ search = v }) end)
          end,
        })),
      dom.label({ class = "flex flex-col text-xs text-[var(--fg-muted)]" }, "Başlangıç",
        dom.input({
          type = "datetime-local", class = field_cls,
          value = type(f.from) == "string" and f.from:sub(1, 16) or "",
          onchange = function(e)
            local v = e.value or ""
            local iso = v ~= "" and js.to_iso_utc(v) or ""
            set_filters({ from = iso })
          end,
        })),
      dom.label({ class = "flex flex-col text-xs text-[var(--fg-muted)]" }, "Bitiş",
        dom.input({
          type = "datetime-local", class = field_cls,
          value = type(f.to) == "string" and f.to:sub(1, 16) or "",
          onchange = function(e)
            local v = e.value or ""
            local iso = v ~= "" and js.to_iso_utc(v) or ""
            set_filters({ to = iso })
          end,
        })),
      icons.button({ icon = "eraser", label = "Filtreleri sıfırla", variant = "ghost",
        title = "Tüm filtreleri temizle", onclick = function() router.navigate("#/audit") end })),
    (st.status ~= "loading" and #st.items == 0)
      and layout.empty_state({ icon_svg = "list", title = "Kayıt yok", text = "Bu filtrelerle eşleşen denetim kaydı yok" })
      or dom.div({ class = "overflow-x-auto" },
        dom.table({ class = "w-full text-sm responsive-table" },
          dom.caption({ class = "sr-only" }, "Denetim kayıtları, " .. (meta.total or 0) .. " kayıt"),
          dom.thead({}, dom.tr({ class = "text-left text-[var(--fg-muted)]" },
            dom.th({ scope = "col", class = "py-2 pr-3", ["aria-sort"] = "descending" }, "Zaman"),
            dom.th({ scope = "col", class = "py-2 pr-3" }, "Kullanıcı"),
            dom.th({ scope = "col", class = "py-2 pr-3" }, "Eylem"),
            dom.th({ scope = "col", class = "py-2 pr-3" }, "Varlık"),
            dom.th({ scope = "col", class = "py-2 pr-3" }, "IP"),
            dom.th({ scope = "col", class = "py-2 pr-3" }, "Durum"))),
          body)),
    layout.pagination(meta, function(p) set_filters({ page = tostring(p) }) end),
    st.selected and detail_drawer(state) or nil)
end

return _M
