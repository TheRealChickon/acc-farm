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
