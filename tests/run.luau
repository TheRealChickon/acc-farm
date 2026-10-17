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
check(#downs == 7, "priority list has 7 rows (" .. #downs .. ")")
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

realPrint(failures == 0 and "ALL PASSED" or (failures .. " FAILED"))
