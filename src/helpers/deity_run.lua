-- Tower of Deity executor (Whousleaks only). SENDS GAME COMMANDS: run only with the Coordinator's game handover.
-- Dumb on purpose: all decisions (decks, start second, which party, which second) are made by deity_driver.py on the PC.
-- Link = three small files in the executor workspace folder AnimeCardClash/deity/:
--   cmd.json    PC -> game   {id=n, op=..., ...}   one command at a time, executed once per new id
--   state.json  game -> PC   server time, session/battle read (cheap ECS reads, no getgc loop), events, last ack
--   probe.json  game -> PC   written by op "probe": the account's towerOfDeity table and the 4 Deity deck slots (ONE getgc scan per probe)
-- Ops (all timed ones carry `at` = whole server second; the command goes out at server time at + OFFSET, or is skipped if > LATE_MAX late):
--   start      {at, wave, slots={4 slot names}, towerId=nil}   -> towerOfDeityAction {kind="startTower", slots, wave}
--   continue   {at}                                             -> towerOfDeityAction {kind="continueTower"}
--   select     {party}                                          -> towerOfDeityAction {kind="selectTowerParty", party}
--   automation {setting="continue"|"rechallenge"|"swapTeam", enabled}  -> {kind="setTowerAutomation", setting, enabled}
--   abandon    {}                                               -> {kind="abandonTower"}
--   upgrade    {what="Damage"|"Health"|"AwakenedDamage"|"AwakenedHealth"} -> {kind="upgrade"..what}
--   setdeck    {slot, attack={[1..4]=card}, support={[1..4]=card}}  (4 Deity slots only; 1.4 s between commands)
--   probe      {}
--   stop       {}
-- Hard rules kept: Whousleaks only, >= 1.2 s between game commands, no hooks, no listeners, no getgc loop.
-- Stop: _G.__DT_STOP = true.   Start: loadstring(readfile("AnimeCardClash/deity/deity_run.lua"))()
if game.Players.LocalPlayer.Name ~= "Whousleaks" then print("DT WRONG ACCOUNT") return end
local RS = game:GetService("ReplicatedStorage")
local HS = game:GetService("HttpService")
local LP = game.Players.LocalPlayer
local comps = require(RS.shared.components)
local jecs = require(RS.rbxts_include.node_modules["@rbxts"].jecs.src.jecs)

local DIR = "AnimeCardClash/deity/"
local OFFSET = _G.__DT_OFFSET or 0.35          -- fire this long after the planned whole second begins (server clock)
local LATE_MAX = _G.__DT_LATE_MAX or 0.7       -- skip a timed command that would go out later than this after its second
local GAP = 1.2                                -- minimum seconds between game commands
local MAX_FIRES = _G.__DT_MAX_FIRES or 600     -- hard cap per script run
local DECK_SLOTS = { slot_tower_of_deity_1 = true, slot_tower_of_deity_2 = true, slot_tower_of_deity_3 = true, slot_tower_of_deity_4 = true }

_G.__DT_STOP = false
_G.__DT_GEN = (_G.__DT_GEN or 0) + 1
local GEN = _G.__DT_GEN
pcall(makefolder, "AnimeCardClash")
pcall(makefolder, "AnimeCardClash/deity")

local function now() return workspace:GetServerTimeNow() end
local function readJson(path) local ok, s = pcall(readfile, path) if not ok then return nil end local ok2, v = pcall(function() return HS:JSONDecode(s) end) return ok2 and v or nil end
local function writeJson(path, v) local ok, s = pcall(function() return HS:JSONEncode(v) end) if ok then pcall(writefile, path, s) end return ok end
local function flat(v) local o = {} if type(v) == "table" then for k, x in pairs(v) do local tx = type(x) if tx == "number" or tx == "string" or tx == "boolean" then o[tostring(k)] = x end end end return o end

-- ---------------------------------------------------------------- game handles (one getgc scan, cached)
local ctx = _G.__DT_CTX
local function findCtx()
  if ctx and pcall(function() return ctx.world end) then return ctx end
  for _, t in ipairs(getgc(true)) do if type(t) == "table" then pcall(function() if rawget(t, "clientToServerEntities") ~= nil and rawget(t, "focusedBattleSession") ~= nil then ctx = t end end) end end
  _G.__DT_CTX = ctx
  return ctx
end
local remotes = {}
local function remote(n)
  if remotes[n] then return remotes[n] end
  for _, d in ipairs(RS:GetDescendants()) do if d.Name == n and d:IsA("RemoteEvent") and not d:GetFullName():find("JABBY", 1, true) then remotes[n] = d return d end end
end

local lastSend = 0
local fires = 0
local function send(name, ...)
  local r = remote(name)
  if not r then return false, "no remote " .. name end
  if fires >= MAX_FIRES then return false, "fire cap reached" end
  local wait = lastSend + GAP - os.clock()
  if wait > 0 then task.wait(wait) end
  r:FireServer(...)
  lastSend = os.clock()
  fires += 1
  return true
end

-- ---------------------------------------------------------------- cheap reads (ECS)
local function session()
  local c = findCtx()
  if not c then return end
  for e, v in c.world:query(comps.BattleSession) do if v.type == "tower_of_deity" then return e, v end end
end
local function battleOf(se)
  local c = findCtx()
  for be, b in c.world:query(comps.Battle, jecs.pair(jecs.ChildOf, se)) do return be, b end
end

-- ---------------------------------------------------------------- one-shot reads (getgc, only on op "probe"/"setdeck")
local function userTable()
  local best
  for _, t in ipairs(getgc(true)) do
    if type(t) == "table" then pcall(function() if rawget(t, "player") == LP and rawget(t, "inventories") then best = t end end) end
  end
  return best
end
local function copyDeep(v, depth, seen)
  if type(v) ~= "table" then local tv = type(v) if tv == "number" or tv == "string" or tv == "boolean" then return v end return nil end
  if depth <= 0 or seen[v] then return nil end
  seen[v] = true
  local o = {}
  for k, x in pairs(v) do local c = copyDeep(x, depth - 1, seen) if c ~= nil then o[tostring(k)] = c end end
  seen[v] = nil
  return o
end
local function deckSlots(u)
  local out = {}
  local ok = pcall(function()
    for name in pairs(DECK_SLOTS) do out[name] = copyDeep(u.inventories.main.party.slots[name], 4, {}) end
  end)
  return out
end
local function at(tbl, pos) return tbl and (tbl[pos] or tbl[tostring(pos)]) end

-- ---------------------------------------------------------------- state publishing
local events = {}
local ack = nil
local function ev(kind, t) t = t or {} t.kind = kind t.at = now() table.insert(events, t) if #events > 30 then table.remove(events, 1) end end
local lastPub = 0
local function publish(force)
  if not force and os.clock() - lastPub < 0.2 then return end
  lastPub = os.clock()
  local se, s = session()
  local snap = { gen = GEN, t = now(), ping = LP:GetNetworkPing(), fires = fires, ack = ack, events = events }
  if se then
    snap.session = flat(s)
    local be, b = battleOf(se)
    if be then snap.battle = flat(b) end
  end
  writeJson(DIR .. "state.json", snap)
end

-- ---------------------------------------------------------------- watcher (events from cheap reads)
task.spawn(function()
  local seenSeed, battleUp, winnerSeen = nil, false, false
  while _G.__DT_STOP ~= true and _G.__DT_GEN == GEN do
    task.wait(0.1)
    local ok, err = pcall(function()
      local se, s = session()
      if not se then if battleUp then battleUp = false ev("battle_gone") end publish() return end
      local be, b = battleOf(se)
      if be and not battleUp then battleUp, winnerSeen = true, false ev("battle_start", { seed = b.seed, startedAt = b.startedAt, speed = b.speed, wave = s.wave, fight = s.fight, partyIndex = s.partyIndex }) end
      if be and b.winner ~= nil and not winnerSeen then winnerSeen = true ev("winner", { winner = b.winner, seed = b.seed }) end
      if not be and battleUp then battleUp = false ev("battle_gone", { wave = s.wave, fight = s.fight }) end
      publish()
    end)
    if not ok then ev("error", { err = tostring(err):sub(1, 200) }) task.wait(1) end
  end
end)

-- ---------------------------------------------------------------- timed fire
local function fireAtSecond(T, name, payload)
  while now() < T + OFFSET - 0.25 do if _G.__DT_STOP then return false, "stopped" end task.wait(0.05) end
  while now() < T + OFFSET do end
  local t = now()
  if t > T + OFFSET + LATE_MAX then return false, "late " .. string.format("%.2f", t - T) end
  local ok, err = send(name, payload)
  return ok, err, t
end

-- ---------------------------------------------------------------- ops
local ops = {}
local function A(...)
  if not remote("towerOfDeityAction") then return false, "no remote towerOfDeityAction" end
  return send("towerOfDeityAction", ...)
end

function ops.start(c)
  if not c.slots or #c.slots ~= 4 then return false, "need 4 slots" end
  for _, s in ipairs(c.slots) do if not DECK_SLOTS[s] then return false, "bad slot " .. tostring(s) end end
  local payload = { kind = "startTower", slots = c.slots, wave = c.wave }
  if c.towerId then payload.towerId = c.towerId end
  return fireAtSecond(c.at, "towerOfDeityAction", payload)
end
function ops.continue(c) return fireAtSecond(c.at, "towerOfDeityAction", { kind = "continueTower" }) end
function ops.select(c) return A({ kind = "selectTowerParty", party = c.party }) end
function ops.automation(c) return A({ kind = "setTowerAutomation", setting = c.setting, enabled = c.enabled == true }) end
function ops.abandon(c) return A({ kind = "abandonTower" }) end
function ops.upgrade(c)
  local ok = { Damage = true, Health = true, AwakenedDamage = true, AwakenedHealth = true }
  if not ok[c.what] then return false, "bad upgrade" end
  return A({ kind = "upgrade" .. c.what })
end
function ops.probe(c)
  local u = userTable()
  if not u then return false, "no user table" end
  local out = { t = now(), towerOfDeity = copyDeep(u.towerOfDeity, 7, {}), slots = deckSlots(u) }
  writeJson(DIR .. "probe.json", out)
  return true
end
function ops.setdeck(c)
  if not DECK_SLOTS[c.slot] then return false, "bad slot" end
  local u = userTable()
  if not u then return false, "no user table" end
  local function cur() local s = u.inventories.main.party.slots[c.slot] or { attack = {}, support = {} } return s end
  local s = cur()
  local diff = {}
  for pos = 1, 4 do
    local wa, ws = c.attack and at(c.attack, pos), c.support and at(c.support, pos)
    if at(s.attack, pos) ~= wa or at(s.support, pos) ~= ws then table.insert(diff, pos) end
  end
  for _, pos in ipairs(diff) do
    if at(s.attack, pos) then send("removeTowerOfDeityTeamPosition", c.slot, "attack", pos) task.wait(0.2) end
    if at(s.support, pos) then send("removeTowerOfDeityTeamPosition", c.slot, "support", pos) task.wait(0.2) end
  end
  for _, pos in ipairs(diff) do
    local wa, ws = c.attack and at(c.attack, pos), c.support and at(c.support, pos)
    if wa then send("setTowerOfDeityTeamPosition", c.slot, wa, pos) task.wait(0.2) end
    if ws then send("setTowerOfDeityTeamPosition", c.slot, ws, pos) task.wait(0.2) end
  end
  task.wait(2.5)
  local after = cur()
  for pos = 1, 4 do
    local wa, ws = c.attack and at(c.attack, pos), c.support and at(c.support, pos)
    if at(after.attack, pos) ~= wa or at(after.support, pos) ~= ws then return false, "deck mismatch at position " .. pos end
  end
  return true
end
function ops.stop(c) _G.__DT_STOP = true return true end

-- ---------------------------------------------------------------- command loop
task.spawn(function()
  local lastId = -1
  local first = readJson(DIR .. "cmd.json")
  if first and first.id then lastId = first.id end          -- never replay a command left over from an earlier run
  print("DT ready; ignoring cmd id <=", lastId)
  ev("ready", { lastId = lastId })
  publish(true)
  while _G.__DT_STOP ~= true and _G.__DT_GEN == GEN do
    task.wait(0.2)
    local c = readJson(DIR .. "cmd.json")
    if c and c.id and c.id > lastId then
      lastId = c.id
      local fn = ops[c.op]
      local ok, a, b, t
      if not fn then
        ok, a, b = true, false, "unknown op " .. tostring(c.op)
      else
        ok, a, b, t = pcall(fn, c)
      end
      -- pcall returns (true, success, err, firedAt) or (false, errmsg)
      local res = { id = c.id, op = c.op, ok = ok and a == true, err = (not ok) and tostring(a) or (a ~= true and tostring(b) or nil), firedAt = t, done = now() }
      ack = res
      ev("ack", res)
      print("DT", c.op, c.id, res.ok and "ok" or ("FAILED " .. tostring(res.err)))
      publish(true)
    end
  end
  ev("over") publish(true)
  print("DT over")
end)
