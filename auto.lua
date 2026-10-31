local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
local PLACE_ID = 142823291
local MAX_SPEED = 25
local UI_URL = "https://raw.githubusercontent.com/egor2149/lurkey/hoplite/mylasa-210d8d35/ui.lua"

local CFG = {
	speed = MAX_SPEED,
	diveDepth = 25,
	touchTime = 1,
	retryAfter = 20,
	missLimit = 4,
	mapMargin = 60,
	rivalSpeed = 16,
	rivalRadius = 24,
	rivalClaim = 12,
}

local ENV
do
	local ok, env = pcall(function() return getgenv() end)
	if ok and type(env) == "table" then ENV = env end
end

do
	if ENV and ENV.MM2_ANTIAFK then pcall(function() ENV.MM2_ANTIAFK:Disconnect() end) end
	local VirtualUser = game:GetService("VirtualUser")
	local conn = LocalPlayer.Idled:Connect(function()
		pcall(function()
			VirtualUser:CaptureController()
			VirtualUser:ClickButton2(Vector2.new())
		end)
	end)
	if ENV then ENV.MM2_ANTIAFK = conn end
end

local stopAntiFling
do
	local parts = setmetatable({}, { __mode = "k" })
	local charConns = setmetatable({}, { __mode = "k" })
	local conns = {}
	local MAX_SPIN, MAX_PUSH = 40, 90

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

local UI
do
	local lib = ENV and ENV.MM2_UI_LIB
	if type(lib) ~= "table" then
		local loader = loadstring or load
		if type(loader) ~= "function" then error("executor missing loadstring") end
		local ok, result = pcall(function()
			return loader(game:HttpGet(UI_URL))()
		end)
		if not ok or type(result) ~= "table" then error("UI library failed: " .. tostring(result)) end
		lib = result
	end
	UI = lib
end

local window = UI.CreateWindow({
	Name = "MM2CollectUI",
	Title = "MM2 Collect",
	Subtitle = "coin auto-farm",
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

	function Memory.penalty(m, p)
		local penalty = 1
		local s = m.spots[key(p, SPOT)]
		if type(s) == "table" and (s.m or 0) > 0 then
			penalty += math.min(3, s.m / ((s.h or 0) + 1))
		end
		return penalty + math.min(3, tonumber(m.zones[key(p, ZONE)]) or 0)
	end

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
end

local state = {
	running = true,
	parking = false,
	mode = "normal",
	phase = "",
	map = nil,
	pivot = nil,
	mem = nil,
	roundDone = nil,
	roundCoins = 0,
	totalCoins = 0,
	misses = 0,
	safeSpot = nil,
	cooldownUntil = 0,
	lastError = nil,
	farmSeconds = 0,
	farmSince = nil,
}

local retryAt = setmetatable({}, { __mode = "k" })
local firstPos = setmetatable({}, { __mode = "k" })
local hadVisual = setmetatable({}, { __mode = "k" })
local seenCoin = setmetatable({}, { __mode = "k" })
local boundsCache = setmetatable({}, { __mode = "k" })
local coinFloor = setmetatable({}, { __mode = "k" })

local PHASE_TEXT = {
	off = "off",
	waiting = "waiting for a round",
	farming = "collecting",
	no_coins = "waiting for coins",
	bag_full = "bag full, waiting for next round",
	dead = "died, waiting for next round",
	wrong_game = "this is not MM2",
	error = "error",
}

local function setPhase(phase)
	if state.phase ~= phase then
		state.phase = phase
		print("[MM2] " .. (PHASE_TEXT[phase] or phase))
	end
end

local function setFarming(on)
	if on and not state.farmSince then
		state.farmSince = os.clock()
	elseif not on and state.farmSince then
		state.farmSeconds += os.clock() - state.farmSince
		state.farmSince = nil
	end
end

local function farmTime()
	return state.farmSeconds + (state.farmSince and os.clock() - state.farmSince or 0)
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

local ctrl = {
	engaged = false,
	pos = nil,
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
	if ENV and ENV.MM2_SURFACING then return false end
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
		hum:SetStateEnabled(Enum.HumanoidStateType.Seated, false)
		hum.Sit = false
		hum.PlatformStand = true
	end)
	return true
end

local connections = {}

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
		ctrl.engaged = false
		return
	end
	local hrp, hum = ctrl.hrp, ctrl.hum
	if not hrp.Parent or not hum.Parent or hum.Health <= 0 then
		ctrl.diedAt = ctrl.pos
		release()
		return
	end
	if (hrp.Position - ctrl.pos).Magnitude > 12 then
		ctrl.displaced = true
		ctrl.pos = hrp.Position
		ctrl.target = nil
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
		return false
	end
	return true
end

local Coins = { cc = nil, set = {}, conns = {} }

function Coins.unwatch()
	for _, c in ipairs(Coins.conns) do c:Disconnect() end
	table.clear(Coins.conns)
	table.clear(Coins.set)
	Coins.cc = nil
end

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

local function listCoins(cc)
	Coins.watch(cc)
	local now = os.clock()
	local coins = {}
	for coin in pairs(Coins.set) do
		if (retryAt[coin] or 0) <= now and coinAlive(coin) then
			coins[#coins + 1] = coin
		elseif not coin.Parent then
			Coins.set[coin] = nil
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

local function floorOf(coin, pos)
	local y = coinFloor[coin]
	if y == nil then
		y = floorBelow(pos) or false
		coinFloor[coin] = y
	end
	return y or nil
end

local function diveY(floorY)
	return math.max(floorY - CFG.diveDepth, Workspace.FallenPartsDestroyHeight + 25)
end

local function clearTraps(map)
	for _, d in ipairs(map:GetDescendants()) do
		if d:IsA("Model") and (d.Name:find("Glitch", 1, true) or d.Name:find("Invis", 1, true)) then
			pcall(function() d:Destroy() end)
		end
	end
end

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
	if not slot or not slot:IsA("GuiObject") or not slot.Visible then return nil end
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

function Bag.status()
	local ok, known, all, any, exact = pcall(function()
		local container = bagContainer()
		local names = Bag.active
		if not names then
			names = {}
			for _, child in ipairs(container and container:GetChildren() or {}) do
				if child:IsA("GuiObject") and child.Visible then names[#names + 1] = child.Name end
			end
		end
		local known, all, any, exact, matched = false, true, false, true, false
		local function add(full, fromEvent, reliable)
			if not reliable then return end
			known = true
			if full then any = true else all = false end
			if not fromEvent then exact = false end
		end
		for _, name in ipairs(names) do
			local hud = hudSlot(container, name)
			local ev = (hud and hud.bagName and Bag.counts[hud.bagName]) or Bag.counts[name]
			if ev then
				matched = true
				add(ev.max ~= nil and ev.count >= ev.max, ev.max ~= nil, ev.max ~= nil)
			elseif hud then
				add(hud.full, false, hud.hasFlag)
			end
		end
		if not matched and next(Bag.counts) then
			known, all, any, exact = false, true, false, true
			for _, ev in pairs(Bag.counts) do add(ev.max ~= nil and ev.count >= ev.max, ev.max ~= nil, ev.max ~= nil) end
		end
		return known, all, any, exact
	end)
	if not ok or not known then return false, false, false, false end
	return true, all, any, exact
end

local function bagIsFull()
	local known, all, any, exact = Bag.status()
	if known and all then return true end
	if known and exact then return false end
	if known and any then return state.misses >= 2 end
	return state.misses >= (known and CFG.missLimit * 2 or CFG.missLimit)
end

local function confirmed(eventsBefore, fallback)
	if Bag.events == 0 then return fallback end
	local deadline = os.clock() + 0.5
	while Bag.events == eventsBefore and os.clock() < deadline do RunService.Heartbeat:Wait() end
	return Bag.events > eventsBefore
end

local function moveTo(target, abort)
	if not ctrl.engaged then return false end
	ctrl.target = target
	while ctrl.engaged and ctrl.target == target do
		if (ctrl.pos - target).Magnitude < 0.05 then return true end
		if not stillOwner() or not (state.running or state.parking) then break end
		if abort and abort() then break end
		RunService.Heartbeat:Wait()
	end
	ctrl.target = nil
	return false
end

local function park(waitForTeleport)
	local spot = state.safeSpot
	if not ctrl.engaged or not spot or ctrl.pos.Y >= spot.Y - 5 then return end
	ctrl.displaced = false
	if waitForTeleport then
		local deadline = os.clock() + 4
		while ctrl.engaged and not ctrl.displaced and stillOwner() and os.clock() < deadline do
			RunService.Heartbeat:Wait()
		end
		if ctrl.displaced then return end
	end
	if ctrl.engaged then
		state.parking = true
		moveTo(spot)
		state.parking = false
	end
end

local function parkAndRelease()
	park(false)
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

local Rivals = { list = {}, history = setmetatable({}, { __mode = "k" }), at = -1 }

function Rivals.get()
	local now = os.clock()
	if now - Rivals.at < 0.1 then return Rivals.list end
	Rivals.at = now
	local list = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= LocalPlayer and player:GetAttribute("Alive") ~= false then
			local char = player.Character
			local root = char and char:FindFirstChild("HumanoidRootPart")
			local hum = char and char:FindFirstChildOfClass("Humanoid")
			if root and hum and hum.Health > 0 then
				local pos = root.Position
				if not state.map or nearMap(state.map, pos) then
					local h = Rivals.history[player]
					local vel = Vector3.zero
					if h and now - h.t > 0.05 and now - h.t < 1 then
						vel = (pos - h.pos) / (now - h.t)
						if vel.Magnitude > 60 then vel = Vector3.zero end
					end
					Rivals.history[player] = { pos = pos, t = now }
					list[#list + 1] = { pos = pos, vel = vel }
				end
			end
		end
	end
	Rivals.list = list
	return list
end

local function rivalEta(rival, pos)
	local offset = pos - rival.pos
	local dist = offset.Magnitude
	if dist < 0.01 then return 0 end
	local moving = rival.vel.Magnitude > 2
	local toward = moving and rival.vel:Dot(offset.Unit) or 0
	if moving and toward < -4 then return dist / 4 end
	local speed = CFG.rivalSpeed
	if toward > speed then speed = toward end
	return dist / speed
end

local function rivalWillClaim(pos, ourEta, rivalsNow)
	for _, rival in ipairs(rivalsNow) do
		if (rival.pos - pos).Magnitude < CFG.rivalRadius then
			if rivalEta(rival, pos) < ourEta + 0.1 then return true end
		end
	end
	return false
end

local function travel(from, pos, floorY)
	if state.mode == "dive" then
		local under = Vector3.new(pos.X, diveY(floorY or pos.Y), pos.Z)
		return (under - from).Magnitude + (pos - under).Magnitude
	end
	return (pos - from).Magnitude
end

local function score(coin, pos, from, rivalsNow)
	local dist = travel(from, pos, floorOf(coin, pos))
	local cost = dist * Memory.penalty(state.mem, toLocal(pos))
	local eta = dist / math.min(CFG.speed, MAX_SPEED)
	if rivalWillClaim(pos, eta, rivalsNow) then return cost * 3 + 40, true end
	return cost, false
end

local function pickCoin(coins, from, exclude)
	local rivalsNow = Rivals.get()
	local best, bestPos, bestCost
	for _, coin in ipairs(coins) do
		local pos = coin ~= exclude and coinPos(coin)
		if pos then
			if not seenCoin[coin] then
				seenCoin[coin] = true
				Memory.spawned(state.mem, toLocal(pos))
			end
			local cost = score(coin, pos, from, rivalsNow)
			if not bestCost or cost < bestCost then best, bestPos, bestCost = coin, pos, cost end
		end
	end
	return best, bestPos, bestCost
end

local confirmDelay = 0.35
local function collect(coin, pos, floorY, cc)
	local events = Bag.events
	local waitLimit = math.min(CFG.touchTime, math.max(0.4, confirmDelay * 3))
	local nextCheck = os.clock() + 0.3
	local function lost()
		if roundOver() or not coinAlive(coin) then return true end
		if os.clock() < nextCheck then return false end
		nextCheck = os.clock() + 0.3
		local current, contested = score(coin, pos, ctrl.pos, Rivals.get())
		if contested and (ctrl.pos - pos).Magnitude > CFG.rivalClaim then return true end
		if current < 8 then return false end
		local _, _, alt = pickCoin(listCoins(cc), ctrl.pos, coin)
		return alt ~= nil and alt < current * 0.6
	end
	local function settle()
		if coinAlive(coin) then return "aborted" end
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

local function waitForCoins(cc)
	if not ctrl.engaged then return end
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

local function resetCharacter()
	state.resetAt = os.clock()
	local _, hum = getChar()
	if not hum then return end
	pcall(function() hum:ChangeState(Enum.HumanoidStateType.Dead) end)
	pcall(function() hum.Health = 0 end)
end

local function bagFull()
	state.roundDone = "bag_full"
	setPhase("bag_full")
	setFarming(false)
	resetCharacter()
end

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
	ctrl.displaced = false
	table.clear(retryAt)
	clearTraps(map)
	print(string.format("[MM2] round on %s (rounds remembered: %d)", map.Name, state.mem.rounds))
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
	setFarming(false)
end

local function holdStill(char, hum, hrp)
	if ctrl.engaged then return end
	if engage(char, hum, hrp) then ctrl.target = nil end
end

local function farmStep()
	if game.PlaceId ~= PLACE_ID then
		release()
		setFarming(false)
		setPhase("wrong_game")
		return 2
	end

	local char, hum, hrp = getChar()
	if not char then
		if state.map and not state.roundDone and LocalPlayer:GetAttribute("Alive") ~= true then
			if ctrl.diedAt then Memory.died(state.mem, toLocal(ctrl.diedAt)) end
			state.roundDone = "dead"
		end
		release()
		setFarming(false)
		setPhase(state.roundDone == "dead" and "dead" or "waiting")
		return 0.5
	end

	holdStill(char, hum, hrp)

	local map, cc = findMap()
	local alive = LocalPlayer:GetAttribute("Alive")
	local onMap = map ~= nil and alive ~= false and nearMap(map, hrp.Position)
	if not onMap then
		if state.map then
			park(true)
			endRound()
		end
		ctrl.displaced = false
		setPhase("waiting")
		return 0.5
	end

	if state.map ~= map then
		if state.map then endRound() end
		startRound(map, hrp)
	end
	if state.roundDone then
		if state.roundDone == "bag_full" and os.clock() - (state.resetAt or 0) > 3 then resetCharacter() end
		setPhase(state.roundDone)
		return 0.5
	end

	if ctrl.displaced then
		ctrl.displaced = false
		state.cooldownUntil = os.clock() + 1.5
	end
	if os.clock() < state.cooldownUntil then return 0.2 end

	if bagIsFull() then
		bagFull()
		return 0.5
	end

	if not engage(char, hum, hrp) then return 0.5 end

	local coins = listCoins(cc)
	if #coins == 0 then
		setPhase("no_coins")
		waitForCoins(cc)
		return 0.3
	end

	local coin, pos = pickCoin(coins, ctrl.pos)
	if not coin then return 0.3 end
	local floorY = floorOf(coin, pos)
	if floorY then state.safeSpot = Vector3.new(pos.X, floorY + 3, pos.Z) end
	setFarming(true)
	setPhase("farming")

	local result = collect(coin, pos, floorY, cc)
	if result == "collected" then
		state.roundCoins += 1
		state.totalCoins += 1
		state.misses = 0
		Memory.result(state.mem, toLocal(pos), true)
	elseif result == "missed" then
		state.misses += 1
		local known, _, anyFull, exact = Bag.status()
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
				setFarming(false)
				warn("[MM2] " .. state.lastError)
				pcall(park, false)
				task.wait(1)
			end
		else
			setPhase("off")
			setFarming(false)
			if ctrl.engaged then pcall(parkAndRelease) end
			task.wait(0.25)
		end
	end
end

window:Toggle({
	Text = "Auto-farm",
	Default = true,
	Callback = function(on)
		state.running = on
	end,
})

window:Segmented({
	Text = "Mode",
	Options = { "Normal", "Dive" },
	Default = "Normal",
	Callback = function(value)
		state.mode = value == "Dive" and "dive" or "normal"
	end,
})

local function setRendering(enabled)
	pcall(function() RunService:Set3dRenderingEnabled(enabled) end)
end

window:Toggle({
	Text = "Disable rendering",
	Default = false,
	Callback = function(off)
		setRendering(not off)
	end,
})

local statusLabel = window:Label({ Text = "Status: -" })
local totalLabel = window:Label({ Text = "Coins: 0 · Time: 0:00" })

local function formatTime(seconds)
	seconds = math.floor(seconds)
	local h = seconds // 3600
	local m = (seconds % 3600) // 60
	local s = seconds % 60
	if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
	return string.format("%d:%02d", m, s)
end

local function updateUI()
	local text = PHASE_TEXT[state.phase] or state.phase
	if state.phase == "error" and state.lastError then text = text .. ": " .. state.lastError end
	statusLabel:SetText("Status: " .. text)
	totalLabel:SetText(string.format("Coins: %d · Time: %s", state.totalCoins, formatTime(farmTime())))
end

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

window:OnDestroy(function()
	state.running = false
	setFarming(false)
	setRendering(true)
	stopAntiFling()
	local spot = state.safeSpot
	if ctrl.engaged and spot and ctrl.pos.Y < spot.Y - 5 then
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

return "ready (memory=" .. tostring(Memory.persistent) .. ")"
