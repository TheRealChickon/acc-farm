-- Ranked recorder v1 (READ ONLY: no game commands, no hooks, no listeners, no getgc loop).
-- Run in the attached client (Potassium execute_script) only while recording. Stop: _G.__RR_STOP = true
-- One getgc scan at start (to find the client context); after that it only reads ctx.reflected() and the ECS BattleSession query.
-- Every change in the ranked data is written as its own small file, so nothing is ever overwritten:
--   <workspace>/AnimeCardClash/ranked_log/<kind>_<ms>_<n>.json     kinds: summary (offers, own defense, rating), history, fight_start, fight_end
-- ranked_log.py ingest moves them into players/Whousleaks/ranked_log/*.jsonl (append only).
-- Raw values are stored (depth <= 9), so unknown fields are kept for later analysis.
if game.Players.LocalPlayer.Name ~= "Whousleaks" then print("RR WRONG ACCOUNT") return end
_G.__RR_GEN = (_G.__RR_GEN or 0) + 1
local GEN = _G.__RR_GEN
_G.__RR_STOP = false
local RS = game:GetService("ReplicatedStorage")
local HS = game:GetService("HttpService")
local comps = require(RS.shared.components)
local POLL = _G.__RR_POLL or 4          -- seconds between reads (cheap table reads)
local DIR = "AnimeCardClash/ranked_log"
pcall(makefolder, "AnimeCardClash") pcall(makefolder, DIR)
local n = 0
local function clean(v, d)
  d = d or 0
  local t = typeof(v)
  if t == "number" then if v ~= v or v == math.huge or v == -math.huge then return tostring(v) end return v
  elseif t == "string" or t == "boolean" then return v
  elseif t == "table" then
    if d > 9 then return "<deep>" end
    local o, c = {}, 0
    for k, x in pairs(v) do c += 1 if c > 600 then break end o[tostring(k)] = clean(x, d + 1) end
    return o
  else return nil end
end
local function save(kind, rec)
  n += 1
  rec.kind = kind
  rec.loggedAtClient = os.time()
  rec.serverNow = workspace:GetServerTimeNow()
  local ok, err = pcall(writefile, DIR .. "/" .. kind .. "_" .. math.floor(rec.serverNow * 1000) .. "_" .. n .. ".json", HS:JSONEncode(clean(rec)))
  if not ok then print("RR write failed", err) end
end
local ctx
local function findCtx()
  for _, t in ipairs(getgc(true)) do
    if type(t) == "table" then pcall(function() if rawget(t, "clientToServerEntities") ~= nil and rawget(t, "focusedBattleSession") ~= nil and rawget(t, "reflected") ~= nil then ctx = t end end) end
  end
  return ctx
end
local lastScan = 0
local function user()
  if not ctx then
    if os.clock() - lastScan < 30 then return nil end   -- never scan more than every 30 s
    lastScan = os.clock() findCtx()
    if not ctx then return nil end
  end
  local ok, r = pcall(function() return ctx.reflected().user end)
  return ok and r or nil
end
local seen = {}         -- kind/season/mode -> last encoded string
local function changed(key, value)
  local ok, s = pcall(function() return HS:JSONEncode(clean(value)) end)
  if not ok then return false end
  if seen[key] == s then return false end
  seen[key] = s
  return true
end
local function rankedSession()
  local ok, e, v = pcall(function() for e, v in ctx.world:query(comps.BattleSession) do if v.type == "ranked" then return e, v end end end)
  if ok then return e, v end
end
local cur   -- fight in progress {entity, seed, startedAt}
task.spawn(function()
  print("RR v1 running gen", GEN, "poll", POLL)
  while not _G.__RR_STOP and _G.__RR_GEN == GEN do
    local u = user()
    if u and type(u.rankedSaves) == "table" then
      for season, sv in pairs(u.rankedSaves) do
        if type(sv) == "table" and type(sv.modes) == "table" then
          for mode, m in pairs(sv.modes) do
            if type(m) == "table" then
              if m.summary and changed("s/" .. tostring(season) .. "/" .. mode, m.summary) then
                save("summary", { season = tostring(season), mode = mode, summary = m.summary })
              end
              if m.history and changed("h/" .. tostring(season) .. "/" .. mode, m.history) then
                save("history", { season = tostring(season), mode = mode, history = m.history })
              end
            end
          end
        end
      end
    end
    if ctx then
      local e, v = rankedSession()
      if e and not cur then
        local extra = {}
        pcall(function() extra.rankedBattle = ctx.world:get(e, comps.RankedBattle) end)
        cur = { entity = e, seed = v.seed, startedAt = v.startedAt }
        save("fight_start", { session = v, rankedBattle = extra.rankedBattle, seed = v.seed, serverNowSeen = workspace:GetServerTimeNow() })
        print("RR fight start seed", tostring(v.seed))
      elseif cur and not e then
        -- session gone: the next summary read carries won/lost for the offer; log the end marker too
        save("fight_end", { seed = cur.seed, startedAt = cur.startedAt })
        print("RR fight end seed", tostring(cur.seed))
        cur = nil
        seen = {}   -- force a fresh summary/history write after the fight
      end
    end
    task.wait(POLL)
  end
  print("RR stopped")
end)
