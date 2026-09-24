-- F16: Modal bileşeni. Native <dialog> + showModal(): focus trap, inert arka plan ve Esc tarayıcıdan gelir.
-- Esc (cancel olayı) varsayılanı engellenir, kapanış Lua state'i üzerinden olur; odak dialog DOM'dan
-- kalkınca tetikleyen öğeye döner (glue.js returnFocus). modal.confirm coroutine ile cevabı bekler.

local dom = require("dom")
local app = require("app")

local modal = {}

local open_modals = {} -- { id, title, render_fn, co }
local root = { h = nil, tree = nil }

local function changed() app.dispatch({ type = "MODAL_CHANGED" }) end

-- Açık bileşen dialog'unu kapatır; confirm ise bekleyen coroutine'i cevapla sürdürür
local function finish(id, answer)
  local m
  for i, x in ipairs(open_modals) do
    if x.id == id then m = table.remove(open_modals, i) break end
  end
  if not m then return end
  changed()
  if m.co then
    local ok, err = coroutine.resume(m.co, answer)
    if not ok then js.log("error", "modal coroutine hatası: " .. tostring(err)) end
  end
end

-- Genel dialog vnode'u: view'lar form modalları için doğrudan kullanır.
-- on_close: Esc veya kapat düğmesi. opts.class ile boyut/konum (ör. yan çekmece) değiştirilebilir.
function modal.dialog(id, title, content, on_close, opts)
  opts = opts or {}
  local icons_mod = require("icons")
  return dom.dialog({
    key = id,
    id = id,
    ["data-modal"] = "1",
    ["aria-labelledby"] = id .. "-title",
    ["aria-describedby"] = opts.describedby,
    class = opts.class or "modal bg-[var(--bg-elev)] text-[var(--fg)] border border-[var(--border)] " ..
      "rounded-[var(--radius)] p-6 w-full " .. (opts.wide and "max-w-3xl" or "max-w-lg"),
    oncancel = function() if on_close then on_close() end end,
  },
    dom.div({ class = "flex items-start justify-between gap-4 mb-4" },
      dom.h2({ id = id .. "-title", class = "text-lg font-semibold flex items-center gap-2" },
        icons_mod.get("info", "w-5 h-5 text-[var(--primary)] opacity-70"), title),
      on_close and dom.button({
        type = "button", class = "btn btn-ghost btn-icon btn-sm",
        ["aria-label"] = "Kapat", onclick = on_close,
      }, icons_mod.get("x", "w-4 h-4"))),
    content)
end

local BTN = "px-4 py-2 rounded-[var(--radius)] border border-[var(--border)]"
local BTN_PRIMARY = "px-4 py-2 rounded-[var(--radius)] bg-[var(--primary)] text-[var(--primary-fg)]"
local BTN_DANGER = "px-4 py-2 rounded-[var(--radius)] bg-[var(--danger)] text-white"

-- Coroutine bekleyen dialog açar; render(id, finish_with) içeriği üretir, dönüş finish'e verilen cevaptır
local function await_dialog(title, render, describedby)
  local co, is_main = coroutine.running()
  assert(not is_main, "modal.confirm/prompt bir coroutine içinde çağrılmalı (app.spawn kullanın)")
  local id = "dlg-" .. tostring(#open_modals + 1)
  open_modals[#open_modals + 1] = {
    id = id, title = title, co = co, describedby = describedby and (id .. "-desc"),
    render_fn = function() return render(id, function(answer) finish(id, answer) end) end,
  }
  changed()
  return coroutine.yield()
end

-- Coroutine confirm: İptal/Esc → false, onay → true.
-- opts.checkboxes = { {key, label, checked?}, ... } verilirse ikinci dönüş { key = bool } olur (ör. CASCADE)
function modal.confirm(opts)
  opts = opts or {}
  local boxes = opts.checkboxes or {}
  local answer = await_dialog(opts.title or "Onay", function(id, done)
    local checks = {}
    for i, b in ipairs(boxes) do
      checks[i] = dom.label({ class = "flex items-center gap-2 text-sm" },
        dom.input({ type = "checkbox", id = id .. "-cb-" .. b.key, checked = b.checked and "checked" or nil }),
        b.label)
    end
    return dom.div({ class = "space-y-4" },
      dom.p({ id = id .. "-desc", class = "text-sm" }, opts.message or ""),
      #checks > 0 and dom.div({ class = "space-y-2" }, dom.list(checks)) or nil,
      dom.div({ class = "flex justify-end gap-2" },
        dom.button({ type = "button", class = BTN,
          autofocus = "autofocus", -- yıkıcı işlemlerde güvenli varsayılan: İptal
          onclick = function() done(false) end }, opts.cancel_label or "İptal"),
        dom.button({ type = "button", class = opts.danger and BTN_DANGER or BTN_PRIMARY,
          onclick = function()
            local vals = {}
            for _, b in ipairs(boxes) do vals[b.key] = dom.checked(id .. "-cb-" .. b.key) == true end
            done(vals)
          end }, opts.confirm_label or "Tamam")))
  end, true)
  if not answer then return false end
  return true, type(answer) == "table" and answer or {}
end

-- Coroutine prompt: girilen metin (trim) ya da İptal/Esc → nil. opts.validate(v) → hata mesajı | nil
function modal.prompt(opts)
  opts = opts or {}
  local err_msg
  while true do
    local answer = await_dialog(opts.title or "Değer girin", function(id, done)
      local function submit() done(dom.value(id .. "-input") or "") end
      return dom.form({ class = "space-y-4", onsubmit = submit },
        dom.label({ ["for"] = id .. "-input", class = "block text-sm" }, opts.label or ""),
        dom.input({ id = id .. "-input", type = opts.type or "text", value = opts.value or "", autofocus = "autofocus",
          autocomplete = opts.type == "password" and "current-password" or "off",
          class = "w-full px-3 py-2 border border-[var(--border)] rounded-[var(--radius)] bg-[var(--bg)]",
          ["aria-invalid"] = err_msg and "true" or nil, ["aria-describedby"] = err_msg and (id .. "-err") or nil }),
        err_msg and dom.p({ id = id .. "-err", role = "alert", class = "text-sm text-[var(--danger)]" }, err_msg) or nil,
        dom.div({ class = "flex justify-end gap-2" },
          dom.button({ type = "button", class = BTN, onclick = function() done(false) end }, "İptal"),
          dom.button({ type = "submit", class = BTN_PRIMARY }, opts.confirm_label or "Tamam")))
    end)
    if type(answer) ~= "string" then return nil end
    answer = answer:match("^%s*(.-)%s*$")
    err_msg = opts.validate and opts.validate(answer) or nil
    if not err_msg then return answer end
    opts.value = answer
  end
end

-- Bilgi dialog'u (beklemez): content vnode ya da render fonksiyonu; opts.actions = { {label, icon?, onclick, class?}, ... }
function modal.show(opts)
  local id = opts.id or ("show-" .. tostring(#open_modals + 1))
  modal.close(id)
  local icons_mod = require("icons")
  open_modals[#open_modals + 1] = {
    id = id, title = opts.title or "", wide = opts.wide,
    render_fn = function()
      local btns = {}
      for i, a in ipairs(opts.actions or {}) do
        -- once eylem (dialog'daki input degerlerini okuyabilsin), sonra kapat; eylem false donerse acik kalir
        if a.icon then
          btns[i] = icons_mod.button({ icon = a.icon, label = a.label, variant = a.variant or "secondary",
            class = a.class, onclick = function()
              if a.onclick() ~= false and a.close ~= false then modal.close(id) end
            end })
        else
          btns[i] = dom.button({ type = "button", class = a.class or BTN, onclick = function()
            if a.onclick() ~= false and a.close ~= false then modal.close(id) end
          end }, a.label)
        end
      end
      btns[#btns + 1] = dom.button({ type = "button", class = BTN_PRIMARY .. " inline-flex items-center gap-1.5", autofocus = "autofocus",
        onclick = function() modal.close(id) end }, icons_mod.get("x", "w-4 h-4"), "Kapat")
      local body = type(opts.content) == "function" and opts.content() or opts.content
      return dom.div({ class = "space-y-4" }, body, dom.div({ class = "flex justify-end gap-2 flex-wrap" }, dom.list(btns)))
    end,
  }
  changed()
  return id
end

function modal.close(id) finish(id, false) end

-- "?" kısayolu: kayıtlı kısayolların listesi
function modal.help()
  for _, m in ipairs(open_modals) do
    if m.id == "shortcut-help" then return end
  end
  open_modals[#open_modals + 1] = {
    id = "shortcut-help",
    title = "Klavye kısayolları",
    wide = true,
    render_fn = function()
      -- F29: scope'a göre gruplu kısayollar + gizli özellikler
      local rows = {}
      local function kbd(k)
        return dom.td({ class = "py-1 pr-4 whitespace-nowrap" },
          dom.kbd({ class = "px-2 py-0.5 border border-[var(--border)] rounded text-sm" },
            k == "Escape" and "Esc" or k))
      end
      for _, g in ipairs(require("shortcuts").grouped()) do
        rows[#rows + 1] = dom.tr({}, dom.th({ scope = "colgroup", colspan = "2",
          class = "text-left pt-3 pb-1 font-semibold" }, g.label))
        for _, s in ipairs(g.items) do
          rows[#rows + 1] = dom.tr({}, kbd(s.key), dom.td({ class = "py-1 text-[var(--fg-muted)]" }, s.description))
        end
      end
      rows[#rows + 1] = dom.tr({}, kbd("Esc"), dom.td({ class = "py-1 text-[var(--fg-muted)]" }, "Pencereyi kapat"))
      local hidden = {}
      for _, t in ipairs(require("tips").for_where("help")) do
        hidden[#hidden + 1] = dom.li({ class = "py-0.5" }, t.text)
      end
      return dom.div({ class = "grid gap-4 md:grid-cols-2 text-sm max-h-[70vh] overflow-auto" },
        dom.table({ class = "text-sm self-start" },
          dom.caption({ class = "sr-only" }, "Kısayollar"),
          dom.tbody({}, rows)),
        dom.section({ ["aria-labelledby"] = "help-hidden" },
          dom.h3({ id = "help-hidden", class = "font-semibold pt-3 pb-1" }, "Gizli özellikler"),
          dom.ul({ class = "list-disc pl-5 text-[var(--fg-muted)]" }, dom.list(hidden)),
          dom.p({ class = "text-xs text-[var(--fg-muted)] mt-3" },
            "Tek tuş kısayollarını Profil sayfasından kapatabilirsiniz.")))
    end,
  }
  changed()
end

function modal.is_open() return #open_modals > 0 end

-- app.render_now her render'da çağırır: bileşen dialog'larını #modal-root'a patch eder
function modal.render(_state)
  if not root.h then
    root.h = js.dom.byId("modal-root")
    if not root.h then return end
  end
  local children = {}
  for _, m in ipairs(open_modals) do
    children[#children + 1] = modal.dialog(m.id, m.title, m.render_fn(),
      function() finish(m.id, false) end, { describedby = m.describedby, wide = m.wide })
  end
  root.tree = dom.patch(root.h, root.tree, dom.div({}, children))
end

return modal
