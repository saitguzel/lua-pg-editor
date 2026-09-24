-- Taslak (snippet) servis: kullanıcıya özel CRUD; başkasının taslağı yokmuş gibi davranır (NOT_FOUND)
local query = require("db.query")
local errors = require("middleware.error_handler")
local audit_service = require("services.audit_service")
local validation = require("pg_shared.validation")

local _M = {}

local COLS = "id, name, prefix, description, body, created_at, updated_at"

-- nullable alanlar: VNULL/boş → SQL NULL
local function opt(v)
  if v == nil or v == validation.NULL or v == "" then return validation.NULL end
  return v
end

local function map_err(err)
  if err and err.code == "CONFLICT" then
    return errors.new("CONFLICT", "Bu önek başka bir taslakta kullanılıyor", { prefix = { "zaten kullanılıyor" } })
  end
  return err
end

function _M.list(identity)
  return query.query("SELECT " .. COLS .. " FROM snippets WHERE user_id = $1 ORDER BY lower(name), id",
    identity.user_id)
end

function _M.create(identity, input)
  local row, err = query.query_one("INSERT INTO snippets (user_id, name, prefix, description, body) "
    .. "VALUES ($1, $2, $3, $4, $5) RETURNING " .. COLS,
    identity.user_id, input.name, opt(input.prefix), opt(input.description), input.body)
  if not row then return nil, map_err(err) end
  audit_service.record("snippet.create", { entity_type = "snippet", entity_id = row.id,
    new_value = { name = row.name, prefix = row.prefix } })
  return row
end

function _M.update(identity, id, input)
  local row, err = query.query_one("UPDATE snippets SET name = $3, prefix = $4, description = $5, body = $6 "
    .. "WHERE id = $1 AND user_id = $2 RETURNING " .. COLS,
    id, identity.user_id, input.name, opt(input.prefix), opt(input.description), input.body)
  if err then return nil, map_err(err) end
  if not row then return nil, errors.new("NOT_FOUND", "Taslak bulunamadı") end
  audit_service.record("snippet.update", { entity_type = "snippet", entity_id = row.id,
    new_value = { name = row.name, prefix = row.prefix } })
  return row
end

function _M.delete(identity, id)
  local row, err = query.query_one("DELETE FROM snippets WHERE id = $1 AND user_id = $2 RETURNING id, name",
    id, identity.user_id)
  if err then return nil, err end
  if not row then return nil, errors.new("NOT_FOUND", "Taslak bulunamadı") end
  audit_service.record("snippet.delete", { entity_type = "snippet", entity_id = row.id,
    old_value = { name = row.name } })
  return true
end

return _M
