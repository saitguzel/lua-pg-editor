-- Hedef PostgreSQL havuz yöneticisi: her kayitli bağlantı icin ayri pgmoon keepalive (LRU)
-- 00 §2: meta DB ve hedef DB izolasyonu; LRU 32 giris, idle 5 dk.
local pgmoon = require("pgmoon")
local config = require("config")
local lru_mod = require("utils.lru")

local _M = {}

local pools = nil

local function get_pools()
  if pools then return pools end
  local cfg = config.get()
  local max = cfg and cfg.target and cfg.target.pool_max or 32
  -- idle: sabit 300 sn (5 dk)
  pools = lru_mod.new(max, 300)
  return pools
end

-- String/number OID 0 serializasyonu (db/pool.lua ile ayni)
local function untyped(_, v)
  if type(v) == "number" and v == math.floor(v) and v > -2^63 and v < 2^63 then
    return 0, string.format("%d", v)
  end
  return 0, tostring(v)
end
local SERIALIZERS = setmetatable({ string = untyped, number = untyped }, { __index = pgmoon.Postgres.type_serializers })

local PgError = {
  __tostring = function(e) return e.message end,
  __concat = function(a, b) return tostring(a) .. tostring(b) end,
}
local function parse_error(self, err_msg)
  local msg, data = pgmoon.Postgres.parse_error(self, err_msg)
  data = data or {}
  -- position: hatanın sorgu metnindeki 1 tabanlı karakter konumu (sözdizimi hataları; F27)
  return setmetatable({ message = msg, code = data.code, constraint = data.constraint,
                        detail = data.detail, table = data.table, position = tonumber(data.position) }, PgError)
end

-- Hedef DB tip eslemesi: bytea hex metin kalir (ham ikili JSON'u bozar), numeric/int8 metin kalir
-- (Lua sayisina cevrilince hassasiyet kaybolur), tarih/saat tipleri grid renklendirmesi icin adlandirilir.
-- Deserializer'i olmayan tip adlari metin olarak doner.
local PG_TYPES = setmetatable({
  [17] = "bytea_hex", [20] = "int8", [1700] = "numeric",
  [1082] = "date", [1083] = "time", [1114] = "timestamp", [1184] = "timestamptz", [1266] = "timetz",
}, { __index = pgmoon.Postgres.PG_TYPES })
local DESERIALIZERS = setmetatable({
  timestamptz = function(_, val)
    return (val:gsub(" ", "T", 1):gsub("%+00$", "Z"))
  end,
}, { __index = pgmoon.Postgres.type_deserializers })

-- Sonuca sirali kolon adlari ve tiplerini ekler (result_info): pgmoon satırlari map dondurur,
-- sira ve NULL kolonlar kaybolur; 0 satırli SELECT'te de kolonlar bilinir.
-- Ayni adli kolonlarda (SELECT 1 a, 2 a) map satırlar degeri ezer: o durumda satırlar kolon indeksiyle
-- ayrica ayristirilip res.array_rows'a konur (NULL → nil delik).
local function format_query_result(self, row_desc, data_rows, command_complete)
  local fields = row_desc and self:parse_row_desc(row_desc)
  local names, types, seen, dup = {}, {}, {}, false
  for i, f in ipairs(fields or {}) do
    names[i], types[i] = f[1], f[2]
    dup = dup or seen[f[1]]
    seen[f[1]] = true
  end
  local raw
  if dup and data_rows then
    raw = {}
    for i, r in ipairs(data_rows) do raw[i] = r end
  end
  local res = pgmoon.Postgres.format_query_result(self, row_desc, data_rows, command_complete)
  if fields and type(res) == "table" then
    -- metatable'da: sonuc dogrudan JSON'a cevrilirse (cjson metatable'i yok sayar) dizi olarak kalir
    local info = { fields = names, types = types }
    if raw then
      local by_index = {}
      for i, f in ipairs(fields) do by_index[i] = { i, f[2] } end
      info.array_rows = {}
      for i, r in ipairs(raw) do info.array_rows[i] = self:parse_data_row(r, by_index) end
    end
    setmetatable(res, { __pg_result = info })
  end
  return res
end

-- Sorgu sonucunun kolon bilgisi: { fields, types, array_rows? } | nil (satır tanimi yok: INSERT/DDL)
function _M.result_info(res)
  local mt = type(res) == "table" and getmetatable(res)
  return mt and mt.__pg_result or nil
end

-- Havuz anahtari hedefi tam tanimlar: ayni conn.id'nin farkli DB/host/kullanıcı soketleri karismaz
-- (pgmoon yeniden kullanilan sokette startup paketini atlar → yanlis DB'de sorgu calisirdi)
local function pool_name(conn, host, port)
  return table.concat({ "target", tostring(conn.id), tostring(host or conn.host), tostring(port or conn.port),
    tostring(conn.database), tostring(conn.username), tostring(conn.ssl_mode or "disable"),
    tostring(conn.updated_at or "") }, ":")
end
_M._pool_name = pool_name

-- save_password=false parolalari kalici DB yerine bellekte tutulur (sifreli, TTL): codd'un
-- "her bağlantıda sor" davranisinin web karsiligi. Suresi dolunca bağlantı PASSWORD_REQUIRED doner.
local SECRET_TTL = 12 * 3600

function _M.remember_password(conn_id, plain)
  local dict = ngx.shared.conn_secrets
  if not dict or not plain or plain == "" then return end
  local enc = require("security.crypto").encrypt(plain)
  if enc then dict:set(tostring(conn_id), enc, SECRET_TTL) end
end

function _M.forget_password(conn_id)
  local dict = ngx.shared.conn_secrets
  if dict then dict:delete(tostring(conn_id)) end
end

local function decrypt_password(conn)
  local enc = conn.password_encrypted
  if not enc or enc == "" then
    local dict = ngx.shared.conn_secrets
    enc = dict and dict:get(tostring(conn.id))
    if not enc then return nil end
  end
  local plain, err = require("security.crypto").decrypt(enc)
  if not plain then ngx.log(ngx.WARN, "pool_manager decrypt basarisiz: ", tostring(err)) end
  return plain
end

-- conn = { id, host, port, database, username, password_encrypted }
function _M.acquire(conn)
  if not conn or not conn.id then return nil, "gecersiz bağlantı" end
  local pools_lru = get_pools()
  -- LRU'da anahtar conn.id
  -- Her cagri yeni pgmoon bağlantısi acar; keepalive ile havuzda tutulur
  local cfg = config.get()
  local timeout = cfg and cfg.query and cfg.query.timeout_ms or 30000
  local pool_size = cfg and cfg.target and cfg.target.pool_size or 5
  local password = decrypt_password(conn)

  -- SSH tuneli: hedefe tunelin yerel ucundan baglanilir
  local host, port = conn.host, conn.port
  if conn.ssh_enabled then
    local crypto = require("security.crypto")
    local secret = conn.ssh_secret_encrypted and crypto.decrypt(conn.ssh_secret_encrypted) or nil
    local private_key = conn.ssh_auth_method == "private_key"
    local h, p = require("db.ssh_tunnel").ensure(conn, {
      password = not private_key and secret or nil,
      key = private_key and secret or nil,
      passphrase = conn.ssh_passphrase_encrypted and crypto.decrypt(conn.ssh_passphrase_encrypted) or nil,
    })
    if not h then
      return nil, { code = p.code, message = p.message, __app_error = true,
        details = { connection_id = conn.id, db_message = p.db_message } }
    end
    host, port = h, p
  end

  -- ssl_mode: disable | prefer (sunucu destekliyorsa SSL) | require
  local ssl_mode = conn.ssl_mode or "disable"
  local pg = pgmoon.new({
    host = host,
    port = port,
    database = conn.database,
    user = conn.username,
    password = password,
    ssl = ssl_mode ~= "disable",
    ssl_required = ssl_mode == "require",
    pool = pool_name(conn, host, port),
  })
  pg.type_serializers = SERIALIZERS
  pg.PG_TYPES = PG_TYPES
  pg.type_deserializers = DESERIALIZERS
  pg.parse_error = parse_error
  pg.format_query_result = format_query_result
  if pg.sock and pg.sock.settimeouts then
    pg.sock:settimeouts(3000, timeout, timeout)
  elseif pg.sock and pg.sock.settimeout then
    pg.sock:settimeout(timeout)
  end
  -- pgmoon parola istenip verilmediyse assert ile firlatir ("missing password"): hataya cevir
  local pok, ok, err = pcall(pg.connect, pg)
  if not pok then ok, err = nil, ok end
  if not ok then
    -- parola kaydedilmemis ve bellekte yok: istemci parolayi sorup /unlock ile gonderir
    if not password and tostring(err):lower():find("password", 1, true) then
      return nil, { code = "PASSWORD_REQUIRED", message = "Bu bağlantı icin parola gerekli",
        details = { connection_id = conn.id }, __app_error = true }
    end
    ngx.log(ngx.WARN, "hedef bağlantı kurulamadı (", tostring(conn.id), " ", tostring(host), ":", tostring(port), "): ", tostring(err))
    return nil, { code = "CONNECTION_FAILED", message = "Bağlantı kurulamadı", details = { db_message = tostring(err) }, __app_error = true }
  end
  -- F30: oturum ayari; keepalive'dan donen socket'te zaten set, yalnizca yeni acilan bağlantıda calisir
  if pg.sock and pg.sock.getreusedtimes and pg.sock:getreusedtimes() == 0 then
    local st_ms = cfg and cfg.query and cfg.query.statement_timeout_ms or 30000
    local st_ok, st_err = pg:query("SET statement_timeout = " .. tostring(math.floor(st_ms)))
    if not st_ok then
      ngx.log(ngx.WARN, "statement_timeout ayarlanamadi (", tostring(conn.id), "): ", tostring(st_err))
    end
  end
  -- LRU'ya dokun (varsa güncelle, yoksa ekle)
  pools_lru:set(conn.id, { pg = pg, touched = ngx.now(), conn_id = conn.id })
  -- stash icin pg'yi sar
  return pg
end

-- Servislerin ortak girisi: istege bagli DB override ile bağlantı satırindan pg al → pg, conn_id
function _M.acquire_for(conn_row, database)
  local conn = conn_row
  if database and database ~= "" and database ~= conn_row.database then
    conn = {}
    for k, v in pairs(conn_row) do conn[k] = v end
    conn.database = database
  end
  local pg, err = _M.acquire(conn)
  if not pg then
    if type(err) == "table" and err.__app_error then return nil, err end
    return nil, { code = "CONNECTION_FAILED", message = "Bağlantı kurulamadı",
      details = { db_message = tostring(err and err.message or err) }, __app_error = true }
  end
  return pg, conn.id
end

function _M.release(conn_id, pg, broken)
  if not pg then return end
  if broken then
    pg:disconnect()
    if conn_id then get_pools():delete(conn_id) end
    return
  end
  local cfg = config.get()
  local pool_size = cfg and cfg.target and cfg.target.pool_size or 5
  local idle = 60000
  local ok, err = pg:keepalive(idle, pool_size)
  if not ok then
    ngx.log(ngx.WARN, "pool_manager keepalive basarisiz: ", tostring(err))
    pg:disconnect()
    if conn_id then get_pools():delete(conn_id) end
  end
end

-- Sifre degisince LRU'dan at
function _M.invalidate(connection_id)
  if not connection_id then return end
  get_pools():delete(connection_id)
end

function _M.stats()
  local p = get_pools()
  return { count = p:count(), keys = p:keys() }
end

-- Test icin LRU'ya erisim
function _M._pools()
  return get_pools()
end

return _M
