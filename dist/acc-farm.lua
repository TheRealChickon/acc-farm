-- Card Clash Farm, bundled by tools/bundle.py. Source: src/. Returns {[module] = source}.
local M = {}
M["core"] = [===[
-- Game access shared by every farm task. Same calls as the climbers in the Potassium workspace (climber.lua,
-- tower_climber.lua, story_climber.lua, tower_farm.lua), which were tested live on 2026-10-16/17.
-- Rules kept here so no task can break them: deck edits ONLY in slot_15, at least GAP seconds between two commands,
-- no __namecall hooks, no remote listeners, getgc only once at start and once after a deck change.
local RS = game:GetService("ReplicatedStorage")
local HS = game:GetService("HttpService")
local Stats = game:GetService("Stats")
local LP = game:GetService("Players").LocalPlayer

local core = { SLOT = "slot_15", GAP = 1.4, log = {}, status = "idle" }
local lastSend = 0
local remotes = {}

function core.say(...)
	local parts = {}
	for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
	local line = os.date("%H:%M:%S") .. "  " .. table.concat(parts, " ")
	table.insert(core.log, 1, line)
	if #core.log > 60 then table.remove(core.log) end
	print("[acc-farm] " .. line)
	if core.onLog then pcall(core.onLog, line) end
end

function core.stopped() return _G.__ACCF_STOP == true or (_G.__ACCF_GEN ~= nil and _G.__ACCF_GEN ~= core.gen) end

-- wait that gives up early when the farm is stopped; returns false if stopped
function core.wait(sec)
	local t0 = os.clock()
	while os.clock() - t0 < sec do
		if core.stopped() then return false end
		task.wait(math.min(0.5, sec))
	end
	return true
end

-- the newest started farm owns the game; an older loop (from an earlier execute) sees a newer gen and stops
function core.claim()
	_G.__ACCF_GEN = (_G.__ACCF_GEN or 0) + 1
	core.gen = _G.__ACCF_GEN
end

function core.init()
	if core.ctx then return true end
	core.comps = require(RS.shared.components)
	local ctx = _G.__ACC_CTX
	for _ = 1, 20 do
		if ctx then break end
		for _, t in ipairs(getgc(true)) do
			if type(t) == "table" then pcall(function() if rawget(t, "clientToServerEntities") ~= nil and rawget(t, "focusedBattleSession") ~= nil then ctx = t end end) end
		end
		if not ctx then task.wait(8) end
	end
	if not ctx then return false, "game context not found (is the game loaded?)" end
	_G.__ACC_CTX = ctx
	core.ctx = ctx
	local ok, t = pcall(function() return require(RS.common.time).EST_OFFSET_SECONDS end)
	core.EST = ok and t or (5 * 3600)
	return true
end

function core.remote(name)
	if remotes[name] then return remotes[name] end
	for _, d in ipairs(RS:GetDescendants()) do
		if d.Name == name and d:IsA("RemoteEvent") and not d:GetFullName():find("JABBY", 1, true) then remotes[name] = d return d end
	end
end

-- the only way any task sends a command
function core.send(name, ...)
	if core.dry then core.say("DRY", name, ...) return true end
	if not core.accountOk() then core.say("blocked: wrong account", LP.Name) return false end
	local r = core.remote(name)
	if not r then core.say("missing command", name) return false end
	local wait = core.GAP - (os.clock() - lastSend)
	if wait > 0 then task.wait(wait) end
	r:FireServer(...)
	lastSend = os.clock()
	return true
end

-- Settings "account" is a comma list of accounts the farm may run on ("" = any)
function core.accountOk()
	local allowed = core.settings and core.settings.account or "Whousleaks"
	if allowed == "" then return true end
	for name in string.gmatch(allowed, "[^,%s]+") do if name == LP.Name then return true end end
	return false
end
function core.isMain() return LP.Name == "Whousleaks" end

-- each account has its own folder for plans, heartbeats and PC-helper answers (both clients share one workspace):
-- Whousleaks = AnimeCardClash/ (as the climbers always used), Umson_42 = AnimeCardClash/umson/ (its own climber), others by name
function core.dir()
	if LP.Name == "Whousleaks" then return "AnimeCardClash/" end
	if LP.Name == "Umson_42" then return "AnimeCardClash/umson/" end
	return "AnimeCardClash/" .. string.lower(LP.Name) .. "/"
end

function core.mem() return Stats:GetTotalMemoryUsageMb() end
function core.now() return workspace:GetServerTimeNow() end
-- start of the current game day (rewards reset at midnight US Eastern, same as the game's useNextIntervalBoundaryEst)
function core.dayStart()
	local t = core.now() + core.EST
	return math.floor(t / 86400) * 86400 - core.EST
end

function core.user() return core.ctx.world:get(core.ctx.localUser(), core.comps.User) end
function core.place()
	local l = core.ctx.world:get(core.ctx.localUser(), core.comps.Location)
	return l and l.place
end
function core.backpack(domain)
	local u = core.user()
	local inv = u and u.inventories and u.inventories[domain or "main"]
	return inv and inv.backpack or {}
end

function core.sessions()
	local out, ents = {}, {}
	for e, v in core.ctx.world:query(core.comps.BattleSession) do table.insert(out, v) table.insert(ents, e) end
	return out, ents
end
function core.serverId(e) return core.ctx.clientToServerEntities[e] end
function core.hide(e)   -- hidden battles run at full speed
	local srv = core.serverId(e)
	if srv then core.send("setBattleSessionDisplayState", srv, "hidden") end
end
function core.forfeitAll()
	local _, ents = core.sessions()
	for _, e in ipairs(ents) do
		local srv = core.serverId(e)
		if srv then core.send("forfeitBattle", srv) core.say("ended old fight", srv) end
	end
	local t0 = os.clock()
	while #core.sessions() > 0 and os.clock() - t0 < 20 do task.wait(2) end
	return #core.sessions() == 0
end
-- waits until no fight is running (max sec); true when free
function core.waitFree(sec)
	local t0 = os.clock()
	while #core.sessions() > 0 and os.clock() - t0 < sec do if not core.wait(3) then return false end end
	return #core.sessions() == 0
end

-- ---------- files (executor workspace) ----------
function core.readJson(path)
	local ok, v = pcall(function() return HS:JSONDecode(readfile(path)) end)
	return ok and v or nil
end
function core.writeJson(path, v) pcall(writefile, path, HS:JSONEncode(v)) end

-- another script (the climbers) owns the game when its heartbeat is fresh: then the farm must not send anything
-- (the Deity helper's state.json counts too: it is written every few seconds while it runs)
local HEARTBEATS = { "story_heartbeat.json", "tower_climb_heartbeat.json", "tower_heartbeat.json", "deity/state.json" }
function core.otherScriptRunning()
	for _, name in ipairs(HEARTBEATS) do
		local f = core.dir() .. name
		local hb = core.readJson(f)
		if hb and type(hb.t) == "number" and os.time() - hb.t < 60 then return f end
	end
end

-- ---------- deck (slot_15 only) ----------
local function slotTable()
	local best
	for _, t in ipairs(getgc(true)) do
		if type(t) == "table" then pcall(function()
			if rawget(t, "player") == LP and rawget(t, "inventories") then
				local m = t.inventories.main
				if m and m.party and m.party.slots and m.party.slots[core.SLOT] then best = m.party.slots[core.SLOT] end
			end
		end) end
	end
	return best or { attack = {}, support = {} }
end
local function deckOf(s)
	local o = {}
	for pos = 1, 4 do o[pos] = { (s.attack and (s.attack[pos] or s.attack[tostring(pos)])) or "", (s.support and (s.support[pos] or s.support[tostring(pos)])) or "" } end
	return o
end
local function samePos(x, y) return (x and x[1] or "") == (y and y[1] or "") and (x and x[2] or "") == (y and y[2] or "") end
function core.sameDeck(a, b) for pos = 1, 4 do if not samePos(a[pos], b[pos]) then return false end end return true end
function core.deckText(d)
	local o = {}
	for pos = 1, 4 do local p = d[pos] table.insert(o, (p and p[1] ~= "" and p[1] or "-") .. (p and p[2] ~= "" and ("+" .. p[2]) or "")) end
	return table.concat(o, ", ")
end
function core.readDeck()
	core.deck = deckOf(slotTable())
	return core.deck
end
-- puts deck {{attack, support}, x4} into slot_15; only touches positions that differ; verifies with one scan
function core.setDeck(deck)
	if not core.deck then core.readDeck() end
	if core.sameDeck(core.deck, deck) then return true end
	for attempt = 1, 2 do
		local s = core.readDeck()
		local diff = {}
		for pos = 1, 4 do if not samePos(s[pos], deck[pos]) then table.insert(diff, pos) end end
		for _, pos in ipairs(diff) do
			if s[pos][1] ~= "" then core.send("removePartyPosition", core.SLOT, "attack", pos, "main") end
			if s[pos][2] ~= "" then core.send("removePartyPosition", core.SLOT, "support", pos, "main") end
		end
		for _, pos in ipairs(diff) do
			local want = deck[pos]
			if want and want[1] and want[1] ~= "" then core.send("setPartyPosition", core.SLOT, want[1], pos, "main") end
			if want and want[2] and want[2] ~= "" then core.send("setPartyPosition", core.SLOT, want[2], pos, "main") end
		end
		task.wait(2.5)
		if core.dry or core.sameDeck(core.readDeck(), deck) then core.deck = deck return true end
		core.say("deck not right yet, try", attempt)
	end
	return false
end

-- ---------- timed starts (optional; the PC helpers tower_watcher.py / story_scan_watcher.py answer these files) ----------
-- returns a server second to start on, or nil (start now)
function core.askTimes(needFile, answerFile, need, waitSec)
	local id = math.floor(core.now() * 10)
	need.id = id
	core.writeJson(needFile, need)
	local t0 = os.clock()
	while os.clock() - t0 < waitSec do
		if not core.wait(2) then return nil end
		local x = core.readJson(answerFile)
		if type(x) == "table" and x.id == id then return x end
	end
end
function core.waitUntil(T)
	while core.now() < T + 0.1 do task.wait(0.05) if core.stopped() then return false end end
	while core.now() < T + 0.35 do end
	return true
end

return core
]===]
M["data"] = [===[
-- Generated by tools/build_data.py from the macro's towers.json + story.json (game 9.6.0). Do not edit by hand.
return {
  difficulties = {"normal", "medium", "hard", "extreme", "nightmare", "celestial"},
  towers = {
    {id = "battle_tower", name = "Battle Tower", group = "main", waves = 50, floorsPerWave = 5, requires = nil, firstRolls = {["15"] = 500, ["22"] = 1000, ["23"] = 1000, ["24"] = 1000, ["25"] = 3000, ["26"] = 3000, ["27"] = 3000, ["28"] = 5000, ["29"] = 5000, ["30"] = 5000, ["31"] = 5000, ["32"] = 6000, ["33"] = 6000, ["34"] = 6000, ["35"] = 6000, ["36"] = 6000, ["37"] = 6000, ["38"] = 6000, ["39"] = 6000, ["40"] = 6000, ["41"] = 6000, ["42"] = 58000, ["43"] = 59000, ["44"] = 60000, ["45"] = 110000, ["46"] = 110000, ["47"] = 110000, ["48"] = 110000, ["49"] = 160000, ["50"] = 265000}, repeatRolls = {["27"] = 100, ["31"] = 100, ["36"] = 150, ["50"] = 200}},
    {id = "watery_depths", name = "Watery Depths Tower", group = "main", waves = 25, floorsPerWave = 10, requires = {mode = "battle_tower", wave = 50}, firstRolls = {["1"] = 30000, ["2"] = 50000, ["3"] = 80000, ["4"] = 80000, ["5"] = 80000, ["6"] = 80000, ["7"] = 80000, ["8"] = 80000, ["9"] = 80000, ["10"] = 50000, ["11"] = 50000, ["12"] = 100000, ["13"] = 100000, ["14"] = 100000, ["15"] = 100000, ["16"] = 100000, ["17"] = 100000, ["18"] = 100000, ["19"] = 100000, ["20"] = 250000, ["21"] = 150000, ["22"] = 150000, ["23"] = 150000, ["24"] = 150000, ["25"] = 350000}, repeatRolls = {["25"] = 70000}},
    {id = "frozen_landscape", name = "Frozen Landscape Tower", group = "main", waves = 25, floorsPerWave = 10, requires = {mode = "battle_tower", wave = 50}, firstRolls = {["1"] = 30000, ["2"] = 50000, ["3"] = 80000, ["4"] = 80000, ["5"] = 80000, ["6"] = 80000, ["7"] = 80000, ["8"] = 80000, ["9"] = 80000, ["10"] = 50000, ["11"] = 50000, ["12"] = 100000, ["13"] = 100000, ["14"] = 100000, ["15"] = 100000, ["16"] = 100000, ["17"] = 100000, ["18"] = 100000, ["19"] = 100000, ["20"] = 250000, ["21"] = 150000, ["22"] = 150000, ["23"] = 150000, ["24"] = 150000, ["25"] = 350000}, repeatRolls = {["25"] = 115000}},
    {id = "stone_citadel", name = "Stone Citadel Tower", group = "main", waves = 25, floorsPerWave = 10, requires = {mode = "frozen_landscape", wave = 20}, firstRolls = {["1"] = 50000, ["2"] = 50000, ["3"] = 80000, ["4"] = 80000, ["5"] = 80000, ["6"] = 100000, ["7"] = 100000, ["8"] = 100000, ["9"] = 100000, ["10"] = 100000, ["11"] = 150000, ["12"] = 150000, ["13"] = 150000, ["14"] = 150000, ["15"] = 150000, ["16"] = 150000, ["17"] = 150000, ["18"] = 150000, ["19"] = 150000, ["20"] = 300000, ["21"] = 150000, ["22"] = 150000, ["23"] = 150000, ["24"] = 150000, ["25"] = 600000}, repeatRolls = {["25"] = 120000}},
    {id = "inferno_depths", name = "Inferno Depths Tower", group = "main", waves = 25, floorsPerWave = 10, requires = {mode = "stone_citadel", wave = 20}, firstRolls = {["1"] = 50000, ["2"] = 50000, ["3"] = 50000, ["4"] = 50000, ["5"] = 50000, ["6"] = 50000, ["7"] = 50000, ["8"] = 50000, ["9"] = 100000, ["10"] = 100000, ["11"] = 100000, ["12"] = 100000, ["13"] = 150000, ["14"] = 150000, ["15"] = 250000, ["16"] = 150000, ["17"] = 150000, ["18"] = 150000, ["19"] = 150000, ["20"] = 150000, ["21"] = 150000, ["22"] = 150000, ["23"] = 150000, ["24"] = 150000, ["25"] = 800000}, repeatRolls = {["25"] = 150000}},
    {id = "lunar_eclipse", name = "Lunar Eclipse Tower", group = "main", waves = 25, floorsPerWave = 10, requires = {mode = "inferno_depths", wave = 15}, firstRolls = {["1"] = 50000, ["2"] = 50000, ["3"] = 50000, ["4"] = 50000, ["5"] = 150000, ["6"] = 150000, ["7"] = 150000, ["8"] = 150000, ["9"] = 150000, ["10"] = 250000, ["11"] = 150000, ["12"] = 150000, ["13"] = 150000, ["14"] = 150000, ["15"] = 300000, ["16"] = 150000, ["17"] = 150000, ["18"] = 150000, ["19"] = 150000, ["20"] = 150000, ["21"] = 150000, ["22"] = 150000, ["23"] = 150000, ["24"] = 150000, ["25"] = 1250000}, repeatRolls = {["25"] = 225000}},
    {id = "light_fairy", name = "Light Fairy Tower", group = "main", waves = 25, floorsPerWave = 10, requires = {mode = "lunar_eclipse", wave = 15}, firstRolls = {["1"] = 50000, ["2"] = 50000, ["3"] = 100000, ["4"] = 100000, ["5"] = 100000, ["6"] = 150000, ["7"] = 150000, ["8"] = 150000, ["9"] = 150000, ["10"] = 150000, ["11"] = 150000, ["12"] = 150000, ["13"] = 150000, ["14"] = 150000, ["15"] = 150000, ["16"] = 150000, ["17"] = 150000, ["18"] = 150000, ["19"] = 150000, ["20"] = 300000, ["21"] = 200000, ["22"] = 200000, ["23"] = 200000, ["24"] = 200000, ["25"] = 1750000}, repeatRolls = {["25"] = 270000}},
    {id = "rebels", name = "Rebels Tower", group = "main", waves = 25, floorsPerWave = 10, requires = {mode = "light_fairy", wave = 15}, firstRolls = {["1"] = 100000, ["2"] = 100000, ["3"] = 100000, ["4"] = 100000, ["5"] = 200000, ["6"] = 200000, ["7"] = 200000, ["8"] = 200000, ["9"] = 200000, ["10"] = 200000, ["11"] = 200000, ["12"] = 200000, ["13"] = 200000, ["14"] = 200000, ["15"] = 200000, ["16"] = 200000, ["17"] = 200000, ["18"] = 200000, ["19"] = 300000, ["20"] = 300000, ["21"] = 300000, ["22"] = 300000, ["23"] = 300000, ["24"] = 300000, ["25"] = 2500000}, repeatRolls = {["25"] = 300000}},
    {id = "android", name = "Android Tower", group = "main", waves = 25, floorsPerWave = 10, requires = {mode = "rebels", wave = 15}, firstRolls = {["1"] = 200000, ["2"] = 200000, ["3"] = 200000, ["4"] = 200000, ["5"] = 300000, ["6"] = 300000, ["7"] = 300000, ["8"] = 300000, ["9"] = 300000, ["10"] = 300000, ["11"] = 300000, ["12"] = 300000, ["13"] = 300000, ["14"] = 300000, ["15"] = 300000, ["16"] = 300000, ["17"] = 300000, ["18"] = 300000, ["19"] = 400000, ["20"] = 400000, ["21"] = 400000, ["22"] = 400000, ["23"] = 400000, ["24"] = 400000, ["25"] = 3000000}, repeatRolls = {["25"] = 350000}},
    {id = "tremor", name = "Tremor Tower", group = "main", waves = 25, floorsPerWave = 10, requires = {mode = "android", wave = 15}, firstRolls = {["1"] = 250000, ["2"] = 250000, ["3"] = 250000, ["4"] = 500000, ["5"] = 500000, ["6"] = 500000, ["7"] = 500000, ["8"] = 500000, ["9"] = 500000, ["10"] = 1000000, ["11"] = 1000000, ["12"] = 1000000, ["13"] = 1000000, ["14"] = 1000000, ["15"] = 1000000, ["16"] = 1500000, ["17"] = 1500000, ["18"] = 1500000, ["19"] = 1500000, ["20"] = 1500000, ["21"] = 2000000, ["22"] = 2000000, ["23"] = 2000000, ["24"] = 2000000, ["25"] = 5000000}, repeatRolls = {["25"] = 400000}},
    {id = "darkness", name = "Darkness Tower", group = "main", waves = 25, floorsPerWave = 10, requires = {mode = "tremor", wave = 15}, firstRolls = {["1"] = 500000, ["2"] = 500000, ["3"] = 500000, ["4"] = 500000, ["5"] = 500000, ["6"] = 1000000, ["7"] = 1000000, ["8"] = 1000000, ["9"] = 1000000, ["10"] = 1000000, ["11"] = 1500000, ["12"] = 1500000, ["13"] = 1500000, ["14"] = 1500000, ["15"] = 1500000, ["16"] = 2000000, ["17"] = 2000000, ["18"] = 2000000, ["19"] = 2000000, ["20"] = 2000000, ["21"] = 2500000, ["22"] = 2500000, ["23"] = 2500000, ["24"] = 2500000, ["25"] = 5000000}, repeatRolls = {["25"] = 450000}},
    {id = "forest", name = "Forest Tower", group = "main", waves = 25, floorsPerWave = 10, requires = {mode = "darkness", wave = 15}, firstRolls = {["1"] = 1000000, ["2"] = 1000000, ["3"] = 1000000, ["4"] = 1000000, ["5"] = 1000000, ["6"] = 1500000, ["7"] = 1500000, ["8"] = 1500000, ["9"] = 1500000, ["10"] = 1500000, ["11"] = 2000000, ["12"] = 2000000, ["13"] = 2000000, ["14"] = 2000000, ["15"] = 2000000, ["16"] = 3000000, ["17"] = 3000000, ["18"] = 3000000, ["19"] = 3000000, ["20"] = 3000000, ["21"] = 4000000, ["22"] = 4000000, ["23"] = 4000000, ["24"] = 4000000, ["25"] = 6500000}, repeatRolls = {["25"] = 500000}},
    {id = "toon_sleepy_gates", name = "Part 1: Sleepy Gates", group = "dream", waves = 10, floorsPerWave = 10, requires = nil, firstRolls = {["1"] = 500000, ["2"] = 500000, ["3"] = 500000, ["4"] = 500000, ["5"] = 500000, ["6"] = 500000, ["7"] = 500000, ["8"] = 500000, ["9"] = 500000, ["10"] = 500000}, repeatRolls = {}},
    {id = "toon_illusion_halls", name = "Part 2: Illusion Halls", group = "dream", waves = 10, floorsPerWave = 10, requires = nil, firstRolls = {["1"] = 800000, ["2"] = 800000, ["3"] = 800000, ["4"] = 800000, ["5"] = 800000, ["6"] = 800000, ["7"] = 800000, ["8"] = 800000, ["9"] = 800000, ["10"] = 800000}, repeatRolls = {}},
    {id = "toon_nightmare_garden", name = "Part 3: Nightmare Garden", group = "dream", waves = 10, floorsPerWave = 10, requires = nil, firstRolls = {["1"] = 1000000, ["2"] = 1000000, ["3"] = 1000000, ["4"] = 1000000, ["5"] = 1000000, ["6"] = 1000000, ["7"] = 1000000, ["8"] = 1000000, ["9"] = 1000000, ["10"] = 1000000}, repeatRolls = {}},
    {id = "toon_endless_dreamscape", name = "Part 4: Endless Dreamscape", group = "dream", waves = 10, floorsPerWave = 10, requires = nil, firstRolls = {["1"] = 2000000, ["2"] = 2000000, ["3"] = 2000000, ["4"] = 2000000, ["5"] = 2000000, ["6"] = 2000000, ["7"] = 2000000, ["8"] = 2000000, ["9"] = 2000000, ["10"] = 2000000}, repeatRolls = {}},
    {id = "toon_twisted_fantasy", name = "Part 5: Twisted Fantasy", group = "dream", waves = 10, floorsPerWave = 10, requires = nil, firstRolls = {["1"] = 2000000, ["2"] = 2000000, ["3"] = 2000000, ["4"] = 2000000, ["5"] = 2000000, ["6"] = 2000000, ["7"] = 2000000, ["8"] = 2000000, ["9"] = 2000000, ["10"] = 2000000}, repeatRolls = {}},
    {id = "toon_glamour_world", name = "Part 6: Glamour World", group = "dream", waves = 10, floorsPerWave = 10, requires = nil, firstRolls = {["1"] = 2000000, ["2"] = 2000000, ["3"] = 2000000, ["4"] = 2000000, ["5"] = 2000000, ["6"] = 2000000, ["7"] = 2000000, ["8"] = 2000000, ["9"] = 2000000, ["10"] = 2000000}, repeatRolls = {}},
    {id = "toon_part_7", name = "Part 7", group = "dream", waves = 1, floorsPerWave = 10, requires = nil, firstRolls = {}, repeatRolls = {}},
    {id = "mage_part_1", name = "Part 1", group = "mage", waves = 10, floorsPerWave = 10, requires = nil, firstRolls = {["1"] = 500000, ["2"] = 500000, ["3"] = 500000, ["4"] = 500000, ["5"] = 500000, ["6"] = 500000, ["7"] = 500000, ["8"] = 500000, ["9"] = 500000, ["10"] = 500000}, repeatRolls = {}},
    {id = "mage_part_2", name = "Part 2", group = "mage", waves = 10, floorsPerWave = 10, requires = nil, firstRolls = {["1"] = 500000, ["2"] = 500000, ["3"] = 500000, ["4"] = 500000, ["5"] = 500000, ["6"] = 500000, ["7"] = 500000, ["8"] = 500000, ["9"] = 500000, ["10"] = 500000}, repeatRolls = {}},
    {id = "mage_part_3", name = "Part 3", group = "mage", waves = 10, floorsPerWave = 10, requires = nil, firstRolls = {["1"] = 500000, ["2"] = 500000, ["3"] = 500000, ["4"] = 500000, ["5"] = 500000, ["6"] = 500000, ["7"] = 500000, ["8"] = 500000, ["9"] = 500000, ["10"] = 500000}, repeatRolls = {}},
    {id = "mage_part_4", name = "Part 4", group = "mage", waves = 10, floorsPerWave = 10, requires = nil, firstRolls = {["1"] = 1000000, ["2"] = 1000000, ["3"] = 1000000, ["4"] = 1000000, ["5"] = 1000000, ["6"] = 1000000, ["7"] = 1000000, ["8"] = 1000000, ["9"] = 1000000, ["10"] = 1000000}, repeatRolls = {}},
    {id = "mage_part_5", name = "Part 5", group = "mage", waves = 10, floorsPerWave = 10, requires = nil, firstRolls = {["1"] = 1000000, ["2"] = 1000000, ["3"] = 1000000, ["4"] = 1000000, ["5"] = 1000000, ["6"] = 1000000, ["7"] = 1000000, ["8"] = 1000000, ["9"] = 1000000, ["10"] = 1000000}, repeatRolls = {}},
    {id = "mage_part_6", name = "Part 6", group = "mage", waves = 10, floorsPerWave = 10, requires = nil, firstRolls = {["1"] = 1000000, ["2"] = 1000000, ["3"] = 1000000, ["4"] = 1000000, ["5"] = 1000000, ["6"] = 1000000, ["7"] = 1000000, ["8"] = 1000000, ["9"] = 1000000, ["10"] = 1000000}, repeatRolls = {}},
    {id = "mage_part_7", name = "Part 7", group = "mage", waves = 10, floorsPerWave = 10, requires = nil, firstRolls = {["1"] = 1500000, ["2"] = 1500000, ["3"] = 1500000, ["4"] = 1500000, ["5"] = 1500000, ["6"] = 1500000, ["7"] = 1500000, ["8"] = 1500000, ["9"] = 1500000, ["10"] = 1500000}, repeatRolls = {}},
    {id = "mage_part_8", name = "Part 8", group = "mage", waves = 10, floorsPerWave = 10, requires = nil, firstRolls = {["1"] = 1500000, ["2"] = 1500000, ["3"] = 1500000, ["4"] = 1500000, ["5"] = 1500000, ["6"] = 1500000, ["7"] = 1500000, ["8"] = 1500000, ["9"] = 1500000, ["10"] = 1500000}, repeatRolls = {}},
    {id = "mage_part_9", name = "Part 9", group = "mage", waves = 10, floorsPerWave = 10, requires = nil, firstRolls = {["1"] = 1500000, ["2"] = 1500000, ["3"] = 1500000, ["4"] = 1500000, ["5"] = 1500000, ["6"] = 1500000, ["7"] = 1500000, ["8"] = 1500000, ["9"] = 1500000, ["10"] = 1500000}, repeatRolls = {}},
    {id = "mage_part_10", name = "Part 10", group = "mage", waves = 10, floorsPerWave = 10, requires = nil, firstRolls = {["1"] = 2000000, ["2"] = 2000000, ["3"] = 2000000, ["4"] = 2000000, ["5"] = 2000000, ["6"] = 2000000, ["7"] = 2000000, ["8"] = 2000000, ["9"] = 2000000, ["10"] = 2000000}, repeatRolls = {}},
  },
  worlds = {
    {id = "ninja_village", name = "Ninja Village", crystal = "yellow_crystal", crystalFloor = nil, bosses = {normal = {{boss = "unstoppable_fist", name = "Unstoppable Fist", stage = 1, rolls = 0}, {boss = "copy_ninja", name = "Copy Ninja", stage = 2, rolls = 0}, {boss = "awakened_dark_avenger", name = "Awakened Dark Avenger", stage = 3, rolls = 0}, {boss = "awakened_promised_child", name = "Awakened Promised Child", stage = 4, rolls = 0}, {boss = "six_paths_of_pain", name = "Six Paths of Pain", stage = 5, rolls = 0}, {boss = "bijuu_beast", name = "Bijuu Beast", stage = 6, rolls = 500}}, medium = {{boss = "unstoppable_fist", name = "Unstoppable Fist", stage = 1, rolls = 0}, {boss = "copy_ninja", name = "Copy Ninja", stage = 2, rolls = 0}, {boss = "awakened_dark_avenger", name = "Awakened Dark Avenger", stage = 3, rolls = 0}, {boss = "awakened_promised_child", name = "Awakened Promised Child", stage = 4, rolls = 0}, {boss = "six_paths_of_pain", name = "Six Paths of Pain", stage = 5, rolls = 0}, {boss = "bijuu_beast", name = "Bijuu Beast", stage = 6, rolls = 1500}}, hard = {{boss = "unstoppable_fist", name = "Unstoppable Fist", stage = 1, rolls = 0}, {boss = "copy_ninja", name = "Copy Ninja", stage = 2, rolls = 0}, {boss = "awakened_dark_avenger", name = "Awakened Dark Avenger", stage = 3, rolls = 0}, {boss = "awakened_promised_child", name = "Awakened Promised Child", stage = 4, rolls = 0}, {boss = "six_paths_of_pain", name = "Six Paths of Pain", stage = 5, rolls = 0}, {boss = "bijuu_beast", name = "Bijuu Beast", stage = 6, rolls = 3500}}, extreme = {{boss = "unstoppable_fist", name = "Unstoppable Fist", stage = 1, rolls = 0}, {boss = "copy_ninja", name = "Copy Ninja", stage = 2, rolls = 0}, {boss = "awakened_dark_avenger", name = "Awakened Dark Avenger", stage = 3, rolls = 0}, {boss = "awakened_promised_child", name = "Awakened Promised Child", stage = 4, rolls = 0}, {boss = "six_paths_of_pain", name = "Six Paths of Pain", stage = 5, rolls = 0}, {boss = "bijuu_beast", name = "Bijuu Beast", stage = 6, rolls = 6500}}, nightmare = {{boss = "unstoppable_fist", name = "Unstoppable Fist", stage = 1, rolls = 0}, {boss = "copy_ninja", name = "Copy Ninja", stage = 2, rolls = 0}, {boss = "awakened_dark_avenger", name = "Awakened Dark Avenger", stage = 3, rolls = 0}, {boss = "awakened_promised_child", name = "Awakened Promised Child", stage = 4, rolls = 0}, {boss = "six_paths_of_pain", name = "Six Paths of Pain", stage = 5, rolls = 0}, {boss = "bijuu_beast", name = "Bijuu Beast", stage = 6, rolls = 10000}}, celestial = {{boss = "unstoppable_fist", name = "Unstoppable Fist", stage = 1, rolls = 0}, {boss = "copy_ninja", name = "Copy Ninja", stage = 2, rolls = 0}, {boss = "awakened_dark_avenger", name = "Awakened Dark Avenger", stage = 3, rolls = 0}, {boss = "awakened_promised_child", name = "Awakened Promised Child", stage = 4, rolls = 0}, {boss = "six_paths_of_pain", name = "Six Paths of Pain", stage = 5, rolls = 0}, {boss = "bijuu_beast", name = "Bijuu Beast", stage = 6, rolls = 14000}}}},
    {id = "green_planet", name = "Green Planet", crystal = "green_crystal", crystalFloor = nil, bosses = {normal = {{boss = "ultimate_warrior", name = "Ultimate Warrior", stage = 1, rolls = 0}, {boss = "body_switcher", name = "Body Switcher", stage = 2, rolls = 0}, {boss = "namekian_sage", name = "Namekian Sage", stage = 3, rolls = 0}, {boss = "awakened_prideful_prince", name = "Awakened Prideful Prince", stage = 4, rolls = 0}, {boss = "awakened_earth_strongest", name = "Awakened Earth's Strongest", stage = 5, rolls = 0}, {boss = "awakened_galactic_tyrant", name = "Awakened Galactic Tyrant", stage = 6, rolls = 500}}, medium = {{boss = "ultimate_warrior", name = "Ultimate Warrior", stage = 1, rolls = 0}, {boss = "body_switcher", name = "Body Switcher", stage = 2, rolls = 0}, {boss = "namekian_sage", name = "Namekian Sage", stage = 3, rolls = 0}, {boss = "awakened_prideful_prince", name = "Awakened Prideful Prince", stage = 4, rolls = 0}, {boss = "awakened_earth_strongest", name = "Awakened Earth's Strongest", stage = 5, rolls = 0}, {boss = "awakened_galactic_tyrant", name = "Awakened Galactic Tyrant", stage = 6, rolls = 1500}}, hard = {{boss = "ultimate_warrior", name = "Ultimate Warrior", stage = 1, rolls = 0}, {boss = "body_switcher", name = "Body Switcher", stage = 2, rolls = 0}, {boss = "namekian_sage", name = "Namekian Sage", stage = 3, rolls = 0}, {boss = "awakened_prideful_prince", name = "Awakened Prideful Prince", stage = 4, rolls = 0}, {boss = "awakened_earth_strongest", name = "Awakened Earth's Strongest", stage = 5, rolls = 0}, {boss = "awakened_galactic_tyrant", name = "Awakened Galactic Tyrant", stage = 6, rolls = 3500}}, extreme = {{boss = "ultimate_warrior", name = "Ultimate Warrior", stage = 1, rolls = 0}, {boss = "body_switcher", name = "Body Switcher", stage = 2, rolls = 0}, {boss = "namekian_sage", name = "Namekian Sage", stage = 3, rolls = 0}, {boss = "awakened_prideful_prince", name = "Awakened Prideful Prince", stage = 4, rolls = 0}, {boss = "awakened_earth_strongest", name = "Awakened Earth's Strongest", stage = 5, rolls = 0}, {boss = "awakened_galactic_tyrant", name = "Awakened Galactic Tyrant", stage = 6, rolls = 6500}}, nightmare = {{boss = "ultimate_warrior", name = "Ultimate Warrior", stage = 1, rolls = 0}, {boss = "body_switcher", name = "Body Switcher", stage = 2, rolls = 0}, {boss = "namekian_sage", name = "Namekian Sage", stage = 3, rolls = 0}, {boss = "awakened_prideful_prince", name = "Awakened Prideful Prince", stage = 4, rolls = 0}, {boss = "awakened_earth_strongest", name = "Awakened Earth's Strongest", stage = 5, rolls = 0}, {boss = "awakened_galactic_tyrant", name = "Awakened Galactic Tyrant", stage = 6, rolls = 10000}}, celestial = {{boss = "ultimate_warrior", name = "Ultimate Warrior", stage = 1, rolls = 0}, {boss = "body_switcher", name = "Body Switcher", stage = 2, rolls = 0}, {boss = "namekian_sage", name = "Namekian Sage", stage = 3, rolls = 0}, {boss = "awakened_prideful_prince", name = "Awakened Prideful Prince", stage = 4, rolls = 0}, {boss = "awakened_earth_strongest", name = "Awakened Earth's Strongest", stage = 5, rolls = 0}, {boss = "awakened_galactic_tyrant", name = "Awakened Galactic Tyrant", stage = 6, rolls = 14000}}}},
    {id = "shibuya_station", name = "Shibuya Station", crystal = "purple_crystal", crystalFloor = nil, bosses = {normal = {{boss = "cursed_doll", name = "Cursed Doll", stage = 1, rolls = 0}, {boss = "awakened_shadow_summoner", name = "Awakened Shadow Summoner", stage = 2, rolls = 0}, {boss = "cursed_fist", name = "Cursed Fist", stage = 3, rolls = 0}, {boss = "rika_blessing", name = "Rika's Blessing", stage = 4, rolls = 0}, {boss = "limitless_master", name = "Limitless Master", stage = 5, rolls = 0}, {boss = "king_of_curses", name = "King of Curses", stage = 6, rolls = 600}}, medium = {{boss = "cursed_doll", name = "Cursed Doll", stage = 1, rolls = 0}, {boss = "awakened_shadow_summoner", name = "Awakened Shadow Summoner", stage = 2, rolls = 0}, {boss = "cursed_fist", name = "Cursed Fist", stage = 3, rolls = 0}, {boss = "rika_blessing", name = "Rika's Blessing", stage = 4, rolls = 0}, {boss = "limitless_master", name = "Limitless Master", stage = 5, rolls = 0}, {boss = "king_of_curses", name = "King of Curses", stage = 6, rolls = 1800}}, hard = {{boss = "cursed_doll", name = "Cursed Doll", stage = 1, rolls = 0}, {boss = "awakened_shadow_summoner", name = "Awakened Shadow Summoner", stage = 2, rolls = 0}, {boss = "cursed_fist", name = "Cursed Fist", stage = 3, rolls = 0}, {boss = "rika_blessing", name = "Rika's Blessing", stage = 4, rolls = 0}, {boss = "limitless_master", name = "Limitless Master", stage = 5, rolls = 0}, {boss = "king_of_curses", name = "King of Curses", stage = 6, rolls = 4200}}, extreme = {{boss = "cursed_doll", name = "Cursed Doll", stage = 1, rolls = 0}, {boss = "awakened_shadow_summoner", name = "Awakened Shadow Summoner", stage = 2, rolls = 0}, {boss = "cursed_fist", name = "Cursed Fist", stage = 3, rolls = 0}, {boss = "rika_blessing", name = "Rika's Blessing", stage = 4, rolls = 0}, {boss = "limitless_master", name = "Limitless Master", stage = 5, rolls = 0}, {boss = "king_of_curses", name = "King of Curses", stage = 6, rolls = 7400}}, nightmare = {{boss = "cursed_doll", name = "Cursed Doll", stage = 1, rolls = 0}, {boss = "awakened_shadow_summoner", name = "Awakened Shadow Summoner", stage = 2, rolls = 0}, {boss = "cursed_fist", name = "Cursed Fist", stage = 3, rolls = 0}, {boss = "rika_blessing", name = "Rika's Blessing", stage = 4, rolls = 0}, {boss = "limitless_master", name = "Limitless Master", stage = 5, rolls = 0}, {boss = "king_of_curses", name = "King of Curses", stage = 6, rolls = 11900}}, celestial = {{boss = "cursed_doll", name = "Cursed Doll", stage = 1, rolls = 0}, {boss = "awakened_shadow_summoner", name = "Awakened Shadow Summoner", stage = 2, rolls = 0}, {boss = "cursed_fist", name = "Cursed Fist", stage = 3, rolls = 0}, {boss = "rika_blessing", name = "Rika's Blessing", stage = 4, rolls = 0}, {boss = "limitless_master", name = "Limitless Master", stage = 5, rolls = 0}, {boss = "king_of_curses", name = "King of Curses", stage = 6, rolls = 16900}}}},
    {id = "titans_city", name = "Titans City", crystal = "orange_crystal", crystalFloor = 25, bosses = {normal = {{boss = "survey_commander", name = "Survey Commander", stage = 1, rolls = 0}, {boss = "blade_warrior", name = "Blade Warrior", stage = 2, rolls = 0}, {boss = "armored_giant", name = "Armored Giant", stage = 3, rolls = 0}, {boss = "beast_giant", name = "Beast Giant", stage = 4, rolls = 0}, {boss = "blade_captain", name = "Blade Captain", stage = 5, rolls = 0}, {boss = "combat_giant", name = "Combat Giant", stage = 6, rolls = 1000}}, medium = {{boss = "survey_commander", name = "Survey Commander", stage = 1, rolls = 0}, {boss = "blade_warrior", name = "Blade Warrior", stage = 2, rolls = 0}, {boss = "armored_giant", name = "Armored Giant", stage = 3, rolls = 0}, {boss = "beast_giant", name = "Beast Giant", stage = 4, rolls = 0}, {boss = "blade_captain", name = "Blade Captain", stage = 5, rolls = 0}, {boss = "combat_giant", name = "Combat Giant", stage = 6, rolls = 2500}}, hard = {{boss = "survey_commander", name = "Survey Commander", stage = 1, rolls = 0}, {boss = "blade_warrior", name = "Blade Warrior", stage = 2, rolls = 0}, {boss = "armored_giant", name = "Armored Giant", stage = 3, rolls = 0}, {boss = "beast_giant", name = "Beast Giant", stage = 4, rolls = 0}, {boss = "blade_captain", name = "Blade Captain", stage = 5, rolls = 0}, {boss = "combat_giant", name = "Combat Giant", stage = 6, rolls = 5000}}, extreme = {{boss = "survey_commander", name = "Survey Commander", stage = 1, rolls = 0}, {boss = "blade_warrior", name = "Blade Warrior", stage = 2, rolls = 0}, {boss = "armored_giant", name = "Armored Giant", stage = 3, rolls = 0}, {boss = "beast_giant", name = "Beast Giant", stage = 4, rolls = 0}, {boss = "blade_captain", name = "Blade Captain", stage = 5, rolls = 0}, {boss = "combat_giant", name = "Combat Giant", stage = 6, rolls = 8500}}, nightmare = {{boss = "survey_commander", name = "Survey Commander", stage = 1, rolls = 0}, {boss = "blade_warrior", name = "Blade Warrior", stage = 2, rolls = 0}, {boss = "armored_giant", name = "Armored Giant", stage = 3, rolls = 0}, {boss = "beast_giant", name = "Beast Giant", stage = 4, rolls = 0}, {boss = "blade_captain", name = "Blade Captain", stage = 5, rolls = 0}, {boss = "combat_giant", name = "Combat Giant", stage = 6, rolls = 12500}}, celestial = {{boss = "survey_commander", name = "Survey Commander", stage = 1, rolls = 0}, {boss = "blade_warrior", name = "Blade Warrior", stage = 2, rolls = 0}, {boss = "armored_giant", name = "Armored Giant", stage = 3, rolls = 0}, {boss = "beast_giant", name = "Beast Giant", stage = 4, rolls = 0}, {boss = "blade_captain", name = "Blade Captain", stage = 5, rolls = 0}, {boss = "combat_giant", name = "Combat Giant", stage = 6, rolls = 17000}}}},
    {id = "dimensional_fortress", name = "Dimensional Fortress", crystal = "red_crystal", crystalFloor = 50, bosses = {normal = {{boss = "thunder_demon", name = "Thunder Demon", stage = 1, rolls = 0}, {boss = "childish_demon", name = "Childish Demon", stage = 2, rolls = 0}, {boss = "compass_demon", name = "Compass Demon", stage = 3, rolls = 0}, {boss = "awakened_frost_demon", name = "Awakened Frost Demon", stage = 4, rolls = 0}, {boss = "awakened_six_eyed_slayer", name = "Awakened Six-Eyed Slayer", stage = 5, rolls = 0}, {boss = "awakened_pale_demon_lord", name = "Awakened Pale Demon Lord", stage = 6, rolls = 1500}}, medium = {{boss = "thunder_demon", name = "Thunder Demon", stage = 1, rolls = 0}, {boss = "childish_demon", name = "Childish Demon", stage = 2, rolls = 0}, {boss = "compass_demon", name = "Compass Demon", stage = 3, rolls = 0}, {boss = "awakened_frost_demon", name = "Awakened Frost Demon", stage = 4, rolls = 0}, {boss = "awakened_six_eyed_slayer", name = "Awakened Six-Eyed Slayer", stage = 5, rolls = 0}, {boss = "awakened_pale_demon_lord", name = "Awakened Pale Demon Lord", stage = 6, rolls = 3500}}, hard = {{boss = "thunder_demon", name = "Thunder Demon", stage = 1, rolls = 0}, {boss = "childish_demon", name = "Childish Demon", stage = 2, rolls = 0}, {boss = "compass_demon", name = "Compass Demon", stage = 3, rolls = 0}, {boss = "awakened_frost_demon", name = "Awakened Frost Demon", stage = 4, rolls = 0}, {boss = "awakened_six_eyed_slayer", name = "Awakened Six-Eyed Slayer", stage = 5, rolls = 0}, {boss = "awakened_pale_demon_lord", name = "Awakened Pale Demon Lord", stage = 6, rolls = 6500}}, extreme = {{boss = "thunder_demon", name = "Thunder Demon", stage = 1, rolls = 0}, {boss = "childish_demon", name = "Childish Demon", stage = 2, rolls = 0}, {boss = "compass_demon", name = "Compass Demon", stage = 3, rolls = 0}, {boss = "awakened_frost_demon", name = "Awakened Frost Demon", stage = 4, rolls = 0}, {boss = "awakened_six_eyed_slayer", name = "Awakened Six-Eyed Slayer", stage = 5, rolls = 0}, {boss = "awakened_pale_demon_lord", name = "Awakened Pale Demon Lord", stage = 6, rolls = 10500}}, nightmare = {{boss = "thunder_demon", name = "Thunder Demon", stage = 1, rolls = 0}, {boss = "childish_demon", name = "Childish Demon", stage = 2, rolls = 0}, {boss = "compass_demon", name = "Compass Demon", stage = 3, rolls = 0}, {boss = "awakened_frost_demon", name = "Awakened Frost Demon", stage = 4, rolls = 0}, {boss = "awakened_six_eyed_slayer", name = "Awakened Six-Eyed Slayer", stage = 5, rolls = 0}, {boss = "awakened_pale_demon_lord", name = "Awakened Pale Demon Lord", stage = 6, rolls = 15100}}, celestial = {{boss = "thunder_demon", name = "Thunder Demon", stage = 1, rolls = 0}, {boss = "childish_demon", name = "Childish Demon", stage = 2, rolls = 0}, {boss = "compass_demon", name = "Compass Demon", stage = 3, rolls = 0}, {boss = "awakened_frost_demon", name = "Awakened Frost Demon", stage = 4, rolls = 0}, {boss = "awakened_six_eyed_slayer", name = "Awakened Six-Eyed Slayer", stage = 5, rolls = 0}, {boss = "awakened_pale_demon_lord", name = "Awakened Pale Demon Lord", stage = 6, rolls = 20100}}}},
    {id = "candy_island", name = "Candy Island", crystal = "white_crystal", crystalFloor = 75, bosses = {normal = {{boss = "genie_commander", name = "Genie Commander", stage = 1, rolls = 0}, {boss = "candy_master", name = "Candy Master", stage = 2, rolls = 0}, {boss = "biscuit_warrior", name = "Biscuit Warrior", stage = 3, rolls = 0}, {boss = "juice_queen", name = "Juice Queen", stage = 4, rolls = 0}, {boss = "mochi_emperor", name = "Mochi Emperor", stage = 5, rolls = 0}, {boss = "soul_queen", name = "Soul Queen", stage = 6, rolls = 1500}}, medium = {{boss = "genie_commander", name = "Genie Commander", stage = 1, rolls = 0}, {boss = "candy_master", name = "Candy Master", stage = 2, rolls = 0}, {boss = "biscuit_warrior", name = "Biscuit Warrior", stage = 3, rolls = 0}, {boss = "juice_queen", name = "Juice Queen", stage = 4, rolls = 0}, {boss = "mochi_emperor", name = "Mochi Emperor", stage = 5, rolls = 0}, {boss = "soul_queen", name = "Soul Queen", stage = 6, rolls = 3500}}, hard = {{boss = "genie_commander", name = "Genie Commander", stage = 1, rolls = 0}, {boss = "candy_master", name = "Candy Master", stage = 2, rolls = 0}, {boss = "biscuit_warrior", name = "Biscuit Warrior", stage = 3, rolls = 0}, {boss = "juice_queen", name = "Juice Queen", stage = 4, rolls = 0}, {boss = "mochi_emperor", name = "Mochi Emperor", stage = 5, rolls = 0}, {boss = "soul_queen", name = "Soul Queen", stage = 6, rolls = 6500}}, extreme = {{boss = "genie_commander", name = "Genie Commander", stage = 1, rolls = 0}, {boss = "candy_master", name = "Candy Master", stage = 2, rolls = 0}, {boss = "biscuit_warrior", name = "Biscuit Warrior", stage = 3, rolls = 0}, {boss = "juice_queen", name = "Juice Queen", stage = 4, rolls = 0}, {boss = "mochi_emperor", name = "Mochi Emperor", stage = 5, rolls = 0}, {boss = "soul_queen", name = "Soul Queen", stage = 6, rolls = 10500}}, nightmare = {{boss = "genie_commander", name = "Genie Commander", stage = 1, rolls = 0}, {boss = "candy_master", name = "Candy Master", stage = 2, rolls = 0}, {boss = "biscuit_warrior", name = "Biscuit Warrior", stage = 3, rolls = 0}, {boss = "juice_queen", name = "Juice Queen", stage = 4, rolls = 0}, {boss = "mochi_emperor", name = "Mochi Emperor", stage = 5, rolls = 0}, {boss = "soul_queen", name = "Soul Queen", stage = 6, rolls = 15000}}, celestial = {{boss = "genie_commander", name = "Genie Commander", stage = 1, rolls = 0}, {boss = "candy_master", name = "Candy Master", stage = 2, rolls = 0}, {boss = "biscuit_warrior", name = "Biscuit Warrior", stage = 3, rolls = 0}, {boss = "juice_queen", name = "Juice Queen", stage = 4, rolls = 0}, {boss = "mochi_emperor", name = "Mochi Emperor", stage = 5, rolls = 0}, {boss = "soul_queen", name = "Soul Queen", stage = 6, rolls = 20000}}}},
    {id = "solo_city", name = "Solo City", crystal = "regal_crystal", crystalFloor = 100, bosses = {normal = {{boss = "light_saintess", name = "Light Saintess", stage = 1, rolls = 0}, {boss = "the_goliath", name = "The Goliath", stage = 2, rolls = 0}, {boss = "shadow_bear", name = "Shadow Bear", stage = 3, rolls = 0}, {boss = "shadow_commander", name = "Shadow Commander", stage = 4, rolls = 0}, {boss = "shadow_ant", name = "Shadow Ant", stage = 5, rolls = 0}, {boss = "awakened_shadow_monarch", name = "Awakened Shadow Monarch", stage = 6, rolls = 2000}}, medium = {{boss = "light_saintess", name = "Light Saintess", stage = 1, rolls = 0}, {boss = "the_goliath", name = "The Goliath", stage = 2, rolls = 0}, {boss = "shadow_bear", name = "Shadow Bear", stage = 3, rolls = 0}, {boss = "shadow_commander", name = "Shadow Commander", stage = 4, rolls = 0}, {boss = "shadow_ant", name = "Shadow Ant", stage = 5, rolls = 0}, {boss = "awakened_shadow_monarch", name = "Awakened Shadow Monarch", stage = 6, rolls = 4500}}, hard = {{boss = "light_saintess", name = "Light Saintess", stage = 1, rolls = 0}, {boss = "the_goliath", name = "The Goliath", stage = 2, rolls = 0}, {boss = "shadow_bear", name = "Shadow Bear", stage = 3, rolls = 0}, {boss = "shadow_commander", name = "Shadow Commander", stage = 4, rolls = 0}, {boss = "shadow_ant", name = "Shadow Ant", stage = 5, rolls = 0}, {boss = "awakened_shadow_monarch", name = "Awakened Shadow Monarch", stage = 6, rolls = 8000}}, extreme = {{boss = "light_saintess", name = "Light Saintess", stage = 1, rolls = 0}, {boss = "the_goliath", name = "The Goliath", stage = 2, rolls = 0}, {boss = "shadow_bear", name = "Shadow Bear", stage = 3, rolls = 0}, {boss = "shadow_commander", name = "Shadow Commander", stage = 4, rolls = 0}, {boss = "shadow_ant", name = "Shadow Ant", stage = 5, rolls = 0}, {boss = "awakened_shadow_monarch", name = "Awakened Shadow Monarch", stage = 6, rolls = 12500}}, nightmare = {{boss = "light_saintess", name = "Light Saintess", stage = 1, rolls = 0}, {boss = "the_goliath", name = "The Goliath", stage = 2, rolls = 0}, {boss = "shadow_bear", name = "Shadow Bear", stage = 3, rolls = 0}, {boss = "shadow_commander", name = "Shadow Commander", stage = 4, rolls = 0}, {boss = "shadow_ant", name = "Shadow Ant", stage = 5, rolls = 0}, {boss = "awakened_shadow_monarch", name = "Awakened Shadow Monarch", stage = 6, rolls = 17500}}, celestial = {{boss = "light_saintess", name = "Light Saintess", stage = 1, rolls = 0}, {boss = "the_goliath", name = "The Goliath", stage = 2, rolls = 0}, {boss = "shadow_bear", name = "Shadow Bear", stage = 3, rolls = 0}, {boss = "shadow_commander", name = "Shadow Commander", stage = 4, rolls = 0}, {boss = "shadow_ant", name = "Shadow Ant", stage = 5, rolls = 0}, {boss = "awakened_shadow_monarch", name = "Awakened Shadow Monarch", stage = 6, rolls = 23000}}}},
    {id = "eminence_lookout", name = "Eminence Lookout", crystal = "emanating_black_crystal", crystalFloor = 125, bosses = {normal = {{boss = "eminence_accountant", name = "Eminence Accountant", stage = 1, rolls = 0}, {boss = "eminence_scout", name = "Eminence Scout", stage = 2, rolls = 0}, {boss = "eminence_strategist", name = "Eminence Strategist", stage = 3, rolls = 0}, {boss = "eminence_cat", name = "Eminence Cat", stage = 4, rolls = 0}, {boss = "eminence_commander", name = "Eminence Commander", stage = 5, rolls = 0}, {boss = "lord_of_eminence", name = "Lord of Eminence", stage = 6, rolls = 2000}}, medium = {{boss = "eminence_accountant", name = "Eminence Accountant", stage = 1, rolls = 0}, {boss = "eminence_scout", name = "Eminence Scout", stage = 2, rolls = 0}, {boss = "eminence_strategist", name = "Eminence Strategist", stage = 3, rolls = 0}, {boss = "eminence_cat", name = "Eminence Cat", stage = 4, rolls = 0}, {boss = "eminence_commander", name = "Eminence Commander", stage = 5, rolls = 0}, {boss = "lord_of_eminence", name = "Lord of Eminence", stage = 6, rolls = 4500}}, hard = {{boss = "eminence_accountant", name = "Eminence Accountant", stage = 1, rolls = 0}, {boss = "eminence_scout", name = "Eminence Scout", stage = 2, rolls = 0}, {boss = "eminence_strategist", name = "Eminence Strategist", stage = 3, rolls = 0}, {boss = "eminence_cat", name = "Eminence Cat", stage = 4, rolls = 0}, {boss = "eminence_commander", name = "Eminence Commander", stage = 5, rolls = 0}, {boss = "lord_of_eminence", name = "Lord of Eminence", stage = 6, rolls = 8000}}, extreme = {{boss = "eminence_accountant", name = "Eminence Accountant", stage = 1, rolls = 0}, {boss = "eminence_scout", name = "Eminence Scout", stage = 2, rolls = 0}, {boss = "eminence_strategist", name = "Eminence Strategist", stage = 3, rolls = 0}, {boss = "eminence_cat", name = "Eminence Cat", stage = 4, rolls = 0}, {boss = "eminence_commander", name = "Eminence Commander", stage = 5, rolls = 0}, {boss = "lord_of_eminence", name = "Lord of Eminence", stage = 6, rolls = 12500}}, nightmare = {{boss = "eminence_accountant", name = "Eminence Accountant", stage = 1, rolls = 0}, {boss = "eminence_scout", name = "Eminence Scout", stage = 2, rolls = 0}, {boss = "eminence_strategist", name = "Eminence Strategist", stage = 3, rolls = 0}, {boss = "eminence_cat", name = "Eminence Cat", stage = 4, rolls = 0}, {boss = "eminence_commander", name = "Eminence Commander", stage = 5, rolls = 0}, {boss = "lord_of_eminence", name = "Lord of Eminence", stage = 6, rolls = 17500}}, celestial = {{boss = "eminence_accountant", name = "Eminence Accountant", stage = 1, rolls = 0}, {boss = "eminence_scout", name = "Eminence Scout", stage = 2, rolls = 0}, {boss = "eminence_strategist", name = "Eminence Strategist", stage = 3, rolls = 0}, {boss = "eminence_cat", name = "Eminence Cat", stage = 4, rolls = 0}, {boss = "eminence_commander", name = "Eminence Commander", stage = 5, rolls = 0}, {boss = "lord_of_eminence", name = "Lord of Eminence", stage = 6, rolls = 23000}}}},
    {id = "invaded_ninja_village", name = "Invaded Ninja Village", crystal = "shadow_crystal", crystalFloor = 125, bosses = {normal = {{boss = "celestial_warrior", name = "Celestial Warrior", stage = 1, rolls = 0}, {boss = "mother_of_creation", name = "Mother of Creation", stage = 2, rolls = 0}, {boss = "celestial_fisherman", name = "Celestial Fisherman", stage = 3, rolls = 0}, {boss = "celestial_destroyer", name = "Celestial Destroyer", stage = 4, rolls = 0}, {boss = "awakened_impure_ghost", name = "Awakened Impure Ghost", stage = 5, rolls = 0}, {boss = "celestial_sovereign", name = "Celestial Sovereign", stage = 6, rolls = 2500}}, medium = {{boss = "celestial_warrior", name = "Celestial Warrior", stage = 1, rolls = 0}, {boss = "mother_of_creation", name = "Mother of Creation", stage = 2, rolls = 0}, {boss = "celestial_fisherman", name = "Celestial Fisherman", stage = 3, rolls = 0}, {boss = "celestial_destroyer", name = "Celestial Destroyer", stage = 4, rolls = 0}, {boss = "awakened_impure_ghost", name = "Awakened Impure Ghost", stage = 5, rolls = 0}, {boss = "celestial_sovereign", name = "Celestial Sovereign", stage = 6, rolls = 5500}}, hard = {{boss = "celestial_warrior", name = "Celestial Warrior", stage = 1, rolls = 0}, {boss = "mother_of_creation", name = "Mother of Creation", stage = 2, rolls = 0}, {boss = "celestial_fisherman", name = "Celestial Fisherman", stage = 3, rolls = 0}, {boss = "celestial_destroyer", name = "Celestial Destroyer", stage = 4, rolls = 0}, {boss = "awakened_impure_ghost", name = "Awakened Impure Ghost", stage = 5, rolls = 0}, {boss = "celestial_sovereign", name = "Celestial Sovereign", stage = 6, rolls = 9500}}, extreme = {{boss = "celestial_warrior", name = "Celestial Warrior", stage = 1, rolls = 0}, {boss = "mother_of_creation", name = "Mother of Creation", stage = 2, rolls = 0}, {boss = "celestial_fisherman", name = "Celestial Fisherman", stage = 3, rolls = 0}, {boss = "celestial_destroyer", name = "Celestial Destroyer", stage = 4, rolls = 0}, {boss = "awakened_impure_ghost", name = "Awakened Impure Ghost", stage = 5, rolls = 0}, {boss = "celestial_sovereign", name = "Celestial Sovereign", stage = 6, rolls = 14500}}, nightmare = {{boss = "celestial_warrior", name = "Celestial Warrior", stage = 1, rolls = 0}, {boss = "mother_of_creation", name = "Mother of Creation", stage = 2, rolls = 0}, {boss = "celestial_fisherman", name = "Celestial Fisherman", stage = 3, rolls = 0}, {boss = "celestial_destroyer", name = "Celestial Destroyer", stage = 4, rolls = 0}, {boss = "awakened_impure_ghost", name = "Awakened Impure Ghost", stage = 5, rolls = 0}, {boss = "celestial_sovereign", name = "Celestial Sovereign", stage = 6, rolls = 20000}}, celestial = {{boss = "celestial_warrior", name = "Celestial Warrior", stage = 1, rolls = 0}, {boss = "mother_of_creation", name = "Mother of Creation", stage = 2, rolls = 0}, {boss = "celestial_fisherman", name = "Celestial Fisherman", stage = 3, rolls = 0}, {boss = "celestial_destroyer", name = "Celestial Destroyer", stage = 4, rolls = 0}, {boss = "awakened_impure_ghost", name = "Awakened Impure Ghost", stage = 5, rolls = 0}, {boss = "celestial_sovereign", name = "Celestial Sovereign", stage = 6, rolls = 26000}}}},
    {id = "necromancer_graveyard", name = "Necromancer Graveyard", crystal = "grim_black_crystal", crystalFloor = 150, bosses = {normal = {{boss = "beast_tamer", name = "Beast Tamer", stage = 1, rolls = 0}, {boss = "servant_of_the_undead", name = "Servant of the Undead", stage = 2, rolls = 0}, {boss = "undead_demon", name = "Undead Demon", stage = 3, rolls = 0}, {boss = "undead_commander", name = "Undead Commander", stage = 4, rolls = 0}, {boss = "blood_valkyrie", name = "Blood Valkyrie", stage = 5, rolls = 0}, {boss = "undead_king", name = "Undead King", stage = 6, rolls = 2500}}, medium = {{boss = "beast_tamer", name = "Beast Tamer", stage = 1, rolls = 0}, {boss = "servant_of_the_undead", name = "Servant of the Undead", stage = 2, rolls = 0}, {boss = "undead_demon", name = "Undead Demon", stage = 3, rolls = 0}, {boss = "undead_commander", name = "Undead Commander", stage = 4, rolls = 0}, {boss = "blood_valkyrie", name = "Blood Valkyrie", stage = 5, rolls = 0}, {boss = "undead_king", name = "Undead King", stage = 6, rolls = 5500}}, hard = {{boss = "beast_tamer", name = "Beast Tamer", stage = 1, rolls = 0}, {boss = "servant_of_the_undead", name = "Servant of the Undead", stage = 2, rolls = 0}, {boss = "undead_demon", name = "Undead Demon", stage = 3, rolls = 0}, {boss = "undead_commander", name = "Undead Commander", stage = 4, rolls = 0}, {boss = "blood_valkyrie", name = "Blood Valkyrie", stage = 5, rolls = 0}, {boss = "undead_king", name = "Undead King", stage = 6, rolls = 9500}}, extreme = {{boss = "beast_tamer", name = "Beast Tamer", stage = 1, rolls = 0}, {boss = "servant_of_the_undead", name = "Servant of the Undead", stage = 2, rolls = 0}, {boss = "undead_demon", name = "Undead Demon", stage = 3, rolls = 0}, {boss = "undead_commander", name = "Undead Commander", stage = 4, rolls = 0}, {boss = "blood_valkyrie", name = "Blood Valkyrie", stage = 5, rolls = 0}, {boss = "undead_king", name = "Undead King", stage = 6, rolls = 14500}}, nightmare = {{boss = "beast_tamer", name = "Beast Tamer", stage = 1, rolls = 0}, {boss = "servant_of_the_undead", name = "Servant of the Undead", stage = 2, rolls = 0}, {boss = "undead_demon", name = "Undead Demon", stage = 3, rolls = 0}, {boss = "undead_commander", name = "Undead Commander", stage = 4, rolls = 0}, {boss = "blood_valkyrie", name = "Blood Valkyrie", stage = 5, rolls = 0}, {boss = "undead_king", name = "Undead King", stage = 6, rolls = 20000}}, celestial = {{boss = "beast_tamer", name = "Beast Tamer", stage = 1, rolls = 0}, {boss = "servant_of_the_undead", name = "Servant of the Undead", stage = 2, rolls = 0}, {boss = "undead_demon", name = "Undead Demon", stage = 3, rolls = 0}, {boss = "undead_commander", name = "Undead Commander", stage = 4, rolls = 0}, {boss = "blood_valkyrie", name = "Blood Valkyrie", stage = 5, rolls = 0}, {boss = "undead_king", name = "Undead King", stage = 6, rolls = 26000}}}},
    {id = "soul_king_castle", name = "Soul King Castle", crystal = "teal_crystal", crystalFloor = 150, bosses = {normal = {{boss = "hornet_shinigami", name = "Hornet Shinigami", stage = 1, rolls = 0}, {boss = "shinigami_strategist", name = "Shinigami Strategist", stage = 2, rolls = 0}, {boss = "shinigami_illusionist", name = "Shinigami Illusionist", stage = 3, rolls = 0}, {boss = "fate_weaver_shinigami", name = "Fate Weaver Shinigami", stage = 4, rolls = 0}, {boss = "shinigami_monk", name = "Shinigami Monk", stage = 5, rolls = 0}, {boss = "substitute_shinigami", name = "Substitute Shinigami", stage = 6, rolls = 3000}}, medium = {{boss = "hornet_shinigami", name = "Hornet Shinigami", stage = 1, rolls = 0}, {boss = "shinigami_strategist", name = "Shinigami Strategist", stage = 2, rolls = 0}, {boss = "shinigami_illusionist", name = "Shinigami Illusionist", stage = 3, rolls = 0}, {boss = "fate_weaver_shinigami", name = "Fate Weaver Shinigami", stage = 4, rolls = 0}, {boss = "shinigami_monk", name = "Shinigami Monk", stage = 5, rolls = 0}, {boss = "substitute_shinigami", name = "Substitute Shinigami", stage = 6, rolls = 6500}}, hard = {{boss = "hornet_shinigami", name = "Hornet Shinigami", stage = 1, rolls = 0}, {boss = "shinigami_strategist", name = "Shinigami Strategist", stage = 2, rolls = 0}, {boss = "shinigami_illusionist", name = "Shinigami Illusionist", stage = 3, rolls = 0}, {boss = "fate_weaver_shinigami", name = "Fate Weaver Shinigami", stage = 4, rolls = 0}, {boss = "shinigami_monk", name = "Shinigami Monk", stage = 5, rolls = 0}, {boss = "substitute_shinigami", name = "Substitute Shinigami", stage = 6, rolls = 11000}}, extreme = {{boss = "hornet_shinigami", name = "Hornet Shinigami", stage = 1, rolls = 0}, {boss = "shinigami_strategist", name = "Shinigami Strategist", stage = 2, rolls = 0}, {boss = "shinigami_illusionist", name = "Shinigami Illusionist", stage = 3, rolls = 0}, {boss = "fate_weaver_shinigami", name = "Fate Weaver Shinigami", stage = 4, rolls = 0}, {boss = "shinigami_monk", name = "Shinigami Monk", stage = 5, rolls = 0}, {boss = "substitute_shinigami", name = "Substitute Shinigami", stage = 6, rolls = 16500}}, nightmare = {{boss = "hornet_shinigami", name = "Hornet Shinigami", stage = 1, rolls = 0}, {boss = "shinigami_strategist", name = "Shinigami Strategist", stage = 2, rolls = 0}, {boss = "shinigami_illusionist", name = "Shinigami Illusionist", stage = 3, rolls = 0}, {boss = "fate_weaver_shinigami", name = "Fate Weaver Shinigami", stage = 4, rolls = 0}, {boss = "shinigami_monk", name = "Shinigami Monk", stage = 5, rolls = 0}, {boss = "substitute_shinigami", name = "Substitute Shinigami", stage = 6, rolls = 22500}}, celestial = {{boss = "hornet_shinigami", name = "Hornet Shinigami", stage = 1, rolls = 0}, {boss = "shinigami_strategist", name = "Shinigami Strategist", stage = 2, rolls = 0}, {boss = "shinigami_illusionist", name = "Shinigami Illusionist", stage = 3, rolls = 0}, {boss = "fate_weaver_shinigami", name = "Fate Weaver Shinigami", stage = 4, rolls = 0}, {boss = "shinigami_monk", name = "Shinigami Monk", stage = 5, rolls = 0}, {boss = "substitute_shinigami", name = "Substitute Shinigami", stage = 6, rolls = 29000}}}},
    {id = "empire_of_light", name = "Empire of Light", crystal = "almighty_crystal", crystalFloor = 150, bosses = {normal = {{boss = "the_visionary", name = "The Visionary", stage = 1, rolls = 0}, {boss = "the_antithesis", name = "The Antithesis", stage = 2, rolls = 0}, {boss = "the_x_axis", name = "The X-Axis", stage = 3, rolls = 0}, {boss = "the_miracle", name = "The Miracle", stage = 4, rolls = 0}, {boss = "the_balance", name = "The Balance", stage = 5, rolls = 0}, {boss = "quincy_king", name = "Quincy King", stage = 6, rolls = 3000}}, medium = {{boss = "the_visionary", name = "The Visionary", stage = 1, rolls = 0}, {boss = "the_antithesis", name = "The Antithesis", stage = 2, rolls = 0}, {boss = "the_x_axis", name = "The X-Axis", stage = 3, rolls = 0}, {boss = "the_miracle", name = "The Miracle", stage = 4, rolls = 0}, {boss = "the_balance", name = "The Balance", stage = 5, rolls = 0}, {boss = "quincy_king", name = "Quincy King", stage = 6, rolls = 6500}}, hard = {{boss = "the_visionary", name = "The Visionary", stage = 1, rolls = 0}, {boss = "the_antithesis", name = "The Antithesis", stage = 2, rolls = 0}, {boss = "the_x_axis", name = "The X-Axis", stage = 3, rolls = 0}, {boss = "the_miracle", name = "The Miracle", stage = 4, rolls = 0}, {boss = "the_balance", name = "The Balance", stage = 5, rolls = 0}, {boss = "quincy_king", name = "Quincy King", stage = 6, rolls = 11000}}, extreme = {{boss = "the_visionary", name = "The Visionary", stage = 1, rolls = 0}, {boss = "the_antithesis", name = "The Antithesis", stage = 2, rolls = 0}, {boss = "the_x_axis", name = "The X-Axis", stage = 3, rolls = 0}, {boss = "the_miracle", name = "The Miracle", stage = 4, rolls = 0}, {boss = "the_balance", name = "The Balance", stage = 5, rolls = 0}, {boss = "quincy_king", name = "Quincy King", stage = 6, rolls = 16500}}, nightmare = {{boss = "the_visionary", name = "The Visionary", stage = 1, rolls = 0}, {boss = "the_antithesis", name = "The Antithesis", stage = 2, rolls = 0}, {boss = "the_x_axis", name = "The X-Axis", stage = 3, rolls = 0}, {boss = "the_miracle", name = "The Miracle", stage = 4, rolls = 0}, {boss = "the_balance", name = "The Balance", stage = 5, rolls = 0}, {boss = "quincy_king", name = "Quincy King", stage = 6, rolls = 22500}}, celestial = {{boss = "the_visionary", name = "The Visionary", stage = 1, rolls = 0}, {boss = "the_antithesis", name = "The Antithesis", stage = 2, rolls = 0}, {boss = "the_x_axis", name = "The X-Axis", stage = 3, rolls = 0}, {boss = "the_miracle", name = "The Miracle", stage = 4, rolls = 0}, {boss = "the_balance", name = "The Balance", stage = 5, rolls = 0}, {boss = "quincy_king", name = "Quincy King", stage = 6, rolls = 29000}}}},
    {id = "defense_force_base", name = "Defense Force Base", crystal = "kaiju_crystal", crystalFloor = 150, bosses = {normal = {{boss = "frostbite_soldier", name = "Frostbite Soldier", stage = 1, rolls = 0}, {boss = "eightfold_slayer", name = "Eightfold Slayer", stage = 2, rolls = 0}, {boss = "gun_blade_hunter", name = "Gun Blade Hunter", stage = 3, rolls = 0}, {boss = "defense_force_captain", name = "Defense Force Captain", stage = 4, rolls = 0}, {boss = "defense_force_heiress", name = "Defense Force Heiress", stage = 5, rolls = 0}, {boss = "monster_10", name = "Monster 10", stage = 6, rolls = 0}, {boss = "humanitys_weapon", name = "Humanity's Weapon", stage = 7, rolls = 3500}}, medium = {{boss = "frostbite_soldier", name = "Frostbite Soldier", stage = 1, rolls = 0}, {boss = "eightfold_slayer", name = "Eightfold Slayer", stage = 2, rolls = 0}, {boss = "gun_blade_hunter", name = "Gun Blade Hunter", stage = 3, rolls = 0}, {boss = "defense_force_captain", name = "Defense Force Captain", stage = 4, rolls = 0}, {boss = "defense_force_heiress", name = "Defense Force Heiress", stage = 5, rolls = 0}, {boss = "monster_10", name = "Monster 10", stage = 6, rolls = 0}, {boss = "humanitys_weapon", name = "Humanity's Weapon", stage = 7, rolls = 7500}}, hard = {{boss = "frostbite_soldier", name = "Frostbite Soldier", stage = 1, rolls = 0}, {boss = "eightfold_slayer", name = "Eightfold Slayer", stage = 2, rolls = 0}, {boss = "gun_blade_hunter", name = "Gun Blade Hunter", stage = 3, rolls = 0}, {boss = "defense_force_captain", name = "Defense Force Captain", stage = 4, rolls = 0}, {boss = "defense_force_heiress", name = "Defense Force Heiress", stage = 5, rolls = 0}, {boss = "monster_10", name = "Monster 10", stage = 6, rolls = 0}, {boss = "humanitys_weapon", name = "Humanity's Weapon", stage = 7, rolls = 12500}}, extreme = {{boss = "frostbite_soldier", name = "Frostbite Soldier", stage = 1, rolls = 0}, {boss = "eightfold_slayer", name = "Eightfold Slayer", stage = 2, rolls = 0}, {boss = "gun_blade_hunter", name = "Gun Blade Hunter", stage = 3, rolls = 0}, {boss = "defense_force_captain", name = "Defense Force Captain", stage = 4, rolls = 0}, {boss = "defense_force_heiress", name = "Defense Force Heiress", stage = 5, rolls = 0}, {boss = "monster_10", name = "Monster 10", stage = 6, rolls = 0}, {boss = "humanitys_weapon", name = "Humanity's Weapon", stage = 7, rolls = 18500}}, nightmare = {{boss = "frostbite_soldier", name = "Frostbite Soldier", stage = 1, rolls = 0}, {boss = "eightfold_slayer", name = "Eightfold Slayer", stage = 2, rolls = 0}, {boss = "gun_blade_hunter", name = "Gun Blade Hunter", stage = 3, rolls = 0}, {boss = "defense_force_captain", name = "Defense Force Captain", stage = 4, rolls = 0}, {boss = "defense_force_heiress", name = "Defense Force Heiress", stage = 5, rolls = 0}, {boss = "monster_10", name = "Monster 10", stage = 6, rolls = 0}, {boss = "humanitys_weapon", name = "Humanity's Weapon", stage = 7, rolls = 25000}}, celestial = {{boss = "frostbite_soldier", name = "Frostbite Soldier", stage = 1, rolls = 0}, {boss = "eightfold_slayer", name = "Eightfold Slayer", stage = 2, rolls = 0}, {boss = "gun_blade_hunter", name = "Gun Blade Hunter", stage = 3, rolls = 0}, {boss = "defense_force_captain", name = "Defense Force Captain", stage = 4, rolls = 0}, {boss = "defense_force_heiress", name = "Defense Force Heiress", stage = 5, rolls = 0}, {boss = "monster_10", name = "Monster 10", stage = 6, rolls = 0}, {boss = "humanitys_weapon", name = "Humanity's Weapon", stage = 7, rolls = 32000}}}},
    {id = "slime_city", name = "Slime City", crystal = "slime_crystal", crystalFloor = 150, bosses = {normal = {{boss = "oni_princess", name = "Oni Princess", stage = 1, rolls = 0}, {boss = "oni_shinobi", name = "Oni Shinobi", stage = 2, rolls = 0}, {boss = "oni_tyrant", name = "Oni Tyrant", stage = 3, rolls = 0}, {boss = "oni_king", name = "Oni King", stage = 4, rolls = 0}, {boss = "storm_dragon", name = "Storm Dragon", stage = 5, rolls = 0}, {boss = "awakened_blue_slime", name = "Awakened Blue Slime", stage = 6, rolls = 4000}}, medium = {{boss = "oni_princess", name = "Oni Princess", stage = 1, rolls = 0}, {boss = "oni_shinobi", name = "Oni Shinobi", stage = 2, rolls = 0}, {boss = "oni_tyrant", name = "Oni Tyrant", stage = 3, rolls = 0}, {boss = "oni_king", name = "Oni King", stage = 4, rolls = 0}, {boss = "storm_dragon", name = "Storm Dragon", stage = 5, rolls = 0}, {boss = "awakened_blue_slime", name = "Awakened Blue Slime", stage = 6, rolls = 8500}}, hard = {{boss = "oni_princess", name = "Oni Princess", stage = 1, rolls = 0}, {boss = "oni_shinobi", name = "Oni Shinobi", stage = 2, rolls = 0}, {boss = "oni_tyrant", name = "Oni Tyrant", stage = 3, rolls = 0}, {boss = "oni_king", name = "Oni King", stage = 4, rolls = 0}, {boss = "storm_dragon", name = "Storm Dragon", stage = 5, rolls = 0}, {boss = "awakened_blue_slime", name = "Awakened Blue Slime", stage = 6, rolls = 14000}}, extreme = {{boss = "oni_princess", name = "Oni Princess", stage = 1, rolls = 0}, {boss = "oni_shinobi", name = "Oni Shinobi", stage = 2, rolls = 0}, {boss = "oni_tyrant", name = "Oni Tyrant", stage = 3, rolls = 0}, {boss = "oni_king", name = "Oni King", stage = 4, rolls = 0}, {boss = "storm_dragon", name = "Storm Dragon", stage = 5, rolls = 0}, {boss = "awakened_blue_slime", name = "Awakened Blue Slime", stage = 6, rolls = 20500}}, nightmare = {{boss = "oni_princess", name = "Oni Princess", stage = 1, rolls = 0}, {boss = "oni_shinobi", name = "Oni Shinobi", stage = 2, rolls = 0}, {boss = "oni_tyrant", name = "Oni Tyrant", stage = 3, rolls = 0}, {boss = "oni_king", name = "Oni King", stage = 4, rolls = 0}, {boss = "storm_dragon", name = "Storm Dragon", stage = 5, rolls = 0}, {boss = "awakened_blue_slime", name = "Awakened Blue Slime", stage = 6, rolls = 27500}}, celestial = {{boss = "oni_princess", name = "Oni Princess", stage = 1, rolls = 0}, {boss = "oni_shinobi", name = "Oni Shinobi", stage = 2, rolls = 0}, {boss = "oni_tyrant", name = "Oni Tyrant", stage = 3, rolls = 0}, {boss = "oni_king", name = "Oni King", stage = 4, rolls = 0}, {boss = "storm_dragon", name = "Storm Dragon", stage = 5, rolls = 0}, {boss = "awakened_blue_slime", name = "Awakened Blue Slime", stage = 6, rolls = 35000}}}},
    {id = "heros_palace", name = "Hero's Palace", crystal = "hero_crystal", crystalFloor = 150, bosses = {normal = {{boss = "silent_assassin", name = "Silent Assassin", stage = 1, rolls = 0}, {boss = "knight_of_conquest", name = "Knight of Conquest", stage = 2, rolls = 0}, {boss = "unstoppable_warrior", name = "Unstoppable Warrior", stage = 3, rolls = 0}, {boss = "honorbound_hero", name = "Honorbound Hero", stage = 4, rolls = 0}, {boss = "divine_weapon", name = "Divine Weapon", stage = 5, rolls = 0}, {boss = "lunar_hero", name = "Lunar Hero", stage = 6, rolls = 0}, {boss = "king_of_heroes", name = "King of Heroes", stage = 7, rolls = 4500}}, medium = {{boss = "silent_assassin", name = "Silent Assassin", stage = 1, rolls = 0}, {boss = "knight_of_conquest", name = "Knight of Conquest", stage = 2, rolls = 0}, {boss = "unstoppable_warrior", name = "Unstoppable Warrior", stage = 3, rolls = 0}, {boss = "honorbound_hero", name = "Honorbound Hero", stage = 4, rolls = 0}, {boss = "divine_weapon", name = "Divine Weapon", stage = 5, rolls = 0}, {boss = "lunar_hero", name = "Lunar Hero", stage = 6, rolls = 0}, {boss = "king_of_heroes", name = "King of Heroes", stage = 7, rolls = 9500}}, hard = {{boss = "silent_assassin", name = "Silent Assassin", stage = 1, rolls = 0}, {boss = "knight_of_conquest", name = "Knight of Conquest", stage = 2, rolls = 0}, {boss = "unstoppable_warrior", name = "Unstoppable Warrior", stage = 3, rolls = 0}, {boss = "honorbound_hero", name = "Honorbound Hero", stage = 4, rolls = 0}, {boss = "divine_weapon", name = "Divine Weapon", stage = 5, rolls = 0}, {boss = "lunar_hero", name = "Lunar Hero", stage = 6, rolls = 0}, {boss = "king_of_heroes", name = "King of Heroes", stage = 7, rolls = 15500}}, extreme = {{boss = "silent_assassin", name = "Silent Assassin", stage = 1, rolls = 0}, {boss = "knight_of_conquest", name = "Knight of Conquest", stage = 2, rolls = 0}, {boss = "unstoppable_warrior", name = "Unstoppable Warrior", stage = 3, rolls = 0}, {boss = "honorbound_hero", name = "Honorbound Hero", stage = 4, rolls = 0}, {boss = "divine_weapon", name = "Divine Weapon", stage = 5, rolls = 0}, {boss = "lunar_hero", name = "Lunar Hero", stage = 6, rolls = 0}, {boss = "king_of_heroes", name = "King of Heroes", stage = 7, rolls = 22500}}, nightmare = {{boss = "silent_assassin", name = "Silent Assassin", stage = 1, rolls = 0}, {boss = "knight_of_conquest", name = "Knight of Conquest", stage = 2, rolls = 0}, {boss = "unstoppable_warrior", name = "Unstoppable Warrior", stage = 3, rolls = 0}, {boss = "honorbound_hero", name = "Honorbound Hero", stage = 4, rolls = 0}, {boss = "divine_weapon", name = "Divine Weapon", stage = 5, rolls = 0}, {boss = "lunar_hero", name = "Lunar Hero", stage = 6, rolls = 0}, {boss = "king_of_heroes", name = "King of Heroes", stage = 7, rolls = 30000}}, celestial = {{boss = "silent_assassin", name = "Silent Assassin", stage = 1, rolls = 0}, {boss = "knight_of_conquest", name = "Knight of Conquest", stage = 2, rolls = 0}, {boss = "unstoppable_warrior", name = "Unstoppable Warrior", stage = 3, rolls = 0}, {boss = "honorbound_hero", name = "Honorbound Hero", stage = 4, rolls = 0}, {boss = "divine_weapon", name = "Divine Weapon", stage = 5, rolls = 0}, {boss = "lunar_hero", name = "Lunar Hero", stage = 6, rolls = 0}, {boss = "king_of_heroes", name = "King of Heroes", stage = 7, rolls = 38000}}}},
    {id = "knight_kingdom", name = "Knight Kingdom", crystal = "wrathful_crystal", crystalFloor = 150, bosses = {normal = {{boss = "envious_sin", name = "Envious Sin", stage = 1, rolls = 0}, {boss = "impure_sin", name = "Impure Sin", stage = 2, rolls = 0}, {boss = "slothful_sin", name = "Slothful Sin", stage = 3, rolls = 0}, {boss = "gluttonous_sin", name = "Gluttonous Sin", stage = 4, rolls = 0}, {boss = "fox_sin", name = "Fox Sin", stage = 5, rolls = 0}, {boss = "awakened_sun_lion", name = "Awakened Sun Lion", stage = 6, rolls = 0}, {boss = "wrathful_sin", name = "Wrathful Sin", stage = 7, rolls = 5000}}, medium = {{boss = "envious_sin", name = "Envious Sin", stage = 1, rolls = 0}, {boss = "impure_sin", name = "Impure Sin", stage = 2, rolls = 0}, {boss = "slothful_sin", name = "Slothful Sin", stage = 3, rolls = 0}, {boss = "gluttonous_sin", name = "Gluttonous Sin", stage = 4, rolls = 0}, {boss = "fox_sin", name = "Fox Sin", stage = 5, rolls = 0}, {boss = "awakened_sun_lion", name = "Awakened Sun Lion", stage = 6, rolls = 0}, {boss = "wrathful_sin", name = "Wrathful Sin", stage = 7, rolls = 10000}}, hard = {{boss = "envious_sin", name = "Envious Sin", stage = 1, rolls = 0}, {boss = "impure_sin", name = "Impure Sin", stage = 2, rolls = 0}, {boss = "slothful_sin", name = "Slothful Sin", stage = 3, rolls = 0}, {boss = "gluttonous_sin", name = "Gluttonous Sin", stage = 4, rolls = 0}, {boss = "fox_sin", name = "Fox Sin", stage = 5, rolls = 0}, {boss = "awakened_sun_lion", name = "Awakened Sun Lion", stage = 6, rolls = 0}, {boss = "wrathful_sin", name = "Wrathful Sin", stage = 7, rolls = 16000}}, extreme = {{boss = "envious_sin", name = "Envious Sin", stage = 1, rolls = 0}, {boss = "impure_sin", name = "Impure Sin", stage = 2, rolls = 0}, {boss = "slothful_sin", name = "Slothful Sin", stage = 3, rolls = 0}, {boss = "gluttonous_sin", name = "Gluttonous Sin", stage = 4, rolls = 0}, {boss = "fox_sin", name = "Fox Sin", stage = 5, rolls = 0}, {boss = "awakened_sun_lion", name = "Awakened Sun Lion", stage = 6, rolls = 0}, {boss = "wrathful_sin", name = "Wrathful Sin", stage = 7, rolls = 23000}}, nightmare = {{boss = "envious_sin", name = "Envious Sin", stage = 1, rolls = 0}, {boss = "impure_sin", name = "Impure Sin", stage = 2, rolls = 0}, {boss = "slothful_sin", name = "Slothful Sin", stage = 3, rolls = 0}, {boss = "gluttonous_sin", name = "Gluttonous Sin", stage = 4, rolls = 0}, {boss = "fox_sin", name = "Fox Sin", stage = 5, rolls = 0}, {boss = "awakened_sun_lion", name = "Awakened Sun Lion", stage = 6, rolls = 0}, {boss = "wrathful_sin", name = "Wrathful Sin", stage = 7, rolls = 35000}}, celestial = {{boss = "envious_sin", name = "Envious Sin", stage = 1, rolls = 0}, {boss = "impure_sin", name = "Impure Sin", stage = 2, rolls = 0}, {boss = "slothful_sin", name = "Slothful Sin", stage = 3, rolls = 0}, {boss = "gluttonous_sin", name = "Gluttonous Sin", stage = 4, rolls = 0}, {boss = "fox_sin", name = "Fox Sin", stage = 5, rolls = 0}, {boss = "awakened_sun_lion", name = "Awakened Sun Lion", stage = 6, rolls = 0}, {boss = "wrathful_sin", name = "Wrathful Sin", stage = 7, rolls = 39000}}}},
    {id = "bizarre_manor", name = "Bizarre Manor", crystal = "bizarre_crystal", crystalFloor = 150, bosses = {normal = {{boss = "apex_of_evolution", name = "Apex of Evolution", stage = 1, rolls = 0}, {boss = "awakened_golden_vampire", name = "Awakened Golden Vampire", stage = 2, rolls = 0}, {boss = "deranged_killer", name = "Deranged Killer", stage = 3, rolls = 0}, {boss = "crimson_emperor", name = "Crimson Emperor", stage = 4, rolls = 0}, {boss = "pale_snake", name = "Pale Snake", stage = 5, rolls = 0}, {boss = "dimensional_manipulator", name = "Dimensional Manipulator", stage = 6, rolls = 7500}}, medium = {{boss = "apex_of_evolution", name = "Apex of Evolution", stage = 1, rolls = 0}, {boss = "awakened_golden_vampire", name = "Awakened Golden Vampire", stage = 2, rolls = 0}, {boss = "deranged_killer", name = "Deranged Killer", stage = 3, rolls = 0}, {boss = "crimson_emperor", name = "Crimson Emperor", stage = 4, rolls = 0}, {boss = "pale_snake", name = "Pale Snake", stage = 5, rolls = 0}, {boss = "dimensional_manipulator", name = "Dimensional Manipulator", stage = 6, rolls = 12500}}, hard = {{boss = "apex_of_evolution", name = "Apex of Evolution", stage = 1, rolls = 0}, {boss = "awakened_golden_vampire", name = "Awakened Golden Vampire", stage = 2, rolls = 0}, {boss = "deranged_killer", name = "Deranged Killer", stage = 3, rolls = 0}, {boss = "crimson_emperor", name = "Crimson Emperor", stage = 4, rolls = 0}, {boss = "pale_snake", name = "Pale Snake", stage = 5, rolls = 0}, {boss = "dimensional_manipulator", name = "Dimensional Manipulator", stage = 6, rolls = 20000}}, extreme = {{boss = "apex_of_evolution", name = "Apex of Evolution", stage = 1, rolls = 0}, {boss = "awakened_golden_vampire", name = "Awakened Golden Vampire", stage = 2, rolls = 0}, {boss = "deranged_killer", name = "Deranged Killer", stage = 3, rolls = 0}, {boss = "crimson_emperor", name = "Crimson Emperor", stage = 4, rolls = 0}, {boss = "pale_snake", name = "Pale Snake", stage = 5, rolls = 0}, {boss = "dimensional_manipulator", name = "Dimensional Manipulator", stage = 6, rolls = 30000}}, nightmare = {{boss = "apex_of_evolution", name = "Apex of Evolution", stage = 1, rolls = 0}, {boss = "awakened_golden_vampire", name = "Awakened Golden Vampire", stage = 2, rolls = 0}, {boss = "deranged_killer", name = "Deranged Killer", stage = 3, rolls = 0}, {boss = "crimson_emperor", name = "Crimson Emperor", stage = 4, rolls = 0}, {boss = "pale_snake", name = "Pale Snake", stage = 5, rolls = 0}, {boss = "dimensional_manipulator", name = "Dimensional Manipulator", stage = 6, rolls = 40000}}, celestial = {{boss = "apex_of_evolution", name = "Apex of Evolution", stage = 1, rolls = 0}, {boss = "awakened_golden_vampire", name = "Awakened Golden Vampire", stage = 2, rolls = 0}, {boss = "deranged_killer", name = "Deranged Killer", stage = 3, rolls = 0}, {boss = "crimson_emperor", name = "Crimson Emperor", stage = 4, rolls = 0}, {boss = "pale_snake", name = "Pale Snake", stage = 5, rolls = 0}, {boss = "dimensional_manipulator", name = "Dimensional Manipulator", stage = 6, rolls = 50000}}}},
    {id = "clover_hideout", name = "Clover Hideout", crystal = "clover_crystal", crystalFloor = 150, bosses = {normal = {{boss = "golden_petal_mage", name = "Golden Petal Mage", stage = 1, rolls = 0}, {boss = "fate_tempter_bull", name = "Fate Tempter Bull", stage = 2, rolls = 0}, {boss = "bull_vice_captain", name = "Bull Vice Captain", stage = 3, rolls = 0}, {boss = "royal_bull_maiden", name = "Royal Bull Maiden", stage = 4, rolls = 0}, {boss = "bull_captain", name = "Bull Captain", stage = 5, rolls = 0}, {boss = "elf_prodigy", name = "Elf Prodigy", stage = 6, rolls = 0}, {boss = "awakened_demon_bull", name = "Awakened Demon Bull", stage = 7, rolls = 8500}}, medium = {{boss = "golden_petal_mage", name = "Golden Petal Mage", stage = 1, rolls = 0}, {boss = "fate_tempter_bull", name = "Fate Tempter Bull", stage = 2, rolls = 0}, {boss = "bull_vice_captain", name = "Bull Vice Captain", stage = 3, rolls = 0}, {boss = "royal_bull_maiden", name = "Royal Bull Maiden", stage = 4, rolls = 0}, {boss = "bull_captain", name = "Bull Captain", stage = 5, rolls = 0}, {boss = "elf_prodigy", name = "Elf Prodigy", stage = 6, rolls = 0}, {boss = "awakened_demon_bull", name = "Awakened Demon Bull", stage = 7, rolls = 13500}}, hard = {{boss = "golden_petal_mage", name = "Golden Petal Mage", stage = 1, rolls = 0}, {boss = "fate_tempter_bull", name = "Fate Tempter Bull", stage = 2, rolls = 0}, {boss = "bull_vice_captain", name = "Bull Vice Captain", stage = 3, rolls = 0}, {boss = "royal_bull_maiden", name = "Royal Bull Maiden", stage = 4, rolls = 0}, {boss = "bull_captain", name = "Bull Captain", stage = 5, rolls = 0}, {boss = "elf_prodigy", name = "Elf Prodigy", stage = 6, rolls = 0}, {boss = "awakened_demon_bull", name = "Awakened Demon Bull", stage = 7, rolls = 30000}}, extreme = {{boss = "golden_petal_mage", name = "Golden Petal Mage", stage = 1, rolls = 0}, {boss = "fate_tempter_bull", name = "Fate Tempter Bull", stage = 2, rolls = 0}, {boss = "bull_vice_captain", name = "Bull Vice Captain", stage = 3, rolls = 0}, {boss = "royal_bull_maiden", name = "Royal Bull Maiden", stage = 4, rolls = 0}, {boss = "bull_captain", name = "Bull Captain", stage = 5, rolls = 0}, {boss = "elf_prodigy", name = "Elf Prodigy", stage = 6, rolls = 0}, {boss = "awakened_demon_bull", name = "Awakened Demon Bull", stage = 7, rolls = 40000}}, nightmare = {{boss = "golden_petal_mage", name = "Golden Petal Mage", stage = 1, rolls = 0}, {boss = "fate_tempter_bull", name = "Fate Tempter Bull", stage = 2, rolls = 0}, {boss = "bull_vice_captain", name = "Bull Vice Captain", stage = 3, rolls = 0}, {boss = "royal_bull_maiden", name = "Royal Bull Maiden", stage = 4, rolls = 0}, {boss = "bull_captain", name = "Bull Captain", stage = 5, rolls = 0}, {boss = "elf_prodigy", name = "Elf Prodigy", stage = 6, rolls = 0}, {boss = "awakened_demon_bull", name = "Awakened Demon Bull", stage = 7, rolls = 50000}}, celestial = {{boss = "golden_petal_mage", name = "Golden Petal Mage", stage = 1, rolls = 0}, {boss = "fate_tempter_bull", name = "Fate Tempter Bull", stage = 2, rolls = 0}, {boss = "bull_vice_captain", name = "Bull Vice Captain", stage = 3, rolls = 0}, {boss = "royal_bull_maiden", name = "Royal Bull Maiden", stage = 4, rolls = 0}, {boss = "bull_captain", name = "Bull Captain", stage = 5, rolls = 0}, {boss = "elf_prodigy", name = "Elf Prodigy", stage = 6, rolls = 0}, {boss = "awakened_demon_bull", name = "Awakened Demon Bull", stage = 7, rolls = 60000}}}},
    {id = "deity_planet", name = "Deity Planet", crystal = "deity_crystal", crystalFloor = 150, bosses = {normal = {{boss = "primal_deity", name = "Primal Deity", stage = 1, rolls = 0}, {boss = "temporal_assassin", name = "Temporal Assassin", stage = 2, rolls = 0}, {boss = "ascended_prideful_prince", name = "Ascended Prideful Prince", stage = 3, rolls = 0}, {boss = "ascended_earths_strongest", name = "Ascended Earth's Strongest", stage = 4, rolls = 0}, {boss = "devourer_sorcerer", name = "Devourer Sorcerer", stage = 5, rolls = 0}, {boss = "prideful_warrior", name = "Prideful Warrior", stage = 6, rolls = 8500}}, medium = {{boss = "primal_deity", name = "Primal Deity", stage = 1, rolls = 0}, {boss = "temporal_assassin", name = "Temporal Assassin", stage = 2, rolls = 0}, {boss = "ascended_prideful_prince", name = "Ascended Prideful Prince", stage = 3, rolls = 0}, {boss = "ascended_earths_strongest", name = "Ascended Earth's Strongest", stage = 4, rolls = 0}, {boss = "devourer_sorcerer", name = "Devourer Sorcerer", stage = 5, rolls = 0}, {boss = "prideful_warrior", name = "Prideful Warrior", stage = 6, rolls = 13500}}, hard = {{boss = "primal_deity", name = "Primal Deity", stage = 1, rolls = 0}, {boss = "temporal_assassin", name = "Temporal Assassin", stage = 2, rolls = 0}, {boss = "ascended_prideful_prince", name = "Ascended Prideful Prince", stage = 3, rolls = 0}, {boss = "ascended_earths_strongest", name = "Ascended Earth's Strongest", stage = 4, rolls = 0}, {boss = "devourer_sorcerer", name = "Devourer Sorcerer", stage = 5, rolls = 0}, {boss = "prideful_warrior", name = "Prideful Warrior", stage = 6, rolls = 40000}}, extreme = {{boss = "primal_deity", name = "Primal Deity", stage = 1, rolls = 0}, {boss = "temporal_assassin", name = "Temporal Assassin", stage = 2, rolls = 0}, {boss = "ascended_prideful_prince", name = "Ascended Prideful Prince", stage = 3, rolls = 0}, {boss = "ascended_earths_strongest", name = "Ascended Earth's Strongest", stage = 4, rolls = 0}, {boss = "devourer_sorcerer", name = "Devourer Sorcerer", stage = 5, rolls = 0}, {boss = "prideful_warrior", name = "Prideful Warrior", stage = 6, rolls = 50000}}, nightmare = {{boss = "primal_deity", name = "Primal Deity", stage = 1, rolls = 0}, {boss = "temporal_assassin", name = "Temporal Assassin", stage = 2, rolls = 0}, {boss = "ascended_prideful_prince", name = "Ascended Prideful Prince", stage = 3, rolls = 0}, {boss = "ascended_earths_strongest", name = "Ascended Earth's Strongest", stage = 4, rolls = 0}, {boss = "devourer_sorcerer", name = "Devourer Sorcerer", stage = 5, rolls = 0}, {boss = "prideful_warrior", name = "Prideful Warrior", stage = 6, rolls = 60000}}, celestial = {{boss = "primal_deity", name = "Primal Deity", stage = 1, rolls = 0}, {boss = "temporal_assassin", name = "Temporal Assassin", stage = 2, rolls = 0}, {boss = "ascended_prideful_prince", name = "Ascended Prideful Prince", stage = 3, rolls = 0}, {boss = "ascended_earths_strongest", name = "Ascended Earth's Strongest", stage = 4, rolls = 0}, {boss = "devourer_sorcerer", name = "Devourer Sorcerer", stage = 5, rolls = 0}, {boss = "prideful_warrior", name = "Prideful Warrior", stage = 6, rolls = 80000}}}},
  },
}
]===]
M["decks"] = [===[
-- Where decks come from. All files are the ones the optimiser / climbers already write into the executor workspace:
--   AnimeCardClash/tower_plan_<tower>.json  {tower, waves = {["<wave>"] = {decks = {deck...}, rate = 0..1}}}   (make_tower_plan.py)
--   AnimeCardClash/climb_decks.json         {["<tower>"] = {["<wave>"] = deck}}                                    (optimiser)
--   AnimeCardClash/story_plan.json          {stages = {{world, diff, boss, stage, decks = {deck...}}}}            (make_story_plan.py)
--   acc-farm/decks.json                     {["tower:<id>:<wave>" | "story:<world>:<diff>:<boss>" | "default"] = deck}  (your own)
-- deck = {{attack, support}, x4} with ids like "pumpkin_witch_cat:secret".
local core = ...
local decks = {}
local cache, cacheAt = {}, {}

local function load(path)
	if cache[path] ~= nil and os.clock() - (cacheAt[path] or 0) < 60 then return cache[path] or nil end
	local v = core.readJson(path)
	cache[path], cacheAt[path] = v or false, os.clock()
	return v
end

local function valid(d)
	if type(d) ~= "table" or #d == 0 then return false end
	for pos = 1, #d do if type(d[pos]) ~= "table" or type(d[pos][1]) ~= "string" or d[pos][1] == "" then return false end end
	return true
end

-- returns list of candidate decks (best first) and the planner's win rate if known
function decks.tower(id, wave)
	local out, rate = {}, nil
	local own = load("acc-farm/decks.json")
	if own and valid(own["tower:" .. id .. ":" .. wave]) then table.insert(out, own["tower:" .. id .. ":" .. wave]) end
	local plan = load(core.dir() .. "tower_plan_" .. id .. ".json")
	local e = plan and plan.waves and plan.waves[tostring(wave)]
	if e then
		rate = e.rate
		for _, d in ipairs(e.decks or {}) do if valid(d) then table.insert(out, d) end end
	end
	local cd = load(core.dir() .. "climb_decks.json")
	local d = cd and cd[id] and cd[id][tostring(wave)]
	if valid(d) then table.insert(out, d) end
	return out, rate
end

function decks.story(world, diff, boss)
	local out = {}
	local own = load("acc-farm/decks.json")
	local k = "story:" .. world .. ":" .. diff .. ":" .. boss
	if own and valid(own[k]) then table.insert(out, own[k]) end
	local plan = load(core.dir() .. "story_plan.json")
	for _, st in ipairs(plan and plan.stages or {}) do
		if st.world == world and st.diff == diff and st.boss == boss then
			for _, d in ipairs(st.decks or {}) do if valid(d) then table.insert(out, d) end end
		end
	end
	return out
end

function decks.default()
	local own = load("acc-farm/decks.json")
	return own and valid(own.default) and own.default or nil
end

-- picks the deck for attempt n: stored decks in turn; falls back to what slot_15 holds now (or nil = keep slot_15)
function decks.pick(list, attempt)
	if core.settings.deckMode == "keep" or #list == 0 then return decks.default() end
	return list[((attempt - 1) % #list) + 1]
end

function decks.plan(path) return load(path) end

return decks
]===]
M["helpers/deity_run"] = [===[
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
]===]
M["helpers/ranked_recorder"] = [===[
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
]===]
M["helpers/steer"] = [===[
-- Closed-loop seed steering for one battle-tower wave (2026-10-17, v4). Whousleaks only, slot_15 only.
-- Commands: fightBattleTowerWave once (floor 1 on a safe second; skipped with _G.__ST_ATTACH), setBattleSpeed only otherwise.
-- >= 1.5 s between commands. Needs steer_helper.py on the PC (answers steer_req.json with steer_plan_<seed>.json).
-- Every floor: press until the speed is the base speed (_G.__ST_SPEED), ask the PC for the engine plan at that speed.
-- At every client turn key the plan knows, forecast the end:  P = t_key + KA * engine s left * (plan speed / speed now)
--   + KB * turn changes left + TAIL   (fitted on live floors). Next floor's seed = floor(P - D).
-- If that second loses or sits near a boundary, pick the nearest reachable winning second (neighbours winning preferred) and press
-- (speed s -> s + 0.5, which shortens the rest; 4.5 wraps to 1, which lengthens it) at the moment that puts the end in its middle.
-- Up to MAXP steering presses per floor (a coarse early one, then corrections). Log: AnimeCardClash/steer_log.json. Stop: _G.__ST_STOP = true.
if game.Players.LocalPlayer.Name ~= "Whousleaks" then print("ST WRONG ACCOUNT") return end
local RS = game:GetService("ReplicatedStorage")
local HS = game:GetService("HttpService")
local comps = require(RS.shared.components)
local jecs = require(RS.rbxts_include.node_modules["@rbxts"].jecs.src.jecs)
local ctx = _G.__BS_CTX
if not ctx then print("ST ABORT no ctx") return end
local function remote(n) for _, d in ipairs(RS:GetDescendants()) do if d.Name == n and d:IsA("RemoteEvent") and not d:GetFullName():find("JABBY", 1, true) then return d end end end
local R = { fight = remote("fightBattleTowerWave"), speed = remote("setBattleSpeed") }
if not R.fight or not R.speed then print("ST ABORT remote missing") return end
local TOWER, WAVE, SPEED = _G.__ST_TOWER or "darkness", _G.__ST_WAVE or 6, _G.__ST_SPEED or 2
local D = _G.__ST_D or 0.085           -- client sees the fight end this long after the server (0.08-0.09, from 15 floors)
local KA = _G.__ST_KA or 1.16          -- real s per engine s (delay/speed)
local KB = _G.__ST_KB or 0.49          -- real s per remaining turn change
local TAIL = _G.__ST_TAIL or 0.5       -- end seen this long after the engine's last turn
local DECIDE = _G.__ST_DECIDE or 25    -- consider presses once the forecast end is this close (s)
local LAT = _G.__ST_LAT or 0.07        -- fire this much before the computed press moment
local MAXP = _G.__ST_MAXP or 3         -- steering presses per floor
local ATTACH = _G.__ST_ATTACH == true
local W = ctx.world
local now = function() return workspace:GetServerTimeNow() end
_G.__ST_STOP = false
_G.__ST_GEN = (_G.__ST_GEN or 0) + 1
local GEN = _G.__ST_GEN
local LOG = { tower = TOWER, wave = WAVE, speed = SPEED, D = D, KA = KA, KB = KB, TAIL = TAIL, events = {} }
local lastSave = 0
local function save(force) if force or os.clock() - lastSave > 0.5 then lastSave = os.clock() pcall(writefile, "AnimeCardClash/steer_log.json", HS:JSONEncode(LOG)) end end
local function log(kind, t) t = t or {} t.kind = kind t.at = now() table.insert(LOG.events, t) save(kind ~= "pred") end
local function stopped() return _G.__ST_STOP or _G.__ST_GEN ~= GEN end
local function moonNow() local ok, m = pcall(ctx.moonCycle) if ok and m and m.current then return m.current, (m.lastChanged and m.duration) and (m.lastChanged + m.duration) or nil end return "none", nil end
local function sess() for e, v in W:query(comps.BattleSession) do if v.type == "battle_tower" then return e, v end end end
local function battle() for e, b in W:query(comps.Battle) do return e, b end end
local function turnKey(be, b)
  local t = {}
  for _, p in W:query(comps.BattlePlayer, jecs.pair(jecs.ChildOf, be)) do if p.side then t[p.side] = p.turn end end
  return tostring(t.player_1) .. "/" .. tostring(t.player_2) .. "/" .. tostring(b.activeSide)
end
local lastCmd, presses = -10, 0
local function fire(se, why)
  local sv = ctx.clientToServerEntities[se]
  if sv == nil or presses >= 150 then log("pressFail", { why = why }) return false end
  while now() - lastCmd < 1.5 do task.wait(0.01) end
  R.speed:FireServer(sv) lastCmd = now() presses += 1
  log("press", { why = why, n = presses })
  return true
end
local function nextSpeed(s) if s >= 4.5 then return 1 end return s + 0.5 end
local function readJson(f) local ok, v = pcall(function() return HS:JSONDecode(readfile(f)) end) return ok and v or nil end

task.spawn(function()
  if ATTACH then
    if not sess() then print("ST ABORT nothing to attach to") return end
    log("attach")
  else
    local plan1 = readJson(("AnimeCardClash/tw_times_%s_%d.json"):format(TOWER, WAVE))
    local T
    for _, s in ipairs(plan1 and plan1.safe or {}) do if s >= now() + 10 and (T == nil or s < T) then T = s end end
    if not T then print("ST ABORT no safe second") log("abort", { why = "no safe second" }) return end
    if sess() then print("ST ABORT a tower session already exists") log("abort", { why = "session exists" }) return end
    log("planned", { target = T })
    print("ST start at", T, "in", math.floor(T - now()), "s")
    while now() < T + 0.1 do task.wait(0.05) if stopped() then log("aborted") return end end
    while now() < T + 0.35 do end
    R.fight:FireServer(TOWER, WAVE, "slot_15") lastCmd = now()
    log("fight", { target = T })
  end

  local t0, lastSeen, seen = os.clock(), os.clock(), false
  local F = nil
  local prevTarget = nil
  local reqN = 0
  local function newFloor(seed, tStart, speedNow)
    local m, mEnd = moonNow()
    if F and F.wins then log("landed", { seed = seed, wins = F.wins[seed] == true, target = prevTarget, hit = prevTarget == seed }) end
    prevTarget = nil
    F = { seed = seed, tStart = tStart, plan = nil, key = nil, steers = 0, tPress = nil, choice = nil, settled = false, moon = m, moonEnd = mEnd }
    log("floor", { seed = seed, tStart = tStart, speed = speedNow, moon = m, moonEnd = mEnd })
  end

  while not stopped() and os.clock() - t0 < 2400 do
    task.wait(0.02)
    local ok, err = pcall(function()
      local se, s = sess()
      if not se then
        if seen and os.clock() - lastSeen > 15 then _G.__ST_STOP = true end
        if not seen and os.clock() - t0 > 40 then log("nostart") _G.__ST_STOP = true end
        return
      end
      seen, lastSeen = true, os.clock()
      if F == nil or s.seed ~= F.seed then
        local _, b0 = battle()
        newFloor(s.seed, now(), b0 and b0.speed or s.battleSpeed)
      end
      local be, b = battle()
      if not be then return end
      -- 1) base speed, then ask the PC for the plan at that speed
      if not F.settled then
        if b.speed == SPEED then
          F.settled = true F.speed = SPEED reqN += 1
          pcall(writefile, "AnimeCardClash/steer_req.json", HS:JSONEncode({ id = F.seed * 10 + reqN % 10, seed = F.seed, speed = SPEED, moon = F.moon, moonEnd = F.moonEnd, tStart = F.tStart }))
          log("settled", { speed = SPEED })
        elseif now() - lastCmd >= 1.5 and b.winner == nil then
          fire(se, "base speed")
        end
        return
      end
      if not F.plan then
        local p = readJson(("AnimeCardClash/steer_plan_%d.json"):format(F.seed))
        if p and p.seed == F.seed and p.speed == F.speed then
          F.plan = p F.wins = {} F.mt = {}
          for _, x in ipairs(p.wins) do F.wins[x] = true end
          for _, v in pairs(p.marks) do table.insert(F.mt, v[1]) end
          log("plan", { winner = p.winner, total = p.total, nwins = #p.wins, from = p.from, to = p.to })
        end
      end
      if not F.plan then return end
      -- 2) forecast at each known turn key
      local k = turnKey(be, b)
      if k ~= F.key then
        F.key = k
        local m = F.plan.marks[k]
        if m then
          local tk, ek = now(), m[1]
          local keysLeft = 0
          for _, x in ipairs(F.mt) do if x > ek + 1e-6 then keysLeft += 1 end end
          local q = F.speed / b.speed
          F.fixed = KB * keysLeft + TAIL
          F.P = tk + KA * (F.plan.total - ek) * q + F.fixed
          F.choice = nil   -- re-decide with the fresh forecast
          log("pred", { key = k, e = ek, P = F.P, speed = b.speed, keysLeft = keysLeft, next = math.floor(F.P - D) })
        else
          log("pred", { key = k, unknown = true })
        end
      end
      local P = F.P
      if not P or F.plan.winner ~= "player_1" then return end
      if P - now() > DECIDE then return end
      -- 3) decide
      if not F.choice then
        local x = P - D
        local Scur = math.floor(x)
        local frac = x - Scur
        local wn = F.wins
        local okHere = wn[Scur] and ((frac >= 0.3 and frac <= 0.7) or (frac < 0.3 and wn[Scur - 1]) or (frac > 0.7 and wn[Scur + 1]))
        if okHere then
          F.choice = { keep = true, S = Scur } F.tPress = nil prevTarget = Scur
          log("keep", { S = Scur, frac = frac, P = P })
        elseif F.steers >= MAXP then
          F.choice = { none = true } F.tPress = nil
          log("noPressLeft", { P = P, Scur = Scur, frac = frac })
        else
          local s1 = b.speed local s2 = nextSpeed(s1) local qq = s1 / s2
          local fx = F.fixed or TAIL
          local best
          for pass = 1, 2 do
            for d = 0, 30 do
              local S = (qq < 1) and (Scur - d) or (Scur + d)
              local good = wn[S] and (pass == 2 or (wn[S - 1] and wn[S + 1]))
              if good and not best then
                local X = S + 0.5 + D
                local tp = (X - fx - (P - fx) * qq) / (1 - qq)
                if tp >= math.max(now() + 0.3, lastCmd + 1.5) and tp < P - fx - 0.1 then best = { S = S, X = X, tp = tp, pass = pass } end
              end
            end
          end
          if best then
            F.choice = best F.tPress = best.tp prevTarget = best.S
            log("steer", { S = best.S, X = best.X, tPress = best.tp, P = P, s1 = s1, s2 = s2, pass = best.pass })
          else
            F.choice = { none = true } F.tPress = nil
            log("noChoice", { P = P, Scur = Scur, frac = frac })
          end
        end
      end
      -- 4) press at the computed moment
      if F.tPress and now() >= F.tPress - LAT then
        local s1 = b.speed
        F.tPress = nil
        if fire(se, "steer to " .. tostring(F.choice.S)) then
          F.steers += 1
          local fx = F.fixed or TAIL
          local q = s1 / nextSpeed(s1)
          local at = now()
          F.P = at + (P - fx - at) * q + fx
          log("pressed", { target = F.choice.S, Pbefore = P, Pafter = F.P, s1 = s1, steers = F.steers })
          F.choice = nil
        end
      end
    end)
    if not ok then log("error", { err = tostring(err) }) end
  end
  if F and F.wins and prevTarget then log("landed", { seed = nil, note = "session ended", target = prevTarget }) end
  log("stop") save(true) print("ST over")
end)
]===]
M["main"] = [===[
-- Anime Card Clash auto farm: GUI + scheduler. Loaded by loader.lua, which passes import(name) -> module.
local import, run = ...
local core = import("core")
local data = import("data")
local lib = import("ui")
local decks = import("decks", core)
local towers = import("tasks/towers", core, data, decks)
local story = import("tasks/story", core, data, decks)
local extras = import("tasks/extras", core, data)
local skip = import("tasks/storyskip", core)
local planner = import("planner", core)

local LP = game:GetService("Players").LocalPlayer
-- one settings file per account (Whousleaks keeps the first file name)
local SETTINGS_FILE = LP.Name == "Whousleaks" and "acc-farm/settings.json" or ("acc-farm/settings_" .. LP.Name .. ".json")
pcall(function() if not isfolder("acc-farm") then makefolder("acc-farm") end end)

-- ---------- settings ----------
local TASKS = {
	{ id = "dailies", name = "Daily login + quests", on = true },
	{ id = "tower_repeat", name = "Tower repeats (packs)", on = true },
	{ id = "story_repeat", name = "Story repeats (packs)", on = true },
	{ id = "story_skip", name = "Story Skip (needs keys + PC helper)", on = false },
	{ id = "tower_clear", name = "Tower first clears", on = true },
	{ id = "story_clear", name = "Story first clears", on = true },
	{ id = "instant_packs", name = "Open instant packs", on = false },
	{ id = "story_tower", name = "Story tower crystals", on = false },
}
local defaults = {
	account = "Whousleaks, Umson_42", antiAfk = true, order = {}, enabled = {}, towers = {}, repeatTowers = {}, towerOrder = {},
	deckMode = "auto", timed = false, hideFights = true, maxLosses = 3, minRate = 0, fightTimeout = 900, memLimit = 4500,
	repeatAll = false, storyDiffs = {}, storyRepeatAll = false, storyTowerWorld = "", storyTowerMinutes = 20,
	packMinSize = 50, packBigFirst = true, packPerUse = 10, dailyLogin = true, dailyQuests = true, theme = "Dark",
	skipWorlds = {}, skipPlanWait = 120,
}
for _, t in ipairs(TASKS) do table.insert(defaults.order, t.id) defaults.enabled[t.id] = t.on end
for _, t in ipairs(data.towers) do
	table.insert(defaults.towerOrder, t.id)
	defaults.towers[t.id] = true
	defaults.repeatTowers[t.id] = next(t.repeatRolls) ~= nil
end
for _, d in ipairs(data.difficulties) do defaults.storyDiffs[d] = true end
for _, w in ipairs(skip.WORLDS) do defaults.skipWorlds[w[1]] = not w.off end

local cfg = core.readJson(SETTINGS_FILE) or {}
for k, v in pairs(defaults) do
	if cfg[k] == nil then cfg[k] = v
	elseif type(v) == "table" and type(cfg[k]) == "table" and #v == 0 then for k2, v2 in pairs(v) do if cfg[k][k2] == nil then cfg[k][k2] = v2 end end end
end
-- tasks added after a settings file was saved go to the end of the saved order
for _, t in ipairs(TASKS) do
	local found = false
	for _, id in ipairs(cfg.order) do if id == t.id then found = true end end
	if not found then table.insert(cfg.order, t.id) end
end
core.settings = cfg
-- Look-only preview (getgenv().ACC_PREVIEW = true before loading): the window opens with every task off, nothing is saved,
-- and every button that would read or touch the game (Start, Probe, Read Deck 15, helpers) is refused. No getgc, no commands.
local PREVIEW = getgenv().ACC_PREVIEW == true
if PREVIEW then
	for id in pairs(cfg.enabled) do cfg.enabled[id] = false end
	cfg.antiAfk = false
	core.init = function() return false, "Preview only: this window is just for looking. Nothing starts." end
end
local function save() if not PREVIEW then core.writeJson(SETTINGS_FILE, cfg) end end

-- ---------- scheduler ----------
local running, stats = false, { win = 0, loss = 0, jobs = 0 }
local SOURCES = {
	dailies = extras.dailies, tower_repeat = towers.repeats, story_repeat = story.repeats, tower_clear = towers.clear,
	story_clear = story.clear, instant_packs = extras.packs, story_tower = story.tower, story_skip = skip,
}
local function nextJob(beforeId)
	for _, id in ipairs(cfg.order) do
		if beforeId and id == beforeId then return nil end
		local src = SOURCES[id]
		if src and cfg.enabled[id] then
			local ok, job = pcall(src.next, cfg)
			if not ok then core.say("error in", id, job)
			elseif job then job.task = id return job end
		end
	end
end
local function runJob(job)
	core.status = job.label
	local res
	if job.kind == "tower" then res = towers.run(job, cfg)
	elseif job.kind == "story" then res = story.run(job, cfg)
	elseif job.kind == "infinite" then res = story.runTower(job, cfg, function() return nextJob("story_tower") ~= nil end)
	elseif job.kind == "storyskip" then res = skip.run(job, cfg)
	elseif job.kind == "packs" then res = extras.runPacks(job, cfg)
	elseif job.kind == "dailies" then res = extras.runDailies(job, cfg) end
	stats.jobs += 1
	if res == "win" then stats.win += 1 elseif res == "loss" then stats.loss += 1 end
	return res
end

local function loop()
	core.say("farm started")
	while running and not core.stopped() do
		local other = core.otherScriptRunning()
		if other then
			core.status = "waiting: another script controls the game (" .. other .. ")"
			core.wait(15)
		elseif core.mem() > cfg.memLimit then
			core.status = "paused: game uses " .. math.floor(core.mem()) .. " MB"
			core.wait(30)
		elseif not core.accountOk() then
			core.status = "stopped: wrong account (" .. game:GetService("Players").LocalPlayer.Name .. ")"
			running = false
		else
			local job = nextJob()
			if job then
				local ok, err = pcall(runJob, job)
				if not ok then core.say("error:", err) core.wait(10) end
				core.wait(2)
			else
				core.status = "nothing to do right now, checking again soon"
				core.wait(30)
			end
		end
	end
	core.status = "stopped"
	core.say("farm stopped")
end

local function start()
	if running then return end
	local ok, err = core.init()
	if not ok then lib:Notification("Can't start", err, nil, "Okay") return end
	core.claim()
	_G.__ACCF_STOP = false
	running = true
	task.spawn(loop)
end
local function stop()
	running = false
	_G.__ACCF_STOP = true
end

-- ---------- anti-AFK (same as toolkit/lua/anti_afk.lua: walk 3 studs and back every 10 min, local only, no commands) ----------
local thisLoad = {}
_G.__ACCF_LOAD = thisLoad   -- a newer window (or Stop and close) ends this loop
task.spawn(function()
	local waited = 0
	while true do
		task.wait(1)
		if _G.__ACCF_LOAD ~= thisLoad then return end
		waited += 1
		if waited >= 600 then
			waited = 0
			if cfg.antiAfk and not _G.__AFK_RUN then   -- the toolkit's own anti-AFK may already run on this client
				pcall(function()
					local char = LP.Character
					local hum = char and char:FindFirstChildOfClass("Humanoid")
					local root = char and char:FindFirstChild("HumanoidRootPart")
					if hum and root and hum.Health > 0 and not hum.Sit then
						local home = root.Position
						hum:MoveTo(home + Vector3.new(3, 0, 0))
						task.wait(0.7)
						hum:MoveTo(home)
					end
				end)
			end
		end
	end
end)

-- ---------- script mode: getgenv().ACC_HEADLESS = true -> no window, same settings file, starts at once ----------
if getgenv().ACC_HEADLESS == true then
	core.say("script mode: no window; settings in " .. SETTINGS_FILE .. "; stop with getgenv().ACC_STOP() or _G.__ACCF_STOP = true")
	getgenv().ACC_STOP = stop
	if not PREVIEW then task.spawn(start) end
	return { start = start, stop = stop, settings = cfg }
end

-- ---------- beta helpers (whole scripts from the project; each one controls the game alone, so the farm stops first) ----------
local farmToggle
local function startHelper(name, setup)
	if not core.isMain() then lib:Notification("Not on this account", "This one is made for Whousleaks only.", nil, "Okay") return end
	local ok, err = core.init()
	if not ok then lib:Notification("Can't start", err, nil, "Okay") return end
	if running then stop() if farmToggle then farmToggle:Set(false, true) end end
	if setup then setup() end
	core.say("starting", name)
	local ok2, e2 = pcall(run, "helpers/" .. name)
	if not ok2 then core.say("could not start", name, e2) end
end

-- ---------- GUI ----------
lib:ChangeTheme(cfg.theme)
local win = lib:Window("Card Clash Farm")
win:Label("Farm")
local PINK = Color3.fromRGB(255, 110, 180)
local RED, ORANGE, YELLOW, GREEN, TEAL, BLUE, PURPLE, GREY =
	Color3.fromRGB(255, 92, 92), Color3.fromRGB(255, 150, 70), Color3.fromRGB(240, 200, 60), Color3.fromRGB(80, 200, 120),
	Color3.fromRGB(60, 190, 200), Color3.fromRGB(100, 140, 255), Color3.fromRGB(170, 110, 255), Color3.fromRGB(140, 145, 160)

local home = win:Tab("Farm", "rbxassetid://6031280882", GREEN)
local towersTab = win:Tab("Towers", "rbxassetid://6034287519", RED)
local storyTab = win:Tab("Story", "rbxassetid://6031763426", ORANGE)
local packsTab = win:Tab("Packs", "rbxassetid://6026568210", YELLOW)
local dailyTab = win:Tab("Dailies & events", "rbxassetid://6031302932", TEAL)
local deckTab = win:Tab("Deck", "rbxassetid://6022668898", BLUE)
win:Label("Info")
local betaTab = win:Tab("Beta", "rbxassetid://6031280882", PINK)
local plannerTab = win:Tab("Planner", "rbxassetid://6031302932", TEAL)
local statusTab = win:Tab("Status", "rbxassetid://6034509993", PURPLE)
local setTab = win:Tab("Settings", "rbxassetid://6031280882", GREY)

-- Farm
home:Line("Start / stop")
farmToggle = home:Toggle("Farm running", false, function(v) if v then start() else stop() end end)
home:Toggle("Test mode (prints, sends nothing)", false, function(v) core.dry = v end)
local nowLabel = home:Label("Idle")
home:Line("What to farm (top = first)")
for _, t in ipairs(TASKS) do
	home:Toggle(t.name, cfg.enabled[t.id], function(v) cfg.enabled[t.id] = v save() end)
end
local names = {} for _, t in ipairs(TASKS) do table.insert(names, { id = t.id, name = t.name }) end
home:Order("Priority", names, function(ids) cfg.order = ids save() end):Set(cfg.order)

-- Towers
towersTab:Line("First clears (one-time rewards) per tower")
local groups = { main = "Battle towers", dream = "Dream tower", mage = "Mage tower" }
local lastGroup
for _, t in ipairs(data.towers) do
	if t.group ~= lastGroup then lastGroup = t.group towersTab:Line(groups[t.group] or t.group) end
	towersTab:Toggle(t.name .. "  (" .. t.waves .. " floors)", cfg.towers[t.id], function(v) cfg.towers[t.id] = v save() end)
end
towersTab:Line("Daily repeat rewards that drop instant packs")
for _, t in ipairs(data.towers) do
	if next(t.repeatRolls) then
		local total = 0 for _, r in pairs(t.repeatRolls) do total += r end
		towersTab:Toggle(t.name .. "  (" .. total .. " rolls a day)", cfg.repeatTowers[t.id], function(v) cfg.repeatTowers[t.id] = v save() end)
	end
end
towersTab:Toggle("Also repeat floors without packs", cfg.repeatAll, function(v) cfg.repeatAll = v save() end)

-- Story
storyTab:Line("Difficulties")
for _, d in ipairs(data.difficulties) do
	storyTab:Toggle(d:sub(1, 1):upper() .. d:sub(2), cfg.storyDiffs[d], function(v) cfg.storyDiffs[d] = v save() end)
end
storyTab:Toggle("Repeat bosses without packs too", cfg.storyRepeatAll, function(v) cfg.storyRepeatAll = v save() end)
storyTab:Line("Story tower (crystals for luck gear)")
local worldNames, worldById = { "off" }, {}
for _, w in ipairs(data.worlds) do table.insert(worldNames, w.name) worldById[w.name] = w.id end
local dd = storyTab:Dropdown("World", worldNames, function(v) cfg.storyTowerWorld = worldById[v] or "" save() end)
for _, w in ipairs(data.worlds) do if w.id == cfg.storyTowerWorld then dd:Set(w.name, true) end end
storyTab:Slider("Minutes per turn", false, 5, 120, cfg.storyTowerMinutes, function(v) cfg.storyTowerMinutes = v save() end)
storyTab:Line("Story Skip (1 key per fight, daily rewards of the whole world)")
local keyLabel = storyTab:Label("Keys: start the farm to read them")
storyTab:Label("Needs ss_watch.py running on the PC. Turn it on in the Farm tab; it stays idle with 0 keys.")
for _, w in ipairs(skip.WORLDS) do
	storyTab:Toggle(w[2] .. (w.off and "  (no winning deck yet)" or ""), cfg.skipWorlds[w[1]], function(v) cfg.skipWorlds[w[1]] = v save() end)
end

-- Packs
packsTab:Line("Instant packs in your backpack")
local packLabel = packsTab:Label("Start the farm to read your backpack.")
packsTab:Toggle("Biggest packs first", cfg.packBigFirst, function(v) cfg.packBigFirst = v save() end)
packsTab:Dropdown("Smallest pack to open", { "50", "1000", "10000", "100000" }, function(v) cfg.packMinSize = tonumber(v) save() end):Set(tostring(cfg.packMinSize), true)
packsTab:Slider("Packs per open", false, 1, 100, cfg.packPerUse, function(v) cfg.packPerUse = v save() end)
packsTab:Label("Opening is off by default (Farm tab). Turn it on when your luck is set up.")

-- Dailies & events
dailyTab:Toggle("Daily login reward", cfg.dailyLogin, function(v) cfg.dailyLogin = v save() end)
dailyTab:Toggle("Daily quests", cfg.dailyQuests, function(v) cfg.dailyQuests = v save() end)
dailyTab:Line("Ranked, Tower of Deity, Chainsaw event")
dailyTab:Label("Not wired yet: they need one live look first. Press Probe while the game is open; it only reads.")
dailyTab:Button("Probe (read only)", function() local ok, err = core.init() if ok then extras.probe() else lib:Notification("Probe", err) end end)

-- Deck
deckTab:Line("Deck 15 only (your other decks are never touched)")
deckTab:RadioButtons("Which deck", { "Best stored deck", "Keep Deck 15" }, function(v) cfg.deckMode = (v == "Keep Deck 15") and "keep" or "auto" save() end)
	:Set(cfg.deckMode == "keep" and "Keep Deck 15" or "Best stored deck", true)
local deckLabel = deckTab:Label("Deck 15: not read yet")
deckTab:Button("Read Deck 15", function() local ok = core.init() if ok then deckLabel:SetText("Deck 15: " .. core.deckText(core.readDeck())) end end)
deckTab:Toggle("Timed starts (needs the PC helpers running)", cfg.timed, function(v) cfg.timed = v save() end)
deckTab:Slider("Losses before skipping a fight (per day)", false, 1, 10, cfg.maxLosses, function(v) cfg.maxLosses = v save() end)
deckTab:Slider("Skip floors below this win % (stored plans)", false, 0, 90, cfg.minRate, function(v) cfg.minRate = v save() end)
deckTab:Toggle("Hide fights (they run faster)", cfg.hideFights, function(v) cfg.hideFights = v save() end)

-- Beta (not tested in the game yet; each needs its PC helper and stops the farm while it runs)
betaTab:Label("These are new and not tested in the game yet. Starting one stops the farm. Whousleaks only.")
betaTab:Line("Tower of Deity (timed wins)")
betaTab:Label("PC: run the Deity driver (tasks/2026-10-17-deity). Uses the 4 Deity deck slots, not Deck 15.")
betaTab:Button("Start Deity helper", function() startHelper("deity_run") end)
betaTab:Button("Stop Deity helper", function() _G.__DT_STOP = true core.say("Deity helper stop sent") end)
betaTab:Line("Speed steering (wins every tower floor)")
betaTab:Label("Presses the speed button near the end of each fight so the next floor starts on a winning second. PC: steer_helper.py with the same tower + floor.")
local mainTowers, towerIdByName = {}, {}
for _, t in ipairs(data.towers) do if t.group == "main" then table.insert(mainTowers, t.name) towerIdByName[t.name] = t.id end end
local steerTower, steerWave = "darkness", 7
betaTab:Dropdown("Tower", mainTowers, function(v) steerTower = towerIdByName[v] or steerTower end)
betaTab:Slider("Floor", false, 1, 25, steerWave, function(v) steerWave = v end)
betaTab:Button("Start speed steering", function()
	startHelper("steer", function() _G.__BS_CTX = core.ctx _G.__ST_TOWER = steerTower _G.__ST_WAVE = steerWave end)
end)
betaTab:Button("Stop speed steering", function() _G.__ST_STOP = true core.say("speed steering stop sent") end)
betaTab:Line("Equip a technique to a card (one command each, never automatic)")
betaTab:Label("Main game: techniqueId + base card id, e.g. fishermans_assault + awakened_sunblaze_shinigami. Deity: card id with rarity (card:rarity). The tower thread decides what goes where.")
local techId, techCard = "", ""
betaTab:Textbox("Technique id", false, false, function(v) techId = v end)
betaTab:Textbox("Card id", false, false, function(v) techCard = v end)
local function oneCommand(name, ...)
	if not core.isMain() then lib:Notification("Not on this account", "Whousleaks only.", nil, "Okay") return end
	local ok, err = core.init()
	if not ok then lib:Notification("Can't send", err, nil, "Okay") return end
	local other = core.otherScriptRunning()
	if other then lib:Notification("Game is busy", "Another script controls the game right now.", nil, "Okay") return end
	if techId == "" then lib:Notification("Missing", "Type the technique id first.", nil, "Okay") return end
	core.say("equip command", name, techId, techCard)
	core.send(name, ...)
end
betaTab:Button("Equip (main game)", function() if techCard == "" then lib:Notification("Missing", "Type the card id too.", nil, "Okay") return end oneCommand("equipTechnique", techId, techCard) end)
betaTab:Button("Unequip (main game)", function() oneCommand("unequipTechnique", techId) end)
betaTab:Button("Equip (Tower of Deity)", function() if techCard == "" then lib:Notification("Missing", "Type the card id too.", nil, "Okay") return end oneCommand("towerOfDeityAction", { kind = "equipTechnique", card = techCard, technique = techId }) end)
betaTab:Button("Unequip (Tower of Deity)", function() oneCommand("towerOfDeityAction", { kind = "equipTechnique", card = techCard ~= "" and techCard or nil, technique = nil }) end)
betaTab:Line("Ranked")
betaTab:Label("No ranked season right now (season 11 is not out). The recorder only reads, so it can run next to the farm.")
betaTab:Button("Start ranked recorder (read only)", function()
	if not core.isMain() or PREVIEW then lib:Notification("Preview only", "Nothing starts from this window.", nil, "Okay") return end
	local ok = pcall(run, "helpers/ranked_recorder") core.say(ok and "ranked recorder started" or "ranked recorder failed")
end)
betaTab:Button("Stop ranked recorder", function() _G.__RR_STOP = true end)

-- Planner (the director's two files; see src/planner.lua)
plannerTab:Line("What the director runs")
local plStatus = plannerTab:Label("No director status yet.")
plannerTab:Line("Director settings (the director applies a change within 5 minutes)")
local plControls = planner.controls(core.readJson(planner.CONFIG), core.readJson(planner.OVERRIDES))
if #plControls == 0 then
	plannerTab:Label("No director settings found (" .. planner.CONFIG .. " has no \"editable\" list yet). Close and reopen the window after the director has written it.")
end
plannerTab:Label("Hard bans (Dream tower, Joyride, memory floor) cannot be changed here. Refused changes show in the status above under rejected_overrides.")
for _, ctl in ipairs(plControls) do
	local title = ctl.key .. (ctl.pending and "  (waiting for the director)" or "")
	local function put(v)
		local val, why = planner.check(ctl, v)
		if val == nil then lib:Notification("Not saved", ctl.key .. ": " .. tostring(why), nil, "Okay") return end
		if not PREVIEW then planner.setOverride(ctl.key, val) end
	end
	if ctl.kind == "bool" then plannerTab:Toggle(title, ctl.value == true, put)
	elseif ctl.kind == "enum" then plannerTab:Dropdown(title, ctl.values or {}, put):Set(ctl.value, true)
	else plannerTab:Textbox(title, true, false, put):Set(ctl.value ~= nil and ctl.value or "") end
end

-- Status
local stLabel = statusTab:Label("Stopped")
local statLabel = statusTab:Label("")
statusTab:Line("Log")
local logLabel = statusTab:Label("")

-- Settings
setTab:Button("Dark theme", function() cfg.theme = "Dark" save() lib:ChangeTheme("Dark") end)
setTab:Button("Light theme", function() cfg.theme = "Light" save() lib:ChangeTheme("Light") end)
setTab:Bind("Show / hide window", lib.ToggleKey, false, true, function() end)
setTab:Textbox("Accounts it may run on (comma list)", false, false, function(v) cfg.account = v save() end):Set(cfg.account)
setTab:Toggle("Anti-AFK (small step every 10 min)", cfg.antiAfk, function(v) cfg.antiAfk = v save() end)
setTab:Label("This window is for " .. LP.Name .. ". Each account keeps its own settings and deck plans.")
setTab:Slider("Pause above game memory (MB)", false, 2000, 8000, cfg.memLimit, function(v) cfg.memLimit = v save() end)
setTab:Button("Stop and close", function() stop() _G.__ACCF_LOAD = nil lib:Destroy() end)

-- live status refresh
task.spawn(function()
	while lib.Gui and lib.Gui.Parent do
		local state = running and core.status or "Stopped"
		nowLabel:SetText((running and "Running · " or "") .. state)
		stLabel:SetText("<b>Now:</b> " .. state)
		statLabel:SetText(string.format("Fights won %d · lost %d · jobs %d%s", stats.win, stats.loss, stats.jobs,
			core.ctx and string.format(" · game memory %d MB", core.mem()) or ""))
		logLabel:SetText(table.concat(core.log, "\n", 1, math.min(#core.log, 12)))
		plStatus:SetText(planner.statusText(core.readJson(planner.STATUS)))
		if core.ctx then
			local ok, bp = pcall(core.backpack, "main")
			if ok then
				local rows, total = {}, 0
				for item, n in pairs(bp) do
					local size = tonumber(string.match(item, "^instant_roll_(%d+)$"))
					if size and n > 0 then table.insert(rows, { size, n }) total += size * n end
				end
				table.sort(rows, function(a, b) return a[1] > b[1] end)
				local o = {} for _, r in ipairs(rows) do table.insert(o, r[2] .. "x " .. r[1]) end
				packLabel:SetText(#o > 0 and (table.concat(o, ", ") .. "\n<b>" .. total .. " rolls total</b>") or "No instant packs.")
			end
			local k = skip.keys()
			if k then keyLabel:SetText("<b>Story Skip keys: " .. k .. "</b>" .. (k == 0 and "  (Story Skip stays off)" or "")) end
		end
		task.wait(1)
	end
end)

lib:Notification("Card Clash Farm" .. (PREVIEW and " (preview)" or ""), "Loaded. " .. lib.ToggleKey.Name .. " shows or hides the window." .. (PREVIEW and " Preview: nothing starts." or ""), nil, "Okay")
return { start = start, stop = stop, settings = cfg }
]===]
M["planner"] = [===[
-- Link to the farm director (the planner thread's program on the PC). Two plain files in the executor workspace, same ones the
-- headless script reads, so the window and the script never disagree:
--   AnimeCardClash/director_config.json   what the director may do (accounts, weights, allowed modes, worker budget ...). The window
--                                         shows every number / on-off / text field it finds and writes a change back to that one field.
--   AnimeCardClash/director_status.json   what the director decided (running now, next, ranking, workers, decisions, warnings).
-- The window never needs to know the exact field names: it lists what is in the files.
local core = ...
local planner = { CONFIG = "AnimeCardClash/director_config.json", STATUS = "AnimeCardClash/director_status.json", MAXROWS = 60 }

local function isArray(t) return type(t) == "table" and (#t > 0 or next(t) == nil) end

-- The director's config mirror says what may be changed: "editable" = { ["dotted.key"] = {kind = float|int|bool|enum, min, max | values} }.
-- Only those keys get a control. A change goes to AnimeCardClash/director_overrides.json as {"set": {"dotted.key": value}}; the director
-- applies valid keys on its next round (max 5 min) and lists refused ones under rejected_overrides (config + status files).
planner.OVERRIDES = "AnimeCardClash/director_overrides.json"

local function walk(cfg, dotted)
	local t = cfg
	for part in string.gmatch(dotted, "[^%.]+") do
		if type(t) ~= "table" then return nil end
		local n = tonumber(part)
		if n and t[n + 1] ~= nil then t = t[n + 1] else t = t[part] end   -- "orders.0" = first list entry
	end
	return t
end
planner.walk = walk

-- editable controls as { {key = "weights.completion_card_M", kind = "float", value = 0.5, min, max, values}, ...}, sorted by key
function planner.controls(cfg, overrides)
	local out = {}
	if type(cfg) ~= "table" or type(cfg.editable) ~= "table" then return out end
	local pending = type(overrides) == "table" and type(overrides.set) == "table" and overrides.set or {}
	local keys = {}
	for k in pairs(cfg.editable) do table.insert(keys, k) end
	table.sort(keys)
	for _, k in ipairs(keys) do
		if #out >= planner.MAXROWS then break end
		local spec = cfg.editable[k]
		if type(spec) == "table" then
			local v = walk(cfg, k)
			local shown = pending[k] ~= nil and pending[k] or v
			table.insert(out, { key = k, kind = spec.kind, value = shown, min = spec.min, max = spec.max, values = spec.values, pending = pending[k] ~= nil })
		end
	end
	return out
end

-- checks a typed value against the spec; returns the value to send or nil + why
function planner.check(ctl, v)
	if ctl.kind == "bool" then return v == true end
	if ctl.kind == "enum" then
		for _, x in ipairs(ctl.values or {}) do if x == v then return v end end
		return nil, "not one of the allowed values"
	end
	local n = tonumber(v)
	if not n then return nil, "not a number" end
	if ctl.kind == "int" then n = math.floor(n + 0.5) end
	if ctl.min and n < ctl.min then return nil, "below the minimum " .. ctl.min end
	if ctl.max and n > ctl.max then return nil, "above the maximum " .. ctl.max end
	return n
end

-- adds one key to the overrides file: reads it fresh, changes only that key, writes it back
function planner.setOverride(key, value)
	local o = core.readJson(planner.OVERRIDES)
	if type(o) ~= "table" then o = {} end
	if type(o.set) ~= "table" then o.set = {} end
	o.set[key] = value
	core.writeJson(planner.OVERRIDES, o)
	return true
end

-- a readable text for the status file; picks the usual name / state / score fields of list rows, shows everything else as key: value
local NAMEKEYS = { "name", "activity", "title", "mode", "label", "consumer", "id", "key" }
local EXTRA = { "state", "score", "now", "target", "delta", "value", "chance", "reason", "why", "eta" }
local function esc(s) return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")) end
local function short(v)
	if type(v) == "number" then return (v == math.floor(v)) and tostring(v) or string.format("%.2f", v) end
	return esc(v)
end
local function rowText(r)
	if type(r) ~= "table" then return short(r) end
	local parts = {}
	for _, k in ipairs(NAMEKEYS) do if r[k] ~= nil and type(r[k]) ~= "table" then table.insert(parts, "<b>" .. short(r[k]) .. "</b>") break end end
	for _, k in ipairs(EXTRA) do if r[k] ~= nil and type(r[k]) ~= "table" then table.insert(parts, k .. " " .. short(r[k])) end end
	if #parts == 0 then
		local keys = {}
		for k, v in pairs(r) do if type(v) ~= "table" then table.insert(keys, k) end end
		table.sort(keys)
		for i = 1, math.min(#keys, 4) do table.insert(parts, tostring(keys[i]) .. " " .. short(r[keys[i]])) end
	end
	return table.concat(parts, " · ")
end
function planner.statusText(st)
	if type(st) ~= "table" then return "No director status yet (the director has not written " .. planner.STATUS .. ")." end
	local lines, keys = {}, {}
	if type(st.text) == "string" then table.insert(lines, esc(st.text)) end
	for k in pairs(st) do if k ~= "text" and k ~= "updated" then table.insert(keys, k) end end
	table.sort(keys, function(a, b)   -- the usual headline fields first
		local order = { now = 1, running = 1, next = 2, decisions_for_sami = 3, ranking = 4, plan = 5, workers = 6, warnings = 7, rejected_overrides = 8 }
		local oa, ob = order[a] or 9, order[b] or 9
		if oa ~= ob then return oa < ob end
		return tostring(a) < tostring(b)
	end)
	for _, k in ipairs(keys) do
		if #lines >= 40 then break end
		local v = st[k]
		if type(v) ~= "table" then table.insert(lines, esc(k) .. ": " .. short(v))
		elseif isArray(v) then
			table.insert(lines, "<b>" .. esc(k) .. "</b>")
			for i = 1, math.min(#v, 6) do table.insert(lines, "  " .. rowText(v[i])) end
			if #v > 6 then table.insert(lines, "  … " .. (#v - 6) .. " more") end
		else
			table.insert(lines, "<b>" .. esc(k) .. "</b>")
			local sub = {}
			for k2, v2 in pairs(v) do table.insert(sub, k2) end
			table.sort(sub, function(a, b) return tostring(a) < tostring(b) end)
			for i = 1, math.min(#sub, 8) do
				local v2 = v[sub[i]]
				if type(v2) == "table" and isArray(v2) then
					table.insert(lines, "  " .. esc(sub[i]))
					for j = 1, math.min(#v2, 6) do table.insert(lines, "    " .. rowText(v2[j])) end
				else
					table.insert(lines, "  " .. esc(sub[i]) .. ": " .. (type(v2) == "table" and rowText(v2) or short(v2)))
				end
			end
		end
	end
	local age = type(st.updated) == "number" and (os.time() - st.updated) or nil
	if age and age > 900 then table.insert(lines, 1, "<b>Director status is " .. math.floor(age / 60) .. " min old</b>") end
	return table.concat(lines, "\n")
end

return planner
]===]
M["tasks/extras"] = [===[
-- Small jobs that are not fights: opening instant packs, daily login, daily quests, and a read-only probe that
-- saves what the game shows for ranked / events so those can be wired up after one live look.
local core, data = ...
local extras = {}

-- ---------- instant packs ----------
-- useBackpackItem({item, amount, domain}) is what the Backpack screen sends (shared/react/views/Backpack/Screen).
extras.packs = { id = "instant_packs", name = "Open instant packs" }
local lastOpen = 0
function extras.packs.next(cfg)
	if os.clock() - lastOpen < 20 then return nil end
	local bp = core.backpack("main")
	local list = {}
	for item, n in pairs(bp) do
		local size = tonumber(string.match(item, "^instant_roll_(%d+)$"))
		if size and type(n) == "number" and n > 0 and size >= cfg.packMinSize then table.insert(list, { item = item, size = size, n = n }) end
	end
	if #list == 0 then return nil end
	table.sort(list, function(a, b) if cfg.packBigFirst then return a.size > b.size end return a.size < b.size end)
	local p = list[1]
	return { kind = "packs", item = p.item, amount = math.min(p.n, cfg.packPerUse), label = "Open " .. math.min(p.n, cfg.packPerUse) .. "x " .. p.item }
end
function extras.runPacks(job)
	lastOpen = os.clock()
	core.say(job.label)
	core.send("useBackpackItem", { item = job.item, amount = job.amount, domain = "main" })
	core.wait(3)
	return "done"
end

-- ---------- dailies ----------
extras.dailies = { id = "dailies", name = "Daily login + daily quests" }
local lastDaily, loginDay = 0, 0
local function findDailyQuests()
	local u = core.user()
	local q = u and u.questProgress
	local d = q and (q.daily or q.dailyQuests)
	if type(d) ~= "table" then return nil end
	return d.quests or d
end
function extras.dailies.next(cfg)
	if os.clock() - lastDaily < 600 then return nil end
	return { kind = "dailies", label = "Claim daily login + daily quests" }
end
function extras.runDailies(job, cfg)
	lastDaily = os.clock()
	local day = core.dayStart()
	if cfg.dailyLogin and loginDay ~= day then
		loginDay = day
		core.say("claim daily login")
		core.send("claimDailyLogin")
	end
	if cfg.dailyQuests then
		local qs = findDailyQuests()
		if type(qs) == "table" then
			for idx, st in pairs(qs) do
				if type(st) == "table" and st.claimed == false then
					core.say("claim daily quest", idx)
					core.send("claimDailyQuest", type(st.idx) == "number" and st.idx or idx)
				end
			end
		else
			core.say("daily quests: list not found (needs a live look)")
		end
	end
	return "done"
end

-- ---------- probe (read only, sends nothing) ----------
function extras.probe()
	local u = core.user()
	local out = { time = os.time(), place = core.place(), userKeys = {}, backpackPacks = {} }
	for k, v in pairs(u or {}) do out.userKeys[tostring(k)] = type(v) end
	for item, n in pairs(core.backpack("main")) do if string.find(item, "instant_roll", 1, true) then out.backpackPacks[item] = n end end
	local function keys(t, depth)
		if type(t) ~= "table" or depth > 2 then return type(t) end
		local r, c = {}, 0
		for k, v in pairs(t) do c += 1 if c > 40 then break end r[tostring(k)] = keys(v, depth + 1) end
		return r
	end
	out.questProgress = keys(u and u.questProgress, 0)
	out.ranked = keys(u and (u.ranked or u.rankedState), 0)
	out.towerOfDeity = keys(u and u.towerOfDeity, 0)
	core.writeJson("acc-farm/probe.json", out)
	core.say("saved acc-farm/probe.json (read only)")
end

return extras
]===]
M["tasks/story"] = [===[
-- Story: first clears (in game order), daily boss repeats (stage 6 of every difficulty drops instant packs) and the
-- story towers (infinite, crystals for luck gear). Calls taken from story_climber.lua / tower_farm.lua (tested live):
--   teleport(world); fightStoryBoss(serverBossId, difficulty, "slot_15") from any distance;
--   a lost story fight restarts itself (restartCount grows) -> forfeitBattle; fightInfinite(world, nil, "slot_15").
local core, data, decks = ...
local story = {}
local fails, failDay = {}, 0
local function resetFails() local d = core.dayStart() if d ~= failDay then failDay, fails = d, {} end end

local function state(world, boss, diff)
	local u = core.user()
	local a = u and u.storyProgress and u.storyProgress[world]
	a = a and a[boss]
	return a and a[diff]
end
local function done(world, boss, diff) local s = state(world, boss, diff) return s ~= nil and s.completed == true end
local DIFFS = data.difficulties

-- game order: world by world (a world needs the previous world's normal bosses), difficulty after difficulty,
-- boss after boss inside a difficulty
local function openStage(w, wi, diff, di, b)
	if wi > 1 then
		local prev = data.worlds[wi - 1]
		for _, pb in ipairs(prev.bosses.normal) do if not done(prev.id, pb.boss, "normal") then return false end end
	end
	if di > 1 and not done(w.id, b.boss, DIFFS[di - 1]) then return false end
	for _, ob in ipairs(w.bosses[diff]) do
		if ob.stage < b.stage and not done(w.id, ob.boss, diff) then return false end
	end
	return true
end

story.clear = { id = "story_clear", name = "Story first clears" }
function story.clear.next(cfg)
	resetFails()
	for wi, w in ipairs(data.worlds) do
		for di, diff in ipairs(DIFFS) do
			if cfg.storyDiffs[diff] then
				for _, b in ipairs(w.bosses[diff]) do
					local k = w.id .. ":" .. diff .. ":" .. b.boss
					if not done(w.id, b.boss, diff) and (fails[k] or 0) < cfg.maxLosses and openStage(w, wi, diff, di, b) then
						return { kind = "story", world = w.id, diff = diff, boss = b.boss, key = k, decks = decks.story(w.id, diff, b.boss),
							label = w.name .. " " .. diff .. " " .. b.name .. " (first clear)" }
					end
				end
			end
		end
	end
end

story.repeats = { id = "story_repeat", name = "Story boss repeats (packs)" }
function story.repeats.next(cfg)
	resetFails()
	local day, best = core.dayStart(), nil
	for _, w in ipairs(data.worlds) do
		for _, diff in ipairs(DIFFS) do
			if cfg.storyDiffs[diff] then
				for _, b in ipairs(w.bosses[diff]) do
					local k = w.id .. ":" .. diff .. ":" .. b.boss
					if (b.rolls > 0 or cfg.storyRepeatAll) and (fails[k] or 0) < cfg.maxLosses then
						local s = state(w.id, b.boss, diff)
						if s and s.completed and (s.lastWin or 0) < day and (not best or b.rolls > best.rolls) then
							best = { kind = "story", world = w.id, diff = diff, boss = b.boss, key = k, rolls = b.rolls, decks = decks.story(w.id, diff, b.boss),
								label = w.name .. " " .. diff .. " " .. b.name .. " repeat (" .. b.rolls .. " rolls)" }
						end
					end
				end
			end
		end
	end
	return best
end

local function bossEntity(id)
	for e, b in core.ctx.world:query(core.comps.Boss) do if b.id == id then return e, b end end
end

local function goTo(world)
	if core.place() == world then return true end
	core.say("teleport to", world)
	core.send("teleport", world)
	local t0 = os.clock()
	while core.place() ~= world and os.clock() - t0 < 45 do if not core.wait(1.5) then return false end end
	if core.place() ~= world then return false end
	return core.wait(3)
end

function story.run(job, cfg)
	local k = job.key
	local attempt = (fails[k] or 0) + 1
	if not core.waitFree(60) then core.forfeitAll() end
	if not goTo(job.world) then core.say("teleport failed") fails[k] = (fails[k] or 0) + 1 return "noteleport" end
	local deck = decks.pick(job.decks, attempt)
	if deck and not core.setDeck(deck) then core.say("deck could not be set, skipping") fails[k] = cfg.maxLosses return "deckfail" end
	local e
	local t0 = os.clock()
	repeat e = bossEntity(job.boss) if not e then if not core.wait(1.5) then return "stopped" end end until e or os.clock() - t0 > 30
	if not e then core.say("boss not found", job.boss) fails[k] = cfg.maxLosses return "noboss" end
	local srv = core.serverId(e)
	if not srv then fails[k] = (fails[k] or 0) + 1 return "nosrv" end
	if cfg.timed then   -- story_scan_watcher.py on the PC answers with winning start seconds
		local r = core.askTimes(core.dir() .. "sc_need.json", core.dir() .. "story_times_" .. job.world .. "_" .. job.diff .. "_" .. job.boss .. ".json",
			{ world = job.world, diff = job.diff, boss = job.boss, deck = -1, pairs = core.deck, from = math.floor(core.now()) + 6, to = math.floor(core.now()) + 96 }, 75)
		local T
		if r then for _, s in ipairs(r.safe or r.wins or {}) do if s >= core.now() + 4 then T = s break end end end
		if T and not core.waitUntil(T) then return "stopped" end
	end
	local was = state(job.world, job.boss, job.diff)
	local lastWin0 = was and was.lastWin or 0
	core.say("FIGHT", job.label, deck and ("deck " .. core.deckText(deck)) or "deck as is")
	core.send("fightStoryBoss", srv, job.diff, core.SLOT)
	local seen, goneFor, hid = false, 0, false
	local t1 = os.clock()
	local wasDone = was ~= nil and was.completed == true
	local function won()
		local s = state(job.world, job.boss, job.diff)
		if not (s and s.completed) then return false end
		return not wasDone or (s.lastWin or 0) ~= lastWin0
	end
	while os.clock() - t1 < cfg.fightTimeout do
		if not core.wait(2) then return "stopped" end
		if won() then core.say("WON", job.label) fails[k] = 0 return "win" end
		local ss, ents = core.sessions()
		if ss[1] then
			seen, goneFor = true, 0
			if cfg.hideFights and not hid and ss[1].displayState ~= "hidden" then core.hide(ents[1]) hid = true end
			core.status = job.label
			if (ss[1].restartCount or 0) > 0 then core.say("lost, ending the fight") core.forfeitAll() break end
		elseif seen then
			goneFor += 2
			if goneFor >= 8 then break end
		elseif os.clock() - t1 > 40 then
			core.say("the fight did not start") break
		end
	end
	if won() then fails[k] = 0 return "win" end
	if #core.sessions() > 0 then core.forfeitAll() end
	fails[k] = (fails[k] or 0) + 1
	core.say("LOST", job.label, "loss", fails[k], "of", cfg.maxLosses)
	return "loss"
end

-- ---------- story tower (infinite): runs for a while, then hands the game back to the queue ----------
story.tower = { id = "story_tower", name = "Story tower crystals" }
function story.tower.next(cfg)
	if not cfg.storyTowerWorld or cfg.storyTowerWorld == "" then return nil end
	return { kind = "infinite", world = cfg.storyTowerWorld, label = "Story tower " .. cfg.storyTowerWorld }
end
function story.runTower(job, cfg, higherWaiting)
	local t0 = os.clock()
	local hid = {}
	while os.clock() - t0 < cfg.storyTowerMinutes * 60 do
		local ss, ents = core.sessions()
		local s, e = ss[1], ents[1]
		if not s then
			if not core.wait(3) then return "stopped" end
			if #core.sessions() == 0 then
				core.say("start / continue", job.label)
				core.send("fightInfinite", job.world, nil, core.SLOT)
				if not core.wait(8) then return "stopped" end
			end
		elseif s.type ~= "infinite_tower" or s.mode ~= job.world then
			core.say("another fight is running, waiting") if not core.wait(10) then return "stopped" end
		else
			if cfg.hideFights and not hid[e] and s.displayState ~= "hidden" then core.hide(e) hid[e] = true end
			core.status = job.label .. " · floor " .. tostring(s.floor)
			if higherWaiting() then core.say("something more important is ready, pausing the story tower") break end
			if not core.wait(5) then return "stopped" end
		end
	end
	local _, ents = core.sessions()
	if ents[1] then core.send("pauseInfinite", job.world) core.waitFree(30) end
	return "done"
end

return story
]===]
M["tasks/storyskip"] = [===[
-- Story Skip: one fight against the last boss of a world's highest cleared difficulty; it costs one Story Skip key
-- (win or lose) and pays that world's daily repeat rewards. Same flow as tasks/2026-10-17-storyskip/storyskip.lua
-- (won live on Solo City, 2026-10-17):
--   write AnimeCardClash/storyskip_want.json {world, diff, t} -> ss_watch.py on the PC scans the next minutes and writes
--   AnimeCardClash/storyskip_times_<world>.json {made, ok, deck, safe, winRate} -> deck into slot_15 -> fightStorySkip(world,
--   "slot_15") at a safe server second + 0.35 s -> wait for the end, forfeit if the game restarts a lost fight.
-- The farm only takes this job when there is a key and the world has rewards to claim.
local core = ...
local RS = game:GetService("ReplicatedStorage")
local skip = { id = "story_skip", name = "Story Skip (keys)" }

-- Story Skip worlds in the game's list order; the last two have no winning deck yet (world_overview.md)
skip.WORLDS = {
	{ "eminence_lookout", "Eminence Lookout" }, { "invaded_ninja_village", "Invaded Ninja Village" }, { "necromancer_graveyard", "Necromancer Graveyard" },
	{ "shibuya_station", "Shibuya Station" }, { "soul_king_castle", "Soul King Castle" }, { "empire_of_light", "Empire of Light" },
	{ "defense_force_base", "Defense Force Base" }, { "slime_city", "Slime City" }, { "heros_palace", "Hero's Palace" },
	{ "knight_kingdom", "Knight Kingdom" }, { "candy_island", "Candy Island" }, { "bizarre_manor", "Bizarre Manor" },
	{ "ninja_village", "Ninja Village" }, { "green_planet", "Green Planet" }, { "titans_city", "Titans City" },
	{ "dimensional_fortress", "Dimensional Fortress" }, { "solo_city", "Solo City" },
	{ "clover_hideout", "Clover Hideout", off = true }, { "deity_planet", "Deity Planet", off = true },
}
local DIFF = "celestial"   -- the planner only scans the celestial final boss
local LEAD = 8             -- seconds needed between the plan arriving and the start (deck change)

local libs
local function gameLibs()
	if libs == nil then
		local ok, a, b = pcall(function() return require(RS.shared.game.storySkip), require(RS.common.result) end)
		libs = ok and { skip = a, result = b } or false
	end
	return libs or nil
end

-- keys in the backpack, nil when the game can't be read
function skip.keys()
	local ok, n = pcall(function() return core.backpack("main").story_skip_key end)
	if not ok then return nil end
	return n or 0
end

-- same call the Story Skip screen makes; nil when the game won't tell
local function rewards(world)
	local L = gameLibs()
	if not L then return nil end
	local ok, r = pcall(function() return L.skip.getAvailableRepeatRewards(world, core.user().storyProgress) end)
	if not ok or not L.result.isOk(r) then return nil end
	local v, cd = r.value, 0
	for _ in pairs(v.onCooldown) do cd += 1 end
	return { count = #v.rewards, bosses = v.bossCount, cooldown = cd, diff = v.highestDifficulty, open = #v.rewards > 0 and cd < v.bossCount }
end

local function session()
	for e, v in core.ctx.world:query(core.comps.BattleSession) do if v.type == "story_skip" then return e, v end end
end

-- a world is left alone for the rest of the game day after a loss, a missing plan or "no winning seconds"
local skipped, skippedDay, helperQuietUntil = {}, 0, 0
local function resetDay() local d = core.dayStart() if d ~= skippedDay then skippedDay, skipped = d, {} end end

function skip.next(cfg)
	if not core.isMain() then return nil end   -- keys, plans and ss_watch.py are Whousleaks's
	resetDay()
	if os.clock() < helperQuietUntil then return nil end
	local k = skip.keys()
	if not k or k < 1 then return nil end
	for _, w in ipairs(skip.WORLDS) do
		local id = w[1]
		if cfg.skipWorlds[id] and not skipped[id] then
			local rw = rewards(id)
			if rw and rw.open and rw.diff == DIFF then
				return { kind = "storyskip", world = id, label = "Story Skip " .. w[2] .. " (" .. k .. " keys)" }
			end
		end
	end
end

function skip.run(job, cfg)
	local world = job.world
	if not core.waitFree(60) then core.forfeitAll() end
	if session() then core.say("a Story Skip fight is already open") return "busy" end
	local want = math.floor(core.now())
	core.writeJson("AnimeCardClash/storyskip_want.json", { world = world, diff = DIFF, t = want })
	core.say("Story Skip", world, ": asking the PC for winning seconds")
	core.status = job.label .. " · waiting for the PC scan"
	local plan
	local t0 = os.clock()
	while os.clock() - t0 < cfg.skipPlanWait do
		if not core.wait(2) then return "stopped" end
		local p = core.readJson("AnimeCardClash/storyskip_times_" .. world .. ".json")
		if type(p) == "table" and type(p.made) == "number" and p.made >= want - 2 then plan = p break end
	end
	if not plan then
		core.say("no answer from the PC (is ss_watch.py running?), Story Skip waits 30 min")
		helperQuietUntil = os.clock() + 1800
		return "noplan"
	end
	if not plan.ok or type(plan.safe) ~= "table" or type(plan.deck) ~= "table" then
		core.say("Story Skip", world, ": no winning start with any deck (", tostring(plan.winRate), "), skipped today")
		skipped[world] = true
		return "noplan"
	end
	if not core.setDeck(plan.deck) then core.say("deck could not be set, skipping") skipped[world] = true return "deckfail" end
	local now, T = core.now(), nil
	for _, s in ipairs(plan.safe) do if s >= now + LEAD then T = s break end end
	if not T then core.say("plan ran out while the deck was set, trying again") return "late" end
	local k0 = skip.keys()
	core.say("FIGHT Story Skip", world, "at", T, "deck", core.deckText(plan.deck))
	core.status = job.label .. " · starting in " .. math.floor(T - now) .. " s"
	if not core.waitUntil(T) then return "stopped" end
	core.send("fightStorySkip", world, core.SLOT)
	local e, s
	for _ = 1, 20 do if not core.wait(0.5) then return "stopped" end e, s = session() if s then break end end
	if s then core.say("seed", tostring(s.seed), s.seed == T and "on target" or ("off target, wanted " .. T)) end
	local restarts0 = s and s.restartCount or 0
	local t1 = os.clock()
	while session() and os.clock() - t1 < cfg.fightTimeout do
		if not core.wait(2) then return "stopped" end
		local e2, s2 = session()
		if s2 and (s2.restartCount or 0) > restarts0 then
			core.say("lost, ending the fight")
			local srv = core.serverId(e2)
			if srv then core.send("forfeitBattle", srv) end
			core.wait(3)
			break
		end
	end
	core.wait(3)
	local after = rewards(world)
	local won = after ~= nil and not after.open
	core.writeJson("acc-farm/storyskip_last.json", { t = os.time(), world = world, target = T, seed = s and s.seed, won = won, keysBefore = k0, keysAfter = skip.keys() })
	if won then core.say("WON Story Skip", world, ", keys left", tostring(skip.keys())) return "win" end
	skipped[world] = true
	core.say("LOST Story Skip", world, ", skipped today, keys left", tostring(skip.keys()))
	return "loss"
end

return skip
]===]
M["tasks/towers"] = [===[
-- Battle towers: first clears (one-time rewards, unlock the next wave) and daily repeat rewards (the wave-25 style
-- repeats that drop instant packs). Fight = fightBattleTowerWave(mode, wave, "slot_15"); one session plays all floors
-- of the wave by itself; won when battleTowerProgress[mode][wave].lastWin changes; a lost floor ends the session.
local core, data, decks = ...
local towers = {}
local fails = {}   -- ["mode:wave"] = losses this game day
local failDay = 0

local function prog(mode, wave)
	local u = core.user()
	local a = u and u.battleTowerProgress and u.battleTowerProgress[mode]
	return a and (a[wave] or a[tostring(wave)])
end
local function done(mode, wave) local p = prog(mode, wave) return p ~= nil and p.completed == true end
local function unlocked(t, wave)
	if wave > 1 then return done(t.id, wave - 1) end
	return not t.requires or done(t.requires.mode, t.requires.wave)
end
local function resetFails() local d = core.dayStart() if d ~= failDay then failDay, fails = d, {} end end
local function key(mode, wave) return mode .. ":" .. wave end

towers.byId = {}
for _, t in ipairs(data.towers) do towers.byId[t.id] = t end

-- ---------- first clears ----------
towers.clear = { id = "tower_clear", name = "Tower first clears" }
function towers.clear.next(cfg)
	resetFails()
	for _, id in ipairs(cfg.towerOrder) do
		local t = towers.byId[id]
		if t and cfg.towers[id] then
			for wave = 1, t.waves do
				if not done(id, wave) then
					if unlocked(t, wave) and (fails[key(id, wave)] or 0) < cfg.maxLosses then
						local list, rate = decks.tower(id, wave)
						if not (rate and rate < cfg.minRate / 100) then
							return { kind = "tower", mode = id, wave = wave, decks = list, rate = rate, label = t.name .. " floor " .. wave .. " (first clear)" }
						end
					end
					break   -- waves unlock in order: the first open one decides; move on to the next tower
				end
			end
		end
	end
end

-- ---------- daily repeats ----------
towers.repeats = { id = "tower_repeat", name = "Tower repeat rewards (packs)" }
function towers.repeats.next(cfg)
	resetFails()
	local day = core.dayStart()
	local best
	for _, id in ipairs(cfg.towerOrder) do
		local t = towers.byId[id]
		if t and cfg.repeatTowers[id] then
			for wave = 1, t.waves do
				local rolls = t.repeatRolls[tostring(wave)] or 0
				if (rolls > 0 or cfg.repeatAll) and done(id, wave) and (fails[key(id, wave)] or 0) < cfg.maxLosses then
					local p = prog(id, wave)
					if (p.lastWin or 0) < day then
						if not best or rolls > best.rolls then
							local list = decks.tower(id, wave)
							best = { kind = "tower", mode = id, wave = wave, decks = list, rolls = rolls, repeatRun = true, label = t.name .. " floor " .. wave .. " repeat (" .. rolls .. " rolls)" }
						end
					end
				end
			end
		end
	end
	return best
end

-- ---------- one fight (shared) ----------
function towers.run(job, cfg)
	local k = key(job.mode, job.wave)
	local attempt = (fails[k] or 0) + 1
	if not core.waitFree(30) then
		core.say("an old fight is still running, ending it")
		core.forfeitAll()
	end
	local deck = decks.pick(job.decks, attempt)
	if deck then
		if not core.setDeck(deck) then core.say("deck could not be set, skipping", job.label) fails[k] = cfg.maxLosses return "deckfail" end
	end
	if core.stopped() then return "stopped" end
	-- optional timed start on a second the PC engine predicts to win (tower_watcher.py)
	if cfg.timed then
		local r = core.askTimes(core.dir() .. "tw_need.json", core.dir() .. "tw_times_" .. job.mode .. "_" .. job.wave .. ".json",
			{ tower = job.mode, wave = job.wave, pairs = core.deck, moon = "none", from = math.floor(core.now()) + 8, to = math.floor(core.now()) + 608 }, 120)
		if r and r.safe then
			local T
			for _, s in ipairs(r.safe) do if s >= core.now() + 5 then T = s break end end
			if T then core.say("timed start in", math.floor(T - core.now()), "s") if not core.waitUntil(T) then return "stopped" end end
		end
	end
	local before = prog(job.mode, job.wave)
	local lastWin0 = before and before.lastWin or 0
	core.say("FIGHT", job.label, deck and ("deck " .. core.deckText(deck)) or "deck as is")
	core.send("fightBattleTowerWave", job.mode, job.wave, core.SLOT)
	local seen, goneFor, hid = false, 0, false
	local t0 = os.clock()
	while os.clock() - t0 < cfg.fightTimeout do
		if not core.wait(3) then return "stopped" end
		local p = prog(job.mode, job.wave)
		if p and p.lastWin and p.lastWin ~= lastWin0 then core.say("WON", job.label) fails[k] = 0 return "win" end
		local ss, ents = core.sessions()
		local s = ss[1]
		if s then
			seen, goneFor = true, 0
			if cfg.hideFights and not hid and s.displayState ~= "hidden" then core.hide(ents[1]) hid = true end
			core.status = job.label .. " · floor " .. tostring((s.restartCount or 0) + 1)
		elseif seen then
			goneFor += 3
			if goneFor >= 15 then break end
		elseif os.clock() - t0 > 30 then
			core.say("the fight did not start", job.label)
			fails[k] = (fails[k] or 0) + 1
			return "nostart"
		end
	end
	local p = prog(job.mode, job.wave)
	if p and p.lastWin and p.lastWin ~= lastWin0 then fails[k] = 0 return "win" end
	if #core.sessions() > 0 then core.say("fight too long, ending it") core.forfeitAll() end
	fails[k] = (fails[k] or 0) + 1
	core.say("LOST", job.label, "loss", fails[k], "of", cfg.maxLosses)
	return "loss"
end

return towers
]===]
M["ui"] = [===[
-- dawidlib (rewrite). Same API as Sami's old lib, plus: drag anywhere on the title bar, resize from the bottom-right
-- corner, minimise, a hide key (RightControl by default), and objects you can update later (:Set / :Get / :SetText).
--   local lib = loadstring(...)()
--   local win = lib:Window("Title")            win:Label("Section")    local tab = win:Tab(name, icon, color)
--   tab:Line(text) tab:Button(text, cb) tab:Label(text) tab:Toggle(text, default, cb) tab:Slider(text, decimals, min, max, default, cb)
--   tab:Bind(text, key, hold, _, cb) tab:Textbox(text, numbersOnly, clearOnFocus, cb) tab:RadioButtons(text, options, cb)
--   tab:Dropdown(text, options, cb) tab:Colorpicker(text, color, cb) tab:Order(text, items, cb)  (reorderable list)
--   lib:Notification(title, text, icon, button) lib:ChangeTheme("Dark"|"Light") lib:Destroy()
--   globals (old API): ChangeLabelText(oldPart, new) ChangeLabelColor(text, r, g, b) ResetLabelColor()
local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local CoreGui = game:GetService("CoreGui")

local lib = { Flags = {}, ToggleKey = Enum.KeyCode.RightControl }
local THEMES = {
	Dark = { bg = Color3.fromRGB(22, 23, 28), side = Color3.fromRGB(28, 29, 36), card = Color3.fromRGB(35, 37, 46), cardHover = Color3.fromRGB(44, 46, 58),
		text = Color3.fromRGB(235, 236, 242), sub = Color3.fromRGB(150, 154, 170), line = Color3.fromRGB(52, 54, 66), accent = Color3.fromRGB(110, 140, 255) },
	Light = { bg = Color3.fromRGB(244, 245, 249), side = Color3.fromRGB(232, 234, 241), card = Color3.fromRGB(255, 255, 255), cardHover = Color3.fromRGB(238, 240, 248),
		text = Color3.fromRGB(28, 30, 38), sub = Color3.fromRGB(105, 110, 128), line = Color3.fromRGB(214, 217, 228), accent = Color3.fromRGB(80, 110, 235) },
}
local theme = THEMES.Dark
local painted = {}   -- {inst, prop, key} repainted on theme change
local labels = {}    -- every Label object, for the old global helpers

local function new(class, props, children)
	local o = Instance.new(class)
	for k, v in pairs(props or {}) do if k ~= "Parent" then o[k] = v end end
	for _, c in ipairs(children or {}) do c.Parent = o end
	if props and props.Parent then o.Parent = props.Parent end
	return o
end
local function paint(inst, prop, key) inst[prop] = theme[key] table.insert(painted, { inst, prop, key }) return inst end
local function round(r) return new("UICorner", { CornerRadius = UDim.new(0, r or 8) }) end
local function pad(p) return new("UIPadding", { PaddingLeft = UDim.new(0, p), PaddingRight = UDim.new(0, p), PaddingTop = UDim.new(0, p), PaddingBottom = UDim.new(0, p) }) end
local function tween(o, t, props) TweenService:Create(o, TweenInfo.new(t, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props):Play() end
local function text(props)
	local t = new("TextLabel", { BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd })
	for k, v in pairs(props) do t[k] = v end
	return t
end

local function guiParent()
	local ok, h = pcall(function() return gethui and gethui() end)
	if ok and h then return h end
	local ok2 = pcall(function() local _ = CoreGui.Name end)
	return ok2 and CoreGui or Players.LocalPlayer:WaitForChild("PlayerGui")
end

function lib:ChangeTheme(name)
	theme = THEMES[name] or THEMES.Dark
	for _, p in ipairs(painted) do if p[1].Parent ~= nil or p[1] == lib.Gui then pcall(function() p[1][p[2]] = theme[p[3]] end) end end
	for _, l in ipairs(labels) do if not l.custom then l.inst.TextColor3 = theme.text end end
end

function lib:Destroy()
	if lib.Gui then lib.Gui:Destroy() end
	for _, c in ipairs(lib.conns or {}) do c:Disconnect() end
end

function lib:Notification(title, body, icon, button, seconds)
	if not lib.Gui then return end
	local holder = lib.Gui:FindFirstChild("Notes")
	local n = new("Frame", { Size = UDim2.new(1, 0, 0, 64), Parent = holder }, { round(10), pad(10) })
	paint(n, "BackgroundColor3", "card")
	if icon and icon ~= "" then new("ImageLabel", { BackgroundTransparency = 1, Image = icon, Size = UDim2.fromOffset(22, 22), Position = UDim2.fromOffset(0, 2), Parent = n }) end
	local x = (icon and icon ~= "") and 30 or 0
	paint(text({ Text = tostring(title), Font = Enum.Font.GothamBold, Size = UDim2.new(1, -x, 0, 18), Position = UDim2.fromOffset(x, 0), Parent = n }), "TextColor3", "text")
	paint(text({ Text = tostring(body), TextWrapped = true, TextTruncate = Enum.TextTruncate.None, Size = UDim2.new(1, -x, 0, 30), Position = UDim2.fromOffset(x, 18), TextYAlignment = Enum.TextYAlignment.Top, Parent = n }), "TextColor3", "sub")
	local function close() if n.Parent then n:Destroy() end end
	if button then
		local b = new("TextButton", { Text = button, Font = Enum.Font.GothamBold, TextSize = 12, AutoButtonColor = false, Size = UDim2.fromOffset(56, 22), Position = UDim2.new(1, -56, 1, -22), Parent = n }, { round(6) })
		b.BackgroundColor3 = theme.accent b.TextColor3 = Color3.new(1, 1, 1)
		b.MouseButton1Click:Connect(close)
	end
	task.delay(seconds or 6, close)
end

function lib:Window(title)
	local old = guiParent():FindFirstChild("dawidlib")
	if old then old:Destroy() end
	painted, labels, lib.conns = {}, {}, {}
	local gui = new("ScreenGui", { Name = "dawidlib", ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, IgnoreGuiInset = true })
	pcall(function() if syn and syn.protect_gui then syn.protect_gui(gui) end end)
	gui.Parent = guiParent()
	lib.Gui = gui
	new("Frame", { Name = "Notes", BackgroundTransparency = 1, Size = UDim2.fromOffset(270, 400), AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -16, 1, -16), Parent = gui },
		{ new("UIListLayout", { Padding = UDim.new(0, 8), VerticalAlignment = Enum.VerticalAlignment.Bottom, SortOrder = Enum.SortOrder.LayoutOrder }) })

	local MIN = Vector2.new(460, 300)
	local main = new("Frame", { Name = "Main", Size = UDim2.fromOffset(620, 420), Position = UDim2.new(0.5, -310, 0.5, -210), ClipsDescendants = true, Parent = gui }, { round(12) })
	paint(main, "BackgroundColor3", "bg")
	paint(new("UIStroke", { Thickness = 1, Transparency = 0.3, Parent = main }), "Color", "line")

	local top = new("Frame", { Name = "Top", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 40), Parent = main })
	paint(text({ Text = title or "Anime Card Clash", Font = Enum.Font.GothamBold, TextSize = 15, Size = UDim2.new(1, -110, 1, 0), Position = UDim2.fromOffset(16, 0), Parent = top }), "TextColor3", "text")
	local function topButton(glyph, x)
		local b = new("TextButton", { Text = glyph, Font = Enum.Font.GothamBold, TextSize = 14, AutoButtonColor = false, Size = UDim2.fromOffset(26, 26), Position = UDim2.new(1, x, 0, 7), Parent = top }, { round(8) })
		paint(b, "BackgroundColor3", "card") paint(b, "TextColor3", "sub")
		return b
	end
	local closeB, minB = topButton("×", -36), topButton("–", -66)

	local side = new("ScrollingFrame", { Name = "Side", Size = UDim2.new(0, 150, 1, -48), Position = UDim2.fromOffset(8, 40), ScrollBarThickness = 0, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, BorderSizePixel = 0, Parent = main },
		{ round(10), pad(6), new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }) })
	paint(side, "BackgroundColor3", "side")
	local pages = new("Frame", { Name = "Pages", BackgroundTransparency = 1, Size = UDim2.new(1, -174, 1, -48), Position = UDim2.fromOffset(166, 40), Parent = main })
	local grip = new("TextButton", { Text = "", AutoButtonColor = false, BackgroundTransparency = 1, Size = UDim2.fromOffset(18, 18), Position = UDim2.new(1, -18, 1, -18), ZIndex = 5, Parent = main })
	local gripDot = new("Frame", { Size = UDim2.fromOffset(8, 8), Position = UDim2.fromOffset(5, 5), Parent = grip }, { round(4) })
	paint(gripDot, "BackgroundColor3", "line")

	-- drag (title bar) and resize (corner grip)
	local mode, startPos, startMouse, startSize
	table.insert(lib.conns, top.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then mode, startMouse, startPos = "drag", i.Position, main.Position end
	end))
	table.insert(lib.conns, grip.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then mode, startMouse, startSize = "size", i.Position, main.AbsoluteSize end
	end))
	table.insert(lib.conns, UIS.InputChanged:Connect(function(i)
		if not mode or (i.UserInputType ~= Enum.UserInputType.MouseMovement and i.UserInputType ~= Enum.UserInputType.Touch) then return end
		local d = i.Position - startMouse
		if mode == "drag" then
			main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
		else
			main.Size = UDim2.fromOffset(math.max(MIN.X, startSize.X + d.X), math.max(MIN.Y, startSize.Y + d.Y))
		end
	end))
	table.insert(lib.conns, UIS.InputEnded:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then mode = nil end
	end))
	local minimised, fullSize = false, nil
	minB.MouseButton1Click:Connect(function()
		minimised = not minimised
		if minimised then fullSize = main.Size tween(main, 0.18, { Size = UDim2.fromOffset(main.AbsoluteSize.X, 40) })
		else tween(main, 0.18, { Size = fullSize }) end
		side.Visible, pages.Visible, grip.Visible = not minimised, not minimised, not minimised
	end)
	closeB.MouseButton1Click:Connect(function() main.Visible = false lib:Notification("Hidden", "Press " .. lib.ToggleKey.Name .. " to show it again.", nil, nil, 4) end)
	table.insert(lib.conns, UIS.InputBegan:Connect(function(i, gp)
		if not gp and i.KeyCode == lib.ToggleKey then main.Visible = not main.Visible end
	end))

	local win, order, firstTab = {}, 0, nil
	local function nextOrder() order += 1 return order end
	function win:Label(t)
		local l = text({ Text = string.upper(t), Font = Enum.Font.GothamBold, TextSize = 11, Size = UDim2.new(1, 0, 0, 20), LayoutOrder = nextOrder(), Parent = side })
		paint(l, "TextColor3", "sub")
	end
	local allTabs = {}
	function win:Tab(name, icon, color)
		local b = new("TextButton", { Text = "", AutoButtonColor = false, Size = UDim2.new(1, 0, 0, 32), LayoutOrder = nextOrder(), Parent = side }, { round(8) })
		b.BackgroundColor3 = theme.side b.BackgroundTransparency = 1
		local dot = new("Frame", { BackgroundColor3 = color or theme.accent, Size = UDim2.fromOffset(24, 24), Position = UDim2.fromOffset(4, 4), Parent = b }, { round(7) })
		if icon and icon ~= "" then new("ImageLabel", { BackgroundTransparency = 1, Image = icon, ImageColor3 = Color3.new(1, 1, 1), Size = UDim2.fromOffset(16, 16), Position = UDim2.fromOffset(4, 4), Parent = dot }) end
		paint(text({ Text = name, Size = UDim2.new(1, -38, 1, 0), Position = UDim2.fromOffset(36, 0), Parent = b }), "TextColor3", "text")
		local page = new("ScrollingFrame", { Visible = false, BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ScrollBarThickness = 3, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, Parent = pages },
			{ new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }), new("UIPadding", { PaddingRight = UDim.new(0, 6), PaddingBottom = UDim.new(0, 8) }) })
		paint(page, "ScrollBarImageColor3", "line")
		local tabObj = { page = page, button = b, color = color }
		table.insert(allTabs, tabObj)
		local function select()
			for _, t in ipairs(allTabs) do t.page.Visible = (t == tabObj) t.button.BackgroundTransparency = (t == tabObj) and 0 or 1 t.button.BackgroundColor3 = theme.card end
		end
		b.MouseButton1Click:Connect(select)
		if not firstTab then firstTab = tabObj select() end
		tabObj.Select = select

		local n = 0
		local function row(h)
			n += 1
			local f = new("Frame", { Size = UDim2.new(1, 0, 0, h or 36), LayoutOrder = n, Parent = page }, { round(8) })
			paint(f, "BackgroundColor3", "card")
			return f
		end
		local function caption(f, t, w)
			local l = text({ Text = t, Size = UDim2.new(1, -(w or 0) - 24, 1, 0), Position = UDim2.fromOffset(12, 0), Parent = f })
			paint(l, "TextColor3", "text")
			return l
		end
		local accent = color or theme.accent

		function tabObj:Line(t)
			n += 1
			local f = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 24), LayoutOrder = n, Parent = page })
			paint(text({ Text = t, Font = Enum.Font.GothamBold, TextSize = 12, Size = UDim2.new(1, 0, 1, 0), Position = UDim2.fromOffset(2, 2), Parent = f }), "TextColor3", "sub")
			return f
		end
		function tabObj:Button(t, cb)
			local f = row()
			local b2 = new("TextButton", { Text = "", AutoButtonColor = false, BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = f })
			caption(f, t)
			b2.MouseEnter:Connect(function() tween(f, 0.1, { BackgroundColor3 = theme.cardHover }) end)
			b2.MouseLeave:Connect(function() tween(f, 0.1, { BackgroundColor3 = theme.card }) end)
			b2.MouseButton1Click:Connect(function() task.spawn(cb) end)
			return { Instance = f }
		end
		function tabObj:Label(t)
			local f = row(nil)
			f.AutomaticSize = Enum.AutomaticSize.Y
			local l = text({ Text = t, TextWrapped = true, TextTruncate = Enum.TextTruncate.None, RichText = true, Size = UDim2.new(1, -24, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Position = UDim2.fromOffset(12, 0), Parent = f }, nil)
			new("UIPadding", { PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 10), Parent = f })
			l.TextColor3 = theme.text
			local o = { inst = l, Instance = f }
			function o:SetText(s) l.Text = tostring(s) end
			function o:SetColor(c) o.custom = true l.TextColor3 = c end
			table.insert(labels, o)
			return o
		end
		function tabObj:Toggle(t, default, cb, flag)
			local f = row()
			caption(f, t, 44)
			local box = new("TextButton", { Text = "", AutoButtonColor = false, Size = UDim2.fromOffset(40, 22), Position = UDim2.new(1, -52, 0.5, -11), Parent = f }, { round(11) })
			local knob = new("Frame", { BackgroundColor3 = Color3.new(1, 1, 1), Size = UDim2.fromOffset(16, 16), Parent = box }, { round(8) })
			local o, state = { Instance = f }, false
			local function draw() tween(box, 0.12, { BackgroundColor3 = state and accent or theme.line }) tween(knob, 0.12, { Position = state and UDim2.fromOffset(21, 3) or UDim2.fromOffset(3, 3) }) end
			function o:Set(v, silent) state = v and true or false draw() if flag then lib.Flags[flag] = state end if not silent and cb then task.spawn(cb, state) end end
			function o:Get() return state end
			box.MouseButton1Click:Connect(function() o:Set(not state) end)
			o:Set(default, true)
			return o
		end
		function tabObj:Slider(t, decimals, min, max, default, cb, flag)
			local f = row(50)
			caption(f, t, 60).Size = UDim2.new(1, -84, 0, 26)
			local val = text({ Text = "", TextXAlignment = Enum.TextXAlignment.Right, Size = UDim2.fromOffset(60, 26), Position = UDim2.new(1, -72, 0, 0), Parent = f })
			paint(val, "TextColor3", "sub")
			local bar = new("TextButton", { Text = "", AutoButtonColor = false, Size = UDim2.new(1, -24, 0, 6), Position = UDim2.fromOffset(12, 32), Parent = f }, { round(3) })
			paint(bar, "BackgroundColor3", "line")
			local fill = new("Frame", { BackgroundColor3 = accent, Size = UDim2.fromScale(0, 1), Parent = bar }, { round(3) })
			local o, value, dragging = { Instance = f }, default, false
			local step = (decimals == true and 0.1) or (type(decimals) == "number" and decimals > 0 and 10 ^ -decimals) or 1
			function o:Set(v, silent)
				v = math.clamp(math.floor(v / step + 0.5) * step, min, max)
				value = v
				fill.Size = UDim2.fromScale((v - min) / math.max(max - min, 1e-9), 1)
				val.Text = (step < 1) and string.format("%.2f", v) or tostring(math.floor(v))
				if flag then lib.Flags[flag] = v end
				if not silent and cb then task.spawn(cb, v) end
			end
			function o:Get() return value end
			local function at(x) o:Set(min + (max - min) * math.clamp((x - bar.AbsolutePosition.X) / bar.AbsoluteSize.X, 0, 1)) end
			bar.InputBegan:Connect(function(i) if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then dragging = true at(i.Position.X) end end)
			table.insert(lib.conns, UIS.InputChanged:Connect(function(i) if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then at(i.Position.X) end end))
			table.insert(lib.conns, UIS.InputEnded:Connect(function(i) if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then dragging = false end end))
			o:Set(default, true)
			return o
		end
		function tabObj:Bind(t, key, hold, _, cb)
			local f = row()
			caption(f, t, 110)
			local b2 = new("TextButton", { Font = Enum.Font.GothamMedium, TextSize = 12, AutoButtonColor = false, Size = UDim2.fromOffset(100, 24), Position = UDim2.new(1, -112, 0.5, -12), Parent = f }, { round(6) })
			paint(b2, "BackgroundColor3", "line") paint(b2, "TextColor3", "text")
			local o, cur, listening = { Instance = f }, key, false
			local function draw() b2.Text = cur and cur.Name or "None" end
			function o:Set(k) cur = k draw() end
			function o:Get() return cur end
			b2.MouseButton1Click:Connect(function() listening = true b2.Text = "..." end)
			table.insert(lib.conns, UIS.InputBegan:Connect(function(i, gp)
				if listening and i.UserInputType == Enum.UserInputType.Keyboard then listening = false cur = i.KeyCode draw() return end
				if not gp and cur and i.KeyCode == cur and cb then task.spawn(cb, hold and true or cur) end
			end))
			if hold then table.insert(lib.conns, UIS.InputEnded:Connect(function(i) if cur and i.KeyCode == cur and cb then task.spawn(cb, false) end end)) end
			draw()
			return o
		end
		function tabObj:Textbox(t, numbersOnly, clearOnFocus, cb)
			local f = row()
			caption(f, t, 150)
			local box = new("TextBox", { Text = "", PlaceholderText = "type…", ClearTextOnFocus = clearOnFocus and true or false, Font = Enum.Font.GothamMedium, TextSize = 12, Size = UDim2.fromOffset(140, 24), Position = UDim2.new(1, -152, 0.5, -12), Parent = f }, { round(6) })
			paint(box, "BackgroundColor3", "line") paint(box, "TextColor3", "text")
			local o = { Instance = f }
			function o:Set(v) box.Text = tostring(v) end
			function o:Get() return numbersOnly and tonumber(box.Text) or box.Text end
			box.FocusLost:Connect(function()
				if numbersOnly and not tonumber(box.Text) then box.Text = "" return end
				if cb then task.spawn(cb, o:Get()) end
			end)
			return o
		end
		local function choiceRow(t, options, cb, compact)
			local f = row(compact and 36 or 66)
			local l = caption(f, t)
			if not compact then l.Size = UDim2.new(1, -24, 0, 30) end
			local holder = new("Frame", { BackgroundTransparency = 1, Size = compact and UDim2.new(0.55, -12, 0, 24) or UDim2.new(1, -24, 0, 26), Position = compact and UDim2.new(0.45, 0, 0.5, -12) or UDim2.fromOffset(12, 30), Parent = f },
				{ new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), HorizontalAlignment = compact and Enum.HorizontalAlignment.Right or Enum.HorizontalAlignment.Left }) })
			local o, buttons, cur = { Instance = f }, {}, nil
			local function draw() for v, b2 in pairs(buttons) do b2.BackgroundColor3 = (v == cur) and accent or theme.line b2.TextColor3 = (v == cur) and Color3.new(1, 1, 1) or theme.text end end
			for _, v in ipairs(options) do
				local b2 = new("TextButton", { Text = tostring(v), Font = Enum.Font.GothamMedium, TextSize = 12, AutoButtonColor = false, AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0, 24), Parent = holder },
					{ round(6), new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }) })
				buttons[v] = b2
				b2.MouseButton1Click:Connect(function() cur = v draw() if cb then task.spawn(cb, v) end end)
			end
			function o:Set(v, silent) cur = v draw() if not silent and cb then task.spawn(cb, v) end end
			function o:Get() return cur end
			draw()
			return o
		end
		function tabObj:RadioButtons(t, options, cb) return choiceRow(t, options, cb, false) end
		function tabObj:Dropdown(t, options, cb)
			local f = row()
			caption(f, t, 170)
			local b2 = new("TextButton", { Text = "Select", Font = Enum.Font.GothamMedium, TextSize = 12, AutoButtonColor = false, Size = UDim2.fromOffset(160, 24), Position = UDim2.new(1, -172, 0.5, -12), Parent = f }, { round(6) })
			paint(b2, "BackgroundColor3", "line") paint(b2, "TextColor3", "text")
			local list = new("Frame", { Visible = false, AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.new(1, 0, 0, 0), LayoutOrder = 0, Parent = page },
				{ round(8), pad(6), new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }) })
			paint(list, "BackgroundColor3", "side")
			n += 1 list.LayoutOrder = n
			local o, cur = { Instance = f }, nil
			local function fill(opts)
				for _, c in ipairs(list:GetChildren()) do if c:IsA("TextButton") then c:Destroy() end end
				for i, v in ipairs(opts) do
					local it = new("TextButton", { Text = "  " .. tostring(v), TextXAlignment = Enum.TextXAlignment.Left, Font = Enum.Font.GothamMedium, TextSize = 12, AutoButtonColor = false, Size = UDim2.new(1, 0, 0, 24), LayoutOrder = i, Parent = list }, { round(6) })
					it.BackgroundColor3 = theme.card it.TextColor3 = theme.text
					it.MouseButton1Click:Connect(function() o:Set(v) list.Visible = false end)
				end
			end
			function o:Set(v, silent) cur = v b2.Text = tostring(v) if not silent and cb then task.spawn(cb, v) end end
			function o:Get() return cur end
			function o:Refresh(opts) fill(opts) end
			b2.MouseButton1Click:Connect(function() list.Visible = not list.Visible end)
			fill(options)
			return o
		end
		function tabObj:Colorpicker(t, c, cb)
			local f = row(70)
			caption(f, t).Size = UDim2.new(1, -24, 0, 28)
			local sw = new("Frame", { BackgroundColor3 = c, Size = UDim2.fromOffset(28, 18), Position = UDim2.new(1, -40, 0, 5), Parent = f }, { round(5) })
			local o, h, s, v = { Instance = f }, c:ToHSV()
			local bars = {}
			local function emit() local col = Color3.fromHSV(h, s, v) sw.BackgroundColor3 = col if cb then task.spawn(cb, col) end end
			for i, key in ipairs({ "h", "s", "v" }) do
				local bar = new("TextButton", { Text = "", AutoButtonColor = false, Size = UDim2.new(1 / 3, -14, 0, 8), Position = UDim2.new((i - 1) / 3, 12, 0, 44), Parent = f }, { round(4) })
				paint(bar, "BackgroundColor3", "line")
				local fl = new("Frame", { BackgroundColor3 = accent, Size = UDim2.fromScale(key == "h" and h or key == "s" and s or v, 1), Parent = bar }, { round(4) })
				bars[key] = fl
				bar.MouseButton1Down:Connect(function(x)
					local r = math.clamp((x - bar.AbsolutePosition.X) / bar.AbsoluteSize.X, 0, 1)
					if key == "h" then h = r elseif key == "s" then s = r else v = r end
					fl.Size = UDim2.fromScale(r, 1) emit()
				end)
			end
			function o:Set(col) h, s, v = col:ToHSV() bars.h.Size, bars.s.Size, bars.v.Size = UDim2.fromScale(h, 1), UDim2.fromScale(s, 1), UDim2.fromScale(v, 1) emit() end
			function o:Get() return Color3.fromHSV(h, s, v) end
			return o
		end
		-- reorderable list: items = { {id=, name=}, ... }; cb(listOfIds) after every move
		function tabObj:Order(t, items, cb)
			local f = row(36)
			f.AutomaticSize = Enum.AutomaticSize.Y
			local l = caption(f, t) l.Size = UDim2.new(1, -24, 0, 30)
			local holder = new("Frame", { BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.new(1, -24, 0, 0), Position = UDim2.fromOffset(12, 30), Parent = f },
				{ new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }), new("UIPadding", { PaddingBottom = UDim.new(0, 8) }) })
			local o, list = { Instance = f }, {}
			for _, it in ipairs(items) do table.insert(list, it) end
			local function ids() local r = {} for _, it in ipairs(list) do table.insert(r, it.id) end return r end
			local draw
			local function move(i, d)
				local j = i + d
				if j < 1 or j > #list then return end
				list[i], list[j] = list[j], list[i]
				draw() if cb then task.spawn(cb, ids()) end
			end
			draw = function()
				for _, c in ipairs(holder:GetChildren()) do if c:IsA("Frame") then c:Destroy() end end
				for i, it in ipairs(list) do
					local r = new("Frame", { Size = UDim2.new(1, 0, 0, 26), LayoutOrder = i, Parent = holder }, { round(6) })
					r.BackgroundColor3 = theme.side
					local nl = text({ Text = i .. ".  " .. it.name, Size = UDim2.new(1, -70, 1, 0), Position = UDim2.fromOffset(10, 0), Parent = r })
					nl.TextColor3 = theme.text
					for k, g in ipairs({ { "▲", -1 }, { "▼", 1 } }) do
						local b2 = new("TextButton", { Text = g[1], Font = Enum.Font.GothamBold, TextSize = 10, AutoButtonColor = false, Size = UDim2.fromOffset(26, 20), Position = UDim2.new(1, -60 + (k - 1) * 30, 0, 3), Parent = r }, { round(5) })
						b2.BackgroundColor3 = theme.line b2.TextColor3 = theme.text
						b2.MouseButton1Click:Connect(function() move(i, g[2]) end)
					end
				end
			end
			function o:Set(order)
				local byId = {} for _, it in ipairs(items) do byId[it.id] = it end
				local seen, nl = {}, {}
				for _, id in ipairs(order or {}) do if byId[id] and not seen[id] then table.insert(nl, byId[id]) seen[id] = true end end
				for _, it in ipairs(items) do if not seen[it.id] then table.insert(nl, it) end end
				list = nl draw()
			end
			function o:Get() return ids() end
			draw()
			return o
		end
		return tabObj
	end
	function win:SelectTab(i) if allTabs[i] then allTabs[i].Select() end end
	return win
end

-- old global helpers
getgenv = getgenv or function() return _G end
getgenv().ChangeLabelText = function(part, new)
	for _, l in ipairs(labels) do if string.find(l.inst.Text, part, 1, true) then l.inst.Text = new return end end
end
getgenv().ChangeLabelColor = function(t, r, g, b)
	for _, l in ipairs(labels) do if string.find(l.inst.Text, t, 1, true) then l.custom = true l.inst.TextColor3 = Color3.fromRGB(r, g, b) end end
end
getgenv().ResetLabelColor = function()
	for _, l in ipairs(labels) do l.custom = false l.inst.TextColor3 = theme.text end
end

return lib
]===]
return M
