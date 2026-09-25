-- AES-256-GCM bağlantı parolasi sifreleme (pg-editor, F4)
-- ENCRYPTION_KEY 32 byte; format iv:ct:tag (her biri base64)
local config = require("config")
local random = require("security.random")

local _M = {}

local function get_key()
  local c = config.get()
  if not c then return nil, "config yok" end
  local raw = c.encryption_key or c.ENCRYPTION_KEY or c._raw and c._raw.ENCRYPTION_KEY
  if not raw or raw == "" then return nil, "ENCRYPTION_KEY eksik" end
  -- base64 decode dene (ngx varsa)
  if ngx and ngx.decode_base64 then
    local decoded = ngx.decode_base64(raw)
    if decoded and #decoded == 32 then return decoded end
    -- bazi uretimlerde newline veya bosluk olabilir
    local trimmed = raw:gsub("%s+", "")
    if trimmed ~= raw then
      decoded = ngx.decode_base64(trimmed)
      if decoded and #decoded == 32 then return decoded end
    end
  end
  -- hex 64 karakter olabilir
  if #raw == 64 and raw:match("^%x+$") then
    local ok, str_mod = pcall(require, "resty.string")
    if ok and str_mod and str_mod.from_hex then
      local h = str_mod.from_hex(raw)
      if h and #h == 32 then return h end
    end
    -- fallback hex decode manuel
    local bytes = {}
    for i = 1, 64, 2 do
      local b = tonumber(raw:sub(i, i + 1), 16)
      if not b then break end
      bytes[#bytes + 1] = string.char(b)
    end
    local hex_decoded = table.concat(bytes)
    if #hex_decoded == 32 then return hex_decoded end
  end
  if #raw == 32 then return raw end
  -- ham anahtar 32'den uzunsa ve base64 decode edilemiyorsa ilk 32'yi al? Guvenli degil, hata dondur
  return nil, "ENCRYPTION_KEY 32 byte olmali, simdiki " .. #raw
end

local function b64enc(s)
  if ngx and ngx.encode_base64 then
    return ngx.encode_base64(s)
  end
  -- fallback: resty.string?
  local ok, resty_str = pcall(require, "resty.string")
  if ok and resty_str and resty_str.to_hex then
    -- hex yerine base64 yok, ama ngx olmali
    return resty_str.to_hex(s)
  end
  return s
end

local function b64dec(s)
  if ngx and ngx.decode_base64 then
    return ngx.decode_base64(s)
  end
  return nil
end

-- luaossl ile encrypt
local function encrypt_luaossl(key, iv, plaintext)
  local ok, cipher_mod = pcall(require, "openssl.cipher")
  if not ok or not cipher_mod then return nil, "luaossl yok" end
  local cipher_ok, cipher = pcall(cipher_mod.new, "aes-256-gcm")
  if not cipher_ok or not cipher then
    -- bazi surumlerde cipher.new("aes-256-gcm") yerine get
    cipher_ok, cipher = pcall(cipher_mod.new, cipher_mod)
    if not cipher_ok then return nil, "cipher new basarisiz" end
  end
  -- Different API paths: cipher:encrypt(key, iv) vs cipher:encrypt(key, iv, aad)
  local ok_init, err_init = pcall(function() return cipher:encrypt(key, iv) end)
  if not ok_init then
    -- try alternative: cipher:encrypt(key, iv, "")
    local ok2, err2 = pcall(function() return cipher:encrypt(key, iv, "") end)
    if not ok2 then return nil, tostring(err2 or err_init) end
  end
  local ok, res = pcall(function()
    local part = cipher:update(plaintext)
    local fin = cipher:final()
    return (part or "") .. (fin or "")
  end)
  if not ok then return nil, tostring(res) end
  local ct = res
  local tag
  local ok_tag, tag_res = pcall(function() return cipher:getTag(16) end)
  if ok_tag then tag = tag_res else
    local ok_tag2, tag2 = pcall(function() return cipher:getTag() end)
    if ok_tag2 then tag = tag2 end
  end
  if not tag then return nil, "tag alinamadi" end
  -- cipher:encrypt modunda tag otomatik; bazi surumlerde getTag parametresiz 16 byte
  return ct, tag
end

local function decrypt_luaossl(key, iv, ct, tag)
  local ok, cipher_mod = pcall(require, "openssl.cipher")
  if not ok or not cipher_mod then return nil, "luaossl yok" end
  local cipher_ok, cipher = pcall(cipher_mod.new, "aes-256-gcm")
  if not cipher_ok or not cipher then return nil, "cipher new basarisiz" end
  local ok_init, err_init = pcall(function() return cipher:decrypt(key, iv) end)
  if not ok_init then
    local ok2, err2 = pcall(function() return cipher:decrypt(key, iv, "") end)
    if not ok2 then return nil, tostring(err2 or err_init) end
  end
  -- tag'i ayarla (decrypt icin)
  local ok_tag, err_tag = pcall(function() return cipher:setTag(tag) end)
  if not ok_tag then
    -- bazi surumlerde tag update'ten once ayarlanir, bazi surumlerde sonra
    -- dene: auth_tag?
    return nil, "setTag basarisiz: " .. tostring(err_tag)
  end
  local ok_dec, res2 = pcall(function()
    local part = cipher:update(ct)
    local fin = cipher:final()
    return (part or "") .. (fin or "")
  end)
  if not ok_dec then
    return nil, tostring(res2)
  end
  return res2
end

-- resty.aes fallback
local function encrypt_resty_aes(key, iv, plaintext)
  local ok, aes_mod = pcall(require, "resty.aes")
  if not ok or not aes_mod then return nil, "resty.aes yok" end
  -- resty.aes API: aes:new(key, salt, { method, iv })
  local aes_obj, err = aes_mod:new(key, nil, aes_mod.cipher(256, "gcm"), { iv = iv })
  if not aes_obj then return nil, tostring(err) end
  -- encrypt returns string, maybe tag via get_tag?
  local ct, tag
  local ok_e, res = pcall(function() return aes_obj:encrypt(plaintext) end)
  if not ok_e then return nil, tostring(res) end
  -- resty.aes gcm'de tag'i ayri donduruyor olabilir
  if type(res) == "table" then
    ct = res.ciphertext or res[1]
    tag = res.tag or res[2]
  else
    ct = res
    -- try get tag
    local ok_t, t = pcall(function() return aes_obj:get_tag() end)
    if ok_t then tag = t end
    if not tag then
      local ok_t2, t2 = pcall(function() return aes_obj._tag end)
      if ok_t2 then tag = t2 end
    end
  end
  if not ct or not tag then return nil, "resty.aes tag alinamadi" end
  return ct, tag
end

local function decrypt_resty_aes(key, iv, ct, tag)
  local ok, aes_mod = pcall(require, "resty.aes")
  if not ok or not aes_mod then return nil, "resty.aes yok" end
  local aes_obj, err = aes_mod:new(key, nil, aes_mod.cipher(256, "gcm"), { iv = iv })
  if not aes_obj then return nil, tostring(err) end
  if tag and aes_obj.set_tag then pcall(function() aes_obj:set_tag(tag) end) end
  local ok_d, res = pcall(function() return aes_obj:decrypt(ct) end)
  if not ok_d then return nil, tostring(res) end
  return res
end

function _M.encrypt(plaintext)
  if plaintext == nil then return nil end
  if type(plaintext) ~= "string" then return nil, "gecersiz girdi" end
  if plaintext == "" then return nil end
  local key, kerr = get_key()
  if not key then
    ngx.log(ngx.ERR, "crypto encrypt key hatasi: ", tostring(kerr))
    return nil, kerr
  end
  if #key ~= 32 then
    ngx.log(ngx.ERR, "crypto encrypt key uzunlugu hatali: ", #key)
    return nil, "gecersiz key uzunlugu"
  end
  local iv = random.bytes(12)
  local ct, tag, enc_err
  -- once luaossl dene
  ct, tag = encrypt_luaossl(key, iv, plaintext)
  if not ct then
    enc_err = tag
    -- fallback resty.aes
    ct, tag = encrypt_resty_aes(key, iv, plaintext)
    if not ct then
      ngx.log(ngx.ERR, "crypto encrypt basarisiz luaossl: ", tostring(enc_err), " resty.aes: ", tostring(tag))
      return nil, "encrypt failed"
    end
  end
  local b64_iv = b64enc(iv)
  local b64_ct = b64enc(ct)
  local b64_tag = b64enc(tag)
  if not b64_iv or not b64_ct or not b64_tag then
    return nil, "base64 encode basarisiz"
  end
  return b64_iv .. ":" .. b64_ct .. ":" .. b64_tag
end

function _M.decrypt(blob)
  if blob == nil then return nil end
  if type(blob) ~= "string" then return nil, "gecersiz girdi" end
  if blob == "" then return nil end
  -- format kontrolu: iv:ct:tag
  local b64_iv, b64_ct, b64_tag = blob:match("^([^:]+):([^:]+):([^:]+)$")
  if not b64_iv then
    ngx.log(ngx.WARN, "crypto decrypt format hatasi")
    return nil, "decrypt failed"
  end
  local iv = b64dec(b64_iv)
  local ct = b64dec(b64_ct)
  local tag = b64dec(b64_tag)
  if not iv or not ct or not tag then
    ngx.log(ngx.WARN, "crypto decrypt base64 decode basarisiz")
    return nil, "decrypt failed"
  end
  if #iv ~= 12 then
    ngx.log(ngx.WARN, "crypto decrypt iv uzunlugu hatali: ", #iv)
    return nil, "decrypt failed"
  end
  local key, kerr = get_key()
  if not key then
    ngx.log(ngx.ERR, "crypto decrypt key hatasi: ", tostring(kerr))
    return nil, "decrypt failed"
  end
  if #key ~= 32 then
    ngx.log(ngx.ERR, "crypto decrypt key uzunlugu hatali")
    return nil, "decrypt failed"
  end
  local plain, dec_err
  plain, dec_err = decrypt_luaossl(key, iv, ct, tag)
  if not plain then
    -- fallback resty.aes
    local plain2, err2 = decrypt_resty_aes(key, iv, ct, tag)
    if plain2 then return plain2 end
    ngx.log(ngx.WARN, "crypto decrypt basarisiz: ", tostring(dec_err), " fallback: ", tostring(err2))
    return nil, "decrypt failed"
  end
  return plain
end

function _M.reencrypt(old_key, new_key)
  -- key rotation helper (job): old_key ile decrypt, new_key ile encrypt
  -- bu fonksiyon dogrudan cagrilmaz; config degisiminde manuel kullanilabilir
  return _M.encrypt
end

return _M
