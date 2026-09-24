-- 003_rbac: rol-sayfa izin matrisi tablosu (pg-editor: rbac_permissions)
-- Her rol × sayfa kombinasyonu için tek satır.
return {
  version = 3,
  name = "rbac",
  up = {
    [[CREATE TABLE rbac_permissions (
      role user_role NOT NULL,
      page_key VARCHAR(64) NOT NULL,
      can_access BOOLEAN NOT NULL,
      updated_at TIMESTAMPTZ DEFAULT now(),
      PRIMARY KEY (role, page_key)
    )]],
  },
  down = {
    [[DROP TABLE IF EXISTS rbac_permissions]],
  },
}
