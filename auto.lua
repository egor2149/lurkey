-- MM2 coin auto-farm: one switch and a mode selector.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
local PLACE_ID = 142823291
local MAX_SPEED = 25 -- studs/s; hard cap for every scripted move

local CFG = {
	speed = MAX_SPEED, -- studs/s, clamped to MAX_SPEED
	diveDepth = 25, -- studs under the floor in dive mode
	touchTime = 1, -- max seconds to wait on a coin for the server to register it
	retryAfter = 20, -- seconds before a missed coin is tried again
	missLimit = 4, -- consecutive misses treated as a full bag when bag counts are unavailable
	mapMargin = 60, -- studs outside the map bounds that still count as "on the map"
}

local ENV
do
	local ok, env = pcall(function() return getgenv() end)
	if ok and type(env) == "table" then ENV = env end
end

---------------------------------------------------------------------------
-- Antifling, always on and silent. Same idea as Infinite Yield's antifling
-- (other characters never collide with us), but parts are cached per
-- character instead of rescanning every character on every step. A velocity
-- guard also cancels spin/launch that still reaches our root part.
---------------------------------------------------------------------------
local stopAntiFling
do
	local parts = setmetatable({}, { __mode = "k" })
	local charConns = setmetatable({}, { __mode = "k" })
	local conns = {}
	local MAX_SPIN, MAX_PUSH = 40, 90 -- rad/s, horizontal studs/s; walking is 16

	local function addPart(part)
		if part:IsA("BasePart") then parts[part] = true end
	end
	local function removePart(part)
		parts[part] = nil
	end
	local function watchCharacter(char)
		if charConns[char] then return end
		for _, d in ipairs(char:GetDescendants()) do addPart(d) end
		charConns[char] = {
			char.DescendantAdded:Connect(addPart),
			char.DescendantRemoving:Connect(removePart),
		}
	end
	local function unwatchCharacter(char)
		for _, c in ipairs(charConns[char] or {}) do c:Disconnect() end
		charConns[char] = nil
		for part in pairs(parts) do
			if not part.Parent or part:IsDescendantOf(char) then parts[part] = nil end
		end
	end
	local function watchPlayer(player)
		if player == LocalPlayer then return end
		if player.Character then watchCharacter(player.Character) end
		conns[#conns + 1] = player.CharacterAdded:Connect(watchCharacter)
		conns[#conns + 1] = player.CharacterRemoving:Connect(unwatchCharacter)
	end

	for _, player in ipairs(Players:GetPlayers()) do watchPlayer(player) end
	conns[#conns + 1] = Players.PlayerAdded:Connect(watchPlayer)
	-- humanoids turn collisions back on, so this has to run every step
	conns[#conns + 1] = RunService.Stepped:Connect(function()
		for part in pairs(parts) do
			if part.CanCollide then part.CanCollide = false end
		end
	end)
	conns[#conns + 1] = RunService.Heartbeat:Connect(function()
		local char = LocalPlayer.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if not root or root.Anchored then return end
		local v = root.AssemblyLinearVelocity
		if root.AssemblyAngularVelocity.Magnitude > MAX_SPIN or Vector3.new(v.X, 0, v.Z).Magnitude > MAX_PUSH then
			root.AssemblyAngularVelocity = Vector3.zero
			root.AssemblyLinearVelocity = Vector3.new(0, math.min(v.Y, 0), 0)
		end
	end)

	function stopAntiFling()
		for _, c in ipairs(conns) do c:Disconnect() end
		table.clear(conns)
		for char in pairs(charConns) do unwatchCharacter(char) end
		if ENV and ENV.MM2_ANTIFLING == stopAntiFling then ENV.MM2_ANTIFLING = nil end
	end
	if ENV then
		if type(ENV.MM2_ANTIFLING) == "function" then pcall(ENV.MM2_ANTIFLING) end
		ENV.MM2_ANTIFLING = stopAntiFling
	end
end

---------------------------------------------------------------------------
-- Built-in UI: one draggable window with a toggle, a segmented selector and
-- text rows. No external code is downloaded.
---------------------------------------------------------------------------
local UI = {}
do
	local UserInputService = game:GetService("UserInputService")
	local TweenService = game:GetService("TweenService")
	local CoreGui = game:GetService("CoreGui")
	local GUI_NAME = "MM2CollectUI"

	local C = {
		bg = Color3.fromRGB(24, 24, 28),
		header = Color3.fromRGB(32, 32, 38),
		row = Color3.fromRGB(34, 34, 40),
		track = Color3.fromRGB(58, 58, 66),
		accent = Color3.fromRGB(255, 184, 48),
		text = Color3.fromRGB(235, 235, 240),
		muted = Color3.fromRGB(150, 150, 160),
		onAccent = Color3.fromRGB(28, 22, 8),
	}
	local FONT, FONT_BOLD = Enum.Font.Gotham, Enum.Font.GothamBold
	local WIDTH, PAD, ROW = 320, 10, 36

	local function make(class, props, parent)
		local inst = Instance.new(class)
		for k, v in pairs(props) do inst[k] = v end
		inst.Parent = parent
		return inst
	end
	local function corner(parent, radius)
		make("UICorner", { CornerRadius = UDim.new(0, radius or 6) }, parent)
	end
	local function text(parent, props)
		local base = {
			BackgroundTransparency = 1, Font = FONT, TextSize = 14, TextColor3 = C.text,
			TextXAlignment = Enum.TextXAlignment.Left, TextWrapped = true, Text = "",
		}
		for k, v in pairs(props) do base[k] = v end
		return make("TextLabel", base, parent)
	end
	local function tween(inst, props, t)
		TweenService:Create(inst, TweenInfo.new(t or 0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props):Play()
	end
	local function guiParent()
		local ok, gui = pcall(function()
			if type(gethui) == "function" then return gethui() end
			return CoreGui
		end)
		if ok and gui then return gui end
		return LocalPlayer:WaitForChild("PlayerGui")
	end

	local Window = {}
	Window.__index = Window

	function UI.CreateWindow(opts)
		local parent = guiParent()
		local old = parent:FindFirstChild(GUI_NAME)
		if old then old:Destroy() end -- fires the previous instance's cleanup through Destroying

		local self = setmetatable({ resources = {}, alive = true, rows = 0 }, Window)
		local gui = make("ScreenGui", { Name = GUI_NAME, ResetOnSpawn = false, ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
			DisplayOrder = 999 }, nil)
		pcall(function() gui.IgnoreGuiInset = true end)
		self.gui = gui

		local frame = make("Frame", { Name = "Window", BackgroundColor3 = C.bg, BorderSizePixel = 0,
			Position = UDim2.new(0, 24, 0.5, -140), Size = UDim2.fromOffset(WIDTH, 100), Active = true }, gui)
		corner(frame, 10)
		make("UIStroke", { Color = Color3.fromRGB(60, 60, 70), Thickness = 1 }, frame)
		self.frame = frame

		local header = make("Frame", { Name = "Header", BackgroundColor3 = C.header, BorderSizePixel = 0,
			Size = UDim2.new(1, 0, 0, 40) }, frame)
		corner(header, 10)
		make("Frame", { BackgroundColor3 = C.header, BorderSizePixel = 0, Position = UDim2.new(0, 0, 1, -10),
			Size = UDim2.new(1, 0, 0, 10) }, header)
		text(header, { Text = opts.Title or "", Font = FONT_BOLD, TextSize = 15, Position = UDim2.fromOffset(PAD + 2, 4),
			Size = UDim2.new(1, -120, 0, 20) })
		text(header, { Text = opts.Subtitle or "", TextSize = 12, TextColor3 = C.muted, Position = UDim2.fromOffset(PAD + 2, 22),
			Size = UDim2.new(1, -120, 0, 14) })
		local hint = text(header, { Text = "", TextSize = 11, TextColor3 = C.muted, TextXAlignment = Enum.TextXAlignment.Right,
			Position = UDim2.new(1, -96, 0, 0), Size = UDim2.fromOffset(60, 40) })
		local close = make("TextButton", { Text = "×", Font = FONT_BOLD, TextSize = 20, TextColor3 = C.muted,
			BackgroundTransparency = 1, Position = UDim2.new(1, -34, 0, 6), Size = UDim2.fromOffset(28, 28), AutoButtonColor = false }, header)
		close.MouseEnter:Connect(function() close.TextColor3 = C.text end)
		close.MouseLeave:Connect(function() close.TextColor3 = C.muted end)
		close.Activated:Connect(function() self:Destroy() end)

		local body = make("Frame", { Name = "Body", BackgroundTransparency = 1, Position = UDim2.fromOffset(PAD, 48),
			Size = UDim2.new(1, -PAD * 2, 1, -56) }, frame)
		make("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, body)
		self.body = body

		-- dragging by the header, mouse and touch
		local dragStart, frameStart
		header.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				dragStart, frameStart = input.Position, frame.Position
			end
		end)
		header.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				dragStart = nil
			end
		end)
		self:Give(UserInputService.InputChanged:Connect(function(input)
			if dragStart and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
				local d = input.Position - dragStart
				frame.Position = UDim2.new(frameStart.X.Scale, frameStart.X.Offset + d.X, frameStart.Y.Scale, frameStart.Y.Offset + d.Y)
			end
		end))

		-- show/hide key
		local key = opts.ToggleKey
		if key then
			hint.Text = key.Name
			self:Give(UserInputService.InputBegan:Connect(function(input, processed)
				if not processed and input.KeyCode == key then frame.Visible = not frame.Visible end
			end))
		end

		gui.Destroying:Connect(function() self:Destroy() end)
		gui.Parent = parent
		self:_Resize()
		return self
	end

	function Window:_Resize()
		local h = 48 + self.rows * (ROW + 6) + 8
		self.frame.Size = UDim2.fromOffset(WIDTH, h)
	end

	function Window:_Row(height)
		self.rows += 1
		local row = make("Frame", { BackgroundColor3 = C.row, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, height or ROW),
			LayoutOrder = self.rows }, self.body)
		corner(row, 6)
		self:_Resize()
		return row
	end

	function Window:Toggle(opts)
		local row = self:_Row()
		text(row, { Text = opts.Text or "", Position = UDim2.fromOffset(PAD, 0), Size = UDim2.new(1, -80, 1, 0) })
		local track = make("TextButton", { Text = "", BackgroundColor3 = C.track, AutoButtonColor = false,
			AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -PAD, 0.5, 0), Size = UDim2.fromOffset(44, 24) }, row)
		corner(track, 12)
		local knob = make("Frame", { BackgroundColor3 = C.text, Position = UDim2.fromOffset(3, 3), Size = UDim2.fromOffset(18, 18) }, track)
		corner(knob, 9)
		local value = opts.Default == true
		local function render(animate)
			local t = animate and 0.15 or 0
			tween(track, { BackgroundColor3 = value and C.accent or C.track }, t)
			tween(knob, { Position = UDim2.fromOffset(value and 23 or 3, 3), BackgroundColor3 = value and C.onAccent or C.text }, t)
		end
		local control = {}
		function control:Set(v, silent)
			v = v == true
			if v == value then return end
			value = v
			render(true)
			if not silent and opts.Callback then task.spawn(opts.Callback, value) end
		end
		function control:Get() return value end
		track.Activated:Connect(function() control:Set(not value) end)
		render(false)
		return control
	end

	function Window:Segmented(opts)
		local row = self:_Row()
		text(row, { Text = opts.Text or "", Position = UDim2.fromOffset(PAD, 0), Size = UDim2.new(0, 90, 1, 0) })
		local options = opts.Options or {}
		local holder = make("Frame", { BackgroundColor3 = C.track, AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -PAD, 0.5, 0), Size = UDim2.new(1, -(PAD * 2 + 90), 0, 26) }, row)
		corner(holder, 6)
		local buttons = {}
		local value = opts.Default or options[1]
		local n = #options
		local function render()
			for i, b in ipairs(buttons) do
				local on = options[i] == value
				tween(b, { BackgroundColor3 = on and C.accent or C.track, TextColor3 = on and C.onAccent or C.muted })
			end
		end
		local control = {}
		function control:Set(v, silent)
			if v == value then return end
			value = v
			render()
			if not silent and opts.Callback then task.spawn(opts.Callback, value) end
		end
		function control:Get() return value end
		for i, option in ipairs(options) do
			local b = make("TextButton", { Text = option, Font = FONT, TextSize = 13, TextColor3 = C.muted, AutoButtonColor = false,
				BackgroundColor3 = C.track, Position = UDim2.new((i - 1) / n, 2, 0, 2), Size = UDim2.new(1 / n, -4, 1, -4), BorderSizePixel = 0 }, holder)
			corner(b, 5)
			b.Activated:Connect(function() control:Set(option) end)
			buttons[i] = b
		end
		render()
		return control
	end

	function Window:Label(opts)
		local row = self:_Row()
		local label = text(row, { Text = opts.Text or "", TextSize = 13, Position = UDim2.fromOffset(PAD, 0), Size = UDim2.new(1, -PAD * 2, 1, 0) })
		local control = {}
		function control:SetText(t)
			if label.Text ~= t then label.Text = t end
		end
		return control
	end

	-- Resources (connections, threads, functions) released when the window closes.
	function Window:Give(resource)
		if not self.alive then
			self:_Dispose(resource)
			return
		end
		self.resources[#self.resources + 1] = resource
	end
	function Window:OnDestroy(fn) self:Give(fn) end
	function Window:_Dispose(r)
		local kind = typeof(r)
		if kind == "function" then r()
		elseif kind == "RBXScriptConnection" then r:Disconnect()
		elseif kind == "thread" then task.cancel(r)
		elseif kind == "Instance" then r:Destroy()
		end
	end
	function Window:Destroy()
		if not self.alive then return end
		self.alive = false
		local list = self.resources
		self.resources = {}
		for i = #list, 1, -1 do pcall(self._Dispose, self, list[i]) end
		if self.gui.Parent then self.gui:Destroy() end
	end
end

-- Creating the window destroys a previous instance's window, which runs that
-- instance's cleanup before we claim the character.
local window = UI.CreateWindow({
	Title = "MM2 Collect",
	Subtitle = "автофарм монет",
	ToggleKey = Enum.KeyCode.RightShift,
})

local TOKEN = {}
if ENV then ENV.MM2_TOKEN = TOKEN end

local function stillOwner()
	return not ENV or ENV.MM2_TOKEN == TOKEN
end

local function giveToWindow(resource)
	window:Give(resource)
end

---------------------------------------------------------------------------
-- Memory: what the farm learns per map, saved between sessions when the
-- executor has writefile. Positions are stored relative to the map pivot.
---------------------------------------------------------------------------
local Memory = {}
do
	local FILE = "mm2_collect_memory.json"
	local SPOT, ZONE = 6, 16
	local MAX_SPOTS, MAX_MAPS = 300, 30
	local canSave = type(readfile) == "function" and type(writefile) == "function"
	local data = { maps = {}, rounds = 0, coins = 0 }
	local dirty, lastSave = false, 0

	Memory.persistent = canSave

	local function key(p, size)
		return string.format("%d,%d,%d", math.floor(p.X / size), math.floor(p.Y / size), math.floor(p.Z / size))
	end

	local function center(k)
		local x, y, z = string.match(k, "^(-?%d+),(-?%d+),(-?%d+)$")
		if not x then return nil end
		return Vector3.new((tonumber(x) + 0.5) * SPOT, (tonumber(y) + 0.5) * SPOT, (tonumber(z) + 0.5) * SPOT)
	end

	if canSave then
		local ok, raw = pcall(readfile, FILE)
		if ok and type(raw) == "string" and raw ~= "" then
			local okJson, decoded = pcall(function() return HttpService:JSONDecode(raw) end)
			if okJson and type(decoded) == "table" and type(decoded.maps) == "table" then
				data = decoded
				data.rounds = tonumber(data.rounds) or 0
				data.coins = tonumber(data.coins) or 0
			end
		end
	end

	function Memory.map(name)
		local m = data.maps[name]
		if type(m) ~= "table" then
			m = {}
			data.maps[name] = m
		end
		m.spots = type(m.spots) == "table" and m.spots or {}
		m.zones = type(m.zones) == "table" and m.zones or {}
		m.rounds = tonumber(m.rounds) or 0
		m.avg = tonumber(m.avg)
		m.seen = os.time()
		dirty = true
		return m
	end

	local function spot(m, p)
		local k = key(p, SPOT)
		local s = m.spots[k]
		if type(s) ~= "table" then
			s = { s = 0, h = 0, m = 0 }
			m.spots[k] = s
		end
		return s
	end

	function Memory.spawned(m, p)
		local s = spot(m, p)
		s.s = (s.s or 0) + 1
		dirty = true
	end

	function Memory.result(m, p, hit)
		local s = spot(m, p)
		if hit then s.h = (s.h or 0) + 1 else s.m = (s.m or 0) + 1 end
		dirty = true
	end

	function Memory.died(m, p)
		local k = key(p, ZONE)
		m.zones[k] = (tonumber(m.zones[k]) or 0) + 1
		dirty = true
	end

	-- >= 1: spots that keep failing and places we died at are visited last, never skipped.
	function Memory.penalty(m, p)
		local penalty = 1
		local s = m.spots[key(p, SPOT)]
		if type(s) == "table" and (s.m or 0) > 0 then
			penalty += math.min(3, s.m / ((s.h or 0) + 1))
		end
		return penalty + math.min(3, tonumber(m.zones[key(p, ZONE)]) or 0)
	end

	-- Most frequent coin spawn spot, nearby ones preferred.
	function Memory.hotspot(m, from)
		local best, bestScore
		for k, s in pairs(m.spots) do
			if type(s) == "table" and (s.s or 0) >= 3 then
				local c = center(k)
				if c then
					local score = s.s / (1 + (c - from).Magnitude / 100)
					if not bestScore or score > bestScore then best, bestScore = c, score end
				end
			end
		end
		return best
	end

	function Memory.roundEnded(m, coins)
		m.rounds += 1
		m.avg = m.avg and (m.avg * 0.7 + coins * 0.3) or coins
		data.rounds += 1
		data.coins += coins
		for k, v in pairs(m.zones) do
			v = (tonumber(v) or 0) * 0.8
			m.zones[k] = v >= 0.2 and v or nil
		end
		dirty = true
	end

	local function prune()
		local names = {}
		for name, m in pairs(data.maps) do
			if type(m) == "table" then names[#names + 1] = name else data.maps[name] = nil end
		end
		table.sort(names, function(a, b) return (data.maps[a].seen or 0) > (data.maps[b].seen or 0) end)
		for i = MAX_MAPS + 1, #names do data.maps[names[i]] = nil end
		for _, m in pairs(data.maps) do
			local keys = {}
			for k in pairs(m.spots or {}) do keys[#keys + 1] = k end
			if #keys > MAX_SPOTS then
				local function weight(k)
					local s = m.spots[k]
					return type(s) == "table" and (s.s or 0) + (s.h or 0) + (s.m or 0) or 0
				end
				table.sort(keys, function(a, b) return weight(a) > weight(b) end)
				for i = MAX_SPOTS + 1, #keys do m.spots[keys[i]] = nil end
			end
		end
	end

	function Memory.save(force)
		if not canSave or not dirty then return end
		if not force and os.clock() - lastSave < 30 then return end
		lastSave = os.clock()
		prune()
		local ok, json = pcall(function() return HttpService:JSONEncode(data) end)
		if ok and pcall(writefile, FILE, json) then dirty = false end
	end

	function Memory.stats()
		local maps, spots = 0, 0
		for _, m in pairs(data.maps) do
			maps += 1
			for _ in pairs(m.spots or {}) do spots += 1 end
		end
		return maps, spots
	end
end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------
local state = {
	running = true,
	parking = false,
	mode = "normal", -- "normal" | "dive"
	phase = "",
	map = nil,
	pivot = nil,
	mem = nil,
	roundDone = nil, -- "bag_full" | "dead": sit out the rest of the round
	roundCoins = 0,
	totalCoins = 0,
	misses = 0,
	safeSpot = nil,
	cooldownUntil = 0,
	lastError = nil,
}

local retryAt = setmetatable({}, { __mode = "k" })
local firstPos = setmetatable({}, { __mode = "k" })
local hadVisual = setmetatable({}, { __mode = "k" })
local seenCoin = setmetatable({}, { __mode = "k" })
local boundsCache = setmetatable({}, { __mode = "k" })

local PHASE_TEXT = {
	off = "выключено",
	waiting = "ждём раунд",
	farming = "сбор монет",
	no_coins = "ждём новые монеты",
	bag_full = "мешок полон — ждём следующий раунд",
	dead = "персонаж погиб — ждём следующий раунд",
	wrong_game = "это не MM2",
	error = "ошибка",
}

local function setPhase(phase)
	if state.phase ~= phase then
		state.phase = phase
		print("[MM2] " .. (PHASE_TEXT[phase] or phase))
	end
end

local function toLocal(pos)
	return state.pivot and state.pivot:PointToObjectSpace(pos) or pos
end

local function toWorld(pos)
	return state.pivot and state.pivot:PointToWorldSpace(pos) or pos
end

local function getChar()
	local char = LocalPlayer.Character
	if not char then return nil end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if not hum or not hrp or hum.Health <= 0 then return nil end
	return char, hum, hrp
end

---------------------------------------------------------------------------
-- Flight controller. The root part stays unanchored: an anchored root stops
-- replicating its position, so the server never sees you reach the coins.
---------------------------------------------------------------------------
local ctrl = {
	engaged = false,
	pos = nil, -- where we keep the root part
	target = nil,
	rot = CFrame.identity,
	displaced = false,
	diedAt = nil,
	collide = setmetatable({}, { __mode = "k" }),
}

local function release()
	if not ctrl.engaged then return end
	ctrl.engaged = false
	ctrl.target = nil
	for part, original in pairs(ctrl.collide) do
		if part.Parent then pcall(function() part.CanCollide = original end) end
	end
	table.clear(ctrl.collide)
	local hum, hrp = ctrl.hum, ctrl.hrp
	pcall(function()
		if hrp.Parent then
			hrp.Anchored = false
			hrp.AssemblyLinearVelocity = Vector3.zero
		end
		if hum.Parent then
			hum.PlatformStand = false
			if ctrl.seat ~= nil then hum:SetStateEnabled(Enum.HumanoidStateType.Seated, ctrl.seat) end
			if hum.Health > 0 then hum:ChangeState(Enum.HumanoidStateType.Freefall) end
		end
	end)
end

local function engage(char, hum, hrp)
	if not stillOwner() then return false end
	if ENV and ENV.MM2_SURFACING then return false end -- the previous instance is still flying us out
	if ctrl.engaged then
		if ctrl.hrp == hrp then return true end
		release()
	end
	local _, yaw = hrp.CFrame:ToOrientation()
	ctrl.engaged = true
	ctrl.char, ctrl.hum, ctrl.hrp = char, hum, hrp
	ctrl.pos, ctrl.target = hrp.Position, nil
	ctrl.rot = CFrame.Angles(0, yaw, 0)
	ctrl.displaced = false
	pcall(function()
		hrp.Anchored = false
		ctrl.seat = hum:GetStateEnabled(Enum.HumanoidStateType.Seated)
		hum:SetStateEnabled(Enum.HumanoidStateType.Seated, false) -- flying through a seat would sit us down
		hum.Sit = false
		hum.PlatformStand = true
	end)
	return true
end

local connections = {}

-- Humanoids re-enable collisions every step, so noclip is reapplied each Stepped.
connections[#connections + 1] = RunService.Stepped:Connect(function()
	if not ctrl.engaged or not stillOwner() then return end
	local char = ctrl.char
	if not char or not char.Parent then return end
	for _, part in ipairs(char:GetDescendants()) do
		if part:IsA("BasePart") and part.CanCollide then
			if ctrl.collide[part] == nil then ctrl.collide[part] = true end
			part.CanCollide = false
		end
	end
end)

connections[#connections + 1] = RunService.Heartbeat:Connect(function(dt)
	if not ctrl.engaged then return end
	if not stillOwner() then
		ctrl.engaged = false -- a newer instance owns the character now
		return
	end
	local hrp, hum = ctrl.hrp, ctrl.hum
	if not hrp.Parent or not hum.Parent or hum.Health <= 0 then
		ctrl.diedAt = ctrl.pos
		release()
		return
	end
	if (hrp.Position - ctrl.pos).Magnitude > 12 then
		-- the game moved us (round-end teleport, respawn): hand control back
		ctrl.displaced = true
		release()
		return
	end
	local target = ctrl.target
	if target then
		local delta = target - ctrl.pos
		local step = math.min(CFG.speed, MAX_SPEED) * math.min(dt, 0.1)
		ctrl.pos = delta.Magnitude <= step and target or ctrl.pos + delta.Unit * step
	end
	hrp.AssemblyLinearVelocity = Vector3.zero
	hrp.AssemblyAngularVelocity = Vector3.zero
	hrp.CFrame = CFrame.new(ctrl.pos) * ctrl.rot
end)

---------------------------------------------------------------------------
-- World
---------------------------------------------------------------------------
local function findMap()
	local current = state.map
	if current and current.Parent then
		local cc = current:FindFirstChild("CoinContainer")
		if cc then return current, cc end
	end
	local fallback, fallbackCC
	for _, obj in ipairs(Workspace:GetChildren()) do
		if obj.Name ~= "Lobby" then
			local cc = obj:FindFirstChild("CoinContainer")
			if cc then
				if obj:GetAttribute("MapID") ~= nil then return obj, cc end
				fallback, fallbackCC = fallback or obj, fallbackCC or cc
			end
		end
	end
	if fallback then return fallback, fallbackCC end
	for _, obj in ipairs(Workspace:GetChildren()) do
		if obj.Name ~= "Lobby" and (obj:IsA("Model") or obj:IsA("Folder")) then
			for _, sub in ipairs(obj:GetChildren()) do
				local cc = sub:FindFirstChild("CoinContainer")
				if cc then return sub, cc end
			end
		end
	end
	return nil
end

local function nearMap(map, pos)
	local entry = boundsCache[map]
	if not entry or os.clock() - entry.t > 5 then
		local ok, cf, size = pcall(function() return map:GetBoundingBox() end)
		entry = { t = os.clock(), cf = ok and cf or nil, size = ok and size or nil }
		boundsCache[map] = entry
	end
	if not entry.cf then return true end
	local p = entry.cf:PointToObjectSpace(pos)
	local half, m = entry.size / 2, CFG.mapMargin
	return math.abs(p.X) <= half.X + m and math.abs(p.Y) <= half.Y + m and math.abs(p.Z) <= half.Z + m
end

local function roundOver()
	return LocalPlayer:GetAttribute("Alive") == false or not (state.map and state.map.Parent)
end

local function coinPos(coin)
	local ok, cf = pcall(coin.GetPivot, coin)
	return ok and cf.Position or nil
end

-- Current MM2 marks taken coins with a "Collected" attribute on their CoinVisual;
-- coins without a visual are live while they still have a TouchInterest.
local function coinAlive(coin)
	if not coin.Parent then return false end
	local visual = coin:FindFirstChild("CoinVisual")
	if visual then
		hadVisual[coin] = true
		if visual:GetAttribute("Collected") then return false end
	elseif hadVisual[coin] or not coin:FindFirstChildWhichIsA("TouchTransmitter") then
		return false
	end
	local pos = coinPos(coin)
	if not pos then return false end
	local first = firstPos[coin]
	if not first then
		firstPos[coin] = pos
	elseif (pos - first).Magnitude > 2 then
		return false -- moved away by the game: already taken or a decoy
	end
	return true
end

-- Coin index: the container is scanned once per round, then kept current by
-- ChildAdded/ChildRemoved instead of rescanning on every call.
local Coins = { cc = nil, set = {}, conns = {} }

function Coins.watch(cc)
	if Coins.cc == cc then return end
	Coins.unwatch()
	Coins.cc = cc
	local function add(child)
		if child:IsA("BasePart") or child:IsA("Model") then Coins.set[child] = true end
	end
	for _, child in ipairs(cc:GetChildren()) do add(child) end
	Coins.conns[1] = cc.ChildAdded:Connect(add)
	Coins.conns[2] = cc.ChildRemoved:Connect(function(child) Coins.set[child] = nil end)
end

function Coins.unwatch()
	for _, c in ipairs(Coins.conns) do c:Disconnect() end
	table.clear(Coins.conns)
	table.clear(Coins.set)
	Coins.cc = nil
end

local function listCoins(cc)
	Coins.watch(cc)
	local now = os.clock()
	local coins = {}
	for coin in pairs(Coins.set) do
		if (retryAt[coin] or 0) <= now and coinAlive(coin) then
			coins[#coins + 1] = coin
		else
			if not coin.Parent then Coins.set[coin] = nil end
		end
	end
	return coins
end

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true
pcall(function() rayParams.RespectCanCollide = true end)

local function floorBelow(pos)
	local ignore = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character then ignore[#ignore + 1] = player.Character end
	end
	local cc = state.map and state.map:FindFirstChild("CoinContainer")
	if cc then ignore[#ignore + 1] = cc end
	rayParams.FilterDescendantsInstances = ignore
	local ok, hit = pcall(function()
		return Workspace:Raycast(pos + Vector3.new(0, 1, 0), Vector3.new(0, -150, 0), rayParams)
	end)
	return ok and hit and hit.Position.Y or nil
end

local function diveY(floorY)
	return math.max(floorY - CFG.diveDepth, Workspace.FallenPartsDestroyHeight + 25)
end

-- Maps hide "Glitch"/"Invis" models that kill or reset anyone passing through
-- walls or under the floor; removing our local copy stops those touches.
local function clearTraps(map)
	for _, d in ipairs(map:GetDescendants()) do
		if d:IsA("Model") and (d.Name:find("Glitch", 1, true) or d.Name:find("Invis", 1, true)) then
			pcall(function() d:Destroy() end)
		end
	end
end

---------------------------------------------------------------------------
-- Bag: exact counts from the server's CoinCollected event, the HUD as fallback.
---------------------------------------------------------------------------
local Bag = { counts = {}, active = nil, events = 0 }

function Bag.reset()
	table.clear(Bag.counts)
	Bag.active = nil
end

function Bag.onCollected(bagName, count, max)
	if type(bagName) ~= "string" or type(count) ~= "number" then return end
	Bag.counts[bagName] = { count = count, max = type(max) == "number" and max or nil }
	Bag.events += 1
end

-- Fired at the start of the coin phase with the round's bag slots (Coin, Candy, ...).
function Bag.onStarted(slots)
	table.clear(Bag.counts)
	if type(slots) == "table" then
		local active = {}
		for slot in pairs(slots) do active[#active + 1] = tostring(slot) end
		Bag.active = #active > 0 and active or nil
	end
end

local function bagContainer()
	local main = LocalPlayer.PlayerGui:FindFirstChild("MainGUI")
	local bags = main and main:FindFirstChild("CoinBags", true)
	return bags and bags:FindFirstChild("Container")
end

local function hudSlot(container, name)
	local slot = container and container:FindFirstChild(name)
	if not slot or not slot:IsA("GuiObject") or not slot.Visible then return nil end -- hidden outside the coin phase
	local currency = slot:FindFirstChild("CurrencyFrame")
	local icon = currency and currency:FindFirstChild("Icon")
	local coins = icon and icon:FindFirstChild("Coins")
	local fullIcon = slot:FindFirstChild("FullBagIcon")
	local fullLabel = slot:FindFirstChild("Full")
	return {
		count = coins and tonumber(string.match(coins.Text, "%d+")) or nil,
		full = (fullIcon and fullIcon.Visible) or (fullLabel and fullLabel.Visible) or false,
		hasFlag = fullIcon ~= nil or fullLabel ~= nil,
		bagName = slot:GetAttribute("BagName"),
	}
end

-- known, every bag full, any bag full, exact (all from server events), display text
function Bag.status()
	local ok, known, all, any, exact, text = pcall(function()
		local container = bagContainer()
		local names = Bag.active
		if not names then
			names = {}
			for _, child in ipairs(container and container:GetChildren() or {}) do
				if child:IsA("GuiObject") and child.Visible then names[#names + 1] = child.Name end
			end
		end
		local known, all, any, exact, matched, parts = false, true, false, true, false, {}
		local function add(count, max, full, fromEvent, reliable)
			parts[#parts + 1] = max and string.format("%d/%d", count, max) or tostring(count or (full and "полон" or "?"))
			if not reliable then return end -- a bare count can't tell us the bag is full
			known = true
			if full then any = true else all = false end
			if not fromEvent then exact = false end
		end
		for _, name in ipairs(names) do
			local hud = hudSlot(container, name)
			local ev = (hud and hud.bagName and Bag.counts[hud.bagName]) or Bag.counts[name]
			if ev then
				matched = true
				add(ev.count, ev.max, ev.max ~= nil and ev.count >= ev.max, ev.max ~= nil, ev.max ~= nil)
			elseif hud then
				add(hud.count, nil, hud.full, false, hud.hasFlag)
			end
		end
		if not matched and next(Bag.counts) then
			-- events we can't tie to a HUD slot are still the most accurate source
			known, all, any, exact, parts = false, true, false, true, {}
			for _, ev in pairs(Bag.counts) do add(ev.count, ev.max, ev.max ~= nil and ev.count >= ev.max, ev.max ~= nil, ev.max ~= nil) end
		end
		return known, all, any, exact, table.concat(parts, " · ")
	end)
	if not ok then return false, false, false, false, nil end
	if not known then return false, false, false, false, text ~= "" and text or nil end
	return true, all, any, exact, text
end

local function bagIsFull()
	local known, all, any, exact = Bag.status()
	if known and all then return true end
	if known and exact then return false end -- server counts say there's room; misses are just bad spots
	if known and any then return state.misses >= 2 end
	-- the HUD may be missing or misread, so repeated misses still end the round
	return state.misses >= (known and CFG.missLimit * 2 or CFG.missLimit)
end

-- Once CoinCollected has been seen, a vanished coin only counts if the event followed.
local function confirmed(eventsBefore, fallback)
	if Bag.events == 0 then return fallback end
	local deadline = os.clock() + 0.5
	while Bag.events == eventsBefore and os.clock() < deadline do RunService.Heartbeat:Wait() end
	return Bag.events > eventsBefore
end

---------------------------------------------------------------------------
-- Movement
---------------------------------------------------------------------------
local function moveTo(target, abort)
	if not ctrl.engaged then return false end
	ctrl.target = target
	while ctrl.engaged do
		if (ctrl.pos - target).Magnitude < 0.05 then return true end
		if not stillOwner() or not (state.running or state.parking) then break end
		if abort and abort() then break end
		RunService.Heartbeat:Wait()
	end
	ctrl.target = nil
	return false
end

local function parkAndRelease(waitForTeleport)
	local spot = state.safeSpot
	if ctrl.engaged and spot then
		if waitForTeleport and ctrl.pos.Y < spot.Y - 8 then
			-- "Alive" can flip just before the round-end teleport; don't drop into the void meanwhile
			local deadline = os.clock() + 4
			while ctrl.engaged and stillOwner() and os.clock() < deadline do
				RunService.Heartbeat:Wait()
			end
		end
		if ctrl.engaged then
			state.parking = true
			moveTo(spot)
			state.parking = false
		end
	end
	release()
end

local fireTouch = firetouchinterest
local function touch(coin)
	local hrp = ctrl.hrp
	local part = coin:IsA("BasePart") and coin or coin:FindFirstChildWhichIsA("BasePart")
	if type(fireTouch) ~= "function" or not hrp or not part then return end
	pcall(fireTouch, hrp, part, 0)
	pcall(fireTouch, hrp, part, 1)
end

local NUDGES = {
	Vector3.new(1.5, 0, 0),
	Vector3.new(-1.5, 0, 0),
	Vector3.new(0, 1.2, 0),
	Vector3.new(0, 0, 1.5),
	Vector3.new(0, 0, -1.5),
	Vector3.zero,
}

local coinFloor = setmetatable({}, { __mode = "k" })
local function floorOf(coin, pos)
	local y = coinFloor[coin]
	if y == nil then
		y = floorBelow(pos) or false
		coinFloor[coin] = y
	end
	return y or nil
end

local function rivals()
	local list = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= LocalPlayer and player:GetAttribute("Alive") ~= false then
			local char = player.Character
			local root = char and char:FindFirstChild("HumanoidRootPart")
			local hum = char and char:FindFirstChildOfClass("Humanoid")
			if root and hum and hum.Health > 0 and (not state.map or nearMap(state.map, root.Position)) then
				list[#list + 1] = root.Position
			end
		end
	end
	return list
end

-- Path length for the current mode (dive goes under the coin, then straight up).
local function travel(from, pos, floorY)
	if state.mode == "dive" then
		local under = Vector3.new(pos.X, diveY(floorY or pos.Y), pos.Z)
		return (under - from).Magnitude + (pos - under).Magnitude
	end
	return (pos - from).Magnitude
end

local RIVAL_SPEED = 16 -- default MM2 walk speed
local function score(coin, pos, from, others)
	local dist = travel(from, pos, floorOf(coin, pos))
	local cost = dist * Memory.penalty(state.mem, toLocal(pos))
	local eta = dist / math.min(CFG.speed, MAX_SPEED)
	for _, other in ipairs(others) do
		local d = (other - pos).Magnitude
		if d < 20 and d / RIVAL_SPEED < eta then
			return cost * 3 + 40 -- someone gets there first
		end
	end
	return cost
end

-- Cheapest coin by travel cost (mode-aware path, learned penalties, rivals).
local function pickCoin(coins, from, exclude)
	local others = rivals()
	local best, bestPos, bestCost
	for _, coin in ipairs(coins) do
		local pos = coin ~= exclude and coinPos(coin)
		if pos then
			if not seenCoin[coin] then
				seenCoin[coin] = true
				Memory.spawned(state.mem, toLocal(pos))
			end
			local cost = score(coin, pos, from, others)
			if not bestCost or cost < bestCost then best, bestPos, bestCost = coin, pos, cost end
		end
	end
	return best, bestPos, bestCost
end

-- Typical server confirmation delay, learned from successful pickups; the wait
-- on a coin is capped at 3x this so misses are detected sooner.
local confirmDelay = 0.35
local function collect(coin, pos, floorY, cc)
	local events = Bag.events
	local waitLimit = math.min(CFG.touchTime, math.max(0.4, confirmDelay * 3))
	local nextCheck = os.clock() + 0.3
	local function lost()
		if roundOver() or not coinAlive(coin) then return true end
		if os.clock() < nextCheck then return false end
		nextCheck = os.clock() + 0.3
		-- switch when a coin became much cheaper (new spawn nearby, or a rival is closing in on ours)
		local current = score(coin, pos, ctrl.pos, rivals())
		if current < 8 then return false end
		local _, _, alt = pickCoin(listCoins(cc), ctrl.pos, coin)
		return alt ~= nil and alt < current * 0.6
	end
	local function settle()
		if coinAlive(coin) then return "aborted" end
		-- without the event: vanishing as we reached it means it was ours
		return confirmed(events, (ctrl.pos - pos).Magnitude <= 6) and "collected" or "gone"
	end

	if state.mode == "dive" then
		if not moveTo(Vector3.new(pos.X, diveY(floorY or pos.Y), pos.Z), lost) then return settle() end
	end
	if not moveTo(pos, lost) then return settle() end

	touch(coin)
	local start, nudge = os.clock(), 0
	while ctrl.engaged and os.clock() - start < waitLimit do
		if not coinAlive(coin) then
			if confirmed(events, true) then
				confirmDelay = confirmDelay * 0.8 + (os.clock() - start) * 0.2
				return "collected"
			end
			return "gone"
		end
		if roundOver() or not (state.running and stillOwner()) then return "aborted" end
		local due = math.floor((os.clock() - start) / 0.15)
		if due > nudge and due <= #NUDGES then
			nudge = due
			ctrl.target = pos + NUDGES[nudge]
		end
		RunService.Heartbeat:Wait()
	end
	if not coinAlive(coin) then return confirmed(events, true) and "collected" or "gone" end
	return ctrl.engaged and "missed" or "aborted"
end

-- No coins right now: wait where they usually spawn (hidden under the map in dive mode).
local function waitForCoins(cc)
	if not ctrl.engaged then return end -- still standing at the spawn
	local target
	local spot = Memory.hotspot(state.mem, toLocal(ctrl.pos))
	if spot then
		spot = toWorld(spot)
		local floorY = floorBelow(spot)
		if floorY then state.safeSpot = Vector3.new(spot.X, floorY + 3, spot.Z) end
		target = state.mode == "dive" and Vector3.new(spot.X, diveY(floorY or spot.Y), spot.Z) or spot
	elseif state.mode == "dive" and state.safeSpot then
		target = Vector3.new(ctrl.pos.X, diveY(state.safeSpot.Y - 3), ctrl.pos.Z)
	end
	if target and (target - ctrl.pos).Magnitude > 3 then
		local nextCheck = 0
		moveTo(target, function()
			if roundOver() then return true end
			if os.clock() < nextCheck then return false end
			nextCheck = os.clock() + 0.3
			return #listCoins(cc) > 0
		end)
	end
end

local function sitOut(reason)
	state.roundDone = reason
	setPhase(reason)
	if state.mode == "dive" and ctrl.engaged and state.safeSpot then
		-- stay hidden under the map until the round ends
		moveTo(Vector3.new(ctrl.pos.X, diveY(state.safeSpot.Y - 3), ctrl.pos.Z), roundOver)
	else
		parkAndRelease(false)
	end
end

---------------------------------------------------------------------------
-- Rounds
---------------------------------------------------------------------------
local function startRound(map, hrp)
	state.map = map
	local ok, pivot = pcall(function() return map:GetPivot() end)
	state.pivot = ok and pivot or nil
	state.mem = Memory.map(map.Name)
	state.roundDone = nil
	state.roundCoins = 0
	state.misses = 0
	state.safeSpot = hrp.Position
	state.cooldownUntil = 0
	ctrl.diedAt = nil
	ctrl.displaced = false -- the teleport into/out of a round isn't a reason to wait
	table.clear(retryAt)
	clearTraps(map)
	print(string.format("[MM2] раунд на карте %s (в памяти раундов: %d)", map.Name, state.mem.rounds))
end

local function endRound()
	if state.mem then
		Memory.roundEnded(state.mem, state.roundCoins)
		Memory.save(true)
	end
	state.map, state.pivot, state.mem = nil, nil, nil
	state.roundDone = nil
	Bag.reset()
	Coins.unwatch()
	state.misses = 0
end

local function farmStep()
	if game.PlaceId ~= PLACE_ID then
		release()
		setPhase("wrong_game")
		return 2
	end

	local char, hum, hrp = getChar()
	if not char then
		-- a respawn the game still counts as alive isn't a death
		if state.map and not state.roundDone and LocalPlayer:GetAttribute("Alive") ~= true then
			if ctrl.diedAt then Memory.died(state.mem, toLocal(ctrl.diedAt)) end
			state.roundDone = "dead"
		end
		release()
		setPhase(state.roundDone == "dead" and "dead" or "waiting")
		return 0.5
	end

	local map, cc = findMap()
	local alive = LocalPlayer:GetAttribute("Alive")
	local onMap = map ~= nil and alive ~= false and (ctrl.engaged or nearMap(map, hrp.Position))
	if not onMap then
		if state.map then
			parkAndRelease(true)
			endRound()
		else
			release()
		end
		setPhase("waiting")
		return 0.5
	end

	if state.map ~= map then
		if state.map then endRound() end
		startRound(map, hrp)
	end
	if state.roundDone then
		setPhase(state.roundDone)
		return 0.5
	end

	if ctrl.displaced then
		-- the game moved us; give it a moment before taking control again
		ctrl.displaced = false
		state.cooldownUntil = os.clock() + 1.5
	end
	if os.clock() < state.cooldownUntil then return 0.2 end

	if bagIsFull() then
		sitOut("bag_full")
		return 0.5
	end

	local coins = listCoins(cc)
	if #coins == 0 then
		setPhase("no_coins")
		waitForCoins(cc)
		return 0.3
	end

	local coin, pos = pickCoin(coins, ctrl.engaged and ctrl.pos or hrp.Position)
	if not coin then return 0.3 end
	local floorY = floorOf(coin, pos)
	if floorY then state.safeSpot = Vector3.new(pos.X, floorY + 3, pos.Z) end
	if not engage(char, hum, hrp) then return 0.5 end
	setPhase("farming")

	local result = collect(coin, pos, floorY, cc)
	if result == "collected" then
		state.roundCoins += 1
		state.totalCoins += 1
		state.misses = 0
		Memory.result(state.mem, toLocal(pos), true)
		if state.totalCoins % 10 == 0 then
			print(string.format("[MM2] всего %d (раунд %d)", state.totalCoins, state.roundCoins))
		end
	elseif result == "missed" then
		state.misses += 1
		local known, _, anyFull, exact = Bag.status()
		-- server counts say there's room, so the coin itself is uncollectable (decoy): skip it this round
		retryAt[coin] = (known and exact and not anyFull) and math.huge or os.clock() + CFG.retryAfter
		if known and not anyFull then Memory.result(state.mem, toLocal(pos), false) end
	end
	return 0
end

local function farmLoop()
	while stillOwner() do
		if state.running then
			local ok, delay = pcall(farmStep)
			if ok then
				state.lastError = nil
				task.wait(delay)
			else
				state.lastError = tostring(delay)
				setPhase("error")
				warn("[MM2] " .. state.lastError)
				pcall(parkAndRelease, false)
				task.wait(1)
			end
		else
			setPhase("off")
			if ctrl.engaged then pcall(parkAndRelease, false) end
			task.wait(0.25)
		end
	end
end

---------------------------------------------------------------------------
-- UI
---------------------------------------------------------------------------
window:Toggle({
	Text = "Автофарм",
	Default = true,
	Callback = function(on)
		state.running = on
	end,
})

window:Segmented({
	Text = "Режим",
	Options = { "Обычный", "Выныривание" },
	Default = "Обычный",
	Callback = function(value)
		state.mode = value == "Выныривание" and "dive" or "normal"
	end,
})

local statusLabel = window:Label({ Text = "Статус: —" })
local memoryLabel = window:Label({ Text = "Память: —" })

local function updateUI()
	local text = PHASE_TEXT[state.phase] or state.phase
	if state.phase == "error" and state.lastError then text = text .. ": " .. state.lastError end
	local _, _, _, _, bag = Bag.status()
	statusLabel:SetText(string.format("Статус: %s · мешок %s · всего %d", text, bag or tostring(state.roundCoins), state.totalCoins))
	local m = state.mem
	if m and state.map then
		memoryLabel:SetText(string.format("Память: %s — %d раундов, ~%d монет за раунд",
			state.map.Name, m.rounds, math.floor((m.avg or 0) + 0.5)))
	else
		local maps, spots = Memory.stats()
		memoryLabel:SetText(string.format("Память: %d карт, %d точек%s", maps, spots,
			Memory.persistent and "" or " (без сохранения)"))
	end
end

-- Older versions of this script anchored the root part; undo leftovers once.
do
	local _, hum, hrp = getChar()
	if hrp and hrp.Anchored then pcall(function() hrp.Anchored = false end) end
	if hum and hum.PlatformStand then pcall(function() hum.PlatformStand = false end) end
end

for _, conn in ipairs(connections) do giveToWindow(conn) end
giveToWindow(task.spawn(function()
	local remotes = ReplicatedStorage:WaitForChild("Remotes", 30)
	local gameplay = remotes and remotes:WaitForChild("Gameplay", 10)
	if not gameplay then
		warn("[MM2] Remotes.Gameplay not found; bag is read from the HUD")
		return
	end
	local collected = gameplay:WaitForChild("CoinCollected", 10)
	if collected then giveToWindow(collected.OnClientEvent:Connect(Bag.onCollected)) end
	local started = gameplay:WaitForChild("CoinsStarted", 10)
	if started then giveToWindow(started.OnClientEvent:Connect(Bag.onStarted)) end
end))
giveToWindow(task.spawn(farmLoop))
giveToWindow(task.spawn(function()
	while stillOwner() do
		pcall(updateUI)
		pcall(Memory.save, false)
		task.wait(0.4)
	end
end))

do
	window:OnDestroy(function()
		state.running = false
		stopAntiFling()
		local spot = state.safeSpot
		if ctrl.engaged and spot and ctrl.pos.Y < spot.Y - 5 then
			-- the window's controller is being torn down, so fly out from under the map
			-- on a separate thread, still within the speed cap
			local surfacing = {}
			if ENV then ENV.MM2_SURFACING = surfacing end
			task.spawn(function()
				local hrp, hum = ctrl.hrp, ctrl.hum
				while ctrl.engaged and hrp.Parent and hum.Health > 0 do
					local dt = RunService.Heartbeat:Wait()
					local delta = spot - ctrl.pos
					local step = math.min(CFG.speed, MAX_SPEED) * math.min(dt, 0.1)
					ctrl.pos = delta.Magnitude <= step and spot or ctrl.pos + delta.Unit * step
					hrp.AssemblyLinearVelocity = Vector3.zero
					hrp.AssemblyAngularVelocity = Vector3.zero
					hrp.CFrame = CFrame.new(ctrl.pos) * ctrl.rot
					if ctrl.pos == spot then break end
				end
				release()
				if ENV and ENV.MM2_SURFACING == surfacing then ENV.MM2_SURFACING = nil end
			end)
		else
			release()
		end
		pcall(Memory.save, true)
		if ENV and ENV.MM2_TOKEN == TOKEN then ENV.MM2_TOKEN = nil end
	end)
end

return "ready (memory=" .. tostring(Memory.persistent) .. ")"
