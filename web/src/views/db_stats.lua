-- DB Detaylı İstatistikler — bağlı hedef DB'nin boyut, tablo, sorgu geçmişi grafikleri
local dom = require("dom")
local app = require("app")
local api = require("fetch")
local router = require("router")
local icons = require("icons")
local storage = require("storage")

local _M = {}
_M.title = "Veritabanı İstatistikleri"
_M.layout = true

local cache = { key = nil, data = nil, status = "idle", error = nil }
local db_list_cache = {} -- connection_id -> { status, items }

local function fmt_bytes(n)
  n = tonumber(n) or 0
  if n == 0 then return "0 B" end
  local units = { "B", "KB", "MB", "GB", "TB" }
  local i = 1
  while n >= 1024 and i < #units do n = n / 1024; i = i + 1 end
  if i == 1 then return string.format("%d %s", n, units[i]) end
  return string.format("%.1f %s", n, units[i])
end

local function fmt_num(n)
  n = tonumber(n) or 0
  if n >= 1000000 then return string.format("%.1fM", n/1000000) end
  if n >= 1000 then return string.format("%.1fK", n/1000) end
  return tostring(n)
end

local function current_params()
  local cur = router.current() or {}
  local q = cur.query or {}
  local st = app.get_state()
  local conn_id = q.connection_id or (st.connections.items[1] and st.connections.items[1].id) or ""
  local database = q.database
  if database == "" then database = nil end
  local range = q.range or "7d" -- 7d / 30d
  return { connection_id = conn_id, database = database, range = range }
end

local function cache_key(p) return (p.connection_id or "") .. "|" .. (p.database or "") end

local function load_stats(p)
  if not p.connection_id or p.connection_id == "" then return end
  local key = cache_key(p)
  cache = { key = key, data = cache.key == key and cache.data or nil, status = "loading", error = nil }
  app.schedule_render()
  local q = {}
  if p.database then q.database = p.database end
  local data, err = api.get("/connections/" .. router.urlencode(p.connection_id) .. "/stats", q)
  if cache.key ~= key then return end
  if err then
    cache.status, cache.error = "error", err
  else
    local d = data and data.data or data
    cache.data, cache.status = d, "ready"
  end
  app.schedule_render()
end

local function load_databases(conn_id)
  if not conn_id or conn_id == "" then return end
  db_list_cache[conn_id] = { status = "loading", items = db_list_cache[conn_id] and db_list_cache[conn_id].items or {} }
  local data, err = api.get("/connections/" .. router.urlencode(conn_id) .. "/databases")
  if err then
    db_list_cache[conn_id] = { status = "error", error = err, items = db_list_cache[conn_id].items or {} }
  else
    local list = type(data) == "table" and data or {}
    -- api returns { data = [...] } or plain array
    if data and data.data then list = data.data end
    if type(list) ~= "table" then list = {} end
    db_list_cache[conn_id] = { status = "ready", items = list }
  end
  app.schedule_render()
end

function _M.enter(route)
  local p = current_params()
  if not p.connection_id or p.connection_id == "" then
    -- bağlantılar yüklenmemişse yükle
    local st = app.get_state()
    if st.connections.status == "idle" then
      app.spawn(function()
        app.dispatch({ type = "CONNECTIONS_REQUESTED" })
        local data = api.get("/connections", { per_page = 100 })
        if data and data.items then app.dispatch({ type = "CONNECTIONS_LOADED", items = data.items }) end
        local cur = current_params()
        if cur.connection_id ~= "" then load_stats(cur); load_databases(cur.connection_id) end
      end)
    end
    return
  end
  load_databases(p.connection_id)
  if cache.key ~= cache_key(p) or cache.status == "idle" then
    app.spawn(load_stats, p)
  end
end

local function vibrant_card(icon, label, value, sub, variant)
  local cls = "stat-card p-4 sm:p-5 rounded-[var(--radius)] flex items-center gap-3 sm:gap-4 " .. (variant or "stat-card-purple")
  return dom.div({ class = cls },
    dom.div({ class = "stat-icon p-2.5 sm:p-3 rounded-xl shrink-0" }, icons.get(icon, "w-5 h-5 sm:w-6 sm:h-6")),
    dom.div({ class = "flex-1 min-w-0" },
      dom.div({ class = "text-xs sm:text-sm font-medium opacity-90 truncate" }, label),
      dom.div({ class = "text-xl sm:text-2xl font-extrabold tracking-tight truncate" }, tostring(value)),
      sub and dom.div({ class = "text-xs opacity-80 mt-0.5 truncate" }, sub) or nil
    )
  )
end

local function set_query(patch)
  router.replace_query(patch)
end

local function selector(p)
  local st = app.get_state()
  local conns = st.connections.items or {}
  local conn_opts = {}
  for _, c in ipairs(conns) do
    conn_opts[#conn_opts+1] = dom.option({ value = c.id, selected = c.id == p.connection_id and "selected" or nil },
      c.name .. " (" .. c.host .. ":" .. tostring(c.port) .. ")")
  end
  -- database opts
  local db_info = db_list_cache[p.connection_id]
  if not db_info and p.connection_id ~= "" then app.spawn(load_databases, p.connection_id) end
  local dbs = db_info and db_info.items or {}
  local db_opts = { dom.option({ value = "" }, "Varsayılan (" .. (p.database or "otomatik") .. ")") }
  for _, name in ipairs(dbs) do
    if type(name) == "string" then
      db_opts[#db_opts+1] = dom.option({ value = name, selected = name == p.database and "selected" or nil }, name)
    end
  end
  return dom.div({ class = "flex flex-col sm:flex-row gap-2 sm:gap-3 p-3 border border-[var(--border)] rounded-[var(--radius)] bg-[var(--bg-elev)]" },
    dom.div({ class = "flex-1 min-w-0" },
      dom.label({ class = "block text-xs font-medium text-[var(--fg-muted)] mb-1" }, "Bağlantı"),
      dom.select({
        class = "w-full px-3 py-2 border border-[var(--border)] rounded-[var(--radius)] bg-[var(--bg)] text-sm",
        onchange = function(e) set_query({ connection_id = e.value, database = "" }) end
      }, dom.option({ value = "" }, conns[1] and "Bağlantı seç" or "Bağlantı yok"), dom.list(conn_opts))),
    dom.div({ class = "flex-1 min-w-0" },
      dom.label({ class = "block text-xs font-medium text-[var(--fg-muted)] mb-1" }, "Veritabanı"),
      dom.select({
        class = "w-full px-3 py-2 border border-[var(--border)] rounded-[var(--radius)] bg-[var(--bg)] text-sm",
        onchange = function(e) set_query({ database = e.value }) end
      }, dom.list(db_opts))),
    dom.div({ class = "flex items-end gap-2" },
      dom.select({
        class = "px-3 py-2 border border-[var(--border)] rounded-[var(--radius)] bg-[var(--bg)] text-sm",
        value = p.range,
        onchange = function(e) set_query({ range = e.value }) end
      },
        dom.option({ value = "7d", selected = p.range == "7d" and "selected" or nil }, "Son 7 gün"),
        dom.option({ value = "30d", selected = p.range == "30d" and "selected" or nil }, "Son 30 gün")),
      icons.button({ icon = "refresh", label = "Yenile", variant = "secondary", class = "shrink-0",
        onclick = function() load_stats(p) end })))
end

local function stat_table(headers, rows, empty_text)
  if #rows == 0 then
    return dom.p({ class = "text-sm text-[var(--fg-muted)] p-4 text-center border border-dashed rounded" }, empty_text or "Veri yok")
  end
  local head = {}
  for i, h in ipairs(headers) do head[i] = dom.th({ scope = "col", class = "py-2 px-3 text-left text-xs font-semibold text-[var(--fg-muted)] bg-[var(--bg)] border-b border-[var(--border)] whitespace-nowrap sticky top-0" }, h) end
  local body = {}
  for i, r in ipairs(rows) do
    local cells = {}
    for j, v in ipairs(r) do cells[j] = dom.td({ class = "py-2 px-3 text-sm border-b border-[var(--border)]" }, v) end
    body[i] = dom.tr({ class = "hover:bg-[var(--bg-elev)]" }, dom.list(cells))
  end
  return dom.div({ class = "overflow-auto border border-[var(--border)] rounded max-h-[24rem] -mx-3 sm:mx-0" },
    dom.div({ class = "min-w-[560px] px-3 sm:px-0" },
      dom.table({ class = "w-full text-sm border-collapse" },
        dom.thead({}, dom.tr({}, dom.list(head))),
        dom.tbody({}, dom.list(body)))))
end

function _M.render(state, dispatch)
  local p = current_params()
  local st = state.connections
  if #st.items == 0 and st.status == "idle" then
    return dom.div({ class = "space-y-4" },
      dom.h1({ class = "text-xl sm:text-2xl font-bold flex items-center gap-2", tabindex = "-1" },
        icons.get("activity", "w-6 h-6 text-violet-600"), "Veritabanı İstatistikleri"),
      require("components.skeleton").lines(4))
  end
  if p.connection_id == "" then
    return dom.div({ class = "space-y-4" },
      dom.h1({ class = "text-xl sm:text-2xl font-bold flex items-center gap-2", tabindex = "-1" },
        icons.get("activity", "w-6 h-6 text-violet-600"), "Veritabanı İstatistikleri"),
      selector(p),
      require("views.layout").empty_state({
        icon_svg = "database", title = "Bağlantı seçin",
        text = "Detaylı istatistikler için bir bağlantı seçin",
        action_label = p.connection_id == "" and "Bağlantı yok" or nil
      }))
  end

  local d = cache.data
  local loading = cache.status == "loading" and not d
  local err = cache.status == "error" and cache.error

  if err then
    return dom.div({ class = "space-y-4" },
      dom.h1({ class = "text-xl sm:text-2xl font-bold flex items-center gap-2", tabindex = "-1" },
        icons.get("activity", "w-6 h-6 text-violet-600"), "Veritabanı İstatistikleri"),
      selector(p),
      dom.div({ class = "p-6 border border-[var(--danger)] rounded bg-[color-mix(in_srgb,var(--danger)_8%,transparent)] text-center", role = "alert" },
        dom.div({ class = "flex justify-center mb-2 text-[var(--danger)]" }, icons.get("alert-triangle", "w-8 h-8")),
        dom.p({ class = "font-semibold mb-1" }, "İstatistikler yüklenemedi"),
        dom.p({ class = "text-sm text-[var(--fg-muted)] mb-3" }, tostring(err and err.message or err and err.code or "Bilinmeyen hata")),
        icons.button({ icon = "refresh", label = "Tekrar dene", variant = "secondary", onclick = function() load_stats(p) end })))
  end

  if loading then
    return dom.div({ class = "space-y-4" },
      dom.h1({ class = "text-xl sm:text-2xl font-bold flex items-center gap-2", tabindex = "-1" },
        icons.get("activity", "w-6 h-6 text-violet-600"), "Veritabanı İstatistikleri"),
      selector(p),
      require("components.skeleton").lines(6))
  end

  if not d then
    return dom.div({ class = "space-y-4" },
      dom.h1({ class = "text-xl sm:text-2xl font-bold flex items-center gap-2", tabindex = "-1" },
        icons.get("activity", "w-6 h-6 text-violet-600"), "Veritabanı İstatistikleri"),
      selector(p),
      dom.div({ class = "p-8 text-center text-sm text-[var(--fg-muted)]" }, "Veri bekleniyor..."))
  end

  local summary = d.summary or {}
  local qh = d.query_history or {}
  local chart = require("components.chart")

  -- per_day seçimi
  local per_day = p.range == "30d" and (qh.per_day_30 or {}) or (qh.per_day_7 or {})
  local day_labels, day_values = {}, {}
  for i, r in ipairs(per_day) do day_labels[i] = r.day or ""; day_values[i] = tonumber(r.count) or 0 end

  -- per_hour
  local hour_labels, hour_values = {}, {}
  for i, r in ipairs(qh.per_hour or {}) do hour_labels[i] = tostring(r.hour) .. ":00"; hour_values[i] = tonumber(r.count) or 0 end

  -- per_database
  local pdb_labels, pdb_values = {}, {}
  for i, r in ipairs(qh.per_database or {}) do
    if i > 6 then break end
    pdb_labels[i] = r.database ~= "" and r.database or "(varsayılan)"
    pdb_values[i] = tonumber(r.count) or 0
  end

  -- top tables by size
  local tbl_labels, tbl_values = {}, {}
  for i, t in ipairs(d.top_tables or {}) do
    if i > 8 then break end
    tbl_labels[i] = t.name:sub(1,10)
    tbl_values[i] = tonumber(t.total_bytes) or 0
  end
  -- top by rows
  local row_labels, row_values = {}, {}
  for i, t in ipairs(d.top_by_rows or {}) do
    if i > 8 then break end
    row_labels[i] = t.name:sub(1,10)
    row_values[i] = tonumber(t.n_live_tup) or 0
  end
  -- schema distribution
  local sch_labels, sch_values = {}, {}
  for i, s in ipairs(d.schemas or {}) do
    if i > 6 then break end
    sch_labels[i] = s.schema
    sch_values[i] = tonumber(s.total_bytes) or 0
  end

  local hit_ratio = d.pg_stat_database and d.pg_stat_database.hit_ratio or 0

  return dom.div({ class = "space-y-4 sm:space-y-6" },
    dom.header({ class = "flex flex-col sm:flex-row sm:items-center justify-between gap-3" },
      dom.div({},
        dom.h1({ class = "text-xl sm:text-2xl font-bold flex items-center gap-2", tabindex = "-1" },
          icons.get("activity", "w-6 h-6 text-violet-600 shrink-0"), "Veritabanı İstatistikleri"),
        dom.p({ class = "text-xs sm:text-sm text-[var(--fg-muted)] mt-1 flex items-center gap-2" },
          dom.span({}, d.connection and d.connection.name or p.connection_id),
          d.current_database and dom.span({ class = "hidden sm:inline-flex items-center gap-1 px-2 py-0.5 rounded-full bg-[var(--bg-elev)] border text-xs" },
            icons.get("database", "w-3 h-3"), d.current_database) or nil,
          dom.span({ class = "inline-flex items-center gap-1 text-xs text-[var(--fg-muted)]" },
            icons.get("clock", "w-3 h-3"), d.current_db_size and d.current_db_size.size_pretty or fmt_bytes(summary.total_bytes)))),
      dom.div({ class = "flex items-center gap-2 text-xs text-[var(--fg-muted)]" },
        icons.button({ icon = "refresh", label = "Yenile", variant = "secondary", class = "btn-sm", onclick = function() load_stats(p) end }),
        dom.a({ href = "#/query?connection_id=" .. router.urlencode(p.connection_id) .. (p.database and ("&database=" .. router.urlencode(p.database)) or ""),
          class = "inline-flex items-center gap-1.5 px-3 py-1.5 text-sm border rounded hover:bg-[var(--bg-elev)]" }, icons.get("terminal", "w-4 h-4"), "Sorgu"))),

    selector(p),

    -- özet kartlar
    dom.div({ class = "grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-3 sm:gap-4" },
      vibrant_card("hard-drive", "Veritabanı Boyutu", d.current_db_size and d.current_db_size.size_pretty or fmt_bytes(summary.total_bytes), (summary.table_count or 0) .. " tablo", "stat-card-purple"),
      vibrant_card("table", "Toplam Tablo", tostring(summary.table_count or 0), fmt_num(summary.total_rows or 0) .. " satır", "stat-card-blue"),
      vibrant_card("zap", "Sorgu Sayısı", tostring(qh.total or 0), "Son 24s: " .. tostring(qh.last_24h or 0), "stat-card-emerald"),
      vibrant_card("clock", "Ort. Süre", tostring(qh.avg_duration_ms or 0) .. " ms", "Max: " .. tostring(qh.max_duration_ms or 0) .. " ms", "stat-card-orange")
    ),

    -- veritabanı listesi + aktivite
    dom.div({ class = "grid grid-cols-1 lg:grid-cols-3 gap-3 sm:gap-4" },
      dom.div({ class = "chart-card" },
        dom.h3({ class = "font-semibold mb-3 flex items-center gap-2 text-sm sm:text-base" }, icons.get("database", "w-4 h-4 text-sky-500"), "Veritabanları (boyuta göre)"),
        # (d.databases or {}) == 0 and dom.p({ class = "text-sm text-[var(--fg-muted)]" }, "Veritabanı listesi yok") or
          chart.hbar({ labels = (function() local l={}; for i,db in ipairs(d.databases or {}) do if i>6 then break end; l[i]=db.name end; return l end)(),
                       values = (function() local v={}; for i,db in ipairs(d.databases or {}) do if i>6 then break end; v[i]=tonumber(db.size_bytes) or 0 end; return v end)() })
      ),
      dom.div({ class = "chart-card" },
        dom.h3({ class = "font-semibold mb-3 flex items-center gap-2 text-sm sm:text-base" }, icons.get("activity", "w-4 h-4 text-emerald-500"), "Bağlantı Aktivitesi"),
        dom.div({ class = "grid grid-cols-3 gap-2 mb-3 text-center" },
          dom.div({ class = "p-2 rounded bg-[var(--bg)] border" }, dom.div({ class = "text-lg font-bold" }, tostring((d.activity or {}).total or 0)), dom.div({ class = "text-xs text-[var(--fg-muted)]" }, "Toplam")),
          dom.div({ class = "p-2 rounded bg-[var(--bg)] border" }, dom.div({ class = "text-lg font-bold text-emerald-600" }, tostring((d.activity or {}).active or 0)), dom.div({ class = "text-xs text-[var(--fg-muted)]" }, "Aktif")),
          dom.div({ class = "p-2 rounded bg-red-50 border border-red-200" }, dom.div({ class = "text-lg font-bold text-red-600" }, tostring((d.activity or {}).waiting or 0)), dom.div({ class = "text-xs text-[var(--fg-muted)]" }, "Bekleyen"))),
        dom.div({ class = "space-y-2" },
          dom.div({ class = "flex justify-between text-xs" }, dom.span({ class = "text-[var(--fg-muted)]" }, "Cache Hit"), dom.span({ class = "font-medium" }, string.format("%.1f%%", hit_ratio))),
          dom.div({ class = "progress-vibrant" }, dom.div({ class = "progress-vibrant-fill success", style = "width:" .. math.min(hit_ratio,100) .. "%" })),
          dom.p({ class = "text-xs text-[var(--fg-muted)]" }, "Blok hit oranı — yüksek olması iyi (disk okuma az)"))
      ),
      dom.div({ class = "chart-card" },
        dom.h3({ class = "font-semibold mb-2 flex items-center gap-2 text-sm sm:text-base" }, icons.get("table", "w-4 h-4 text-violet-500"), "Şema Dağılımı"),
        #sch_labels == 0 and dom.p({ class = "text-sm text-[var(--fg-muted)]" }, "Şema yok") or
          chart.donut({ segments = (function() local s={}; local cols={"#6366f1","#06b6d4","#8b5cf6","#f59e0b","#10b981","#ef4444"}; for i,l in ipairs(sch_labels) do s[i]={ label=l, value=sch_values[i], color=cols[((i-1)%#cols)+1]} end; return s end)(), title="Şema boyutları" })
      )
    ),

    -- grafik satırları
    dom.div({ class = "grid grid-cols-1 lg:grid-cols-2 gap-3 sm:gap-4" },
      dom.div({ class = "chart-card" },
        dom.h3({ class = "font-semibold mb-3 flex items-center gap-2 text-sm sm:text-base" }, icons.get("hard-drive", "w-4 h-4 text-sky-500"), "En Büyük Tablolar (boyut)"),
        chart.bar({ labels = tbl_labels, values = tbl_values, title = "Tablo boyutları", height = 160 })
      ),
      dom.div({ class = "chart-card" },
        dom.h3({ class = "font-semibold mb-3 flex items-center gap-2 text-sm sm:text-base" }, icons.get("table", "w-4 h-4 text-amber-500"), "En Kalabalık Tablolar (satır)"),
        chart.bar({ labels = row_labels, values = row_values, title = "Satır sayıları", height = 160 })
      )
    ),

    dom.div({ class = "grid grid-cols-1 lg:grid-cols-2 gap-3 sm:gap-4" },
      dom.div({ class = "chart-card" },
        dom.h3({ class = "font-semibold mb-3 flex items-center gap-2 text-sm sm:text-base" }, icons.get("clock", "w-4 h-4 text-sky-500"), qh.per_day_7 and "Sorgu Sayısı — Günlük" or "Sorgu Sayısı"),
        dom.div({ class = "flex gap-2 mb-2" },
          dom.button({
            type = "button",
            class = p.range == "7d" and "px-3 py-1 text-xs rounded bg-[var(--primary)] text-white" or "px-3 py-1 text-xs rounded border",
            onclick = function() set_query({ range = "7d" }) end
          }, "7 gün"),
          dom.button({
            type = "button",
            class = p.range == "30d" and "px-3 py-1 text-xs rounded bg-[var(--primary)] text-white" or "px-3 py-1 text-xs rounded border",
            onclick = function() set_query({ range = "30d" }) end
          }, "30 gün")),
        chart.area({ labels = day_labels, values = day_values, color = "#6366f1", title = "Günlük sorgu", height = 150 })
      ),
      dom.div({ class = "chart-card" },
        dom.h3({ class = "font-semibold mb-3 flex items-center gap-2 text-sm sm:text-base" }, icons.get("trending", "w-4 h-4 text-emerald-500"), "Saatlik Dağılım (24s)"),
        chart.bar({ labels = hour_labels, values = hour_values, title = "Saatlik sorgu", height = 150 })
      )
    ),

    dom.div({ class = "grid grid-cols-1 lg:grid-cols-2 gap-3 sm:gap-4" },
      dom.div({ class = "chart-card" },
        dom.h3({ class = "font-semibold mb-3 flex items-center gap-2 text-sm sm:text-base" }, icons.get("database", "w-4 h-4 text-violet-500"), "Sorgu — Veritabanına Göre"),
        #pdb_labels == 0 and dom.p({ class = "text-sm text-[var(--fg-muted)]" }, "Sorgu geçmişi yok") or
          chart.hbar({ labels = pdb_labels, values = pdb_values })
      ),
      dom.div({ class = "chart-card" },
        dom.h3({ class = "font-semibold mb-2 flex items-center gap-2 text-sm sm:text-base" }, icons.get("zap", "w-4 h-4 text-amber-500"), "pg_stat_database"),
        dom.dl({ class = "grid grid-cols-2 gap-3 text-sm" },
          dom.div({ class = "p-3 rounded bg-[var(--bg)] border" }, dom.dt({ class = "text-xs text-[var(--fg-muted)]" }, "Commit"), dom.dd({ class = "font-semibold" }, fmt_num((d.pg_stat_database or {}).xact_commit))),
          dom.div({ class = "p-3 rounded bg-[var(--bg)] border" }, dom.dt({ class = "text-xs text-[var(--fg-muted)]" }, "Rollback"), dom.dd({ class = "font-semibold" }, fmt_num((d.pg_stat_database or {}).xact_rollback))),
          dom.div({ class = "p-3 rounded bg-[var(--bg)] border" }, dom.dt({ class = "text-xs text-[var(--fg-muted)]" }, "Blks Read"), dom.dd({ class = "font-semibold" }, fmt_num((d.pg_stat_database or {}).blks_read))),
          dom.div({ class = "p-3 rounded bg-[var(--bg)] border" }, dom.dt({ class = "text-xs text-[var(--fg-muted)]" }, "Blks Hit"), dom.dd({ class = "font-semibold" }, fmt_num((d.pg_stat_database or {}).blks_hit))),
          dom.div({ class = "p-3 rounded bg-[var(--bg)] border" }, dom.dt({ class = "text-xs text-[var(--fg-muted)]" }, "Tup Fetched"), dom.dd({ class = "font-semibold" }, fmt_num((d.pg_stat_database or {}).tup_fetched))),
          dom.div({ class = "p-3 rounded bg-[var(--bg)] border" }, dom.dt({ class = "text-xs text-[var(--fg-muted)]" }, "Deadlocks"), dom.dd({ class = "font-bold text-[var(--danger)]" }, tostring((d.pg_stat_database or {}).deadlocks or 0))))
      )
    ),

    -- detay tablolar
    dom.div({ class = "space-y-4" },
      dom.h2({ class = "text-lg font-semibold flex items-center gap-2" }, icons.get("table", "w-5 h-5 text-[var(--primary)]"), "En Büyük 20 Tablo"),
      stat_table({ "Şema", "Tablo", "Toplam", "Tablo", "Index", "Satır", "Seq Scan", "Idx Scan" },
        (function()
          local rows = {}
          for i, t in ipairs(d.top_tables or {}) do
            rows[i] = { t.schema, t.name, t.total_pretty or fmt_bytes(t.total_bytes), t.table_pretty or fmt_bytes(t.table_bytes), t.index_pretty or fmt_bytes(t.index_bytes), fmt_num(t.n_live_tup), tostring(t.seq_scan), tostring(t.idx_scan) }
          end
          return rows
        end)(), "Tablo yok")
    ),

    # (d.bloat or {}) > 0 and dom.div({ class = "space-y-2" },
      dom.h2({ class = "text-lg font-semibold flex items-center gap-2 text-amber-600" }, icons.get("alert-triangle", "w-5 h-5"), "Bloat Uyarısı (dead tup yüksek)"),
      stat_table({ "Şema", "Tablo", "Live", "Dead", "Bloat %" },
        (function()
          local rows = {}
          for i, b in ipairs(d.bloat or {}) do
            rows[i] = { b.schema, b.name, fmt_num(b.live_tup), fmt_num(b.dead_tup), string.format("%.1f%%", b.bloat_ratio or 0) }
          end
          return rows
        end)(), "Bloat yok — iyi durum")
    ) or nil,

    dom.div({ class = "space-y-2" },
      dom.h2({ class = "text-lg font-semibold flex items-center gap-2" }, icons.get("zap", "w-5 h-5 text-[var(--primary)]"), "En Büyük Indexler"),
      stat_table({ "Şema", "Tablo", "Index", "Boyut", "Scan", "Tip" },
        (function()
          local rows = {}
          for i, ix in ipairs(d.top_indexes or {}) do
            rows[i] = { ix.schema, ix.table_name, ix.index_name, ix.size_pretty or fmt_bytes(ix.size_bytes), tostring(ix.idx_scan), (ix.is_primary and "PK" or ix.is_unique and "Unique" or "") }
          end
          return rows
        end)(), "Index yok")
    ),

    dom.div({ class = "space-y-2" },
      dom.h2({ class = "text-lg font-semibold flex items-center gap-2" }, icons.get("clock", "w-5 h-5 text-[var(--primary)]"), "En Yavaş Sorgular (kişisel geçmiş)"),
      stat_table({ "SQL (120)", "Süre", "DB", "Zaman" },
        (function()
          local rows = {}
          for i, s in ipairs(qh.slowest or {}) do
            rows[i] = { dom.div({ class = "font-mono text-xs truncate max-w-[28rem]", title = s.sql_preview or "" }, s.sql_preview or ""), tostring(s.duration_ms or 0) .. " ms", s.database or "-", s.executed_at and js.format_date(s.executed_at) or "-" }
          end
          return rows
        end)(), "Yavaş sorgu yok")
    )
  )
end

return _M
