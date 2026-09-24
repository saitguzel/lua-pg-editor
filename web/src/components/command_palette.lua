-- F21: Komut paleti — Ctrl+K ile acilir modal: baglanti degistir, tablo ara.
-- connections.items ve mevcut objects (eger varsa) uzerinde filtreler.
-- js.dom.focusFirst("[data-command]") ile odak yonetimi.

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
    -- ilk 20'yi goster
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

function palette.open()
  if open then return end
  open = true
  query = ""
  selected = 1
  -- baglanti/tablo listesini tazelemek icin api cagrisi yapilabilir ama hizli olmasi icin mevcut state kullanilir
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
  -- query sayfasina baglanti secili git veya connections detay? basit: query'ye baglanti parametresiyle
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
  -- palette kendi kokunu #palette-root uzerinde yonetir
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

    local items = {}

    -- baglantilar bolumu
    items[#items + 1] = dom.div({ class = "text-xs font-semibold text-[var(--fg-muted)] px-2 py-1" }, "Baglantilar (" .. #conns .. ")")
    if #conns == 0 then
      items[#items + 1] = dom.div({ class = "px-3 py-2 text-sm text-[var(--fg-muted)]" }, "Eslesen baglanti yok")
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
        }, dom.span({}, (c.name or c.host or "Baglanti") .. " — " .. (c.host or "") .. ":" .. tostring(c.port or "")),
           dom.span({ class = "text-xs opacity-60" }, c.database or ""))
      end
    end

    items[#items + 1] = dom.div({ class = "text-xs font-semibold text-[var(--fg-muted)] px-2 py-1 mt-2" }, "Tablolar (" .. #tables .. ")")
    if #tables == 0 then
      items[#items + 1] = dom.div({ class = "px-3 py-2 text-sm text-[var(--fg-muted)]" }, "Eslesen tablo yok (once sema yukleyin)")
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

    local content = dom.div({ class = "space-y-2 min-w-[28rem]" },
      dom.input({
        type = "search",
        placeholder = "Baglanti veya tablo ara…",
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
            selected = math.min(selected + 1, #conns + #tables)
            app.schedule_render()
            return true
          elseif e.key == "ArrowUp" then
            selected = math.max(selected - 1, 1)
            app.schedule_render()
            return true
          elseif e.key == "Enter" then
            if conns[selected] then navigate_connection(conns[selected])
            elseif tables[selected - #conns] then navigate_table(tables[selected - #conns])
            end
            return true
          elseif e.key == "Escape" then palette.close(); return true end
        end,
      }),
      dom.div({ class = "max-h-64 overflow-auto border border-[var(--border)] rounded p-1 space-y-0.5" }, dom.list(items)),
      dom.div({ class = "text-xs text-[var(--fg-muted)] px-1" }, "↑↓ gezin, Enter sec, Esc kapat · Ctrl+K ile acilir"))

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
