local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
local PLACE_ID = 142823291

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
	newRoundGap = 5,
	bagCap = 0,
	maxMapDist = 1200,
	collectRadius = 9,
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

local window = nil

local state = {
	running = false,
	phase = "waiting",
	mode = "normal",
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
	coinsOnMap = 0,
	roundSeconds = nil,
	lastError = nil,
	thread = nil,
	frozen = false,
	noclip = false,
	lastPhasePrinted = nil,
}

local blacklist = setmetatable({}, { __mode = "k" })
local partCollide = setmetatable({}, { __mode = "k" })

local PHASE_TEXT = {
	waiting = "ждём раунд",
	farming = "сбор монет",
	bagfull = "мешок полон — до конца раунда",
	round_end = "раунд закончился — ждём следующий",
	no_coins = "монет на карте нет",
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

local function getChar()
	local char = LocalPlayer.Character
	if not char then return nil end
	return char, char:FindFirstChildOfClass("Humanoid"), char:FindFirstChild("HumanoidRootPart")
end

local function setFrozen(on)
	local _, hum, hrp = getChar()
	if hrp then pcall(function() hrp.Anchored = on end) end
	if hum then
		pcall(function()
			hum.AutoRotate = not on
			hum.PlatformStand = on
		end)
	end
	state.frozen = on
end

local function setNoclip(on)
	local char = getChar()
	if not char then return end
	if on then
		for _, part in ipairs(char:GetDescendants()) do
			if part:IsA("BasePart") then
				if partCollide[part] == nil then partCollide[part] = part.CanCollide end
				part.CanCollide = false
			end
		end
	else
		for part, value in pairs(partCollide) do
			if part and part.Parent then pcall(function() part.CanCollide = value end) end
		end
		table.clear(partCollide)
	end
	state.noclip = on
end

local function resetCharacter()
	setNoclip(false)
	setFrozen(false)
	local _, hum = getChar()
	if hum and hum.Health > 0 then
		pcall(function() hum:ChangeState(Enum.HumanoidStateType.Freefall) end)
	end
end

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

local containerPosCache = setmetatable({}, { __mode = "k" })
local function containerPos(cc)
	local hit = containerPosCache[cc]
	if hit then return hit end
	local pos
	local ok = pcall(function()
		pos = cc.Parent and cc.Parent:GetPivot().Position or cc:GetPivot().Position
	end)
	if not ok or not pos then pos = Vector3.new(0, 0, 0) end
	containerPosCache[cc] = pos
	return pos
end

local function pickContainers(hrp)
	local best, bestD
	for _, cc in ipairs(getCoinContainers()) do
		local d = (containerPos(cc) - hrp.Position).Magnitude
		if d <= CFG.maxMapDist and (not bestD or d < bestD) then
			best, bestD = cc, d
		end
	end
	if best then return { best } end
	return {}
end

local function listCoins(containers)
	local now = os.clock()
	local list = {}
	for _, cc in ipairs(containers) do
		for _, c in ipairs(cc:GetChildren()) do
			if c:IsA("BasePart") and c.Name == "Coin_Server" then
				local collected = false
				pcall(function() collected = c:GetAttribute("Collected") == true end)
				if not collected and (blacklist[c] or 0) < now then
					list[#list + 1] = c
				end
			end
		end
	end
	return list
end

local function nearestCoin(coins, from)
	local best, bestD
	for _, c in ipairs(coins) do
		local ok, pos = pcall(function() return c.Position end)
		if ok and pos then
			local d = (pos - from).Magnitude
			if not bestD or d < bestD then best, bestD = c, d end
		end
	end
	return best
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

local function groundY(pos, containers)
	local filter = {}
	local char = LocalPlayer.Character
	if char then filter[#filter + 1] = char end
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= LocalPlayer and p.Character then filter[#filter + 1] = p.Character end
	end
	for _, cc in ipairs(containers or {}) do filter[#filter + 1] = cc end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = filter
	params.IgnoreWater = true
	local ok, result = pcall(function()
		return Workspace:Raycast(pos + Vector3.new(0, 2, 0), Vector3.new(0, -140, 0), params)
	end)
	if ok and result then return result.Position.Y end
	return pos.Y - 16
end

local function tweenTo(hrp, targetPos, guard)
	if not hrp or not hrp.Parent then return false end
	local okStart, startPos = pcall(function() return hrp.Position end)
	if not okStart then return false end
	local dist = (targetPos - startPos).Magnitude
	if dist < 0.2 then return true end
	local duration = math.max(dist / math.max(CFG.speed, 1), 0.03)
	local goal = CFrame.new(targetPos) * hrp.CFrame.Rotation
	local tween = TweenService:Create(hrp, TweenInfo.new(duration, Enum.EasingStyle.Linear, Enum.EasingDirection.Out), { CFrame = goal })
	tween:Play()
	while tween.PlaybackState == Enum.PlaybackState.Playing do
		if not state.running or not stillOwner() then
			tween:Cancel()
			return false
		end
		if guard and guard() == false then
			tween:Cancel()
			return false
		end
		local _, hum = getChar()
		if not hum or hum.Health <= 0 then
			tween:Cancel()
			return false
		end
		RunService.Heartbeat:Wait()
	end
	return true
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

local function coinDistance(coinPos)
	local _, _, hrp = getChar()
	if not hrp then return math.huge end
	return (coinPos - hrp.Position).Magnitude
end

local function touchCoin(hrp, coin, guard)
	local okPos, base = pcall(function() return coin.Position end)
	if not okPos or not base then return true end
	if coinGone(coin) then return true end
	if not tweenTo(hrp, base, guard) then return false end
	task.wait(CFG.touchHold)
	if coinGone(coin) then return true end
	if not tweenTo(hrp, base + Vector3.new(1.2, 0, 0), guard) then return false end
	if coinGone(coin) then return true end
	if not tweenTo(hrp, base - Vector3.new(1.2, 0, 0), guard) then return false end
	task.wait(CFG.touchHold)
	return coinGone(coin)
end

local function collectCoin(coin, containers, mode, diveY)
	local _, hum, hrp = getChar()
	if not hrp or not hum or hum.Health <= 0 then return "aborted" end
	local okPos, coinPos = pcall(function() return coin.Position end)
	if not okPos or not coinPos then return "gone" end

	local guard = function()
		for _, cc in ipairs(containers) do
			if not cc.Parent then return false end
		end
		return true
	end

	local ok
	if mode == "dive" then
		local under = Vector3.new(coinPos.X, diveY, coinPos.Z)
		ok = tweenTo(hrp, under, guard)
		if ok and not coinGone(coin) then
			ok = tweenTo(hrp, coinPos, guard)
		end
		if not ok then return "aborted" end
		if coinGone(coin) then
			return coinDistance(coinPos) <= CFG.collectRadius and "collected" or "gone"
		end
		local touched = touchCoin(hrp, coin, guard)
		if coinGone(coin) and coinDistance(coinPos) <= CFG.collectRadius then
			tweenTo(hrp, under, guard)
			return "collected"
		end
		if touched then return "gone" end
		tweenTo(hrp, under, guard)
		return "failed"
	end

	ok = tweenTo(hrp, coinPos, guard)
	if not ok then return "aborted" end
	if coinGone(coin) then
		return coinDistance(coinPos) <= CFG.collectRadius and "collected" or "gone"
	end
	local touched = touchCoin(hrp, coin, guard)
	if coinGone(coin) then
		return coinDistance(coinPos) <= CFG.collectRadius and "collected" or "gone"
	end
	return touched and "gone" or "failed"
end

local function parkAtSafe()
	local _, hum, hrp = getChar()
	if not hrp or not state.lastSafe or not hum or hum.Health <= 0 then return end
	tweenTo(hrp, state.lastSafe, nil)
end

local function beginRound()
	state.inRound = true
	state.roundCollected = 0
	state.failures = 0
	state.bagFull = false
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
	state.inRound = false
	state.roundOver = timeUp == true
	state.bagFull = false
	state.parked = false
	state.lastSafe = nil
	setPhase("round_end")
end

local function onDeath()
	state.inRound = false
	state.lastSafe = nil
	state.parked = false
	state.bagFull = false
	state.failures = 0
	state.frozen = false
	state.noclip = false
	table.clear(partCollide)
end

local function farmStep()
	if game.PlaceId ~= PLACE_ID then
		resetCharacter()
		setPhase("wrong_game")
		return 1
	end

	local char, hum, hrp = getChar()
	if not char or not hum or not hrp or hum.Health <= 0 then
		onDeath()
		setPhase("dead")
		return 0.5
	end

	local containers = pickContainers(hrp)
	local secs = roundSeconds()
	state.roundSeconds = secs

	if #containers == 0 then
		state.mapEmpty = true
		if state.inRound then endRound(false) end
		setPhase("waiting")
		return 0.4
	end

	if state.roundOver then
		local newRound = state.mapEmpty or (secs ~= nil and secs > CFG.endBuffer + CFG.newRoundGap)
		if not newRound then
			setPhase("round_end")
			return 0.5
		end
		state.roundOver = false
	end
	state.mapEmpty = false

	if not state.inRound then beginRound() end

	if state.bagFull then
		if not state.parked then
			state.parked = true
			parkAtSafe()
		end
		setPhase("bagfull")
		return 0.4
	end

	if CFG.bagCap > 0 and state.roundCollected >= CFG.bagCap then
		state.bagFull = true
		setPhase("bagfull")
		return 0.4
	end

	if secs and secs <= CFG.endBuffer then
		endRound(true)
		return 0.5
	end

	local coins = listCoins(containers)
	state.coinsOnMap = #coins

	if #coins == 0 then
		state.emptySince = state.emptySince or os.clock()
		if os.clock() - state.emptySince > CFG.emptyWait then
			if not state.parked then
				state.parked = true
				parkAtSafe()
			end
			setPhase("no_coins")
		end
		return 0.2
	end
	state.emptySince = nil
	state.parked = false

	local coin = nearestCoin(coins, hrp.Position)
	if not coin then return 0.1 end

	local gy = groundY(coin.Position, containers)
	state.lastSafe = Vector3.new(coin.Position.X, gy + 3, coin.Position.Z)
	local diveY = gy - CFG.diveDepth

	local result = collectCoin(coin, containers, state.mode, diveY)

	if result == "collected" then
		state.roundCollected += 1
		state.totalCollected += 1
		state.failures = 0
		setPhase("farming")
		if state.totalCollected % 10 == 0 then
			print(string.format("[MM2] всего %d (раунд %d)", state.totalCollected, state.roundCollected))
		end
		return 0.01
	elseif result == "gone" then
		state.failures = 0
		return 0.01
	elseif result == "failed" then
		blacklist[coin] = os.clock() + CFG.blacklistTime
		state.failures += 1
		if state.failures >= CFG.failLimit then
			state.bagFull = true
			setPhase("bagfull")
		end
		return 0.02
	else
		return 0.05
	end
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
			task.wait(0.6)
		end
	end
	resetCharacter()
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
end

window = UI:CreateWindow({
	Id = "mm2-collect",
	Title = "MM2 Collect",
	Subtitle = "coins only · 2 modes",
})

local farmTab = window:Tab({ Title = "Фарм" })

local control = farmTab:Section({ Title = "Управление" })

control:Segmented({
	Id = "mode",
	Text = "Режим",
	Description = "Обычный — над картой. Выныривание — под картой, подъём вертикально.",
	Options = { "Обычный", "Выныривание" },
	Default = "Обычный",
	Callback = function(value)
		state.mode = (value == "Выныривание") and "dive" or "normal"
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
local mapLabel = stats:Label({ Text = "На карте: 0" })
local timerLabel = stats:Label({ Text = "Таймер: —" })
local bagLabel = stats:Label({ Text = "Мешок: не полон" })

local checks = farmTab:Section({ Title = "Проверки" })
local gameLabel = checks:Label({ Text = "Игра: проверка…" })
local modeLabel = checks:Label({ Text = "Режим: обычный" })
local errorLabel = checks:Label({ Text = "Ошибок нет" })

local function formatTimer(secs)
	if not secs then return "—" end
	return string.format("%dm %02ds", math.floor(secs / 60), secs % 60)
end

local function updateUI()
	stateLabel:SetText("Состояние: " .. (PHASE_TEXT[state.phase] or state.phase))
	roundLabel:SetText("За раунд: " .. tostring(state.roundCollected))
	totalLabel:SetText("За сессию: " .. tostring(state.totalCollected))
	mapLabel:SetText("На карте: " .. tostring(state.coinsOnMap))
	timerLabel:SetText("Таймер: " .. formatTimer(state.roundSeconds))
	bagLabel:SetText("Мешок: " .. (state.bagFull and "полон" or "не полон"))
	modeLabel:SetText("Режим: " .. (state.mode == "dive" and "выныривание" or "обычный"))
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
		task.wait(0.35)
	end
end)
giveToWindow(uiThread)

if type(window.OnDestroy) == "function" then
	window:OnDestroy(function()
		stopFarm()
		if ENV and ENV.MM2_TOKEN == TOKEN then
			ENV.MM2_TOKEN = nil
		end
	end)
end

updateUI()
startFarm()

return "ready (mode=" .. state.mode .. ", running=" .. tostring(state.running) .. ")"