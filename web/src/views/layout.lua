-- F17: Layout — üst bar (tema, kullanıcı, çıkış), izin bazlı yan menü, 403/404/iskelet blokları
-- View'lar render(state, dispatch) → vnode sözleşmesini izler; içerik #main içine konur.

local dom = require("dom")
local router = require("router")
local app = require("app")
local theme_toggle = require("components.theme_toggle")
local icons = require("icons")
local storage = require("storage")

local layout = {}
local last_saved_open = nil

-- Menü öğeleri; görünürlük tamamen izne bağlı
local NAV = {
  { href = "#/", label = "Pano", page_key = "dashboard", icon = "dashboard", routes = { dashboard = true } },
  { href = "#/connections", label = "Bağlantılar", page_key = "connections.list", icon = "plug",
    routes = { connections = true } },
  -- tablolar sorgu/tarayıcı sayfalarindaki nesne kenar cubugundan acilir (codd)
  { href = "#/query", label = "Sorgu", page_key = "query.execute", icon = "terminal",
    routes = { query = true, browse = true, structure = true, query_history = true } },
  { href = "#/stats", label = "İstatistikler", page_key = "dashboard", icon = "activity",
    routes = { db_stats = true } },
  { href = "#/users", label = "Kullanıcılar", page_key = "users.list", icon = "users", routes = { users = true } },
  { href = "#/rbac", label = "Yetkiler", page_key = "rbac.matrix", icon = "shield", routes = { rbac = true } },
  { href = "#/audit", label = "Denetim", page_key = "audit.logs", icon = "list", routes = { audit = true } },
  -- herkese açık (tema/görünüm); AI kartı sayfa içinde settings iznine bağlı
  { href = "#/settings", label = "Ayarlar", icon = "settings", routes = { settings = true } },
}

function layout.render(state, dispatch, content, title)
  local auth = state.auth
  local user = auth.user or {}
  local nav_items = {}
  for _, item in ipairs(NAV) do
    if not item.page_key or router.can(auth, item.page_key) then
      local active = item.routes[state.route.name or ""] == true
      nav_items[#nav_items + 1] = dom.li({},
        dom.a({
          href = item.href,
          class = active
            and "nav-link flex items-center gap-2 px-3 py-2.5 rounded-[var(--radius)] bg-[var(--primary)] " ..
              "text-[var(--primary-fg)] shadow-sm"
            or "nav-link flex items-center gap-2 px-3 py-2.5 rounded-[var(--radius)] hover:bg-[var(--bg)] text-[var(--fg)] transition-colors",
          ["aria-current"] = active and "page" or nil,
          title = item.label,
        }, icons.get(item.icon, "w-5 h-5 shrink-0"), dom.span({ class = "nav-label text-sm font-medium" }, item.label)))
    end
  end

  local open = state.ui.sidebar_open
  local mobile = js.media and js.media.matches and js.media.matches("(max-width: 767px)")
  -- masaüstünde tercih kalıcı (mobilde gezinme menüyü kapatır; o tercih sayılmaz)
  if not mobile and open ~= last_saved_open then
    last_saved_open = open
    storage.set_raw("sidebar", open and "open" or "rail")
  end
  return dom.div({ class = "min-h-screen flex flex-col lg:flex-row bg-[var(--bg)]" },
    -- mobil backdrop: açık menüyü kapatmak için
    open and mobile and dom.div({
      class = "fixed inset-0 bg-black/40 backdrop-blur-sm z-30 lg:hidden",
      ["aria-hidden"] = "true",
      onclick = function() dispatch({ type = "SIDEBAR_SET", sidebar_open = false }) end,
    }) or nil,
    dom.aside({
      id = "sidebar",
      ["aria-label"] = "Ana menü",
      -- kapalı: masaüstünde ikon rayı, mobilde tamamen gizli; açık: mobilde fixed overlay
      class = open
        and "sidebar sidebar-open w-72 sm:w-60 shrink-0 border-r border-[var(--border)] bg-[var(--bg-elev)] p-4 flex flex-col lg:static fixed inset-y-0 left-0 z-40 shadow-2xl lg:shadow-none overflow-y-auto"
        or "sidebar sidebar-rail hidden md:flex md:flex-col shrink-0 border-r border-[var(--border)] bg-[var(--bg-elev)] py-4 overflow-y-auto",
      ["data-collapsed"] = tostring(not open),
    },
      -- mobilde üst kapatma alanı
      open and dom.div({ class = "flex items-center justify-between mb-4 lg:hidden" },
        dom.a({ href = "#/", class = "text-lg font-bold flex items-center gap-2 hover:opacity-80 transition-opacity", title = "Panoya git" }, icons.get("database", "w-5 h-5 text-[var(--primary)]"), "pgLua"),
        dom.button({
          type = "button", class = "btn btn-ghost btn-icon btn-sm",
          ["aria-label"] = "Menüyü kapat",
          onclick = function() dispatch({ type = "SIDEBAR_SET", sidebar_open = false }) end,
        }, icons.get("x", "w-5 h-5"))) or nil,
      dom.nav({ ["aria-label"] = "Sayfalar", class = "flex-1" }, dom.ul({ class = "space-y-1", role = "list" }, nav_items)),
      dom.div({ class = "pt-4 mt-4 border-t border-[var(--border)] hidden lg:block" },
        dom.p({ class = "text-xs text-[var(--fg-muted)] px-3" }, "Ctrl+B ile daralt"))),
    dom.div({ class = "flex-1 flex flex-col min-w-0 min-h-screen" },
      dom.header({ class = "sticky top-0 z-20 flex items-center justify-between gap-2 h-14 px-3 sm:px-4 border-b border-[var(--border)] bg-[var(--bg-elev)]/95 backdrop-blur supports-[backdrop-filter]:bg-[var(--bg-elev)]/80" },
        dom.div({ class = "flex items-center gap-2 sm:gap-3 min-w-0 flex-1" },
          dom.button({
            type = "button",
            class = "btn btn-ghost btn-icon shrink-0", ["aria-label"] = open and "Menüyü daralt" or "Menüyü genişlet",
            title = "Menüyü daralt/genişlet (Ctrl+B)",
            ["aria-controls"] = "sidebar", ["aria-expanded"] = tostring(open),
            onclick = function() dispatch({ type = "SIDEBAR_TOGGLED" }) end,
          }, icons.get(open and "panel-left" or "menu", "w-5 h-5")),
          dom.a({ href = "#/", class = "text-base sm:text-lg font-semibold truncate flex items-center gap-2 hover:opacity-80 transition-opacity", title = "Panoya git", ["aria-label"] = "Panoya git" },
            dom.span({ class = "hidden sm:inline" }, "pgLua"),
            dom.span({ class = "sm:hidden flex items-center gap-1.5" }, icons.get("database", "w-4 h-4 text-[var(--primary)]"), "pgLua"))),
        dom.div({ class = "flex items-center gap-1 sm:gap-2 md:gap-3 shrink-0" },
          -- F29: görünür yardım butonu (kısayollar + gizli özellikler); ? tuşu ile aynı modal
          dom.button({
            type = "button", class = "btn btn-ghost btn-icon btn-sm", ["aria-label"] = "Yardım",
            title = "Yardım ve kısayollar (?)",
            onclick = function() require("components.modal").help() end,
          }, icons.get("help", "w-4 h-4")),
          theme_toggle.render_compact(state, dispatch),
          dom.a({ href = "#/profile", class = "hidden sm:inline-flex items-center gap-1.5 text-sm text-[var(--fg-muted)] hover:text-[var(--fg)] hover:underline truncate max-w-[12rem] py-1 px-2 rounded hover:bg-[var(--bg)] transition-colors",
            ["aria-current"] = state.route.name == "profile" and "page" or nil },
            icons.get("users", "w-4 h-4 opacity-60"), dom.span({ class = "truncate" }, user.email or "Profil")),
          dom.a({ href = "#/profile", class = "sm:hidden btn btn-ghost btn-icon btn-sm", ["aria-label"] = "Profil",
            title = user.email or "Profil" }, icons.get("users", "w-4 h-4")),
          icons.button({ icon = "logout", label = "Çıkış", variant = "secondary",
            title = "Çıkış yap", class = "hidden sm:inline-flex", onclick = function() app.logout() end }),
          dom.button({
            type = "button", class = "btn btn-secondary btn-icon sm:hidden", title = "Çıkış",
            ["aria-label"] = "Çıkış yap", onclick = function() app.logout() end,
          }, icons.get("logout", "w-4 h-4")))),
      dom.main({ id = "main", tabindex = "-1", class = "flex-1 p-3 sm:p-4 md:p-6 min-w-0 w-full max-w-[1600px] mx-auto",
        ["aria-label"] = title }, content)))
end

function layout.boot_skeleton()
  return dom.div({ class = "min-h-screen flex items-center justify-center", ["aria-busy"] = "true" },
    dom.span({ class = "sr-only" }, "Yükleniyor…"),
    dom.div({ class = "skeleton w-64 h-8", ["aria-hidden"] = "true" }))
end

function layout.page_skeleton()
  return require("components.skeleton").lines(6)
end

function layout.forbidden_page()
  return dom.section({ class = "p-8 max-w-md mx-auto text-center" },
    dom.div({ class = "flex justify-center mb-3 text-[var(--danger)]" }, icons.get("shield", "w-10 h-10 opacity-80")),
    dom.h1({ class = "text-2xl font-bold mb-2", tabindex = "-1" }, "Bu sayfaya erişim yetkiniz yok"),
    dom.p({ class = "text-[var(--fg-muted)] mb-4" }, "Bu alan için gerekli izin verilmedi. Yöneticinizle görüşün."),
    dom.a({ href = "#/", class = "inline-flex items-center gap-1.5 text-[var(--primary)] underline" },
      icons.get("arrow-left", "w-4 h-4"), "Panoya dön"))
end

function layout.empty_state(opts)
  local action_icon = opts.action_icon or "plus"
  return dom.div({ class = "text-center py-10 sm:py-16 px-4" },
    opts.icon_svg and dom.div({ class = "flex justify-center mb-3 text-[var(--fg-muted)]" }, icons.get(opts.icon_svg, "w-10 h-10 opacity-60"))
      or dom.div({ class = "text-4xl mb-3", ["aria-hidden"] = "true" }, opts.icon or "∅"),
    dom.h2({ class = "text-base sm:text-lg font-semibold mb-1" }, opts.title or "Kayıt yok"),
    dom.p({ class = "text-sm text-[var(--fg-muted)] mb-4 max-w-md mx-auto" }, opts.text or ""),
    opts.action_label and icons.button({
      icon = action_icon, label = opts.action_label, variant = "accent",
      onclick = opts.on_action,
    }))
end

function layout.pagination(meta, on_page)
  meta = meta or {}
  local page, pages = tonumber(meta.page) or 1, tonumber(meta.total_pages) or 1
  if pages <= 1 then return nil end
  return dom.nav({ ["aria-label"] = "Sayfalama", class = "flex flex-col sm:flex-row items-center justify-center gap-3 sm:gap-4 mt-4 flex-wrap" },
    dom.div({ class = "flex items-center gap-2" },
      icons.button({ icon = "chevron-left", label = "Önceki", variant = "secondary",
        disabled = page <= 1 and true or nil, title = "Önceki sayfa",
        onclick = function() on_page(math.max(page - 1, 1)) end }),
      dom.span({ class = "text-sm text-[var(--fg-muted)] px-3 py-1 rounded-full bg-[var(--bg-elev)] border border-[var(--border)]", ["aria-current"] = "page", role = "status" },
        "Sayfa " .. page .. " / " .. pages),
      icons.button({ icon = "chevron-right", label = "Sonraki", variant = "secondary",
        disabled = page >= pages and true or nil, title = "Sonraki sayfa",
        onclick = function() on_page(page + 1) end })))
end

function layout.sort_th(label, field, sort, on_sort, class)
  local dir = "none"
  if sort == field then dir = "ascending" elseif sort == "-" .. field then dir = "descending" end
  local next_sort = dir == "ascending" and ("-" .. field) or field
  local sort_icon = dir == "ascending" and "chevron-up" or (dir == "descending" and "chevron-down" or "chevron-down")
  return dom.th({ scope = "col", class = class or "py-2 pr-3", ["aria-sort"] = dir },
    dom.button({
      type = "button", class = "inline-flex items-center gap-1.5 font-medium hover:text-[var(--primary)] transition-colors",
      onclick = function() on_sort(next_sort) end,
      title = dir == "none" and "Sırala" or (dir == "ascending" and "Azalan sırala" or "Sıralamayı kaldır"),
    }, label, icons.get(sort_icon, "w-3.5 h-3.5 opacity-60")))
end

return layout
