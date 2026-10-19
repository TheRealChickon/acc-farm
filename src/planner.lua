-- Link to the farm director (the planner thread's program on the PC). Two plain files in the executor workspace, same ones the
-- headless script reads, so the window and the script never disagree:
--   AnimeCardClash/director_config.json   what the director may do (accounts, weights, allowed modes, worker budget ...). The window
--                                         shows every number / on-off / text field it finds and writes a change back to that one field.
--   AnimeCardClash/director_status.json   what the director decided (running now, next, ranking, workers, decisions, warnings).
-- The window never needs to know the exact field names: it lists what is in the files.
local core = ...
local planner = { CONFIG = "AnimeCardClash/director_config.json", STATUS = "AnimeCardClash/director_status.json", MAXROWS = 60 }

local function isArray(t) return type(t) == "table" and (#t > 0 or next(t) == nil) end

-- The director's config mirror says what may be changed: "editable" = { ["dotted.key"] = {kind = float|int|bool|enum, min, max | values} }.
-- Only those keys get a control. A change goes to AnimeCardClash/director_overrides.json as {"set": {"dotted.key": value}}; the director
-- applies valid keys on its next round (max 5 min) and lists refused ones under rejected_overrides (config + status files).
planner.OVERRIDES = "AnimeCardClash/director_overrides.json"

local function walk(cfg, dotted)
	local t = cfg
	for part in string.gmatch(dotted, "[^%.]+") do
		if type(t) ~= "table" then return nil end
		local n = tonumber(part)
		if n and t[n + 1] ~= nil then t = t[n + 1] else t = t[part] end   -- "orders.0" = first list entry
	end
	return t
end
planner.walk = walk

-- editable controls as { {key = "weights.completion_card_M", kind = "float", value = 0.5, min, max, values}, ...}, sorted by key
function planner.controls(cfg, overrides)
	local out = {}
	if type(cfg) ~= "table" or type(cfg.editable) ~= "table" then return out end
	local pending = type(overrides) == "table" and type(overrides.set) == "table" and overrides.set or {}
	local keys = {}
	for k in pairs(cfg.editable) do table.insert(keys, k) end
	table.sort(keys)
	for _, k in ipairs(keys) do
		if #out >= planner.MAXROWS then break end
		local spec = cfg.editable[k]
		if type(spec) == "table" then
			local v = walk(cfg, k)
			local shown = pending[k] ~= nil and pending[k] or v
			table.insert(out, { key = k, kind = spec.kind, value = shown, min = spec.min, max = spec.max, values = spec.values, pending = pending[k] ~= nil })
		end
	end
	return out
end

-- checks a typed value against the spec; returns the value to send or nil + why
function planner.check(ctl, v)
	if ctl.kind == "bool" then return v == true end
	if ctl.kind == "enum" then
		for _, x in ipairs(ctl.values or {}) do if x == v then return v end end
		return nil, "not one of the allowed values"
	end
	local n = tonumber(v)
	if not n then return nil, "not a number" end
	if ctl.kind == "int" then n = math.floor(n + 0.5) end
	if ctl.min and n < ctl.min then return nil, "below the minimum " .. ctl.min end
	if ctl.max and n > ctl.max then return nil, "above the maximum " .. ctl.max end
	return n
end

-- adds one key to the overrides file: reads it fresh, changes only that key, writes it back
function planner.setOverride(key, value)
	local o = core.readJson(planner.OVERRIDES)
	if type(o) ~= "table" then o = {} end
	if type(o.set) ~= "table" then o.set = {} end
	o.set[key] = value
	core.writeJson(planner.OVERRIDES, o)
	return true
end

-- a readable text for the status file; picks the usual name / state / score fields of list rows, shows everything else as key: value
local NAMEKEYS = { "name", "activity", "title", "mode", "label", "consumer", "id", "key" }
local EXTRA = { "state", "score", "now", "target", "delta", "value", "chance", "reason", "why", "eta" }
local function esc(s) return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")) end
local function short(v)
	if type(v) == "number" then return (v == math.floor(v)) and tostring(v) or string.format("%.2f", v) end
	return esc(v)
end
local function rowText(r)
	if type(r) ~= "table" then return short(r) end
	local parts = {}
	for _, k in ipairs(NAMEKEYS) do if r[k] ~= nil and type(r[k]) ~= "table" then table.insert(parts, "<b>" .. short(r[k]) .. "</b>") break end end
	for _, k in ipairs(EXTRA) do if r[k] ~= nil and type(r[k]) ~= "table" then table.insert(parts, k .. " " .. short(r[k])) end end
	if #parts == 0 then
		local keys = {}
		for k, v in pairs(r) do if type(v) ~= "table" then table.insert(keys, k) end end
		table.sort(keys)
		for i = 1, math.min(#keys, 4) do table.insert(parts, tostring(keys[i]) .. " " .. short(r[keys[i]])) end
	end
	return table.concat(parts, " · ")
end
function planner.statusText(st)
	if type(st) ~= "table" then return "No director status yet (the director has not written " .. planner.STATUS .. ")." end
	local lines, keys = {}, {}
	if type(st.text) == "string" then table.insert(lines, esc(st.text)) end
	for k in pairs(st) do if k ~= "text" and k ~= "updated" then table.insert(keys, k) end end
	table.sort(keys, function(a, b)   -- the usual headline fields first
		local order = { now = 1, running = 1, next = 2, decisions_for_sami = 3, ranking = 4, plan = 5, workers = 6, warnings = 7, rejected_overrides = 8 }
		local oa, ob = order[a] or 9, order[b] or 9
		if oa ~= ob then return oa < ob end
		return tostring(a) < tostring(b)
	end)
	for _, k in ipairs(keys) do
		if #lines >= 40 then break end
		local v = st[k]
		if type(v) ~= "table" then table.insert(lines, esc(k) .. ": " .. short(v))
		elseif isArray(v) then
			table.insert(lines, "<b>" .. esc(k) .. "</b>")
			for i = 1, math.min(#v, 6) do table.insert(lines, "  " .. rowText(v[i])) end
			if #v > 6 then table.insert(lines, "  … " .. (#v - 6) .. " more") end
		else
			table.insert(lines, "<b>" .. esc(k) .. "</b>")
			local sub = {}
			for k2, v2 in pairs(v) do table.insert(sub, k2) end
			table.sort(sub, function(a, b) return tostring(a) < tostring(b) end)
			for i = 1, math.min(#sub, 8) do
				local v2 = v[sub[i]]
				if type(v2) == "table" and isArray(v2) then
					table.insert(lines, "  " .. esc(sub[i]))
					for j = 1, math.min(#v2, 6) do table.insert(lines, "    " .. rowText(v2[j])) end
				else
					table.insert(lines, "  " .. esc(sub[i]) .. ": " .. (type(v2) == "table" and rowText(v2) or short(v2)))
				end
			end
		end
	end
	local age = type(st.updated) == "number" and (os.time() - st.updated) or nil
	if age and age > 900 then table.insert(lines, 1, "<b>Director status is " .. math.floor(age / 60) .. " min old</b>") end
	return table.concat(lines, "\n")
end

return planner
