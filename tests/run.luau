--!nocheck
-- Offline test: runs the real loader + modules against tests/mock.luau. Usage: luau tests/run.luau
local OUT = print
local M = require("./mock")
setfenv(1, M.env)
local SRC = require("../dist/acc-farm")
for name, src in pairs(SRC) do M.files["acc-farm/src/" .. name .. ".lua"] = src end
local HS = game:GetService("HttpService")
local failures = 0
local function check(cond, msg) if cond then OUT("  ok   " .. msg) else failures += 1 OUT("  FAIL " .. msg) end end
local realPrint = OUT
local function log(...) realPrint(...) end

-- stored decks like the optimiser writes them
M.files["AnimeCardClash/tower_plan_tremor.json"] = HS:JSONEncode({ tower = "tremor", waves = {
	["14"] = { rate = 0.8, decks = { { { "pumpkin_witch_cat:secret", "a_support:gold" }, { "sun_blaze:rainbow", "b_support:gold" }, { "c:gold", "c_support:gold" }, { "d:gold", "d_support:gold" } } } },
	["15"] = { rate = 0.2, decks = { { { "x:gold", "x_support:gold" }, { "y:gold", "" }, { "z:gold", "" }, { "w:gold", "" } } } },
} })
M.files["acc-farm/settings.json"] = HS:JSONEncode({ storyTowerWorld = "" })

-- account state: every main tower done up to tremor 13, dream part 1 done up to 3
local data = loadstring(SRC.data)()
for _, t in ipairs(data.towers) do
	if t.group == "main" then
		M.user.battleTowerProgress[t.id] = {}
		local upTo = (t.id == "tremor") and 13 or ((t.id == "darkness" or t.id == "forest") and 0 or t.waves)
		for w = 1, upTo do M.user.battleTowerProgress[t.id][w] = { completed = true, lastWin = M.now - 3 * 86400 } end
	end
end
M.user.battleTowerProgress.toon_sleepy_gates = { [1] = { completed = true, lastWin = 0 }, [2] = { completed = true, lastWin = 0 }, [3] = { completed = true, lastWin = 0 } }
M.towerWinUpTo = { tremor = 14, toon_sleepy_gates = 5, battle_tower = 99, watery_depths = 99, frozen_landscape = 99, stone_citadel = 99, inferno_depths = 99,
	lunar_eclipse = 99, light_fairy = 99, rebels = 99, android = 99 }
-- story: ninja village fully done, green planet nightmare boss stage 6 done (repeat with packs), one open first clear
for _, w in ipairs(data.worlds) do
	if w.id == "ninja_village" then
		M.user.storyProgress[w.id] = {}
		for _, d in ipairs(data.difficulties) do for _, b in ipairs(w.bosses[d]) do
			M.user.storyProgress[w.id][b.boss] = M.user.storyProgress[w.id][b.boss] or {}
			M.user.storyProgress[w.id][b.boss][d] = { completed = true, lastWin = M.now - 2 * 86400 }
		end end
		for _, b in ipairs(w.bosses.normal) do M.addBoss(b.boss, w.id) M.storyWins[w.id .. ":celestial:" .. b.boss] = true M.storyWins[w.id .. ":normal:" .. b.boss] = true end
	end
	if w.id == "green_planet" then
		for _, b in ipairs(w.bosses.normal) do M.addBoss(b.boss, w.id) M.storyWins[w.id .. ":normal:" .. b.boss] = true end
	end
end
M.user.inventories.main.backpack = { instant_roll_100000 = 3, instant_roll_50 = 10, xxlarge_luck_potion = 5 }
M.user.questProgress.daily = { { claimed = false, idx = 1 }, { claimed = true, idx = 2 } }

log("1) loader + window")
getgenv().ACC_LOCAL = true
local farm
M.files.LOADER = require("./_loader")
check(true, "bundle has " .. (function() local n = 0 for _ in pairs(SRC) do n += 1 end return n end)() .. " modules")
task.spawn(function() farm = loadstring(M.files.LOADER)() end)
M.run(M.now + 5)
check(farm ~= nil and farm.start ~= nil, "farm loaded and returned start/stop")
local gui = game:GetService("CoreGui"):FindFirstChild("dawidlib")
check(gui ~= nil, "window created as CoreGui.dawidlib")

log("2) farm runs for 3 virtual hours")
farm.settings.enabled.instant_packs = true
farm.settings.packMinSize = 1000
task.spawn(farm.start)
M.run(M.now + 3 * 3600)
farm.stop()
M.run(M.now + 60)

local count = {}
for _, s in ipairs(M.sent) do count[s.name] = (count[s.name] or 0) + 1 end
for k, v in pairs(count) do log(string.format("     sent %-30s %d", k, v)) end
local fightCount = {}
for _, s in ipairs(M.sent) do
	if s.name == "fightBattleTowerWave" then local k = s.args[1] .. " " .. s.args[2] fightCount[k] = (fightCount[k] or 0) + 1 end
	if s.name == "claimDailyLogin" then log("     login at", s.at) end
end
local repeatTwice = false
for k, v in pairs(fightCount) do if v > 3 then repeatTwice = true log("     tower fight", k, v) end end
check(not repeatTwice, "no tower floor fought more than the loss limit in one day")
check(#M.violations == 0, "no rule broken (" .. table.concat(M.violations, "; ") .. ")")
local tp = M.user.battleTowerProgress
check(tp.tremor[14] and tp.tremor[14].completed, "tremor floor 14 cleared with the stored deck")
check(not (tp.tremor[15] and tp.tremor[15].completed), "tremor floor 15 skipped (stored win rate 20% below… or lost)")
check(tp.toon_sleepy_gates[5] and tp.toon_sleepy_gates[5].completed, "dream part 1 cleared up to floor 5")
check(not tp.toon_sleepy_gates[6], "dream part 1 floor 6 lost and left alone after max losses")
check(tp.android[25].lastWin > M.now - 4 * 3600, "android floor 25 repeat (packs) done today")
check(tp.watery_depths[25].lastWin > M.now - 4 * 3600, "watery depths floor 25 repeat done today")
check(tp.android[3].lastWin < M.now - 86400, "floors without packs not repeated")
local nv = M.user.storyProgress.ninja_village
local repeated = 0
for _, b in pairs(nv) do for d, s in pairs(b) do if s.lastWin > M.now - 4 * 3600 then repeated += 1 end end end
check(repeated > 0, "story repeats with packs fought (" .. repeated .. ")")
local gp = M.user.storyProgress.green_planet
check(gp ~= nil and next(gp) ~= nil, "green planet first clears started")
check(M.user.inventories.main.backpack.instant_roll_100000 == 0, "100k packs opened")
check(M.user.inventories.main.backpack.instant_roll_50 == 10, "packs below the minimum size kept")
check((count.claimDailyLogin or 0) == 1, "daily login claimed once")
check((count.claimDailyQuest or 0) == 1, "open daily quest claimed once")
check(M.getgcCalls < 40, "getgc used sparingly (" .. tostring(M.getgcCalls) .. " calls)")
check(next(M.sessions) == nil, "no fight left running after stop")

log("3) another script owns the game -> farm waits")
M.sent = {}
M.files["AnimeCardClash/story_heartbeat.json"] = HS:JSONEncode({ t = os.time() })
task.spawn(farm.start)
M.run(M.now + 50)
check(#M.sent == 0, "nothing sent while the climber heartbeat is fresh")
farm.stop()
M.run(M.now + 30)

log("4) wrong account -> nothing sent")
M.files["AnimeCardClash/story_heartbeat.json"] = nil
game:GetService("Players").LocalPlayer.Name = "SomeoneElse"
M.sent = {}
task.spawn(farm.start)
M.run(M.now + 120)
check(#M.sent == 0, "nothing sent on another account")
farm.stop()
M.run(M.now + 30)

log("5) GUI clicks")
local function findText(root, t) for _, d in ipairs(root:GetDescendants()) do if d.Text and string.find(d.Text, t, 1, true) then return d end end end
local first = farm.settings.order[1]
local downs = {}
for _, d in ipairs(gui:GetDescendants()) do if d.Text == "▼" then table.insert(downs, d) end end
check(#downs == 8, "priority list has 8 rows (" .. #downs .. ")")
downs[1].MouseButton1Click:Fire()
M.run(M.now + 1)
check(farm.settings.order[2] == first, "moving the first task down changes the order")
local saved = HS:JSONDecode(M.files["acc-farm/settings.json"])
check(saved.order[2] == first, "order saved to acc-farm/settings.json")
local lbl = findText(gui, "Forest Tower")
check(lbl ~= nil, "tower toggles listed (Forest Tower)")
local sw = lbl.Parent:FindFirstChildOfClass("TextButton")
sw.MouseButton1Click:Fire()
M.run(M.now + 1)
check(farm.settings.towers.forest == false, "turning Forest off is saved")
check(findText(gui, "rolls total") ~= nil, "pack counter shows totals")

log("6) story tower hands the game back when something better is ready")
game:GetService("Players").LocalPlayer.Name = "Whousleaks"
for k in pairs(farm.settings.enabled) do farm.settings.enabled[k] = false end
farm.settings.enabled.story_tower = true
farm.settings.storyTowerWorld = "dimensional_fortress"
M.sent = {}
task.spawn(farm.start)
M.run(M.now + 600)
local inf = 0 for _, x in ipairs(M.sent) do if x.name == "fightInfinite" then inf += 1 end end
check(inf >= 1, "story tower started")
farm.settings.enabled.instant_packs = true
M.user.inventories.main.backpack.instant_roll_100000 = 2
M.run(M.now + 120)
local paused = false for _, x in ipairs(M.sent) do if x.name == "pauseInfinite" then paused = true end end
check(paused, "story tower paused for the waiting packs")
check(M.user.inventories.main.backpack.instant_roll_100000 == 0, "then the packs were opened")
farm.stop()
M.run(M.now + 60)
check(#M.violations == 0, "still no rule broken (" .. table.concat(M.violations, "; ") .. ")")

log("7) Story Skip")
for k in pairs(farm.settings.enabled) do farm.settings.enabled[k] = false end
farm.settings.enabled.story_skip = true
M.user.inventories.main.backpack.story_skip_key = 0
M.skipWorlds = {
	solo_city = { bosses = 6, diff = "celestial", win = true },
	heros_palace = { bosses = 6, diff = "celestial", win = false },
	green_planet = { bosses = 6, diff = "nightmare", win = true },          -- highest difficulty not planned: skipped
	ninja_village = { bosses = 6, diff = "celestial", claimed = true },     -- nothing to claim today
	clover_hideout = { bosses = 6, diff = "celestial", win = true },        -- off by default (no deck)
}
M.sent = {}
M.files["AnimeCardClash/storyskip_want.json"] = nil
task.spawn(farm.start)
M.run(M.now + 120)
check(M.files["AnimeCardClash/storyskip_want.json"] == nil, "no keys -> Story Skip stays off")
check(findText(gui, "Story Skip keys: 0") ~= nil, "window shows 0 keys")
farm.stop()
M.run(M.now + 30)
-- fake ss_watch.py: answers every want with safe seconds starting 20 s later
local answered = 0
task.spawn(function()
	local last
	while true do
		task.wait(2)
		local w = M.files["AnimeCardClash/storyskip_want.json"]
		if w and w ~= last then
			last = w
			local want = HS:JSONDecode(w)
			local safe = {} for i = 20, 200 do table.insert(safe, want.t + i) end
			task.wait(15)
			answered += 1
			M.files["AnimeCardClash/storyskip_times_" .. want.world .. ".json"] = HS:JSONEncode({ world = want.world, made = want.t + 1, ok = true, winRate = 1,
				deck = { { "sun_blaze_shinigami:gold", "fox_cloak:basic" }, { "awakened_sunblaze_shinigami:secret", "binding_vow:basic" }, { "sun_blaze_shinigami:gold", "mech_contract:basic" }, { "undead_king:rainbow", "undead_staff:basic" } },
				safe = safe })
		end
	end
end)
M.user.inventories.main.backpack.story_skip_key = 5
M.skipFights = {}
task.spawn(farm.start)
M.run(M.now + 1800)
farm.stop()
M.run(M.now + 60)
local fought = {} for _, f in ipairs(M.skipFights) do fought[f.world] = (fought[f.world] or 0) + 1 end
check(fought.solo_city == 1 and M.skipWorlds.solo_city.claimed, "Solo City fought once and won")
check(fought.heros_palace == 1, "Hero's Palace lost once and not retried today")
check(not fought.green_planet and not fought.ninja_village and not fought.clover_hideout, "worlds without celestial / without rewards / without a deck left alone")
check(M.user.inventories.main.backpack.story_skip_key == 3, "two keys used")
local onTime = true
for _, x in ipairs(M.sent) do if x.name == "fightStorySkip" then local frac = x.at - math.floor(x.at) if frac < 0.3 or frac > 0.5 then onTime = false end end end
check(onTime, "fired just after a planned second (+0.35 s)")
check(next(M.sessions) == nil, "no Story Skip fight left open")
check(findText(gui, "Story Skip keys: 3") ~= nil, "window shows 3 keys")
check(#M.violations == 0, "no rule broken (" .. table.concat(M.violations, "; ") .. ")")

log("8) second account (Umson_42)")
farm.settings.enabled.tower_repeat = true
game:GetService("Players").LocalPlayer.Name = "Umson_42"
M.files["AnimeCardClash/story_heartbeat.json"] = HS:JSONEncode({ t = os.time() })          -- Whousleaks's climber: not ours
M.files["AnimeCardClash/umson/story_heartbeat.json"] = HS:JSONEncode({ t = os.time() })    -- Umson's climber runs: wait
M.sent = {}
task.spawn(farm.start)
M.run(M.now + 60)
check(#M.sent == 0, "waits for Umson's own climber")
M.files["AnimeCardClash/umson/story_heartbeat.json"] = nil
M.user.inventories.main.backpack.story_skip_key = 5
for _, w in pairs(M.skipWorlds) do w.claimed = false end
M.user.battleTowerProgress.android[25].lastWin = 0
M.run(M.now + 600)
local skipSent = false for _, x in ipairs(M.sent) do if x.name == "fightStorySkip" then skipSent = true end end
check(#M.sent > 0, "farms on Umson_42 although Whousleaks's climber runs")
check(not skipSent, "no Story Skip on Umson_42 (Whousleaks's keys plan)")
farm.stop()
M.run(M.now + 60)
local function click(t) findText(gui, t).Parent:FindFirstChildOfClass("TextButton").MouseButton1Click:Fire() end
click("Start Deity helper")
M.run(M.now + 2)
check(findText(gui, "Not on this account") ~= nil, "beta helpers refused on Umson_42")
check(#M.violations == 0, "no rule broken (" .. table.concat(M.violations, "; ") .. ")")
game:GetService("Players").LocalPlayer.Name = "Whousleaks"
M.files["AnimeCardClash/story_heartbeat.json"] = nil

log("9) beta helper stops the farm first")
task.spawn(farm.start)
M.run(M.now + 30)
M.sent = {}
click("Start Deity helper")
M.run(M.now + 60)
check(#M.sent == 0, "farm stopped when the Deity helper starts (it controls the game alone)")
_G.__DT_STOP = true
M.run(M.now + 10)

log("10) Cyberpunk tab: the shared farm script is started and stopped from the window")
local function J(t) return HS:JSONEncode(t) end
local CFG, FLAG = "AnimeCardClash/cyber_farm_cfg.json", "AnimeCardClash/cyber_farm.flag"
-- a stand-in for cyber_farm.lua with the same contract as the real script (checked against the real file by tools/check_farm.py)
local function stubSrc(tag, extra)
	return ([==[
local HS = game:GetService("HttpService")
local DIR = game.Players.LocalPlayer.Name == "Umson_42" and "AnimeCardClash/umson/" or "AnimeCardClash/"
if _G.__CF_RUNNING and _G.__CF_RUNNING > 0 and os.clock() - _G.__CF_RUNNING < 30 and not _G.__CF_FORCE then print("CF already running") return end
_G.__CF_STOP = false
_G.__CF_WHICH = "%s"
_G.__CF_STARTS = (_G.__CF_STARTS or 0) + 1
%s
local T0 = workspace:GetServerTimeNow()
local status = "running"
local function hb()
	writefile(DIR .. "cyber_farm_hb.json", HS:JSONEncode({ t = workspace:GetServerTimeNow(), status = status, version = "stub-%s", dry = _G.__CF_DRY and true or false,
		act = 3, room = 4, highest = 40, eddies = 12300, runs = 1, deaths = 0, buys = 2, sent = 9, up = workspace:GetServerTimeNow() - T0, owner = "x" }))
end
while true do
	_G.__CF_RUNNING = os.clock()
	local ok, flag = pcall(readfile, DIR .. "cyber_farm.flag")
	flag = ok and tostring(flag):match("%%S+") or "1"
	if _G.__CF_STOP then status = "stopped: stop flag" break end
	if flag == "0" then status = "stopped: flag file 0" break end
	hb()
	task.wait(1)
end
hb()
_G.__CF_RUNNING = 0
]==]):format(tag, extra or "", tag)
end
local function wipe(dir)
	for _, f in ipairs({ "cyber_farm_hb.json", "cyber_farm.flag", "cyber_farm_cfg.json", "cyber_farm.lua", "cyber_farm_prev.lua" }) do M.files[dir .. f] = nil end
	_G.__CF_RUNNING, _G.__CF_STOP, _G.__CF_WHICH, _G.__CF_STARTS, _G.__CF_DRY = 0, false, nil, 0, nil
end
-- synthetic files shaped like the real ones (the farm's heartbeat, the optimiser's report, the anti-AFK heartbeat, the lock)
local function statusFor(name, over)
	local s = {
		account = name, at = os.time() - 20,
		aiming = { "clear act 60 to open shop tier 3 (30 more 1M rolls); engine depth now 54.5 acts per run", "next buy: tier 2 crates (18 each, 4 cards): 84/92 of that tier owned" },
		crates = { tier = 2, price = 18, poolOwned = { 84, 92 }, targets = {}, betterCards = 0 },
		searching = true, phase = "single", tried = 128, since = os.time() - 1500,
		played = { team = { { attacker = "alpha_knight", support = "iron_ward" }, { attacker = "neon_ronin", support = "ghost_net" }, { attacker = "chrome_hound", support = "" }, { attacker = "red_wraith", support = "echo_chip" } },
			chromeEquipped = { sandevistan = "alpha_knight", mantis_blade = "neon_ronin" }, score = { acts = 54.5, eddies = 9984.25, survive = { 270.5, 281.75 } } },
		best = { team = { { attacker = "night_runner", support = "iron_ward" }, { attacker = "neon_ronin", support = "ghost_net" }, { attacker = "chrome_hound", support = "" }, { attacker = "red_wraith", support = "echo_chip" } },
			chromeEquipped = { sandevistan = "night_runner", mantis_blade = "neon_ronin" }, score = { acts = 58, eddies = 10500 } },
		lastChanges = {},
		nextBuy = { kind = "crates", n = 25, payload = { kind = "buyCrate", tier = 2, quantity = 25 }, price = 450, affordable = true, dActs = 1.5, dEddiesPerHour = 0, note = "tier 2 crates (18 each, 4 cards): 84/92 of that tier owned" },
		trying = { { team = {}, chromeEquipped = {}, move = "card ice_empress" }, { team = {}, chromeEquipped = {}, move = "chrome kinetic_dampener@alpha_knight" },
			{ team = {}, chromeEquipped = {}, move = "chrome mantis_blade<->sandevistan" }, { team = {}, chromeEquipped = {}, move = "support ghost_net" } },
		candidates = {}, learned = { cards = {} },
	}
	for k, v in pairs(over or {}) do s[k] = v end
	return s
end
local function present(name)
	M.files["AnimeCardClash/cyber_status_" .. name .. ".json"] = J(statusFor(name))
	M.files["AnimeCardClash/antiafk_" .. name .. ".json"] = J({ t = os.time() - 25, taps = 12 })
end

-- the window comes up clean and the tab is there
for _, p in ipairs(M.printed) do if string.find(p, "could not be built", 1, true) then check(false, "tab build error: " .. p) end end
local cap = findText(gui, "Cyberpunk farm running")
check(cap ~= nil, "Cyberpunk tab with its start switch")
local function page() return cap.Parent.Parent end
local function all() local out = {} for _, d in ipairs(page():GetDescendants()) do if d.Text and d.Text ~= "" then table.insert(out, d.Text) end end return table.concat(out, "\n") end
local function has(s) return string.find(all(), s, 1, true) ~= nil end
local function toggleOn()
	local box = cap.Parent:FindFirstChildOfClass("TextButton")
	return box:FindFirstChildOfClass("Frame").Position.X.Offset == 21
end
local function clickSwitch() cap.Parent:FindFirstChildOfClass("TextButton").MouseButton1Click:Fire() end
local function clickIn(root, t) findText(root, t).Parent:FindFirstChildOfClass("TextButton").MouseButton1Click:Fire() end   -- a row's caption
local function clickButton(root, t) findText(root, t).MouseButton1Click:Fire() end                                         -- a button with that text
check(findText(gui, "Joyride") == nil and findText(gui, "joyride") == nil, "no Joyride anywhere in the window")

-- setup: Whousleaks, event open, nothing running
game:GetService("Players").LocalPlayer.Name = "Whousleaks"
for _, f in ipairs({ "story_heartbeat.json", "tower_climb_heartbeat.json", "tower_heartbeat.json", "deity/state.json" }) do M.files["AnimeCardClash/" .. f] = nil M.files["AnimeCardClash/umson/" .. f] = nil end
wipe("AnimeCardClash/") wipe("AnimeCardClash/umson/")
M.user.cyberpunkEvent = { highestActCleared = 40 }
M.files["AnimeCardClash/whousleaks_owner.json"] = J({ owner = "cyberpunk_w", since = 1, by = "test" })
M.sent = {}
M.run(M.now + 4)
check(has("Not running"), "before anything starts it says Not running")
check(has("No heartbeat file yet") and has("No optimiser report yet"), "says what is missing instead of showing blanks")
check(has("Shop buying: ") and has("OFF"), "shop buying shows OFF")
check(not toggleOn(), "start switch is off")

-- start from the window (newest script), with the optimiser's report and a lock that fits
present("Whousleaks")
M.files["AnimeCardClash/cyber_farm.lua"] = stubSrc("newest")
M.files["AnimeCardClash/cyber_farm_prev.lua"] = stubSrc("prev")
farm.settings.enabled.tower_repeat = true
M.user.battleTowerProgress.android[25].lastWin = 0
task.spawn(farm.start)               -- the tower / story farm is running when the Cyberpunk farm is started
M.run(M.now + 150)
local sentBefore = #M.sent
check(sentBefore > 0, "tower / story farm was busy before (" .. sentBefore .. " commands)")
clickSwitch()
M.run(M.now + 8)
check(_G.__CF_WHICH == "newest" and _G.__CF_STARTS == 1, "switch starts the newest script exactly once")
check(M.files[FLAG] == "1", "flag file says go")
local cfgNow = HS:JSONDecode(M.files[CFG] or "{}")
check(cfgNow.spend and cfgNow.spend.shop == false, "shop buying written as OFF in the farm's settings")
check(toggleOn(), "switch shows on")
check(has("Running") and has("Act 3 · room 4 of 9") and has("123 Eddies") and has("stub-newest"), "state, act, Eddies and script version shown")
check(has("Recruit crates, tier 2, x25") and has("450 Eddies") and has("can buy now") and has("+1.5 acts per run"), "next purchase shown")
check(has("1   Alpha Knight + Iron Ward") and has("3   Chrome Hound\n") and has("2 chrome pieces"), "deck in play shown with names and chrome count")
check(has("goes in at the next run start (+3.5 acts)") and has("Night Runner + Iron Ward"), "best deck found shown with its gain")
check(has("Searching (single) · 128 decks tried") and has("Swap in Ice Empress") and has("Chrome Kinetic Dampener on Alpha Knight")
	and has("Swap chrome Mantis Blade and Sandevistan") and has("Try support Ghost Net"), "what it is trying now")
check(has("Lock: cyberpunk_w (the farm may send)") and has("Anti-AFK (autoexec): ") and has("on"), "lock and anti-AFK shown")
M.sent = {}
M.run(M.now + 40)
check(#M.sent == 0, "the tower / story farm stepped aside: nothing sent while the Cyberpunk farm runs")
task.spawn(farm.start)               -- starting it again: it waits for the Cyberpunk farm
M.run(M.now + 60)
check(#M.sent == 0, "starting the tower / story farm again waits for the Cyberpunk farm")
check(findText(gui, "waiting: another script controls the game (AnimeCardClash/cyber_farm_hb.json)") ~= nil, "and the Status tab says why it waits")

-- stop from the window
clickSwitch()
M.run(M.now + 5)
check(M.files[FLAG] == "0" and _G.__CF_RUNNING == 0, "stop: flag file 0 and the script ended")
check(has("Stopped · stop flag"), "window says Stopped and why")
check(not toggleOn(), "switch shows off")
M.sent = {}
M.run(M.now + 400)
check(#M.sent > 0, "the waiting tower / story farm carries on once the Cyberpunk farm has stopped")
farm.stop()
M.run(M.now + 30)

-- an unreadable or missing script, the previous one, crashes (module level)
local core2 = loadstring(SRC.core)()
core2.settings = farm.settings
local cy = loadstring(SRC["tasks/cyberpunk"])(core2)
local function stopNow() _G.__CF_STOP = true M.run(M.now + 3) end
local function begin(opts) local ok, msg = cy.start(opts) M.run(M.now + 3) return ok, msg end
wipe("AnimeCardClash/")
M.files["AnimeCardClash/cyber_farm_prev.lua"] = stubSrc("prev")
local ok, msg = begin({ version = "newest" })
check(ok and _G.__CF_WHICH == "prev", "newest script missing -> the previous one starts")
stopNow()
wipe("AnimeCardClash/")
M.files["AnimeCardClash/cyber_farm.lua"] = "local x = = 1"
M.files["AnimeCardClash/cyber_farm_prev.lua"] = stubSrc("prev")
ok = begin({ version = "newest" })
check(ok and _G.__CF_WHICH == "prev", "newest script does not compile -> the previous one starts")
stopNow()
wipe("AnimeCardClash/")
M.files["AnimeCardClash/cyber_farm.lua"] = "error('boom')"
M.files["AnimeCardClash/cyber_farm_prev.lua"] = stubSrc("prev")
ok = begin({ version = "newest" })
check(ok and _G.__CF_WHICH == "prev" and _G.__CF_STARTS == 1, "newest script crashes at once -> the previous one takes over")
stopNow()
wipe("AnimeCardClash/")
M.files["AnimeCardClash/cyber_farm.lua"] = stubSrc("newest")
M.files["AnimeCardClash/cyber_farm_prev.lua"] = stubSrc("prev")
ok = begin({ version = "previous" })
check(ok and _G.__CF_WHICH == "prev", "Previous picked -> the previous script starts although the newest is fine")
stopNow()
wipe("AnimeCardClash/")
M.files["AnimeCardClash/cyber_farm.lua"] = "local x = = 1"
M.files["AnimeCardClash/cyber_farm_prev.lua"] = "also not lua ("
M.files[FLAG] = "pause"
local stoppedFarm = false
ok, msg = cy.start({ version = "newest", before = function() stoppedFarm = true end })
check(not ok and msg:find("Can't find or load", 1, true) and not stoppedFarm and M.files[FLAG] == "pause", "nothing loads -> says so, changes nothing, the tower / story farm is left alone")

-- guards
wipe("AnimeCardClash/")
M.files["AnimeCardClash/cyber_farm.lua"] = stubSrc("newest")
task.spawn(loadstring(stubSrc("someone-else")))          -- already running in this game (started by another script)
M.run(M.now + 3)
ok, msg = cy.start({})
check(not ok and msg:find("Already running on", 1, true) and _G.__CF_STARTS == 1, "already running -> no second copy")
stopNow()
wipe("AnimeCardClash/")
M.files["AnimeCardClash/cyber_farm.lua"] = stubSrc("newest")
game:GetService("Players").LocalPlayer.Name = "SomeoneElse"
ok, msg = cy.start({})
check(not ok and msg:find("Only Whousleaks and Umson_42", 1, true) and M.files[FLAG] == nil and M.files[CFG] == nil, "another account -> refused, nothing written")
game:GetService("Players").LocalPlayer.Name = "Whousleaks"
M.user.cyberpunkEvent = nil
ok, msg = cy.start({})
check(not ok and msg:find("not open", 1, true), "event not open -> refused")
M.user.cyberpunkEvent = { highestActCleared = 40 }
M.files["AnimeCardClash/story_heartbeat.json"] = J({ t = os.time() })
ok, msg = cy.start({})
check(not ok and msg:find("story_heartbeat.json", 1, true) and M.files[FLAG] == nil, "a climber is running -> refused, names the climber")
M.files["AnimeCardClash/story_heartbeat.json"] = nil
M.files[CFG] = "{ this is not json"
ok, msg = cy.start({})
check(not ok and M.files[CFG] == "{ this is not json" and M.files[FLAG] == nil, "unreadable settings file -> refused and never overwritten")
M.files[CFG] = J({ gap = 1.25, route = "custom", spend = { shop = true, team = false, shopSkip = { "rolls_1", "rolls_2" } } })
ok, msg = begin({})
local c2 = HS:JSONDecode(M.files[CFG])
check(ok and c2.spend.shop == false and c2.gap == 1.25 and c2.route == "custom" and c2.spend.team == false and c2.spend.shopSkip[2] == "rolls_2",
	"shop was ON -> switched off, every other setting kept")
check(msg:find("was ON", 1, true), "and it says so")
stopNow()
wipe("AnimeCardClash/")
M.files["AnimeCardClash/cyber_farm.lua"] = stubSrc("newest")
M.files[CFG] = J({ spend = { shop = false, shopOnly = { "__none__" } } })
local before = M.files[CFG]
ok = begin({})
check(ok and M.files[CFG] == before, "shop already OFF -> the settings file is not touched")
stopNow()
wipe("AnimeCardClash/")
M.files["AnimeCardClash/cyber_farm.lua"] = stubSrc("newest")
farm.settings.account = "Umson_42"
ok, msg = cy.start({})
check(not ok and msg:find("switched off in Settings", 1, true), "account removed in Settings -> refused")
farm.settings.account = "Whousleaks, Umson_42"
M.files[CFG] = J({ spend = { shop = true } })
local ok2, m2 = cy.shopOff("Whousleaks")
check(ok2 and HS:JSONDecode(M.files[CFG]).spend.shop == false and m2 == "Shop buying switched off.", "button: shop buying off (never on)")
ok2, m2 = cy.shopOff("Whousleaks")
check(ok2 and m2 == "Shop buying is already off.", "button again: already off")

-- test mode shows in the window; the Script switch is saved
wipe("AnimeCardClash/")
M.files["AnimeCardClash/cyber_farm.lua"] = stubSrc("newest")
M.files["AnimeCardClash/cyber_farm_prev.lua"] = stubSrc("prev")
clickIn(gui, "Test mode (decides and logs, sends nothing)")
M.run(M.now + 1)
check(_G.__CF_DRY == true, "test mode switch sets the farm's test flag")
clickButton(gui, "Previous")
M.run(M.now + 1)
check(farm.settings.cyberVersion == "previous" and HS:JSONDecode(M.files["acc-farm/settings.json"]).cyberVersion == "previous", "Script: Previous is saved")
clickSwitch()
M.run(M.now + 8)
check(_G.__CF_WHICH == "prev" and has("test mode, nothing is sent"), "started in test mode with the previous script, and the window says so")
clickSwitch()
M.run(M.now + 5)
clickButton(gui, "Newest")
clickIn(gui, "Test mode (decides and logs, sends nothing)")
M.run(M.now + 1)
check(farm.settings.cyberVersion == "newest" and _G.__CF_DRY == nil, "switches back")

-- stop when nothing runs: no flag left behind that would stop the next start at once
wipe("AnimeCardClash/")
local sok, what = cy.stop("Whousleaks")
check(sok and what == "not running" and M.files[FLAG] == nil, "stop with nothing running writes no flag")

-- the other account: shown, and can be stopped from here
M.files["AnimeCardClash/umson/cyber_farm_hb.json"] = J({ t = M.now, status = "running", act = 7, highest = 45, owner = "cyberpunk_u" })
M.run(M.now + 4)
check(has("Umson_42") and has("act 7 · best 45"), "the other account's state is shown")
M.files["AnimeCardClash/umson/cyber.flag"] = tostring(os.time() + 36000)
M.files["AnimeCardClash/cyber_farm.flag"] = "1"
clickIn(gui, "Stop the other account's Cyberpunk farm")
M.run(M.now + 1)
check(M.files["AnimeCardClash/umson/cyber_farm.flag"] == "0" and M.files["AnimeCardClash/cyber_farm.flag"] == "1", "stop reaches the other account's flag only")
check(M.files["AnimeCardClash/umson/cyber.flag"] == "0", "and switches off its restart after a rejoin")

M.files["AnimeCardClash/umson/cyber_farm_hb.json"] = J({ t = M.now - 1000, status = "running", act = 7, highest = 45 })   -- its heartbeat is old: not running
clickIn(gui, "Stop the other account's Cyberpunk farm")      -- nothing to stop, nothing written
M.run(M.now + 1)
check(M.files["AnimeCardClash/umson/cyber_farm.flag"] == "0" and findText(gui, "is not running") ~= nil, "stopping an account that is not running says so")
M.files["AnimeCardClash/umson/cyber_farm.flag"] = nil
M.files["AnimeCardClash/umson/cyber_farm_hb.json"] = nil
M.files["AnimeCardClash/umson/cyber.flag"] = nil
clickIn(gui, "Stop the other account's Cyberpunk farm")
M.run(M.now + 1)
check(M.files["AnimeCardClash/umson/cyber_farm.flag"] == nil, "and leaves no flag behind")

-- Umson_42 in its own window: its own folder, its own lock, restart after a rejoin
game:GetService("Players").LocalPlayer.Name = "Umson_42"
wipe("AnimeCardClash/umson/") wipe("AnimeCardClash/")
M.files["AnimeCardClash/umson/cyber_farm.lua"] = stubSrc("umson")
M.files["AnimeCardClash/umson/cyber_owner.json"] = J({ owner = "cyberpunk_u" })
M.files["AnimeCardClash/umson/cyber.flag"] = tostring(os.time() + 36000)
present("Umson_42")
ok, msg = begin({})
check(ok and _G.__CF_WHICH == "umson" and M.files["AnimeCardClash/umson/cyber_farm.flag"] == "1" and M.files["AnimeCardClash/cyber_farm.flag"] == nil, "Umson_42 starts from its own folder and leaves Whousleaks's files alone")
M.run(M.now + 4)
check(has("Lock: cyberpunk_u (the farm may send)") and has("Restarts itself after a rejoin until"), "Umson's lock and its restart after a rejoin are shown")
stopNow()                      -- (a running copy would overwrite the heartbeat written below)
_G.__CF_STOP = false           -- and a paused farm that is alive has no stop request
M.files["AnimeCardClash/umson/cyber_owner.json"] = J({ owner = "tower_climber" })
M.files["AnimeCardClash/umson/cyber_farm_hb.json"] = J({ t = workspace:GetServerTimeNow(), status = "paused: owner is tower_climber", act = 2, room = 1, highest = 45 })
M.run(M.now + 4)
check(has("Waiting: the lock says tower_climber, the farm needs cyberpunk_u") and has("the farm waits until it says cyberpunk_u"), "another owner holds the lock -> says the farm waits and why")
cy.stop("Umson_42")
M.run(M.now + 5)
check(M.files["AnimeCardClash/umson/cyber_farm.flag"] == "0" and M.files["AnimeCardClash/umson/cyber.flag"] == "0", "stop writes the flag and switches the restart after a rejoin off")
game:GetService("Players").LocalPlayer.Name = "Whousleaks"

-- stale reports are called stale; anti-AFK problems are loud
wipe("AnimeCardClash/") wipe("AnimeCardClash/umson/")
M.files["AnimeCardClash/cyber_status_Whousleaks.json"] = J(statusFor("Whousleaks", { at = os.time() - 1800 }))
M.files["AnimeCardClash/antiafk_Whousleaks.json"] = J({ t = os.time() - 900, taps = 3 })
M.files["AnimeCardClash/cyber_optimizer.stop"] = ""
M.files["AnimeCardClash/whousleaks_owner.json"] = J({ owner = "somebody_else" })
M.run(M.now + 4)
check(has("Optimiser report is 30 min old (optimiser stopped)"), "an old optimiser report is called old")
check(has("NOT running") and has("last tap 15 min ago"), "anti-AFK not running is shown loud")
check(has("the farm waits until it says cyberpunk_w"), "lock of somebody else is shown")
check(#M.violations == 0, "no rule broken in the Cyberpunk checks (" .. table.concat(M.violations, "; ") .. ")")

-- closing the window: stops the Cyberpunk farm only when this window started it
wipe("AnimeCardClash/") wipe("AnimeCardClash/umson/")
M.files["AnimeCardClash/whousleaks_owner.json"] = J({ owner = "cyberpunk_w" })
M.files["AnimeCardClash/cyber_farm.lua"] = stubSrc("newest")
M.files["AnimeCardClash/cyber_farm_prev.lua"] = stubSrc("prev")
M.run(M.now + 30)
ok = cy.start({})                                     -- started by another script, not by this window
M.run(M.now + 8)
check(ok and cy.alive(cy.read("Whousleaks")), "a farm started elsewhere is running")
clickIn(gui, "Stop and close")
M.run(M.now + 5)
check(cy.alive(cy.read("Whousleaks")) and M.files[FLAG] == "1", "closing the window leaves a farm it did not start running")
_G.__CF_STOP = true
M.run(M.now + 5)
wipe("AnimeCardClash/")
M.files["AnimeCardClash/cyber_farm.lua"] = stubSrc("newest")
game:GetService("Players").LocalPlayer.Name = "Whousleaks"
farm = nil
task.spawn(function() farm = loadstring(M.files.LOADER)() end)       -- a fresh window
M.run(M.now + 5)
gui = game:GetService("CoreGui"):FindFirstChild("dawidlib")
cap = findText(gui, "Cyberpunk farm running")
cap.Parent:FindFirstChildOfClass("TextButton").MouseButton1Click:Fire()
M.run(M.now + 8)
check(_G.__CF_WHICH == "newest" and cy.alive(cy.read("Whousleaks")), "fresh window starts the farm")
clickIn(gui, "Stop and close")
M.run(M.now + 5)
check(not cy.alive(cy.read("Whousleaks")) and M.files[FLAG] == "0", "closing the window stops the farm it started")

realPrint(failures == 0 and "ALL PASSED" or (failures .. " FAILED"))
