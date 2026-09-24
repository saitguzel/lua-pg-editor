-- F19: Satir formlari (codd). 1) Ekle/Cogalt: kolon basina Deger / NULL / Varsayilan secimi; identity ve
-- generated kolonlar atlanir. 2) Hucre editoru: bool/enum icin secim, diger tipler cok satirli metin;
-- Kaydet / NULL yap (yalniz nullable) / Iptal. Degerler metin gonderilir, Postgres kolon tipine cevirir.
local dom = require("dom")
local json = require("json")
local icons = require("icons")

local row_form = {}

local INPUT = "w-full px-3 py-2 border rounded-[var(--radius)] bg-[var(--bg)] text-sm"

-- API degeri → duzenlenebilir metin
function row_form.to_text(v)
  if v == nil or v == json.null then return "" end
  if type(v) == "table" then return js.json.pretty(json.encode(v)) end
  if type(v) == "boolean" then return v and "true" or "false" end
  return tostring(v)
end

local function insertable(c) return not (c.is_identity or c.is_generated) and c.type_group ~= "binary" end

-- secim: bool → "true"/"false", enum → deger listesi, diger → textarea
local function value_input(col, id, text, invalid)
  local cls = INPUT .. (invalid and " border-[var(--danger)]" or " border-[var(--border)]")
  if col.type_group == "boolean" or (col.enum_values and #col.enum_values > 0) then
    local values = col.type_group == "boolean" and { "false", "true" } or col.enum_values
    local opts = {}
    for i, v in ipairs(values) do
      opts[i] = dom.option({ value = v, selected = v == text and "selected" or nil },
        col.type_group == "boolean" and v:upper() or v)
    end
    return dom.select({ id = id, class = cls, ["aria-invalid"] = invalid and "true" or nil }, dom.list(opts))
  end
  return dom.textarea({ id = id, rows = (col.type_group == "json" or #text > 60) and "4" or "1", class = cls .. " font-mono",
    ["aria-invalid"] = invalid and "true" or nil, value = text })
end

local function read_value(col, id)
  local v = dom.value(id) or ""
  if col.type_group == "boolean" then return v == "true" end
  return v
end

-- --- 1) Ekle / Cogalt formu ------------------------------------------------------
-- state: { modes = { kolon = "value"|"null"|"default" }, errors = { kolon = {msg} } } (cagiran tutar)
-- opts: { columns, values (on-dolum), state, on_submit(values), on_cancel }
function row_form.render(opts)
  local st = opts.state
  local fields = {}
  for _, col in ipairs(opts.columns or {}) do
    if insertable(col) then
      local name = col.name
      local prefill = opts.values and opts.values[name]
      if st.modes[name] == nil then
        -- varsayilan secim: on-dolum varsa deger; PK/varsayilanli kolonda varsayilan; nullable → NULL
        if col.is_primary_key and col.has_default then st.modes[name] = "default"
        elseif prefill ~= nil and prefill ~= json.null then st.modes[name] = "value"
        elseif prefill == json.null and col.is_nullable then st.modes[name] = "null"
        elseif col.has_default then st.modes[name] = "default"
        else st.modes[name] = col.is_nullable and "null" or "value" end
      end
      local mode = st.modes[name]
      local err = st.errors[name]
      local hints = {}
      if not col.is_nullable and not col.has_default then hints[#hints + 1] = "Zorunlu" end
      if col.has_default then hints[#hints + 1] = "Varsayılan kullanılabilir" end
      if col.is_nullable then hints[#hints + 1] = "NULL olabilir" end
      local mode_opts = { dom.option({ value = "value", selected = mode == "value" and "selected" or nil }, "Değer") }
      if col.is_nullable then
        mode_opts[#mode_opts + 1] = dom.option({ value = "null", selected = mode == "null" and "selected" or nil }, "NULL")
      end
      if col.has_default then
        mode_opts[#mode_opts + 1] = dom.option({ value = "default", selected = mode == "default" and "selected" or nil }, "Varsayılan")
      end
      fields[#fields + 1] = dom.div({ key = name, class = "space-y-1" },
        dom.div({ class = "flex items-center justify-between gap-2" },
          dom.label({ ["for"] = "val-" .. name, class = "text-xs font-medium" }, name,
            dom.span({ class = "text-[var(--fg-muted)] font-normal ml-1" }, "(" .. tostring(col.display_type) .. ")")),
          dom.select({ ["aria-label"] = name .. " giriş türü",
            class = "px-2 py-0.5 text-xs border border-[var(--border)] rounded bg-[var(--bg)]",
            onchange = function(e) st.modes[name] = e.value; require("app").schedule_render() end },
            dom.list(mode_opts))),
        mode == "value" and value_input(col, "val-" .. name, row_form.to_text(prefill), err ~= nil) or nil,
        dom.p({ class = "text-[11px] text-[var(--fg-muted)]" }, table.concat(hints, " · ")),
        err and dom.p({ role = "alert", class = "text-xs text-[var(--danger)]" }, tostring(err[1] or err)) or nil)
    end
  end
  return dom.form({ class = "space-y-3", novalidate = "novalidate",
    onsubmit = function()
      local out = {}
      for _, col in ipairs(opts.columns or {}) do
        local mode = st.modes[col.name]
        if insertable(col) then
          if mode == "value" then out[col.name] = read_value(col, "val-" .. col.name)
          elseif mode == "null" then out[col.name] = json.null end
        end
      end
      opts.on_submit(out)
      return false
    end },
    dom.div({ class = "space-y-3 max-h-[60vh] overflow-auto pr-1" }, dom.list(fields)),
    dom.div({ class = "flex justify-end gap-2 pt-2 border-t border-[var(--border)]" },
      icons.button({ icon = "x", label = "İptal", variant = "secondary", onclick = opts.on_cancel }),
      dom.button({ type = "submit", class = "btn btn-accent inline-flex items-center gap-1.5" },
        icons.get("check", "w-4 h-4"), "Kaydet")))
end

-- --- 2) Hucre editoru ------------------------------------------------------------
-- on_save(value | json.null) → false donerse dialog acik kalir (hata)
function row_form.edit_cell(col, value, on_save)
  local modal = require("components.modal")
  local id = "cell-edit-input"
  local actions = {}
  if col.is_nullable then
    actions[#actions + 1] = { label = "NULL yap", icon = "eraser", class = "btn btn-ghost", onclick = function() return on_save(json.null) end }
  end
  actions[#actions + 1] = { label = "Kaydet", icon = "check", class = "btn btn-accent", variant = "accent",
    onclick = function() return on_save(read_value(col, id)) end }
  modal.show({
    id = "cell-editor", wide = col.type_group == "json",
    title = col.name .. " (" .. tostring(col.display_type) .. ")",
    content = dom.div({ class = "space-y-2" },
      dom.label({ ["for"] = id, class = "sr-only" }, col.name .. " değeri"),
      value_input(col, id, row_form.to_text(value), false),
      value == json.null and dom.p({ class = "text-xs text-[var(--fg-muted)]" }, "Şu anki değer: NULL") or nil),
    actions = actions,
  })
  js.timer.after(0, function() dom.focus(id) end)
end

return row_form
