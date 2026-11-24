-- ShopHandler — gamepass checks + developer product receipts
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local MarketplaceService = game:GetService("MarketplaceService")
local Players            = game:GetService("Players")
local ServerStorage      = game:GetService("ServerStorage")

local PlayerDataManager = require(ServerStorage:WaitForChild("PlayerDataManager"))

-- ── Gamepass IDs ─────────────────────────────────────────────────────────────
local GAMEPASS_IDS = {
	VIP            = 2096727203,
	AutoCollect    = 2094001229,
	StarterPack    = 2092291263,
	DoublePrestige = 2092441277,
}

-- ── Developer Product IDs ─────────────────────────────────────────────────────
-- Set real IDs from Roblox Creator Dashboard → Monetization → Developer Products.
-- Leave as 0 until created; ProcessReceipt safely ignores 0-valued entries.
local DEVPRODUCT_IDS = {
	Cash10k        = 0, -- TODO: set real product ID  (+$10,000 Cash)
	Cash100k       = 0, -- TODO: set real product ID  (+$100,000 Cash)
	ServerBoost2x  = 0, -- TODO: set real product ID  (Server-wide 2× boost, 15 min)
	InstantRebirth = 0, -- TODO: set real product ID  (Instant Prestige Rebirth)
}
-- Keep this table synced with DEVPRODUCT_IDS in HUD.client.lua (client needs IDs for shop UI).

local ShopHandler = {}

-- TycoonManager fills this after requiring ShopHandler.
-- Called from ProcessReceipt so effects run in the same call stack.
ShopHandler.OnProductPurchased = nil

-- ── Gamepass check ────────────────────────────────────────────────────────────
function ShopHandler.checkGamepasses(player)
	local data = PlayerDataManager.getData(player)
	if not data then return end

	for passName, passId in pairs(GAMEPASS_IDS) do
		local owned = false
		local ok, result = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(player.UserId, passId)
		end)
		if ok then owned = result end
		data.Gamepasses[passName] = owned
	end
end

-- ── Developer Product receipts ────────────────────────────────────────────────
MarketplaceService.ProcessReceipt = function(receiptInfo)
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if not player then return Enum.ProductPurchaseDecision.NotProcessedYet end

	local data = PlayerDataManager.getData(player)
	if not data then return Enum.ProductPurchaseDecision.NotProcessedYet end

	local pid = receiptInfo.ProductId
	local fulfilled = false

	local function tryProduct(configId, action)
		if configId ~= 0 and pid == configId then
			action(); fulfilled = true
		end
	end

	tryProduct(DEVPRODUCT_IDS.Cash10k, function()
		PlayerDataManager.addCash(player, 10000)
		if ShopHandler.OnProductPurchased then
			ShopHandler.OnProductPurchased(player, "Cash10k", 10000)
		end
	end)

	tryProduct(DEVPRODUCT_IDS.Cash100k, function()
		PlayerDataManager.addCash(player, 100000)
		if ShopHandler.OnProductPurchased then
			ShopHandler.OnProductPurchased(player, "Cash100k", 100000)
		end
	end)

	tryProduct(DEVPRODUCT_IDS.ServerBoost2x, function()
		if ShopHandler.OnProductPurchased then
			ShopHandler.OnProductPurchased(player, "ServerBoost2x", 900)
		end
	end)

	tryProduct(DEVPRODUCT_IDS.InstantRebirth, function()
		if ShopHandler.OnProductPurchased then
			ShopHandler.OnProductPurchased(player, "InstantRebirth", 0)
		end
	end)

	if not fulfilled then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local uc = ReplicatedStorage:FindFirstChild("UpdateCash")
	if uc then uc:FireClient(player, data.Cash) end

	return Enum.ProductPurchaseDecision.PurchaseGranted
end

-- ── Ensure shared RemoteEvents exist ─────────────────────────────────────────
local function ensureRemote(parent, name)
	local r = parent:FindFirstChild(name)
	if not r then
		r = Instance.new("RemoteEvent"); r.Name = name; r.Parent = parent
	end
	return r
end

ensureRemote(ReplicatedStorage, "UpdateCash")
ensureRemote(ReplicatedStorage, "UpdateIncome")
ensureRemote(ReplicatedStorage, "UpdatePrestige")
ensureRemote(ReplicatedStorage, "UpdateLeaderboard")

local refreshRemote = ensureRemote(ReplicatedStorage, "RefreshGamepasses")
refreshRemote.OnServerEvent:Connect(function(player)
	ShopHandler.checkGamepasses(player)
end)

return ShopHandler
