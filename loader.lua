-- Card Clash Farm loader. Run it with (one line, your token in the executor's workspace file acc-farm/token.txt):
--   loadstring(request({Url="https://raw.githubusercontent.com/OWNER/REPO/main/loader.lua",Headers={Authorization="token "..readfile("acc-farm/token.txt")}}).Body)()
-- It downloads dist/acc-farm.lua (all modules in one file) from the same private repo and starts the window.
-- Offline / testing: put the repo's src folder at acc-farm/src in the workspace and set getgenv().ACC_LOCAL = true first.
local REPO = getgenv().ACC_REPO or "OWNER/REPO"
local BRANCH = getgenv().ACC_BRANCH or "main"

local sources
if getgenv().ACC_LOCAL then
	sources = setmetatable({}, { __index = function(_, name)
		local ok, s = pcall(readfile, "acc-farm/src/" .. name .. ".lua")
		return ok and s or nil
	end })
else
	local token = getgenv().ACC_TOKEN
	if not token then local ok, t = pcall(readfile, "acc-farm/token.txt") token = ok and t:gsub("%s+", "") or nil end
	local req = request or http_request or (syn and syn.request)
	local res = req({ Url = "https://raw.githubusercontent.com/" .. REPO .. "/" .. BRANCH .. "/dist/acc-farm.lua?t=" .. os.time(),
		Method = "GET", Headers = token and { Authorization = "token " .. token } or nil })
	if not res or res.StatusCode ~= 200 then error("Card Clash Farm: download failed (" .. tostring(res and res.StatusCode) .. "). Check acc-farm/token.txt.") end
	sources = loadstring(res.Body)()
end

local loaded = {}
local function import(name, ...)
	if loaded[name] ~= nil then return loaded[name] end
	local src = sources[name]
	if not src then error("Card Clash Farm: module missing: " .. name) end
	local fn, err = loadstring(src, "=" .. name)
	if not fn then error("Card Clash Farm: " .. name .. ": " .. tostring(err)) end
	local mod = fn(...)
	loaded[name] = mod
	return mod
end
return import("main", import)
