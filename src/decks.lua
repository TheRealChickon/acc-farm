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
	local plan = load("AnimeCardClash/tower_plan_" .. id .. ".json")
	local e = plan and plan.waves and plan.waves[tostring(wave)]
	if e then
		rate = e.rate
		for _, d in ipairs(e.decks or {}) do if valid(d) then table.insert(out, d) end end
	end
	local cd = load("AnimeCardClash/climb_decks.json")
	local d = cd and cd[id] and cd[id][tostring(wave)]
	if valid(d) then table.insert(out, d) end
	return out, rate
end

function decks.story(world, diff, boss)
	local out = {}
	local own = load("acc-farm/decks.json")
	local k = "story:" .. world .. ":" .. diff .. ":" .. boss
	if own and valid(own[k]) then table.insert(out, own[k]) end
	local plan = load("AnimeCardClash/story_plan.json")
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
