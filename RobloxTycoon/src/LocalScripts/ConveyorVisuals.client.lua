-- ConveyorVisuals — client-side moving cash bills, gold bars, diamonds & deposit pops
local Workspace    = game:GetService("Workspace")
local TweenService = game:GetService("TweenService")
local Debris       = game:GetService("Debris")

local PLOT_H = 4

local ITEM_STYLES = {
	bill = {
		size     = Vector3.new(2.0, 0.16, 1.1),
		color    = Color3.fromRGB(85, 200, 95),
		material = Enum.Material.SmoothPlastic,
		strap    = Color3.fromRGB(240, 215, 110),
		symbol   = "$",
	},
	stack = {
		size     = Vector3.new(2.2, 0.55, 1.25),
		color    = Color3.fromRGB(65, 180, 80),
		material = Enum.Material.SmoothPlastic,
		strap    = Color3.fromRGB(255, 215, 0),
		symbol   = "$$$",
	},
	gold = {
		size     = Vector3.new(2.1, 0.65, 1.15),
		color    = Color3.fromRGB(255, 195, 30),
		material = Enum.Material.Metal,
		strap    = nil,
		symbol   = "GOLD",
	},
	diamond = {
		size     = Vector3.new(1.4, 1.4, 1.4),
		color    = Color3.fromRGB(70, 230, 255),
		material = Enum.Material.Neon,
		strap    = nil,
		symbol   = "💎",
	},
}

local function spawnCollectPop(pos, text, color)
	local anchor = Instance.new("Part")
	anchor.Size         = Vector3.new(0.2, 0.2, 0.2)
	anchor.CFrame       = CFrame.new(pos + Vector3.new(0, 1.2, 0))
	anchor.Anchored     = true
	anchor.CanCollide   = false
	anchor.Transparency = 1
	anchor.Parent       = Workspace

	local bbg = Instance.new("BillboardGui")
	bbg.Size        = UDim2.new(0, 90, 0, 32)
	bbg.AlwaysOnTop = false
	bbg.MaxDistance = 65
	bbg.Parent      = anchor

	local lbl = Instance.new("TextLabel")
	lbl.Size                   = UDim2.new(1, 0, 1, 0)
	lbl.BackgroundTransparency = 1
	lbl.TextColor3             = color
	lbl.TextStrokeTransparency = 0.3
	lbl.TextScaled             = true
	lbl.Font                   = Enum.Font.GothamBold
	lbl.Text                   = text
	lbl.Parent                 = bbg

	TweenService:Create(anchor, TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		CFrame = anchor.CFrame + Vector3.new(0, 3.2, 0)
	}):Play()
	TweenService:Create(lbl, TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		TextTransparency       = 1,
		TextStrokeTransparency = 1,
	}):Play()

	Debris:AddItem(anchor, 1.0)
end

local function createItemPart(style, startPos, rotY)
	local part = Instance.new("Part")
	part.Name          = "VisualCashItem"
	part.Size          = style.size
	part.Color         = style.color
	part.Material      = style.material
	part.Anchored      = true
	part.CanCollide    = false
	part.CastShadow    = false
	part.TopSurface    = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.CFrame        = CFrame.new(startPos) * CFrame.Angles(0, rotY, 0)
	part.Parent        = Workspace

	if style.strap then
		local strap = Instance.new("Part")
		strap.Size          = Vector3.new(0.38, style.size.Y + 0.04, style.size.Z + 0.04)
		strap.Color         = style.strap
		strap.Material      = Enum.Material.SmoothPlastic
		strap.Anchored      = false
		strap.CanCollide    = false
		strap.CastShadow    = false
		strap.CFrame        = part.CFrame
		strap.Parent        = part
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = part; weld.Part1 = strap; weld.Parent = part
	end

	local sg = Instance.new("SurfaceGui")
	sg.Face = Enum.NormalId.Top; sg.PixelsPerStud = 30; sg.Parent = part
	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.new(1,0,1,0); lbl.BackgroundTransparency = 1
	lbl.TextColor3 = Color3.fromRGB(255,255,255); lbl.TextStrokeTransparency = 0.4
	lbl.TextScaled = true; lbl.Font = Enum.Font.GothamBold
	lbl.Text = style.symbol; lbl.Parent = sg

	return part
end

local function launchItem(plot, styleKey, laneOffsetX, hasMultiplier)
	local pp = plot.PrimaryPart
	if not pp then return end

	local style = ITEM_STYLES[styleKey] or ITEM_STYLES.bill
	local px, pz = pp.Position.X, pp.Position.Z

	local dropPos    = Vector3.new(px + laneOffsetX, PLOT_H + 3.2, pz - 16)
	local beltStart  = Vector3.new(px + laneOffsetX, PLOT_H + 1.35, pz - 16)
	local midPoint   = Vector3.new(px + laneOffsetX, PLOT_H + 1.35, pz + 4)
	local collectPos = Vector3.new(px + laneOffsetX, PLOT_H + 0.65, pz + 23)

	local rotY = math.rad(math.random(-18, 18))
	local item = createItemPart(style, dropPos, rotY)

	local dropTween = TweenService:Create(item, TweenInfo.new(0.28, Enum.EasingStyle.Bounce, Enum.EasingDirection.Out), {
		CFrame = CFrame.new(beltStart) * CFrame.Angles(0, rotY, 0)
	})
	dropTween:Play(); dropTween.Completed:Wait()
	if not item.Parent then return end

	local midTween = TweenService:Create(item, TweenInfo.new(1.35, Enum.EasingStyle.Linear), {
		CFrame = CFrame.new(midPoint) * CFrame.Angles(0, rotY, 0)
	})
	midTween:Play(); midTween.Completed:Wait()
	if not item.Parent then return end

	if hasMultiplier then
		item.Material = Enum.Material.Neon
		item.Color    = Color3.fromRGB(110, 255, 140)
		item.Size     = item.Size * 1.22
	end

	local endTween = TweenService:Create(item, TweenInfo.new(1.35, Enum.EasingStyle.Linear), {
		CFrame = CFrame.new(collectPos) * CFrame.Angles(0, rotY, 0)
	})
	endTween:Play(); endTween.Completed:Wait()
	if not item.Parent then return end

	local popColor = styleKey == "diamond" and Color3.fromRGB(100, 240, 255)
		or (styleKey == "gold" and Color3.fromRGB(255, 215, 0) or Color3.fromRGB(100, 255, 130))
	spawnCollectPop(collectPos, "+$", popColor)

	local shrink = TweenService:Create(item, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		Size = Vector3.new(0.1, 0.1, 0.1), Transparency = 1,
	})
	shrink:Play()
	Debris:AddItem(item, 0.25)
end

local function watchPlot(plot)
	task.spawn(function()
		local lanes   = { -14, -5, 5, 14 }
		local laneIdx = 1

		while plot.Parent do
			local ov = plot:FindFirstChild("Owner")
			if ov and ov.Value ~= "" then
				local pool = { "bill" }
				if plot:FindFirstChild("Upgrade_7") or plot:FindFirstChild("Upgrade_9") then
					table.insert(pool, "stack")
				end
				if plot:FindFirstChild("Upgrade_11") then table.insert(pool, "gold") end
				if plot:FindFirstChild("Upgrade_13") then table.insert(pool, "diamond") end

				local hasMult = (plot:FindFirstChild("Upgrade_8") ~= nil) or (plot:FindFirstChild("Upgrade_12") ~= nil)
				local chosenStyle = pool[math.random(1, #pool)]
				local laneX = lanes[laneIdx]
				laneIdx = (laneIdx % #lanes) + 1

				task.spawn(launchItem, plot, chosenStyle, laneX, hasMult)

				local interval = math.max(0.45, 1.25 - (#pool * 0.2))
				task.wait(interval)
			else
				task.wait(1.5)
			end
		end
	end)
end

local plotsFolder = Workspace:WaitForChild("Plots", 15)
if plotsFolder then
	for _, plot in ipairs(plotsFolder:GetChildren()) do
		watchPlot(plot)
	end
	plotsFolder.ChildAdded:Connect(watchPlot)
end

print("[ConveyorVisuals] Moving cash bills & droppers active.")
