-- dawidlib (rewrite). Same API as Sami's old lib, plus: drag anywhere on the title bar, resize from the bottom-right
-- corner, minimise, a hide key (RightControl by default), and objects you can update later (:Set / :Get / :SetText).
--   local lib = loadstring(...)()
--   local win = lib:Window("Title")            win:Label("Section")    local tab = win:Tab(name, icon, color)
--   tab:Line(text) tab:Button(text, cb) tab:Label(text) tab:Toggle(text, default, cb) tab:Slider(text, decimals, min, max, default, cb)
--   tab:Bind(text, key, hold, _, cb) tab:Textbox(text, numbersOnly, clearOnFocus, cb) tab:RadioButtons(text, options, cb)
--   tab:Dropdown(text, options, cb) tab:Colorpicker(text, color, cb) tab:Order(text, items, cb)  (reorderable list)
--   lib:Notification(title, text, icon, button) lib:ChangeTheme("Dark"|"Light") lib:Destroy()
--   globals (old API): ChangeLabelText(oldPart, new) ChangeLabelColor(text, r, g, b) ResetLabelColor()
local Players = game:GetService("Players")
local UIS = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local CoreGui = game:GetService("CoreGui")

local lib = { Flags = {}, ToggleKey = Enum.KeyCode.RightControl }
local THEMES = {
	Dark = { bg = Color3.fromRGB(22, 23, 28), side = Color3.fromRGB(28, 29, 36), card = Color3.fromRGB(35, 37, 46), cardHover = Color3.fromRGB(44, 46, 58),
		text = Color3.fromRGB(235, 236, 242), sub = Color3.fromRGB(150, 154, 170), line = Color3.fromRGB(52, 54, 66), accent = Color3.fromRGB(110, 140, 255) },
	Light = { bg = Color3.fromRGB(244, 245, 249), side = Color3.fromRGB(232, 234, 241), card = Color3.fromRGB(255, 255, 255), cardHover = Color3.fromRGB(238, 240, 248),
		text = Color3.fromRGB(28, 30, 38), sub = Color3.fromRGB(105, 110, 128), line = Color3.fromRGB(214, 217, 228), accent = Color3.fromRGB(80, 110, 235) },
}
local theme = THEMES.Dark
local painted = {}   -- {inst, prop, key} repainted on theme change
local labels = {}    -- every Label object, for the old global helpers

local function new(class, props, children)
	local o = Instance.new(class)
	for k, v in pairs(props or {}) do if k ~= "Parent" then o[k] = v end end
	for _, c in ipairs(children or {}) do c.Parent = o end
	if props and props.Parent then o.Parent = props.Parent end
	return o
end
local function paint(inst, prop, key) inst[prop] = theme[key] table.insert(painted, { inst, prop, key }) return inst end
local function round(r) return new("UICorner", { CornerRadius = UDim.new(0, r or 8) }) end
local function pad(p) return new("UIPadding", { PaddingLeft = UDim.new(0, p), PaddingRight = UDim.new(0, p), PaddingTop = UDim.new(0, p), PaddingBottom = UDim.new(0, p) }) end
local function tween(o, t, props) TweenService:Create(o, TweenInfo.new(t, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props):Play() end
local function text(props)
	local t = new("TextLabel", { BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, TextSize = 13, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd })
	for k, v in pairs(props) do t[k] = v end
	return t
end

local function guiParent()
	local ok, h = pcall(function() return gethui and gethui() end)
	if ok and h then return h end
	local ok2 = pcall(function() local _ = CoreGui.Name end)
	return ok2 and CoreGui or Players.LocalPlayer:WaitForChild("PlayerGui")
end

function lib:ChangeTheme(name)
	theme = THEMES[name] or THEMES.Dark
	for _, p in ipairs(painted) do if p[1].Parent ~= nil or p[1] == lib.Gui then pcall(function() p[1][p[2]] = theme[p[3]] end) end end
	for _, l in ipairs(labels) do if not l.custom then l.inst.TextColor3 = theme.text end end
end

function lib:Destroy()
	if lib.Gui then lib.Gui:Destroy() end
	for _, c in ipairs(lib.conns or {}) do c:Disconnect() end
end

function lib:Notification(title, body, icon, button, seconds)
	if not lib.Gui then return end
	local holder = lib.Gui:FindFirstChild("Notes")
	local n = new("Frame", { Size = UDim2.new(1, 0, 0, 64), Parent = holder }, { round(10), pad(10) })
	paint(n, "BackgroundColor3", "card")
	if icon and icon ~= "" then new("ImageLabel", { BackgroundTransparency = 1, Image = icon, Size = UDim2.fromOffset(22, 22), Position = UDim2.fromOffset(0, 2), Parent = n }) end
	local x = (icon and icon ~= "") and 30 or 0
	paint(text({ Text = tostring(title), Font = Enum.Font.GothamBold, Size = UDim2.new(1, -x, 0, 18), Position = UDim2.fromOffset(x, 0), Parent = n }), "TextColor3", "text")
	paint(text({ Text = tostring(body), TextWrapped = true, TextTruncate = Enum.TextTruncate.None, Size = UDim2.new(1, -x, 0, 30), Position = UDim2.fromOffset(x, 18), TextYAlignment = Enum.TextYAlignment.Top, Parent = n }), "TextColor3", "sub")
	local function close() if n.Parent then n:Destroy() end end
	if button then
		local b = new("TextButton", { Text = button, Font = Enum.Font.GothamBold, TextSize = 12, AutoButtonColor = false, Size = UDim2.fromOffset(56, 22), Position = UDim2.new(1, -56, 1, -22), Parent = n }, { round(6) })
		b.BackgroundColor3 = theme.accent b.TextColor3 = Color3.new(1, 1, 1)
		b.MouseButton1Click:Connect(close)
	end
	task.delay(seconds or 6, close)
end

function lib:Window(title)
	local old = guiParent():FindFirstChild("dawidlib")
	if old then old:Destroy() end
	painted, labels, lib.conns = {}, {}, {}
	local gui = new("ScreenGui", { Name = "dawidlib", ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, IgnoreGuiInset = true })
	pcall(function() if syn and syn.protect_gui then syn.protect_gui(gui) end end)
	gui.Parent = guiParent()
	lib.Gui = gui
	new("Frame", { Name = "Notes", BackgroundTransparency = 1, Size = UDim2.fromOffset(270, 400), AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -16, 1, -16), Parent = gui },
		{ new("UIListLayout", { Padding = UDim.new(0, 8), VerticalAlignment = Enum.VerticalAlignment.Bottom, SortOrder = Enum.SortOrder.LayoutOrder }) })

	local MIN = Vector2.new(460, 300)
	local main = new("Frame", { Name = "Main", Size = UDim2.fromOffset(620, 420), Position = UDim2.new(0.5, -310, 0.5, -210), ClipsDescendants = true, Parent = gui }, { round(12) })
	paint(main, "BackgroundColor3", "bg")
	paint(new("UIStroke", { Thickness = 1, Transparency = 0.3, Parent = main }), "Color", "line")

	local top = new("Frame", { Name = "Top", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 40), Parent = main })
	paint(text({ Text = title or "Anime Card Clash", Font = Enum.Font.GothamBold, TextSize = 15, Size = UDim2.new(1, -110, 1, 0), Position = UDim2.fromOffset(16, 0), Parent = top }), "TextColor3", "text")
	local function topButton(glyph, x)
		local b = new("TextButton", { Text = glyph, Font = Enum.Font.GothamBold, TextSize = 14, AutoButtonColor = false, Size = UDim2.fromOffset(26, 26), Position = UDim2.new(1, x, 0, 7), Parent = top }, { round(8) })
		paint(b, "BackgroundColor3", "card") paint(b, "TextColor3", "sub")
		return b
	end
	local closeB, minB = topButton("×", -36), topButton("–", -66)

	local side = new("ScrollingFrame", { Name = "Side", Size = UDim2.new(0, 150, 1, -48), Position = UDim2.fromOffset(8, 40), ScrollBarThickness = 0, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, BorderSizePixel = 0, Parent = main },
		{ round(10), pad(6), new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }) })
	paint(side, "BackgroundColor3", "side")
	local pages = new("Frame", { Name = "Pages", BackgroundTransparency = 1, Size = UDim2.new(1, -174, 1, -48), Position = UDim2.fromOffset(166, 40), Parent = main })
	local grip = new("TextButton", { Text = "", AutoButtonColor = false, BackgroundTransparency = 1, Size = UDim2.fromOffset(18, 18), Position = UDim2.new(1, -18, 1, -18), ZIndex = 5, Parent = main })
	local gripDot = new("Frame", { Size = UDim2.fromOffset(8, 8), Position = UDim2.fromOffset(5, 5), Parent = grip }, { round(4) })
	paint(gripDot, "BackgroundColor3", "line")

	-- drag (title bar) and resize (corner grip)
	local mode, startPos, startMouse, startSize
	table.insert(lib.conns, top.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then mode, startMouse, startPos = "drag", i.Position, main.Position end
	end))
	table.insert(lib.conns, grip.InputBegan:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then mode, startMouse, startSize = "size", i.Position, main.AbsoluteSize end
	end))
	table.insert(lib.conns, UIS.InputChanged:Connect(function(i)
		if not mode or (i.UserInputType ~= Enum.UserInputType.MouseMovement and i.UserInputType ~= Enum.UserInputType.Touch) then return end
		local d = i.Position - startMouse
		if mode == "drag" then
			main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
		else
			main.Size = UDim2.fromOffset(math.max(MIN.X, startSize.X + d.X), math.max(MIN.Y, startSize.Y + d.Y))
		end
	end))
	table.insert(lib.conns, UIS.InputEnded:Connect(function(i)
		if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then mode = nil end
	end))
	local minimised, fullSize = false, nil
	minB.MouseButton1Click:Connect(function()
		minimised = not minimised
		if minimised then fullSize = main.Size tween(main, 0.18, { Size = UDim2.fromOffset(main.AbsoluteSize.X, 40) })
		else tween(main, 0.18, { Size = fullSize }) end
		side.Visible, pages.Visible, grip.Visible = not minimised, not minimised, not minimised
	end)
	closeB.MouseButton1Click:Connect(function() main.Visible = false lib:Notification("Hidden", "Press " .. lib.ToggleKey.Name .. " to show it again.", nil, nil, 4) end)
	table.insert(lib.conns, UIS.InputBegan:Connect(function(i, gp)
		if not gp and i.KeyCode == lib.ToggleKey then main.Visible = not main.Visible end
	end))

	local win, order, firstTab = {}, 0, nil
	local function nextOrder() order += 1 return order end
	function win:Label(t)
		local l = text({ Text = string.upper(t), Font = Enum.Font.GothamBold, TextSize = 11, Size = UDim2.new(1, 0, 0, 20), LayoutOrder = nextOrder(), Parent = side })
		paint(l, "TextColor3", "sub")
	end
	local allTabs = {}
	function win:Tab(name, icon, color)
		local b = new("TextButton", { Text = "", AutoButtonColor = false, Size = UDim2.new(1, 0, 0, 32), LayoutOrder = nextOrder(), Parent = side }, { round(8) })
		b.BackgroundColor3 = theme.side b.BackgroundTransparency = 1
		local dot = new("Frame", { BackgroundColor3 = color or theme.accent, Size = UDim2.fromOffset(24, 24), Position = UDim2.fromOffset(4, 4), Parent = b }, { round(7) })
		if icon and icon ~= "" then new("ImageLabel", { BackgroundTransparency = 1, Image = icon, ImageColor3 = Color3.new(1, 1, 1), Size = UDim2.fromOffset(16, 16), Position = UDim2.fromOffset(4, 4), Parent = dot }) end
		paint(text({ Text = name, Size = UDim2.new(1, -38, 1, 0), Position = UDim2.fromOffset(36, 0), Parent = b }), "TextColor3", "text")
		local page = new("ScrollingFrame", { Visible = false, BackgroundTransparency = 1, BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), ScrollBarThickness = 3, CanvasSize = UDim2.new(), AutomaticCanvasSize = Enum.AutomaticSize.Y, Parent = pages },
			{ new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }), new("UIPadding", { PaddingRight = UDim.new(0, 6), PaddingBottom = UDim.new(0, 8) }) })
		paint(page, "ScrollBarImageColor3", "line")
		local tabObj = { page = page, button = b, color = color }
		table.insert(allTabs, tabObj)
		local function select()
			for _, t in ipairs(allTabs) do t.page.Visible = (t == tabObj) t.button.BackgroundTransparency = (t == tabObj) and 0 or 1 t.button.BackgroundColor3 = theme.card end
		end
		b.MouseButton1Click:Connect(select)
		if not firstTab then firstTab = tabObj select() end
		tabObj.Select = select

		local n = 0
		local function row(h)
			n += 1
			local f = new("Frame", { Size = UDim2.new(1, 0, 0, h or 36), LayoutOrder = n, Parent = page }, { round(8) })
			paint(f, "BackgroundColor3", "card")
			return f
		end
		local function caption(f, t, w)
			local l = text({ Text = t, Size = UDim2.new(1, -(w or 0) - 24, 1, 0), Position = UDim2.fromOffset(12, 0), Parent = f })
			paint(l, "TextColor3", "text")
			return l
		end
		local accent = color or theme.accent

		function tabObj:Line(t)
			n += 1
			local f = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 24), LayoutOrder = n, Parent = page })
			paint(text({ Text = t, Font = Enum.Font.GothamBold, TextSize = 12, Size = UDim2.new(1, 0, 1, 0), Position = UDim2.fromOffset(2, 2), Parent = f }), "TextColor3", "sub")
			return f
		end
		function tabObj:Button(t, cb)
			local f = row()
			local b2 = new("TextButton", { Text = "", AutoButtonColor = false, BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = f })
			caption(f, t)
			b2.MouseEnter:Connect(function() tween(f, 0.1, { BackgroundColor3 = theme.cardHover }) end)
			b2.MouseLeave:Connect(function() tween(f, 0.1, { BackgroundColor3 = theme.card }) end)
			b2.MouseButton1Click:Connect(function() task.spawn(cb) end)
			return { Instance = f }
		end
		function tabObj:Label(t)
			local f = row(nil)
			f.AutomaticSize = Enum.AutomaticSize.Y
			local l = text({ Text = t, TextWrapped = true, TextTruncate = Enum.TextTruncate.None, RichText = true, Size = UDim2.new(1, -24, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Position = UDim2.fromOffset(12, 0), Parent = f }, nil)
			new("UIPadding", { PaddingTop = UDim.new(0, 10), PaddingBottom = UDim.new(0, 10), Parent = f })
			l.TextColor3 = theme.text
			local o = { inst = l, Instance = f }
			function o:SetText(s) l.Text = tostring(s) end
			function o:SetColor(c) o.custom = true l.TextColor3 = c end
			table.insert(labels, o)
			return o
		end
		function tabObj:Toggle(t, default, cb, flag)
			local f = row()
			caption(f, t, 44)
			local box = new("TextButton", { Text = "", AutoButtonColor = false, Size = UDim2.fromOffset(40, 22), Position = UDim2.new(1, -52, 0.5, -11), Parent = f }, { round(11) })
			local knob = new("Frame", { BackgroundColor3 = Color3.new(1, 1, 1), Size = UDim2.fromOffset(16, 16), Parent = box }, { round(8) })
			local o, state = { Instance = f }, false
			local function draw() tween(box, 0.12, { BackgroundColor3 = state and accent or theme.line }) tween(knob, 0.12, { Position = state and UDim2.fromOffset(21, 3) or UDim2.fromOffset(3, 3) }) end
			function o:Set(v, silent) state = v and true or false draw() if flag then lib.Flags[flag] = state end if not silent and cb then task.spawn(cb, state) end end
			function o:Get() return state end
			box.MouseButton1Click:Connect(function() o:Set(not state) end)
			o:Set(default, true)
			return o
		end
		function tabObj:Slider(t, decimals, min, max, default, cb, flag)
			local f = row(50)
			caption(f, t, 60).Size = UDim2.new(1, -84, 0, 26)
			local val = text({ Text = "", TextXAlignment = Enum.TextXAlignment.Right, Size = UDim2.fromOffset(60, 26), Position = UDim2.new(1, -72, 0, 0), Parent = f })
			paint(val, "TextColor3", "sub")
			local bar = new("TextButton", { Text = "", AutoButtonColor = false, Size = UDim2.new(1, -24, 0, 6), Position = UDim2.fromOffset(12, 32), Parent = f }, { round(3) })
			paint(bar, "BackgroundColor3", "line")
			local fill = new("Frame", { BackgroundColor3 = accent, Size = UDim2.fromScale(0, 1), Parent = bar }, { round(3) })
			local o, value, dragging = { Instance = f }, default, false
			local step = (decimals == true and 0.1) or (type(decimals) == "number" and decimals > 0 and 10 ^ -decimals) or 1
			function o:Set(v, silent)
				v = math.clamp(math.floor(v / step + 0.5) * step, min, max)
				value = v
				fill.Size = UDim2.fromScale((v - min) / math.max(max - min, 1e-9), 1)
				val.Text = (step < 1) and string.format("%.2f", v) or tostring(math.floor(v))
				if flag then lib.Flags[flag] = v end
				if not silent and cb then task.spawn(cb, v) end
			end
			function o:Get() return value end
			local function at(x) o:Set(min + (max - min) * math.clamp((x - bar.AbsolutePosition.X) / bar.AbsoluteSize.X, 0, 1)) end
			bar.InputBegan:Connect(function(i) if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then dragging = true at(i.Position.X) end end)
			table.insert(lib.conns, UIS.InputChanged:Connect(function(i) if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then at(i.Position.X) end end))
			table.insert(lib.conns, UIS.InputEnded:Connect(function(i) if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then dragging = false end end))
			o:Set(default, true)
			return o
		end
		function tabObj:Bind(t, key, hold, _, cb)
			local f = row()
			caption(f, t, 110)
			local b2 = new("TextButton", { Font = Enum.Font.GothamMedium, TextSize = 12, AutoButtonColor = false, Size = UDim2.fromOffset(100, 24), Position = UDim2.new(1, -112, 0.5, -12), Parent = f }, { round(6) })
			paint(b2, "BackgroundColor3", "line") paint(b2, "TextColor3", "text")
			local o, cur, listening = { Instance = f }, key, false
			local function draw() b2.Text = cur and cur.Name or "None" end
			function o:Set(k) cur = k draw() end
			function o:Get() return cur end
			b2.MouseButton1Click:Connect(function() listening = true b2.Text = "..." end)
			table.insert(lib.conns, UIS.InputBegan:Connect(function(i, gp)
				if listening and i.UserInputType == Enum.UserInputType.Keyboard then listening = false cur = i.KeyCode draw() return end
				if not gp and cur and i.KeyCode == cur and cb then task.spawn(cb, hold and true or cur) end
			end))
			if hold then table.insert(lib.conns, UIS.InputEnded:Connect(function(i) if cur and i.KeyCode == cur and cb then task.spawn(cb, false) end end)) end
			draw()
			return o
		end
		function tabObj:Textbox(t, numbersOnly, clearOnFocus, cb)
			local f = row()
			caption(f, t, 150)
			local box = new("TextBox", { Text = "", PlaceholderText = "type…", ClearTextOnFocus = clearOnFocus and true or false, Font = Enum.Font.GothamMedium, TextSize = 12, Size = UDim2.fromOffset(140, 24), Position = UDim2.new(1, -152, 0.5, -12), Parent = f }, { round(6) })
			paint(box, "BackgroundColor3", "line") paint(box, "TextColor3", "text")
			local o = { Instance = f }
			function o:Set(v) box.Text = tostring(v) end
			function o:Get() return numbersOnly and tonumber(box.Text) or box.Text end
			box.FocusLost:Connect(function()
				if numbersOnly and not tonumber(box.Text) then box.Text = "" return end
				if cb then task.spawn(cb, o:Get()) end
			end)
			return o
		end
		local function choiceRow(t, options, cb, compact)
			local f = row(compact and 36 or 66)
			local l = caption(f, t)
			if not compact then l.Size = UDim2.new(1, -24, 0, 30) end
			local holder = new("Frame", { BackgroundTransparency = 1, Size = compact and UDim2.new(0.55, -12, 0, 24) or UDim2.new(1, -24, 0, 26), Position = compact and UDim2.new(0.45, 0, 0.5, -12) or UDim2.fromOffset(12, 30), Parent = f },
				{ new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0, 6), HorizontalAlignment = compact and Enum.HorizontalAlignment.Right or Enum.HorizontalAlignment.Left }) })
			local o, buttons, cur = { Instance = f }, {}, nil
			local function draw() for v, b2 in pairs(buttons) do b2.BackgroundColor3 = (v == cur) and accent or theme.line b2.TextColor3 = (v == cur) and Color3.new(1, 1, 1) or theme.text end end
			for _, v in ipairs(options) do
				local b2 = new("TextButton", { Text = tostring(v), Font = Enum.Font.GothamMedium, TextSize = 12, AutoButtonColor = false, AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(0, 24), Parent = holder },
					{ round(6), new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }) })
				buttons[v] = b2
				b2.MouseButton1Click:Connect(function() cur = v draw() if cb then task.spawn(cb, v) end end)
			end
			function o:Set(v, silent) cur = v draw() if not silent and cb then task.spawn(cb, v) end end
			function o:Get() return cur end
			draw()
			return o
		end
		function tabObj:RadioButtons(t, options, cb) return choiceRow(t, options, cb, false) end
		function tabObj:Dropdown(t, options, cb)
			local f = row()
			caption(f, t, 170)
			local b2 = new("TextButton", { Text = "Select", Font = Enum.Font.GothamMedium, TextSize = 12, AutoButtonColor = false, Size = UDim2.fromOffset(160, 24), Position = UDim2.new(1, -172, 0.5, -12), Parent = f }, { round(6) })
			paint(b2, "BackgroundColor3", "line") paint(b2, "TextColor3", "text")
			local list = new("Frame", { Visible = false, AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.new(1, 0, 0, 0), LayoutOrder = 0, Parent = page },
				{ round(8), pad(6), new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }) })
			paint(list, "BackgroundColor3", "side")
			n += 1 list.LayoutOrder = n
			local o, cur = { Instance = f }, nil
			local function fill(opts)
				for _, c in ipairs(list:GetChildren()) do if c:IsA("TextButton") then c:Destroy() end end
				for i, v in ipairs(opts) do
					local it = new("TextButton", { Text = "  " .. tostring(v), TextXAlignment = Enum.TextXAlignment.Left, Font = Enum.Font.GothamMedium, TextSize = 12, AutoButtonColor = false, Size = UDim2.new(1, 0, 0, 24), LayoutOrder = i, Parent = list }, { round(6) })
					it.BackgroundColor3 = theme.card it.TextColor3 = theme.text
					it.MouseButton1Click:Connect(function() o:Set(v) list.Visible = false end)
				end
			end
			function o:Set(v, silent) cur = v b2.Text = tostring(v) if not silent and cb then task.spawn(cb, v) end end
			function o:Get() return cur end
			function o:Refresh(opts) fill(opts) end
			b2.MouseButton1Click:Connect(function() list.Visible = not list.Visible end)
			fill(options)
			return o
		end
		function tabObj:Colorpicker(t, c, cb)
			local f = row(70)
			caption(f, t).Size = UDim2.new(1, -24, 0, 28)
			local sw = new("Frame", { BackgroundColor3 = c, Size = UDim2.fromOffset(28, 18), Position = UDim2.new(1, -40, 0, 5), Parent = f }, { round(5) })
			local o, h, s, v = { Instance = f }, c:ToHSV()
			local bars = {}
			local function emit() local col = Color3.fromHSV(h, s, v) sw.BackgroundColor3 = col if cb then task.spawn(cb, col) end end
			for i, key in ipairs({ "h", "s", "v" }) do
				local bar = new("TextButton", { Text = "", AutoButtonColor = false, Size = UDim2.new(1 / 3, -14, 0, 8), Position = UDim2.new((i - 1) / 3, 12, 0, 44), Parent = f }, { round(4) })
				paint(bar, "BackgroundColor3", "line")
				local fl = new("Frame", { BackgroundColor3 = accent, Size = UDim2.fromScale(key == "h" and h or key == "s" and s or v, 1), Parent = bar }, { round(4) })
				bars[key] = fl
				bar.MouseButton1Down:Connect(function(x)
					local r = math.clamp((x - bar.AbsolutePosition.X) / bar.AbsoluteSize.X, 0, 1)
					if key == "h" then h = r elseif key == "s" then s = r else v = r end
					fl.Size = UDim2.fromScale(r, 1) emit()
				end)
			end
			function o:Set(col) h, s, v = col:ToHSV() bars.h.Size, bars.s.Size, bars.v.Size = UDim2.fromScale(h, 1), UDim2.fromScale(s, 1), UDim2.fromScale(v, 1) emit() end
			function o:Get() return Color3.fromHSV(h, s, v) end
			return o
		end
		-- reorderable list: items = { {id=, name=}, ... }; cb(listOfIds) after every move
		function tabObj:Order(t, items, cb)
			local f = row(36)
			f.AutomaticSize = Enum.AutomaticSize.Y
			local l = caption(f, t) l.Size = UDim2.new(1, -24, 0, 30)
			local holder = new("Frame", { BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.Y, Size = UDim2.new(1, -24, 0, 0), Position = UDim2.fromOffset(12, 30), Parent = f },
				{ new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }), new("UIPadding", { PaddingBottom = UDim.new(0, 8) }) })
			local o, list = { Instance = f }, {}
			for _, it in ipairs(items) do table.insert(list, it) end
			local function ids() local r = {} for _, it in ipairs(list) do table.insert(r, it.id) end return r end
			local draw
			local function move(i, d)
				local j = i + d
				if j < 1 or j > #list then return end
				list[i], list[j] = list[j], list[i]
				draw() if cb then task.spawn(cb, ids()) end
			end
			draw = function()
				for _, c in ipairs(holder:GetChildren()) do if c:IsA("Frame") then c:Destroy() end end
				for i, it in ipairs(list) do
					local r = new("Frame", { Size = UDim2.new(1, 0, 0, 26), LayoutOrder = i, Parent = holder }, { round(6) })
					r.BackgroundColor3 = theme.side
					local nl = text({ Text = i .. ".  " .. it.name, Size = UDim2.new(1, -70, 1, 0), Position = UDim2.fromOffset(10, 0), Parent = r })
					nl.TextColor3 = theme.text
					for k, g in ipairs({ { "▲", -1 }, { "▼", 1 } }) do
						local b2 = new("TextButton", { Text = g[1], Font = Enum.Font.GothamBold, TextSize = 10, AutoButtonColor = false, Size = UDim2.fromOffset(26, 20), Position = UDim2.new(1, -60 + (k - 1) * 30, 0, 3), Parent = r }, { round(5) })
						b2.BackgroundColor3 = theme.line b2.TextColor3 = theme.text
						b2.MouseButton1Click:Connect(function() move(i, g[2]) end)
					end
				end
			end
			function o:Set(order)
				local byId = {} for _, it in ipairs(items) do byId[it.id] = it end
				local seen, nl = {}, {}
				for _, id in ipairs(order or {}) do if byId[id] and not seen[id] then table.insert(nl, byId[id]) seen[id] = true end end
				for _, it in ipairs(items) do if not seen[it.id] then table.insert(nl, it) end end
				list = nl draw()
			end
			function o:Get() return ids() end
			draw()
			return o
		end
		return tabObj
	end
	function win:SelectTab(i) if allTabs[i] then allTabs[i].Select() end end
	return win
end

-- old global helpers
getgenv = getgenv or function() return _G end
getgenv().ChangeLabelText = function(part, new)
	for _, l in ipairs(labels) do if string.find(l.inst.Text, part, 1, true) then l.inst.Text = new return end end
end
getgenv().ChangeLabelColor = function(t, r, g, b)
	for _, l in ipairs(labels) do if string.find(l.inst.Text, t, 1, true) then l.custom = true l.inst.TextColor3 = Color3.fromRGB(r, g, b) end end
end
getgenv().ResetLabelColor = function()
	for _, l in ipairs(labels) do l.custom = false l.inst.TextColor3 = theme.text end
end

return lib
