-- Bağlam menüsü: sağ tık veya "⋯" düğmesiyle açılır; #menu-root'a ayrı ağaç olarak çizilir.
-- Dışarı tıklama/Esc kapatır, ok tuşları öğeler arasında gezer (role=menu/menuitem).
-- items: { {label, onclick, danger?, disabled?}, {separator=true}, {group="Başlık"} }
local dom = require("dom")
local app = require("app")

local context_menu = {}

local current = nil -- { items, x, y }
local root = { h = nil, tree = nil }
local ITEM_SEL = "#menu-root [role=menuitem]:not([disabled])"
local MENU_W, ITEM_H = 224, 32

function context_menu.open(ev, items)
  if not items or #items == 0 then return end
  current = { items = items, x = ev and ev.x or 0, y = ev and ev.y or 0 }
  app.schedule_render()
  js.timer.after(0, function() js.dom.focusFirst(ITEM_SEL) end)
end

function context_menu.close()
  if not current then return end
  current = nil
  app.schedule_render()
end

function context_menu.is_open() return current ~= nil end

-- ekrandan taşmayacak konum
local function position(n)
  local vp = js.dom.viewport() or { 1280, 800 }
  local h = math.min(n * ITEM_H + 8, vp[2] * 0.7)
  local x = math.max(4, math.min(current.x, vp[1] - MENU_W - 4))
  local y = current.y
  if y + h > vp[2] - 4 then y = math.max(4, y - h) end
  return x, y
end

function context_menu.render()
  if not root.h then
    root.h = js.dom.byId("menu-root")
    if not root.h then return end
  end
  if not current then
    root.tree = dom.patch(root.h, root.tree, dom.div({}))
    return
  end
  local children = {}
  for i, it in ipairs(current.items) do
    if it.separator then
      children[i] = dom.div({ role = "separator", class = "my-1 border-t border-[var(--border)]" })
    elseif it.group then
      children[i] = dom.div({ class = "px-3 pt-2 pb-1 text-xs font-semibold text-[var(--fg-muted)]" }, it.group)
    else
      children[i] = dom.button({
        type = "button", role = "menuitem", disabled = it.disabled and "disabled" or nil,
        class = "w-full text-left px-3 py-1.5 text-sm rounded hover:bg-[var(--bg)] focus:bg-[var(--bg)] disabled:opacity-50 "
          .. (it.danger and "text-[var(--danger)]" or ""),
        onclick = function()
          context_menu.close()
          if it.onclick then it.onclick() end
        end,
      }, it.label)
    end
  end
  local x, y = position(#current.items)
  root.tree = dom.patch(root.h, root.tree, dom.div({},
    dom.div({ class = "fixed inset-0 z-40", ["aria-hidden"] = "true",
      onclick = context_menu.close, oncontextmenu = context_menu.close }),
    dom.div({
      role = "menu", class = "fixed z-50 w-56 max-h-[70vh] overflow-auto p-1 bg-[var(--bg-elev)] border border-[var(--border)] rounded-[var(--radius)] shadow-lg",
      style = "left:" .. math.floor(x) .. "px;top:" .. math.floor(y) .. "px",
      onkeydown = function(e)
        if e.key == "Escape" then context_menu.close(); return true end
        if e.key == "ArrowDown" then js.dom.focusMove(ITEM_SEL, 1); return true end
        if e.key == "ArrowUp" then js.dom.focusMove(ITEM_SEL, -1); return true end
        if e.key == "Tab" then context_menu.close() end
      end,
    }, dom.list(children))))
end

return context_menu
