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
betaTab:Line("Ranked")
betaTab:Label("No ranked season right now (season 11 is not out). The recorder only reads, so it can run next to the farm.")
betaTab:Button("Start ranked recorder (read only)", function()
	if not core.isMain() or PREVIEW then lib:Notification("Preview only", "Nothing starts from this window.", nil, "Okay") return end
	local ok = pcall(run, "helpers/ranked_recorder") core.say(ok and "ranked recorder started" or "ranked recorder failed")
end)
betaTab:Button("Stop ranked recorder", function() _G.__RR_STOP = true end)

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
