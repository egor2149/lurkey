local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local CoreGui = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer

local UI = {}
UI.Version = "1.0.0"

local Theme = {
	Background = Color3.fromRGB(24, 24, 28),
	Header = Color3.fromRGB(32, 32, 38),
	Row = Color3.fromRGB(34, 34, 40),
	Track = Color3.fromRGB(58, 58, 66),
	Accent = Color3.fromRGB(255, 184, 48),
	Text = Color3.fromRGB(235, 235, 240),
	Muted = Color3.fromRGB(150, 150, 160),
	OnAccent = Color3.fromRGB(28, 22, 8),
	Stroke = Color3.fromRGB(60, 60, 70),
}

local Layout = {
	Width = 320,
	Padding = 10,
	Row = 36,
	Header = 44,
	Gap = 6,
	LauncherSize = 44,
}

local FONT = Enum.Font.Gotham
local FONT_BOLD = Enum.Font.GothamBold

local function create(class, props, parent)
	local inst = Instance.new(class)
	for key, value in pairs(props) do
		inst[key] = value
	end
	inst.Parent = parent
	return inst
end

local function corner(parent, radius)
	return create("UICorner", { CornerRadius = UDim.new(0, radius) }, parent)
end

local function label(parent, props)
	local base = {
		BackgroundTransparency = 1,
		Font = FONT,
		TextSize = 14,
		TextColor3 = Theme.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = true,
		Text = "",
	}
	for key, value in pairs(props) do
		base[key] = value
	end
	return create("TextLabel", base, parent)
end

local function animate(inst, props, duration)
	if duration and duration > 0 then
		TweenService:Create(inst, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props):Play()
	else
		for key, value in pairs(props) do
			inst[key] = value
		end
	end
end

local function isPointer(input)
	local kind = input.UserInputType
	return kind == Enum.UserInputType.MouseButton1 or kind == Enum.UserInputType.Touch
end

local function isPointerMove(input)
	local kind = input.UserInputType
	return kind == Enum.UserInputType.MouseMovement or kind == Enum.UserInputType.Touch
end

local function guiRoot()
	local ok, root = pcall(function()
		if type(gethui) == "function" then
			return gethui()
		end
		return CoreGui
	end)
	if ok and root then
		return root
	end
	return LocalPlayer:WaitForChild("PlayerGui")
end

local function mount(gui, root)
	if pcall(function() gui.Parent = root end) and gui.Parent == root then
		return
	end
	gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
end

local function clampToScreen(gui, frame)
	local screen = gui.AbsoluteSize
	local size = frame.AbsoluteSize
	if screen.X <= 0 or screen.Y <= 0 then
		return
	end
	local pos = frame.AbsolutePosition
	local x = math.clamp(pos.X, 0, math.max(0, screen.X - size.X))
	local y = math.clamp(pos.Y, 0, math.max(0, screen.Y - size.Y))
	if x ~= pos.X or y ~= pos.Y then
		frame.Position = UDim2.fromOffset(x, y)
	end
end

local function makeDraggable(window, handle, frame, onTap)
	local gui = window.gui
	local dragInput, dragStart, frameStart, moved

	handle.InputBegan:Connect(function(input)
		if not isPointer(input) then
			return
		end
		dragInput, dragStart, frameStart, moved = input, input.Position, frame.Position, false
		input.Changed:Connect(function()
			if input.UserInputState == Enum.UserInputState.End and dragInput == input then
				dragInput = nil
				if not moved and onTap then
					onTap()
				end
			end
		end)
	end)

	window:Give(UserInputService.InputChanged:Connect(function(input)
		if not dragInput or not isPointerMove(input) then
			return
		end
		if input.UserInputType == Enum.UserInputType.Touch and input ~= dragInput then
			return
		end
		local delta = input.Position - dragStart
		if delta.Magnitude > 4 then
			moved = true
		end
		frame.Position = UDim2.new(
			frameStart.X.Scale, frameStart.X.Offset + delta.X,
			frameStart.Y.Scale, frameStart.Y.Offset + delta.Y
		)
		clampToScreen(gui, frame)
	end))
end

local Window = {}
Window.__index = Window

function UI.CreateWindow(options)
	options = options or {}
	local name = options.Name or "UIWindow"
	local root = guiRoot()
	local existing = root:FindFirstChild(name)
	if existing then
		existing:Destroy()
	end

	local self = setmetatable({
		resources = {},
		alive = true,
		rows = 0,
		visible = true,
	}, Window)

	local gui = create("ScreenGui", {
		Name = name,
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 999,
	}, nil)
	pcall(function() gui.IgnoreGuiInset = true end)
	self.gui = gui

	local frame = create("Frame", {
		Name = "Window",
		BackgroundColor3 = Theme.Background,
		BorderSizePixel = 0,
		Position = UDim2.new(0, 24, 0.5, -120),
		Size = UDim2.fromOffset(Layout.Width, Layout.Header),
		Active = true,
	}, gui)
	corner(frame, 10)
	create("UIStroke", { Color = Theme.Stroke, Thickness = 1 }, frame)
	self.frame = frame

	local header = create("Frame", {
		Name = "Header",
		BackgroundColor3 = Theme.Header,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, Layout.Header),
		Active = true,
	}, frame)
	corner(header, 10)
	create("Frame", {
		Name = "HeaderFill",
		BackgroundColor3 = Theme.Header,
		BorderSizePixel = 0,
		Position = UDim2.new(0, 0, 1, -10),
		Size = UDim2.new(1, 0, 0, 10),
	}, header)
	label(header, {
		Name = "Title",
		Text = options.Title or "",
		Font = FONT_BOLD,
		TextSize = 15,
		Position = UDim2.fromOffset(Layout.Padding + 2, 5),
		Size = UDim2.new(1, -130, 0, 20),
	})
	label(header, {
		Name = "Subtitle",
		Text = options.Subtitle or "",
		TextSize = 12,
		TextColor3 = Theme.Muted,
		Position = UDim2.fromOffset(Layout.Padding + 2, 24),
		Size = UDim2.new(1, -130, 0, 14),
	})

	local hide = create("TextButton", {
		Name = "Hide",
		Text = "–",
		Font = FONT_BOLD,
		TextSize = 18,
		TextColor3 = Theme.Muted,
		BackgroundTransparency = 1,
		Position = UDim2.new(1, -68, 0, 8),
		Size = UDim2.fromOffset(28, 28),
		AutoButtonColor = false,
	}, header)
	local close = create("TextButton", {
		Name = "Close",
		Text = "×",
		Font = FONT_BOLD,
		TextSize = 20,
		TextColor3 = Theme.Muted,
		BackgroundTransparency = 1,
		Position = UDim2.new(1, -36, 0, 8),
		Size = UDim2.fromOffset(28, 28),
		AutoButtonColor = false,
	}, header)
	for _, button in ipairs({ hide, close }) do
		button.MouseEnter:Connect(function() button.TextColor3 = Theme.Text end)
		button.MouseLeave:Connect(function() button.TextColor3 = Theme.Muted end)
	end
	hide.Activated:Connect(function() self:SetVisible(false) end)
	close.Activated:Connect(function() self:Destroy() end)

	local body = create("Frame", {
		Name = "Body",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(Layout.Padding, Layout.Header + Layout.Gap),
		Size = UDim2.new(1, -Layout.Padding * 2, 1, -(Layout.Header + Layout.Gap + Layout.Padding)),
	}, frame)
	create("UIListLayout", {
		Padding = UDim.new(0, Layout.Gap),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, body)
	self.body = body

	local launcher = create("TextButton", {
		Name = "Launcher",
		Text = options.LauncherText or "≡",
		Font = FONT_BOLD,
		TextSize = 22,
		TextColor3 = Theme.OnAccent,
		BackgroundColor3 = Theme.Accent,
		BorderSizePixel = 0,
		Position = UDim2.new(0, 24, 0, 24),
		Size = UDim2.fromOffset(Layout.LauncherSize, Layout.LauncherSize),
		Visible = false,
		AutoButtonColor = false,
		Active = true,
	}, gui)
	corner(launcher, Layout.LauncherSize / 2)
	self.launcher = launcher

	makeDraggable(self, header, frame, nil)
	makeDraggable(self, launcher, launcher, function() self:SetVisible(true) end)

	local key = options.ToggleKey
	if key then
		self:Give(UserInputService.InputBegan:Connect(function(input, processed)
			if not processed and input.KeyCode == key then
				self:SetVisible(not self.visible)
			end
		end))
	end

	gui.Destroying:Connect(function() self:Destroy() end)
	mount(gui, root)
	self:_Resize()
	return self
end

function Window:_Resize()
	local height = Layout.Header + Layout.Gap + self.rows * (Layout.Row + Layout.Gap) + Layout.Padding - Layout.Gap
	self.frame.Size = UDim2.fromOffset(Layout.Width, height)
end

function Window:_Row()
	self.rows += 1
	local row = create("Frame", {
		Name = "Row" .. self.rows,
		BackgroundColor3 = Theme.Row,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, Layout.Row),
		LayoutOrder = self.rows,
	}, self.body)
	corner(row, 6)
	self:_Resize()
	return row
end

function Window:Toggle(options)
	local row = self:_Row()
	row.Name = "Toggle"
	label(row, {
		Text = options.Text or "",
		Position = UDim2.fromOffset(Layout.Padding, 0),
		Size = UDim2.new(1, -80, 1, 0),
	})
	local track = create("TextButton", {
		Name = "Track",
		Text = "",
		BackgroundColor3 = Theme.Track,
		AutoButtonColor = false,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -Layout.Padding, 0.5, 0),
		Size = UDim2.fromOffset(44, 24),
	}, row)
	corner(track, 12)
	local knob = create("Frame", {
		Name = "Knob",
		BackgroundColor3 = Theme.Text,
		Position = UDim2.fromOffset(3, 3),
		Size = UDim2.fromOffset(18, 18),
	}, track)
	corner(knob, 9)

	local value = options.Default == true
	local function render(duration)
		animate(track, { BackgroundColor3 = value and Theme.Accent or Theme.Track }, duration)
		animate(knob, {
			Position = UDim2.fromOffset(value and 23 or 3, 3),
			BackgroundColor3 = value and Theme.OnAccent or Theme.Text,
		}, duration)
	end

	local control = {}
	function control:Get()
		return value
	end
	function control:Set(newValue, silent)
		newValue = newValue == true
		if newValue == value then
			return
		end
		value = newValue
		render(0.15)
		if not silent and options.Callback then
			task.spawn(options.Callback, value)
		end
	end
	track.Activated:Connect(function() control:Set(not value) end)
	render(0)
	return control
end

function Window:Segmented(options)
	local row = self:_Row()
	row.Name = "Segmented"
	label(row, {
		Text = options.Text or "",
		Position = UDim2.fromOffset(Layout.Padding, 0),
		Size = UDim2.new(0, 90, 1, 0),
	})
	local choices = options.Options or {}
	local holder = create("Frame", {
		Name = "Options",
		BackgroundColor3 = Theme.Track,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -Layout.Padding, 0.5, 0),
		Size = UDim2.new(1, -(Layout.Padding * 2 + 90), 0, 26),
	}, row)
	corner(holder, 6)

	local value = options.Default or choices[1]
	local buttons = {}
	local function render()
		for index, button in ipairs(buttons) do
			local on = choices[index] == value
			animate(button, {
				BackgroundColor3 = on and Theme.Accent or Theme.Track,
				TextColor3 = on and Theme.OnAccent or Theme.Muted,
			}, 0.15)
		end
	end

	local control = {}
	function control:Get()
		return value
	end
	function control:Set(newValue, silent)
		if newValue == value then
			return
		end
		value = newValue
		render()
		if not silent and options.Callback then
			task.spawn(options.Callback, value)
		end
	end

	local count = #choices
	for index, choice in ipairs(choices) do
		local button = create("TextButton", {
			Name = "Option" .. index,
			Text = choice,
			Font = FONT,
			TextSize = 13,
			TextColor3 = Theme.Muted,
			AutoButtonColor = false,
			BackgroundColor3 = Theme.Track,
			BorderSizePixel = 0,
			Position = UDim2.new((index - 1) / count, 2, 0, 2),
			Size = UDim2.new(1 / count, -4, 1, -4),
		}, holder)
		corner(button, 5)
		button.Activated:Connect(function() control:Set(choice) end)
		buttons[index] = button
	end
	render()
	return control
end

function Window:Label(options)
	local row = self:_Row()
	row.Name = "Label"
	local text = label(row, {
		Text = options.Text or "",
		TextSize = 13,
		Position = UDim2.fromOffset(Layout.Padding, 0),
		Size = UDim2.new(1, -Layout.Padding * 2, 1, 0),
	})
	local control = {}
	function control:SetText(value)
		if text.Text ~= value then
			text.Text = value
		end
	end
	return control
end

function Window:SetVisible(visible)
	self.visible = visible == true
	self.frame.Visible = self.visible
	self.launcher.Visible = not self.visible
end

function Window:IsVisible()
	return self.visible
end

function Window:Give(resource)
	if not self.alive then
		self:_Dispose(resource)
		return
	end
	self.resources[#self.resources + 1] = resource
end

function Window:OnDestroy(callback)
	self:Give(callback)
end

function Window:_Dispose(resource)
	local kind = typeof(resource)
	if kind == "function" then
		resource()
	elseif kind == "RBXScriptConnection" then
		resource:Disconnect()
	elseif kind == "thread" then
		task.cancel(resource)
	elseif kind == "Instance" then
		resource:Destroy()
	end
end

function Window:Destroy()
	if not self.alive then
		return
	end
	self.alive = false
	local list = self.resources
	self.resources = {}
	for index = #list, 1, -1 do
		pcall(self._Dispose, self, list[index])
	end
	if self.gui.Parent then
		self.gui:Destroy()
	end
end

return UI
