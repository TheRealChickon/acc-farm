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
