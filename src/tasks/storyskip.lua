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
