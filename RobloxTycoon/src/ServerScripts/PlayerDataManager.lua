-- Handles saving and loading all player data using DataStoreService
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

local PlayerStore = DataStoreService:GetDataStore("TycoonPlayerData_v1")

local PlayerDataManager = {}
local loadedData = {}

local DEFAULT_DATA = {
	Cash = 0,
	TotalEarned = 0,
	PrestigeLevel = 0,
	PrestigeMultiplier = 1,
	UnlockedUpgrades = {},  -- ordered list of upgrade IDs (1-30) owned by the player
	StarterPackClaimed = false,
	RedeemedCodes = {},      -- [upperCaseCode] = true once claimed
	GroupBonusClaimed = false,
	Gamepasses = {
		VIP = false,
		AutoCollect = false,
		StarterPack = false,
		DoublePrestige = false,
	},
}

local function deepCopy(original)
	local copy = {}
	for k, v in pairs(original) do
		if type(v) == "table" then
			copy[k] = deepCopy(v)
		else
			copy[k] = v
		end
	end
	return copy
end

function PlayerDataManager.loadPlayer(player)
	local userId = tostring(player.UserId)
	local success, data = pcall(function()
		return PlayerStore:GetAsync(userId)
	end)

	if success and data then
		-- merge saved data with defaults so new keys always exist
		local merged = deepCopy(DEFAULT_DATA)
		for k, v in pairs(data) do
			if type(v) == "table" and type(merged[k]) == "table" then
				for k2, v2 in pairs(v) do
					merged[k][k2] = v2
				end
			else
				merged[k] = v
			end
		end
		loadedData[userId] = merged
	else
		loadedData[userId] = deepCopy(DEFAULT_DATA)
	end

	return loadedData[userId]
end

function PlayerDataManager.savePlayer(player)
	local userId = tostring(player.UserId)
	local data = loadedData[userId]
	if not data then return end

	local success, err = pcall(function()
		PlayerStore:SetAsync(userId, data)
	end)

	if not success then
		warn("Failed to save data for " .. player.Name .. ": " .. tostring(err))
	end
end

function PlayerDataManager.getData(player)
	return loadedData[tostring(player.UserId)]
end

function PlayerDataManager.addCash(player, amount)
	local data = PlayerDataManager.getData(player)
	if data then
		data.Cash = data.Cash + amount
		data.TotalEarned = (data.TotalEarned or 0) + amount
	end
end

function PlayerDataManager.spendCash(player, amount)
	local data = PlayerDataManager.getData(player)
	if not data then return false end
	if data.Cash < amount then return false end
	data.Cash = data.Cash - amount
	return true
end

-- Auto-save every 60 seconds
game:GetService("RunService").Heartbeat:Connect(function()
	-- handled via periodic loop below
end)

local function autoSaveLoop()
	while true do
		task.wait(60)
		for _, player in ipairs(Players:GetPlayers()) do
			PlayerDataManager.savePlayer(player)
		end
	end
end

task.spawn(autoSaveLoop)

Players.PlayerRemoving:Connect(function(player)
	PlayerDataManager.savePlayer(player)
	loadedData[tostring(player.UserId)] = nil
end)

game:BindToClose(function()
	for _, player in ipairs(Players:GetPlayers()) do
		PlayerDataManager.savePlayer(player)
	end
end)

return PlayerDataManager
