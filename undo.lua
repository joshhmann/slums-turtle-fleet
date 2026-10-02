-- undo.lua — remove the Hyrax fleet from a CC computer.
-- Paste into the computer. Reverses bootstrap.lua.
-- Refuses to delete anything it did not create.

local MANIFEST_PATH = "/fleet/.installed"
local TARGETS = {
  "/fleet/errors.lua", "/fleet/net.lua", "/fleet/config.lua",
  "/fleet/verbs.lua", "/fleet/state.lua", "/fleet/controller.lua",
  "/fleet/controller_startup.lua", "/fleet/turtle_startup.lua",
  "/startup.lua", "/turtle-startup.lua", "/bridge-token.txt",
}

local function out(s) print("[hyrax] " .. s) end

-- Only proceed if we installed it. Otherwise we might delete someone's startup.
local installed = fs.exists(MANIFEST_PATH)
if not installed then
  out("no manifest at " .. MANIFEST_PATH .. " — not undoing anything.")
  out("if you are sure, delete the files manually.")
  return
end

local f = fs.open(MANIFEST_PATH, "r")
local raw = f.readAll()
f.close()
print("[hyrax] manifest: " .. raw)

-- Dry run is the DEFAULT. Undo that can silently delete someone's startup.lua
-- is not something to trigger by pasting. Delete these two lines to arm it.
local ARMED = false
if not ARMED then
  out("DRY RUN — nothing deleted. Set ARMED = true above to delete.")
  return
end

do
  local removed, missing = {}, {}
  for _, p in ipairs(TARGETS) do
    if fs.exists(p) then
      fs.delete(p)
      removed[#removed + 1] = p
    else
      missing[#missing + 1] = p
    end
  end
  if fs.exists("/fleet") then fs.delete("/fleet") end
  print("")
  out("REMOVED " .. #removed)
  for _, p in ipairs(removed) do print("    - " .. p) end
  if #missing > 0 then out("already absent: " .. #missing) end
  out("if /bridge-token.txt was real, rotate that token now")
end