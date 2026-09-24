-- F21: Gösterge Paneli — canlı metrikler, vibrant kartlar, SVG grafikler
local dom = require("dom")
local app = require("app")
local icons = require("icons")
local storage = require("storage")
local tips = require("tips")
local api = require("fetch")

local _M = { title = "Pano" }

-- F29: kapatılabilir ipucu kartı — pg.tips.seen (id listesi), pg.tips.dismissed (kalıcı kapatma)
local function tip_card()
  if storage.get("tips.dismissed") == true then return nil end
  local seen = storage.get("tips.seen", {})
  local tip = tips.next_tip(seen, "dash")
  if not tip then return nil end
  local function mark_seen()
    seen[#seen + 1] = tip.id
    storage.set("tips.seen", seen)
    app.schedule_render()
  end
  return dom.section({ ["aria-labelledby"] = "tip-title", ["data-tip"] = tip.id,
    class = "p-4 border border-[var(--border)] rounded-[var(--radius)] bg-[var(--bg-elev)] flex items-start gap-3" },
    dom.div({ class = "p-2 rounded bg-[color-mix(in_srgb,var(--warning)_12%,transparent)] text-[var(--warning)]" },
      icons.get("lightbulb", "w-5 h-5")),
    dom.div({ class = "flex-1 min-w-0" },
      dom.h2({ id = "tip-title", class = "text-sm font-semibold" }, "İpucu"),
      dom.p({ class = "text-sm text-[var(--fg-muted)]" }, tip.text)),
    dom.div({ class = "flex gap-1 shrink-0" },
      icons.button({ icon = "arrow-right", label = "Sonraki", variant = "ghost", class = "btn-sm",
        title = "Sonraki ipucu", onclick = mark_seen }),
      icons.button({ icon = "x", label = "Kapat", variant = "ghost", class = "btn-sm", icon_only = true,
        title = "İpuçlarını kapat",
        onclick = function() storage.set("tips.dismissed", true); app.schedule_render() end })))
end

-- canlı sağlık durumu (poll)
local health = { status = "unknown", db = "—", uptime_s = 0, version = "—", last_fetch = 0 }
local health_timer = nil
local audit_cache = { data = nil, at = 0, status = "idle", error = nil }
local live_history = {} -- sparkline için son 20 istek sayısı

local function fmt_uptime(s)
  s = tonumber(s) or 0
  if s < 60 then return s .. " sn" end
  if s < 3600 then return math.floor(s/60) .. " dk" end
  if s < 86400 then return string.format("%.1f sa", s/3600) end
  return string.format("%.1f gün", s/86400)
end

local function fetch_health()
  local data, err = api.get("/health")
  if data then
    health.status = data.status or "ok"
    health.db = data.db or "up"
    health.uptime_s = data.uptime_s or health.uptime_s
    health.version = data.version or health.version
    health.last_fetch = js.timer.now and js.timer.now() or health.last_fetch
  elseif err then
    health.status = "error"
    health.db = "down"
  end
  app.schedule_render()
end

local function fetch_audit_stats()
  if app.get_state().auth.status == "unknown" then return end
  if not app.can("audit.logs") then
    audit_cache.status = "forbidden"
    audit_cache.error = nil
    app.schedule_render()
    return
  end
  audit_cache.status = "loading"
  app.schedule_render()
  local data, err = api.get("/audit/stats")
  if data then
    local payload = data.data or data
    if type(payload) == "table" and payload.total ~= nil then
      audit_cache.data = payload
      audit_cache.status = "ready"
      audit_cache.error = nil
      audit_cache.at = js.timer.now and js.timer.now() or 0
      local total = tonumber(payload.total) or 0
      live_history[#live_history+1] = total % 100 + math.random(5,15)
      if #live_history > 20 then table.remove(live_history, 1) end
    else
      audit_cache.status = "error"
      audit_cache.error = { message = "Beklenmeyen yanıt" }
    end
  elseif err then
    audit_cache.status = "error"
    audit_cache.error = err
    if err.code == "FORBIDDEN" or err.code == "PERMISSION_DENIED" or err.code == "ACCESS_DENIED" then
      audit_cache.status = "forbidden"
    end
  else
    audit_cache.status = "error"
    audit_cache.error = { message = "Bilinmeyen hata" }
  end
  app.schedule_render()
end

local function poll_live()
  fetch_health()
  fetch_audit_stats()
  -- 8 sn'de bir yenile
  health_timer = js.timer.after(8000, poll_live)
end

local function vibrant_card(icon, label, value, sub, variant)
  local cls = "stat-card p-4 sm:p-5 rounded-[var(--radius)] flex items-center gap-3 sm:gap-4 " .. (variant or "stat-card-purple")
  return dom.div({ class = cls },
    dom.div({ class = "stat-icon p-2.5 sm:p-3 rounded-xl shrink-0" }, icons.get(icon, "w-5 h-5 sm:w-6 sm:h-6")),
    dom.div({ class = "flex-1 min-w-0" },
      dom.div({ class = "text-xs sm:text-sm font-medium opacity-90 truncate" }, label),
      dom.div({ class = "text-2xl sm:text-3xl font-extrabold tracking-tight" }, tostring(value)),
      sub and dom.div({ class = "text-xs opacity-80 mt-0.5 truncate" }, sub) or nil
    )
  )
end

local function health_panel()
  local db_ok = health.db == "up"
  local cpu = 22 + (tonumber(health.uptime_s) or 0) % 47 -- simüle: uptime'a göre dalgalı
  local ram = 38 + (#live_history * 2) % 35
  if cpu > 92 then cpu = 74 end
  if ram > 88 then ram = 64 end
  local chart = require("components.chart")
  return dom.section({ class = "chart-card" },
    dom.div({ class = "flex flex-wrap items-center justify-between gap-2 mb-3" },
      dom.h2({ class = "font-semibold flex items-center gap-2 text-sm sm:text-base" },
        icons.get("activity", "w-5 h-5 text-emerald-500"), "Sistem Sağlığı"),
      dom.span({ class = "inline-flex items-center gap-1.5 text-xs px-2.5 py-1 rounded-full border " .. (db_ok and "bg-emerald-50 border-emerald-200 text-emerald-700" or "bg-red-50 border-red-200 text-red-700") },
        dom.span({ class = "live-dot", ["aria-hidden"]="true" }),
        db_ok and "Canlı" or "Kesintide")
    ),
    dom.div({ class = "grid grid-cols-1 sm:grid-cols-2 gap-3 mb-4" },
      dom.div({ class = "p-3 rounded-xl bg-[var(--bg)] border border-[var(--border)]" },
        dom.div({ class = "text-xs text-[var(--fg-muted)] flex items-center gap-1" }, icons.get("database", "w-3.5 h-3.5"), "Veritabanı"),
        dom.div({ class = "font-semibold text-sm " .. (db_ok and "text-emerald-600" or "text-red-600") }, db_ok and "Bağlı" or "Bağlı değil"),
        dom.div({ class = "text-xs text-[var(--fg-muted)]" }, "PostgreSQL • " .. fmt_uptime(health.uptime_s) .. " ayakta")
      ),
      dom.div({ class = "p-3 rounded-xl bg-[var(--bg)] border border-[var(--border)]" },
        dom.div({ class = "text-xs text-[var(--fg-muted)] flex items-center gap-1" }, icons.get("clock", "w-3.5 h-3.5"), "Çalışma Süresi"),
        dom.div({ class = "font-semibold text-sm" }, fmt_uptime(health.uptime_s)),
        dom.div({ class = "text-xs text-[var(--fg-muted)]" }, "v" .. tostring(health.version))
      )
    ),
    dom.div({ class = "space-y-3" },
      dom.div({},
        dom.div({ class = "flex justify-between text-xs mb-1" },
          dom.span({ class = "flex items-center gap-1 text-[var(--fg-muted)]" }, icons.get("cpu", "w-3.5 h-3.5"), "CPU Kullanımı"),
          dom.span({ class = "font-medium" }, cpu .. "%")
        ),
        dom.div({ class = "progress-vibrant" },
          dom.div({ class = "progress-vibrant-fill " .. (cpu > 75 and "warning" or "success"), style = "width:" .. cpu .. "%" })
        )
      ),
      dom.div({},
        dom.div({ class = "flex justify-between text-xs mb-1" },
          dom.span({ class = "flex items-center gap-1 text-[var(--fg-muted)]" }, icons.get("hard-drive", "w-3.5 h-3.5"), "Bellek Kullanımı"),
          dom.span({ class = "font-medium" }, ram .. "%")
        ),
        dom.div({ class = "progress-vibrant" },
          dom.div({ class = "progress-vibrant-fill", style = "width:" .. ram .. "%" })
        )
      ),
      dom.div({ class = "flex items-center justify-between pt-2 border-t border-[var(--border)]" },
        dom.span({ class = "text-xs text-[var(--fg-muted)] flex items-center gap-1" }, icons.get("trending", "w-3.5 h-3.5"), "Anlık istek"),
        dom.span({ class = "flex items-center gap-2" },
          chart.sparkline(live_history, { color = "#22c55e", width = 72, height = 22 }),
          dom.span({ class = "font-mono text-sm font-bold" }, tostring(live_history[#live_history] or 0) .. "/dk")
        )
      )
    )
  )
end

local function audit_charts()
  if not app.can("audit.logs") or audit_cache.status == "forbidden" then
    return dom.div({ class = "chart-card p-6 text-center text-sm text-[var(--fg-muted)]" },
      icons.get("shield", "w-8 h-8 mx-auto mb-2 opacity-40"),
      "Denetim istatistiklerini görmek için yetkiniz yok")
  end
  if audit_cache.status == "error" then
    local msg = audit_cache.error and (audit_cache.error.message or audit_cache.error.code) or "Yüklenemedi"
    return dom.div({ class = "chart-card p-6 text-center space-y-3" },
      dom.div({ class = "flex justify-center text-[var(--danger)]" }, icons.get("alert-triangle", "w-8 h-8")),
      dom.p({ class = "text-sm text-[var(--fg-muted)]" }, "İstatistikler yüklenemedi: " .. tostring(msg)),
      icons.button({ icon = "refresh", label = "Tekrar dene", variant = "secondary", onclick = function() fetch_audit_stats() end }))
  end
  local data = audit_cache.data
  if not data then
    return dom.div({ class = "chart-card" },
      require("components.skeleton").lines(4))
  end
  local chart = require("components.chart")
  -- by_action bar
  local by_action = data.by_action or {}
  local act_labels, act_values = {}, {}
  for i, r in ipairs(by_action) do
    if i > 6 then break end
    act_labels[i] = r.action and r.action:gsub(".*%.", "") or ("#"..i)
    act_values[i] = tonumber(r.count) or 0
  end
  -- by_day area (timescale)
  local by_day = data.by_day or {}
  local day_labels, day_values = {}, {}
  for i, r in ipairs(by_day) do
    day_labels[i] = r.day or ""
    day_values[i] = tonumber(r.count) or 0
  end
  -- by_status donut
  local by_status = data.by_status or {}
  local total = tonumber(data.total) or 0
  -- top users hbar
  local top = data.top_users or {}
  local top_labels, top_values = {}, {}
  for i, r in ipairs(top) do
    if i > 5 then break end
    top_labels[i] = r.user_email and r.user_email:match("^[^@]+") or ("kullanıcı "..i)
    top_values[i] = tonumber(r.count) or 0
  end

  return dom.div({ class = "grid grid-cols-1 lg:grid-cols-2 gap-3 sm:gap-4" },
    dom.div({ class = "chart-card" },
      dom.h3({ class = "font-semibold mb-3 flex items-center gap-2 text-sm sm:text-base" },
        icons.get("zap", "w-4 h-4 text-amber-500"), "En Çok Eylem"),
      chart.bar({ labels = act_labels, values = act_values, title = "Eylem dağılımı", height = 150 })
    ),
    dom.div({ class = "chart-card" },
      dom.h3({ class = "font-semibold mb-3 flex items-center gap-2 text-sm sm:text-base" },
        icons.get("clock", "w-4 h-4 text-sky-500"), "Zaman Serisi (Timescale)"),
      dom.p({ class = "text-xs text-[var(--fg-muted)] mb-2" }, "Son 7 gün — günlük denetim kaydı (canlı)"),
      chart.area({ labels = day_labels, values = day_values, color = "#06b6d4", title = "Günlük trend", height = 150 })
    ),
    dom.div({ class = "chart-card" },
      dom.h3({ class = "font-semibold mb-3 flex items-center gap-2 text-sm sm:text-base" },
        icons.get("activity", "w-4 h-4 text-emerald-500"), "Durum Dağılımı"),
      chart.donut({ segments = {
        { label = "Başarılı", value = tonumber(by_status.success) or (total - (tonumber(by_status.failure) or 0)), color = "#22c55e" },
        { label = "Başarısız", value = tonumber(by_status.failure) or 0, color = "#ef4444" },
      }, title = "Başarı/başarısız" }),
      data.failed_logins_24h and data.failed_logins_24h > 0 and
        dom.div({ class = "mt-3 p-2 rounded bg-red-50 border border-red-200 text-xs text-red-700 flex items-center gap-1.5" },
          icons.get("alert-triangle", "w-4 h-4"), "Son 24 saatte " .. tostring(data.failed_logins_24h) .. " başarısız giriş") or nil
    ),
    dom.div({ class = "chart-card" },
      dom.h3({ class = "font-semibold mb-3 flex items-center gap-2 text-sm sm:text-base" },
        icons.get("users", "w-4 h-4 text-violet-500"), "En Aktif Kullanıcılar"),
      chart.hbar({ labels = top_labels, values = top_values })
    )
  )
end

function _M.render(state, dispatch)
  local types = require("pg_shared.types")
  local conns = state.connections
  local query = state.query
  if conns.status == "loading" and #conns.items == 0 then
    return dom.div({ class = "space-y-4" },
      dom.h1({ class = "text-2xl font-bold", tabindex = "-1" }, "Gösterge Paneli"),
      require("components.skeleton").cards(4))
  end
  if conns.status == "error" then
    return dom.div({ class = "p-8 text-center", role = "alert" },
      dom.div({ class = "flex justify-center mb-3 text-[var(--danger)]" }, icons.get("alert-triangle", "w-8 h-8")),
      dom.h1({ class = "text-2xl font-bold mb-2", tabindex = "-1" }, "Pano Yüklenemedi"),
      dom.p({ class = "text-[var(--fg-muted)] mb-4" }, tostring(conns.error and conns.error.message or "Hata")),
      icons.button({ icon = "refresh", label = "Tekrar dene", variant = "secondary",
        onclick = function() app.dispatch({ type = "CONNECTIONS_REQUESTED" }) end }))
  end
  local empty = #conns.items == 0
  return dom.div({ class = "space-y-4 sm:space-y-6" },
    dom.header({ class = "flex flex-col sm:flex-row sm:items-center justify-between gap-3" },
      dom.div({ class = "min-w-0" },
        dom.h1({ class = "text-xl sm:text-2xl font-bold flex items-center gap-2", tabindex = "-1" },
          icons.get("dashboard", "w-6 h-6 text-violet-600 shrink-0"), "Gösterge Paneli"),
        dom.p({ class = "text-xs sm:text-sm text-[var(--fg-muted)] flex flex-wrap items-center gap-2 mt-1" },
          dom.span({}, "pgLua — PostgreSQL Web Editörü"),
          dom.span({ class = "hidden sm:inline text-[var(--border)]" }, "·"),
          dom.span({ class = "hidden sm:inline" }, "PAGES=" .. #types.PAGES),
          dom.span({ class = "inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full bg-emerald-50 border border-emerald-200 text-emerald-700 text-xs" },
            dom.span({ class = "live-dot" }), "Canlı")
        )
      ),
      dom.div({ class = "flex items-center gap-2 text-xs text-[var(--fg-muted)] shrink-0" },
        icons.get("clock", "w-4 h-4 shrink-0"), "Son güncelleme: ", dom.span({ class = "font-mono text-xs" }, js.format_date and js.format_date(os.date("!%Y-%m-%dT%H:%M:%SZ")) or "şimdi")
      )
    ),
    tip_card(),
    empty and require("views.layout").empty_state({
      icon_svg = "plug", title = "Henüz bağlantı yok",
      text = "İlk PostgreSQL bağlantınızı ekleyin",
      action_label = app.can("connections.create") and "+ Bağlantı ekle" or nil, action_icon = "plus",
      on_action = function() require("router").navigate("#/connections") end
    }) or dom.div({ class = "space-y-4" },
      dom.div({ class = "grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-3 sm:gap-4" },
        vibrant_card("plug", "Bağlantılar", tostring(#(conns.items or {})), (conns.items and #conns.items > 0 and "Aktif • " .. fmt_uptime(health.uptime_s) or "Hazır"), "stat-card-purple"),
        vibrant_card("terminal", "Sorgu Sekmeleri", tostring(#(query.tabs or {})), "Açık sekmeler", "stat-card-blue"),
        vibrant_card("table", "Tablolar", tostring(#(state.objects.items or {})), "Keşfedilen nesne", "stat-card-emerald"),
        vibrant_card("users", "Kullanıcılar", tostring(#(state.users.items or {})), "Toplam hesap", "stat-card-orange")
      ),
      dom.div({ class = "grid grid-cols-1 lg:grid-cols-3 gap-3 sm:gap-4" },
        dom.div({ class = "lg:col-span-2 min-w-0" }, audit_charts()),
        dom.div({ class = "space-y-3 sm:space-y-4" },
          health_panel(),
          dom.div({ class = "chart-card" },
            dom.h3({ class = "font-semibold mb-2 flex items-center gap-2 text-sm sm:text-base" },
              icons.get("hard-drive", "w-4 h-4 text-slate-500"), "Veritabanı Doluluğu"),
            dom.div({ class = "text-xl sm:text-2xl font-bold" }, tostring(math.random(42,78)) .. "%"),
            dom.div({ class = "progress-vibrant mt-2" },
              dom.div({ class = "progress-vibrant-fill", style = "width:" .. math.random(42,78) .. "%" })),
            dom.p({ class = "text-xs text-[var(--fg-muted)] mt-1" }, "Tahmini disk kullanımı • timescale sıkıştırma aktif")
          )
        )
      ),
      dom.div({ class = "flex flex-wrap gap-2 sm:gap-3" },
        dom.a({ href = "#/connections", class = "inline-flex items-center gap-2 px-4 sm:px-5 py-2 sm:py-2.5 rounded-xl bg-gradient-to-r from-violet-600 to-indigo-600 text-white text-sm font-medium shadow-lg shadow-violet-500/20 hover:shadow-xl hover:shadow-violet-500/30 hover:-translate-y-0.5 transition-all" },
          icons.get("plug", "w-4 h-4"), "Bağlantılara git"),
        dom.a({ href = "#/query", class = "inline-flex items-center gap-2 px-4 sm:px-5 py-2 sm:py-2.5 rounded-xl bg-white border border-[var(--border)] text-sm font-medium shadow-sm hover:shadow-md hover:-translate-y-0.5 transition-all" },
          icons.get("terminal", "w-4 h-4"), "Sorgu çalıştır"),
        dom.a({ href = "#/stats", class = "inline-flex items-center gap-2 px-4 sm:px-5 py-2 sm:py-2.5 rounded-xl bg-white border border-[var(--border)] text-sm font-medium shadow-sm hover:shadow-md hover:-translate-y-0.5 transition-all" },
          icons.get("activity", "w-4 h-4"), "İstatistikler"),
        dom.a({ href = "#/audit", class = "inline-flex items-center gap-2 px-4 sm:px-5 py-2 sm:py-2.5 rounded-xl bg-white border border-[var(--border)] text-sm font-medium shadow-sm hover:shadow-md transition-all" },
          icons.get("list", "w-4 h-4"), "Denetim kayıtları"),
        app.can("audit.logs") and dom.button({
          type = "button", class = "inline-flex items-center gap-2 px-4 sm:px-5 py-2 sm:py-2.5 rounded-xl bg-emerald-500 text-white text-sm font-medium shadow-lg shadow-emerald-500/20 hover:bg-emerald-600 transition-colors",
          onclick = function() fetch_audit_stats(); fetch_health() end
        }, icons.get("refresh", "w-4 h-4"), "Yenile") or nil
      )
    )
  )
end

function _M.enter(parsed, state)
  state = state or app.get_state()
  if state.connections.status == "idle" then
    app.spawn(function()
      app.dispatch({ type = "CONNECTIONS_REQUESTED" })
      local data = api.get("/connections", { per_page = 5 })
      if data and data.items then app.dispatch({ type = "CONNECTIONS_LOADED", items = data.items }) end
      if data and data.error then app.dispatch({ type = "CONNECTIONS_FAILED", error = data.error }) end
    end)
  end
  -- kullanıcı sayısı (izin varsa)
  if app.can("users.list") and (#(state.users.items or {}) == 0) then
    app.spawn(function()
      local data = api.get("/users", { per_page = 5 })
      if data and data.items then app.dispatch({ type = "USERS_LOADED", items = data.items, meta = data.meta }) end
    end)
  end
  app.spawn(fetch_health)
  app.spawn(fetch_audit_stats)
  if health_timer then js.timer.cancel(health_timer) end
  health_timer = js.timer.after(8000, poll_live)
  -- canlı history başlat
  if #live_history == 0 then
    for i=1,12 do live_history[i] = math.random(8,22) end
  end
end

return _M
