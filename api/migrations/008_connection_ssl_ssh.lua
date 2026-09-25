-- 008_connection_ssl_ssh: SSL modu ve SSH tuneli sirlari.
-- ssl_mode: disable | prefer | require (yeni bağlantılar prefer; mevcutlar bugunku davranis: disable)
-- ssh_secret_encrypted: SSH parolasi ya da ozel anahtar (crypto.encrypt); ssh_passphrase_encrypted: anahtar parolasi
-- ssh_known_host: kullanıcınin onayladigi known_hosts satıri (ilk bağlantıda guven, TOFU)
return {
  version = 8,
  name = "connection_ssl_ssh",
  up = {
    [[ALTER TABLE connections ADD COLUMN ssl_mode VARCHAR(10) NOT NULL DEFAULT 'prefer'
      CHECK (ssl_mode IN ('disable', 'prefer', 'require'))]],
    [[UPDATE connections SET ssl_mode = 'disable']],
    [[ALTER TABLE connections ADD COLUMN ssh_secret_encrypted TEXT]],
    [[ALTER TABLE connections ADD COLUMN ssh_passphrase_encrypted TEXT]],
    [[ALTER TABLE connections ADD COLUMN ssh_known_host TEXT]],
  },
  down = {
    [[ALTER TABLE connections DROP COLUMN IF EXISTS ssh_known_host]],
    [[ALTER TABLE connections DROP COLUMN IF EXISTS ssh_passphrase_encrypted]],
    [[ALTER TABLE connections DROP COLUMN IF EXISTS ssh_secret_encrypted]],
    [[ALTER TABLE connections DROP COLUMN IF EXISTS ssl_mode]],
  },
}
