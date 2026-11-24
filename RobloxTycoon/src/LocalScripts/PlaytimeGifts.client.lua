-- PlaytimeGifts — timed gift modal, live countdowns, ready badge & 2x boost timer
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local ClaimGift   = ReplicatedStorage:WaitForChild("ClaimGift", 15)
local UpdateBoost = ReplicatedStorage:WaitForChild("UpdateBoost", 15)
local hud         = playerGui:WaitForChild("CashHUD", 15)

local REWARDS = {
	{ id = 1, waitSec = 60,   title = "FREE CASH",  desc = "15s of Income", color = Color3.fromRGB(46, 204, 113) },
	{ id = 2, waitSec = 180,  title = "2× BOOST",   desc = "2 Mins Active", color = Color3.fromRGB(241, 196, 15) },
	{ id = 3, waitSec = 360,  title = "CASH CRATE", desc = "45s of Income", color = Color3.fromRGB(46, 204, 113) },
	{ id = 4, waitSec = 600,  title = "MEGA 2×",    desc = "4 Mins Active", color = Color3.fromRGB(230, 126, 34) },
	{ id = 5, waitSec = 900,  title = "GOLD VAULT", desc = "90s of Income", color = Color3.fromRGB(255, 215, 0) },
	{ id = 6, waitSec = 1500, title = "ULTRA 2×",   desc = "6 Mins Active", color = Color3.fromRGB(155, 89, 182) },
}

local joinClock  = os.clock()
local claimed    = {}
local boostUntil = 0

local function fmtTime(sec)
	sec = math.max(0, math.ceil(sec))
	return string.format("%02d:%02d", math.floor(sec / 60), sec % 60)
end

-- ── GIFTS Button ──────────────────────────────────────────────────────────────
local giftsBtn = Instance.new("TextButton")
giftsBtn.Name             = "GiftsBtn"
giftsBtn.Size             = UDim2.new(0.085, 0, 0.06, 0)
giftsBtn.Position         = UDim2.new(0.84, 0, 0.015, 0)
giftsBtn.BackgroundColor3 = Color3.fromRGB(211, 84, 0)
giftsBtn.BorderSizePixel  = 0
giftsBtn.TextColor3       = Color3.fromRGB(255, 255, 255)
giftsBtn.TextScaled       = true
giftsBtn.Font             = Enum.Font.GothamBold
giftsBtn.Text             = "GIFTS"
giftsBtn.Parent           = hud
Instance.new("UICorner", giftsBtn).CornerRadius = UDim.new(0.35, 0)
local gStroke = Instance.new("UIStroke", giftsBtn)
gStroke.Color = Color3.fromRGB(255, 215, 0); gStroke.Thickness = 1.5

local badge = Instance.new("TextLabel")
badge.Size             = UDim2.new(0.34, 0, 0.45, 0)
badge.Position         = UDim2.new(0.76, 0, -0.15, 0)
badge.BackgroundColor3 = Color3.fromRGB(231, 76, 60)
badge.TextColor3       = Color3.fromRGB(255, 255, 255)
badge.TextScaled       = true
badge.Font             = Enum.Font.GothamBold
badge.Text             = "!"
badge.Visible          = false
badge.Parent           = giftsBtn
Instance.new("UICorner", badge).CornerRadius = UDim.new(1, 0)

-- ── 2× Boost Banner ───────────────────────────────────────────────────────────
local boostPill = Instance.new("Frame")
boostPill.Size             = UDim2.new(0.24, 0, 0.048, 0)
boostPill.Position         = UDim2.new(0.38, 0, 0.925, 0)
boostPill.BackgroundColor3 = Color3.fromRGB(180, 110, 0)
boostPill.BorderSizePixel  = 0
boostPill.Visible          = false
boostPill.Parent           = hud
Instance.new("UICorner", boostPill).CornerRadius = UDim.new(0.4, 0)
local bStroke = Instance.new("UIStroke", boostPill)
bStroke.Color = Color3.fromRGB(255, 235, 100); bStroke.Thickness = 1.5

local boostLbl = Instance.new("TextLabel")
boostLbl.Size                   = UDim2.new(0.92, 0, 0.85, 0)
boostLbl.Position               = UDim2.new(0.04, 0, 0.075, 0)
boostLbl.BackgroundTransparency = 1
boostLbl.TextColor3             = Color3.fromRGB(255, 255, 255)
boostLbl.TextScaled             = true
boostLbl.Font                   = Enum.Font.GothamBold
boostLbl.Text                   = "⚡ 2× CASH: 02:00"
boostLbl.Parent                 = boostPill

-- ── Gift Panel ────────────────────────────────────────────────────────────────
local giftPanel = Instance.new("Frame")
giftPanel.Name                   = "GiftPanel"
giftPanel.Size                   = UDim2.new(0.54, 0, 0.58, 0)
giftPanel.Position               = UDim2.new(0.23, 0, 0.21, 0)
giftPanel.BackgroundColor3       = Color3.fromRGB(12, 18, 32)
giftPanel.BackgroundTransparency = 0.04
giftPanel.BorderSizePixel        = 0
giftPanel.Visible                = false
giftPanel.ZIndex                 = 30
giftPanel.Parent                 = hud
Instance.new("UICorner", giftPanel).CornerRadius = UDim.new(0.04, 0)
local gpStroke = Instance.new("UIStroke", giftPanel)
gpStroke.Color = Color3.fromRGB(255, 180, 0); gpStroke.Thickness = 2

local gpTitle = Instance.new("TextLabel")
gpTitle.Size = UDim2.new(0.8,0,0.13,0); gpTitle.Position = UDim2.new(0.04,0,0.02,0)
gpTitle.BackgroundTransparency = 1; gpTitle.TextColor3 = Color3.fromRGB(255,215,0)
gpTitle.TextScaled = true; gpTitle.Font = Enum.Font.GothamBold
gpTitle.Text = "PLAYTIME REWARDS"; gpTitle.TextXAlignment = Enum.TextXAlignment.Left
gpTitle.ZIndex = 31; gpTitle.Parent = giftPanel

local closeGpBtn = Instance.new("TextButton")
closeGpBtn.Size = UDim2.new(0.1,0,0.12,0); closeGpBtn.Position = UDim2.new(0.87,0,0.025,0)
closeGpBtn.BackgroundColor3 = Color3.fromRGB(192,57,43); closeGpBtn.BorderSizePixel = 0
closeGpBtn.TextColor3 = Color3.fromRGB(255,255,255); closeGpBtn.TextScaled = true
closeGpBtn.Font = Enum.Font.GothamBold; closeGpBtn.Text = "X"
closeGpBtn.ZIndex = 31; closeGpBtn.Parent = giftPanel
Instance.new("UICorner", closeGpBtn).CornerRadius = UDim.new(0.3, 0)

local gridFrame = Instance.new("Frame")
gridFrame.Size = UDim2.new(0.92,0,0.78,0); gridFrame.Position = UDim2.new(0.04,0,0.18,0)
gridFrame.BackgroundTransparency = 1; gridFrame.ZIndex = 31; gridFrame.Parent = giftPanel
local grid = Instance.new("UIGridLayout", gridFrame)
grid.CellSize = UDim2.new(0.31,0,0.46,0); grid.CellPadding = UDim2.new(0.03,0,0.06,0)
grid.SortOrder = Enum.SortOrder.LayoutOrder

local cardButtons = {}

for _, r in ipairs(REWARDS) do
	local card = Instance.new("Frame")
	card.BackgroundColor3 = Color3.fromRGB(22,32,54); card.BorderSizePixel = 0
	card.LayoutOrder = r.id; card.ZIndex = 32; card.Parent = gridFrame
	Instance.new("UICorner", card).CornerRadius = UDim.new(0.12, 0)
	local cStroke = Instance.new("UIStroke", card)
	cStroke.Color = r.color; cStroke.Thickness = 1.5

	local tLbl = Instance.new("TextLabel")
	tLbl.Size = UDim2.new(0.9,0,0.28,0); tLbl.Position = UDim2.new(0.05,0,0.08,0)
	tLbl.BackgroundTransparency = 1; tLbl.TextColor3 = r.color
	tLbl.TextScaled = true; tLbl.Font = Enum.Font.GothamBold
	tLbl.Text = r.title; tLbl.ZIndex = 33; tLbl.Parent = card

	local dLbl = Instance.new("TextLabel")
	dLbl.Size = UDim2.new(0.9,0,0.24,0); dLbl.Position = UDim2.new(0.05,0,0.36,0)
	dLbl.BackgroundTransparency = 1; dLbl.TextColor3 = Color3.fromRGB(220,230,245)
	dLbl.TextScaled = true; dLbl.Font = Enum.Font.Gotham
	dLbl.Text = r.desc; dLbl.ZIndex = 33; dLbl.Parent = card

	local btn = Instance.new("TextButton")
	btn.Size = UDim2.new(0.84,0,0.28,0); btn.Position = UDim2.new(0.08,0,0.64,0)
	btn.BackgroundColor3 = Color3.fromRGB(60,70,90); btn.BorderSizePixel = 0
	btn.TextColor3 = Color3.fromRGB(255,255,255); btn.TextScaled = true
	btn.Font = Enum.Font.GothamBold; btn.Text = fmtTime(r.waitSec)
	btn.ZIndex = 33; btn.Parent = card
	Instance.new("UICorner", btn).CornerRadius = UDim.new(0.25, 0)

	cardButtons[r.id] = { btn = btn, waitSec = r.waitSec }

	btn.MouseButton1Click:Connect(function()
		if claimed[r.id] then return end
		if (os.clock() - joinClock) < r.waitSec then return end
		ClaimGift:FireServer(r.id)
	end)
end

giftsBtn.MouseButton1Click:Connect(function()
	giftPanel.Visible = not giftPanel.Visible
end)
closeGpBtn.MouseButton1Click:Connect(function()
	giftPanel.Visible = false
end)

ClaimGift.OnClientEvent:Connect(function(giftId)
	claimed[giftId] = true
	local entry = cardButtons[giftId]
	if entry then
		entry.btn.Text             = "CLAIMED ✓"
		entry.btn.BackgroundColor3 = Color3.fromRGB(50, 60, 75)
	end
end)

UpdateBoost.OnClientEvent:Connect(function(remainingSec)
	boostUntil = os.clock() + remainingSec
end)

-- ── 1-Second Countdown Loop ───────────────────────────────────────────────────
task.spawn(function()
	while true do
		task.wait(1)
		local elapsed    = os.clock() - joinClock
		local readyCount = 0

		for id, entry in pairs(cardButtons) do
			if not claimed[id] then
				local left = entry.waitSec - elapsed
				if left <= 0 then
					readyCount += 1
					entry.btn.Text             = "CLAIM!"
					entry.btn.BackgroundColor3 = Color3.fromRGB(39, 174, 96)
				else
					entry.btn.Text = fmtTime(left)
				end
			end
		end

		badge.Visible = readyCount > 0
		badge.Text    = tostring(readyCount)

		local boostLeft = boostUntil - os.clock()
		if boostLeft > 0 then
			boostPill.Visible = true
			boostLbl.Text     = "⚡ 2× CASH: " .. fmtTime(boostLeft)
		else
			boostPill.Visible = false
		end
	end
end)

print("[PlaytimeGifts] Timed gift & boost UI loaded.")
