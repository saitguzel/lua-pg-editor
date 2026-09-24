-- Hazır taslaklar (düzenlenemez; "Taslaklarım"a kopyalanıp düzenlenebilir).
-- Gövde CodeMirror snippet sözdizimi: ${ad} yer tutucu (Tab ile gezinilir); düz eklemede snippets.plain() adı bırakır.
local _M = {}

_M.items = {
  { id = "b:select", name = "SELECT", prefix = "sel", category = "Sorgu",
    body = "SELECT ${kolonlar}\nFROM ${tablo}\nWHERE ${kosul}\nORDER BY ${kolon}\nLIMIT 100;" },
  { id = "b:insert", name = "INSERT", prefix = "ins", category = "Sorgu",
    body = "INSERT INTO ${tablo} (${kolon1}, ${kolon2})\nVALUES (${deger1}, ${deger2})\nRETURNING *;" },
  { id = "b:update", name = "UPDATE", prefix = "upd", category = "Sorgu",
    body = "UPDATE ${tablo}\nSET ${kolon} = ${deger}\nWHERE ${kosul}\nRETURNING *;" },
  { id = "b:delete", name = "DELETE", prefix = "del", category = "Sorgu",
    body = "DELETE FROM ${tablo}\nWHERE ${kosul}\nRETURNING *;" },
  { id = "b:cte", name = "WITH (CTE)", prefix = "cte", category = "Sorgu",
    body = "WITH ${ad} AS (\n    SELECT ${kolonlar}\n    FROM ${tablo}\n)\nSELECT *\nFROM ${ad};" },
  { id = "b:join", name = "JOIN", prefix = "join", category = "Sorgu",
    body = "SELECT a.*, b.*\nFROM ${tablo_a} a\nJOIN ${tablo_b} b ON b.${a_id} = a.id\nLIMIT 100;" },
  { id = "b:explain", name = "EXPLAIN ANALYZE", prefix = "exp", category = "Sorgu",
    body = "EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)\n${sorgu};" },
  { id = "b:tx", name = "Transaction bloğu", prefix = "tx", category = "Sorgu",
    body = "BEGIN;\n\n${komutlar}\n\nCOMMIT;" },
  { id = "b:create_table", name = "CREATE TABLE", prefix = "ctab", category = "DDL",
    body = "CREATE TABLE ${sema}.${tablo} (\n    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,\n"
      .. "    ${kolon} text NOT NULL,\n    created_at timestamptz NOT NULL DEFAULT now()\n);" },
  { id = "b:create_index", name = "CREATE INDEX", prefix = "cidx", category = "DDL",
    body = "CREATE INDEX CONCURRENTLY IF NOT EXISTS ${index_adi}\n    ON ${tablo} (${kolon});" },
  { id = "b:create_view", name = "CREATE VIEW", prefix = "cview", category = "DDL",
    body = "CREATE OR REPLACE VIEW ${sema}.${view_adi} AS\nSELECT ${kolonlar}\nFROM ${tablo};" },
  { id = "b:create_function", name = "CREATE FUNCTION", prefix = "cfn", category = "Fonksiyon",
    body = "CREATE OR REPLACE FUNCTION ${sema}.${fonksiyon_adi}(p_id integer)\nRETURNS TABLE (id integer, ad text)\n"
      .. "LANGUAGE plpgsql\nSTABLE\nAS $$\nBEGIN\n    RETURN QUERY\n    SELECT t.id, t.ad\n    FROM ${tablo} t\n"
      .. "    WHERE t.id = p_id;\nEND;\n$$;" },
  { id = "b:create_procedure", name = "CREATE PROCEDURE", prefix = "cproc", category = "Fonksiyon",
    body = "CREATE OR REPLACE PROCEDURE ${sema}.${prosedur_adi}(p_id integer)\nLANGUAGE plpgsql\nAS $$\nBEGIN\n"
      .. "    UPDATE ${tablo} SET ${kolon} = ${deger} WHERE id = p_id;\n"
      .. "    -- COMMIT; (prosedürde transaction kontrolü mümkün)\nEND;\n$$;\n\n-- CALL ${sema}.${prosedur_adi}(1);" },
  { id = "b:create_trigger", name = "CREATE TRIGGER (+ fonksiyon)", prefix = "ctrg", category = "Fonksiyon",
    body = "CREATE OR REPLACE FUNCTION ${sema}.${trigger_fonksiyonu}()\nRETURNS trigger\nLANGUAGE plpgsql\n"
      .. "AS $$\nBEGIN\n"
      .. "    NEW.updated_at := now();\n    RETURN NEW;\nEND;\n$$;\n\nCREATE TRIGGER ${trigger_adi}\n"
      .. "    BEFORE UPDATE ON ${sema}.${tablo}\n    FOR EACH ROW\n"
      .. "    EXECUTE FUNCTION ${sema}.${trigger_fonksiyonu}();" },
}

-- ${ad} → ad (düz metin eklemede)
function _M.plain(body)
  return (body:gsub("%${([^}]*)}", "%1"))
end

-- sidebar "+" butonları: tür → taslak (şema adı doldurulmuş)
local CREATE_FOR = { ["function"] = "b:create_function", procedure = "b:create_procedure",
  trigger = "b:create_trigger", table = "b:create_table", view = "b:create_view" }

function _M.create_template(kind, schema)
  for _, it in ipairs(_M.items) do
    if it.id == CREATE_FOR[kind] then
      local quoted = schema:match("^[a-z_][a-z0-9_]*$") and schema or ('"' .. schema:gsub('"', '""') .. '"')
      return _M.plain((it.body:gsub("%${sema}", (quoted:gsub("%%", "%%%%")))))
    end
  end
end

return _M
