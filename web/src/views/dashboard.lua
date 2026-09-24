-- F21: Dashboard — pano, istatistik kartlari, skeleton, bos durum
local dom = require("dom")
local app = require("app")
local icons = require("icons")

local _M = { title = "Pano" }

function _M.render(state, dispatch)
  local types = require("pg_shared.types")
  local conns = state.connections
  local query = state.query
  -- loading state
  if conns.status == "loading" and #conns.items == 0 then
    return dom.div({ class = "space-y-4" },
      dom.h1({ class = "text-2xl font-bold", tabindex = "-1" }, "Gösterge Paneli"),
      require("components.skeleton").cards(4))
  end
  if conns.status == "error" then
    return dom.div({ class = "p-8 text-center", role = "alert" },
      dom.div({ class = "flex justify-center mb-3 text-[var(--danger)]" }, icons.get("alert-triangle", "w-8 h-8")),
      dom.h1({ class = "text-2xl font-bold mb-2", tabindex = "-1" }, "Pano yüklenemedi"),
      dom.p({ class = "text-[var(--fg-muted)] mb-4" }, tostring(conns.error and conns.error.message or "Hata")),
      icons.button({ icon = "refresh", label = "Tekrar dene", variant = "secondary",
        onclick = function() app.dispatch({ type = "CONNECTIONS_REQUESTED" }) end }))
  end
  local empty = #conns.items == 0
  return dom.div({ class = "space-y-4" },
    dom.h1({ class = "text-2xl font-bold", tabindex = "-1" }, "Gösterge Paneli"),
    dom.p({ class = "text-[var(--fg-muted)]" }, "pgLua — PostgreSQL Web Editor · PAGES=" .. #types.PAGES),
    empty and require("views.layout").empty_state({
      icon_svg = "plug", title = "Henüz bağlantı yok",
      text = "İlk PostgreSQL bağlantınızı ekleyin",
      action_label = app.can("connections.create") and "+ Bağlantı ekle" or nil, action_icon = "plus",
      on_action = function() require("router").navigate("#/connections") end
    }) or dom.div({ class = "grid grid-cols-2 lg:grid-cols-4 gap-3" },
      dom.div({ class = "p-4 border border-[var(--border)] rounded-[var(--radius)] bg-[var(--bg-elev)] flex items-start gap-3" },
        dom.div({ class = "p-2 rounded bg-[color-mix(in_srgb,var(--primary)_12%,transparent)] text-[var(--primary)]" }, icons.get("plug", "w-5 h-5")),
        dom.div({},
          dom.div({ class = "text-sm text-[var(--fg-muted)]" }, "Bağlantılar"),
          dom.div({ class = "text-2xl font-bold" }, tostring(#(conns.items or {}))))),
      dom.div({ class = "p-4 border border-[var(--border)] rounded-[var(--radius)] bg-[var(--bg-elev)] flex items-start gap-3" },
        dom.div({ class = "p-2 rounded bg-[color-mix(in_srgb,var(--primary)_12%,transparent)] text-[var(--primary)]" }, icons.get("terminal", "w-5 h-5")),
        dom.div({},
          dom.div({ class = "text-sm text-[var(--fg-muted)]" }, "Sorgu Sekmeleri"),
          dom.div({ class = "text-2xl font-bold" }, tostring(#(query.tabs or {}))))),
      dom.div({ class = "p-4 border border-[var(--border)] rounded-[var(--radius)] bg-[var(--bg-elev)] flex items-start gap-3" },
        dom.div({ class = "p-2 rounded bg-[color-mix(in_srgb,var(--success)_12%,transparent)] text-[var(--success)]" }, icons.get("table", "w-5 h-5")),
        dom.div({},
          dom.div({ class = "text-sm text-[var(--fg-muted)]" }, "Tablolar"),
          dom.div({ class = "text-2xl font-bold" }, tostring(#(state.objects.items or {}))))),
      dom.div({ class = "p-4 border border-[var(--border)] rounded-[var(--radius)] bg-[var(--bg-elev)] flex items-start gap-3" },
        dom.div({ class = "p-2 rounded bg-[color-mix(in_srgb,var(--warning)_12%,transparent)] text-[var(--warning)]" }, icons.get("users", "w-5 h-5")),
        dom.div({},
          dom.div({ class = "text-sm text-[var(--fg-muted)]" }, "Kullanıcılar"),
          dom.div({ class = "text-2xl font-bold" }, tostring(#(state.users.items or {})))))),
    dom.div({ class = "flex gap-2 mt-4" },
      dom.a({ href = "#/connections", class = "inline-flex items-center gap-1.5 px-4 py-2 rounded bg-[var(--primary)] text-[var(--primary-fg)] hover:opacity-90 transition-opacity" },
        icons.get("plug", "w-4 h-4"), "Bağlantılara git"),
      dom.a({ href = "#/query", class = "inline-flex items-center gap-1.5 px-4 py-2 rounded border border-[var(--border)] hover:bg-[var(--bg-elev)] transition-colors" },
        icons.get("terminal", "w-4 h-4"), "Sorgu çalıştır")))
end

function _M.enter(parsed, state)
  state = state or app.get_state()
  if state.connections.status == "idle" then
    app.spawn(function()
      local api = require("fetch")
      app.dispatch({ type = "CONNECTIONS_REQUESTED" })
      local data = api.get("/connections", { per_page = 5 })
      if data and data.items then app.dispatch({ type = "CONNECTIONS_LOADED", items = data.items }) end
      if data and data.error then app.dispatch({ type = "CONNECTIONS_FAILED", error = data.error }) end
    end)
  end
end

return _M
