-- fleet/load.lua — module loader for CC:Tweaked.
--
-- WHY THIS EXISTS: CC:Tweaked sandboxes each program, and `require` is NOT a
-- guaranteed global in that environment. Observed 2026-10-02 on computer 5:
--
--   [fleet] FATAL load error /fleet/net.lua:4: attempt to call global require a nil value
--
-- So no module in this tree may call require(). Instead they call:
--
--   local E = requireModule("errors")     -- from any module
--
-- which is wired up here. The cache means each module is loaded exactly once
-- per process, matching what require() would have guaranteed.
--
-- Install order matters: load.lua must be executed once before any module that
-- uses requireModule(). fleet/main.lua does this, and so does
-- fleet/turtle_startup.lua.

local DIR = "/fleet/"
local CACHE = {}

--- Load (once) and return the module table for `name`.
-- @param name string module basename, e.g. "errors" — not "fleet.errors"
-- @return table|nil module, string|nil error
local function requireModule(name)
  local cached = CACHE[name]
  if cached ~= nil then return cached ~= false and cached or nil, nil end

  local path = DIR .. name .. ".lua"
  if not fs.exists(path) then
    CACHE[name] = false
    return nil, "missing " .. path
  end

  local chunk, err = loadfile(path)
  if not chunk then
    CACHE[name] = false
    return nil, "parse failed " .. path .. ": " .. tostring(err)
  end

  local ok, result = pcall(chunk)
  if not ok then
    CACHE[name] = false
    return nil, "load error " .. path .. ": " .. tostring(result)
  end

  CACHE[name] = result
  return result
end

-- Expose as a global so sibling modules can call it. CC programs share a
-- global table per process, so this is the equivalent of an import.
_G.requireModule = requireModule
_G.FLEET_LOADED = CACHE

return { requireModule = requireModule, CACHE = CACHE, DIR = DIR }