-- 006_query_history: sorgu geçmişi tablosu + updated_at triggerlari
return {
  version = 6,
  name = "query_history",
  up = {
    [[CREATE TABLE query_history (
      id BIGSERIAL PRIMARY KEY,
      user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      connection_id UUID NOT NULL REFERENCES connections(id) ON DELETE CASCADE,
      database VARCHAR(63) NOT NULL,
      sql TEXT NOT NULL,
      row_count INT,
      duration_ms INT,
      truncated BOOLEAN DEFAULT false,
      executed_at TIMESTAMPTZ DEFAULT now()
    )]],
    [[CREATE INDEX query_history_user_conn_idx ON query_history(user_id, connection_id, database)]],
    [[CREATE INDEX query_history_executed_at_idx ON query_history(executed_at)]],
    [[CREATE INDEX query_history_lookup_idx ON query_history(connection_id, database, executed_at DESC)]],
    [[CREATE OR REPLACE FUNCTION set_updated_at()
      RETURNS TRIGGER AS $$
      BEGIN
        NEW.updated_at = now();
        RETURN NEW;
      END;
      $$ LANGUAGE plpgsql]],
    [[CREATE TRIGGER users_updated_at
      BEFORE UPDATE ON users
      FOR EACH ROW EXECUTE FUNCTION set_updated_at()]],
    [[CREATE TRIGGER connections_updated_at
      BEFORE UPDATE ON connections
      FOR EACH ROW EXECUTE FUNCTION set_updated_at()]],
  },
  down = {
    [[DROP TRIGGER IF EXISTS connections_updated_at ON connections]],
    [[DROP TRIGGER IF EXISTS users_updated_at ON users]],
    [[DROP FUNCTION IF EXISTS set_updated_at()]],
    [[DROP TABLE IF EXISTS query_history]],
  },
}
