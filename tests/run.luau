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
local sw = (lbl.Parent.ClassName == "TextButton") and lbl.Parent or lbl.Parent:FindFirstChildOfClass("TextButton")   -- dawidlib: the toggle IS the button
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
local function btnOf(l) return (l.Parent.ClassName == "TextButton") and l.Parent or l.Parent:FindFirstChildOfClass("TextButton") end   -- dawidlib: the label sits inside its button
local function boxOf(l) for _, d in ipairs(l.Parent:GetDescendants()) do if d.ClassName == "TextBox" then return d end end end
local function click(t) btnOf(findText(gui, t)).MouseButton1Click:Fire() end
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

log("10) look-only preview")
farm.stop()
M.run(M.now + 30)
local gcBefore, sentBefore = M.getgcCalls, #M.sent
_G.__ACCF_LOAD = nil
game:GetService("CoreGui"):FindFirstChild("dawidlib"):Destroy()
M.files["acc-farm/settings.json"] = HS:JSONEncode({ enabled = { dailies = true, tower_repeat = true }, antiAfk = true })
getgenv().ACC_PREVIEW = true
local pv
task.spawn(function() pv = loadstring(M.files.LOADER)() end)
M.run(M.now + 5)
local pgui = game:GetService("CoreGui"):FindFirstChild("dawidlib")
check(pv ~= nil and pgui ~= nil, "preview window opens")
check(next((function() local t = {} for k, v in pairs(pv.settings.enabled) do if v then t[k] = v end end return t end)()) == nil, "every task is off")
pv.start()
M.run(M.now + 5)
local function clickp(t) btnOf(findText(pgui, t)).MouseButton1Click:Fire() end
clickp("Probe (read only)") clickp("Read Deck 15") clickp("Start Deity helper") clickp("Start ranked recorder (read only)")
M.run(M.now + 700)
check(#M.sent == sentBefore and M.getgcCalls == gcBefore, "preview sends no command and scans nothing")
check(HS:JSONDecode(M.files["acc-farm/settings.json"]).antiAfk == true, "preview does not rewrite the saved settings")
getgenv().ACC_PREVIEW = nil

log("11) planner tab + script mode")
farm.stop()
M.run(M.now + 30)
_G.__ACCF_LOAD = nil
game:GetService("CoreGui"):FindFirstChild("dawidlib"):Destroy()
M.files["AnimeCardClash/director_config.json"] = HS:JSONEncode({ accounts = { "Whousleaks", "Umson_42" }, weights = { completion_card_M = 0.5, luck_M_per_pct = 2.7 },
	rules = { event_policy = "fixed" }, workers = { ram_floor_gb = 2, orders = { { tower_side_share = 0.8 } } }, allowed = { modes = { forest = { allowed = true } } },
	editable = { ["weights.completion_card_M"] = { kind = "float", min = 0, max = 5 }, ["rules.event_policy"] = { kind = "enum", values = { "fixed", "free" } },
		["workers.ram_floor_gb"] = { kind = "int", min = 2, max = 8 }, ["workers.orders.0.tower_side_share"] = { kind = "float", min = 0, max = 1 },
		["allowed.modes.forest.allowed"] = { kind = "bool" } } })
M.files["AnimeCardClash/director_status.json"] = HS:JSONEncode({ updated = os.time(), text = "Event running, Shinsu Training next.", ranking = { { name = "Shinsu Training", score = 2.31, state = "can start" } },
	workers = { rows = { { consumer = "cp_search", now = 3, target = 1, delta = -2, why = "event side" } } }, decisions_for_sami = { { name = "set luck weight" } }, rejected_overrides = { ["horizon_h"] = "out of range" } })
M.files["acc-farm/settings.json"] = HS:JSONEncode({})
local pl
task.spawn(function() pl = loadstring(M.files.LOADER)() end)
M.run(M.now + 5)
local g2 = game:GetService("CoreGui"):FindFirstChild("dawidlib")
check(findText(g2, "weights.completion_card_M") ~= nil and findText(g2, "allowed.modes.forest.allowed") ~= nil, "only the director's editable settings are listed")
check(findText(g2, "weights.luck_M_per_pct") == nil and findText(g2, "accounts") == nil, "read-only fields get no control")
check(findText(g2, "Event running, Shinsu Training next.") ~= nil and findText(g2, "cp_search") ~= nil and findText(g2, "horizon_h") ~= nil, "status text, workers and refused changes shown")
btnOf(findText(g2, "allowed.modes.forest.allowed")).MouseButton1Click:Fire()
M.run(M.now + 1)
local ov = HS:JSONDecode(M.files["AnimeCardClash/director_overrides.json"])
check(ov.set["allowed.modes.forest.allowed"] == false, "a switch goes to director_overrides.json only")
check(HS:JSONDecode(M.files["AnimeCardClash/director_config.json"]).allowed.modes.forest.allowed == true, "the config mirror is never written")
M.files["AnimeCardClash/director_overrides.json"] = HS:JSONEncode({ set = { ["horizon_h"] = 8 } })   -- the director's side added a key meanwhile
local tb = boxOf(findText(g2, "weights.completion_card_M"))
tb.Text = "0.7" tb.FocusLost:Fire()
M.run(M.now + 1)
local o2 = HS:JSONDecode(M.files["AnimeCardClash/director_overrides.json"])
check(o2.set["weights.completion_card_M"] == 0.7 and o2.set.horizon_h == 8, "a typed number keeps the other keys in the file")
local tb2 = boxOf(findText(g2, "workers.ram_floor_gb"))
tb2.Text = "1" tb2.FocusLost:Fire()
M.run(M.now + 1)
check(HS:JSONDecode(M.files["AnimeCardClash/director_overrides.json"]).set["workers.ram_floor_gb"] == nil, "a value below the minimum is refused")
-- equip commands (Beta tab)
game:GetService("Players").LocalPlayer.Name = "Whousleaks"
M.sent = {}
local function box(t) return boxOf(findText(g2, t)) end
local b1, b2 = box("Technique id"), box("Card id")
b1.Text = "fishermans_assault" b1.FocusLost:Fire() b2.Text = "pumpkin_witch_cat" b2.FocusLost:Fire()
M.run(M.now + 1)
btnOf(findText(g2, "Equip (main game)")).MouseButton1Click:Fire()
M.run(M.now + 30)
local eq = M.sent[#M.sent]
for _, x in ipairs(M.sent) do if x.name == "equipTechnique" then eq = x end end
check(eq and eq.name == "equipTechnique" and eq.args[1] == "fishermans_assault" and eq.args[2] == "pumpkin_witch_cat", "equip button sends equipTechnique(techniqueId, cardId)")
btnOf(findText(g2, "Equip (Tower of Deity)")).MouseButton1Click:Fire()
M.run(M.now + 5)
local ed = M.sent[#M.sent]
check(ed and ed.name == "towerOfDeityAction" and ed.args[1].kind == "equipTechnique" and ed.args[1].card == "pumpkin_witch_cat", "Deity equip sends towerOfDeityAction")
pl.stop() M.run(M.now + 10)
game:GetService("CoreGui"):FindFirstChild("dawidlib"):Destroy()
_G.__ACCF_LOAD = nil
getgenv().ACC_HEADLESS = true
M.sent = {}
M.files["acc-farm/settings.json"] = HS:JSONEncode({ enabled = { dailies = true, tower_repeat = false, story_repeat = false, tower_clear = false, story_clear = false } })
M.user.questProgress.daily = { { claimed = false, idx = 1 } }
local hl
task.spawn(function() hl = loadstring(M.files.LOADER)() end)
M.run(M.now + 120)
check(hl ~= nil and game:GetService("CoreGui"):FindFirstChild("dawidlib") == nil, "script mode opens no window")
local dc = 0 for _, x in ipairs(M.sent) do if x.name == "claimDailyQuest" or x.name == "claimDailyLogin" then dc += 1 end end
check(dc >= 1, "script mode farms from the settings file")
getgenv().ACC_STOP()
M.run(M.now + 30)
getgenv().ACC_HEADLESS = nil
check(#M.violations == 0, "no rule broken (" .. table.concat(M.violations, "; ") .. ")")

log("12) autopilot tab + status bar")
game:GetService("Players").LocalPlayer.Name = "Whousleaks"
M.files["AnimeCardClash/autopilot/config.json"] = HS:JSONEncode({ focus = "auto", jobs = { claims = { allowed = true }, packs = { allowed = true } },
	accounts = { Whousleaks = { new_account_mode = false } },
	editable = { focus = { kind = "enum", values = { "auto", "luck", "traits", "packs" } }, ["jobs.claims.allowed"] = { kind = "bool" }, ["jobs.packs.allowed"] = { kind = "bool" },
		["accounts.Whousleaks.new_account_mode"] = { kind = "bool" } } })
M.files["AnimeCardClash/autopilot/status.json"] = HS:JSONEncode({ updatedAt = os.time(), dry_run = true, live = { approved_steps = {} },
	accounts = { Whousleaks = { now = "Cyberpunk event run + Shinsu Training", next = "Planner pick: Story tower crystals", why = "luck first: Sword of Hope",
		conditions = { "story-tower script passes its watched test" }, focus = { chosen = "auto", effective = "luck", why = "luck first" },
		quick = { { label = "Claim the daily login reward", state = "ready" }, { label = "Open packs in a good moon", state = "waiting" } } } } })
M.files["AnimeCardClash/autopilot_overrides.json"] = nil
M.files["acc-farm/settings.json"] = HS:JSONEncode({})
_G.__ACCF_LOAD = nil
local apw
task.spawn(function() apw = loadstring(M.files.LOADER)() end)
M.run(M.now + 5)
local g3 = game:GetService("CoreGui"):FindFirstChild("dawidlib")
check(g3 ~= nil and findText(g3, "Cyberpunk event run + Shinsu Training") ~= nil and findText(g3, "luck first: Sword of Hope") ~= nil, "autopilot tab shows now / why")
check(findText(g3, "Claim the daily login reward") ~= nil, "ready quick jobs listed")
local bar = findText(g3, "Autopilot · Luck index")
check(bar ~= nil, "status bar shows the autopilot under every tab")
-- focus: click "Trait rerolls" -> overrides file, nothing else
local radio = findText(g3, "Trait rerolls")
check(radio ~= nil, "focus choices listed")
btnOf(radio).MouseButton1Click:Fire()
M.run(M.now + 1)
local ov = M.files["AnimeCardClash/autopilot_overrides.json"] and HS:JSONDecode(M.files["AnimeCardClash/autopilot_overrides.json"])
check(ov and ov.set and ov.set.focus == "traits", "focus change goes to autopilot_overrides.json")
local sw = findText(g3, "Packs")
-- the job switch "Packs" (not the focus radio "Packs"): find the toggle whose text is exactly "Packs"
local tog
for _, d in ipairs(g3:GetDescendants()) do if d.Text == "Packs" and d.Parent and d.Parent.ClassName == "TextButton" and d.Name == "ToggleText" then tog = d.Parent end end
check(tog ~= nil, "job switches listed")
if tog then tog.MouseButton1Click:Fire() end
M.run(M.now + 1)
ov = HS:JSONDecode(M.files["AnimeCardClash/autopilot_overrides.json"])
check(ov.set["jobs.packs.allowed"] == false and ov.set.focus == "traits", "a job switch keeps the focus already in the file")
M.sent = {}
btnOf(findText(g3, "Start the runner (only approved jobs)")).MouseButton1Click:Fire()
M.run(M.now + 2)
check(findText(g3, "Nothing approved") ~= nil and #M.sent == 0, "runner refuses while nothing is approved")
check(findText(g3, "The autopilot does not touch Joyride.") ~= nil, "Joyride is a slot only")
apw.stop() M.run(M.now + 10)
game:GetService("CoreGui"):FindFirstChild("dawidlib"):Destroy()
_G.__ACCF_LOAD = nil
check(#M.violations == 0, "no rule broken (" .. table.concat(M.violations, "; ") .. ")")

log("13) focus and manual priority go to the planner's file")
M.files["AnimeCardClash/director_config.json"] = HS:JSONEncode({ focus = "auto", editable = { focus = { kind = "enum", values = { "auto", "luck", "traits", "packs" } } } })
M.files["AnimeCardClash/director_status.json"] = HS:JSONEncode({ updated = os.time(), text = "x",
	queue = { { rank = 1, id = "story_tower:sword_of_hope", label = "Sword of Hope", draggable = true }, { rank = 2, id = "deity:training", label = "Shinsu Training", draggable = true },
		{ rank = 3, id = "tower:toon_x:1", label = "Dream", draggable = false } },
	override = { mode = "auto", expired = false, remaining_s = 0 } })
M.files["AnimeCardClash/director_overrides.json"] = HS:JSONEncode({ set = { horizon_h = 8 } })
M.files["AnimeCardClash/autopilot_overrides.json"] = nil
_G.__ACCF_LOAD = nil
local w4
task.spawn(function() w4 = loadstring(M.files.LOADER)() end)
M.run(M.now + 5)
local g4 = game:GetService("CoreGui"):FindFirstChild("dawidlib")
local packsRadio
for _, d in ipairs(g4:GetDescendants()) do if d.Text == "Packs" and d.Parent and d.Parent.Name == "RadioBtn" then packsRadio = d.Parent end end
check(packsRadio ~= nil, "focus radio found")
packsRadio.MouseButton1Click:Fire()
M.run(M.now + 1)
local dov = HS:JSONDecode(M.files["AnimeCardClash/director_overrides.json"])
check(dov.set.focus == "packs" and dov.set.horizon_h == 8 and M.files["AnimeCardClash/autopilot_overrides.json"] == nil, "focus goes to director_overrides.json, other keys kept")
check(findText(g4, ".  Shinsu Training") ~= nil and findText(g4, ".  Dream") == nil, "priority list shows the movable rows only")
-- move Sword of Hope (row 1 of the priority list) down
local row1 = findText(g4, "1.  Sword of Hope").Parent
for _, c in ipairs(row1:GetChildren()) do if c.Text == "▼" then c.MouseButton1Click:Fire() end end
M.run(M.now + 1)
btnOf(findText(g4, "Use my order")).MouseButton1Click:Fire()
M.run(M.now + 1)
dov = HS:JSONDecode(M.files["AnimeCardClash/director_overrides.json"])
check(dov.mode == "manual" and dov.queue_order[1] == "deity:training" and dov["until"] > os.time() and dov.set.focus == "packs", "my order is written with an expiry, focus kept")
btnOf(findText(g4, "Back to automatic")).MouseButton1Click:Fire()
M.run(M.now + 1)
dov = HS:JSONDecode(M.files["AnimeCardClash/director_overrides.json"])
check(dov.mode == "auto" and #dov.queue_order == 0, "back to automatic clears my order")
w4.stop() M.run(M.now + 10)
game:GetService("CoreGui"):FindFirstChild("dawidlib"):Destroy()
_G.__ACCF_LOAD = nil

realPrint(failures == 0 and "ALL PASSED" or (failures .. " FAILED"))
