-- Card Clash Farm, bundled by tools/bundle.py. Source: src/. Returns {[module] = source}.
local M = {}
M["autopilot"] = [===[
-- Link to the account autopilot (the PC program tasks/2026-10-19-account-autopilot). Plain files in the executor workspace:
--   AnimeCardClash/autopilot/status.json          what the autopilot decided for every account (now, next, why, conditions, focus, quick jobs)
--   AnimeCardClash/autopilot/config.json          read-only copy of its config; "editable" lists what the window may change
--   AnimeCardClash/autopilot_overrides.json       the window's changes: {"set": {"focus": "luck", "jobs.packs.allowed": false}}
--   AnimeCardClash/autopilot/autopilot_read.lua   the read-only account read (sends nothing)
--   AnimeCardClash/autopilot/autopilot_runner.lua runs only the jobs Sami approved in the PC config (live.approved_steps)
-- The window never approves a live step: that only happens in the PC config, on Sami's word.
local core = ...
local ap = {
	STATUS = "AnimeCardClash/autopilot/status.json",
	CONFIG = "AnimeCardClash/autopilot/config.json",
	OVERRIDES = "AnimeCardClash/autopilot_overrides.json",
	READER = "AnimeCardClash/autopilot/autopilot_read.lua",
	RUNNER = "AnimeCardClash/autopilot/autopilot_runner.lua",
	FOCUSES = { "auto", "luck", "traits", "packs" },
	FOCUS_NAMES = { auto = "Auto", luck = "Luck index", traits = "Trait rerolls", packs = "Packs" },
}

-- the GUI may only set keys the autopilot lists as editable; anything else is refused here too
function ap.editable(cfg, key)
	return type(cfg) == "table" and type(cfg.editable) == "table" and cfg.editable[key] ~= nil
end

function ap.setOverride(key, value)
	local cur = core.readJson(ap.OVERRIDES) or {}
	cur.set = type(cur.set) == "table" and cur.set or {}
	cur.set[key] = value
	core.writeJson(ap.OVERRIDES, cur)
	return cur
end

-- the account's block of the status file, or nil
function ap.account(status, name)
	return type(status) == "table" and type(status.accounts) == "table" and status.accounts[name] or nil
end

local function ago(t)
	if not t then return "?" end
	local s = math.max(0, os.time() - t)
	if s < 90 then return math.floor(s) .. " s" end
	if s < 5400 then return math.floor(s / 60 + 0.5) .. " min" end
	return string.format("%.1f h", s / 3600)
end
ap.ago = ago

-- one block of text for the Autopilot tab
function ap.statusText(status, name)
	local a = ap.account(status, name)
	if not a then return "No autopilot plan for " .. tostring(name) .. " yet. It appears once the PC runs the autopilot." end
	local f = a.focus or {}
	local lines = {
		"<b>Now:</b> " .. tostring(a.now or "-"),
		"<b>Next:</b> " .. tostring(a.next or "-"),
		"<b>Why:</b> " .. tostring(a.why or "-"),
	}
	if type(a.conditions) == "table" and #a.conditions > 0 then table.insert(lines, "<b>Conditions:</b> " .. table.concat(a.conditions, "; ")) end
	table.insert(lines, string.format("<b>Focus:</b> %s%s", ap.FOCUS_NAMES[f.effective] or tostring(f.effective),
		f.chosen == "auto" and " (picked by auto)" or ""))
	table.insert(lines, string.format("Plan made %s ago%s", ago(status.updatedAt), status.dry_run and " · plan only, nothing is sent" or ""))
	return table.concat(lines, "\n")
end

-- the quick jobs that are ready / waiting, short
function ap.jobsText(status, name)
	local a = ap.account(status, name)
	if not a or type(a.quick) ~= "table" then return "" end
	local ready, waiting = {}, {}
	for _, q in ipairs(a.quick) do
		if q.state == "ready" then table.insert(ready, "• " .. tostring(q.label))
		elseif q.state == "waiting" or q.state == "needs_check" then table.insert(waiting, "• " .. tostring(q.label)) end
	end
	local out = {}
	if #ready > 0 then table.insert(out, "<b>Ready</b>\n" .. table.concat(ready, "\n", 1, math.min(#ready, 8))) end
	if #waiting > 0 then table.insert(out, "<b>Waiting</b>\n" .. table.concat(waiting, "\n", 1, math.min(#waiting, 8))) end
	return #out > 0 and table.concat(out, "\n") or "Nothing to do right now."
end

-- one line for the status bar under every tab
function ap.barText(status, name)
	local a = ap.account(status, name)
	if not a then return nil end
	local f = a.focus or {}
	return string.format("Autopilot · %s · next: %s", ap.FOCUS_NAMES[f.effective] or tostring(f.effective or "?"), tostring(a.next or "-"))
end

function ap.approved(status)
	local l = type(status) == "table" and type(status.live) == "table" and status.live.approved_steps or {}
	return type(l) == "table" and l or {}
end

return ap
]===]
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
local autopilot = import("autopilot", core)

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
win:Label("Autopilot")
local autoTab = win:Tab("Autopilot", "rbxassetid://6031302932", Color3.fromRGB(71, 200, 140))
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
local joyTab = win:Tab("Joyride", "rbxassetid://6034287519", Color3.fromRGB(150, 150, 160))
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

-- Autopilot (the PC program decides; this tab shows it and changes only what its config allows)
autoTab:Line("What it does for " .. LP.Name)
local apStatus = autoTab:Paragraph("Waiting for the autopilot on the PC.")
autoTab:Line("Focus")
local apCfg = core.readJson(autopilot.CONFIG) or {}
local focusNames = {}
for _, f in ipairs(autopilot.FOCUSES) do table.insert(focusNames, autopilot.FOCUS_NAMES[f]) end
local focusById = {} for _, f in ipairs(autopilot.FOCUSES) do focusById[autopilot.FOCUS_NAMES[f]] = f end
local focusReady = false
-- one place for the focus: the planner's overrides file (it turns the focus into weights); older planners: the autopilot's own file
local dirCfg = core.readJson(planner.CONFIG) or {}
local function dirEditable(key) return type(dirCfg.editable) == "table" and dirCfg.editable[key] ~= nil end
local focusRow = autoTab:RadioButtons("What to go for", focusNames, function(v)
	if not focusReady or PREVIEW then return end
	if dirEditable("focus") then planner.setOverride("focus", focusById[v])
	elseif autopilot.editable(apCfg, "focus") then autopilot.setOverride("focus", focusById[v])
	else lib:Notification("Not saved", "The planner has no editable focus yet.", nil, "Okay") end
end)
focusRow:Set(autopilot.FOCUS_NAMES[dirCfg.focus or apCfg.focus or "auto"] or "Auto", true)
focusReady = true
autoTab:Label("Auto = the autopilot picks (luck first while cheap luck is open, then packs). The PC takes a change within 5 minutes.")
autoTab:Line("Priority (your order wins for a while, then it goes back to automatic)")
local qStatus = autoTab:Label("")
local dirSt = core.readJson(planner.STATUS) or {}
local qItems = {}
for _, r in ipairs(type(dirSt.queue) == "table" and dirSt.queue or {}) do
	if r.draggable ~= false and r.id then table.insert(qItems, { id = r.id, name = tostring(r.label or r.id) }) end
end
local qList = autoTab:Order("Drag order (top runs first when it may)", qItems, function() end)
local qHours = 2
autoTab:Slider("Keep my order for (hours)", false, 1, 24, qHours, function(v) qHours = v end)
autoTab:Button("Use my order", function()
	if PREVIEW then return end
	local o = core.readJson(planner.OVERRIDES)
	if type(o) ~= "table" then o = {} end
	o.mode, o.queue_order, o["until"], o.by = "manual", qList:Get(), os.time() + qHours * 3600, "game window"
	o.rev = (tonumber(o.rev) or 0) + 1
	core.writeJson(planner.OVERRIDES, o)
	lib:Notification("Priority", "Your order is used for " .. qHours .. " h. The planner takes it within 5 minutes.", nil, "Okay")
end)
autoTab:Button("Back to automatic", function()
	if PREVIEW then return end
	local o = core.readJson(planner.OVERRIDES)
	if type(o) ~= "table" then o = {} end
	o.mode, o.queue_order, o.skip, o["until"] = "auto", {}, {}, nil
	o.rev = (tonumber(o.rev) or 0) + 1
	core.writeJson(planner.OVERRIDES, o)
end)
autoTab:Line("Quick jobs")
local apJobs = autoTab:Paragraph("")
autoTab:Line("Which jobs it may plan")
for _, job in ipairs({ "claims", "equips", "upgrades", "explorations", "crafting", "potions", "packs", "moon_rolls", "levelling", "trait_rolls", "story" }) do
	local key = "jobs." .. job .. ".allowed"
	if autopilot.editable(apCfg, key) then
		local on = type(apCfg.jobs) == "table" and type(apCfg.jobs[job]) == "table" and apCfg.jobs[job].allowed == true
		autoTab:Toggle(job:gsub("_", " "):gsub("^%l", string.upper), on, function(v) if not PREVIEW then autopilot.setOverride(key, v) end end)
	end
end
if autopilot.editable(apCfg, "accounts." .. LP.Name .. ".new_account_mode") then
	local acc = type(apCfg.accounts) == "table" and apCfg.accounts[LP.Name] or {}
	autoTab:Toggle("New-account mode (story first, packs only in a good moon)", acc.new_account_mode == true, function(v)
		if not PREVIEW then autopilot.setOverride("accounts." .. LP.Name .. ".new_account_mode", v) end
	end)
end
autoTab:Line("Account")
autoTab:Button("Read this account now (read only)", function()
	if PREVIEW then lib:Notification("Preview only", "Nothing starts from this window.", nil, "Okay") return end
	local ok, src = pcall(readfile, autopilot.READER)
	if not ok then lib:Notification("Missing", autopilot.READER .. " is not in the workspace yet.", nil, "Okay") return end
	local fn = loadstring(src)
	if fn then task.spawn(fn) end
	lib:Notification("Account read", "Reading " .. LP.Name .. " (sends nothing). The PC uses it on its next round.", nil, "Okay")
end)
local apLive = autoTab:Label("")
autoTab:Button("Start the runner (only approved jobs)", function()
	if PREVIEW then lib:Notification("Preview only", "Nothing starts from this window.", nil, "Okay") return end
	local st = core.readJson(autopilot.STATUS)
	if #autopilot.approved(st) == 0 then lib:Notification("Nothing approved", "No job is approved for live play yet. Only Sami's yes in the PC config turns one on.", nil, "Okay") return end
	local ok, src = pcall(readfile, autopilot.RUNNER)
	if not ok then lib:Notification("Missing", autopilot.RUNNER .. " is not in the workspace yet.", nil, "Okay") return end
	local fn = loadstring(src)
	if fn then task.spawn(fn) end
end)
autoTab:Button("Stop the runner", function() _G.__AP_STOP = true end)

-- Joyride: a slot for Sami's own script. The autopilot never builds, runs or plans Joyride.
joyTab:Line("Joyride")
joyTab:Label("Your own Joyride script runs on its own. The autopilot does not touch Joyride.")

-- Status
local stLabel = statusTab:Label("Stopped")
local statLabel = statusTab:Label("")
statusTab:Line("Log")
local logLabel = statusTab:Label("")

-- Settings
setTab:Button("Dark theme", function() cfg.theme = "Dark" save() lib:ChangeTheme("Dark") end)
setTab:Button("Light theme", function() cfg.theme = "Light" save() lib:ChangeTheme("Light") end)
setTab:Label("Show / hide the window: " .. lib.ToggleKey.Name .. ". Drag the bottom-right corner to resize.")
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
		local apSt = core.readJson(autopilot.STATUS)
		local ds = core.readJson(planner.STATUS)
		local ov = type(ds) == "table" and ds.override or nil
		qStatus:SetText(type(ov) == "table" and ov.mode == "manual" and not ov.expired
			and string.format("Your order is on (%d min left).", math.floor((tonumber(ov.remaining_s) or 0) / 60)) or "Automatic priority.")
		apStatus:SetText(autopilot.statusText(apSt, LP.Name))
		apJobs:SetText(autopilot.jobsText(apSt, LP.Name))
		local appr = autopilot.approved(apSt)
		apLive:SetText(#appr > 0 and ("Approved for live play: " .. table.concat(appr, ", ")) or "Approved for live play: nothing yet (plan only).")
		local bar = (running and ("Farm: " .. tostring(core.status)) or "Farm stopped")
		local apBar = autopilot.barText(apSt, LP.Name)
		win:Status(apBar and (bar .. "  ·  " .. apBar) or bar, running and Color3.fromRGB(71, 200, 140) or nil)
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
-- dawidlib (Sami's UI library, "LabelModdedNewFunc"), modified for Card Clash Farm (2026-10-19). Same look and same calls as before,
-- loadable with loadstring (returns lib). What changed:
--   * the window sizes itself to its tabs and content (up to 85% of the screen), and you can resize it from the bottom-right corner
--   * a status bar at the bottom that every tab shows (win:Status(text, color))
--   * the tab list scrolls when there are many tabs; tab pages size their scroll area by themselves
--   * hide / show with RightControl (lib.ToggleKey); the red button hides the window instead of shrinking it to nothing
--   * the theme is painted once and again on ChangeTheme (it used to repaint every element every frame: lag with many elements)
--   * every element returns an object: Label :Change/:SetText/:SetColor, Toggle/Slider/Dropdown/Textbox :Set/:Get, Dropdown :Refresh
--   * fixes: Toggle honours its default, Notification without an icon, the label helpers search every tab, lib:Destroy, win:SelectTab
--   * new elements: tab:Order(text, items, cb) (reorder a list), tab:Paragraph(text) (wrapped multi-line text)
local CoreGuiService = game:GetService("CoreGui")
local GUI_PARENT = (gethui and gethui()) or CoreGuiService
do
    for _, p in ipairs({ CoreGuiService, GUI_PARENT }) do
        local ui = p:FindFirstChild("dawidlib")
        if ui then
            ui:Destroy()
        end
    end
end

local lib = {CurrentlyBinding = false,RainbowColorValue = 0, HueSelectionPosition = 0, Flags = {}, ToggleKey = Enum.KeyCode.RightControl}

-- theme registry: each element registers how it paints itself; ChangeTheme repaints them all once
local THEMED = {}
local function themed(fn)
    table.insert(THEMED, fn)
    pcall(fn)
end
local function repaint()
    for i = #THEMED, 1, -1 do
        local ok = pcall(THEMED[i])
        if not ok then table.remove(THEMED, i) end
    end
end

local themes = {
	Light = {
		Color1 = Color3.fromRGB(255,255,255),
		Color2 = Color3.fromRGB(240,240,240),
		Color3 = Color3.fromRGB(228,228,228),
		TabColor = Color3.fromRGB(220, 220, 220),
		ScrollBar = Color3.fromRGB(213, 213, 213),
		TextColor = Color3.fromRGB(0,0,0)
	},
	Dark = {
		Color1 = Color3.fromRGB(35,35,35),
		Color2 = Color3.fromRGB(38,38,38),
		Color3 = Color3.fromRGB(31,31,31),
		TabColor = Color3.fromRGB(45,45,45),
		ScrollBar = Color3.fromRGB(58, 58, 58),
		TextColor = Color3.fromRGB(255,255,255)
	}
}
local HttpService = game:GetService("HttpService")
local loadedinfo = {}
local selectedtheme = "Light"
local watermarkpos = "BottomLeft"
local watermarktext = "Ui made by dawid#7205, Script by TheRealChicken#5230"

pcall(function()
	loadedinfo = HttpService:JSONDecode(readfile("dawidhubinfo.txt"))
	selectedtheme = loadedinfo["theme"] or "Light"
	watermarktext = "Ui made by dawid#7205, Script by TheRealChicken#5230"
	watermarkpos = loadedinfo["watermarkpos"] or "BottomLeft"
end)

local function saveinfo()
	loadedinfo["theme"] = selectedtheme
	loadedinfo["watermarktext"] = watermarktext
	loadedinfo["watermarkpos"] = watermarkpos
	writefile("dawidhubinfo.txt", HttpService:JSONEncode(loadedinfo))
end




coroutine.wrap(
	function()
		while task.wait(1/30) do
			lib.RainbowColorValue = lib.RainbowColorValue + 1 / 255
			lib.HueSelectionPosition = lib.HueSelectionPosition + 1

			if lib.RainbowColorValue >= 1 then
				lib.RainbowColorValue = 0
			end

			if lib.HueSelectionPosition == 80 then
				lib.HueSelectionPosition = 0
			end
		end
	end
)()
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local LocalPlayer = game:GetService("Players").LocalPlayer
local Mouse = LocalPlayer:GetMouse()

local function MakeDraggable(topbarobject, object)
	local Dragging = nil
	local DragInput = nil
	local DragStart = nil
	local StartPosition = nil

	local function Update(input)
		local Delta = input.Position - DragStart
		local pos =
			UDim2.new(
				StartPosition.X.Scale,
				StartPosition.X.Offset + Delta.X,
				StartPosition.Y.Scale,
				StartPosition.Y.Offset + Delta.Y
			)
		object.Position = pos
	end

	topbarobject.InputBegan:Connect(
		function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				Dragging = true
				DragStart = input.Position
				StartPosition = object.Position

				input.Changed:Connect(
					function()
						if input.UserInputState == Enum.UserInputState.End then
							Dragging = false
						end
					end
				)
			end
		end
	)

	topbarobject.InputChanged:Connect(
		function(input)
			if
				input.UserInputType == Enum.UserInputType.MouseMovement or
					input.UserInputType == Enum.UserInputType.Touch
			then
				DragInput = input
			end
		end
	)

	UserInputService.InputChanged:Connect(
		function(input)
			if input == DragInput and Dragging then
				Update(input)
			end
		end
	)
end

local dawidlib = Instance.new("ScreenGui")
dawidlib.Name = "dawidlib"
-- parented when a window opens, so loading the library alone (script mode) puts nothing on screen
dawidlib.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
dawidlib.ResetOnSpawn = false
lib.Gui = dawidlib

local function loadwatermark()
	local WatermarkFrame = Instance.new("Frame")
	local WatermarkLabel = Instance.new("TextLabel")

	WatermarkFrame.Name = "WatermarkFrame"
	WatermarkFrame.Parent = dawidlib
	WatermarkFrame.AnchorPoint = Vector2.new(0.5, 0.5)
	WatermarkFrame.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	WatermarkFrame.BackgroundTransparency = 1.000
	WatermarkFrame.Position = UDim2.new(0.5, 0, 0.5, 0)
	WatermarkFrame.Size = UDim2.new(1, 0, 1, 0)

	WatermarkLabel.Name = "WatermarkLabel"
	WatermarkLabel.Parent = WatermarkFrame
	WatermarkLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	WatermarkLabel.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	WatermarkLabel.BackgroundTransparency = 1.000
	WatermarkLabel.BorderColor3 = Color3.fromRGB(27, 42, 53)
	WatermarkLabel.Position = UDim2.new(0.5, 0, 0.5, 0)
	WatermarkLabel.Size = UDim2.new(1, -25, 1, -25)
	WatermarkLabel.Font = Enum.Font.Gotham
	WatermarkLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	WatermarkLabel.TextSize = 16.000
	WatermarkLabel.TextXAlignment = Enum.TextXAlignment.Left
	WatermarkLabel.TextYAlignment = Enum.TextYAlignment.Bottom
	WatermarkLabel.Text = watermarktext

	coroutine.wrap(
		function()
			while WatermarkLabel.Parent and task.wait(0.5) do
				WatermarkLabel.Text = watermarktext
				if watermarkpos == "BottomLeft" then
					WatermarkLabel.TextXAlignment = Enum.TextXAlignment.Left
					WatermarkLabel.TextYAlignment = Enum.TextYAlignment.Bottom
				elseif watermarkpos == "BottomRight" then
					WatermarkLabel.TextXAlignment = Enum.TextXAlignment.Right
					WatermarkLabel.TextYAlignment = Enum.TextYAlignment.Bottom
					elseif watermarkpos == "TopLeft" then
						WatermarkLabel.TextXAlignment = Enum.TextXAlignment.Left
						WatermarkLabel.TextYAlignment = Enum.TextYAlignment.Top
					elseif watermarkpos == "TopRight" then
						WatermarkLabel.TextXAlignment = Enum.TextXAlignment.Right
						WatermarkLabel.TextYAlignment = Enum.TextYAlignment.Top
				end
			end
		end
	)()
end

function update()
	repaint()
end
function lib:ChangeTheme(theme)
	if not themes[theme] then return end
	selectedtheme = theme
	repaint()
	pcall(saveinfo)
end
function lib:Destroy()
	if dawidlib then dawidlib:Destroy() end
end

local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local LocalPlayer = game:GetService("Players").LocalPlayer
local Mouse = LocalPlayer:GetMouse()


local function errornotif(text)

	local error = Instance.new("ScreenGui")
	local ErrorMain = Instance.new("Frame")
	local ErrorMainCircle = Instance.new("Frame")
	local ErrorMainCircleImg = Instance.new("ImageLabel")
	local ErrorMainCircleCorner = Instance.new("UICorner")
	local ErrorText = Instance.new("TextLabel")


	error.Name = "error"
	error.Parent = game.CoreGui
	error.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	ErrorMain.Name = "ErrorMain"
	ErrorMain.Parent = error
	ErrorMain.BackgroundColor3 = Color3.fromRGB(17, 17, 17)
	ErrorMain.BackgroundTransparency = 1.000
	ErrorMain.BorderSizePixel = 0
	ErrorMain.Size = UDim2.new(1, 0, 1, 0)

	ErrorMainCircle.Name = "ErrorMainCircle"
	ErrorMainCircle.Parent = ErrorMain
	ErrorMainCircle.AnchorPoint = Vector2.new(0.5, 0.5)
	ErrorMainCircle.BackgroundColor3 = Color3.fromRGB(29, 29, 29)
	ErrorMainCircle.BackgroundTransparency = 1.000
	ErrorMainCircle.Position = UDim2.new(0.5, 0, 0.5, 0)
	ErrorMainCircle.Size = UDim2.new(0, 100, 0, 100)

	ErrorMainCircleImg.Name = "ErrorMainCircleImg"
	ErrorMainCircleImg.Parent = ErrorMainCircle
	ErrorMainCircleImg.AnchorPoint = Vector2.new(0.5, 0.5)
	ErrorMainCircleImg.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	ErrorMainCircleImg.BackgroundTransparency = 1.000
	ErrorMainCircleImg.Position = UDim2.new(0.5, 0, 0.5, 0)
	ErrorMainCircleImg.Size = UDim2.new(0, 75, 0, 75)
	ErrorMainCircleImg.Image = "http://www.roblox.com/asset/?id=6031260781"
	ErrorMainCircleImg.ImageColor3 = Color3.fromRGB(17, 17, 17)
	ErrorMainCircleImg.ImageTransparency = 1.000

	ErrorMainCircleCorner.CornerRadius = UDim.new(1, 8)
	ErrorMainCircleCorner.Name = "ErrorMainCircleCorner"
	ErrorMainCircleCorner.Parent = ErrorMainCircle

	ErrorText.Name = "ErrorText"
	ErrorText.Parent = ErrorMain
	ErrorText.AnchorPoint = Vector2.new(0.5, 0.5)
	ErrorText.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	ErrorText.BackgroundTransparency = 1.000
	ErrorText.Position = UDim2.new(0.5, 0, 0.5, 50)
	ErrorText.Size = UDim2.new(0, 200, 0, 50)
	ErrorText.Font = Enum.Font.Gotham
	ErrorText.Text = text
	ErrorText.TextColor3 = Color3.fromRGB(255, 255, 255)
	ErrorText.TextSize = 18.000
	ErrorText.TextTransparency = 1.000

	TweenService:Create(
		ErrorMain,
		TweenInfo.new(.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{BackgroundTransparency = 0}
	):Play()

	task.wait(.5)

	TweenService:Create(
		ErrorMainCircle,
		TweenInfo.new(.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{BackgroundTransparency = 0}
	):Play()
	TweenService:Create(
		ErrorMainCircleImg,
		TweenInfo.new(.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ImageTransparency = 0}
	):Play()

	task.wait(.8)

	ErrorMainCircle:TweenPosition(UDim2.new(0.5, 0, 0.5, -25), Enum.EasingDirection.Out, Enum.EasingStyle.Quart, .4, true)

	task.wait(.1)

	TweenService:Create(
		ErrorText,
		TweenInfo.new(.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{TextTransparency = 0}
	):Play()
end


function lib:Window(title, opts)
	opts = type(title) == "table" and title or (opts or {})
	title = type(title) == "string" and title or opts.title
	local fs = false
	local Main = Instance.new("Frame")
	local MainCorner = Instance.new("UICorner")
	local LeftFrame = Instance.new("Frame")
	local LeftFrame1 = Instance.new("Frame")
	local CloseBtn = Instance.new("TextButton")
	local CloseBtnCorner = Instance.new("UICorner")
	local CloseBtnImg = Instance.new("ImageLabel")
	local TabHold = Instance.new("ScrollingFrame")
	local TabHoldLayout = Instance.new("UIListLayout")
	local Line = Instance.new("Frame")
	local LeftFrameCorner = Instance.new("UICorner")
	local TabFolder = Instance.new("Frame")
	local DragFrame = Instance.new("Frame")
	local TitleText = Instance.new("TextLabel")
	local StatusBar = Instance.new("Frame")
	local StatusDot = Instance.new("Frame")
	local StatusText = Instance.new("TextLabel")
	local Grip = Instance.new("ImageButton")

	-- sizes: LEFT = tab list width, TOP = title row, STATUS = status bar height; the window grows with its content
	local LEFT, TOP, STATUS = 162, 36, 24
	local MIN = Vector2.new(opts.minWidth or 541, opts.minHeight or 368)
	local userSized = false

	dawidlib.Parent = GUI_PARENT
	Main.Name = "Main"
	Main.Parent = dawidlib
	Main.AnchorPoint = Vector2.new(0.5, 0.5)
	Main.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	Main.ClipsDescendants = true
	Main.Position = UDim2.new(0.5, 0, 0.498903513, 0)
	Main.Size = UDim2.new(0, MIN.X, 0, MIN.Y)
	Main.BorderSizePixel = 0

	MainCorner.CornerRadius = UDim.new(0, 10)
	MainCorner.Name = "MainCorner"
	MainCorner.Parent = Main

	LeftFrame.Name = "LeftFrame"
	LeftFrame.Parent = Main
	LeftFrame.BackgroundColor3 = Color3.fromRGB(240, 240, 240)
	LeftFrame.Position = UDim2.new(0, 0, 0, 0)
	LeftFrame.Size = UDim2.new(0, LEFT, 1, 0)

	LeftFrame1.Name = "LeftFrame1"
	LeftFrame1.Parent = LeftFrame
	LeftFrame1.AnchorPoint = Vector2.new(0.5, 0.5)
	LeftFrame1.BackgroundColor3 = Color3.fromRGB(240, 240, 240)
	LeftFrame1.BorderSizePixel = 0
	LeftFrame1.Position = UDim2.new(0.971977353, 0, 0.5, 0)
	LeftFrame1.Size = UDim2.new(0, 9, 1, 0)

	CloseBtn.Name = "CloseBtn"
	CloseBtn.Parent = LeftFrame
	CloseBtn.BackgroundColor3 = Color3.fromRGB(244, 96, 86)
	CloseBtn.Position = UDim2.new(0, 20, 0, 12)
	CloseBtn.Size = UDim2.new(0, 13, 0, 13)
	CloseBtn.AutoButtonColor = false
	CloseBtn.Font = Enum.Font.SourceSans
	CloseBtn.Text = ""
	CloseBtn.TextColor3 = Color3.fromRGB(0, 0, 0)
	CloseBtn.TextSize = 14.000
	CloseBtn.ZIndex = 3

	CloseBtnCorner.CornerRadius = UDim.new(1, 0)
	CloseBtnCorner.Name = "CloseBtnCorner"
	CloseBtnCorner.Parent = CloseBtn

	CloseBtnImg.Name = "CloseBtnImg"
	CloseBtnImg.Parent = CloseBtn
	CloseBtnImg.BackgroundColor3 = Color3.fromRGB(244, 96, 86)
	CloseBtnImg.BackgroundTransparency = 1.000
	CloseBtnImg.Position = UDim2.new(0.144999996, 0, 0.144999996, 0)
	CloseBtnImg.Size = UDim2.new(0, 9, 0, 9)
	CloseBtnImg.Image = "http://www.roblox.com/asset/?id=6031094678"
	CloseBtnImg.ImageColor3 = Color3.fromRGB(170, 65, 60)
	CloseBtnImg.ImageTransparency = 1.000
	CloseBtnImg.ZIndex = 3

	TitleText.Name = "TitleText"
	TitleText.Parent = LeftFrame
	TitleText.BackgroundTransparency = 1
	TitleText.Position = UDim2.new(0, 40, 0, 6)
	TitleText.Size = UDim2.new(1, -48, 0, 25)
	TitleText.Font = Enum.Font.GothamSemibold
	TitleText.Text = title or ""
	TitleText.TextSize = 13
	TitleText.TextXAlignment = Enum.TextXAlignment.Left
	TitleText.TextTruncate = Enum.TextTruncate.AtEnd

	-- drag: the left title row and a thin strip along the top of the page
	DragFrame.Name = "DragFrame"
	DragFrame.Parent = Main
	DragFrame.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	DragFrame.BackgroundTransparency = 1.000
	DragFrame.Position = UDim2.new(0, LEFT, 0, 0)
	DragFrame.Size = UDim2.new(1, -LEFT, 0, 14)
	local LeftDrag = DragFrame:Clone()
	LeftDrag.Parent = LeftFrame
	LeftDrag.Position = UDim2.new(0, 36, 0, 0)
	LeftDrag.Size = UDim2.new(1, -36, 0, TOP)

	TabHold.Name = "TabHold"
	TabHold.Parent = LeftFrame
	TabHold.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	TabHold.BackgroundTransparency = 1.000
	TabHold.BorderSizePixel = 0
	TabHold.Position = UDim2.new(0, 10, 0, TOP + 8)
	TabHold.Size = UDim2.new(0, 147, 1, -(TOP + 8 + 10))
	TabHold.CanvasSize = UDim2.new(0, 0, 0, 0)
	TabHold.AutomaticCanvasSize = Enum.AutomaticSize.Y
	TabHold.ScrollBarThickness = 3
	TabHold.ScrollingDirection = Enum.ScrollingDirection.Y

	TabHoldLayout.Name = "TabHoldLayout"
	TabHoldLayout.Parent = TabHold
	TabHoldLayout.SortOrder = Enum.SortOrder.LayoutOrder
	TabHoldLayout.Padding = UDim.new(0, 4)

	Line.Name = "Line"
	Line.Parent = LeftFrame
	Line.BackgroundColor3 = Color3.fromRGB(228, 228, 228)
	Line.BorderSizePixel = 0
	Line.Position = UDim2.new(1, -1, 0, 0)
	Line.Size = UDim2.new(0, 2, 1, 0)

	LeftFrameCorner.CornerRadius = UDim.new(0, 10)
	LeftFrameCorner.Name = "LeftFrameCorner"
	LeftFrameCorner.Parent = LeftFrame

	-- the pages (one ScrollingFrame per tab) sit right of the tab list and above the status bar
	TabFolder.Name = "TabFolder"
	TabFolder.Parent = Main
	TabFolder.BackgroundTransparency = 1
	TabFolder.BorderSizePixel = 0
	TabFolder.Position = UDim2.new(0, LEFT + 10, 0, 17)
	TabFolder.Size = UDim2.new(1, -(LEFT + 18), 1, -(17 + STATUS + 12))

	-- status bar: always visible under every tab (win:Status(text, color))
	StatusBar.Name = "StatusBar"
	StatusBar.Parent = Main
	StatusBar.BorderSizePixel = 0
	StatusBar.Position = UDim2.new(0, LEFT + 10, 1, -(STATUS + 6))
	StatusBar.Size = UDim2.new(1, -(LEFT + 34), 0, STATUS)
	Instance.new("UICorner", StatusBar).CornerRadius = UDim.new(0, 6)
	StatusDot.Name = "StatusDot"
	StatusDot.Parent = StatusBar
	StatusDot.AnchorPoint = Vector2.new(0, 0.5)
	StatusDot.Position = UDim2.new(0, 8, 0.5, 0)
	StatusDot.Size = UDim2.new(0, 8, 0, 8)
	StatusDot.BackgroundColor3 = Color3.fromRGB(182, 182, 182)
	StatusDot.BorderSizePixel = 0
	Instance.new("UICorner", StatusDot).CornerRadius = UDim.new(1, 0)
	StatusText.Name = "StatusText"
	StatusText.Parent = StatusBar
	StatusText.BackgroundTransparency = 1
	StatusText.Position = UDim2.new(0, 22, 0, 0)
	StatusText.Size = UDim2.new(1, -28, 1, 0)
	StatusText.Font = Enum.Font.Gotham
	StatusText.TextSize = 12
	StatusText.TextXAlignment = Enum.TextXAlignment.Left
	StatusText.TextTruncate = Enum.TextTruncate.AtEnd
	StatusText.Text = "Ready"

	-- resize grip (bottom-right corner)
	Grip.Name = "Grip"
	Grip.Parent = Main
	Grip.BackgroundTransparency = 1
	Grip.AnchorPoint = Vector2.new(1, 1)
	Grip.Position = UDim2.new(1, -4, 1, -4)
	Grip.Size = UDim2.new(0, 16, 0, 16)
	Grip.Image = "rbxassetid://6031094687"
	Grip.ImageTransparency = 0.5
	Grip.ZIndex = 5

	MakeDraggable(DragFrame,Main)
	MakeDraggable(LeftDrag,Main)
	loadwatermark()

	local function screen()
		local cam = workspace.CurrentCamera
		return cam and cam.ViewportSize or Vector2.new(1280, 720)
	end
	local function clampSize(w, h)
		local sc = screen()
		return math.clamp(w, MIN.X, math.max(MIN.X, sc.X * 0.95)), math.clamp(h, MIN.Y, math.max(MIN.Y, sc.Y * 0.9))
	end

	-- the window sizes itself to the tab list and the page shown (until you resize it by hand)
	local current = nil
	local function autoFit()
		if userSized or not Main.Parent or not Main.Visible then return end
		local tabsH = TabHoldLayout.AbsoluteContentSize.Y + TOP + 8 + 18
		local pageH = current and (current.layout.AbsoluteContentSize.Y + 17 + STATUS + 22) or 0
		local want = math.max(tabsH, pageH)
		local _, h = clampSize(Main.AbsoluteSize.X, math.min(want, screen().Y * 0.85))
		if math.abs(h - Main.AbsoluteSize.Y) > 2 then
			TweenService:Create(Main, TweenInfo.new(.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {Size = UDim2.new(0, Main.AbsoluteSize.X, 0, h)}):Play()
		end
	end
	TabHoldLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(autoFit)

	do   -- drag the grip to resize; after that the window keeps your size
		local resizing, startPos, startSize = false, nil, nil
		Grip.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				resizing, startPos, startSize = true, input.Position, Main.AbsoluteSize
				input.Changed:Connect(function() if input.UserInputState == Enum.UserInputState.End then resizing = false end end)
			end
		end)
		UserInputService.InputChanged:Connect(function(input)
			if resizing and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
				local d = input.Position - startPos
				local w, h = clampSize(startSize.X + d.X, startSize.Y + d.Y)
				userSized = true
				Main.Size = UDim2.new(0, w, 0, h)
			end
		end)
	end

	-- hide / show: the red button hides, lib.ToggleKey (RightControl) brings it back
	local hidden, shownSize = false, nil
	local function setHidden(v)
		if v == hidden then return end
		hidden = v
		if v then
			shownSize = Main.Size
			Main:TweenSize(UDim2.new(0, 0, 0, 0), Enum.EasingDirection.Out, Enum.EasingStyle.Quart, .4, true, function() if hidden then Main.Visible = false end end)
		else
			Main.Visible = true
			Main:TweenSize(shownSize or UDim2.new(0, MIN.X, 0, MIN.Y), Enum.EasingDirection.Out, Enum.EasingStyle.Quart, .4, true)
		end
	end
	CloseBtn.MouseButton1Click:Connect(function() setHidden(true) end)
	UserInputService.InputBegan:Connect(function(input, gp)
		if not gp and input.KeyCode == lib.ToggleKey and not lib.CurrentlyBinding then setHidden(not hidden) end
	end)

	CloseBtn.MouseEnter:Connect(function()
		CloseBtnImg.ImageTransparency = 0
	end)

	CloseBtn.MouseLeave:Connect(function()
		CloseBtnImg.ImageTransparency = 1
	end)

	themed(function()
		Main.BackgroundColor3 = themes[selectedtheme].Color1
		LeftFrame.BackgroundColor3 = themes[selectedtheme].Color2
		LeftFrame1.BackgroundColor3 = themes[selectedtheme].Color2
		Line.BackgroundColor3 = themes[selectedtheme].Color3
		TitleText.TextColor3 = themes[selectedtheme].TextColor
		StatusBar.BackgroundColor3 = themes[selectedtheme].Color2
		StatusText.TextColor3 = themes[selectedtheme].TextColor
		TabHold.ScrollBarImageColor3 = themes[selectedtheme].ScrollBar
		Grip.ImageColor3 = themes[selectedtheme].TextColor
	end)

	local function notify(text,desc,icotext,btntext)
		local NotificationHold = Instance.new("TextButton")
		local NotificationHoldCorner = Instance.new("UICorner")
		local Notification = Instance.new("Frame")
		local NotificationTitle = Instance.new("TextLabel")
		local NotificationCorner = Instance.new("UICorner")
		local NotificationIco = Instance.new("ImageLabel")
		local NotificationBtn = Instance.new("TextButton")
		local NotificationBtnCorner = Instance.new("UICorner")
		local NotificationDesc = Instance.new("TextLabel")
		local NotificationHoldScale = Instance.new("UIScale")

		NotificationHold.Name = "NotificationHold"
		NotificationHold.Parent = Main
		NotificationHold.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
		NotificationHold.BackgroundTransparency = 1.000
		NotificationHold.Position = UDim2.new(0, 0, 8.2928203e-08, 0)
		NotificationHold.Size = UDim2.new(1, 29, 1, 20)
		NotificationHold.AutoButtonColor = false
		NotificationHold.Font = Enum.Font.SourceSans
		NotificationHold.Text = ""
		NotificationHold.TextColor3 = Color3.fromRGB(0, 0, 0)
		NotificationHold.TextSize = 14.000

		NotificationHoldCorner.CornerRadius = UDim.new(0, 10)
		NotificationHoldCorner.Name = "NotificationHoldCorner"
		NotificationHoldCorner.Parent = NotificationHold

		Notification.Name = "Notification"
		Notification.Parent = NotificationHold
		Notification.AnchorPoint = Vector2.new(0.5, 0.5)
		Notification.BackgroundColor3 = themes[selectedtheme].Color1
		Notification.BackgroundTransparency = 1.000
		Notification.Position = UDim2.new(0.5, 0, 0.5, 0)
		Notification.Selectable = true
		Notification.Size = UDim2.new(0, 142, 0, 179)

		NotificationTitle.Name = "NotificationTitle"
		NotificationTitle.Parent = Notification
		NotificationTitle.BackgroundColor3 = themes[selectedtheme].TextColor
		NotificationTitle.BackgroundTransparency = 1.000
		NotificationTitle.Position = UDim2.new(0, 0, 0.5, -17)
		NotificationTitle.Size = UDim2.new(1, 0, 0, 15)
		NotificationTitle.Font = Enum.Font.GothamSemibold
		NotificationTitle.Text = text
		NotificationTitle.TextColor3 = themes[selectedtheme].TextColor
		NotificationTitle.TextSize = 16.000
		NotificationTitle.TextTransparency = 1.000

		NotificationCorner.CornerRadius = UDim.new(0, 7)
		NotificationCorner.Name = "NotificationCorner"
		NotificationCorner.Parent = Notification

		NotificationIco.Name = "NotificationIco"
		NotificationIco.Parent = Notification
		NotificationIco.AnchorPoint = Vector2.new(0.5, 0.5)
		NotificationIco.BackgroundTransparency = 1.000
		NotificationIco.BorderSizePixel = 0
		NotificationIco.Position = UDim2.new(0.5, 0, 0.5, -55)
		NotificationIco.Size = UDim2.new(0, 60, 0, 60)
		NotificationIco.Image = icotext or "rbxassetid://6031071053"
		NotificationIco.ImageColor3 = Color3.fromRGB(31, 118, 219)
		NotificationIco.ImageTransparency = 1.000

		NotificationBtn.Name = "NotificationBtn"
		NotificationBtn.Parent = Notification
		NotificationBtn.AnchorPoint = Vector2.new(0.5, 0.5)
		NotificationBtn.BackgroundColor3 = Color3.fromRGB(31, 118, 219)
		NotificationBtn.BackgroundTransparency = 1.000
		NotificationBtn.Position = UDim2.new(0.5, 0, 0.5, 78)
		NotificationBtn.Size = UDim2.new(0, 150, 0, 28)
		NotificationBtn.Font = Enum.Font.Gotham
		NotificationBtn.Text = btntext or "Okay"
		NotificationBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
		NotificationBtn.TextSize = 14.000
		NotificationBtn.TextTransparency = 1.000
		NotificationBtn.AutoButtonColor = false

		NotificationBtnCorner.CornerRadius = UDim.new(0, 5)
		NotificationBtnCorner.Name = "NotificationBtnCorner"
		NotificationBtnCorner.Parent = NotificationBtn

		NotificationDesc.Name = "NotificationDesc"
		NotificationDesc.Parent = Notification
		NotificationDesc.AnchorPoint = Vector2.new(0.5, 0.5)
		NotificationDesc.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		NotificationDesc.BackgroundTransparency = 1.000
		NotificationDesc.Position = UDim2.new(0.5, 0, 0.458999991, 38)
		NotificationDesc.Size = UDim2.new(1.01365006, -25, 0.168424815, 25)
		NotificationDesc.Font = Enum.Font.Gotham
		NotificationDesc.Text = tostring(desc or "")
		NotificationDesc.TextColor3 = themes[selectedtheme].TextColor
		NotificationDesc.TextSize = 14.000
		NotificationDesc.TextTransparency = 1.000
		NotificationDesc.TextWrapped = true

		NotificationHoldScale.Name = "NotificationHoldScale"
		NotificationHoldScale.Parent = NotificationHold
		NotificationHoldScale.Scale = 0.950

		TweenService:Create(
			NotificationHold,
			TweenInfo.new(.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{BackgroundTransparency = 0.7}
		):Play()
		task.wait(.2)
		Notification:TweenSize(UDim2.new(0, 172, 0, 209), Enum.EasingDirection.Out, Enum.EasingStyle.Quart, .2, true)
		TweenService:Create(
			NotificationIco,
			TweenInfo.new(.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ImageTransparency = 0}
		):Play()
		TweenService:Create(
			Notification,
			TweenInfo.new(.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{BackgroundTransparency = 0}
		):Play()
		TweenService:Create(
			NotificationBtn,
			TweenInfo.new(.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{BackgroundTransparency = 0}
		):Play()
		TweenService:Create(
			NotificationDesc,
			TweenInfo.new(.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{TextTransparency = 0}
		):Play()
		TweenService:Create(
			NotificationBtn,
			TweenInfo.new(.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{TextTransparency = 0}
		):Play()
		TweenService:Create(
			NotificationTitle,
			TweenInfo.new(.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{TextTransparency = 0}
		):Play()

		NotificationBtn.MouseButton1Click:Connect(function()
			Notification:TweenSize(UDim2.new(0, 142, 0, 179), Enum.EasingDirection.Out, Enum.EasingStyle.Quart, .2, true)
			TweenService:Create(
				NotificationIco,
				TweenInfo.new(.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ImageTransparency = 1}
			):Play()
			TweenService:Create(
				Notification,
				TweenInfo.new(.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{BackgroundTransparency = 1}
			):Play()
			TweenService:Create(
				NotificationBtn,
				TweenInfo.new(.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{BackgroundTransparency = 1}
			):Play()
			TweenService:Create(
				NotificationDesc,
				TweenInfo.new(.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{TextTransparency = 1}
			):Play()
			TweenService:Create(
				NotificationBtn,
				TweenInfo.new(.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{TextTransparency = 1}
			):Play()
			TweenService:Create(
				NotificationTitle,
				TweenInfo.new(.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{TextTransparency = 1}
			):Play()
			task.wait(.2)
			TweenService:Create(
				NotificationHold,
				TweenInfo.new(.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{BackgroundTransparency = 1}
			):Play()
			task.wait(.2)
			NotificationHold:Destroy()
		end)
	end

	-- non-blocking: the old version waited inside the caller
	function lib:Notification(text,desc,icotext,btntext)
		task.spawn(notify, text, desc, icotext, btntext)
	end

	local tabhold = {}

	function tabhold:Label(text)
		local labelfunc = {}
		local LabelFrame = Instance.new("Frame")
		local Label = Instance.new("TextLabel")

		LabelFrame.Name = "LabelFrame"
		LabelFrame.Parent = TabHold
		LabelFrame.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		LabelFrame.BackgroundTransparency = 1.000
		LabelFrame.Size = UDim2.new(0, 70, 0, 17)

		Label.Name = "Label"
		Label.Parent = LabelFrame
		Label.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		Label.BackgroundTransparency = 1.000
		Label.Position = UDim2.new(0.139885604, 0, 0, 0)
		Label.Size = UDim2.new(0, 134, 0, 17)
		Label.Font = Enum.Font.GothamSemibold
		Label.Text = text
		Label.TextColor3 = Color3.fromRGB(182, 182, 182)
		Label.TextSize = 12.000
		Label.TextXAlignment = Enum.TextXAlignment.Left
		Label.TextYAlignment = Enum.TextYAlignment.Bottom
		LabelFrame.Size = UDim2.new(1, 0, 0, 17)
		function labelfunc:Change(tochange)
			Label.Text = tostring(tochange)
		end
		labelfunc.SetText = labelfunc.Change
		return labelfunc
	end

	-- old helpers (global): change every tab's labels whose text contains text1 (plain match)
	local function allLabels()
		local out = {}
		for _, page in ipairs(TabFolder:GetChildren()) do
			for _, v in ipairs(page:GetChildren()) do
				if v.Name == "Label" and v:IsA("TextLabel") then table.insert(out, v) end
			end
		end
		return out
	end
	function ChangeLabelText(text1, text2)
		for _, v in ipairs(allLabels()) do
			if string.find(v.Text, text1, 1, true) then
				v.Text = text2
			end
		end
	end

	function ChangeLabelColor(text, r, g, b)
		local c = typeof(r) == "Color3" and r or Color3.fromRGB(tonumber(r) or 0, tonumber(g) or 0, tonumber(b) or 0)
		for _, v in ipairs(allLabels()) do
			if string.find(v.Text, text, 1, true) then
				v:SetAttribute("custom", true)
				v.TextColor3 = c
			end
		end
	end

	function ResetLabelColor(text1)
		for _, v in ipairs(allLabels()) do
			if not text1 or string.find(v.Text, text1, 1, true) then v:SetAttribute("custom", nil) end
		end
		repaint()
	end

	-- the status bar under every tab: win:Status("Farming Forest 17", Color3) ; color nil = grey dot
	function tabhold:Status(text, color)
		StatusText.Text = tostring(text or "")
		StatusDot.BackgroundColor3 = color or Color3.fromRGB(182, 182, 182)
	end
	function tabhold:Title(text) TitleText.Text = tostring(text or "") end
	local tabList = {}
	function tabhold:SelectTab(i)
		local t = tabList[i]
		if t then t.select() end
	end


	function tabhold:Tab(text, img, color)
		local TabBtn = Instance.new("TextButton")
		local TabBtnCorner = Instance.new("UICorner")
		local TabBtnTitle = Instance.new("TextLabel")
		local TabBtnIco = Instance.new("ImageLabel")

		TabBtn.Name = "TabBtn"
		TabBtn.Parent = TabHold
		TabBtn.BackgroundColor3 = Color3.fromRGB(220, 220, 220)
		TabBtn.BackgroundTransparency = 1.000
		TabBtn.Position = UDim2.new(0, 0, 0.0849673226, 0)
		TabBtn.Size = UDim2.new(0, 143, 0, 26)
		TabBtn.AutoButtonColor = false
		TabBtn.Font = Enum.Font.SourceSans
		TabBtn.Text = ""
		TabBtn.TextColor3 = Color3.fromRGB(0, 0, 0)
		TabBtn.TextSize = 14.000

		TabBtnCorner.CornerRadius = UDim.new(0, 6)
		TabBtnCorner.Name = "TabBtnCorner"
		TabBtnCorner.Parent = TabBtn

		TabBtnTitle.Name = "TabBtnTitle"
		TabBtnTitle.Parent = TabBtn
		TabBtnTitle.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		TabBtnTitle.BackgroundTransparency = 1.000
		TabBtnTitle.Position = UDim2.new(0.170713201, 0, 0, 0)
		TabBtnTitle.Size = UDim2.new(0, 116, 0, 26)
		TabBtnTitle.Font = Enum.Font.Gotham
		TabBtnTitle.Text = text
		TabBtnTitle.TextColor3 = Color3.fromRGB(0, 0, 0)
		TabBtnTitle.TextSize = 13.000
		TabBtnTitle.TextXAlignment = Enum.TextXAlignment.Left

		TabBtnIco.Name = "TabBtnIco"
		TabBtnIco.Parent = TabBtn
		TabBtnIco.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		TabBtnIco.BackgroundTransparency = 1.000
		TabBtnIco.Position = UDim2.new(0.0120000001, 3, 0.170000002, 0)
		TabBtnIco.Size = UDim2.new(0, 17, 0, 17)
		TabBtnIco.Image = img
		TabBtnIco.ImageColor3 = color

		local Tab = Instance.new("ScrollingFrame")
		local TabLayout = Instance.new("UIListLayout")

		Tab.Name = "Tab"
		Tab.Parent = TabFolder
		Tab.Active = true
		Tab.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		Tab.BackgroundTransparency = 1.000
		Tab.BorderSizePixel = 0
		Tab.Position = UDim2.new(0, 0, 0, 0)
		Tab.Size = UDim2.new(1, 0, 1, 0)
		Tab.CanvasSize = UDim2.new(0, 0, 0, 0)
		Tab.AutomaticCanvasSize = Enum.AutomaticSize.Y
		Tab.ScrollingDirection = Enum.ScrollingDirection.Y
		Tab.ScrollBarThickness = 5
		Tab.Visible = false
		Tab.ScrollBarImageColor3 = Color3.fromRGB(213, 213, 213)

		TabLayout.Name = "TabLayout"
		TabLayout.Parent = Tab
		TabLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		TabLayout.SortOrder = Enum.SortOrder.LayoutOrder
		TabLayout.Padding = UDim.new(0, 8)
		local order = 0
		local function nextOrder() order += 1 return order end
		Tab.ChildAdded:Connect(function(c) if c:IsA("GuiObject") then c.LayoutOrder = nextOrder() end end)

		local TabPad = Instance.new("UIPadding")
		TabPad.PaddingTop = UDim.new(0, 2)
		TabPad.PaddingBottom = UDim.new(0, 8)
		TabPad.Parent = Tab
		TabBtnTitle.TextTruncate = Enum.TextTruncate.AtEnd

		local me = { layout = TabLayout }
		local function select()
			for i,v in next, TabFolder:GetChildren() do
				if v.Name == "Tab" then
					v.Visible = false
				end
			end
			Tab.Visible = true
			for i,v in next, TabHold:GetChildren() do
				if v.Name == "TabBtn" then
					v.BackgroundTransparency = 1
				end
			end
			TabBtn.BackgroundTransparency = 0
			current = me
			autoFit()
		end
		me.select = select
		table.insert(tabList, me)
		TabLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
			if current == me then autoFit() end
		end)

		if fs == false then
			fs = true
			select()
		end

		TabBtn.MouseButton1Click:Connect(select)

		themed(function()
					TabBtn.BackgroundColor3 = themes[selectedtheme].TabColor
					TabBtnTitle.TextColor3 = themes[selectedtheme].TextColor
					Tab.ScrollBarImageColor3 = themes[selectedtheme].ScrollBar
			end)
		local tabcontent = {}
		function tabcontent:Line(text)
			local Line = Instance.new("TextLabel")

			Line.Name = "Line"
			Line.Parent = Tab
			Line.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			Line.BackgroundTransparency = 1.000
			Line.Size = UDim2.new(1, 0, 0, 13)
			Line.Font = Enum.Font.GothamSemibold
			Line.Text = text
			Line.TextColor3 = Color3.fromRGB(0, 0, 0)
			Line.TextSize = 14.000
			Line.TextXAlignment = Enum.TextXAlignment.Left
			Line.TextWrapped = true
			Line.AutomaticSize = Enum.AutomaticSize.Y
			Line.LayoutOrder = nextOrder()

			themed(function()
						Line.TextColor3= themes[selectedtheme].TextColor
				end)
			local o = {}
			function o:SetText(t) Line.Text = tostring(t) end
			o.Change = o.SetText
			return o
		end
		function tabcontent:Label(text)
			local Label = Instance.new("TextLabel")

			Label.Name = "Label"
			Label.Parent = Tab
			Label.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			Label.BackgroundTransparency = 1.000
			Label.Size = UDim2.new(1, 0, 0, 13)
			Label.Font = Enum.Font.Gotham
			Label.Text = text
			Label.TextColor3 = Color3.fromRGB(0, 0, 0)
			Label.TextSize = 14.000
			Label.TextWrapped = true
			Label.RichText = true
			Label.AutomaticSize = Enum.AutomaticSize.Y
			Label.LayoutOrder = nextOrder()

			themed(function()
					    if not Label:GetAttribute("custom") then
						Label.TextColor3 = themes[selectedtheme].TextColor
					    end
				end)
			local o = {}
			function o:SetText(t) Label.Text = tostring(t) end
			function o:SetColor(c)
				if c then Label:SetAttribute("custom", true) Label.TextColor3 = c
				else Label:SetAttribute("custom", nil) Label.TextColor3 = themes[selectedtheme].TextColor end
			end
			function o:Get() return Label.Text end
			o.Change = o.SetText
			o.Instance = Label
			return o
		end
		-- several lines of text, left aligned (for status blocks)
		function tabcontent:Paragraph(text)
			local P = Instance.new("TextLabel")
			P.Name = "Paragraph"
			P.Parent = Tab
			P.BackgroundTransparency = 1
			P.Size = UDim2.new(1, -12, 0, 13)
			P.AutomaticSize = Enum.AutomaticSize.Y
			P.Font = Enum.Font.Gotham
			P.TextSize = 13
			P.TextWrapped = true
			P.RichText = true
			P.TextXAlignment = Enum.TextXAlignment.Left
			P.TextYAlignment = Enum.TextYAlignment.Top
			P.Text = tostring(text or "")
			P.LayoutOrder = nextOrder()
			themed(function() P.TextColor3 = themes[selectedtheme].TextColor end)
			local o = {}
			function o:SetText(t) P.Text = tostring(t or "") end
			o.Change = o.SetText
			return o
		end
		function tabcontent:Button(text, callback)
			local hovering = false
			local Button = Instance.new("TextButton")
			local ButtonFrame = Instance.new("Frame")
			local ButtonFrameCorner = Instance.new("UICorner")
			local ButtonCorner = Instance.new("UICorner")
			local ButtonHoverFrame = Instance.new("Frame")
			local ButtonHoverFrameCorner = Instance.new("UICorner")
			local ButtonText = Instance.new("TextLabel")

			Button.Name = "Button"
			Button.Parent = Tab
			Button.BackgroundColor3 = Color3.fromRGB(240, 240, 240)
			Button.BorderSizePixel = 0
			Button.AutoButtonColor = false
			Button.Font = Enum.Font.Gotham
			Button.TextColor3 = Color3.fromRGB(0, 0, 0)
			Button.TextSize = 14.000

			ButtonFrame.Name = "ButtonFrame"
			ButtonFrame.Parent = Button
			ButtonFrame.AnchorPoint = Vector2.new(0.5, 0.5)
			ButtonFrame.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			ButtonFrame.BorderSizePixel = 0
			ButtonFrame.Position = UDim2.new(0.5, 0, 0.5, 0)
			ButtonFrame.Size = UDim2.new(1, -4, 0, 21)

			ButtonFrameCorner.CornerRadius = UDim.new(0, 5)
			ButtonFrameCorner.Name = "ButtonFrameCorner"
			ButtonFrameCorner.Parent = ButtonFrame

			ButtonCorner.CornerRadius = UDim.new(0, 5)
			ButtonCorner.Name = "ButtonCorner"
			ButtonCorner.Parent = Button

			ButtonHoverFrame.Name = "ButtonHoverFrame"
			ButtonHoverFrame.Parent = Button
			ButtonHoverFrame.AnchorPoint = Vector2.new(0.5, 0.5)
			ButtonHoverFrame.BackgroundColor3 = Color3.fromRGB(31, 118, 219)
			ButtonHoverFrame.BackgroundTransparency = 1.000
			ButtonHoverFrame.BorderSizePixel = 0
			ButtonHoverFrame.Position = UDim2.new(0.5, 0, 0.528750002, 0)
			ButtonHoverFrame.Size = UDim2.new(1, 0, 0, 25)

			ButtonHoverFrameCorner.CornerRadius = UDim.new(0, 5)
			ButtonHoverFrameCorner.Name = "ButtonHoverFrameCorner"
			ButtonHoverFrameCorner.Parent = ButtonHoverFrame

			ButtonText.Name = "ButtonText"
			ButtonText.Parent = Button
			ButtonText.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			ButtonText.BackgroundTransparency = 1.000
			ButtonText.Size = UDim2.new(1, 0, 1, 0)
			ButtonText.Font = Enum.Font.Gotham
			ButtonText.Text = text
			ButtonText.TextColor3 = Color3.fromRGB(0, 0, 0)
			ButtonText.TextSize = 14.000

			themed(function()
						Button.BackgroundColor3 = themes[selectedtheme].Color2
						ButtonFrame.BackgroundColor3 = themes[selectedtheme].Color1
						if hovering == false then
							ButtonText.TextColor3 = themes[selectedtheme].TextColor
						end
				end)

			Button.MouseEnter:Connect(function()
				hovering = true
				ButtonHoverFrame.BackgroundTransparency = 0
				ButtonText.TextColor3 = Color3.fromRGB(255,255,255)
			end)

			Button.MouseLeave:Connect(function()
				hovering = false
				ButtonHoverFrame.BackgroundTransparency = 1
				ButtonText.TextColor3 = themes[selectedtheme].TextColor
			end)

			Button.MouseButton1Click:Connect(function()
				pcall(callback)
			end)

			Button.Size = UDim2.new(0, math.max(ButtonText.TextBounds.X + 20, 60), 0, 25)
			ButtonText:GetPropertyChangedSignal("TextBounds"):Connect(function()
				Button.Size = UDim2.new(0, math.max(ButtonText.TextBounds.X + 20, 60), 0, 25)
			end)
			Button.LayoutOrder = nextOrder()
			local o = {}
			function o:SetText(t) ButtonText.Text = tostring(t) end
			return o
		end
		function tabcontent:Toggle(text, default, callback)
			local toggled = false
			local Toggle = Instance.new("TextButton")
			local ToggleFrame = Instance.new("Frame")
			local ToggleFrameCorner = Instance.new("UICorner")
			local ToggleFrame1 = Instance.new("Frame")
			local ToggleFrame1Corner = Instance.new("UICorner")
			local ToggleFrame2 = Instance.new("Frame")
			local ToggleFrame2Corner = Instance.new("UICorner")
			local ToggleToggledFrame = Instance.new("Frame")
			local ToggleToggledFrameCorner = Instance.new("UICorner")
			local ToggleTick = Instance.new("ImageLabel")
			local ToggleText = Instance.new("TextLabel")

			Toggle.Name = "Toggle"
			Toggle.Parent = Tab
			Toggle.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			Toggle.BackgroundTransparency = 1.000
			Toggle.Position = UDim2.new(0.394886374, 0, 0.0925373137, 0)
			Toggle.Size = UDim2.new(0, 71, 0, 16)
			Toggle.Font = Enum.Font.SourceSans
			Toggle.Text = ""
			Toggle.TextColor3 = Color3.fromRGB(0, 0, 0)
			Toggle.TextSize = 14.000

			ToggleFrame.Name = "ToggleFrame"
			ToggleFrame.Parent = Toggle
			ToggleFrame.BackgroundColor3 = Color3.fromRGB(240, 240, 240)
			ToggleFrame.Size = UDim2.new(0, 16, 0, 16)

			ToggleFrameCorner.CornerRadius = UDim.new(0, 5)
			ToggleFrameCorner.Name = "ToggleFrameCorner"
			ToggleFrameCorner.Parent = ToggleFrame

			ToggleFrame1.Name = "ToggleFrame1"
			ToggleFrame1.Parent = ToggleFrame
			ToggleFrame1.BackgroundColor3 = Color3.fromRGB(240, 240, 240)
			ToggleFrame1.Size = UDim2.new(0, 16, 0, 16)

			ToggleFrame1Corner.CornerRadius = UDim.new(0, 5)
			ToggleFrame1Corner.Name = "ToggleFrame1Corner"
			ToggleFrame1Corner.Parent = ToggleFrame1

			ToggleFrame2.Name = "ToggleFrame2"
			ToggleFrame2.Parent = ToggleFrame1
			ToggleFrame2.AnchorPoint = Vector2.new(0.5, 0.5)
			ToggleFrame2.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			ToggleFrame2.Position = UDim2.new(0.5, 0, 0.5, 0)
			ToggleFrame2.Size = UDim2.new(0, 12, 0, 12)

			ToggleFrame2Corner.CornerRadius = UDim.new(0, 3)
			ToggleFrame2Corner.Name = "ToggleFrame2Corner"
			ToggleFrame2Corner.Parent = ToggleFrame2

			ToggleToggledFrame.Name = "ToggleToggledFrame"
			ToggleToggledFrame.Parent = ToggleFrame
			ToggleToggledFrame.BackgroundColor3 = Color3.fromRGB(31, 118, 219)
			ToggleToggledFrame.Position = UDim2.new(0, 0, 0, 0)
			ToggleToggledFrame.Size = UDim2.new(0, 16, 0, 16)
			ToggleToggledFrame.Visible = false

			ToggleToggledFrameCorner.CornerRadius = UDim.new(0, 5)
			ToggleToggledFrameCorner.Name = "ToggleToggledFrameCorner"
			ToggleToggledFrameCorner.Parent = ToggleToggledFrame

			ToggleTick.Name = "ToggleTick"
			ToggleTick.Parent = ToggleToggledFrame
			ToggleTick.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			ToggleTick.BackgroundTransparency = 1.000
			ToggleTick.Position = UDim2.new(0.0500000007, 0, 0, 1)
			ToggleTick.Size = UDim2.new(0, 13, 0, 13)
			ToggleTick.Image = "http://www.roblox.com/asset/?id=6031094667"

			ToggleText.Name = "ToggleText"
			ToggleText.Parent = Toggle
			ToggleText.AnchorPoint = Vector2.new(1, 1)
			ToggleText.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			ToggleText.BackgroundTransparency = 1.000
			ToggleText.Position = UDim2.new(1, 0, 1, 0)
			ToggleText.Size = UDim2.new(1, -23, 1, 0)
			ToggleText.Font = Enum.Font.Gotham
			ToggleText.Text = text
			ToggleText.TextColor3 = Color3.fromRGB(0, 0, 0)
			ToggleText.TextSize = 14.000
			ToggleText.TextXAlignment = Enum.TextXAlignment.Left

			Toggle.Size = UDim2.new(1, -12, 0, 16)
			Toggle.LayoutOrder = nextOrder()
			toggled = default and true or false
			ToggleToggledFrame.Visible = toggled
			local o = {}
			function o:Set(v, silent)
				toggled = v and true or false
				ToggleToggledFrame.Visible = toggled
				if not silent and callback then task.spawn(pcall, callback, toggled) end
			end
			function o:Get() return toggled end
			Toggle.MouseButton1Click:Connect(function()
				o:Set(not toggled)
			end)

			themed(function()
						ToggleFrame.BackgroundColor3 = themes[selectedtheme].Color2
						ToggleFrame1.BackgroundColor3 = themes[selectedtheme].Color2
						ToggleFrame2.BackgroundColor3 = themes[selectedtheme].Color1
						ToggleText.TextColor3 = themes[selectedtheme].TextColor
				end)
			return o
		end
		function tabcontent:Slider(text,precise, min, max, start, callback)
			local sliderfunc = {}
			local dragging = false
			local Slider = Instance.new("Frame")
			local SliderText = Instance.new("TextLabel")
			local SliderFrame = Instance.new("Frame")
			local SliderFrameCorner = Instance.new("UICorner")
			local SlideCurrent = Instance.new("Frame")
			local SlideCurrentCorner = Instance.new("UICorner")
			local SlideCircle = Instance.new("Frame")
			local SlideCircleCorner = Instance.new("UICorner")
			local SlideCircle1 = Instance.new("Frame")
			local SlideCircle1Corner = Instance.new("UICorner")
			local ValueFrame = Instance.new("Frame")
			local ValueFrameCorner = Instance.new("UICorner")
			local ValueText = Instance.new("TextLabel")

			Slider.Name = "Slider"
			Slider.Parent = Tab
			Slider.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			Slider.BackgroundTransparency = 1.000
			Slider.Position = UDim2.new(0.264204532, 0, 0.158208951, 0)
			Slider.Size = UDim2.new(0, 148, 0, 65)

			SliderText.Name = "SliderText"
			SliderText.Parent = Slider
			SliderText.AnchorPoint = Vector2.new(1, 1)
			SliderText.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			SliderText.BackgroundTransparency = 1.000
			SliderText.Position = UDim2.new(0.999999166, 0, 0.33968538, 0)
			SliderText.Size = UDim2.new(1.16142857, -23, 0.339685708, 0)
			SliderText.Font = Enum.Font.Gotham
			SliderText.Text = text
			SliderText.TextColor3 = Color3.fromRGB(0, 0, 0)
			SliderText.TextSize = 14.000
			SliderText.TextXAlignment = Enum.TextXAlignment.Left

			SliderFrame.Name = "SliderFrame"
			SliderFrame.Parent = Slider
			SliderFrame.BackgroundColor3 = Color3.fromRGB(240, 240, 240)
			SliderFrame.Position = UDim2.new(-0.00675675692, 0, 0.477616459, 0)
			SliderFrame.Size = UDim2.new(0, 148, 0, 5)

			SliderFrameCorner.CornerRadius = UDim.new(0, 15)
			SliderFrameCorner.Name = "SliderFrameCorner"
			SliderFrameCorner.Parent = SliderFrame

			SlideCurrent.Name = "SlideCurrent"
			SlideCurrent.Parent = SliderFrame
			SlideCurrent.BackgroundColor3 = Color3.fromRGB(31, 118, 219)
			SlideCurrent.BorderSizePixel = 0
			SlideCurrent.Position = UDim2.new(-0.0001257658, 0, -0.0184065104, 0)			local function frac(v) return math.clamp(((v or min) - min) / math.max(max - min, 1e-9), 0, 1) end
			local function fmt(v) if type(precise) == "number" then local m = 10 ^ precise return math.floor(v * m + 0.5) / m end return math.floor(v + 0.5) end
			local value = fmt(start or min)
			SlideCurrent.Size = UDim2.new(frac(value), 0, 0, 5)

			SlideCurrentCorner.CornerRadius = UDim.new(0, 15)
			SlideCurrentCorner.Name = "SlideCurrentCorner"
			SlideCurrentCorner.Parent = SlideCurrent

			SlideCircle.Name = "SlideCircle"
			SlideCircle.Parent = SliderFrame
			SlideCircle.BackgroundColor3 = Color3.fromRGB(181, 181, 181)			SlideCircle.Position = UDim2.new(frac(value), -6,-1.5, 0)
			SlideCircle.Size = UDim2.new(0, 22, 0, 22)

			SlideCircleCorner.CornerRadius = UDim.new(1, 0)
			SlideCircleCorner.Name = "SlideCircleCorner"
			SlideCircleCorner.Parent = SlideCircle

			SlideCircle1.Name = "SlideCircle1"
			SlideCircle1.Parent = SlideCircle
			SlideCircle1.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			SlideCircle1.Position = UDim2.new(0.0450000018, 0, 0.0410000011, 0)
			SlideCircle1.Size = UDim2.new(0, 20, 0, 20)

			SlideCircle1Corner.CornerRadius = UDim.new(1, 0)
			SlideCircle1Corner.Name = "SlideCircle1Corner"
			SlideCircle1Corner.Parent = SlideCircle1

			ValueFrame.Name = "ValueFrame"
			ValueFrame.Parent = Slider
			ValueFrame.BackgroundColor3 = Color3.fromRGB(240, 240, 240)
			ValueFrame.Position = UDim2.new(0, 0, 0.769924223, 0)
			ValueFrame.Size = UDim2.new(0, 45, 0, 14)

			ValueFrameCorner.CornerRadius = UDim.new(0, 3)
			ValueFrameCorner.Name = "ValueFrameCorner"
			ValueFrameCorner.Parent = ValueFrame

			ValueText.Name = "ValueText"
			ValueText.Parent = ValueFrame
			ValueText.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			ValueText.BackgroundTransparency = 1.000
			ValueText.Size = UDim2.new(1, 0, 0, 14)
			ValueText.Font = Enum.Font.GothamSemibold


			ValueText.Text = tostring(value)
			ValueText.TextColor3 = Color3.fromRGB(182, 182, 182)
			ValueText.TextSize = 11.000
			Slider.LayoutOrder = nextOrder()

			local function move(input)
				local pos =
					UDim2.new(
						math.clamp((input.Position.X - SliderFrame.AbsolutePosition.X) / SliderFrame.AbsoluteSize.X, 0, 1),
						-6,
						-1.5,
						0
					)
				local pos1 =
					UDim2.new(
						math.clamp((input.Position.X - SliderFrame.AbsolutePosition.X) / SliderFrame.AbsoluteSize.X, 0, 1),
						0,
						0,
						5
					)
				SlideCurrent.Size = pos1
				SlideCircle.Position = pos
				local percent = math.clamp((input.Position.X - SliderFrame.AbsolutePosition.X) / SliderFrame.AbsoluteSize.X, 0, 1)
				local val = fmt(min + (max - min) * percent)
				ValueText.Text = tostring(val)
				if val ~= value then
					value = val
					pcall(callback, val)
				end
			end
			SlideCircle.InputBegan:Connect(
				function(input)
					if input.UserInputType == Enum.UserInputType.MouseButton1 then
						dragging = true
					end
				end
			)
			SliderFrame.InputBegan:Connect(function(input)   -- a click on the bar jumps there
				if input.UserInputType == Enum.UserInputType.MouseButton1 then
					dragging = true
					move(input)
				end
			end)
			SliderFrame.InputEnded:Connect(function(input)
				if input.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
			end)
			SlideCircle.InputEnded:Connect(
				function(input)
					if input.UserInputType == Enum.UserInputType.MouseButton1 then
						dragging = false
					end
				end
			)
			game:GetService("UserInputService").InputChanged:Connect(function(input)
				if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
					move(input)
				end
			end)

			function sliderfunc:Set(val, silent)
				value = fmt(math.clamp(tonumber(val) or min, min, max))
				ValueText.Text = tostring(value)
				SlideCircle.Position = UDim2.new(frac(value), -6,-1.5, 0)
				SlideCurrent.Size = UDim2.new(frac(value), 0, 0, 5)
				if not silent then pcall(callback, value) end
			end
			function sliderfunc:Change(val) sliderfunc:Set(val, true) end
			function sliderfunc:Get() return value end

			themed(function()
						ValueFrame.BackgroundColor3 = themes[selectedtheme].Color2
						SliderFrame.BackgroundColor3 = themes[selectedtheme].Color2
						SlideCircle.BackgroundColor3 = themes[selectedtheme].Color3
						SlideCircle1.BackgroundColor3 = themes[selectedtheme].Color1
						SliderText.TextColor3 = themes[selectedtheme].TextColor
				end)

			Tab.CanvasSize = UDim2.new(0, 0, 0, TabLayout.AbsoluteContentSize.Y)
			return sliderfunc
		end
		function tabcontent:SlidersHorizontal()
			local SlidersHorizontal = Instance.new("Frame")
			local SlidersHorizontalLayout = Instance.new("UIListLayout")

			SlidersHorizontal.Name = "SlidersHorizontal"
			SlidersHorizontal.Parent = Tab
			SlidersHorizontal.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			SlidersHorizontal.BackgroundTransparency = 1.000
			SlidersHorizontal.Position = UDim2.new(1.35802472, 0, 0.364130437, 0)
			SlidersHorizontal.Size = UDim2.new(1, 0, 0, 65)

			SlidersHorizontalLayout.Name = "SlidersHorizontalLayout"
			SlidersHorizontalLayout.Parent = SlidersHorizontal
			SlidersHorizontalLayout.FillDirection = Enum.FillDirection.Horizontal
			SlidersHorizontalLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
			SlidersHorizontalLayout.SortOrder = Enum.SortOrder.LayoutOrder
			SlidersHorizontalLayout.Padding = UDim.new(0, 25)

			Tab.CanvasSize = UDim2.new(0, 0, 0, TabLayout.AbsoluteContentSize.Y)
			local SlidersHorizontalHold = {}
			function SlidersHorizontalHold:Slider(text,precise, min, max, start, callback)
				local sliderfunc = {}
				local dragging = false
				local Slider = Instance.new("Frame")
				local SliderText = Instance.new("TextLabel")
				local SliderFrame = Instance.new("Frame")
				local SliderFrameCorner = Instance.new("UICorner")
				local SlideCurrent = Instance.new("Frame")
				local SlideCurrentCorner = Instance.new("UICorner")
				local SlideCircle = Instance.new("Frame")
				local SlideCircleCorner = Instance.new("UICorner")
				local SlideCircle1 = Instance.new("Frame")
				local SlideCircle1Corner = Instance.new("UICorner")
				local ValueFrame = Instance.new("Frame")
				local ValueFrameCorner = Instance.new("UICorner")
				local ValueText = Instance.new("TextLabel")

				Slider.Name = "Slider"
				Slider.Parent = 			SlidersHorizontal
				Slider.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
				Slider.BackgroundTransparency = 1.000
				Slider.Position = UDim2.new(0.264204532, 0, 0.158208951, 0)
				Slider.Size = UDim2.new(0, 148, 0, 65)

				SliderText.Name = "SliderText"
				SliderText.Parent = Slider
				SliderText.AnchorPoint = Vector2.new(1, 1)
				SliderText.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
				SliderText.BackgroundTransparency = 1.000
				SliderText.Position = UDim2.new(0.999999166, 0, 0.33968538, 0)
				SliderText.Size = UDim2.new(1.16142857, -23, 0.339685708, 0)
				SliderText.Font = Enum.Font.Gotham
				SliderText.Text = text
				SliderText.TextColor3 = Color3.fromRGB(0, 0, 0)
				SliderText.TextSize = 14.000
				SliderText.TextXAlignment = Enum.TextXAlignment.Left

				SliderFrame.Name = "SliderFrame"
				SliderFrame.Parent = Slider
				SliderFrame.BackgroundColor3 = Color3.fromRGB(240, 240, 240)
				SliderFrame.Position = UDim2.new(-0.00675675692, 0, 0.477616459, 0)
				SliderFrame.Size = UDim2.new(0, 148, 0, 5)

				SliderFrameCorner.CornerRadius = UDim.new(0, 15)
				SliderFrameCorner.Name = "SliderFrameCorner"
				SliderFrameCorner.Parent = SliderFrame

				SlideCurrent.Name = "SlideCurrent"
				SlideCurrent.Parent = SliderFrame
				SlideCurrent.BackgroundColor3 = Color3.fromRGB(31, 118, 219)
				SlideCurrent.BorderSizePixel = 0
				SlideCurrent.Position = UDim2.new(-0.0001257658, 0, -0.0184065104, 0)
				SlideCurrent.Size = UDim2.new((start or 0) / max, 0, 0, 5)

				SlideCurrentCorner.CornerRadius = UDim.new(0, 15)
				SlideCurrentCorner.Name = "SlideCurrentCorner"
				SlideCurrentCorner.Parent = SlideCurrent

				SlideCircle.Name = "SlideCircle"
				SlideCircle.Parent = SliderFrame
				SlideCircle.BackgroundColor3 = Color3.fromRGB(181, 181, 181)
				SlideCircle.Position = UDim2.new((start or 0)/max, -6,-1.5, 0)
				SlideCircle.Size = UDim2.new(0, 22, 0, 22)

				SlideCircleCorner.CornerRadius = UDim.new(1, 0)
				SlideCircleCorner.Name = "SlideCircleCorner"
				SlideCircleCorner.Parent = SlideCircle

				SlideCircle1.Name = "SlideCircle1"
				SlideCircle1.Parent = SlideCircle
				SlideCircle1.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
				SlideCircle1.Position = UDim2.new(0.0450000018, 0, 0.0410000011, 0)
				SlideCircle1.Size = UDim2.new(0, 20, 0, 20)

				SlideCircle1Corner.CornerRadius = UDim.new(1, 0)
				SlideCircle1Corner.Name = "SlideCircle1Corner"
				SlideCircle1Corner.Parent = SlideCircle1

				ValueFrame.Name = "ValueFrame"
				ValueFrame.Parent = Slider
				ValueFrame.BackgroundColor3 = Color3.fromRGB(240, 240, 240)
				ValueFrame.Position = UDim2.new(0, 0, 0.769924223, 0)
				ValueFrame.Size = UDim2.new(0, 45, 0, 14)

				ValueFrameCorner.CornerRadius = UDim.new(0, 3)
				ValueFrameCorner.Name = "ValueFrameCorner"
				ValueFrameCorner.Parent = ValueFrame

				ValueText.Name = "ValueText"
				ValueText.Parent = ValueFrame
				ValueText.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
				ValueText.BackgroundTransparency = 1.000
				ValueText.Size = UDim2.new(1, 0, 0, 14)
				ValueText.Font = Enum.Font.GothamSemibold
				ValueText.Text = tostring(start and math.floor((start / max) * (max - min) + min) or 0)
				ValueText.TextColor3 = Color3.fromRGB(182, 182, 182)
				ValueText.TextSize = 11.000

				local function move(input)
					local pos =
						UDim2.new(
							math.clamp((input.Position.X - SliderFrame.AbsolutePosition.X) / SliderFrame.AbsoluteSize.X, 0, 1),
							-1,
							-1.5,
							0
						)
					local pos1 =
						UDim2.new(
							math.clamp((input.Position.X - SliderFrame.AbsolutePosition.X) / SliderFrame.AbsoluteSize.X, 0, 1),
							0,
							0,
							5
						)
					SlideCurrent.Size = pos1
					SlideCircle.Position = pos
					local size = math.clamp(Mouse.X - SlideCurrent.AbsolutePosition.X, 0, 148)
					local percent = size / 148

					local val = math.floor((min + (max- min) * percent) * 10) / 10
					if precise == true then
						ValueText.Text = tostring(math.ceil(val))
					else
						ValueText.Text = tostring(val)
					end

					pcall(callback, val)
				end
				SlideCircle.InputBegan:Connect(
					function(input)
						if input.UserInputType == Enum.UserInputType.MouseButton1 then
							dragging = true
						end
					end
				)
				SlideCircle.InputEnded:Connect(
					function(input)
						if input.UserInputType == Enum.UserInputType.MouseButton1 then
							dragging = false
						end
					end
				)
				game:GetService("UserInputService").InputChanged:Connect(function(input)
					if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
						move(input)
					end
				end)

				function sliderfunc:Change(val)
					ValueText.Text = tostring(val and math.floor((val / max) * (max - min) + min) or 0)
					SlideCircle.Position = UDim2.new((val or 0)/max, -6,-1.5, 0)
					SlideCurrent.Size = UDim2.new((val or 0) / max, 0, 0, 5)
				end


				themed(function()
							ValueFrame.BackgroundColor3 = themes[selectedtheme].Color2
							SliderFrame.BackgroundColor3 = themes[selectedtheme].Color2
							SlideCircle.BackgroundColor3 = themes[selectedtheme].Color3
							SlideCircle1.BackgroundColor3 = themes[selectedtheme].Color1
							SliderText.TextColor3 = themes[selectedtheme].TextColor
					end)
				return sliderfunc
			end
			return SlidersHorizontalHold
		end
		function tabcontent:Dropdown(text, list, callback)
			local dropfunc = {}
			local cur = nil
			local ItemCount = 0
			local DropToggled = false
			local Dropdown = Instance.new("Frame")
			local DropdownBtn = Instance.new("TextButton")
			local DropdownFrameOutline = Instance.new("Frame")
			local DropdownFrameOutlineCorner = Instance.new("UICorner")
			local DropdownFrame = Instance.new("Frame")
			local DropdownFrameCorner = Instance.new("UICorner")
			local DropdownIcoFrame = Instance.new("Frame")
			local DropdownIcoFrameCorner = Instance.new("UICorner")
			local DropdownIco = Instance.new("ImageLabel")
			local DropdownText = Instance.new("TextLabel")
			local DropdownFrameMainOutline = Instance.new("Frame")
			local DropdownFrameMainOutlineCorner = Instance.new("UICorner")
			local DropdownFrameMain = Instance.new("Frame")
			local DropdownFrameMainCorner = Instance.new("UICorner")
			local DropdownMainScrollFrame = Instance.new("ScrollingFrame")
			local DropdownMainScrollFrameLayout = Instance.new("UIListLayout")
			local DropdownTitle = Instance.new("TextLabel")
			local DropdownMainHold = Instance.new("Frame")


			Dropdown.Name = "Dropdown"
			Dropdown.Parent = Tab
			Dropdown.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			Dropdown.BackgroundTransparency = 1.000
			Dropdown.Position = UDim2.new(0.220833331, 0, 0.260726064, 0)
			Dropdown.Size = UDim2.new(0, 171, 0, 25)

			DropdownBtn.Name = "DropdownBtn"
			DropdownBtn.Parent = Dropdown
			DropdownBtn.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			DropdownBtn.BackgroundTransparency = 1.000
			DropdownBtn.Position = UDim2.new(0.257309943, 0, 0, 0)
			DropdownBtn.Size = UDim2.new(0, 170, 0, 25)
			DropdownBtn.Font = Enum.Font.SourceSans
			DropdownBtn.TextColor3 = Color3.fromRGB(0, 0, 0)
			DropdownBtn.TextSize = 14.000

			DropdownMainHold.Name = "DropdownBtn"
			DropdownMainHold.Parent = Tab
			DropdownMainHold.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			DropdownMainHold.BackgroundTransparency = 1.000
			DropdownMainHold.Position = UDim2.new(0.257309943, 0, 0, 0)
			DropdownMainHold.Size = UDim2.new(0, 170, 0, 25)
			DropdownMainHold.Visible = false

			DropdownFrameOutline.Name = "DropdownFrameOutline"
			DropdownFrameOutline.Parent = DropdownBtn
			DropdownFrameOutline.BackgroundColor3 = Color3.fromRGB(240, 240, 240)
			DropdownFrameOutline.Position = UDim2.new(0, 0, -0.00300000003, 0)
			DropdownFrameOutline.Size = UDim2.new(0, 171, 0, 25)

			DropdownFrameOutlineCorner.CornerRadius = UDim.new(0, 5)
			DropdownFrameOutlineCorner.Name = "DropdownFrameOutlineCorner"
			DropdownFrameOutlineCorner.Parent = DropdownFrameOutline

			DropdownFrame.Name = "DropdownFrame"
			DropdownFrame.Parent = DropdownFrameOutline
			DropdownFrame.AnchorPoint = Vector2.new(0.5, 0.5)
			DropdownFrame.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			DropdownFrame.BorderSizePixel = 0
			DropdownFrame.Position = UDim2.new(0.5, 0, 0.5, 0)
			DropdownFrame.Size = UDim2.new(1, -4, 0, 21)

			DropdownFrameCorner.CornerRadius = UDim.new(0, 5)
			DropdownFrameCorner.Name = "DropdownFrameCorner"
			DropdownFrameCorner.Parent = DropdownFrame

			DropdownIcoFrame.Name = "DropdownIcoFrame"
			DropdownIcoFrame.Parent = DropdownFrame
			DropdownIcoFrame.BackgroundColor3 = Color3.fromRGB(31, 118, 219)
			DropdownIcoFrame.Position = UDim2.new(0.884000003, 0, 0.150000006, 0)
			DropdownIcoFrame.Size = UDim2.new(0, 15, 1, -6)

			DropdownIcoFrameCorner.CornerRadius = UDim.new(0, 5)
			DropdownIcoFrameCorner.Name = "DropdownIcoFrameCorner"
			DropdownIcoFrameCorner.Parent = DropdownIcoFrame

			DropdownIco.Name = "DropdownIco"
			DropdownIco.Parent = DropdownIcoFrame
			DropdownIco.AnchorPoint = Vector2.new(0.5, 0.5)
			DropdownIco.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			DropdownIco.BackgroundTransparency = 1.000
			DropdownIco.Position = UDim2.new(0.5, 0, 0.5, 0)
			DropdownIco.Rotation = 90.000
			DropdownIco.Size = UDim2.new(0, 11, 0, 11)
			DropdownIco.Image = "http://www.roblox.com/asset/?id=6022668955"

			DropdownText.Name = "DropdownText"
			DropdownText.Parent = DropdownFrameOutline
			DropdownText.AnchorPoint = Vector2.new(1, 1)
			DropdownText.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			DropdownText.BackgroundTransparency = 1.000
			DropdownText.Position = UDim2.new(1, 0, 1, 0)
			DropdownText.Size = UDim2.new(1, -7, 1.00300002, 0)
			DropdownText.Font = Enum.Font.Gotham
			DropdownText.Text = ""
			DropdownText.TextColor3 = Color3.fromRGB(0, 0, 0)
			DropdownText.TextSize = 13.000
			DropdownText.TextXAlignment = Enum.TextXAlignment.Left

			DropdownFrameMainOutline.Name = "DropdownFrameMainOutline"
			DropdownFrameMainOutline.Parent = DropdownMainHold
			DropdownFrameMainOutline.BackgroundColor3 = Color3.fromRGB(240, 240, 240)
			DropdownFrameMainOutline.Position = UDim2.new(0.257309943, 0,0, 0)
			DropdownFrameMainOutline.Size = UDim2.new(0, 171, 0, 95)
			DropdownFrameMainOutline.Visible = false

			DropdownFrameMainOutlineCorner.CornerRadius = UDim.new(0, 5)
			DropdownFrameMainOutlineCorner.Name = "DropdownFrameMainOutlineCorner"
			DropdownFrameMainOutlineCorner.Parent = DropdownFrameMainOutline

			DropdownFrameMain.Name = "DropdownFrameMain"
			DropdownFrameMain.Parent = DropdownFrameMainOutline
			DropdownFrameMain.AnchorPoint = Vector2.new(0.5, 0.5)
			DropdownFrameMain.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			DropdownFrameMain.BorderSizePixel = 0
			DropdownFrameMain.Position = UDim2.new(0.5, 0, 0.5, 0)
			DropdownFrameMain.Size = UDim2.new(1, -4, 1, -4)

			DropdownFrameMainCorner.CornerRadius = UDim.new(0, 5)
			DropdownFrameMainCorner.Name = "DropdownFrameMainCorner"
			DropdownFrameMainCorner.Parent = DropdownFrameMain

			DropdownMainScrollFrame.Name = "DropdownMainScrollFrame"
			DropdownMainScrollFrame.Parent = DropdownFrameMain
			DropdownMainScrollFrame.Active = true
			DropdownMainScrollFrame.AnchorPoint = Vector2.new(0.5, 0.5)
			DropdownMainScrollFrame.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			DropdownMainScrollFrame.BackgroundTransparency = 1
			DropdownMainScrollFrame.BorderSizePixel = 0
			DropdownMainScrollFrame.Position = UDim2.new(0.511976063, 0, 0.50300014, 0)
			DropdownMainScrollFrame.Size = UDim2.new(0.0199520998, 155, 1, -13)
			DropdownMainScrollFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
			DropdownMainScrollFrame.ScrollBarThickness = 3
			DropdownMainScrollFrame.ScrollBarImageColor3 = Color3.fromRGB(213, 213, 213)

			DropdownMainScrollFrameLayout.Name = "DropdownMainScrollFrameLayout"
			DropdownMainScrollFrameLayout.Parent = DropdownMainScrollFrame
			DropdownMainScrollFrameLayout.SortOrder = Enum.SortOrder.LayoutOrder

			DropdownTitle.Name = "DropdownTitle"
			DropdownTitle.Parent = Dropdown
			DropdownTitle.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			DropdownTitle.BackgroundTransparency = 1.000
			DropdownTitle.BorderSizePixel = 0
			DropdownTitle.Position = UDim2.new(0, 37, 0, 0)
			DropdownTitle.Size = UDim2.new(0, 0, 0, 25)
			DropdownTitle.Font = Enum.Font.Gotham
			DropdownTitle.Text = text
			DropdownTitle.TextColor3 = Color3.fromRGB(0, 0, 0)
			DropdownTitle.TextSize = 14.000
			DropdownTitle.TextXAlignment = Enum.TextXAlignment.Right

			DropdownBtn.MouseButton1Click:Connect(function()
				if DropToggled == false then
					DropdownFrameMainOutline.Visible = true
					DropdownMainHold.Visible = true
					Tab.CanvasSize = UDim2.new(0, 0, 0, TabLayout.AbsoluteContentSize.Y)

				else
					DropdownFrameMainOutline.Visible = false
					DropdownMainHold.Visible = false
					Tab.CanvasSize = UDim2.new(0, 0, 0, TabLayout.AbsoluteContentSize.Y)
				end
				DropToggled = not DropToggled
			end)

			themed(function()
						DropdownTitle.TextColor3 = themes[selectedtheme].TextColor
						DropdownText.TextColor3 = themes[selectedtheme].TextColor
						DropdownFrameOutline.BackgroundColor3 = themes[selectedtheme].Color2
						DropdownFrame.BackgroundColor3 = themes[selectedtheme].Color1
						DropdownFrameMainOutline.BackgroundColor3 = themes[selectedtheme].Color2
						DropdownFrameMain.BackgroundColor3 = themes[selectedtheme].Color1
						DropdownMainScrollFrame.ScrollBarImageColor3 = themes[selectedtheme].ScrollBar
				end)

			Tab.CanvasSize = UDim2.new(0, 0, 0, TabLayout.AbsoluteContentSize.Y)
			for i,v in next, list do
				ItemCount = ItemCount + 1
				if ItemCount == 1 then
					DropdownFrameMainOutline.Size = UDim2.new(0, 171, 0, 43)
					DropdownMainHold.Size = UDim2.new(0, 170, 0, 43)
				elseif ItemCount == 2 then
					DropdownFrameMainOutline.Size = UDim2.new(0, 171, 0, 67)
					DropdownMainHold.Size = UDim2.new(0, 170, 0, 67)
				else
					DropdownFrameMainOutline.Size = UDim2.new(0, 171, 0, 92)
					DropdownMainHold.Size = UDim2.new(0, 170, 0, 92)
				end
				local ItemBtn = Instance.new("TextButton")
				local ItemBtnCorner = Instance.new("UICorner")
				local ItemText = Instance.new("TextLabel")
				local hovering = false

				ItemBtn.Name = "ItemBtn"
				ItemBtn.Parent = DropdownMainScrollFrame
				ItemBtn.BackgroundColor3 = Color3.fromRGB(31, 118, 219)
				ItemBtn.Size = UDim2.new(0, 154, 0, 25)
				ItemBtn.AutoButtonColor = false
				ItemBtn.Font = Enum.Font.SourceSans
				ItemBtn.Text = ""
				ItemBtn.TextColor3 = Color3.fromRGB(0, 0, 0)
				ItemBtn.TextSize = 14.000
				ItemBtn.BackgroundTransparency = 1

				ItemBtnCorner.CornerRadius = UDim.new(0, 5)
				ItemBtnCorner.Name = "ItemBtnCorner"
				ItemBtnCorner.Parent = ItemBtn

				ItemText.Name = "ItemText"
				ItemText.Parent = ItemBtn
				ItemText.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
				ItemText.BackgroundTransparency = 1.000
				ItemText.Position = UDim2.new(0.038961038, 0, 0, 0)
				ItemText.Size = UDim2.new(0, 148, 0, 25)
				ItemText.Font = Enum.Font.Gotham
				ItemText.Text = v
				ItemText.TextColor3 = Color3.fromRGB(255, 255, 255)
				ItemText.TextSize = 14.000
				ItemText.TextXAlignment = Enum.TextXAlignment.Left

				DropdownMainScrollFrame.CanvasSize = UDim2.new(0, 0, 0, DropdownMainScrollFrameLayout.AbsoluteContentSize.Y)

				ItemBtn.MouseButton1Click:Connect(function()
					DropdownMainHold.Visible = false
					DropToggled = not DropToggled
					DropdownText.Text = v
					cur = v
					pcall(callback, v)

				end)

				ItemBtn.MouseLeave:Connect(function()
					ItemBtn.BackgroundTransparency = 1
					hovering = false
				end)

				ItemBtn.MouseEnter:Connect(function()
					ItemBtn.BackgroundTransparency = 0
					hovering = true
				end)

				themed(function()
							if hovering == false then
								ItemText.TextColor3 = themes[selectedtheme].TextColor
							else
								ItemText.TextColor3 = Color3.fromRGB(255, 255, 255)
							end
					end)
			end
			function dropfunc:Add(toadd)
				ItemCount = ItemCount + 1
				if ItemCount == 1 then
					DropdownFrameMainOutline.Size = UDim2.new(0, 171, 0, 43)
					DropdownMainHold.Size = UDim2.new(0, 170, 0, 43)
				elseif ItemCount == 2 then
					DropdownFrameMainOutline.Size = UDim2.new(0, 171, 0, 67)
					DropdownMainHold.Size = UDim2.new(0, 170, 0, 67)
				else
					DropdownFrameMainOutline.Size = UDim2.new(0, 171, 0, 92)
					DropdownMainHold.Size = UDim2.new(0, 170, 0, 92)
				end
				local ItemBtn = Instance.new("TextButton")
				local ItemBtnCorner = Instance.new("UICorner")
				local ItemText = Instance.new("TextLabel")
				local hovering = false

				ItemBtn.Name = "ItemBtn"
				ItemBtn.Parent = DropdownMainScrollFrame
				ItemBtn.BackgroundColor3 = Color3.fromRGB(31, 118, 219)
				ItemBtn.Size = UDim2.new(0, 154, 0, 25)
				ItemBtn.AutoButtonColor = false
				ItemBtn.Font = Enum.Font.SourceSans
				ItemBtn.Text = ""
				ItemBtn.TextColor3 = Color3.fromRGB(0, 0, 0)
				ItemBtn.TextSize = 14.000
				ItemBtn.BackgroundTransparency = 1

				ItemBtnCorner.CornerRadius = UDim.new(0, 5)
				ItemBtnCorner.Name = "ItemBtnCorner"
				ItemBtnCorner.Parent = ItemBtn

				ItemText.Name = "ItemText"
				ItemText.Parent = ItemBtn
				ItemText.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
				ItemText.BackgroundTransparency = 1.000
				ItemText.Position = UDim2.new(0.038961038, 0, 0, 0)
				ItemText.Size = UDim2.new(0, 148, 0, 25)
				ItemText.Font = Enum.Font.Gotham
				ItemText.Text = toadd
				ItemText.TextColor3 = Color3.fromRGB(255, 255, 255)
				ItemText.TextSize = 14.000
				ItemText.TextXAlignment = Enum.TextXAlignment.Left

				DropdownMainScrollFrame.CanvasSize = UDim2.new(0, 0, 0, DropdownMainScrollFrameLayout.AbsoluteContentSize.Y)

				ItemBtn.MouseButton1Click:Connect(function()
					DropdownMainHold.Visible = false
					DropToggled = not DropToggled
					DropdownText.Text = toadd
					cur = toadd
					pcall(callback, toadd)

				end)

				ItemBtn.MouseLeave:Connect(function()
					ItemBtn.BackgroundTransparency = 1
					hovering = false
				end)

				ItemBtn.MouseEnter:Connect(function()
					ItemBtn.BackgroundTransparency = 0
					hovering = true
				end)

				themed(function()
							if hovering == false then
								ItemText.TextColor3 = themes[selectedtheme].TextColor
							else
								ItemText.TextColor3 = Color3.fromRGB(255, 255, 255)
							end
					end)
			end
			function dropfunc:Clear()
				ItemCount = 0
				for i,v in next, DropdownMainScrollFrame:GetChildren() do
					if v.Name == "ItemBtn" then
						v:Destroy()
					end
				end
			end
			function dropfunc:Set(v, silent)
				cur = v
				DropdownText.Text = tostring(v)
				if not silent then pcall(callback, v) end
			end
			function dropfunc:Get() return cur end
			function dropfunc:Refresh(newList)
				dropfunc:Clear()
				for _, v in ipairs(newList or {}) do dropfunc:Add(v) end
			end
			return dropfunc
		end
		function tabcontent:Colorpicker(text, preset, callback)
			local ColorPickerToggled = false
			local OldToggleColor = Color3.fromRGB(0, 0, 0)
			local OldColor = Color3.fromRGB(0, 0, 0)
			local OldColorSelectionPosition = nil
			local OldHueSelectionPosition = nil
			local ColorH, ColorS, ColorV = 1, 1, 1
			local RainbowColorPicker = false
			local ColorPickerInput = nil
			local ColorInput = nil
			local HueInput = nil
			local hovering = false

			local Colorpicker = Instance.new("TextButton")
			local ColorpickerFrameClr = Instance.new("Frame")
			local ColorpickerFrameClrCorner = Instance.new("UICorner")
			local ColorpickerText = Instance.new("TextLabel")

			Colorpicker.Name = "Colorpicker"
			Colorpicker.Parent = Tab
			Colorpicker.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			Colorpicker.BackgroundTransparency = 1.000
			Colorpicker.Position = UDim2.new(0.394886374, 0, 0.0925373137, 0)
			Colorpicker.Size = UDim2.new(0, 71, 0, 16)
			Colorpicker.Font = Enum.Font.SourceSans
			Colorpicker.Text = ""
			Colorpicker.TextColor3 = Color3.fromRGB(0, 0, 0)
			Colorpicker.TextSize = 14.000

			ColorpickerFrameClr.Name = "ColorpickerFrame"
			ColorpickerFrameClr.Parent = Colorpicker
			ColorpickerFrameClr.BackgroundColor3 = preset
			ColorpickerFrameClr.Size = UDim2.new(0, 16, 0, 16)

			ColorpickerFrameClrCorner.CornerRadius = UDim.new(1, 0)
			ColorpickerFrameClrCorner.Name = "ColorpickerFrameCorner"
			ColorpickerFrameClrCorner.Parent = ColorpickerFrameClr

			ColorpickerText.Name = "ColorpickerText"
			ColorpickerText.Parent = Colorpicker
			ColorpickerText.AnchorPoint = Vector2.new(1, 1)
			ColorpickerText.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			ColorpickerText.BackgroundTransparency = 1.000
			ColorpickerText.Position = UDim2.new(1, 0, 1, 0)
			ColorpickerText.Size = UDim2.new(1, -23, 1, 0)
			ColorpickerText.Font = Enum.Font.Gotham
			ColorpickerText.Text = text
			ColorpickerText.TextColor3 = Color3.fromRGB(0, 0, 0)
			ColorpickerText.TextSize = 14.000
			ColorpickerText.TextXAlignment = Enum.TextXAlignment.Left

			local ColorPickerOutlineFrame = Instance.new("Frame")
			local ColorPickerOutlineFrameCorner = Instance.new("UICorner")
			local ColorPickerFrame = Instance.new("Frame")
			local ColorPickerFrameCorner = Instance.new("UICorner")
			local Color = Instance.new("ImageLabel")
			local ColorCorner = Instance.new("UICorner")
			local ColorSelection = Instance.new("ImageLabel")
			local Hue = Instance.new("ImageLabel")
			local HueCorner = Instance.new("UICorner")
			local HueGradient = Instance.new("UIGradient")
			local HueSelection = Instance.new("ImageLabel")
			local ConfirmBtn = Instance.new("TextButton")
			local ConfirmBtnFrame = Instance.new("Frame")
			local ConfirmBtnFrameCorner = Instance.new("UICorner")
			local ConfirmBtnCorner = Instance.new("UICorner")
			local ConfirmBtnHoverFrame = Instance.new("Frame")
			local ConfirmBtnHoverFrameCorner = Instance.new("UICorner")
			local ConfirmBtnText = Instance.new("TextLabel")
			local RainbowToggle = Instance.new("TextButton")
			local RainbowToggleText = Instance.new("TextLabel")
			local RainbowToggleFrame = Instance.new("Frame")
			local RainbowToggleFrameCorner = Instance.new("UICorner")
			local RainbowToggleFrame1 = Instance.new("Frame")
			local RainbowToggleFrame1Corner = Instance.new("UICorner")
			local RainbowToggleFrame2 = Instance.new("Frame")
			local RainbowToggleFrame2Corner = Instance.new("UICorner")
			local RainbowToggleToggledFrame = Instance.new("Frame")
			local RainbowToggleToggledFrameCorner = Instance.new("UICorner")
			local ToggleTick = Instance.new("ImageLabel")


			ColorPickerOutlineFrame.Name = "ColorPickerOutlineFrame"
			ColorPickerOutlineFrame.Parent = Tab
			ColorPickerOutlineFrame.BackgroundColor3 = Color3.fromRGB(240, 240, 240)
			ColorPickerOutlineFrame.Position = UDim2.new(0.213314757, 0, 0.19295603, 0)
			ColorPickerOutlineFrame.Size = UDim2.new(0, 139, 0, 161)
			ColorPickerOutlineFrame.Visible = false

			ColorPickerOutlineFrameCorner.CornerRadius = UDim.new(0, 5)
			ColorPickerOutlineFrameCorner.Name = "ColorPickerOutlineFrameCorner"
			ColorPickerOutlineFrameCorner.Parent = ColorPickerOutlineFrame

			ColorPickerFrame.Name = "ColorPickerFrame"
			ColorPickerFrame.Parent = ColorPickerOutlineFrame
			ColorPickerFrame.AnchorPoint = Vector2.new(0.5, 0.5)
			ColorPickerFrame.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			ColorPickerFrame.Position = UDim2.new(0.5, 0, 0.5, 0)
			ColorPickerFrame.Size = UDim2.new(1, -4, 1, -4)

			ColorPickerFrameCorner.CornerRadius = UDim.new(0, 5)
			ColorPickerFrameCorner.Name = "ColorPickerFrameCorner"
			ColorPickerFrameCorner.Parent = ColorPickerFrame

			Color.Name = "Color"
			Color.Parent = ColorPickerFrame
			Color.BackgroundColor3 = Color3.fromRGB(255, 0, 4)
			Color.Position = UDim2.new(0, 7, 0, 10)
			Color.Size = UDim2.new(0, 94, 0, 89)
			Color.ZIndex = 10
			Color.Image = "rbxassetid://4155801252"

			ColorCorner.CornerRadius = UDim.new(0, 3)
			ColorCorner.Name = "ColorCorner"
			ColorCorner.Parent = Color

			ColorSelection.Name = "ColorSelection"
			ColorSelection.Parent = Color
			ColorSelection.AnchorPoint = Vector2.new(0.5, 0.5)
			ColorSelection.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			ColorSelection.BackgroundTransparency = 1.000
			ColorSelection.Position = UDim2.new(preset and select(3, Color3.toHSV(preset)))
			ColorSelection.Size = UDim2.new(0, 18, 0, 18)
			ColorSelection.Image = "http://www.roblox.com/asset/?id=4805639000"
			ColorSelection.ScaleType = Enum.ScaleType.Fit

			Hue.Name = "Hue"
			Hue.Parent = ColorPickerFrame
			Hue.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			Hue.Position = UDim2.new(0, 107, 0, 10)
			Hue.Size = UDim2.new(0, 20, 0, 87)
			Hue.ImageTransparency = 1.000

			HueCorner.CornerRadius = UDim.new(0, 3)
			HueCorner.Name = "HueCorner"
			HueCorner.Parent = Hue

			HueGradient.Color = ColorSequence.new {
				ColorSequenceKeypoint.new(0.00, Color3.fromRGB(255, 0, 4)),
				ColorSequenceKeypoint.new(0.20, Color3.fromRGB(234, 255, 0)),
				ColorSequenceKeypoint.new(0.40, Color3.fromRGB(21, 255, 0)),
				ColorSequenceKeypoint.new(0.60, Color3.fromRGB(0, 255, 255)),
				ColorSequenceKeypoint.new(0.80, Color3.fromRGB(0, 17, 255)),
				ColorSequenceKeypoint.new(0.90, Color3.fromRGB(255, 0, 251)),
				ColorSequenceKeypoint.new(1.00, Color3.fromRGB(255, 0, 4))
			}
			HueGradient.Rotation = 270
			HueGradient.Name = "HueGradient"
			HueGradient.Parent = Hue

			HueSelection.Name = "HueSelection"
			HueSelection.Parent = Hue
			HueSelection.AnchorPoint = Vector2.new(0.5, 0.5)
			HueSelection.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			HueSelection.BackgroundTransparency = 1.000
			HueSelection.Position = UDim2.new(0.48, 0, 1 - select(1, Color3.toHSV(preset)))
			HueSelection.Size = UDim2.new(0, 18, 0, 18)
			HueSelection.Image = "http://www.roblox.com/asset/?id=4805639000"

			ConfirmBtn.Name = "ConfirmBtn"
			ConfirmBtn.Parent = ColorPickerFrame
			ConfirmBtn.AnchorPoint = Vector2.new(0.5, 0)
			ConfirmBtn.BackgroundColor3 = Color3.fromRGB(240, 240, 240)
			ConfirmBtn.BorderSizePixel = 0
			ConfirmBtn.Position = UDim2.new(0.5, 0, 0, 105)
			ConfirmBtn.Size = UDim2.new(0, 71, 0, 25)
			ConfirmBtn.AutoButtonColor = false
			ConfirmBtn.Font = Enum.Font.Gotham
			ConfirmBtn.TextColor3 = Color3.fromRGB(0, 0, 0)
			ConfirmBtn.TextSize = 14.000

			ConfirmBtnFrame.Name = "ConfirmBtnFrame"
			ConfirmBtnFrame.Parent = ConfirmBtn
			ConfirmBtnFrame.AnchorPoint = Vector2.new(0.5, 0.5)
			ConfirmBtnFrame.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			ConfirmBtnFrame.BorderSizePixel = 0
			ConfirmBtnFrame.Position = UDim2.new(0.5, 0, 0.5, 0)
			ConfirmBtnFrame.Size = UDim2.new(1, -4, 0, 21)

			ConfirmBtnFrameCorner.CornerRadius = UDim.new(0, 5)
			ConfirmBtnFrameCorner.Name = "ConfirmBtnFrameCorner"
			ConfirmBtnFrameCorner.Parent = ConfirmBtnFrame

			ConfirmBtnCorner.CornerRadius = UDim.new(0, 5)
			ConfirmBtnCorner.Name = "ConfirmBtnCorner"
			ConfirmBtnCorner.Parent = ConfirmBtn

			ConfirmBtnHoverFrame.Name = "ConfirmBtnHoverFrame"
			ConfirmBtnHoverFrame.Parent = ConfirmBtn
			ConfirmBtnHoverFrame.AnchorPoint = Vector2.new(0.5, 0.5)
			ConfirmBtnHoverFrame.BackgroundColor3 = Color3.fromRGB(31, 118, 219)
			ConfirmBtnHoverFrame.BackgroundTransparency = 1.000
			ConfirmBtnHoverFrame.BorderSizePixel = 0
			ConfirmBtnHoverFrame.Position = UDim2.new(0.5, 0, 0.528750002, 0)
			ConfirmBtnHoverFrame.Size = UDim2.new(1, 0, 0, 25)

			ConfirmBtnHoverFrameCorner.CornerRadius = UDim.new(0, 5)
			ConfirmBtnHoverFrameCorner.Name = "ConfirmBtnHoverFrameCorner"
			ConfirmBtnHoverFrameCorner.Parent = ConfirmBtnHoverFrame

			ConfirmBtnText.Name = "ConfirmBtnText"
			ConfirmBtnText.Parent = ConfirmBtn
			ConfirmBtnText.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			ConfirmBtnText.BackgroundTransparency = 1.000
			ConfirmBtnText.Size = UDim2.new(1, 0, 1, 0)
			ConfirmBtnText.Font = Enum.Font.Gotham
			ConfirmBtnText.Text = "Confirm"
			ConfirmBtnText.TextColor3 = Color3.fromRGB(0, 0, 0)
			ConfirmBtnText.TextSize = 14.000

			RainbowToggle.Name = "RainbowToggle"
			RainbowToggle.Parent = ColorPickerFrame
			RainbowToggle.AnchorPoint = Vector2.new(0.5, 0)
			RainbowToggle.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			RainbowToggle.BackgroundTransparency = 1.000
			RainbowToggle.Position = UDim2.new(0.5, 0, 0, 135)
			RainbowToggle.Size = UDim2.new(0, 83, 0, 16)
			RainbowToggle.Font = Enum.Font.SourceSans
			RainbowToggle.Text = ""
			RainbowToggle.TextColor3 = Color3.fromRGB(0, 0, 0)
			RainbowToggle.TextSize = 14.000

			RainbowToggleText.Name = "RainbowToggleText"
			RainbowToggleText.Parent = RainbowToggle
			RainbowToggleText.AnchorPoint = Vector2.new(1, 1)
			RainbowToggleText.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			RainbowToggleText.BackgroundTransparency = 1.000
			RainbowToggleText.Position = UDim2.new(1.13727927, 0, 1, 0)
			RainbowToggleText.Size = UDim2.new(1.13727927, -23, 1, 0)
			RainbowToggleText.Font = Enum.Font.Gotham
			RainbowToggleText.Text = "Rainbow"
			RainbowToggleText.TextColor3 = Color3.fromRGB(0, 0, 0)
			RainbowToggleText.TextSize = 14.000
			RainbowToggleText.TextXAlignment = Enum.TextXAlignment.Left

			RainbowToggleFrame.Name = "RainbowToggleFrame"
			RainbowToggleFrame.Parent = RainbowToggle
			RainbowToggleFrame.BackgroundColor3 = Color3.fromRGB(240, 240, 240)
			RainbowToggleFrame.Size = UDim2.new(0, 16, 0, 16)

			RainbowToggleFrameCorner.CornerRadius = UDim.new(0, 5)
			RainbowToggleFrameCorner.Name = "RainbowToggleFrameCorner"
			RainbowToggleFrameCorner.Parent = RainbowToggleFrame

			RainbowToggleFrame1.Name = "RainbowToggleFrame1"
			RainbowToggleFrame1.Parent = RainbowToggleFrame
			RainbowToggleFrame1.BackgroundColor3 = Color3.fromRGB(240, 240, 240)
			RainbowToggleFrame1.Size = UDim2.new(0, 16, 0, 16)

			RainbowToggleFrame1Corner.CornerRadius = UDim.new(0, 5)
			RainbowToggleFrame1Corner.Name = "RainbowToggleFrame1Corner"
			RainbowToggleFrame1Corner.Parent = RainbowToggleFrame1

			RainbowToggleFrame2.Name = "RainbowToggleFrame2"
			RainbowToggleFrame2.Parent = RainbowToggleFrame1
			RainbowToggleFrame2.AnchorPoint = Vector2.new(0.5, 0.5)
			RainbowToggleFrame2.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			RainbowToggleFrame2.Position = UDim2.new(0.5, 0, 0.5, 0)
			RainbowToggleFrame2.Size = UDim2.new(0, 12, 0, 12)

			RainbowToggleFrame2Corner.CornerRadius = UDim.new(0, 3)
			RainbowToggleFrame2Corner.Name = "RainbowToggleFrame2Corner"
			RainbowToggleFrame2Corner.Parent = RainbowToggleFrame2

			RainbowToggleToggledFrame.Name = "RainbowToggleToggledFrame"
			RainbowToggleToggledFrame.Parent = RainbowToggleFrame
			RainbowToggleToggledFrame.BackgroundColor3 = Color3.fromRGB(31, 118, 219)
			RainbowToggleToggledFrame.Position = UDim2.new(0, 0, 0, 0)
			RainbowToggleToggledFrame.Size = UDim2.new(0, 16, 0, 16)
			RainbowToggleToggledFrame.Visible = false

			RainbowToggleToggledFrameCorner.CornerRadius = UDim.new(0, 5)
			RainbowToggleToggledFrameCorner.Name = "RainbowToggleToggledFrameCorner"
			RainbowToggleToggledFrameCorner.Parent = RainbowToggleToggledFrame

			ToggleTick.Name = "ToggleTick"
			ToggleTick.Parent = RainbowToggleToggledFrame
			ToggleTick.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			ToggleTick.BackgroundTransparency = 1.000
			ToggleTick.Position = UDim2.new(0.0500000007, 0, 0, 1)
			ToggleTick.Size = UDim2.new(0, 13, 0, 13)
			ToggleTick.Image = "http://www.roblox.com/asset/?id=6031094667"

			Tab.CanvasSize = UDim2.new(0, 0, 0, TabLayout.AbsoluteContentSize.Y)


			Colorpicker.MouseButton1Click:Connect(function()
				if ColorPickerToggled == false then
					ColorPickerOutlineFrame.Visible = true
					Tab.CanvasSize = UDim2.new(0, 0, 0, TabLayout.AbsoluteContentSize.Y)
				else
					ColorPickerOutlineFrame.Visible = false
					Tab.CanvasSize = UDim2.new(0, 0, 0, TabLayout.AbsoluteContentSize.Y)
				end
				ColorPickerToggled = not ColorPickerToggled
			end)

			local function UpdateColorPicker(nope)
				ColorpickerFrameClr.BackgroundColor3 = Color3.fromHSV(ColorH, ColorS, ColorV)
				Color.BackgroundColor3 = Color3.fromHSV(ColorH, 1, 1)

				pcall(callback, ColorpickerFrameClr.BackgroundColor3)
			end

			ColorH =
				1 -
				(math.clamp(HueSelection.AbsolutePosition.Y - Hue.AbsolutePosition.Y, 0, Hue.AbsoluteSize.Y) /
					Hue.AbsoluteSize.Y)
			ColorS =
				(math.clamp(ColorSelection.AbsolutePosition.X - Color.AbsolutePosition.X, 0, Color.AbsoluteSize.X) /
					Color.AbsoluteSize.X)
			ColorV =
				1 -
				(math.clamp(ColorSelection.AbsolutePosition.Y - Color.AbsolutePosition.Y, 0, Color.AbsoluteSize.Y) /
					Color.AbsoluteSize.Y)

			ColorpickerFrameClr.BackgroundColor3 = preset
			Color.BackgroundColor3 = preset
			pcall(callback, ColorpickerFrameClr.BackgroundColor3)

			Color.InputBegan:Connect(
				function(input)
					if input.UserInputType == Enum.UserInputType.MouseButton1 then
						if RainbowColorPicker then
							return
						end

						if ColorInput then
							ColorInput:Disconnect()
						end

						ColorInput =
							RunService.RenderStepped:Connect(
								function()
								local ColorX =
									(math.clamp(Mouse.X - Color.AbsolutePosition.X, 0, Color.AbsoluteSize.X) /
										Color.AbsoluteSize.X)
								local ColorY =
									(math.clamp(Mouse.Y - Color.AbsolutePosition.Y, 0, Color.AbsoluteSize.Y) /
										Color.AbsoluteSize.Y)

								ColorSelection.Position = UDim2.new(ColorX, 0, ColorY, 0)
								ColorS = ColorX
								ColorV = 1 - ColorY

								UpdateColorPicker(true)
							end
							)
					end
				end
			)

			Color.InputEnded:Connect(
				function(input)
					if input.UserInputType == Enum.UserInputType.MouseButton1 then
						if ColorInput then
							ColorInput:Disconnect()
						end
					end
				end
			)

			Hue.InputBegan:Connect(
				function(input)
					if input.UserInputType == Enum.UserInputType.MouseButton1 then
						if RainbowColorPicker then
							return
						end

						if HueInput then
							HueInput:Disconnect()
						end

						HueInput =
							RunService.RenderStepped:Connect(
								function()
								local HueY =
									(math.clamp(Mouse.Y - Hue.AbsolutePosition.Y, 0, Hue.AbsoluteSize.Y) /
										Hue.AbsoluteSize.Y)

								HueSelection.Position = UDim2.new(0.48, 0, HueY, 0)
								ColorH = 1 - HueY

								UpdateColorPicker(true)
							end
							)
					end
				end
			)

			Hue.InputEnded:Connect(
				function(input)
					if input.UserInputType == Enum.UserInputType.MouseButton1 then
						if HueInput then
							HueInput:Disconnect()
						end
					end
				end
			)

			RainbowToggle.MouseButton1Down:Connect(
				function()
					RainbowColorPicker = not RainbowColorPicker

					if ColorInput then
						ColorInput:Disconnect()
					end

					if HueInput then
						HueInput:Disconnect()
					end

					if RainbowColorPicker then
						RainbowToggleToggledFrame.Visible = true
						OldToggleColor = ColorpickerFrameClr.BackgroundColor3
						OldColor = Color.BackgroundColor3
						OldColorSelectionPosition = ColorSelection.Position
						OldHueSelectionPosition = HueSelection.Position

						while RainbowColorPicker do
							ColorpickerFrameClr.BackgroundColor3 = Color3.fromHSV(lib.RainbowColorValue, 1, 1)
							Color.BackgroundColor3 = Color3.fromHSV(lib.RainbowColorValue, 1, 1)

							ColorSelection.Position = UDim2.new(1, 0, 0, 0)
							HueSelection.Position = UDim2.new(0.48, 0, 0, lib.HueSelectionPosition)

							pcall(callback, ColorpickerFrameClr.BackgroundColor3)
							task.wait()
						end
					elseif not RainbowColorPicker then
						RainbowToggleToggledFrame.Visible = false

						Colorpicker.BackgroundColor3 = OldToggleColor
						Color.BackgroundColor3 = OldColor

						ColorSelection.Position = OldColorSelectionPosition
						HueSelection.Position = OldHueSelectionPosition

						pcall(callback, ColorpickerFrameClr.BackgroundColor3)
					end
				end
			)

			ConfirmBtn.MouseButton1Click:Connect(
				function()
					ColorPickerToggled = not ColorPickerToggled
					ColorPickerOutlineFrame.Visible = false
					Tab.CanvasSize = UDim2.new(0, 0, 0, TabLayout.AbsoluteContentSize.Y)
				end
			)

			ConfirmBtn.MouseEnter:Connect(function()
				ConfirmBtnHoverFrame.BackgroundTransparency = 0
				hovering = true
			end)

			ConfirmBtn.MouseLeave:Connect(function()
				ConfirmBtnHoverFrame.BackgroundTransparency = 1
				hovering = false
			end)

			themed(function()
						ColorPickerOutlineFrame.BackgroundColor3 = themes[selectedtheme].Color2
						ColorPickerFrame.BackgroundColor3 = themes[selectedtheme].Color1
						ColorpickerText.TextColor3 = themes[selectedtheme].TextColor
						ConfirmBtn.BackgroundColor3 = themes[selectedtheme].Color2
						ConfirmBtnFrame.BackgroundColor3 = themes[selectedtheme].Color1
						RainbowToggleFrame.BackgroundColor3 = themes[selectedtheme].Color2
						RainbowToggleFrame1.BackgroundColor3 = themes[selectedtheme].Color2
						RainbowToggleFrame2.BackgroundColor3 = themes[selectedtheme].Color1
						RainbowToggleText.TextColor3 = themes[selectedtheme].TextColor
						if hovering == false then
							ConfirmBtnText.TextColor3 = themes[selectedtheme].TextColor
						else
							ConfirmBtnText.TextColor3 = Color3.fromRGB(255, 255, 255)
						end
				end)

		end
		function tabcontent:RadioButtons(text, list, callback)
			local radios, cur = {}, nil
			local FrameSize = 0
			local fr = false
			local RadioButtonsFrame = Instance.new("Frame")
			local RadioButtonsTitle = Instance.new("TextLabel")
			local RadioButtonsHolder = Instance.new("Frame")
			local RadioButtonsHolderLayout = Instance.new("UIListLayout")

			RadioButtonsFrame.Name = "RadioButtonsFrame"
			RadioButtonsFrame.Parent = Tab
			RadioButtonsFrame.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			RadioButtonsFrame.BackgroundTransparency = 1.000
			RadioButtonsFrame.Position = UDim2.new(0.453125, 0, 0.558208883, 0)
			RadioButtonsFrame.Size = UDim2.new(0, 11, 0, 0)

			RadioButtonsTitle.Name = "RadioButtonsTitle"
			RadioButtonsTitle.Parent = RadioButtonsFrame
			RadioButtonsTitle.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			RadioButtonsTitle.BackgroundTransparency = 1.000
			RadioButtonsTitle.BorderSizePixel = 0
			RadioButtonsTitle.Size = UDim2.new(0, 0, 0, 16)
			RadioButtonsTitle.Font = Enum.Font.Gotham
			RadioButtonsTitle.Text = text
			RadioButtonsTitle.TextColor3 = Color3.fromRGB(0, 0, 0)
			RadioButtonsTitle.TextSize = 14.000
			RadioButtonsTitle.TextXAlignment = Enum.TextXAlignment.Right

			RadioButtonsHolder.Name = "RadioButtonsHolder"
			RadioButtonsHolder.Parent = RadioButtonsFrame
			RadioButtonsHolder.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			RadioButtonsHolder.BackgroundTransparency = 1.000
			RadioButtonsHolder.Position = UDim2.new(0.727272749, 0, 0, 0)
			RadioButtonsHolder.Size = UDim2.new(0, 100, 0, 16)

			RadioButtonsHolderLayout.Name = "RadioButtonsHolderLayout"
			RadioButtonsHolderLayout.Parent = RadioButtonsHolder
			RadioButtonsHolderLayout.SortOrder = Enum.SortOrder.LayoutOrder
			RadioButtonsHolderLayout.Padding = UDim.new(0, 4)

			Tab.CanvasSize = UDim2.new(0, 0, 0, TabLayout.AbsoluteContentSize.Y)

			themed(function()
						RadioButtonsTitle.TextColor3 = themes[selectedtheme].TextColor
				end)

			for i,v in next, list do
				FrameSize = FrameSize + 20
				RadioButtonsFrame.Size = UDim2.new(0, 11, 0, FrameSize)
				Tab.CanvasSize = UDim2.new(0, 0, 0, TabLayout.AbsoluteContentSize.Y)
				local RadioBtn = Instance.new("TextButton")
				local RadioBtnText = Instance.new("TextLabel")
				local RadioBtnFrame = Instance.new("Frame")
				local RadioBtnFrame1 = Instance.new("Frame")
				local RadioBtnFrame1Corner = Instance.new("UICorner")
				local RadioBtnFrame2 = Instance.new("Frame")
				local RadioBtnFrame2Corner = Instance.new("UICorner")
				local RadioBtnToggledFrame = Instance.new("Frame")
				local RadioBtnToggledFrameCorner = Instance.new("UICorner")
				local RadioBtnToggledFrame_2 = Instance.new("Frame")
				local RadioBtnToggledFrameCorner_2 = Instance.new("UICorner")
				local RadioBtnCorner = Instance.new("UICorner")

				RadioBtn.Name = "RadioBtn"
				RadioBtn.Parent = RadioButtonsHolder
				RadioBtn.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
				RadioBtn.BackgroundTransparency = 1.000
				RadioBtn.Size = UDim2.new(0, 791, 0, 16)
				RadioBtn.Font = Enum.Font.SourceSans
				RadioBtn.Text = ""
				RadioBtn.TextColor3 = Color3.fromRGB(0, 0, 0)
				RadioBtn.TextSize = 14.000

				RadioBtnText.Name = "RadioBtnText"
				RadioBtnText.Parent = RadioBtn
				RadioBtnText.AnchorPoint = Vector2.new(1, 1)
				RadioBtnText.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
				RadioBtnText.BackgroundTransparency = 1.000
				RadioBtnText.Position = UDim2.new(1, 0, 1, 0)
				RadioBtnText.Size = UDim2.new(1, -23, 1, 0)
				RadioBtnText.Font = Enum.Font.Gotham
				RadioBtnText.Text = v
				RadioBtnText.TextColor3 = Color3.fromRGB(0, 0, 0)
				RadioBtnText.TextSize = 14.000
				RadioBtnText.TextXAlignment = Enum.TextXAlignment.Left

				RadioBtnFrame.Name = "RadioBtnFrame"
				RadioBtnFrame.Parent = RadioBtn
				RadioBtnFrame.BackgroundColor3 = Color3.fromRGB(240, 240, 240)
				RadioBtnFrame.Size = UDim2.new(0, 16, 0, 16)

				RadioBtnFrame1.Name = "RadioBtnFrame1"
				RadioBtnFrame1.Parent = RadioBtnFrame
				RadioBtnFrame1.BackgroundColor3 = Color3.fromRGB(240, 240, 240)
				RadioBtnFrame1.Size = UDim2.new(0, 16, 0, 16)

				RadioBtnFrame1Corner.CornerRadius = UDim.new(1, 0)
				RadioBtnFrame1Corner.Name = "RadioBtnFrame1Corner"
				RadioBtnFrame1Corner.Parent = RadioBtnFrame1

				RadioBtnFrame2.Name = "RadioBtnFrame2"
				RadioBtnFrame2.Parent = RadioBtnFrame1
				RadioBtnFrame2.AnchorPoint = Vector2.new(0.5, 0.5)
				RadioBtnFrame2.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
				RadioBtnFrame2.Position = UDim2.new(0.5, 0, 0.5, 0)
				RadioBtnFrame2.Size = UDim2.new(0, 12, 0, 12)

				RadioBtnFrame2Corner.CornerRadius = UDim.new(1, 0)
				RadioBtnFrame2Corner.Name = "RadioBtnFrame2Corner"
				RadioBtnFrame2Corner.Parent = RadioBtnFrame2

				RadioBtnToggledFrame.Name = "RadioBtnToggledFrame"
				RadioBtnToggledFrame.Parent = RadioBtnFrame
				RadioBtnToggledFrame.BackgroundColor3 = Color3.fromRGB(31, 118, 219)
				RadioBtnToggledFrame.Size = UDim2.new(0, 16, 0, 16)
				RadioBtnToggledFrame.Visible = false

				RadioBtnToggledFrameCorner.CornerRadius = UDim.new(1, 0)
				RadioBtnToggledFrameCorner.Name = "RadioBtnToggledFrameCorner"
				RadioBtnToggledFrameCorner.Parent = RadioBtnToggledFrame

				RadioBtnToggledFrame_2.Name = "RadioBtnToggledFrame"
				RadioBtnToggledFrame_2.Parent = RadioBtnToggledFrame
				RadioBtnToggledFrame_2.AnchorPoint = Vector2.new(0.5, 0.5)
				RadioBtnToggledFrame_2.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
				RadioBtnToggledFrame_2.Position = UDim2.new(0.5, 0, 0.5, 0)
				RadioBtnToggledFrame_2.Size = UDim2.new(1, -9, 1, -9)

				RadioBtnToggledFrameCorner_2.CornerRadius = UDim.new(1, 0)
				RadioBtnToggledFrameCorner_2.Name = "RadioBtnToggledFrameCorner"
				RadioBtnToggledFrameCorner_2.Parent = RadioBtnToggledFrame_2

				RadioBtnCorner.CornerRadius = UDim.new(1, 0)
				RadioBtnCorner.Name = "RadioBtnCorner"
				RadioBtnCorner.Parent = RadioBtnFrame

				radios[v] = RadioBtnToggledFrame
				RadioBtn.MouseButton1Click:Connect(function()
					cur = v
					pcall(callback, v)
					for i,v in next, RadioButtonsHolder:GetChildren() do
						if v.Name == "RadioBtn" then
							v.RadioBtnFrame.RadioBtnToggledFrame.Visible = false
						end
					end
					RadioBtnToggledFrame.Visible = true
				end)

				if fr == false then
					fr = true
					cur = v
					RadioBtnToggledFrame.Visible = true
					pcall(callback, v)
				end

				themed(function()
					        RadioBtnFrame.BackgroundColor3 = themes[selectedtheme].Color2
							RadioBtnFrame1.BackgroundColor3 = themes[selectedtheme].Color2
							RadioBtnFrame2.BackgroundColor3 = themes[selectedtheme].Color1
							RadioBtnText.TextColor3 = themes[selectedtheme].TextColor
					end)
			end
			local o = {}
			function o:Set(v, silent)
				if not radios[v] then return end
				for _, f in pairs(radios) do f.Visible = false end
				radios[v].Visible = true
				cur = v
				if not silent then pcall(callback, v) end
			end
			function o:Get() return cur end
			return o
		end
		function tabcontent:Bind(text, preset, keyboardonly, holdmode, callback )

			local OldBind = preset.Name
			local LoadFromPreset = false
			local JustBinded = false
			local HoldModeToggled = false

			local NotAllowedKeys = {
				Return = true,
				Space = true,
				Tab = true,
				Unknown = true,
				MouseButton1 = true
			}

			local AllowedMouseTypes = {
				MouseButton2 = true,
				MouseButton3 = true
			}

			local ShortenedNames = {
				LeftShift = "LShift",
				RightShift = "RShift",
				LeftControl = "LCtrl",
				RightControl = "RCtrl",
				LeftAlt = "LAlt",
				RightAlt = "RAlt",
				CapsLock = "Caps",
				One = "1",
				Two = "2",
				Three = "3",
				Four = "4",
				Five = "5",
				Six = "6",
				Seven = "7",
				Eight = "8",
				Nine = "9",
				Zero = "0",
				KeypadOne = "Num-1",
				KeypadTwo = "Num-2",
				KeypadThree = "Num-3",
				KeypadFour = "Num-4",
				KeypadFive = "Num-5",
				KeypadSix = "Num-6",
				KeypadSeven = "Num-7",
				KeypadEight = "Num-8",
				KeypadNine = "Num-9",
				KeypadZero = "Num-0",
				Minus = "-",
				Equals = "=",
				Tilde = "~",
				LeftBracket = "[",
				RightBracket = "]",
				RightParenthesis = ")",
				LeftParenthesis = "(",
				Semicolon = ";",
				Quote = "'",
				BackSlash = "\\",
				Comma = ",",
				Period = ".",
				Slash = "/",
				Asterisk = "*",
				Plus = "+",
				Period = ".",
				Backquote = "`",
				MouseButton1 = "M1",
				MouseButton2 = "M2",
				MouseButton3 = "M3"
			}



			local Bind = Instance.new("Frame")
			local BindBtn = Instance.new("TextButton")
			local BindBtnFrameOutline = Instance.new("Frame")
			local BindBtnFrameOutlineCorner = Instance.new("UICorner")
			local BindBtnFrame = Instance.new("Frame")
			local BindBtnFrameCorner = Instance.new("UICorner")
			local BindBtnText = Instance.new("TextLabel")
			local BindTitle = Instance.new("TextLabel")


			Bind.Name = "Bind"
			Bind.Parent = Tab
			Bind.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			Bind.BackgroundTransparency = 1.000
			Bind.Position = UDim2.new(0.298295468, 0, 0.629850626, 0)
			Bind.Size = UDim2.new(0, 120, 0, 25)

			BindBtn.Name = "BindBtn"
			BindBtn.Parent = Bind
			BindBtn.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			BindBtn.BackgroundTransparency = 1.000
			BindBtn.Position = UDim2.new(0.456999987, 0, 0, 0)
			BindBtn.Size = UDim2.new(0, 90, 0, 25)
			BindBtn.Font = Enum.Font.SourceSans
			BindBtn.TextColor3 = Color3.fromRGB(0, 0, 0)
			BindBtn.TextSize = 14.000

			BindBtnFrameOutline.Name = "BindBtnFrameOutline"
			BindBtnFrameOutline.Parent = BindBtn
			BindBtnFrameOutline.BackgroundColor3 = Color3.fromRGB(240, 240, 240)
			BindBtnFrameOutline.Position = UDim2.new(0, 0, -0.00300048827, 0)
			BindBtnFrameOutline.Size = UDim2.new(0, 92, 0, 25)

			BindBtnFrameOutlineCorner.CornerRadius = UDim.new(0, 5)
			BindBtnFrameOutlineCorner.Name = "BindBtnFrameOutlineCorner"
			BindBtnFrameOutlineCorner.Parent = BindBtnFrameOutline

			BindBtnFrame.Name = "BindBtnFrame"
			BindBtnFrame.Parent = BindBtnFrameOutline
			BindBtnFrame.AnchorPoint = Vector2.new(0.5, 0.5)
			BindBtnFrame.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			BindBtnFrame.BorderSizePixel = 0
			BindBtnFrame.Position = UDim2.new(0.5, 0, 0.5, 0)
			BindBtnFrame.Size = UDim2.new(1, -4, 0, 21)

			BindBtnFrameCorner.CornerRadius = UDim.new(0, 5)
			BindBtnFrameCorner.Name = "BindBtnFrameCorner"
			BindBtnFrameCorner.Parent = BindBtnFrame

			BindBtnText.Name = "BindBtnText"
			BindBtnText.Parent = BindBtnFrameOutline
			BindBtnText.AnchorPoint = Vector2.new(1, 1)
			BindBtnText.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			BindBtnText.BackgroundTransparency = 1.000
			BindBtnText.Position = UDim2.new(0.989130437, 0, 1, 0)
			BindBtnText.Size = UDim2.new(1.05434787, -7, 1.00300002, 0)
			BindBtnText.Font = Enum.Font.Gotham
			BindBtnText.Text = (ShortenedNames[preset.Name] or ShortenedNames[preset] or preset.Name or "None")
			BindBtnText.TextColor3 = Color3.fromRGB(0, 0, 0)
			BindBtnText.TextSize = 13.000

			BindTitle.Name = "BindTitle"
			BindTitle.Parent = Bind
			BindTitle.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			BindTitle.BackgroundTransparency = 1.000
			BindTitle.BorderSizePixel = 0
			BindTitle.Position = UDim2.new(0, 50, 0, 0)
			BindTitle.Size = UDim2.new(0, 0, 0, 25)
			BindTitle.Font = Enum.Font.Gotham
			BindTitle.Text = text
			BindTitle.TextColor3 = Color3.fromRGB(0, 0, 0)
			BindTitle.TextSize = 14.000
			BindTitle.TextXAlignment = Enum.TextXAlignment.Right

			if preset == Enum.KeyCode.Unknown or preset == "Unknown" then
				BindBtnText.Text = "None"
			end

			BindBtn.MouseButton1Click:Connect(function()
				if lib.CurrentlyBinding then return end

				BindBtnText.Text = "..."

				local Input, Bruh = UserInputService.InputBegan:wait()
				lib.CurrentlyBinding = true

				if Input.KeyCode.Name == "Backspace" or Input.KeyCode.Name == "Delete" then
					BindBtnText.Text = "None"
					OldBind = Enum.KeyCode.Unknown.Name
					lib.CurrentlyBinding = false
					JustBinded = false
					return
				end

				if (Input.UserInputType ~= Enum.UserInputType.Keyboard and (AllowedMouseTypes[Input.UserInputType.Name]) and (not keyboardonly)) or (Input.KeyCode and (not NotAllowedKeys[Input.KeyCode.Name])) then
					local BindName = ((Input.UserInputType ~= Enum.UserInputType.Keyboard and Input.UserInputType.Name) or Input.KeyCode.Name)
					BindBtnText.Text = ShortenedNames[BindName] or BindName
					OldBind = BindName
					lib.CurrentlyBinding = false
					JustBinded = true
				else
					BindBtnText.Text = ShortenedNames[OldBind] or OldBind
					lib.CurrentlyBinding = false
				end
			end)

			if not holdmode then
				UserInputService.InputBegan:Connect(function(input, gameprocessedevent)
					if not gameprocessedevent then
						if UserInputService:GetFocusedTextBox() then return end
						if OldBind == Enum.KeyCode.Unknown.Name then return end
						if JustBinded then JustBinded = false return end

						local BindName = ((input.UserInputType ~= Enum.UserInputType.Keyboard and input.UserInputType.Name) or input.KeyCode.Name)

						if BindName == OldBind then
							pcall(callback)
						end
					end
				end)
			else
				UserInputService.InputBegan:Connect(function(input, gameprocessedevent)
					if not gameprocessedevent then
						if UserInputService:GetFocusedTextBox() then return end
						if OldBind == Enum.KeyCode.Unknown.Name then return end
						if JustBinded then JustBinded = false return end

						local BindName = ((input.UserInputType ~= Enum.UserInputType.Keyboard and input.UserInputType.Name) or input.KeyCode.Name)

						if BindName == OldBind then
							pcall(callback, true)
						end
					end
				end)

				UserInputService.InputEnded:Connect(function(input, gameprocessedevent)
					if not gameprocessedevent then
						if UserInputService:GetFocusedTextBox() then return end
						if OldBind == Enum.KeyCode.Unknown.Name then return end
						if JustBinded then JustBinded = false return end

						HoldModeToggled = false
						local BindName = ((input.UserInputType ~= Enum.UserInputType.Keyboard and input.UserInputType.Name) or input.KeyCode.Name)

						if BindName == OldBind then
							pcall(callback, false)
						end
					end
				end)
			end

			Tab.CanvasSize = UDim2.new(0, 0, 0, TabLayout.AbsoluteContentSize.Y)

			themed(function()
						BindBtnFrameOutline.BackgroundColor3 = themes[selectedtheme].Color2
						BindBtnFrame.BackgroundColor3  = themes[selectedtheme].Color1
						BindTitle.TextColor3= themes[selectedtheme].TextColor
						BindBtnText.TextColor3= themes[selectedtheme].TextColor
				end)
		end
		function tabcontent:Textbox(text,numbersonly, disapper, callback)
			local Textbox = Instance.new("Frame")
			local TextboxTitle = Instance.new("TextLabel")
			local TextboxFrameOutline = Instance.new("Frame")
			local TextboxFrameOutlineCorner = Instance.new("UICorner")
			local TextboxFrame = Instance.new("Frame")
			local TextboxFrameCorner = Instance.new("UICorner")
			local TextBox = Instance.new("TextBox")

			Textbox.Name = "Textbox"
			Textbox.Parent = Tab
			Textbox.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			Textbox.BackgroundTransparency = 1.000
			Textbox.Position = UDim2.new(0.220833331, 0, 0.260726064, 0)
			Textbox.Size = UDim2.new(0, 171, 0, 25)

			TextboxTitle.Name = "TextboxTitle"
			TextboxTitle.Parent = Textbox
			TextboxTitle.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			TextboxTitle.BackgroundTransparency = 1.000
			TextboxTitle.BorderSizePixel = 0
			TextboxTitle.Position = UDim2.new(0, 37, 0, 0)
			TextboxTitle.Size = UDim2.new(0, 0, 0, 25)
			TextboxTitle.Font = Enum.Font.Gotham
			TextboxTitle.Text = text
			TextboxTitle.TextColor3 = Color3.fromRGB(0, 0, 0)
			TextboxTitle.TextSize = 14.000
			TextboxTitle.TextXAlignment = Enum.TextXAlignment.Right

			TextboxFrameOutline.Name = "TextboxFrameOutline"
			TextboxFrameOutline.Parent = Textbox
			TextboxFrameOutline.BackgroundColor3 = Color3.fromRGB(240, 240, 240)
			TextboxFrameOutline.Position = UDim2.new(0.256999999, 0, 0, 0)
			TextboxFrameOutline.Size = UDim2.new(0, 171, 0, 25)

			TextboxFrameOutlineCorner.CornerRadius = UDim.new(0, 5)
			TextboxFrameOutlineCorner.Name = "TextboxFrameOutlineCorner"
			TextboxFrameOutlineCorner.Parent = TextboxFrameOutline

			TextboxFrame.Name = "TextboxFrame"
			TextboxFrame.Parent = TextboxFrameOutline
			TextboxFrame.AnchorPoint = Vector2.new(0.5, 0.5)
			TextboxFrame.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			TextboxFrame.BorderSizePixel = 0
			TextboxFrame.Position = UDim2.new(0.5, 0, 0.5, 0)
			TextboxFrame.Size = UDim2.new(1, -4, 0, 21)
			TextboxFrame.ClipsDescendants = true

			TextboxFrameCorner.CornerRadius = UDim.new(0, 5)
			TextboxFrameCorner.Name = "TextboxFrameCorner"
			TextboxFrameCorner.Parent = TextboxFrame

			TextBox.Parent = TextboxFrame
			TextBox.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			TextBox.BackgroundTransparency = 1.000
			TextBox.Position = UDim2.new(0, 7, 0, 0)
			TextBox.Size = UDim2.new(1, -7, 1, 0)
			TextBox.Font = Enum.Font.Gotham
			TextBox.Text = ""
			TextBox.TextColor3 = Color3.fromRGB(0, 0, 0)
			TextBox.TextSize = 14.000
			TextBox.TextXAlignment = Enum.TextXAlignment.Left


			TextBox.FocusLost:Connect(
				function(ep)
					do   -- Enter or a click elsewhere both keep the text (it used to need Enter)
						if #TextBox.Text > 0 then
							pcall(callback, TextBox.Text)
							if disapper then
								TextBox.Text = ""
							end
						end
					end
				end
			)

			TextBox:GetPropertyChangedSignal("Text"):Connect(function()
				if numbersonly == true then
					TextBox.Text = TextBox.Text:gsub('%D+', '');
					end
			end)

			Tab.CanvasSize = UDim2.new(0, 0, 0, TabLayout.AbsoluteContentSize.Y)


			themed(function()
						TextboxFrameOutline.BackgroundColor3 = themes[selectedtheme].Color2
						TextboxFrame.BackgroundColor3  = themes[selectedtheme].Color1
						TextBox.TextColor3= themes[selectedtheme].TextColor
						TextboxTitle.TextColor3= themes[selectedtheme].TextColor
				end)
			local o = {}
			function o:Set(v) TextBox.Text = tostring(v == nil and "" or v) end
			function o:Get() return numbersonly and tonumber(TextBox.Text) or TextBox.Text end
			return o
		end
		-- a list you can put in order with the arrow buttons: items = {{id=, name=}}; cb(ids in the new order)
		function tabcontent:Order(text, items, callback)
			local Holder = Instance.new("Frame")
			Holder.Name = "Order"
			Holder.Parent = Tab
			Holder.BackgroundTransparency = 1
			Holder.Size = UDim2.new(1, -12, 0, 20)
			Holder.AutomaticSize = Enum.AutomaticSize.Y
			local HL = Instance.new("UIListLayout", Holder)
			HL.Padding = UDim.new(0, 4)
			HL.SortOrder = Enum.SortOrder.LayoutOrder
			local Title = Instance.new("TextLabel")
			Title.Parent = Holder
			Title.BackgroundTransparency = 1
			Title.Size = UDim2.new(1, 0, 0, 18)
			Title.Font = Enum.Font.Gotham
			Title.TextSize = 14
			Title.TextXAlignment = Enum.TextXAlignment.Left
			Title.Text = text
			Title.LayoutOrder = 0
			local list, rows = {}, {}
			for _, it in ipairs(items or {}) do table.insert(list, it) end
			local function ids() local r = {} for _, it in ipairs(list) do table.insert(r, it.id) end return r end
			local draw
			local function move(i, d)
				local j = i + d
				if j < 1 or j > #list then return end
				list[i], list[j] = list[j], list[i]
				draw()
				if callback then task.spawn(pcall, callback, ids()) end
			end
			local function paintRows()
				for _, r in ipairs(rows) do
					r.frame.BackgroundColor3 = themes[selectedtheme].Color2
					r.label.TextColor3 = themes[selectedtheme].TextColor
					for _, b in ipairs(r.buttons) do b.BackgroundColor3 = themes[selectedtheme].Color1 b.TextColor3 = themes[selectedtheme].TextColor end
				end
			end
			draw = function()
				for _, r in ipairs(rows) do r.frame:Destroy() end
				rows = {}
				for i, it in ipairs(list) do
					local F = Instance.new("Frame")
					F.Parent = Holder
					F.Size = UDim2.new(1, 0, 0, 25)
					F.LayoutOrder = i
					F.BorderSizePixel = 0
					Instance.new("UICorner", F).CornerRadius = UDim.new(0, 5)
					local L = Instance.new("TextLabel")
					L.Parent = F
					L.BackgroundTransparency = 1
					L.Position = UDim2.new(0, 8, 0, 0)
					L.Size = UDim2.new(1, -70, 1, 0)
					L.Font = Enum.Font.Gotham
					L.TextSize = 13
					L.TextXAlignment = Enum.TextXAlignment.Left
					L.TextTruncate = Enum.TextTruncate.AtEnd
					L.Text = i .. ".  " .. tostring(it.name or it.id)
					local bs = {}
					for k, g in ipairs({ { "▲", -1 }, { "▼", 1 } }) do
						local B = Instance.new("TextButton")
						B.Parent = F
						B.AutoButtonColor = false
						B.Font = Enum.Font.GothamBold
						B.TextSize = 10
						B.Text = g[1]
						B.Size = UDim2.new(0, 24, 0, 19)
						B.Position = UDim2.new(1, -56 + (k - 1) * 28, 0, 3)
						B.BorderSizePixel = 0
						Instance.new("UICorner", B).CornerRadius = UDim.new(0, 4)
						B.MouseButton1Click:Connect(function() move(i, g[2]) end)
						table.insert(bs, B)
					end
					table.insert(rows, { frame = F, label = L, buttons = bs })
				end
				paintRows()
			end
			themed(function() Title.TextColor3 = themes[selectedtheme].TextColor paintRows() end)
			local o = {}
			function o:Set(order)
				local byId = {}
				for _, it in ipairs(items or {}) do byId[it.id] = it end
				local seen, nl = {}, {}
				for _, id in ipairs(order or {}) do if byId[id] and not seen[id] then table.insert(nl, byId[id]) seen[id] = true end end
				for _, it in ipairs(items or {}) do if not seen[it.id] then table.insert(nl, it) end end
				list = nl
				draw()
			end
			function o:Get() return ids() end
			draw()
			return o
		end
		return tabcontent
	end
	tabhold.Instance = Main
	return tabhold
end

return lib


]===]
return M
