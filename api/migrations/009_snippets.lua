-- 009_snippets: kullanıcıya özel SQL taslakları (Ctrl+J paleti, önek + Tab ile ekleme)
return {
  version = 9,
  name = "snippets",
  up = {
    [[CREATE TABLE snippets (
      id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
      user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      name VARCHAR(100) NOT NULL,
      prefix VARCHAR(32),
      description VARCHAR(500),
      body TEXT NOT NULL CHECK (length(body) <= 65536),
      created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
      updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
    )]],
    [[CREATE INDEX snippets_user_idx ON snippets(user_id, name)]],
    -- aynı kullanıcıda önek tekil (boş önek serbest)
    [[CREATE UNIQUE INDEX snippets_user_prefix_uidx ON snippets(user_id, prefix) WHERE prefix IS NOT NULL]],
    [[CREATE TRIGGER snippets_updated_at
      BEFORE UPDATE ON snippets
      FOR EACH ROW EXECUTE FUNCTION set_updated_at()]],
  },
  down = {
    [[DROP TABLE IF EXISTS snippets]],
  },
}
