-- Cyberpunk Run farm: start / stop and status for the farm window. It does not play the event itself. The shared farm
-- script (cyber_farm.lua, written and updated by the Cyberpunk threads) is started and stopped from here, and what it and
-- the deck optimiser write is shown. Nothing from the script is copied into this project: it is read from the executor
-- workspace every time it starts, so it is always the newest one (or the previous one, cyber_farm_prev.lua, on request).
-- Contract used (from the script's own header):
--   start  = loadstring(readfile("<account folder>cyber_farm.lua"))()   (it blocks until the farm ends, so it runs in its own thread)
--   stop   = _G.__CF_STOP = true, and "0" in <account folder>cyber_farm.flag ("pause" = pause, anything else = go)
--   alive  = _G.__CF_RUNNING (an os.clock() stamp that is refreshed all the time, 0 after a clean end), or a fresh heartbeat
--   files  = <account folder>cyber_farm_hb.json (heartbeat every 5 s), cyber_farm_cfg.json, and the lock file <ownerFile>
--            that must say <owner> or the farm waits; the deck optimiser writes AnimeCardClash/cyber_status_<account>.json
--   test   = _G.__CF_DRY = true (decides and logs, sends nothing)
-- Rules kept here: never sends a game command itself, never touches the lock, never turns shop buying on (Sami buys the
-- rolls himself), never starts or stops anti-AFK (it runs from the executor's autoexec).
local core = ...
local HS = game:GetService("HttpService")
local LP = game:GetService("Players").LocalPlayer

local cy = {}
local ROOT = "AnimeCardClash/"
local HB = "cyber_farm_hb.json"
cy.HB = HB
-- same table as in the farm script (own folder, own lock file and lock name per account)
cy.ACCOUNTS = {
	Whousleaks = { dir = "AnimeCardClash/", ownerFile = "whousleaks_owner.json", owner = "cyberpunk_w" },
	-- cyber.flag: the autoexec's switch that restarts the farm after a rejoin (a Unix deadline, 0 = off)
	Umson_42 = { dir = "AnimeCardClash/umson/", ownerFile = "cyber_owner.json", owner = "cyberpunk_u", autostart = "AnimeCardClash/umson/cyber.flag" },
}
cy.NAMES = { "Whousleaks", "Umson_42" }

-- ---------- small helpers ----------
local COLORS = { ok = "#5ac878", warn = "#ff9646", bad = "#ff5c5c", dim = "#8c91a0" }
local function paint(kind, s) return '<font color="' .. COLORS[kind] .. '">' .. s .. "</font>" end
local function esc(s) return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")) end

function cy.pretty(id)
	if id == nil or id == "" then return "-" end
	local s = tostring(id):gsub("_", " ")
	return (s:gsub("(%a)([%w']*)", function(a, b) return a:upper() .. b end))
end
function cy.num(n)
	if type(n) ~= "number" then return "?" end
	if n < 0 then return "-" .. cy.num(-n) end
	local s = tostring(math.floor(n + 0.5))
	return (s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end
function cy.span(sec)
	if type(sec) ~= "number" then return "?" end
	sec = math.max(0, math.floor(sec))
	if sec < 90 then return sec .. " s" end
	if sec < 5400 then return math.floor(sec / 60 + 0.5) .. " min" end
	local h = math.floor(sec / 3600)
	return h .. " h " .. math.floor((sec - h * 3600) / 60) .. " min"
end
local function short(s, n)
	s = tostring(s)
	if #s <= n then return s end
	return s:sub(1, n - 1) .. "…"
end

local function textOf(path)
	local ok, s = pcall(readfile, path)
	if ok and type(s) == "string" then return s end
end
local function put(path, text) return (pcall(writefile, path, text)) end
-- a file that is being rewritten reads badly for a moment: keep the last good copy; a missing file clears it
local cache = {}
local function jread(path)
	local s = textOf(path)
	if s == nil or s == "" then cache[path] = nil return nil end
	local ok, v = pcall(function() return HS:JSONDecode(s) end)
	if ok and type(v) == "table" then cache[path] = v return v end
	return cache[path]
end

-- ---------- what the farm and the optimiser wrote ----------
local function stopped(hb) return type(hb) == "table" and type(hb.status) == "string" and hb.status:sub(1, 7) == "stopped" end

function cy.read(name)
	local a = cy.ACCOUNTS[name]
	local snap = { name = name, mine = (name == LP.Name) }
	local server, pc = workspace:GetServerTimeNow(), os.time()
	snap.hb = jread(a.dir .. HB)
	if snap.hb and type(snap.hb.t) == "number" then snap.hbAge = server - snap.hb.t end
	snap.status = jread(ROOT .. "cyber_status_" .. name .. ".json")
	if snap.status and type(snap.status.at) == "number" then snap.statusAge = pc - snap.status.at end
	local flag = textOf(a.dir .. "cyber_farm.flag")
	snap.flag = flag and flag:match("%S+") or nil
	local lock = jread(a.dir .. a.ownerFile)
	snap.lock = lock and lock.owner or nil
	local afk = jread(ROOT .. "antiafk_" .. name .. ".json")
	if afk and type(afk.t) == "number" then snap.afkAge = pc - afk.t end
	snap.optimizerStopped = isfile(ROOT .. "cyber_optimizer.stop") and true or false
	local cfg = jread(a.dir .. "cyber_farm_cfg.json")
	snap.shopOn = cfg ~= nil and type(cfg.spend) == "table" and cfg.spend.shop == true
	if a.autostart then
		local dl = tonumber((textOf(a.autostart) or ""):match("%d+")) or 0
		if dl > pc then snap.autostartUntil = dl end
	end
	local g = _G.__CF_RUNNING
	snap.gAlive = snap.mine and type(g) == "number" and g > 0 and os.clock() - g < 30 or false
	return snap
end

-- running here (the script's own stamp), or a heartbeat so fresh that another copy must be alive
function cy.alive(snap)
	if snap.gAlive then return true end
	if snap.hb and snap.hbAge and not stopped(snap.hb) then return snap.hbAge < (snap.mine and 20 or 150) end
	return false
end

-- one word for the state + the line to show: kind is ok / warn / bad / dim
function cy.stateView(snap)
	local a = cy.ACCOUNTS[snap.name]
	local hb = snap.hb
	local st = hb and hb.status or nil
	local text, kind
	if cy.alive(snap) then
		if st == nil then text, kind = "Starting…", "warn"
		elseif st:sub(1, 6) == "paused" then
			local who = st:match("owner is (.+)$")
			if who then text, kind = "Waiting: the lock says " .. esc(who) .. ", the farm needs " .. a.owner, "warn"
			else text, kind = "Paused (" .. esc(st:sub(9)) .. ")", "warn" end
		elseif st == "between runs" then text, kind = "Running · between runs", "ok"
		else text, kind = "Running", "ok" end
		if hb and hb.dry then text = text .. " · test mode, nothing is sent" kind = "warn" end
	elseif stopped(hb) then
		text, kind = "Stopped · " .. esc(st:sub(10)), "dim"
	else
		text, kind = "Not running", "dim"
	end
	return kind, text
end

-- ---------- text for the window ----------
local function layoutSig(l)
	if type(l) ~= "table" then return nil end
	local t, c = {}, {}
	for _, m in ipairs(l.team or {}) do table.insert(t, tostring(m.attacker) .. "+" .. tostring(m.support or "")) end
	for k, v in pairs(l.chromeEquipped or {}) do table.insert(c, k .. ">" .. tostring(v)) end
	table.sort(c)
	return table.concat(t, "|") .. "#" .. table.concat(c, ",")
end
local function scoreText(sc)
	if type(sc) ~= "table" or type(sc.acts) ~= "number" then return nil end
	return string.format("%.1f acts per run", sc.acts) .. (type(sc.eddies) == "number" and (" · " .. cy.num(sc.eddies) .. " Eddies per run") or "")
end
local function deckText(l)
	local rows = {}
	for i, m in ipairs(l.team or {}) do
		local sup = (m.support and m.support ~= "") and (" + " .. esc(cy.pretty(m.support))) or ""
		table.insert(rows, i .. "   " .. esc(cy.pretty(m.attacker)) .. sup)
	end
	local pieces = 0
	for _ in pairs(l.chromeEquipped or {}) do pieces += 1 end
	if pieces > 0 then table.insert(rows, paint("dim", pieces .. " chrome pieces on the team")) end
	return table.concat(rows, "\n")
end

-- "card x", "support x", "chrome a@b", "chrome a<->b", "start", "pair" are the optimiser's move tags
function cy.moveText(move)
	local kind, rest = tostring(move or ""):match("^(%S+)%s*(.*)$")
	if kind == "card" then return "Swap in " .. esc(cy.pretty(rest)) end
	if kind == "support" then return "Try support " .. esc(cy.pretty(rest)) end
	if kind == "chrome" then
		local a, b = rest:match("^(.-)<%->(.*)$")
		if a then return "Swap chrome " .. esc(cy.pretty(a)) .. " and " .. esc(cy.pretty(b)) end
		local p, c = rest:match("^(.-)@(.*)$")
		if p then return "Chrome " .. esc(cy.pretty(p)) .. " on " .. esc(cy.pretty(c)) end
		return "Chrome change"
	end
	if kind == "start" then return "Re-check the deck in play" end
	if kind == "pair" then return "Combine the best changes" end
	return esc(cy.pretty(rest ~= "" and rest or kind or "?"))
end

local UPGRADES = { health = "Health", damage = "Damage", eddies = "Income", battleSpeed = "Battle speed" }
function cy.buyName(b)
	local kind, p = b.kind, type(b.payload) == "table" and b.payload or {}
	if kind == "crates" then return string.format("Recruit crates, tier %s, x%s", tostring(p.tier or "?"), tostring(b.n or p.quantity or "?")) end
	if kind == "capsules" then return "Chrome capsules x" .. tostring(b.n or p.quantity or "?") end
	if kind == "chromeGoal" then return "Saving up for chrome capsules" end
	if kind == "battleSpeed" then return "Battle speed" end
	if kind == "upgrade" then return (UPGRADES[p.upgrade] or cy.pretty(p.upgrade)) .. " upgrade" end
	return cy.pretty(kind)
end

-- everything the tab shows for one account, as rich text
function cy.view(snap)
	local a = cy.ACCOUNTS[snap.name]
	local hb, st = snap.hb, snap.status
	local v = {}
	local kind, text = cy.stateView(snap)
	v.state = "<b>" .. paint(kind, text) .. "</b>"

	-- current run
	local rows = {}
	if hb then
		local alive = cy.alive(snap)
		if alive and hb.act then table.insert(rows, "Act " .. tostring(hb.act) .. " · room " .. tostring(hb.room or "?") .. " of 9")
		elseif alive then table.insert(rows, "Between runs") end
		table.insert(rows, "Best act cleared " .. tostring(hb.highest or hb.bestAct or "?")
			.. (type(hb.eddies) == "number" and (" · " .. cy.num(hb.eddies / 100) .. " Eddies") or "")
			.. (type(hb.rate) == "number" and (" · about " .. cy.num(hb.rate) .. " Eddies per hour") or ""))
		table.insert(rows, paint("dim", tostring(hb.runs or 0) .. " runs · " .. tostring(hb.deaths or 0) .. " defeats · " .. tostring(hb.buys or 0) .. " purchases · "
			.. tostring(hb.sent or 0) .. " commands · up " .. cy.span(hb.up) .. (hb.version and (" · script " .. esc(hb.version)) or "")))
		if not alive and snap.hbAge then table.insert(rows, paint("dim", "last heartbeat " .. cy.span(snap.hbAge) .. " ago")) end
	else
		table.insert(rows, paint("dim", "No heartbeat file yet (" .. a.dir .. HB .. ")."))
	end
	v.run = table.concat(rows, "\n")

	-- what the optimiser writes
	local old = ""
	if st and snap.statusAge and snap.statusAge > 600 then
		old = paint("warn", "Optimiser report is " .. cy.span(snap.statusAge) .. " old" .. (snap.optimizerStopped and " (optimiser stopped)" or "")) .. "\n"
	end
	if not st then
		local none = paint("dim", "No optimiser report yet (" .. ROOT .. "cyber_status_" .. snap.name .. ".json).")
		v.aiming, v.buy, v.deck, v.best, v.trying = none, none, none, none, none
	else
		local aim = {}
		for i, s in ipairs(st.aiming or {}) do if i <= 3 then table.insert(aim, "• " .. esc(short(s, 180))) end end
		v.aiming = old .. (#aim > 0 and table.concat(aim, "\n") or paint("dim", "Nothing listed."))

		local b = st.nextBuy
		if type(b) == "table" then
			local line = "<b>" .. esc(cy.buyName(b)) .. "</b>"
			if type(b.price) == "number" then line = line .. " · " .. cy.num(b.price) .. " Eddies" end
			if b.affordable == true then line = line .. " · " .. paint("ok", "can buy now")
			elseif b.affordable == false then line = line .. " · " .. paint("warn", "saving up") end
			local gains = {}
			if type(b.dActs) == "number" and b.dActs > 0 then table.insert(gains, string.format("+%.1f acts per run", b.dActs)) end
			if type(b.dEddiesPerHour) == "number" and b.dEddiesPerHour > 0 then table.insert(gains, "+" .. cy.num(b.dEddiesPerHour) .. " Eddies per hour") end
			if #gains > 0 then line = line .. "\n" .. table.concat(gains, " · ") end
			if b.note and b.note ~= "" then line = line .. "\n" .. paint("dim", esc(short(b.note, 160))) end
			v.buy = line
		else
			v.buy = paint("dim", "Nothing to buy right now.")
		end

		local played, best = st.played, st.best
		if type(played) == "table" and type(played.team) == "table" then
			v.deck = deckText(played) .. (scoreText(played.score) and ("\n" .. paint("dim", "Engine: " .. scoreText(played.score))) or "")
		else
			v.deck = paint("dim", "Not known yet.")
		end

		if type(best) ~= "table" or type(best.team) ~= "table" then
			v.best = paint("dim", "Nothing better than the deck in play found yet.")
		elseif layoutSig(best) == layoutSig(played) then
			v.best = paint("ok", "The deck in play is the best found.") .. (scoreText(best.score) and ("\n" .. paint("dim", scoreText(best.score))) or "")
		else
			local gain = ""
			local bs, ps = best.score, played and played.score
			if type(bs) == "table" and type(ps) == "table" and type(bs.acts) == "number" and type(ps.acts) == "number" then
				gain = string.format(" (%+.1f acts)", bs.acts - ps.acts)
			end
			v.best = deckText(best) .. "\n" .. paint("ok", "goes in at the next run start" .. gain)
				.. (scoreText(best.score) and ("\n" .. paint("dim", scoreText(best.score))) or "")
		end

		local tr, lines = st.trying, {}
		if type(tr) == "table" then for i, t in ipairs(tr) do if i <= 5 then table.insert(lines, "• " .. cy.moveText(t.move)) end end end
		local head
		if st.searching then
			head = "Searching" .. (st.phase and (" (" .. esc(st.phase) .. ")") or "") .. " · " .. tostring(st.tried or 0) .. " decks tried"
			if type(st.since) == "number" then head = head .. " · since " .. cy.span(os.time() - st.since) end
		else
			head = "Nothing left to try · " .. tostring(st.tried or 0) .. " decks tried, waits for new cards, chrome or upgrades"
		end
		v.trying = old .. head .. (#lines > 0 and ("\n" .. table.concat(lines, "\n")) or "")
	end

	-- safety: shop, lock, anti-AFK, restart after a rejoin
	local s = {}
	table.insert(s, snap.shopOn and ("Shop buying: " .. paint("bad", "ON") .. " (it would buy the rolls). Press the button below.")
		or ("Shop buying: " .. paint("ok", "OFF") .. " (you buy the rolls yourself)"))
	if snap.lock == a.owner then table.insert(s, "Lock: " .. esc(snap.lock) .. " (the farm may send)")
	else table.insert(s, "Lock: " .. paint("warn", snap.lock and esc(snap.lock) or "not set") .. " (the farm waits until it says " .. a.owner .. ")") end
	if snap.afkAge and snap.afkAge < 150 then table.insert(s, "Anti-AFK (autoexec): " .. paint("ok", "on") .. ", last tap " .. cy.span(snap.afkAge) .. " ago")
	else table.insert(s, "Anti-AFK (autoexec): " .. paint("bad", "NOT running") .. (snap.afkAge and (", last tap " .. cy.span(snap.afkAge) .. " ago") or ", no heartbeat") .. ". Rejoin the game: the autoexec starts it.") end
	if snap.flag == "0" or snap.flag == "pause" then table.insert(s, "Flag file: " .. paint("warn", esc(snap.flag)) .. " (" .. (snap.flag == "0" and "stop" or "pause") .. ")") end
	if snap.autostartUntil then table.insert(s, "Restarts itself after a rejoin until " .. os.date("%H:%M", snap.autostartUntil) .. ". Stop turns that off.") end
	v.safety = table.concat(s, "\n")

	-- one line for the other account
	local line = "<b>" .. esc(snap.name) .. "</b>  " .. paint(kind, text)
	if hb and cy.alive(snap) and hb.act then line = line .. " · act " .. tostring(hb.act) .. " · best " .. tostring(hb.highest or "?") end
	v.line = line
	return v
end

-- ---------- control ----------
local function writeFlag(name, value) return put(cy.ACCOUNTS[name].dir .. "cyber_farm.flag", value) end
cy.writeFlag = writeFlag

-- the farm's settings file must say spend.shop = false (the script's own default flipped once and bought rolls); only that key is touched
function cy.ensureShopOff(name)
	local path = cy.ACCOUNTS[name].dir .. "cyber_farm_cfg.json"
	local s = textOf(path)
	local cfg
	if s == nil or s:match("^%s*$") then cfg = {}
	else
		local ok, v = pcall(function() return HS:JSONDecode(s) end)
		if not ok or type(v) ~= "table" then return false, false end   -- unreadable right now: never overwrite a file we could not read
		cfg = v
	end
	if type(cfg.spend) ~= "table" then cfg.spend = {} end
	if cfg.spend.shop == false then return false, true end
	local was = cfg.spend.shop
	cfg.spend.shop = false
	local ok2, out = pcall(function() return HS:JSONEncode(cfg) end)
	if not ok2 or not put(path, out) then return false, false end
	return was == true, true
end

-- a restart after a rejoin would undo a Stop: switch the autoexec's deadline off (only if it is armed)
function cy.disarmAutostart(name)
	local a = cy.ACCOUNTS[name]
	if not a.autostart then return false end
	local dl = tonumber((textOf(a.autostart) or ""):match("%d+")) or 0
	if dl > os.time() then put(a.autostart, "0") return true end
	return false
end

-- returns true, "sent" | "not running" ; the flag file only gets its "0" while the farm is alive (a 0 left behind would stop its next start at once)
function cy.stop(name)
	name = name or LP.Name
	if not cy.ACCOUNTS[name] then return false, "unknown account" end
	local alive = cy.alive(cy.read(name))
	if name == LP.Name then _G.__CF_STOP = true end
	if alive then writeFlag(name, "0") end
	local disarmed = cy.disarmAutostart(name)
	core.say("Cyberpunk farm: stop " .. (alive and "sent to " or "(not running) for ") .. name .. (disarmed and ", restart after a rejoin switched off" or ""))
	return true, alive and "sent" or "not running"
end

local function candidates(name, version)
	local a = cy.ACCOUNTS[name]
	local list = {}
	local function add(p) for _, q in ipairs(list) do if q == p then return end end table.insert(list, p) end
	if version ~= "previous" then add(a.dir .. "cyber_farm.lua") add(ROOT .. "cyber_farm.lua") end
	add(a.dir .. "cyber_farm_prev.lua") add(ROOT .. "cyber_farm_prev.lua")
	return list
end
cy.candidates = candidates

local function loadScript(path)
	local src = textOf(path)
	if not src then return nil, "file not found" end
	-- an executor's loadstring returns nil + the error; some runtimes (Lune) raise it instead
	local ok, fn, err = pcall(loadstring, src, "=" .. path:match("[^/]+$"))
	if not ok then return nil, fn end
	return fn, err
end

-- runs paths[i] (already compiled as fn, or compiled here) in its own thread; a crash in the first 30 s moves on to the next script
local function launch(paths, i, fn)
	while i <= #paths do
		local err
		if not fn then fn, err = loadScript(paths[i]) end
		if fn then
			core.say("Cyberpunk farm: starting " .. paths[i])
			local began = os.clock()
			task.spawn(function()
				local ok, e = pcall(fn)
				if not ok then
					core.say("Cyberpunk farm crashed:", short(e, 160))
					_G.__CF_RUNNING = 0
					if os.clock() - began < 30 and not _G.__CF_STOP and i < #paths then launch(paths, i + 1) end
				elseif os.clock() - began < 15 then
					core.say("Cyberpunk farm: the script ended right away (look for a console line starting with CF)")
				else
					core.say("Cyberpunk farm ended")
				end
			end)
			return paths[i], i
		end
		core.say("Cyberpunk farm: can't use " .. paths[i] .. " (" .. short(err, 120) .. ")")
		i += 1
		fn = nil
	end
end

-- opts = { version = "newest" | "previous", dry = bool, before = function() end (called once everything checked out) }
-- returns true, message  or  false, reason
function cy.start(opts)
	opts = opts or {}
	local name = LP.Name
	if not cy.ACCOUNTS[name] then return false, "Only Whousleaks and Umson_42 have a Cyberpunk farm." end
	if not core.accountOk() then return false, name .. " is switched off in Settings." end
	if cy.alive(cy.read(name)) then return false, "Already running on " .. name .. ". Stop it first to restart." end
	local other = core.otherScriptRunning(HB)
	if other then return false, "Another script runs (" .. other:gsub("^AnimeCardClash/", "") .. "). Stop it first." end
	local ok, err = core.init()
	if not ok then return false, err end
	local okU, user = pcall(core.user)
	if okU and user and user.cyberpunkEvent == nil then return false, "The Cyberpunk event is not open on this account." end
	-- the first script that exists and compiles (the previous one when the newest is missing or broken)
	local list = candidates(name, opts.version)
	local first, fn0
	for i, p in ipairs(list) do
		local fn, e = loadScript(p)
		if fn then first, fn0 = i, fn break end
		if e ~= "file not found" then core.say("Cyberpunk farm: can't use " .. p .. " (" .. short(e, 120) .. ")") end
	end
	if not first then return false, "Can't find or load cyber_farm.lua in " .. cy.ACCOUNTS[name].dir end
	local changed, readable = cy.ensureShopOff(name)
	if not readable then return false, "Can't read the farm settings file now. Try again." end
	if opts.before then opts.before() end
	writeFlag(name, "1")
	_G.__CF_STOP = false
	_G.__CF_DRY = opts.dry and true or nil
	if not _G.__BS_CTX and core.ctx then _G.__BS_CTX = core.ctx end
	local used = launch(list, first, fn0)
	local msg = "Starting " .. used:match("[^/]+$") .. (opts.dry and " in test mode" or "")
	if changed then msg = msg .. ". Shop was ON, now OFF." end
	return true, msg, used
end

-- turns shop buying off in the settings file (never on)
function cy.shopOff(name)
	local changed, readable = cy.ensureShopOff(name)
	if not readable then return false, "Can't read the farm settings file now." end
	return true, changed and "Shop buying switched off." or "Shop buying is already off."
end

return cy
