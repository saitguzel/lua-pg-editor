-- Fonksiyon / prosedür / trigger (hedef DB): oid ile adreslenir (overload'lar aynı adı paylaşır).
-- İmza ve tablo adları katalogdan gelir, kullanıcı girdisinden değil; yalnızca yeni ad kullanıcıdan gelir (quote'lu).
local _M = {}

local function q(ident) return '"' .. tostring(ident):gsub('"', '""') .. '"' end

_M.KINDS = { ["function"] = "FUNCTION", procedure = "PROCEDURE", trigger = "TRIGGER" }
local PROKIND = { ["function"] = "f", procedure = "p" }

-- nesneyi bul; yoksa nil, { code = "42883" }
function _M.lookup(pg, kind, oid)
  local res, err
  if kind == "trigger" then
    res, err = pg:query([[SELECT t.tgname AS name, n.nspname AS schema, c.relname AS table_name,
        t.tgfoid::bigint AS function_oid, t.tgenabled::text AS enabled
      FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE t.oid = $1::bigint::oid AND NOT t.tgisinternal]], oid)
  else
    res, err = pg:query([[SELECT p.proname AS name, n.nspname AS schema,
        pg_get_function_identity_arguments(p.oid) AS args
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE p.oid = $1::bigint::oid AND p.prokind = $2]], oid, PROKIND[kind])
  end
  if not res then return nil, err end
  if not res[1] then return nil, { code = "42883", message = "object does not exist" } end
  return res[1]
end

local function signature(r) return q(r.schema) .. "." .. q(r.name) .. "(" .. (r.args or "") .. ")" end
local function trigger_target(r) return q(r.name) .. " ON " .. q(r.schema) .. "." .. q(r.table_name) end

-- "a integer, b numeric(10,2)" → { "a integer", "b numeric(10,2)" } (parantez içi virgüller bölünmez)
function _M.split_args(args)
  local out, depth, cur = {}, 0, {}
  for ch in (args or ""):gmatch(".") do
    if ch == "(" then depth = depth + 1 elseif ch == ")" then depth = depth - 1 end
    if ch == "," and depth == 0 then
      out[#out + 1] = table.concat(cur):match("^%s*(.-)%s*$")
      cur = {}
    else
      cur[#cur + 1] = ch
    end
  end
  local last = table.concat(cur):match("^%s*(.-)%s*$")
  if last ~= "" then out[#out + 1] = last end
  return out
end

local function functiondef(pg, oid)
  local res, err = pg:query("SELECT pg_get_functiondef($1::bigint::oid) AS def", oid)
  if not res then return nil, err end
  return (res[1].def:gsub("%s+$", "")) .. ";"
end

-- execute şablonu: her argüman için NULL + tip yorumu
function _M.call_script(kind, r)
  local params = {}
  for i, a in ipairs(_M.split_args(r.args)) do params[i] = "    NULL /* " .. a:gsub("%*/", "* /") .. " */" end
  local call = q(r.schema) .. "." .. q(r.name) .. "("
    .. (#params > 0 and ("\n" .. table.concat(params, ",\n") .. "\n") or "") .. ")"
  return (kind == "procedure" and "CALL " or "SELECT * FROM ") .. call .. ";"
end

function _M.drop_script(kind, r)
  if kind == "trigger" then return "DROP TRIGGER " .. trigger_target(r) .. ";" end
  return "DROP " .. _M.KINDS[kind] .. " " .. signature(r) .. ";"
end

-- tür: ddl (CREATE OR REPLACE, düzenlemeye hazır) | execute (çağrı şablonu) | drop
function _M.script(pg, kind, oid, script_kind)
  local r, err = _M.lookup(pg, kind, oid)
  if not r then return nil, err end
  if script_kind == "drop" then return _M.drop_script(kind, r) end
  if script_kind == "execute" then
    if kind == "trigger" then return nil, { code = "22023", message = "trigger dogrudan calistirilamaz" } end
    return _M.call_script(kind, r)
  end
  if kind == "trigger" then
    local fn = functiondef(pg, r.function_oid) or ""
    local res, terr = pg:query("SELECT pg_get_triggerdef($1::bigint::oid, true) AS def", oid)
    if not res then return nil, terr end
    return "-- Trigger fonksiyonu\n" .. fn .. "\n\n-- Trigger (değiştirmek için önce DROP)\n"
      .. "-- DROP TRIGGER IF EXISTS " .. trigger_target(r) .. ";\n" .. res[1].def .. ";"
  end
  return functiondef(pg, oid)
end

function _M.drop(pg, kind, oid, cascade)
  local r, err = _M.lookup(pg, kind, oid)
  if not r then return nil, err end
  local sql = _M.drop_script(kind, r)
  if cascade then sql = sql:gsub(";$", " CASCADE;") end
  local res, qerr = pg:query(sql)
  if not res then return nil, qerr end
  return r
end

function _M.rename(pg, kind, oid, new_name)
  local r, err = _M.lookup(pg, kind, oid)
  if not r then return nil, err end
  local sql = kind == "trigger"
    and ("ALTER TRIGGER " .. trigger_target(r) .. " RENAME TO " .. q(new_name))
    or ("ALTER " .. _M.KINDS[kind] .. " " .. signature(r) .. " RENAME TO " .. q(new_name))
  local res, qerr = pg:query(sql)
  if not res then return nil, qerr end
  return r
end

function _M.set_trigger_enabled(pg, oid, enabled)
  local r, err = _M.lookup(pg, "trigger", oid)
  if not r then return nil, err end
  local res, qerr = pg:query("ALTER TABLE " .. q(r.schema) .. "." .. q(r.table_name)
    .. (enabled and " ENABLE" or " DISABLE") .. " TRIGGER " .. q(r.name))
  if not res then return nil, qerr end
  return r
end

return _M
