-- TycoonManager — plot claiming, collector pad, Auto-Collect pass, 30 upgrades, Rebirth,
--                  Promo Codes, Group Bonus, Server-Wide Boost, Developer Products
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage     = game:GetService("ServerStorage")

local PlayerDataManager = require(ServerStorage:WaitForChild("PlayerDataManager"))
local ShopHandler       = require(ServerStorage:WaitForChild("ShopHandler"))
local UpgradeTable      = require(ServerStorage:WaitForChild("UpgradeTable"))

local PLOT_H       = 4
local REBIRTH_COST = 100000000

-- ── Configurable constants ────────────────────────────────────────────────────
local GROUP_ID = 0  -- set to your Roblox Group ID (e.g. 12345678); 0 = disabled

local PROMO_CODES = {
	LAUNCH100  = { rewardType = "Cash",    amount   = 2500, label = "+$2,500 Cash!"          },
	EMPIRE2026 = { rewardType = "Cash",    amount   = 5000, label = "+$5,000 Cash!"          },
	WATERFRONT = { rewardType = "Boost2x", duration = 300,  label = "5-Min 2× Cash Boost!"   },
	CASHKING   = { rewardType = "Cash",    amount  = 10000, label = "+$10,000 Cash!"          },
}

-- ── Server-wide boost state ───────────────────────────────────────────────────
local SERVER_BOOST_END = 0  -- os.clock() timestamp when server 2× expires (0 = inactive)

-- ── Per-player state ─────────────────────────────────────────────────────────
local PENDING_CASH   = {} -- [userId] = pending uncollected cash
local DEBOUNCE       = {}
local SESSION_START  = {} -- [userId] = os.clock() on join (server-side, spoofing-safe)
local CLAIMED_GIFTS  = {} -- [userId] = { [giftId] = true }
local BOOST_END_TIME = {} -- [userId] = personal 2× boost expiry

local PLAYTIME_REWARDS = {
	{ id = 1, waitSec = 60,   incomeMultSec = 15, boostSec = 0   },
	{ id = 2, waitSec = 180,  incomeMultSec = 0,  boostSec = 120 },
	{ id = 3, waitSec = 360,  incomeMultSec = 45, boostSec = 0   },
	{ id = 4, waitSec = 600,  incomeMultSec = 0,  boostSec = 240 },
	{ id = 5, waitSec = 900,  incomeMultSec = 90, boostSec = 0   },
	{ id = 6, waitSec = 1500, incomeMultSec = 0,  boostSec = 360 },
}

-- ── Helpers ───────────────────────────────────────────────────────────────────
local function fmt(n)
	if n >= 1e9 then return string.format("$%.2fB", n / 1e9)
	elseif n >= 1e6 then return string.format("$%.2fM", n / 1e6)
	elseif n >= 1e3 then return string.format("$%.1fK", n / 1e3)
	else return "$" .. math.floor(n) end
end

local function calcIncome(data, userId)
	local base, mult = 0, 1
	for _, id in ipairs(data.UnlockedUpgrades or {}) do
		local u = UpgradeTable[id]
		if u then
			if u.income     then base = base + u.income   end
			if u.multiplier then mult = mult * u.multiplier end
		end
	end
	local total = base * mult * (data.PrestigeMultiplier or 1)
	if data.Gamepasses then
		if data.Gamepasses.VIP         then total = total * 1.25 end
		if data.Gamepasses.StarterPack then total = total * 2    end
	end
	-- personal 2× boost
	if userId and BOOST_END_TIME[userId] and os.clock() < BOOST_END_TIME[userId] then
		total = total * 2
	end
	-- server-wide 2× boost (stacks cleanly with personal boost)
	if SERVER_BOOST_END > 0 and os.clock() < SERVER_BOOST_END then
		total = total * 2
	end
	return math.floor(total)
end

local function nextUpgradeId(data)
	local owned = {}
	for _, id in ipairs(data.UnlockedUpgrades or {}) do owned[id] = true end
	for i = 1, #UpgradeTable do
		if not owned[i] then return i end
	end
	return nil
end

local function getPlot(player)
	local plots = workspace:FindFirstChild("Plots")
	if not plots then return nil end
	for _, plot in ipairs(plots:GetChildren()) do
		local ov = plot:FindFirstChild("Owner")
		if ov and ov.Value == player.Name then return plot end
	end
	return nil
end

local function ensureRemote(name)
	local r = ReplicatedStorage:FindFirstChild(name)
	if not r then
		r = Instance.new("RemoteEvent"); r.Name = name; r.Parent = ReplicatedStorage
	end
	return r
end

local function ensureRemoteFunction(name)
	local r = ReplicatedStorage:FindFirstChild(name)
	if not r then
		r = Instance.new("RemoteFunction"); r.Name = name; r.Parent = ReplicatedStorage
	end
	return r
end

local UpdateCash       = ensureRemote("UpdateCash")
local UpdateIncome     = ensureRemote("UpdateIncome")
local UpdatePrestige   = ensureRemote("UpdatePrestige")
local UpdatePending    = ensureRemote("UpdatePending")
local RequestRebirth   = ensureRemote("RequestRebirth")
local ClaimGift        = ensureRemote("ClaimGift")
local UpdateBoost      = ensureRemote("UpdateBoost")
local ShowToast        = ensureRemote("ShowToast")
local ServerBoostNotify = ensureRemote("ServerBoostNotify")

local RedeemCode = ensureRemoteFunction("RedeemCode")

-- ── Collector Pad Floating Display ────────────────────────────────────────────
local function updateCollectorDisplay(plot, text, color)
	if not plot then return end
	local collector = plot:FindFirstChild("Collector")
	if not collector then return end

	local bbg = collector:FindFirstChild("CollectorDisplay")
	if not bbg then
		bbg = Instance.new("BillboardGui")
		bbg.Name        = "CollectorDisplay"
		bbg.Size        = UDim2.new(0, 210, 0, 50)
		bbg.StudsOffset = Vector3.new(0, 4, 0)
		bbg.MaxDistance = 70
		bbg.Parent      = collector

		local lbl = Instance.new("TextLabel")
		lbl.Name                   = "Label"
		lbl.Size                   = UDim2.new(1, 0, 1, 0)
		lbl.BackgroundColor3       = Color3.fromRGB(0, 0, 0)
		lbl.BackgroundTransparency = 0.35
		lbl.TextScaled             = true
		lbl.Font                   = Enum.Font.GothamBold
		lbl.Parent                 = bbg
		Instance.new("UICorner", lbl).CornerRadius = UDim.new(0.25, 0)
	end

	local lbl = bbg:FindFirstChild("Label")
	if lbl then lbl.Text = text; lbl.TextColor3 = color end
end

local function setupCollectorPad(plot)
	local collector = plot:FindFirstChild("Collector")
	if not collector or collector:GetAttribute("Hooked") then return end
	collector:SetAttribute("Hooked", true)

	collector.Touched:Connect(function(hit)
		if not hit.Parent then return end
		local plr = Players:GetPlayerFromCharacter(hit.Parent)
		if not plr then return end

		local ov = plot:FindFirstChild("Owner")
		if not ov or ov.Value ~= plr.Name then return end

		local pending = PENDING_CASH[plr.UserId] or 0
		if pending <= 0 then return end

		PENDING_CASH[plr.UserId] = 0
		PlayerDataManager.addCash(plr, pending)

		local data = PlayerDataManager.getData(plr)
		if data then UpdateCash:FireClient(plr, data.Cash) end
		UpdatePending:FireClient(plr, 0, false)
		updateCollectorDisplay(plot, "Vault: $0", Color3.fromRGB(180, 255, 180))
	end)
end

-- ── Upgrade Visual Spawning ───────────────────────────────────────────────────
local function upgradePos(id, plotPos)
	local col  = (id - 1) % 3
	local row  = math.floor((id - 1) / 3)
	local xOff = (col - 1) * 9
	local zOff = 10 - row * 5
	return Vector3.new(plotPos.X + xOff, PLOT_H + 1.5, plotPos.Z + zOff)
end

local function spawnUpgradeVisual(plot, upgradeId)
	local u = UpgradeTable[upgradeId]
	if not u then return end
	local pp = plot.PrimaryPart
	if not pp then return end

	local old = plot:FindFirstChild("Upgrade_" .. upgradeId)
	if old then old:Destroy() end

	local pos = upgradePos(upgradeId, pp.Position)

	local modelsFolder = ServerStorage:FindFirstChild("UpgradeModels")
	local template = modelsFolder and modelsFolder:FindFirstChild("Upgrade_" .. upgradeId)

	if template then
		local clone = template:Clone()
		clone.Name = "Upgrade_" .. upgradeId
		if clone:IsA("BasePart") then
			clone.Anchored = true
			clone.CFrame = CFrame.new(pos.X, PLOT_H + (clone.Size.Y / 2), pos.Z)
		elseif clone:IsA("Model") then
			for _, d in ipairs(clone:GetDescendants()) do
				if d:IsA("BasePart") then d.Anchored = true end
			end
			local _, size = clone:GetBoundingBox()
			clone:PivotTo(CFrame.new(pos.X, PLOT_H + (size.Y / 2), pos.Z))
		end
		clone.Parent = plot
		return
	end

	-- Fallback colored box
	local part = Instance.new("Part")
	part.Name          = "Upgrade_" .. upgradeId
	part.Size          = Vector3.new(5, 3, 5)
	part.CFrame        = CFrame.new(pos)
	part.BrickColor    = u.color or BrickColor.new("Bright yellow")
	part.Material      = Enum.Material.SmoothPlastic
	part.Anchored      = true
	part.CanCollide    = true
	part.TopSurface    = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent        = plot

	local sg = Instance.new("SurfaceGui")
	sg.Face = Enum.NormalId.Top; sg.PixelsPerStud = 30; sg.Parent = part
	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.new(1,0,1,0); lbl.BackgroundTransparency = 1
	lbl.TextColor3 = Color3.fromRGB(255,255,255); lbl.TextScaled = true
	lbl.Font = Enum.Font.GothamBold; lbl.Text = u.name; lbl.Parent = sg
end

local spawnButton  -- forward declaration

local function performRebirth(plr, data, plot)
	PENDING_CASH[plr.UserId] = 0
	data.UnlockedUpgrades    = { 1 }
	data.Cash                = 0
	data.PrestigeLevel       = (data.PrestigeLevel or 0) + 1
	local bonus              = (data.Gamepasses and data.Gamepasses.DoublePrestige) and 2 or 1
	data.PrestigeMultiplier  = 1 + (data.PrestigeLevel * 0.5 * bonus)

	if plot then
		for _, child in ipairs(plot:GetChildren()) do
			if child.Name:sub(1, 8) == "Upgrade_" then child:Destroy() end
		end
		spawnUpgradeVisual(plot, 1)
		local nxt = nextUpgradeId(data)
		if nxt then spawnButton(plot, nxt, data.Cash) end
	end

	UpdatePrestige:FireClient(plr, data.PrestigeLevel, data.PrestigeMultiplier)
	UpdateCash:FireClient(plr, data.Cash)
	UpdateIncome:FireClient(plr, calcIncome(data, plr.UserId))
	UpdatePending:FireClient(plr, 0, data.Gamepasses and data.Gamepasses.AutoCollect == true)
end

-- ── Purchase Button ───────────────────────────────────────────────────────────
spawnButton = function(plot, upgradeId, playerCash)
	for _, child in ipairs(plot:GetChildren()) do
		if child.Name == "PurchaseButton" or child.Name == "PurchaseBeacon" then
			child:Destroy()
		end
	end

	local u  = UpgradeTable[upgradeId]
	if not u then return end
	local pp = plot.PrimaryPart
	if not pp then return end

	local affordable = playerCash >= u.cost
	local bpos = Vector3.new(pp.Position.X, PLOT_H + 0.5, pp.Position.Z + 28)

	local pad = Instance.new("Part")
	pad.Name = "PurchaseButton"; pad.Size = Vector3.new(14, 1, 14)
	pad.CFrame = CFrame.new(bpos); pad.Anchored = true; pad.CanCollide = false
	pad.Material = Enum.Material.Neon
	pad.BrickColor = affordable and BrickColor.new("Bright green") or BrickColor.new("Bright yellow")
	pad.Parent = plot

	local pole = Instance.new("Part")
	pole.Name = "PurchaseBeacon"; pole.Size = Vector3.new(1, 12, 1)
	pole.CFrame = CFrame.new(bpos + Vector3.new(0, 7, 0)); pole.Anchored = true; pole.CanCollide = false
	pole.Material = Enum.Material.Neon
	pole.BrickColor = affordable and BrickColor.new("Bright green") or BrickColor.new("Bright yellow")
	pole.Parent = plot

	local bbg = Instance.new("BillboardGui")
	bbg.Size = UDim2.new(0, 180, 0, 90); bbg.StudsOffset = Vector3.new(0, 15, 0)
	bbg.MaxDistance = 50; bbg.AlwaysOnTop = false; bbg.Parent = pad

	local frame = Instance.new("Frame")
	frame.Size = UDim2.new(1,0,1,0); frame.BackgroundColor3 = Color3.fromRGB(0,0,0)
	frame.BackgroundTransparency = 0.3; frame.BorderSizePixel = 0; frame.Parent = bbg
	Instance.new("UICorner", frame).CornerRadius = UDim.new(0.1, 0)

	local function row(text, color, yPos, h)
		local l = Instance.new("TextLabel")
		l.Size = UDim2.new(1,0,h,0); l.Position = UDim2.new(0,0,yPos,0)
		l.BackgroundTransparency = 1; l.TextColor3 = color
		l.TextScaled = true; l.Font = Enum.Font.GothamBold; l.Text = text; l.Parent = frame
	end

	row(u.name, Color3.fromRGB(255,255,255), 0, 0.35)
	row(fmt(u.cost), affordable and Color3.fromRGB(100,255,100) or Color3.fromRGB(255,215,0), 0.35, 0.3)

	local incomeText
	if u.isRebirth    then incomeText = "REBIRTH  +50% Mult"
	elseif u.multiplier then incomeText = "×" .. u.multiplier .. " Multiplier"
	elseif u.income and u.income > 0 then incomeText = "+" .. fmt(u.income):sub(2) .. "/s"
	else incomeText = "Visual Upgrade" end
	row(incomeText, Color3.fromRGB(180, 255, 180), 0.65, 0.3)

	pad.Touched:Connect(function(hit)
		if not hit.Parent then return end
		local plr = Players:GetPlayerFromCharacter(hit.Parent)
		if not plr then return end

		local ov = plot:FindFirstChild("Owner")
		if not ov or ov.Value ~= plr.Name then return end
		if DEBOUNCE[plr.UserId] then return end
		DEBOUNCE[plr.UserId] = true
		task.delay(1.0, function() DEBOUNCE[plr.UserId] = nil end)

		local data = PlayerDataManager.getData(plr)
		if not data then return end
		if u.cost > 0 and not PlayerDataManager.spendCash(plr, u.cost) then return end

		if u.isRebirth then
			performRebirth(plr, data, plot)
			return
		end

		if table.find(data.UnlockedUpgrades, upgradeId) then return end
		table.insert(data.UnlockedUpgrades, upgradeId)
		spawnUpgradeVisual(plot, upgradeId)

		UpdateCash:FireClient(plr, data.Cash)
		UpdateIncome:FireClient(plr, calcIncome(data, plr.UserId))

		local nxt = nextUpgradeId(data)
		if nxt then spawnButton(plot, nxt, data.Cash) end
	end)
end

-- ── ShopHandler dev-product callback ─────────────────────────────────────────
-- Set after performRebirth is defined so InstantRebirth can call it safely.
ShopHandler.OnProductPurchased = function(plr, productType, value)
	local data = PlayerDataManager.getData(plr)
	if not data then return end

	if productType == "Cash10k" or productType == "Cash100k" then
		-- cash already added by ShopHandler; notify the client
		UpdateCash:FireClient(plr, data.Cash)
		ShowToast:FireClient(plr, "+" .. fmt(value) .. " Cash credited!")

	elseif productType == "ServerBoost2x" then
		SERVER_BOOST_END = math.max(SERVER_BOOST_END, os.clock()) + (value or 900)
		local remaining = math.floor(SERVER_BOOST_END - os.clock())
		ServerBoostNotify:FireAllClients({ buyerName = plr.Name, remainingSec = remaining })

	elseif productType == "InstantRebirth" then
		local plot = getPlot(plr)
		performRebirth(plr, data, plot)
		ShowToast:FireClient(plr, "🌟 Instant Prestige Rebirth activated!")
	end
end

-- ── Promo Code Redemption ─────────────────────────────────────────────────────
RedeemCode.OnServerInvoke = function(plr, code)
	if typeof(code) ~= "string" then
		return { success = false, message = "Invalid input." }
	end
	code = code:match("^%s*(.-)%s*$"):upper()
	if code == "" then
		return { success = false, message = "Please enter a code." }
	end

	local reward = PROMO_CODES[code]
	if not reward then
		return { success = false, message = "Code not found." }
	end

	local data = PlayerDataManager.getData(plr)
	if not data then
		return { success = false, message = "Data error — try again." }
	end

	data.RedeemedCodes = data.RedeemedCodes or {}
	if data.RedeemedCodes[code] then
		return { success = false, message = "Already redeemed!" }
	end

	data.RedeemedCodes[code] = true

	if reward.rewardType == "Cash" then
		PlayerDataManager.addCash(plr, reward.amount)
		UpdateCash:FireClient(plr, data.Cash)
	elseif reward.rewardType == "Boost2x" then
		local uid = plr.UserId
		BOOST_END_TIME[uid] = math.max(BOOST_END_TIME[uid] or 0, os.clock()) + reward.duration
		UpdateBoost:FireClient(plr, reward.duration)
	end

	PlayerDataManager.savePlayer(plr)
	ShowToast:FireClient(plr, "🎁 Code redeemed: " .. reward.label)
	return { success = true, message = reward.label }
end

-- ── ClaimGift Remote Handler ──────────────────────────────────────────────────
ClaimGift.OnServerEvent:Connect(function(plr, giftId)
	local uid = plr.UserId
	if not SESSION_START[uid] then return end
	local elapsed = os.clock() - SESSION_START[uid]

	local reward
	for _, r in ipairs(PLAYTIME_REWARDS) do
		if r.id == giftId then reward = r; break end
	end
	if not reward or elapsed < reward.waitSec then return end

	CLAIMED_GIFTS[uid] = CLAIMED_GIFTS[uid] or {}
	if CLAIMED_GIFTS[uid][giftId] then return end
	CLAIMED_GIFTS[uid][giftId] = true

	ClaimGift:FireClient(plr, giftId)

	if reward.boostSec > 0 then
		BOOST_END_TIME[uid] = os.clock() + reward.boostSec
		UpdateBoost:FireClient(plr, reward.boostSec)
	elseif reward.incomeMultSec > 0 then
		local data = PlayerDataManager.getData(plr)
		if data then
			local gift = calcIncome(data, uid) * reward.incomeMultSec
			PlayerDataManager.addCash(plr, gift)
			UpdateCash:FireClient(plr, data.Cash)
		end
	end
end)

-- ── Manual Rebirth Remote Handler ─────────────────────────────────────────────
RequestRebirth.OnServerEvent:Connect(function(plr)
	if DEBOUNCE[plr.UserId] then return end
	local data = PlayerDataManager.getData(plr)
	if not data or data.Cash < REBIRTH_COST then return end

	DEBOUNCE[plr.UserId] = true
	task.delay(1.5, function() DEBOUNCE[plr.UserId] = nil end)

	local plot = getPlot(plr)
	performRebirth(plr, data, plot)
end)

-- ── Plot Assignment ───────────────────────────────────────────────────────────
local function assignPlot(player, data)
	local plots = workspace:FindFirstChild("Plots")
	if not plots then return nil end

	for _, plot in ipairs(plots:GetChildren()) do
		local ov = plot:FindFirstChild("Owner")
		if ov and ov.Value == "" then
			ov.Value = player.Name
			setupCollectorPad(plot)

			if #(data.UnlockedUpgrades) == 0 then
				table.insert(data.UnlockedUpgrades, 1)
				spawnUpgradeVisual(plot, 1)
			else
				for _, id in ipairs(data.UnlockedUpgrades) do
					spawnUpgradeVisual(plot, id)
				end
			end

			if data.Gamepasses and data.Gamepasses.StarterPack and not data.StarterPackClaimed then
				PlayerDataManager.addCash(player, 5000)
				data.StarterPackClaimed = true
			end

			local nxt = nextUpgradeId(data)
			if nxt then spawnButton(plot, nxt, data.Cash) end

			return plot
		end
	end
	return nil
end

-- ── Income Tick Loop ──────────────────────────────────────────────────────────
task.spawn(function()
	while true do
		task.wait(1)
		for _, plr in ipairs(Players:GetPlayers()) do
			local data = PlayerDataManager.getData(plr)
			if not data then continue end

			local income   = calcIncome(data, plr.UserId)
			local autoPass = data.Gamepasses and data.Gamepasses.AutoCollect == true
			local plot     = getPlot(plr)

			if autoPass then
				local pending   = PENDING_CASH[plr.UserId] or 0
				local totalGain = income + pending
				PENDING_CASH[plr.UserId] = 0
				if totalGain > 0 then
					PlayerDataManager.addCash(plr, totalGain)
					UpdateCash:FireClient(plr, data.Cash)
				end
				UpdatePending:FireClient(plr, 0, true)
				updateCollectorDisplay(plot, "AUTO-COLLECT ACTIVE ✓", Color3.fromRGB(100, 220, 255))
			else
				if income > 0 then
					PENDING_CASH[plr.UserId] = (PENDING_CASH[plr.UserId] or 0) + income
				end
				local pending = PENDING_CASH[plr.UserId] or 0
				UpdatePending:FireClient(plr, pending, false)
				updateCollectorDisplay(plot, "Vault: " .. fmt(pending), Color3.fromRGB(100, 255, 130))
			end
		end
	end
end)

-- Slower loop: income display + button affordability color
task.spawn(function()
	while true do
		task.wait(2)
		for _, plr in ipairs(Players:GetPlayers()) do
			local data = PlayerDataManager.getData(plr)
			if not data then continue end
			UpdateIncome:FireClient(plr, calcIncome(data, plr.UserId))

			local plot = getPlot(plr)
			if not plot then continue end
			local btn = plot:FindFirstChild("PurchaseButton")
			if not (btn and btn:IsA("BasePart")) then continue end
			local nxt = nextUpgradeId(data)
			if not nxt then continue end
			local affordable = data.Cash >= UpgradeTable[nxt].cost
			btn.BrickColor = affordable and BrickColor.new("Bright green") or BrickColor.new("Bright yellow")
		end
	end
end)

-- ── Player Events ─────────────────────────────────────────────────────────────
Players.PlayerAdded:Connect(function(player)
	local uid = player.UserId
	PENDING_CASH[uid]   = 0
	SESSION_START[uid]  = os.clock()
	CLAIMED_GIFTS[uid]  = {}
	BOOST_END_TIME[uid] = 0
	local data = PlayerDataManager.loadPlayer(player)
	ShopHandler.checkGamepasses(player)

	-- Group bonus (async to avoid blocking join)
	if GROUP_ID > 0 and not data.GroupBonusClaimed then
		task.spawn(function()
			local ok, inGroup = pcall(function() return player:IsInGroup(GROUP_ID) end)
			if ok and inGroup then
				data.GroupBonusClaimed = true
				PlayerDataManager.addCash(player, 5000)
				PlayerDataManager.savePlayer(player)
				ShowToast:FireClient(player, "🎉 GROUP MEMBER BONUS: +$5,000 CASH!")
				UpdateCash:FireClient(player, data.Cash)
			end
		end)
	end

	local function onSpawn()
		if not getPlot(player) then assignPlot(player, data) end
		local autoPass = data.Gamepasses and data.Gamepasses.AutoCollect == true
		UpdateCash:FireClient(player, data.Cash)
		UpdateIncome:FireClient(player, calcIncome(data, uid))
		UpdatePrestige:FireClient(player, data.PrestigeLevel or 0, data.PrestigeMultiplier or 1)
		UpdatePending:FireClient(player, PENDING_CASH[uid] or 0, autoPass)

		-- Sync active server boost to newly spawning player
		local svrLeft = SERVER_BOOST_END - os.clock()
		if svrLeft > 0 then
			ServerBoostNotify:FireClient(player, { buyerName = "SERVER", remainingSec = math.floor(svrLeft) })
		end
	end

	if player.Character then onSpawn() end
	player.CharacterAdded:Connect(onSpawn)
end)

Players.PlayerRemoving:Connect(function(player)
	local uid = player.UserId
	PENDING_CASH[uid]   = nil
	SESSION_START[uid]  = nil
	CLAIMED_GIFTS[uid]  = nil
	BOOST_END_TIME[uid] = nil
	local plots = workspace:FindFirstChild("Plots")
	if not plots then return end
	for _, plot in ipairs(plots:GetChildren()) do
		local ov = plot:FindFirstChild("Owner")
		if ov and ov.Value == player.Name then
			ov.Value = ""
			for _, child in ipairs(plot:GetChildren()) do
				if child.Name:sub(1, 8) == "Upgrade_"
					or child.Name == "PurchaseButton"
					or child.Name == "PurchaseBeacon" then
					child:Destroy()
				end
			end
			updateCollectorDisplay(plot, "COLLECT HERE", Color3.fromRGB(0, 255, 80))
		end
	end
end)

print("[TycoonManager] Cash Empire Tycoon — Codes, Group Bonus, Server Boost ready.")
