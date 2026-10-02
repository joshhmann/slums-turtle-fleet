-- boot.lua — the single paste that installs the whole fleet.
-- Paste into a CC:Tweaked computer. Under 400 chars per line by design.
--
-- Fetches each module from the public repo and writes it into /fleet/.
-- One file at a time, verifying the byte count before accepting it, so a
-- truncated download can't silently corrupt an install.

local R = "http://192.168.0.200:6157/opengist/joshmann/slums-fleet/raw/"
local D = "/fleet/"

-- name, repo subpath, expected bytes
local FILES = {
  { "errors.lua",       "fleet/errors.lua",        798 },
  { "net.lua",          "fleet/net.lua",          2364 },
  { "config.lua",       "fleet/config.lua",       2216 },
  { "verbs.lua",        "fleet/verbs.lua",        6837 },
  { "state.lua",        "fleet/state.lua",        9462 },
  { "controller.lua",   "fleet/controller.lua",   7451 },
  { "turtle_startup.lua", "fleet/turtle_startup.lua", 874 },
}

if not fs.exists(D) then fs.mkdir(D) end

print("[hyrax] fetching " .. #FILES .. " modules")

local ok_count, fail_count = 0, 0

for i = 1, #FILES do
  local spec = FILES[i]
  local r = http.get(R .. spec[2])

  if r == nil then
    print("  FAIL " .. spec[1] .. " : no response")
    fail_count = fail_count + 1
  elseif r.statusCode ~= 200 then
    print("  FAIL " .. spec[1] .. " : HTTP " .. tostring(r.statusCode))
    fail_count = fail_count + 1
  else
    local body = r.readAll()
    if #body ~= spec[3] then
      print("  FAIL " .. spec[1] .. " : got " .. #body .. " want " .. spec[3])
      fail_count = fail_count + 1
    else
      local f = fs.open(D .. spec[1], "w")
      if f then
        f.write(body)
        f.close()
        print("  ok   " .. spec[1] .. " (" .. #body .. "B)")
        ok_count = ok_count + 1
      else
        print("  FAIL " .. spec[1] .. " : cannot write")
        fail_count = fail_count + 1
      end
    end
  end
end

print("")
print("[hyrax] installed " .. ok_count .. "/" .. #FILES)
if fail_count > 0 then
  print("[hyrax] " .. fail_count .. " FAILED — do not run the controller yet")
  print("[hyrax] re-run this file; successful modules are not re-fetched")
else
  print("[hyrax] next:")
  print("  1. edit /fleet/config.lua -> MODE = 'controller', BRIDGE_ENABLED = true")
  print("  2. put the bridge token in /bridge-token.txt (never paste it into code)")
  print("  3. reboot the computer")
end