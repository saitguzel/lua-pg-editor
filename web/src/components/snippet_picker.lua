-- Taslak paleti (Ctrl+J) + yönetimi: hazır taslaklar ve kullanıcı taslakları (GET/POST/PUT/DELETE /snippets).
-- Liste: ara (ad/önek/kategori), ↑/↓ ile seç, Enter ekler. Kullanıcı taslakları düzenlenir/silinir; hazır olanlar
-- "Kopyala" ile düzenlenebilir kopyaya dönüşür. Önekli taslaklar editörde önek + Tab ile de açılır.
local dom = require("dom")
local app = require("app")
local api = require("fetch")
local icons = require("icons")
local builtin = require("snippets_builtin")
local protocol = require("pg_shared.protocol")

local _M = {}

local ID = "snippet-dialog"
local mine = nil -- nil: yüklenmedi; { ... } kullanıcı taslakları
local search, selected = "", 1
local form = nil -- düzenleme formu: { id?, name, prefix, description, body, error }
local on_insert = nil -- fn(body)

local INPUT = "w-full px-3 py-2 border border-[var(--border)] rounded-[var(--radius)] bg-[var(--bg)] text-sm"

-- JSON null / nil → ""
local function str(v) return type(v) == "string" and v or "" end

-- editör tamamlaması için: kullanıcı + hazır taslaklar (kullanıcınınki aynı öneki ezer)
function _M.all()
  local out, seen = {}, {}
  for _, s in ipairs(mine or {}) do
    local prefix = str(s.prefix)
    out[#out + 1] = { name = s.name, prefix = prefix ~= "" and prefix or nil, body = s.body }
    if prefix ~= "" then seen[prefix] = true end
  end
  for _, s in ipairs(builtin.items) do
    if not seen[s.prefix] then out[#out + 1] = { name = s.name, prefix = s.prefix, body = s.body } end
  end
  return out
end

local function notify_changed()
  pcall(function() require("views.query_editor").apply_snippets() end)
end

function _M.load(force)
  if mine and not force then return mine end
  local data, err = api.get("/snippets")
  if err then app.toast("error", protocol.message(err.code)); return mine end
  mine = type(data) == "table" and data or {}
  notify_changed()
  app.schedule_render()
  return mine
end

local function filtered()
  local needle = search:lower()
  local out = {}
  local function add(item, own)
    local hay = (str(item.name) .. " " .. str(item.prefix) .. " " .. str(item.category) .. " "
      .. str(item.description)):lower()
    if needle == "" or hay:find(needle, 1, true) then out[#out + 1] = { item = item, own = own } end
  end
  for _, s in ipairs(mine or {}) do add(s, true) end
  for _, s in ipairs(builtin.items) do add(s, false) end
  return out
end

local function insert(item)
  local fn = on_insert
  require("components.modal").close(ID)
  if fn then fn(item.body) end
end

local function save_form()
  local f = form
  f.name = dom.value("snippet-name") or ""
  f.prefix = dom.value("snippet-prefix") or ""
  f.description = dom.value("snippet-desc") or ""
  f.body = dom.value("snippet-body") or ""
  local function invalid(msg) f.error = msg; app.schedule_render() end
  if f.name:match("^%s*$") then return invalid("Ad zorunlu") end
  if f.body:match("^%s*$") then return invalid("Gövde boş olamaz") end
  if not f.prefix:match("^[%w_]*$") then return invalid("Önek yalnızca harf, rakam ve _ içerebilir") end
  app.spawn(function()
    local payload = { name = f.name, prefix = f.prefix ~= "" and f.prefix or nil,
      description = f.description ~= "" and f.description or nil, body = f.body }
    local _, err
    if f.id then _, err = api.put("/snippets/" .. f.id, payload) else _, err = api.post("/snippets", payload) end
    if err then
      return invalid(err.code == "CONFLICT" and "Bu önek başka bir taslakta kullanılıyor"
        or (err.message or protocol.message(err.code)))
    end
    app.toast("success", "Taslak kaydedildi")
    form = nil
    _M.load(true)
  end)
end

local function remove(item)
  app.spawn(function()
    if not require("components.modal").confirm({ title = "Taslak silinsin mi?", danger = true, confirm_label = "Sil",
      message = item.name .. " taslağı silinecek." }) then return end
    local _, err = api.delete("/snippets/" .. item.id)
    if err then app.toast("error", protocol.message(err.code)); return end
    app.toast("success", "Taslak silindi")
    _M.load(true)
  end)
end

local function render_form()
  local f = form
  return dom.form({ class = "space-y-3", onsubmit = function() save_form() end },
    dom.div({ class = "grid grid-cols-1 sm:grid-cols-[1fr_10rem] gap-3" },
      dom.label({ class = "block text-sm space-y-1" }, "Ad",
        dom.input({ id = "snippet-name", class = INPUT, value = str(f.name), maxlength = "100",
          autofocus = "autofocus" })),
      dom.label({ class = "block text-sm space-y-1" }, "Önek (Tab ile açılır)",
        dom.input({ id = "snippet-prefix", class = INPUT .. " font-mono", value = str(f.prefix), maxlength = "32",
          placeholder = "ör. sel" }))),
    dom.label({ class = "block text-sm space-y-1" }, "Açıklama",
      dom.input({ id = "snippet-desc", class = INPUT, value = str(f.description), maxlength = "500" })),
    -- ponytail: düz textarea; sözdizimi renklendirmeli ikinci editör gerekirse CodeMirror örneği açılır
    dom.label({ class = "block text-sm space-y-1" }, "SQL (yer tutucu: ${ad})",
      dom.textarea({ id = "snippet-body", class = INPUT .. " font-mono min-h-48", value = str(f.body),
        spellcheck = "false" })),
    f.error and dom.p({ class = "field-error", role = "alert" }, f.error) or nil,
    dom.div({ class = "flex justify-end gap-2" },
      dom.button({ type = "button", class = "btn btn-secondary",
        onclick = function() form = nil; app.schedule_render() end }, "Vazgeç"),
      dom.button({ type = "submit", class = "btn btn-accent" }, icons.get("save"), dom.span({}, "Kaydet"))))
end

local function render_list()
  local items = filtered()
  selected = math.max(1, math.min(selected, #items))
  local rows = {}
  for i, e in ipairs(items) do
    local it, own = e.item, e.own
    local active = i == selected
    local function action_btn(action, icon, label, fn)
      -- data-action: satır tıklaması (ekle) bu butonlardan gelen tıklamayı yok sayar
      return dom.button({ type = "button", class = "btn btn-ghost btn-icon btn-sm", ["data-action"] = action,
        ["aria-label"] = it.name .. " " .. label, title = label, onclick = fn }, icons.get(icon))
    end
    rows[i] = dom.li({ key = (own and "u:" .. str(it.id)) or it.id, role = "option",
      ["aria-selected"] = active and "true" or "false", ["aria-label"] = it.name,
      class = "group flex items-center gap-2 px-2 py-1.5 rounded cursor-pointer "
        .. (active and "bg-[color-mix(in_srgb,var(--primary)_14%,transparent)]" or "hover:bg-[var(--bg)]"),
      onclick = function(ev) if not (ev and ev.action) then insert(it) end end },
      dom.span({ class = own and "text-[var(--primary)]" or "text-[var(--fg-muted)]", ["aria-hidden"] = "true" },
        icons.get(own and "file-code" or "code")),
      dom.div({ class = "flex-1 min-w-0" },
        dom.div({ class = "text-sm font-medium truncate" }, it.name),
        dom.div({ class = "text-xs text-[var(--fg-muted)] truncate font-mono" },
          str(it.description) ~= "" and it.description or (it.body:gsub("%s+", " "):sub(1, 90)))),
      str(it.prefix) ~= "" and dom.kbd({ class = "badge font-mono" }, it.prefix) or nil,
      dom.span({ class = "badge hidden sm:inline-flex" }, own and "Benim" or (it.category or "Hazır")),
      own and action_btn("edit", "edit", "düzenle", function()
        form = { id = it.id, name = it.name, prefix = it.prefix, description = it.description, body = it.body }
        app.schedule_render()
      end) or nil,
      own and action_btn("delete", "trash", "sil", function() remove(it) end) or nil,
      not own and action_btn("copy", "copy", "kopyala (düzenlenebilir)", function()
        form = { name = it.name .. " (kopya)", prefix = "", description = it.description, body = it.body }
        app.schedule_render()
      end) or nil)
  end
  return dom.div({ class = "space-y-3" },
    dom.div({ class = "flex gap-2" },
      dom.input({ id = "snippet-search", type = "search", class = INPUT, value = search, autofocus = "autofocus",
        placeholder = "Taslak ara (ad, önek, kategori)…", ["aria-label"] = "Taslak ara",
        ["aria-controls"] = "snippet-list", autocomplete = "off",
        oninput = function(e) search = e.value or ""; selected = 1; app.schedule_render() end,
        onkeydown = function(e)
          if e.key == "ArrowDown" then selected = selected + 1; app.schedule_render(); return true end
          if e.key == "ArrowUp" then selected = math.max(1, selected - 1); app.schedule_render(); return true end
          if e.key == "Enter" and items[selected] then insert(items[selected].item); return true end
        end }),
      dom.button({ type = "button", class = "btn btn-accent", onclick = function()
        form = { name = "", prefix = "", description = "", body = "" }; app.schedule_render()
      end }, icons.get("plus"), dom.span({}, "Yeni taslak"))),
    mine == nil and require("components.skeleton").lines(3) or nil,
    #items == 0 and mine ~= nil
      and dom.p({ class = "text-sm text-[var(--fg-muted)] p-2" }, "Eşleşen taslak yok") or nil,
    dom.ul({ id = "snippet-list", role = "listbox", ["aria-label"] = "Taslaklar",
      class = "max-h-[55vh] overflow-auto space-y-0.5" }, dom.list(rows)),
    dom.p({ class = "text-xs text-[var(--fg-muted)]" },
      "Enter: ekle · ↑/↓: seç · Editörde öneki yazıp Tab: taslağı aç, Tab ile alanlar arasında gezin"))
end

-- opts: { on_insert = fn(body), new_body = "…" (seçimi taslak olarak kaydet) }
function _M.open(opts)
  opts = opts or {}
  on_insert = opts.on_insert
  search, selected = "", 1
  form = opts.new_body and { name = "", prefix = "", description = "", body = opts.new_body } or nil
  require("components.modal").show({
    id = ID, title = "Taslaklar", wide = true,
    content = function() return form and render_form() or render_list() end,
  })
  app.spawn(_M.load, true)
end

return _M
