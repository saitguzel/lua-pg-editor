-- F21: Komut paleti — Ctrl+K ile acilir modal: bağlantı degistir, tablo ara.
-- connections.items ve mevcut objects (eger varsa) üzerinde filtreler.
-- js.dom.focusFirst("[data-command]") ile odak yönetimi.

local dom = require("dom")
local app = require("app")
local router = require("router")

local palette = {}

local open = false
local query = ""
local selected = 1

local function filtered_connections(q)
  local st = app.get_state()
  local items = st.connections.items or {}
  if not q or q == "" then return items end
  local lq = q:lower()
  local out = {}
  for _, c in ipairs(items) do
    local hay = (c.name or "") .. " " .. (c.host or "") .. " " .. (c.database or "")
    if hay:lower():find(lq, 1, true) then out[#out + 1] = c end
  end
  return out
end

local function filtered_tables(q)
  -- sorgu/nesne kenar çubuğunun yüklediği katalog (state.query.completion) düz listeye çevrilir
  local st = app.get_state()
  local objs = {}
  local catalog = st.query and st.query.completion
  for _, sch in ipairs(catalog and catalog.schemas or {}) do
    for _, t in ipairs(sch.tables or {}) do objs[#objs + 1] = { schema = sch.name, name = t.name } end
  end
  if not q or q == "" then
    -- ilk 20'yi göster
    local out = {}
    for i = 1, math.min(20, #objs) do out[i] = objs[i] end
    return out
  end
  local lq = q:lower()
  local out = {}
  for _, o in ipairs(objs) do
    local name = o.name or o.table_name or ""
    local schema = o.schema or ""
    local hay = schema .. "." .. name
    if hay:lower():find(lq, 1, true) or name:lower():find(lq, 1, true) then
      out[#out + 1] = o
      if #out >= 20 then break end
    end
  end
  return out
end

-- F29: komutlar — mevcut kısayol eylemlerini çağırır; route verilenler önce sorgu sayfasına gider
local function qe() return require("views.query_editor") end
local COMMANDS = {
  { label = "Yeni sekme", hint = "Alt+N", route = "query", run = function() qe().new_tab() end },
  { label = "Seçimi çalıştır", hint = "Ctrl+Shift+Enter", route = "query", run = function() qe().run_selection() end },
  { label = "Formatla", hint = "Ctrl+Shift+F", route = "query", run = function() qe().format_sql() end },
  { label = "Dışa aktar", route = "query", run = function() qe().export_active() end },
  { label = "Tema: açık / koyu / sistem", run = function()
    local order = { light = "dark", dark = "system", system = "light" }
    app.dispatch({ type = "THEME_SET", theme = order[app.get_state().ui.theme] or "system" })
  end },
  { label = "Yardım ve kısayollar", hint = "?", run = function() require("components.modal").help() end },
  { label = "Nesne gezginini yenile", hint = "F5", run = function() require("views.schema_sidebar").reload() end },
  { label = "Kenar çubuğunu daralt/genişlet", hint = "Ctrl+B",
    run = function() app.dispatch({ type = "SIDEBAR_TOGGLED" }) end },
}
palette.COMMANDS = COMMANDS

local function filtered_commands(q)
  if not q or q == "" then return COMMANDS end
  local lq, out = q:lower(), {}
  for _, c in ipairs(COMMANDS) do
    if c.label:lower():find(lq, 1, true) then out[#out + 1] = c end
  end
  return out
end

local function run_command(cmd)
  palette.close()
  if cmd.route and app.get_state().route.name ~= cmd.route then
    router.navigate("#/" .. cmd.route)
    js.timer.after(100, function() pcall(cmd.run) end) -- sayfa render edilsin
    return
  end
  local ok, err = pcall(cmd.run)
  if not ok then js.log("error", "palet komutu: " .. tostring(err)) end
end

function palette.open()
  if open then return end
  open = true
  query = ""
  selected = 1
  -- bağlantı/tablo listesini tazelemek icin api cagrisi yapılabilir ama hizli olmasi icin mevcut state kullanilir
  app.dispatch({ type = "COMMAND_PALETTE_OPENED" })
  app.schedule_render()
  js.timer.after(30, function() js.dom.focusFirst("[data-command]") end)
end

function palette.close()
  if not open then return end
  open = false
  app.dispatch({ type = "COMMAND_PALETTE_CLOSED" })
  app.schedule_render()
end

function palette.is_open() return open end

local function navigate_connection(conn)
  palette.close()
  -- query sayfasina bağlantı secili git veya connections detay? basit: query'ye bağlantı parametresiyle
  if conn and conn.id then
    router.navigate("#/query?connection_id=" .. router.urlencode(conn.id))
  end
end

local function navigate_table(obj)
  palette.close()
  local st = app.get_state()
  local cur = router.current()
  local q = cur and cur.query or {}
  local tab = st.query and st.query.tabs[st.query.active_tab]
  local conn_id = q.connection_id or (tab and tab.connection_id)
    or (st.connections.items[1] and st.connections.items[1].id) or ""
  local schema = obj.schema or "public"
  local name = obj.name or obj.table_name or ""
  if name ~= "" then
    local hash = "#/browse/" .. router.urlencode(schema) .. "/" .. router.urlencode(name)
      .. (conn_id ~= "" and ("?connection_id=" .. router.urlencode(conn_id)) or "")
    router.navigate(hash)
  end
end

function palette.render(state)
  -- palette kendi kokunu #palette-root üzerinde yonetir
  palette._root = palette._root or { h = nil, tree = nil }
  if not palette._root.h then
    local h = js.dom.byId("palette-root")
    if not h then return nil end
    palette._root.h = h
  end
  local dialog_vnode = nil
  if open then
    local conns = filtered_connections(query)
    local tables = filtered_tables(query)
    local commands = filtered_commands(query)
    local total = #conns + #tables + #commands

    local items = {}

    -- bağlantılar bolumu
    items[#items + 1] = dom.div({ class = "text-xs font-semibold text-[var(--fg-muted)] px-2 py-1" }, "Bağlantılar (" .. #conns .. ")")
    if #conns == 0 then
      items[#items + 1] = dom.div({ class = "px-3 py-2 text-sm text-[var(--fg-muted)]" }, "Eslesen bağlantı yok")
    else
      for i, c in ipairs(conns) do
        local idx = i
        local is_sel = selected == idx
        items[#items + 1] = dom.button({
          type = "button",
          ["data-command"] = is_sel and "1" or nil,
          class = (is_sel and "bg-[var(--primary)] text-[var(--primary-fg)] " or "hover:bg-[var(--bg)] ")
            .. "w-full text-left px-3 py-2 text-sm rounded flex items-center justify-between",
          onclick = function() navigate_connection(c) end,
        }, dom.span({}, (c.name or c.host or "Bağlantı") .. " — " .. (c.host or "") .. ":" .. tostring(c.port or "")),
           dom.span({ class = "text-xs opacity-60" }, c.database or ""))
      end
    end

    items[#items + 1] = dom.div({ class = "text-xs font-semibold text-[var(--fg-muted)] px-2 py-1 mt-2" }, "Tablolar (" .. #tables .. ")")
    if #tables == 0 then
      items[#items + 1] = dom.div({ class = "px-3 py-2 text-sm text-[var(--fg-muted)]" }, "Eslesen tablo yok (once şema yukleyin)")
    else
      for _, o in ipairs(tables) do
        local name = o.name or o.table_name or ""
        local schema = o.schema or "public"
        items[#items + 1] = dom.button({
          type = "button",
          class = "w-full text-left px-3 py-2 text-sm rounded hover:bg-[var(--bg)]",
          onclick = function() navigate_table(o) end,
        }, schema .. "." .. name)
      end
    end

    items[#items + 1] = dom.div({ class = "text-xs font-semibold text-[var(--fg-muted)] px-2 py-1 mt-2" },
      "Komutlar (" .. #commands .. ")")
    for i, c in ipairs(commands) do
      local is_sel = selected == #conns + #tables + i
      items[#items + 1] = dom.button({
        type = "button", ["data-command"] = is_sel and "1" or nil,
        class = (is_sel and "bg-[var(--primary)] text-[var(--primary-fg)] " or "hover:bg-[var(--bg)] ")
          .. "w-full text-left px-3 py-2 text-sm rounded flex items-center justify-between",
        onclick = function() run_command(c) end,
      }, dom.span({}, c.label), c.hint and dom.kbd({ class = "text-xs opacity-60" }, c.hint) or nil)
    end

    local content = dom.div({ class = "space-y-2 w-full sm:min-w-[28rem]" },
      dom.input({
        type = "search",
        placeholder = "Bağlantı, tablo veya komut ara…",
        value = query,
        ["data-command"] = "1",
        class = "w-full px-3 py-2 border border-[var(--border)] rounded-[var(--radius)] bg-[var(--bg)] text-sm focus:outline-none focus-visible:ring-2 focus-visible:ring-[var(--focus)]",
        autofocus = "autofocus",
        oninput = function(e)
          query = e.value or ""
          selected = 1
          app.schedule_render()
        end,
        onkeydown = function(e)
          if e.key == "ArrowDown" then
            selected = math.min(selected + 1, total)
            app.schedule_render()
            return true
          elseif e.key == "ArrowUp" then
            selected = math.max(selected - 1, 1)
            app.schedule_render()
            return true
          elseif e.key == "Enter" then
            if conns[selected] then navigate_connection(conns[selected])
            elseif tables[selected - #conns] then navigate_table(tables[selected - #conns])
            elseif commands[selected - #conns - #tables] then run_command(commands[selected - #conns - #tables])
            end
            return true
          elseif e.key == "Escape" then palette.close(); return true end
        end,
      }),
      dom.div({ class = "max-h-64 overflow-auto border border-[var(--border)] rounded p-1 space-y-0.5" }, dom.list(items)),
      dom.div({ class = "text-xs text-[var(--fg-muted)] px-1" }, "↑↓ gezin, Enter seç, Esc kapat · Ctrl+K ile açılır"))

    dialog_vnode = require("components.modal").dialog("command-palette", "Komut paleti", content, palette.close, { class = "modal bg-[var(--bg-elev)] text-[var(--fg)] border border-[var(--border)] rounded-[var(--radius)] p-4 w-full max-w-xl" })
  end

  if dialog_vnode then
    palette._root.tree = dom.patch(palette._root.h, palette._root.tree, dom.div({}, dialog_vnode))
  else
    if palette._root.tree then
      palette._root.tree = dom.patch(palette._root.h, palette._root.tree, dom.div({}))
    end
  end
  return dialog_vnode
end

return palette
