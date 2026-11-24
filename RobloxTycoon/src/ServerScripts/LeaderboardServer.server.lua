-- Leaderboard: updates player stats every 60 s and broadcasts top 10
local Players           = game:GetService("Players")
local DataStoreService  = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage     = game:GetService("ServerStorage")

local PlayerDataManager = require(ServerStorage:WaitForChild("PlayerDataManager"))

local leaderboardStore = DataStoreService:GetOrderedDataStore("TotalEarned_v1")

-- Remote for client leaderboard UI (use existing or create)
local lbRemote = ReplicatedStorage:FindFirstChild("UpdateLeaderboard")
if not lbRemote then
	lbRemote = Instance.new("RemoteEvent")
	lbRemote.Name = "UpdateLeaderboard"
	lbRemote.Parent = ReplicatedStorage
end

-- ── Save each player's total earned to the ordered store ─────────────────────
local function saveScores()
	for _, player in ipairs(Players:GetPlayers()) do
		local data = PlayerDataManager.getData(player)
		if data then
			local total = data.TotalEarned or data.Cash or 0
			pcall(function()
				leaderboardStore:SetAsync(tostring(player.UserId), total)
			end)
		end
	end
end

-- ── Fetch top 10 and broadcast to all clients ────────────────────────────────
local function broadcastLeaderboard()
	local ok, pages = pcall(function()
		return leaderboardStore:GetSortedAsync(false, 10)
	end)
	if not ok then return end

	local top10 = {}
	local firstPage = pages:GetCurrentPage()
	for _, entry in ipairs(firstPage) do
		local name = "[unknown]"
		local ok2, info = pcall(function()
			return game:GetService("Players"):GetNameFromUserIdAsync(tonumber(entry.key))
		end)
		if ok2 then name = info end
		table.insert(top10, { name, entry.value })  -- array format: {name, cash}
	end

	lbRemote:FireAllClients(top10)
end

-- ── Loop: save then broadcast every 60 s ─────────────────────────────────────
task.spawn(function()
	while true do
		task.wait(60)
		saveScores()
		broadcastLeaderboard()
	end
end)

-- Initial broadcast on first player join
Players.PlayerAdded:Connect(function()
	task.wait(5)
	broadcastLeaderboard()
end)

print("[Leaderboard] Server ready.")
