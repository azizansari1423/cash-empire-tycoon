-- SoundManager — cash collect, upgrade purchase, rebirth fanfare, UI clicks & mute toggle
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService      = game:GetService("SoundService")

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local UpdateCash     = ReplicatedStorage:WaitForChild("UpdateCash", 15)
local UpdatePrestige = ReplicatedStorage:WaitForChild("UpdatePrestige", 15)

local soundFolder = Instance.new("Folder")
soundFolder.Name   = "GameSounds"
soundFolder.Parent = SoundService

local isMuted = false

local function createSound(name, soundId, volume, pitch)
	local s = Instance.new("Sound")
	s.Name          = name
	s.SoundId       = soundId
	s.Volume        = volume or 0.5
	s.PlaybackSpeed = pitch or 1.0
	s.Parent        = soundFolder
	return s
end

local collectSound = createSound("CashCollect", "rbxassetid://12222030", 0.45, 1.15)
local upgradeSound = createSound("UpgradeBuy",  "rbxassetid://12222253", 0.55, 1.2)
local rebirthSound = createSound("Rebirth",     "rbxassetid://12222253", 0.80, 0.9)
local clickSound   = createSound("UIClick",     "rbxassetid://12221967", 0.35, 1.0)

local function playSFX(sound, minPitch, maxPitch)
	if isMuted or not sound then return end
	if minPitch and maxPitch then
		sound.PlaybackSpeed = math.random(minPitch * 100, maxPitch * 100) / 100
	end
	sound:Play()
end

local cashInitialized = false
local prevCash        = 0

if UpdateCash then
	UpdateCash.OnClientEvent:Connect(function(cash)
		if not cashInitialized then
			prevCash = cash; cashInitialized = true; return
		end
		if cash > prevCash then
			playSFX(collectSound, 1.05, 1.25)
		elseif cash < prevCash then
			playSFX(upgradeSound, 1.15, 1.25)
		end
		prevCash = cash
	end)
end

local levelInitialized = false
local prevLevel        = 0

if UpdatePrestige then
	UpdatePrestige.OnClientEvent:Connect(function(level)
		if not levelInitialized then
			prevLevel = level; levelInitialized = true; return
		end
		if level > prevLevel then playSFX(rebirthSound) end
		prevLevel = level
	end)
end

local function hookButton(btn)
	if btn:IsA("TextButton") or btn:IsA("ImageButton") then
		if btn:GetAttribute("SoundHooked") then return end
		btn:SetAttribute("SoundHooked", true)
		btn.MouseButton1Click:Connect(function()
			playSFX(clickSound, 0.96, 1.04)
		end)
	end
end

task.spawn(function()
	local hud = playerGui:WaitForChild("CashHUD", 15)
	if not hud then return end

	for _, desc in ipairs(hud:GetDescendants()) do hookButton(desc) end
	hud.DescendantAdded:Connect(hookButton)

	local muteBtn = Instance.new("TextButton")
	muteBtn.Name                   = "MuteBtn"
	muteBtn.Size                   = UDim2.new(0.085, 0, 0.055, 0)
	muteBtn.Position               = UDim2.new(0.903, 0, 0.92, 0)
	muteBtn.BackgroundColor3       = Color3.fromRGB(20, 28, 44)
	muteBtn.BackgroundTransparency = 0.2
	muteBtn.BorderSizePixel        = 0
	muteBtn.TextColor3             = Color3.fromRGB(220, 230, 245)
	muteBtn.TextScaled             = true
	muteBtn.Font                   = Enum.Font.GothamBold
	muteBtn.Text                   = "SFX: ON"
	muteBtn.Parent                 = hud
	Instance.new("UICorner", muteBtn).CornerRadius = UDim.new(0.35, 0)

	muteBtn.MouseButton1Click:Connect(function()
		isMuted = not isMuted
		if isMuted then
			muteBtn.Text             = "SFX: OFF"
			muteBtn.BackgroundColor3 = Color3.fromRGB(140, 40, 40)
		else
			muteBtn.Text             = "SFX: ON"
			muteBtn.BackgroundColor3 = Color3.fromRGB(20, 28, 44)
			playSFX(clickSound)
		end
	end)
end)

print("[SoundManager] Cash Empire Tycoon SFX ready.")
