-- Link to the farm director (the planner thread's program on the PC). Two plain files in the executor workspace, same ones the
-- headless script reads, so the window and the script never disagree:
--   AnimeCardClash/director_config.json   what the director may do (accounts, weights, allowed modes, worker budget ...). The window
--                                         shows every number / on-off / text field it finds and writes a change back to that one field.
--   AnimeCardClash/director_status.json   what the director decided (running now, next, ranking, workers, decisions, warnings).
-- The window never needs to know the exact field names: it lists what is in the files.
local core = ...
local planner = { CONFIG = "AnimeCardClash/director_config.json", STATUS = "AnimeCardClash/director_status.json", MAXROWS = 60 }

local function isArray(t) return type(t) == "table" and (#t > 0 or next(t) == nil) end

-- config leaves as { {path = {"weights","luck_factor"}, value = 0.25, kind = "number"|"boolean"|"string"}, ... }, sorted by path text
function planner.leaves(cfg)
	local out = {}
	local function walk(t, path)
		if type(t) ~= "table" or #out >= planner.MAXROWS then return end
		local keys = {}
		for k in pairs(t) do table.insert(keys, k) end
		table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
		for _, k in ipairs(keys) do
			local v, p = t[k], { table.unpack(path) }
			table.insert(p, k)
			local tv = type(v)
			if tv == "number" or tv == "boolean" or tv == "string" then table.insert(out, { path = p, value = v, kind = tv })
			elseif tv == "table" and not isArray(v) then walk(v, p)
			elseif tv == "table" then   -- list of plain values -> one comma text field
				local plain = true
				for _, x in ipairs(v) do if type(x) == "table" then plain = false end end
				if plain then table.insert(out, { path = p, value = v, kind = "list" }) end
			end
		end
	end
	walk(cfg or {}, {})
	return out
end

function planner.pathText(path)
	local o = {}
	for _, k in ipairs(path) do table.insert(o, tostring(k)) end
	return table.concat(o, " / ")
end

-- writes one field: reads the file fresh, changes only that path, saves (the director may have changed other fields meanwhile)
function planner.setField(path, value)
	local cfg = core.readJson(planner.CONFIG)
	if type(cfg) ~= "table" then return false, "config file not found" end
	local t = cfg
	for i = 1, #path - 1 do
		if type(t[path[i]]) ~= "table" then return false, "field vanished" end
		t = t[path[i]]
	end
	t[path[#path]] = value
	core.writeJson(planner.CONFIG, cfg)
	return true
end

function planner.parseList(s)
	local o = {}
	for part in string.gmatch(s, "[^,]+") do
		local v = part:gsub("^%s+", ""):gsub("%s+$", "")
		if v ~= "" then table.insert(o, tonumber(v) or v) end
	end
	return o
end

-- a readable text for the status file; picks the usual name / state / score fields of list rows, shows everything else as key: value
local NAMEKEYS = { "name", "activity", "title", "mode", "label", "id", "key" }
local EXTRA = { "state", "score", "value", "chance", "reason", "why", "eta" }
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
	for k in pairs(st) do table.insert(keys, k) end
	table.sort(keys, function(a, b)   -- the usual headline fields first
		local order = { now = 1, running = 1, next = 2, decisions = 3, ranking = 4, plan = 5, workers = 6, warnings = 7 }
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
				table.insert(lines, "  " .. esc(sub[i]) .. ": " .. (type(v2) == "table" and rowText(v2) or short(v2)))
			end
		end
	end
	local age = type(st.updated) == "number" and (os.time() - st.updated) or nil
	if age and age > 900 then table.insert(lines, 1, "<b>Director status is " .. math.floor(age / 60) .. " min old</b>") end
	return table.concat(lines, "\n")
end

return planner
