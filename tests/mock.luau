--!nocheck
-- A small fake Roblox + fake Anime Card Clash server, enough to run the farm offline with the Luau CLI.
-- Virtual clock: task.wait advances time instantly, so hours of farming run in a second.
local M = { now = 1792263600 + 600, sent = {}, violations = {}, files = {}, printed = {} }
local realLoadstring, realSetfenv = loadstring, setfenv
local env = setmetatable({}, { __index = _G })
M.env = env
setfenv(1, env)
env._G = env
loadstring = function(s, n) local f, e = realLoadstring(s, n) if f then realSetfenv(f, env) end return f, e end

-- ---------- scheduler ----------
local queue = {}
local function schedule(co, at, ...) table.insert(queue, { co = co, at = at, args = table.pack(...) }) end
M.schedule = schedule
local current
task = {}
function task.wait(s)
	s = s or 0.03
	local co = coroutine.running()
	schedule(co, M.now + math.max(s, 0.001))
	coroutine.yield()
	return s
end
function task.spawn(f, ...)
	local co = type(f) == "thread" and f or coroutine.create(f)
	schedule(co, M.now, ...)
	return co
end
function task.delay(s, f, ...) local co = coroutine.create(f) schedule(co, M.now + s, ...) return co end
function M.run(untilT)
	while true do
		table.sort(queue, function(a, b) return a.at < b.at end)
		local item = table.remove(queue, 1)
		if not item or item.at > untilT then if item then table.insert(queue, 1, item) end M.now = untilT return end
		M.now = math.max(M.now, item.at)
		if coroutine.status(item.co) == "suspended" then
			local ok, err = coroutine.resume(item.co, table.unpack(item.args, 1, item.args.n))
			if not ok then error("coroutine error: " .. tostring(err) .. "\n" .. debug.traceback(item.co)) end
		end
	end
end
local realOs = os
os = setmetatable({
	clock = function() return M.now end,
	time = function() return math.floor(M.now) end,
	date = function(f) return realOs.date(f, math.floor(M.now)) end,
}, { __index = realOs })

-- ---------- datatypes ----------
local function dt(name, fields) local t = fields t.__type = name return setmetatable(t, { __index = function() return 0 end }) end
UDim = { new = function(s, o) return dt("UDim", { Scale = s, Offset = o }) end }
UDim2 = {
	new = function(xs, xo, ys, yo) return dt("UDim2", { X = UDim.new(xs or 0, xo or 0), Y = UDim.new(ys or 0, yo or 0) }) end,
	fromOffset = function(x, y) return UDim2.new(0, x, 0, y) end,
	fromScale = function(x, y) return UDim2.new(x, 0, y, 0) end,
}
local V2mt = {}
V2mt.__index = V2mt
V2mt.__sub = function(a, b) return Vector2.new(a.X - b.X, a.Y - b.Y) end
Vector2 = { new = function(x, y) return setmetatable({ X = x or 0, Y = y or 0 }, V2mt) end }
Vector3 = { new = function(x, y, z) return { X = x, Y = y, Z = z } end }
local Cmt = {}
Cmt.__index = Cmt
function Cmt:ToHSV() return 0.5, 0.5, 0.5 end
Color3 = {
	new = function(r, g, b) return setmetatable({ R = r, G = g, B = b }, Cmt) end,
	fromRGB = function(r, g, b) return Color3.new(r / 255, g / 255, b / 255) end,
	fromHSV = function() return Color3.new(0.5, 0.5, 0.5) end,
}
TweenInfo = { new = function() return {} end }
local function enumNode(path)
	return setmetatable({ Name = path:match("[^%.]+$") }, { __index = function(t, k) local v = enumNode(path .. "." .. k) rawset(t, k, v) return v end })
end
Enum = enumNode("Enum")
typeof = typeof or type

-- ---------- instances ----------
local function signal()
	local s = { fns = {} }
	function s:Connect(f) table.insert(self.fns, f) return { Disconnect = function() for i, g in ipairs(s.fns) do if g == f then table.remove(s.fns, i) end end end } end
	function s:Fire(...) for _, f in ipairs(self.fns) do f(...) end end
	return s
end
local Inst = {}
local EVENTS = { MouseButton1Click = 1, MouseButton1Down = 1, MouseEnter = 1, MouseLeave = 1, InputBegan = 1, InputChanged = 1, InputEnded = 1, FocusLost = 1, Heartbeat = 1, OnClientEvent = 1 }
local function newInstance(class, name)
	local o = { ClassName = class, Name = name or class, _children = {}, _props = {} }
	return setmetatable(o, Inst)
end
Inst.__index = function(o, k)
	local m = rawget(Inst, k)
	if m then return m end
	if EVENTS[k] then local s = signal() rawset(o, k, s) return s end
	if k == "Parent" then return rawget(o, "_parent") end
	if k == "AbsolutePosition" or k == "AbsoluteSize" then return Vector2.new(0, 100) end
	local p = rawget(o, "_props")[k]
	if p ~= nil then return p end
	local c = o:FindFirstChild(k)
	if c then return c end
	return nil
end
Inst.__newindex = function(o, k, v)
	if k == "Parent" then
		local old = rawget(o, "_parent")
		if old then for i, c in ipairs(old._children) do if c == o then table.remove(old._children, i) break end end end
		rawset(o, "_parent", v)
		if v then table.insert(v._children, o) end
		return
	end
	rawget(o, "_props")[k] = v
end
function Inst:FindFirstChild(n) for _, c in ipairs(self._children) do if c.Name == n then return c end end end
function Inst:WaitForChild(n) return self:FindFirstChild(n) end
function Inst:FindFirstChildOfClass(cl) for _, c in ipairs(self._children) do if c.ClassName == cl then return c end end end
function Inst:GetChildren() local r = {} for _, c in ipairs(self._children) do table.insert(r, c) end return r end
function Inst:GetDescendants()
	local r = {}
	local function walk(x) for _, c in ipairs(x._children) do table.insert(r, c) walk(c) end end
	walk(self)
	return r
end
function Inst:IsA(cl)
	if cl == "GuiObject" or cl == "Instance" then return true end
	return self.ClassName == cl
end
function Inst:GetFullName() local p, s = rawget(self, "_parent"), self.Name while p do s = p.Name .. "." .. s p = rawget(p, "_parent") end return s end
function Inst:Destroy() self.Parent = nil rawset(self, "_destroyed", true) end
function Inst:FireServer(...) M.onRemote(self.Name, ...) end
function Inst:Disconnect() end
Instance = { new = function(class, parent) local o = newInstance(class) if parent then o.Parent = parent end return o end }
M.Instance = newInstance

-- ---------- services ----------
local services = {}
local game_ = newInstance("DataModel", "game")
game = game_
function game_:GetService(n) return services[n] end
game_.JobId = "test-job"
local function svc(n) local s = newInstance(n, n) s.Parent = game_ services[n] = s return s end
local Players = svc("Players")
local LP = newInstance("Player", "Whousleaks")
LP.Parent = Players
Players.LocalPlayer = LP
local pg = newInstance("PlayerGui", "PlayerGui") pg.Parent = LP
local CoreGui = svc("CoreGui")
local UIS = svc("UserInputService")
local RunService = svc("RunService")
local TweenService = svc("TweenService")
function TweenService:Create(o, _, props) return { Play = function() for k, v in pairs(props) do o[k] = v end end } end
local Stats = svc("Stats")
function Stats:GetTotalMemoryUsageMb() return M.memory or 1800 end
local HttpService = svc("HttpService")
local RS = svc("ReplicatedStorage")
workspace = newInstance("Workspace", "Workspace")
function workspace:GetServerTimeNow() M.now += 0.0005 return M.now end

-- remotes, in a folder like the game's
local net = newInstance("Folder", "network@eventDefinitions") net.Parent = RS
for _, n in ipairs({ "fightBattleTowerWave", "setPartyPosition", "removePartyPosition", "forfeitBattle", "setBattleSessionDisplayState",
	"teleport", "fightStoryBoss", "fightInfinite", "pauseInfinite", "useBackpackItem", "claimDailyLogin", "claimDailyQuest" }) do
	local r = newInstance("RemoteEvent", n) r.Parent = net
end
-- a debug copy that must be ignored
local jabby = newInstance("Folder", "JABBY_REMOTES") jabby.Parent = RS
local fake = newInstance("RemoteEvent", "fightBattleTowerWave") fake.Parent = jabby

-- modules used through require()
local modules = {}
local shared = newInstance("Folder", "shared") shared.Parent = RS
local common = newInstance("Folder", "common") common.Parent = RS
local compsMod = newInstance("ModuleScript", "components") compsMod.Parent = shared
local timeMod = newInstance("ModuleScript", "time") timeMod.Parent = common
local COMPS = { User = { name = "User" }, Location = { name = "Location" }, BattleSession = { name = "BattleSession" }, Boss = { name = "Boss" } }
modules[compsMod] = COMPS
modules[timeMod] = { EST_OFFSET_SECONDS = 5 * 3600 }
local realRequire = require
require = function(x) if type(x) == "table" and modules[x] then return modules[x] end return realRequire(x) end

-- ---------- JSON ----------
local function enc(v)
	local t = type(v)
	if t == "nil" then return "null" end
	if t == "boolean" then return tostring(v) end
	if t == "number" then return (v == math.floor(v) and math.abs(v) < 1e15) and string.format("%d", v) or string.format("%.6f", v) end
	if t == "string" then return '"' .. v:gsub('[%c"\\]', function(c) return string.format("\\u%04x", c:byte()) end) .. '"' end
	if t == "table" then
		if #v > 0 or next(v) == nil then local o = {} for _, x in ipairs(v) do table.insert(o, enc(x)) end return "[" .. table.concat(o, ",") .. "]" end
		local o = {} for k, x in pairs(v) do table.insert(o, enc(tostring(k)) .. ":" .. enc(x)) end return "{" .. table.concat(o, ",") .. "}"
	end
	return "null"
end
local function dec(s)
	local i = 1
	local function ws() i = s:find("[^%s]", i) or #s + 1 end
	local val
	local function str()
		local j, out = i + 1, {}
		while true do
			local c = s:sub(j, j)
			if c == '"' then i = j + 1 return table.concat(out) end
			if c == "\\" then
				local n = s:sub(j + 1, j + 1)
				if n == "u" then table.insert(out, utf8.char(tonumber(s:sub(j + 2, j + 5), 16))) j += 6
				else table.insert(out, ({ n = "\n", t = "\t", r = "\r", b = "\b", f = "\f" })[n] or n) j += 2 end
			else table.insert(out, c) j += 1 end
		end
	end
	val = function()
		ws()
		local c = s:sub(i, i)
		if c == "{" then
			i += 1 local o = {} ws()
			if s:sub(i, i) == "}" then i += 1 return o end
			while true do ws() local k = str() ws() i += 1 o[k] = val() ws() local d = s:sub(i, i) i += 1 if d == "}" then return o end end
		elseif c == "[" then
			i += 1 local o = {} ws()
			if s:sub(i, i) == "]" then i += 1 return o end
			while true do table.insert(o, val()) ws() local d = s:sub(i, i) i += 1 if d == "]" then return o end end
		elseif c == '"' then return str()
		elseif s:sub(i, i + 3) == "true" then i += 4 return true
		elseif s:sub(i, i + 4) == "false" then i += 5 return false
		elseif s:sub(i, i + 3) == "null" then i += 4 return nil
		else local n = s:match("^-?[%d%.eE+-]+", i) i += #n return tonumber(n) end
	end
	return val()
end
function HttpService:JSONEncode(v) return enc(v) end
function HttpService:JSONDecode(s) return dec(s) end

-- ---------- executor API ----------
local function getenv() return env end
getgenv = getenv
gethui = function() return CoreGui end
readfile = function(p) local f = M.files[p] if f == nil then error("no file " .. p) end return f end
writefile = function(p, s) M.files[p] = s end
isfile = function(p) return M.files[p] ~= nil end
isfolder = function() return true end
makefolder = function() end
local realPrint = print
print = function(...) local o = {} for i = 1, select("#", ...) do o[i] = tostring((select(i, ...))) end table.insert(M.printed, table.concat(o, " ")) if M.verbose then realPrint(...) end end

-- ---------- fake game state + server ----------
local userEnt, entities = 1, {}
local sessions = {}      -- entity -> session
local nextEnt = 100
local user = { battleTowerProgress = {}, storyProgress = {}, inventories = { main = { backpack = {} } }, questProgress = { daily = {} } }
local location = { place = "lobby" }
M.user, M.location, M.sessions = user, location, sessions
local slot15 = { attack = {}, support = {} }
local userDoc = { player = LP, inventories = { main = { party = { slots = { slot_15 = slot15, slot_1 = { attack = { "luck_card:secret" }, support = {} } } } } } }
M.slot15, M.userDoc = slot15, userDoc
local bosses = {}   -- entity -> {id=}
M.bosses = bosses
local world = {}
function world:get(e, c1, c2)
	local function one(c)
		if c == COMPS.User then return e == userEnt and user or nil end
		if c == COMPS.Location then return e == userEnt and location or nil end
		if c == COMPS.BattleSession then return sessions[e] end
		if c == COMPS.Boss then return bosses[e] end
	end
	if c2 then return one(c1), one(c2) end
	return one(c1)
end
function world:query(c)
	local list = {}
	if c == COMPS.BattleSession then for e, v in pairs(sessions) do table.insert(list, { e, v }) end end
	if c == COMPS.Boss then for e, v in pairs(bosses) do table.insert(list, { e, v }) end end
	local i = 0
	return function() i += 1 if list[i] then return list[i][1], list[i][2] end end
end
local ctx = { world = world, clientToServerEntities = {}, focusedBattleSession = false, localUser = function() return userEnt end }
M.ctx = ctx
getgc = function() M.getgcCalls = (M.getgcCalls or 0) + 1 return { {}, ctx, userDoc, "x" } end
function M.addBoss(id, place)
	nextEnt += 1
	bosses[nextEnt] = { id = id, place = place }
	ctx.clientToServerEntities[nextEnt] = 5000 + nextEnt
	return nextEnt
end

-- rules for the fake fights
M.towerWinUpTo = {}     -- [mode] = highest wave the deck wins
M.storyWins = {}        -- ["world:diff:boss"] = true
M.fightSeconds = 40
local lastSendAt = -1e9
local function fail(msg) table.insert(M.violations, msg) end
local function newSession(v) nextEnt += 1 sessions[nextEnt] = v ctx.clientToServerEntities[nextEnt] = 9000 + nextEnt return nextEnt end
local function bySrv(srv) for e, _ in pairs(sessions) do if ctx.clientToServerEntities[e] == srv then return e end end end

function M.onRemote(name, ...)
	local args = table.pack(...)
	table.insert(M.sent, { name = name, at = M.now, args = args })
	if M.now - lastSendAt < 1.39 then fail(string.format("commands %.2f s apart (%s)", M.now - lastSendAt, name)) end
	lastSendAt = M.now
	if name == "setPartyPosition" or name == "removePartyPosition" then
		if args[1] ~= "slot_15" then fail("deck edit outside slot_15: " .. tostring(args[1])) return end
		if name == "setPartyPosition" then
			local card, pos = args[2], args[3]
			local kind = string.find(card, "support", 1, true) and "support" or "attack"
			slot15[kind][pos] = card
		else
			slot15[args[2]][args[3]] = nil
		end
	elseif name == "fightBattleTowerWave" then
		local mode, wave, slot = args[1], args[2], args[3]
		if slot ~= "slot_15" then fail("fight with " .. tostring(slot)) end
		if next(sessions) then fail("fight started while another runs") end
		local e = newSession({ type = "battle_tower", mode = mode, wave = wave, restartCount = 0 })
		local win = wave <= (M.towerWinUpTo[mode] or 0)
		task.spawn(function()
			for f = 1, 3 do task.wait(M.fightSeconds / 3) if not sessions[e] then return end sessions[e].restartCount = f end
			sessions[e] = nil
			if win then
				user.battleTowerProgress[mode] = user.battleTowerProgress[mode] or {}
				user.battleTowerProgress[mode][wave] = { completed = true, lastWin = M.now }
			end
		end)
	elseif name == "teleport" then
		task.delay(4, function() location.place = args[1] end)
	elseif name == "fightStoryBoss" then
		local srv, diff, slot = args[1], args[2], args[3]
		if slot ~= "slot_15" then fail("story fight with " .. tostring(slot)) end
		local be
		for e, _ in pairs(bosses) do if ctx.clientToServerEntities[e] == srv then be = e end end
		if not be then fail("unknown boss " .. tostring(srv)) return end
		local b = bosses[be]
		if b.place ~= location.place then fail("story fight from the wrong world") end
		local key = b.place .. ":" .. diff .. ":" .. b.id
		local e = newSession({ type = "story", restartCount = 0 })
		task.spawn(function()
			task.wait(M.fightSeconds)
			if not sessions[e] then return end
			if M.storyWins[key] then
				sessions[e] = nil
				user.storyProgress[b.place] = user.storyProgress[b.place] or {}
				user.storyProgress[b.place][b.id] = user.storyProgress[b.place][b.id] or {}
				user.storyProgress[b.place][b.id][diff] = { completed = true, lastWin = M.now }
			else
				sessions[e].restartCount = 1   -- lost: restarts by itself until forfeited
			end
		end)
	elseif name == "forfeitBattle" then
		local e = bySrv(args[1])
		if e then sessions[e] = nil else fail("forfeit of unknown fight") end
	elseif name == "setBattleSessionDisplayState" then
		local e = bySrv(args[1])
		if e then sessions[e].displayState = args[2] end
	elseif name == "useBackpackItem" then
		local t = args[1]
		local bp = user.inventories[t.domain].backpack
		if (bp[t.item] or 0) < t.amount then fail("opened more packs than owned") end
		bp[t.item] -= t.amount
	elseif name == "claimDailyQuest" then
		for _, q in ipairs(user.questProgress.daily) do if q.idx == args[1] then q.claimed = true end end
	elseif name == "fightInfinite" then
		local e = newSession({ type = "infinite_tower", mode = args[1], floor = 1 })
		task.spawn(function() while sessions[e] do task.wait(20) if sessions[e] then sessions[e].floor += 1 end end end)
	elseif name == "pauseInfinite" then
		task.delay(10, function() for e, s in pairs(sessions) do if s.type == "infinite_tower" then sessions[e] = nil end end end)
	end
end

return M
