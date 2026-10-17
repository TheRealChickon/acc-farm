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
		local r = core.askTimes("AnimeCardClash/tw_need.json", "AnimeCardClash/tw_times_" .. job.mode .. "_" .. job.wave .. ".json",
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
