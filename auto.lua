local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
local PLACE_ID = 142823291
local rng = Random.new()

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

local CFG = {
	speed = 23,
	diveDepth = 25,
	touchHold = 0.06,
	failLimit = 3,
	blacklistTime = 25,
	emptyWait = 3,
	endBuffer = 3,
	bagCap = 0, -- 0 = use the game's bag signal or the learned cap
	maxMapDist = 1200,
	collectRadius = 9,
	holdMethod = "anchor", -- "anchor" | "hover"; memory may override
	avoidMurderer = true,
	dangerRadius = 22,
	lookahead = 0.5,
	learning = true,
	autosave = 20,
	exploreRate = 0.1,
	signalWait = 0.3,
}

local ENV
do
	local ok, env = pcall(function() return getgenv() end)
	if ok and type(env) == "table" then ENV = env end
end
local TOKEN = {}
if ENV then ENV.MM2_TOKEN = TOKEN end

local function stillOwner()
	if not ENV then return true end
	return ENV.MM2_TOKEN == TOKEN
end

local conns = {}
local function track(conn)
	conns[#conns + 1] = conn
	return conn
end
local function disconnectAll()
	for _, c in ipairs(conns) do
		pcall(function() c:Disconnect() end)
	end
	table.clear(conns)
end

local window = nil

local state = {
	running = false,
	phase = "waiting",
	mode = "normal", -- user choice: normal | dive | auto
	activeMode = "normal", -- mode actually used this round
	holdMethod = CFG.holdMethod,
	inRound = false,
	roundOver = false,
	mapEmpty = false,
	bagFull = false,
	parked = false,
	roundCollected = 0,
	totalCollected = 0,
	failures = 0,
	emptySince = nil,
	lastSafe = nil,
	lastPos = nil,
	coinsOnMap = 0,
	roundSeconds = nil,
	lastError = nil,
	thread = nil,
	frozen = false,
	noclip = false,
	tweening = false,
	holdCFrame = nil,
	lastPhasePrinted = nil,
	roundContainer = nil,
	endedContainer = nil,
	roundMap = nil,
	roundMapName = nil,
	roundStart = 0,
	roundRecorded = true,
	methodSwitched = false,
	deathHandled = false,
	sessionStart = os.clock(),
	-- game signals (optional, hooked if the remotes exist)
	coinRemoteHooked = false,
	coinSignalSeen = false,
	lastCoinSignal = nil,
	bagCount = nil,
	bagMax = nil,
	roundStartSignal = false,
	roundEndSignal = false,
}

local blacklist = setmetatable({}, { __mode = "k" })
local partCollide = setmetatable({}, { __mode = "k" })
local seenCoins = setmetatable({}, { __mode = "k" })
local coinGround = setmetatable({}, { __mode = "k" })

local PHASE_TEXT = {
	waiting = "ждём раунд",
	farming = "сбор монет",
	bagfull = "мешок полон — до конца раунда",
	round_end = "раунд закончился — ждём следующий",
	no_coins = "монет на карте нет",
	threat = "убийца рядом — ждём",
	dead = "персонаж мёртв",
	wrong_game = "не та игра",
	stopped = "остановлено",
	error = "ошибка",
}

local function setPhase(phase)
	state.phase = phase
	if state.lastPhasePrinted ~= phase then
		state.lastPhasePrinted = phase
		print("[MM2] " .. phase .. " | " .. (PHASE_TEXT[phase] or ""))
	end
end

---------------------------------------------------------------------------
-- Memory: persistent per-map knowledge (spawn hotspots, ground heights,
-- per-spot reliability, death zones, mode/hold-method performance, bag cap).
---------------------------------------------------------------------------
local Memory = {}
do
	local VERSION = 1
	local CELL = 4
	local DANGER_CELL = 16
	local MAX_CELLS = 800
	local MAX_GROUND = 2000
	local MAX_MAPS = 60
	local MIN_MODE_TIME = 45
	local MIN_HOLD_SAMPLES = 20

	local canFs = type(readfile) == "function" and type(writefile) == "function"
	local hasFolders = type(isfolder) == "function" and type(makefolder) == "function"
	local DIR = "mm2_collect"
	local FILE = hasFolders and (DIR .. "/memory.json") or "mm2_collect_memory.json"

	local data
	local dirty = false
	local lastSave = 0

	local function fresh()
		return {
			version = VERSION,
			global = { sessions = 0, coins = 0, bagCap = nil, hold = {} },
			maps = {},
		}
	end

	local function key3(pos)
		return string.format("%d:%d:%d", math.floor(pos.X / CELL), math.floor(pos.Y / CELL), math.floor(pos.Z / CELL))
	end

	local function key2(pos)
		return string.format("%d:%d", math.floor(pos.X / DANGER_CELL), math.floor(pos.Z / DANGER_CELL))
	end

	local function center3(key)
		local x, y, z = key:match("^(-?%d+):(-?%d+):(-?%d+)$")
		if not x then return nil end
		return Vector3.new((tonumber(x) + 0.5) * CELL, (tonumber(y) + 0.5) * CELL, (tonumber(z) + 0.5) * CELL)
	end

	local function ema(old, value, alpha)
		if old == nil then return value end
		return old + (value - old) * alpha
	end

	local function trimTable(t, limit, score)
		local keys = {}
		for k in pairs(t) do keys[#keys + 1] = k end
		if #keys <= limit then return end
		if score then
			table.sort(keys, function(a, b) return score(t[a]) > score(t[b]) end)
		end
		for i = limit + 1, #keys do t[keys[i]] = nil end
	end

	local function normalize(m)
		m.rounds = m.rounds or 0
		m.deaths = m.deaths or 0
		m.cells = m.cells or {}
		m.ground = m.ground or {}
		m.danger = m.danger or {}
		m.modes = m.modes or {}
		for _, mode in ipairs({ "normal", "dive" }) do
			local s = m.modes[mode] or {}
			s.coins, s.time, s.deaths = s.coins or 0, s.time or 0, s.deaths or 0
			m.modes[mode] = s
		end
		return m
	end

	function Memory.persistent()
		return canFs
	end

	function Memory.load()
		data = fresh()
		if canFs then
			local raw
			pcall(function()
				if type(isfile) ~= "function" or isfile(FILE) then raw = readfile(FILE) end
			end)
			if type(raw) == "string" and raw ~= "" then
				local ok, decoded = pcall(function() return HttpService:JSONDecode(raw) end)
				if ok and type(decoded) == "table" and decoded.version == VERSION and type(decoded.maps) == "table" then
					data = decoded
					data.global = type(data.global) == "table" and data.global or fresh().global
					data.global.hold = type(data.global.hold) == "table" and data.global.hold or {}
					for name, m in pairs(data.maps) do
						if type(m) == "table" then normalize(m) else data.maps[name] = nil end
					end
				else
					-- keep the unreadable file instead of silently overwriting it
					pcall(function() writefile(FILE .. ".bak", raw) end)
				end
			end
		end
		data.global.sessions = (data.global.sessions or 0) + 1
		dirty = true
	end

	function Memory.prune()
		local names = {}
		for name in pairs(data.maps) do names[#names + 1] = name end
		if #names > MAX_MAPS then
			table.sort(names, function(a, b)
				return (data.maps[a].lastSeen or 0) > (data.maps[b].lastSeen or 0)
			end)
			for i = MAX_MAPS + 1, #names do data.maps[names[i]] = nil end
		end
		for _, m in pairs(data.maps) do
			trimTable(m.cells, MAX_CELLS, function(c) return (c.s or 0) + (c.o or 0) + (c.f or 0) end)
			trimTable(m.ground, MAX_GROUND, nil)
		end
	end

	function Memory.save(force)
		if not canFs or not data or not dirty then return end
		if not force and os.clock() - lastSave < CFG.autosave then return end
		lastSave = os.clock()
		Memory.prune()
		local ok, encoded = pcall(function() return HttpService:JSONEncode(data) end)
		if not ok then return end
		local wrote = pcall(function()
			if hasFolders and not isfolder(DIR) then makefolder(DIR) end
			writefile(FILE, encoded)
		end)
		if wrote then dirty = false end
	end

	function Memory.map(name)
		local m = data.maps[name]
		if not m then
			m = normalize({})
			data.maps[name] = m
		end
		m.lastSeen = os.time()
		dirty = true
		return m
	end

	function Memory.forget(name)
		if name and data.maps[name] then
			data.maps[name] = nil
			dirty = true
		end
	end

	local function cell(m, pos)
		local k = key3(pos)
		local c = m.cells[k]
		if not c then
			c = { s = 0, o = 0, f = 0 }
			m.cells[k] = c
		end
		return c
	end

	function Memory.noteSpawn(m, pos)
		if not CFG.learning then return end
		local c = cell(m, pos)
		c.s += 1
		dirty = true
	end

	function Memory.noteResult(m, pos, success)
		if not CFG.learning then return end
		local c = cell(m, pos)
		if success then c.o += 1 else c.f += 1 end
		dirty = true
	end

	-- Laplace-style estimate; unknown spots are treated as reliable.
	function Memory.reliability(m, pos)
		local c = m.cells[key3(pos)]
		if not c then return 1 end
		return (c.o + 1) / (c.o + c.f + 1)
	end

	function Memory.failCount(m, pos)
		local c = m.cells[key3(pos)]
		return c and c.f or 0
	end

	function Memory.ground(m, pos)
		return m.ground[key3(pos)]
	end

	function Memory.setGround(m, pos, y)
		if not CFG.learning then return end
		m.ground[key3(pos)] = math.floor(y * 10 + 0.5) / 10
		dirty = true
	end

	function Memory.noteDeath(m, pos, mode)
		if not CFG.learning then return end
		local k = key2(pos)
		m.danger[k] = (m.danger[k] or 0) + 1
		m.deaths += 1
		if m.modes[mode] then m.modes[mode].deaths += 1 end
		dirty = true
	end

	function Memory.danger(m, pos)
		return m.danger[key2(pos)] or 0
	end

	function Memory.noteRound(m, coins)
		if not CFG.learning then return end
		m.rounds += 1
		m.coinsEma = ema(m.coinsEma, coins, 0.3)
		-- old deaths matter less over time
		for k, v in pairs(m.danger) do
			v *= 0.9
			m.danger[k] = v >= 0.2 and v or nil
		end
		dirty = true
	end

	function Memory.noteMode(m, mode, coins, seconds)
		if not CFG.learning then return end
		local s = m.modes[mode]
		if not s then return end
		s.coins += coins
		s.time += seconds
		data.global.coins = (data.global.coins or 0) + coins
		dirty = true
	end

	-- Coins per second, with each death charged as 30s of lost farming.
	function Memory.modeRate(m, mode)
		local s = m.modes[mode]
		if not s or s.time <= 0 then return nil end
		return s.coins / (s.time + s.deaths * 30)
	end

	function Memory.pickMode(m)
		local n, d = m.modes.normal, m.modes.dive
		if n.time < MIN_MODE_TIME or d.time < MIN_MODE_TIME then
			return n.time <= d.time and "normal" or "dive"
		end
		local best = (Memory.modeRate(m, "normal") or 0) >= (Memory.modeRate(m, "dive") or 0) and "normal" or "dive"
		if rng:NextNumber() < CFG.exploreRate then
			return best == "normal" and "dive" or "normal"
		end
		return best
	end

	function Memory.noteHold(method, success)
		if not CFG.learning then return end
		local h = data.global.hold[method] or { o = 0, f = 0 }
		data.global.hold[method] = h
		if success then h.o += 1 else h.f += 1 end
		dirty = true
	end

	function Memory.pickHold(default)
		local a, h = data.global.hold.anchor, data.global.hold.hover
		if not a or not h then return default end
		if a.o + a.f < MIN_HOLD_SAMPLES or h.o + h.f < MIN_HOLD_SAMPLES then return default end
		return (a.o / (a.o + a.f)) >= (h.o / (h.o + h.f)) and "anchor" or "hover"
	end

	function Memory.setBagCap(n)
		if type(n) == "number" and n > 0 and data.global.bagCap ~= n then
			data.global.bagCap = n
			dirty = true
		end
	end

	function Memory.bagCap()
		return data.global.bagCap
	end

	-- Best spot to wait for respawning coins: frequent spawn cells, nearby preferred.
	function Memory.hotspot(m, from)
		local bestPos, bestGround, bestScore
		for k, c in pairs(m.cells) do
			if c.s >= 2 then
				local pos = center3(k)
				if pos then
					local score = c.s / (1 + (pos - from).Magnitude / 150)
					if not bestScore or score > bestScore then
						bestPos, bestGround, bestScore = pos, m.ground[k], score
					end
				end
			end
		end
		return bestPos, bestGround
	end

	function Memory.summary()
		local maps, cells = 0, 0
		for _, m in pairs(data.maps) do
			maps += 1
			for _ in pairs(m.cells) do cells += 1 end
		end
		return maps, cells, data.global.sessions or 0
	end
end

Memory.load()
state.holdMethod = Memory.pickHold(CFG.holdMethod)

---------------------------------------------------------------------------
-- Character control
---------------------------------------------------------------------------
local function getChar()
	local char = LocalPlayer.Character
	if not char then return nil end
	return char, char:FindFirstChildOfClass("Humanoid"), char:FindFirstChild("HumanoidRootPart")
end

local function setFrozen(on)
	local _, hum, hrp = getChar()
	state.frozen = on
	if on then
		if hrp then
			state.holdCFrame = hrp.CFrame
			pcall(function() hrp.Anchored = state.holdMethod == "anchor" end)
		end
		if hum then
			pcall(function()
				hum.AutoRotate = false
				hum.PlatformStand = true
			end)
		end
	else
		state.holdCFrame = nil
		if hrp then pcall(function() hrp.Anchored = false end) end
		if hum then
			pcall(function()
				hum.AutoRotate = true
				hum.PlatformStand = false
			end)
		end
	end
end

local function setNoclip(on)
	state.noclip = on
	if on then return end -- enforced every Stepped while on
	for part, value in pairs(partCollide) do
		if part and part.Parent then pcall(function() part.CanCollide = value end) end
	end
	table.clear(partCollide)
end

local function resetCharacter()
	setNoclip(false)
	setFrozen(false)
	local _, hum = getChar()
	if hum and hum.Health > 0 then
		pcall(function() hum:ChangeState(Enum.HumanoidStateType.Freefall) end)
	end
end

-- Humanoids re-enable collision on body parts each step, so noclip must be reapplied.
track(RunService.Stepped:Connect(function()
	if not state.noclip or not stillOwner() then return end
	local char = LocalPlayer.Character
	if not char then return end
	for _, part in ipairs(char:GetDescendants()) do
		if part:IsA("BasePart") and part.CanCollide then
			if partCollide[part] == nil then partCollide[part] = true end
			part.CanCollide = false
		end
	end
end))

-- Keeps the character in place between tweens; "hover" stays unanchored so
-- physics/touch replication keeps working.
track(RunService.Heartbeat:Connect(function()
	if not state.frozen or not stillOwner() then return end
	local _, hum, hrp = getChar()
	if not hrp then return end
	local anchor = state.holdMethod == "anchor"
	if hrp.Anchored ~= anchor then hrp.Anchored = anchor end
	if not anchor then
		hrp.AssemblyLinearVelocity = Vector3.zero
		hrp.AssemblyAngularVelocity = Vector3.zero
		if not state.tweening and state.holdCFrame then hrp.CFrame = state.holdCFrame end
	end
	if hum and not hum.PlatformStand then hum.PlatformStand = true end
end))

---------------------------------------------------------------------------
-- Game signals (optional). If these remotes are absent we fall back to
-- heuristics, so nothing here is required for farming.
---------------------------------------------------------------------------
local function onCoinCollected(...)
	local nums = {}
	for i = 1, select("#", ...) do
		local n = tonumber((select(i, ...)))
		if n then nums[#nums + 1] = n end
	end
	state.coinSignalSeen = true
	state.lastCoinSignal = os.clock()
	if #nums >= 2 and nums[2] > 0 then
		state.bagCount, state.bagMax = nums[1], nums[2]
		Memory.setBagCap(nums[2])
		if nums[1] >= nums[2] then state.bagFull = true end
	end
end

local function hookRemotes()
	local function find(name)
		local ok, r = pcall(function() return ReplicatedStorage:FindFirstChild(name, true) end)
		if ok and r and r:IsA("RemoteEvent") then return r end
		return nil
	end
	local coinEv = find("CoinCollected")
	if coinEv then
		state.coinRemoteHooked = true
		track(coinEv.OnClientEvent:Connect(onCoinCollected))
	end
	local startEv = find("RoundStart")
	if startEv then
		track(startEv.OnClientEvent:Connect(function()
			state.roundStartSignal = true
			state.bagCount = 0
		end))
	end
	local endEv = find("RoundEndFade")
	if endEv then
		track(endEv.OnClientEvent:Connect(function()
			state.roundEndSignal = true
		end))
	end
end
pcall(hookRemotes)

---------------------------------------------------------------------------
-- World queries
---------------------------------------------------------------------------
local function getCoinContainers()
	local list = {}
	for _, model in ipairs(Workspace:GetChildren()) do
		local cc = model:FindFirstChild("CoinContainer")
		if cc and cc:IsA("Model") then
			list[#list + 1] = cc
		end
	end
	if #list == 0 then
		for _, model in ipairs(Workspace:GetChildren()) do
			if model:IsA("Model") or model:IsA("Folder") then
				for _, sub in ipairs(model:GetChildren()) do
					local cc = sub:FindFirstChild("CoinContainer")
					if cc and cc:IsA("Model") then
						list[#list + 1] = cc
					end
				end
			end
		end
	end
	return list
end

-- Distance to the nearest coin, falling back to the map pivot when empty.
local function containerDistance(cc, from)
	local best
	for _, c in ipairs(cc:GetChildren()) do
		if c:IsA("BasePart") then
			local d = (c.Position - from).Magnitude
			if not best or d < best then best = d end
		end
	end
	if best then return best end
	local ok, pos = pcall(function() return (cc.Parent or cc):GetPivot().Position end)
	return ok and pos and (pos - from).Magnitude or math.huge
end

local function mapNameOf(cc)
	local parent = cc.Parent
	if parent and parent ~= Workspace then return parent.Name end
	return "unknown"
end

local function pickContainer(hrp)
	-- the current round's container stays selected even after it empties out
	local current = state.roundContainer
	if state.inRound and current and current.Parent then
		return current, mapNameOf(current)
	end
	local best, bestD
	for _, cc in ipairs(getCoinContainers()) do
		local d = containerDistance(cc, hrp.Position)
		if d <= CFG.maxMapDist and (not bestD or d < bestD) then
			best, bestD = cc, d
		end
	end
	if best then return best, mapNameOf(best) end
	return nil
end

local function coinGone(coin)
	if coin.Parent == nil then return true end
	local collected = false
	pcall(function() collected = coin:GetAttribute("Collected") == true end)
	if collected then return true end
	local transparent = false
	pcall(function() transparent = coin.Transparency >= 0.95 end)
	return transparent
end

local function listCoins(containers)
	local now = os.clock()
	local list = {}
	for _, cc in ipairs(containers) do
		for _, c in ipairs(cc:GetChildren()) do
			if c:IsA("BasePart") and c.Name == "Coin_Server" and not coinGone(c) and (blacklist[c] or 0) < now then
				list[#list + 1] = c
			end
		end
	end
	return list
end

local function roundSeconds()
	local rt = Workspace:FindFirstChild("RoundTimerPart")
	if not rt then return nil end
	for _, d in ipairs(rt:GetDescendants()) do
		if d:IsA("TextLabel") then
			local text = d.Text
			local m, s = text:match("(%d+)%s*:%s*(%d+)")
			if not m then m, s = text:match("(%d+)%s*m%s*(%d+)%s*s") end
			if m and s then return tonumber(m) * 60 + tonumber(s) end
			local only = text:match("^%s*(%d+)%s*s?%s*$")
			if only then return tonumber(only) end
		end
	end
	return nil
end

local function makeRayParams(containers)
	local filter = {}
	for _, p in ipairs(Players:GetPlayers()) do
		if p.Character then filter[#filter + 1] = p.Character end
	end
	for _, cc in ipairs(containers or {}) do filter[#filter + 1] = cc end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = filter
	params.IgnoreWater = true
	return params
end

local function groundY(pos, params)
	local ok, result = pcall(function()
		return Workspace:Raycast(pos + Vector3.new(0, 2, 0), Vector3.new(0, -140, 0), params)
	end)
	if ok and result then return result.Position.Y, true end
	return pos.Y - 16, false
end

-- Coin position + ground height; ground is cached per coin and in memory.
local function coinInfo(coin, m, params)
	local cached = coinGround[coin]
	if cached then return cached end
	local ok, pos = pcall(function() return coin.Position end)
	if not ok or not pos then return nil end
	local gy = m and Memory.ground(m, pos)
	if not gy then
		local hit
		gy, hit = groundY(pos, params)
		if hit and m then Memory.setGround(m, pos, gy) end
	end
	local info = { pos = pos, gy = gy }
	coinGround[coin] = info
	return info
end

local function hasKnife(player)
	local found = false
	pcall(function()
		local char = player.Character
		local backpack = player:FindFirstChildOfClass("Backpack")
		found = (char and char:FindFirstChild("Knife") ~= nil) or (backpack and backpack:FindFirstChild("Knife") ~= nil) or false
	end)
	return found
end

local function murdererPositions()
	local list = {}
	if hasKnife(LocalPlayer) then return list end
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= LocalPlayer and hasKnife(p) then
			local root = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
			if root then list[#list + 1] = root.Position end
		end
	end
	return list
end

local function nearThreat(pos, threats, radius)
	for _, t in ipairs(threats) do
		if (t - pos).Magnitude < radius then return true end
	end
	return false
end

---------------------------------------------------------------------------
-- Movement and collection
---------------------------------------------------------------------------
local function tweenTo(hrp, targetPos, guard)
	if not hrp or not hrp.Parent then return false end
	local okStart, startPos = pcall(function() return hrp.Position end)
	if not okStart then return false end
	local dist = (targetPos - startPos).Magnitude
	if dist < 0.2 then return true end
	local duration = math.max(dist / math.max(CFG.speed, 1), 0.03)
	local goal = CFrame.new(targetPos) * hrp.CFrame.Rotation
	local tween = TweenService:Create(hrp, TweenInfo.new(duration, Enum.EasingStyle.Linear, Enum.EasingDirection.Out), { CFrame = goal })
	state.tweening = true
	tween:Play()

	local function finish(success)
		if tween.PlaybackState == Enum.PlaybackState.Playing then tween:Cancel() end
		tween:Destroy()
		state.tweening = false
		if hrp.Parent then state.holdCFrame = success and goal or hrp.CFrame end
		return success
	end

	while tween.PlaybackState == Enum.PlaybackState.Playing do
		if not state.running or not stillOwner() then return finish(false) end
		if guard and guard() == false then return finish(false) end
		local _, hum = getChar()
		if not hum or hum.Health <= 0 or not hrp.Parent then return finish(false) end
		RunService.Heartbeat:Wait()
	end
	-- a tween cancelled from outside (e.g. respawn) must not count as arrival
	return finish(tween.PlaybackState == Enum.PlaybackState.Completed)
end

local function coinDistance(coinPos)
	local _, _, hrp = getChar()
	if not hrp then return math.huge end
	return (coinPos - hrp.Position).Magnitude
end

-- Prefers the game's own CoinCollected signal once it has been observed;
-- otherwise "gone while we were touching it" counts as ours.
local function wasCollected(coin, coinPos, t0)
	if state.coinSignalSeen then
		local deadline = os.clock() + CFG.signalWait
		repeat
			if state.lastCoinSignal and state.lastCoinSignal >= t0 then return true end
			if not coinGone(coin) then return false end
			task.wait()
		until os.clock() > deadline
		return false
	end
	return coinGone(coin) and coinDistance(coinPos) <= CFG.collectRadius
end

local function touchCoin(hrp, coinPos, coin, guard)
	if coinGone(coin) then return true end
	if not tweenTo(hrp, coinPos, guard) then return false end
	task.wait(CFG.touchHold)
	if coinGone(coin) then return true end
	if not tweenTo(hrp, coinPos + Vector3.new(1.2, 0, 0), guard) then return false end
	if coinGone(coin) then return true end
	if not tweenTo(hrp, coinPos - Vector3.new(1.2, 0, 0), guard) then return false end
	task.wait(CFG.touchHold)
	return coinGone(coin)
end

local function collectCoin(coin, info, cc, mode)
	local _, hum, hrp = getChar()
	if not hrp or not hum or hum.Health <= 0 then return "aborted" end
	local coinPos = info.pos
	local t0 = os.clock()
	local checkThreats = mode == "normal" and CFG.avoidMurderer
	local nextThreatCheck = 0

	local guard = function()
		if not cc.Parent or state.roundEndSignal then return false end
		if checkThreats and os.clock() >= nextThreatCheck then
			nextThreatCheck = os.clock() + 0.15
			if nearThreat(coinPos, murdererPositions(), CFG.dangerRadius * 0.6) then return false end
		end
		return true
	end

	local function outcome(touched)
		if wasCollected(coin, coinPos, t0) then return "collected" end
		if coinGone(coin) or touched then return "gone" end
		return "failed"
	end

	if mode == "dive" then
		local under = Vector3.new(coinPos.X, info.gy - CFG.diveDepth, coinPos.Z)
		if not tweenTo(hrp, under, guard) then return "aborted" end
		if not coinGone(coin) and not tweenTo(hrp, coinPos, guard) then return "aborted" end
		local touched = coinGone(coin) or touchCoin(hrp, coinPos, coin, guard)
		local result = outcome(touched)
		tweenTo(hrp, under, guard)
		return result
	end

	if not tweenTo(hrp, coinPos, guard) then return "aborted" end
	local touched = coinGone(coin) or touchCoin(hrp, coinPos, coin, guard)
	return outcome(touched)
end

local function moveCost(from, info, mode)
	if mode == "dive" then
		local under = Vector3.new(info.pos.X, info.gy - CFG.diveDepth, info.pos.Z)
		return (under - from).Magnitude + (info.pos - under).Magnitude
	end
	return (info.pos - from).Magnitude
end

-- Two-step greedy route: rank by travel / learned reliability (+ death-zone
-- penalty), then re-rank the best few by how close they leave us to the next coin.
local function chooseCoin(coins, from, m, mode, threats, params)
	local scored = {}
	for _, coin in ipairs(coins) do
		local info = coinInfo(coin, m, params)
		if info and not seenCoins[coin] then
			seenCoins[coin] = true
			Memory.noteSpawn(m, info.pos)
		end
		if info and not (mode == "normal" and nearThreat(info.pos, threats, CFG.dangerRadius)) then
			local cost = moveCost(from, info, mode) / Memory.reliability(m, info.pos)
			if mode == "normal" then cost *= 1 + 0.5 * Memory.danger(m, info.pos) end
			scored[#scored + 1] = { coin = coin, info = info, cost = cost }
		end
	end
	if #scored == 0 then return nil end
	table.sort(scored, function(a, b) return a.cost < b.cost end)

	local best, bestTotal
	for i = 1, math.min(8, #scored) do
		local cand = scored[i]
		local nextD = 0
		if CFG.lookahead > 0 and #scored > 1 then
			nextD = math.huge
			for _, other in ipairs(scored) do
				if other ~= cand then
					local d = (other.info.pos - cand.info.pos).Magnitude
					if d < nextD then nextD = d end
				end
			end
		end
		local total = cand.cost + CFG.lookahead * nextD
		if not bestTotal or total < bestTotal then best, bestTotal = cand, total end
	end
	return best.coin, best.info
end

local function parkAt(pos)
	local _, hum, hrp = getChar()
	if not hrp or not pos or not hum or hum.Health <= 0 then return end
	tweenTo(hrp, pos, nil)
end

local function parkAtSafe()
	parkAt(state.lastSafe)
end

-- Wait for respawns where coins historically appear most.
local function parkAtHotspot(hrp, params, threats)
	local m = state.roundMap
	if not m then parkAtSafe() return end
	local pos, gy = Memory.hotspot(m, hrp.Position)
	if not pos then parkAtSafe() return end
	if not gy then gy = groundY(pos, params) end
	if state.activeMode == "dive" then
		parkAt(Vector3.new(pos.X, gy - CFG.diveDepth, pos.Z))
		return
	end
	if nearThreat(pos, threats, CFG.dangerRadius) then parkAtSafe() return end
	parkAt(Vector3.new(pos.X, gy + 3, pos.Z))
end

---------------------------------------------------------------------------
-- Round lifecycle
---------------------------------------------------------------------------
local function finishRound()
	if state.roundRecorded or not state.roundMap then return end
	state.roundRecorded = true
	Memory.noteRound(state.roundMap, state.roundCollected)
end

local function beginRound(cc, mapName)
	if state.roundContainer ~= cc then
		state.roundContainer = cc
		state.roundMapName = mapName
		state.roundMap = Memory.map(mapName)
		state.roundCollected = 0
		state.roundStart = os.clock()
		state.roundRecorded = false
		state.methodSwitched = false
		state.bagFull = false
		state.bagCount = state.bagMax and 0 or nil
		state.activeMode = state.mode == "auto" and Memory.pickMode(state.roundMap) or state.mode
		print(string.format("[MM2] новый раунд: %s, режим %s", mapName, state.activeMode))
	end
	state.inRound = true
	state.roundStartSignal = false
	state.roundEndSignal = false
	state.failures = 0
	state.emptySince = nil
	state.lastSafe = nil
	state.parked = false
	setNoclip(true)
	setFrozen(true)
	setPhase("farming")
end

local function endRound(timeUp)
	parkAtSafe()
	resetCharacter()
	finishRound()
	state.inRound = false
	state.roundOver = timeUp == true
	state.endedContainer = state.roundContainer
	state.bagFull = false
	state.parked = false
	state.lastSafe = nil
	setPhase("round_end")
end

local function handleDeath()
	if state.deathHandled then return end
	state.deathHandled = true
	if state.inRound and state.roundMap and state.lastPos then
		Memory.noteDeath(state.roundMap, state.lastPos, state.activeMode)
	end
	finishRound()
	-- dead players can't collect; wait for the next map instead of re-entering this one
	if state.inRound then
		state.roundOver = true
		state.endedContainer = state.roundContainer
	end
	state.inRound = false
	state.lastSafe = nil
	state.parked = false
	state.bagFull = false
	state.failures = 0
	state.frozen = false
	state.noclip = false
	state.tweening = false
	table.clear(partCollide)
end

track(LocalPlayer.CharacterAdded:Connect(function()
	if state.inRound then handleDeath() end
	state.deathHandled = false
	state.frozen = false
	state.noclip = false
	table.clear(partCollide)
end))

local function switchHold()
	state.holdMethod = state.holdMethod == "anchor" and "hover" or "anchor"
	state.methodSwitched = true
	state.failures = 0
	if state.frozen then setFrozen(true) end
	print("[MM2] метод удержания → " .. state.holdMethod)
end

local function farmStep()
	if game.PlaceId ~= PLACE_ID then
		resetCharacter()
		setPhase("wrong_game")
		return 1
	end

	local char, hum, hrp = getChar()
	if not char or not hum or not hrp or hum.Health <= 0 then
		if state.inRound then handleDeath() end
		setPhase("dead")
		return 0.5
	end
	state.lastPos = hrp.Position

	local cc, mapName = pickContainer(hrp)
	local secs = roundSeconds()
	state.roundSeconds = secs

	if not cc then
		state.mapEmpty = true
		if state.inRound then endRound(false) end
		state.roundOver = false
		state.roundEndSignal = false
		setPhase("waiting")
		return 0.4
	end

	if state.roundOver then
		-- MM2 loads a fresh map per round, so a new container instance means a new round
		if cc == state.endedContainer and not state.roundStartSignal then
			state.roundEndSignal = false
			setPhase("round_end")
			return 0.5
		end
		state.roundOver = false
	end
	state.mapEmpty = false

	if not state.inRound then
		state.roundEndSignal = false
		beginRound(cc, mapName)
	end
	local m = state.roundMap

	if state.roundEndSignal or (secs and secs <= CFG.endBuffer) then
		state.roundEndSignal = false
		endRound(true)
		return 0.5
	end

	if state.bagFull then
		if not state.parked then
			state.parked = true
			parkAtSafe()
		end
		setPhase("bagfull")
		return 0.4
	end

	-- without the game's bag signal, fall back to a fixed or learned cap
	local cap = (CFG.bagCap > 0 and CFG.bagCap) or (not state.bagMax and Memory.bagCap()) or nil
	if cap and state.roundCollected >= cap then
		state.bagFull = true
		setPhase("bagfull")
		return 0.4
	end

	local containers = { cc }
	local params = makeRayParams(containers)
	local mode = state.activeMode
	local threats = (CFG.avoidMurderer and mode == "normal") and murdererPositions() or {}

	-- murderer closing in: drop under the map until they leave
	if #threats > 0 and nearThreat(hrp.Position, threats, CFG.dangerRadius) then
		local gy = groundY(hrp.Position, params)
		parkAt(Vector3.new(hrp.Position.X, gy - CFG.diveDepth, hrp.Position.Z))
		state.parked = false
		setPhase("threat")
		return 0.25
	end

	local coins = listCoins(containers)
	state.coinsOnMap = #coins

	if #coins == 0 then
		state.emptySince = state.emptySince or os.clock()
		if os.clock() - state.emptySince > CFG.emptyWait then
			if not state.parked then
				state.parked = true
				parkAtHotspot(hrp, params, threats)
			end
			setPhase("no_coins")
		end
		return 0.2
	end
	state.emptySince = nil
	state.parked = false

	local coin, info = chooseCoin(coins, hrp.Position, m, mode, threats, params)
	if not coin then
		setPhase("threat")
		return 0.25
	end
	setPhase("farming")
	state.lastSafe = Vector3.new(info.pos.X, info.gy + 3, info.pos.Z)

	local t0 = os.clock()
	local result = collectCoin(coin, info, cc, mode)
	if result ~= "aborted" then
		Memory.noteMode(m, mode, result == "collected" and 1 or 0, os.clock() - t0)
	end

	-- Failures only say something about the spot/method when the bag is known not to be full.
	local bagKnownOpen = state.bagMax ~= nil and (state.bagCount or 0) < state.bagMax

	if result == "collected" then
		state.roundCollected += 1
		state.totalCollected += 1
		state.failures = 0
		Memory.noteResult(m, info.pos, true)
		Memory.noteHold(state.holdMethod, true)
		if state.totalCollected % 10 == 0 then
			print(string.format("[MM2] всего %d (раунд %d)", state.totalCollected, state.roundCollected))
		end
		return 0.01
	elseif result == "gone" then
		state.failures = 0
		return 0.01
	elseif result == "failed" then
		if bagKnownOpen then
			Memory.noteResult(m, info.pos, false)
			Memory.noteHold(state.holdMethod, false)
		end
		blacklist[coin] = os.clock() + CFG.blacklistTime * (1 + math.min(Memory.failCount(m, info.pos), 3))
		state.failures += 1
		if state.failures >= CFG.failLimit then
			if not state.methodSwitched then
				-- try the other hold method before assuming the bag is full
				switchHold()
			elseif bagKnownOpen then
				state.failures = 0
			else
				state.bagFull = true
				setPhase("bagfull")
			end
		end
		return 0.02
	end
	return 0.05
end

local function farmLoop()
	while state.running and stillOwner() do
		local ok, delay = pcall(farmStep)
		if ok then
			state.lastError = nil
			task.wait(delay or 0.01)
		else
			state.lastError = tostring(delay)
			setPhase("error")
			resetCharacter()
			state.inRound = false
			task.wait(0.6)
		end
	end
	-- a newer instance owns the character now; don't undo its setup
	if stillOwner() then resetCharacter() end
end

local function giveToWindow(obj)
	if window and type(window.Give) == "function" then
		pcall(function() window:Give(obj) end)
	end
end

local function startFarm()
	if state.running then return end
	state.running = true
	state.inRound = false
	state.roundOver = false
	state.bagFull = false
	state.failures = 0
	state.emptySince = nil
	state.lastSafe = nil
	state.parked = false
	setPhase("waiting")
	if not state.thread or coroutine.status(state.thread) == "dead" then
		state.thread = task.spawn(farmLoop)
		giveToWindow(state.thread)
	end
end

local function stopFarm()
	state.running = false
	setPhase("stopped")
	resetCharacter()
	Memory.save(true)
end

---------------------------------------------------------------------------
-- UI
---------------------------------------------------------------------------
local MODE_LABEL = { normal = "обычный", dive = "выныривание", auto = "авто" }

window = UI:CreateWindow({
	Id = "mm2-collect",
	Title = "MM2 Collect",
	Subtitle = "coins · память карт",
})

local farmTab = window:Tab({ Title = "Фарм" })

local control = farmTab:Section({ Title = "Управление" })

control:Segmented({
	Id = "mode",
	Text = "Режим",
	Description = "Обычный — над картой. Выныривание — под картой, подъём вертикально. Авто — выбирает лучший режим для карты по памяти.",
	Options = { "Обычный", "Выныривание", "Авто" },
	Default = "Обычный",
	Callback = function(value)
		local mode = (value == "Выныривание" and "dive") or (value == "Авто" and "auto") or "normal"
		state.mode = mode
		if mode ~= "auto" then
			state.activeMode = mode
		elseif state.roundMap then
			state.activeMode = Memory.pickMode(state.roundMap)
		end
	end,
})

control:Toggle({
	Id = "enabled",
	Text = "Запуск",
	Description = "Выключение сразу возвращает управление персонажу.",
	Default = true,
	Callback = function(enabled)
		if enabled then startFarm() else stopFarm() end
	end,
})

control:Toggle({
	Id = "avoid",
	Text = "Избегать убийцу",
	Description = "В обычном режиме пропускает монеты рядом с убийцей и уходит под карту при его приближении.",
	Default = CFG.avoidMurderer,
	Callback = function(on)
		CFG.avoidMurderer = on
	end,
})

local settingsSection = farmTab:Section({ Title = "Настройки" })

settingsSection:Slider({
	Id = "speed",
	Text = "Скорость",
	Min = 10,
	Max = 60,
	Step = 1,
	Default = CFG.speed,
	Suffix = " studs/s",
	Callback = function(value)
		CFG.speed = value
	end,
})

settingsSection:Slider({
	Id = "depth",
	Text = "Глубина",
	Min = 8,
	Max = 60,
	Step = 1,
	Default = CFG.diveDepth,
	Suffix = " studs",
	Callback = function(value)
		CFG.diveDepth = value
	end,
})

local stats = farmTab:Section({ Title = "Статистика" })

local stateLabel = stats:Label({ Text = "Состояние: ждём раунд" })
local roundLabel = stats:Label({ Text = "За раунд: 0" })
local totalLabel = stats:Label({ Text = "За сессию: 0" })
local rateLabel = stats:Label({ Text = "Темп: —" })
local mapLabel = stats:Label({ Text = "На карте: 0" })
local timerLabel = stats:Label({ Text = "Таймер: —" })
local bagLabel = stats:Label({ Text = "Мешок: не полон" })

local memSection = farmTab:Section({ Title = "Память" })

memSection:Toggle({
	Id = "learning",
	Text = "Обучение",
	Description = "Запоминать точки появления монет, высоту земли, опасные зоны и эффективность режимов.",
	Default = CFG.learning,
	Callback = function(on)
		CFG.learning = on
	end,
})

if type(memSection.Button) == "function" then
	memSection:Button({
		Text = "Забыть текущую карту",
		Callback = function()
			Memory.forget(state.roundMapName)
			state.roundMap = state.roundMapName and Memory.map(state.roundMapName) or nil
			Memory.save(true)
		end,
	})
end

local memLabel = memSection:Label({ Text = "Память: —" })
local mapInfoLabel = memSection:Label({ Text = "Карта: —" })
local bestModeLabel = memSection:Label({ Text = "Режимы: —" })
local holdLabel = memSection:Label({ Text = "Удержание: " .. state.holdMethod })

local checks = farmTab:Section({ Title = "Проверки" })
local gameLabel = checks:Label({ Text = "Игра: проверка…" })
local modeLabel = checks:Label({ Text = "Режим: обычный" })
local signalLabel = checks:Label({ Text = "Сигналы игры: —" })
local errorLabel = checks:Label({ Text = "Ошибок нет" })

local function formatTimer(secs)
	if not secs then return "—" end
	return string.format("%dm %02ds", math.floor(secs / 60), secs % 60)
end

local function formatRate(rate)
	if not rate then return "—" end
	return string.format("%.0f/ч", rate * 3600)
end

local function updateUI()
	stateLabel:SetText("Состояние: " .. (PHASE_TEXT[state.phase] or state.phase))
	roundLabel:SetText("За раунд: " .. tostring(state.roundCollected))
	totalLabel:SetText("За сессию: " .. tostring(state.totalCollected))
	local elapsed = os.clock() - state.sessionStart
	rateLabel:SetText("Темп: " .. (elapsed > 30 and formatRate(state.totalCollected / elapsed) or "—"))
	mapLabel:SetText("На карте: " .. tostring(state.coinsOnMap))
	timerLabel:SetText("Таймер: " .. formatTimer(state.roundSeconds))
	if state.bagMax then
		bagLabel:SetText(string.format("Мешок: %d/%d%s", state.bagCount or 0, state.bagMax, state.bagFull and " (полон)" or ""))
	else
		bagLabel:SetText("Мешок: " .. (state.bagFull and "полон" or "не полон"))
	end

	local maps, cells, sessions = Memory.summary()
	memLabel:SetText(string.format("Память: %d карт, %d точек, сессия #%d%s", maps, cells, sessions,
		Memory.persistent() and "" or " (без файла)"))
	local m = state.roundMap
	if m then
		mapInfoLabel:SetText(string.format("Карта: %s · раундов %d · ~%.0f монет · смертей %d",
			state.roundMapName or "?", m.rounds, m.coinsEma or 0, m.deaths))
		bestModeLabel:SetText(string.format("Режимы: обычный %s · выныривание %s",
			formatRate(Memory.modeRate(m, "normal")), formatRate(Memory.modeRate(m, "dive"))))
	else
		mapInfoLabel:SetText("Карта: —")
		bestModeLabel:SetText("Режимы: —")
	end
	holdLabel:SetText("Удержание: " .. state.holdMethod)

	local modeText = MODE_LABEL[state.mode] or state.mode
	if state.mode == "auto" then modeText ..= " → " .. (MODE_LABEL[state.activeMode] or state.activeMode) end
	modeLabel:SetText("Режим: " .. modeText)
	signalLabel:SetText("Сигналы игры: " .. (state.coinSignalSeen and "монеты ок" or (state.coinRemoteHooked and "ждём первую монету" or "нет, эвристика")))
	if game.PlaceId == PLACE_ID then
		gameLabel:SetText("Игра: ок")
	else
		gameLabel:SetText("Игра: не та (" .. tostring(game.PlaceId) .. ")")
	end
	if state.lastError then
		errorLabel:SetText("Ошибка: " .. tostring(state.lastError))
	else
		errorLabel:SetText("Ошибок нет")
	end
end

local uiThread = task.spawn(function()
	while stillOwner() do
		pcall(updateUI)
		pcall(Memory.save, false)
		task.wait(0.35)
	end
	pcall(Memory.save, true)
	disconnectAll()
end)
giveToWindow(uiThread)

if type(window.OnDestroy) == "function" then
	window:OnDestroy(function()
		if stillOwner() then stopFarm() else state.running = false end
		disconnectAll()
		if ENV and ENV.MM2_TOKEN == TOKEN then
			ENV.MM2_TOKEN = nil
		end
	end)
end

updateUI()
startFarm()

return "ready (mode=" .. state.mode .. ", running=" .. tostring(state.running) .. ", memory=" .. tostring(Memory.persistent()) .. ")"
