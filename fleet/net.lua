-- fleet/net.lua — envelope encode/decode, version check, id minting, dedupe.
-- Shared by turtle and controller so both sides agree on the wire format.

local E = requireModule("errors")
local net = {}

net.VERSION = 1

-- JSON that tolerates CC's quirks. textutils.serialiseJSON emits {} for an
-- empty table (never []), so consumers must accept {} to mean "no items".
function net.encode(tbl)
  local ok, out = pcall(textutils.serialiseJSON, tbl)
  if not ok then return nil, "encode_failed" end
  return out
end

function net.decode(raw)
  if type(raw) ~= "string" then return nil, "not_a_string" end
  if #raw > 32768 then return nil, "too_large" end
  local ok, tbl = pcall(textutils.unserialiseJSON, raw)
  if not ok or type(tbl) ~= "table" then return nil, "malformed_json" end
  return tbl
end

-- Validate the envelope. Returns the message table or nil + reason.
-- Deliberately strict: anything unexpected is rejected, not coerced.
function net.validate(msg)
  if type(msg) ~= "table" then return nil, E.BAD_ARGS end
  if msg.v ~= net.VERSION then return nil, "bad_version" end
  if type(msg.id) ~= "string" or #msg.id == 0 or #msg.id > 64 then return nil, E.BAD_ARGS end
  if type(msg.action) ~= "string" or #msg.action == 0 or #msg.action > 32 then return nil, E.BAD_ARGS end
  if msg.args ~= nil and type(msg.args) ~= "table" then return nil, E.BAD_ARGS end
  return msg
end

-- Command ids are namespaced by boot epoch so a controller restart can never
-- alias an id used in a previous session (which would corrupt turtle dedupe).
function net.newIdMinter(namespace)
  local epoch = os.epoch("utc")
  local n = 0
  return function()
    n = n + 1
    return ("%s-%d-%03d"):format(namespace, epoch, n)
  end
end

-- Bounded ring buffer of (id -> response) for idempotency.
-- The whole point: a retried command must REPLAY, never RE-EXECUTE.
function net.newDedupe(size)
  local d = { order = {}, map = {}, size = size or 32, n = 0 }
  function d:get(id)
    return self.map[id]
  end
  function d:put(id, response)
    if self.map[id] == nil then
      self.n = self.n + 1
      self.order[self.n] = id
      if self.n > self.size then
        local oldest = table.remove(self.order, 1)
        self.map[oldest] = nil
        self.n = self.n - 1
      end
    end
    self.map[id] = response
    return response
  end
  return d
end

return net
