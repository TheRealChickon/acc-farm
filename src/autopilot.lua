-- Link to the account autopilot (the PC program tasks/2026-10-19-account-autopilot). Plain files in the executor workspace:
--   AnimeCardClash/autopilot/status.json          what the autopilot decided for every account (now, next, why, conditions, focus, quick jobs)
--   AnimeCardClash/autopilot/config.json          read-only copy of its config; "editable" lists what the window may change
--   AnimeCardClash/autopilot_overrides.json       the window's changes: {"set": {"focus": "luck", "jobs.packs.allowed": false}}
--   AnimeCardClash/autopilot/autopilot_read.lua   the read-only account read (sends nothing)
--   AnimeCardClash/autopilot/autopilot_runner.lua runs only the jobs Sami approved in the PC config (live.approved_steps)
-- The window never approves a live step: that only happens in the PC config, on Sami's word.
local core = ...
local ap = {
	STATUS = "AnimeCardClash/autopilot/status.json",
	CONFIG = "AnimeCardClash/autopilot/config.json",
	OVERRIDES = "AnimeCardClash/autopilot_overrides.json",
	READER = "AnimeCardClash/autopilot/autopilot_read.lua",
	RUNNER = "AnimeCardClash/autopilot/autopilot_runner.lua",
	FOCUSES = { "auto", "luck", "traits", "packs" },
	FOCUS_NAMES = { auto = "Auto", luck = "Luck index", traits = "Trait rerolls", packs = "Packs" },
}

-- the GUI may only set keys the autopilot lists as editable; anything else is refused here too
function ap.editable(cfg, key)
	return type(cfg) == "table" and type(cfg.editable) == "table" and cfg.editable[key] ~= nil
end

function ap.setOverride(key, value)
	local cur = core.readJson(ap.OVERRIDES) or {}
	cur.set = type(cur.set) == "table" and cur.set or {}
	cur.set[key] = value
	core.writeJson(ap.OVERRIDES, cur)
	return cur
end

-- the account's block of the status file, or nil
function ap.account(status, name)
	return type(status) == "table" and type(status.accounts) == "table" and status.accounts[name] or nil
end

local function ago(t)
	if not t then return "?" end
	local s = math.max(0, os.time() - t)
	if s < 90 then return math.floor(s) .. " s" end
	if s < 5400 then return math.floor(s / 60 + 0.5) .. " min" end
	return string.format("%.1f h", s / 3600)
end
ap.ago = ago

-- one block of text for the Autopilot tab
function ap.statusText(status, name)
	local a = ap.account(status, name)
	if not a then return "No autopilot plan for " .. tostring(name) .. " yet. It appears once the PC runs the autopilot." end
	local f = a.focus or {}
	local lines = {
		"<b>Now:</b> " .. tostring(a.now or "-"),
		"<b>Next:</b> " .. tostring(a.next or "-"),
		"<b>Why:</b> " .. tostring(a.why or "-"),
	}
	if type(a.conditions) == "table" and #a.conditions > 0 then table.insert(lines, "<b>Conditions:</b> " .. table.concat(a.conditions, "; ")) end
	table.insert(lines, string.format("<b>Focus:</b> %s%s", ap.FOCUS_NAMES[f.effective] or tostring(f.effective),
		f.chosen == "auto" and " (picked by auto)" or ""))
	table.insert(lines, string.format("Plan made %s ago%s", ago(status.updatedAt), status.dry_run and " · plan only, nothing is sent" or ""))
	return table.concat(lines, "\n")
end

-- the quick jobs that are ready / waiting, short
function ap.jobsText(status, name)
	local a = ap.account(status, name)
	if not a or type(a.quick) ~= "table" then return "" end
	local ready, waiting = {}, {}
	for _, q in ipairs(a.quick) do
		if q.state == "ready" then table.insert(ready, "• " .. tostring(q.label))
		elseif q.state == "waiting" or q.state == "needs_check" then table.insert(waiting, "• " .. tostring(q.label)) end
	end
	local out = {}
	if #ready > 0 then table.insert(out, "<b>Ready</b>\n" .. table.concat(ready, "\n", 1, math.min(#ready, 8))) end
	if #waiting > 0 then table.insert(out, "<b>Waiting</b>\n" .. table.concat(waiting, "\n", 1, math.min(#waiting, 8))) end
	return #out > 0 and table.concat(out, "\n") or "Nothing to do right now."
end

-- one line for the status bar under every tab
function ap.barText(status, name)
	local a = ap.account(status, name)
	if not a then return nil end
	local f = a.focus or {}
	return string.format("Autopilot · %s · next: %s", ap.FOCUS_NAMES[f.effective] or tostring(f.effective or "?"), tostring(a.next or "-"))
end

-- a roll order (the strict perfect-luck pack session) or a cancel of the last one; the PC answers in status.json "orders"
function ap.order(kind, account, target)
	local cur = core.readJson(ap.OVERRIDES) or {}
	cur.orders = type(cur.orders) == "table" and cur.orders or {}
	local id = string.format("%s-%d-%d", kind, os.time(), math.random(1000, 9999))
	local o = { id = id, kind = kind, account = account, at = os.time(), by = "game window" }
	if kind == "roll_packs" then o.when = "next_ideal" end
	if target then o.target = target end
	table.insert(cur.orders, o)
	while #cur.orders > 20 do table.remove(cur.orders, 1) end
	cur.rev = (tonumber(cur.rev) or 0) + 1
	core.writeJson(ap.OVERRIDES, cur)
	return id
end

function ap.lastRoll(status, account)
	local last
	for _, o in ipairs(type(status) == "table" and type(status.orders) == "table" and status.orders or {}) do
		if o.kind == "roll_packs" and o.account == account then last = o end
	end
	return last
end

function ap.approved(status)
	local l = type(status) == "table" and type(status.live) == "table" and status.live.approved_steps or {}
	return type(l) == "table" and l or {}
end

return ap
