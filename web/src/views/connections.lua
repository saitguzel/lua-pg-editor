-- F18: Bağlantı yönetimi — liste, arama, form (create/edit), test, sil.
-- URL filtreleri: ?search -> ILIKE; sayfalama meta ile.
-- Validasyon: pg_shared.validation.connection_create (frontend ayni kurallar).
local dom = require("dom")
local app = require("app")
local api = require("fetch")
local router = require("router")
local validation = require("pg_shared.validation")
local protocol = require("pg_shared.protocol")
local json = require("json")

local _M = {}
_M.title = "Bağlantılar"
_M.layout = true

local debounce_id = nil
local ssh_open = false
local ssh_auth = nil -- form acikken secili SSH kimlik yontemi (password | private_key)

local function field_class(invalid)
  return "w-full px-3 py-2 border rounded-[var(--radius)] bg-[var(--bg)] "
    .. (invalid and "border-[var(--danger)]" or "border-[var(--border)]")
end

local FIELD_IDS = { name = "conn-name", host = "conn-host", port = "conn-port",
  database = "conn-db", username = "conn-user", password = "conn-pass" }

local function focus_first_error(errs)
  for _, k in ipairs({ "name", "host", "port", "database", "username", "password" }) do
    if errs[k] then return dom.focus(FIELD_IDS[k]) end
  end
end

-- --- veri yukleme ----------------------------------------------------------------

local function load_connections(filters)
  app.dispatch({ type = "CONNECTIONS_REQUESTED", filters = filters })
  local q = {}
  for k, v in pairs(filters or {}) do
    if v ~= nil and v ~= "" then q[k] = v end
  end
  local data, err = api.get("/connections", q)
  if err then
    app.dispatch({ type = "CONNECTIONS_FAILED", error = err })
    app.toast("error", protocol.message(err.code))
    return
  end
  -- fetch handle_success: liste zarfi -> {items, meta}
  if data and data.items then
    app.dispatch({ type = "CONNECTIONS_LOADED", items = data.items, meta = data.meta })
  elseif type(data) == "table" and data[1] then
    app.dispatch({ type = "CONNECTIONS_LOADED", items = data })
  else
    app.dispatch({ type = "CONNECTIONS_LOADED", items = {} })
  end
end

function _M.filters_from_query(q)
  q = q or {}
  return {
    search = q.search or q.q or "",
    page = tonumber(q.page) or 1,
    per_page = 20,
  }
end

function _M.query_from_filters(f)
  local q = {}
  if f.search and f.search ~= "" then q.search = f.search end
  if f.page and f.page ~= 1 then q.page = tostring(f.page) end
  return q
end

local function same_filters(a, b)
  return tostring(a.search or "") == tostring(b.search or "") and tostring(a.page or 1) == tostring(b.page or 1)
end

function _M.enter(route)
  local st = app.get_state().connections
  local filters = _M.filters_from_query(route.query)
  if st.status == "idle" or st.status == "error" or not same_filters(filters, st.filters or {}) then
    load_connections(filters)
  end
end

function _M.mounted(dispatch)
  -- router enter disinda dogrudan cagri icin (eski sozlesme)
  local cur = router.current()
  if cur then _M.enter(cur) end
end

local function set_filters(patch)
  local cur = router.current()
  local base = _M.filters_from_query(cur and cur.query or {})
  local f = app._assign(base, patch)
  if patch.search ~= nil and patch.page == nil then f.page = 1 end
  router.navigate("#/connections" .. router.encode_query(_M.query_from_filters(f)))
end

local function reload()
  local cur = router.current()
  load_connections(_M.filters_from_query(cur and cur.query or {}))
end

-- --- islemler --------------------------------------------------------------------

local function test_connection(id)
  app.dispatch({ type = "CONNECTION_TESTING", id = id })
  local data, err = api.post("/connections/" .. router.urlencode(id) .. "/test", {})
  if err then
    app.dispatch({ type = "CONNECTION_TEST_FAILED", id = id })
    app.toast("error", err.code == "CONNECTION_FAILED" and ("Bağlantı başarısız: "
      .. tostring((err.details and err.details.db_message) or err.message))
      or protocol.message(err.code))
    return
  end
  app.dispatch({ type = "CONNECTION_TESTED", id = id })
  local latency = data and data.latency_ms or "?"
  app.toast("success", "Bağlantı başarılı (" .. tostring(latency) .. " ms)")
  -- listeyi tazele (last_test guncellendi)
  reload()
end

local function delete_connection(conn)
  app.spawn(function()
    local modal = require("components.modal")
    if not modal.confirm({ title = "Bağlantı silinsin mi?",
      message = "'" .. (conn.name or conn.host or "") .. "' kalici olarak silinecek.",
      confirm_label = "Sil", danger = true }) then
      return
    end
    local _, err = api.delete("/connections/" .. router.urlencode(conn.id))
    if err then
      app.toast("error", protocol.message(err.code))
      return
    end
    app.dispatch({ type = "CONNECTION_REMOVED", id = conn.id })
    app.toast("success", "Bağlantı silindi")
  end)
end

local function open_new()
  if app.can("connections.create") then
    ssh_open, ssh_auth = false, nil
    app.dispatch({ type = "CONNECTION_EDIT_OPENED", id = "new" })
  end
end

local function open_edit(conn)
  if app.can("connections.create") then
    ssh_open, ssh_auth = conn.ssh_enabled == true, nil
    app.dispatch({ type = "CONNECTION_EDIT_OPENED", id = conn.id, item = conn })
  end
end

local function close_editor()
  app.dispatch({ type = "CONNECTION_EDIT_CLOSED" })
  app.dispatch({ type = "FORM_ERRORS_SET", form = "connection", errors = false })
end

-- --- form ------------------------------------------------------------------------

local function conn_by_id(id)
  for _, c in ipairs(app.get_state().connections.items or {}) do if c.id == id then return c end end
end

-- codd "Trust SSH Host Key?": sunucunun parmak izlerini goster, onaylanirsa kaydet → true
function _M.trust_host_key(id)
  local data, err = api.get("/connections/" .. id .. "/ssh/host-key")
  if err then app.toast("error", err.message or protocol.message(err.code)); return false end
  local fps = data.fingerprints or {}
  local chosen = fps[1]
  for _, f in ipairs(fps) do if f.type == "ED25519" then chosen = f end end
  if not chosen then app.toast("error", "SSH sunucu anahtarı alınamadı"); return false end
  local lines = {}
  for _, f in ipairs(fps) do lines[#lines + 1] = f.type .. "  " .. f.fingerprint end
  local ok = require("components.modal").confirm({ title = "SSH sunucu anahtarına güvenilsin mi?",
    confirm_label = "Güven ve bağlan",
    message = data.host .. ":" .. tostring(data.port) .. " ilk kez bağlanılıyor. Parmak izlerini sunucu yöneticisinden "
      .. "doğrulayın:\n" .. table.concat(lines, "\n") })
  if not ok then return false end
  local conn, terr = api.post("/connections/" .. id .. "/ssh/host-key", { fingerprint = chosen.fingerprint })
  if terr then app.toast("error", terr.message or protocol.message(terr.code)); return false end
  app.dispatch({ type = "CONNECTION_UPDATED", connection = conn })
  return true
end

-- fetch.lua kurtarilabilir hata kancasi (coroutine icinde): parola sor / SSH anahtarini onayla
function _M.recover(err)
  local id = err.details and err.details.connection_id
  if not id then return false end
  if err.code == "SSH_HOST_KEY_UNKNOWN" then return _M.trust_host_key(id) end
  local c = conn_by_id(id)
  local pw = require("components.modal").prompt({ title = "Parola gerekli", type = "password",
    label = (c and (c.username .. "@" .. c.host .. " (" .. c.name .. ")") or "Bağlantı") .. " için parola",
    validate = function(v) if v == "" then return "Parola boş olamaz" end end })
  if not pw then return false end
  local _, uerr = api.post("/connections/" .. id .. "/unlock", { password = pw })
  if uerr then app.toast("error", uerr.message or protocol.message(uerr.code)); return false end
  return true
end

local function connection_form(state)
  local errors = (state.ui.form_errors or {}).connection or {}
  local editing = state.connections.editing
  local conn = nil
  if editing and editing ~= "new" then
    local idx = state.connections.by_id[editing]
    conn = (idx and state.connections.items[idx]) or state.connections.editing_item
  end
  local is_edit = conn ~= nil

  local function err_p(field, id)
    return errors[field] and dom.p({ id = id .. "-err", class = "field-error text-xs text-[var(--danger)] mt-1" },
      errors[field][1])
  end

  if ssh_auth == nil then ssh_auth = conn and conn.ssh_auth_method ~= json.null and conn.ssh_auth_method or "password" end

  return dom.form({
    class = "space-y-3",
    ["aria-label"] = is_edit and "Bağlantı düzenle" or "Yeni bağlantı",
    novalidate = "novalidate",
    onsubmit = function()
      app.spawn(function()
        local input = {
          name = dom.value("conn-name") or "",
          host = dom.value("conn-host") or "",
          port = dom.value("conn-port") or "",
          database = dom.value("conn-db") or "",
          username = dom.value("conn-user") or "",
          password = dom.value("conn-pass") or "",
          save_password = dom.checked("conn-save-pw"),
          ssh_enabled = dom.checked("conn-ssh-enabled"),
          ssh_host = dom.value("conn-ssh-host"),
          ssh_port = dom.value("conn-ssh-port"),
          ssh_username = dom.value("conn-ssh-user"),
          ssh_auth_method = dom.value("conn-ssh-auth"),
          ssh_secret = dom.value(ssh_auth == "private_key" and "conn-ssh-key" or "conn-ssh-pass"),
          ssh_passphrase = ssh_auth == "private_key" and dom.value("conn-ssh-passphrase") or nil,
          ssl_mode = dom.value("conn-ssl"),
        }
        -- sirlar: bos = degistirme (duzenleme) / yok (yeni)
        if input.ssh_secret == "" then input.ssh_secret = nil end
        if input.ssh_passphrase == "" then input.ssh_passphrase = nil end
        -- bos string -> nil (optional alanlar)
        if input.ssh_host == "" then input.ssh_host = nil end
        if input.ssh_port == "" then
          input.ssh_port = nil
        else
          input.ssh_port = tonumber(input.ssh_port)
        end
        if input.ssh_username == "" then input.ssh_username = nil end
        if input.ssh_auth_method == "" then input.ssh_auth_method = nil end
        -- port string -> number
        if input.port ~= "" then input.port = tonumber(input.port) end
        -- duzenlemede parola bos ise gonderme (degistirme)
        if is_edit and (input.password == "" or input.password == nil) then
          input.password = nil
        elseif input.password == "" then
          input.password = nil
        end
        -- ssh kapali ise ssh alanlarini temizle
        if not input.ssh_enabled then
          input.ssh_host = nil
          input.ssh_port = nil
          input.ssh_username = nil
          input.ssh_auth_method = nil
          input.ssh_secret = nil
          input.ssh_passphrase = nil
        end

        local schema = validation.schemas.connection_create
        local clean, errs
        if is_edit then
          -- edit: partial validasyon; name/host degismediyse mevcut degeri kullan
          local payload = {}
          for k, v in pairs(input) do payload[k] = v end
          -- eksik zorunlu alanlar icin conn degerini doldurup validate et
          if not payload.name or payload.name == "" then payload.name = conn.name end
          if not payload.host or payload.host == "" then payload.host = conn.host end
          if not payload.port then payload.port = conn.port end
          if not payload.database or payload.database == "" then payload.database = conn.database end
          if not payload.username or payload.username == "" then payload.username = conn.username end
          -- editte password optional kalir
          clean, errs = validation.validate(validation.schemas.connection_create, payload)
          if not clean then
            -- sadece degisen alanlari gondermeyi dene: partial
            local partial = {}
            for k, v in pairs(input) do
              if v ~= nil then partial[k] = v end
            end
            -- partial validasyon manuel: en az bir alan varsa schema strict disi
            clean, errs = validation.validate_partial(schema, partial)
            -- partial basarili ama zorunlu alanlar eksikse yine hata gosterecek; bu durumda full hatayi goster
            if not clean then errs = errs end
          end
        else
          clean, errs = validation.validate(schema, input)
        end
        if not clean then
          app.dispatch({ type = "FORM_ERRORS_SET", form = "connection", errors = errs })
          js.timer.after(0, function() focus_first_error(errs) end)
          return
        end
        -- temizle: editte nil olanlari gonderme
        if is_edit and clean.password == nil then clean.password = nil end
        local data, err
        if is_edit then
          data, err = api.put("/connections/" .. conn.id, clean)
        else
          data, err = api.post("/connections", clean)
        end
        if err then
          if err.code == "VALIDATION_FAILED" then
            app.dispatch({ type = "FORM_ERRORS_SET", form = "connection", errors = err.details or {} })
            js.timer.after(0, function() focus_first_error(err.details or {}) end)
          elseif err.code == "CONFLICT" then
            app.dispatch({ type = "FORM_ERRORS_SET", form = "connection",
              errors = { name = { "Bu isimde bağlantı zaten var" } } })
            dom.focus("conn-name")
          else
            app.toast("error", protocol.message(err.code))
          end
          return
        end
        if is_edit then
          app.dispatch({ type = "CONNECTION_UPDATED", connection = data })
          app.toast("success", "Bağlantı güncellendi")
        else
          app.dispatch({ type = "CONNECTION_CREATED", connection = data })
          app.toast("success", "Bağlantı oluşturuldu")
        end
        app.dispatch({ type = "FORM_ERRORS_SET", form = "connection", errors = false })
        close_editor()
        -- SSH acik ve sunucu anahtari onaylanmamis: codd gibi hemen parmak izi onayi
        if data and data.ssh_enabled and not data.ssh_host_trusted then _M.trust_host_key(data.id) end
      end)
      return false
    end,
  },
    dom.div({},
      dom.label({ ["for"] = "conn-name", class = "block text-sm font-medium mb-1" }, "Bağlantı adı"),
      dom.input({ id = "conn-name", type = "text", required = "required", maxlength = "100",
        autofocus = "autofocus",
        class = field_class(errors.name), value = conn and conn.name or nil,
        ["aria-invalid"] = errors.name and "true" or nil,
        ["aria-describedby"] = errors.name and "conn-name-err" or nil,
      }),
      err_p("name", "conn-name")),
    dom.div({ class = "grid grid-cols-3 gap-3" },
      dom.div({ class = "col-span-2" },
        dom.label({ ["for"] = "conn-host", class = "block text-sm font-medium mb-1" }, "Host"),
        dom.input({ id = "conn-host", type = "text", required = "required",
          placeholder = "localhost veya /var/run/postgresql",
          class = field_class(errors.host), value = conn and conn.host or nil,
          ["aria-invalid"] = errors.host and "true" or nil,
          ["aria-describedby"] = errors.host and "conn-host-err" or nil }),
        err_p("host", "conn-host")),
      dom.div({},
        dom.label({ ["for"] = "conn-port", class = "block text-sm font-medium mb-1" }, "Port"),
        dom.input({ id = "conn-port", type = "number", required = "required", min = "1", max = "65535",
          class = field_class(errors.port), value = conn and conn.port or 5432,
          ["aria-invalid"] = errors.port and "true" or nil,
          ["aria-describedby"] = errors.port and "conn-port-err" or nil }),
        err_p("port", "conn-port"))),
    dom.div({ class = "grid grid-cols-2 gap-3" },
      dom.div({},
        dom.label({ ["for"] = "conn-db", class = "block text-sm font-medium mb-1" }, "Veritabanı"),
        dom.input({ id = "conn-db", type = "text", required = "required",
          class = field_class(errors.database), value = conn and conn.database or nil,
          ["aria-invalid"] = errors.database and "true" or nil }),
        err_p("database", "conn-db")),
      dom.div({},
        dom.label({ ["for"] = "conn-user", class = "block text-sm font-medium mb-1" }, "Kullanıcı"),
        dom.input({ id = "conn-user", type = "text", required = "required",
          class = field_class(errors.username), value = conn and conn.username or nil,
          ["aria-invalid"] = errors.username and "true" or nil }),
        err_p("username", "conn-user"))),
    dom.div({},
      dom.label({ ["for"] = "conn-pass", class = "block text-sm font-medium mb-1" },
        is_edit and "Parola (boş = değiştirme)" or "Parola"),
      dom.input({ id = "conn-pass", type = "password", autocomplete = "new-password",
        class = field_class(errors.password), placeholder = is_edit and "***" or "",
        ["aria-invalid"] = errors.password and "true" or nil }),
      err_p("password", "conn-pass"),
      dom.div({ class = "flex items-center gap-2 mt-1" },
        dom.input({ id = "conn-save-pw", type = "checkbox",
          checked = (conn and conn.save_password) and "checked" or nil }),
        dom.label({ ["for"] = "conn-save-pw", class = "text-xs" }, "Parolayı kaydet (kapalıysa oturum boyunca sorulur)"))),
    dom.div({},
      dom.label({ ["for"] = "conn-ssl", class = "block text-sm font-medium mb-1" }, "SSL"),
      dom.select({ id = "conn-ssl", class = field_class(errors.ssl_mode) .. " bg-[var(--bg)]" },
        dom.option({ value = "prefer", selected = (not conn or conn.ssl_mode == "prefer") and "selected" or nil },
          "Tercih et (sunucu destekliyorsa)"),
        dom.option({ value = "require", selected = conn and conn.ssl_mode == "require" and "selected" or nil }, "Zorunlu"),
        dom.option({ value = "disable", selected = conn and conn.ssl_mode == "disable" and "selected" or nil }, "Kapalı"))),
    -- SSH accordion
    dom.details({ open = ssh_open and "open" or nil, class = "border border-[var(--border)] rounded-[var(--radius)]" },
      dom.summary({ class = "px-3 py-2 cursor-pointer text-sm font-medium select-none",
        onclick = function() ssh_open = not ssh_open end }, "SSH Tüneli (opsiyonel)"),
      dom.div({ class = "p-3 space-y-3 border-t border-[var(--border)]" },
        dom.div({ class = "flex items-center gap-2" },
          dom.input({ id = "conn-ssh-enabled", type = "checkbox",
            checked = ssh_open and "checked" or nil,
            onchange = function(e) ssh_open = e.checked == true; app.schedule_render() end }),
          dom.label({ ["for"] = "conn-ssh-enabled", class = "text-sm" }, "SSH aktif")),
        dom.div({ class = "grid grid-cols-2 gap-3" },
          dom.div({},
            dom.label({ ["for"] = "conn-ssh-host", class = "block text-xs mb-1" }, "SSH Host"),
            dom.input({ id = "conn-ssh-host", type = "text",
              class = field_class(errors.ssh_host),
              value = conn and conn.ssh_host ~= json.null and conn.ssh_host or nil })),
          dom.div({},
            dom.label({ ["for"] = "conn-ssh-port", class = "block text-xs mb-1" }, "SSH Port"),
            dom.input({ id = "conn-ssh-port", type = "number",
              class = "w-full px-3 py-2 border border-[var(--border)] rounded-[var(--radius)]",
              value = conn and conn.ssh_port ~= json.null and conn.ssh_port or nil }))),
        dom.div({},            dom.label({ ["for"] = "conn-ssh-user", class = "block text-xs mb-1" }, "SSH Kullanıcı"),
          dom.input({ id = "conn-ssh-user", type = "text",
            class = field_class(errors.ssh_username),
            value = conn and conn.ssh_username ~= json.null and conn.ssh_username or nil })),
        dom.div({},
          dom.label({ ["for"] = "conn-ssh-auth", class = "block text-xs mb-1" }, "Kimlik doğrulama"),
          dom.select({ id = "conn-ssh-auth",
            class = "w-full px-3 py-2 border border-[var(--border)] rounded-[var(--radius)] bg-[var(--bg)]",
            onchange = function(e) ssh_auth = e.value; app.schedule_render() end },
            dom.option({ value = "password", selected = ssh_auth == "password" and "selected" or nil }, "Parola"),
            dom.option({ value = "private_key", selected = ssh_auth == "private_key" and "selected" or nil }, "Özel anahtar"))),
        ssh_auth == "private_key" and dom.div({ class = "space-y-2" },
          dom.label({ ["for"] = "conn-ssh-key", class = "block text-xs" },
            "Özel anahtar (OpenSSH PEM)" .. (conn and conn.has_ssh_secret and " — boş = değiştirme" or "")),
          dom.textarea({ id = "conn-ssh-key", rows = "4", spellcheck = "false",
            class = "w-full px-3 py-2 border border-[var(--border)] rounded-[var(--radius)] font-mono text-xs",
            placeholder = "-----BEGIN OPENSSH PRIVATE KEY-----" }),
          dom.label({ ["for"] = "conn-ssh-passphrase", class = "block text-xs" }, "Anahtar parolası (varsa)"),
          dom.input({ id = "conn-ssh-passphrase", type = "password", autocomplete = "new-password",
            class = "w-full px-3 py-2 border border-[var(--border)] rounded-[var(--radius)]" }))
        or dom.div({},
          dom.label({ ["for"] = "conn-ssh-pass", class = "block text-xs mb-1" },
            "SSH parolası" .. (conn and conn.has_ssh_secret and " (boş = değiştirme)" or "")),
          dom.input({ id = "conn-ssh-pass", type = "password", autocomplete = "new-password",
            class = "w-full px-3 py-2 border border-[var(--border)] rounded-[var(--radius)]" })),
        conn and conn.ssh_enabled and dom.p({ class = "text-xs text-[var(--fg-muted)]" },
          conn.ssh_host_trusted and ("Sunucu anahtarı onaylı: " .. tostring(conn.ssh_host_key_fingerprint))
            or "Sunucu anahtarı henüz onaylanmadı") or nil)),
    dom.div({ class = "flex justify-end gap-2 pt-2" },
      dom.button({ type = "button",
        class = "px-4 py-2 rounded-[var(--radius)] border border-[var(--border)]",
        onclick = close_editor }, "İptal"),
      dom.button({ type = "submit",
        class = "px-4 py-2 rounded-[var(--radius)] bg-[var(--primary)] text-[var(--primary-fg)]" },
        is_edit and "Kaydet" or "Oluştur"))
  )
end

-- --- render --------------------------------------------------------------------

local function badge(text, variant)
  local cls = "inline-flex items-center px-2 py-0.5 rounded text-xs border "
  if variant == "success" then
    cls = cls .. "bg-[color-mix(in_srgb,var(--success)_12%,transparent)] border-[var(--success)] text-[var(--success)]"
  elseif variant == "muted" then
    cls = cls .. "bg-[var(--bg)] border-[var(--border)] text-[var(--fg-muted)]"
  else
    cls = cls .. "bg-[var(--bg-elev)] border-[var(--border)] text-[var(--fg-muted)]"
  end
  return dom.span({ class = cls }, text)
end

local function connection_card(conn, state)
  local testing = state.connections.testing == conn.id
  local has_pw = conn.has_password == true
  local last_ok = conn.last_test_success == true
  local last_lat = conn.last_test_latency_ms
  local last_at = conn.last_tested_at
  local can_edit = app.can("connections.create")
  return dom.div({
    key = conn.id,
    class = "p-4 border border-[var(--border)] rounded-[var(--radius)] bg-[var(--bg-elev)] space-y-2",
    ["data-id"] = conn.id,
  },
    dom.div({ class = "flex items-start justify-between gap-3" },
      dom.div({ class = "min-w-0 flex-1" },
        dom.h3({ class = "font-semibold truncate" }, conn.name or conn.host or "Bağlantı"),
        dom.p({ class = "text-sm text-[var(--fg-muted)] truncate" },
          (conn.username or "") .. "@" .. (conn.host or "") .. ":" .. tostring(conn.port or "")
          .. " – Varsayılan veritabanı: " .. (conn.database or ""))),
      dom.div({ class = "flex items-center gap-2 shrink-0" },
        has_pw and badge("parola", "muted") or badge(conn.save_password and "parola yok" or "parola sorulur", "muted"),
        conn.ssh_enabled and badge(conn.ssh_host_trusted and "SSH" or "SSH: onay bekliyor", "muted") or nil,
        conn.ssl_mode and conn.ssl_mode ~= "disable" and badge("SSL " .. conn.ssl_mode, "muted") or nil,
        last_at ~= nil and last_at ~= json.null and (
          last_ok and badge(tostring(last_lat or "?") .. " ms", "success") or badge("hatali", "muted")
        ) or nil)),
    dom.div({ class = "flex gap-2 flex-wrap" },
      can_edit and dom.button({
        type = "button",
        class = "px-3 py-1.5 text-sm rounded-[var(--radius)] border border-[var(--border)] hover:bg-[var(--bg)] min-h-9",
        onclick = function() open_edit(conn) end,
      }, "Düzenle") or nil,
      can_edit and dom.button({
        type = "button",
        class = "px-3 py-1.5 text-sm rounded-[var(--radius)] bg-[var(--primary)] text-[var(--primary-fg)] min-h-9 disabled:opacity-50",
        disabled = testing and "disabled" or nil,
        ["aria-busy"] = tostring(testing),
        onclick = function() app.spawn(test_connection, conn.id) end,
      }, testing and "Test ediliyor..." or "Test et") or nil,
      can_edit and dom.button({
        type = "button",
        class = "px-3 py-1.5 text-sm rounded-[var(--radius)] border border-[var(--danger)] text-[var(--danger)] hover:bg-[var(--bg)] min-h-9",
        onclick = function() delete_connection(conn) end,
      }, "Sil") or nil,
      can_edit and conn.ssh_enabled and not conn.ssh_host_trusted and dom.button({
        type = "button",
        class = "px-3 py-1.5 text-sm rounded-[var(--radius)] border border-[var(--warning)] hover:bg-[var(--bg)] min-h-9",
        onclick = function() app.spawn(_M.trust_host_key, conn.id) end,
      }, "SSH anahtarını onayla") or nil,
      dom.a({ href = "#/query?connection_id=" .. router.urlencode(conn.id),
        class = "px-3 py-1.5 text-sm rounded-[var(--radius)] border border-[var(--border)] hover:bg-[var(--bg)]" },
        "Sorgu")))
end

function _M.render(state, dispatch)
  local st = state.connections
  local meta = st.meta or {}
  local q = (router.current() and router.current().query) or {}
  local search_val = q.search or q.q or st.filters.search or ""

  local search_form = dom.form({
    role = "search", ["aria-label"] = "Bağlantı ara",
    class = "flex gap-2 mb-4",
    onsubmit = function() return false end,
  },
    dom.input({
      type = "search", id = "conn-search", placeholder = "Ara (isim/host/db)…",
      ["aria-label"] = "Bağlantı ara",
      class = "flex-1 px-3 py-2 min-h-11 border border-[var(--border)] rounded-[var(--radius)] bg-[var(--bg)] text-sm",
      value = search_val,
      oninput = function(e)
        if debounce_id then js.timer.cancel(debounce_id) end
        local v = e.value or ""
        -- sayfadan ayrildiysa gecikmeli arama URL'yi geri cekmesin
        debounce_id = js.timer.after(300, function()
          if app.get_state().route.name == "connections" then set_filters({ search = v }) end
        end)
      end,
    }),
    app.can("connections.create") and dom.button({
      type = "button",
      class = "px-4 py-2 min-h-11 rounded-[var(--radius)] bg-[var(--primary)] text-[var(--primary-fg)] whitespace-nowrap",
      onclick = open_new,
    }, "+ Yeni bağlantı") or nil)

  local body, error_body
  if st.status == "loading" and #st.items == 0 then
    body = require("components.skeleton").lines(6)
  elseif st.status == "error" then
    error_body = dom.div({ class = "p-8 text-center", role = "alert" },
      dom.p({ class = "text-[var(--danger)] mb-2" }, "Bağlantılar yüklenemedi: "
        .. tostring(st.error and st.error.message or st.error and st.error.code or "")),
      dom.button({ type = "button",
        class = "px-4 py-2 rounded-[var(--radius)] border border-[var(--border)]", onclick = reload }, "Tekrar dene"))
  elseif #st.items == 0 then
    local layout = require("views.layout")
    if search_val ~= "" then
      body = layout.empty_state({ icon = "🔍", title = "Sonuç yok",
        text = "Bu filtreyle eşleşen bağlantı yok",
        action_label = "Filtreyi temizle",
        on_action = function() set_filters({ search = "" }) end })
    else
      body = layout.empty_state({ icon = "⎆", title = "Henüz bağlantı yok",
        text = "İlk PostgreSQL bağlantınızı ekleyin",
        action_label = app.can("connections.create") and "+ Bağlantı ekle" or nil,
        on_action = open_new })
    end
  else
    local cards = {}
    for _, conn in ipairs(st.items) do
      cards[#cards + 1] = connection_card(conn, state)
    end
    body = dom.div({ class = "grid gap-3 md:grid-cols-2" }, dom.list(cards))
  end

  local modal = nil
  if st.editing then
    local is_new = st.editing == "new"
    modal = require("components.modal").dialog("conn-edit",
      is_new and "Yeni bağlantı" or "Bağlantı düzenle",
      connection_form(state), close_editor)
  end

  return dom.section({ ["aria-labelledby"] = "connections-title" },
    dom.header({ class = "flex items-center justify-between gap-2 mb-4" },
      dom.h1({ id = "connections-title", class = "text-2xl font-bold", tabindex = "-1" },
        "Bağlantılar" .. ((tonumber(meta.total) or 0) > 0 and (" (" .. meta.total .. ")") or ""))),
    error_body or search_form,
    not error_body and body or nil,
    require("views.layout").pagination(meta, function(p) set_filters({ page = p }) end),
    modal)
end

return _M
