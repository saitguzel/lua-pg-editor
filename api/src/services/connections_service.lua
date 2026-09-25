-- Bağlantı servis: CRUD, sahiplik, crypto, pool_manager, audit
local connection_repo = require("repositories.connection_repo")
local connection_model = require("models.connection")
local errors = require("middleware.error_handler")
local query = require("db.query")
local crypto = require("security.crypto")
local pool_manager = require("db.pool_manager")
local cjson = require("cjson.safe")

local _M = {}

local function mask_for_audit(row)
  if not row then return nil end
  local copy = {}
  for k, v in pairs(row) do
    if k == "password_encrypted" or k == "password" or k:lower():find("password") or k:lower():find("secret") then
      copy[k] = "***"
    else
      copy[k] = v
    end
  end
  -- also mask old/new serialized
  return copy
end

function _M.list(identity, q)
  q = q or {}
  local page = tonumber(q.page) or 1
  local per_page = tonumber(q.per_page) or 20
  if page < 1 then page = 1 end
  if per_page < 1 then per_page = 20 end
  if per_page > 100 then per_page = 100 end
  local search = q.search or q.q
  local rows, total = connection_repo.find_by_user(identity.user_id, { page = page, per_page = per_page, search = search })
  if not rows then return nil, total end
  local items = {}
  for i, r in ipairs(rows) do items[i] = connection_model.serialize(r) end
  local total_pages = total > 0 and math.ceil(total / per_page) or 0
  return { items = items, meta = { page = page, per_page = per_page, total = total, total_pages = total_pages } }
end

function _M.get(identity, id)
  local row, err = connection_repo.find_by_id(id)
  if err then return nil, err end
  if not row or row.user_id ~= identity.user_id then
    return nil, errors.new("CONNECTION_NOT_FOUND", "Bağlantı bulunamadı")
  end
  return connection_model.serialize(row)
end

-- SSH sirri (parola/ozel anahtar, anahtar parolasi): dolu → sifreli, "" → sil (cjson.null), nil → dokunma
-- ponytail: SSH sirri her zaman sifreli saklanir (codd'un "sirri kaydetme" secenegi yok); gerekirse
-- parola gibi bellekte tutma eklenir
local function encrypt_optional(v)
  if v == nil then return nil end
  if v == cjson.null or v == "" then return cjson.null end
  local e, err = crypto.encrypt(v)
  if not e then
    ngx.log(ngx.ERR, "crypto encrypt hatasi: ", tostring(err))
    return nil, errors.new("INTERNAL_ERROR", "Sifreleme hatasi")
  end
  return e
end

function _M.create(identity, input)
  -- name unique per user
  local existing, _ = connection_repo.find_by_user_and_name(identity.user_id, input.name)
  if existing then
    return nil, errors.new("CONFLICT", "Ayni isimde bağlantı zaten var")
  end
  -- password encrypt: yalnizca save_password ise kalici saklanir, degilse bellekte (pool_manager)
  local enc = nil
  if input.password and input.password ~= "" and input.save_password then
    local e, err = crypto.encrypt(input.password)
    if err and not e then
      ngx.log(ngx.ERR, "crypto encrypt hatasi: ", tostring(err))
      return nil, errors.new("INTERNAL_ERROR", "Sifreleme hatasi")
    end
    enc = e
  end
  local fields = {
    user_id = identity.user_id,
    name = input.name,
    host = input.host,
    port = input.port,
    database = input.database,
    username = input.username,
    password_encrypted = enc,
    save_password = input.save_password or false,
    ssh_enabled = input.ssh_enabled or false,
    ssh_host = input.ssh_host ~= cjson.null and input.ssh_host or nil,
    ssh_port = input.ssh_port ~= cjson.null and input.ssh_port or nil,
    ssh_username = input.ssh_username ~= cjson.null and input.ssh_username or nil,
    ssh_auth_method = input.ssh_auth_method ~= cjson.null and input.ssh_auth_method or nil,
    ssh_private_key_path = input.ssh_private_key_path ~= cjson.null and input.ssh_private_key_path or nil,
    ssh_save_secret = input.ssh_save_secret or false,
    ssh_host_key_fingerprint = input.ssh_host_key_fingerprint ~= cjson.null and input.ssh_host_key_fingerprint or nil,
    ssl_mode = input.ssl_mode,
  }
  local serr
  fields.ssh_secret_encrypted, serr = encrypt_optional(input.ssh_secret)
  if serr then return nil, serr end
  fields.ssh_passphrase_encrypted, serr = encrypt_optional(input.ssh_passphrase)
  if serr then return nil, serr end
  if fields.ssh_secret_encrypted == cjson.null then fields.ssh_secret_encrypted = nil end
  if fields.ssh_passphrase_encrypted == cjson.null then fields.ssh_passphrase_encrypted = nil end
  -- ssh validasyon: enabled ise host/port/username gerekli (validation'da nullable, burada kontrol)
  if fields.ssh_enabled then
    if not fields.ssh_host or fields.ssh_host == "" then
      return nil, errors.new("VALIDATION_FAILED", "SSH host gerekli", { ssh_host = { "zorunlu alan" } })
    end
  end
  local row, err
  local ok, tx_err = query.with_transaction(function()
    row, err = connection_repo.create(fields)
    if not row then return nil, err end
    local audit_service = require("services.audit_service")
    audit_service.record("connection.create", {
      entity_type = "connection", entity_id = row.id,
      new_value = { host = row.host, port = row.port, database = row.database, username = row.username, name = row.name },
    })
    return row
  end)
  if not ok then return nil, tx_err end
  if not input.save_password and input.password and input.password ~= "" then
    pool_manager.remember_password(row.id, input.password)
  end
  return connection_model.serialize(row)
end

function _M.update(identity, id, input)
  local row, err = connection_repo.find_by_id(id)
  if err then return nil, err end
  if not row or row.user_id ~= identity.user_id then
    return nil, errors.new("CONNECTION_NOT_FOUND", "Bağlantı bulunamadı")
  end
  local old_serialized = connection_model.serialize(row)
  -- name degisti ise unique kontrol
  if input.name and input.name ~= row.name then
    local dup = connection_repo.find_by_user_and_name(identity.user_id, input.name)
    if dup then
      return nil, errors.new("CONFLICT", "Ayni isimde bağlantı zaten var")
    end
  end
  local fields = {}
  if input.name ~= nil then fields.name = input.name end
  if input.host ~= nil then fields.host = input.host end
  if input.port ~= nil then fields.port = input.port end
  if input.database ~= nil then fields.database = input.database end
  if input.username ~= nil then fields.username = input.username end
  if input.save_password ~= nil then fields.save_password = input.save_password end
  if input.ssh_enabled ~= nil then fields.ssh_enabled = input.ssh_enabled end
  if input.ssh_host ~= nil then fields.ssh_host = input.ssh_host end
  if input.ssh_port ~= nil then fields.ssh_port = input.ssh_port end
  if input.ssh_username ~= nil then fields.ssh_username = input.ssh_username end
  if input.ssh_auth_method ~= nil then fields.ssh_auth_method = input.ssh_auth_method end
  if input.ssh_private_key_path ~= nil then fields.ssh_private_key_path = input.ssh_private_key_path end
  if input.ssh_save_secret ~= nil then fields.ssh_save_secret = input.ssh_save_secret end
  if input.ssl_mode ~= nil then fields.ssl_mode = input.ssl_mode end
  local serr
  fields.ssh_secret_encrypted, serr = encrypt_optional(input.ssh_secret)
  if serr then return nil, serr end
  fields.ssh_passphrase_encrypted, serr = encrypt_optional(input.ssh_passphrase)
  if serr then return nil, serr end
  -- SSH sunucusu degisti: onaylanan host anahtari artik gecersiz (yeniden onay gerekir)
  if (input.ssh_host ~= nil and input.ssh_host ~= row.ssh_host)
    or (input.ssh_port ~= nil and tonumber(input.ssh_port) ~= tonumber(row.ssh_port)) then
    fields.ssh_known_host = cjson.null
  end
  if input.ssh_host_key_fingerprint ~= nil then fields.ssh_host_key_fingerprint = input.ssh_host_key_fingerprint end
  -- parola: nil => dokunma, "" => temizle, dolu => save_password'a gore DB'ye (sifreli) ya da bellege.
  -- cjson.null repo'da SQL NULL olur. save_password kapatilinca kayitli parola DB'den silinir (codd).
  local save = input.save_password
  if save == nil then save = row.save_password end
  local plain = input.password ~= cjson.null and input.password or nil
  if plain == "" then
    fields.password_encrypted = cjson.null
    pool_manager.forget_password(id)
  elseif plain and save then
    local e, cerr = crypto.encrypt(plain)
    if not e then
      ngx.log(ngx.ERR, "crypto encrypt hatasi: ", tostring(cerr))
      return nil, errors.new("INTERNAL_ERROR", "Sifreleme hatasi")
    end
    fields.password_encrypted = e
    pool_manager.forget_password(id)
  elseif not save then
    if not plain and row.password_encrypted and row.password_encrypted ~= "" then
      plain = crypto.decrypt(row.password_encrypted)
    end
    if row.password_encrypted then fields.password_encrypted = cjson.null end
    if plain then pool_manager.remember_password(id, plain) end
  end
  local new_row, uerr
  local ok, tx_err = query.with_transaction(function()
    new_row, uerr = connection_repo.update(id, fields)
    if not new_row then return nil, uerr end
    local audit_service = require("services.audit_service")
    audit_service.record("connection.update", {
      entity_type = "connection", entity_id = id,
      old_value = mask_for_audit(old_serialized),
      new_value = mask_for_audit(connection_model.serialize(new_row)),
    })
    return new_row
  end)
  if not ok then return nil, tx_err end
  -- havuz adi updated_at icerdigi icin eski soketler zaten kullanilmaz; LRU kaydini da at
  pool_manager.invalidate(id)
  return connection_model.serialize(new_row)
end

function _M.delete(identity, id)
  local row, err = connection_repo.find_by_id(id)
  if err then return nil, err end
  if not row or row.user_id ~= identity.user_id then
    return nil, errors.new("CONNECTION_NOT_FOUND", "Bağlantı bulunamadı")
  end
  local old_serialized = connection_model.serialize(row)
  local deleted, derr = connection_repo.delete(id)
  if derr then return nil, derr end
  if not deleted then return nil, errors.new("CONNECTION_NOT_FOUND", "Bağlantı bulunamadı") end
  pool_manager.invalidate(id)
  local audit_service = require("services.audit_service")
  audit_service.record("connection.delete", {
    entity_type = "connection", entity_id = id,
    old_value = mask_for_audit(old_serialized),
  })
  return true
end

function _M.test_connection(identity, id)
  local row, err = connection_repo.find_by_id(id)
  if err then return nil, err end
  if not row or row.user_id ~= identity.user_id then
    return nil, errors.new("CONNECTION_NOT_FOUND", "Bağlantı bulunamadı")
  end
  local start = ngx.now()
  -- pool_manager acquire: decrypt iceride yapıliyor ama biz de log icin kontrol edelim
  local pg, acq_err = pool_manager.acquire(row)
  if not pg then
    local latency = math.floor((ngx.now() - start) * 1000)
    connection_repo.update_test_result(id, false, latency)
    local audit_service = require("services.audit_service")
    audit_service.record("connection.test", {
      entity_type = "connection", entity_id = id, status = "failure",
      new_value = { success = false, latency_ms = latency },
      error_message = type(acq_err) == "table" and acq_err.message or tostring(acq_err),
    })
    if type(acq_err) == "table" and acq_err.__app_error then
      return nil, acq_err
    end
    return nil, errors.new("CONNECTION_FAILED", "Bağlantı kurulamadı", { db_message = tostring(acq_err and acq_err.message or acq_err) })
  end
  -- SELECT 1 test
  -- F30: read_only → hedef rol salt okunur (default_transaction_read_only); UI'da RO rozeti
  local res, qerr = pg:query("SELECT version() AS pg_version, "
    .. "current_setting('default_transaction_read_only') = 'on' AS read_only")
  local latency = math.floor((ngx.now() - start) * 1000)
  local success = res ~= nil
  local pg_version = success and res[1] and res[1].pg_version or nil
  local read_only = success and res[1] and res[1].read_only == true or false
  -- release
  pool_manager.release(id, pg, not success)
  connection_repo.update_test_result(id, success, latency)
  local audit_service = require("services.audit_service")
  audit_service.record("connection.test", {
    entity_type = "connection", entity_id = id, status = success and "success" or "failure",
    new_value = { success = success, latency_ms = latency },
    error_message = not success and tostring(qerr) or nil,
  })
  if not success then
    return nil, errors.new("CONNECTION_FAILED", "Bağlantı testi basarisiz", { db_message = tostring(qerr) })
  end
  return { success = true, latency_ms = latency, pg_version = pg_version, read_only = read_only }
end

local function owned(identity, id)
  local row, err = connection_repo.find_by_id(id)
  if err then return nil, err end
  if not row or row.user_id ~= identity.user_id then
    return nil, errors.new("CONNECTION_NOT_FOUND", "Bağlantı bulunamadı")
  end
  return row
end

-- Kaydedilmemis parolayi dogrula ve bellege al (PASSWORD_REQUIRED sonrasi)
function _M.unlock(identity, id, password)
  local row, err = owned(identity, id)
  if not row then return nil, err end
  pool_manager.remember_password(id, password)
  local pg, aerr = pool_manager.acquire(row)
  if not pg then
    pool_manager.forget_password(id)
    local msg = tostring(aerr and aerr.details and aerr.details.db_message)
    if aerr and aerr.code == "PASSWORD_REQUIRED" or msg:find("password") or msg:find("authentication") then
      return nil, errors.new("VALIDATION_FAILED", "Parola hatali", { password = { "Parola hatali" } })
    end
    return nil, aerr
  end
  pool_manager.release(id, pg, false)
  return { unlocked = true }
end

-- SSH sunucu anahtari (TOFU): parmak izlerini goster; kullanıcı onaylayinca kaydet
function _M.ssh_host_key(identity, id)
  local row, err = owned(identity, id)
  if not row then return nil, err end
  if not row.ssh_enabled or not row.ssh_host then return nil, errors.new("VALIDATION_FAILED", "SSH tuneli kapali") end
  local ssh_tunnel = require("db.ssh_tunnel")
  local lines, serr = ssh_tunnel.scan(row.ssh_host, row.ssh_port or 22)
  if not lines then return nil, errors.new("CONNECTION_FAILED", "SSH sunucusuna ulasilamadi", { db_message = tostring(serr) }) end
  return { host = row.ssh_host, port = row.ssh_port or 22, fingerprints = ssh_tunnel.fingerprints(lines),
    trusted = row.ssh_known_host == lines }
end

function _M.trust_ssh_host_key(identity, id, fingerprint)
  local row, err = owned(identity, id)
  if not row then return nil, err end
  if not row.ssh_enabled or not row.ssh_host then return nil, errors.new("VALIDATION_FAILED", "SSH tuneli kapali") end
  local ssh_tunnel = require("db.ssh_tunnel")
  local lines, serr = ssh_tunnel.scan(row.ssh_host, row.ssh_port or 22)
  if not lines then return nil, errors.new("CONNECTION_FAILED", "SSH sunucusuna ulasilamadi", { db_message = tostring(serr) }) end
  -- sunucu anahtari yeniden taranir: kullanıcınin gordugu parmak izi hala sunucununki olmali
  local match = false
  for _, fp in ipairs(ssh_tunnel.fingerprints(lines)) do if fp.fingerprint == fingerprint then match = true end end
  if not match then return nil, errors.new("CONFLICT", "Parmak izi sunucunun anahtariyla eslesmiyor") end
  local updated, uerr = connection_repo.update(id, { ssh_known_host = lines, ssh_host_key_fingerprint = fingerprint })
  if not updated then return nil, uerr end
  require("services.audit_service").record("connection.update", { entity_type = "connection", entity_id = id,
    new_value = { ssh_host_key_fingerprint = fingerprint } })
  return connection_model.serialize(updated)
end

function _M.list_databases(identity, id)
  local row, err = connection_repo.find_by_id(id)
  if err then return nil, err end
  if not row or row.user_id ~= identity.user_id then
    return nil, errors.new("CONNECTION_NOT_FOUND", "Bağlantı bulunamadı")
  end
  local pg, acq_err = pool_manager.acquire(row)
  if not pg then
    if type(acq_err) == "table" and acq_err.__app_error then return nil, acq_err end
    return nil, errors.new("CONNECTION_FAILED", "Bağlantı kurulamadı", { db_message = tostring(acq_err and acq_err.message or acq_err) })
  end
  local res, qerr = pg:query("SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY datname")
  pool_manager.release(id, pg, res == nil)
  if not res then
    return nil, errors.new("CONNECTION_FAILED", "Veritabanlari listelenemedi", { db_message = tostring(qerr) })
  end
  local dbs = {}
  for i, r in ipairs(res) do dbs[i] = r.datname end
  return dbs
end

return _M
