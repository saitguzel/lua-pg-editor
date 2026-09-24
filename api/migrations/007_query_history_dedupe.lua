-- 007_query_history_dedupe: codd gibi ayni SQL tekrar calisinca yeni kayit yerine mevcut kayit en uste tasinir.
-- sql_hash = md5(sql); (kullanici, baglanti, veritabani, sql_hash) tekil. Mevcut kopyalardan en yenisi kalir.
return {
  version = 7,
  name = "query_history_dedupe",
  up = {
    [[ALTER TABLE query_history ADD COLUMN sql_hash TEXT]],
    [[UPDATE query_history SET sql_hash = md5(sql)]],
    [[DELETE FROM query_history a USING query_history b
      WHERE a.user_id = b.user_id AND a.connection_id = b.connection_id AND a.database = b.database
        AND a.sql_hash = b.sql_hash AND (a.executed_at, a.id) < (b.executed_at, b.id)]],
    [[ALTER TABLE query_history ALTER COLUMN sql_hash SET NOT NULL]],
    [[CREATE UNIQUE INDEX query_history_dedupe_idx ON query_history(user_id, connection_id, database, sql_hash)]],
  },
  down = {
    [[DROP INDEX IF EXISTS query_history_dedupe_idx]],
    [[ALTER TABLE query_history DROP COLUMN IF EXISTS sql_hash]],
  },
}
