-- 010_app_settings: uygulama geneli ayarlar (anahtar → JSON). İlk kullanım: "ai" (NVIDIA API anahtarı şifreli)
return {
  version = 10,
  name = "app_settings",
  up = {
    [[CREATE TABLE app_settings (
      key VARCHAR(64) PRIMARY KEY,
      value JSONB NOT NULL DEFAULT '{}'::jsonb,
      updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
      updated_by UUID REFERENCES users(id) ON DELETE SET NULL
    )]],
    [[CREATE TRIGGER app_settings_updated_at
      BEFORE UPDATE ON app_settings
      FOR EACH ROW EXECUTE FUNCTION set_updated_at()]],
  },
  down = {
    [[DROP TABLE IF EXISTS app_settings]],
  },
}
