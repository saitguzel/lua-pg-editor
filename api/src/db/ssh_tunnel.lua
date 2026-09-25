-- SSH tuneli (codd ssh_tunnel): `ssh -N -L 127.0.0.1:<yerel>:<db_host>:<db_port>` sureci (ngx.pipe).
-- Kimlik: parola (sshpass) ya da ozel anahtar (0600 gecici dosya, parolasi sshpass ile). Sunucu anahtari:
-- ilk bağlantıda kullanıcı parmak izini onaylar (TOFU), sonra StrictHostKeyChecking=yes.
-- ponytail: tuneller worker basina tutulur (her worker kendi ssh sureci); cok sayida es zamanli SSH
-- bağlantısi gerekirse ayri bir tunel sidecar'ina tasinmali.
local ngx_pipe = require("ngx.pipe")

local _M = {}

local DIR = "/tmp/pgl-ssh"
local IDLE_TTL = 600 -- sn: kullanilmayan tunel kapatilir
local PORT_BASE, PORTS_PER_WORKER = 40000, 200
local ENV_PATH = "PATH=/usr/local/bin:/usr/bin:/bin"

local tunnels = {} -- key -> { proc, port, used }
local slot = 0
local reaper_started = false

local function run(args, stdin)
  local proc, err = ngx_pipe.spawn(args, { environ = { ENV_PATH } })
  if not proc then return nil, err end
  proc:set_timeouts(5000, 10000, 10000, 15000)
  if stdin then proc:write(stdin); proc:shutdown("stdin") end
  local out = proc:stdout_read_all() or ""
  local errout = proc:stderr_read_all() or ""
  local ok = proc:wait()
  return out, (not ok) and errout or nil
end

local function write_file(path, content)
  local f, err = io.open(path, "w")
  if not f then return nil, err end
  f:write(content)
  f:close()
  run({ "chmod", "600", path })
  return true
end

local function ensure_dir() run({ "mkdir", "-p", "-m", "700", DIR }) end

local function key_of(conn) return tostring(conn.id) .. ":" .. tostring(conn.updated_at or "") end

-- ssh-keyscan: sunucunun known_hosts satırlari
function _M.scan(host, port)
  local out, err = run({ "ssh-keyscan", "-T", "5", "-p", tostring(port or 22), host })
  local lines = {}
  for line in (out or ""):gmatch("[^\n]+") do
    if not line:match("^#") then lines[#lines + 1] = line end
  end
  if #lines == 0 then return nil, err or "sunucu anahtari alinamadi" end
  return table.concat(lines, "\n") .. "\n"
end

-- known_hosts satırlari → { { type, fingerprint } } (ssh-keygen -lf -)
function _M.fingerprints(known_hosts)
  local out = run({ "ssh-keygen", "-lf", "-" }, known_hosts) or ""
  local list = {}
  for line in out:gmatch("[^\n]+") do
    local fp, typ = line:match("^%d+%s+(SHA256:%S+)%s+.-%((%S+)%)%s*$")
    if fp then list[#list + 1] = { type = typ, fingerprint = fp } end
  end
  return list
end

-- ssh komut satıri (test edilebilir, surec baslatmaz). secrets: { password, passphrase }
function _M.command(conn, local_port, files, secrets)
  local args, env = {}, { ENV_PATH }
  local ssh = {
    "ssh", "-N", "-T",
    "-L", "127.0.0.1:" .. local_port .. ":" .. conn.host .. ":" .. tostring(conn.port),
    "-p", tostring(conn.ssh_port or 22),
    "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3",
    "-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=" .. files.known_hosts,
  }
  if conn.ssh_auth_method == "private_key" then
    for _, a in ipairs({ "-i", files.key, "-o", "IdentitiesOnly=yes" }) do ssh[#ssh + 1] = a end
    if secrets.passphrase then
      args = { "sshpass", "-P", "passphrase", "-e" }
      env[#env + 1] = "SSHPASS=" .. secrets.passphrase
    else
      for _, a in ipairs({ "-o", "BatchMode=yes" }) do ssh[#ssh + 1] = a end
    end
  else
    args = { "sshpass", "-e" }
    env[#env + 1] = "SSHPASS=" .. (secrets.password or "")
    for _, a in ipairs({ "-o", "PreferredAuthentications=password,keyboard-interactive", "-o", "PubkeyAuthentication=no" }) do
      ssh[#ssh + 1] = a
    end
  end
  ssh[#ssh + 1] = conn.ssh_username .. "@" .. conn.ssh_host
  for _, a in ipairs(ssh) do args[#args + 1] = a end
  return args, env
end

local function port_open(port)
  local sock = ngx.socket.tcp()
  sock:settimeout(200)
  local ok = sock:connect("127.0.0.1", port)
  sock:close()
  return ok ~= nil
end

local function start_reaper()
  if reaper_started then return end
  reaper_started = true
  ngx.timer.every(60, function(premature)
    if premature then return end
    for k, t in pairs(tunnels) do
      if ngx.now() - t.used > IDLE_TTL then pcall(t.proc.kill, t.proc, 15); tunnels[k] = nil end
    end
  end)
end

-- Tunel ac ya da mevcudu kullan → "127.0.0.1", yerel_port | nil, hata ({ code, message })
-- secrets: { password = ssh parolasi | key = ozel anahtar icerigi, passphrase }
function _M.ensure(conn, secrets)
  if not conn.ssh_known_host or conn.ssh_known_host == "" then
    return nil, { code = "SSH_HOST_KEY_UNKNOWN", message = "SSH sunucu anahtari onaylanmadi" }
  end
  local key = key_of(conn)
  local t = tunnels[key]
  if t and port_open(t.port) then t.used = ngx.now(); return "127.0.0.1", t.port end
  if t then pcall(t.proc.kill, t.proc, 15); tunnels[key] = nil end
  ensure_dir()
  local files = { known_hosts = DIR .. "/" .. tostring(conn.id) .. ".known_hosts", key = DIR .. "/" .. tostring(conn.id) .. ".key" }
  write_file(files.known_hosts, conn.ssh_known_host)
  if conn.ssh_auth_method == "private_key" then
    local k = (secrets.key or ""):gsub("\r\n", "\n")
    if not k:match("\n$") then k = k .. "\n" end
    write_file(files.key, k)
  end
  local base = PORT_BASE + (ngx.worker.id() or 0) * PORTS_PER_WORKER
  local last_err
  for _ = 1, 5 do
    slot = (slot + 1) % PORTS_PER_WORKER
    local lport = base + slot
    if not port_open(lport) then
      local args, env = _M.command(conn, lport, files, secrets)
      local proc, serr = ngx_pipe.spawn(args, { environ = env })
      if not proc then return nil, { code = "CONNECTION_FAILED", message = "ssh baslatilamadi: " .. tostring(serr) } end
      proc:set_timeouts(nil, nil, 100)
      local stderr = ""
      for _ = 1, 100 do -- en fazla ~10 sn
        if port_open(lport) then
          tunnels[key] = { proc = proc, port = lport, used = ngx.now() }
          start_reaper()
          return "127.0.0.1", lport
        end
        local chunk, rerr = proc:stderr_read_any(4096)
        if chunk then stderr = stderr .. chunk end
        if rerr == "closed" then break end
      end
      pcall(proc.kill, proc, 15)
      last_err = stderr ~= "" and stderr or "SSH tuneli acilamadi (zaman asimi)"
      if not stderr:find("bind", 1, true) then break end -- port cakismasi degilse tekrar deneme
    end
  end
  ngx.log(ngx.WARN, "ssh tuneli acilamadi (", tostring(conn.ssh_username), "@", tostring(conn.ssh_host), "): ", tostring(last_err))
  return nil, { code = "CONNECTION_FAILED", message = "SSH tuneli acilamadi", db_message = last_err }
end

return _M
