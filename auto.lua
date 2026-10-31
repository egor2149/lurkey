-- MM2 coin auto-farm: one switch and a mode selector.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer
local PLACE_ID = 142823291

local CFG = {
	speed = 23, -- studs/s
	diveDepth = 25, -- studs under the floor in dive mode
	touchTime = 1, -- seconds to wait on a coin for the server to register it
	retryAfter = 20, -- seconds before a missed coin is tried again
	missLimit = 4, -- consecutive misses treated as a full bag when the bag HUD can't be read
	mapMargin = 60, -- studs outside the map bounds that still count as "on the map"
}

local UI_URL = "https://raw.githubusercontent.com/Project-Ptolemy/ProjectUAI/main/dist/uai-ui.lua"
local UI
do
	local loader = loadstring or load
	if type(loader) ~= "function" then
		error("executor missing loadstring")
	end
	local ok, result = pcall(function()
		return loader(game:HttpGet(UI_URL))()
	end)
	if not ok or type(result) ~= "table" then
		error("UI lib failed: " .. tostring(result))
	end
	UI = result
end

-- Creating the window destroys a previous instance's window (same Id), which
-- lets that instance hand the character back before we claim ownership.
local window = UI:CreateWindow({
	Id = "mm2-collect",
	Title = "MM2 Collect",
	Subtitle = "автофарм монет",
})

local ENV
do
	local ok, env = pcall(function() return getgenv() end)
	if ok and type(env) == "table" then ENV = env end
end
local TOKEN = {}
if ENV then ENV.MM2_TOKEN = TOKEN end

local function stillOwner()
	return not ENV or ENV.MM2_TOKEN == TOKEN
end

local function giveToWindow(resource)
	if type(window.Give) == "function" then
		pcall(function() window:Give(resource) end)
	end
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
		local step = CFG.speed * math.min(dt, 0.1)
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

local function listCoins(cc)
	local now = os.clock()
	local coins = {}
	for _, coin in ipairs(cc:GetChildren()) do
		if (coin:IsA("BasePart") or coin:IsA("Model")) and (retryAt[coin] or 0) <= now and coinAlive(coin) then
			coins[#coins + 1] = coin
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

-- Reads the bag HUD: known, every bag full, any bag full.
local function bagUI()
	local ok, known, all, any = pcall(function()
		local container = LocalPlayer.PlayerGui.MainGUI.Game.CoinBags.Container
		local known, all, any = false, true, false
		for _, bag in ipairs(container:GetChildren()) do
			local icon = bag:FindFirstChild("FullBagIcon")
			if icon and bag:IsA("GuiObject") and bag.Visible then
				known = true
				if icon.Visible then any = true else all = false end
			end
		end
		return known, all, any
	end)
	if not ok or not known then return false, false, false end
	return true, all, any
end

local function bagIsFull()
	local known, all, any = bagUI()
	if known and all then return true end
	if known and any then return state.misses >= 2 end
	-- the HUD may be missing or misread, so repeated misses still end the round
	return state.misses >= (known and CFG.missLimit * 2 or CFG.missLimit)
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
	Vector3.new(0, 0, 1.5),
	Vector3.new(0, 0, -1.5),
	Vector3.zero,
}

local function collect(coin, pos, floorY)
	local function lost()
		return roundOver() or not coinAlive(coin)
	end
	local function settle()
		if coinAlive(coin) then return "aborted" end
		-- it vanished as we reached it, so it was ours; otherwise someone else took it
		return (ctrl.pos - pos).Magnitude <= 6 and "collected" or "gone"
	end

	if state.mode == "dive" then
		if not moveTo(Vector3.new(pos.X, diveY(floorY or pos.Y), pos.Z), lost) then return settle() end
	end
	if not moveTo(pos, lost) then return settle() end

	touch(coin)
	local start, nudge = os.clock(), 0
	while ctrl.engaged and os.clock() - start < CFG.touchTime do
		if not coinAlive(coin) then return "collected" end
		if roundOver() or not (state.running and stillOwner()) then return "aborted" end
		local due = math.floor((os.clock() - start) / 0.2)
		if due > nudge and due <= #NUDGES then
			nudge = due
			ctrl.target = pos + NUDGES[nudge]
		end
		RunService.Heartbeat:Wait()
	end
	if not coinAlive(coin) then return "collected" end
	return ctrl.engaged and "missed" or "aborted"
end

local function pickCoin(coins, from)
	local best, bestPos, bestCost
	for _, coin in ipairs(coins) do
		local pos = coinPos(coin)
		if pos then
			local lp = toLocal(pos)
			if not seenCoin[coin] then
				seenCoin[coin] = true
				Memory.spawned(state.mem, lp)
			end
			local cost = (pos - from).Magnitude * Memory.penalty(state.mem, lp)
			if not bestCost or cost < bestCost then
				best, bestPos, bestCost = coin, pos, cost
			end
		end
	end
	return best, bestPos
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
		if state.map and not state.roundDone then
			if ctrl.diedAt then Memory.died(state.mem, toLocal(ctrl.diedAt)) end
			state.roundDone = "dead"
		end
		release()
		setPhase(state.map and "dead" or "waiting")
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
	local floorY = floorBelow(pos)
	if floorY then state.safeSpot = Vector3.new(pos.X, floorY + 3, pos.Z) end
	if not engage(char, hum, hrp) then return 0.5 end
	setPhase("farming")

	local result = collect(coin, pos, floorY)
	if result == "collected" then
		state.roundCoins += 1
		state.totalCoins += 1
		state.misses = 0
		Memory.result(state.mem, toLocal(pos), true)
		if state.totalCoins % 10 == 0 then
			print(string.format("[MM2] всего %d (раунд %d)", state.totalCoins, state.roundCoins))
		end
	elseif result == "missed" then
		retryAt[coin] = os.clock() + CFG.retryAfter
		state.misses += 1
		local known, _, anyFull = bagUI()
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
			if ctrl.engaged then pcall(parkAndRelease, false) end
			setPhase("off")
			task.wait(0.25)
		end
	end
end

---------------------------------------------------------------------------
-- UI
---------------------------------------------------------------------------
local tab = window:Tab({ Title = "Фарм" })
local section = tab:Section({ Title = "Автофарм" })

section:Toggle({
	Id = "enabled",
	Text = "Автофарм",
	Description = "Собирает монеты каждый раунд. Выключение возвращает управление персонажу.",
	Default = true,
	Callback = function(on)
		state.running = on
	end,
})

section:Segmented({
	Id = "mode",
	Text = "Режим",
	Description = "Обычный — летит прямо к монете. Выныривание — идёт под картой и поднимается к монете снизу.",
	Options = { "Обычный", "Выныривание" },
	Default = "Обычный",
	Callback = function(value)
		state.mode = value == "Выныривание" and "dive" or "normal"
	end,
})

local statusLabel = section:Label({ Text = "Статус: —" })
local memoryLabel = section:Label({ Text = "Память: —" })

local function updateUI()
	local text = PHASE_TEXT[state.phase] or state.phase
	if state.phase == "error" and state.lastError then text = text .. ": " .. state.lastError end
	statusLabel:SetText(string.format("Статус: %s · за раунд %d · всего %d", text, state.roundCoins, state.totalCoins))
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
giveToWindow(task.spawn(farmLoop))
giveToWindow(task.spawn(function()
	while stillOwner() do
		pcall(updateUI)
		pcall(Memory.save, false)
		task.wait(0.4)
	end
end))

if type(window.OnDestroy) == "function" then
	window:OnDestroy(function()
		state.running = false
		if ctrl.engaged and state.safeSpot and ctrl.pos.Y < state.safeSpot.Y - 5 then
			-- the controller is gone with the window, so hop straight out from under the map
			pcall(function() ctrl.hrp.CFrame = CFrame.new(state.safeSpot) * ctrl.rot end)
		end
		release()
		pcall(Memory.save, true)
		if ENV and ENV.MM2_TOKEN == TOKEN then ENV.MM2_TOKEN = nil end
	end)
end

return "ready (memory=" .. tostring(Memory.persistent) .. ")"
