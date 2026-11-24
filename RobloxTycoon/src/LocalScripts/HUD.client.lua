-- HUD — Cash display, Vault/Auto-Collect, Tabbed Shop, Rebirth, Leaderboard,
--        Promo Codes, Server Boost Banner, Toast notifications
local Players            = game:GetService("Players")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")
local TweenService       = game:GetService("TweenService")

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Remotes (server creates these before HUD loads)
local UpdateCash        = ReplicatedStorage:WaitForChild("UpdateCash",        15)
local UpdateIncome      = ReplicatedStorage:WaitForChild("UpdateIncome",      15)
local UpdatePrestige    = ReplicatedStorage:WaitForChild("UpdatePrestige",    15)
local UpdateLeaderboard = ReplicatedStorage:WaitForChild("UpdateLeaderboard", 15)
local UpdatePending     = ReplicatedStorage:WaitForChild("UpdatePending",     15)
local RequestRebirth    = ReplicatedStorage:WaitForChild("RequestRebirth",    15)
local RefreshGamepasses = ReplicatedStorage:WaitForChild("RefreshGamepasses", 15)
local UpdateBoost       = ReplicatedStorage:WaitForChild("UpdateBoost",       15)
local ShowToast         = ReplicatedStorage:WaitForChild("ShowToast",         15)
local ServerBoostNotify = ReplicatedStorage:WaitForChild("ServerBoostNotify", 15)
local RedeemCode        = ReplicatedStorage:WaitForChild("RedeemCode",        15)

local REBIRTH_COST = 100000000

-- Developer Product IDs — keep in sync with ShopHandler.lua
local DEVPRODUCT_IDS = {
	Cash10k        = 0,
	Cash100k       = 0,
	ServerBoost2x  = 0,
	InstantRebirth = 0,
}

local GAMEPASSES = {
	{ key = "StarterPack",    id = 2092291263, title = "2× CASH FOREVER",   desc = "Permanently doubles all cash + $5,000 bonus!",        color = Color3.fromRGB(46, 204, 113)  },
	{ key = "VIP",            id = 2096727203, title = "VIP EMPIRE PASS",   desc = "+25% permanent cash multiplier & VIP status!",         color = Color3.fromRGB(241, 196, 15)  },
	{ key = "AutoCollect",    id = 2094001229, title = "AUTO-COLLECT",      desc = "Automatically deposits cash straight to your wallet!", color = Color3.fromRGB(52,  152, 219)  },
	{ key = "DoublePrestige", id = 2092441277, title = "DOUBLE PRESTIGE",   desc = "2× Prestige multiplier bonus every Rebirth!",          color = Color3.fromRGB(155, 89,  182)  },
}

local DEVPRODUCTS = {
	{ key = "Cash10k",        title = "+$10,000 CASH",       desc = "Instant $10,000 cash boost!",           color = Color3.fromRGB(100, 220, 100) },
	{ key = "Cash100k",       title = "+$100,000 CASH",      desc = "Instant $100,000 cash boost!",          color = Color3.fromRGB(50,  200, 80)  },
	{ key = "ServerBoost2x",  title = "SERVER 2× BOOST",     desc = "15-min 2× cash for the ENTIRE server!", color = Color3.fromRGB(255, 160, 40)  },
	{ key = "InstantRebirth", title = "INSTANT PRESTIGE",    desc = "Skip the grind — Rebirth right now!",   color = Color3.fromRGB(220, 80,  180) },
}

-- ── Helpers ──────────────────────────────────────────────────────────────────
local function fmt(n)
	if n >= 1e9 then return string.format("$%.2fB", n / 1e9)
	elseif n >= 1e6 then return string.format("$%.2fM", n / 1e6)
	elseif n >= 1e3 then return string.format("$%.1fK", n / 1e3)
	else return "$" .. math.floor(n) end
end

local function fmtTime(sec)
	sec = math.max(0, math.floor(sec))
	local m = math.floor(sec / 60)
	local s = sec % 60
	return string.format("%d:%02d", m, s)
end

-- ── State ────────────────────────────────────────────────────────────────────
local currentCash        = 0
local currentLevel       = 0
local currentMult        = 1.0
local ownsDoublePrestige = false

local svrBoostUntil    = 0   -- os.time() expiry for server boost display
local svrBoostBuyerName = ""

-- ── Root ScreenGui ───────────────────────────────────────────────────────────
local sg = Instance.new("ScreenGui")
sg.Name           = "CashHUD"
sg.ResetOnSpawn   = false
sg.IgnoreGuiInset = false
sg.DisplayOrder   = 10
sg.Parent         = playerGui

-- ── Top bar ──────────────────────────────────────────────────────────────────
local topBar = Instance.new("Frame")
topBar.Name                   = "TopBar"
topBar.Size                   = UDim2.new(0.32, 0, 0.06, 0)
topBar.Position               = UDim2.new(0.26, 0, 0.015, 0)
topBar.BackgroundColor3       = Color3.fromRGB(10, 14, 24)
topBar.BackgroundTransparency = 0.25
topBar.BorderSizePixel        = 0
topBar.Parent                 = sg
Instance.new("UICorner", topBar).CornerRadius = UDim.new(0.35, 0)
local topStroke = Instance.new("UIStroke", topBar)
topStroke.Color = Color3.fromRGB(255, 215, 0); topStroke.Thickness = 1.5

local cashLbl = Instance.new("TextLabel")
cashLbl.Size = UDim2.new(0.58, 0, 0.85, 0); cashLbl.Position = UDim2.new(0.04, 0, 0.075, 0)
cashLbl.BackgroundTransparency = 1; cashLbl.TextColor3 = Color3.fromRGB(255, 215, 0)
cashLbl.TextScaled = true; cashLbl.Font = Enum.Font.GothamBold; cashLbl.Text = "$0"
cashLbl.TextXAlignment = Enum.TextXAlignment.Left; cashLbl.Parent = topBar

local incomeLbl = Instance.new("TextLabel")
incomeLbl.Size = UDim2.new(0.36, 0, 0.8, 0); incomeLbl.Position = UDim2.new(0.60, 0, 0.1, 0)
incomeLbl.BackgroundTransparency = 1; incomeLbl.TextColor3 = Color3.fromRGB(100, 255, 130)
incomeLbl.TextScaled = true; incomeLbl.Font = Enum.Font.GothamBold; incomeLbl.Text = "+$0/s"
incomeLbl.TextXAlignment = Enum.TextXAlignment.Right; incomeLbl.Parent = topBar

-- ── Vault / Auto-Collect Status Pill ─────────────────────────────────────────
local vaultPill = Instance.new("Frame")
vaultPill.Name = "VaultPill"; vaultPill.Size = UDim2.new(0.24, 0, 0.036, 0)
vaultPill.Position = UDim2.new(0.36, 0, 0.082, 0)
vaultPill.BackgroundColor3 = Color3.fromRGB(12, 24, 38); vaultPill.BackgroundTransparency = 0.25
vaultPill.BorderSizePixel = 0; vaultPill.Parent = sg
Instance.new("UICorner", vaultPill).CornerRadius = UDim.new(0.4, 0)

local vaultLbl = Instance.new("TextLabel")
vaultLbl.Size = UDim2.new(0.92, 0, 0.85, 0); vaultLbl.Position = UDim2.new(0.04, 0, 0.075, 0)
vaultLbl.BackgroundTransparency = 1; vaultLbl.TextColor3 = Color3.fromRGB(140, 255, 170)
vaultLbl.TextScaled = true; vaultLbl.Font = Enum.Font.GothamBold
vaultLbl.Text = "Vault: $0 (Step on Green Pad)"; vaultLbl.Parent = vaultPill

-- ── Server Boost Banner ───────────────────────────────────────────────────────
local svrBoostPill = Instance.new("Frame")
svrBoostPill.Name = "ServerBoostPill"
svrBoostPill.Size     = UDim2.new(0.76, 0, 0.038, 0)
svrBoostPill.Position = UDim2.new(0.12, 0, 0.082, 0)
svrBoostPill.BackgroundColor3       = Color3.fromRGB(180, 100, 0)
svrBoostPill.BackgroundTransparency = 0.1
svrBoostPill.BorderSizePixel        = 0
svrBoostPill.Visible                = false
svrBoostPill.ZIndex                 = 14
svrBoostPill.Parent                 = sg
Instance.new("UICorner", svrBoostPill).CornerRadius = UDim.new(0.35, 0)
local svrStroke = Instance.new("UIStroke", svrBoostPill)
svrStroke.Color = Color3.fromRGB(255, 200, 50); svrStroke.Thickness = 2

local svrBoostLbl = Instance.new("TextLabel")
svrBoostLbl.Size = UDim2.new(0.9, 0, 0.85, 0); svrBoostLbl.Position = UDim2.new(0.05, 0, 0.075, 0)
svrBoostLbl.BackgroundTransparency = 1; svrBoostLbl.TextColor3 = Color3.fromRGB(255, 230, 100)
svrBoostLbl.TextScaled = true; svrBoostLbl.Font = Enum.Font.GothamBold
svrBoostLbl.Text = "🔥 SERVER 2× BOOST ACTIVE — 0:00"; svrBoostLbl.ZIndex = 14
svrBoostLbl.Parent = svrBoostPill

-- Countdown loop for server boost pill
task.spawn(function()
	while true do
		task.wait(1)
		local remaining = svrBoostUntil - os.time()
		if remaining <= 0 then
			svrBoostPill.Visible = false
		else
			svrBoostPill.Visible = true
			svrBoostLbl.Text = string.format(
				"🔥 SERVER 2× BOOST (%s) — %s remaining",
				svrBoostBuyerName, fmtTime(remaining)
			)
		end
	end
end)

-- ── SHOP button ───────────────────────────────────────────────────────────────
local shopBtn = Instance.new("TextButton")
shopBtn.Name = "ShopBtn"; shopBtn.Size = UDim2.new(0.09, 0, 0.06, 0)
shopBtn.Position = UDim2.new(0.59, 0, 0.015, 0)
shopBtn.BackgroundColor3 = Color3.fromRGB(34, 153, 84); shopBtn.BorderSizePixel = 0
shopBtn.TextColor3 = Color3.fromRGB(255, 255, 255); shopBtn.TextScaled = true
shopBtn.Font = Enum.Font.GothamBold; shopBtn.Text = "SHOP"; shopBtn.Parent = sg
Instance.new("UICorner", shopBtn).CornerRadius = UDim.new(0.35, 0)
local shopBtnStroke = Instance.new("UIStroke", shopBtn)
shopBtnStroke.Color = Color3.fromRGB(130, 255, 170); shopBtnStroke.Thickness = 1.5

-- ── Leaderboard button ────────────────────────────────────────────────────────
local lbBtn = Instance.new("TextButton")
lbBtn.Name = "LBBtn"; lbBtn.Size = UDim2.new(0.08, 0, 0.06, 0)
lbBtn.Position = UDim2.new(0.69, 0, 0.015, 0)
lbBtn.BackgroundColor3 = Color3.fromRGB(20, 50, 110); lbBtn.BackgroundTransparency = 0.2
lbBtn.BorderSizePixel = 0; lbBtn.TextColor3 = Color3.fromRGB(180, 210, 255)
lbBtn.TextScaled = true; lbBtn.Font = Enum.Font.GothamBold; lbBtn.Text = "TOP"; lbBtn.Parent = sg
Instance.new("UICorner", lbBtn).CornerRadius = UDim.new(0.35, 0)

-- ── CODES button (purple, right of LB) ───────────────────────────────────────
local codesBtn = Instance.new("TextButton")
codesBtn.Name = "CodesBtn"; codesBtn.Size = UDim2.new(0.06, 0, 0.06, 0)
codesBtn.Position = UDim2.new(0.78, 0, 0.015, 0)
codesBtn.BackgroundColor3 = Color3.fromRGB(100, 30, 180); codesBtn.BorderSizePixel = 0
codesBtn.TextColor3 = Color3.fromRGB(220, 180, 255); codesBtn.TextScaled = true
codesBtn.Font = Enum.Font.GothamBold; codesBtn.Text = "CODE"; codesBtn.Parent = sg
Instance.new("UICorner", codesBtn).CornerRadius = UDim.new(0.35, 0)
local codesBtnStroke = Instance.new("UIStroke", codesBtn)
codesBtnStroke.Color = Color3.fromRGB(180, 100, 255); codesBtnStroke.Thickness = 1.5

-- ── Prestige badge + REBIRTH button (bottom-left) ────────────────────────────
local prestigeBadge = Instance.new("Frame")
prestigeBadge.Size = UDim2.new(0.17, 0, 0.055, 0); prestigeBadge.Position = UDim2.new(0.012, 0, 0.92, 0)
prestigeBadge.BackgroundColor3 = Color3.fromRGB(80, 0, 160); prestigeBadge.BackgroundTransparency = 0.2
prestigeBadge.BorderSizePixel = 0; prestigeBadge.Parent = sg
Instance.new("UICorner", prestigeBadge).CornerRadius = UDim.new(0.35, 0)

local prestigeLbl = Instance.new("TextLabel")
prestigeLbl.Size = UDim2.new(0.9, 0, 0.85, 0); prestigeLbl.Position = UDim2.new(0.05, 0, 0.075, 0)
prestigeLbl.BackgroundTransparency = 1; prestigeLbl.TextColor3 = Color3.fromRGB(220, 180, 255)
prestigeLbl.TextScaled = true; prestigeLbl.Font = Enum.Font.GothamBold
prestigeLbl.Text = "Prestige 0  ×1.0"; prestigeLbl.Parent = prestigeBadge

local rebirthHudBtn = Instance.new("TextButton")
rebirthHudBtn.Size = UDim2.new(0.12, 0, 0.055, 0); rebirthHudBtn.Position = UDim2.new(0.19, 0, 0.92, 0)
rebirthHudBtn.BackgroundColor3 = Color3.fromRGB(130, 30, 90); rebirthHudBtn.BorderSizePixel = 0
rebirthHudBtn.TextColor3 = Color3.fromRGB(255, 255, 255); rebirthHudBtn.TextScaled = true
rebirthHudBtn.Font = Enum.Font.GothamBold; rebirthHudBtn.Text = "REBIRTH"; rebirthHudBtn.Parent = sg
Instance.new("UICorner", rebirthHudBtn).CornerRadius = UDim.new(0.35, 0)
local rbStroke = Instance.new("UIStroke", rebirthHudBtn)
rbStroke.Color = Color3.fromRGB(255, 130, 210); rbStroke.Thickness = 1.5

-- ── REBIRTH PANEL ────────────────────────────────────────────────────────────
local rebirthPanel = Instance.new("Frame")
rebirthPanel.Name = "RebirthPanel"; rebirthPanel.Size = UDim2.new(0.42, 0, 0.46, 0)
rebirthPanel.Position = UDim2.new(0.29, 0, 0.27, 0)
rebirthPanel.BackgroundColor3 = Color3.fromRGB(18, 12, 32); rebirthPanel.BackgroundTransparency = 0.04
rebirthPanel.BorderSizePixel = 0; rebirthPanel.Visible = false; rebirthPanel.ZIndex = 25; rebirthPanel.Parent = sg
Instance.new("UICorner", rebirthPanel).CornerRadius = UDim.new(0.05, 0)
local rbPanelStroke = Instance.new("UIStroke", rebirthPanel)
rbPanelStroke.Color = Color3.fromRGB(255, 80, 180); rbPanelStroke.Thickness = 2

local rbTitle = Instance.new("TextLabel")
rbTitle.Size = UDim2.new(0.8, 0, 0.16, 0); rbTitle.Position = UDim2.new(0.05, 0, 0.04, 0)
rbTitle.BackgroundTransparency = 1; rbTitle.TextColor3 = Color3.fromRGB(255, 110, 200)
rbTitle.TextScaled = true; rbTitle.Font = Enum.Font.GothamBold; rbTitle.Text = "PRESTIGE REBIRTH"
rbTitle.TextXAlignment = Enum.TextXAlignment.Left; rbTitle.ZIndex = 26; rbTitle.Parent = rebirthPanel

local closeRbBtn = Instance.new("TextButton")
closeRbBtn.Size = UDim2.new(0.11, 0, 0.14, 0); closeRbBtn.Position = UDim2.new(0.85, 0, 0.04, 0)
closeRbBtn.BackgroundColor3 = Color3.fromRGB(192, 57, 43); closeRbBtn.BorderSizePixel = 0
closeRbBtn.TextColor3 = Color3.fromRGB(255,255,255); closeRbBtn.TextScaled = true
closeRbBtn.Font = Enum.Font.GothamBold; closeRbBtn.Text = "X"; closeRbBtn.ZIndex = 26; closeRbBtn.Parent = rebirthPanel
Instance.new("UICorner", closeRbBtn).CornerRadius = UDim.new(0.3, 0)

local rbDesc = Instance.new("TextLabel")
rbDesc.Size = UDim2.new(0.9, 0, 0.24, 0); rbDesc.Position = UDim2.new(0.05, 0, 0.22, 0)
rbDesc.BackgroundTransparency = 1; rbDesc.TextColor3 = Color3.fromRGB(225, 225, 240)
rbDesc.TextScaled = true; rbDesc.Font = Enum.Font.Gotham
rbDesc.Text = "Reset your plot and cash to gain a permanent income multiplier! (Gamepasses & Prestige stay forever)"
rbDesc.ZIndex = 26; rbDesc.Parent = rebirthPanel

local rbStatsLbl = Instance.new("TextLabel")
rbStatsLbl.Size = UDim2.new(0.9, 0, 0.16, 0); rbStatsLbl.Position = UDim2.new(0.05, 0, 0.48, 0)
rbStatsLbl.BackgroundTransparency = 1; rbStatsLbl.TextColor3 = Color3.fromRGB(255, 215, 0)
rbStatsLbl.TextScaled = true; rbStatsLbl.Font = Enum.Font.GothamBold
rbStatsLbl.Text = "Multiplier: ×1.0  →  ×1.5"; rbStatsLbl.ZIndex = 26; rbStatsLbl.Parent = rebirthPanel

local confirmRbBtn = Instance.new("TextButton")
confirmRbBtn.Size = UDim2.new(0.84, 0, 0.22, 0); confirmRbBtn.Position = UDim2.new(0.08, 0, 0.70, 0)
confirmRbBtn.BackgroundColor3 = Color3.fromRGB(80, 85, 100); confirmRbBtn.BorderSizePixel = 0
confirmRbBtn.TextColor3 = Color3.fromRGB(255,255,255); confirmRbBtn.TextScaled = true
confirmRbBtn.Font = Enum.Font.GothamBold; confirmRbBtn.Text = "NEED $100.00M TO REBIRTH"
confirmRbBtn.ZIndex = 26; confirmRbBtn.Parent = rebirthPanel
Instance.new("UICorner", confirmRbBtn).CornerRadius = UDim.new(0.25, 0)

local function refreshRebirthUI()
	local gain    = ownsDoublePrestige and 1.0 or 0.5
	local nxtMult = currentMult + gain
	rbStatsLbl.Text = string.format(
		"Prestige %d (×%.1f)  →  Prestige %d (×%.1f)",
		currentLevel, currentMult, currentLevel + 1, nxtMult
	)
	if currentCash >= REBIRTH_COST then
		confirmRbBtn.BackgroundColor3  = Color3.fromRGB(219, 39, 119)
		confirmRbBtn.Text              = "REBIRTH NOW ($100.00M)"
		rebirthHudBtn.BackgroundColor3 = Color3.fromRGB(236, 72, 153)
	else
		confirmRbBtn.BackgroundColor3  = Color3.fromRGB(75, 80, 95)
		confirmRbBtn.Text              = "NEED " .. fmt(REBIRTH_COST - currentCash) .. " MORE"
		rebirthHudBtn.BackgroundColor3 = Color3.fromRGB(130, 30, 90)
	end
end

confirmRbBtn.MouseButton1Click:Connect(function()
	if currentCash < REBIRTH_COST then return end
	if RequestRebirth then RequestRebirth:FireServer() end
	rebirthPanel.Visible = false
end)

-- ── TABBED SHOP PANEL ────────────────────────────────────────────────────────
local shopPanel = Instance.new("Frame")
shopPanel.Name = "ShopPanel"; shopPanel.Size = UDim2.new(0.52, 0, 0.72, 0)
shopPanel.Position = UDim2.new(0.24, 0, 0.14, 0)
shopPanel.BackgroundColor3 = Color3.fromRGB(12, 18, 32); shopPanel.BackgroundTransparency = 0.05
shopPanel.BorderSizePixel = 0; shopPanel.Visible = false; shopPanel.ZIndex = 20; shopPanel.Parent = sg
Instance.new("UICorner", shopPanel).CornerRadius = UDim.new(0.04, 0)
local panelStroke = Instance.new("UIStroke", shopPanel)
panelStroke.Color = Color3.fromRGB(255, 215, 0); panelStroke.Thickness = 2

local shopTitleLbl = Instance.new("TextLabel")
shopTitleLbl.Size = UDim2.new(0.7, 0, 0.09, 0); shopTitleLbl.Position = UDim2.new(0.04, 0, 0.015, 0)
shopTitleLbl.BackgroundTransparency = 1; shopTitleLbl.TextColor3 = Color3.fromRGB(255, 215, 0)
shopTitleLbl.TextScaled = true; shopTitleLbl.Font = Enum.Font.GothamBold
shopTitleLbl.Text = "EMPIRE SHOP"; shopTitleLbl.TextXAlignment = Enum.TextXAlignment.Left
shopTitleLbl.ZIndex = 21; shopTitleLbl.Parent = shopPanel

local closeShopBtn = Instance.new("TextButton")
closeShopBtn.Size = UDim2.new(0.1, 0, 0.09, 0); closeShopBtn.Position = UDim2.new(0.87, 0, 0.015, 0)
closeShopBtn.BackgroundColor3 = Color3.fromRGB(192, 57, 43); closeShopBtn.BorderSizePixel = 0
closeShopBtn.TextColor3 = Color3.fromRGB(255,255,255); closeShopBtn.TextScaled = true
closeShopBtn.Font = Enum.Font.GothamBold; closeShopBtn.Text = "X"; closeShopBtn.ZIndex = 21; closeShopBtn.Parent = shopPanel
Instance.new("UICorner", closeShopBtn).CornerRadius = UDim.new(0.3, 0)

-- Tab bar
local tabBar = Instance.new("Frame")
tabBar.Size = UDim2.new(0.92, 0, 0.09, 0); tabBar.Position = UDim2.new(0.04, 0, 0.11, 0)
tabBar.BackgroundColor3 = Color3.fromRGB(8, 14, 28); tabBar.BackgroundTransparency = 0.3
tabBar.BorderSizePixel = 0; tabBar.ZIndex = 21; tabBar.Parent = shopPanel
Instance.new("UICorner", tabBar).CornerRadius = UDim.new(0.35, 0)

local tabPasses = Instance.new("TextButton")
tabPasses.Size = UDim2.new(0.5, 0, 1, 0); tabPasses.Position = UDim2.new(0, 0, 0, 0)
tabPasses.BackgroundColor3 = Color3.fromRGB(34, 153, 84); tabPasses.BorderSizePixel = 0
tabPasses.TextColor3 = Color3.fromRGB(255,255,255); tabPasses.TextScaled = true
tabPasses.Font = Enum.Font.GothamBold; tabPasses.Text = "GAMEPASSES"
tabPasses.ZIndex = 22; tabPasses.Parent = tabBar
Instance.new("UICorner", tabPasses).CornerRadius = UDim.new(0.35, 0)

local tabBoosts = Instance.new("TextButton")
tabBoosts.Size = UDim2.new(0.5, 0, 1, 0); tabBoosts.Position = UDim2.new(0.5, 0, 0, 0)
tabBoosts.BackgroundColor3 = Color3.fromRGB(30, 40, 65); tabBoosts.BorderSizePixel = 0
tabBoosts.TextColor3 = Color3.fromRGB(180, 190, 220); tabBoosts.TextScaled = true
tabBoosts.Font = Enum.Font.GothamBold; tabBoosts.Text = "BOOSTS & CASH"
tabBoosts.ZIndex = 22; tabBoosts.Parent = tabBar
Instance.new("UICorner", tabBoosts).CornerRadius = UDim.new(0.35, 0)

-- Gamepass content
local gpContent = Instance.new("Frame")
gpContent.Size = UDim2.new(0.92, 0, 0.78, 0); gpContent.Position = UDim2.new(0.04, 0, 0.21, 0)
gpContent.BackgroundTransparency = 1; gpContent.ZIndex = 21; gpContent.Parent = shopPanel
local gpLayout = Instance.new("UIListLayout", gpContent)
gpLayout.Padding = UDim.new(0.025, 0); gpLayout.SortOrder = Enum.SortOrder.LayoutOrder

-- Boost content
local boostContent = Instance.new("Frame")
boostContent.Size = UDim2.new(0.92, 0, 0.78, 0); boostContent.Position = UDim2.new(0.04, 0, 0.21, 0)
boostContent.BackgroundTransparency = 1; boostContent.Visible = false; boostContent.ZIndex = 21; boostContent.Parent = shopPanel
local boostLayout = Instance.new("UIListLayout", boostContent)
boostLayout.Padding = UDim.new(0.025, 0); boostLayout.SortOrder = Enum.SortOrder.LayoutOrder

local function switchTab(showPasses)
	gpContent.Visible   = showPasses
	boostContent.Visible = not showPasses
	tabPasses.BackgroundColor3 = showPasses and Color3.fromRGB(34,153,84) or Color3.fromRGB(30,40,65)
	tabPasses.TextColor3 = showPasses and Color3.fromRGB(255,255,255) or Color3.fromRGB(180,190,220)
	tabBoosts.BackgroundColor3 = (not showPasses) and Color3.fromRGB(200,120,30) or Color3.fromRGB(30,40,65)
	tabBoosts.TextColor3 = (not showPasses) and Color3.fromRGB(255,255,255) or Color3.fromRGB(180,190,220)
end

tabPasses.MouseButton1Click:Connect(function() switchTab(true) end)
tabBoosts.MouseButton1Click:Connect(function() switchTab(false) end)

-- ── Gamepass cards ────────────────────────────────────────────────────────────
local buyButtonsById = {}

local function markOwned(buyBtn, passKey)
	buyBtn.Text = "OWNED ✓"; buyBtn.BackgroundColor3 = Color3.fromRGB(70, 80, 95)
	buyBtn.AutoButtonColor = false
	if passKey == "DoublePrestige" then ownsDoublePrestige = true; refreshRebirthUI() end
end

for idx, pass in ipairs(GAMEPASSES) do
	local card = Instance.new("Frame")
	card.Size = UDim2.new(1, 0, 0.225, 0); card.BackgroundColor3 = Color3.fromRGB(22, 32, 54)
	card.BorderSizePixel = 0; card.LayoutOrder = idx; card.ZIndex = 22; card.Parent = gpContent
	Instance.new("UICorner", card).CornerRadius = UDim.new(0.18, 0)
	local cs = Instance.new("UIStroke", card); cs.Color = pass.color; cs.Thickness = 1.5

	local nameLbl = Instance.new("TextLabel")
	nameLbl.Size = UDim2.new(0.66,0,0.45,0); nameLbl.Position = UDim2.new(0.03,0,0.08,0)
	nameLbl.BackgroundTransparency = 1; nameLbl.TextColor3 = pass.color
	nameLbl.TextScaled = true; nameLbl.Font = Enum.Font.GothamBold; nameLbl.Text = pass.title
	nameLbl.TextXAlignment = Enum.TextXAlignment.Left; nameLbl.ZIndex = 23; nameLbl.Parent = card

	local descLbl = Instance.new("TextLabel")
	descLbl.Size = UDim2.new(0.66,0,0.38,0); descLbl.Position = UDim2.new(0.03,0,0.54,0)
	descLbl.BackgroundTransparency = 1; descLbl.TextColor3 = Color3.fromRGB(210,220,235)
	descLbl.TextScaled = true; descLbl.Font = Enum.Font.Gotham; descLbl.Text = pass.desc
	descLbl.TextXAlignment = Enum.TextXAlignment.Left; descLbl.ZIndex = 23; descLbl.Parent = card

	local buyBtn = Instance.new("TextButton")
	buyBtn.Size = UDim2.new(0.26,0,0.72,0); buyBtn.Position = UDim2.new(0.71,0,0.14,0)
	buyBtn.BackgroundColor3 = Color3.fromRGB(39,174,96); buyBtn.BorderSizePixel = 0
	buyBtn.TextColor3 = Color3.fromRGB(255,255,255); buyBtn.TextScaled = true
	buyBtn.Font = Enum.Font.GothamBold; buyBtn.Text = "BUY"; buyBtn.ZIndex = 23; buyBtn.Parent = card
	Instance.new("UICorner", buyBtn).CornerRadius = UDim.new(0.25, 0)

	buyButtonsById[pass.id] = { btn = buyBtn, key = pass.key }

	task.spawn(function()
		local okOwn, owns = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(player.UserId, pass.id)
		end)
		if okOwn and owns then markOwned(buyBtn, pass.key); return end

		local okInfo, info = pcall(function()
			return MarketplaceService:GetProductInfo(pass.id, Enum.InfoType.GamePass)
		end)
		if okInfo and info and info.PriceInRobux then
			buyBtn.Text = "R$ " .. info.PriceInRobux
		end
	end)

	buyBtn.MouseButton1Click:Connect(function()
		if buyBtn.Text == "OWNED ✓" then return end
		MarketplaceService:PromptGamePassPurchase(player, pass.id)
	end)
end

MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(plr, passId, wasPurchased)
	if plr == player and wasPurchased then
		local entry = buyButtonsById[passId]
		if entry then markOwned(entry.btn, entry.key) end
		if RefreshGamepasses then RefreshGamepasses:FireServer() end
	end
end)

-- ── Dev Product (Boost & Cash) cards ─────────────────────────────────────────
for idx, prod in ipairs(DEVPRODUCTS) do
	local card = Instance.new("Frame")
	card.Size = UDim2.new(1, 0, 0.225, 0); card.BackgroundColor3 = Color3.fromRGB(18, 28, 46)
	card.BorderSizePixel = 0; card.LayoutOrder = idx; card.ZIndex = 22; card.Parent = boostContent
	Instance.new("UICorner", card).CornerRadius = UDim.new(0.18, 0)
	local cs = Instance.new("UIStroke", card); cs.Color = prod.color; cs.Thickness = 1.5

	local nameLbl = Instance.new("TextLabel")
	nameLbl.Size = UDim2.new(0.65,0,0.45,0); nameLbl.Position = UDim2.new(0.03,0,0.08,0)
	nameLbl.BackgroundTransparency = 1; nameLbl.TextColor3 = prod.color
	nameLbl.TextScaled = true; nameLbl.Font = Enum.Font.GothamBold; nameLbl.Text = prod.title
	nameLbl.TextXAlignment = Enum.TextXAlignment.Left; nameLbl.ZIndex = 23; nameLbl.Parent = card

	local descLbl = Instance.new("TextLabel")
	descLbl.Size = UDim2.new(0.65,0,0.38,0); descLbl.Position = UDim2.new(0.03,0,0.54,0)
	descLbl.BackgroundTransparency = 1; descLbl.TextColor3 = Color3.fromRGB(210,220,235)
	descLbl.TextScaled = true; descLbl.Font = Enum.Font.Gotham; descLbl.Text = prod.desc
	descLbl.TextXAlignment = Enum.TextXAlignment.Left; descLbl.ZIndex = 23; descLbl.Parent = card

	local buyBtn = Instance.new("TextButton")
	buyBtn.Size = UDim2.new(0.27,0,0.72,0); buyBtn.Position = UDim2.new(0.70,0,0.14,0)
	buyBtn.BorderSizePixel = 0; buyBtn.TextColor3 = Color3.fromRGB(255,255,255)
	buyBtn.TextScaled = true; buyBtn.Font = Enum.Font.GothamBold
	buyBtn.ZIndex = 23; buyBtn.Parent = card
	Instance.new("UICorner", buyBtn).CornerRadius = UDim.new(0.25, 0)

	local pid = DEVPRODUCT_IDS[prod.key]
	if pid == 0 then
		buyBtn.Text = "COMING SOON"; buyBtn.BackgroundColor3 = Color3.fromRGB(60, 65, 80)
		buyBtn.AutoButtonColor = false
	else
		buyBtn.Text = "BUY"; buyBtn.BackgroundColor3 = prod.color

		task.spawn(function()
			local ok, info = pcall(function()
				return MarketplaceService:GetProductInfo(pid, Enum.InfoType.Product)
			end)
			if ok and info and info.PriceInRobux then
				buyBtn.Text = "R$ " .. info.PriceInRobux
			end
		end)

		buyBtn.MouseButton1Click:Connect(function()
			MarketplaceService:PromptProductPurchase(player, pid)
		end)
	end
end

-- ── Leaderboard panel ────────────────────────────────────────────────────────
local lbPanel = Instance.new("Frame")
lbPanel.Name = "LBPanel"; lbPanel.Size = UDim2.new(0.3,0,0.52,0)
lbPanel.Position = UDim2.new(0.55,0,0.09,0)
lbPanel.BackgroundColor3 = Color3.fromRGB(8,16,36); lbPanel.BackgroundTransparency = 0.08
lbPanel.BorderSizePixel = 0; lbPanel.Visible = false; lbPanel.ZIndex = 15; lbPanel.Parent = sg
Instance.new("UICorner", lbPanel).CornerRadius = UDim.new(0.03, 0)

local lbTitleLbl = Instance.new("TextLabel")
lbTitleLbl.Size = UDim2.new(1,0,0.11,0); lbTitleLbl.BackgroundTransparency = 1
lbTitleLbl.TextColor3 = Color3.fromRGB(255,215,0); lbTitleLbl.TextScaled = true
lbTitleLbl.Font = Enum.Font.GothamBold; lbTitleLbl.Text = "TOP EARNERS"
lbTitleLbl.ZIndex = 16; lbTitleLbl.Parent = lbPanel

local lbScroll = Instance.new("ScrollingFrame")
lbScroll.Size = UDim2.new(1,0,0.89,0); lbScroll.Position = UDim2.new(0,0,0.11,0)
lbScroll.BackgroundTransparency = 1; lbScroll.BorderSizePixel = 0
lbScroll.ScrollBarThickness = 4; lbScroll.CanvasSize = UDim2.new(0,0,0,0)
lbScroll.ZIndex = 16; lbScroll.Parent = lbPanel
Instance.new("UIListLayout", lbScroll).SortOrder = Enum.SortOrder.LayoutOrder

-- ── CODES PANEL ───────────────────────────────────────────────────────────────
local codesPanel = Instance.new("Frame")
codesPanel.Name = "CodesPanel"; codesPanel.Size = UDim2.new(0.38, 0, 0.36, 0)
codesPanel.Position = UDim2.new(0.31, 0, 0.32, 0)
codesPanel.BackgroundColor3 = Color3.fromRGB(14, 10, 28); codesPanel.BackgroundTransparency = 0.04
codesPanel.BorderSizePixel = 0; codesPanel.Visible = false; codesPanel.ZIndex = 30; codesPanel.Parent = sg
Instance.new("UICorner", codesPanel).CornerRadius = UDim.new(0.06, 0)
local codesPanelStroke = Instance.new("UIStroke", codesPanel)
codesPanelStroke.Color = Color3.fromRGB(180, 100, 255); codesPanelStroke.Thickness = 2

local codesTitleLbl = Instance.new("TextLabel")
codesTitleLbl.Size = UDim2.new(0.78, 0, 0.18, 0); codesTitleLbl.Position = UDim2.new(0.05, 0, 0.04, 0)
codesTitleLbl.BackgroundTransparency = 1; codesTitleLbl.TextColor3 = Color3.fromRGB(220, 180, 255)
codesTitleLbl.TextScaled = true; codesTitleLbl.Font = Enum.Font.GothamBold
codesTitleLbl.Text = "REDEEM A CODE"; codesTitleLbl.TextXAlignment = Enum.TextXAlignment.Left
codesTitleLbl.ZIndex = 31; codesTitleLbl.Parent = codesPanel

local closeCodesBtn = Instance.new("TextButton")
closeCodesBtn.Size = UDim2.new(0.12, 0, 0.17, 0); closeCodesBtn.Position = UDim2.new(0.84, 0, 0.04, 0)
closeCodesBtn.BackgroundColor3 = Color3.fromRGB(192, 57, 43); closeCodesBtn.BorderSizePixel = 0
closeCodesBtn.TextColor3 = Color3.fromRGB(255,255,255); closeCodesBtn.TextScaled = true
closeCodesBtn.Font = Enum.Font.GothamBold; closeCodesBtn.Text = "X"
closeCodesBtn.ZIndex = 31; closeCodesBtn.Parent = codesPanel
Instance.new("UICorner", closeCodesBtn).CornerRadius = UDim.new(0.3, 0)

local codeBox = Instance.new("TextBox")
codeBox.Size = UDim2.new(0.9, 0, 0.22, 0); codeBox.Position = UDim2.new(0.05, 0, 0.26, 0)
codeBox.BackgroundColor3 = Color3.fromRGB(25, 20, 48); codeBox.BorderSizePixel = 0
codeBox.TextColor3 = Color3.fromRGB(220, 220, 255); codeBox.TextScaled = true
codeBox.Font = Enum.Font.GothamBold; codeBox.PlaceholderText = "Enter code here..."
codeBox.PlaceholderColor3 = Color3.fromRGB(120, 100, 160); codeBox.Text = ""
codeBox.ClearTextOnFocus = true; codeBox.ZIndex = 31; codeBox.Parent = codesPanel
Instance.new("UICorner", codeBox).CornerRadius = UDim.new(0.2, 0)

local redeemBtn = Instance.new("TextButton")
redeemBtn.Size = UDim2.new(0.9, 0, 0.2, 0); redeemBtn.Position = UDim2.new(0.05, 0, 0.52, 0)
redeemBtn.BackgroundColor3 = Color3.fromRGB(100, 30, 180); redeemBtn.BorderSizePixel = 0
redeemBtn.TextColor3 = Color3.fromRGB(255,255,255); redeemBtn.TextScaled = true
redeemBtn.Font = Enum.Font.GothamBold; redeemBtn.Text = "REDEEM"
redeemBtn.ZIndex = 31; redeemBtn.Parent = codesPanel
Instance.new("UICorner", redeemBtn).CornerRadius = UDim.new(0.25, 0)

local codesStatusLbl = Instance.new("TextLabel")
codesStatusLbl.Size = UDim2.new(0.9, 0, 0.2, 0); codesStatusLbl.Position = UDim2.new(0.05, 0, 0.75, 0)
codesStatusLbl.BackgroundTransparency = 1; codesStatusLbl.TextColor3 = Color3.fromRGB(180, 255, 180)
codesStatusLbl.TextScaled = true; codesStatusLbl.Font = Enum.Font.Gotham
codesStatusLbl.Text = ""; codesStatusLbl.ZIndex = 31; codesStatusLbl.Parent = codesPanel

redeemBtn.MouseButton1Click:Connect(function()
	local code = codeBox.Text
	if code == "" then codesStatusLbl.Text = "Enter a code first!"; codesStatusLbl.TextColor3 = Color3.fromRGB(255,120,120); return end

	redeemBtn.Text = "..."; redeemBtn.AutoButtonColor = false
	local ok, result = pcall(function() return RedeemCode:InvokeServer(code) end)
	redeemBtn.Text = "REDEEM"; redeemBtn.AutoButtonColor = true

	if ok and result then
		if result.success then
			codesStatusLbl.Text      = result.message
			codesStatusLbl.TextColor3 = Color3.fromRGB(100, 255, 150)
			codeBox.Text             = ""
		else
			codesStatusLbl.Text      = result.message
			codesStatusLbl.TextColor3 = Color3.fromRGB(255, 120, 120)
		end
	else
		codesStatusLbl.Text      = "Connection error — try again."
		codesStatusLbl.TextColor3 = Color3.fromRGB(255, 180, 60)
	end
end)

-- ── Toast Notification ────────────────────────────────────────────────────────
local function showToast(msg)
	local toast = Instance.new("Frame")
	toast.Size = UDim2.new(0.4, 0, 0.065, 0)
	toast.Position = UDim2.new(0.3, 0, 1.0, 0)  -- starts below screen
	toast.BackgroundColor3 = Color3.fromRGB(14, 20, 40)
	toast.BackgroundTransparency = 0.1
	toast.BorderSizePixel = 0
	toast.ZIndex = 50
	toast.Parent = sg
	Instance.new("UICorner", toast).CornerRadius = UDim.new(0.35, 0)
	local ts = Instance.new("UIStroke", toast); ts.Color = Color3.fromRGB(100, 200, 255); ts.Thickness = 1.5

	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.new(0.9, 0, 0.85, 0); lbl.Position = UDim2.new(0.05, 0, 0.075, 0)
	lbl.BackgroundTransparency = 1; lbl.TextColor3 = Color3.fromRGB(220, 240, 255)
	lbl.TextScaled = true; lbl.Font = Enum.Font.GothamBold; lbl.Text = msg
	lbl.ZIndex = 51; lbl.Parent = toast

	-- Slide up
	TweenService:Create(toast, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Position = UDim2.new(0.3, 0, 0.9, 0) }):Play()

	-- Hold then slide out
	task.delay(2.5, function()
		TweenService:Create(toast, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ Position = UDim2.new(0.3, 0, 1.05, 0) }):Play()
		task.delay(0.3, function() toast:Destroy() end)
	end)
end

-- ── Panel Toggles ─────────────────────────────────────────────────────────────
local function closeAllPanels()
	shopPanel.Visible = false; lbPanel.Visible = false
	rebirthPanel.Visible = false; codesPanel.Visible = false
end

shopBtn.MouseButton1Click:Connect(function()
	local t = not shopPanel.Visible; closeAllPanels(); shopPanel.Visible = t
	if t then switchTab(true) end
end)
closeShopBtn.MouseButton1Click:Connect(closeAllPanels)

lbBtn.MouseButton1Click:Connect(function()
	local t = not lbPanel.Visible; closeAllPanels(); lbPanel.Visible = t
end)

rebirthHudBtn.MouseButton1Click:Connect(function()
	local t = not rebirthPanel.Visible; closeAllPanels()
	if t then refreshRebirthUI() end
	rebirthPanel.Visible = t
end)
closeRbBtn.MouseButton1Click:Connect(closeAllPanels)

codesBtn.MouseButton1Click:Connect(function()
	local t = not codesPanel.Visible; closeAllPanels(); codesPanel.Visible = t
	if t then codesStatusLbl.Text = "" end
end)
closeCodesBtn.MouseButton1Click:Connect(closeAllPanels)

-- ── Cash Pop Animation ───────────────────────────────────────────────────────
local prevCash = 0
local function animateCash()
	TweenService:Create(cashLbl, TweenInfo.new(0.08, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ TextColor3 = Color3.fromRGB(255, 255, 100) }):Play()
	task.delay(0.15, function()
		TweenService:Create(cashLbl, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ TextColor3 = Color3.fromRGB(255, 215, 0) }):Play()
	end)
end

-- ── Remote Event Handlers ────────────────────────────────────────────────────
UpdateCash.OnClientEvent:Connect(function(cash)
	currentCash = cash
	cashLbl.Text = fmt(cash)
	if cash > prevCash then animateCash() end
	prevCash = cash
	refreshRebirthUI()
end)

UpdateIncome.OnClientEvent:Connect(function(income)
	incomeLbl.Text = "+" .. fmt(income):sub(2) .. "/s"
end)

UpdatePrestige.OnClientEvent:Connect(function(level, mult)
	currentLevel = level; currentMult = mult
	prestigeLbl.Text = "Prestige " .. level .. "  ×" .. string.format("%.1f", mult)
	refreshRebirthUI()
end)

UpdatePending.OnClientEvent:Connect(function(pending, isAuto)
	if isAuto then
		vaultLbl.Text = "⚡ AUTO-COLLECT ACTIVE"; vaultLbl.TextColor3 = Color3.fromRGB(100, 220, 255)
	else
		vaultLbl.Text = "Vault: " .. fmt(pending) .. " (Step on Green Pad)"
		vaultLbl.TextColor3 = Color3.fromRGB(140, 255, 170)
	end
end)

UpdateLeaderboard.OnClientEvent:Connect(function(entries)
	for _, c in ipairs(lbScroll:GetChildren()) do if c:IsA("Frame") then c:Destroy() end end
	local RANK_COLORS = { Color3.fromRGB(255,215,0), Color3.fromRGB(192,192,192), Color3.fromRGB(205,127,50) }
	for i, entry in ipairs(entries) do
		local row = Instance.new("Frame")
		row.Size = UDim2.new(1,0,0,38); row.BackgroundColor3 = Color3.fromRGB(15,30,65)
		row.BackgroundTransparency = i%2==0 and 0.75 or 0.85
		row.BorderSizePixel = 0; row.LayoutOrder = i; row.ZIndex = 17; row.Parent = lbScroll

		local function cell(text, color, xPos, w, align)
			local l = Instance.new("TextLabel")
			l.Size = UDim2.new(w,0,1,0); l.Position = UDim2.new(xPos,0,0,0)
			l.BackgroundTransparency = 1; l.TextColor3 = color
			l.TextScaled = true; l.Font = Enum.Font.GothamBold; l.Text = text
			l.TextXAlignment = align or Enum.TextXAlignment.Left; l.ZIndex = 18; l.Parent = row
		end

		cell("#"..i, RANK_COLORS[i] or Color3.fromRGB(200,200,200), 0, 0.14, Enum.TextXAlignment.Center)
		cell(entry[1] or "?", Color3.fromRGB(220,220,220), 0.14, 0.52)
		cell(fmt(entry[2] or 0), Color3.fromRGB(255,215,0), 0.66, 0.34, Enum.TextXAlignment.Right)
	end
	lbScroll.CanvasSize = UDim2.new(0, 0, 0, #entries * 38)
end)

ShowToast.OnClientEvent:Connect(function(msg) showToast(msg) end)

ServerBoostNotify.OnClientEvent:Connect(function(info)
	if typeof(info) == "table" then
		svrBoostBuyerName = info.buyerName or "SERVER"
		svrBoostUntil     = os.time() + (info.remainingSec or 900)
	end
	showToast("🔥 SERVER 2× BOOST activated by " .. svrBoostBuyerName .. "!")
end)

UpdateBoost.OnClientEvent:Connect(function(durationSec)
	showToast("⚡ Personal 2× Boost: " .. fmtTime(durationSec) .. " !")
end)

print("[HUD] Cash Empire Tycoon — Tabbed Shop, Promo Codes, Server Boost loaded.")
