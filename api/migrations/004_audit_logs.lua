-- 004_audit_logs: denetim kaydı tablosu ve indeksleri (pg-editor spec)
return {
  version = 4,
  name = "audit_logs",
  up = {
    [[CREATE TABLE audit_logs (
      id BIGSERIAL PRIMARY KEY,
      request_id UUID,
      user_id UUID REFERENCES users(id) ON DELETE SET NULL,
      user_email VARCHAR(255),
      action VARCHAR(64) NOT NULL,
      entity_type VARCHAR(32) NOT NULL,
      entity_id TEXT,
      old_value JSONB,
      new_value JSONB,
      ip INET,
      ip_address INET,
      user_agent TEXT,
      status VARCHAR(16) NOT NULL DEFAULT 'success' CHECK (status IN ('success','failure')),
      error_message TEXT,
      created_at TIMESTAMPTZ DEFAULT now()
    )]],
    [[CREATE INDEX audit_logs_user_id_idx ON audit_logs(user_id)]],
    [[CREATE INDEX audit_logs_action_idx ON audit_logs(action)]],
    [[CREATE INDEX audit_logs_entity_idx ON audit_logs(entity_type, entity_id)]],
    [[CREATE INDEX audit_logs_created_at_idx ON audit_logs(created_at)]],
    [[CREATE INDEX audit_logs_created_at_brin ON audit_logs USING brin(created_at)]],
  },
  down = {
    [[DROP TABLE IF EXISTS audit_logs]],
  },
}
