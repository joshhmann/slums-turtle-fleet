-- bootstrap.lua — one-paste installer for the Hyrax Slums MC turtle fleet.
-- Paste into a CC:Tweaked COMPUTER (not a turtle) on the Slums server.
--
-- What it does, in order:
--   1. reads /config.json  (github token, repo, ref)  — or fills it in
--   2. fetches /VERSION    (version guard: refuse to downgrade silently)
--   3. fetches fleet/*.lua from GitHub raw into /fleet/
--   4. writes /startup.lua (controller) OR /turtle-startup.lua
--   5. prints a manifest of what it wrote and what it skipped
--
-- Re-running is safe: it overwrites only its own files and never touches
-- anything else. An undo paste removes fleet/ and startup.lua again.
--
-- SECURITY: the token is read from a file and never echoed, logged, or
-- inlined into any written file. Do NOT paste a token into this program.

local VERSION_URL  = "https://raw.githubusercontent.com/OWNER/REPO/REF/VERSION"
local BASE_URL     = "https://raw.githubusercontent.com/OWNER/REPO/REF"
local CONFIG_PATH  = "/config.json"
local MANIFEST_PATH = "/fleet/.installed"

local MODULES = {
  "errors", "net", "config", "verbs", "state",
}
local STARTUP_CONTROLLER = "controller_startup"
local STARTUP_TURTLE     = "turtle_startup"

local function out(s) print("[hyrax] " .. s) end
local function fail(s) print("[hyrax] FAIL: " .. s) end

-- ---------------------------------------------------------------------------
-- 1. config
-- ---------------------------------------------------------------------------
local function readConfig()
  if not fs.exists(CONFIG_PATH) then
    fail("no " .. CONFIG_PATH)
    print("  create it first, e.g.:")
    print('  shell.run(\'echo \\"{\\\\\\"token\\\\\\":\\\\\\"ghp_xxx\\\\\\",\\\\\\"repo\\\\\\":\\\\\\"OWNER/REPO\\\\\\",\\\\\\"ref\\\\\\":\\\\\\"main\\\\\\"}\\" > ' .. CONFIG_PATH .. '\')')
    return nil
  end
  local f = fs.open(CONFIG_PATH, "r")
  if not f then fail("cannot open " .. CONFIG_PATH) return nil end
  local raw = f.readAll()
  f.close()

  local ok, cfg = pcall(textutils.unserialiseJSON, raw)
  if not ok or type(cfg) ~= "table" then
    fail(CONFIG_PATH .. " is not valid JSON")
    return nil
  end
  if type(cfg.token) ~= "string" or #cfg.token == 0 then
    fail("config needs a \"token\" field")
    return nil
  end
  if type(cfg.repo) ~= "string" or not cfg.repo:find("/") then
    fail("config needs \"repo\" as OWNER/REPO")
    return nil
  end
  cfg.ref = cfg.ref or "main"
  return cfg
end

-- ---------------------------------------------------------------------------
-- 2. version guard
-- ---------------------------------------------------------------------------
local function remoteVersion(cfg)
  local r = http.get(VERSION_URL:gsub("OWNER/REPO/REF", cfg.repo .. "/" .. cfg.ref), {
    headers = { ["Authorization"] = "token " .. cfg.token },
  })
  if r == nil then return nil, "version fetch failed (token or network?)" end
  if r.statusCode and r.statusCode ~= 200 then
    return nil, "version HTTP " .. tostring(r.statusCode)
  end
  local body = r.readAll and r.readAll() or ""
  return (body:gsub("%s+", ""))
end

-- ---------------------------------------------------------------------------
-- 3. fetch a module
-- ---------------------------------------------------------------------------
local function fetchModule(cfg, name)
  local url = BASE_URL:gsub("OWNER/REPO/REF", cfg.repo .. "/" .. cfg.ref) .. "/fleet/" .. name .. ".lua"
  local r = http.get(url, {
    headers = { ["Authorization"] = "token " .. cfg.token },
  })
  if r == nil then return nil, "nil response" end
  if r.statusCode and r.statusCode ~= 200 then
    return nil, "HTTP " .. tostring(r.statusCode)
  end
  local body = r.readAll and r.readAll() or ""
  if #body == 0 then return nil, "empty body" end
  return body
end

local function writeFile(path, content)
  local f = fs.open(path, "w")
  if not f then return false, "cannot open " .. path .. " for write" end
  f.write(content)
  f.close()
  return true
end

-- ---------------------------------------------------------------------------
-- 4. main
-- ---------------------------------------------------------------------------
local cfg = readConfig()
if not cfg then return end

local wantVersion, verr = remoteVersion(cfg)
if wantVersion == nil then
  fail(verr)
  return
end
out("remote version: " .. wantVersion)

if fs.exists(MANIFEST_PATH) then
  local mf = fs.open(MANIFEST_PATH, "r")
  local prev = mf and mf.readAll() or ""
  if mf then mf.close() end
  local prevVersion = prev:match('"version"%s*:%s*"([^"]*)"')
  if prevVersion and prevVersion ~= wantVersion and prevVersion > wantVersion then
    out("installed " .. prevVersion .. " is NEWER than remote " .. wantVersion .. " — keeping local copy")
    out("to force reinstall, delete " .. MANIFEST_PATH .. " and re-run")
    return
  end
  if prevVersion == wantVersion then
    out("version unchanged (" .. wantVersion .. ") — refreshing files anyway")
  end
end

if not fs.exists("/fleet") then fs.mkdir("/fleet") end

local written, skipped = {}, {}
for _, name in ipairs(MODULES) do
  local body, ferr = fetchModule(cfg, name)
  if body == nil then
    fail(name .. ".lua — " .. tostring(ferr))
    skipped[#skipped + 1] = name
  else
    local ok, werr = writeFile("/fleet/" .. name .. ".lua", body)
    if ok then
      written[#written + 1] = name .. ".lua (" .. #body .. "B)"
    else
      fail(name .. ".lua — " .. tostring(werr))
      skipped[#skipped + 1] = name
    end
  end
end

-- Controller entry point
local ctrl, cerr = fetchModule(cfg, STARTUP_CONTROLLER)
if ctrl then
  writeFile("/startup.lua", ctrl)
  written[#written + 1] = "startup.lua (controller, " .. #ctrl .. "B)"
else
  fail("controller_startup — " .. tostring(cerr))
  skipped[#skipped + 1] = "controller_startup"
end

-- The turtle side is optional at bootstrap time; fetch it too so a single
-- paste on the PC can hand it to a turtle later.
local tur, terr = fetchModule(cfg, STARTUP_TURTLE)
if tur then
  writeFile("/turtle-startup.lua", tur)
  written[#written + 1] = "turtle-startup.lua (" .. #tur .. "B)"
else
  fail("turtle_startup — " .. tostring(terr))
  skipped[#skipped + 1] = "turtle_startup"
end

writeFile(MANIFEST_PATH, textutils.serialiseJSON({
  version = wantVersion,
  repo = cfg.repo,
  ref = cfg.ref,
  installed_epoch = os.epoch("utc"),
}))

print("")
out("INSTALLED " .. #written .. " files:")
for _, w in ipairs(written) do print("    + " .. w) end
if #skipped > 0 then
  print("")
  out("SKIPPED " .. #skipped .. " (check token scope: contents:read):")
  for _, s in ipairs(skipped) do print("    - " .. s) end
end
print("")
out("NEXT:")
print("  1. copy config into /fleet/config.lua  (MODE, TURTLE_ID, CONTROLLER_ID)")
print("  2. put a bridge token in /bridge-token.txt")
print("  3. reboot the computer — startup.lua runs")
out("done.")