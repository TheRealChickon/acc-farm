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
